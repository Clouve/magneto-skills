---
name: odoo
description: 'Safely operate an Odoo 19.0 ERP install — install/upgrade modules, filestore-aware backups and restores, prod→staging neutralization, database-manager hardening, and diagnosing module/upgrade failures — without corrupting accounting or framework data. Use when the user is running the Clouve Odoo app, mentions "Odoo", `odoo-bin`, `odoo.conf`, the master password, `account.move`, `ir_model_data`, `ir.config_parameter`, the filestore, or `/web/database/manager`. Do not use for generic Python/PostgreSQL/Linux questions that are not tied to an Odoo instance.'
type: devops
version: 0.1.3
authoredAgainst: odoo 19.0
---

# Odoo DevOps Skill

You are the operator of a live Odoo 19.0 ERP. It holds real business data: posted invoices, journal entries, inventory, customers. The people asking are business admins, not developers. Assume they trust you not to corrupt their accounting.

## When to use this skill

Use this skill when the user is working with the Clouve Odoo app, when they mention Odoo or odoo.com, or when they reference any of: `odoo-bin`, `odoo.conf`, the master password (`admin_passwd`), `account.move`, `ir_model_data`, `ir.config_parameter`, the filestore at `/var/lib/odoo/filestore/`, `/web/database/manager`, or any Odoo module management via `-u`/`-i`/`--stop-after-init`.

## When NOT to use this skill

- Generic "how does Python/PostgreSQL/Linux work" questions with no Odoo tie-in.
- The user is building a new application from scratch.
- The user is debugging Magneto Agent itself (the terminal, FileBrowser, nginx, `.bash_profile`, `/_clv/`) — that is not Odoo's concern.
- The user is asking about another app in the same pod — unless the question is about Odoo's side of an integration.

## Operating principles (golden rules — load-bearing — read before any destructive action)

1. **A complete backup is the PG dump AND the filestore.** Prefer `odoo-bin db dump <db> <out.zip>` — it produces a ZIP of `dump.sql` (`pg_dump --no-owner`) + `filestore/` + `manifest.json`, bypasses the master password, and is the only self-contained restore unit. A hand-rolled `pg_dump` alone silently omits the per-DB filestore (`/var/lib/odoo/filestore/<dbname>`); missing attachment files read back as empty `b''` with no error. Take backups by piping the skill's own [scripts/backup.sh](scripts/backup.sh) into the Odoo container ([playbooks/backup.md](playbooks/backup.md), step 1). By hand, give the config as `ODOO_RC=/etc/odoo/odoo.conf`: `-c` after `dump` is an error. → [reference/backup-restore.md](reference/backup-restore.md).

2. **`odoo` ≡ `odoo-bin`.** Both shim `odoo.cli.main()`. Install or upgrade a module while the server keeps serving, with the `module` subcommand: `sudo odoo module install -c /etc/odoo/odoo.conf -d <db> <module>` (or `module upgrade`); the server reloads its registry by itself. The classic flags do the same as a one-shot run: `sudo odoo -c /etc/odoo/odoo.conf -d <db> -i <module> --stop-after-init` (`-u` to upgrade). Over the clouve-ops channel every `odoo` command needs the config (`-c /etc/odoo/odoo.conf`, or `ODOO_RC=` for `odoo db`), because `sudo` drops the image's `ODOO_RC`. Module **uninstall** executes `DROP TABLE/COLUMN CASCADE` plus cascades to dependents — it is irreversible; the only recovery is restore from backup. → [reference/module-lifecycle.md](reference/module-lifecycle.md).

3. **`odoo shell` rolls back unless you `env.cr.commit()`.** The shell runs as SUPERUSER and calls `cr.rollback()` both before and after the session. Changes that are not followed by an explicit `env.cr.commit()` are silently discarded. → [reference/shell-access.md](reference/shell-access.md).

4. **Never write to these tables or columns via raw SQL** — all integrity is ORM/Python-enforced with no DB triggers; a single raw `UPDATE`/`DELETE` corrupts state unrepairably:
   - `account_move` / `account_move_line` — SHA-256 hash chain, gapless sequence, lock dates, audit trail. Undo only via reversal/credit note (`_reverse_moves`), never delete or edit a posted entry.
   - `ir_model_data` — the XML-ID ↔ res_id backbone for all installed data.
   - `ir_model` / `ir_model_fields` — ORM registry metadata.
   - `ir_module_module.state` — stuck states (`to install`/`to upgrade`/`to remove`) recover via `button_reset_state()` / `reset_modules_state()`, never by hand-editing the column.
   - `ir_sequence` and reconciliation tables.
   - Protected `ir_config_parameter` keys: `database.secret`, `database.uuid`, `database.create_date`, `web.base.url`, `base.login_cooldown_*`.
   → [reference/data-model.md](reference/data-model.md), [reference/accounting-integrity.md](reference/accounting-integrity.md).

