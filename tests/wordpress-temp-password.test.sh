#!/usr/bin/env bash
# The wordpress skill's temporary password never reaches the chat or a command line (release
# 4.5.3, review finding C1 with I2).
#
# Before: playbooks/rotate-admin-credentials.md piped $NEWPASS into
# `wp user update '<login>' --prompt=user_pass` over SSH. wp-cli reads a prompted value with PHP's
# readline(), and readline echoes what it reads to stdout when stdin is a pipe, so the new password
# came back as the command's output: into the tool result, the chat and the model's context. The
# password also lived only in a shell variable, which doesn't survive between the assistant's Bash
# calls, so the check and the handover that followed had nothing to work with.
#
# Now scripts/temp-password.sh does the change in one run. It makes the password, saves it to a
# mode 600 file in ~/wordpress-passwords (a folder of mode 700) before anything changes, hands it
# to wp-cli on stdin with wp's output thrown away on the WordPress side (with --via-db, to mysql on
# stdin as an MD5 value), reads the account back, tries the password at wp-login.php with the
# password on curl's stdin, and prints only the file's name.
#
# The test runs the real script against stand-ins for sshpass, ssh, sudo, wp, mysql, curl and
# clv-secret that record their arguments, their environment and what they read. The stand-in wp
# prints the prompted value to stdout, as wp-cli does with readline. Fails when the password shows
# up in the script's stdout or stderr, in what comes back from the WordPress container over SSH,
# in any stand-in's arguments or environment, or anywhere but the file, wp's stdin, mysql's stdin
# (--via-db) and curl's stdin; when the file or its folder can be read by others; when a
# change that failed leaves a file for a password that was never set, or deletes the file of one
# that was set; when the account is picked by anything but its own ID; or when --remove deletes
# anything outside ~/wordpress-passwords.
#
# The sign-in check (4.5.3 re-review N1): WordPress answers wp-login.php with a 302 before it
# looks at the password when FORCE_SSL_ADMIN is on and the request came over plain HTTP, as the
# check's does, and a plugin that hides wp-login.php redirects it too. So a 302 alone counted any
# password as accepted. The stand-in curl answers like WordPress in each case. Fails unless the
# line says WordPress accepted the password only when the answer sets the logged-in cookie and
# redirects to wp-admin (or to the admin email check WordPress shows an administrator first every
# six months), and says it couldn't confirm the sign-in otherwise; and fails when the answer's
# session cookie reaches the output or is left in a file.
#
# No network and no Docker: the script runs under `env -i` with the stand-ins first on PATH, and
# everything is written under mktemp -d.
#
# Run: bash tests/wordpress-temp-password.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/plugins/wordpress/skills/wordpress/scripts/temp-password.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/wp-temp-password.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; return 1; fi; }

if [ ! -f "$SCRIPT" ]; then
  fail "plugins/wordpress/skills/wordpress/scripts/temp-password.sh exists"
  echo
  exit 1
fi

# --- Stand-ins ---------------------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"

# Every stand-in appends its whole command line to $FAKE_STATE/argv and its environment to
# $FAKE_STATE/env.
cat > "$bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf 'sshpass %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
[ "${1:-}" = "-e" ] || { echo "fake sshpass: wants -e" >&2; exit 2; }
[ -n "${SSHPASS:-}" ] || { echo "fake sshpass: SSHPASS is empty" >&2; exit 5; }
printf '%s' "$SSHPASS" > "$FAKE_STATE/sshpass-env"
shift
exec "$@"
EOF

# ssh runs the remote command with a local bash, so a redirection in it works as it would there,
# and keeps a copy of what comes back over the channel in $FAKE_STATE/ssh-stdout.
cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o | -p | -i | -F | -l | -J) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
target="${1:-}"
shift
printf '%s\n' "$target" >> "$FAKE_STATE/ssh-targets"
if [ "${FAKE_SSH:-ok}" = refused ]; then
  echo "ssh: connect to host ${target#*@} port 22: Connection refused" >&2
  exit 255
