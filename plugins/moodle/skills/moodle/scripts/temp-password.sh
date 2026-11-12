#!/usr/bin/env bash
# Moodle DevOps Skill: temp-password.sh
#
# Gives a Moodle account a strong temporary password without ever showing it. The password is
# made here and saved to a private file in the agent user's home (the Files pane shows it) before
# Moodle changes. Then Moodle gets it on stdin and checks it against the stored hash. It is never
# printed, never on a command line and never left in your shell, so it stays out of the chat. The
# admin passes it on, and Moodle asks the person for a new one at their first sign-in.
#
# Usage: temp-password.sh [--] <username>
#        temp-password.sh --remove <file>
#
#   (no option)    Two runs of lib/set-temp-password.php in the moodle container, as www-data,
#                  over the clouve-ops SSH channel. The first finds the account by its username and
#                  reads nothing. The second sets the password by the account's id, with the
#                  password on php's stdin: bash's printf, ssh, sudo -n -u www-data, then
#                  stream_get_contents(STDIN). Only the program and the username or the id are on
#                  a command line. A sudo log in the container that records what a command reads
#                  (sudo's I/O log) would keep the password, so don't turn one on. It does what Moodle's own profile page does when an admin types a
#                  new password: the account's sign-in plugin sets it, the External Database sync's
#                  create_password preference is cleared (or Moodle's "Send new user passwords" task
#                  replaces the password within five minutes), a new password is required at the next
#                  sign-in, and the account's sessions end. It works for manual accounts and for the
#                  Education Kit's accounts synced from Gibbon (auth = 'db'). An account that signs in
#                  through an identity provider (OAuth 2, SAML, LDAP) is refused: its password is set
#                  there.
#   --remove FILE  Delete a password file once it is handed over. FILE is a bare name,
#                  moodle-passwords/NAME, or a path. It must resolve, links followed, to a .txt file
#                  inside ~/moodle-passwords/. Anything else is exit 64 and nothing is touched. The file
#                  goes with shred -u when that works, else rm -f.
#   --             Ends the options, for a username that starts with a dash.
#
# The file is ~/moodle-passwords/<user id>-<UTC YYYYmmdd-HHMMSS>.txt, mode 600 in a folder of mode
# 700. Its name and the output line give the account's id, not the username, which is often an
# email address. A file made in the same second as another gets -2, then -3. It holds the
# username, the sign-in page (MOODLE_URL/login/index.php, when that is set), the UTC time it was
# made, the password on a line of its own, and a reminder to delete the file.
#
# Order: the file is written first, then Moodle is changed, so no password is ever set that
# nobody has saved. When Moodle says nothing changed (the account is gone, or the site's password
# policy refused the password), or the run ended before the change started, the file is deleted
# again and the exit code is 2. When the change may have happened (Moodle stopped after it began,
# reported a failure, or the new password doesn't check against the stored hash), the file is kept,
# since it may hold the only copy of the account's password, and the exit code is 2 as well.
#
# Output: one line on stdout that names the file and the user id, and says whether the account is
# suspended, locked after failed sign-ins, or uses a sign-in method that is turned off. What the
# moodle container said on a failure goes to stderr with the password blanked out.
#
# Env vars read:
#   MOODLE_HOST          the moodle container (required)
#   MOODLE_URL           optional: the site's address, for the sign-in page written into the file
#   CLOUVE_OPS_PASSWORD  the clouve-ops password, for sshpass -e (never printed). A current agent
#                        keeps it out of the environment; the loader line below fetches it.
#   HOME                 where ~/moodle-passwords lives
#
# Exit codes:
#   0   done
#   64  usage, or --remove of something that isn't a .txt file inside the folder
#   1   a setting or a tool is missing, or the account couldn't be looked up
#   2   no account that Moodle keeps a password for, or the change failed or may have happened
#       (stderr says whether the password file was kept)
#   3   the password file could not be written; nothing was changed in Moodle

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: temp-password.sh [--] <username>
       temp-password.sh --remove <file>

Gives a Moodle account a strong temporary password and saves it to a private file in
~/moodle-passwords (the Files pane shows it). The password is never printed. Moodle asks for
a new password at the first sign-in.

  --remove <file>  delete a password file once it is handed over: a file name or a path
                   inside ~/moodle-passwords, ending in .txt
  --               end of options, for a username that starts with a dash

