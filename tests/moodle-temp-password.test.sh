#!/usr/bin/env bash
# The moodle skill's temporary password never reaches the chat or a command line (moodle 0.1.9, release 4.5.5, M1).
#
# Before: playbooks/rotate-admin-credentials.md ran admin/cli/reset_password.php with --password='<the password>' on
# the moodle container's command line, where ps shows it, and its "safer" form read it with read -s into a shell
# variable that the assistant's next Bash call doesn't have, then put it on the same command line anyway.
# reset_password.php also finds only auth = 'manual' accounts and sets no forced change.
#
# Now scripts/temp-password.sh asks Moodle for the account's id (the lookup half of
# scripts/lib/set-temp-password.php, no password involved), makes the password, saves it to a mode 600 file
# ~/moodle-passwords/<user id>-<UTC time>.txt (a folder of mode 700) before anything changes, and sends it to the
# program's set half on stdin: bash's printf, ssh, sudo -u www-data and php -r. The program sets it the way Moodle's
# own profile page does and reads it back against the stored hash. The script prints one line that names the file and
# the user id, never the username (often an email address) or the password.
#
# The test runs the real script against stand-ins for sshpass, ssh, sudo, php and clv-secret. The stand-in php
# answers as the program would (FAKE_LOOKUP and FAKE_SET pick the answer) and records its arguments, the program's
# text and its stdin. Fails when the password shows up anywhere but the file and php's stdin in the set call; when the
# file or its folder can be read by others, or the file didn't exist before the set call; when a run that changed
# nothing leaves the file, or one that may have changed the password deletes it; when the username doesn't reach php
# as one argument; when ssh lacks either host-key option or closes the set call's stdin; or when --remove deletes
# anything outside ~/moodle-passwords. It also reads the program: it takes the password from stdin and makes the
# calls Moodle's own pages make.
#
# No network and no Docker: the script runs under `env -i` with the stand-ins first on PATH, and everything is written
# under mktemp -d.
#
# Run: bash tests/moodle-temp-password.test.sh [path/to/temp-password.sh]
# (a path runs that copy instead, with its lib/ next to it: how the mutants run)

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPT="${1:-$ROOT/plugins/moodle/skills/moodle/scripts/temp-password.sh}"
PROGRAM="$(dirname "$SCRIPT")/lib/set-temp-password.php"
work="$(mktemp -d "${TMPDIR:-/tmp}/moodle-temp-password.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; return 1; fi; }

if [ ! -f "$SCRIPT" ] || [ ! -f "$PROGRAM" ]; then
  fail "plugins/moodle/skills/moodle/scripts/temp-password.sh and scripts/lib/set-temp-password.php exist"
  echo
  exit 1
fi

# --- Stand-ins ---------------------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"

# Every stand-in appends its command line to $FAKE_STATE/argv (newlines as \n) and its environment to $FAKE_STATE/env.
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

# ssh runs the remote command with a local bash in a clean environment, as sshd gives a session, and keeps a copy of
# what came back in $FAKE_STATE/ssh-stdout. At each call it records how many password files exist
# ($FAKE_STATE/files-at-ssh) and whether it was given -n ($FAKE_STATE/ssh-n). FAKE_SSH=refused: every call fails.
cat > "$bin/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
printf 'ssh %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
find "$FAKE_PWDIR" -maxdepth 1 -name '*.txt' 2> /dev/null | wc -l >> "$FAKE_STATE/files-at-ssh"
n=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) n=yes; shift ;;
    -o | -p | -i | -F | -l | -J) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
echo "$n" >> "$FAKE_STATE/ssh-n"
target="${1:-}"
shift
printf '%s\n' "$target" >> "$FAKE_STATE/ssh-targets"
if [ "${FAKE_SSH:-ok}" = refused ]; then
  echo "ssh: connect to host ${target#*@} port 22: Connection refused" >&2
  exit 255
fi
mapfile -t controls < <(env | grep -E '^FAKE_[A-Z_]*=' || true)
if [ "$n" = yes ]; then exec < /dev/null; fi
env -i PATH="$PATH" HOME=/home/clouve-ops USER=clouve-ops LOGNAME=clouve-ops SHELL=/bin/bash \
  "${controls[@]}" bash -c "$*" 2> "$FAKE_STATE/ssh-stderr.now" | tee -a "$FAKE_STATE/ssh-stdout"
