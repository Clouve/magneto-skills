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
# Two gaps the rig showed on 2026-11-03 (wordpress 0.1.6):
# - wp-cli over the clouve-ops shell had no database settings. The official image's wp-config.php
#   reads them from the environment, and an SSH session doesn't inherit the container's. So wp
#   stopped with "Error establishing a database connection" and nothing changed. The stand-in ssh
#   now gives the session a clean environment, as sshd does, the stand-in sudo resets it as a
#   stock sudoers does, and the stand-in wp can't connect without the WORDPRESS_DB_* values of the
#   container's first process ($FAKE_STATE/pid1-environ stands in for /proc/1/environ). Fails
#   unless wp gets those values in its environment, with none of them on a command line or in an
#   output, and nothing but the WORDPRESS_* settings.
# - The sign-in check posted to the container's own address over plain HTTP. When the site's
#   address is https, WordPress forces SSL for wp-login.php and redirects there before it checks
#   the password, so the check could never confirm a sign-in. The stand-in curl answers that way.
#   Fails unless the check posts to the site's own https address, and keeps an http or missing
#   site address on the container's own address, so a password sent in clear stays in the cluster.
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
all="$*"
printf 'sshpass %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
[ "${1:-}" = "-e" ] || { echo "fake sshpass: wants -e" >&2; exit 2; }
[ -n "${SSHPASS:-}" ] || { echo "fake sshpass: SSHPASS is empty" >&2; exit 5; }
printf '%s' "$SSHPASS" > "$FAKE_STATE/sshpass-env"
shift
exec "$@"
EOF

# ssh runs the remote command with a local bash, so a redirection in it works as it would there,
# and keeps a copy of what comes back over the channel in $FAKE_STATE/ssh-stdout. The command runs
# in a clean environment, as sshd gives a session: none of the agent's variables, only the
# session's own and the test's FAKE_* controls.
cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
# One line per call: the newlines of a remote script are logged as \n.
all="$*"
printf 'ssh %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
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
mapfile -t controls < <(env | grep -E '^FAKE_[A-Z_]*=' || true)
env -i PATH="$PATH" HOME=/home/clouve-ops USER=clouve-ops LOGNAME=clouve-ops SHELL=/bin/bash \
  "${controls[@]}" bash -c "$*" 2> "$FAKE_STATE/ssh-stderr.now" | tee -a "$FAKE_STATE/ssh-stdout"
rc="${PIPESTATUS[0]}"
# What the remote side said on stderr comes back too; a copy is kept in $FAKE_STATE/ssh-stderr.
cat "$FAKE_STATE/ssh-stderr.now" >> "$FAKE_STATE/ssh-stderr"
cat "$FAKE_STATE/ssh-stderr.now" >&2
rm -f "$FAKE_STATE/ssh-stderr.now"
exit "$rc"
EOF

# sudo resets the environment, as a stock sudoers does (env_reset): the command keeps PATH, the
# test's FAKE_* controls and only the names --preserve-env lists (all of it with -E), and gets the
# target user's HOME, USER and LOGNAME. The container's /proc/1/environ is $FAKE_STATE/pid1-environ
# here; with FAKE_ENVIRON=denied it can't be read. Each target user goes to $FAKE_STATE/sudo-users.
cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
user=root keep_all=0 keep=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | -H) shift ;;
    -E) keep_all=1; shift ;;
    -u) user="${2:-}"; shift 2 ;;
    --preserve-env=*) keep="${1#*=}"; shift ;;
    --) shift; break ;;
    -*) echo "fake sudo: unknown option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
printf '%s\n' "$user" >> "$FAKE_STATE/sudo-users"
args=()
for a in "$@"; do
  if [ "$a" = /proc/1/environ ]; then
    if [ "${FAKE_ENVIRON:-ok}" = denied ]; then
      echo "cat: /proc/1/environ: Permission denied" >&2
      exit 1
    fi
    a="$FAKE_STATE/pid1-environ"
    # A command run here with the channel's stdin still open could read the line meant for wp (the new
    # password). This one takes a line from it then, as such a command would.
    if [ "$(readlink "/proc/$$/fd/0")" != /dev/null ]; then IFS= read -r _ || true; fi
  fi
  args+=("$a")