fi
bash -c "$*" | tee -a "$FAKE_STATE/ssh-stdout"
exit "${PIPESTATUS[0]}"
EOF

cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
if [ "${1:-}" = "-u" ]; then shift 2; fi
exec "$@"
EOF

# wp-cli with PHP's readline: the prompt and the value it reads both go to stdout.
cat > "$bin/wp" <<'EOF'
#!/usr/bin/env bash
printf 'wp %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
IFS= read -r value || true
printf '%s' "$value" > "$FAKE_STATE/wp-stdin"
printf '1/1 --user_pass=<password>: %s\n' "$value"
case "${FAKE_WP:-ok}" in
  ok)
    echo "hash-set-by-wp" > "$FAKE_STATE/user_pass"
    echo "Success: Updated user 5."
    ;;
  fails)
    printf 'Error: could not save the password %s\n' "$value" >&2
    exit 1
    ;;
  fails-after-change)
    echo "hash-set-by-wp" > "$FAKE_STATE/user_pass"
    printf 'Warning: could not send the notice about %s\n' "$value" >&2
    exit 1
    ;;
esac
EOF

# mysql answers the account lookup from $FAKE_STATE/accounts ("<hex of the login><TAB><ID>"), and the
# read-back with a digest of $FAKE_STATE/user_pass, which the stand-in wp and an MD5 UPDATE change.
cat > "$bin/mysql" <<'EOF'
#!/usr/bin/env bash
printf 'mysql %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
[ -n "${MYSQL_PWD:-}" ] || { echo "ERROR 1045 (28000): Access denied for user (using password: NO)" >&2; exit 1; }
printf '%s' "$MYSQL_PWD" > "$FAKE_STATE/mysql-env"
sql=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e) sql="${2:-}"; shift 2 ;;
    --execute=*) sql="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
if [ -z "$sql" ]; then
  input="$(cat)"
  printf '%s\n' "$input" >> "$FAKE_STATE/mysql-stdin"
  if [ "${FAKE_MYSQL:-ok}" = update-denied ]; then
    echo "ERROR 1142 (42000): UPDATE command denied to user 'wordpress'" >&2
    exit 1
  fi
  case "$input" in *UPDATE*MD5\(*) echo "hash-set-by-md5" > "$FAKE_STATE/user_pass" ;; esac
  exit 0
fi
printf '%s\n' "$sql" >> "$FAKE_STATE/mysql-sql"
case "$sql" in
  *SHA2\(*)
    # With FAKE_MYSQL=readback-fails, every read of the hash after the first one fails.
    reads=$(( $(cat "$FAKE_STATE/hash-reads" 2> /dev/null || echo 0) + 1 ))
    echo "$reads" > "$FAKE_STATE/hash-reads"
    if [ "${FAKE_MYSQL:-ok}" = readback-fails ] && [ "$reads" -ge 2 ]; then
      echo "ERROR 2013 (HY000): Lost connection to MySQL server during query" >&2
      exit 1
    fi
    sha256sum < "$FAKE_STATE/user_pass" | cut -d' ' -f1
    ;;
  *"SELECT ID"*)
    hex="$(printf '%s' "$sql" | grep -oE "X'[0-9A-Fa-f]*'" | head -n1 | tr -d "X'" | tr 'A-F' 'a-f')"
    awk -F'\t' -v h="$hex" '$1 == h { print $2 }' "$FAKE_STATE/accounts"
    ;;
  *) echo "fake mysql: unexpected SQL: $sql" >&2; exit 1 ;;
esac
EOF

