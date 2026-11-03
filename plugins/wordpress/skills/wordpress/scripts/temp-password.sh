#!/usr/bin/env bash
# WordPress DevOps Skill: temp-password.sh
#
# Gives a WordPress account a strong temporary password without ever showing it. The password
# is made here and saved to a private file in the agent user's home (the Files pane shows it)
# before WordPress changes. Then WordPress gets it on stdin, the account is read back, and the
# password is tried at wp-login.php. It is never printed, never on a command line and never
# left in your shell, so it stays out of the chat. The admin passes it on, and the person
# changes it after signing in.
#
# Usage: temp-password.sh [--via-db] [--] <login>
#        temp-password.sh --remove <file>
#
#   (no option)    [shell-only] wp-cli over the clouve-ops SSH channel:
#                  sudo -u www-data wp --path=/var/www/html user update <ID> --prompt=user_pass
#                  with the password on wp's stdin. wp-cli reads a prompted value with PHP's
#                  readline(), which echoes it to stdout, so wp's stdout goes to /dev/null in
#                  the WordPress container and the echo never comes back over SSH.
#   --via-db       [TCP-mysql] For a deployment without the shell (Shape B, or a failed
#                  probe): writes MD5(<password>) to user_pass, with the statement on mysql's
#                  stdin. WordPress takes an MD5 value at sign-in and re-hashes it then; the
#                  sign-in check below does that straight away.
#   --remove FILE  Delete a password file once it is handed over. FILE is a bare name,
#                  wordpress-passwords/NAME, or a path. It must resolve, links followed, to a
#                  .txt file inside ~/wordpress-passwords/. Anything else is exit 64 and
#                  nothing is touched. The file goes with shred -u when that works, else rm -f.
#   --             Ends the options, for a login that starts with a dash.
#
# The account is looked up by its login over TCP-mysql, with the login sent as a hex literal so
# that no character in it can change the SQL. Exactly one account has to match, and the change
# then goes by its ID. The account's stored hash is read before and after the change, as a
# SHA-256 digest that is compared and never shown, which tells a change that happened from one
# that didn't.
#
# The file is ~/wordpress-passwords/<safe login>-<UTC YYYYmmdd-HHMMSS>.txt, mode 600 in a folder
# of mode 700. The safe login is the login with every byte outside A-Za-z0-9._@- turned into _.
# A file made in the same second as another gets -2, then -3, so one never replaces another. It
# holds the login, the sign-in page (WORDPRESS_SITE_URL/wp-login.php, when that is set), the UTC
# time it was made, the password on a line of its own, and a reminder to have the password
# changed and the file deleted.
#
# Order: the file is written first, then WordPress is changed, so no password is ever set that
# nobody has saved. If the change fails and the stored hash is what it was, nothing changed: the
# file is deleted again and the exit code is 2. If the hash changed, or can't be read back, the
# file is kept, since it may hold the only copy of the account's password, and the exit code is
# 2 as well.
#
# The sign-in check posts the login and the password (on curl's stdin, URL-encoded by curl) to
# http://WORDPRESS_HOST/wp-login.php with WordPress's test cookie. WordPress's answer headers go
# to a file in the temporary folder, deleted straight after, and are never printed: they hold a
# live session. The check counts as accepted only when WordPress answers 302, sets its
# wordpress_logged_in_ cookie and redirects to wp-admin, or first to the admin email check it
# shows an administrator every six months. A 302 alone proves nothing: with FORCE_SSL_ADMIN on,
# or a plugin that hides wp-login.php, WordPress redirects before it checks the password. Any
# other answer reads "Couldn't confirm the sign-in", and the admin tries the password in a
# private browser window, since WordPress can also turn down a request made straight to its
# container for its host name or its cookie.
#
# Output: one line on stdout that names the file and says what the sign-in check found. The
# password and the full path are never printed. What wp-cli or mysql says on a failure goes to
# stderr with the password blanked out.
#
# Env vars read (names vary per deployment: discover them with
# `compgen -e | grep -iE 'wordpress|mysql|maria|host'`, the passwords' names with
# `clv-secret --list`):
#   WORDPRESS_DB_HOST       the database sibling, host or host:port (required)
#   WORDPRESS_DB_PASSWORD   the database password (required; never printed)
#   WORDPRESS_DB_USER       default wordpress
#   WORDPRESS_DB_NAME       default wordpress
#   WORDPRESS_TABLE_PREFIX  default wp_
#   WORDPRESS_HOST          the WordPress sibling (default wordpress)
#   WORDPRESS_SITE_URL      optional: the sign-in page written into the file
#   CLOUVE_OPS_PASSWORD     the clouve-ops password, for the shell (never printed)
#   HOME                    where ~/wordpress-passwords lives
#
# Exit codes:
#   0   done; the line on stdout says whether the sign-in check confirmed it
#   64  usage, or --remove of something that isn't a .txt file inside the folder
#   1   a setting or a tool is missing, or the account lookup failed
#   2   no single account has that login, or the change failed (stderr says whether the
#       password file was kept)
#   3   the password file could not be written; nothing was changed in WordPress

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: temp-password.sh [--via-db] [--] <login>
       temp-password.sh --remove <file>

