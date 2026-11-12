# Playbook: Diagnose a Gibbon 500

Use when the tenant reports "Gibbon is down" or "pages show an error." A 500 in Gibbon has a few distinct root-cause buckets; walk them in order of probability.

## Step 0 — confirm the symptom

```bash
curl -sI http://gibbon/index.php
# 200 — it's not actually down; the user is seeing a page-level error somewhere else
# 500 — genuine 5xx from Apache
# 502/503/504 — Apache/Gibbon container is not reachable (not a Gibbon issue — escalate)
# timeout / connection refused — network layer; check the pod is running
```

Ask the user for the **exact URL** that's broken and the **exact error text** they see. "It's broken" is not specific enough; "System Admin → Manage Users shows 500" is.

## Step 1 — is the container even running?

Step 0 tells you whether Apache answers. If it doesn't, try the `clouve-ops` channel ([reference/shell-access.md](../reference/shell-access.md)): if ssh connects, the container is running and Apache isn't answering; if ssh is refused or times out, the container is down or still starting. The platform restarts a container that fails its health check for 7.5 minutes ([reference/operations-and-signals.md](../reference/operations-and-signals.md)). The user's Clouve dashboard has no container list, no log view and no restart button for the app, so if the container stays down or keeps restarting, the user files a support ticket with the time it started and Step 0's output. Clouve support can see the container's state and its log.

## Step 2 — DB reachable?

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysqladmin -h "$GIBBON_DB_HOST" -u gibbon ping
# Expect: "mysqld is alive"
# If it fails: gibbon-mysql container is down, or DB_PASSWORD env is wrong.
```

If DB is down → escalate to ops. If the password stopped matching, that is Clouve support's to fix too ([rotate-admin-credentials.md](rotate-admin-credentials.md), section 2).

## Step 3 — version mismatch?

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -sN -e \
  "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';"
# Compare to the container's code version:
curl -sf http://gibbon/version.php 2>/dev/null || echo "version.php returned non-200"
# (Gibbon doesn't expose version.php over HTTP by default — you may need the tenant to share
#  the value from their System Admin → System Overview page.)
```

If the DB version is behind the code version, a migration is pending. Running some module pages against the wrong schema produces 500s. Follow [upgrade-gibbon.md step 4](upgrade-gibbon.md) — run `/update.php`.

## Step 4 — `config.php` intact?

Quick signal: if the login page renders but all post-login pages 500, `config.php` is usually fine (Gibbon got past the DB connect). If the login page itself 500s, `config.php` may be broken.

Check the file over the `clouve-ops` channel ([reference/shell-access.md](../reference/shell-access.md)). It holds the database password, so check it without printing it. `php -l` names the token where it stopped, which can be part of a broken password line, so the command keeps its answer to "parses" or a line number:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'sudo test -s /var/www/html/config.php && echo "config.php: not empty"; if sudo php -l /var/www/html/config.php > /dev/null 2>&1; then echo "config.php: parses"; else echo "config.php: does not parse"; sudo php -l /var/www/html/config.php 2>&1 | grep -o "on line [0-9]*"; fi'
```

Only if it parses, check the settings it must hold. This prints `set` or `EMPTY` for each, never a value:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} 'sudo php' <<'PHP'
<?php
include '/var/www/html/config.php';
foreach (['databaseServer', 'databaseName', 'databaseUsername', 'databasePassword', 'guid'] as $name) {
    echo $name, ': ', empty($$name) ? 'EMPTY' : 'set', PHP_EOL;
}
PHP
```

Expect `set` on every line. Also: `$version` matches `version.php`, and `$guid` is a 36-char string with dashes.

