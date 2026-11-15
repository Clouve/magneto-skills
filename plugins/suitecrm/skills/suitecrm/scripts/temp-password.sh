#!/usr/bin/env bash
# SuiteCRM skill: temp-password.sh
#
# Gives a SuiteCRM user a strong temporary password without ever showing it. The password is made here, saved
# to a private file in the agent user's home (the Files pane shows it) and handed to SuiteCRM on the SSH
# channel's stdin. It is never printed and never in a command line, so it stays out of the chat. The admin
# passes it on.
#
# SuiteCRM does not make the person change it at the first sign-in unless the site's rule says so. The rule
# is SuiteCRM's own setting for generated passwords (Admin > Password Management), and on a stock install it
# is "7 days after the password was set": until then the temporary password is the person's working
# password. This script reads the rule and writes what is true for this site into the password file and its
# own output. `users.sh password-rule` prints the rule, and `users.sh password-rule first-sign-in
# --yes-change` sets it to the first sign-in for the whole site. Whatever the rule, ask the person to change
# the password under their profile right after they sign in.
#
# Usage: temp-password.sh --yes-reset <login>
#        temp-password.sh --create --last-name NAME --email ADDR [--first-name NAME] [--admin --yes-admin] <login>
#        temp-password.sh --remove <file>
#
#   --yes-reset     Needed to reset the password of a user that exists. The person's current password stops
#                   working at once, and the old one can't be brought back. Without the flag nothing is
#                   changed and the script says what it would do (exit 64).
#   --create        Make the user. Without it the user must exist, and its password is reset.
#   --last-name     With --create: the person's last name (SuiteCRM requires it).
#   --first-name    With --create: the first name.
#   --email         With --create: the person's email address. No mail is sent.
#   --admin         With --create: make the user an administrator, with full control of SuiteCRM. It needs
#                   --yes-admin; without it nothing is changed (exit 64).
#   --remove FILE   Delete a password file once it is handed over. FILE is a bare name,
#                   suitecrm-passwords/NAME, or a path. It must resolve, links followed, to a .txt file inside
#                   ~/suitecrm-passwords/. Anything else is exit 64 and nothing is touched.
#   --              Ends the options, for a login that starts with a dash.
#
# The password has 20 characters (lib/suitecrm-passwords.sh). The file is
# ~/suitecrm-passwords/<safe login>-<UTC YYYYmmdd-HHMMSS>.txt, mode 600 in a folder of mode 700. It holds the
# login, the password on a line of its own, the sign-in address, the UTC time it was made, when SuiteCRM
# asks for a new password on this site, and a reminder to delete the file.
#
# Order: the account and the site's rule are read, then the file is written, then SuiteCRM is changed, so no
# password is ever set that nobody has saved. If SuiteCRM changes nothing (the user exists already, or
# doesn't, bad input, SuiteCRM being upgraded), the file is deleted again. If the outcome isn't known (the
# script crashed, the SSH session dropped, SuiteCRM did not confirm the password), the file is kept, because
# it may hold the only copy.
#
# Resets are refused for two kinds of account, before anything is written:
#   - the deployment's main admin (SUITECRM_ADMIN_USER, or user id 1). Its password is the one the Clouve
#     dashboard shows, and in the Customer Kit LimeSurvey signs in to SuiteCRM with it.
#     restore-admin-password.sh is the way back in. The login in SUITECRM_ADMIN_USER is refused at once,
#     also without --yes-reset, so that nobody is asked for a yes that would be refused.
#   - an account that signs in through LDAP or SAML: SuiteCRM keeps no password for it.
#
# Output: two lines on stdout. `Saved the temporary password for <login> to suitecrm-passwords/<file> in the
# Files pane.` and then when SuiteCRM asks for a new password on this site, for example `SuiteCRM asks for a
# new password 7 days after the password was set. Until then this password keeps working, so ask the person
# to change it under their profile right after they sign in.` The password and the full path are never
# printed.
#
# Env vars read:
#   SUITECRM_HOST        for run-in-suitecrm.sh
#   SUITECRM_URL         the sign-in address written into the file
#   SUITECRM_ADMIN_USER  the main admin, whose password this script will not reset
#   HOME                 where ~/suitecrm-passwords lives
# It needs no agent-side secret itself: run-in-suitecrm.sh loads the one it uses.
#
# Exit codes:
#   0   done
#   64  usage; --yes-reset or --yes-admin is missing (nothing was changed); or --remove of something that is
#       not a .txt file inside the folder
#   1   SUITECRM_HOST, SUITECRM_URL, HOME or jq is missing
#   2   SuiteCRM refused or did not confirm, or the reset was refused (the main admin, an outside sign-in)
#   3   the file could not be written; nothing was changed in SuiteCRM
#   4   --create and the user exists already; or no --create and there is no such user. Nothing was changed.
#   75  SuiteCRM is being installed or upgraded; nothing was changed
#   255 ssh failed; the file is kept in case the password was set

