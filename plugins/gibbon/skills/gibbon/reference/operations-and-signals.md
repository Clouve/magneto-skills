# Operations & Signals

## What "healthy" looks like

A healthy Gibbon container in this app satisfies all of the below. Run these checks whenever the user asks "is this working?"

1. **HTTP**. `curl -sI http://gibbon/index.php` from inside the Magneto Agent container returns `200 OK`. Login page renders (html contains `Gibbon`).
2. **DB reachability**. `MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysqladmin -h gibbon-mysql -u gibbon ping` returns `mysqld is alive`.
3. **`gibbonSetting(version) == /var/www/html/version.php $version`**. If they drift, an upgrade is pending.
4. **Cron running**. Inside the `gibbon` container, over the `clouve-ops` channel: `sudo service cron status` → `cron is running`, and `/var/log/gibbon-cron.log` keeps growing. The commands are under "Diagnosing 'are my scheduled tasks running?'" below.
5. **Uploads writable**. `uploads/cache/` owned by `www-data`, mode 755. Gibbon writes compiled templates here on every request.
6. **No PHP fatal errors**. They go to Apache's error log, which is the container's own output and usually not readable from here ([shell-access.md](shell-access.md#the-apache-error-log)). Checks 1 to 3 and the user's report are your signals; Clouve support can read the container log.

The Clouve healthcheck configured in [apps/gibbon/clv-docker-compose.yml](../../clv-docker-compose.yml) is an HTTP GET against `/index.php`, port 80, initial delay 60s, interval 30s, timeout 15s, failure threshold 15. A container that fails this for 7.5 minutes is restarted by Clouve's orchestrator.

## Where logs live

### In the `gibbon` container (over the `clouve-ops` SSH channel, [shell-access.md](shell-access.md))

The two Apache files are links to the container's stdout and stderr (the `php:8.3-apache` base image's setup), so there is nothing to read in them, even over SSH. The rest are files you can read with `sudo`.

| Path | What's in it | Rotation |
|---|---|---|
| `/var/log/apache2/access.log` | Apache access log | Docker-managed (stdout) |
| `/var/log/apache2/error.log` | Apache errors + PHP errors | Same |
| `/var/log/gibbon-cron.log` | Our cron wrapper's output (one banner per task start/finish) | Not rotated — grows unbounded |
| `/var/log/gibbon-cron.state/<script>.lastrun` | Per-CLI-task unix timestamp of last run | Overwritten each run |
| `/var/www/html/var/log/` | Gibbon's own Monolog output (depending on settings) | Gibbon-managed |
| stdout / stderr (via `docker logs <container>`) | Apache access + error | Docker-managed |

### Accessible to the tenant

- **Gibbon UI: System Admin → View Logs** — reads `gibbonLog`, the in-DB event log (logins, setting changes, module installs, rollover runs). Not the Apache log.
- Not Apache's or PHP's errors: those are the container's own output, and the tenant's Clouve dashboard doesn't show it. Clouve support can read it, so a question about it goes in a support ticket.

### Accessible from Magneto Agent

From inside this container, you can:
- `curl` Gibbon's HTTP endpoint for page responses.
- Query the DB (read-only with gibbon user, write with the same).
- Read `gibbonLog` via SQL.
- Read the files inside the `gibbon` container over the `clouve-ops` channel: `/var/log/gibbon-cron.log`, `/var/www/html/config.php` (it holds the database password: check it, never print it).

If the tenant needs something from Apache's log, it's the container's own output, which neither of you can read. Clouve support can: put the time and the page in a support ticket. (`./logs.sh gibbon` is a magneto developer script for a local docker compose; a tenant doesn't have it.)

## The in-container cron daemon