done
if [ "$keep_all" -eq 0 ]; then
  keepers=" PATH ${keep//,/ } "
  for v in $(compgen -e); do
    case "$v" in FAKE_*) continue ;; esac
    case "$keepers" in *" $v "*) continue ;; esac
    unset "$v"
  done
fi
export HOME="/home/$user" USER="$user" LOGNAME="$user"
exec "${args[@]}"
EOF

# wp-cli with PHP's readline: the prompt and the value it reads both go to stdout. Before that, wp
# loads wp-config.php, and the official image's wp-config.php reads the database settings from the
# environment (getenv_docker): without the values the container's first process has, wp can't
# connect and stops before it reads anything. Its environment goes to $FAKE_STATE/wp-env (NUL
# separated).
cat > "$bin/wp" <<'EOF'
#!/usr/bin/env bash
printf 'wp %s\n' "$*" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
env -0 > "$FAKE_STATE/wp-env"
for name in WORDPRESS_DB_HOST WORDPRESS_DB_USER WORDPRESS_DB_PASSWORD WORDPRESS_DB_NAME; do
  expected="$(tr '\0' '\n' < "$FAKE_STATE/pid1-environ" | grep -m1 "^$name=" | cut -d= -f2-)"
  if [ -z "$expected" ] || [ "${!name:-}" != "$expected" ]; then
    echo "Error: Error establishing a database connection." >&2
    exit 1
  fi
done
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
# file -D names and prints the status code. Where the check posts decides first. FAKE_SITE is the
# site's own address (WordPress's siteurl; default https://blog.example.test):
#   FAKE_SITE/wp-login.php        WordPress answers as FAKE_SIGN_IN says (below)
#   http://wp-host/wp-login.php   the WordPress container's own address, over plain HTTP. With an
#                                 https site, WordPress forces SSL for wp-login.php and redirects
#                                 before it checks the password, with no cookie (the force-ssl
#                                 answer below); with an http site it answers as FAKE_SIGN_IN says
#   anything else                 no such host: curl prints 000 and exits 6
# FAKE_SIGN_IN picks the answer:
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
headers="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D | --dump-header) headers="${2:-}"; shift 2 ;;
    --data-urlencode)
      [ "${2:-}" = "pwd@-" ] && cat > "$FAKE_STATE/curl-stdin"
      shift 2
      ;;
    -o | -w | -b | -H | --max-time | --proto | --proto-redir | --noproxy) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
site="${FAKE_SITE:-https://blog.example.test}"
answer="${FAKE_SIGN_IN:-wp-admin}"
case "$url" in
  "$site/wp-login.php") ;;
  http://wp-host/wp-login.php) case "$site" in https://*) answer=force-ssl ;; esac ;;
  *) printf '000'; exit 6 ;;
esac
# badcert: the site's certificate can't be checked (curl exit 60)
if [ "$answer" = badcert ]; then printf '000'; exit 60; fi
session="admin%7C1762300000%7Cfake-session-token-5d2c%7Cfakehmac"
test_cookie="Set-Cookie: wordpress_test_cookie=WP%20Cookie%20check; path=/"
auth="Set-Cookie: wordpress_0123abcd=$session; path=/wp-admin; HttpOnly"
logged_in="Set-Cookie: wordpress_logged_in_0123abcd=$session; path=/; HttpOnly"
case "$answer" in
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

CONFIG_EXTRA="$(printf "WORDPRESS_CONFIG_EXTRA=define('WP_POST_REVISIONS', 5);\ndefine('WP_MEMORY_LIMIT', '256M');")"

