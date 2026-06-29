# Shell Access

## clouve-ops SSH channel

Both the Odoo container and the Postgres container expose an SSH server accepting the `clouve-ops` user. The password is the per-pod secret in `$CLOUVE_OPS_PASSWORD` (already in the agent environment).

```bash
# Connect to Odoo container (odoo-bin, filestore, conf, addons)
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST}

# Connect to PostgreSQL container (OS-level postgres ops)
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_DB_HOST}
```

On first connection, accept the host key (`StrictHostKeyChecking accept-new` or answer `yes`). Subsequent connections reuse the known-hosts entry.

`clouve-ops` has **passwordless sudo** on both containers.

### SSH vs TCP psql — when to use which

| Task | Channel |
|---|---|
| Run `odoo-bin`, read/edit `odoo.conf`, inspect filestore, restart service | SSH → Odoo container |
| Postgres OS ops: `pg_dump`, `pg_restore`, `psql` without TCP auth | SSH → Postgres container, then `sudo -u postgres psql` |
| ORM-driven data fixes, module inspection, scripted record updates | `odoo shell` (see below) — avoids raw SQL pitfalls |
| Simple `SELECT` or schema inspection from agent environment | TCP `psql -h ${ODOO_DB_HOST} -U odoo -d <db>` (password in `$ODOO_DB_PASSWORD`) |

## `odoo shell`

`odoo shell -d <dbname>` (`odoo/cli/shell.py`) starts an interactive Python REPL with the ORM fully loaded.

### Environment

```python
# Pre-defined names when -d is given
env   # api.Environment(cr, SUPERUSER_ID, ctx) — full superuser access, no record rules
self  # env.user  (the SUPERUSER user record)
odoo  # the odoo module itself
```

`uid = api.SUPERUSER_ID` — all access control and record rules are bypassed. Use this for data fixes, not routine inspection.

### Transaction safety (`cli/shell.py`, lines 147–149)

The shell opens a cursor and calls `cr.rollback()` **before** and **after** `console()`:

```python
cr.rollback()       # before: clear any state from context_get()
self.console(local_vars)
cr.rollback()       # after: roll back anything the session left uncommitted
```

This means: **writes made in the shell are rolled back unless you commit explicitly.**

```python
# Pattern for a durable write
partner = env['res.partner'].search([('email', '=', 'old@example.com')], limit=1)
partner.email = 'new@example.com'
env.cr.commit()     # required — without this, the change is lost on exit
```

Do not call `env.cr.commit()` after every statement during exploratory sessions; commit only when the change is intentional and verified.

### Single database only

If `db_name` in the config contains more than one database, `odoo shell` exits with an error. Pass exactly one: `odoo shell -d mydb`.

### Preferred REPL

If `ipython`, `ptpython`, or `bpython` is installed, the shell picks the first available (in that order). Force a specific one with `--shell-interface python` (or `ipython`, etc.). Tab completion is available in the plain Python REPL via `readline`.

### Use cases

- ORM-driven data fixes instead of raw SQL (safer: respects computed fields, onchange logic is not triggered but constraints run on save)
- Inspecting model fields: `env['account.move'].fields_get().keys()`
- Running a one-off script non-interactively: `odoo shell -d mydb < fix.py`
