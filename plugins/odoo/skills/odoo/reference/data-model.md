# Data Model

Odoo 19.0. Authored against `odoo/addons/base/models/{ir_model,ir_config_parameter,ir_module,ir_cron,res_users}.py`.

This file is the authoritative **never-touch / handle-with-care** split for a DevOps agent operating on Odoo without human review of every SQL statement.

---

## NEVER TOUCH via raw SQL

All integrity in Odoo is ORM- and Python-enforced. There are **no DB triggers**. Raw SQL bypasses every protection silently and irreparably.

### `ir_model_data` — XML-ID backbone
The `ir.model.data` table maps every external ID (`module.name`) to a `(model, res_id)` pair. It is ormcached (`_xmlid_lookup` is decorated `@ormcache`; raising `ValueError('External ID not found in the system: %s' % xmlid)` on miss). The `noupdate` flag protects a record from being overwritten on upgrade. During every module upgrade, `_process_end()` runs: it queries `ir_model_data` for records whose xmlid is no longer in `pool.loaded_xmlids` and `noupdate=False`, then **deletes those records**. Editing or deleting rows in this table by hand orphans external IDs, breaks every `env.ref()` call, and corrupts future upgrades. (`ir_model.py:2273–2283, 2633–2705`)

### `ir_model` / `ir_model_fields`
The ORM delete path for `ir.model` and `ir.model.fields` calls `DROP TABLE/COLUMN CASCADE` in Python. Raw SQL `DELETE` from these tables skips the cascade — the physical table stays, but Odoo's registry thinks the model is gone, causing startup failures. (`ir_model.py:2454–2626`)

### `ir_module_module.state`
The `state` column drives the entire module install/upgrade/uninstall lifecycle. The registry loads **only** modules with `state='installed'`. Editing state by hand — even to fix a stuck operation — is unsupported and leaves the DB in an inconsistent state. See the recovery path below and `playbooks/recover-stuck-module-state.md`.

Allowed states (`ir_module.py:142–146`):
```
uninstallable → Uninstallable (default; dependencies unmet or not on addons_path)
uninstalled  → Not Installed
installed    → Installed
to install   → To be installed
to upgrade   → To be upgraded
to remove    → To be removed
```

### `ir_config_parameter` — protected keys
These keys are set at DB creation (`_default_parameters`, `ir_config_parameter.py:18–25`) and are guarded by ORM-level `ValidationError` on rename or delete (`ir_config_parameter.py:110–125`). Their values must not be changed by raw SQL:

| Key | What breaks if changed |
|-----|------------------------|
| `database.secret` | Signs HMAC/CSRF tokens; rotating it **invalidates every active session** and logs out all users |
| `database.uuid` | Immutable DB identity; used by Odoo Enterprise licensing and telemetry |
| `database.create_date` | Auditing baseline; should never change |
| `web.base.url` | Auto-rewrites to the requesting host on the next system-user login **unless** `web.base.url.freeze` is set (`res_users.py:803–810`); hand-editing is immediately overwritten |
| `base.login_cooldown_after` | Number of failed logins before cooldown (default 10) |
| `base.login_cooldown_duration` | Cooldown length in seconds (default 60) |

### `ir_sequence` + reconciliation tables
Sequences enforce gapless numbering (invoices, payments). Raw edits create gaps that break legal audit trails. Accounting reconciliation tables tie together journal items — editing them outside the ORM breaks the reconciliation hash chain.

### `account_move` / `account_move_line`
Posted accounting entries carry a SHA-256 hash chain and a gapless sequence. **See `reference/accounting-integrity.md`.** Never edit or delete posted entries by SQL.

### The filestore
Binary attachments live on disk at `<data_dir>/filestore/<dbname>` (content-addressed; see `reference/file-storage.md`). The database holds only the path. Deleting or renaming files outside the GC process silently loses data — missing files return empty `b''` with no error. **Never touch the filestore directly.**

---

## `ir.cron` — cron behaviour under version mismatch or module trouble

`ir.cron` skips an entire database if its `base` module version does not match the running code version (`_check_version`, `ir_cron.py:241–252`). It also checks module states and skips databases with modules stuck in transitional states (`_check_modules_state`, `ir_cron.py:198`).

A cron job is **deactivated** only when **both** thresholds are met (`ir_cron.py:36–38, 588–603`):
- `failure_count >= MIN_FAILURE_COUNT_BEFORE_DEACTIVATION` (= **5**)
- `first_failure_date + MIN_DELTA_BEFORE_DEACTIVATION < now` (= **7 days**)

Both conditions must be true simultaneously. A job that fails 5 times in one hour will not be deactivated until the 7-day window has also elapsed.

---

## Recovery: stuck `to install` / `to upgrade` / `to remove`

When a module operation is interrupted, `ir_config_parameter` gains `base.partially_updated_database=1` (`loading.py:601–608`) and `ir_cron` skips the database.

**Recovery path (never hand-edit `state`):**
- Via UI: Settings → Technical → Modules → call `button_reset_state()` (`ir_module.py:496–500`)
- Via Python: `odoo.modules.loading.reset_modules_state('<db_name>')` (`loading.py:611–632`)

`reset_modules_state` uses raw SQL internally (`state='to remove'/'to upgrade'` → `'installed'`; `state='to install'` → `'uninstalled'`) — this is the one sanctioned exception, implemented in the loader, not by a human typing SQL.

See `playbooks/recover-stuck-module-state.md` for the step-by-step.

---

## Key schema facts

- **All model integrity is Python/ORM-enforced — no DB triggers.** A raw `DELETE` or `UPDATE` that would be caught by the ORM passes through PostgreSQL silently.
- **`ir.config_parameter` is ormcached** (`_get_param` decorated `@ormcache('key', cache='stable')`). Raw SQL `UPDATE` of a cached key is not seen until the cache is invalidated (server restart or `env.registry.clear_cache('stable')`).
- **Registry loads only `installed` modules.** A module whose `state` is anything else (including `to upgrade`) is not loaded on startup.
- **`noupdate=True` protects records across upgrades.** If a record's xmlid has `noupdate=True`, `_process_end` will not delete it even if the xmlid is absent from the updated data. This is set by the data file; toggling it by SQL is unsupported.
