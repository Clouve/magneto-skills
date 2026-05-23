# Learnings

Living scratchpad for Moodle-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

---

## 2026-04-28 — `admin/cli/` lives OUTSIDE the webroot in 5.2

In 5.2, the webroot is `<dirroot>/public/`, but `admin/cli/` stays at `<dirroot>/admin/cli/` — outside the webroot, intentionally. This means:

- `curl http://moodle/admin/cli/cron.php` returns 404 in 5.2 (was 200 with auth-bypass risk pre-5.2).
- All CLI invocations must be via `php` directly: `sudo -u www-data php /var/www/html/admin/cli/<script>.php`.
- The webserver has no way to reach these scripts.

This is a security improvement — pre-5.2 sites that didn't set `$CFG->cronclionly = true` were exposing every CLI maintenance script over HTTP.

---

## 2026-04-28 — DB choice in this skill: agnostic, with MySQL as the implicit default

The Magneto-shipped Moodle uses **MySQL 8.4** (see [apps/moodle/image/mysql/Dockerfile](../../../apps/moodle/image/mysql/Dockerfile) in the magneto repo — `FROM mysql:8.4`). MariaDB ≥10.11 and Postgres ≥16 are also supported by Moodle 5.2 and are preferred by some operators. This skill aims to be DB-agnostic — every SQL example is shown for both engines where syntax differs (e.g. `ON DUPLICATE KEY UPDATE` vs `ON CONFLICT`), and [reference/stack-and-runtime.md](reference/stack-and-runtime.md) documents the support matrix without picking a winner.

When a playbook uses `mysql` or `psql` in a one-liner, default to `mysql` (matching the shipped image). If the tenant is on Postgres, swap mentally.

---

## 2026-04-28 — Moodle 5.2 split Redis timeouts (MDL-85336)

Pre-5.2: `$CFG->session_redis_timeout = 3` (single value, applied to both connect and read).
5.2: split into `session_redis_connection_timeout` and `session_redis_read_timeout`, both accept floats.

Same applies to `cachestore_redis` admin UI. Documented in [reference/configuration.md](reference/configuration.md) and [reference/caching.md](reference/caching.md) with config-dist.php line refs.

The old single-value setting still works for backward compat — but on a 5.2 deploy, prefer the split values.

---

## Pruning rule

When an entry above is fully covered by a dedicated file under `reference/` or `playbooks/`, **delete it from this file**. Git history retains the original capture. This file should not grow beyond a screenful.