Prints one line naming the file. Exit codes: 0 done, 64 usage, 1 a missing setting or tool or
a failed lookup, 2 no such account or a failed change, 3 the file could not be written.
EOF
}

msg() { printf '[moodle/temp-password] %s\n' "$*" >&2; }

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

remove=0
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --remove) remove=1; shift ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -?*) usage_error "unknown option: $1" ;;
        *) positional+=("$1"); shift ;;
    esac
done

# password_dir: makes ~/moodle-passwords with mode 700 (an existing one is set to 700 too) and prints its path
password_dir() {
    local dir
    if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
        msg "HOME is not an existing folder, so ~/moodle-passwords has no place to go"
        return 1
    fi
    dir="${HOME}/moodle-passwords"
    if [ -e "${dir}" ] && [ ! -d "${dir}" ]; then
        msg "the path ~/moodle-passwords is taken by something that is not a folder"
        return 1
    fi
    if ! (umask 077 && mkdir -p -- "${dir}") || ! chmod 700 -- "${dir}"; then
        msg "could not make ~/moodle-passwords with mode 700"
        return 1
    fi
    printf '%s\n' "${dir}"
}

# write_private_file PATH: writes stdin to PATH with mode 600. Refuses anything already at PATH
# (a file, a link of any kind, a FIFO), and removes a file it made and could not finish.
write_private_file() {
    local path="$1"
    if [ -e "${path}" ] || [ -L "${path}" ]; then return 1; fi
    # noclobber makes the redirection fail instead of truncating, and its O_EXCL stops a link that
    # appeared since the check from being written through.
    (set -o noclobber; umask 077; : > "${path}") 2> /dev/null || return 1
    # chmod covers a default ACL on the folder, which umask does not.
    if ! chmod 600 -- "${path}" || ! cat >> "${path}"; then
        rm -f -- "${path}"
        return 1
    fi
    [ -f "${path}" ] && [ ! -L "${path}" ]
}

# delete_private_file PATH: shred -u when there is a shred that works, else rm -f. Fails if the file is still there.
delete_private_file() {
    if command -v shred > /dev/null 2>&1 && shred -u -- "$1" 2> /dev/null; then
        return 0
    fi
    rm -f -- "$1"
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

# remove_file ARG: --remove. ARG is a bare name (in the folder), ~/NAME, an absolute path, or a
# path relative to the home folder (moodle-passwords/NAME is what the Saved line prints).
# What gets deleted is what ARG resolves to, so a link cannot lead out of the folder.
remove_file() {
    local arg="$1" dir dir_real candidate resolved rel
    dir="$(password_dir)" || exit 1
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
        *) die 64 "will not remove that: it must be a .txt file inside ~/moodle-passwords/" ;;
    esac
    rel="${resolved#"${dir_real}"/}"
    [ -f "${resolved}" ] || die 64 "moodle-passwords/${rel} is not a file"
    delete_private_file "${resolved}" || die 1 "could not delete moodle-passwords/${rel}"
    printf 'Deleted moodle-passwords/%s.\n' "${rel}"
}

if [ "${remove}" -eq 1 ]; then
    [ "${#positional[@]}" -eq 1 ] || usage_error "--remove takes exactly one file"
    remove_file "${positional[0]}"
    exit 0
fi

[ "${#positional[@]}" -eq 1 ] || usage_error "give exactly one username"
username="${positional[0]}"
[ -n "${username}" ] || usage_error "the username is empty"
case "${username}" in *$'\n'* | *$'\r'*) usage_error "the username has a line break in it" ;; esac

[ -n "${MOODLE_HOST:-}" ] || die 1 "MOODLE_HOST is not set (compgen -e | grep -i moodle lists the names this agent has)"

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"

