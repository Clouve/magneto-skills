#!/usr/bin/env bash
# LimeSurvey skill: temp-password.sh
#
# Gives a LimeSurvey admin account a strong temporary password without ever showing it. The password is made here,
# saved to a private file in the agent user's home (the Files pane shows it) and handed to LimeSurvey on the SSH
# channel's stdin. It is never printed and never in a command line, so it stays out of the chat. The admin passes
# it on, and the person changes it after signing in.
#
# Usage: temp-password.sh --create --email <address> [--full-name <name>] [--can-create-surveys] <login>
#        temp-password.sh <login>
#        temp-password.sh --remove <file>
#
#   --create              make the account. Without it the account must exist, and its password is reset.
#   --email ADDR          with --create: the account's email address. LimeSurvey needs one for every account.
#   --full-name NAME      with --create: the name LimeSurvey shows (the login when left out)
#   --can-create-surveys  with --create: let the account make its own surveys. Without it the account sees only
#                         the surveys it is given a role on (admin-users.sh grant).
#   --remove FILE         delete a password file once it is handed over. FILE is a bare name,
#                         limesurvey-passwords/NAME, or a path. It must resolve, links followed, to a .txt file
#                         inside ~/limesurvey-passwords/. Anything else is exit 64 and nothing is touched.
#   --                    ends the options
#
# The password has 20 characters; see lib/limesurvey-files.sh.
#
# The file is ~/limesurvey-passwords/<safe login>-<UTC YYYYmmdd-HHMMSS>.txt, mode 600 in a folder of mode 700. It
# holds the login, the password on a line of its own, the sign-in page, the UTC time it was made, and a reminder to
# have the password changed and the file deleted.
#
# Order: the file is written first, then LimeSurvey is changed, so no password is ever set that nobody has saved.
# If LimeSurvey refuses (the login or the address is taken, the address is not valid), or nothing was run at all,
# the file is deleted again. If the connection drops while LimeSurvey is being changed, nobody can tell from here
# whether the password was set. Then the file is KEPT, since it may hold the only copy of a password that is now
# in force, and the message says so: run the command again, which settles it either way, and remove the file that
# is then out of date.
#
# A reset is refused for the site's main admin (LIMESURVEY_ADMIN_USER): its password is the one the Clouve dashboard
# shows, and a temporary one set here would put the two out of step. playbooks/regain-admin-access.md is the way
# back in.
#
# Output: one line on stdout, `Saved the temporary password for <login> to limesurvey-passwords/<file name> in the
# Files pane.` The password and the full path are never printed.
#
# Env vars read:
#   LIMESURVEY_HOST        for run-in-limesurvey.sh
#   LIMESURVEY_PUBLIC_URL  the sign-in page written into the file
#   LIMESURVEY_ADMIN_USER  the main admin, whose password this script will not reset
#   HOME                   where ~/limesurvey-passwords lives
# It needs no agent-side secret itself: run-in-limesurvey.sh loads the one it uses.
#
# Exit codes:
#   0    done
#   64   usage, or --remove of something that is not a .txt file inside the folder
#   1    LIMESURVEY_PUBLIC_URL, HOME or jq is missing, or the channel failed before anything was changed
#   2    LimeSurvey refused, or a reset was refused (the main admin, an account that does not exist)
#   255  ssh could not reach the container. When that happens after the change was sent, the password may or may
#        not be set: the file is kept, and the message says what to do
#   3    the file could not be written; nothing was changed in LimeSurvey
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the password.
set +x

