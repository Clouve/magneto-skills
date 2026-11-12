# Shell Access (`clouve-ops` SSH)

You have an interactive shell into both side containers via SSH as the `clouve-ops` operator account. The account is dedicated to this app's DevOps agent (you), pre-created in both images, and has **passwordless sudo for everything** — treat it as effective root inside those containers, gated only by the safety rules in [SKILL.md](../SKILL.md).

This file describes when SSH is the right tool vs. the TCP `mysql`/`curl` channels, and the safety gates that apply over the SSH hop.

## Authenticating

The per-pod password is `CLOUVE_OPS_PASSWORD`. It isn't in your environment on current agents, so each command fetches it with `${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}` and sets `SSHPASS` on the `sshpass` command itself. `sshpass -e` reads the password from `SSHPASS` rather than the command line, so it never lands in shell history or `ps`. Don't `export SSHPASS` once and reuse it: your next Bash call starts without it.

```bash
# Open an interactive shell in the moodle container:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST}

# Open an interactive shell in the moodle-mysql container:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_DB_HOST}

# Run a one-shot command (preferred for scripted operations):
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    "df -h /var/moodledata"
```

Pass `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null` on every connection, as every command in this skill does. The two options take the key the container shows and save nothing. From the 5.3 image on, the `moodle` container makes a new SSH host key at every start, so a key saved earlier is wrong after the next restart, and ssh refuses it ("REMOTE HOST IDENTIFICATION HAS CHANGED"). An older agent has no SSH settings of its own for the app's containers, so there a command without the options stops at the first connection: `sshpass` can't answer the yes/no prompt for a key it doesn't know, and exits 6 without printing anything.

## When SSH is the right tool

The SSH hop is unambiguously needed for any of:

- **Checking the Apache logs.** On this image `/var/log/apache2/error.log` and `access.log` are links to the container's own output, which even SSH can't read: see [The Apache error log](#the-apache-error-log) before you read either.
- **Running Moodle CLI scripts.** `admin/cli/*.php` lives at `/var/www/html/admin/cli/` inside the moodle container. Use `sudo -u www-data php /var/www/html/admin/cli/<script>.php` so the script runs as the web user with the right `$CFG->dataroot` permissions. [scripts/temp-password.sh](../scripts/temp-password.sh) sends a new password through sudo's stdin this way, so don't turn on a sudo log in the container that records what a command reads (sudo's I/O log): it would keep the password.
- **Inspecting `/var/www/html` filesystem.** Listing plugin directories, checking `<dataroot>` permissions, locating a config file.
- **Reloading Apache.** `sudo apachectl graceful`. The containers have no systemd, so there is no `systemctl`. A `config.php` edit takes effect within a minute without a reload, since OPcache checks files every 60 seconds on this image; the reload applies it at once.
- **Inspecting MySQL internals on the DB host.** `/etc/my.cnf`, `/var/lib/mysql/`, slow query log files, disk use. The Clouve image runs MySQL 8.4.
- **Writing to `<dataroot>` for diagnostics.** E.g. `chown -R www-data:www-data <dataroot>` after a volume remount.

## When NOT to use SSH

The SSH hop is overkill (and slower) for:

- **Routine SQL.** From the Magneto Agent container you can `mysql -h ${MOODLE_DB_HOST} ...` or `psql -h ${MOODLE_DB_HOST} ...` over TCP — no SSH hop needed.
- **HTTP probes.** `curl -sI -H "Host: ${MOODLE_URL#*://}" http://${MOODLE_HOST}/login/index.php` works directly. Send the site's host: Moodle answers any other host with a 303 to its `wwwroot`, and on Kubernetes `${MOODLE_HOST}` is the internal service name.
- **Reading files that the script wrapper already exposes.** [scripts/php-info.sh](../scripts/php-info.sh) and [scripts/verify-health.sh](../scripts/verify-health.sh) are designed to give you the data you need without SSH.

The TCP channels (mysql, curl) are faster and produce more reliable transcripts. Reach for SSH only when you need filesystem access or a process inside the target container.

## Safety gates apply over SSH too

Having a `sudo` prompt does not change the safety story. Every gate from [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) applies whether the command runs locally in Magneto Agent or via SSH:

- `sudo apachectl stop` is destructive — gate it.
- Stopping `mysqld` on the DB host stops that container, and the site has no database until it's back. There's no systemd to stop it gently. Gate it, and prefer Clouve support.
- `sudo rm -rf /var/www/html/...` is destructive — gate it.
- `sudo mysqldump --all-databases > /tmp/dump.sql` is fine (read-only) but **its output may contain secrets** — be careful where you put the file and what you do with it next.
- `sudo php /var/www/html/admin/cli/upgrade.php` IS the upgrade — gate it via [playbooks/upgrade-moodle.md](../playbooks/upgrade-moodle.md).
- `sudo -u www-data php /var/www/html/admin/cli/maintenance.php --enable` is fine (idempotent state change) and you should announce it before running.

The general rule: if the same command would require user ack when run from Magneto Agent, it requires user ack when run via SSH.

## The Apache error log

Check what `/var/log/apache2/error.log` is before reading it:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    "ls -l /var/log/apache2/"
```

The moodle image is built on `php:8.3-apache`, whose `error.log` and `access.log` are links to `/dev/stderr` and `/dev/stdout`. Then Apache's and PHP's errors go to the container's own log, which nothing in this pod can read, SSH included: don't `tail` the link, since the command hangs and reads nothing. Work from what you can see (the HTTP response, the error text the user saw, `mdl_logstore_standard_log`, `mdl_task_log`, `admin/cli/checks.php`, `php -l` on a suspect file) and leave the container log to Clouve support. If `error.log` is a regular file on this install, `sudo tail -100` it.

## Common one-shot commands

```bash
# Check the running Moodle code version
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \$CFG->version, PHP_EOL;"'

# List currently running scheduled tasks
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --list'

# Check whether an upgrade is pending
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-pending; echo "exit: $?"'

# Read the effective config value for a setting
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cfg.php --name=lang'

# Check disk usage on the dataroot volume
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} 'df -h /var/moodledata'

# Check directory permissions on dataroot
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} 'ls -la /var/moodledata | head'

# Reload Apache after a config.php change
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} 'sudo apachectl graceful'

# On the DB host: show the MySQL version
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_DB_HOST} 'mysqld --version'
```

## What you do NOT do over SSH

- Edit the database or `wwwroot` lines of `<dirroot>/config.php`. The image writes them from the deployment's settings at every start, and only Clouve can change those settings, so an edit there breaks the site or is undone at the next start ([reference/configuration.md](configuration.md)). Other `config.php` edits go through the gate in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow).
- Install plugins by `git clone`-ing into `<dirroot>/local/`. Use [playbooks/install-plugin.md](../playbooks/install-plugin.md) instead: it vets the plugin and takes a backup first. Plugins on the code volume survive pod restarts, and the image's upgrade carries them over to a newer Moodle.
- Modify Moodle's own code under `<dirroot>`. The next image upgrade replaces it with a clean copy, so the edit is lost, and a broken core file can take the site down until then.
- Stop or restart `mysqld`. Stopping it stops the database container, and the site is down until the container is back. Even with sudo, gate it, and prefer Clouve support.
