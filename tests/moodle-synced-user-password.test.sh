#!/usr/bin/env bash
# A password the assistant sets for a Gibbon-synced Moodle user must survive Moodle's next cron run (2026-10-20).
#
# The External Database sync (auth_db, passtype=internal) tags every user it creates with the create_password
# preference (public/auth/db/auth.php). Moodle's "Send new user passwords" task then replaces that user's password
# with a random one and emails it, at the next cron run (every minute on Clouve). On the rig the assistant set
# Maya Patel's password 24 s after the sync, showed it once, and 40 s later the task replaced it: the password it
# handed over no longer worked.
#
# Fails when a moodle skill file sets a password with update_internal_user_password() without also clearing
# create_password, or when SKILL.md doesn't warn about it.
#
# Run: bash tests/moodle-synced-user-password.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILL_DIR="$ROOT/plugins/moodle/skills/moodle"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

missing=""
while IFS= read -r f; do
  grep -q "unset_user_preference('create_password'" "$f" || missing+="  ${f#"$ROOT"/}"$'\n'
done < <(grep -rl 'update_internal_user_password' "$SKILL_DIR" --include='*.md' --include='*.sh' --include='*.php' || true)
if [ -z "$missing" ]; then
  pass "every file that sets a password with update_internal_user_password also clears create_password"
else
  fail "every file that sets a password with update_internal_user_password also clears create_password"
  printf '%s' "$missing"
fi

if grep -q 'create_password' "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md warns that the sync's create_password replaces a password at the next cron run"
else
  fail "SKILL.md warns that the sync's create_password replaces a password at the next cron run"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All synced-user password checks passed."; else exit 1; fi