# curl answers the sign-in check the way WordPress does. It writes the response headers to the
# file -D names and prints the status code. FAKE_SIGN_IN picks the answer:
#   wp-admin     (default) the password works: 302 to wp-admin, with the logged-in cookie
#   admin-email  the password works, and WordPress first sends an administrator to confirm the
#                site's admin email, as it does every six months: 302 to
#                wp-login.php?action=confirm_admin_email, with the logged-in cookie
#   force-ssl    FORCE_SSL_ADMIN is on and the check came over plain HTTP: WordPress redirects
#                before it looks at the password, to wp-admin (wp_safe_redirect's fallback for
#                the container's host name), and sets no cookie
#   hide-login   a plugin hides wp-login.php: 302 to its 404 page, no cookie
#   elsewhere    the logged-in cookie, but a redirect to the front page
#   form         the login form came back: 200
#   down         nothing answers: curl prints 000 and exits 7
# The cookies carry a session token, fake-session-token-5d2c, that must never leave the header file.
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
headers=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D | --dump-header) headers="${2:-}"; shift 2 ;;
    --data-urlencode)
      [ "${2:-}" = "pwd@-" ] && cat > "$FAKE_STATE/curl-stdin"
      shift 2
      ;;
    *) shift ;;
  esac
done
site="https://blog.example.test"
session="admin%7C1762300000%7Cfake-session-token-5d2c%7Cfakehmac"
test_cookie="Set-Cookie: wordpress_test_cookie=WP%20Cookie%20check; path=/"
auth="Set-Cookie: wordpress_0123abcd=$session; path=/wp-admin; HttpOnly"
logged_in="Set-Cookie: wordpress_logged_in_0123abcd=$session; path=/; HttpOnly"
case "${FAKE_SIGN_IN:-wp-admin}" in
  wp-admin) code=302 lines=("$test_cookie" "$auth" "$logged_in" "Location: $site/wp-admin/") ;;
  admin-email)
    code=302
    lines=("$test_cookie" "$auth" "$logged_in"
      "Location: $site/wp-login.php?redirect_to=https%3A%2F%2Fblog.example.test%2Fwp-admin%2F&action=confirm_admin_email&wp_lang=en_US")
    ;;
  force-ssl) code=302 lines=("Location: $site/wp-admin/") ;;
  hide-login) code=302 lines=("Location: $site/404/") ;;
  elsewhere) code=302 lines=("$test_cookie" "$auth" "$logged_in" "Location: $site/") ;;
  form) code=200 lines=("$test_cookie" "Content-Type: text/html; charset=UTF-8") ;;
  down) printf '000'; exit 7 ;;
esac
if [ -n "$headers" ]; then
  { printf 'HTTP/1.1 %s\r\n' "$code"; printf '%s\r\n' "${lines[@]}"; printf '\r\n'; } > "$headers"
fi
printf '%s' "$code"
EOF

cat > "$bin/clv-secret" <<'EOF'
#!/usr/bin/env bash
printf 'clv-secret %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
case "${1:-}" in
  WORDPRESS_DB_PASSWORD) printf '%s' 'db-secret-from-clv' ;;
  CLOUVE_OPS_PASSWORD) printf '%s' 'ops-secret-from-clv' ;;
  *) echo "clv-secret: ${1:-} is not set on this server" >&2; exit 2 ;;