5. **Reverse posted entries via credit note/reversal, never delete; `hard_lock_date` is irreversible.** Posted `account.move` entries carry a SHA-256 hash chain and gapless sequence enforced in Python — no DB trigger will catch a raw change, but the next hash verification will detect tampering with no repair path. → [reference/accounting-integrity.md](reference/accounting-integrity.md).

6. **Never expose `/web/database/*`; treat `admin_passwd` like an API key.** All nine `/web/database/*` routes are `auth='none'`; the mutating ones are `csrf=False`; the only gate is the master password. While `admin_passwd` is still the default `'admin'`, the first submitted password is silently adopted. The real kill-switch is `list_db=False` (or `--no-database-list`) **plus** a pinned `db_name`/`dbfilter`; the manager GET page still returns 200 with a banner when disabled, so verify lockdown via the POST endpoints and block the `/web/database/` prefix at the ingress. → [reference/security.md](reference/security.md), [playbooks/harden-db-manager.md](playbooks/harden-db-manager.md).

7. **Restart Odoo inside its container with `SIGHUP`; logs go to stderr.** Odoo is the container's main process (PID 1, `workers=0` threaded server). `sudo kill -HUP 1` over the clouve-ops channel makes it finish in-flight requests and re-execute itself in place: same container, back within seconds, `odoo.conf` and `addons_path` read again. Installing or upgrading a module needs no restart; new code in `/mnt/extra-addons` does. Never send `SIGTERM` or `SIGKILL` to PID 1 (the container stops with it), and don't hand restarts to the tenant: the Clouve dashboard has no restart button. Logs are StreamHandler→stderr (no `--logfile` set), read through the platform's log view (`kubectl logs` / `docker logs`). There is no `/var/log/odoo` path and no web server process in this container. → [reference/stack-and-runtime.md](reference/stack-and-runtime.md#restarting-odoo), [reference/observability.md](reference/observability.md).

8. **Any non-production clone must be neutralized before use.** `sudo odoo neutralize -c /etc/odoo/odoo.conf -d <db>` (add `--stdout` to audit first) disables mail servers, all crons (except autovacuum), payment providers, and webhooks, and sets `database.is_neutralized=true`. Skipping this step risks sending real emails or processing real payments from the clone. → [reference/neutralization.md](reference/neutralization.md), [playbooks/restore-and-clone.md](playbooks/restore-and-clone.md).

9. **Vet third-party addons before install.** Addons go in `/mnt/extra-addons` (on `addons_path` as the pattern `/mnt/extra-addons*`, which Odoo loads at its next start once a module is in it). They run arbitrary Python with full DB access and filestore write. Read `__manifest__.py` and the top-level Python before installing. → [reference/module-lifecycle.md](reference/module-lifecycle.md).

10. **Never expose the AI Assistant's access key** (`MAGNETO_AGENT_LLM_KEY`; `ANTHROPIC_AUTH_TOKEN` in your session). Clouve manages and rotates it, one key per deployment. Never print it, copy it to another path, or send it anywhere.

## Environment you are running in

- You are inside the Magneto Agent container in the app's pod.
- Odoo is reachable at `${ODOO_HOST}:8069`. The Odoo database runs at `${ODOO_DB_HOST}` (PostgreSQL). Both are injected into your environment by the platform — confirm the actual variable names with `compgen -e | grep -i odoo` (names only), and the passwords' names with `clv-secret --list | grep -i odoo`, before relying on any specific one.
- Passwords aren't in your environment on current agents. Commands here fetch one with `${NAME:-$(clv-secret NAME)}`, which also works on older agents. `clv-secret --list` shows the names. Never run `clv-secret NAME` on its own or print a value.
- You have an interactive shell in the Odoo and Postgres containers via SSH as the `clouve-ops` operator account (passwordless sudo). The credential is the per-pod password, `CLOUVE_OPS_PASSWORD`. Connect with:
  ```bash
  SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_HOST}
  SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${ODOO_DB_HOST}
  ```
  On the first connection add `-o StrictHostKeyChecking=accept-new`: while the host key is unknown, `sshpass` exits 6 without printing anything.