set -uo pipefail
set +x

usage() {
    cat <<'USAGE'
Usage: temp-password.sh --yes-reset <login>
       temp-password.sh --create --last-name NAME --email ADDR [--first-name NAME] [--admin --yes-admin] <login>
       temp-password.sh --remove <file>

Gives a SuiteCRM user a strong temporary password and saves it to a private file in ~/suitecrm-passwords (the
Files pane shows it). The password is never printed.

SuiteCRM asks the person for a new password when the site's rule says so, which on a stock install is 7 days
after the password was set. Until then the temporary password keeps working. The file and this script's
output say what is true for this site. users.sh password-rule prints the rule and can set it to the first
sign-in.

  --yes-reset        needed to reset an existing user's password: the current one stops working at once
                     and can't be brought back
  --create           make the user; without it the user must exist, and its password is reset
  --last-name NAME   with --create: the last name (required)
  --first-name NAME  with --create: the first name
  --email ADDR       with --create: the email address (required; no mail is sent)
  --admin            with --create: an administrator; needs --yes-admin
  --remove <file>    delete a password file once it is handed over
  --                 end of options

Prints the file's name and when SuiteCRM asks for a new password. Exit codes: 0 done; 64 usage, or a yes
flag is missing; 1 a missing setting or tool; 2 SuiteCRM refused; 3 the file could not be written; 4 the
user exists already, or doesn't exist; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/temp-password] %s\n' "$*" >&2; }
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

# The runner's php form says which script of the skill called it.
export SC_SKILL_CALLER=temp-password.sh

create=0 remove=0 admin=0 yes_reset=0 yes_admin=0
first='' last='' email=''
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --create) create=1; shift ;;
        --remove) remove=1; shift ;;
        --admin) admin=1; shift ;;
        --yes-reset) yes_reset=1; shift ;;
        --yes-admin) yes_admin=1; shift ;;
        --first-name | --last-name | --email)
            [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
            case "$1" in --first-name) first="$2" ;; --last-name) last="$2" ;; --email) email="$2" ;; esac
            shift 2
            ;;
        --) shift; positional+=("$@"); break ;;
        -?*) usage_error "unknown option: $1" ;;
        *) positional+=("$1"); shift ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${script_dir}/lib/suitecrm-passwords.sh" || exit 1

# delete_private_file PATH: shred -u when there is a shred that works, else rm -f. Fails if the file is still there.
delete_private_file() {
    if command -v shred > /dev/null 2>&1 && shred -u -- "$1" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$1"
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# remove_file ARG: --remove. What gets deleted is what ARG resolves to, so a link cannot lead out of the folder.
remove_file() {
    local arg="$1" dir dir_real candidate resolved rel
    dir="$(sc_password_dir)" || exit 1
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
        *) die 64 "will not remove '${arg}': it must be a .txt file inside ~/suitecrm-passwords/" ;;
    esac
    rel="${resolved#"${dir_real}"/}"
    [ -f "${resolved}" ] || die 64 "suitecrm-passwords/${rel} is not a file"
    delete_private_file "${resolved}" || die 1 "could not delete suitecrm-passwords/${rel}"
    printf 'Deleted suitecrm-passwords/%s.\n' "${rel}"
}

