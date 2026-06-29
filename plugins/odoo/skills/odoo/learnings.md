# Odoo DevOps — Session Learnings

This file is the catch-all for facts about *this* Odoo install (the Clouve `apps/odoo` package) that emerge from real sessions and are too small, too cross-cutting, or too speculative to live in a dedicated [reference/](reference/) or [playbooks/](playbooks/) file. It is part of the skill — Claude Code reads it whenever the Odoo DevOps skill is loaded.

The protocol that drives appends here is in [SKILL.md](SKILL.md) under "Maintaining this skill". The summary below is just the format guide.

## What goes here

Append an entry when you discover any of the following:

- **Non-obvious behaviour** that surprised you and could bite the next session if it surprised you again.
- **Version-specific facts** about Odoo 19.0 that upstream docs do not surface clearly.
- **Environment quirks** of the Clouve packaging — Docker Compose vs. Kubernetes differences, entrypoint `odoo.conf` templating, the `clouve-ops` SSH channel, filestore volume layout.
- **Workflow patterns** the user has confirmed at least twice — the verified shape of a recurring response.
- **Corrections** to anything elsewhere in the skill — fix the original file *in place*, then drop a one-line stub here pointing at the change so future sessions notice the update.

## What does NOT go here

- Generic Python / PostgreSQL / Linux knowledge — training-data territory, not skill content.
- Anything tied to a `/_clv/` path — that namespace is the Clouve platform's, not Odoo's.
- Anything that belongs in a global Claude Code skill (e.g., "how to use grep", "how memory works") — not Odoo-specific.
- Per-session ephemera — what you tried and rolled back, the contents of one bug report, the user's preferred name for their database. That belongs in conversation context or the memory system, not here.
- Secrets. Ever. (Including the literal value of `${CLOUVE_OPS_PASSWORD}`, the tenant's `ANTHROPIC_API_KEY`, or any DB password.)

## Entry format

Use one fenced section per entry, in the shape below. Keep it terse — one paragraph, max ~10 lines. If an entry needs more, promote it to its own file under `reference/` or `playbooks/` and replace the entry here with a one-line pointer.

```
### YYYY-MM-DD — short title (≤ 60 chars)

**Category:** gotcha | version-note | env-quirk | workflow-pattern | correction
**Origin:** one-sentence trigger (what task surfaced this).

Body — the fact itself. If it overrules something elsewhere in the skill,
link to that file with a relative path. If a future reader could re-derive
this from the code in two minutes, it does not belong here.
```

## Edit rules

1. **Prefer the right file over this one.** Reference facts go in `reference/*.md`. New verified procedures go in `playbooks/*.md`. New audited automation goes under `scripts/`. Use `learnings.md` only when the fact is too small, too cross-cutting, or too speculative for a permanent home.
2. **De-duplicate before appending.** Grep this file for the topic first. If a related entry exists, extend it; do not create a parallel entry.
3. **Keep entries terse and dated.** ISO-8601 (`YYYY-MM-DD`), one paragraph.
4. **Promote entries that grow.** If an entry crosses ~10 lines or earns repeated reference, move it to its own file under `reference/` or `playbooks/` and leave a one-line pointer here.
5. **Drop superseded entries.** Once a learning is reflected in a dedicated reference file, delete the entry here — git history retains the original capture.

## Entries

### 2026-06-24 — filestore is per-DB; pg_dump alone loses all attachments

**Category:** gotcha
**Origin:** Authoring the backup playbook and file-storage reference.

The Odoo filestore lives at `/var/lib/odoo/filestore/<dbname>/` — a **per-database** directory. A `pg_dump` alone is an incomplete backup: it misses the filestore. On restore, missing filestore files return empty bytes (`b''`) with no exception raised and no UI error — the database loads and appears healthy while silently serving blank for every attachment. Always use `odoo db dump` (ZIP format) or `scripts/backup.sh`, which captures `dump.sql` + `filestore/` + `manifest.json` atomically. See [reference/file-storage.md](reference/file-storage.md) and [playbooks/backup.md](playbooks/backup.md).

---

### 2026-06-24 — `odoo shell` rolls back writes unless you call `env.cr.commit()`

**Category:** gotcha
**Origin:** Authoring the safe-data-fix playbook.

`odoo shell` calls `cr.rollback()` both before and after the REPL session (`cli/shell.py:147-149`). Any write made in the shell — ORM field assignment, `.write()`, `.create()`, `.unlink()` — is silently rolled back on exit unless you explicitly call `env.cr.commit()` inside the session. This is intentional safety behaviour, but it means a "successful" shell session may have committed nothing. Always verify with a re-read or a SELECT after committing. See [reference/shell-access.md](reference/shell-access.md#transaction-safety).

---

### 2026-06-24 — `list_db=False` requires a pinned `db_name` or the login page breaks

**Category:** gotcha
**Origin:** Authoring the harden-db-manager playbook.

Setting `list_db = False` in `odoo.conf` kills the database selector. Without a pinned `db_name` (or `dbfilter`), the Odoo login page cannot determine which database to connect to and breaks. Always set both together: `list_db = False` + `db_name = mydb`. A GET to `/web/database/manager` returning HTTP 200 is NOT proof the kill-switch is active — verify by POSTing to `/web/database/backup` and confirming AccessDenied. See [reference/security.md](reference/security.md#list_dbfalse--the-real-kill-switch) and [playbooks/harden-db-manager.md](playbooks/harden-db-manager.md).

---

### 2026-06-24 — `admin_passwd` default-`'admin'` auto-change footgun

**Category:** gotcha
**Origin:** Authoring the harden-db-manager playbook.

When `admin_passwd` is still `'admin'` (the compiled-in default), the first POST body that supplies any non-empty `master_pwd` to any mutating DB manager route **silently replaces it** with no confirmation step (`service/db.py:change_admin_password` is called before the action proceeds). An attacker who reaches `/web/database/create` before the operator sets a real password can adopt any password they choose. Set `ODOO_MASTER_PASSWORD` to a strong random value before first boot. See [reference/security.md](reference/security.md#default-password-footgun).

---

### 2026-06-24 — `hard_lock_date` is one-way and cannot be lowered

**Category:** gotcha
**Origin:** Authoring the safe-data-fix playbook and accounting-integrity reference.

`hard_lock_date` on `res.company` can only move forward — it can never be cleared or set to a prior date. The ORM enforces this in `company.write()` (`company.py:559-566`). Attempting to bypass it via raw SQL is doubly dangerous: it also invalidates the hash chain for entries in the "unlocked" period, with no repair path. Before advising any accounting period adjustment, always check `hard_lock_date` first. See [reference/accounting-integrity.md](reference/accounting-integrity.md#lock-dates).

---

### 2026-06-24 — raw SQL on posted `account_move` permanently corrupts the hash chain

**Category:** gotcha
**Origin:** Authoring the accounting-integrity reference and safe-data-fix playbook.

There are no PostgreSQL triggers or constraints protecting `account_move` or `account_move_line`. Every integrity check is in Odoo's Python ORM. One raw `UPDATE account_move SET date = ...` on a hashed entry invalidates that entry's `inalterable_hash`, which cascades to every later entry in the same journal prefix — their hashes become wrong because they chain to the modified entry. **There is no recalculation path.** The only recovery is a restore from a pre-corruption backup. Always use `_reverse_moves()` or `button_cancel()` — never raw SQL. See [reference/accounting-integrity.md](reference/accounting-integrity.md) and [playbooks/safe-data-fix.md](playbooks/safe-data-fix.md).