# wp_env NAME: the value NAME had in the stand-in wp's environment, NUL-safe (a missing NAME prints
# nothing and fails)
wp_env() {
  python3 - "$state/wp-env" "$1" <<'PY'
import sys
try:
    data = open(sys.argv[1], "rb").read().decode()
except OSError:
    sys.exit(1)
for entry in data.split("\0"):
    name, sep, value = entry.partition("=")
    if sep and name == sys.argv[2]:
        sys.stdout.write(value)
        sys.exit(0)
sys.exit(1)
PY
}

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
  rm -f "$state/hash-reads" "$state/wp-env" "$state/sudo-users"
  echo "hash-before" > "$state/user_pass"
  # The accounts the lookup finds, unless the case wrote its own: admin is 61 64 6d 69 6e (ID 5),
  # o'brien is 6f 27 62 72 69 65 6e (ID 7).
  [ -f "$state/accounts" ] || printf '61646d696e\t5\n6f27627269656e\t7\n' > "$state/accounts"
  # The WordPress container's own environment, as its first process has it: NUL-separated, with
  # values that differ from the agent's, a setting that spans two lines, a name bash can't export,
  # and the container's clouve-ops password, which must not reach wp.
  printf '%s\0' PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOSTNAME=tkt-5-wordpress \
    WORDPRESS_DB_HOST=tkt-5-wordpress-mariadb WORDPRESS_DB_USER=wordpress WORDPRESS_DB_NAME=wordpress \
    WORDPRESS_DB_PASSWORD=container-db-secret WORDPRESS_TABLE_PREFIX=wp_ \
    WORDPRESS_SITE_URL=https://blog.example.test "$CONFIG_EXTRA" WORDPRESS_X.Y=1 \
    WORDPRESS_ADMIN_PASSWORD=container-admin-secret \
    CLOUVE_OPS_PASSWORD=container-ops-secret APACHE_RUN_USER=www-data > "$state/pid1-environ"
  env -i HOME="$home" PATH="$bin:/usr/bin:/bin" TMPDIR="$work" LANG=C.UTF-8 FAKE_STATE="$state" \
    WORDPRESS_DB_HOST=wp-db WORDPRESS_DB_USER=wpuser WORDPRESS_DB_NAME=wpdb \
    WORDPRESS_HOST=wp-host WORDPRESS_SITE_URL=https://blog.example.test \
    WORDPRESS_DB_PASSWORD=db-secret CLOUVE_OPS_PASSWORD=ops-secret \
    ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" > "$out" 2> "$err"
  rc=$?
}

# password_files: the .txt files in this case's ~/wordpress-passwords, one per line
password_files() { find "$home/wordpress-passwords" -maxdepth 1 -type f -name '*.txt' 2> /dev/null | sort; }

# password_in FILE: the line after "Temporary password:" in FILE. Fails when FILE isn't a file
# (awk would read stdin for an empty name, and the test would wait for ever).
password_in() { [ -f "${1:-}" ] || return 1; awk 'f { print; exit } /^Temporary password:$/ { f = 1 }' "$1"; }

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
  'grep -qE "^sudo .*-u www-data wp --path=/var/www/html user update 5 --prompt=user_pass$" "$state/argv" && grep -qx www-data "$state/sudo-users"'
check "wp got the database settings of the WordPress container's first process, in its environment" \
  '[ "$(wp_env WORDPRESS_DB_HOST)" = tkt-5-wordpress-mariadb ] && [ "$(wp_env WORDPRESS_DB_PASSWORD)" = container-db-secret ] && [ "$(wp_env WORDPRESS_TABLE_PREFIX)" = wp_ ]'
check "a WordPress setting whose value spans two lines reaches wp whole" \
  '[ "WORDPRESS_CONFIG_EXTRA=$(wp_env WORDPRESS_CONFIG_EXTRA)" = "$CONFIG_EXTRA" ]'
check "only WordPress's settings reach wp: not the container's clouve-ops or admin password" \
  '! wp_env CLOUVE_OPS_PASSWORD > /dev/null && ! grep -qaF -e container-ops-secret -e container-admin-secret "$state/wp-env"'
check "a setting with a name bash can't export is skipped without an error, on either side" \
  '! grep -qi "not a valid identifier" "$err" "$state/ssh-stderr" 2> /dev/null'
check "the container's database password is on no command line and in no output, nor in what came back on stderr" \
  '! grep -qF container-db-secret "$state/argv" "$out" "$err" "$state/ssh-stdout" "$state/ssh-stderr" 2> /dev/null'
check "ssh keeps and checks no saved host key" \
  'grep -E "^ssh " "$state/argv" | grep -F -- "-o StrictHostKeyChecking=accept-new" | grep -qF -- "-o UserKnownHostsFile=/dev/null"'
