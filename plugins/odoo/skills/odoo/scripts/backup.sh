#!/usr/bin/env bash
# Filestore-aware Odoo backup. Runs `odoo db dump` INSIDE the odoo app container
# (over the clouve-ops SSH channel) so the resulting ZIP carries dump.sql +
# filestore/ + manifest.json — a hand-rolled pg_dump would lose the filestore.
# Usage: backup.sh [db] [out-path-on-odoo-host]
set -euo pipefail

DB="${1:-${ODOO_DB_NAME:?set ODOO_DB_NAME or pass the db as arg 1}}"
TS="$(date +%Y-%m-%d-%H-%M-%S)"
OUT="${2:-/var/lib/odoo/backups/${DB}-${TS}.zip}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"
export SSHPASS="$CLOUVE_OPS_PASSWORD"
SSH=(sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}")

echo "[odoo/backup] ${DB} -> ${ODOO_HOST}:${OUT} (DB + filestore + manifest)"
# NOTE: `-c` is a parent-parser option of the `db` command, so it goes BETWEEN
# `db` and the `dump` subcommand. `odoo -c ... db dump` would be misparsed as the
# default `server` command (command.py treats a leading `-` as "no command").
"${SSH[@]}" "sudo mkdir -p '$(dirname "${OUT}")' && sudo odoo db -c /etc/odoo/odoo.conf dump '${DB}' '${OUT}'"

echo "[odoo/backup] verifying the archive contains a filestore + manifest ..."
"${SSH[@]}" "sudo python3 - '${OUT}' <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert any(n == 'dump.sql' for n in names), 'missing dump.sql'
assert any(n == 'manifest.json' for n in names), 'missing manifest.json'
assert any(n.startswith('filestore/') for n in names), 'missing filestore/ (attachments would be lost!)'
print('[odoo/backup] OK: dump.sql + manifest.json + filestore/ present')
PY"

echo "[odoo/backup] done: ${ODOO_HOST}:${OUT}  (copy it off the pod to retain it)"
