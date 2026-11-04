#!/usr/bin/env bash
# Moodle skill: scripts/backup.sh dumps the database without the PROCESS privilege
# (#64, release 4.5.3, 2026-11-02).
#
# The agent's mysqldump is Oracle MySQL 8.0 (Ubuntu 24.04's default-mysql-client).
# Unless it gets --no-tablespaces, it asks the server for tablespace information,
# which needs the PROCESS privilege, and the moodle database user doesn't have it.
# Every backup printed "Access denied; you need (at least one of) the PROCESS
# privilege(s) for this operation". Moodle creates no general tablespaces, so the
# flag costs the dump nothing.
#
# Runs backup.sh against fakes and fails when:
#   - the script doesn't finish with a database dump and a dataroot archive;
#   - mysqldump doesn't get --no-tablespaces;
#   - the database password reaches mysqldump's command line (where ps shows it);
#   - mysqldump doesn't get the password in MYSQL_PWD.
#
# Fakes, first on PATH: mysqldump records its arguments and whether MYSQL_PWD
# held the test's password, then prints a small dump; sshpass records its call
# and prints a few bytes for the dataroot archive; clv-secret fails, because the
# test sets every password. No MySQL, network or ssh. The passwords are made up.
#
# Run: bash tests/moodle-backup-script.test.sh   (exit 0 = all pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
script="$ROOT/plugins/moodle/skills/moodle/scripts/backup.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/moodle-backup-script-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

bin="$work/bin"
mkdir -p "$bin" "$work/home"

cat > "$bin/mysqldump" <<'FAKE'
#!/bin/bash
printf 'mysqldump %s\n' "$*" >> "$FAKE_CALLS"
if [ "${MYSQL_PWD:-}" = "$FAKE_DB_PASSWORD" ]; then
  echo "mysqldump MYSQL_PWD=the-db-password" >> "$FAKE_CALLS"
fi
printf '%s\n' \
  '-- MySQL dump 10.13  Distrib 8.0.46, for Linux (x86_64)' \
  'CREATE TABLE `mdl_config` (' \
  '  `id` bigint NOT NULL' \
  ') ENGINE=InnoDB;' \
  '-- Dump completed on 2026-11-02 12:00:00'
FAKE

cat > "$bin/sshpass" <<'FAKE'
#!/bin/bash
printf 'sshpass %s\n' "$*" >> "$FAKE_CALLS"
printf 'fake dataroot archive\n'
FAKE

cat > "$bin/clv-secret" <<'FAKE'
#!/bin/bash
echo "fake clv-secret: the test sets every password, so this must not run ($*)" >&2
exit 2
FAKE
chmod +x "$bin"/*

calls="$work/calls"
: > "$calls"
out="$(env -i \
  HOME="$work/home" \
  PATH="$bin:/usr/bin:/bin" \
  FAKE_CALLS="$calls" \
  FAKE_DB_PASSWORD=not-a-real-db-password \
  MOODLE_HOST=moodle.test \
  MOODLE_DB_HOST=moodle-mysql.test \
  MOODLE_DB_USER=moodle \
  MOODLE_DB_PASSWORD=not-a-real-db-password \
  MOODLE_DB_NAME=moodle \
  CLOUVE_OPS_PASSWORD=not-a-real-ops-password \
  "$BASH" "$script" 2>&1)"
rc=$?

dump="$(find "$work/home/backups" -name db.sql.gz 2>/dev/null | head -n 1)"
archive="$(find "$work/home/backups" -name moodledata.tar.gz 2>/dev/null | head -n 1)"
if [ "$rc" -eq 0 ] && [ -s "$dump" ] && [ -s "$archive" ] \
  && gzip -dc "$dump" | grep -q '^CREATE TABLE `mdl_config`'; then
  pass "backup.sh exits 0 with a database dump and a dataroot archive"
else
  fail "backup.sh exits 0 with a database dump and a dataroot archive (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/       | /'
fi

dump_call="$(grep -E '^mysqldump -' "$calls" || true)"
if [ -n "$dump_call" ] && grep -qE '(^| )--no-tablespaces( |$)' <<< "$dump_call"; then
  pass "mysqldump gets --no-tablespaces, so the moodle user needs no PROCESS privilege"
else
  fail "mysqldump gets --no-tablespaces, so the moodle user needs no PROCESS privilege"
  printf '       calls: %s\n' "${dump_call:-(mysqldump never ran)}"
fi

if [ -n "$dump_call" ] && ! grep -qF 'not-a-real-db-password' <<< "$dump_call"; then
  pass "the database password stays off mysqldump's command line"
else
  fail "the database password stays off mysqldump's command line"
fi

if grep -qx 'mysqldump MYSQL_PWD=the-db-password' "$calls"; then
  pass "mysqldump gets the password in MYSQL_PWD"
else
  fail "mysqldump gets the password in MYSQL_PWD"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All moodle backup-script checks passed."; else exit 1; fi
