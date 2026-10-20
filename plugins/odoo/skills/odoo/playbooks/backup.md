# Playbook: Backup

Use before any module install/upgrade, restore, data fix, or configuration change. A complete Odoo backup captures the PostgreSQL database AND the per-database filestore.

## What a complete backup contains

A backup ZIP produced by `odoo db dump` includes all three required components (see [reference/backup-restore.md](../reference/backup-restore.md)):

1. `dump.sql` — plain-text `pg_dump --no-owner` of the database.
2. `filestore/` — the per-DB binary filestore at `/var/lib/odoo/filestore/<db>/`.
3. `manifest.json` — Odoo version, installed module list with versions.

A `pg_dump` alone is NOT a complete backup. Missing filestore = silently lost attachments on restore (missing files return empty bytes with no error — see [reference/file-storage.md](../reference/file-storage.md#missing-files-return-empty-b-silently)).

## Steps

You run these commands in this container (the Magneto Agent) and reach Odoo over the clouve-ops SSH channel. Step 1 carries `-o StrictHostKeyChecking=accept-new` because it is often the first connection: while the host key is unknown, `sshpass` exits 6 without printing anything.

### 1. Preferred: pipe the skill's `scripts/backup.sh` into the Odoo container

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@${ODOO_HOST} \
  "sudo bash -s -- <db>" < /clouve/skills/odoo/plugin/skills/odoo/scripts/backup.sh
```

The script is in this skill's own folder, here in the agent container. The Odoo container has no copy of it, and nothing needs installing there: `bash -s` reads the script from the pipe and runs it inside the Odoo container as root. It runs `odoo db dump`, writes `/var/lib/odoo/backups/<db>-<UTC timestamp>.zip` on Odoo's data volume, and checks that the ZIP holds `dump.sql`, `manifest.json` and the filestore. If the dump or the check fails, it exits non-zero and deletes the file.

Its last line is the backup's path and where it lives, for example `[odoo/backup] done: /var/lib/odoo/backups/odoo-20261020-071500.zip (516K). It is on Odoo's data volume, which survives restarts, next to the data it protects; copy it off the deployment for a separate copy`. `/var/lib/odoo` is that data volume, so a backup there is kept across restarts; copying it off (step 5) gives you a copy that doesn't share the volume with the data. Note the path for step 5. To pick the path yourself, add it after the database name: `"sudo bash -s -- <db> /tmp/<db>.zip"`.

### 2. Manual fallback: `odoo db dump` directly

If you can't use the script, run the dump yourself. Pass the config as `ODOO_RC`, never as `-c`. Where `odoo` accepts `-c` differs from one subcommand to the next (after `dump`, `-c` fails with "unrecognized arguments"), and `sudo` over SSH drops the `ODOO_RC` that the image sets, so without it Odoo can't find its database.

```bash
# ZIP format (default) — includes dump.sql + filestore/ + manifest.json:
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo ODOO_RC=/etc/odoo/odoo.conf odoo db dump <db> /tmp/<db>-$(date +%Y%m%d-%H%M%S).zip"
```

A failed dump still leaves an empty file at that path. Check that the artifact is there and not zero bytes:

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
sudo ODOO_RC=/etc/odoo/odoo.conf odoo db dump --no-filestore <db> /tmp/<db>-dbonly.zip

# PG custom format (no filestore, no manifest — DB-admin use only):
sudo ODOO_RC=/etc/odoo/odoo.conf odoo db dump --format dump <db> /tmp/<db>.dump
```

### 4. Manual fallback — `pg_dump` + filestore tar

Use only if `odoo db dump` is not available (e.g., the Odoo process cannot start).

**This produces an incomplete Odoo backup** — no `manifest.json`, but the filestore is included if you tar it separately. The restore path requires manual `psql` + filestore extraction (not `odoo db load`).

The database's superuser role is `${ODOO_DB_USER}` (`odoo`). There is no `postgres` role, so `pg_dump` needs `-U`. This may be your first connection to the Postgres container, hence `accept-new` on that command too.

```bash
# Step 1: dump the database (via SSH to the Postgres container):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=accept-new clouve-ops@${ODOO_DB_HOST} \
  "sudo -u postgres pg_dump -U ${ODOO_DB_USER} --no-owner -Fc <db> > /tmp/<db>-$(date +%Y%m%d).dump"

# Step 2: tar the filestore (via SSH to the Odoo container):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo tar -C /var/lib/odoo/filestore -czf /tmp/filestore-<db>-$(date +%Y%m%d).tar.gz <db>"
```

**Important:** `pg_dump` alone silently loses all attachments stored in the filestore. Always tar the filestore directory in the same step. A failed `pg_dump` still leaves an empty `.dump` file, so check its size with `ls -lh` before you rely on it.

### 5. Copy the artifact off the Odoo container

There is no `kubectl` in this container, and `scp` can't read `/var/lib/odoo`: that folder belongs to the `odoo` user, and `scp` runs as clouve-ops without sudo. Stream the file over the SSH channel with `sudo cat` into the Magneto Agent's persistent home directory:

```bash
mkdir -p "$HOME/backups"
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo cat /var/lib/odoo/backups/<db>-<timestamp>.zip" > "$HOME/backups/<db>-<timestamp>.zip"
```

For a step 2 backup, use its `/tmp/` path instead. For step 4, fetch the `.dump` from `${ODOO_DB_HOST}` and the filestore tar from `${ODOO_HOST}` the same way.

Verify the copy arrived whole (`Done testing` means the ZIP is intact):

```bash
ls -lh "$HOME/backups/<db>-<timestamp>.zip"
python3 -m zipfile -t "$HOME/backups/<db>-<timestamp>.zip" | tail -1
```

The `$HOME/backups/` directory survives pod restarts (it is on the persistent `magneto-agent-home` volume), but it is not an off-site backup. Advise the tenant to download the file periodically to an external location. Backups left in `/var/lib/odoo/backups/` take space on Odoo's data volume, the same volume as the filestore, so delete old ones there once they are copied.

## Do NOT

- Take a `pg_dump`-only backup and call it complete — filestore attachments will be silently lost on restore.
- Use `--format dump` as a routine Odoo backup — it produces a DBA-level DB-only dump, not a restorable Odoo backup.
- Skip the copy step. A backup in the Odoo container's `/tmp` is gone when that container is replaced, and one on its data volume goes wherever that volume goes.