[ -n "${CLOUVE_OPS_PASSWORD:-}" ] \
    || die 1 "CLOUVE_OPS_PASSWORD is not set, so there is no clouve-ops shell to use (clv-secret --list shows the passwords this agent has). Nothing was changed."
{ command -v sshpass > /dev/null 2>&1 && command -v ssh > /dev/null 2>&1; } \
    || die 1 "sshpass or ssh is not installed (the moodle plugin's install.sh adds them). Nothing was changed."
{ [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die 1 "could not find the script's own folder. Nothing was changed."
program="${script_dir}/lib/set-temp-password.php"
[ -r "${program}" ] || die 1 "could not read lib/set-temp-password.php next to temp-password.sh. Nothing was changed."
# php -r takes the program without its <?php line.
code="$(sed '1{/^<?php[[:space:]]*$/d;}' "${program}")" || die 1 "could not read lib/set-temp-password.php. Nothing was changed."

# remote_php MODE ARG: the command the moodle container's bash runs, each part quoted with printf %q,
# which that bash decodes, so a username with spaces, quotes, $ or ; reaches php as one argument.
remote_php() {
    printf 'sudo -n -u www-data php -r %q -- %q %q' "${code}" "$1" "$2"
}

# result_line OUTPUT: the RESULT line the program printed, without "RESULT ", or nothing
result_line() { printf '%s\n' "$1" | grep -m 1 '^RESULT ' | sed 's/^RESULT //'; }

# --- The account ---------------------------------------------------------------------------------

# The two -o options take the host key the container shows and keep none. stdin is closed (-n).
output="$(SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "clouve-ops@${MOODLE_HOST}" "$(remote_php lookup "${username}")" 2>&1)"
rc=$?
result="$(result_line "${output}")"
case "${result}" in
    "found id="*)
        id="${result#found id=}"
        id="${id%% *}"
        [[ "${id}" =~ ^[0-9]+$ ]] || die 1 "Moodle's answer had no usable user id. Nothing was changed."
        ;;
    "unchanged no-account")
        die 2 "no Moodle account on this site has that username. Check it with the user (playbooks/rotate-admin-credentials.md, step 1). Nothing was changed."
        ;;
    "unchanged guest")
        die 2 "that is Moodle's guest account, which has no password to hand over. Nothing was changed."
        ;;
    "unchanged not-local auth="*)
        auth="${result#unchanged not-local auth=}"
        [[ "${auth}" =~ ^[a-z0-9_]+$ ]] || auth="another plugin"
        die 2 "that account signs in through ${auth}, so its password is set at that identity provider, not in Moodle. Nothing was changed."
        ;;
    *)
        if [ "${rc}" -eq 255 ] || [ "${rc}" -eq 5 ] || [ "${rc}" -eq 6 ] || [ "${rc}" -eq 7 ]; then
            msg "could not reach clouve-ops@${MOODLE_HOST} over SSH (exit ${rc}; reference/shell-access.md has the probe and the failure modes):"
        else
            msg "the account lookup didn't give an answer (exit ${rc}):"
        fi
        printf '%s\n' "${output}" | tail -n 20 >&2
        die 1 "Nothing was changed."
        ;;
esac

# --- The password and its file -------------------------------------------------------------------

