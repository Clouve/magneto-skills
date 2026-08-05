# Playbook: Upgrade WordPress

Use this playbook when the tenant asks to upgrade WordPress core, or when you find a pending DB update (`/wp-admin` shows "Database Update Required" while the front-end serves normally). Background and the version invariant: [reference/upgrade.md](../reference/upgrade.md).

The core-upgrade safety gate applies throughout ([SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow)): backup + invariant checked + user ack, and on the packaged shape core comes from the image — route through the platform.

## Preconditions

- [ ] **Env names discovered**: `env | grep -iE 'wordpress|mysql|maria|host'`. Examples below assume the `WORDPRESS_DB_*` set, sibling host `WORDPRESS_HOST=wordpress`, and the default `wp_` prefix (confirm: `SHOW TABLES LIKE '%options';`).
- [ ] **Channel inventory done** ([reference/shell-access.md](../reference/shell-access.md)). Probe SSH: `SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new clouve-ops@"${WORDPRESS_HOST}" true` — on today's WordPress images expect **failure**; plan on TCP + HTTP only.
- [ ] **Shape identified** ([reference/stack-and-runtime.md](../reference/stack-and-runtime.md)). Quick check: `WORDPRESS_SITE_URL`/`WORDPRESS_ADMIN_*` in env + MariaDB from `SELECT VERSION();` ⇒ Shape A (Clouve-packaged); vanilla env + MySQL 8 ⇒ Shape B (developer compose).
- [ ] **Backup taken now** — and the user has explicitly acknowledged its scope: on today's channels it is **DB-only** ([reference/backup-restore.md](../reference/backup-restore.md) — what that does and does not protect). Do not proceed on a stale or unacknowledged backup.
- [ ] **Release notes read** — the target release's announcement on wordpress.org/news and its page under wordpress.org/documentation. Note new PHP/DB floors; compare against this stack ([reference/stack-and-runtime.md](../reference/stack-and-runtime.md)).
- [ ] **Version invariant read and recorded** (step 1) — know your starting point before anything moves.

## Steps

### 1. Capture the pre-upgrade state — [TCP-mysql] + [HTTP]

```bash
mkdir -p "$HOME/backups"; ts=$(date +%Y%m%d-%H%M%S)

# 1a. DB schema version + identity options:
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -e "
  SELECT option_name, option_value FROM wp_options
   WHERE option_name IN ('db_version','siteurl','home','template','stylesheet');"

# 1b. Code version, inferred over HTTP (version.php is not in the DB):
curl -sS "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>'

# 1c. Canary row counts — capture, you'll compare after:
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -e "
  SELECT 'wp_posts' t, COUNT(*) c FROM wp_posts
  UNION ALL SELECT 'wp_users', COUNT(*) FROM wp_users
  UNION ALL SELECT 'wp_comments', COUNT(*) FROM wp_comments
  UNION ALL SELECT 'wp_options', COUNT(*) FROM wp_options
  UNION ALL SELECT 'wp_postmeta', COUNT(*) FROM wp_postmeta;" | tee "$HOME/backups/pre-upgrade-canaries-$ts.txt"

# 1d. Save the plugin/theme registration (restore material if isolation is needed later):
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -sN \
    -e "SELECT option_value FROM wp_options WHERE option_name='active_plugins';" \
    > "$HOME/backups/active_plugins-$ts.txt"
```

Put the numbers in chat — you will compare after.

### 2. Take the backup — [TCP-mysql]

```bash
bash "$SKILL_DIR/scripts/backup.sh"
```

Confirm the dump exists, is non-trivially sized, and its manifest table count looks sane. Restate the DB-only caveat to the user and get the ack before proceeding.

### 3. Ship the new core files — branch by shape

**Shape A (Clouve-packaged): route through the platform.** The core version is the pinned image tag; you do not change it from inside the pod. Tell the user:

> WordPress core on this app comes from the Clouve app image. Trigger the app update from the Clouve platform (or ask Clouve support when a newer app version ships). Your data volumes are preserved; on restart the entrypoint refreshes the core files to the new version.

If asked to `wp core update` in place instead: decline and explain the image drift ([reference/upgrade.md](../reference/upgrade.md) → "Why `wp core update` drifts").

**Shape B (developer compose): the developer owns the tag.** The upgrade is a compose edit — bump the image tag (e.g. `wordpress:6.8-apache` → the target) and republish/redeploy through the platform. The stock entrypoint refreshes core files on the volume the same way.

