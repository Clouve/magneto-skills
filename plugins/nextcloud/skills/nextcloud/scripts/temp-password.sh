#!/usr/bin/env bash
# Nextcloud DevOps Skill: temp-password.sh
#
# Gives a Nextcloud account a strong temporary password without ever showing it. The
# password is made here, saved to a private file in the agent user's home (the Files pane
# shows it) and handed to Nextcloud on stdin through occ.sh. It is never printed and never
# in a command line, so it stays out of the chat. The admin passes it on, and the person
# changes it after signing in.
#
# Usage: temp-password.sh [--create] [--display-name NAME] [--email ADDR] [--group GROUP]... <uid>
#        temp-password.sh --remove <file>
#
#   --create          Make the account with occ user:add. Without it the account must
#                     exist, and its password is reset with occ user:resetpassword.
#   --display-name    With --create: the name Nextcloud shows for the account.
#   --email           With --create: the account's address, set with user:setting once
#                     the account exists. Not user:add --email, which would also mail a
#                     reset link.
#   --group           With --create: a group to add the account to; repeat for more. occ
#                     makes a group that is missing.
#   --remove FILE     Delete a password file once it is handed over. FILE is a bare name,
#                     nextcloud-passwords/NAME, or a path. It must resolve, links
#                     followed, to a .txt file inside ~/nextcloud-passwords/. Anything
#                     else is exit 64 and nothing is touched. The file goes with
#                     shred -u when that works, else rm -f.
#   --                Ends the options, for a uid that starts with a dash.
#
# The password has 20 characters; see lib/nextcloud-passwords.sh.
#
# The file is ~/nextcloud-passwords/<safe uid>-<UTC YYYYmmdd-HHMMSS>.txt, mode 600 in a
# folder of mode 700. The safe uid is the uid with every byte outside A-Za-z0-9._@-
# turned into _ (Nextcloud takes no other characters in a uid, bar a space and a quote,
# which become _ too). A file made in the same second as another for the same uid gets
# -2, then -3, so one never replaces another. It holds the login (the real uid), the
# password on a line of its own, the sign-in page NEXTCLOUD_URL/login, the UTC time it
# was made, and a reminder to have the password changed and the file deleted.
#
# Order: the file is written first, then Nextcloud is changed, so no password is ever set
# that nobody has saved. If occ refuses (a policy failure, or an account that already
# exists), the file is deleted again, occ's message is shown on stderr and the exit code
# is 2. When the name that "already exists" is another account's email address or another
# spelling of its login, the message names that account.
#
# A user:add that fails can still have made the account: it creates it, then sets the display
# name and the groups, and an error in those later steps (core/Command/User/Add.php in v35.0.2
# does not catch them) leaves an account with the password and without the rest. So two things.
# Before anything is written, a display name over 64 characters (Database::setDisplayName) or a
# group name over 255 (Group\Manager::createGroup, for a new group) is refused with exit 64: they
# are the two errors that can be seen coming. And when user:add fails for any other reason than
# "already exists" (it changed nothing) or an unreachable container (it never ran), the account
# is read back; if it is there, the file is kept, what is missing is listed, and the exit code
# is 2, because the file then holds the only copy of the password.
#
# Resets are refused, with exit 2 and before anything is written, for two accounts:
#   - the main admin (NEXTCLOUD_ADMIN_USER, compared without regard to case). Its password is
#     the one the Clouve dashboard shows; a temporary one set here would put the two out of step.
#     The way back in is playbooks/regain-admin-access.md.
#   - any account, while the encryption app is enabled with per-user keys, which is whenever
#     useMasterKey is stored as anything but 1, true, yes or on (in any case, nothing around it):
#     that is how Nextcloud reads it (getValueBool in Util::isMasterKeyEnabled), so 0, false, no,
#     off and an empty string all mean the master key is off. A reset makes the app back up,
#     delete and regenerate that user's keys, and the files encrypted with the old ones become
#     unreadable. The app registers those listeners only without a master key
#     (apps/encryption/lib/AppInfo/Application.php). The key defaults to on, so an unset key (the
#     config:app:get exits 1 and prints nothing), a true value or a disabled app is fine. If app:list or
#     config:app:get fails in any other way, exit 1 with text included, it cannot tell and refuses too.
# Creating an account is not affected by either.
#
# A reset goes by the account's login. Nextcloud finds an account by its login in any case, and by
# its email address too (Database.php in v35.0.2), so the name given is looked up first and the
# login that user:info returns is used. Another spelling of the login is taken. A name that finds
# the main admin is refused, as the main admin is. Any other name that finds a different account,
# such as its email address, is exit 2 with the login named, so a person is never picked by an
# address alone.
#
# Read-back: after --create, occ user:info shows the account, and what it shows must match
# what was asked for: the login, the display name, the email address and every group. An
# exit code of 0 is not enough: user:add exits 0 even when it skipped a group it could not
# create (core/Command/User/Add.php in v35.0.2). A mismatch is exit 2 and the file is kept,
# since the password is probably set. A reset has nothing to read back afterwards, because
# Nextcloud never shows a password; the account lookup before it is its read.
#
# Output: one line on stdout, `Saved the temporary password for <uid> to
# nextcloud-passwords/<file name> in the Files pane.` The password and the full path are
# never printed. What occ says is shown with the password blanked out, in case it echoes it.
#
# Env vars read:
#   NEXTCLOUD_HOST        for occ.sh
#   NEXTCLOUD_URL         the sign-in page written into the file
#   NEXTCLOUD_ADMIN_USER  the main admin, whose password this script will not reset
#   HOME                  where ~/nextcloud-passwords lives
# It needs no agent-side secret itself: occ.sh loads the one it uses.
#
# Exit codes:
#   0   done
#   64  usage; a display name over 64 characters or a group name over 255; or --remove of
#       something that is not a .txt file inside the folder
#   1   NEXTCLOUD_HOST, NEXTCLOUD_URL, HOME or jq is missing
#   2   Nextcloud refused, the read-back did not match, or a reset was refused (the main admin,
#       per-user encryption keys, a name that is not the account's login, no login from user:info)
#   3   the file could not be written; nothing was changed in Nextcloud
#
# A run that is killed after the file is written leaves the file: occ may already have set
# that password, and a password nobody can find is worse than a spare file. List
# ~/nextcloud-passwords/ and --remove what is not needed.

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: temp-password.sh [--create] [--display-name NAME] [--email ADDR] [--group GROUP]... <uid>
       temp-password.sh --remove <file>

