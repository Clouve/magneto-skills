# Neutralization

## What neutralization is

Neutralization is the process of making a copy of a production database safe to run in a
non-production environment. A non-neutralized prod clone will send real emails to real
customers, fire real payment transactions, trigger real webhooks, and run automated jobs
against live external systems.

**Neutralization is mandatory for any prod→staging clone before use.**

## How to neutralize

```bash
# Neutralize in place (modifies the DB):
odoo-bin neutralize -d <dbname>

# Preview the SQL without applying it (audit / dry-run):
odoo-bin neutralize -d <dbname> --stdout
```

The `--stdout` flag prints the complete SQL wrapped in `BEGIN;` ... `COMMIT;`
to stdout without executing it. Use this to review what will change before running it.

Source: `odoo/cli/neutralize.py`, `Neutralize.run()`.

## How neutralization works

`neutralize_database(cursor)` (`odoo/modules/neutralize.py:36-41`):

1. Queries `ir_module_module` for all installed (or to-upgrade, to-remove) modules.
2. For each module, looks for `<module>/data/neutralize.sql`.
3. Executes each file's SQL in sequence via `cursor.execute()`.

The per-module SQL files are the actual source of truth. Any module that ships
`data/neutralize.sql` contributes to neutralization. There is no central list — the
set of neutralization actions depends on which modules are installed.

## What base neutralization does

`odoo/addons/base/data/neutralize.sql`:

```sql
-- 1. Deactivate all mail servers
UPDATE ir_mail_server SET active = false;

-- 2. Insert a dummy SMTP server to prevent command-line fallback
INSERT INTO ir_mail_server(name, smtp_port, smtp_host, smtp_encryption, active, smtp_authentication)
VALUES ('neutralization - disable emails', 1025, 'invalid', 'none', true, 'login');

-- 3. Deactivate all crons except base.autovacuum_job
UPDATE ir_cron SET active = false
WHERE id NOT IN (
    SELECT res_id FROM ir_model_data
    WHERE model = 'ir.cron' AND name = 'autovacuum_job' AND module = 'base'
);

-- 4. Set the neutralization flag
INSERT INTO ir_config_parameter (key, value)
VALUES ('database.is_neutralized', true)
ON CONFLICT (key) DO UPDATE SET value = true;

-- 5. Disable webhook server actions
UPDATE ir_act_server SET webhook_url = 'neutralization - disable webhook'
WHERE state = 'webhook';
```

The dummy SMTP entry uses host `'invalid'` with port 1025 and `active = true`. Any
attempt to send mail via the ORM will hit this server and fail at the SMTP connection
level, rather than silently using a command-line-specified fallback.

## Cron re-enable is blocked on a neutralized DB

`ir.cron.toggle()` (`odoo/addons/base/models/ir_cron.py:722-733`) checks:

```python
if self.env['ir.config_parameter'].sudo().get_param('database.is_neutralized'):
    return True
```

When `database.is_neutralized` is set, `toggle()` silently returns `True` without
reactivating the cron. This prevents any module install or system event from
accidentally re-enabling crons on a neutralized DB through side effects.

## Additional module-level neutralization

Several modules ship their own `data/neutralize.sql`:

- **`mail`** — additional mail/messaging neutralization.
- **`payment`** — payment providers neutralized (prevents real charges).
- **`iap`** — in-app purchase services disabled.
- **`auth_oauth`** — OAuth provider credentials cleared.
- **`account_edi_proxy_client`** (`l10n_edi`)— EDI proxy disabled.
- **`account_peppol`** — Peppol integration disabled.
- Various delivery and localization modules ship their own.

The exact set depends on what is installed. Use `--stdout` to see the complete SQL
before applying it.

## Built-in neutralization during restore/duplicate

`db load -n` and `db duplicate -n` call `neutralize_database()` immediately after
restoring or duplicating, inside the same transaction. This is the recommended path
for a prod→staging clone: restore + neutralize atomically.

```bash
# Clone prod to staging and neutralize in one step:
odoo-bin db -c /etc/odoo/odoo.conf load -n staging-db /tmp/prod-backup.zip
```

## Verify neutralization applied

```python
# From odoo shell:
env['ir.config_parameter'].sudo().get_param('database.is_neutralized')
# Should return 'true'

# Check that no mail servers are active (other than the dummy):
env['ir.mail.server'].search([('active', '=', True)]).mapped('name')
# Should return ['neutralization - disable emails']

# Check no crons are active except autovacuum:
env['ir.cron'].search([('active', '=', True)]).mapped('name')
# Should return only the base autovacuum job name
```

## What neutralization does NOT do

- Does not change application data (invoices, products, contacts, etc.).
- Does not remove the database secret or UUID.
- Does not reset user passwords.
- Does not disable user accounts or change access rights.
- Does not remove API keys stored in `ir.config_parameter`.

If staging needs to be accessible only to internal users, additionally:
- Reset user passwords via the ORM or UI.
- Remove or rotate any API keys that could trigger external side effects.