check "ssh went to clouve-ops on the WordPress host" 'grep -qx "clouve-ops@wp-host" "$state/ssh-targets"'
check "the sign-in check got the password on curl's stdin" \
  '[ -n "$pw" ] && [ "$(cat "$state/curl-stdin" 2> /dev/null)" = "$pw" ]'
check "the sign-in check posts to the site's own address, https://blog.example.test/wp-login.php" \
  'grep -E "^curl " "$state/argv" | grep -qF "https://blog.example.test/wp-login.php" && ! grep -E "^curl " "$state/argv" | grep -qF "http://wp-host/"'
check "stdout says WordPress took the password at sign-in" 'grep -qi "accepted" "$out"'
check "curl ignores ~/.curlrc (-q comes first)" 'grep -qE "^curl -q " "$state/argv"'
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
check "the sign-in check posts to the site's own address, and stdout says WordPress took the password" \
  'grep -E "^curl " "$state/argv" | grep -qF "https://blog.example.test/wp-login.php" && grep -qi "accepted" "$out"' \
  || show "$out"

echo
echo "Where the sign-in check posts"
run subdir WORDPRESS_SITE_URL=https://blog.example.test/news/ FAKE_SITE=https://blog.example.test/news -- admin
check "a site in a folder: the check posts to https://blog.example.test/news/wp-login.php and WordPress accepts it" \
  '[ "$rc" -eq 0 ] && grep -E "^curl " "$state/argv" | grep -qF "https://blog.example.test/news/wp-login.php" && grep -qi "accepted" "$out"' \
  || show "$out" "$err"
run httpsite WORDPRESS_SITE_URL=http://blog.example.test FAKE_SITE=http://blog.example.test -- admin
check "an http site: the check stays on the container's own address, so the password crosses no other network in clear" \
  '[ "$rc" -eq 0 ] && grep -E "^curl " "$state/argv" | grep -qF "http://wp-host/wp-login.php" && ! grep -E "^curl " "$state/argv" | grep -qF "http://blog.example.test" && grep -qi "accepted" "$out"' \
  || show "$out" "$err"
check "  and that post to the container goes through no proxy" 'grep -E "^curl " "$state/argv" | grep -qF -- "--noproxy *"'
run nohostname WORDPRESS_SITE_URL=https://elsewhere.example.test -- admin
check "the site's address doesn't resolve from here: exit 0, and the line says so" \
  '[ "$rc" -eq 0 ] && grep -qi "couldn.t confirm the sign-in" "$out" && grep -qi "resolve" "$out"' || show "$out" "$err"
run badcert FAKE_SIGN_IN=badcert -- admin
check "the site's certificate can't be checked: exit 0, and the line says so" \
  '[ "$rc" -eq 0 ] && grep -qi "couldn.t confirm the sign-in" "$out" && grep -qi "certificate" "$out"' || show "$out" "$err"
run nosite WORDPRESS_SITE_URL= -- admin
pw="$(password_in "$(password_files | head -n 1)" 2> /dev/null || true)"
check "no site address: the check posts to the container's own address, and with an https site it can't confirm (exit 0)" \
  '[ "$rc" -eq 0 ] && grep -E "^curl " "$state/argv" | grep -qF "http://wp-host/wp-login.php" && grep -qi "couldn.t confirm the sign-in" "$out"' \
  || show "$out" "$err"
check "  and the file is kept, with no sign-in page line and the password in no output" \
  '[ -n "$pw" ] && ! grep -q "^Sign in at:" "$(password_files | head -n 1)" && [ -z "$(leaks "$pw")" ]'

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
  '[ "$rc" -eq 0 ] && grep -qE "^sudo .*-u www-data wp --path=/var/www/html user update 7 --prompt=user_pass$" "$state/argv"' \
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
run noenviron FAKE_ENVIRON=denied -- admin
mapfile -t files < <(password_files)
check "the container's settings can't be read: exit 2, no file left, stderr says why and suggests --via-db" \
  '[ "$rc" -eq 2 ] && [ "${#files[@]}" -eq 0 ] && grep -qF "Permission denied" "$err" && grep -qF -- "--via-db" "$err"' \
  || show "$err"
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
