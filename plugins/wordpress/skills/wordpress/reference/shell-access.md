# Channels and Shell Access

From the Magneto Agent container you have exactly **two live channels** into a WordPress deployment today: the database over TCP (`mysql`/`mysqldump`) and the site over HTTP (`curl`). A shell inside the WordPress or database container — the `clouve-ops` SSH hop that the moodle and gibbon skills treat as a given — **does not exist here**: today's WordPress images (both the Clouve-packaged one and typical developer-submitted vanilla images) ship no sshd and no `clouve-ops` account. That single fact shapes every playbook in this skill: wp-cli lives inside the Shape A web container, so **wp-cli is currently unreachable**, and every procedure gives the TCP/HTTP path as the live one.

This file is the channel matrix: what each channel gives you, how credentials arrive, how to probe for the conditional shell, and the safety gates that apply on every channel.

## The channel matrix

| Channel | Status today | Transport | What it gets you |
|---|---|---|---|
| **[TCP-mysql]** | Always live | `mysql` / `mysqldump` to the DB sibling on 3306 | Every `wp_*` table, dumps, scalar-option edits, install-state evidence |
| **[HTTP]** | Always live | `curl` to the WordPress sibling on :80 | Status codes, error pages, version inference, asset/theme existence probes, wp-cron kick |
| **[shell-only — probe first]** | **Absent today**; conditional on future images | SSH as `clouve-ops` into a sibling | wp-cli, `wp-content/` filesystem, `debug.log`, `.maintenance` removal, `wp-config.php`, chown |

## Channel 1: [TCP-mysql] — the database

The `mysql` and `mysqldump` clients are installed on the agent by this plugin's `install.sh`. Credentials arrive as env vars: the sidecar env fetcher re-exports the sibling containers' environment into your shell. **Names vary between deployments — always discover before relying on a var name:**

```bash
env | grep -iE 'wordpress|mysql|maria|host'
```

Expect the `WORDPRESS_DB_*` set (host, name, user, password) — that is your TCP credential. In the commands throughout this skill, `${WORDPRESS_HOST}` stands for the discovered web-container hostname and `${WORDPRESS_DB_*}` for the discovered credential set; substitute what discovery actually printed.

```bash
# Connectivity check (the canonical "is the DB up" probe):
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      "$WORDPRESS_DB_NAME" -e "SELECT 1"

# Confirm the real table prefix before trusting any wp_-prefixed query:
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      "$WORDPRESS_DB_NAME" -e "SHOW TABLES LIKE '%options'"

# Read-only dump (backup half #1 — see backup-restore.md):
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysqldump -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" \
      --single-transaction "$WORDPRESS_DB_NAME" > dump.sql
```

Shape caveats:

- **Shape A** (Clouve-packaged): DB is MariaDB, `:latest` and unpinned — the engine version floats per pull. Verify with `SELECT VERSION()` before anything version-sensitive.
- **Shape B** (developer compose): DB is typically MySQL 8 with `caching_sha2_password` default auth, and `MYSQL_RANDOM_ROOT_PASSWORD` is common — you have the app-scoped user only, and **root access does not exist for anyone**. If the agent's client fails with an auth-plugin error, see [troubleshooting.md](troubleshooting.md#mysql-client-cant-authenticate-shape-b--mysql-8).

## Channel 2: [HTTP] — the site

`curl` to the WordPress sibling on port 80. This is your only window into PHP-land today, so use it hard:

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

## Channel 3: [shell-only — probe first] — conditional `clouve-ops` SSH

**Expected result today: failure.** The moodle and gibbon sibling images ship sshd and a `clouve-ops` account with passwordless sudo, and those skills lean on SSH for logs, CLI scripts, and file surgery. Today's WordPress images ship **neither** — but the platform mechanism is generic, so a future WordPress image rebuild could light this channel up. Probe, never assume, and never write a plan whose happy path needs a channel you haven't proven:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new \
    "clouve-ops@${WORDPRESS_HOST}" true \
    && echo "shell channel: AVAILABLE" \
    || echo "shell channel: not available (expected today)"
```

- Any failure — connection refused (no sshd), timeout, auth rejection (no account), or `CLOUVE_OPS_PASSWORD` unset in your env — means the channel is absent. Do not retry-loop; record the result and use the TCP/HTTP path.
- Probe once per session per host; a sibling that failed the probe at session start will not spontaneously grow an sshd.

**What lights up if the probe ever succeeds** (Shape A):

- **wp-cli** at `/usr/local/bin/wp` — the preferred tool for almost everything (`wp option`, `wp user update`, `wp search-replace --dry-run`, `wp core update-db`). Run it with `--allow-root` only when you must, and chown `wp-content` afterwards — root-owned droppings persist and break later updates.
- **File operations**: enabling `WP_DEBUG_LOG` (reading an existing `wp-content/debug.log` is HTTP-fetchable — it sits in the docroot), removing a stuck `.maintenance`, gated `wp-config.php` edits, `chown -R www-data wp-content`, inspecting plugin/theme directories.
- **Not historic Apache logs**: in official-image derivatives the Apache error/access logs stream to container stderr (the files under `/var/log/apache2/` are typically links to the process's stderr), so even a shell does not buy you scrollback. `debug.log` is the readable artifact, and only once `WP_DEBUG_LOG` is on.

On Shape B even a hypothetical shell would find **no wp-cli and no mysql client** in the web container — the image is stock.

## When each channel is the right tool

- **Routine SQL, install-state evidence, backups, gated scalar-option edits** → [TCP-mysql]. Fastest, always live, best transcripts.
- **"Is the site up", version inference, existence probes, cron kick** → [HTTP].
- **Anything touching files** — `wp-config.php`, `.maintenance`, enabling `WP_DEBUG_LOG` (reading an existing `debug.log` is HTTP-fetchable when it exists), plugin/theme code, permissions → needs the shell channel. Today that means: say so plainly, offer the DB/HTTP-side alternative when one exists (this skill's playbooks list them), and otherwise route the user — many operations they can do themselves from `/wp-admin`, and the rest is a Clouve support ticket. **Do not improvise a file channel through the database** ([SKILL.md](../SKILL.md) principle 7).

## Safety gates apply on every channel

The gates in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) are channel-independent. The general rule: if a command would need user ack when run one way, it needs user ack run any other way.

- A multi-row `UPDATE`/`DELETE` over [TCP-mysql] gets its `SELECT COUNT(*)` dry-run + ack, always.
- The `active_plugins` and theme-fallback writes are gated even though they are single-row — record the current value first, print the exact SQL, wait for ack.
- [HTTP] is read-mostly but not read-only: kicking `wp-cron.php` runs due jobs, and POSTing to `install.php` **installs a site** — never POST to installer or admin endpoints without printed-command + ack.
- Over a future shell, `wp` commands that mutate state carry the same gates as their SQL equivalents, and `sudo` does not change the safety story.
- `mysqldump` output contains secrets and content — treat dump files as sensitive; never paste their contents into chat.
