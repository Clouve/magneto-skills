# wp-cron & Scheduled Tasks

WordPress has **no cron daemon**. `wp-cron.php` is a pseudo-cron: on each page load WordPress checks its schedule, and if anything is due it spawns a non-blocking loopback HTTP request to `wp-cron.php` to run it. No traffic ⇒ no cron. **Neither Clouve WordPress image runs a system cron** — not the Clouve-packaged image, not the vanilla developer-submitted one — so everything below assumes traffic-driven scheduling.

## What rides on wp-cron

Core events (standard WordPress; recurrences from a stock 6.x install):

| Hook | Recurrence | Does |
|---|---|---|
| `publish_future_post` | one event per scheduled post | **The** scheduled-publishing mechanism |
| `wp_version_check` | twice daily | Core update check |
| `wp_update_plugins` / `wp_update_themes` | twice daily | Plugin/theme update metadata |
| `delete_expired_transients` | daily | Expired-transient cleanup (see [caching.md](caching.md)) |
| `wp_scheduled_delete` | daily | Purges trash older than `EMPTY_TRASH_DAYS` (default 30) |
| `wp_scheduled_auto_draft_delete` | daily | Old auto-draft cleanup |
| `wp_privacy_delete_old_export_files` | hourly | Personal-data export cleanup |
| `wp_site_health_scheduled_check` | weekly | Site Health background test |

Plugin jobs (backup plugins, SEO sitemap rebuilds, mail queues, WooCommerce followups) ride the same array. If cron starves, all of it starves together.

## How an event actually fires

1. A visitor (or the healthcheck) loads any page.
2. During init, WordPress compares the schedule against now.
3. If anything is due, it fires a ~0.01s-timeout loopback request to `wp-cron.php?doing_wp_cron=<ts>` and returns to rendering — the visitor doesn't wait.
4. The `wp-cron.php` request takes a lock (the `doing_cron` transient, ~60s TTL) and runs every due event synchronously, subject to PHP's `max_execution_time`.

Consequence: events fire *at or after* their timestamp, never on the dot. A "9:00 AM" scheduled post publishes at the first page load after 9:00.

## The heartbeat, per shape

| | Clouve-packaged (Shape A) | Developer compose (Shape B) |
|---|---|---|
| System cron in image | **None** | **None** |
| Healthcheck | `wget --spider http://localhost:80/` every 10s | Typically none declared |
| Effective cron cadence | ~10s heartbeat — each probe is a real PHP page load, so due events get spawned even with zero visitors | **Visitor traffic only** — a quiet site runs no cron at all |

On Shape A, missed schedules usually mean something else is wrong (cron lock stuck, `DISABLE_WP_CRON` set, site erroring). On Shape B, missed schedules on a low-traffic site are **expected behavior**, not a bug.

## Symptoms of starved cron

- Scheduled posts stuck in **"Missed schedule"** status.
- Update checks stale — `/wp-admin` shows no available updates for weeks, or updates stick at "in progress".
- Plugin-scheduled work silently absent: no backup emails, stale sitemaps, unsent digests.
- `wp_options` bloating with expired transients (`delete_expired_transients` never runs — see [caching.md](caching.md)).
- Trash never empties.

## Inspecting the schedule — **[TCP-mysql]**, read-only

The entire schedule is ONE serialized PHP array in the `cron` row of `wp_options`. **Read it, never write it** — hand-editing serialized PHP over SQL is forbidden ([SKILL.md](../SKILL.md) principle 6).

```bash
# How big is the schedule? (a multi-MB value = something is flooding the queue)
mysql -h "${WORDPRESS_DB_HOST}" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" \
  -e "SELECT LENGTH(option_value) FROM wp_options WHERE option_name='cron';"

# Oldest scheduled timestamps vs now — the starvation test.
# Serialized keys look like i:<unix-ts>; — extract and compare:
mysql -N -h "${WORDPRESS_DB_HOST}" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" \
  -e "SELECT option_value FROM wp_options WHERE option_name='cron';" \
  | grep -oE 'i:1[0-9]{9}' | cut -c3- | sort -n | head -5
date -u +%s   # compare: due timestamps minutes/hours in the past ⇒ cron is starved

# Is a cron run in flight right now? (the lock transient)
mysql -h "${WORDPRESS_DB_HOST}" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name='_transient_doing_cron';"
```

(Password via `MYSQL_PWD` in the env; adjust `wp_` if the prefix differs. If an object-cache drop-in is active, `doing_cron` may live outside the DB — see [caching.md](caching.md).)

## Running due events now

- **[HTTP] — always available, on both shapes.** Nudge cron directly:

  ```bash
  # Internal sibling host always works (wp-cron.php does no canonical redirect);
  # WORDPRESS_SITE_URL exists on Shape A only.
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 120 \
    "http://<wordpress-host>/wp-cron.php?doing_wp_cron"
  ```

  Expect `200` with an empty body. This runs every due event **synchronously in this request**, so give it a generous `--max-time`; a long-running plugin job can still be cut off by PHP's `max_execution_time`. Re-check the oldest-timestamp query above afterward to confirm the backlog drained.

- **[shell-only — probe first]** With a shell into the Shape A container (today's WordPress images ship no `clouve-ops` SSH — probe per [shell-access.md](shell-access.md), expect failure):

  ```bash
  wp cron event list --allow-root --path=/var/www/html          # readable schedule with next-run times
  wp cron event run --due-now --allow-root --path=/var/www/html # run everything due
  wp cron event run <hook> --allow-root --path=/var/www/html    # run one hook surgically
  ```

  Shape B has no wp-cli in the image at all, shell or not.

There is no per-event trigger over TCP or HTTP — the HTTP nudge is all-or-nothing. If the user needs one specific job re-run and it has its own UI (backup plugin "Run now" buttons, etc.), route them to `/wp-admin`.

## `DISABLE_WP_CRON` — read before setting it

`define('DISABLE_WP_CRON', true)` in `wp-config.php` stops the page-load spawn. The standard advice pairs it with a real system cron hitting `wp-cron.php` every minute — advice written for servers that *have* a system cron.

**On Clouve, do not set it.** There is no system cron in either image to take over, and on Shape A the healthcheck probes `/`, not `wp-cron.php` — so with `DISABLE_WP_CRON` set, the heartbeat stops triggering events too and scheduling dies entirely. Setting it also requires editing `wp-config.php`, which needs a file channel that does not exist today. If a plugin's docs insist on it, explain the trade-off and decline unless the user has arranged an external scheduler (e.g., an uptime monitor hitting the public `wp-cron.php` URL — which is just traffic, solving the problem without the constant).

## First thing to check

User reports missed schedules / stuck updates / absent plugin jobs:

1. **[HTTP]** Is the site even serving? `curl -s -o /dev/null -w '%{http_code}' http://<wordpress-host>/` — a 500 site runs no cron.
2. **[TCP-mysql]** Oldest-timestamp query above. Backlog in the past ⇒ starved.
3. **[HTTP]** Nudge `wp-cron.php?doing_wp_cron`, re-check. Backlog drains ⇒ it was starvation — on Shape B, explain the traffic-driven model; on Shape A, ask what changed (was the container restarting? healthcheck failing?).
4. Backlog does *not* drain ⇒ an event is fatally erroring inside the cron request. That's [troubleshooting.md](troubleshooting.md) / [diagnose-500.md](../playbooks/diagnose-500.md) territory (WSOD isolation via `active_plugins` applies to cron too).
