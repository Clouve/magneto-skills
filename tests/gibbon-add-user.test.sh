#!/usr/bin/env bash
# The gibbon skill has an "add a user" playbook, and it starts with Gibbon's own form
# (#39, release 4.5.3, 2026-11-02).
#
# On the Education Kit shoot the assistant had no playbook for adding a person, so it
# wrote a raw gibbonPerson insert: about 50 NOT NULL columns set to '', a password hash
# made by hand and a status-log row guessed from the schema. Gibbon's own form (User
# Admin, Manage Users, Add) fills every column, hashes the password and writes the
# log itself. A SQL path ships only once it has been checked against Gibbon 30's own
# add script, which this release couldn't read, so the playbook has none.
#
# Fails when:
#   - playbooks/add-a-user.md is missing, or SKILL.md or reference/README.md doesn't
#     link it;
#   - the playbook's first path isn't Gibbon's form;
#   - the playbook writes to gibbonPerson or sets a password hash (an unchecked SQL path);
#   - a SQL write in the playbook comes before its backup step;
#   - a mysql command gets the password any way but MYSQL_PWD in the two-part form;
#   - the playbook doesn't keep passwords out of the chat;
#   - it doesn't tell an Education Kit admin that Moodle's sync is off there, with a
#     pointer to the moodle skill.
#
# And, from the 4.5.3 reviews:
#   - a username typed by the admin goes into SQL as a quoted string, where a quote,
#     a backslash or a `;` in it could change the query: it goes in as a hex literal
#     (CONVERT(X'...' USING utf8mb3));
#   - a write to gibbonPerson spread over two lines of a code block (INSERT INTO on one,
#     the table on the next; UPDATE gibbonPerson, then SET) slips past: each code
#     block's lines are joined before the scan, and the backup step is a fenced
#     invocation of scripts/backup.sh, not a link in the prose;
#   - the Education Kit section sends the new person's Moodle password through a flow
#     that makes the assistant generate and pass on a password (the moodle skill's
#     rotate-admin-credentials playbook or its principle 12), says that Moodle replaces a
#     password set "any other way", or doesn't say that only students and staff with
#     status Full get a Moodle account (never a parent);
#   - the Education Kit section loses its "Never set, ask for or show" sentence about the
#     Moodle password, or has the assistant make a password (openssl rand, pwgen,
#     /dev/urandom, "generate") or say what one is (re-review N4b);
#   - the playbook says a SQL path is still to come.
#
# Run: bash tests/gibbon-add-user.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILL_DIR="$ROOT/plugins/gibbon/skills/gibbon"
PLAYBOOK="$SKILL_DIR/playbooks/add-a-user.md"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

if [ ! -f "$PLAYBOOK" ]; then
  fail "playbooks/add-a-user.md exists"
  echo
  exit 1
fi
pass "playbooks/add-a-user.md exists"

if grep -qF '](playbooks/add-a-user.md)' "$SKILL_DIR/SKILL.md"; then
  pass "SKILL.md links the playbook"
else
  fail "SKILL.md links the playbook"
fi
if grep -qF '](../playbooks/add-a-user.md)' "$SKILL_DIR/reference/README.md"; then
  pass "reference/README.md links the playbook"
else
  fail "reference/README.md links the playbook"
fi

first_path="$(grep -m1 -E '^## Path' "$PLAYBOOK" || true)"
if [ -n "$first_path" ] && grep -qi 'form' <<< "$first_path"; then
  pass "the first path is Gibbon's own form ($first_path)"
else
  fail "the first path is Gibbon's own form (first path heading: ${first_path:-none})"
fi

# code_blocks: each fenced code block of the playbook on one line, as "<first line>: <text>", with
# the block's lines joined by spaces. Only code counts: the prose may warn against an insert.
code_blocks() {
  awk '/^[[:space:]]*```/ {
         if (fence && text != "") print start ": " text
         fence = !fence; text = ""; next
       }
       fence { if (text == "") start = NR; text = text " " $0 }' "$PLAYBOOK"
}

