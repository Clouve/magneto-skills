# Configuration (`wp-config.php`)

`wp-config.php` lives **inside the docroot** — `/var/www/html/wp-config.php` on both shapes — and on Clouve it is **generated, not hand-written**: the official image's `docker-entrypoint.sh` writes it on first boot from `WORDPRESS_*` env vars, and the file lands on the `wordpressdata` volume, so it survives restarts. You currently have **no file channel to it** — today's WordPress sibling images ship no `clouve-ops` SSH account (see [shell-access.md](shell-access.md)) — so every "edit wp-config.php" instruction in upstream docs must be translated into: which knob is env-driven, which lives in the database, and which honestly has no live path. That translation is this file.

First thing to check, always: which shape you are on ([stack-and-runtime.md](stack-and-runtime.md)). Shape A (Clouve-packaged) actively re-asserts parts of this configuration **on every boot**; Shape B (developer compose) never touches the file after first-boot generation.

Any actual `wp-config.php` edit falls under the [SKILL.md safety gate](../SKILL.md#safety-gates-enforce-these-in-every-flow): requires a file channel, show the diff, get user ack — and on Shape A prefer the env-driven path.

## How the file is generated (both shapes)

*General docker-library WordPress knowledge:* the official image copies its [wp-config-docker.php](https://github.com/docker-library/wordpress/blob/master/wp-config-docker.php) template into place at first boot. The generated file does **not** hard-code most values — it calls a `getenv_docker()` helper at request time, so a changed env var (e.g. a rotated `WORDPRESS_DB_PASSWORD`) takes effect on the next container restart *without* regenerating the file.

| Env var | Drives | Notes |
|---|---|---|
| `WORDPRESS_DB_HOST`, `_DB_NAME`, `_DB_USER`, `_DB_PASSWORD` | `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Platform-injected on Clouve. **Env-authoritative — never edit these anywhere else.** Also your own [TCP-mysql] credential. |
| `WORDPRESS_TABLE_PREFIX` | `$table_prefix` | `wp_` on Shape A. Never change on a live install — see below. |
| `WORDPRESS_DEBUG` | `WP_DEBUG` | Any **non-empty** value reads as on — see the debug section for the Shape A caveat. |
| `WORDPRESS_AUTH_KEY` … `WORDPRESS_NONCE_SALT` (8 vars) | The 8 salt/key constants | Not set on either Clouve shape → random values generated at first boot and baked into the file on the volume. |
| `WORDPRESS_CONFIG_EXTRA` | Raw PHP appended to the file | The official escape hatch for arbitrary constants (`DISALLOW_FILE_EDIT`, `WP_MEMORY_LIMIT`, …). Container env is platform-controlled on Clouve — adding this means a support ticket, not something you can do from the agent. |

Shape A wraps this entrypoint untouched, then post-processes with wp-cli — see [entrypoint.sh](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh) and [architecture.md](architecture.md) for the full boot sequence. The post-processing steps that matter here are called out per-constant below.

## Debug constants

| Constant | Default | What it does |
|---|---|---|
| `WP_DEBUG` | `false` | Master switch — enables notice/warning reporting. |
| `WP_DEBUG_DISPLAY` | `true` (when `WP_DEBUG` on) | Prints errors into the page. **Shape A forces this off on every boot** (`wp config set WP_DEBUG_DISPLAY false --raw` in the entrypoint) — never expect on-page errors there, and don't bother turning it on: the next restart reverts it. |
| `WP_DEBUG_LOG` | `false` | `true` → append errors to `wp-content/debug.log`; a path string → log there instead. |
| `SCRIPT_DEBUG` | `false` | Serve unminified core JS/CSS. Dev-only. |
| `SAVEQUERIES` | `false` | Record every DB query per request. Heavy — dev-only, never leave on. |

**Shape A truthiness caveat (unverified — flag before relying on it).** The official template evaluates `WP_DEBUG` as `!!getenv_docker('WORDPRESS_DEBUG', '')`, i.e. *any non-empty string is true*. The Clouve manifest sets `WORDPRESS_DEBUG='false'` — a non-empty string — so if that value passed through the stock generator, `WP_DEBUG` may effectively be **on** with display suppressed on Shape A. We have not been able to read the generated file to confirm (no file channel). Verify by reading `/var/www/html/wp-config.php` the day a shell exists; until then treat Shape A's debug state as unknown-but-quiet.

What you can actually do today:

- **[HTTP]** `curl -sf "http://${WORDPRESS_HOST}/wp-content/debug.log" | tail -50` — `debug.log` sits inside the docroot, so on a default Apache setup it is fetchable if logging was ever enabled. A 404 means no log (or blocked), not "no errors". Its public fetchability is also a leak — see [security.md](security.md).
- **Flipping `WP_DEBUG` / `WP_DEBUG_LOG`: no live channel exists.** They are wp-config constants; changing them needs **[shell-only — probe first]** `wp config set WP_DEBUG true --raw` (and `WP_DEBUG_LOG`), which is unreachable today. Work the problem from DB + HTTP evidence instead per [playbooks/diagnose-500.md](../playbooks/diagnose-500.md), or route the user to Clouve support if a debug-enabled boot is genuinely required.

## `WP_HOME` / `WP_SITEURL` vs the database

Precedence ladder — top wins:

1. **Constants in `wp-config.php`** (`WP_HOME`, `WP_SITEURL`), if defined. `get_option()` short-circuits to them, and the Settings → General URL fields grey out. **Neither Clouve shape defines them by default** (the official generator doesn't emit them).
2. **DB options** `siteurl` and `home` in `wp_options` — the normal authority.
3. **Shape A only:** the installer entrypoint compares both DB options against `WORDPRESS_SITE_URL` on every boot and rewrites them on mismatch (then `wp rewrite flush --hard`). The env var — i.e. the platform — is the *effective* authority even though no constant is set.

Consequences:

| Shape | Authority | If you hand-edit the DB rows [TCP-mysql] |
|---|---|---|
| A (packaged) | `WORDPRESS_SITE_URL` env | Silently reverts at the next pod restart. Don't fight the reconciler — domain changes go through the platform. |
| B (vanilla) | The DB rows themselves | Sticks — and a wrong value locks everyone out of `/wp-admin`. Gated edit only. |

All URL work goes through [playbooks/change-site-url.md](../playbooks/change-site-url.md). Note the reconciler touches **only** `siteurl`/`home` — URLs embedded in content and serialized options need a separate, serialization-aware pass: [urls-and-migration.md](urls-and-migration.md).

## Table prefix

`$table_prefix` comes from `WORDPRESS_TABLE_PREFIX` (`wp_` on Shape A). Two reasons it is frozen on a live install:

- Standard WordPress: the prefix is baked into row *data*, not just table names (`wp_user_roles` option, `wp_capabilities` usermeta) — renaming tables alone half-migrates.
- Shape A specific: the entrypoint's install-detection probes the **hardcoded** `wp_options` table name, ignoring the env var. A non-default prefix makes every boot think the site is uninstalled and run a second `wp core install` into the same database.

Per [SKILL.md](../SKILL.md) principle 10 and its gate: **refuse** prefix changes on a live install.

## Salts and keys

Eight constants (`AUTH_KEY`, `SECURE_AUTH_KEY`, `LOGGED_IN_KEY`, `NONCE_KEY` + their four `_SALT` twins) sign login cookies and nonces. On both shapes they were randomly generated at first boot and live only in `wp-config.php` on the volume — they persist across restarts.

- Rotating them invalidates every login cookie site-wide (everyone re-logs-in). That is sometimes exactly what you want after a suspected credential leak.
- Rotation needs a file channel: **[shell-only — probe first]** `wp config shuffle-salts`. **No live TCP/HTTP path exists**, and there is no wp-admin UI for it either. Today: route to support, or use the session-invalidation alternatives in [playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md).
- Never print or paste salt values into chat if you ever do gain file access.

## Memory limits

| Constant | Default | Meaning |
|---|---|---|
| `WP_MEMORY_LIMIT` | `40M` | What WordPress raises PHP's `memory_limit` to for front-end requests. WordPress only ever raises — if PHP already allows more, this is a no-op. |
| `WP_MAX_MEMORY_LIMIT` | `256M` | Same, for admin/upgrade contexts. |

The real ceiling is PHP's `memory_limit`:

- **Shape A:** `512M` via `/usr/local/etc/php/conf.d/wordpress.ini` (plus `upload_max_filesize`/`post_max_size` at `100M`). Both WP constants are no-ops here — you already run at 512M.
- **Shape B:** whatever the stock image's PHP config sets — commonly PHP's own `128M` default, but verify rather than assume (a "Allowed memory size of N bytes exhausted" line in an error message tells you the true limit).

Raising the ceiling means editing PHP ini or wp-config — **[shell-only — probe first]**, no live path today. If a memory ceiling is the diagnosis, remember [SKILL.md](../SKILL.md) principle 11: container resources are platform-managed and paid — report the finding and route the user, never patch.

## File-edit lockdown

| Constant | Effect |
|---|---|
| `DISALLOW_FILE_EDIT` | Removes the theme/plugin code editors from `/wp-admin`. Recommended on every production site. |
| `DISALLOW_FILE_MODS` | Also blocks plugin/theme *installs and updates* from wp-admin — stronger, and usually too strong here, since wp-admin is the tenant's only plugin channel today. |

Neither is set on either Clouve shape (nothing in the manifest or entrypoint adds them). Setting one requires wp-config access: **[shell-only — probe first]** `wp config set DISALLOW_FILE_EDIT true --raw` — unreachable today, and there is **no TCP or HTTP fallback** (these are PHP constants, not options rows). Honest posture until a shell exists: recommend it, note it can't currently be applied, and compensate with strong admin credentials and role hygiene ([security.md](security.md)).

## Other constants you will meet

| Constant | Why an operator cares |
|---|---|
| `DISABLE_WP_CRON` | Moves cron off HTTP traffic to an external trigger. Neither shape sets it; neither image has system cron, so setting it without a replacement trigger silently stops all scheduled work. See [cron-and-tasks.md](cron-and-tasks.md). |
| `FORCE_SSL_ADMIN` | Forces HTTPS for wp-admin/login. On Clouve, TLS terminates at the platform ingress; usually unnecessary. |
| `AUTOMATIC_UPDATER_DISABLED` / `WP_AUTO_UPDATE_CORE` | Core auto-updates write files that drift from the container image — on Shape A core versioning belongs to the image ([upgrade.md](upgrade.md)). Neither constant is set today; treat any observed core drift as a finding. |
| `FS_METHOD` | How WP writes files for updates/installs. In both images Apache runs as `www-data`; where `www-data` owns the tree, WP picks `direct` on its own. Root-owned leftovers from `--allow-root` wp-cli runs are what break this — see [SKILL.md](../SKILL.md). |

## What is editable over which channel — the honest matrix

| Knob | Lives in | Live path today | With a shell (probe first) |
|---|---|---|---|
| DB credentials | Platform env (`WORDPRESS_DB_*`) | None for you — platform-managed. Never edit in-file or in-DB. | Still no — env is authoritative. |
| `siteurl` / `home` | `wp_options` (Shape A: env-reconciled) | Shape B: gated [TCP-mysql] `UPDATE` per [playbook](../playbooks/change-site-url.md). Shape A: platform request only. | `wp option update` — same authority rules apply. |
| `WP_DEBUG` / `WP_DEBUG_LOG` | wp-config constant | **None.** Read `debug.log` over [HTTP] if it exists; else diagnose from DB/HTTP evidence. | `wp config set … --raw` |
| `WP_DEBUG_DISPLAY` | wp-config constant | None — and on Shape A forced off every boot regardless. | Pointless on Shape A; `wp config set` on B. |
| `DISALLOW_FILE_EDIT` | wp-config constant | **None** — recommend and route. | `wp config set DISALLOW_FILE_EDIT true --raw` |
| Salts/keys | wp-config file | **None** — no UI, no SQL equivalent. Route to support if rotation is urgent. | `wp config shuffle-salts` |
| `$table_prefix` | wp-config + row data | Refuse (principle 10). | Refuse. |
| `WP_MEMORY_LIMIT` / PHP limits | wp-config / php.ini | None — and resource ceilings are platform territory (principle 11). | ini/wp-config edit, gated. |
| Site title, tagline, admin email, timezone, … | `wp_options` scalar rows | `/wp-admin` Settings (user's route) or gated [TCP-mysql] scalar update — see [data-model.md](data-model.md). | `wp option update <name> <value>` |

The last row is the general rule worth internalizing: most things users call "settings" are **not** in `wp-config.php` at all — they are `wp_options` rows, which you *can* reach today. [data-model.md](data-model.md) is the map of which of those are safe.