usage() {
    cat <<'USAGE'
Usage: temp-password.sh --create --email <address> [--full-name <name>] [--can-create-surveys] <login>
       temp-password.sh <login>
       temp-password.sh --remove <file>

Gives a LimeSurvey admin account a strong temporary password and saves it to a private file in
~/limesurvey-passwords (the Files pane shows it). The password is never printed.

  --create              make the account; without it the account must exist, and its password is reset
  --email ADDR          with --create: the account's email address (needed)
  --full-name NAME      with --create: the name LimeSurvey shows
  --can-create-surveys  with --create: let the account make its own surveys
  --remove <file>       delete a password file once it is handed over

Prints one line naming the file. Exit codes: 0 done, 64 usage, 1 a missing setting or tool, 2 LimeSurvey refused
or the reset was refused, 3 the file could not be written, 75 LimeSurvey is being installed, upgraded or
restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/temp-password] %s\n' "$*" >&2; }
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
email=''
full_name=''
can_create=false
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --create) create=1; shift ;;
        --remove) remove=1; shift ;;
        --can-create-surveys) can_create=true; shift ;;
        --email | --full-name)
            [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value"
            if [ "$1" = --email ]; then email="$2"; else full_name="$2"; fi
            shift 2
            ;;
        --email=*) email="${1#--email=}"; shift ;;
        --full-name=*) full_name="${1#--full-name=}"; shift ;;
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
# lib/limesurvey-files.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/limesurvey-files.sh" || exit 1

# remove_file ARG: --remove. What gets deleted is what ARG resolves to, so a link cannot lead out of the folder.
remove_file() {
    local arg="$1" dir dir_real candidate resolved rel
    dir="$(ls_private_dir limesurvey-passwords)" || exit 1
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
        *) die 64 "will not remove '${arg}': it must be a .txt file inside ~/limesurvey-passwords/" ;;
    esac
    rel="${resolved#"${dir_real}"/}"
    [ -f "${resolved}" ] || die 64 "limesurvey-passwords/${rel} is not a file"
    ls_delete_private_file "${resolved}" || die 1 "could not delete limesurvey-passwords/${rel}"
    printf 'Deleted limesurvey-passwords/%s.\n' "${rel}"
}

if [ "${remove}" -eq 1 ]; then
    if [ "${create}" -eq 1 ] || [ -n "${email}${full_name}" ] || [ "${can_create}" = true ]; then
        usage_error "--remove takes only the file to delete"
    fi
    [ "${#positional[@]}" -eq 1 ] || usage_error "--remove takes exactly one file"
    remove_file "${positional[0]}"
    exit 0
fi

[ "${#positional[@]}" -eq 1 ] || usage_error "give exactly one login"
login="${positional[0]}"
[ -n "${login}" ] || usage_error "the login is empty"
if [ "${create}" -eq 0 ] && { [ -n "${email}${full_name}" ] || [ "${can_create}" = true ]; }; then
    usage_error "--email, --full-name and --can-create-surveys only work with --create"
