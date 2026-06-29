# Playbook: Restore and Clone

Use when restoring a backup to recover from data loss, or when cloning a production database to a staging environment.

## Preconditions

- [ ] You have a backup ZIP (produced by `odoo db dump` or `scripts/backup.sh`) — not a raw `pg_dump` `.dump` file (the `db load` command only accepts ZIP format).
- [ ] You know the target database name (`<target-db>`). For a recovery restore, this is typically the existing database name. For a clone, this is a new staging name.
- [ ] If restoring over an existing database, you have confirmed intent — the `-f` flag will permanently destroy the target database and its filestore.

## Steps

### 1. Confirm the target database does not already exist (for new restores)

`odoo db load` refuses to overwrite an existing database by default. Check first:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_DB_HOST} \
  "sudo -u postgres psql -lqt | cut -d\| -f1 | grep -w '<target-db>'"
```

If the database exists and you want to replace it, see the force-overwrite step below.

### 2. Copy the backup artifact into the Odoo container

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e scp \
  $HOME/backups/<backup>.zip \
  clouve-ops@${ODOO_HOST}:/tmp/<backup>.zip
```

Verify it arrived:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "ls -lh /tmp/<backup>.zip"
```

### 3. Preferred — `scripts/restore.sh`

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo -E bash /var/lib/odoo/scripts/restore.sh <target-db> /tmp/<backup>.zip"
```

For a prod→staging clone, pass `-n` to neutralize immediately (see step 5):

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo -E bash /var/lib/odoo/scripts/restore.sh -n <target-db> /tmp/<backup>.zip"
```

### 4. Manual fallback — `odoo db load`

**Note: `-c` goes AFTER `db`, not before it** (see [reference/backup-restore.md](../reference/backup-restore.md#cli-vs-http--prefer-the-cli)).

```bash
# Restore to a new database (new dbuuid generated — the "copy" path):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf load <target-db> /tmp/<backup>.zip"

# Restore and neutralize immediately (MANDATORY for prod→staging):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf load -n <target-db> /tmp/<backup>.zip"

# Restore as a "move" — keep the original dbuuid (use for DR recovery, not cloning):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf load --move <target-db> /tmp/<backup>.zip"
```

**Flag semantics:**
- Default (no `--move`): generates a new `dbuuid` — correct for clones and copies.
- `--move`: retains the original `dbuuid` — correct for disaster-recovery restores to the same logical database.
- `-n` / `--neutralize`: neutralizes after restore — mandatory for any prod→staging clone (prevents live emails, crons, webhooks).
- `-f` / `--force`: drops the target DB and deletes its filestore before loading — **irreversible** (see gate below).

### 4a. Force-overwrite gate (DESTRUCTIVE)

```
GATE: -f drops the target database AND removes its filestore directory permanently.
There is no undo other than another backup. Confirm the tenant explicitly intends
to destroy the existing <target-db> before proceeding.
```

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf load -f <target-db> /tmp/<backup>.zip"
```

### 5. Clone: prod → staging

The recommended pattern is dump then load with `-n`:

```bash
# Step 1: dump prod (on the Odoo container):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf dump prod-db /tmp/prod-db-$(date +%Y%m%d).zip"

# Step 2: restore to staging with immediate neutralization:
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf load -n staging-db /tmp/prod-db-$(date +%Y%m%d).zip"
```

Alternatively, use `db duplicate -n` for a server-side copy when both databases will be on the same Odoo instance (faster — no dump/load round-trip):

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf duplicate -n prod-db staging-db"
```

### 6. Verify neutralization on a staging clone

After any prod→staging restore, confirm neutralization applied:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <target-db> --no-http <<'EOF'
print(env['ir.config_parameter'].sudo().get_param('database.is_neutralized'))
print(env['ir.mail.server'].search([('active', '=', True)]).mapped('name'))
EOF"
```

Expected: `'true'` and `['neutralization - disable emails']`.

See [reference/neutralization.md](../reference/neutralization.md) for the full list of what neutralization disables (crons, payment providers, webhooks, etc.) and what it does NOT do (user passwords, API keys, application data).

### 7. Verify the restore

Spot-check that attachments are intact (a quick test that the filestore came through):

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <target-db> --no-http <<'EOF'
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