if [ "${remove}" -eq 1 ]; then
    if [ "${create}" -eq 1 ] || [ "${admin}" -eq 1 ] || [ "${yes_reset}" -eq 1 ] || [ "${yes_admin}" -eq 1 ] || [ -n "${first}${last}${email}" ]; then
        usage_error "--remove takes only the file to delete"
    fi
    [ "${#positional[@]}" -eq 1 ] || usage_error "--remove takes exactly one file"
    remove_file "${positional[0]}"
    exit 0
fi

[ "${#positional[@]}" -eq 1 ] || usage_error "give exactly one login"
login="${positional[0]}"
[ -n "${login}" ] || usage_error "the login is empty"
if [ "${create}" -eq 0 ] && { [ "${admin}" -eq 1 ] || [ -n "${first}${last}${email}" ]; }; then
    usage_error "--first-name, --last-name, --email and --admin only work with --create"
fi
if [ "${yes_admin}" -eq 1 ] && [ "${admin}" -eq 0 ]; then
    usage_error "--yes-admin goes with --create --admin"
fi
if [ "${create}" -eq 1 ]; then
    [ "${yes_reset}" -eq 0 ] || usage_error "--yes-reset is for a reset; --create makes a new user and needs none"
    [ -n "${last}" ] || usage_error "--create needs --last-name"
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || usage_error "--create needs --email with an address like name@example.com"
fi

# main_admin_refusal LOGIN: why the main admin's password is not reset here
main_admin_refusal() {
    printf '"%s" is this deployment'"'"'s main admin. Its password is the one on the Clouve dashboard, and in the Customer Kit LimeSurvey signs in to SuiteCRM with it, so a temporary password here would break that. To get back in, run restore-admin-password.sh (playbooks/regain-admin-access.md). Nothing was changed.' "$1"
}
# The main admin is refused with or without the yes. Said here, before a yes is asked for that would be
# refused. An account that was renamed is recognised by its id further down, once SuiteCRM was asked.
if [ "${create}" -eq 0 ] && [ -n "${SUITECRM_ADMIN_USER:-}" ] && [ "${login,,}" = "${SUITECRM_ADMIN_USER,,}" ]; then
    die 2 "$(main_admin_refusal "${login}")"
fi

# Who can sign in, and as what, changes only on a clear yes.
if [ "${create}" -eq 0 ] && [ "${yes_reset}" -ne 1 ]; then
    msg "nothing was changed. This replaces the password of $(printf '%q' "${login}") with a new temporary one, saved to a private file in the Files pane. The person's current password stops working at once, and the old one can't be brought back: until someone hands them the new one they can't sign in. Show that to the user, check that the person can be reached, and run it again with --yes-reset after a clear yes."
    exit 64
fi
if [ "${create}" -eq 1 ] && [ "${admin}" -eq 1 ] && [ "${yes_admin}" -ne 1 ]; then
    msg "nothing was changed. This makes the new account $(printf '%q' "${login}") an administrator, with a temporary password in the Files pane. An administrator has full control of SuiteCRM: every record whatever its roles, exports, other users' accounts and Module Loader, which runs code on the server. It can be taken back with users.sh set-admin $(printf '%q' "${login}") no, or users.sh deactivate. Show that to the user, and run it again with --yes-admin after a clear yes."
    exit 64
fi