fi
if [ "${create}" -eq 1 ]; then
    [[ "${login}" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || usage_error "a new login is 1 to 64 letters, digits, dots, dashes, underscores or @ signs"
    [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || usage_error "--create needs --email with an address like name@example.com"
fi

[ -n "${LIMESURVEY_PUBLIC_URL:-}" ] || die 1 "LIMESURVEY_PUBLIC_URL is not set (compgen -e | grep -i limesurvey lists the settings this agent has)"
{ [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder"
command -v jq > /dev/null 2>&1 || die 1 "jq is not installed (the limesurvey plugin's install.sh adds it)"

# The main admin's password is the one on the Clouve dashboard; a reset here would put the two out of step.
if [ "${create}" -eq 0 ] && [ -n "${LIMESURVEY_ADMIN_USER:-}" ] && [ "${login,,}" = "${LIMESURVEY_ADMIN_USER,,}" ]; then
    die 2 "\"${login}\" is this deployment's main admin. Its password is the one on the Clouve dashboard, and a temporary password set here would put the two out of step. To get back in, follow playbooks/regain-admin-access.md. Nothing was changed."
fi

# call REQUEST: sends the request to ls-users.php; leaves the reply in reply and the runner's exit code in call_rc
reply=''
call_rc=0
call() {
    reply="$(printf '%s' "$1" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-users.php)"
    call_rc=$?
}

# The account must exist for a reset, and must not exist for a new one. Looking first means no file is made for a
# typo.
call "$(jq -nc --arg login "${login}" '{action: "show", login: $login}')"
case "${call_rc}" in
    0)
        if [ "${create}" -eq 1 ]; then
            die 2 "the admin account \"${login}\" already exists. To give it a new password, run this again without --create. Nothing was changed."
        fi
        if [ "$(jq -r '.result.is_main_admin' <<< "${reply}")" = true ]; then
            die 2 "\"${login}\" is the site's main admin. Its password is the one on the Clouve dashboard. To get back in, follow playbooks/regain-admin-access.md. Nothing was changed."
        fi
        ;;
    1)
        if [ "${create}" -eq 0 ]; then
            die 2 "$(jq -r '.error // "the account could not be read"' <<< "${reply}" 2> /dev/null). Add --create to make it. Nothing was changed."
        fi
        # Exit 1 is also what a failed call gives. Only "there is no admin account" means the login is free.
        if [[ "$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)" != 'there is no admin account'* ]]; then
            die 1 "could not check whether \"${login}\" exists: $(jq -r '.error // "no reply"' <<< "${reply}" 2> /dev/null). Nothing was changed."
        fi
        ;;
    *) exit "${call_rc}" ;;
esac

pw="$(ls_generate_password)" || exit 1

# The file is written before anything changes in LimeSurvey.
dir="$(ls_private_dir limesurvey-passwords)" || die 3 "could not set up ~/limesurvey-passwords; nothing was changed in LimeSurvey"
safe_login="$(LC_ALL=C; printf '%s' "${login//[^A-Za-z0-9._@-]/_}")"
read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
[ -n "${made_time}" ] || die 1 "date gave no time"
name="$(ls_free_name "${dir}" "${safe_login}-${stamp}" txt)" || die 3 "nothing was changed in LimeSurvey"
path="${dir}/${name}"
printf -v content '%s\n' \
    "LimeSurvey temporary password" \
    "" \
    "Login: ${login}" \
    "Sign in at: ${LIMESURVEY_PUBLIC_URL%/}/index.php/admin" \
    "Made: ${made_date} ${made_time} UTC" \
    "" \
    "Temporary password:" \
    "${pw}" \
    "" \
    "Ask them to change it after signing in (their name at the top right, then Account). Delete this file once it's handed over."
printf '%s' "${content}" | ls_write_private_file limesurvey-passwords "${name}" \
    || die 3 "could not save limesurvey-passwords/${name}; nothing was changed in LimeSurvey"
content=''

# Now LimeSurvey. The password goes into the request on jq's stdin and on to the channel's stdin: it is in no
# command line, here or in the container.
if [ "${create}" -eq 1 ]; then
    what="make the account"
    request="$(printf '%s' "${pw}" | jq -Rsc --arg login "${login}" --arg email "${email}" --arg name "${full_name}" --argjson create "${can_create}" \
        '{action: "create", login: $login, email: $email, full_name: $name, can_create_surveys: $create, password: .}')"
else
    what="reset the password of"
    request="$(printf '%s' "${pw}" | jq -Rsc --arg login "${login}" '{action: "set-password", login: $login, password: .}')"
fi
call "${request}"
request=''
if [ "${call_rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    case "${call_rc}" in
        1 | 64 | 70 | 75)
            # LimeSurvey answered no, or nothing was run in the container: no password was set.
            msg "LimeSurvey could not ${what} \"${login}\"${error:+: ${error//"${pw}"/[password hidden]}}"
            if ls_delete_private_file "${path}"; then
                msg "The password file was deleted, so nothing is saved."
            else
                msg "The password file limesurvey-passwords/${name} could not be deleted; remove it with --remove."
            fi
            case "${call_rc}" in 70 | 75) exit "${call_rc}" ;; esac
            exit 2
            ;;
        *)
            # The change was sent and no answer came back (the connection dropped, or the run was cut off). The
            # password may be in force, so the file that holds it stays.
            pw=''
            msg "The connection to LimeSurvey was lost while it was asked to ${what} \"${login}\", so there is no telling whether the password was set."
            msg "The password file limesurvey-passwords/${name} was KEPT: it may hold the password that is in force now."
            if [ "${create}" -eq 1 ]; then
                msg "Check with admin-users.sh show '${login}'. If the account is there, the file holds its password. If it is not, run this command again and remove this file (temp-password.sh --remove '${name}')."
            else
                msg "Run this command again: it sets a new password and saves a new file, which settles it. Then remove this file (temp-password.sh --remove '${name}')."
            fi
            exit 255
            ;;
    esac
fi
pw=''

printf 'Saved the temporary password for %s to limesurvey-passwords/%s in the Files pane.\n' "${login}" "${name}"
