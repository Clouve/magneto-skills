# Playbook: Roll back from backup

Use this playbook when an upgrade, plugin change, or bad edit has put the site in a state where restoring the pre-change backup is the right move. This is destructive: **every database change since the backup is lost** — posts, comments, orders, user registrations, all of it.

On today's channels this is almost always a **DB-only rollback**: the dump restores over TCP, but `wp-content/` stays exactly as it is now, because no file channel exists into the WordPress container ([reference/shell-access.md](../reference/shell-access.md)). Set that expectation with the user up front — do not imply files are coming back unless you hold a `wp-content` archive *and* a working shell.

## Preconditions

- [ ] **Backup dump in hand** with its manifest ([reference/backup-restore.md](../reference/backup-restore.md)); you know whether a `wp-content/` archive exists too (today: usually not).
- [ ] **Env names discovered** (`env | grep -iE 'wordpress|mysql|maria|host'`); examples assume `WORDPRESS_DB_*`, `WORDPRESS_HOST=wordpress`, default `wp_` prefix.
- [ ] **Channel inventory done** — SSH probe run; expect TCP + HTTP only on today's images.
- [ ] **Version fit known**: the dump's `db_version` vs the running code (case matrix in step 4). `zgrep -A2 "option_name.*db_version" backup.sql.gz` or read it after import.
- [ ] **User ack recorded** — per the gates in [SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow): print the exact restore command, spell out the data-loss window (backup timestamp → now), and wait for the literal phrase `yes, I understand this is irreversible`.

## Steps

### 1. Forensic capture of the broken state — [TCP-mysql] + [HTTP]

Even though you're restoring, keep what's there now — you may need it for diagnosis, and "we kept the broken state" is the right answer when the user asks later.

```bash
ts=$(date +%Y%m%d-%H%M%S); out="$HOME/forensic-$ts"; mkdir -p "$out"

MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysqldump -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
    --single-transaction --quick --default-character-set=utf8mb4 \
    "$WORDPRESS_DB_NAME" | gzip > "$out/db-broken.sql.gz"

curl -sSI "http://${WORDPRESS_HOST}/" > "$out/homepage-headers.txt"
curl -sS  "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>' > "$out/generator.txt" || true
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -sN \
    -e "SELECT option_value FROM wp_options WHERE option_name='active_plugins';" > "$out/active_plugins.txt"
ls -la "$out"
```

### 2. Freeze writes as best you can

- **[shell-only — probe first]** Real maintenance mode: `echo '<?php $upgrading = time();' > /var/www/html/.maintenance`. Standard WordPress behaviour: it expires after 10 minutes — re-touch it during a long restore, and remove it at the end.
- **No shell (today's reality):** there is no maintenance mode you can set. Say so. Tell the user to stop editing and warn other admins; keep the window short. Writes that land mid-import are lost or inconsistent — that is part of the risk they acked.

### 3. Restore the DB — [TCP-mysql]

Print this command and get the ack (precondition 5) **before** running it:

```bash
gunzip -c "$HOME/backups/wordpress-<ts>.sql.gz" | MYSQL_PWD="$WORDPRESS_DB_PASSWORD" \
    mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME"
```

The dump carries `DROP TABLE IF EXISTS` per table, so every dumped table is replaced wholesale. Two follow-ups:

```sql
-- 3a. Confirm the restored schema version matches the backup:
SELECT option_value FROM wp_options WHERE option_name='db_version';
```

```bash
# 3b. Leftover tables created AFTER the backup (e.g. by a since-installed plugin) survive
#     the import. List and compare against the manifest:
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
    "$WORDPRESS_DB_NAME" -e "SHOW TABLES;"
```

Dropping leftovers is a schema change — the schema-change gate applies (fresh dump already in hand from step 1; print each `DROP TABLE` and get an explicit ack per table). Leaving them is usually harmless; say which you did. Shape B (MySQL 8) client/auth caveats: [reference/backup-restore.md](../reference/backup-restore.md).

### 4. Reconcile restored DB with the running code

| Case | Situation | Action |
|---|---|---|
| **A** | Code version == what the backup ran on | Nothing — proceed |
| **B** | Code **newer** than the dump's schema | A DB update is pending (front-end still serves). If the *code* is what broke, roll the image back instead: Shape A → platform redeploys the prior app version (route the user); Shape B → developer re-pins the old tag and redeploys. Otherwise run the DB update: `/wp-admin` prompt **[HTTP — user's browser]** or `wp core update-db` **[shell-only — probe first]** |
| **C** | Code **older** than the dump's schema | **Stop.** No supported downgrade. Get the matching (newer) image via the platform, or restore an older backup |

### 5. Files — per channel