- `sudo` in these sessions drops the `ODOO_RC` the image sets, so give every `odoo` command its config: `-c /etc/odoo/odoo.conf` for the server, `shell` and `module` commands, `ODOO_RC=/etc/odoo/odoo.conf` in front of `odoo db`. The database's superuser role is `${ODOO_DB_USER}`; there is no `postgres` role, so `psql` and `pg_dump` run as `sudo -u postgres` need `-U ${ODOO_DB_USER}`.
- Use the SSH channel for OS-level operations (running `odoo-bin`, reading logs, editing `odoo.conf`). Use the TCP PostgreSQL connection (`psql`) for read-only queries and gated writes. → [reference/shell-access.md](reference/shell-access.md).

## Pointers into the deeper docs

- [reference/stack-and-runtime.md](reference/stack-and-runtime.md) — Odoo 19.0 entrypoints (`odoo` ≡ `odoo-bin`), Python/PG version requirements, filesystem layout, process model, subcommand registry, restarting Odoo with `SIGHUP`.
- [reference/configuration.md](reference/configuration.md) — `odoo.conf` / `odoo-bin` option cheat sheet: `admin_passwd`, `list_db`, `db_name`/`dbfilter`, `proxy_mode`, `data_dir`, `addons_path`, `workers`, `logfile`; env-var-driven pattern.
- [reference/data-model.md](reference/data-model.md) — never-touch tables and columns, safe-to-read tables, how `ir_model_data`, `ir_config_parameter`, `ir_module_module`, `res_users` work.
- [reference/file-storage.md](reference/file-storage.md) — filestore layout (`<data_dir>/filestore/<dbname>`, content-addressed `sha1[:2]/sha1`), attachment model, missing-file silent-empty behaviour.
- [reference/backup-restore.md](reference/backup-restore.md) — `odoo-bin db dump` ZIP anatomy, CLI vs HTTP backup paths, filestore-aware restore via `odoo-bin db load`, manual `pg_dump`+filestore-tar fallback.
- [reference/security.md](reference/security.md) — DB-manager hardening, `admin_passwd` footgun, `list_db=False` kill-switch, `proxy_mode`, cookie flags, ingress-level `/web/database/` block.
- [reference/module-lifecycle.md](reference/module-lifecycle.md) — `-i`/`-u`/`--stop-after-init` mechanics, `odoo-bin module` subcommands, uninstall irreversibility, stuck-state recovery, third-party addon vetting.
- [reference/accounting-integrity.md](reference/accounting-integrity.md) — hash chain, gapless sequence, lock dates, `hard_lock_date` irreversibility, reversal/credit-note pattern, hash integrity check.
- [reference/neutralization.md](reference/neutralization.md) — what `odoo-bin neutralize` disables, `--stdout` audit mode, `database.is_neutralized` sentinel, when to run it.
- [reference/observability.md](reference/observability.md) — stderr log model, `--log-handler MODULE:LEVEL`, reading via `kubectl/docker logs`, no `logfile` in the container, no separate web-server log path.
- [reference/shell-access.md](reference/shell-access.md) — `odoo shell` SUPERUSER env, rollback-unless-commit, `env.cr.commit()` pattern; `clouve-ops` SSH channel safety gates.
- [playbooks/install-or-upgrade-module.md](playbooks/install-or-upgrade-module.md) — step-by-step module install/upgrade while Odoo keeps serving: backup gate, third-party code into `/mnt/extra-addons` plus an in-container `SIGHUP` restart, one-shot install, verification.
- [playbooks/backup.md](playbooks/backup.md) — pre-action backup: pipe `scripts/backup.sh` into the Odoo container; manual `odoo db dump` and `pg_dump` fallbacks; copying the backup off the container.
- [playbooks/restore-and-clone.md](playbooks/restore-and-clone.md) — restore from ZIP via `odoo-bin db load`, prod→staging clone workflow, mandatory neutralization step.
- [playbooks/harden-db-manager.md](playbooks/harden-db-manager.md) — set `admin_passwd`, enable `list_db=False` + `db_name`/`dbfilter`, verify via POST endpoint, block `/web/database/` at ingress.
- [playbooks/recover-stuck-module-state.md](playbooks/recover-stuck-module-state.md) — diagnose `to install`/`to upgrade`/`to remove` stuck states; `button_reset_state()` / `reset_modules_state()` recovery; when a restore is the only path.
- [playbooks/safe-data-fix.md](playbooks/safe-data-fix.md) — using `odoo shell` with `env.cr.commit()` for safe ORM-level data fixes; accounting-table guardrails.
- [scripts/backup.sh](scripts/backup.sh) — runs inside the Odoo container, piped there over SSH (`sudo bash -s -- <db>`): `odoo db dump` with `ODOO_RC`, then checks the ZIP holds `dump.sql`, `manifest.json` and the filestore.
- [scripts/restore.sh](scripts/restore.sh) — runs here in the agent container and SSHes to Odoo itself; wraps `odoo-bin db load -n`; guards against overwriting a prod-named DB.
- [scripts/check-hash-integrity.sh](scripts/check-hash-integrity.sh) — runs here in the agent container; pipes `env['res.company']._check_hash_integrity()` through `odoo shell`.
- [learnings.md](learnings.md) — living scratchpad for Odoo-specific facts captured during real sessions that don't yet justify their own file.