Gives a Nextcloud account a strong temporary password and saves it to a private file in
~/nextcloud-passwords (the Files pane shows it). The password is never printed.

  --create             make the account; without it the account must exist, and its
                       password is reset
  --display-name NAME  with --create: the name Nextcloud shows
  --email ADDR         with --create: the account's email address (no mail is sent)
  --group GROUP        with --create: a group to add the account to; repeat for more
  --remove <file>      delete a password file once it is handed over: a file name or a
                       path inside ~/nextcloud-passwords, ending in .txt
  --                   end of options, for a uid that starts with a dash

Prints one line naming the file. Exit codes: 0 done, 64 usage, 1 a missing setting or
tool, 2 Nextcloud refused or the read-back did not match, 3 the file could not be written.
EOF
}

msg() { printf '[nextcloud/temp-password] %s\n' "$*" >&2; }

die() {
    local code="$1"
    shift
    msg "$@"
    exit "${code}"
}

usage_error() {
    msg "$@"
    usage >&2
    exit 64
}

create=0
remove=0
display_name=""
email=""
member_of=()
positional=()

# set_option NAME VALUE: keeps the value of --display-name, --email or --group; empty is a usage error
set_option() {
    [ -n "$2" ] || usage_error "$1 needs a value"
    case "$1" in
        --display-name) display_name="$2" ;;
        --email) email="$2" ;;
        --group) member_of+=("$2") ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --create) create=1; shift ;;
        --remove) remove=1; shift ;;
        --display-name | --email | --group)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            set_option "$1" "$2"
            shift 2
            ;;
        --display-name=* | --email=* | --group=*)
            set_option "${1%%=*}" "${1#*=}"
            shift
            ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -?*) usage_error "unknown option: $1" ;;
        *) positional+=("$1"); shift ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/nextcloud-passwords.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/nextcloud-passwords.sh" || exit 1

