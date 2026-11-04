#!/usr/bin/env bash
# The wordpress skill describes the SSH channel that the Clouve WordPress images ship (4.5.3, #69).
#
# Since 2026-08-05 both packaged images (wordpress, wordpress-mariadb) ship sshd and the clouve-ops account with
# passwordless sudo, and sshd starts whenever the platform sets CLOUVE_OPS_PASSWORD, which it does on every
# deployment that runs the AI Assistant. learnings.md said so, but about 35 passages elsewhere still said the images
# had no sshd: "Expected result today: failure", "today's WordPress images ship no sshd", "No shell (today's
# reality)". So the assistant expected the SSH probe to fail, planned without wp-cli, and called a DB-only backup the
# normal case. The text dated itself with "today", and that is how it went stale, so this plugin doesn't use the word:
# say which shape a step is for ("on Shape A", "on Shape B") instead.
#
# Fails on any of those stale phrases in a .md or .sh file under plugins/wordpress (install.sh included). Also fails
# unless reference/shell-access.md says both packaged images ship the clouve-ops sshd, that sshd starts when
# CLOUVE_OPS_PASSWORD is set, and gives wp-cli as scripts/wp.sh, saying why (0.1.6: an SSH session doesn't have the
# container's environment, where wp-config.php finds the database settings, so a plain `sudo -u www-data wp ...` over
# SSH stops with "Error establishing a database connection"); when any markdown still runs wp that way; unless the
# 2026-08-05 "Channel reality" entry is gone from learnings.md (its facts now live in the reference files) with the
# "Secrets. Ever." line kept. tests/mysqldump-no-tablespaces.test.sh checks that every wordpress mysqldump, in the
# markdown and in scripts/backup.sh, passes --no-tablespaces.
#
# From the 4.5.3 re-review: fails on text that has the user restart the app, the pod or the container, calls a
# restart the fix, or sends the user to a pod list or a platform dashboard. The user's Clouve dashboard has none of
# these for the app, so the text says what the user can do, what the assistant can do, or to ask Clouve support (N2).
# Fails, too, on text that says a 302 from wp-login.php alone means a password works: WordPress sends that 302 before
# it checks the password when FORCE_SSL_ADMIN is on or a plugin hides wp-login.php (N1).
#
# Run: bash tests/wordpress-channel-text.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN="$ROOT/plugins/wordpress"
SKILL_DIR="$PLUGIN/skills/wordpress"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

mapfile -t files < <(find "$PLUGIN" -type f \( -name '*.md' -o -name '*.sh' \) | sort)
if [ "${#files[@]}" -lt 20 ]; then
  fail "found the wordpress plugin's files (only ${#files[@]}: the scan is broken)"
fi

# stale LABEL REGEX: fails when a line of the plugin matches REGEX (extended, any case).
stale() {
  local hits
  hits="$(grep -nHiE -- "$2" "${files[@]}" || true)"
  if [ -z "$hits" ]; then
    pass "no file says $1"
  else
    fail "no file says $1"
    printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
  fi
}

stale '"today" (the text names the shape instead)' '\btoday\b'
stale 'the SSH probe is expected to fail' 'expect(ed)?[[:space:]]+(\*\*)?failure|expected[[:space:]]+to[[:space:]]+fail|expected result'
stale 'the images ship no sshd or no clouve-ops account' 'ships?[[:space:]]+(\*\*)?(no|neither)\b(\*\*)?[[:space:]]*(sshd|shell|`?clouve-ops|$)|do(es)?[[:space:]]+not[[:space:]]+ship[[:space:]]+(sshd|the[[:space:]]+`?clouve-ops)|no sshd(/|, no)|no sshd and no|not shipped'
stale 'the shell does not exist (here, currently, or only in a future image)' 'does not exist here|hypothetical shell|future (shell|wordpress|image)|for the day (a|the)\b|currently (unreachable|cannot|has[[:space:]]+(\*\*)?no|have[[:space:]]+(\*\*)?no)|can.t currently'
stale 'no shell or file channel exists' 'no shell exists|no shell and no wp-cli|there.s no shell|there is no shell into|no file channel|no live channel'
stale 'the MariaDB image is unpinned' 'unpinned|floats per pull|(tag|version) floats'