If `config.php` is broken, check whether the most recent restart ran `update-config.sh` cleanly. The script escapes `/` and `&` in `$DB_PASSWORD` for its sed, but not a `'` or a `\`, and either one breaks the password line (see [reference/troubleshooting.md#4](../reference/troubleshooting.md)). Restore `config.php` from backup.

## Step 5 — file permissions

If a specific page 500s with "permission denied" or "could not write to" in the error:

The error text itself is in Apache's error log, which usually isn't readable from here ([reference/shell-access.md](../reference/shell-access.md#the-apache-error-log)). Check the ownership directly over the `clouve-ops` channel:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST} \
  'ls -ld /var/www/html/uploads /var/www/html/uploads/cache; sudo find /var/www/html/uploads ! -user www-data | head -20'
```

Common: `/var/www/html/uploads/` or `/var/www/html/uploads/cache/` not writable by `www-data`. Fix it over the same channel, after the user's ack: `sudo chown -R www-data:www-data /var/www/html/uploads`.

## Step 6 — bad module

A recently-installed or recently-upgraded module is a top suspect for 500s.

```bash
# Any module changes recently?
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e \
  "SELECT name, version, type, active FROM gibbonModule ORDER BY gibbonModuleID;"
# What's the page URL that 500s? What module does it belong to?
# The module can be found from the URL path: /modules/<ModuleName>/<file>.php.
```

If the 500 is isolated to one module:
- Disable it temporarily: `UPDATE gibbonModule SET active='N' WHERE name='<ModuleName>'` (require user ack).
- If it's an Additional module, uninstall it (see [install-module.md](install-module.md)) and restore from backup if its install corrupted state.
- If it's a Core module → do NOT disable; a Core-module 500 is a deeper issue (schema mismatch, usually from step 3).

## Step 7 — log table overflow or lock contention

Very busy schools can see `gibbonLog` grow to GB-scale and slow the whole app down. Check:

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u gibbon gibbon -e "
  SELECT COUNT(*) FROM gibbonLog;
  SELECT table_schema, table_name, ROUND(data_length/1024/1024, 2) AS size_mb
  FROM information_schema.tables
  WHERE table_schema='gibbon'
  ORDER BY data_length DESC LIMIT 10;"
```

If `gibbonLog` is dominant (> 1 GB), offer a prune:
```sql
-- Show first, prune after user ack
SELECT COUNT(*) FROM gibbonLog WHERE timestamp < NOW() - INTERVAL 1 YEAR;
-- Then with ack:
DELETE FROM gibbonLog WHERE timestamp < NOW() - INTERVAL 1 YEAR;
```

## Step 8 — uploads cache corruption

Twig compile errors manifest as 500 on the first page load after a code change, then resolve themselves. If the error text mentions `twig` or a template path, the cache is stale or corrupt.

From the Gibbon UI: **System Admin → Cache Manager → Clear Cache**.
Or empty it yourself over the `clouve-ops` channel, after telling the user: `sudo find /var/www/html/uploads/cache -mindepth 1 -delete`. Keep the folder itself, since `entrypoint.sh` expects it. The next container start empties it too, but the user has no restart button for the app.

## If nothing above matches

1. Capture everything:
   - Exact URL, exact error, tenant's browser console + network tab if they can share.
   - `gibbonLog` entries in the last 10 minutes.
   - Output of all diagnostic queries above.
2. Put that evidence in the support ticket. Apache's error log is the `gibbon` container's own output, which Clouve support can read and nothing in this pod can ([reference/shell-access.md](../reference/shell-access.md#the-apache-error-log)).
3. If it's reproducible after a restart and the tenant hasn't changed anything, file it upstream at `github.com/GibbonEdu/core/issues` with the stack trace.
4. Last resort: restore from backup to a known-good state, then observe whether the issue recurs.

## Do NOT

- Do NOT "fix" a 500 by disabling error reporting. Errors you hide still break things.
- Do NOT edit PHP files on the `gibbondata` volume speculatively — changes survive the restart but not the next app upgrade.
- Do NOT assume the issue is Gibbon's. 502/503/504 are ingress/pod issues; escalate to Clouve ops before spelunking in Gibbon.