rc="${PIPESTATUS[0]}"
cat "$FAKE_STATE/ssh-stderr.now" >> "$FAKE_STATE/ssh-stderr"
cat "$FAKE_STATE/ssh-stderr.now" >&2
rm -f "$FAKE_STATE/ssh-stderr.now"
exit "$rc"
EOF

# sudo resets the environment, as a stock sudoers does, and records the target user.
cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "${*//$'\n'/\\n}" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
user=root
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | -H) shift ;;
    -u) user="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) echo "fake sudo: unknown option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
printf '%s\n' "$user" >> "$FAKE_STATE/sudo-users"
for v in $(compgen -e); do
  case "$v" in PATH | FAKE_*) ;; *) unset "$v" ;; esac
done
export HOME="/home/$user" USER="$user" LOGNAME="$user"
exec "$@"
EOF

# php -r CODE -- MODE ARG: answers as scripts/lib/set-temp-password.php would. Each call appends "MODE ARG" to
# $FAKE_STATE/php-calls (NUL-separated fields, one record per line), the program to $FAKE_STATE/php-code, and its
# stdin to $FAKE_STATE/php-stdin-<n> (n = the call's number). $FAKE_STATE/accounts maps a lower-case username to
# "<id>\t<auth>".
#   FAKE_SET   changed (default) | policy | crash-before | crash-after | failed | not-verified | notes | echo-fail
#              | echo-after (prints what it read after the change started, then dies)
cat > "$bin/php" <<'EOF'
#!/usr/bin/env bash
all="$*"
printf 'php %s\n' "${all//$'\n'/\\n}" >> "$FAKE_STATE/argv"
env >> "$FAKE_STATE/env"
[ "${1:-}" = -r ] || { echo "fake php: wants -r CODE" >&2; exit 1; }
printf '%s' "${2:-}" > "$FAKE_STATE/php-code"
[ "${3:-}" = -- ] || { echo "fake php: wants -- before the program's arguments" >&2; exit 1; }
mode="${4:-}" arg="${5:-}"
calls=$(( $(cat "$FAKE_STATE/php-count" 2> /dev/null || echo 0) + 1 ))
echo "$calls" > "$FAKE_STATE/php-count"
printf '%s\0%s\0%s\n' "$mode" "$arg" "$#" >> "$FAKE_STATE/php-calls"
input="$(cat; echo x)"
input="${input%x}"
printf '%s' "$input" > "$FAKE_STATE/php-stdin-$calls"
lower="$(printf '%s' "$arg" | tr '[:upper:]' '[:lower:]')"
case "$mode" in
  lookup)
    line="$(awk -F'\t' -v u="$lower" '$1 == u { print $2 "\t" $3; exit }' "$FAKE_STATE/accounts")"
    if [ -z "$line" ]; then echo "RESULT unchanged no-account"; exit 0; fi
    id="${line%%$'\t'*}" auth="${line#*$'\t'}"
    case "$auth" in manual | db | email) echo "RESULT found id=$id auth=$auth" ;; *) echo "RESULT unchanged not-local auth=$auth" ;; esac
    ;;
  set)
    pw="${input%$'\n'}"
    case "${FAKE_SET:-changed}" in
      changed) echo "STEP change id=$arg"; echo "RESULT changed id=$arg auth=manual verified" ;;
      policy) echo "RESULT unchanged policy Passwords must have at least 3 digit(s)." ;;
      crash-before) echo "PHP Fatal error: Uncaught dml_connection_exception" >&2; exit 255 ;;
      crash-after) echo "STEP change id=$arg"; echo "PHP Fatal error: Uncaught Error in session manager" >&2; exit 255 ;;
      failed) echo "STEP change id=$arg"; echo "RESULT failed id=$arg"; exit 3 ;;
      not-verified) echo "STEP change id=$arg"; echo "RESULT changed id=$arg auth=manual not-verified" ;;
      notes) echo "STEP change id=$arg"; echo "RESULT changed id=$arg auth=db verified suspended locked auth-disabled" ;;
      echo-fail) echo "read: $pw"; echo "Error: could not save $pw" >&2; exit 1 ;;
      echo-after) echo "STEP change id=$arg"; echo "read: $pw"; echo "Error: session store failed after $pw" >&2; exit 255 ;;
    esac
    ;;
  *) echo "RESULT unchanged usage"; exit 64 ;;
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
  rm -f "$state"/php-* "$state/files-at-ssh" "$state/ssh-n" "$state/sudo-users" "$state/ssh-stdout" "$state/env"
  [ -f "$state/accounts" ] || printf 'maya.patel\t42\tmanual\nadmin\t2\tmanual\nsso.user\t9\toauth2\n' > "$state/accounts"
  env -i HOME="$home" PATH="$bin:/usr/bin:/bin" TMPDIR="$work" LANG=C.UTF-8 FAKE_STATE="$state" \
    FAKE_PWDIR="$home/moodle-passwords" MOODLE_HOST=moodle-host MOODLE_URL=https://lms.example.test \
    CLOUVE_OPS_PASSWORD=ops-secret ${vars[@]+"${vars[@]}"} bash "$SCRIPT" "$@" > "$out" 2> "$err"
  rc=$?
}

