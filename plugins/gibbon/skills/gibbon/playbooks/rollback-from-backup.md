# Playbook: Rollback from Backup

Use when an upgrade, migration, rollover, or risky operation has left the DB in a bad state and the right answer is "go back to the last good point."

There is no upstream Gibbon "downgrade" story (see [reference/upgrade.md](../reference/upgrade.md)). Rollback = restore from the backup taken before the risky operation.

## Preconditions

- [ ] You have a complete backup. See [reference/backup-restore.md](../reference/backup-restore.md) — DB dump + uploads tar + `config.php` + customAssets.
- [ ] The tenant has acknowledged that any work done since the backup will be lost.

## Decision: partial-restore or full-restore?

- **Partial restore** — a single table (e.g. just `gibbonBehaviour` because a mis-import went wrong). Do this from Magneto Agent if you can cleanly scope the rows. High risk of FK orphans if you pick wrong.
- **Full restore** — the whole DB and the files on the `gibbondata` volume (`uploads/`, `config.php`, `customAssets/`). Always-correct, and you can do both halves yourself: the DB over TCP, the files over the `clouve-ops` SSH channel. The files come back only if the backup has a files archive ([reference/backup-restore.md](../reference/backup-restore.md)).

When in doubt, full restore. The operational cost is small; the cost of a partial restore that introduces FK orphans is weeks of chasing ghost data.

## Full restore — steps

### 1. Capture the current-bad state (so you know what you're throwing away)

```bash
# Timestamp + DB snapshot of what you're about to overwrite.
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysqldump \
  -h "$GIBBON_DB_HOST" -u gibbon \
  --single-transaction --quick --lock-tables=false --no-tablespaces \
  --default-character-set=utf8mb3 \
  gibbon > "$HOME/backups/pre-restore-$(date +%Y-%m-%d-%H-%M-%S).sql"
```

### 2. Confirm what comes back, before anything is replaced

Nothing has been overwritten yet. Show the user what the restore brings back and what it replaces, and wait for their ack:

```bash
b="$HOME/backups/gibbon-<timestamp>"
ls -l "$b"/gibbon.sql "$b"/gibbon-files.tar.gz   # date and size of each half (no files archive: only the database comes back)
grep -c '^CREATE TABLE' "$b/gibbon.sql"           # tables in the dump
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='gibbon';"   # tables about to be dropped
# Whether the backup's config.php is the one the container has now: compare digests, never the files.
tar -xzOf "$b/gibbon-files.tar.gz" config.php | sha256sum
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'sudo sha256sum /var/www/html/config.php'
```

Tell the user both halves' dates and sizes, how many tables are dropped and how many come back, and whether `config.php` differs. Never show `config.php` itself or a diff of it: it holds the database password.

### 3. Restore the files over the `clouve-ops` channel

Skip this step if the backup has no `gibbon-files.tar.gz`, and tell the user that only the database comes back. Otherwise keep the current files first, then unpack the backup's archive over them:

```bash
# The current files, in case the user wants them back.
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'cd /var/www/html && sudo tar -czf - --exclude="uploads/cache/*" config.php uploads $(test -d customAssets && echo customAssets)' \
  > "$HOME/backups/pre-restore-files-$(date +%Y-%m-%d-%H-%M-%S).tar.gz"

# The backup's files, over the current ones.
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'sudo tar -C /var/www/html -xzf - && sudo chown -R www-data:www-data /var/www/html/uploads /var/www/html/config.php' \
  < "$HOME/backups/gibbon-<timestamp>/gibbon-files.tar.gz"
```

Files added since the backup stay where they are; the archive's files replace the ones with the same name. Restore only this deployment's own backups: another deployment's `config.php` carries its own database settings and `$guid`.

### 4. Restore the DB

```bash
# Wipe the existing tables. The gibbon user usually can DROP tables in its own DB.
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SET FOREIGN_KEY_CHECKS=0;" \
  -e "$(MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
        "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema='gibbon';" | tr '\n' ' ')"

# Apply the dump.
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql \
  -h "$GIBBON_DB_HOST" -u gibbon \
  --default-character-set=utf8mb3 \
  gibbon < "$HOME/backups/gibbon-<timestamp>/gibbon.sql"
```

