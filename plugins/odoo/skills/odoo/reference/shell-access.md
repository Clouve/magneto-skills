# Shell Access

## clouve-ops SSH channel

Both the Odoo container and the Postgres container expose an SSH server accepting the `clouve-ops` user. The password is the per-pod secret `CLOUVE_OPS_PASSWORD`. It isn't in your environment on current agents, so a command fetches it with `${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}`.

```bash
# Connect to Odoo container (odoo-bin, filestore, conf, addons)
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST}

# Connect to PostgreSQL container (OS-level postgres ops)
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_DB_HOST}
```

Pass `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null` on every connection, as every command in this skill does. Odoo images built from 2026-11-02 on hold no SSH host keys: each container makes new ones when its `sshd` starts, so a key saved from an earlier start is wrong, and ssh refuses it ("REMOTE HOST IDENTIFICATION HAS CHANGED"). The two options take the key the container shows and save nothing.

Newer agents' own SSH settings keep no key for the app's containers either. Older agents have no such settings, so there a command without the options fails: `sshpass` can't answer the yes/no prompt for a key it doesn't know, and exits 6 without printing anything. With the options, an older agent's ssh also prints "Permanently added ... to the list of known hosts" on every call. That list is `/dev/null`, so nothing is kept.

`clouve-ops` has **passwordless sudo** on both containers.

### SSH vs TCP psql — when to use which

| Task | Channel |
|---|---|
| Run `odoo-bin`, read/edit `odoo.conf`, inspect filestore, restart service | SSH → Odoo container |
| Postgres OS ops: `pg_dump`, `pg_restore`, `psql` without TCP auth | SSH → Postgres container, then `sudo -u postgres psql -U ${ODOO_DB_USER}` (the superuser role is `${ODOO_DB_USER}`; there is no `postgres` role) |
| ORM-driven data fixes, module inspection, scripted record updates | `odoo shell` (see below) — avoids raw SQL pitfalls |
| Simple `SELECT` or schema inspection from agent environment | TCP `psql -h ${ODOO_DB_HOST} -U odoo -d <db>` (password in `ODOO_DB_PASSWORD`) |

## `odoo shell`

`odoo shell -d <dbname>` (`odoo/cli/shell.py`) starts an interactive Python REPL with the ORM fully loaded. Over the clouve-ops channel, run `sudo odoo shell -c /etc/odoo/odoo.conf -d <dbname>`: `sudo` drops the `ODOO_RC` the image sets, and with no config the shell looks for PostgreSQL on a local socket and fails.

### Environment

Pre-defined names when `-d` is given:

- `env`: `api.Environment(cr, SUPERUSER_ID, ctx)`, full superuser access, no record rules
- `self`: `env.user` (the SUPERUSER user record)
- `odoo`: the odoo module itself

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

If `db_name` in the config contains more than one database, `odoo shell` exits with an error. Pass exactly one: `odoo shell -c /etc/odoo/odoo.conf -d mydb`.

### Preferred REPL

If `ipython`, `ptpython`, or `bpython` is installed, the shell picks the first available (in that order). Force a specific one with `--shell-interface python` (or `ipython`, etc.). Tab completion is available in the plain Python REPL via `readline`.

### Use cases

- ORM-driven data fixes instead of raw SQL (safer: respects computed fields, onchange logic is not triggered but constraints run on save)
- Inspecting model fields: `env['account.move'].fields_get().keys()`
- Running a one-off script non-interactively: `odoo shell -c /etc/odoo/odoo.conf -d mydb --no-http < fix.py`