**Then wait for the container to come back** — [HTTP]:

```bash
until curl -sfo /dev/null "http://${WORDPRESS_HOST}/"; do sleep 5; done; echo up
```

### 4. Run the DB schema update

Pick the first channel that exists:

- **[HTTP — the user's browser, always available]** Have the user open `/wp-admin`. If a "Database Update Required" screen appears, they click **Update WordPress Database**. The front-end keeps serving meanwhile — no panic window.
- **[shell-only — probe first]** `wp core update-db --path=/var/www/html --allow-root` (DB-only, no ownership side effects). On today's images this channel does not exist; on Shape B it never will (no wp-cli in the vanilla image).
- **Minor release?** `db_version` often doesn't change and no prompt appears — that is success, not a stuck update.

### 5. Verify — [TCP-mysql] + [HTTP]

```bash
# 5a. Invariant: db_version advanced (or unchanged for a schema-less minor):
MYSQL_PWD="$WORDPRESS_DB_PASSWORD" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -sN \
    -e "SELECT option_value FROM wp_options WHERE option_name='db_version';"

# 5b. Code version shows the target:
curl -sS "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>'

# 5c. Probes: home, login, one permalink, one media URL from
#     SELECT guid FROM wp_posts WHERE post_type='attachment' ORDER BY ID DESC LIMIT 1;
curl -sSI "http://${WORDPRESS_HOST}/" | head -1
curl -sSI "http://${WORDPRESS_HOST}/wp-login.php" | head -1
```

Re-run the step 1c canary query — **no count may drop**. A drop in `wp_posts`/`wp_users`/`wp_postmeta` is the stop-and-rollback case: [rollback-from-backup.md](rollback-from-backup.md).

### 6. If the site is stuck on "Briefly unavailable for scheduled maintenance"

An interrupted update left `.maintenance` in the docroot. **Standard WordPress behaviour: it auto-expires after 10 minutes** — the honest first move on today's channels is to wait it out, then re-verify. Removing it earlier is **[shell-only — probe first]** (`rm /var/www/html/.maintenance`); with no file channel, say so plainly rather than improvising. Still 503 after the window → [diagnose-500.md](diagnose-500.md).

### 7. Plugin and theme updates after core

Core first, then extensions — route the user to `/wp-admin` → Dashboard → Updates **[HTTP — user's browser]**, or `wp plugin update` / `wp theme update` **[shell-only — probe first]**. Never by SQL (install/update gate in [SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow)). Mechanics and the root-owned-files trap: [reference/upgrade.md](../reference/upgrade.md).

### 8. Tell the user

- Source → target version (generator before/after, `db_version` before/after).
- Backup location and its scope (DB-only, if so — repeat it).
- Canary comparison: any deltas and whether they're expected.
- Plugins/themes still showing available updates.
- Anything you had to skip for lack of a channel, in plain words.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| "Database Update Required" reappears after clicking Update | The schema update failed mid-run | Re-run once; if it persists, check `wp-content/debug.log` (enabling it needs a file channel; reading is HTTP-fetchable when it exists) or go to [diagnose-500.md](diagnose-500.md); rollback if unresolved |
| White screen / fatal after upgrade | A plugin or theme incompatible with the new core | WSOD isolation via saved `active_plugins` (step 1d is your restore value) — gate: record first + user ack; see [reference/troubleshooting.md](../reference/troubleshooting.md) |
| Front page fine, `/wp-admin` 500s | Same as above, admin-side code path | Same isolation path |
| Generator still shows the old version | Page cache serving stale HTML, or the image never actually changed | Check `/feed/` (rarely cached), then confirm the platform update really rolled; purge caches per [reference/caching.md](../reference/caching.md) |
| 503 maintenance page > 10 min | Not the `.maintenance` gate anymore (or repeated crash-looping updates) | [diagnose-500.md](diagnose-500.md) |
| `db_version` *ahead* of the code | Image was rolled back without the DB | Unsupported downgrade — [rollback-from-backup.md](rollback-from-backup.md), Case C |
| Permalinks 404 after upgrade | Stale rewrite rules | Delete the `rewrite_rules` option row (single row; regenerates) — [TCP-mysql]; or `wp rewrite flush --hard` with a shell |

## After-action

Capture anything WordPress-specific that surprised you per [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill) — especially a plugin that needed special handling, a canary that misled, or a shape difference not yet in [reference/upgrade.md](../reference/upgrade.md).
