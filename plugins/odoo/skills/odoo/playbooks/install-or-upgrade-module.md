# Playbook: Install or Upgrade a Module

Use when the tenant asks to install a module, either one that ships with Odoo (CRM, Sales, Inventory and the rest) or a third-party one, or to upgrade an installed module.

Odoo keeps serving through the whole procedure. You don't stop it, and you don't hand a restart to the tenant: their Clouve dashboard has no restart button. The one restart this playbook uses is the in-container `SIGHUP` in step 2, and only third-party code needs it.

## Preconditions

- [ ] For a third-party module: you have the module source and have read `__manifest__.py` plus every top-level Python file (security posture: third-party addons run arbitrary Python with full DB access — see [reference/module-lifecycle.md](../reference/module-lifecycle.md#third-party-addons--security-posture)). Modules that ship with Odoo live in `/usr/lib/python3/dist-packages/odoo/addons` and skip this check and step 2.
- [ ] You can reach the Odoo container via SSH: `SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST}`.
- [ ] You know the exact database name (`<db>`, normally `${ODOO_DB_NAME}`) and module technical name (`<mod>`).

## Steps

### 1. Take a backup (GATE — do not continue without this)

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@${ODOO_HOST} \
  "sudo bash -s -- <db>" < /clouve/skills/odoo/plugin/skills/odoo/scripts/backup.sh
```

This pipes the skill's own `scripts/backup.sh` into the Odoo container and runs it there. [playbooks/backup.md](backup.md) explains what it checks, gives the manual fallback, and shows how to copy the ZIP off the container.

**Confirm the backup artifact exists before proceeding.** An upgrade that drops columns or runs migration scripts cannot be safely interrupted mid-flight.

```
GATE: Confirm backup completed and artifact path noted. Type "backup confirmed" to proceed.
```

### 2. Third-party modules only: copy the code in, then restart Odoo

Third-party modules go in `/mnt/extra-addons`, the custom-modules volume. `odoo.conf` lists it in `addons_path` as the pattern `/mnt/extra-addons*`, which Odoo checks each time it starts: it skips the folder while no module is in it and loads it once one is (see [reference/configuration.md](../reference/configuration.md#this-images-conf-template)).

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "ls /mnt/extra-addons/<mod>/"
```

If the directory is missing, or holds an older version, copy the module folder over the SSH channel (there is no `kubectl` in this container):

```bash
tar -C /path/to/parent-folder -cf - <mod> | SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo tar -C /mnt/extra-addons -xf - && sudo chown -R odoo:odoo /mnt/extra-addons/<mod>"
```

The running server reads module folders and Python code only when it starts, so restart it now, before step 3. Odoo is PID 1 in its container and re-executes itself on `SIGHUP`, inside the same container:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1'
for i in $(seq 1 30); do
  sleep 2
  curl -fsS -o /dev/null "http://${ODOO_HOST}:8069/web/health" && { echo "Odoo is back"; break; }
done
```

The container keeps running, and so does your SSH access. Odoo is back within a few seconds. Never send `SIGTERM` or `SIGKILL` to PID 1: that stops the container. See [reference/stack-and-runtime.md](../reference/stack-and-runtime.md#restarting-odoo).

### 3. Install or upgrade while Odoo runs

**To install:**

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module install -c /etc/odoo/odoo.conf -d <db> <mod>"
```

**To upgrade:**

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module upgrade -c /etc/odoo/odoo.conf -d <db> <mod>"
```

This takes the same path as the Install button in Apps (`button_immediate_install`), in a separate one-shot process with no HTTP server, while the live server keeps serving. When it finishes, the live server sees the change in the database and reloads its registry on its next request (its log says "Reloading the model registry after database signaling"). The new app works at once, with no restart. For the `module` command, `-c` goes after `install` or `upgrade`.

A wrong module name installs nothing and prints no error, so always check step 4. If the run stops with "Odoo is currently processing a scheduled action", a cron job holds the lock: wait a minute and run it again.

The classic flags do the same job and also work while Odoo runs:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo -c /etc/odoo/odoo.conf -d <db> -i <mod> --stop-after-init"   # -u <mod> to upgrade
```

A clean run ends with `Modules loaded.` and exit code 0. Watch the output for `WARNING` or `ERROR` lines.

Checked on Odoo 19 on 2026-10-20: installing `crm` with `-i` took 8 seconds while the server was serving, and the running server created and read `crm.lead` records straight after, without a restart. `odoo module install board` worked the same way.

### 4. Verify the module state

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d <db> --no-http <<'EOF'
result = env['ir.module.module'].search([('name', '=', '<mod>')])
print(result.mapped(lambda m: (m.name, m.state, m.latest_version)))
EOF"
```

Expected: `state` = `installed`, `latest_version` matches the version in `__manifest__.py`. Keep the `-c`: `sudo` over SSH drops the image's `ODOO_RC`, and without it the shell can't reach the database.

Also confirm the UI: navigate to Settings → Apps and search for the module name. Installed modules show the "Installed" label. A browser tab that was open during the install may need a reload to show the new menus.

### 5. If the module is stuck in `to upgrade` or `to install`

If the module state is not `installed` after the run, follow [playbooks/recover-stuck-module-state.md](recover-stuck-module-state.md) before attempting any further operation.

## Uninstall (separate gate)

```
GATE: Uninstall is IRREVERSIBLE. It runs DROP TABLE ... CASCADE on every table
the module created, cascading to any dependent module. The ONLY undo is a restore
from backup. Confirm the tenant understands this and has a recent backup before
proceeding.
```

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo module uninstall -c /etc/odoo/odoo.conf -d <db> <mod>"
```

## Do NOT

- Skip the backup step — module upgrades can run migration scripts that drop columns.
- Stop Odoo, or wait for a maintenance window, to install a module. The install runs next to the live server.
- Hand a restart to the tenant. Their dashboard has no restart button, and step 2's `SIGHUP` restarts Odoo from here.
- Install modules from untrusted sources onto a database that holds production data.
- Run `-u all --stop-after-init` unless you fully understand all installed modules will be upgraded.
