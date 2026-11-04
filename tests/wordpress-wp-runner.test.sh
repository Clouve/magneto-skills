#!/usr/bin/env bash
# The wordpress skill runs wp-cli in the WordPress container with WordPress's own database settings
# (wordpress 0.1.6).
#
# Before: the playbooks ran `sudo -u www-data wp --path=/var/www/html ...` over the clouve-ops SSH
# channel. The official image's wp-config.php reads the database settings from the environment
# (getenv_docker), and an SSH session doesn't inherit the container's environment, so every wp
# command that touches the database stopped with "Error establishing a database connection". Only
# commands that never load the database worked, `core version` among them, and that is what the
# 2026-08-05 check ran. Found on the rig on 2026-11-03, through scripts/temp-password.sh.
#
# Now scripts/wp.sh runs one wp command as www-data over the channel. On the WordPress side, the
# WORDPRESS_* settings of the container's first process (/proc/1/environ, read as its owner) go
# into wp's environment, so no value is ever on a command line. Each argument is quoted with
# printf %q and reaches wp unchanged. wp's output and exit code pass through.
#
# The test runs the real script against stand-ins for sshpass, ssh, sudo, wp and clv-secret. The
# stand-in ssh gives the remote command a clean environment, as sshd does; the stand-in sudo
# resets it, as a stock sudoers does; the stand-in wp can't connect without the WORDPRESS_DB_*
# values that $FAKE_STATE/pid1-environ (the stand-in for /proc/1/environ) holds. No network and no
# Docker.
#
# Run: bash tests/wordpress-wp-runner.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="$ROOT/plugins/wordpress/skills/wordpress/scripts/wp.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/wp-runner.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; return 1; fi; }

if [ ! -f "$SCRIPT" ]; then
  fail "plugins/wordpress/skills/wordpress/scripts/wp.sh exists"
  echo
  exit 1
fi

# --- Stand-ins ---------------------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"

cat > "$bin/sshpass" <<'EOF'
#!/usr/bin/env bash
all="$*"
printf 'sshpass %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
[ "${1:-}" = "-e" ] || { echo "fake sshpass: wants -e" >&2; exit 2; }
[ -n "${SSHPASS:-}" ] || { echo "fake sshpass: SSHPASS is empty" >&2; exit 5; }
printf '%s' "$SSHPASS" > "$FAKE_STATE/sshpass-env"
shift
exec "$@"
EOF

# ssh runs the remote command with a local bash in a clean environment, as sshd gives a session
# (the test's FAKE_* controls aside). With FAKE_SSH=refused every connection fails, the `true`
# probe included.
cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
# One line per call: the newlines of a remote script are logged as \n.
all="$*"
printf 'ssh %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
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
  "${controls[@]}" bash -c "$*"
EOF

# sudo with env_reset: PATH, the FAKE_* controls and only the names --preserve-env lists survive.
# /proc/1/environ is $FAKE_STATE/pid1-environ.
cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_STATE/argv"
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
  [ "$a" = /proc/1/environ ] && a="$FAKE_STATE/pid1-environ"
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

# wp: without the container's database settings it stops as wp-cli does. Its arguments go to
# $FAKE_STATE/wp-args and its environment to $FAKE_STATE/wp-env (both NUL separated). FAKE_WP:
#   ok     (default) `option get siteurl` prints the site's address; anything else prints "Success"
#   fails  prints an error on stderr and exits 3
#   fatal  exits 255, as wp-cli does after a PHP fatal error
cat > "$bin/wp" <<'EOF'
#!/usr/bin/env bash
printf 'wp %s\n' "$*" >> "$FAKE_STATE/argv"
printf '%s\0' "$@" > "$FAKE_STATE/wp-args"
env -0 > "$FAKE_STATE/wp-env"
for name in WORDPRESS_DB_HOST WORDPRESS_DB_USER WORDPRESS_DB_PASSWORD WORDPRESS_DB_NAME; do
  expected="$(tr '\0' '\n' < "$FAKE_STATE/pid1-environ" | grep -m1 "^$name=" | cut -d= -f2-)"
  if [ -z "$expected" ] || [ "${!name:-}" != "$expected" ]; then
    echo "Error: Error establishing a database connection." >&2
    exit 1
  fi
done
case "${FAKE_WP:-ok}" in
  ok)
    if [ "$*" = "--path=/var/www/html option get siteurl" ]; then echo "https://blog.example.test"; else echo "Success"; fi
    ;;
  fails) echo "Error: The 'nope' plugin could not be found." >&2; exit 3 ;;
  fatal) echo "PHP Fatal error:  Uncaught Error" >&2; exit 255 ;;
esac
EOF

