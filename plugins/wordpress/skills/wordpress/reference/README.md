# WordPress DevOps reference

Per-topic facts about WordPress as deployed on Clouve, covering **both deployment shapes**: the Clouve-packaged marketplace app (pinned `wordpress:6.9.0` + MariaDB, with the installer entrypoint) and developer-submitted compose apps (typically vanilla `wordpress:<ver>-apache` + MySQL 8, stock entrypoint). Clouve-packaging facts are sourced from the [apps/wordpress tree in Clouve/magneto](https://github.com/Clouve/magneto/tree/develop/apps/wordpress); upstream facts from WordPress core and the [official documentation](https://wordpress.org/documentation/).

## How to navigate

Two questions decide everything in these docs: *which shape are you on* and *which channels exist*. Answer them first — start with [stack-and-runtime.md](stack-and-runtime.md) (shape probe) and [shell-access.md](shell-access.md) (channel matrix; today's WordPress images have **no** shell channel, so wp-cli is unreachable and every doc below labels its TCP/HTTP fallback). When you arrive with a symptom rather than a task, enter through [troubleshooting.md](troubleshooting.md).

| File | What it covers |
|---|---|
| [shell-access.md](shell-access.md) | The channel matrix (TCP `mysql`, HTTP `curl`, conditional `clouve-ops` SSH), the probe procedure, why today's WordPress images ship no shell, and the safety gates per channel |
| [stack-and-runtime.md](stack-and-runtime.md) | The two shapes side by side: images, PHP limits, wp-cli availability, DB engines (MariaDB floating tag vs. MySQL 8), volumes, filesystem layout |
| [architecture.md](architecture.md) | Request lifecycle, `wp-config.php` generation from `WORDPRESS_*` env, the Clouve installer entrypoint's boot sequence step by step |
| [configuration.md](configuration.md) | Operationally-relevant `wp-config.php` constants (`WP_DEBUG*`, `DISALLOW_FILE_EDIT`, `WP_HOME`/`WP_SITEURL`, table prefix, salts) and which are env-driven on the packaged shape |
| [install-and-bootstrap.md](install-and-bootstrap.md) | Auto-install vs. the browser installer, the hardcoded `wp_options` install probe, verifying install state from the DB |
| [upgrade.md](upgrade.md) | Core version vs. `db_version` invariant, image-driven core updates on the packaged shape, `wp core update-db`, plugin/theme update mechanics |
| [backup-restore.md](backup-restore.md) | What a complete backup is on each channel (DB dump *and* `wp-content/`), restore order, verification canaries |
| [data-model.md](data-model.md) | Never-touch tables, safe-to-touch scalar options, serialized-PHP hazards, how `wp_options`/`wp_users`/`wp_posts` actually work |
| [urls-and-migration.md](urls-and-migration.md) | `siteurl` vs. `home`, the every-boot env reconciler, embedded content URLs, serialization-aware search-replace |
| [cron-and-tasks.md](cron-and-tasks.md) | Traffic-driven `wp-cron.php` (no system cron in either image), `DISABLE_WP_CRON`, why schedules drift on quiet sites |
| [caching.md](caching.md) | Transients in `wp_options`, object caches, OPcache, page-cache plugins, and what "purge caches" means on each shape and channel |
| [security.md](security.md) | Login hardening, `xmlrpc.php`, file-edit lockdown, upload execution, update hygiene, the platform-injected admin-credential caveat |
| [troubleshooting.md](troubleshooting.md) | Failure modes seen in the wild (WSOD, 500s, redirect loops, `.maintenance`, DB connection errors) and the first thing to check for each |

## Citation convention

When a fact comes from the Clouve packaging, the citation is a full GitHub URL into [Clouve/magneto](https://github.com/Clouve/magneto) — e.g. [the installer entrypoint](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh) — never a relative path out of this plugin (the magneto tree is a different repo and is not present at runtime). When a fact is upstream WordPress behaviour, the citation links to the official docs or to core at a pinned tag, e.g. [wp-includes/version.php at 6.9](https://github.com/WordPress/WordPress/blob/6.9/wp-includes/version.php). Facts that hold on only one deployment shape say so inline.
