# Playbook: Backup

Use before any module install/upgrade, restore, data fix, or configuration change. A complete Odoo backup captures the PostgreSQL database AND the per-database filestore.

## What a complete backup contains

A backup ZIP produced by `odoo db dump` includes all three required components (see [reference/backup-restore.md](../reference/backup-restore.md)):

1. `dump.sql` — plain-text `pg_dump --no-owner` of the database.
2. `filestore/` — the per-DB binary filestore at `/var/lib/odoo/filestore/<db>/`.
3. `manifest.json` — Odoo version, installed module list with versions.

A `pg_dump` alone is NOT a complete backup. Missing filestore = silently lost attachments on restore (missing files return empty bytes with no error — see [reference/file-storage.md](../reference/file-storage.md#missing-files-return-empty-b-silently)).

## Steps

### 1. Preferred — `scripts/backup.sh`

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo -E bash /var/lib/odoo/scripts/backup.sh <db>"
```

This script wraps `odoo db -c /etc/odoo/odoo.conf dump <db> <out.zip>`, handles error checking, and writes the artifact to a predictable path (typically `/var/lib/odoo/backups/<db>-<timestamp>.zip`). It is the preferred path because it is audited and filestore-aware.

Check the output for the artifact path, then note it for the copy step below.

### 2. Manual fallback — `odoo db dump` directly

If `scripts/backup.sh` is not present, run the dump command directly.

**Note: `-c` goes AFTER `db`, not before it. This is a subcommand flag, not a server flag.**

```bash
# ZIP format (default) — includes dump.sql + filestore/ + manifest.json:
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo db -c /etc/odoo/odoo.conf dump <db> /tmp/<db>-$(date +%Y%m%d-%H%M%S).zip"
```

Verify the artifact was created and is non-zero:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "ls -lh /tmp/<db>-*.zip"
```

### 3. Format options and tradeoffs

| Flag | Output | Contains filestore? | Contains manifest? | Use when |
|---|---|---|---|---|
| (none / default) | `.zip` | Yes | Yes | **Default. Always use this.** |
| `--no-filestore` | `.zip` | No | Yes | DB-only point-in-time (fast); requires separate filestore backup |
| `--format dump` | `.dump` | No | No | DBA-level PG custom-format restore via `pg_restore`; not a full Odoo backup |

```bash
# Dump-only (no filestore — incomplete Odoo backup):
sudo odoo db -c /etc/odoo/odoo.conf dump --no-filestore <db> /tmp/<db>-dbonly.zip

# PG custom format (no filestore, no manifest — DB-admin use only):
sudo odoo db -c /etc/odoo/odoo.conf dump --format dump <db> /tmp/<db>.dump
```

### 4. Manual fallback — `pg_dump` + filestore tar

Use only if `odoo db dump` is not available (e.g., the Odoo process cannot start).

**This produces an incomplete Odoo backup** — no `manifest.json`, but the filestore is included if you tar it separately. The restore path requires manual `psql` + filestore extraction (not `odoo db load`).

```bash
# Step 1: dump the database (via SSH to the Postgres container):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_DB_HOST} \
  "sudo -u postgres pg_dump --no-owner -Fc <db> > /tmp/<db>-$(date +%Y%m%d).dump"

# Step 2: tar the filestore (via SSH to the Odoo container):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo tar -C /var/lib/odoo/filestore -czf /tmp/filestore-<db>-$(date +%Y%m%d).tar.gz <db>"
```

**Important:** `pg_dump` alone silently loses all attachments stored in the filestore. Always tar the filestore directory in the same step.

### 5. Copy the artifact off the pod

The backup artifact lives inside the container. Copy it to the Magneto Agent's persistent home directory for safekeeping:

```bash
# Via kubectl cp (if running in Kubernetes):
kubectl cp <odoo-pod>:/tmp/<db>-<timestamp>.zip $HOME/backups/<db>-<timestamp>.zip

# Or via scp through the clouve-ops SSH channel:
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e scp \
  clouve-ops@${ODOO_HOST}:/tmp/<db>-<timestamp>.zip \
  $HOME/backups/<db>-<timestamp>.zip
```

Verify the copy arrived:

```bash
ls -lh $HOME/backups/<db>-<timestamp>.zip
```

The `$HOME/backups/` directory survives pod restarts (it is on the persistent `magneto-agent-home` volume), but it is not an off-site backup. Advise the tenant to download the file periodically to an external location.

## Do NOT

- Take a `pg_dump`-only backup and call it complete — filestore attachments will be silently lost on restore.
- Use `--format dump` as a routine Odoo backup — it produces a DBA-level DB-only dump, not a restorable Odoo backup.
- Skip the copy step — backups inside the pod are lost if the pod is replaced.
