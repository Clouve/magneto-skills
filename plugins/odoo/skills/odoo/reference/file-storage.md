# File Storage

Odoo 19.0. Authored against `odoo/addons/base/models/ir_attachment.py` and `odoo/tools/config.py`.

---

## Filestore location

```
<data_dir>/filestore/<dbname>
```

In this deployment, `data_dir = /var/lib/odoo` (set by the entrypoint via `data_dir = /var/lib/odoo` in `odoo.conf`), so the filestore lives at:

```
/var/lib/odoo/filestore/<dbname>
```

Source: `config.py:1028–1029`
```python
def filestore(self, dbname):
    return os.path.join(self['data_dir'], 'filestore', dbname)
```

The filestore is a **per-database** directory. Each Odoo database has its own subdirectory. A backup that covers the PostgreSQL dump but omits `/var/lib/odoo/filestore/<dbname>` is **incomplete**.

---

## Content-addressing layout

Files are stored content-addressed by SHA-1. A file whose checksum is `abc123...` is stored at:

```
/var/lib/odoo/filestore/<dbname>/ab/abc123...
```

i.e., `sha1[:2]/sha1` — first two hex characters are the subdirectory, the full SHA-1 is the filename. This provides:

- **Deduplication**: if two attachments have identical content they share one file on disk.
- **Deterministic paths**: given the content, the path is always computable.

Source: `ir_attachment.py:132–144` (`_get_path` method, `fname = sha[:2] + '/' + sha`).

---

## Storage backend

The backend is controlled by the `ir_attachment.location` system parameter (`ir_config_parameter`):

- `file` (default) — binary content stored in the filestore; `store_fname` column in `ir_attachment` holds the relative path.
- `db` — binary content stored in the `db_datas` column directly in PostgreSQL.

Source: `ir_attachment.py:88–89`
```python
def _storage(self):
    return self.env['ir.config_parameter'].sudo().get_param('ir_attachment.location', 'file')
```

`force_storage()` migrates all existing attachments to the currently configured backend (`ir_attachment.py:103–114`). This is an admin-only ORM operation — do not attempt to migrate by moving files manually.

---

## Missing files return empty `b''` silently

**This is the most operationally dangerous property of the filestore.**

`_file_read` catches `OSError` and returns `b''` with a log at INFO level only. The ORM call succeeds; the caller sees an empty byte string with no exception raised.

Source: `ir_attachment.py:147–155`
```python
def _file_read(self, fname, size=None):
    full_path = self._full_path(fname)
    try:
        with open(full_path, 'rb') as f:
            return f.read(size)
    except OSError:
        _logger.info("_read_file reading %s", full_path, exc_info=True)
    return b''
```

**Consequence**: a partial backup (PG dump present, filestore missing or incomplete) will appear to load successfully. Every attachment that has a missing file will silently serve a blank — no error in the UI, no exception in the ORM. This is why a backup **must** capture the filestore alongside the PG dump.

---

## Deletes and garbage collection

Deleting an attachment does **not** immediately unlink the file from disk. Instead, `_file_delete` calls `_mark_for_gc`, which writes an empty sentinel file in `<filestore>/checklist/<sha1[:2]>/<sha1>`.

Source: `ir_attachment.py:172–188`

The actual `unlink()` is performed later by `_gc_file_store` (`@api.autovacuum`). The GC:
1. Commits its transaction and takes `LOCK ir_attachment IN SHARE MODE` (with 10 s timeout to avoid blocking).
2. Scans the `checklist/` subdirectory.
3. Unlinks checklist entries (and the corresponding data file) that are no longer referenced in `ir_attachment`.

This means a file that has just been "deleted" still exists on disk until the next autovacuum run. Plan snapshots and backups accordingly — the checklist entries are harmless to include in a backup.

---

## Backup rule

> A backup MUST capture the filestore together with the PostgreSQL dump.

Preferred: `odoo-bin db dump <db> <out.zip>` — produces a ZIP of `dump.sql` + `filestore/` + `manifest.json` in one atomic operation. See `reference/backup-restore.md` and `playbooks/backup.md`.

Manual fallback: `pg_dump` **plus** `tar -C /var/lib/odoo/filestore -czf filestore-<db>.tar.gz <dbname>`. A `pg_dump`-only backup silently loses all binary attachments stored as files.

---

## Filestore is off-limits for direct manipulation

- Never move, rename, or delete files in `/var/lib/odoo/filestore/` by hand — the GC is the only safe deletion path.
- Never copy a filestore from one database to another without also restoring the matching PG dump — the SHA-1 filenames are shared across databases but the `store_fname` references in `ir_attachment` are database-specific.
- Never edit `ir_attachment.store_fname` by raw SQL — the path is a content-address, not a configurable field.
