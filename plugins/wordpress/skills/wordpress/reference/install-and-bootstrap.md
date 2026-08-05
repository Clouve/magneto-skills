# Install & Bootstrap

How a fresh WordPress site comes up differs completely between the two shapes: the Clouve-packaged app **auto-installs itself** from env at first boot (`wp core install` inside the entrypoint), while a developer-submitted compose serves the **browser installer** and waits for a human. Establish the shape first ([stack-and-runtime.md](stack-and-runtime.md)); the install-state probes below work on both.

## The "is it installed?" sentinel

WordPress has no marker file — **install state is the populated `wp_options` table.** The Clouve entrypoint's own probe is literally:

```sql
-- [TCP-mysql] the entrypoint's exact check (prefix HARDCODED to wp_,
-- ignoring WORDPRESS_TABLE_PREFIX — SKILL.md principle 10)
SELECT 1 FROM wp_options LIMIT 1;
```

Errors (table missing) ⇒ not installed; any row ⇒ installed. For your own diagnosis, use the richer probe:

```sql
-- [TCP-mysql]
SELECT option_name, option_value FROM wp_options
 WHERE option_name IN ('siteurl','home','blogname','db_version');
SELECT COUNT(*) FROM wp_users;
```

A healthy install has all four options populated and at least one user. `db_version` is the **schema** version; the **code** version is not in the DB at all — infer it over [HTTP] from the `<generator>` tag in `/feed/` or the meta generator on the front page (`readme.html` is often blocked). The code/schema pairing matters for upgrades ([upgrade.md](upgrade.md)).

Over HTTP alone, "not installed" is unmistakable:

```bash
# [HTTP] an uninstalled site redirects to the browser installer
curl -sI "http://${WORDPRESS_HOST}/" | grep -iE '^(HTTP|location)'
# → Location: .../wp-admin/install.php  ⇒ not installed
```

## Shape A — auto-install from env

First boot on the packaged app, per the [entrypoint](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh) (full sequence in [architecture.md](architecture.md)): core files extracted and `wp-config.php` generated from `WORDPRESS_*` env → DB wait → `wp_options` probe finds nothing → fresh-install path runs:

```
wp core install --url --title --admin_user --admin_password --admin_email --skip-email --allow-root
```

fed from `WORDPRESS_SITE_URL`, `WORDPRESS_SITE_TITLE`, `WORDPRESS_ADMIN_USER` (`{firstName}_{lastName}`), `WORDPRESS_ADMIN_PASSWORD` (platform-generated), `WORDPRESS_ADMIN_EMAIL` — then timezone `UTC`, permalinks `/%postname%/`, hard rewrite flush. `--skip-email` means no "new site" email is sent; the admin credentials live in the platform's deployment config, and the user reads them from the Clouve UI. Note the standing caveat: those env vars reflect *first-install* values — a later in-app password change does **not** update them ([rotate-admin-credentials playbook](../playbooks/rotate-admin-credentials.md)).

No human action is required; by the time the healthcheck goes green the site should answer logged-out traffic on `/`.

## Shape B — browser installer

The stock image writes `wp-config.php` from env and starts Apache; with an empty DB every request redirects to `/wp-admin/install.php`, where whoever arrives first picks the site title and admin credentials. Two operator implications:

- **The install page is unauthenticated.** Between deploy and someone completing the wizard, *anyone* who reaches the URL can claim the site (standard WordPress behavior, not Clouve-specific). A Shape B deploy that sat uninstalled for a while deserves a suspicious `wp_users` check afterwards.
- **Nobody else will finish it.** If the user reports "my new site shows a setup screen," that is not a fault — walk them through the wizard; you cannot complete it for them from the agent (it wants their chosen credentials), though you *can* confirm DB readiness first: `[TCP-mysql] SELECT 1` against `${WORDPRESS_DB_HOST}` with the `WORDPRESS_DB_*` creds.

## First-boot races and their signatures (Shape A)

The entrypoint runs `set +e` — apart from two explicit exits, failures are logged and Apache starts anyway. **Pod Running ≠ installed.** The known races:

| Symptom | Cause | What happens next |
|---|---|---|
| Container exits (code 1) early, restarts, comes good | Step-1 race: the official entrypoint gets a fixed 5s to extract core; on a slow/cold volume `wp-load.php` isn't there yet → explicit `exit 1` | Usually self-heals on restart — extraction resumes/completes. Persistent crash-looping here means a genuinely stuck volume: surface it, route to support |
| Container exits after ~5 minutes of retry logs | DB wait exhausted (60 × 5s of `SELECT 1`) → explicit `exit 1` | Check the DB container; note the marketplace manifest **disables the DB healthcheck**, so the platform won't restart a wedged DB for you |
| Site up but `wp_options` half-empty, admin login fails | A step *after* the explicit exits failed under `set +e` (e.g. `wp core install` errored) and Apache started anyway | Run the verification below; a broken fresh install with **no content** is a candidate for a clean re-deploy via the platform rather than in-place surgery |
| Two families of tables: `wp_*` **and** `<prefix>_*` | Non-default `WORDPRESS_TABLE_PREFIX`: the hardcoded `wp_options` probe says "not installed" every boot → repeated `wp core install` created a second site in the same DB | Detect with `[TCP-mysql] SHOW TABLES;`. Do not improvise a merge — this is a backup-then-support situation; the prevention is principle 10 |

## Verifying a healthy install (TCP + HTTP only — the live channels)

[scripts/verify-health.sh](../scripts/verify-health.sh) wraps these; the manual sequence:

1. **[HTTP]** `curl -sI "http://${WORDPRESS_HOST}/"` → `200` (or a `30x` to the site's canonical URL — follow it once with `-L` and expect `200`). A `Location: …/wp-admin/install.php` means not installed; `500`/`503` → [diagnose-500 playbook](../playbooks/diagnose-500.md).
2. **[HTTP]** `curl -s "http://${WORDPRESS_HOST}/wp-login.php" | grep -c loginform` → `1`. Confirms PHP executes and the auth stack renders, beyond a cached front page.
3. **[TCP-mysql]** `siteurl` and `home` equal the expected deployment URL (on Shape A: exactly `WORDPRESS_SITE_URL` — if not, the reconciler hasn't run since the value changed, or you are not on the shape you think).
4. **[TCP-mysql]** `SELECT option_value FROM wp_options WHERE option_name='db_version';` returns a number, and `SELECT COUNT(*) FROM wp_users;` ≥ 1 with the expected admin login present (`SELECT user_login FROM wp_users LIMIT 5;` — read-only, fine).
5. **[HTTP]** `curl -s "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*'` → the expected code version (`6.9` on the current packaged image — the tag is `wordpress:6.9.0`, but core omits the trailing `.0` on `x.y.0` releases; patch releases like `6.9.1` match exactly). Code version ahead of what `db_version` implies means a pending schema update ([upgrade.md](upgrade.md)).
6. **[HTTP]** Fetch one known permalink (any `SELECT post_name FROM wp_posts WHERE post_status='publish' LIMIT 1` over **[TCP-mysql]**, then `curl -sI "http://${WORDPRESS_HOST}/<post_name>/"`) → `200`. Proves rewrites/`.htaccess` are live, not just the front page.

A shell channel would add file-level checks (uploads ownership, `wp core verify-checksums`) — **[shell-only — probe first]**, and today's images don't have one, so treat the six checks above as the complete achievable verification and say so rather than implying more was checked.

## What install does NOT give you

- **No cron registration** — neither shape ships a cron daemon; schedules ride on HTTP traffic ([cron-and-tasks.md](cron-and-tasks.md)).
- **No plugins/themes beyond the bundled defaults** — anything else arrives via `/wp-admin` afterwards ([install-plugin playbook](../playbooks/install-plugin.md)).
- **No TLS in-container** — Apache serves plain :80; HTTPS is the platform ingress's job. Mixed-content complaints are a URL question ([urls-and-migration.md](urls-and-migration.md)), not an Apache one.
- **No hardening** — fresh installs get the defaults; walk [harden-fresh-install playbook](../playbooks/harden-fresh-install.md) as the follow-up.
- **No multisite** — the Clouve packaging is single-site only (no `WP_ALLOW_MULTISITE` anywhere); treat multisite requests as out of scope and route to support.
