# Channels and Shell Access

From the Magneto Agent container you can reach a WordPress deployment over three channels: the database over TCP (`mysql`/`mysqldump`), the site over HTTP (`curl`), and a shell inside the WordPress and database containers over SSH as `clouve-ops`. Which ones you get depends on the deployment's shape ([stack-and-runtime.md](stack-and-runtime.md)). On Shape A, the Clouve-packaged app, both packaged images (`wordpress` and `wordpress-mariadb`) ship the `clouve-ops` sshd, the same channel the moodle and gibbon skills use, so you have all three, and wp-cli through the shell. On Shape B, a developer's own compose with the stock image, there is no SSH server and no wp-cli, so TCP and HTTP are all you have. Every procedure in this skill labels the channel each step needs and gives the TCP/HTTP fallback where one exists.

This file is the channel matrix: what each channel gives you, how credentials arrive, how to probe for the shell, and the safety gates that apply on every channel.

## The channel matrix

| Channel | Available | Transport | What it gets you |
|---|---|---|---|
| **[TCP-mysql]** | Always | `mysql` / `mysqldump` to the DB sibling on 3306 | Every `wp_*` table, dumps, scalar-option edits, install-state evidence |
| **[HTTP]** | Always | `curl` to the WordPress sibling on :80 | Status codes, error pages, version inference, asset/theme existence probes, wp-cron kick |
| **[shell-only — probe first]** | Shape A: yes, in both containers (probe first). Shape B: no | SSH as `clouve-ops` into a sibling | wp-cli, `wp-content/` filesystem, `debug.log`, `.maintenance` removal, `wp-config.php`, chown |

## Channel 1: [TCP-mysql] — the database

The `mysql` and `mysqldump` clients are installed on the agent by this plugin's `install.sh`. Connection settings arrive as env vars: the sidecar env fetcher re-exports the sibling containers' environment into your shell, except the passwords, which `clv-secret` holds. **Names vary between deployments — always discover before relying on a var name:**

```bash
compgen -e | grep -iE 'wordpress|mysql|maria|host'
clv-secret --list | grep -iE 'wordpress|mysql|maria|host'   # the passwords' names
```

Expect the `WORDPRESS_DB_*` set (host, name and user from the first command, the password from the second). That is your TCP credential. In the commands throughout this skill, `${WORDPRESS_HOST}` stands for the discovered web-container hostname and `${WORDPRESS_DB_*}` for the discovered credential set; substitute what discovery actually printed.

```bash
# Connectivity check (the canonical "is the DB up" probe):
MYSQL_PWD="${WORDPRESS_DB_PASSWORD:-$(clv-secret WORDPRESS_DB_PASSWORD)}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      "$WORDPRESS_DB_NAME" -e "SELECT 1"

# Confirm the real table prefix before trusting any wp_-prefixed query:
MYSQL_PWD="${WORDPRESS_DB_PASSWORD:-$(clv-secret WORDPRESS_DB_PASSWORD)}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      "$WORDPRESS_DB_NAME" -e "SHOW TABLES LIKE '%options'"

# Read-only dump (backup half #1 — see backup-restore.md):
MYSQL_PWD="${WORDPRESS_DB_PASSWORD:-$(clv-secret WORDPRESS_DB_PASSWORD)}" mysqldump -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      --single-transaction --no-tablespaces "$WORDPRESS_DB_NAME" > dump.sql
```

Shape caveats:

- **Shape A** (Clouve-packaged): DB is MariaDB from the pinned `mariadb:12.3` image (12.3.2 when it was pinned). Check `SELECT VERSION()` before anything version-sensitive.
- **Shape B** (developer compose): DB is typically MySQL 8 with `caching_sha2_password` default auth, and `MYSQL_RANDOM_ROOT_PASSWORD` is common — you have the app-scoped user only, and **root access does not exist for anyone**. If the agent's client fails with an auth-plugin error, see [troubleshooting.md](troubleshooting.md#mysql-client-cant-authenticate-shape-b--mysql-8).

## Channel 2: [HTTP] — the site

`curl` to the WordPress sibling on port 80. On Shape B it is your only window into PHP-land, so use it hard. On Shape A it is still the quickest check of what users see:

```bash
# Status of the front page and the login page:
curl -sI "http://${WORDPRESS_HOST}/"
curl -sI "http://${WORDPRESS_HOST}/wp-login.php"

# Does a core static asset serve? (Distinguishes PHP fatals from a broken tree.)
curl -sI "http://${WORDPRESS_HOST}/wp-includes/js/jquery/jquery.min.js"

# Infer the code version (it is NOT in the DB — only db_version is):
curl -s "http://${WORDPRESS_HOST}/feed/" | grep -o '<generator>[^<]*</generator>'

# Does a theme directory exist? (Probe before any theme-fallback SQL.)
curl -sI "http://${WORDPRESS_HOST}/wp-content/themes/twentytwentyfive/style.css"

# Kick wp-cron on a quiet site (state-changing — announce before running):
curl -s "http://${WORDPRESS_HOST}/wp-cron.php?doing_wp_cron" -o /dev/null
```

Note that you probe the sibling over plain HTTP on :80 while real users arrive through the TLS-terminating ingress — a canonical redirect to `https://` on your direct probe can be normal, not a bug. See [troubleshooting.md](troubleshooting.md#redirect-loop) before diagnosing loops.

## Channel 3: [shell-only — probe first] — `clouve-ops` SSH

**On Shape A this channel should work.** Both packaged images, `wordpress` and `wordpress-mariadb`, ship openssh-server and the `clouve-ops` account with passwordless sudo, like the moodle and gibbon images. sshd starts when `CLOUVE_OPS_PASSWORD` is set, and the platform sets it on every deployment that runs the AI Assistant, so wherever this skill runs on Shape A the channel is there. (The same images run with no sshd on a deployment without the AI Assistant, but then nothing runs this skill.) Checked on a live Kubernetes deployment on 2026-08-05: the probe passed to both containers, wp-cli answered over SSH (`core version`, which needs no database), and [scripts/verify-health.sh](../scripts/verify-health.sh) reported GREEN. On Shape B the stock image runs no SSH server. Either way, probe first, and never write a plan whose happy path needs a channel you haven't proven:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    "clouve-ops@${WORDPRESS_HOST}" true \
    && echo "shell channel: AVAILABLE" \
    || echo "shell channel: not available"
```

- Probe the database container the same way (`clouve-ops@${WORDPRESS_DB_HOST}`) before a step that needs a shell there.
- On Shape B a failed probe is normal. Record it and use the TCP/HTTP path.
- On Shape A a failed probe is a problem to report. sshd starts a little after its container does, so retry once after a short wait. If it still fails, check "Failure modes" below, tell the user what failed, and use the TCP/HTTP path meanwhile. Don't retry in a loop.

Pass `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null` on every connection, as every command in this skill does. The two options take the key the container shows and save nothing. A rebuilt image has new host keys, and a key saved earlier is then wrong, so ssh refuses it ("REMOTE HOST IDENTIFICATION HAS CHANGED"). On an older agent, which has no SSH settings of its own for the app's containers, a command without the options also fails at the first connection: `sshpass` can't answer the yes/no prompt for a key it doesn't know, and exits 6 without printing anything.

**What the shell gives you** (Shape A):

- **wp-cli** at `/usr/local/bin/wp`, the preferred tool for almost everything (`wp option`, `wp user update`, `wp search-replace --dry-run`, `wp core update-db`). Run it through [scripts/wp.sh](../scripts/wp.sh), written `wp.sh` in these docs:
  ```bash
  /clouve/skills/wordpress/plugin/skills/wordpress/scripts/wp.sh core version
  /clouve/skills/wordpress/plugin/skills/wordpress/scripts/wp.sh option get siteurl
  ```
  It runs `wp --path=/var/www/html` as the web server's user, so whatever it writes belongs to `www-data`, and it gives wp WordPress's own database settings. An SSH session doesn't have them: the image's `wp-config.php` reads them from the container's environment, which sshd doesn't pass on, so a wp command you run over SSH yourself stops with `Error establishing a database connection` as soon as it needs the database. `wp.sh` takes the settings `wp-config.php` reads (the `WORDPRESS_DB_*` names, the table prefix, the keys and salts) from the environment of the container's first process (`/proc/1/environ`, read with sudo) and hands them to wp in its environment, so no value appears on a command line. It quotes each argument for you, passes wp's output and exit code through, and keeps no host key. Its stdin is closed, so nothing can be piped into it. `core version` needs no database, which is why it worked on the 2026-08-05 check.
  Since wp sees the real settings, a command that prints `wp-config.php`'s constants would put the database password, a key or a salt into the chat. `wp.sh` refuses `config list` and `config get` of `DB_PASSWORD` or any `*_KEY` or `*_SALT`. To see whether a constant is set, use `wp.sh config has <NAME>`, and for the names, `wp.sh config list --fields=name`. Don't print wp's environment or `phpinfo()` with `wp.sh eval` either: it holds the database password.
  Avoid `--allow-root`: the root-owned files it leaves behind persist and break later updates. If root was unavoidable, `sudo chown -R www-data:www-data` the paths it touched.
- **File operations**: enabling `WP_DEBUG_LOG` with the log outside the docroot ([configuration.md](configuration.md)), removing a stuck `.maintenance`, gated `wp-config.php` edits, `chown -R www-data wp-content`, inspecting plugin/theme directories.
- **Not historic Apache logs**: in official-image derivatives the Apache error/access logs stream to container stderr (the files under `/var/log/apache2/` are typically links to the process's stderr), so even a shell does not buy you scrollback. `debug.log` is the readable artifact, and only once `WP_DEBUG_LOG` is on.

On Shape B there is no shell, and the stock web image has **no wp-cli and no mysql client** either.

### Failure modes

| Symptom | Likely cause |
|---|---|
| `Connection refused` right after the pod or a container started | sshd isn't up yet. Retry after a few seconds. |
| `Connection refused` that persists | Shape B: there is no sshd, which is normal. Shape A: the container started without `CLOUVE_OPS_PASSWORD`, so its start script logged `[clouve-ops-sshd] ✗ CLOUVE_OPS_PASSWORD is unset — sshd will not start` to the container log, which you can't read from here. Tell the user, and use the TCP/HTTP path. |
| `Permission denied` | Shape A: the password this container has differs from the one the sibling applied with `chpasswd` at its start, or the sibling hasn't applied it yet. Retry once after a few seconds; if it persists, tell the user. Shape B: there is no `clouve-ops` account. |
| `Host key verification failed`, or sshpass exits 6 with nothing printed | The command lacks `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null`, and the agent has no SSH settings for this container: add both options. Leave `~/.ssh/known_hosts` as it is. |
| `Connection timed out` or `Could not resolve hostname` | Wrong host name, or the container is down. Rediscover the names with the commands under Channel 1 above, and check that the site and database still answer over HTTP and TCP. |

## When each channel is the right tool

- **Routine SQL, install-state evidence, backups, gated scalar-option edits** → [TCP-mysql]. Fastest, always live, best transcripts.
- **"Is the site up", version inference, existence probes, cron kick** → [HTTP].
- **Anything touching files** — `wp-config.php`, `.maintenance`, enabling `WP_DEBUG_LOG` (reading an existing `debug.log` is HTTP-fetchable when it exists), plugin/theme code, permissions → the shell channel. On Shape A, use it once the probe passes. On Shape B, or after a failed probe, say so plainly, offer the DB/HTTP-side alternative when one exists (this skill's playbooks list them), and otherwise route the user — many operations they can do themselves from `/wp-admin`, and the rest is a Clouve support ticket. **Do not improvise a file channel through the database** ([SKILL.md](../SKILL.md) principle 7).

## Safety gates apply on every channel

The gates in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) are channel-independent. The general rule: if a command would need user ack when run one way, it needs user ack run any other way.

- A multi-row `UPDATE`/`DELETE` over [TCP-mysql] gets its `SELECT COUNT(*)` dry-run + ack, always.
- The `active_plugins` and theme-fallback writes are gated even though they are single-row — record the current value first, print the exact SQL, wait for ack.
- [HTTP] is read-mostly but not read-only: kicking `wp-cron.php` runs due jobs, and POSTing to `install.php` **installs a site** — never POST to installer or admin endpoints without printed-command + ack.
- Over the shell, `wp` commands that mutate state carry the same gates as their SQL equivalents, and `sudo` does not change the safety story.
- `mysqldump` output contains secrets and content — treat dump files as sensitive; never paste their contents into chat.