# --- The channel the packaged images ship -------------------------------------------

ACCESS="$SKILL_DIR/reference/shell-access.md"
if grep -qiE 'both (packaged |clouve )?(wordpress )?images' "$ACCESS" && grep -qF 'sshd' "$ACCESS"; then
  pass "shell-access.md says both packaged images ship the clouve-ops sshd"
else
  fail "shell-access.md says both packaged images ship the clouve-ops sshd"
fi
if grep -qE 'starts (only )?when `CLOUVE_OPS_PASSWORD` is set' "$ACCESS"; then
  pass "shell-access.md says sshd starts when CLOUVE_OPS_PASSWORD is set, naming it bare"
else
  fail "shell-access.md says sshd starts when CLOUVE_OPS_PASSWORD is set, naming it bare"
fi
if grep -qF 'scripts/wp.sh' "$ACCESS" && grep -qiE 'database settings' "$ACCESS" \
  && grep -qF 'Error establishing a database connection' "$ACCESS"; then
  pass "shell-access.md gives wp-cli as scripts/wp.sh, and why (a plain SSH session has no database settings)"
else
  fail "shell-access.md gives wp-cli as scripts/wp.sh, and why (a plain SSH session has no database settings)"
fi
# wordpress 0.1.6: every ssh and scp command keeps and checks no saved host key, as gibbon's and odoo's do. The
# WordPress images make new host keys when they are rebuilt, and on an agent without the Magneto Agent's sibling SSH
# settings a saved key that no longer matches stops the command. tests/lib/ssh-host-key-check.py puts each command's
# -o options, written on its line, through the real `ssh -G -F /dev/null`.
if ! command -v ssh > /dev/null 2>&1; then
  fail "ssh is installed, to check each command's options with ssh -G"
else
  commands="$(python3 -I "$ROOT/tests/lib/ssh-host-key-check.py" "$ROOT" wordpress)"
  bad="$(grep '^bad ' <<< "$commands" || true)"
  n_cmds="$(grep -c '' <<< "$commands" || true)"
  if [ "$n_cmds" -ge 10 ] && [ -z "$bad" ]; then
    pass "every ssh and scp command passes StrictHostKeyChecking=accept-new and UserKnownHostsFile=/dev/null ($n_cmds commands)"
  else
    fail "every ssh and scp command passes StrictHostKeyChecking=accept-new and UserKnownHostsFile=/dev/null ($n_cmds commands)"
    printf '%s\n' "${bad:-found too few commands, so the scan is broken}" | sed 's/^bad /       /' | cut -c1-200
  fi
fi
# wordpress 0.1.6: wp over SSH without the container's settings can't reach the database, so every wp command in the
# markdown goes through scripts/wp.sh, which loads them (tests/wordpress-wp-runner.test.sh runs it).
mapfile -t md_files < <(printf '%s\n' "${files[@]}" | grep '\.md$')
bare_wp="$(grep -nHE -- '-u www-data wp( |$)|sudo -u www-data wp' "${md_files[@]}" || true)"
if [ -z "$bare_wp" ]; then
  pass "no markdown runs wp over SSH without WordPress's database settings (each wp command goes through scripts/wp.sh)"
else
  fail "no markdown runs wp over SSH without WordPress's database settings (each wp command goes through scripts/wp.sh)"
  printf '%s\n' "$bare_wp" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi
# A wp command in backticks on a line about the shell is one the assistant runs over SSH, so it goes through wp.sh
# too (headings aside).
shell_wp="$(grep -nHE '`wp [a-z]' "${md_files[@]}" | grep -iE 'with (a|the) shell|over (the )?(shell|ssh)|shell-only|or a shell' \
  | grep -vF 'wp.sh' | grep -vE '^[^:]+:[0-9]+:#' || true)"
if [ -z "$shell_wp" ]; then
  pass "no markdown gives a bare wp command to run with the shell (each one is wp.sh)"
else
  fail "no markdown gives a bare wp command to run with the shell (each one is wp.sh)"
  printf '%s\n' "$shell_wp" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi
if grep -qF 'config list' "$ACCESS" && grep -qiE 'refuses?' "$ACCESS"; then
  pass "shell-access.md says wp.sh refuses the commands that would print a password (config list, config get)"
