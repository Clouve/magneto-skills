# Playbook: Harden a fresh install

Use this on a brand-new WordPress site, or any time the tenant asks "is this safe to expose?" It walks the checks and settings to apply before letting the public in.

This is a **checklist, not a linear recipe** — and, more than any other playbook in this skill, it is dominated by the channel reality: from the agent container you can *detect* most weaknesses over **[HTTP]** and **[TCP-mysql]**, but most of the *fixes* live in `wp-config.php`, in web-server config, or behind `/wp-admin` — a **file channel** you almost certainly do not have today. So each item below is labeled with (a) the channel that detects it and (b) whether the fix is live-from-here or **recommend-and-route**. Be honest with the user about which is which; do not narrate a fix you cannot apply.

The rationale behind every item is in [../reference/security.md](../reference/security.md). Gates cited below are defined in [SKILL.md → Safety gates](../SKILL.md).

## 0. Establish the deployment shape first — [TCP-mysql] + [shell-only — probe first]

Everything branches on this. Confirm which shape you are on and whether a shell exists, per [../reference/stack-and-runtime.md](../reference/stack-and-runtime.md) and [../reference/shell-access.md](../reference/shell-access.md):

```bash
env | grep -iE 'wordpress|mysql|maria|host'                       # discover sibling names/creds
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
  clouve-ops@"${WORDPRESS_HOST}" true && echo "shell: yes" || echo "shell: no (expected today)"
```

- **Shape A** (Clouve-packaged `wordpress` + `wordpress-mariadb`): the installer entrypoint already forces some good defaults every boot (`WP_DEBUG_DISPLAY` off, `siteurl`/`home` from the platform). Note which controls it hands you for free so you don't re-do them.
- **Shape B** (developer compose, vanilla image): nothing reconciles anything; more of this list is on the user.

If the shell probe fails (the normal case today), treat every file-channel item as recommend-and-route.

## 1. Confirm the site is reached over HTTPS — [TCP-mysql] + [HTTP]

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT option_name, option_value FROM wp_options
   WHERE option_name IN ('siteurl','home');"
```

Both should be `https://…`. On **Shape A** these are re-asserted from `WORDPRESS_SITE_URL` every boot — the platform owns them, so a mismatch is a platform/URL question, not a hand-edit (see [change-site-url.md](change-site-url.md)). On **Shape B** a wrong scheme locks users out of `/wp-admin`; fixing it is the change-site-url procedure, not an ad-hoc `UPDATE`. Confirm the front door actually serves HTTPS end-to-end via the platform ingress; the pod-internal `curl` is plain HTTP by design.

**Fix channel:** Shape A → platform (route). Shape B → [change-site-url.md](change-site-url.md).

## 2. Close user / login enumeration — [HTTP] detect, recommend-and-route fix

```bash
curl -sI "http://${WORDPRESS_HOST}/?author=1" | grep -i '^location:'      # leaks the login slug if it redirects to /author/<slug>/
curl -s  "http://${WORDPRESS_HOST}/wp-json/wp/v2/users" | head -c 300     # a JSON user array ⇒ enumerable
curl -s  "http://${WORDPRESS_HOST}/?rest_route=/wp/v2/users" | head -c 300 # plain-permalink fallback for the same check
```

A 404 on the pretty `/wp-json/…` path — especially on Shape B — may just mean plain permalinks, not that the route is hardened; confirm with the `?rest_route=` form before concluding it is blocked.

If either leaks usernames, the site hands an attacker half of every credential. **The fix is code/plugin (file channel), not data** — a hardening plugin or `mu-plugin` that blocks the REST `users` route, the author-archive redirect, and adds login-attempt limiting. Route the user to install a reputable limit-login/hardening plugin from `/wp-admin`. See [../reference/security.md → Login / user enumeration](../reference/security.md).

## 3. Probe `xmlrpc.php` — [HTTP] detect, recommend-and-route fix

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://${WORDPRESS_HOST}/xmlrpc.php"
# 405 ⇒ enabled/reachable (brute-force amplification + pingback DoS surface). 403/404 ⇒ blocked.
```

If it is live and the site does not need XML-RPC (no legacy mobile app, no Jetpack feature depending on it), recommend disabling it. Only a **web-server block** is a complete disable (file/config channel); the `xmlrpc_enabled` filter is partial. If XML-RPC *is* needed, route to a login-limiter instead. Full detail and the exact server snippets are in [../reference/security.md → `xmlrpc.php`](../reference/security.md).

## 4. Check the admin username and password strength — [TCP-mysql] detect

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT u.ID, u.user_login FROM wp_users u
   JOIN wp_usermeta m ON m.user_id = u.ID
   WHERE m.meta_key='wp_capabilities' AND m.meta_value LIKE '%administrator%';"
```

- A literal `admin` (or another guessable slug) → recommend the *create-new-admin, reassign, delete-old* dance in `/wp-admin`; WordPress can't rename a `user_login`, and you must never `UPDATE wp_users` to fake it (route).
- Weak/unknown admin password, or a lost one → [rotate-admin-credentials.md](rotate-admin-credentials.md) (that has a live [TCP-mysql] fallback and the confirm-identity gate).
- **Do not** trust `WORDPRESS_ADMIN_PASSWORD` as the current password — it is frozen at the platform's original value and does not track manual changes ([../reference/security.md → the env trap](../reference/security.md)).

