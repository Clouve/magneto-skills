# Upgrade

"Upgrading WordPress" is three separate layers, each with its own mechanics and channels:

1. **Core files** — come from the image on both Clouve shapes; refreshed by the official entrypoint when the image version changes.
2. **The DB schema** — reconciled by WordPress's own updater (`/wp-admin` prompt or `wp core update-db`) *after* the code changes.
3. **Plugins and themes** — code on disk: on Shape A the persistent `wordpressdata` volume; on Shape B persistent only if the developer's compose declares a volume for `/var/www/html` ([stack-and-runtime.md](stack-and-runtime.md)). Updated through `/wp-admin` or wp-cli, never by SQL.

## The version invariant

| Value | Where it lives | How to read it |
|---|---|---|
| **Code version** | `$wp_version` in `wp-includes/version.php` of the running code (the same file's `$wp_db_version` is the schema target) — **not stored in the DB** | see channel table below |
| **DB schema version** | `wp_options` row `option_name='db_version'` | **[TCP-mysql]** one SELECT |

When `db_version` is behind the code's `$wp_db_version`, a DB update is **pending**: `/wp-admin` gates on a "Database Update Required" screen until it runs — but unlike stricter systems (e.g. Moodle), **the front-end keeps serving** the whole time. A pending update is quiet; check for it, don't wait to trip over it.

When `db_version` is *ahead* of the running code (someone rolled the image back without restoring the DB), you are in unsupported-downgrade territory — WordPress may limp along on a minor skew, but the supported answer is matching code or a restored backup. See [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md).

### Reading each value, per channel

```sql
-- [TCP-mysql] DB schema version — always available:
SELECT option_value FROM wp_options WHERE option_name='db_version';
```

```bash
# [HTTP] code version — inference only, since version.php is not in the DB:
curl -sS "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>'
#   → <generator>https://wordpress.org/?v=6.9</generator>
#   404 on the pretty /feed/ path (Shape B) can mean plain permalinks, not a missing feed — fall back to:
#   curl -sS "http://${WORDPRESS_HOST}/?feed=rss2" | grep -o '<generator>[^<]*</generator>'
curl -sS "http://${WORDPRESS_HOST}/" | grep -io '<meta name="generator"[^>]*>'   # themes/security plugins often strip this
# readme.html carries the version too but is frequently blocked — don't rely on it.
```

```bash
# [shell-only — probe first] exact answer, when a shell exists:
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh clouve-ops@"${WORDPRESS_HOST}" \
    "wp core version --path=/var/www/html --allow-root"
```

There is no clean public mapping from a `db_version` number to a release; the authoritative pair is `$wp_version`/`$wp_db_version` in [wp-includes/version.php](https://github.com/WordPress/WordPress/blob/master/wp-includes/version.php) of the target release. Over TCP/HTTP alone, verify upgrades by *movement* (did `db_version` advance? does the generator show the target?) rather than by absolute numbers.

## Core updates on Shape A (Clouve-packaged) — image-first

The packaged app pins `wordpress:6.9.0`. `/var/www/html` is the persistent `wordpressdata` volume; the [official image's entrypoint](https://github.com/docker-library/wordpress) (wrapped untouched by the [Clouve installer entrypoint](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh)) refreshes the core files on that volume when the image's WordPress version changes. So the core upgrade path is:

**new image (platform) → entrypoint refreshes core files at boot → you run the DB update.**

The image tag is Clouve's to change — **route the user through the platform** (marketplace app update), never upgrade core in place.

### Why `wp core update` drifts (refuse it)

`wp core update` (and WordPress's own background auto-updater — minor releases auto-update by default, standard WordPress behaviour) rewrites core files on the *volume*, ahead of what the image ships. The running site and the image now disagree; the next image-driven boot can partially re-assert older files over newer ones. On the packaged shape the image is the single source of truth for core — an in-place core update is drift, not an upgrade. If the site self-updated a minor version, note it, don't fight it — but surface that the image is now behind.

## Core updates on Shape B (developer compose)

Same image-first logic, different owner: the developer controls the tag (e.g. `wordpress:6.8-apache`). The upgrade is: bump the tag in the compose, republish/redeploy through the platform, then run the DB update. The stock entrypoint refreshes core files the same way. There is no wp-cli and no mysql client in this container, so the shell path does not exist even if SSH someday does — the `/wp-admin` DB-update prompt is the working path.

## The DB update step

After the code changes, reconcile the schema:

- **[HTTP — the user's browser]** Always available: `/wp-admin` shows "Database Update Required"; one click runs it. Your `curl` has no admin session — route the user.
- **[shell-only — probe first]** `wp core update-db --path=/var/www/html --allow-root` (DB-only; no file ownership side effects).
- **Minor releases usually ship no schema change** — `db_version` staying put with no prompt is success, not failure.

## Plugin and theme updates

- **[HTTP — the user's browser]** `/wp-admin` → Dashboard → Updates. This is the always-available path and uses WordPress's direct filesystem method — it works when `wp-content/` is writable by `www-data`.
- **[shell-only — probe first]** `wp plugin update <slug>` / `wp theme update <slug>` / `--all`. After any `--allow-root` operation, chown what it wrote: the Clouve entrypoint re-chowns **only `wp-content/uploads`** at boot; root-owned leftovers elsewhere in `wp-content` persist and later break `/wp-admin` updates with "Could not create directory".
- **[TCP-mysql]** — **no.** Plugins/themes are code on disk; SQL can only flip activation state, not install or update files. The install/update gate in [SKILL.md → Safety gates](../SKILL.md#safety-gates-enforce-these-in-every-flow) applies: trusted source + backup + user ack, never via SQL. Vet per [playbooks/install-plugin.md](../playbooks/install-plugin.md).
- Per-plugin auto-updates (opt-in toggles in `/wp-admin` since WP 5.5 — standard behaviour) are the low-touch answer for security patches on sites nobody watches.

## The `.maintenance` file

Every `/wp-admin` or wp-cli update drops a `.maintenance` file in the docroot for the duration; an interrupted update leaves it behind and the whole site answers **"Briefly unavailable for scheduled maintenance. Check back in a minute."** (503).

- **Standard WordPress behaviour: the file auto-expires.** WordPress ignores a `.maintenance` older than 10 minutes, so the site un-bricks itself — the file stays on disk but stops mattering. If a user reports this error, the first honest answer is often "wait out the window, then verify".
- Removing it sooner is **[shell-only — probe first]**: `rm /var/www/html/.maintenance`. On today's images there is no file channel — say so plainly and fall back to the 10-minute expiry. On Shape A a container restart does **not** clear it (the docroot sits on the persistent `wordpressdata` volume); on Shape B that depends on whether the compose declares a `/var/www/html` volume — without one, a restart wipes the docroot, `.maintenance` included (along with everything else non-core; see [stack-and-runtime.md](stack-and-runtime.md)).
- Still 503 after 10+ minutes → it is not (or no longer) the `.maintenance` gate; go to [playbooks/diagnose-500.md](../playbooks/diagnose-500.md).

## Rollback

A failed upgrade rolls back via **restore from backup** — WordPress has no supported schema downgrade. The implication: the backup must be taken *immediately before* the upgrade, and on today's channels that backup is DB-only ([backup-restore.md](backup-restore.md) — make sure the user understood that before starting). Procedure: [playbooks/upgrade-wordpress.md](../playbooks/upgrade-wordpress.md) forward, [playbooks/rollback-from-backup.md](../playbooks/rollback-from-backup.md) back.