- **[shell-only — probe first]**, when you hold a `wp-content` archive: move the current `wp-content` aside (forensics, don't delete), extract the archive into the docroot, then `chown -R www-data:www-data wp-content`.
- **No file channel (today):** `wp-content/` keeps its *current* files under the *restored* DB. Consequences to check and tell the user:
  - A plugin active in the restored DB but **missing on disk** is auto-deactivated by WordPress with a "plugin file does not exist" notice (standard behaviour) — its features silently vanish; list what got deactivated from `/wp-admin` → Plugins.
  - Plugin **files newer** than the restored DB's data is usually tolerated, but a plugin that migrated its own tables forward may misbehave against its rolled-back rows — watch that plugin's screens specifically.
  - To put a plugin's *code* back to the old version: route the user to `/wp-admin` — wordpress.org keeps previous plugin versions under each plugin page's Advanced view (install gate applies: [SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow)).
  - Broken/missing **theme**: the scalar fallback (`template`/`stylesheet` → a stock theme, existence verified over HTTP first) is in [reference/troubleshooting.md](../reference/troubleshooting.md).

### 6. Flush caches and rewrites

```sql
-- [TCP-mysql] Rewrite rules: single-row delete; WordPress regenerates on the next request
-- (standard behaviour). Print + ack first, then:
DELETE FROM wp_options WHERE option_name='rewrite_rules';
```

Transients from the broken state can serve stale data. Multi-row delete ⇒ the gate applies — count first, show the number, get the ack:

```sql
SELECT COUNT(*) FROM wp_options WHERE option_name LIKE '\_transient\_%' OR option_name LIKE '\_site\_transient\_%';
-- after ack:
DELETE FROM wp_options WHERE option_name LIKE '\_transient\_%' OR option_name LIKE '\_site\_transient\_%';
```

With a shell: `wp cache flush && wp rewrite flush --hard`. More in [reference/caching.md](../reference/caching.md).

**Shape A bonus:** a platform restart makes the installer entrypoint re-assert `siteurl`/`home` from `WORDPRESS_SITE_URL` (with a hard rewrite flush on mismatch) — after a restore, ask the user to restart the app from Clouve.

### 7. Check `siteurl` / `home` — [TCP-mysql]

```sql
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');
```

If the dump predates a domain change, the restored values are stale. Shape A: the env reconciler fixes both at the next restart (or set them now — two single-row updates, print + ack). Shape B: **nothing reconciles them**, and a wrong value locks everyone out of `/wp-admin` — follow [change-site-url.md](change-site-url.md).

### 8. Verify — canaries

```sql
-- [TCP-mysql] row counts vs the backup manifest (they should match the manifest, not the broken state):
SELECT 'wp_posts' t, COUNT(*) c FROM wp_posts
UNION ALL SELECT 'wp_users', COUNT(*) FROM wp_users
UNION ALL SELECT 'wp_comments', COUNT(*) FROM wp_comments
UNION ALL SELECT 'wp_options', COUNT(*) FROM wp_options
UNION ALL SELECT 'wp_postmeta', COUNT(*) FROM wp_postmeta;
```

```bash
# [HTTP] home, login, one permalink, one media URL (from a recent attachment guid):
curl -sSI "http://${WORDPRESS_HOST}/" | head -1
curl -sSI "http://${WORDPRESS_HOST}/wp-login.php" | head -1
```

Have the user log in and open a post they remember from *before* the backup window — content they added *after* it should be gone (that is the rollback working, not a bug — but confirm it matches the window you told them).

### 9. Tell the user

- What was restored: **DB only** (or DB + files, if a channel and archive existed), from the backup taken at `<timestamp>`.
- The data-loss window: backup time → now; what they must re-do (posts, comments, user signups, orders).
- What was *not* restored: `wp-content/` files, and what that meant here (auto-deactivated plugins, plugin-version skew).
- Forensic snapshot location (`$HOME/forensic-<ts>/`).
- Whether a restart is still pending (Shape A URL reconcile) and anything you had to skip for lack of a channel.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| Import dies with `server has gone away` | Oversized rows vs the server's `max_allowed_packet` | Re-run the import (dump is self-replacing via `DROP TABLE`); if it repeats at the same point, surface it — the packet ceiling is server-side config you should not patch |
| Import errors on charset/collation | Dump vs server charset mismatch | `--default-character-set=utf8mb4` on both dump and import; re-run |
| `Access denied` on Shape B | MySQL 8 auth / app-scoped grants | [reference/backup-restore.md](../reference/backup-restore.md) Shape B caveats |
| Site redirects to the wrong domain after restore | Stale `siteurl`/`home` from the dump | Step 7 |
| "Database Update Required" after restore | Case B — code newer than the dump | Step 4 |
| Site won't bootstrap / acts inconsistently | Case C — code older than the dump | Matching image or older backup; no downgrade |
| "Plugin file does not exist" notices | DB-only restore; plugin code missing on disk | Expected — step 5; reinstall via `/wp-admin` if wanted |
| Users report being logged out / passwords "wrong" | Credentials reverted to backup-time values | Expected — part of the data-loss window; reset via `/wp-admin` |
| Permalinks 404 | Stale rewrite rules | Step 6 |

## After-action

A rollback is a high-impact event — capture what happened per [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill): what failure triggered it, whether DB-only proved sufficient or the missing file channel hurt, and the window the user accepted. If the file-channel gap was the pain, that is exactly the kind of learning worth echoing for the operator.