# delete_private_file PATH: shred -u when there is a shred that works, else rm -f. Fails if the file is still there.
delete_private_file() {
    if command -v shred > /dev/null 2>&1 && shred -u -- "$1" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$1"
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# remove_file ARG: --remove. ARG is a bare name (in the folder), ~/NAME, an absolute path, or a
# path relative to the home folder (nextcloud-passwords/NAME is what the Saved line prints).
# What gets deleted is what ARG resolves to, so a link cannot lead out of the folder.
remove_file() {
    local arg="$1" dir dir_real candidate resolved rel
    dir="$(nc_password_dir)" || exit 1
    dir_real="$(realpath -- "${dir}")" || exit 1
    # shellcheck disable=SC2088  # the pattern is a literal ~/ on purpose: a shell never expanded it
    case "${arg}" in
        '') usage_error "--remove needs a file name" ;;
        "~/"*) candidate="${HOME}/${arg#"~/"}" ;;
        /*) candidate="${arg}" ;;
        */*) candidate="${HOME}/${arg}" ;;
        *) candidate="${dir}/${arg}" ;;
    esac
    resolved="$(realpath -- "${candidate}" 2> /dev/null)" || resolved=""
    case "${resolved}" in
        "${dir_real}"/?*.txt) ;;
        *) die 64 "will not remove '${arg}': it must be a .txt file inside ~/nextcloud-passwords/" ;;
    esac
    rel="${resolved#"${dir_real}"/}"
    [ -f "${resolved}" ] || die 64 "nextcloud-passwords/${rel} is not a file"
    delete_private_file "${resolved}" || die 1 "could not delete nextcloud-passwords/${rel}"
    printf 'Deleted nextcloud-passwords/%s.\n' "${rel}"
}

if [ "${remove}" -eq 1 ]; then
    if [ "${create}" -eq 1 ] || [ -n "${display_name}" ] || [ -n "${email}" ] || [ "${#member_of[@]}" -gt 0 ]; then
        usage_error "--remove takes only the file to delete"
    fi
    [ "${#positional[@]}" -eq 1 ] || usage_error "--remove takes exactly one file"
    remove_file "${positional[0]}"
    exit 0
fi

[ "${#positional[@]}" -eq 1 ] || usage_error "give exactly one account name (uid)"
uid="${positional[0]}"
[ -n "${uid}" ] || usage_error "the account name is empty"
if [ "${create}" -eq 0 ] && { [ -n "${display_name}" ] || [ -n "${email}" ] || [ "${#member_of[@]}" -gt 0 ]; }; then
    usage_error "--display-name, --email and --group only work with --create"