Source: [apps/gibbon/image/installer/gibbon-cron.sh](../../image/installer/gibbon-cron.sh). Details in [apps/gibbon/README.md](../../README.md#scheduled-tasks).

The container runs Debian `cron` as a service. `/etc/cron.d/gibbon-cron` is rendered from `$GIBBON_CRON_INTERVAL` at container start and invokes `gibbon-cron.sh` on that interval (default `* * * * *`). The wrapper:

1. Bails early if `/var/www/html/config.php` is missing or empty (install sentinel).
2. Iterates a hard-coded map of Gibbon CLI scripts → per-task interval in minutes.
3. For each, checks `/var/log/gibbon-cron.state/<script>.lastrun`; if enough time has passed, runs `/usr/local/bin/php /var/www/html/cli/<script>.php`.
4. Logs `Started` / `Completed` / `Failed` banners with timestamps to `/var/log/gibbon-cron.log`.

### Task schedule (intervals in minutes)

| Script | Interval | Purpose |
|---|---|---|
| `userAdmin_statusCheckAndFix` | 1440 | Daily: verify and fix user statuses |
| `userAdmin_removeStaleNotifications` | 1440 | Daily: prune `gibbonNotification` |
| `attendance_dailyIncompleteEmail` | 1440 | Daily: email teachers who haven't taken attendance |
| `attendance_dailyIncompleteEmail_byClass` | 1440 | Daily: same, class-level breakdown |
| `attendance_weeklySummaryEmail` | 10080 | Weekly: attendance summary |
| `behaviour_dailySummaryEmail` | 1440 | Daily: behaviour events digest |
| `behaviour_lettersNegative` | 1440 | Daily: auto-generate negative-behaviour letters |
| `behaviour_lettersPositive` | 1440 | Daily: auto-generate positive-behaviour letters |
| `schoolAdmin_parentDailyEmailSummary` | 1440 | Daily: parent digest |
| `schoolAdmin_parentWeeklyEmailSummary` | 10080 | Weekly: parent digest |
| `schoolAdmin_tutorDailyEmailSummary` | 1440 | Daily: tutor digest |
| `library_overdueNotification` | 1440 | Daily: library overdue-item emails |
| `finance_staffPettyCashNotification` | 1440 | Daily: petty cash reminders (staff) |
| `finance_studentPettyCashNotification` | 1440 | Daily: petty cash reminders (students) |
| `staff_FirstAidExpiryNotification` | 1440 | Daily: first-aid cert expiry alerts |

### Not scheduled (deliberately)

- `system_backgroundProcessor.php` — a worker invoked programmatically by Gibbon with `processID` / `processKey` arguments (e.g. async report generation). **Do not add it to the schedule.** The wrapper omits it by design.

### Diagnosing "are my scheduled tasks running?"

The canonical diagnostic surface lives in the `gibbon` container. Look yourself, over the `clouve-ops` channel:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} '
  sudo service cron status                     # Is cron alive?
  cat /etc/cron.d/gibbon-cron                  # Rendered crontab
  sudo tail -n 50 /var/log/gibbon-cron.log     # The scheduler log (tail -F in an interactive session)
  sudo ls -la /var/log/gibbon-cron.state/      # Per-task lastrun timestamps
'
```

From the Magneto Agent side, you can still check indirect signals:
- `SELECT * FROM gibbonLog WHERE title LIKE '%cron%' OR title LIKE '%notification%' ORDER BY timestamp DESC LIMIT 20;` — some scripts write to the event log.
- `SELECT * FROM gibbonNotification WHERE timestamp > NOW() - INTERVAL 2 DAY ORDER BY timestamp DESC LIMIT 20;` — if notifications are being created, something is running.
- Ask the user to try to trigger a behaviour-letter manually and check if it arrives on the expected cadence.

## Clearing the upload cache

`/var/www/html/uploads/cache/` holds compiled twig templates and cached rendered pages. It's wiped on every `entrypoint.sh` run, so the next container start clears it. If you see stale rendering (e.g. a CSS change didn't take effect after an upgrade), clear it now: the user has no restart button for the app.

The first choice is Gibbon's own **System Admin → Cache Manager → Clear Cache**, which the admin runs from the Gibbon UI. You can also empty it yourself over the `clouve-ops` channel, after telling the user: `sudo find /var/www/html/uploads/cache -mindepth 1 -delete`. Keep the folder itself: `entrypoint.sh` expects it at the next start.

## Metrics / observability the tenant sees

- The Clouve dashboard shows no container metrics (uptime, memory, CPU) and no container log for the app. Clouve support can look at those for a support ticket.
- Gibbon admin UI: **System Admin → System Overview** shows version, last login, basic counts.
- Gibbon admin UI: **System Admin → View Logs** (the `gibbonLog` event log).

Claude Code should not intermediate any of this: surface it as "Gibbon's System Overview has this" or "run this query to see."

## Limits of what this skill can observe

Every skill user should know, and you should say so when relevant:
- Apache's access and error logs, PHP errors included, are the `gibbon` container's own output. Nothing in this pod can read them, SSH included ([shell-access.md](shell-access.md#the-apache-error-log)). The same goes for the container's start-up messages from `entrypoint.sh`.
- Everything else inside the `gibbon` and `gibbon-mysql` containers is reachable over the `clouve-ops` channel: files under `/var/www/html`, `/var/log/gibbon-cron.log`, `service cron status`, `config.php` (check it, never print it).
- We CAN also: query Gibbon's DB over the pod network, HTTP-fetch Gibbon's public pages, and read anything in the Magneto Agent container's own filesystem.

When the answer to a diagnostic question is in the container's own output, say so plainly and leave it to Clouve support, rather than inventing output.
