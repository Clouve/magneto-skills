# Backup & Restore

A complete WordPress backup is **three coordinated artifacts** (see [SKILL.md principle 1](../SKILL.md)):

| Artifact | What it holds | Recoverable without it? |
|---|---|---|
| **SQL dump** | All content: posts, pages, comments, users, settings, plugin data, media *metadata* | No — this is the site |
| **`wp-content/` archive** | Media bytes (`uploads/`), plugin code, theme code, `debug.log` | Uploads: **no**. Plugin/theme code: re-downloadable *only if you recorded the inventory* |
| **`wp-config.php` copy** | DB creds, salts, hand-added constants | On both Clouve shapes it is generated from `WORDPRESS_*` env, so mostly yes — but fresh salts log every user out, and hand-added constants are gone |

Core files (`wp-admin/`, `wp-includes/`, root PHP) are **not** backup material — they come from the image.

## What each artifact needs, per channel

| Artifact | Channel | Available today? |
|---|---|---|
| SQL dump | **[TCP-mysql]** `mysqldump` from the agent container | **Yes, always** |
| `wp-content/` archive | **[shell-only — probe first]** file access inside the WordPress container | **No** — today's WordPress images ship no `clouve-ops` SSH account (see [shell-access.md](shell-access.md)) |
| `wp-config.php` copy | **[shell-only — probe first]** | **No** — same |
| Code inventory (plugins/theme, versions) | **[TCP-mysql]** — partial, see below | Yes |

Probe before planning; never write a backup promise that silently assumes a shell.

## The TCP-only reality

On today's images the only backup you can take yourself is the DB dump. Say this to the user in plain words before they rely on it.

A **DB-only backup protects against**: bad SQL, a botched plugin's data, a failed core schema migration, accidental content/user deletion, options corruption — anything whose damage lives in the database.

A **DB-only backup does NOT protect against**: loss or corruption of `wp-content/uploads/` (the dump holds the attachment *rows*, not the bytes), loss of plugin/theme code, loss of hand edits to `wp-config.php`, or the `wordpressdata` volume itself dying. After a volume loss, a DB-only backup restores a site full of 404 media.

### Mitigation 1 — always store a code inventory next to the dump [TCP-mysql]

With an inventory, plugin/theme *code* can be re-downloaded from wordpress.org at matching versions. Uploads cannot.

```sql
-- Active plugins (serialized array — save raw, never edit):
SELECT option_value FROM wp_options WHERE option_name='active_plugins';
-- Current theme:
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('template','stylesheet');
-- Schema version:
SELECT option_value FROM wp_options WHERE option_name='db_version';
-- Best-effort full plugin list WITH versions (standard WordPress behaviour: the update-check
-- transient's 'checked' map lists every installed plugin, when the check has run recently):
SELECT option_value FROM wp_options WHERE option_name='_site_transient_update_plugins';
```

### Mitigation 2 — route the user for the file half

