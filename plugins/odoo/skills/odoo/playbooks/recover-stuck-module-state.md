# Playbook: Recover a Stuck Module State

Use when a module operation (install, upgrade, or uninstall) was interrupted and one or more modules are stuck in `to install`, `to upgrade`, or `to remove`. A stuck state causes `ir.cron` to stop running all jobs for the database.

See [reference/module-lifecycle.md](../reference/module-lifecycle.md#stuck-states-recovery) for the source-code basis.

## Symptoms

- Scheduled jobs are not running (crons are idle).
- A module shows `to upgrade` or `to install` in Settings → Apps, but the upgrade/install never completed.
- The Odoo log shows `base.partially_updated_database` warnings.
- A partial upgrade was interrupted by a crash, kill signal, or timeout.

## Step 1: Confirm the stuck state

Check which modules are in a transitional state:

```bash
# Query via TCP psql from the agent environment:
PGPASSWORD="$ODOO_DB_PASSWORD" psql -h "$ODOO_DB_HOST" -U odoo -d <db> \
  -c "SELECT name, state, latest_version FROM ir_module_module WHERE state NOT IN ('installed','uninstalled','uninstallable') ORDER BY name;"
```

Check for the `partially_updated_database` flag (this causes crons to skip the DB):

```bash
PGPASSWORD="$ODOO_DB_PASSWORD" psql -h "$ODOO_DB_HOST" -U odoo -d <db> \
  -c "SELECT key, value FROM ir_config_parameter WHERE key = 'base.partially_updated_database';"
```

If `value = '1'`, the database is flagged as partially updated and crons are suspended.

## Step 2: Take a backup before any recovery action

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo -E bash /var/lib/odoo/scripts/backup.sh <db>"
```

If `scripts/backup.sh` is not present, follow [playbooks/backup.md](backup.md).

## Step 3: Reset stuck module states via `odoo shell`

**Never hand-edit `ir_module_module.state` directly with SQL.** The sanctioned recovery path is:

**Option A — via the Odoo shell (preferred):**

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http <<'EOF'
# button_reset_state() transitions:
#   'to install'  → 'uninstalled'
#   'to upgrade'  → 'installed'
#   'to remove'   → 'installed'
# Source: ir_module.py:496-500
env['ir.module.module'].button_reset_state()
env.cr.commit()
print('Done. States reset.')
EOF"
```

**Option B — via `reset_modules_state` (Python loader function):**

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http <<'EOF'
from odoo.modules.loading import reset_modules_state
reset_modules_state('<db>')
env.cr.commit()
print('Done.')
EOF"
```

`reset_modules_state` is the one sanctioned use of raw SQL state updates — it is implemented in the Odoo loader (`loading.py:611-632`) and called only after a confirmed failed operation.

## Step 4: Clear the `partially_updated_database` flag

After resetting module states, the `base.partially_updated_database` parameter should be cleared automatically. Verify:

```bash
PGPASSWORD="$ODOO_DB_PASSWORD" psql -h "$ODOO_DB_HOST" -U odoo -d <db> \
  -c "SELECT key, value FROM ir_config_parameter WHERE key = 'base.partially_updated_database';"
```

If it is still `'1'`, clear it via the shell:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http <<'EOF'
param = env['ir.config_parameter'].sudo().search([('key', '=', 'base.partially_updated_database')])
param.unlink()
env.cr.commit()
print('Flag cleared.')
EOF"
```

## Step 5: Restart Odoo and re-run the upgrade

After resetting states, restart the Odoo service:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo systemctl restart odoo || sudo supervisorctl restart odoo"
```

Then re-run the module upgrade that was interrupted (see [playbooks/install-or-upgrade-module.md](install-or-upgrade-module.md)):

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo -c /etc/odoo/odoo.conf -d <db> -u <mod> --stop-after-init"
```

## Step 6: Verify crons resumed

After a successful upgrade pass, confirm crons are running again:

```bash
PGPASSWORD="$ODOO_DB_PASSWORD" psql -h "$ODOO_DB_HOST" -U odoo -d <db> \
  -c "SELECT name, active, nextcall FROM ir_cron WHERE active = true ORDER BY nextcall LIMIT 10;"
```

At least the base autovacuum job should appear. If crons are still suspended, check that `base.partially_updated_database` is no longer set.

## Do NOT

- Edit `ir_module_module.state` directly with SQL (`UPDATE ir_module_module SET state = ...`). This bypasses the ORM state machine and can leave the database in an inconsistent state.
- Re-run an upgrade without first resetting states — a module in `to upgrade` combined with a second `-u` invocation can lead to double-migration attempts.
- Ignore the `partially_updated_database` flag — crons will remain suspended for the entire database until it is cleared.
