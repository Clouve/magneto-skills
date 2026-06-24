# Playbook: Safe Data Fix

Use when the tenant needs to correct business data in Odoo — wrong partner email, duplicate record, posted invoice that needs reversing, etc.

This playbook enforces the core constraint: **use `odoo shell` with `env.cr.commit()` for ORM writes; never use raw SQL for accounting or ORM-managed tables.**

See [reference/accounting-integrity.md](../reference/accounting-integrity.md) and [reference/shell-access.md](../reference/shell-access.md) for the source-code basis.

## Preconditions

- [ ] You have a recent backup. Take one if not: see [playbooks/backup.md](backup.md).
- [ ] You have confirmed which records need changing and have the exact IDs or search criteria.
- [ ] You understand whether the affected records are `account_move` (posted entries) — those require the reversal path, not direct edits.

## Shell setup

All ORM-driven fixes run via `odoo shell -d <db>`:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http"
```

The shell opens with `env` (full superuser Environment), `self` (superuser user record), and `odoo` (the odoo module). All access control and record rules are bypassed. **This is a superuser REPL — scope your changes carefully.**

**Critical:** the shell rolls back all uncommitted writes on exit. **Every intentional write requires an explicit `env.cr.commit()`.**

```python
# Pattern for a safe, durable write:
record = env['res.partner'].search([('email', '=', 'wrong@example.com')], limit=1)
record.email = 'correct@example.com'
env.cr.commit()   # required — without this, the change is rolled back on exit
```

Do not call `env.cr.commit()` speculatively during exploratory queries — only commit when the change is intentional and you have verified the record set.

## Non-accounting data fixes

### Correct a field value on a standard record

```python
# Example: fix a partner's email
partner = env['res.partner'].browse(42)
print(partner.name, partner.email)   # verify before writing
partner.email = 'new@example.com'
env.cr.commit()
print('Done:', partner.email)
```

### Fix a record via search

```python
# Example: deactivate duplicate partners with wrong domain
dupes = env['res.partner'].search([('email', 'like', '@olddomain.com'), ('customer_rank', '=', 0)])
print(dupes.mapped('name'))   # review the set before committing
dupes.write({'active': False})
env.cr.commit()
```

### Run a fix from a script file (non-interactively)

```bash
# Write the fix script locally first, then pipe it in:
cat fix.py | SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http"
```

## Accounting data — posted journal entries

**NEVER use raw SQL to modify `account_move`, `account_move_line`, or related tables.** There are no database triggers protecting these tables — raw SQL bypasses the ORM's integrity checks, hash chains, lock dates, and sequence constraints entirely. One raw `UPDATE` on a hashed entry permanently corrupts the journal's hash chain with no repair path. See [reference/accounting-integrity.md](../reference/accounting-integrity.md#what-one-raw-sql-edit-actually-breaks).

### Reverse a posted entry (preferred method)

The correct undo for any posted `account.move` is a reversal, which creates a sign-flipped entry and links it to the original:

```python
# In odoo shell:
move = env['account.move'].browse(123)
print(move.name, move.state, move.amount_total)   # confirm before reversing
move._reverse_moves()
env.cr.commit()
```

Or trigger via the UI: open the journal entry and click the "Reverse" button (`action_reverse()`).

### Cancel a draft or cancellable entry

If the entry has not been hashed and the date is not locked:

```python
move = env['account.move'].browse(123)
move.button_cancel()
env.cr.commit()
```

`button_cancel()` is only available when the entry can safely be cancelled (not hashed, date not inside a lock date). The ORM enforces this — it will raise a `UserError` if the entry cannot be cancelled.

### Check lock dates before any accounting fix

```python
company = env['res.company'].browse(1)
print('fiscalyear_lock_date:', company.fiscalyear_lock_date)
print('tax_lock_date:', company.tax_lock_date)
print('hard_lock_date:', company.hard_lock_date)
```

`hard_lock_date` is **irreversible** — once set, it can only move forward and can never be cleared. Do not attempt to set it back even via raw SQL; doing so also invalidates the hash chain for entries in the "unlocked" period.

## Tables that must NEVER be modified by raw SQL

| Table | Reason |
|---|---|
| `account_move` | Hash chain, sequence, lock dates — ORM-only |
| `account_move_line` | Hash chain fields, gapless sequence — ORM-only |
| `ir_model_data` | External ID registry — ORM-only (removing an xmlid orphans all references) |
| `ir_sequence` | Sequence counters — ORM-only (gaps are a compliance violation in many jurisdictions) |
| `ir_config_parameter` (accounting keys) | `hard_lock_date`, `base.partially_updated_database`, hash-related parameters — ORM-only |
| `ir_module_module.state` | Module state machine — use `button_reset_state()` or `reset_modules_state()` only |

For accounting tables: use `_reverse_moves()` or `button_cancel()` instead of any SQL. For `ir_model_data`: use `env['ir.model.data'].search(...).unlink()` if a record truly needs removing, and confirm with the tenant. For sequences: never touch `ir_sequence` rows directly.

## Verification after a fix

After committing, verify the change took effect:

```python
# Re-fetch the record (bypasses any cached state):
record = env['<model>'].browse(<id>)
env.cr.execute('SELECT <field> FROM <table> WHERE id = %s', (<id>,))
print(env.cr.fetchone())   # confirms the DB row
```

For accounting entries after a reversal:

```python
# Check hash integrity:
env['res.company'].browse(1)._check_hash_integrity()
```

## Do NOT

- `UPDATE account_move SET ...` — permanently corrupts the hash chain.
- `UPDATE account_move_line SET ...` — same.
- `DELETE FROM account_move WHERE ...` — forbidden; use reversal instead.
- `UPDATE ir_module_module SET state = ...` — use `button_reset_state()` instead (see [playbooks/recover-stuck-module-state.md](recover-stuck-module-state.md)).
- Call `env.cr.commit()` after every exploratory query — only commit intentional writes.
- Attempt to lower `hard_lock_date` — it is ORM-enforced as one-way only, and attempting it via raw SQL also breaks the hash chain.