- **[HTTP — the user's browser]** A vetted backup plugin installed via `/wp-admin` runs *inside* the web container and can archive `wp-content/` to a downloadable zip. Vet first per [playbooks/install-plugin.md](../playbooks/install-plugin.md) and its safety gate.
- If neither works, have the user ask Clouve support whether volume-level backup options exist for their plan — that is outside what this agent can see or promise.

## Taking the DB dump [TCP-mysql]

Store backups under `$HOME` (persistent across pod restarts; `/tmp` and `/clouve` are not). Discover env names first: `env | grep -iE 'wordpress|mysql|maria|host'`. Examples assume the default `wp_` prefix — confirm with `SHOW TABLES LIKE '%options';`.

```bash
mkdir -p "$HOME/backups"
ts=$(date +%Y%m%d-%H%M%S)
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysqldump \
    -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
    --single-transaction --quick \
    --default-character-set=utf8mb4 \
    "$WORDPRESS_DB_NAME" | gzip > "$HOME/backups/wordpress-$ts.sql.gz"
```

`--single-transaction` gives a consistent InnoDB snapshot without locking; `--quick` streams rows (matters for `wp_postmeta` and `wp_options` bloat). [scripts/backup.sh](../scripts/backup.sh) wraps this and records a manifest (size, table list, row counts) so a broken artifact is noticed before you need it.

### Shape B (vanilla compose, MySQL 8) caveats

- If the dump fails with `Access denied; you need (at least one of) the PROCESS privilege(s)`, add `--no-tablespaces` — standard MySQL 8 behaviour with an app-scoped user, and on this shape **root does not exist for anyone** (`MYSQL_RANDOM_ROOT_PASSWORD`).
- The agent's client is Debian's `default-mysql-client` (a MariaDB build, installed by this plugin's `install.sh`). Against MariaDB (Shape A) it is a native match. Against MySQL 8 it generally interoperates, but the server's default `caching_sha2_password` auth is a known friction point — verify with a cheap `SELECT 1` first; if auth fails with an unknown-auth-plugin error, surface it honestly (a client that supports that plugin is the likely fix — verify in-session rather than assuming this one does).

## Archiving `wp-content/` — [shell-only — probe first]

Probe: `SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new clouve-ops@"${WORDPRESS_HOST}" true` — expect failure on today's images. When a shell *does* exist:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh clouve-ops@"${WORDPRESS_HOST}" \
    "sudo tar -C /var/www/html --exclude='wp-content/cache/*' -czf - wp-content" \
    > "$HOME/backups/wp-content-$ts.tar.gz"
# And the config copy:
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh clouve-ops@"${WORDPRESS_HOST}" \
    "sudo cat /var/www/html/wp-config.php" > "$HOME/backups/wp-config-$ts.php"
```

`wp-content/cache/` (page-cache plugins) regenerates — exclude it. Never print `wp-config.php` contents into chat; it holds credentials and salts.

## Restore

Order matters (files first so the DB never references code/media that isn't there yet):

1. **Files** — `wp-content/` from the archive **[shell-only — probe first]**; without a channel see [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md) for what a DB-only restore means and how to route the file half.
2. **DB import** — **[TCP-mysql]**:
   ```bash
   gunzip -c "$HOME/backups/wordpress-<ts>.sql.gz" | MYSQL_PWD="$WORDPRESS_DB_PASSWORD" \
       mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME"
   ```
   `mysqldump` output includes `DROP TABLE IF EXISTS` per table, so the import replaces every dumped table. Tables *created after* the backup (e.g. by a since-installed plugin) survive the import — compare `SHOW TABLES` against the manifest and drop leftovers only under the schema-change gate in [SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow).
3. **Ownership** — `chown -R www-data:www-data wp-content` **[shell-only — probe first]**; skip when no file restore happened.
4. **Flush caches/rewrites** — **[TCP-mysql]** delete the `rewrite_rules` option (single row; WordPress regenerates it on the next request — standard behaviour) and clear expired transients per [caching.md](caching.md). With a shell: `wp cache flush && wp rewrite flush --hard`.

**Shape A note:** the installer entrypoint re-asserts `siteurl`/`home` from `WORDPRESS_SITE_URL` at every boot — after a restore, a platform restart both fixes a stale restored URL and hard-flushes rewrites. On Shape B nothing reconciles URLs; check them yourself (step canaries below, and [urls-and-migration.md](urls-and-migration.md)).

**Cross-version restore:** running code newer than the dump's `db_version` → complete the restore, then run the DB update ([upgrade.md](upgrade.md)). Running code *older* than the dump's `db_version` → stop; WordPress has no supported downgrade — get the matching image or an older backup.

## Verification canaries

Run after every restore (and record before every backup — the comparison is the point).

```sql
-- [TCP-mysql] row counts:
SELECT 'wp_posts' t, COUNT(*) c FROM wp_posts
UNION ALL SELECT 'wp_users', COUNT(*) FROM wp_users
UNION ALL SELECT 'wp_comments', COUNT(*) FROM wp_comments
UNION ALL SELECT 'wp_options', COUNT(*) FROM wp_options
UNION ALL SELECT 'wp_postmeta', COUNT(*) FROM wp_postmeta;
-- [TCP-mysql] option spot-checks:
SELECT option_name, option_value FROM wp_options
 WHERE option_name IN ('siteurl','home','blogname','template','stylesheet','db_version');
```

```bash
# [HTTP] probes (a 301 to the public URL is normal for in-pod curl):
curl -sSI "http://${WORDPRESS_HOST}/" | head -1
curl -sSI "http://${WORDPRESS_HOST}/wp-login.php" | head -1
curl -sS  "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>'
```

Then pick a recent attachment (`SELECT guid FROM wp_posts WHERE post_type='attachment' ORDER BY ID DESC LIMIT 3;`) and probe one media URL — after a DB-only restore this is exactly the canary that exposes missing upload bytes. The only true test of a backup is restoring it somewhere; anything less is hope-driven.