unchecked="$(code_blocks | awk '{ t = tolower($0) }
  t ~ /(insert|replace)[[:space:]]+(into[[:space:]]+)?`?gibbonperson`?([[:space:](]|$)|update[[:space:]]+`?gibbonperson`?([[:space:]]|$)|passwordstrong/ { print }')"
if [ -z "$unchecked" ]; then
  pass "no unchecked SQL path: nothing writes to gibbonPerson or sets a password hash"
else
  fail "no unchecked SQL path: nothing writes to gibbonPerson or sets a password hash"
  printf '%s\n' "$unchecked" | cut -c1-200 | sed 's/^/       /'
fi

# SQL writes in code blocks, by the block's first line; the backup step is the first code
# block that runs scripts/backup.sh (a link to it in the prose doesn't count).
writes="$(code_blocks | awk 'toupper($0) ~ /(^|[^A-Z_])(INSERT|UPDATE|DELETE|REPLACE|ALTER|DROP|TRUNCATE|CREATE)[[:space:]]/ { print $1 + 0 }')"
backup_line="$(code_blocks | awk -F': ' 'index($0, "scripts/backup.sh") { print $1 + 0; exit }')"
early=""
for n in $writes; do
  if [ -z "$backup_line" ] || [ "$n" -lt "$backup_line" ]; then early+=" $n"; fi
done
if [ -z "$early" ]; then
  pass "every SQL write comes after the backup step ($(wc -w <<< "$writes") writes)"
else
  fail "every SQL write comes after the backup step (lines:$early)"
fi

mysql_lines="$(grep -nE '(^|[[:space:]])mysql[[:space:]]' "$PLAYBOOK" || true)"
bad_pwd="$(grep -vF 'MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql' <<< "$mysql_lines" | grep -E '^[0-9]+:[[:space:]]*(MYSQL_PWD|mysql)' || true)"
argv_pwd="$(grep -nE 'mysql[^|]*[[:space:]](-p[^[:space:]]|--password)' "$PLAYBOOK" || true)"
if [ -n "$mysql_lines" ] && [ -z "$bad_pwd" ] && [ -z "$argv_pwd" ]; then
  pass "each mysql command gets the password in MYSQL_PWD, in the two-part form"
else
  fail "each mysql command gets the password in MYSQL_PWD, in the two-part form"
  printf '%s\n' "${bad_pwd}${argv_pwd}" | sed '/^$/d; s/^/       /'
fi

if grep -qiE "password[^.]*(never|not|isn't)[^.]*chat|chat[^.]*(never|not)[^.]*password" "$PLAYBOOK"; then
  pass "the playbook keeps passwords out of the chat"
else
  fail "the playbook keeps passwords out of the chat"
fi

if grep -qF 'Education Kit' "$PLAYBOOK" && grep -qiE 'moodle skill|plugins/moodle' "$PLAYBOOK" \
  && grep -qiE 'sync' "$PLAYBOOK"; then
  pass "the playbook tells an Education Kit admin about Moodle's sync and points to the moodle skill"
else
  fail "the playbook tells an Education Kit admin about Moodle's sync and points to the moodle skill"
fi

# A username the admin typed reaches SQL only as a hex literal.
quoted="$(code_blocks | grep -iE "username[[:space:]]*(=|like)[[:space:]]*'" || true)"
hexed="$(code_blocks | grep -cE "username[[:space:]]*=[[:space:]]*CONVERT\(X'" || true)"
if [ -z "$quoted" ] && [ "$hexed" -ge 2 ]; then
  pass "a typed username reaches SQL only as a hex literal ($hexed queries)"
else
  fail "a typed username reaches SQL only as a hex literal (hex: $hexed)"
  printf '%s\n' "$quoted" | cut -c1-200 | sed '/^$/d; s/^/       /'
fi

# The Education Kit section, from its heading to the next one.
kit="$(awk '/^## / { inkit = ($0 ~ /Education Kit/) } inkit' "$PLAYBOOK")"
if grep -qiE 'rotate-admin-credentials|principle 12|set it the way' <<< "$kit"; then
  fail "the Education Kit section doesn't hand the Moodle password to a flow that makes the assistant set one"
else
  pass "the Education Kit section doesn't hand the Moodle password to a flow that makes the assistant set one"
fi
if grep -qiE 'any other way' <<< "$kit"; then
  fail "the Education Kit section doesn't claim Moodle replaces a password set any other way"
else
  pass "the Education Kit section doesn't claim Moodle replaces a password set any other way"
fi
if grep -qiE "never set, ask for or show[^.]*moodle password" <<< "$kit"; then
  pass "the Education Kit section says never to set, ask for or show the new person's Moodle password"
else
  fail "the Education Kit section says never to set, ask for or show the new person's Moodle password"
fi
made="$(grep -oiE "openssl[[:space:]]+rand|pwgen|/dev/urandom|\bgenerat(e|es|ed|ing)\b[^.]*password|what (it|the password) is" <<< "$kit" || true)"
if [ -z "$made" ]; then
  pass "the Education Kit section never has the assistant make a password or say what one is"
else
  fail "the Education Kit section never has the assistant make a password or say what one is"
  printf '%s\n' "$made" | sed 's/^/       /'
fi
if grep -qF 'Full' <<< "$kit" && grep -qiE 'parent' <<< "$kit" && grep -qiE 'Expected' <<< "$kit"; then
  pass "the Education Kit section says only Full students and staff get Moodle (parents never; Expected once Full)"
else
  fail "the Education Kit section says only Full students and staff get Moodle (parents never; Expected once Full)"
fi

if grep -qiE "hasn't been done yet|ships only after" "$PLAYBOOK"; then
  fail "the playbook doesn't say a SQL path is still to come"
else
  pass "the playbook doesn't say a SQL path is still to come"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All gibbon add-a-user checks passed."; else exit 1; fi
