# Moodle DevOps reference

Per-topic facts about Moodle 5.3.0, sourced from the upstream tag `v5.3.0` (commit `42622298fe06f9626d988d60b2bf589bd8f850e8`) and the [official 5.3 admin docs](https://docs.moodle.org/503/en/Main_page). Where a fact differs on 5.2, the doc says so; [changes-in-5.3.md](changes-in-5.3.md) lists what changed.

## How to navigate

Start with [stack-and-runtime.md](stack-and-runtime.md) and [architecture.md](architecture.md) when onboarding to a new instance — the rest of the docs assume you know which file lives at the project root vs. inside `public/`.

| File | What it covers |
|---|---|
| [shell-access.md](shell-access.md) | SSH'ing into the moodle / moodle-mysql side containers as `clouve-ops`, when to use SSH vs. TCP `mysql`/`curl` |
| [stack-and-runtime.md](stack-and-runtime.md) | PHP 8.3+, supported DBs (MariaDB 11.4+, PostgreSQL 17+, MySQL 8.4+, MSSQL 15+; 5.2 took MariaDB 10.11+ and PostgreSQL 16+), required + recommended PHP extensions, OS-level packages, filesystem layout |
| [architecture.md](architecture.md) | The `public/` webroot (required since 5.2), request lifecycle, plugin taxonomy, where each subsystem lives |
| [configuration.md](configuration.md) | `config.php` cheat sheet — DB, paths, sessions, MUC, sslproxy, debug, security flags — with the recommended `getenv()` pattern |
| [install-and-bootstrap.md](install-and-bootstrap.md) | Non-interactive install via `admin/cli/install_database.php`, the `mdl_config` install sentinel, what "installed" means |
| [upgrade.md](upgrade.md) | `version.php` ↔ `mdl_config(version)` invariant, `admin/cli/upgrade.php` flag semantics, exit codes, the `requires=4.4` floor for 5.2 and 5.3 |
| [cron-and-tasks.md](cron-and-tasks.md) | Every-minute cron, `tool_task` scheduled vs. adhoc tasks, `--keep-alive` daemon mode, lock factories |
| [caching.md](caching.md) | MUC stores in 5.2 and 5.3 (apcu, file, redis, session, static — memcached and mongodb cache stores are gone), recommended store mappings |
| [file-storage.md](file-storage.md) | `moodledata/filedir/` content-addressable layout, `alternative_file_system_class`, shared-volume requirement for HA |
| [backup-restore.md](backup-restore.md) | DB + `moodledata` coordination, course-level `.mbz` vs. site-level snapshots, maintenance-mode timing |
| [data-model.md](data-model.md) | Never-touch tables, safe-to-touch tables, the `mdl_config` / `mdl_config_plugins` / `mdl_user` / `mdl_course` tables |
| [security.md](security.md) | File permissions, https + sslproxy, `preventexecpath`, cookies, antivirus, CSRF/sesskey, headers |
| [performance.md](performance.md) | PHP-FPM pool sizing, OPcache, `cachejs`, theme designer mode warning, DB read/write split |
| [scaling.md](scaling.md) | Preconditions for horizontal scaling: shared `moodledata`, shared MUC, shared session store |
| [observability.md](observability.md) | `report_log`, `tool_log`, `admin/cli/checks.php`, the `\core\check\check` framework, liveness/readiness probes |
| [troubleshooting.md](troubleshooting.md) | Failure modes seen in the wild and the first thing to check for each |
| [changes-in-5.3.md](changes-in-5.3.md) | What changed from 5.2 to 5.3: the Classic theme, what the image does when it upgrades a site, the new security check, the database floors |
| [changes-in-5.2.md](changes-in-5.2.md) | The operator-relevant 5.1 to 5.2 changes, distilled from `UPGRADING.md`; they still hold on 5.3 |

## Citation convention

When a fact in these docs is sourced from the upstream tree, the citation links to GitHub at tag `v5.3.0` so the reference is stable: `[public/version.php](https://github.com/moodle/moodle/blob/v5.3.0/public/version.php)`. When the fact comes from the Clouve packaging, the link is relative into the `apps/moodle/` tree.