else
  fail "shell-access.md says wp.sh refuses the commands that would print a password (config list, config get)"
fi

LEARN="$SKILL_DIR/learnings.md"
if ! grep -qiE 'Channel reality' "$LEARN" && grep -qF 'Secrets. Ever.' "$LEARN"; then
  pass "learnings.md dropped the 2026-08-05 channel entry and kept its Secrets. Ever. line"
else
  fail "learnings.md dropped the 2026-08-05 channel entry and kept its Secrets. Ever. line"
fi

# --- A new password stays out of the chat (4.5.3 review C1, I2) -------------------------------

# wp-cli reads a --prompt value with PHP's readline(), which echoes it to stdout when stdin is a
# pipe, so `wp user update ... --prompt=user_pass` printed the new password into the chat. A
# password kept in a shell variable is gone by the assistant's next Bash call. The markdown runs
# scripts/temp-password.sh instead (tests/wordpress-temp-password.test.sh runs it); a script that
# uses --prompt sends wp's stdout to /dev/null on the same line.
stale 'a password kept in a shell variable between steps (NEWPASS)' 'NEWPASS'
stale 'a password on wp-cli'"'"'s command line (--user_pass=)' '\-\-user_pass='
md_prompt="$(grep -nHE -- '--prompt=' "${md_files[@]}" || true)"
if [ -z "$md_prompt" ]; then
  pass "no markdown gives a wp --prompt= command (playbooks run scripts/temp-password.sh)"
else
  fail "no markdown gives a wp --prompt= command (playbooks run scripts/temp-password.sh)"
  printf '%s\n' "$md_prompt" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi
sh_prompt="$(grep -nHE -- '--prompt=' $(printf '%s\n' "${files[@]}" | grep '\.sh$') \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE -- '--prompt=[^>]*>[[:space:]]*/dev/null' || true)"
if [ -z "$sh_prompt" ]; then
  pass "every script line that runs wp --prompt= sends wp's stdout to /dev/null"
else
  fail "every script line that runs wp --prompt= sends wp's stdout to /dev/null"
  printf '%s\n' "$sh_prompt" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi
# The playbook's commands, not its prose (re-review N4c): its fenced code runs the script on the
# shell path, with --via-db and with --remove, and writes user_pass nowhere itself.
ROTATE="$SKILL_DIR/playbooks/rotate-admin-credentials.md"
fenced="$(awk '/^[[:space:]]*```/ { fence = !fence; next } fence' "$ROTATE")"
if grep -qE 'scripts/temp-password\.sh -- ' <<< "$fenced" && grep -qE 'scripts/temp-password\.sh --via-db -- ' <<< "$fenced" \
  && grep -qE 'scripts/temp-password\.sh --remove ' <<< "$fenced" \
  && ! grep -qiE 'update[^;]*user_pass|set[[:space:]]+user_pass|md5\(' <<< "$fenced"; then
  pass "rotate-admin-credentials.md's commands run scripts/temp-password.sh (shell, --via-db, --remove) and write user_pass nowhere else"
else
  fail "rotate-admin-credentials.md's commands run scripts/temp-password.sh (shell, --via-db, --remove) and write user_pass nowhere else"
fi

# What a 302 from the sign-in check proves (4.5.3 re-review N1): nothing on its own.
# tests/wordpress-temp-password.test.sh runs the check; this keeps the text from saying otherwise.
stale 'that a 302 from wp-login.php alone means the password works' \
  'accepted it at sign-in \(HTTP 302\)|302[^.]*\bmeans\b[^.]*(works|took|accepted)'

# --- No restart, container list or container log the user doesn't have (4.5.3 re-review N2) ----

stale 'that the user restarts the app, the pod or the container, or that a restart is the fix' \
  'restart (the|their|your) (app|application|pod|container)\b|restart of the (app|application|pod|container)|restart is (the|a valid) fix|kubectl rollout|restart[^.]*clouve ui'
stale 'that the user has a pod list or a platform dashboard to check' 'pod[- ]?list|platform dashboards?'

echo
if [ "$FAILED" -eq 0 ]; then echo "All wordpress channel-text checks passed."; else exit 1; fi
