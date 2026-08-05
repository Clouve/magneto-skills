# Stack & Runtime

Two deployment shapes of WordPress exist on Clouve, and almost every operational decision branches on which one you are in front of. **Run the shape probe below before planning any change.** The channel matrix at the bottom is the second thing to internalize: from the Magneto Agent container you have TCP `mysql` and HTTP `curl` — a shell into the WordPress container (and therefore wp-cli) does not exist on today's images.

Examples below use `${WORDPRESS_HOST}` for the WordPress sibling hostname and the `WORDPRESS_DB_*` set for DB credentials. Names vary per deployment — discover them first: `env | grep -iE 'wordpress|mysql|maria|host'`.

## The two shapes side by side

| | Shape A — Clouve-packaged app | Shape B — developer-submitted compose |
|---|---|---|
| Source | [apps/wordpress](https://github.com/Clouve/magneto/tree/develop/apps/wordpress) in Clouve/magneto | The developer's own compose file (the marketplace demo publishes a representative one) |
| Web image | Custom, FROM `wordpress:6.9.0` (**pinned**) — [Dockerfile](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/Dockerfile) | Vanilla `wordpress:<tag>-apache` (demo: `wordpress:6.8-apache`) — tag is developer-controlled |
| DB image / engine | `mariadb` — **`:latest`, unpinned**; engine version floats per pull ([mariadb/Dockerfile](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/mariadb/Dockerfile)) | Demo: `mysql:8.0`. Developer's choice in general |
| Container names | `wordpress` (Frontend, isPublic, :80) + `wordpress-mariadb` (Database, :3306, not public) | Per the developer's compose (demo: `wordpress`, `mysql`) |
| Entrypoint | Custom installer [entrypoint.sh](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh) wrapping the untouched official one — auto-installs, reconciles URLs, forces debug-display off (see [architecture.md](architecture.md)) | Stock official entrypoint — first boot serves the browser installer; **nothing reconciles anything** |
| wp-cli | `/usr/local/bin/wp` (phar) — inside the container, so **unreachable without a shell channel** | Absent |
| mysql client in web container | `default-mysql-client` installed | Absent |
| PHP limits | Raised via `/usr/local/etc/php/conf.d/wordpress.ini` (see below) | Image defaults (`upload_max_filesize` 2M-ish territory — small uploads fail loudly) |
| Site URL handling | `WORDPRESS_SITE_URL` env re-asserted into `siteurl`/`home` **every boot** | No such env; `siteurl`/`home` are whatever the installer or an admin last wrote |
| Admin bootstrap | `WORDPRESS_ADMIN_USER` (`{firstName}_{lastName}`), `WORDPRESS_ADMIN_EMAIL`, `WORDPRESS_ADMIN_PASSWORD` (platform-generated) via `wp core install` | Browser installer — whoever loads the page first picks the credentials |
| Volumes | `wordpressdata` → `/var/www/html` (10Gi), `dbdata` → `/var/lib/mysql` (10Gi) | Per the developer's compose |
| Healthcheck | wordpress container: `wget --spider http://localhost:80/` every 10s, 30s start period. **DB healthcheck disabled** in the marketplace manifest | Demo declares none |
| DB root access | MariaDB root per image config; app user is `wordpress` | **`MYSQL_RANDOM_ROOT_PASSWORD="1"`** — root password unknown to everyone, forever; the app user has grants on the `wordpress` schema only |
| sshd / `clouve-ops` | **Not shipped** (unlike moodle/gibbon) | Not shipped |

## Shape A: the Clouve-packaged image in detail

FROM `wordpress:6.9.0` (pinned), plus: `curl`, `default-mysql-client`, the wp-cli phar at `/usr/local/bin/wp`, and PHP overrides in `/usr/local/etc/php/conf.d/wordpress.ini`:

| Setting | Value |
|---|---|
| `upload_max_filesize` | `100M` |
| `post_max_size` | `100M` |
| `memory_limit` | `512M` |

Environment on the `wordpress` container (all platform-injected):

| Var | Value / meaning |
|---|---|
| `WORDPRESS_DB_HOST` | → `wordpress-mariadb` |
| `WORDPRESS_DB_NAME` / `WORDPRESS_DB_USER` | `wordpress` / `wordpress` |
| `WORDPRESS_DB_PASSWORD` | Platform secret (same value as the DB container's `MYSQL_PASSWORD`) |
| `WORDPRESS_TABLE_PREFIX` | `wp_` — **never change on a live install** ([SKILL.md](../SKILL.md) principle 10) |
| `WORDPRESS_SITE_URL` | The deployment URL — authoritative for `siteurl`/`home` at every boot |
| `WORDPRESS_SITE_TITLE` | Site title used at first install |
| `WORDPRESS_ADMIN_USER` / `_EMAIL` / `_PASSWORD` | First-install admin credentials; the env will **not** reflect later manual changes |
| `WORDPRESS_DEBUG` | `'false'` |

The container starts as root (the entrypoint needs it); Apache workers run as `www-data`. Everything under `/var/www/html` lives on the `wordpressdata` volume, so wp-content — plugins, themes, uploads — survives pod restarts; core files are refreshed from the image by the official entrypoint when the image version changes (see [upgrade.md](upgrade.md)).

## Shape B: developer compose in detail

Whatever the developer submitted. The reference demo compose: `wordpress:6.8-apache` + `mysql:8.0`, with `WORDPRESS_DB_HOST=mysql`, `WORDPRESS_DB_NAME=wordpress`, `WORDPRESS_DB_USER=wordpress`, `WORDPRESS_DB_PASSWORD` (becomes a typed platform secret on import), and `MYSQL_DATABASE`/`MYSQL_USER`/`MYSQL_PASSWORD` mirroring it. Treat every detail here as "verify per deployment" — service names, tags, and engine are all developer choices.

Operationally that means: no wp-cli anywhere, no mysql client in the web container, image-default PHP limits, no healthchecks, no URL reconciliation, and no admin env vars. The stock official image behaves like Shape A at the process level (root entrypoint, `www-data` Apache workers) — standard official-image behavior.

**MySQL 8.0 auth gotcha**: its default auth plugin is `caching_sha2_password`. The agent container's `mysql` binary is Debian's `default-mysql-client`, which is the MariaDB client — its support for that plugin varies by client version. If a `[TCP-mysql]` connection fails with an auth-plugin error rather than a bad-password error, this mismatch is the first suspect; verify with the actual error text rather than assuming, and note that root-level workarounds are off the table (`MYSQL_RANDOM_ROOT_PASSWORD` — nobody has root).

## Filesystem layout (inside the WordPress container)

Standard WordPress layout — same on both shapes (Shape A puts it on the `wordpressdata` volume):

```
/var/www/html/                  ← Apache docroot
├── index.php                   ← entry point (front controller)
├── wp-config.php               ← generated from WORDPRESS_* env by the official entrypoint
├── wp-load.php                 ← bootstrap; Shape A's entrypoint checks its presence as "core extracted"
├── wp-settings.php             ← the real bootstrap, loaded by wp-config.php
├── wp-admin/                   ← admin UI (+ install.php, the browser installer)
├── wp-includes/                ← core libraries — never edit
├── wp-content/
│   ├── plugins/                ← code on disk, referenced from wp_options.active_plugins
│   ├── themes/
│   ├── uploads/                ← media; the ONLY path Shape A re-chowns every boot
│   ├── upgrade/                ← staging dir for in-app updates
│   └── debug.log               ← only when WP_DEBUG_LOG is enabled
├── .htaccess                   ← permalink rewrite rules
├── .maintenance                ← transient; present only mid-update (stuck = interrupted update)
├── wp-cron.php                 ← traffic-driven task runner (see cron-and-tasks.md)
└── xmlrpc.php                  ← legacy remote API (see security.md)
```

None of this is reachable from the agent container today — filesystem facts are established indirectly ([HTTP] probes like `curl -sI http://${WORDPRESS_HOST}/wp-content/themes/<theme>/style.css`) or by routing the user to `/wp-admin`.

## Shape-probe procedure

Run this at the start of any session; record the conclusion before acting.

1. **[agent-local]** `env | grep -iE 'wordpress|mysql|maria|host'` — inventory the injected env. `WORDPRESS_SITE_URL` + `WORDPRESS_ADMIN_*` present ⇒ Shape A (only the packaged manifest injects them). Only the `WORDPRESS_DB_*` set ⇒ almost certainly Shape B. `WORDPRESS_DB_HOST` = `wordpress-mariadb` is a further Shape A signal.
2. **[TCP-mysql]** `MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" -u "${WORDPRESS_DB_USER}" -e "SELECT VERSION()"` — a `-MariaDB` banner is consistent with Shape A (exact version floats — the image is unpinned, so **always check, never assume** the engine version); `8.0.x` matches the Shape B demo.
3. **[HTTP]** `curl -s "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*'` — code version. `6.9` matches the current packaged pin — the image tag is `wordpress:6.9.0`, but core reports `x.y.0` releases as `x.y` (patch releases like `6.9.1` match exactly); anything else on a packaged deploy means an older/newer image.
4. **[shell-only — probe first]** `SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new clouve-ops@"${WORDPRESS_HOST}" true` — determines whether a shell (and thus wp-cli) exists. **Expect failure on today's images, both shapes.** Full procedure and etiquette in [shell-access.md](shell-access.md).

If the signals disagree (e.g. `WORDPRESS_SITE_URL` present but MySQL 8 answering), say so to the user and treat the deployment as Shape B for safety — assume nothing reconciles and wp-cli does not exist.

## Channel matrix summary

Full detail in [shell-access.md](shell-access.md); this is the quick reference every playbook labels against.

| Channel | Tool | Availability today | Typical use |
|---|---|---|---|
| **[TCP-mysql]** | `mysql` / `mysqldump -h ${WORDPRESS_DB_HOST}` (client installed by this plugin's [install.sh](../../../install.sh)) | Always | Install-state probe, options reads, DB backups, password reset, WSOD isolation |
| **[HTTP]** | `curl http://${WORDPRESS_HOST}/` | Always | Health, code version, wp-cron kick, installer detection, asset-existence probes |
| **[shell-only — probe first]** | `sshpass -e ssh clouve-ops@${WORDPRESS_HOST}` → wp-cli, file edits, logs | **Not on today's WordPress images** (no sshd, no `clouve-ops` account — unlike moodle/gibbon) | Documented for the day the images ship it; until then the fallback is the TCP/HTTP variant in each playbook, `/wp-admin` for the user, or a support ticket |

The consequence to internalize: anything that is file-only — `wp-config.php` edits, plugin file surgery, `.maintenance` removal, enabling `WP_DEBUG_LOG` (reading an existing `debug.log` is HTTP-fetchable when it exists) — currently has **no direct path from the agent**. The honest move is to say so, offer the DB/HTTP-side alternative where one exists, and otherwise route the user ([SKILL.md](../SKILL.md) principle 13).
