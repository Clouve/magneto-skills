#!/usr/bin/env bash
# Run Odoo's own accounting hash-integrity check to detect SQL-tampered or
# corrupted journal entry chains. Read-only. Usage: check-hash-integrity.sh [db]
set -euo pipefail

DB="${1:-${ODOO_DB_NAME:?set ODOO_DB_NAME or pass the db as arg 1}}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"
export SSHPASS="$CLOUVE_OPS_PASSWORD"

echo "[odoo/hash-check] res.company._check_hash_integrity() on ${DB}"
sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}" \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d '${DB}' --stop-after-init" <<'PY'
companies = env['res.company'].search([])
for c in companies:
    try:
        c._check_hash_integrity()
        print(f"company {c.id} {c.name!r}: integrity check ran (review the report for any non-compliant journal)")
    except Exception as e:
        # UserError when hashing isn't enabled is benign; other errors are not
        print(f"company {c.id} {c.name!r}: {type(e).__name__}: {e}")
PY
echo "[odoo/hash-check] done — investigate any journal flagged non-compliant (a broken/edited chain)."
