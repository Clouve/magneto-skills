# Security

A working hardening posture for a WordPress 6.x site on Clouve. Treat this as a pre-flight checklist before letting the public in, and as the diagnosis ladder when something is reported as a security concern. The companion checklist you *run* is [../playbooks/harden-fresh-install.md](../playbooks/harden-fresh-install.md); this file is the *why* behind each item.

## First thing to know: what you can actually touch from here

This skill's defining constraint is the channel matrix. From the Magneto Agent container you have **[TCP-mysql]** to the database sibling and **[HTTP]** `curl` to the WordPress sibling on :80. A shell *inside* the WordPress container — and therefore `wp-cli` and any `wp-config.php`/file edit — exists only if the sibling image ships the `clouve-ops` SSH account, which today's WordPress images do **not**. Probe before you plan ([shell-access.md](shell-access.md)); most of the hardening controls below live in files and are therefore **recommend-and-route** today, not fix-it-yourself.

| Concern | Detect from agent? | Fix from agent today? |
|---|---|---|
| User / login enumeration (`?author=`, REST `/users`) | **[HTTP]** yes | No — needs a plugin or code (file channel) → route |
| `xmlrpc.php` exposed | **[HTTP]** yes | No — server config, plugin, or filter (file channel) → route |
| Default `admin` username | **[TCP-mysql]** yes | Partial — new user via `/wp-admin`; rename is not a live op → route |
| Weak / lost admin password | login probe **[HTTP]** | Yes — [../playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md) (TCP fallback) |
| `DISALLOW_FILE_EDIT` off | No reliable HTTP signal | No — `wp-config.php` edit (file channel) → route |
| Uploads execute PHP | limited **[HTTP]** probe | No — web-server config (file channel) → route |
| Stale core / plugins | **[HTTP]** version fingerprint | Core is image-driven; plugins via `/wp-admin` → guide the user |
| Salts need rotating | No | No — `wp-config.php` edit (file channel) → route |

