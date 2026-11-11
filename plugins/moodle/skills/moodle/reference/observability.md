# Observability

What Moodle exposes about itself, and how to wire it into a monitoring system.

## Built-in logs

| Log | Where | What |
|---|---|---|
| Standard log | `mdl_logstore_standard_log` | Per-user actions: page views, logins, course access, role grants, file downloads, plugin actions. **The audit trail.** |
| Live log | (in-memory, last 60s) | Real-time event feed at Site administration → Reports → Live logs. Useful for tailing during an incident. |
| Failed login log | `mdl_logstore_standard_log` rows where `eventname = '\core\event\user_login_failed'` | Auth failures. Source for brute-force detection. |
| Task log | `mdl_task_log` | Cron task runs (timestart, timeend, result, output). |
| Slow query log | `mdl_log_queries` | Only populated if `$CFG->dboptions['logslow'] > 0`. |
| Configuration changes | `mdl_config_log` | Every change to `mdl_config` / `mdl_config_plugins`. |

Reports are under Site administration → Reports → ... and read these tables.

### Log retention

`mdl_logstore_standard_log` grows linearly with user activity — for a busy site, **gigabytes per month**. Default retention is forever. Configure under Site administration → Plugins → Logging → Standard log → "Keep logs for".

If the table is huge, the symptom is slow report rendering, not crashes. Cleanup runs as a scheduled task.

### Log archiving

Beyond the active log table, the `tool_log` plugins under [public/admin/tool/log/](https://github.com/moodle/moodle/tree/v5.3.0/public/admin/tool/log) support multiple stores: `logstore_standard` (DB), `logstore_legacy` (legacy log table — disabled in 5.x), `logstore_database` (external DB), `logstore_xapi` (xAPI / Learning Locker integration), and contributed stores for Splunk / ELK forwarding.

For a school size, the default `logstore_standard` is fine. For an institution with compliance requirements, `logstore_database` to a dedicated audit DB is the typical answer.

## Health checks

### `admin/cli/checks.php`

[admin/cli/checks.php](https://github.com/moodle/moodle/blob/v5.3.0/admin/cli/checks.php) runs one set of Moodle's checks. Output is human-readable; the exit code is the worst result (Nagios style).

```bash
sudo -u www-data php admin/cli/checks.php
```

Pick the set with `--type=status | security | performance` (`status` is the default). `-v` lists every check, not just the failing ones. `--filter=TEXT` keeps only the checks whose reference contains TEXT (for example `--filter=cron`), so it narrows a set and never picks one. Useful subset for an automated probe:

```bash
sudo -u www-data php admin/cli/checks.php --type=status
echo "Exit: $?"   # 0 = ok, 1 = a warning, 2 = an error or a critical check, 3 = unknown
```

On a Clouve site the status set always reports `core_router` as an ERROR, so the exit code there is 2 (5.2 and 5.3 alike). Read the lines, not just the code: see [changes-in-5.3.md](changes-in-5.3.md#checks-that-fail-on-every-clouve-site).

The check framework lives at [public/lib/classes/check/](https://github.com/moodle/moodle/tree/v5.3.0/public/lib/classes/check). Plugins can register their own checks by extending `\core\check\check`.

### Probes for liveness / readiness

For a containerized deploy:

| Probe | Purpose | Implementation |
|---|---|---|
| **Liveness** | "is the process alive?" | TCP probe on port 80, OR a tiny PHP file like `public/_health.php` that returns 200 with a fixed body. The webserver responds → liveness ok. |
| **Readiness** | "can it serve traffic?" | HTTP GET on `/login/index.php` expecting 200 (login page renders → DB up, MUC up, sessions up). |
| **Deep health** | scheduled check | `admin/cli/checks.php --type=status` invoked on a schedule, results posted to monitoring. |

Avoid using `/` as a readiness check — Moodle's homepage may redirect, may be customized, may require login. The login page is more stable.

A common pattern: a `_health.php` file dropped at `<dirroot>/public/`:

```php
<?php
// _health.php — minimal: don't require config.php so it works even when DB is down.
// For a deeper check, swap this for a script that tries a DB query.
http_response_code(200);
header('Content-Type: text/plain');
echo "ok\n";
```

Then liveness probes hit `/_health.php`. Readiness probes hit something deeper.

## Heartbeat / pingable URL

The `tool_heartbeat` plugin exposes a heartbeat URL designed for external monitors. It returns 200 only when the site is healthy by Moodle's definition, and 503 otherwise. It is a contributed plugin, not part of Moodle 5.2 or 5.3 (there is no `public/admin/tool/heartbeat/` in either), so it needs the [install-plugin](../playbooks/install-plugin.md) playbook first. Once installed, configure access via Site administration → Plugins → Admin tools → Heartbeat.

## Cron lag

The metric: time since last successful cron run.

```sql
SELECT EXTRACT(EPOCH FROM NOW()) - MAX(timestart) AS seconds_since_last_cron
FROM mdl_task_log;
```

Alert if this exceeds 120 seconds for more than a minute. Cron not firing is the most common silent failure mode.

## Resource monitoring

Moodle doesn't ship a Prometheus exporter. The standard pattern:

1. **Application-level metrics**: PHP-FPM exporter (`pm.status_path = /status` + a Prometheus scraper on the FPM status endpoint). Exposes pool saturation, request rate, slow request count.
2. **DB-level metrics**: `postgres_exporter` / `mysqld_exporter`. Connection count, slow queries, replication lag.
3. **Cache metrics**: `redis_exporter` if Redis is in the topology.
4. **Webserver metrics**: Apache `mod_status` or nginx `stub_status`.

Put it in Grafana. The four dashboards that matter for Moodle: PHP-FPM saturation, DB query rate + slow query rate, Redis ops/sec + memory, and cron lag.

## What to alert on

Pri 1 (page someone now):
- HTTPS health probe fails for >2 minutes.
- DB connection failures from web pods.
- Free disk on `<dataroot>` < 10%.
- Cron lag > 5 minutes.

Pri 2 (notify, look in business hours):
- PHP-FPM saturation > 90% for 5+ minutes.
- 5xx rate > 1% sustained.
- New failed-login spikes (auth brute-force detection).
- `admin/cli/checks.php --type=security` exit non-zero.

Pri 3 (ticket):
- Plugin reports update available (Site administration → Plugins → Plugins overview).
- Log queries growing fast (capacity planning).

## What "healthy" looks like

- HTTP probe returns 200 in <500 ms.
- `mdl_task_log` has rows with `result = 0` from the last 60 seconds.
- `<dataroot>` disk usage flat or trending up slowly (not jumping).
- DB connection count steady (not climbing).
- Redis hit rate > 90% on the application cache definitions.
- No errors in the PHP error log for the last hour.

The PHP error log (Apache: `/var/log/apache2/error.log`; FPM: `/var/log/php-fpm/error.log`) is where Moodle dumps `debug_developer` messages, fatal errors, and the call traces for `print_error()` failures. **Tail this during any deploy.**

## Surfacing tenant info to Clouve ops

If you can't fix something from inside the Magneto Agent container, the user files a Clouve support ticket. Make their life easier:

- Include the value of `$CFG->release` (Site administration → Notifications, or `mdl_config WHERE name='release'`).
- Include the result of `admin/cli/checks.php --type=status`.
- Include the last 50 rows of `mdl_logstore_standard_log` filtered to the affected user, if applicable.
- Include the last 100 lines of the PHP error log.

Don't paste secrets — DB passwords, API keys, the AI Assistant's access key, user emails. Sanitize.