fi
if [ -n "${email}" ] && ! [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
    usage_error "--email needs an address like name@example.com, not '${email}'"
fi

[ -n "${NEXTCLOUD_HOST:-}" ] || die 1 "NEXTCLOUD_HOST is not set"
[ -n "${NEXTCLOUD_URL:-}" ] || die 1 "NEXTCLOUD_URL is not set"
{ [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder"
command -v jq > /dev/null 2>&1 || die 1 "jq is not installed (the nextcloud plugin's install.sh adds it)"

# Nextcloud trims a display name before it keeps it, so that is what the read-back expects.
display_expected="${display_name#"${display_name%%[![:space:]]*}"}"
display_expected="${display_expected%"${display_expected##*[![:space:]]}"}"

# char_count TEXT: how many characters TEXT has, counted as PHP's mb_strlen counts them (code points).
# jq counts those whatever the locale; ${#TEXT} would count bytes under LC_ALL=C.
char_count() { jq -rn --arg s "$1" '$s | length'; }

# Limits Nextcloud enforces only after user:add has made the account (see the header).
if [ "${create}" -eq 1 ]; then
    n_chars="$(char_count "${display_expected}")" || die 1 "jq could not count the display name"
    [ "${n_chars}" -le 64 ] || die 64 "the display name has ${n_chars} characters and Nextcloud keeps at most 64; shorten it. Nothing was changed."
    for group in ${member_of[@]+"${member_of[@]}"}; do
        n_chars="$(char_count "${group}")" || die 1 "jq could not count a group name"
        [ "${n_chars}" -le 255 ] || die 64 "a group name has ${n_chars} characters and Nextcloud allows at most 255 in a new group; shorten it. Nothing was changed."
    done
fi

# The main admin's password is the one on the Clouve dashboard; a reset here would put the two out of step.
if [ "${create}" -eq 0 ] && [ -n "${NEXTCLOUD_ADMIN_USER:-}" ] && [ "${uid,,}" = "${NEXTCLOUD_ADMIN_USER,,}" ]; then
    die 2 "\"${uid}\" is this deployment's main admin. Its password is the one on the Clouve dashboard, and a temporary password set here would put the two out of step. To get back in, follow playbooks/regain-admin-access.md. Nothing was changed."
fi

info_json=""
info_text=""
info_rc=0

# first_json_line TEXT: prints the first line of TEXT that starts with {, and fails if there is none.
# occ may print a notice or a PHP warning before its JSON.
first_json_line() {
    local line
    while IFS= read -r line; do
        case "${line}" in '{'*) printf '%s' "${line}"; return 0 ;; esac
    done <<< "$1"
    return 1
}

# read_account: reads the account with user:info. Leaves everything occ printed in info_text,
# its exit code in info_rc and the JSON line in info_json. Fails if occ failed or printed no JSON.
read_account() {
    info_json=""
    info_text="$("${script_dir}/occ.sh" user:info --output=json -- "${uid}" 2>&1)"
    info_rc=$?
    [ "${info_rc}" -eq 0 ] || return 1
    info_json="$(first_json_line "${info_text}")"
}

# mismatches: what the account in info_json lacks of what was asked for, one thing per line;
# nothing when it all matches. Everything compares exactly (a new account keeps its uid as
# typed, and group names are case-sensitive: the tables are utf8mb4_bin) except the email
# address, which Nextcloud trims and keeps in lower case (User::setSystemEMailAddress).
mismatches() {
    jq -r --arg uid "${uid}" --arg display "${display_expected}" --arg email "${email}" '
        (.groups // []) as $have
        | (if (.user_id | tostring) != $uid then "login is \(.user_id)" else empty end),
          (if $display != "" and .display_name != $display then "display name is \"\(.display_name)\"" else empty end),
          (if $email != "" and ((.email // "") | ascii_downcase) != ($email | ascii_downcase) then "email is \"\(.email // "")\"" else empty end),
          ($ARGS.positional[] | select(IN($have[]) | not) | "not in group \(.)")
    ' --args ${member_of[@]+"${member_of[@]}"} <<< "${info_json}"
}

# check_encryption: exits 2 when a reset would regenerate the account's encryption keys, which makes
# its encrypted files unreadable: the encryption app is enabled and useMasterKey is stored as anything
# Nextcloud does not read as true. getValueBool lower-cases the stored text and accepts exactly 1, true,
# yes and on, with no trimming; so 0, false, no, off, an empty string or any other text means the master
# key is off. An unset key (config:app:get exits 1 and prints nothing: the default is on), a true value
# and a disabled app are fine. If app:list or config:app:get fails in another way the script cannot
# tell, so it refuses too.
check_encryption() {
    local apps_text apps_rc apps_json enabled key_text key_rc
    apps_text="$("${script_dir}/occ.sh" app:list --output=json 2>&1)"
    apps_rc=$?
    if [ "${apps_rc}" -ne 0 ] || ! apps_json="$(first_json_line "${apps_text}")"; then
        msg "could not tell whether the encryption app is on (app:list, exit ${apps_rc}), so the password was not reset:"
        printf '%s\n' "${apps_text}" >&2
        exit 2
    fi
    # The type test matters: jq 1.8 says false for null | has(...), where older versions fail, and a
    # reply with no list of enabled apps must not read as "encryption is off".
    enabled="$(jq -r 'if (.enabled | type) == "object" then (.enabled | has("encryption")) else error("no list of enabled apps") end' <<< "${apps_json}" 2> /dev/null)" || enabled=""
    case "${enabled}" in
        false) return 0 ;;
        true) ;;
        *) die 2 "could not read the app list from app:list, so the password was not reset" ;;
    esac
    key_text="$("${script_dir}/occ.sh" config:app:get encryption useMasterKey 2>&1)"
    key_rc=$?
    # An unset key is exit 1 with no output, and the default, the master key, applies. Exit 1 with text is an error
    # that occ turned into 1 (an exception whose code is no number, such as a PDOException's SQLSTATE): refused below.
    if [ "${key_rc}" -eq 1 ] && [ -z "${key_text}" ]; then return 0; fi
    if [ "${key_rc}" -ne 0 ]; then
        msg "could not read the encryption app's useMasterKey (config:app:get, exit ${key_rc}), so the password was not reset:"
        printf '%s\n' "${key_text}" >&2
        exit 2
    fi
    case "${key_text,,}" in
        1 | true | yes | on) return 0 ;;
    esac
    die 2 "the encryption app is on and useMasterKey is stored as \"${key_text}\", which Nextcloud reads as off (only 1, true, yes and on mean on), so it uses per-user keys. A reset would make Nextcloud generate new keys for \"${uid}\", and the files encrypted with the old ones would become unreadable, so nothing was changed. The person can change their own password after signing in."
}

# The account must exist for a reset. Looking first means no file is made for a typo.
if [ "${create}" -eq 0 ]; then
    if ! read_account; then
        if [ "${info_rc}" -eq 1 ]; then
            die 2 "there is no account \"${uid}\" to reset (occ said: ${info_text}). Add --create to make it."
        fi
        msg "could not look up the account \"${uid}\":"
        printf '%s\n' "${info_text}" >&2
        exit 2
    fi
    # Nextcloud finds an account by its login in any case, and by its email address too, so the name given may not be
    # the login. The checks and the reset go by the login that user:info returns.
    real_uid="$(jq -r '.user_id // empty' <<< "${info_json}" 2> /dev/null)"
    [ -n "${real_uid}" ] || die 2 "could not read the login of \"${uid}\" (user:info gave no user_id). Nothing was changed."
    if [ "${real_uid}" != "${uid}" ]; then
        if [ -n "${NEXTCLOUD_ADMIN_USER:-}" ] && [ "${real_uid,,}" = "${NEXTCLOUD_ADMIN_USER,,}" ]; then
            die 2 "\"${uid}\" finds \"${real_uid}\", this deployment's main admin. Its password is the one on the Clouve dashboard, and a temporary password set here would put the two out of step. To get back in, follow playbooks/regain-admin-access.md. Nothing was changed."
        fi
        if [ "${real_uid,,}" != "${uid,,}" ]; then
            die 2 "\"${uid}\" is not a login: Nextcloud found the account \"${real_uid}\" by it (its email address, or another spelling). Check with the user that this is the person, then run this again with the login: temp-password.sh -- $(printf '%q' "${real_uid}"). Nothing was changed."
        fi
        uid="${real_uid}"
    fi
    check_encryption
fi

pw="$(nc_generate_password)" || exit 1

# hide_password TEXT: prints TEXT with the password blanked out, in case occ ever echoes it
hide_password() { printf '%s\n' "${1//"${pw}"/[password hidden]}"; }

# The file is written before anything changes in Nextcloud.
dir="$(nc_password_dir)" || die 3 "could not set up ~/nextcloud-passwords; nothing was changed in Nextcloud"
safe_uid="$(LC_ALL=C; printf '%s' "${uid//[^A-Za-z0-9._@-]/_}")"
read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
[ -n "${made_time}" ] || die 1 "date gave no time"
base="${safe_uid}-${stamp}"
name="${base}.txt"
n=1
while [ -e "${dir}/${name}" ] || [ -L "${dir}/${name}" ]; do
    n=$((n + 1))
    [ "${n}" -le 999 ] || die 3 "nextcloud-passwords already holds 999 files named ${base}*; nothing was changed in Nextcloud"
    name="${base}-${n}.txt"
done
path="${dir}/${name}"
printf -v content '%s\n' \
    "Nextcloud temporary password" \
    "" \
    "Login: ${uid}" \
    "Sign in at: ${NEXTCLOUD_URL%/}/login" \
    "Made: ${made_date} ${made_time} UTC" \
    "" \
    "Temporary password:" \
    "${pw}" \
    "" \
    "Ask them to change it after signing in (Settings > Security). Delete this file once it's handed over."
printf '%s' "${content}" | nc_write_private_file "${name}" \
    || die 3 "could not save nextcloud-passwords/${name}; nothing was changed in Nextcloud"

# keep_note: the file stays, because from here on the password is probably set
keep_note() {
    msg "The password file nextcloud-passwords/${name} was kept, since the password is probably set. Check the account, then remove the file with --remove once it is handed over."
}

# Now Nextcloud. The password goes in on stdin and is in no command line.
if [ "${create}" -eq 1 ]; then
    what="make the account"
    # --password-from-env is written on the user:add line itself, where tests/nextcloud-skill-commands.test.sh
    # (rule 4) can see it; add_args holds the optional parts.
    add_args=()
    if [ -n "${display_name}" ]; then add_args+=("--display-name=${display_name}"); fi
    for group in ${member_of[@]+"${member_of[@]}"}; do add_args+=(-g "${group}"); done
    occ_text="$(printf '%s\n' "${pw}" | "${script_dir}/occ.sh" --password-stdin user:add --password-from-env ${add_args[@]+"${add_args[@]}"} -- "${uid}" 2>&1)"
    occ_rc=$?
else
    what="reset the password of"
    occ_text="$(printf '%s\n' "${pw}" | "${script_dir}/occ.sh" --password-stdin user:resetpassword --password-from-env -- "${uid}" 2>&1)"
    occ_rc=$?
fi
if [ "${occ_rc}" -ne 0 ]; then
    msg "occ could not ${what} \"${uid}\" (exit ${occ_rc}):"
    hide_password "${occ_text}" >&2
    looked=no
    # user:add makes the account, then sets the display name and groups, so it can fail with the account
    # made and the password set. Unless it said the account already exists (it changed nothing) or occ.sh
    # could not reach the container (it never ran), look. If the account is there, this file holds the only
    # copy of its password.
    if [ "${create}" -eq 1 ] && [[ "${occ_text}" != *'already exists'* ]] && [[ "${occ_text}" != *'could not reach'* ]]; then
        looked=yes
        if read_account; then
            differences="$(mismatches 2>&1)" || differences="jq could not read user:info's answer: ${differences}"
            msg "occ made the account \"${uid}\" before it failed, so the account exists and has the temporary password."
            if [ -n "${differences}" ]; then
                msg "What user:info shows does not match what was asked for:"
                printf '%s\n' "${differences}" >&2
                msg "Finish it with user:setting (display name, email) and group:adduser (groups)."
            fi
            keep_note
            exit 2
        fi
    fi
    if delete_private_file "${path}"; then
        msg "The password file was deleted, so nothing is saved."
    else
        msg "The password file nextcloud-passwords/${name} could not be deleted; remove it with --remove."
    fi
    if [ "${create}" -eq 1 ]; then
        if [[ "${occ_text}" == *'already exists'* ]]; then
            # occ finds an account by its email address too: say whose name it was before advising a reset.
            real_uid=""
            if read_account; then real_uid="$(jq -r '.user_id // empty' <<< "${info_json}" 2> /dev/null)"; fi
            if [ -n "${real_uid}" ] && [ "${real_uid,,}" != "${uid,,}" ]; then
                msg "\"${uid}\" is not a free login: Nextcloud finds the account \"${real_uid}\" by it (its email address, or another spelling). Pick another login for the new account, or check with the user whether \"${real_uid}\" is the person."
            else
                msg "That account already exists. To give it a new password, run this again without --create."
            fi
        elif [ "${looked}" = yes ] && [ "${info_rc}" -eq 1 ]; then
            msg "user:info finds no account \"${uid}\", so nothing was made."
        else
            msg "If the account was made before the error, run this again without --create to give it a password."
        fi
    fi
    exit 2
fi

if [ "${create}" -eq 1 ]; then
    if [ -n "${email}" ]; then
        if ! setting_text="$("${script_dir}/occ.sh" user:setting -- "${uid}" settings email "${email}" 2>&1)"; then
            msg "the account \"${uid}\" was made and its password is saved in nextcloud-passwords/${name}, but setting its email failed:"
            printf '%s\n' "${setting_text}" >&2
            msg "Set the email again with occ.sh user:setting -- <uid> settings email <address>, then hand the file over."
            exit 2
        fi
    fi
    if ! read_account; then
        msg "occ said the account \"${uid}\" was made, but user:info could not read it back (exit ${info_rc}):"
        printf '%s\n' "${info_text}" >&2
        keep_note
        exit 2
    fi
    differences="$(mismatches 2>&1)" || differences="jq could not read user:info's answer: ${differences}"
    if [ -n "${differences}" ]; then
        msg "occ said the account \"${uid}\" was made, but user:info does not match what was asked for:"
        printf '%s\n' "${differences}" >&2
        keep_note
        exit 2
    fi
fi

printf 'Saved the temporary password for %s to nextcloud-passwords/%s in the Files pane.\n' "${uid}" "${name}"