Gives a WordPress account a strong temporary password and saves it to a private file in
~/wordpress-passwords (the Files pane shows it). The password is never printed.

  --via-db         write it over TCP-mysql as an MD5 value, for a deployment without the
                   clouve-ops shell; without it, wp-cli sets it over the shell
  --remove <file>  delete a password file once it is handed over: a file name or a path
                   inside ~/wordpress-passwords, ending in .txt
  --               end of options, for a login that starts with a dash

Prints one line naming the file. Exit codes: 0 done, 64 usage, 1 a missing setting or tool
or a failed lookup, 2 no single account or a failed change, 3 the file could not be written.
EOF
}

msg() { printf '[wordpress/temp-password] %s\n' "$*" >&2; }

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

via_db=0
remove=0
positional=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --via-db) via_db=1; shift ;;
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

# password_dir: makes ~/wordpress-passwords with mode 700 (an existing one is set to 700 too) and prints its path
password_dir() {
    local dir
    if [ -z "${HOME:-}" ] || [ ! -d "${HOME}" ]; then
        msg "HOME is not an existing folder, so ~/wordpress-passwords has no place to go"
        return 1
    fi
    dir="${HOME}/wordpress-passwords"
    if [ -e "${dir}" ] && [ ! -d "${dir}" ]; then
        msg "the path ~/wordpress-passwords is taken by something that is not a folder"
        return 1
    fi
    if ! (umask 077 && mkdir -p -- "${dir}") || ! chmod 700 -- "${dir}"; then
        msg "could not make ~/wordpress-passwords with mode 700"
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
# path relative to the home folder (wordpress-passwords/NAME is what the Saved line prints).
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
        *) die 64 "will not remove '${arg}': it must be a .txt file inside ~/wordpress-passwords/" ;;
    esac
    rel="${resolved#"${dir_real}"/}"
    [ -f "${resolved}" ] || die 64 "wordpress-passwords/${rel} is not a file"
    delete_private_file "${resolved}" || die 1 "could not delete wordpress-passwords/${rel}"
    printf 'Deleted wordpress-passwords/%s.\n' "${rel}"
}

if [ "${remove}" -eq 1 ]; then
    [ "${via_db}" -eq 0 ] || usage_error "--remove takes only the file to delete"
    [ "${#positional[@]}" -eq 1 ] || usage_error "--remove takes exactly one file"
    remove_file "${positional[0]}"
    exit 0
fi

[ "${#positional[@]}" -eq 1 ] || usage_error "give exactly one login"
login="${positional[0]}"
[ -n "${login}" ] || usage_error "the login is empty"

: "${WORDPRESS_DB_PASSWORD:=$(clv-secret WORDPRESS_DB_PASSWORD)}"

