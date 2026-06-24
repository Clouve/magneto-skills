# Accounting Integrity — The Never-Touch Rule

This is the most safety-critical constraint in the Odoo skill. A single raw SQL edit to
accounting data can corrupt an entire journal's hash chain with no repair path.

## Core tables

- **`account_move`** — journal entry header (invoice, bill, payment, manual entry).
- **`account_move_line`** — individual debit/credit lines within an entry.

## State machine

```
draft → posted → cancel
```

- `draft`: editable.
- `posted`: posted to the ledger, immutable via the ORM. The entry has a sequence number
  and may have a hash.
- `cancel`: cancelled (usually via reversal). A cancelled entry is not deleted; it remains
  in the ledger as an audit record.

## Integrity is pure Python ORM — no database triggers

**There are no PostgreSQL triggers, constraints, or rules protecting `account_move` or
`account_move_line`.** Every integrity check lives in Odoo's Python ORM:
`write()`, `unlink()`, and `_post()` in `addons/account/models/account_move.py`.

**Consequence: any raw SQL `UPDATE`, `DELETE`, or `INSERT` on these tables bypasses all
integrity enforcement entirely.** The ORM's `write()` won't see it. The hash chain won't
be recalculated. The sequence won't be checked. The lock date won't be respected.

This is not a theoretical risk. One raw `UPDATE account_move SET date = ...` on a hashed
entry invalidates that entry's hash, which cascades: every later entry in the same journal
prefix that was chained to it will also fail the integrity check. **There is no repair
path.** The chain is broken permanently.

## SHA-256 hash chain (optional per journal, but irreversible once enabled)

Controlled by `account.journal.restrict_mode_hash_table` (`account_journal.py:145`).
When enabled on a journal, every entry posted to that journal gets an `inalterable_hash`
field set on `account_move`.

### What is hashed

`_get_integrity_hash_fields()` (`account_move.py:4557-4564`) returns the header fields
covered by the hash (hash version 2–4, which is current):

- `name` (the journal entry number)
- `date`
- `journal_id`
- `company_id`

Plus each line's fields from `account_move_line._get_integrity_hash_fields()`.

The hash is SHA-256, chained: each entry's hash includes the previous entry's hash as
input, forming a forward chain (`account_move.py:4765`):

```python
hash_string = sha256((previous_hash + current_record).encode('utf-8')).hexdigest()
```

### Irreversibility

Once `restrict_mode_hash_table = True` and entries exist with `inalterable_hash` set,
you cannot turn it off. Attempting to clear `restrict_mode_hash_table` on a journal that
has hashed entries raises a `UserError` (`account_journal.py:794-801`).

### Write protection

`account_move.write()` (`account_move.py:3892-3898`) checks before every write:

```python
violated_fields = set(vals).intersection(move._get_integrity_hash_fields() + ['inalterable_hash'])
if move.inalterable_hash and violated_fields:
    raise UserError("This document is protected by a hash.")
```

Editing the hashed fields (`name`, `date`, `journal_id`, `company_id`) or
`inalterable_hash` itself on a hashed entry raises a `UserError`. This is ORM-level only
— raw SQL is not blocked.

### Verification

`company._check_hash_integrity()` (`company.py:994-1085`) iterates all journals, fetches
their hashed entries in sequence order, recomputes the chain, and reports any mismatches.
Trigger it via Accounting → Reporting → Audit Reports → Inalterability Check, or from
`odoo shell`:

```python
env['res.company'].browse(1)._check_hash_integrity()
```

### Localizations that force hash chains

- **Germany (DE):** `l10n_de` forces `force_restrictive_audit_trail = True` for all
  companies with `country_code == 'DE'` (`l10n_de/models/res_company.py:35`). Once
  `restrictive_audit_trail` is forced on, it cannot be disabled
  (`company.py:329-333`).
- **India (IN):** `l10n_in` forces `force_restrictive_audit_trail` once
  `_existing_accounting()` is true for the company (`l10n_in/models/company.py:110`),
  i.e., once any accounting entries exist.

## Gapless sequence (sequence.mixin)

`account.move` inherits `sequence.mixin` (`account_move.py:74`), which enforces
gapless, per-journal, per-period sequence numbers. The sequence prefix (e.g. `INV/2024/`)
is stored in `sequence_prefix`; the number is in `sequence_number`. You cannot insert,
delete, or renumber entries without creating a sequence gap, which is itself a compliance
violation in many jurisdictions.

## Lock dates

Lock dates prevent posting or modifying entries before a given date. There are several:

| Field | Reversible? | Who can override? |
|---|---|---|
| `fiscalyear_lock_date` | Yes | Accounting manager + exception |
| `tax_lock_date` | Yes | Accounting manager + exception |
| `sale_lock_date` | Yes | Accounting manager + exception |
| `purchase_lock_date` | Yes | Accounting manager + exception |
| `hard_lock_date` | **NO** | Nobody |

`hard_lock_date` is defined as `"irreversible and does not allow any exception"`
(`company.py:102-103`). The `write()` check (`company.py:559-566`) enforces:

```python
if not hard_lock_date:
    raise UserError("The Hard Lock Date cannot be removed.")
if hard_lock_date < company.hard_lock_date:
    raise UserError("A new Hard Lock Date must be posterior (or equal) to the previous one.")
```

Once set, `hard_lock_date` can only move forward. It can never be cleared or moved
backward. This is ORM-enforced; raw SQL could bypass it, but doing so would also
bypass every audit trail and potentially invalidate the hash chain for entries
in the newly "unlocked" period.

## Restrictive audit trail

`company.restrictive_audit_trail` (`company.py:268-276`) forbids:

1. Deleting any `account_move` that has ever been `posted_before` (`account_move.py:4036`).
2. Rewriting chatter messages on posted moves (`account_move.py:3995`).

Forced on by German and Indian localizations (see above). Cannot be disabled once forced
(`company.py:329-333`).

## The correct way to undo a posted entry

**NEVER delete a posted entry. NEVER use raw SQL to modify `account_move` or
`account_move_line`.**

The correct undo mechanisms, in order of preference:

### 1. Reversal / credit note (primary method)

`_reverse_moves()` (`account_move.py:5441-5485`) creates a new entry with all amounts
sign-flipped and links it to the original via `reversed_entry_id`. The original entry
stays in the ledger.

**Important:** bare `_reverse_moves()` (default `cancel=False`) creates the reverse move
in **DRAFT** state. It does NOT auto-post or auto-reconcile. You must post it separately
and then reconcile it against the original if needed. To create, post, and reconcile in
one call, pass `cancel=True`:

```python
move._reverse_moves(cancel=True)
# cancel=True: posts the reverse move and reconciles it against the original,
# netting them to zero.
```

The **recommended path** is the UI wizard or `action_reverse()`, which handles posting and
reconciliation through the supported `account.move.reversal` wizard flow
(`account_move.py:6093`).

Trigger via UI: the "Reverse" button, or `action_reverse()` (`account_move.py:6093`).

```python
# From odoo shell — use cancel=True to post and reconcile in one step:
move = env['account.move'].browse(123)
move._reverse_moves(cancel=True)
env.cr.commit()

# Or bare _reverse_moves() returns a DRAFT reversal you must post separately:
reverse = move._reverse_moves()
reverse.action_post()
env.cr.commit()
```

### 2. Cancel (before posting is finalized)

`button_cancel()` (`account_move.py:6273`) is available only when the entry can be
cancelled (not hashed, date not locked). It moves the state to `cancel` without creating
a reverse entry.

### What "one raw SQL edit" actually breaks

If you run `UPDATE account_move SET date = '2024-01-01' WHERE id = 500` on an entry
that is part of a hash chain:

1. The `inalterable_hash` for entry 500 is now wrong (computed from stale field values).
2. Every entry after 500 in the same journal prefix chained to it — their hashes also
   become wrong, because the chain input included entry 500's hash.
3. `_check_hash_integrity()` will report all of these as corrupted.
4. **There is no recalculation path.** The `_hash_moves()` function only hashes forward
   from the current field values; it cannot retroactively fix a chain where an intermediate
   entry was edited.

The only recovery is a restore from a pre-corruption backup.

## Summary — do and do not

**Do:**
- Use reversals or credit notes (`_reverse_moves`, `action_reverse`) to undo posted entries.
- Use `button_cancel()` to cancel entries that have not been hashed.
- Run `_check_hash_integrity()` after any bulk operation to verify the chain is intact.
- Check `hard_lock_date` before assuming an accounting period can be modified.

**Do not:**
- `DELETE FROM account_move WHERE ...`
- `UPDATE account_move SET ... WHERE ...`
- `UPDATE account_move_line SET ... WHERE ...`
- Manually set `inalterable_hash = ''` to "unlock" an entry for editing.
- Assume a sequence gap can be filled by renumbering.
- Set `hard_lock_date` without understanding it is permanent and cannot be lowered.
