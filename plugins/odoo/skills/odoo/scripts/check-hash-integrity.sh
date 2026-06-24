#!/usr/bin/env bash
# Run Odoo's own accounting hash-integrity check to detect SQL-tampered or
# corrupted journal entry chains. Read-only. Usage: check-hash-integrity.sh [db]
#
# _check_hash_integrity() (company.py:994) returns a dict:
#   {'results': [{'status': 'verified'|'corrupted'|'no_data', 'msg_cover': ...,
#                 'journal_name': ..., 'restricted_by_hash_table': ...}, ...]}
# It does NOT raise on corruption — status is 'corrupted'. This script iterates
# the results, prints each journal's status, and exits non-zero if any are corrupted.
set -euo pipefail

DB="${1:-${ODOO_DB_NAME:?set ODOO_DB_NAME or pass the db as arg 1}}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"
export SSHPASS="$CLOUVE_OPS_PASSWORD"

echo "[odoo/hash-check] res.company._check_hash_integrity() on ${DB}"
sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}" \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d '${DB}' --stop-after-init" <<'PY'
import sys

companies = env['res.company'].search([])
any_corrupted = False

for c in companies:
    result = c._check_hash_integrity()
    for entry in result.get('results', []):
        journal = entry.get('journal_name', '?')
        status = entry.get('status', '?')
        msg = entry.get('msg_cover', '')
        print(f"company {c.id} {c.name!r}  journal={journal!r}  status={status}  msg={msg!r}")
        if status == 'corrupted':
            any_corrupted = True

if any_corrupted:
    print("RESULT: CORRUPTED — one or more journal chains are broken. Restore from a pre-corruption backup.")
    sys.exit(1)
else:
    print("RESULT: OK — no corrupted chains detected.")
PY
echo "[odoo/hash-check] done."