cat > "$bin/clv-secret" <<'EOF'
#!/usr/bin/env bash
printf 'clv-secret %s\n' "$*" >> "$FAKE_STATE/argv"
case "${1:-}" in
  CLOUVE_OPS_PASSWORD) printf '%s' 'ops-secret-from-clv' ;;
  *) echo "clv-secret: ${1:-} is not set on this server" >&2; exit 2 ;;
esac
EOF
chmod +x "$bin"/*

# --- Running the script --------------------------------------------------------------------

# run CASE [VAR=VALUE...] -- ARGS...: runs wp.sh for CASE. Leaves $state, $out, $err and $rc.
run() {
  local name="$1" vars=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do vars+=("$1"); shift; done
  shift
  state="$work/$name/state"
  out="$work/$name/out"
  err="$work/$name/err"
  mkdir -p "$state"
  rm -f "$state"/*
  : > "$state/argv"
  # The container's first process: WordPress's database settings, a key's _FILE form and WORDPRESS_DEBUG (which
  # wp-config.php reads), the admin password and the site address (which it doesn't), a name bash can't export,
  # and the clouve-ops password. With ENVIRON_KIND=none it holds no WORDPRESS_ setting at all.
  if [ "${ENVIRON_KIND:-full}" = none ]; then
    printf '%s\0' PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOSTNAME=tkt-5-wordpress \
      > "$state/pid1-environ"
  else
    printf '%s\0' PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      WORDPRESS_DB_HOST=tkt-5-wordpress-mariadb WORDPRESS_DB_USER=wordpress WORDPRESS_DB_NAME=wordpress \
      WORDPRESS_DB_PASSWORD=container-db-secret WORDPRESS_TABLE_PREFIX=wp_ WORDPRESS_X.Y=1 \
      WORDPRESS_AUTH_KEY_FILE=/run/secrets/auth-key WORDPRESS_DEBUG=false \
      WORDPRESS_ADMIN_PASSWORD=container-admin-secret WORDPRESS_SITE_URL=https://blog.example.test \
      CLOUVE_OPS_PASSWORD=container-ops-secret > "$state/pid1-environ"
  fi
  env -i HOME="$work/$name" PATH="$bin:/usr/bin:/bin" LANG=C.UTF-8 FAKE_STATE="$state" \
    WORDPRESS_HOST=wp-host WORDPRESS_DB_PASSWORD=agent-db-secret CLOUVE_OPS_PASSWORD=ops-secret \
    ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" > "$out" 2> "$err" < /dev/null
  rc=$?
}

# wp_env NAME: the value NAME had in the stand-in wp's environment (fails when it had none)
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

show() { sed 's/^/       /' "$@" | cut -c1-200; }

echo "A wp command that reads the database"
run read -- option get siteurl
check "exits 0 and passes wp's output through" \
  '[ "$rc" -eq 0 ] && [ "$(cat "$out")" = "https://blog.example.test" ]' || show "$err"
check "wp ran as www-data on /var/www/html with the command's arguments" \
  'grep -qE "^sudo .*-u www-data wp --path=/var/www/html option get siteurl$" "$state/argv" && grep -qx www-data "$state/sudo-users"'
check "wp got the database settings of the WordPress container's first process, in its environment" \
  '[ "$(wp_env WORDPRESS_DB_HOST)" = tkt-5-wordpress-mariadb ] && [ "$(wp_env WORDPRESS_DB_PASSWORD)" = container-db-secret ]'
check "only WordPress's settings reach wp: not the container's clouve-ops password" \
  '! wp_env CLOUVE_OPS_PASSWORD > /dev/null && ! grep -qaF container-ops-secret "$state/wp-env"'
check "the settings wp-config.php reads reach wp, a _FILE form and WORDPRESS_DEBUG included" \
  '[ "$(wp_env WORDPRESS_AUTH_KEY_FILE)" = /run/secrets/auth-key ] && [ "$(wp_env WORDPRESS_DEBUG)" = false ] && [ "$(wp_env WORDPRESS_TABLE_PREFIX)" = wp_ ]'
check "settings wp-config.php never reads stay out of wp's environment: the admin password and the site address" \
  '! wp_env WORDPRESS_ADMIN_PASSWORD > /dev/null && ! grep -qaF container-admin-secret "$state/wp-env" && ! wp_env WORDPRESS_SITE_URL > /dev/null'
check "the container's database password is on no command line and in no output" \
  '! grep -qF container-db-secret "$state/argv" "$out" "$err"'
check "a setting with a name bash can't export is skipped without an error" '! grep -qi "not a valid identifier" "$err"'
check "ssh goes to clouve-ops on the WordPress host, with stdin closed and no saved host key" \
  'grep -qx "clouve-ops@wp-host" "$state/ssh-targets" && grep -E "^ssh " "$state/argv" | grep -F -- " -n " | grep -F -- "-o StrictHostKeyChecking=accept-new" | grep -qF -- "-o UserKnownHostsFile=/dev/null"'
check "the clouve-ops password reaches sshpass in its environment only" \
  '[ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret ] && ! grep -qF ops-secret "$state/argv"'

echo
echo "Arguments reach wp unchanged"
run quoting -- search-replace 'https://old.example.com' "it's \$HOME; a&b | c" "$(printf 'two\nlines')" '*' --dry-run
check "exits 0" '[ "$rc" -eq 0 ]' || show "$err"
check "each argument arrives as one, unexpanded: quotes, \$, ;, &, |, a newline and a *" \
  'python3 -c "import sys; got = open(sys.argv[1], \"rb\").read().decode().split(\"\0\")[:-1]; sys.exit(got != sys.argv[2:])" \
     "$state/wp-args" --path=/var/www/html search-replace https://old.example.com "it'"'"'s \$HOME; a&b | c" "$(printf "two\nlines")" "*" --dry-run'
run dashdash -- -- --info
check "-- ends wp.sh's options, so wp gets --info" \
  '[ "$rc" -eq 0 ] && grep -qE "^sudo .*-u www-data wp --path=/var/www/html --info$" "$state/argv"' || show "$err"
run globalflag -- --skip-plugins plugin list
check "a wp option first goes to wp too" \
  '[ "$rc" -eq 0 ] && grep -qE "^sudo .*-u www-data wp --path=/var/www/html --skip-plugins plugin list$" "$state/argv"' || show "$err"

echo
echo "Commands that would print a password are refused"
# wp gets WordPress's real settings, so these print the database password, a key or a salt into the chat.
refused() {
  local label="$1"
  shift
  run refuse -- "$@"
  check "$label: exit 64, nothing run, and stderr says it would print a secret" \
    '[ "$rc" -eq 64 ] && ! grep -qE "^(ssh|sshpass) " "$state/argv" && grep -qi "would print" "$err"' || show "$err"
}
refused "config get DB_PASSWORD" config get DB_PASSWORD
refused "config get AUTH_SALT" config get AUTH_SALT
refused "config get with an option before the name" config get --type=constant DB_PASSWORD
refused "config get nonce_key in lower case, after a wp option" --skip-plugins config get nonce_key
refused "config list" config list
run fieldnames -- config list --fields=name
check "config list --fields=name (the names only) runs" '[ "$rc" -eq 0 ]' || show "$err"
run debugget -- config get WP_DEBUG
check "config get WP_DEBUG runs" '[ "$rc" -eq 0 ]' || show "$err"

echo
echo "Exit codes"
run fails FAKE_WP=fails -- plugin activate nope
check "wp's own exit code and its stderr pass through" \
  '[ "$rc" -eq 3 ] && grep -qF "could not be found" "$err"'
run fatal FAKE_WP=fatal -- plugin list
check "wp's own 255 passes through and isn't called an SSH failure" \
  '[ "$rc" -eq 255 ] && ! grep -qi "could not reach" "$err"' || show "$err"
run down FAKE_SSH=refused -- plugin list
check "ssh can't connect: exit 255, and stderr says it couldn't reach clouve-ops@wp-host" \
  '[ "$rc" -eq 255 ] && grep -qF "could not reach clouve-ops@wp-host" "$err"' || show "$err"
ENVIRON_KIND=none run nowpenv -- option get siteurl
check "no WordPress setting in the container's environment: wp runs without --preserve-env, and its error passes through" \
  '[ "$rc" -eq 1 ] && grep -qF "Error establishing a database connection" "$err" && ! grep -E "^sudo " "$state/argv" | grep -qF -- "--preserve-env"' \
  || show "$err"
run nohost WORDPRESS_HOST= -- plugin list
check "no WORDPRESS_HOST: exit 1, nothing run" '[ "$rc" -eq 1 ] && ! grep -qE "^(ssh|sshpass) " "$state/argv"'
run noargs --
check "no wp command: exit 64, nothing run" '[ "$rc" -eq 64 ] && ! grep -qE "^(ssh|sshpass) " "$state/argv"'

echo
echo "On an agent that keeps the passwords out of the environment"
run clv CLOUVE_OPS_PASSWORD= -- option get siteurl
check "exits 0, with the clouve-ops password from clv-secret" \
  '[ "$rc" -eq 0 ] && [ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret-from-clv ]' || show "$err"

echo
if [ "$FAILED" -eq 0 ]; then echo "All wordpress wp.sh checks passed."; else exit 1; fi
