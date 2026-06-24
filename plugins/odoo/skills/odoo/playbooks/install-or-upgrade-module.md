# Playbook: Install or Upgrade a Module

Use when the tenant asks to install a new third-party module or upgrade an existing one.

## Preconditions

- [ ] You have the module source and have read `__manifest__.py` plus every top-level Python file (security posture: third-party addons run arbitrary Python with full DB access — see [reference/module-lifecycle.md](../reference/module-lifecycle.md#third-party-addons--security-posture)).
- [ ] You can reach the Odoo container via SSH: `SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST}`.
- [ ] You know the exact database name (`<db>`) and module technical name (`<mod>`).

## Steps

### 1. Take a backup (GATE — do not continue without this)

```bash
# Preferred: run the audited backup script
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo -E bash /var/lib/odoo/scripts/backup.sh <db>"
```

If `scripts/backup.sh` is not yet present, fall back to the manual procedure in [playbooks/backup.md](backup.md).

**Confirm the backup artifact exists before proceeding.** An upgrade that drops columns or runs migration scripts cannot be safely interrupted mid-flight.

```
GATE: Confirm backup completed and artifact path noted. Type "backup confirmed" to proceed.
```

### 2. Confirm the module is on `addons_path`

Third-party modules must live in `/mnt/extra-addons`, which is included in `addons_path` by the entrypoint (see [reference/configuration.md](../reference/configuration.md#this-images-conf-template)).

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "ls /mnt/extra-addons/<mod>/"
```

If the directory is missing, the module has not been placed on the volume. Stage it first:

```bash
# Copy module from a local path into the Odoo container (example using kubectl cp):
kubectl cp /path/to/<mod> <odoo-pod>:/mnt/extra-addons/<mod>
```

### 3. Stop the running Odoo service

Module install/upgrade acquires an exclusive registry lock. The running server must be stopped first to avoid conflicts.

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo systemctl stop odoo || sudo supervisorctl stop odoo"
```

### 4. Run the install or upgrade (one-shot)

**To install a new module:**

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo -c /etc/odoo/odoo.conf -d <db> -i <mod> --stop-after-init"
```

**To upgrade an existing module:**

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo -c /etc/odoo/odoo.conf -d <db> -u <mod> --stop-after-init"
```

`--stop-after-init` causes Odoo to exit after the operation completes. The `-c` flag before `-d`/`-u` is correct for the server command (not the `db` subcommand). Watch the output for `WARNING` or `ERROR` lines — a clean run ends with `Modules loaded.` and a zero exit code.

Alternatively, use the dedicated `module` subcommand (no `--stop-after-init` needed):

```bash
# Install
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module install -c /etc/odoo/odoo.conf -d <db> <mod>"

# Upgrade
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module upgrade -c /etc/odoo/odoo.conf -d <db> <mod>"
```

### 5. Restart the Odoo service

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo systemctl start odoo || sudo supervisorctl start odoo"
```

Wait ~10 seconds and verify the process is up:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo systemctl status odoo || sudo supervisorctl status odoo"
```

### 6. Verify the module state

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http <<'EOF'
result = env['ir.module.module'].search([('name', '=', '<mod>')])
print(result.mapped(lambda m: (m.name, m.state, m.latest_version)))
EOF"
```

Expected: `state` = `installed`, `latest_version` matches the version in `__manifest__.py`.

Also confirm the UI: navigate to Settings → Apps and search for the module name. Installed modules show the "Installed" label.

### 7. If the module is stuck in `to upgrade` or `to install`

If the module state is not `installed` after the run, follow [playbooks/recover-stuck-module-state.md](recover-stuck-module-state.md) before attempting any further operation.

## Uninstall (separate gate)

```
GATE: Uninstall is IRREVERSIBLE. It runs DROP TABLE ... CASCADE on every table
the module created, cascading to any dependent module. The ONLY undo is a restore
from backup. Confirm the tenant understands this and has a recent backup before
proceeding.
```

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module uninstall -c /etc/odoo/odoo.conf -d <db> <mod>"
```

## Do NOT

- Skip the backup step — module upgrades can run migration scripts that drop columns.
- Leave Odoo running during the install/upgrade — registry lock conflicts can cause a stuck state.
- Install modules from untrusted sources onto a database that holds production data.
- Run `-u all --stop-after-init` unless you fully understand all installed modules will be upgraded.