[ -n "${SUITECRM_HOST:-}" ] || die 1 "SUITECRM_HOST is not set"
[ -n "${SUITECRM_URL:-}" ] || die 1 "SUITECRM_URL is not set"
{ [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder"
command -v jq > /dev/null 2>&1 || die 1 "jq is not installed (the suitecrm plugin's install.sh adds it)"

main="${SUITECRM_ADMIN_USER:--}"
run="${script_dir}/run-in-suitecrm.sh"

# The account is looked up before any file is made, so a typo leaves nothing behind.
show_text="$("${run}" php users.php show "${login}" 2>&1)"
show_rc=$?
case "${show_rc}" in
    0)
        if [ "${create}" -eq 1 ]; then
            die 4 "the user \"${login}\" exists already. To give it a new password, run this again with --yes-reset and without --create. Nothing was changed."
        fi
        ;;
    3)
        if [ "${create}" -eq 0 ]; then
            die 4 "there is no user \"${login}\" to reset. users.sh list shows the logins; add --create to make one. Nothing was changed."
        fi
        ;;
    75 | 255 | 70 | 1)
        printf '%s\n' "${show_text}" >&2
        exit "${show_rc}"
        ;;
    *)
        printf '%s\n' "${show_text}" >&2
        die 2 "could not look up the user \"${login}\" (exit ${show_rc}). Nothing was changed."
        ;;
esac
if [ "${create}" -eq 0 ]; then
    real_login="$(printf '%s\n' "${show_text}" | sed -n '/^{/,$p' | jq -r '.login // empty' 2> /dev/null)"
    user_id="$(printf '%s\n' "${show_text}" | sed -n '/^{/,$p' | jq -r '.id // empty' 2> /dev/null)"
    [ -n "${real_login}" ] || die 2 "could not read the user \"${login}\" back. Nothing was changed."
    if [ "${user_id}" = 1 ] || { [ "${main}" != - ] && [ "${real_login,,}" = "${main,,}" ]; }; then
        die 2 "$(main_admin_refusal "${real_login}")"
    fi
    login="${real_login}"
fi

# When SuiteCRM will ask for a new password, read before the file is written so that the file says what is
# true for this site.
rule_text="$("${run}" php users.php password-rule 2>&1)"
rule_rc=$?
case "${rule_rc}" in
    0) ;;
    75 | 255 | 70 | 1)
        printf '%s\n' "${rule_text}" >&2
        exit "${rule_rc}"
        ;;
    *)
        printf '%s\n' "${rule_text}" >&2
        die 2 "could not read the site's rule for generated passwords (exit ${rule_rc}). Nothing was changed."
        ;;
esac
rule="$(printf '%s\n' "${rule_text}" | sed -n '/^{/,$p' | jq -r '.asks_for_new_password // empty' 2> /dev/null)"
change_now="Sign in and change it right away under your profile."
case "${rule}" in
    'at the first sign-in')
        file_rule="SuiteCRM asks for a new password at the first sign-in."
        said_rule="SuiteCRM asks for a new password at the first sign-in."
        ;;
    never)
        file_rule="SuiteCRM does not ask for a new password by itself. ${change_now}"
        said_rule="SuiteCRM does not ask for a new password by itself on this site. Ask the person to change it under their profile right after they sign in."
        ;;
    *' days after the password was set' | '1 day after the password was set')
        file_rule="SuiteCRM asks for a new password ${rule/the password was set/this one was set}. ${change_now}"
        said_rule="SuiteCRM asks for a new password ${rule}. Until then this password keeps working, so ask the person to change it under their profile right after they sign in."
        ;;
    'at sign-in number '*' with that password')
        file_rule="SuiteCRM asks for a new password ${rule/with that password/with this one}. ${change_now}"
        said_rule="SuiteCRM asks for a new password ${rule}. Until then this password keeps working, so ask the person to change it under their profile right after they sign in."
        ;;
    *)
        file_rule="SuiteCRM may not ask for a new password by itself. ${change_now}"
        said_rule="When SuiteCRM asks for a new password could not be read (users.sh password-rule shows the setting). Ask the person to change it under their profile right after they sign in."
        ;;