Run it only with the ack from step 2, which covered the drop-and-replace.

### 5. What the next container start does

The restore changed files and rows, not code, so nothing needs a restart. When the `gibbon` container next starts, `entrypoint.sh` will:
- Find `config.php` present → skip install.
- Find `clouve/installed/<version>` → skip upgrade.
- Wipe `uploads/cache/`.
- Run `update-config.sh` → re-sync `$DB_*` into `config.php` and `$GIBBON_URL` into `gibbonSetting.absoluteURL`.
- Render `/etc/cron.d/gibbon-cron` from current `$GIBBON_CRON_INTERVAL` and start cron.

Nothing to do from your side. Verify now; the next start doesn't have to come first. One exception: if Gibbon can't reach its database after the restore, the restored `config.php` holds older database settings than the container's (from before a password change, say). The next container start would write the current ones back (`update-config.sh`), but the user has no restart button for the app. Offer to put back the `config.php` that step 3 kept instead: it is the container's own copy from just before the restore, the one step 2 compared by `sha256sum`. That is an edit to `config.php`, so say which file goes back and why, show no line of either copy, and wait for the user's ack:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'sudo tar -C /var/www/html -xzf - config.php && sudo chown www-data:www-data /var/www/html/config.php' \
  < "$HOME/backups/pre-restore-files-<timestamp>.tar.gz"
```

It unpacks only `config.php` from that archive and prints nothing from it. Then check the file as [diagnose-500.md](diagnose-500.md) step 4 does, without printing it. If step 3's archive isn't there, the user asks Clouve support for a restart, which writes the current settings back.

### 6. Verify the restore

Follow [reference/backup-restore.md#verify-a-restore](../reference/backup-restore.md). At minimum:
- `gibbonSetting(version) == /var/www/html/version.php $version`.
- Row counts match pre-backup expectations.
- Admin login works (ask the user).
- Home page renders.
- Cron logs show fresh ticks after a minute or two.

## Partial restore — when and how

Appropriate when:
- A single table was corrupted by a bad import / bad SQL.
- You can name the exact tables and confirm no FKs point into them from other tables you're keeping.
- The user accepts they may end up with orphan rows if you got the scoping wrong.

### Extract one table from the dump

```bash
# Pulls everything from one table's CREATE to the next table's CREATE.
TABLE=gibbonBehaviour
awk "/^-- Table structure for table \`${TABLE}\`/,/^-- Table structure for table \`/" \
  "$HOME/backups/gibbon-<timestamp>/gibbon.sql" > "/tmp/${TABLE}.sql"

# Sanity-check: the file should contain exactly one CREATE TABLE.
grep -c '^CREATE TABLE' "/tmp/${TABLE}.sql"   # expect 2 (this table + the start of the next)
```

### Apply with FK checks off

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon <<EOF
SET FOREIGN_KEY_CHECKS=0;
DROP TABLE IF EXISTS \`${TABLE}\`;
SOURCE /tmp/${TABLE}.sql;
SET FOREIGN_KEY_CHECKS=1;
EOF
```

### Verify no orphans

For the partially-restored table, check every FK column matches live rows in the target:

```sql
-- Example for gibbonBehaviour.gibbonPersonID
SELECT COUNT(*) FROM gibbonBehaviour b
LEFT JOIN gibbonPerson p ON b.gibbonPersonID = p.gibbonPersonID
WHERE p.gibbonPersonID IS NULL;
-- Expect 0.
```

If orphans exist, you either need to also restore the parent tables or accept the orphans and manually clean them up.

## Do NOT

- Do NOT try to "reverse-apply" `CHANGEDB.php` migrations. No DOWN migrations exist.
- Do NOT manually rewrite `config.php $version` to match an older schema — the mismatch will be detected and corrupted migrations may re-run.
- Do NOT delete `dbdata` volume contents thinking "I'll just re-run the installer" — you'll lose the tenant's data entirely. The installer is for empty schemas only.
- Do NOT pick a partial restore because it "seems faster." The safe default is a full restore when anything feels uncertain.