esac
EOF
chmod +x "$bin"/*

# --- Running the script --------------------------------------------------------------------

# run CASE [VAR=VALUE...] -- ARGS...: runs the script for CASE with its own home and state.
# Leaves $state, $home, $out, $err and $rc.
run() {
  local name="$1" vars=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  state="$work/$name/state"
  home="$work/$name/home"
  out="$work/$name/out"
  err="$work/$name/err"
  mkdir -p "$state" "$home"
  : > "$state/argv"
  rm -f "$state/hash-reads"
  echo "hash-before" > "$state/user_pass"
  # The accounts the lookup finds, unless the case wrote its own: admin is 61 64 6d 69 6e (ID 5),
  # o'brien is 6f 27 62 72 69 65 6e (ID 7).
  [ -f "$state/accounts" ] || printf '61646d696e\t5\n6f27627269656e\t7\n' > "$state/accounts"
  env -i HOME="$home" PATH="$bin:/usr/bin:/bin" TMPDIR="$work" LANG=C.UTF-8 FAKE_STATE="$state" \
    WORDPRESS_DB_HOST=wp-db WORDPRESS_DB_USER=wpuser WORDPRESS_DB_NAME=wpdb \
    WORDPRESS_HOST=wp-host WORDPRESS_SITE_URL=https://blog.example.test \
    WORDPRESS_DB_PASSWORD=db-secret CLOUVE_OPS_PASSWORD=ops-secret \
    ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" > "$out" 2> "$err"
  rc=$?
}

# password_files: the .txt files in this case's ~/wordpress-passwords, one per line
password_files() { find "$home/wordpress-passwords" -maxdepth 1 -type f -name '*.txt' 2> /dev/null | sort; }

# password_in FILE: the line after "Temporary password:" in FILE
password_in() { awk 'f { print; exit } /^Temporary password:$/ { f = 1 }' "$1"; }

# leaks PW: every place PW shows up outside the file and the stdin captures. ssh-stdout is what
# came back from the WordPress container over SSH, where wp printed what it read; env holds the
# stand-ins' environments, so an exported password shows up there.
leaks() {
  grep -lF -- "$1" "$out" "$err" "$state/argv" "$state/env" "$state/mysql-sql" "$state/ssh-targets" \
    "$state/ssh-stdout" 2> /dev/null | sed "s#^$work/##"
}

# session_left: files under $work, the stand-ins aside, that hold the session token the stand-in
# curl put in WordPress's answer: the output, a home folder or a temporary folder left behind.
session_left() { grep -rlF -- "fake-session-token-5d2c" "$work" 2> /dev/null | grep -vF "$bin/" | sed "s#^$work/##"; }

show() { sed 's/^/       /' "$@" | cut -c1-200; }

echo "wp-cli over the clouve-ops shell"
run shell -- admin
check "exits 0" '[ "$rc" -eq 0 ]' || show "$err"
mapfile -t files < <(password_files)
check "saves one password file" '[ "${#files[@]}" -eq 1 ]'
file="${files[0]:-/nonexistent}"
pw="$(password_in "$file" 2> /dev/null || true)"
check "the file holds a 20-character password" '[[ "$pw" =~ ^[A-Za-z0-9]{20}$ ]]'
check "the file is mode 600" '[ "$(stat -c %a "$file" 2> /dev/null)" = 600 ]'
check "its folder is mode 700" '[ "$(stat -c %a "$home/wordpress-passwords" 2> /dev/null)" = 700 ]'
check "the file names the login and the sign-in page" \
  'grep -qx "Login: admin" "$file" && grep -qF "https://blog.example.test/wp-login.php" "$file"'
check "stdout is one line naming the file, not the password" \
  '[ "$(wc -l < "$out")" -eq 1 ] && grep -qF "wordpress-passwords/$(basename "$file")" "$out"'
if [ -n "$pw" ]; then
  where="$(leaks "$pw")"
  check "the password is in no output and no command line (wp prints what it reads)" '[ -z "$where" ]' \
    || printf '       found in: %s\n' $where
fi
check "wp got the password on its stdin" '[ -n "$pw" ] && [ "$(cat "$state/wp-stdin" 2> /dev/null)" = "$pw" ]'
check "wp changed the account by its ID, as www-data" \
  'grep -qx "sudo -u www-data wp --path=/var/www/html user update 5 --prompt=user_pass" "$state/argv"'
check "ssh keeps and checks no saved host key" \
  'grep -E "^ssh " "$state/argv" | grep -F -- "-o StrictHostKeyChecking=accept-new" | grep -qF -- "-o UserKnownHostsFile=/dev/null"'
check "ssh went to clouve-ops on the WordPress host" 'grep -qx "clouve-ops@wp-host" "$state/ssh-targets"'
check "the sign-in check got the password on curl's stdin" \
  '[ -n "$pw" ] && [ "$(cat "$state/curl-stdin" 2> /dev/null)" = "$pw" ]'
check "the sign-in check posts to the WordPress host's wp-login.php" \
  'grep -E "^curl " "$state/argv" | grep -qF "http://wp-host/wp-login.php"'
check "stdout says WordPress took the password at sign-in" 'grep -qi "accepted" "$out"'
check "the deployment's own passwords stay off every command line" \
  '! grep -qF -e db-secret -e ops-secret "$state/argv"'
check "sshpass and mysql got the deployment's passwords in their environment" \
  '[ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret ] && [ "$(cat "$state/mysql-env" 2> /dev/null)" = db-secret ]'

echo
echo "--via-db, for a deployment without the shell"
run db -- --via-db admin
check "exits 0" '[ "$rc" -eq 0 ]' || show "$err"
mapfile -t files < <(password_files)
file="${files[0]:-/nonexistent}"
pw="$(password_in "$file" 2> /dev/null || true)"
check "saves one password file, mode 600" '[ "${#files[@]}" -eq 1 ] && [ "$(stat -c %a "$file")" = 600 ]'
if [ -n "$pw" ]; then
  where="$(leaks "$pw")"
  check "the password is in no output and no command line" '[ -z "$where" ]' || printf '       found in: %s\n' $where
fi
check "mysql got the MD5 write on its stdin, for ID 5 only" \
  'grep -qF "MD5('"'"'$pw'"'"')" "$state/mysql-stdin" && grep -qE "WHERE ID = 5;" "$state/mysql-stdin"'
check "no ssh was run" '! grep -qE "^(ssh|sshpass) " "$state/argv"'
check "the sign-in check got the password on curl's stdin" \
  '[ -n "$pw" ] && [ "$(cat "$state/curl-stdin" 2> /dev/null)" = "$pw" ]'

echo
echo "On an agent that keeps the passwords out of the environment"
run clv WORDPRESS_DB_PASSWORD= CLOUVE_OPS_PASSWORD= -- admin
check "exits 0, with the passwords from clv-secret" \
  '[ "$rc" -eq 0 ] && [ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret-from-clv ] && [ "$(cat "$state/mysql-env" 2> /dev/null)" = db-secret-from-clv ]' \
  || show "$err"

echo
echo "A login with a quote in it"
run quote -- "o'brien"
check "exits 0 and changes ID 7 (the login goes into the SQL as hex)" \
  '[ "$rc" -eq 0 ] && grep -qx "sudo -u www-data wp --path=/var/www/html user update 7 --prompt=user_pass" "$state/argv"' \
  || show "$err"

echo
echo "Refusals that change nothing"
run unknown -- nobody
check "an unknown login: exit 2, no file, no ssh" \
  '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ] && ! grep -qE "^(ssh|sshpass) " "$state/argv"'
mkdir -p "$work/twice/state"
printf '61646d696e\t5\n61646d696e\t9\n' > "$work/twice/state/accounts"
run twice -- admin
check "a login that finds two accounts: exit 2, no file, no ssh" \
  '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ] && ! grep -qE "^(ssh|sshpass) " "$state/argv"'
run noarg --
check "no login: exit 64" '[ "$rc" -eq 64 ]'
run badprefix WORDPRESS_TABLE_PREFIX='wp_;DROP' -- admin
check "a table prefix that isn't letters, digits and _: exit 1, nothing run" \
  '[ "$rc" -eq 1 ] && ! grep -qE "^(mysql|ssh|sshpass) " "$state/argv"'

echo
echo "A change that fails"
run wpfails FAKE_WP=fails -- admin
mapfile -t files < <(password_files)
pw="$(cat "$state/wp-stdin" 2> /dev/null || true)"
check "wp refused and nothing changed: exit 2, and the file is gone" '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 0 ]'
check "what wp printed is shown with the password blanked out" \
  '[ -n "$pw" ] && ! grep -qF -- "$pw" "$err" && grep -qF "[password hidden]" "$err"'
run wpafter FAKE_WP=fails-after-change -- admin
mapfile -t files < <(password_files)
check "wp failed after the password changed: exit 2, the file is kept and stderr says so" \
  '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 1 ] && grep -qi "kept" "$err"'
pw="$(password_in "${files[0]:-/nonexistent}" 2> /dev/null || true)"
check "and the password is still in no output" '[ -n "$pw" ] && [ -z "$(leaks "$pw")" ]'
run readback FAKE_MYSQL=readback-fails -- admin
mapfile -t files < <(password_files)
check "the account can't be read back after the change: exit 2, the file is kept and stderr says so" \
  '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 1 ] && grep -qi "kept" "$err"'
run sshdown FAKE_SSH=refused -- admin
mapfile -t files < <(password_files)
check "ssh can't connect: exit 2, no file left, and it suggests --via-db" \
  '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 0 ] && grep -qF -- "--via-db" "$err"'
run denied FAKE_MYSQL=update-denied -- --via-db admin
mapfile -t files < <(password_files)
check "--via-db and the UPDATE is refused: exit 2, no file left" '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 0 ]'

echo
echo "The sign-in check"
check "WordPress's answer holds a live session, and it is in no output and no file left behind" \
  '[ -z "$(session_left)" ]' || printf '       found in: %s\n' $(session_left)
run adminemail FAKE_SIGN_IN=admin-email -- admin
check "signed in and sent to the admin email check WordPress shows an administrator first: accepted" \
  '[ "$rc" -eq 0 ] && grep -qi "accepted" "$out"' || show "$out" "$err"

# not_confirmed CASE LABEL: runs the script with FAKE_SIGN_IN=CASE and checks that the line says it
# couldn't confirm the sign-in, sends the admin to a private browser window, and keeps the file of
# a password that was set, with the password still in no output.
not_confirmed() {
  run "signin-$1" FAKE_SIGN_IN="$1" -- admin
  pw="$(password_in "$(password_files | head -n 1)" 2> /dev/null || true)"
  check "$2: exit 0, the line says it couldn't confirm the sign-in and to try a private browser window" \
    '[ "$rc" -eq 0 ] && ! grep -qi "accepted" "$out" && grep -qi "couldn.t confirm the sign-in" "$out" && grep -qi "private browser window" "$out"' \
    || show "$out" "$err"
  check "  and the file is kept, with the password in no output" \
    '[ -n "$pw" ] && [ -z "$(leaks "$pw")" ]'
}
not_confirmed force-ssl "FORCE_SSL_ADMIN redirects to wp-admin before checking the password, with no cookie"
check "  and the line names what redirects before the password is checked (FORCE_SSL_ADMIN, a plugin that hides wp-login.php)" \
  'grep -qF "FORCE_SSL_ADMIN" "$out" && grep -qi "hides wp-login.php" "$out"'
not_confirmed hide-login "a plugin that hides wp-login.php redirects to its 404 page"
not_confirmed elsewhere "the logged-in cookie, but a redirect to the front page instead of wp-admin"
not_confirmed form "the login form came back (HTTP 200)"
not_confirmed down "nothing answered"
check "  and the line says WordPress didn't answer, not HTTP 000" 'grep -qi "no answer" "$out" && ! grep -qF "HTTP 000" "$out"'
check "no session from any of these answers is in an output or a file left behind" \
  '[ -z "$(session_left)" ]' || printf '       found in: %s\n' $(session_left)

echo
echo "--remove"
run remove -- admin
mapfile -t files < <(password_files)
name="$(basename "${files[0]:-none}")"
run remove -- --remove "$name"
check "deletes the file named, and says so without the password" \
  '[ "$rc" -eq 0 ] && [ -z "$(password_files)" ] && grep -qF "Deleted wordpress-passwords/$name" "$out"'
run outside -- admin
echo "keep" > "$home/elsewhere.txt"
run outside -- --remove "$home/elsewhere.txt"
check "won't delete a file outside ~/wordpress-passwords: exit 64, untouched" \
  '[ "$rc" -eq 64 ] && [ -f "$home/elsewhere.txt" ]'
ln -s "$home/elsewhere.txt" "$home/wordpress-passwords/link.txt"
run outside -- --remove link.txt
check "won't follow a link out of the folder: exit 64, untouched" '[ "$rc" -eq 64 ] && [ -f "$home/elsewhere.txt" ]'

echo
if [ "$FAILED" -eq 0 ]; then echo "All wordpress temp-password checks passed."; else exit 1; fi
