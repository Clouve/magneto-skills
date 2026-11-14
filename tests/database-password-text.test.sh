#!/usr/bin/env bash
# What each skill says about a new database password (release 4.5.6, #109; the design review's I4).
#
# A deployment installed from a listing version that declares the rotation has a "Database password" section on its
# Settings tab in Clouve, which only the organization's admins (and Clouve support) see, and where they press Rotate
# database password; one from an earlier version doesn't, and Clouve support does it. A skill reaches every running AI
# Assistant whatever its listing version and whoever is asking, so its text names both, in these words: "admins see
# Database password on the deployment's Settings tab" and "Otherwise Clouve support can do it for you". The gibbon,
# moodle, odoo and wordpress channel-text tests check their own files; this one checks suitecrm, limesurvey and
# nextcloud, that the skills which forbid it still say never to ALTER USER the database user, and that no skill still
# says the password is Clouve support's alone or tells a client user to look for a section only admins see.
#
# Run: bash tests/database-password-text.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

both() {
  local file="$ROOT/plugins/$1"
  if grep -qF "admins see Database password on the deployment's Settings tab" "$file" &&
     grep -qF "Otherwise Clouve support can do it for you" "$file"; then
    pass "$1 names the Rotate database password action where it's shown, and Clouve support otherwise"
  else
    fail "$1 names the Rotate database password action where it's shown, and Clouve support otherwise"
  fi
}

both suitecrm/skills/suitecrm/reference/customer-kit.md
both suitecrm/skills/suitecrm/playbooks/customer-kit-limesurvey-link.md
both limesurvey/skills/limesurvey/reference/stack-and-runtime.md
both nextcloud/skills/nextcloud/reference/security.md

# Never ALTER USER the database user: the action changes it, and a change by hand leaves the deployment's settings behind.
never_alter_user() {
  if grep -qiE '(do not|never) `?ALTER USER`?' "$ROOT/plugins/$1"; then
    pass "$1 still says never to ALTER USER the database user"
  else
    fail "$1 still says never to ALTER USER the database user"
  fi
}
never_alter_user gibbon/skills/gibbon/SKILL.md
never_alter_user gibbon/skills/gibbon/playbooks/rotate-admin-credentials.md
never_alter_user moodle/skills/moodle/SKILL.md
never_alter_user nextcloud/skills/nextcloud/reference/security.md

# 4.5.5's M2 wording, which sent every database password change to Clouve support alone ("Rotating the database
# password is a Clouve support request", "Only Clouve support rotates it"), and 4.5.6's first wording, which told a
# client user to look at a Settings tab section that only admins see.
STALE="Clouve support only|Clouve support's to rotate|Rotate DB credentials \| Not from here, and the customer has no control"
STALE="$STALE|database password is a Clouve support request|only Clouve support rotates|only Clouve support can change|Settings tab in Clouve shows Database password"
hits="$(grep -rniE --include='*.md' "$STALE" "$ROOT/plugins" || true)"
if [ -z "$hits" ]; then
  pass "no skill says the database password is Clouve support's alone"
else
  fail "no skill says the database password is Clouve support's alone"
  printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All database password text checks passed."; else exit 1; fi
