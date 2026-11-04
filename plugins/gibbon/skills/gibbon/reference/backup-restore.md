# Backup & Restore

## What a "complete" Gibbon backup contains

A complete backup for this app is **four things**. If any one is missing, the restore is incomplete.

1. **Database dump** — `mysqldump` of the `gibbon` schema.
2. **Uploads** — everything under `/var/www/html/uploads/` except `uploads/cache/`.
3. **`config.php`** — at `/var/www/html/config.php`. Tiny but irreplaceable: contains the tenant's `$guid`, without which old sessions and some internal references break.
4. **Custom assets** — `/var/www/html/customAssets/` if present (custom logos, theme overlays). Most tenants won't have this.

Not backed up:
- Additional modules' code under `modules/`. The core modules come back with the image, but a module the school added (`SELECT name, version FROM gibbonModule WHERE type='Additional'`) exists only on the `gibbondata` volume. A restored database still lists it, so keep each one's source (its release zip) before a risky step, or archive its folder the same way as the files below (`modules/<name>`).
- The pristine Gibbon package (`/clouve/gibbon/gibbon-$GIBBON_VERSION/`) — rebuilt from the image layer on every container start.
- `uploads/cache/` — wiped on every container start anyway.
- `/var/log/gibbon-cron.log`, `/var/log/gibbon-cron.state/` — operational diagnostics, not data.

## Volume layout in this app

Both volumes are sized per the app's `clv-docker-compose.yml`:

| Volume | Container path | What's on it | Size |
|---|---|---|---|
| `gibbondata` | `/var/www/html` | Web root: `config.php`, `uploads/`, `customAssets/`, `modules/`, the upgraded package contents | 10 GiB (default) |
| `dbdata` | `/var/lib/mysql` (on `gibbon-mysql`) | MySQL data files | 10 GiB (default) |

Backup of `gibbondata` captures items 2, 3, 4. Dump of the DB captures item 1.

## Backup procedure

Run from the Magneto Agent container. [scripts/backup.sh](../scripts/backup.sh) does step 1, the database dump, into `$HOME/backups/gibbon-<timestamp>/`. Steps 2 to 4, the files, go over the `clouve-ops` SSH channel ([shell-access.md](shell-access.md)) into the same folder.

```
timestamp=$(date +%Y-%m-%d-%H-%M-%S)
out="$HOME/backups/gibbon-$timestamp"
mkdir -p "$out"

# 1. DB dump
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysqldump \
  -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" \
  --single-transaction --quick --lock-tables=false --no-tablespaces \
  --default-character-set=utf8mb3 \
  "$GIBBON_DB_NAME" > "$out/gibbon.sql"

# 2/3/4. The files: uploads/ (without its cache), config.php and customAssets/ if present,
# archived in the gibbon container and streamed back over the clouve-ops channel.
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'cd /var/www/html && sudo tar -czf - --exclude="uploads/cache/*" config.php uploads $(test -d customAssets && echo customAssets)' \
  > "$out/gibbon-files.tar.gz"

# Check the archive opens and holds config.php (lists names only).
tar -tzf "$out/gibbon-files.tar.gz" config.php
```

**The gotcha:** the files live on the `gibbon` container's `gibbondata` volume, not in the Magneto Agent container, so they come over SSH; the database comes over TCP. A backup with only one of the two halves is incomplete: say which halves you took. The archive holds `config.php`, and with it the database password, so keep it under `$HOME/backups` and never print its contents.

## Restore procedure

### DB restore (over TCP)

```
# 1. Confirm gibbon-mysql is reachable and the target DB is empty or you're overwriting intentionally
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" \
  "$GIBBON_DB_NAME" -e "SHOW TABLES;" | wc -l

# 2. Replace the tables. The gibbon user has every privilege on its own schema, so it can
#    drop and recreate the tables; no MySQL root is needed.
#   - For a partial restore (a single table), SOURCE the relevant section from the dump.
#   - For a full restore, drop the schema's tables, then apply the whole dump:
#     playbooks/rollback-from-backup.md, step 4.

# Partial-restore example (single table recovery — only with explicit user ack):
# Extract just that table's CREATE+INSERTs from the dump:
awk '/^-- Table structure for table `gibbonBehaviour`/,/^-- Table structure for table `/' dump.sql > one.sql
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" < one.sql
```

### Filesystem restore

Over the `clouve-ops` channel, from a backup's `gibbon-files.tar.gz`, with the user's ack. The commands are in [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md), steps 2 and 3:

1. Archive the current files first, the same way as the backup, so the user can have them back.
2. Unpack the backup's archive over `/var/www/html` and give `uploads/` and `config.php` back to `www-data`. Files added since the backup stay.
3. Nothing needs a restart. At the next container start, `entrypoint.sh` runs `update-config.sh`, which re-syncs `$DB_{HOST,NAME,USER,PASSWORD}` into `config.php`, so a restored `config.php` with stale database settings heals then. Restore only this deployment's own backups.

If the whole volume is lost, look first at the deployment's **Backups** tab in the Clouve dashboard: it lists the deployment's platform backups and their schedules, and has a Restore action. If it holds no backup from before the loss, point the user to Clouve support, and restore the files from your archive once the container runs again.

## Verify a restore

After a restore, before you tell the user "you're good":

1. **Row counts match.** Pre-backup counts of `gibbonPerson`, `gibbonAttendanceLogPerson`, `gibbonMarkbookEntry`, `gibbonFinanceInvoice` should match post-restore counts (use `SELECT COUNT(*)`). If pre-backup counts aren't recorded, at least confirm counts are non-zero and plausible.
2. **`gibbonSetting(version) == version.php $version`.** If they diverge, run `update.php` or ask the user to.
3. **`absoluteURL` matches the tenant's current `$GIBBON_URL`.** Our `update-config.sh` should handle this on next restart; confirm.
4. **Admin login works.** Ask the user to log in. Don't touch the password yourself.
5. **HTTP 200 on `/index.php`** and the home page renders. `curl -sI https://$tenant/index.php`.
6. **Cron runs.** After a minute, `/var/log/gibbon-cron.log` should show a fresh tick (or idle ticks suppressed — check `service cron status`).

## How often should the tenant back up?

For a live school: daily at minimum, with retention. The deployment's **Backups** tab in the Clouve dashboard is where the user turns on daily, weekly, monthly or yearly backups of the whole deployment. This skill's role is to make a backup on demand before any risky operation (upgrades, module installs, rollover, `ALTER TABLE`).

## What to tell the tenant

When you take a backup on their behalf, tell them:
- Where it is (`$HOME/backups/gibbon-<timestamp>/`).
- What's in it: the database dump, and the files archive if you took one (`uploads/`, `config.php`, `customAssets/`).
- That Magneto Agent's `/home` volume survives pod restarts, so the backup persists, but it is not off-site.
- That for disaster recovery, they should periodically download the backup to their own laptop or cloud storage.
