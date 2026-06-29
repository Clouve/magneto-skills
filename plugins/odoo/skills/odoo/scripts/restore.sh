#!/usr/bin/env bash
# Restore/clone an Odoo DB from a filestore-aware zip via `odoo db load`.
# Defaults to a NEUTRALIZED load and refuses to clobber the live DB.
# Usage: restore.sh <target-db> <backup.zip-on-odoo-host> [--prod]
set -euo pipefail

DB="${1:?usage: restore.sh <target-db> <backup.zip> [--prod]}"
ZIP="${2:?usage: restore.sh <target-db> <backup.zip> [--prod]}"
ALLOW_PROD="${3:-}"
: "${ODOO_HOST:?ODOO_HOST not set}" "${CLOUVE_OPS_PASSWORD:?CLOUVE_OPS_PASSWORD not set}"

if [ "${DB}" = "${ODOO_DB_NAME:-}" ] && [ "${ALLOW_PROD}" != "--prod" ]; then
  echo "[odoo/restore] refusing to restore over the live DB '${DB}' without --prod" >&2
  echo "[odoo/restore] restore into a new name (e.g. ${DB}-staging) for a safe clone." >&2
  exit 1
fi

export SSHPASS="$CLOUVE_OPS_PASSWORD"
SSH=(sshpass -e ssh -o StrictHostKeyChecking=accept-new "clouve-ops@${ODOO_HOST}")

NEUTRALIZE="-n"
[ "${ALLOW_PROD}" = "--prod" ] && NEUTRALIZE=""   # a real prod restore is NOT neutralized

echo "[odoo/restore] loading ${ZIP} -> ${DB} ${NEUTRALIZE:+(neutralized)}"
# `-c` goes between `db` and `load` (parent-parser option of the `db` command);
# positional order is `load [database] <dump_file>` (db_name then dump path).
"${SSH[@]}" "sudo odoo db -c /etc/odoo/odoo.conf load ${NEUTRALIZE} '${DB}' '${ZIP}'"

if [ -n "${NEUTRALIZE}" ]; then
  echo "[odoo/restore] confirming database.is_neutralized ..."
  "${SSH[@]}" "sudo odoo shell -c /etc/odoo/odoo.conf -d '${DB}' --stop-after-init <<'PY'
print('is_neutralized =', env['ir.config_parameter'].sudo().get_param('database.is_neutralized'))
PY"
fi
echo "[odoo/restore] done."