names_hint="discover the names with: compgen -e | grep -iE 'wordpress|mysql|maria|host' (passwords: clv-secret --list)"
[ -n "${WORDPRESS_DB_HOST:-}" ] || die 1 "WORDPRESS_DB_HOST is not set: ${names_hint}"
[ -n "${WORDPRESS_DB_PASSWORD:-}" ] || die 1 "WORDPRESS_DB_PASSWORD is not set: ${names_hint}"
: "${WORDPRESS_DB_USER:=wordpress}"
: "${WORDPRESS_DB_NAME:=wordpress}"
: "${WORDPRESS_TABLE_PREFIX:=wp_}"
: "${WORDPRESS_HOST:=wordpress}"
P="${WORDPRESS_TABLE_PREFIX}"
[[ "${P}" =~ ^[A-Za-z0-9_]+$ ]] || die 1 "WORDPRESS_TABLE_PREFIX has characters other than letters, digits and _, so it doesn't go into SQL"
{ [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder"
command -v mysql > /dev/null 2>&1 || die 1 "the mysql client is not installed (the wordpress plugin's install.sh adds it)"

# WordPress allows WORDPRESS_DB_HOST in the form host:port.
DB_HOST="${WORDPRESS_DB_HOST%%:*}"
DB_PORT=3306
if [[ "${WORDPRESS_DB_HOST}" == *:* ]]; then DB_PORT="${WORDPRESS_DB_HOST##*:}"; fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/wp-temp-password.XXXXXX")" || die 1 "could not make a temporary folder"
trap 'rm -rf "${tmp}"' EXIT
errfile="${tmp}/mysql-errors"

# mysql_query SQL: runs one statement and prints its rows, tab-separated, with no header
mysql_query() {
    MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${DB_HOST}" -P "${DB_PORT}" \
        -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -sN --connect-timeout=10 -e "$1" 2> "${errfile}"
}

# --- The account ------------------------------------------------------------------------------

# The login goes into the SQL as a hex literal, so a quote or a backslash in it can't end the string.
login_hex="$(printf '%s' "${login}" | od -An -tx1 -v | tr -d ' \n')"
ids="$(mysql_query "SELECT ID FROM \`${P}users\` WHERE user_login = CONVERT(X'${login_hex}' USING utf8mb4);")" \
    || die 1 "could not look up the login \"${login}\" (mysql said: $(cat "${errfile}")). Nothing was changed."
mapfile -t id_list < <(printf '%s\n' "${ids}" | grep -E '^[0-9]+$')
case "${#id_list[@]}" in
    0) die 2 "no account has the login \"${login}\". Check it with the user (playbooks/rotate-admin-credentials.md, step 1). Nothing was changed." ;;
    1) id="${id_list[0]}" ;;
    *) die 2 "${#id_list[@]} accounts have the login \"${login}\" (IDs ${id_list[*]}), so it doesn't pick one. Nothing was changed." ;;
esac

# stored_hash_digest: a SHA-256 digest of the account's stored hash, for comparing only
stored_hash_digest() { mysql_query "SELECT SHA2(user_pass, 256) FROM \`${P}users\` WHERE ID = ${id};"; }
before="$(stored_hash_digest)" && [ -n "${before}" ] \
    || die 1 "could not read the account with ID ${id} (mysql said: $(cat "${errfile}")). Nothing was changed."

# --- The password and its file ------------------------------------------------------------------

# generate_password: 20 characters from A-Z a-z 2-9 without I, O, l, 0 and 1, so it can be read
# aloud or retyped, with at least one upper-case letter, one lower-case letter and one digit. It
# has no quote, so it is safe inside the SQL string literal --via-db writes.
generate_password() {
    local alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789' candidate=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        # head stops after 20 characters and tr then dies of SIGPIPE, so the status is ignored
        # and the length is what is checked.
        candidate="$(LC_ALL=C tr -dc "${alphabet}" < /dev/urandom | head -c 20)" || true
        [ "${#candidate}" -eq 20 ] || continue
        case "${candidate}" in *[[:upper:]]*) ;; *) continue ;; esac
        case "${candidate}" in *[[:lower:]]*) ;; *) continue ;; esac
        case "${candidate}" in *[[:digit:]]*) ;; *) continue ;; esac
        printf '%s' "${candidate}"
        return 0
    done
    return 1
}

pw="$(generate_password)" || die 1 "could not draw a password from /dev/urandom. Nothing was changed."

# hide_password TEXT: prints TEXT with the password blanked out, in case a tool echoes it
hide_password() { printf '%s\n' "${1//"${pw}"/[password hidden]}"; }

# write_password_file: the file is written before anything changes in WordPress. Sets name and path.
write_password_file() {
    local dir safe_login stamp made_date made_time base n content sign_in=""
    dir="$(password_dir)" || die 3 "could not set up ~/wordpress-passwords. Nothing was changed in WordPress."
    safe_login="$(LC_ALL=C; printf '%s' "${login//[^A-Za-z0-9._@-]/_}")"
    read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
    [ -n "${made_time}" ] || die 1 "date gave no time. Nothing was changed in WordPress."
    base="${safe_login}-${stamp}"
    name="${base}.txt"
    n=1
    while [ -e "${dir}/${name}" ] || [ -L "${dir}/${name}" ]; do
        n=$((n + 1))
        [ "${n}" -le 999 ] || die 3 "wordpress-passwords already holds 999 files named ${base}*. Nothing was changed in WordPress."
        name="${base}-${n}.txt"
    done
    path="${dir}/${name}"
    if [ -n "${WORDPRESS_SITE_URL:-}" ]; then sign_in="Sign in at: ${WORDPRESS_SITE_URL%/}/wp-login.php"; fi
    printf -v content '%s\n' \
        "WordPress temporary password" \
        "" \
        "Login: ${login}" \
        ${sign_in:+"${sign_in}"} \
        "Made: ${made_date} ${made_time} UTC" \
        "" \
        "Temporary password:" \
        "${pw}" \
        "" \
        "Ask them to change it after signing in (Users > Profile). Delete this file once it's handed over."
    printf '%s' "${content}" | write_private_file "${path}" \
        || die 3 "could not save wordpress-passwords/${name}. Nothing was changed in WordPress."
}

# signed_in HEADERS: WordPress's answer to the sign-in check is what it gives a signed-in account:
# its logged-in cookie, and a redirect to wp-admin or to the admin email check. Reads the headers
# without printing any of them, since the cookie is a live session.
signed_in() {
    local location
    [ -f "$1" ] || return 1
    tr -d '\r' < "$1" | grep -qiE '^set-cookie:[[:space:]]*wordpress_logged_in_[^=;[:space:]]*=[^;[:space:]]' \
        || return 1
    location="$(tr -d '\r' < "$1" | grep -iE '^location:' | tail -n 1 | sed -E 's/^[^:]*:[[:space:]]*//')"
    case "${location%%[?#]*}" in
        */wp-admin | */wp-admin/*) return 0 ;;
        */wp-login.php)
            case "${location}" in *[?\&]action=confirm_admin_email*) return 0 ;; esac
            ;;
    esac
    return 1
}

# finish TOOL RC OUTPUT: reads the account back after the change, then checks the sign-in and
# prints the one line, or says what happened and exits 2.
finish() {
    local tool="$1" rc="$2" output="$3" after code result
    if ! after="$(stored_hash_digest)" || [ -z "${after}" ]; then
        msg "could not read the account back after the change (mysql said: $(hide_password "$(cat "${errfile}")"))."
        if [ "${rc}" -ne 0 ]; then
            msg "${tool} also reported an error (exit ${rc}):"
            hide_password "${output}" >&2
        fi
        msg "The password file wordpress-passwords/${name} was kept, since the password may be set. Have the admin try it in a private browser window, and remove the file with --remove once it's handed over or not needed."
        exit 2
    fi
    if [ "${after}" = "${before}" ]; then
        if [ "${rc}" -ne 0 ]; then
            msg "${tool} could not change the password of \"${login}\" (exit ${rc}):"
            hide_password "${output}" >&2
        else
            msg "${tool} reported success, but the account's stored password did not change."
        fi
        if delete_private_file "${path}"; then
            msg "Nothing was changed, and the password file was deleted."
        else
            msg "Nothing was changed, but the password file wordpress-passwords/${name} could not be deleted: remove it with --remove."
        fi
        if [ "${via_db}" -eq 0 ]; then
            msg "Without the clouve-ops shell or wp-cli, run this again with --via-db (reference/shell-access.md says when the shell is there)."
        fi
        exit 2
    fi
    if [ "${rc}" -ne 0 ]; then
        msg "the account has the new password, but ${tool} reported an error (exit ${rc}):"
        hide_password "${output}" >&2
        msg "The password file wordpress-passwords/${name} was kept: it holds the account's password now."
        exit 2
    fi

    if ! command -v curl > /dev/null 2>&1; then
        result="Couldn't confirm the sign-in: curl isn't installed here. Have the admin try the password in a private browser window"
    else
        headers="${tmp}/sign-in-headers"
        code="$(printf '%s' "${pw}" | curl -s -o /dev/null -D "${headers}" -w '%{http_code}' --max-time 15 \
            -b 'wordpress_test_cookie=WP Cookie check' \
            --data-urlencode "log=${login}" \
            --data-urlencode 'pwd@-' \
            --data-urlencode 'wp-submit=Log In' \
            --data-urlencode 'testcookie=1' \
            "http://${WORDPRESS_HOST}/wp-login.php" 2> /dev/null)" || true
        if [ "${code}" = 302 ] && signed_in "${headers}"; then
            result="WordPress accepted it at sign-in"
        elif [ "${code}" = 302 ]; then
            result="Couldn't confirm the sign-in: WordPress answered with a redirect, but not with a signed-in session in wp-admin. With FORCE_SSL_ADMIN on, or a plugin that hides wp-login.php, WordPress redirects before it checks the password. Have the admin try the password in a private browser window"
        elif [ -z "${code}" ] || [ "${code}" = 000 ]; then
            result="Couldn't confirm the sign-in: there was no answer from WordPress at http://${WORDPRESS_HOST}/wp-login.php. Have the admin try the password in a private browser window"
        else
            result="Couldn't confirm the sign-in: the check got HTTP ${code}, which doesn't settle it, since WordPress can turn down a request made straight to its container. Have the admin try the password in a private browser window"
        fi
        rm -f -- "${headers}"
    fi
    printf 'Saved the temporary password for %s to wordpress-passwords/%s in the Files pane. %s.\n' \
        "${login}" "${name}" "${result}"
    exit 0
}

# --- --via-db: an MD5 value over TCP-mysql ----------------------------------------------------------

if [ "${via_db}" -eq 1 ]; then
    write_password_file
    # printf is a shell builtin, so the password is in no process's arguments: the statement reaches
    # mysql on its stdin.
    output="$(printf "UPDATE \`%susers\` SET user_pass = MD5('%s') WHERE ID = %s;\n" "${P}" "${pw}" "${id}" \
        | MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${DB_HOST}" -P "${DB_PORT}" \
            -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" --connect-timeout=10 2>&1)"
    rc=$?
    finish mysql "${rc}" "${output}"
fi

# --- wp-cli over the clouve-ops shell -------------------------------------------------------------

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"

[ -n "${CLOUVE_OPS_PASSWORD:-}" ] \
    || die 1 "CLOUVE_OPS_PASSWORD is not set, so there is no clouve-ops shell to use. On a deployment without it, run this again with --via-db. Nothing was changed."
{ command -v sshpass > /dev/null 2>&1 && command -v ssh > /dev/null 2>&1; } \
    || die 1 "sshpass or ssh is not installed (the wordpress plugin's install.sh adds them). Nothing was changed."

write_password_file
# wp-cli echoes the value it reads for --prompt to stdout, so wp's stdout goes to /dev/null in the
# WordPress container. The two -o options take the host key the container shows and keep none.
output="$(printf '%s\n' "${pw}" | SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh \
    -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    "clouve-ops@${WORDPRESS_HOST}" \
    "sudo -u www-data wp --path=/var/www/html user update ${id} --prompt=user_pass > /dev/null" 2>&1)"
rc=$?
finish wp-cli "${rc}" "${output}"
