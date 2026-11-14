#!/usr/bin/env bash
# The moodle skill's commands work in the containers Clouve ships, and its text promises nothing the customer can't do
# (moodle 0.1.9, release 4.5.5: M1, M2, M3 and M7).
#
# M7. Every ssh and scp command keeps and checks no saved host key. From the 5.3 image on, the moodle container makes
# a new SSH host key at every start, so a saved key is wrong after the next restart, and on an agent without the
# Magneto Agent's sibling SSH settings a key that is new to it stops at a yes/no prompt that sshpass can't answer:
# sshpass exits 6 and prints nothing. So every command passes -o StrictHostKeyChecking=accept-new
# -o UserKnownHostsFile=/dev/null on its own line, as gibbon's, odoo's and wordpress's do, and
# tests/lib/ssh-host-key-check.py runs each command's options through the real `ssh -G -F /dev/null`. Each command
# also sets SSHPASS on the sshpass command itself: the assistant's next Bash call doesn't have a variable that an
# `export SSHPASS=...` set in the one before, so the old "do this once per shell" form ran with no password.
#
# M3. The images have no systemd, and the customer's Clouve dashboard has no restart button. Fails on systemctl, on
# mariadb or postgres commands in a MySQL 8.4 container, and on text that has the user restart the app, the pod or
# the container or calls a restart the fix.
#
# M2. The image writes config.php's database lines from the deployment's settings at every start, and only Clouve
# can change those, so a database password changed from here breaks the site or is undone at the next start. Fails on
# text that offers a database password rotation through the environment, a Clouve control or a restart.
#
# M1. The moodle image is built on php:8.3-apache, whose /var/log/apache2/error.log is a link to the container's
# stderr: a tail of it hangs and reads nothing. Fails on such a tail, and checks that reference/shell-access.md says
# so. The admin password playbook runs scripts/temp-password.sh: fails on a password on reset_password.php's command
# line, on `read -s` and on the draft UPDATE of a column Moodle doesn't have.
#
# Reads the plugin's files only; ssh -G connects to nothing.
#
# Run: bash tests/moodle-channel-text.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN="$ROOT/plugins/moodle"
SKILL_DIR="$PLUGIN/skills/moodle"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# stale LABEL [-i] REGEX: no moodle file matches REGEX (extended; -i ignores case).
stale() {
  local label="$1" opt="" hits
  shift
  if [ "$1" = "-i" ]; then opt="-i"; shift; fi
  hits="$(grep -rnE $opt --include='*.md' --include='*.sh' --exclude-dir=tests -- "$1" "$PLUGIN" || true)"
  if [ -z "$hits" ]; then
    pass "$label"
  else
    fail "$label"
    printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-200
  fi
}

# --- M7: SSH host keys and the password ------------------------------------------------------

if ! command -v ssh > /dev/null 2>&1; then
  fail "ssh is installed, to check each command's options with ssh -G"
else
  commands="$(python3 -I "$ROOT/tests/lib/ssh-host-key-check.py" "$ROOT" moodle)"
  bad="$(grep '^bad ' <<< "$commands" || true)"
  ok="$(grep -c '^ok ' <<< "$commands" || true)"
  if [ "$ok" -lt 60 ] && [ -z "$bad" ]; then
    fail "every ssh and scp command keeps no host key (found only $ok commands: the scan is broken)"
  elif [ -z "$bad" ]; then
    pass "every ssh and scp command keeps no host key, even on an agent without the sibling SSH settings ($ok checked)"
  else
    fail "every ssh and scp command keeps no host key, even on an agent without the sibling SSH settings ($(grep -c '' <<< "$bad") fail)"
    printf '%s\n' "$bad" | sed 's/^bad /       /' | head -20 | cut -c1-200
  fi
fi
mapfile -t md_files < <(find "$PLUGIN" -type f -name '*.md' | sort)
bare="$(grep -nHE 'sshpass -e (ssh|scp)' "${md_files[@]}" | grep -vF 'SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e' || true)"
if [ -z "$bare" ]; then
  pass "every sshpass command in the markdown sets SSHPASS on the command itself"
else
  fail "every sshpass command in the markdown sets SSHPASS on the command itself ($(grep -c '' <<< "$bare") don't)"
  printf '%s\n' "$bare" | sed "s#^$ROOT/##; s/^/       /" | head -10 | cut -c1-200
fi
exported="$(grep -nHE '(^|[;&|][[:space:]]*)[[:space:]]*export SSHPASS=' "${md_files[@]}" || true)"
if [ -z "$exported" ]; then
  pass "no markdown exports SSHPASS once per shell (the next Bash call doesn't have it)"
else
  fail "no markdown exports SSHPASS once per shell (the next Bash call doesn't have it)"
  printf '%s\n' "$exported" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-200
fi
stale "no line says to accept a host key interactively, or relies on a saved one" \
  -i "accept it interactively|accept it once|key is captured|first ssh to each host|known[-_ ]?hosts?[[:space:]]+entry|subsequent connections are silent"