password_files() { find "$home/moodle-passwords" -maxdepth 1 -type f -name '*.txt' 2> /dev/null | sort; }
password_in() { [ -f "${1:-}" ] || return 1; awk 'f { print; exit } /^Temporary password:$/ { f = 1 }' "$1"; }

# leaks PW: every place PW shows up outside the file and php's stdin.
leaks() {
  grep -lF -- "$1" "$out" "$err" "$state/argv" "$state/env" "$state/ssh-targets" "$state/ssh-stdout" \
    "$state/ssh-stderr" "$state/php-calls" "$state/php-code" 2> /dev/null | sed "s#^$work/##"
}

# call N FIELD: field 1 (mode) or 2 (argument) of php's Nth call
call() { sed -n "${1}p" "$state/php-calls" 2> /dev/null | cut -d '' -f "$2"; }

show() { sed 's/^/       /' "$@" | cut -c1-200; }

echo "A manual account"
run main -- maya.patel
check "exits 0" '[ "$rc" -eq 0 ]' || show "$err"
mapfile -t files < <(password_files)
check "saves one password file" '[ "${#files[@]}" -eq 1 ]'
file="${files[0]:-/nonexistent}"
pw="$(password_in "$file" 2> /dev/null || true)"
check "the file is named by the user id and the UTC time, never the username" \
  '[[ "$(basename "$file")" =~ ^42-[0-9]{8}-[0-9]{6}\.txt$ ]]'
check "the file is mode 600, in a folder of mode 700" \
  '[ "$(stat -c %a "$file" 2> /dev/null)" = 600 ] && [ "$(stat -c %a "$home/moodle-passwords" 2> /dev/null)" = 700 ]'
check "the password is 20 characters with at least two capitals, small letters, digits and symbols each" \
  '[ "${#pw}" -eq 20 ] && [[ "$pw" =~ ^[A-Za-z0-9!#%+.=@-]+$ ]] && [ "$(tr -cd A-Z <<< "$pw" | wc -c)" -ge 2 ] && [ "$(tr -cd a-z <<< "$pw" | wc -c)" -ge 2 ] && [ "$(tr -cd 0-9 <<< "$pw" | wc -c)" -ge 2 ] && [ "$(tr -cd "!#%+.=@-" <<< "$pw" | wc -c)" -ge 2 ]'
check "the file names the account and the sign-in page, for the hand-over" \
  'grep -qx "Username: maya.patel" "$file" && grep -qF "https://lms.example.test/login/index.php" "$file"'
check "stdout is one line naming the file and the user id, not the username or the password" \
  '[ "$(wc -l < "$out")" -eq 1 ] && grep -qF "moodle-passwords/$(basename "$file")" "$out" && grep -qF "user id 42" "$out" && ! grep -qF maya "$out"'
