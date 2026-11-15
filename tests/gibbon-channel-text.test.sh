#!/usr/bin/env bash
# The gibbon skill knows it can work inside the gibbon container (#39's stale lines,
# release 4.5.3, 2026-11-02).
#
# Both gibbon images ship the clouve-ops sshd with passwordless sudo, and the skill's
# reference/shell-access.md documents the channel. Older passages, written before
# that, still told the assistant it couldn't write into the gibbon container, that a
# shell there needed `kubectl exec` or `docker exec`, that it couldn't read config.php
# or the cron log, and that files had to go to Clouve ops. An assistant that believes
# them plans around a channel it has: it backs up the database alone, asks ops to
# copy a module in, or sends the user off to run commands.
#
# Fails on those claims anywhere in plugins/gibbon (markdown and scripts; scripts/tests/
# skipped), and checks that the backup, restore and module-install texts give the
# clouve-ops command.
#
# Every ssh and scp command keeps and checks no saved host key (4.5.3 review, lens 3
# I1). On an agent older than 4.5.3's image, which has no SSH settings for its sibling
# containers, a host key that is new to it stops at a yes/no prompt that sshpass can't
# answer: sshpass exits 6 and prints nothing, so a backup's files archive came out empty
# and a restore or module install did nothing, without a word. And a key saved from one
# image is wrong after a rebuild. So every command passes
# `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null`, as the odoo
# skill's do: tests/lib/ssh-host-key-check.py runs each command's options through the
# real `ssh -G -F /dev/null`, which connects to nothing. Fails too on text that says to
# accept a key interactively or that relies on a saved one.
#
# config.php holds the database password (4.5.3 review, lens 1 M2 and M4). `php -l`
# names the token it stopped at, which can be part of a broken password line, so every
# `php -l` of config.php keeps its output to pass or fail and a line number, and nothing
# diffs config.php. A full restore asks before it overwrites anything: its
# confirmation, which compares config.php by sha256sum, comes before the files are
# unpacked, and SKILL.md's gates table has a row for it.
#
# The user's Clouve dashboard has no restart button, no container list and no log view
# for the app (4.5.3 re-review N2 and N3; widened in 4.5.5 to "restart pod", "pod restart"
# and "the `gibbon` container"). Fails on text that has the user restart the
# app, the pod or the container, calls a restart the fix, or sends the user to a pod
# list or a platform dashboard: the text says what the user can do in Gibbon, what the
# assistant can do over its channels, or to ask Clouve support.
#
# Run: bash tests/gibbon-channel-text.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN="$ROOT/plugins/gibbon"
SKILL_DIR="$PLUGIN/skills/gibbon"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# stale LABEL [-i] REGEX: no gibbon file matches REGEX (extended; -i ignores case).
stale() {
  local label="$1" opt="" hits
  shift
  if [ "$1" = "-i" ]; then opt="-i"; shift; fi
  hits="$(grep -rnE $opt --include='*.md' --include='*.sh' --exclude-dir=tests -- "$1" "$PLUGIN" || true)"
  if [ -z "$hits" ]; then
    pass "$label"
  else
    fail "$label"
    printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /"
  fi
}

stale "no line says the assistant can't write into the gibbon container" \
  -i "(you|we|agent|ai studio)[*[:space:]]+(cannot|can't|can not)[*[:space:]]+(write|tar)"
stale "no line says writing there is an ops-only job" \
  -i "not from magneto agent|from magneto agent you (cannot|can't)|you can't write to that volume"
stale "no line says the assistant has no shell or no view of the gibbon container's files" \
  -i "don't have a shell|no filesystem view|not directly read files|do not attempt to shell into"
stale "no line sends anyone to kubectl exec, kubectl cp or docker exec for the gibbon container" \
  -i "kubectl (exec|cp)|docker exec"
stale "no line says the assistant can't read config.php, the cron log or cron's status" \
  -i "can't read[^.]{0,60}config\.php|can't read that file|can't check this directly|we cannot (see|run|read)|we can't see"
stale "no line hands an in-container command to the user or Clouve ops instead" \
  -i "the user or clouve ops runs this|ask the tenant or ops (to|for)|requires tenant / ops inspection|via the file browser"
stale "no gibbon file still says AI Studio for the agent's side" \
  "(from|in) AI Studio"
stale "no line has the user restart the app, the pod or the container, or calls a restart the fix" \
  -i "restart (the|their|your) (\`[^\`]+\` )?(app|application|pod|container)\b|restart of the (app|application|pod|container)|restart is (the|a valid) fix|kubectl rollout|restart[^.]*clouve ui|restart (the )?pod\b|pod restart (is|to)\b|\+ pod restart|on pod restart"
stale "no line sends the user to a pod list or a platform dashboard" \
  -i "pod[- ]?list|platform dashboards?"