# generate_password: 20 characters from A-Z a-z 2-9 without I, O, l, 0 and 1, and the symbols
# ! # % + - . = @, so it can be read aloud or retyped, with at least two of each of the four kinds.
# Moodle's default policy wants a symbol, and a site can ask for more of each kind.
generate_password() {
    local candidate="" upper lower digit symbol
    for _ in $(seq 1 50); do
        # head stops after 20 characters and tr then dies of SIGPIPE, so the status is ignored
        # and the length is what is checked.
        candidate="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9!#%+.=@-' < /dev/urandom | head -c 20)" || true
        [ "${#candidate}" -eq 20 ] || continue
        upper="${candidate//[^A-Z]/}"
        lower="${candidate//[^a-z]/}"
        digit="${candidate//[^0-9]/}"
        symbol="${candidate//[A-Za-z0-9]/}"
        if [ "${#upper}" -ge 2 ] && [ "${#lower}" -ge 2 ] && [ "${#digit}" -ge 2 ] && [ "${#symbol}" -ge 2 ]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

pw="$(LC_ALL=C generate_password)" || die 1 "could not draw a password from /dev/urandom. Nothing was changed."

# hide_password TEXT: prints TEXT with the password blanked out, in case a tool echoes it
hide_password() { printf '%s\n' "${1//"${pw}"/[password hidden]}"; }

# write_password_file: the file is written before anything changes in Moodle. Sets name and path.
write_password_file() {
    local dir stamp made_date made_time base n content sign_in=""
    dir="$(password_dir)" || die 3 "could not set up ~/moodle-passwords. Nothing was changed in Moodle."
    read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
    [ -n "${made_time}" ] || die 1 "date gave no time. Nothing was changed in Moodle."
    base="${id}-${stamp}"
    name="${base}.txt"
    n=1
    while [ -e "${dir}/${name}" ] || [ -L "${dir}/${name}" ]; do
        n=$((n + 1))
        [ "${n}" -le 999 ] || die 3 "moodle-passwords already holds 999 files named ${base}*. Nothing was changed in Moodle."
        name="${base}-${n}.txt"
    done
    path="${dir}/${name}"
    if [ -n "${MOODLE_URL:-}" ]; then sign_in="Sign in at: ${MOODLE_URL%/}/login/index.php"; fi
    printf -v content '%s\n' \
        "Moodle temporary password" \
        "" \
        "Username: ${username}" \
        ${sign_in:+"${sign_in}"} \
        "Made: ${made_date} ${made_time} UTC" \
        "" \
        "Temporary password:" \
        "${pw}" \
        "" \
        "Moodle asks for a new password at the first sign-in. Delete this file once it's handed over."
    printf '%s' "${content}" | write_private_file "${path}" \
        || die 3 "could not save moodle-passwords/${name}. Nothing was changed in Moodle."
}

# keep_file WHY: the change may have happened, so the file stays. Prints why and exits 2.
keep_file() {
    msg "$1"
    msg "The password file moodle-passwords/${name} was kept, since the password may be set. Have the admin try it in a private browser window, and remove the file with --remove once it's handed over or not needed."
    exit 2
}

# drop_file WHY: nothing changed in Moodle, so the file goes. Prints why and exits 2.
drop_file() {
    msg "$1"
    if delete_private_file "${path}"; then
        msg "Nothing was changed, and the password file was deleted."
    else
        msg "Nothing was changed, but the password file moodle-passwords/${name} could not be deleted: remove it with --remove."
    fi
    exit 2
}

write_password_file

# --- The change ----------------------------------------------------------------------------------

# printf is a shell builtin, so the password is in no process's arguments: it reaches php on stdin.
# The two -o options take the host key the container shows and keep none. No -n: php reads stdin.
output="$(printf '%s\n' "${pw}" | SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "clouve-ops@${MOODLE_HOST}" "$(remote_php set "${id}")" 2>&1)"
rc=$?
result="$(result_line "${output}")"
started=0
if printf '%s\n' "${output}" | grep -q '^STEP change '; then started=1; fi

case "${result}" in
    "changed id=${id} "*)
        notes=" ${result#changed id="${id}" } "
        if [[ "${notes}" == *" not-verified "* ]]; then
            keep_file "Moodle changed the account, but the new password doesn't check against the stored hash."
        fi
        line="Saved the temporary password for Moodle user id ${id} to moodle-passwords/${name} in the Files pane. Moodle took it (checked against the stored hash) and asks for a new password at the first sign-in."
        if [[ "${notes}" == *" suspended "* ]]; then
            line+=" The account is suspended, so it can't sign in until an admin unsuspends it (Site administration > Users > Browse list of users)."
        fi
        if [[ "${notes}" == *" locked "* ]]; then
            line+=" The account is locked after failed sign-ins: unlock it in Site administration > Users > Browse list of users."
        fi
        if [[ "${notes}" == *" auth-disabled "* ]]; then
            line+=" Its sign-in method is turned off in Site administration > Plugins > Authentication, so it can't sign in until that's on."
        fi
        printf '%s\n' "${line}"
        exit 0
        ;;
    "unchanged policy "*)
        drop_file "the site's password policy refused the password: $(hide_password "${result#unchanged policy }")"
        ;;
    "unchanged "*)
        drop_file "Moodle changed nothing: the account is no longer one whose password Moodle keeps."
        ;;
esac

if [ "${started}" -eq 1 ]; then
    msg "Moodle started the change and didn't finish it cleanly (exit ${rc}):"
    hide_password "${output}" | grep -v '^STEP ' | tail -n 20 >&2
    keep_file "The new password may be set."
fi
if [ "${rc}" -eq 255 ] || [ "${rc}" -eq 5 ] || [ "${rc}" -eq 6 ] || [ "${rc}" -eq 7 ]; then
    msg "could not reach clouve-ops@${MOODLE_HOST} over SSH (exit ${rc}):"
else
    msg "Moodle stopped before the change (exit ${rc}):"
fi
hide_password "${output}" | tail -n 20 >&2
drop_file "The password was not set."