"Route" means: state the finding plainly, tell the user the exact thing to click in `/wp-admin` or the exact `wp-config.php`/server change, and — where warranted — surface it as a platform request. It does **not** mean improvise the change through the database. See SKILL.md principle 13 (Clouve doesn't see the inside of this container).

## Login / user enumeration — [HTTP], fully checkable

WordPress leaks usernames through two public surfaces. Both are HTTP-checkable without auth; neither is fixable from the agent today.

Discover the sibling host first (`env | grep -iE 'wordpress|host'`), then:

**Author-archive redirect.** A request for `?author=<n>` 301-redirects to `/author/<login-slug>/`, and the slug is usually the exact `user_login`:

```bash
curl -sI "http://${WORDPRESS_HOST}/?author=1" | grep -i '^location:'
# Location: http://<site>/author/janedoe/   ← 'janedoe' is a valid login name
```

**REST users endpoint.** Since WP 4.7 `/wp-json/wp/v2/users` returns every user who has authored a published post — `id`, `name`, and `slug`:

```bash
curl -s "http://${WORDPRESS_HOST}/wp-json/wp/v2/users" | head -c 400
# A JSON array of {id,name,slug,...} ⇒ enumerable.
# 401 / empty array ⇒ already blocked (a security plugin, or REST auth required).
curl -s "http://${WORDPRESS_HOST}/?rest_route=/wp/v2/users" | head -c 400   # plain-permalink fallback
# A 404 on the pretty /wp-json/ path — especially on Shape B — may just mean plain
# permalinks, not hardening; confirm with ?rest_route= before concluding it is blocked.
```

Username disclosure turns a login page into a targeted brute-force surface — the attacker now needs only the password. **The fix is code, not data**: a `rest_endpoints` filter to unset the users route, an author-archive redirect block, and (best) a login-attempt limiter. Those ship as a security/hardening plugin or an `mu-plugin` — installed from `/wp-admin` or by editing files, i.e. a file channel. Route the user to install a reputable limit-login / hardening plugin; do **not** attempt to synthesize the block through SQL.

## `xmlrpc.php` — [HTTP] probe, file-channel to disable

`xmlrpc.php` is WordPress's legacy remote API. It is a live surface for two attacks: **credential brute-force amplification** (`system.multicall` lets an attacker try hundreds of user/password pairs in one request) and **pingback DoS reflection**. Probe it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "http://${WORDPRESS_HOST}/xmlrpc.php"
# 405 with body "XML-RPC server accepts POST requests only." ⇒ enabled and reachable.
# 403 / 404 ⇒ blocked at the web-server layer (good).
```

Confirm it actually answers RPC (not just that the file exists):

```bash
curl -s "http://${WORDPRESS_HOST}/xmlrpc.php" \
  -d '<?xml version="1.0"?><methodCall><methodName>system.listMethods</methodName><params></params></methodCall>' \
  | head -c 300
# A <methodResponse> listing methods (incl. system.multicall, pingback.ping) ⇒ fully live.
```

Disabling is a file/config operation, and the options differ in completeness — be honest about which:

- **Web-server block** (Apache `<Files xmlrpc.php> Require all denied </Files>`, or an nginx `location`): the only *complete* block; the file stops responding. Requires editing web-server config → file channel or a platform/image change. Route.
- **`add_filter( 'xmlrpc_enabled', '__return_false' )`** (via an `mu-plugin`): disables the methods that require authentication, but the endpoint itself still responds and some methods remain reachable — **partial**, not a full block. Needs a file channel to install.
- **A security plugin toggle** in `/wp-admin`: the user-facing path. Route them there.

If the site genuinely uses XML-RPC (older mobile apps, Jetpack in some modes), don't blanket-block — instead route to a limit-login plugin so multicall brute-force is throttled.

## Admin account hygiene and the `WORDPRESS_ADMIN_*` env trap

**Default username.** Check whether the primary admin is the guessable `admin`:

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT u.ID, u.user_login FROM wp_users u
   JOIN wp_usermeta m ON m.user_id = u.ID
   WHERE m.meta_key = 'wp_capabilities' AND m.meta_value LIKE '%administrator%';"
```

On the Clouve-packaged shape the installer names the admin `{firstName}_{lastName}` from `WORDPRESS_ADMIN_USER`, so a literal `admin` there means someone created it by hand. WordPress cannot rename a `user_login` from the UI — the supported fix is *create a new administrator, reassign content, delete the old one* from `/wp-admin`. Route the user; do not `UPDATE wp_users SET user_login=...` (it desynchronizes `wp_usermeta`, comment authorship, and post authorship).

**The env-var caveat — load-bearing.** `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_EMAIL`, and `WORDPRESS_ADMIN_PASSWORD` are consumed **once**, by the fresh-install path (`wp core install`) on the very first boot. Unlike `siteurl`/`home`, they are **not** re-asserted on subsequent restarts (see [architecture.md](architecture.md)). Two consequences:

- A password or email the tenant changed later (via `/wp-admin` or the rotate playbook) **persists** — the reconciler will not stomp it. Good.
- The env var stays **frozen at the platform's original generated value** and does *not* track the live credential. Never read `WORDPRESS_ADMIN_PASSWORD` and assume it is the current password, and never hand it back as "your password" without verifying — it is very likely stale. The source of truth for credentials is `wp_users`, not the environment.

Rotation procedure (with the confirm-identity gate) is in [../playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md).

## `DISALLOW_FILE_EDIT` — file channel

By default WordPress exposes an in-dashboard PHP editor (Appearance → Theme File Editor, Plugins → Plugin File Editor). Any account that reaches admin — legitimately, via stolen cookie, or via an admin-level XSS — can rewrite live PHP from the browser and get immediate code execution. Set:

```php
// wp-config.php
define( 'DISALLOW_FILE_EDIT', true );
```

This removes those editors entirely. It lives in `wp-config.php`, so it needs a file channel:

- **With a shell** (Shape A, only when a `clouve-ops` account exists): `wp config set DISALLOW_FILE_EDIT true --raw --allow-root`, then re-chown any root-owned files it touched (the entrypoint only re-chowns `wp-content/uploads`).
- **Without a shell** (today): there is no live path from the agent — it cannot be set over the DB or HTTP. Recommend it and route: either the user adds the line via a file manager / next image build, or they use a hardening plugin that offers the same toggle.

There is no clean HTTP signal for whether it is set (the editor menu only shows to an authenticated admin), so treat this as a recommend-and-verify item, not a detect-and-confirm one.

## Uploads executing PHP — server-level, usually out of reach

The classic post-upload escalation: an attacker gets a `.php` file into `wp-content/uploads/` (via a vulnerable plugin's uploader) and then requests it directly to run code. The durable fix is to make the web server **refuse to execute PHP under `uploads/`** — an Apache `<Directory>` / `.htaccess` `php_admin_flag engine off` or an nginx `location ~* /uploads/.*\.php$ { deny all; }`. That is web-server configuration, below WordPress and below the agent's reach on both shapes.

You can do a shallow **[HTTP]** sanity probe — try to fetch a known-nonexistent PHP path under uploads and confirm it is not silently executed — but you cannot prove the negative from outside, and you cannot apply the fix. Recommend the web-server rule and route it to the image/platform. Pair the recommendation with the real mitigation the user *can* act on: keep plugins current (below), since the upload almost always arrives through a stale plugin CVE.

## Secret keys and salts — file channel; rotating logs everyone out

The eight `AUTH_KEY` / `SECURE_AUTH_KEY` / `LOGGED_IN_KEY` / `NONCE_KEY` and matching `*_SALT` constants in `wp-config.php` key the auth cookies and nonces. Rotating them (for example, after a suspected compromise, or to force every session to end) has three effects:

- Every auth cookie is invalidated → **all users, including you, are logged out** and must sign in again.
- All in-flight nonces are invalidated → open forms / AJAX fail until the page is reloaded.
- Stored passwords are **not** affected (they are hashed separately in `wp_users.user_pass`).

Rotation is a `wp-config.php` edit — there is **no** database or HTTP path for it. With a shell, `wp config shuffle-salts --allow-root` regenerates all eight in place. Without one (today), it is recommend-and-route: the user regenerates them via the [wordpress.org secret-key API](https://api.wordpress.org/secret-key/1.1/salt/) into `wp-config.php` on the next image build, or a security plugin does it. Because it force-logs-out everyone, treat it as a coordinated action, not a quiet fix — tell the user before it happens.

## Update hygiene

Stale plugins are the single most common breach vector; keep the whole stack current.

- **Core.** On the Clouve-packaged shape core is **pinned to the image** (`wordpress:6.9.0`) and refreshes only when the platform ships a new image — do **not** run `wp core update` inside the container (it drifts the code out from under the image; see [upgrade.md](upgrade.md)). On the developer-submitted shape the image tag is the developer's to bump. Either way, route a core version bump through the deploy, not the in-product updater.
- **Plugins / themes.** These live under `wp-content/`, which on the Clouve-packaged shape is on the persistent `wordpressdata` volume, so updates applied from `/wp-admin` **persist across restarts** (unlike a from-image codebase). On the developer-submitted shape, persistence depends on the developer's compose declaring a volume for `/var/www/html` — verify (ask the developer / check the compose) before promising an update survives a restart; without a volume, plugins, themes, and uploads are lost on every pod restart. Guide the user to keep them current in Dashboard → Updates; verify afterward that the site still returns 200.
- **Version fingerprint — [HTTP].** Infer the running core version without a shell:

  ```bash
  curl -s "http://${WORDPRESS_HOST}/" | grep -i '<meta name="generator"'   # often "WordPress 6.9" unless stripped
  curl -s "http://${WORDPRESS_HOST}/feed/" | grep -i '<generator>'          # generator URL carries the version
  curl -s "http://${WORDPRESS_HOST}/?feed=rss2" | grep -i '<generator>'     # plain-permalink fallback — a 404 on /feed/ (Shape B) may mean plain permalinks, not hardening
  ```

  Note the image tag vs the observable string: the `wordpress:6.9.0` image reports itself as `WordPress 6.9` — core omits the trailing `.0` on x.y.0 releases; patch releases (e.g. 6.9.1) match exactly. `readme.html` is frequently blocked. The `db_version` in `wp_options` (`option_name='db_version'`) is the **schema** revision, not the marketing version — useful for the upgrade invariant, not for "am I patched."

- Turn **off** the in-product "an update is available" nag where it conflicts with image-driven core upgrades, and never let the in-dashboard core auto-updater run on the packaged shape.

## If you suspect a compromise (DB + HTTP triage)

You can triage a fair amount without a shell; forensics on files needs one and is a support engagement.

1. **Unexpected administrators** — run the admin-enumeration query above and eyeball every row. An account you don't recognize is the headline finding.
2. **Rogue scheduled events** — WordPress stores its cron in an option:
   ```sql
   SELECT option_value FROM wp_options WHERE option_name = 'cron';
   ```
   Look for hook names that aren't from a plugin you installed (a common persistence trick).
3. **Tampered active plugin set** — `SELECT option_value FROM wp_options WHERE option_name='active_plugins';` and confirm every entry is a plugin the user knows about.
4. **New users generally** — `SELECT ID, user_login, user_email, user_registered FROM wp_users ORDER BY user_registered DESC LIMIT 20;`
5. **[HTTP]** spot-check that the homepage and `/wp-login.php` return the expected 200 / login form and haven't been defaced or made to redirect off-site (`curl -sI`).
6. **File-level checks** (webshells under `uploads/`, modified core files, an injected `mu-plugin`) require a shell — **route them**: there is no honest DB/HTTP substitute for scanning the filesystem.

Before touching anything, take a forensic backup (DB dump + `wp-content/` where a file channel exists — [../scripts/backup.sh](../scripts/backup.sh)); don't `rm` evidence. Rotating salts (above) and every admin password ([../playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md)) are the two containment actions you *can* take from here. Anything past triage is a forensic engagement — surface it to Clouve ops and the site owner with what you found.
