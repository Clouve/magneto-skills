# Troubleshooting

Failure modes seen in the wild and the **first** thing to check for each. Stop after one diagnostic step — if the answer isn't obvious, escalate the diagnosis flow rather than running 5 tools at once. Every probe is channel-labeled ([reference/shell-access.md](shell-access.md)); remember there is **no shell and no wp-cli** on today's WordPress deployments, so each entry gives the live TCP/HTTP path and says plainly when only a file channel or support can finish the job.

`${WORDPRESS_HOST}` / `${WORDPRESS_DB_*}` below are the discovered names — run `env | grep -iE 'wordpress|mysql|maria|host'` first.

## "The site is down"

Split web from DB first — two probes, one conclusion:

1. **[HTTP]** Is the web container answering at all?
   ```bash
   curl -sI -m 10 "http://${WORDPRESS_HOST}/"
   ```
   - Connection refused / timeout → the web container is down or not listening. You cannot restart it — that's a platform action; escalate with the curl output.
   - `500` → PHP-land problem; go to [playbooks/diagnose-500.md](../playbooks/diagnose-500.md).
   - `503` → likely maintenance mode; see "Stuck in maintenance mode" below.
   - `200` but the body says `Error establishing a database connection` → next probe.

2. **[TCP-mysql]** Is the DB answering?
   ```bash
   MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" -e "SELECT 1"
   ```
   - Refused/timeout → DB container down or still starting. Platform action; escalate.
   - Auth error → see "mysql client can't authenticate" below before concluding anything.
   - `SELECT 1` succeeds but WordPress still shows the DB-error page → the *web container's* view of the DB differs from yours: wrong `WORDPRESS_DB_*` values in its env, or in-pod DNS. The official image's generated `wp-config.php` reads `WORDPRESS_DB_*` from the environment at request time (official-image behavior), so compare the env you discovered against what the page implies — and escalate env mismatches to the platform.

## White screen / "There has been a critical error on this website"

A PHP fatal. Since WP 5.2 the fatal handler serves that message with a 500; a truly blank 200 usually means output was killed earlier. Either way the ladder is [playbooks/diagnose-500.md](../playbooks/diagnose-500.md) — including the gated no-shell plugin-isolation and theme-fallback steps. WordPress also tries to email a recovery-mode link to the admin address; ask the user to check that inbox, but don't rely on mail leaving these pods.

## Redirect loop

Usually a scheme/host mismatch between what WordPress thinks it is (`siteurl`/`home`) and what the ingress serves.

1. **[HTTP]** See the loop:
   ```bash
   curl -sI "http://${WORDPRESS_HOST}/" | grep -i '^location'
   ```
   Caveat: you probe plain HTTP on :80 while users arrive via the TLS-terminating ingress — a single redirect to `https://` on your direct probe is *normal*. A loop is `https → http → https…` or `www ↔ non-www` when following the public URL (`curl -sIL --max-redirs 5 https://<public-url>/`, if egress allows).
2. **[TCP-mysql]** What does WordPress think it is?
   ```sql
   SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');
   ```
3. Branch on shape ([SKILL.md](../SKILL.md) principle 4):
   - **Shape A**: compare against `printenv WORDPRESS_SITE_URL`. The entrypoint re-asserts both options from that env var **every boot** — hand-fixing the option only survives until the next restart. If the env var itself is wrong, that's a platform config problem; escalate. If the options merely drifted from a correct env var, a pod restart self-heals them.
   - **Shape B**: nothing reconciles these. Fix via the gated flow in [playbooks/change-site-url.md](../playbooks/change-site-url.md) (`siteurl`/`home` are plain scalars — safe for SQL; embedded content URLs are not).

## 500 right after a plugin update

The most common 500 there is. The plugin's new code fatals on load; because there's no shell, you cannot read the fatal — go straight to evidence-then-isolate:

1. **[HTTP]** Confirm scope: front page vs `/wp-login.php` vs a static asset (see the ladder's Step 2).
2. **[TCP-mysql]** Read **and save** the plugin list, then — gated ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow): "Deactivate all plugins") — write the empty list. Full procedure with the exact SQL: [playbooks/diagnose-500.md](../playbooks/diagnose-500.md) Step 4.
3. Site back? Have the user reactivate plugins one at a time from `/wp-admin` (the UI reactivation is the honest re-bisect — never rebuild the serialized array by hand, principle 6). The last one they activate before it breaks again is the culprit; roll it back from `/wp-admin` or wait for the author's fix.

## Media 404s / broken images

Two distinct causes — check which you have before touching anything:

1. **Restore with the `wp-content/` half missing.** The DB references files that aren't on disk ([SKILL.md](../SKILL.md) principle 1).
   ```sql
   -- [TCP-mysql] Recent attachments the DB believes in:
   SELECT ID, guid FROM wp_posts WHERE post_type='attachment' ORDER BY ID DESC LIMIT 5;
   ```
   ```bash
   # [HTTP] Do they actually serve?
   curl -sI "http://${WORDPRESS_HOST}/wp-content/uploads/<path-from-guid>"
   ```
   All 404 → the uploads tree is missing/stale. Recovery needs the file half of a backup restored — a file channel you don't have; route per [reference/backup-restore.md](backup-restore.md) and support.
2. **Uploads permissions** — *new* uploads fail while old media serves. On Shape A the entrypoint re-chowns `wp-content/uploads` to `www-data` on **every boot**, so a platform-side pod restart is the no-shell fix; if uploads still fail after a restart, escalate. On Shape B no reconciler exists — a perms fix needs a file channel; route to support.

## Lost admin access

1. **[TCP-mysql]** Establish which accounts exist (read-only, always safe):
   ```sql
   SELECT ID, user_login, user_email FROM wp_users ORDER BY ID LIMIT 10;
   ```