For brute-force resistance generally, the durable control is a login-attempt limiter plugin (same one as step 2) — recommend it.

## 5. Confirm debug output is not exposed — [TCP-mysql] / shape-aware

Debug output on a public page leaks paths, queries, and sometimes secrets.

- **Shape A:** the entrypoint forces `WP_DEBUG_DISPLAY` off **every boot** — you get this for free; just confirm no stack traces render on an error page over **[HTTP]**.
- **Shape B:** nothing enforces it. If the vanilla image was built with `WORDPRESS_DEBUG=1`, display may be on. Recommend `WP_DEBUG_DISPLAY` off (and log to file instead) — a `wp-config.php` change, so file-channel / route. See [diagnose-500.md](diagnose-500.md) for the debug-log approach.

## 6. Lock down the in-dashboard file editors — recommend-and-route (file channel)

`define( 'DISALLOW_FILE_EDIT', true );` in `wp-config.php` removes the Theme/Plugin File Editors, closing a straight admin-cookie → RCE path.

- **With a shell** (rare today): `wp config set DISALLOW_FILE_EDIT true --raw --allow-root` (wp-config edit gate applies: print the exact command, get user ack first — SKILL.md safety gates), then re-chown anything it touched (`--allow-root` leaves root-owned files; only `uploads/` is auto-chowned).
- **Without a shell** (today): no live path — recommend the constant (next image build / file manager) or a hardening plugin that offers the toggle. There is no reliable HTTP signal for its current state, so treat this as recommend-and-verify. See [../reference/security.md → `DISALLOW_FILE_EDIT`](../reference/security.md).

## 7. Block PHP execution under `uploads/` — recommend-and-route (server config)

Make the web server refuse to run PHP under `wp-content/uploads/` (Apache `php_admin_flag engine off` / nginx `location` deny). This neutralizes the standard "upload a webshell, then request it" escalation. It is **web-server configuration, below WordPress and below the agent** on both shapes — recommend it and route to the image/platform. Pair it with "keep plugins current" (step 8), which is the mitigation the user can actually act on, since the malicious upload almost always rides in on a stale plugin CVE. Detail: [../reference/security.md → Uploads executing PHP](../reference/security.md).

## 8. Update hygiene — [HTTP] detect, mixed fix

```bash
curl -s "http://${WORDPRESS_HOST}/" | grep -i '<meta name="generator"'    # core version, if not stripped
```

- **Core:** Shape A is image-pinned — a bump goes through the deploy, never `wp core update` in-container. Route. (See [upgrade.md](../reference/upgrade.md) / [upgrade-wordpress.md](upgrade-wordpress.md).)
- **Plugins/themes:** on **Shape A** these live on the persistent `wordpressdata` volume, so updates from Dashboard → Updates **persist** across restarts. On **Shape B** persistence depends on the developer's compose declaring a volume for `/var/www/html` — verify (ask the developer / check the compose) before promising an update survives a restart; without a volume, plugins, themes, and uploads are lost on every pod restart. Guide the user to apply pending plugin/theme updates; verify the site still returns 200 afterward. Remove plugins/themes that are installed-but-unused — dormant code is still attack surface (route the removal to `/wp-admin`; deletion via SQL is off-limits — SKILL.md principle 8/9).

## 9. Sanity-check the public surface — [HTTP]

```bash
curl -sI "http://${WORDPRESS_HOST}/"            # 200
curl -sI "http://${WORDPRESS_HOST}/wp-login.php" # 200, serves the login form
curl -sI "http://${WORDPRESS_HOST}/wp-config.php" # must NOT return PHP source; expect 200 empty / 403 / 500 — never readable text
```

Confirm the homepage and login load, and that `wp-config.php` is not being served as text (it never should be, but a broken handler mapping is worth catching before launch).

## 10. Salts (optional, for a site that existed before you locked it down) — recommend-and-route

If this "fresh" install was actually up and possibly probed before hardening, recommend rotating the secret keys/salts so any cookie an attacker may hold is invalidated. This is a `wp-config.php` edit (`wp config shuffle-salts` with a shell; otherwise route) and it **logs every user out** — coordinate, don't surprise them. See [../reference/security.md → Secret keys and salts](../reference/security.md).

## Tell the user

Report, explicitly split by what you *did* vs *found* vs *couldn't touch*:

- **Applied from here:** anything you actually changed (over TCP/HTTP) — likely little, and say so.
- **Verified good:** items already correct (e.g. Shape A's forced `WP_DEBUG_DISPLAY` off, HTTPS `siteurl`).
- **Detected weak, routed to you:** each recommend-and-route item, with the exact `/wp-admin` click, `wp-config.php` line, or web-server rule they (or the platform) need to apply, and why it matters.
- **Skipped, and why.**

This list is conservative. A low-stakes internal sandbox can skip several items; any site that will hold real user data or take payments should get the whole list applied — even where "applied" means the user does it because the agent can't.
