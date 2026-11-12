# Playbook: Restore and Clone

Use when restoring a backup to recover from data loss, or when cloning a production database to a staging environment.

Only `${ODOO_DB_NAME}` answers in a browser. Clouve's Odoo image writes a `dbfilter` for that one database into `odoo.conf` at every start (see [harden-db-manager.md](harden-db-manager.md), step 2), so a clone or a restore under another name never reaches the login page: use it with `odoo shell`, `psql` and the checks below. A copy someone wants to use in a browser goes into its own deployment, restored there from the backup. A disaster-recovery restore into `${ODOO_DB_NAME}` itself (`scripts/restore.sh --prod`, or `db load -f`) serves in the browser as before. `odoo db` works with the database manager locked: it turns the lock off for itself.

The filter limits the browser and nothing else. Odoo's cron thread runs the scheduled jobs of every database the `odoo` role owns, so a copy under another name sends its mail, charges its payment providers and calls its webhooks unless it is neutralized: every load or copy under another name below uses `-n`. And XML-RPC and JSON-RPC (`/xmlrpc/2/*`, `/jsonrpc`) reach any database by name, so a copy's users can still sign in to it over the API. Keep a copy only for its task, then drop it (`sudo ODOO_RC=/etc/odoo/odoo.conf odoo db drop <copy>`, with the user's ack: it removes the database and its filestore).

## Preconditions

- [ ] You have a backup ZIP (produced by `odoo db dump` or `scripts/backup.sh`) — not a raw `pg_dump` `.dump` file (the `db load` command only accepts ZIP format).
- [ ] You know the target database name (`<target-db>`). For a recovery restore, this is typically the existing database name. For a clone, this is a new staging name.
- [ ] If restoring over an existing database, you have confirmed intent — the `-f` flag will permanently destroy the target database and its filestore.

## Steps

### 1. Confirm the target database does not already exist (for new restores)

`odoo db load` refuses to overwrite an existing database by default. Check first:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_DB_HOST} \
  "sudo -u postgres psql -U ${ODOO_DB_USER} -lqt | cut -d\| -f1 | grep -w '<target-db>'"
```

No output (exit 1) means it doesn't exist. The superuser role is `${ODOO_DB_USER}`; there is no `postgres` role. If the database exists and you want to replace it, see the force-overwrite step below.

### 2. Copy the backup artifact into the Odoo container

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e scp -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
  $HOME/backups/<backup>.zip \
  clouve-ops@${ODOO_HOST}:/tmp/<backup>.zip
```

Verify it arrived:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "ls -lh /tmp/<backup>.zip"
```

### 3. Preferred: the skill's `scripts/restore.sh`

```bash
bash /clouve/skills/odoo/plugin/skills/odoo/scripts/restore.sh <target-db> /tmp/<backup>.zip
```

Run it here, in this container: it SSHes to the Odoo container itself (unlike `scripts/backup.sh`, which you pipe in). It loads the ZIP into `<target-db>` neutralized, the safe default for a prod→staging clone (see step 5), then prints `database.is_neutralized`. It refuses to load into the live database name (`${ODOO_DB_NAME}`) unless you add `--prod`, which also skips neutralization, for a real disaster-recovery restore.

### 4. Manual fallback — `odoo db load`

Pass the config as `ODOO_RC`, not `-c` (see [reference/backup-restore.md](../reference/backup-restore.md#cli-vs-http--prefer-the-cli)).

```bash
# A copy under another name: always neutralized, since its scheduled jobs run as soon as it exists:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db load -n <target-db> /tmp/<backup>.zip"
```

**Flag semantics:**
- Default (no `--move`): generates a new `dbuuid`, right for clones and copies.
- `--move`: keeps the original `dbuuid`, right only for a disaster-recovery restore into `${ODOO_DB_NAME}` itself (4a). A second database with production's `dbuuid` is still a copy, with live scheduled jobs.
- `-n` / `--neutralize`: neutralizes after restore. Mandatory for every database under another name: it turns off the mail servers and every scheduled job but autovacuum.
- `-f` / `--force`: drops the target DB and deletes its filestore before loading. **Irreversible** (see gate below). To refresh a copy, drop it and load it again with `-n`.

### 4a. Force-overwrite gate (DESTRUCTIVE)

```
GATE: -f drops the target database AND removes its filestore directory permanently.
There is no undo other than another backup. Confirm the tenant explicitly intends
to replace the live database ${ODOO_DB_NAME} with the backup before proceeding.
```

A disaster-recovery restore into the live database, keeping its `dbuuid`. (`scripts/restore.sh ${ODOO_DB_NAME} <zip> --prod` also loads into the live name without neutralizing, but it passes no `-f`, so it works only once the old database is gone.)

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db load -f --move ${ODOO_DB_NAME} /tmp/<backup>.zip"
```

### 5. Clone: prod → staging

The recommended pattern is dump then load with `-n`. The clone doesn't answer in a browser (see the top of this playbook):

```bash
# Step 1: dump prod (on the Odoo container):
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db dump prod-db /tmp/prod-db-$(date +%Y%m%d).zip"

# Step 2: restore to staging with immediate neutralization:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db load -n staging-db /tmp/prod-db-$(date +%Y%m%d).zip"
```

Alternatively, use `db duplicate -n` for a server-side copy when both databases will be on the same Odoo instance (faster — no dump/load round-trip):

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db duplicate -n prod-db staging-db"
```

### 6. Verify neutralization on a staging clone

After any prod→staging restore, confirm neutralization applied:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d <target-db> --no-http <<'EOF'
print(env['ir.config_parameter'].sudo().get_param('database.is_neutralized'))
print(env['ir.mail_server'].search([('active', '=', True)]).mapped('name'))
EOF"
```

Expected: `'true'` and `['neutralization - disable emails']`.

See [reference/neutralization.md](../reference/neutralization.md) for the full list of what neutralization disables (crons, payment providers, webhooks, etc.) and what it does NOT do (user passwords, API keys, application data).

### 7. Verify the restore

Spot-check that attachments are intact (a quick test that the filestore came through):

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -c /etc/odoo/odoo.conf -d <target-db> --no-http <<'EOF'
count = env['ir.attachment'].search_count([('type', '=', 'binary'), ('store_fname', '!=', False)])
print(f'Filestore attachments: {count}')
EOF"
```

Compare with the source database count. A zero count when the source had attachments indicates the filestore was not restored.

## Do NOT

- Use `db load` with a raw `pg_dump` `.dump` file — it only accepts ZIP format; use `pg_restore` for raw dumps.
- Restore a prod backup to staging without the `-n` flag — a non-neutralized clone will send real emails and trigger real payment transactions.
- Run `-f` without an explicit destructive-intent confirmation from the tenant.
- Assume `database.is_neutralized=true` without verifying — check with the shell command above.