if [ -n "$pw" ]; then
  where="$(leaks "$pw")"
  check "the password is in no output, no command line and no environment" '[ -z "$where" ]' \
    || printf '       found in: %s\n' $where
fi
check "php was called twice: lookup with the username, then set with the id" \
  '[ "$(call 1 1)" = lookup ] && [ "$(call 1 2)" = maya.patel ] && [ "$(call 2 1)" = set ] && [ "$(call 2 2)" = 42 ]'
check "the set call got the password on stdin, and the lookup got nothing" \
  '[ "$(cat "$state/php-stdin-2" 2> /dev/null)" = "$pw" ] && [ ! -s "$state/php-stdin-1" ]'
check "the file was there when the set call started, and not before the lookup" \
  '[ "$(sed -n 1p "$state/files-at-ssh")" = 0 ] && [ "$(sed -n 2p "$state/files-at-ssh")" = 1 ]'
check "php ran as www-data both times, with the program on its command line" \
  '[ "$(sort -u "$state/sudo-users")" = www-data ] && grep -qF "user_update_password" "$state/php-code"'
check "the program arrives without its <?php line" '! head -n 1 "$state/php-code" | grep -qF "<?php"'
check "ssh goes to clouve-ops on the moodle host with both host-key options, each time" \
  '[ "$(sort -u "$state/ssh-targets")" = clouve-ops@moodle-host ] && [ "$(grep -cE "^ssh .*-o StrictHostKeyChecking=accept-new .*-o UserKnownHostsFile=/dev/null" "$state/argv")" = 2 ]'
check "the set call keeps ssh's stdin open (no -n), so php can read the password" '[ "$(sed -n 2p "$state/ssh-n")" = no ]'
check "the clouve-ops password reaches sshpass in its environment only" \
  '[ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret ] && ! grep -qF ops-secret "$state/argv"'

echo
echo "A username with a quote, spaces, \$ and ;"
mkdir -p "$work/quote/state"
printf "o'hara x\$y;z\t7\tdb\n" > "$work/quote/state/accounts"
run quote -- "O'Hara x\$y;z"
check "exits 0, and the username reaches php as one argument, unexpanded" \
  '[ "$rc" -eq 0 ] && [ "$(call 1 2)" = "O'"'"'Hara x\$y;z" ] && [ "$(call 2 2)" = 7 ]' || show "$err"
check "  and the file is 7-<time>.txt" 'password_files | grep -qE "/7-[0-9]{8}-[0-9]{6}\.txt$"'

echo
echo "Refusals that change nothing"
run unknown -- nobody.here
check "no such account: exit 2, no file, no set call, and the refusal doesn't repeat the username" \
  '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ] && [ "$(wc -l < "$state/php-calls")" = 1 ] && ! grep -qF nobody "$err"' || show "$err"
run sso -- sso.user
check "an SSO account: exit 2, no file, and stderr names the sign-in method and where its password is set" \
  '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ] && grep -qF oauth2 "$err" && grep -qi "identity provider" "$err"' || show "$err"
run policy FAKE_SET=policy -- maya.patel
check "the site's password policy refuses it: exit 2, the file is deleted, and stderr gives Moodle's rule" \
  '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ] && grep -qF "at least 3 digit(s)" "$err"' || show "$err"
run crashbefore FAKE_SET=crash-before -- maya.patel
check "php dies before the change: exit 2 and the file is deleted" '[ "$rc" -eq 2 ] && [ -z "$(password_files)" ]' || show "$err"
run echofail FAKE_SET=echo-fail -- maya.patel
pw="$(cat "$state/php-stdin-2" 2> /dev/null || true)"
check "what the remote side printed is shown with the password blanked out" \
  '[ -n "$pw" ] && ! grep -qF -- "$pw" "$err" "$out" && grep -qF "[password hidden]" "$err"' || show "$err"
run echoafter FAKE_SET=echo-after -- maya.patel
pw="$(cat "$state/php-stdin-2" 2> /dev/null || true)"
check "the same after the change started: the file is kept and the password is blanked out" \
  '[ "$rc" -eq 2 ] && [ -n "$(password_files)" ] && [ -n "$pw" ] && ! grep -qF -- "$pw" "$err" "$out" && grep -qF "[password hidden]" "$err"' || show "$err"
