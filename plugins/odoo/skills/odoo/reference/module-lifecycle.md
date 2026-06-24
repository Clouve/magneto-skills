# Module Lifecycle

Odoo 19.0. Authored against `odoo/cli/module.py`, `odoo/modules/{loading,migration}.py`, `odoo/orm/registry.py`, `odoo/addons/base/models/ir_module.py`.

---

## Install, upgrade, and uninstall — the two interfaces

### Classic flags (require `--stop-after-init` for one-shot use)

```bash
# Install
odoo-bin -d <dbname> -i <module>[,<module>,...] --stop-after-init

# Upgrade (single module or everything)
odoo-bin -d <dbname> -u <module>[,<module>,...] --stop-after-init
odoo-bin -d <dbname> -u all --stop-after-init
```

Both `-i` and `-u` **require `-d`** (database name). They are CLI-only operations that mutate the database. Without `--stop-after-init` the Odoo server continues running after the operation; use `--stop-after-init` for scripted/one-shot invocations. (`config.py:227–232, 431–432`)

### Dedicated `module` subcommand (preferred for scripted use)

Source: `odoo/cli/module.py` — registered as the `module` subcommand with four sub-subcommands.

```bash
odoo-bin module install    -d <dbname> <module> [<module>...]
odoo-bin module upgrade    -d <dbname> <module>|all [--outdated]
odoo-bin module uninstall  -d <dbname> <module> [<module>...]
odoo-bin module force-demo -d <dbname>          # installs demo data (development only)
```

The subcommand always passes `--no-http` internally (`module.py`: `config_args = ['--no-http']`), so no HTTP server is started. It also enforces a **single database** — the parser errors out if more than one DB name is resolved from the config (`module.py`: `if not db_names or len(db_names) > 1: self.parser.error(...)`).

`upgrade` accepts `all` (upgrades every installed module) and `--outdated` (only upgrades modules where the on-disk version is newer than the installed version).

---

## What happens during install/upgrade

1. **Registry rebuild.** `Registry.new()` loads the module graph, computes dependencies, and initialises the Python ORM for all `installed` modules.
2. **Migration scripts.** `MigrationManager` runs scripts from `migrations/<version>/` in three phases (`migration.py:149`):
   - `pre-*.py` — before the module is loaded/updated
   - `post-*.py` — after the module is loaded
   - `end-*.py` — after **all** modules in the batch have been loaded (`loading.py:497–501`)
3. **XML/CSV data loading.** Data files are re-processed; `ir_model_data._process_end()` removes records whose xmlid has vanished (unless `noupdate=True`).
4. **`partially_updated_database` flag.** At the start of any update pass, `ir_config_parameter` gets `base.partially_updated_database=1` if any module is in a transitional state (`loading.py:600–608`). This causes `ir.cron` to skip the database until the flag is cleared.

Only **one module operation can run at a time** on a given database. The `module` subcommand uses `Registry.new()` which takes an exclusive lock on the registry, and the ORM-level operations themselves acquire PostgreSQL row locks on `ir_module_module`.

---

## Uninstall is irreversible

**The only undo for an uninstall is a restore from backup.**

`module_uninstall()` calls `ir.model.data._module_data_uninstall()`, which:
- Drops every table and column that was created by the module (`DROP TABLE ... CASCADE`, `DROP COLUMN ... CASCADE`) — `ir_model.py:2454–2626`.
- Cascades to any dependent modules that rely on those tables/columns.
- Deletes all `ir.model.data` records for the module (removing all external IDs).
- Sets `state='uninstalled'` and clears `latest_version`.

(`ir_module.py:507–516`)

There is no rollback, no recycle bin, and no "dry run" option. If a dependent module is affected, it is also uninstalled transitively. Verify dependencies with `module.upstream_dependencies()` before proceeding.

---

## Stuck states: recovery

When a module operation is interrupted (crash, kill, timeout), modules can be left in `to install`, `to upgrade`, or `to remove`. The database is then flagged with `base.partially_updated_database=1` and `ir.cron` stops running all jobs for that database.

**Never hand-edit `ir_module_module.state`.**

Recovery options:

**Option 1 — UI** (Settings → Technical → Modules → Reset Module State):
```python
env['ir.module.module'].button_reset_state()
# ir_module.py:496–500
# Sets 'to install' → 'uninstalled', 'to upgrade'/'to remove' → 'installed'
```

**Option 2 — Python/CLI**:
```python
from odoo.modules.loading import reset_modules_state
reset_modules_state('<dbname>')
# loading.py:611–632
```

`reset_modules_state` is the one sanctioned case of raw SQL state updates, implemented in the loader and called only after a confirmed failed operation.

See `playbooks/recover-stuck-module-state.md` for the full step-by-step, including clearing the `base.partially_updated_database` parameter.

---

## `upgrade_code` — source rewriting, not a DB operation

`odoo-bin upgrade_code` (`odoo/cli/upgrade_code.py`) rewrites **source files on disk** in place using scripts from `/odoo/upgrade_code/`. It is a code-migration helper for moving an addon from one Odoo major version to another. It does **not** touch the database, does not install or upgrade modules, and is completely unrelated to `-u`. (`upgrade_code.py:1–30, 177`)

---

## Third-party addons — security posture

Third-party addons installed into `/mnt/extra-addons` (already on `addons_path`) run **arbitrary Python with full database access** at the ORM SUPERUSER level. There is no sandboxing.

Before installing any third-party addon:
1. Read `__manifest__.py` — check `depends`, `version`, and `license`.
2. Read every top-level Python file — look for raw SQL, subprocess calls, network access, and file writes.
3. Verify the source against a known-good tag or commit hash.

Never install an addon from an untrusted source onto a database that holds production data.

---

## State machine reference

```
uninstallable ──[resolve deps]──► uninstalled ──[install]──► to install ──[load]──► installed
                                  installed   ──[upgrade]──► to upgrade ──[load]──► installed
                                  installed   ──[uninstall]► to remove  ──[load]──► uninstalled (+ DROP TABLE CASCADE)
```

The registry only loads modules in state `installed`. Modules in `uninstallable` cannot be installed until dependencies are met or the module is placed on `addons_path`; it is the default state. Modules in any `to *` state are processed during the next `load_modules()` pass and then transition to `installed` or `uninstalled`. (`ir_module.py:142–146, 303`)