# --- M3: no systemd, no restart button -----------------------------------------------------------

stale "no systemctl command (the containers have no systemd)" 'systemctl [a-z]'
stale "no mariadb or postgres command on the moodle-mysql container (it runs MySQL 8.4)" 'sudo mariadb\b|sudo -u postgres'
stale "no line has the user restart the app, the pod or the container, or calls a restart the fix" \
  -i 'restart (the|their|your) (`[^`]+` )?(app|application|pod|container)\b|restart of the (app|application|pod|container)|restart is (the|a valid) fix|kubectl rollout|restart[^.]*clouve ui|restart (the )?pod\b|pod restart (is|to)\b|\+ pod restart|on pod restart'

# --- M2: the database password is Clouve support's ---------------------------------------------

stale "no line offers a database password rotation through the environment, a Clouve control or a restart" \
  -i 'prefer (the |that )?env[- ]|env(-var)?-driven (sync |config )?(path|pattern)|via env vars|env injection on pod restart|rotate the secret|rotated clouve secret|via a kubernetes secret|clouve platform ui'
stale "no config.php gate shows a diff (config.php holds the database password)" -i 'show(ing)? (a |the )?diff'

# --- M1: the Apache error log, and the temporary password ---------------------------------------

stale "no tail of /var/log/apache2/error.log (a link to the container's stderr: the tail hangs)" \
  -i 'tail[^|;]*/var/log/apache2/error\.log|tailing php|tail this'
stale "no line asks for lines of the PHP error log (nothing in the pod can read it)" -i 'lines of the PHP error log'
ACCESS="$SKILL_DIR/reference/shell-access.md"
if grep -qE '^## The Apache error log' "$ACCESS" && grep -qF 'ls -l /var/log/apache2/' "$ACCESS" \
  && grep -qF 'php:8.3-apache' "$ACCESS"; then
  pass "reference/shell-access.md says what error.log is on this image, and how to check"
else
  fail "reference/shell-access.md says what error.log is on this image, and how to check"
fi
# The password goes to php through sudo's stdin, so a sudo I/O log in the container would keep it (as wp.sh's
# --preserve-env values would be kept in wordpress's): the script and shell-access.md say not to turn one on.
if grep -qi "sudo log" "$SKILL_DIR/scripts/temp-password.sh" && grep -qi "sudo log" "$ACCESS"; then
  pass "temp-password.sh and shell-access.md say not to turn on a sudo log in the container"
else
  fail "temp-password.sh and shell-access.md say not to turn on a sudo log in the container"
fi
stale "no password on reset_password.php's command line" '\-\-password=[^`[:space:]]'
stale "no password read with read -s or kept in a shell variable" 'read -s[[:space:]]+-|NEWPASS'
stale "no draft UPDATE of a column Moodle doesn't have" 'password_change_required|preference_auth_forcepasswordchange'
ROTATE="$SKILL_DIR/playbooks/rotate-admin-credentials.md"
fenced="$(awk '/^[[:space:]]*```/ { fence = !fence; next } fence' "$ROTATE")"
if grep -qE 'scripts/temp-password\.sh -- ' <<< "$fenced" && grep -qE 'scripts/temp-password\.sh --remove ' <<< "$fenced" \
  && ! grep -qiE 'reset_password\.php' <<< "$fenced" && grep -qF 'relateduserid' <<< "$fenced"; then
  pass "rotate-admin-credentials.md's commands run scripts/temp-password.sh (and --remove), and its audit query reads relateduserid"
else
  fail "rotate-admin-credentials.md's commands run scripts/temp-password.sh (and --remove), and its audit query reads relateduserid"
fi
if grep -qE '^\| (Set|Reset) [^|]*password[^|]*\|[^|]*scripts/temp-password\.sh' "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md's gates table sends a password reset through scripts/temp-password.sh"
else
  fail "SKILL.md's gates table sends a password reset through scripts/temp-password.sh"
fi

# --- A new database password (release 4.5.6, #109) ---------------------------------------------
# A deployment from a listing version with the rotation has a "Database password" section on its Settings tab, and
# one from an earlier version doesn't (the skills reach both). So the text names both: the Rotate database password
# action where the Settings tab shows it, and Clouve support otherwise.
db_password_both() {
  local file="$SKILL_DIR/$1"
  if grep -qF "admins see Database password on the deployment's Settings tab" "$file" &&
     grep -qF "Otherwise Clouve support can do it for you" "$file"; then
    pass "$1 names the Rotate database password action where it's shown, and Clouve support otherwise"
  else
    fail "$1 names the Rotate database password action where it's shown, and Clouve support otherwise"
  fi
}
db_password_both SKILL.md
db_password_both playbooks/diagnose-500.md
db_password_both reference/configuration.md

echo
if [ "$FAILED" -eq 0 ]; then echo "All moodle channel-text checks passed."; else exit 1; fi