run sshdown FAKE_SSH=refused -- maya.patel
check "ssh can't connect: exit 1, no file, and stderr says it couldn't reach clouve-ops@moodle-host" \
  '[ "$rc" -eq 1 ] && [ -z "$(password_files)" ] && grep -qF "clouve-ops@moodle-host" "$err"' || show "$err"
run nohost MOODLE_HOST= -- maya.patel
check "no MOODLE_HOST: exit 1, nothing run" '[ "$rc" -eq 1 ] && ! grep -qE "^(ssh|sshpass) " "$state/argv"'
run noarg --
check "no username: exit 64" '[ "$rc" -eq 64 ]'
run twoargs -- a b
check "two usernames: exit 64" '[ "$rc" -eq 64 ]'

echo
echo "A change that may have happened"
run crashafter FAKE_SET=crash-after -- maya.patel
check "php dies after it started the change: exit 2, the file is kept, and stderr says the password may be set" \
  '[ "$rc" -eq 2 ] && [ -n "$(password_files)" ] && grep -qi "may be set" "$err" && grep -qi kept "$err"' || show "$err"
run failed FAKE_SET=failed -- maya.patel
check "Moodle reports the change failed: exit 2 and the file is kept" '[ "$rc" -eq 2 ] && [ -n "$(password_files)" ]' || show "$err"
run notverified FAKE_SET=not-verified -- maya.patel
check "the stored hash doesn't match after the change: exit 2, the file is kept and stderr says so" \
  '[ "$rc" -eq 2 ] && [ -n "$(password_files)" ] && grep -qi "stored hash" "$err"' || show "$err"
run notes FAKE_SET=notes -- maya.patel
check "a suspended, locked account with its sign-in method off: exit 0, and the line says each" \
  '[ "$rc" -eq 0 ] && grep -qi suspended "$out" && grep -qi unlock "$out" && grep -qi "turned off" "$out"' || show "$out" "$err"

echo
echo "On an agent that keeps the passwords out of the environment"
run clv CLOUVE_OPS_PASSWORD= -- maya.patel
check "exits 0, with the clouve-ops password from clv-secret" \
  '[ "$rc" -eq 0 ] && [ "$(cat "$state/sshpass-env" 2> /dev/null)" = ops-secret-from-clv ]' || show "$err"

echo
echo "--remove"
run remove -- maya.patel
mapfile -t files < <(password_files)
name="$(basename "${files[0]:-none}")"
run remove -- --remove "$name"
check "deletes the file named, and says so" '[ "$rc" -eq 0 ] && [ -z "$(password_files)" ] && grep -qF "Deleted moodle-passwords/$name" "$out"'
run outside -- maya.patel
echo "keep" > "$home/elsewhere.txt"
run outside -- --remove "$home/elsewhere.txt"
check "won't delete a file outside ~/moodle-passwords: exit 64, untouched" '[ "$rc" -eq 64 ] && [ -f "$home/elsewhere.txt" ]'
ln -s "$home/elsewhere.txt" "$home/moodle-passwords/link.txt"
run outside -- --remove link.txt
check "won't follow a link out of the folder: exit 64, untouched" '[ "$rc" -eq 64 ] && [ -f "$home/elsewhere.txt" ]'

echo
echo "The program (scripts/lib/set-temp-password.php)"
prog="$(cat "$PROGRAM")"
for call in "stream_get_contents(STDIN)" "->user_update_password(" "unset_user_preference('create_password'" \
  "set_user_preference('auth_forcepasswordchange', 1" "destroy_user_sessions(" "check_password_policy(" \
  "validate_internal_user_password(" "prevent_local_passwords()" "'deleted' => 0"; do
  check "it calls $call" 'grep -qF -- "$call" <<< "$prog"'
done
check "no echo, print or var_dump line names \$password" \
  '! grep -E "^[^/]*\b(echo|print|printf|var_dump|var_export|print_r)\b" <<< "$prog" | grep -qF "\$password"'

echo
if [ "$FAILED" -eq 0 ]; then echo "All moodle temp-password checks passed."; else exit 1; fi