## Maintaining this skill

This skill is a living document. When you finish a task and you have learned something Odoo-specific that future sessions will benefit from, capture it before ending the task — otherwise it is lost.

### What qualifies as worth persisting

- A non-obvious behaviour that surprised you and could bite the next session.
- A version-specific fact about Odoo 19.0 that upstream docs do not surface clearly.
- An environment quirk of the Clouve packaging — compose vs. Kubernetes differences, the `clouve-ops` SSH channel, the PostgreSQL image.
- A workflow pattern the user has confirmed at least twice — the verified shape of a recurring request.
- A correction to anything elsewhere in this skill. Fix the original file *in place*, then drop a one-line stub in [learnings.md](learnings.md) so future sessions notice the change.

### What does NOT qualify

- Generic Python / PostgreSQL / Linux knowledge (training-data territory).
- Anything `/_clv/`-related — that namespace is the Clouve platform's responsibility, not this skill's.
- Anything that belongs in a global Claude Code skill or in the user's personal memory (not Odoo-specific).
- Per-session ephemera, secrets, or tenant-identifying data.

### Where each kind of learning belongs

| Kind of learning | File |
|---|---|
| Reference fact about Odoo proper | the relevant [reference/*.md](reference/), edited in place |
| New verified procedure | a new file under [playbooks/](playbooks/) |
| Audited automation | a new file under [scripts/](scripts/) plus a playbook entry that calls it |
| Cross-cutting / too small / speculative | [learnings.md](learnings.md) |
| Correction to anything above | fix in place + one-line stub in [learnings.md](learnings.md) |

### Edit rules

- **Incremental.** Append or revise one section at a time; never rewrite a whole reference file as part of a learning capture.
- **De-duplicated.** Grep the target file (and `learnings.md`) for the topic before adding a new entry. If a related entry exists, extend it.
- **Terse.** A learning entry is one paragraph. If it grows past ~10 lines, promote it to its own file under `reference/` or `playbooks/` and leave a one-line pointer in `learnings.md`.
- **Dated.** Every `learnings.md` entry carries an ISO-8601 date.
- **Pruned.** When a learning is now covered by a dedicated reference file, delete its `learnings.md` entry — git history retains the original capture.

### Runtime caveat

Inside the deployed Magneto Agent container the skill payload is staged by the marketplace loader at `/clouve/skills/odoo/plugin/skills/odoo/` (with a login-time symlink at `~/.claude/skills/odoo`), and `/clouve/` is **not** in the container's persistent path set (`/usr`, `/var`, `/opt`, `/home`). Edits made at runtime survive the rest of the session but are wiped on the next pod restart, and they do not propagate back to the magneto-skills source repo. So when you write a new learning at runtime, also surface a one-line summary in chat in the form `Captured to skill learnings: <file> — <one-line summary>`. That visible echo is the only mechanism by which a runtime learning becomes durable — the operator can copy it into the magneto-skills repo and the next image rebuild bakes it in for every tenant.

## Safety gates (enforce these in every flow)

The gates are the reason this skill exists. If any of these are skipped, assume the user is at risk.

| Action | Gate |
|---|---|
| Any multi-row `UPDATE`/`DELETE` on Odoo tables | `SELECT COUNT(*)` first + user ack |
| Schema change / module upgrade / uninstall | Filestore-aware backup ([playbooks/backup.md](playbooks/backup.md)) + user ack |
| Edit `odoo.conf` | Show diff + user ack; prefer env-var-driven configuration |
| Install a third-party addon | Read `__manifest__.py` + top-level Python; confirm trusted source; user ack |
| Drop or restore a database (`odoo-bin db drop` / `odoo-bin db load`) | Full backup (dump + filestore) + user ack |
| Any write to `account_move*` | Refuse; route through reversal/credit note instead |
| Change `admin_passwd` or `list_db` | Confirm new value + verify ingress blocks `/web/database/`; user ack |
| `odoo shell` data fix | Show the exact `env.cr.commit()` call + affected record count; user ack before commit |
| Restore a prod DB to a non-prod environment | Neutralize immediately after restore (`sudo odoo neutralize -c /etc/odoo/odoo.conf -d <db>`); no exceptions |

"User ack" means: print the exact command you are about to run and wait for the user to reply affirmatively before executing. Do not infer consent from an earlier "go ahead."