2. **Shape A**: the platform injected `WORDPRESS_ADMIN_USER` / `WORDPRESS_ADMIN_PASSWORD` at install. Those env values are the *initial* credentials — a manual change in `/wp-admin` is **not** reflected back into env, so a stale env password proves nothing. Never print the password env var into chat.
3. Password-reset email requires working outbound mail — not guaranteed from these pods; try it, don't rely on it.
4. The live no-shell reset is the documented MD5 fallback — WordPress accepts an MD5 hash in `wp_users.user_pass` and upgrades it on next login. It is **gated** ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow): confirm the username, confirm the user is contactable, print the exact SQL, get ack): see [playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md). With a (future) shell, `wp user update <login> --user_pass=...` is the better tool.

## Stuck in maintenance mode

Symptom: every page is `503` with *"Briefly unavailable for scheduled maintenance. Check back in a minute."* — an interrupted core/plugin update left `.maintenance` in the docroot.

- Core writes a timestamp into the file and ignores it once it's roughly 10 minutes old, so most "stuck" states self-clear — **[HTTP]** re-probe after 10 minutes before doing anything.
- If it persists past that, removing the file needs a file channel — which doesn't exist today. Options, in order: wait out one more probe cycle, platform-side pod restart (Shape A's docroot is a persistent volume, so a restart does **not** reliably remove the file — say so honestly), support ticket.
- Then find out *which* update was interrupted before it gets retried blind — see [reference/upgrade.md](upgrade.md).

## Memory exhaustion

Symptom: intermittent 500s on heavy admin screens, large imports, or big uploads; fatals name `Allowed memory size ... exhausted` — which you cannot read without a log channel, so diagnose by pattern (heavy page → 500, light pages → 200).

- **Shape A** ships `memory_limit=512M`, `upload_max_filesize=100M`, `post_max_size=100M` via `/usr/local/etc/php/conf.d/wordpress.ini`. If 512M is genuinely exceeded, the fix is finding the hungry plugin/operation — not raising limits. Never patch container resources; capacity is platform-managed and paid ([SKILL.md](../SKILL.md) principle 11).
- **Shape B** runs the stock image — PHP's default limit (commonly 128M, but verify rather than assume) plus WordPress's own `WP_MEMORY_LIMIT` defaults. Raising it needs a `wp-config.php` or image change: the developer who owns the compose updates their image; from here it's recommend-and-route.

## mysql client can't authenticate (Shape B / MySQL 8)

MySQL 8's default auth plugin is `caching_sha2_password`, and the client this plugin installs is Debian's `default-mysql-client` — the MariaDB client. If the connection fails with an auth-plugin error (e.g. mentioning `caching_sha2_password`), the likely story is a client/plugin capability gap, **not** a broken site — WordPress itself connects via PHP mysqli and is unaffected. Verify rather than assume: recent MariaDB clients may handle it; if yours doesn't, the fallback is a client that supports the plugin (unverified in this environment — treat as a lead, not a fact). Also remember `MYSQL_RANDOM_ROOT_PASSWORD`: there is no root account to fall back to, for anyone, ever. Capture what you learn to [learnings.md](../learnings.md).

## Pod is Running but the site is broken (Shape A boot half-failures)

The Shape A entrypoint runs `set +e` — most boot errors are logged (to container stderr, which you can't read) and **Apache starts anyway**. A Running pod is not evidence of a healthy install ([SKILL.md](../SKILL.md): verify with [scripts/verify-health.sh](../scripts/verify-health.sh), not liveness). Patterns:

| Symptom | Likely half-failure | Probe |
|---|---|---|
| Core asset 404s, odd fatals | The fixed 5s window for the official entrypoint raced a slow volume — core files half-extracted | **[HTTP]** `curl -sI .../wp-includes/js/jquery/jquery.min.js` → 404 |
| Browser installer showing on a "fresh" deploy | `wp core install` failed after Apache start | **[TCP-mysql]** `SHOW TABLES LIKE 'wp\_%'` → empty/partial |
| A second, empty-looking site atop real data | Non-default `WORDPRESS_TABLE_PREFIX` — install detection probes hardcoded `wp_options`, so every boot re-installs | **[TCP-mysql]** `SHOW TABLES` → two prefix families |
| Old URL still serving after a domain change | URL self-heal step errored mid-boot | **[TCP-mysql]** compare `siteurl`/`home` to `printenv WORDPRESS_SITE_URL` |

A pod restart re-runs the whole sequence and often self-heals the first and last rows — but a half-extracted tree can fool the official entrypoint's presence checks, so if one restart doesn't fix it, stop and escalate rather than restart-looping. The prefix case is principle 10 territory: **refuse** to "fix" it live; it needs platform + support coordination. Entrypoint source: [entrypoint.sh](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh).

## "Magneto Agent can't reach the wordpress container"

Out of skill scope — that's a Clouve platform / pod networking issue, not a WordPress issue. Confirm with `curl -v http://${WORDPRESS_HOST}/` from the agent. If it's connection refused / DNS fail / 0 bytes, it's not WordPress.

## When to escalate to Clouve ops

- Anything needing a pod restart, env-var change, storage, resources, or ingress — you can't do these, and capacity is paid (principle 11).
- Anything whose fix needs a file channel that doesn't exist: `.maintenance` removal, `wp-config.php` edits, uploads perms on Shape B, restoring the `wp-content/` half of a backup, reading fatals.
- Anything pointing outside the wordpress / DB containers (networking, ingress, certs).

Surface enough detail for a support ticket: shape, code version (HTTP-inferred) + `db_version`, exact curl status lines, the SELECT evidence, scope of users affected. Do NOT paste secrets (DB password, admin password env, Anthropic key) or dump contents.