esac

pw="$(sc_generate_password)" || exit 1

dir="$(sc_password_dir)" || die 3 "could not set up ~/suitecrm-passwords; nothing was changed in SuiteCRM"
safe_login="$(LC_ALL=C; printf '%s' "${login//[^A-Za-z0-9._@-]/_}")"
read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
[ -n "${made_time}" ] || die 1 "date gave no time"
base="${safe_login}-${stamp}"
name="${base}.txt"
n=1
while [ -e "${dir}/${name}" ] || [ -L "${dir}/${name}" ]; do
    n=$((n + 1))
    [ "${n}" -le 999 ] || die 3 "suitecrm-passwords already holds 999 files named ${base}*; nothing was changed in SuiteCRM"
    name="${base}-${n}.txt"
done
path="${dir}/${name}"
printf -v content '%s\n' \
    "SuiteCRM temporary password" \
    "" \
    "Login: ${login}" \
    "Sign in at: ${SUITECRM_URL%/}/" \
    "Made: ${made_date} ${made_time} UTC" \
    "" \
    "Temporary password:" \
    "${pw}" \
    "" \
    "${file_rule} Delete this file once it is handed over."
printf '%s' "${content}" | sc_write_private_file "${name}" \
    || die 3 "could not save suitecrm-passwords/${name}; nothing was changed in SuiteCRM"

# Now SuiteCRM. The password goes in on stdin and is in no command line: printf is a builtin.
if [ "${create}" -eq 1 ]; then
    out="$(printf '%s\n' "${pw}" | "${run}" --stdin php users.php create "${login}" "${first}" "${last}" "${email}" "${admin}" 2>&1)"
    rc=$?
else
    out="$(printf '%s\n' "${pw}" | "${run}" --stdin php users.php set-password "${login}" "${main}" 2>&1)"
    rc=$?
fi
# What SuiteCRM said, with the password blanked out in case it ever echoes it
shown="${out//"${pw}"/[password hidden]}"

case "${rc}" in
    0) ;;
    3 | 4 | 64 | 65 | 75 | 76)
        # Nothing was changed, so the file holds a password nobody has.
        printf '%s\n' "${shown}" | sed '/^{/,/^}/d' >&2
        if delete_private_file "${path}"; then
            msg "The password file was deleted, so nothing is saved. Nothing was changed in SuiteCRM."
        else
            msg "The password file suitecrm-passwords/${name} could not be deleted; remove it with --remove."
        fi
        case "${rc}" in 3 | 4) exit 4 ;; 75 | 76) exit 75 ;; *) exit 2 ;; esac
        ;;
    2)
        # users.php refuses before it writes (the main admin, an outside sign-in) or fails its read-back after.
        printf '%s\n' "${shown}" | sed '/^{/,/^}/d' >&2
        if [[ "${out}" == *"Nothing was changed."* ]]; then
            if delete_private_file "${path}"; then
                msg "The password file was deleted, so nothing is saved."
            else
                msg "The password file suitecrm-passwords/${name} could not be deleted; remove it with --remove."
            fi
        else
            msg "The password file suitecrm-passwords/${name} was kept, since the password may be set. Check the account with users.sh show, then remove the file with --remove if it is not needed."
        fi
        exit 2
        ;;
    *)
        printf '%s\n' "${shown}" | sed '/^{/,/^}/d' >&2
        msg "The outcome is not known (exit ${rc}). The password file suitecrm-passwords/${name} was kept, since the password may be set. Check the account with users.sh show before you run this again, and remove the file with --remove if it is not needed."
        if [ "${rc}" -eq 255 ]; then exit 255; fi
        exit 2
        ;;
esac

printf 'Saved the temporary password for %s to suitecrm-passwords/%s in the Files pane.\n' "${login}" "${name}"
printf '%s\n' "${said_rule}"