# The database password (gibbon 0.1.5, release 4.5.5, M2). update-config.sh writes config.php's database lines from
# the deployment's settings at every start, and nothing lets the customer change those settings: a password changed in
# MySQL alone breaks Gibbon at the next start, and one changed in config.php is undone. So no line offers a rotation
# through the environment, a Clouve control or a restart; the text sends it to Clouve support.
stale "no line offers a database password rotation through the environment, a Clouve control or a restart" \
  -i "prefer (the |that )?env[- ]|env(-var)?-driven (sync |config )?(path|pattern)|via env vars|env injection on pod restart|rotate the secret|rotated clouve secret|via a kubernetes secret|clouve platform ui"
# The containers have no systemd (M3): mysqld is started by the image's entrypoint, so systemctl finds nothing.
stale "no systemctl command (the containers have no systemd)" "systemctl [a-z]"

# has LABEL FILE: FILE gives an `sshpass -e ssh` command to clouve-ops@${GIBBON_HOST}.
has() {
  local label="$1" file="$2"
  if grep -qE 'sshpass -e ssh .*clouve-ops@\$\{GIBBON_HOST\}' "$SKILL_DIR/$file"; then pass "$label"; else fail "$label"; fi
}
has "reference/backup-restore.md archives the files over the clouve-ops channel" reference/backup-restore.md
has "playbooks/rollback-from-backup.md restores the files over the clouve-ops channel" playbooks/rollback-from-backup.md
has "playbooks/install-module.md places the module over the clouve-ops channel" playbooks/install-module.md

# --- SSH host keys ----------------------------------------------------------------------

# From the 4.5.5 images on, every container makes new host keys at each start (N6), not only after a rebuild.
stale "no line says the host keys change only when an image is rebuilt" -i "image's whenever it is rebuilt"
stale "no line says to accept a host key interactively, or relies on a saved one" \
  -i "accept it interactively|key is captured|first ssh to each host|first connection|known[-_ ]?hosts?[[:space:]]+entry|subsequent connections are silent"

if ! command -v ssh >/dev/null 2>&1; then
  fail "ssh is installed, to check each command's options with ssh -G"
else
  commands="$(python3 -I "$ROOT/tests/lib/ssh-host-key-check.py" "$ROOT" gibbon)"
  bad="$(grep '^bad ' <<< "$commands" || true)"
  ok="$(grep -c '^ok ' <<< "$commands" || true)"
  if [ "$ok" -lt 10 ] && [ -z "$bad" ]; then
    fail "every ssh and scp command keeps no host key (found only $ok commands: the scan is broken)"
  elif [ -z "$bad" ]; then
    pass "every ssh and scp command keeps no host key, even on an agent without the sibling SSH settings ($ok checked)"
  else
    fail "every ssh and scp command keeps no host key, even on an agent without the sibling SSH settings"
    printf '%s\n' "$bad" | sed 's/^bad /       /' | cut -c1-200
  fi
fi

# --- config.php holds the database password ------------------------------------------

# Each ;-separated part of a line that runs php -l on config.php sends the output to /dev/null
# or keeps only the line number, after the php -l: on a one-line ssh command, the ssh option
# UserKnownHostsFile=/dev/null comes before it and doesn't count.
lint="$(grep -rnE --include='*.md' --include='*.sh' --exclude-dir=tests 'php -l[^;|&]*config\.php' "$PLUGIN" \
  | awk -F';' '{ for (i = 1; i <= NF; i++) if ($i ~ /php -l[^|&]*config\.php/ && substr($i, index($i, "php -l")) !~ /\/dev\/null|grep -o/) { print; break } }' || true)"
if [ -z "$lint" ]; then
  pass "every php -l of config.php shows only pass or fail and a line number"
else
  fail "every php -l of config.php shows only pass or fail and a line number"
  printf '%s\n' "$lint" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi
stale "nothing diffs config.php (it would print the database password)" -i "\bdiff\b[^|;.]*config\.php"

ROLLBACK="$SKILL_DIR/playbooks/rollback-from-backup.md"
unpack="$(grep -n -m1 -F 'tar -C /var/www/html -xzf' "$ROLLBACK" | cut -d: -f1)"
confirm="$(grep -n -m1 -F 'sha256sum' "$ROLLBACK" | cut -d: -f1)"
if [ -n "$unpack" ] && [ -n "$confirm" ] && [ "$confirm" -lt "$unpack" ]; then
  pass "a full restore confirms, comparing config.php by sha256sum, before it unpacks any file"
else
  fail "a full restore confirms, comparing config.php by sha256sum, before it unpacks any file (confirm: ${confirm:-none}, unpack: ${unpack:-none})"
fi
if grep -qE '^\| *Restore' "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md's gates table has a row for a restore from backup"
else
  fail "SKILL.md's gates table has a row for a restore from backup"
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
db_password_both playbooks/rotate-admin-credentials.md
db_password_both reference/security.md

echo
if [ "$FAILED" -eq 0 ]; then echo "All gibbon channel-text checks passed."; else exit 1; fi
