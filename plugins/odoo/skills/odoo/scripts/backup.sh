#!/usr/bin/env bash
# Filestore-aware Odoo backup. Runs INSIDE the Odoo container, as root.
#
# Nothing installs this file in the Odoo container. The assistant pipes it from
# the skill's own folder over the clouve-ops SSH channel, and `bash -s` runs it
# there:
#
#   SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
#     clouve-ops@${ODOO_HOST} "sudo bash -s -- <db>" \
#     < /clouve/skills/odoo/plugin/skills/odoo/scripts/backup.sh
#
# Usage: backup.sh <db> [out.zip]
#   out.zip defaults to <data_dir>/backups/<db>-<UTC YYYYmmdd-HHMMSS>.zip, with
#   data_dir read from odoo.conf (/var/lib/odoo on Clouve, the data volume).
#
# It runs `odoo db dump`, which writes one ZIP holding dump.sql (pg_dump
# --no-owner), filestore/ and manifest.json. The config goes in ODOO_RC, not -c:
# `-c` after `dump` fails on Odoo 19 ("unrecognized arguments"), and sudo
# over SSH drops the image's own ODOO_RC. Then it checks the ZIP: dump.sql and
# manifest.json, plus filestore/ whenever the database's filestore folder holds
# files (a database dump alone loses every attachment). A dump or a check that
# fails leaves no file behind, so nothing that looks like a backup is wrong.
set -euo pipefail

DB="${1:?usage: backup.sh <db> [out.zip]}"
CONF="${ODOO_RC:-/etc/odoo/odoo.conf}"

if [ ! -r "${CONF}" ]; then
  echo "[odoo/backup] can't read the Odoo config ${CONF}; no backup taken" >&2
  exit 1
fi

DATA_DIR="$(python3 -I - "${CONF}" <<'PY'
import configparser, sys
p = configparser.RawConfigParser()
p.read(sys.argv[1])
print(p.get('options', 'data_dir', fallback='/var/lib/odoo'))
PY
)"
OUT="${2:-${DATA_DIR}/backups/${DB}-$(date -u +%Y%m%d-%H%M%S).zip}"
FILESTORE="${DATA_DIR}/filestore/${DB}"

if [ -e "${OUT}" ]; then
  echo "[odoo/backup] ${OUT} already exists; give another output path" >&2
  exit 1
fi

# odoo db dump runs as the odoo user on Odoo images from 2026-11-03 on, so a
# missing folder for the backup is made as odoo's, mode 700. The default
# folder, right inside data_dir, is made by root one level deep and given to
# odoo: mkdir without -p fails on anything already there, a link included,
# and chown -h changes the folder itself. That holds only when no part of
# data_dir's path is a link. Any other folder is made by the odoo user itself,
# so a link in a path that odoo controls can't make root create a folder
# somewhere else. An existing folder is left as it is.
OUT_DIR="$(dirname -- "${OUT}")"
if [ ! -d "${OUT_DIR}" ]; then
  if [ "$(dirname -- "${OUT_DIR}")" = "${DATA_DIR}" ] \
      && [ "$(realpath -e -- "${DATA_DIR}" 2>/dev/null)" = "${DATA_DIR}" ]; then
    mkdir -m 700 -- "${OUT_DIR}"
    chown -h odoo:odoo -- "${OUT_DIR}"
  elif ! setpriv --reuid=odoo --regid=odoo --init-groups --no-new-privs -- mkdir -p -m 700 -- "${OUT_DIR}"; then
    echo "[odoo/backup] can't make ${OUT_DIR} as the odoo user; give a folder odoo can write, or leave out the output path" >&2
    exit 1
  fi
fi

echo "[odoo/backup] ${DB} -> ${OUT} (database + filestore + manifest)"
# </dev/null: under `bash -s` this script arrives on stdin; keep odoo off it.
if ! ODOO_RC="${CONF}" odoo db dump "${DB}" "${OUT}" </dev/null; then
  rm -f "${OUT}"   # odoo creates the file before pg_dump runs
  echo "[odoo/backup] FAILED: odoo db dump exited non-zero; no backup written" >&2
  exit 1
fi

if ! python3 -I - "${OUT}" "${FILESTORE}" <<'PY'
import os, sys, zipfile
out, filestore = sys.argv[1], sys.argv[2]
if not zipfile.is_zipfile(out):
    sys.exit(f"[odoo/backup] FAILED: {out} is not a ZIP archive")
names = zipfile.ZipFile(out).namelist()
missing = [n for n in ('dump.sql', 'manifest.json') if n not in names]
if missing:
    sys.exit(f"[odoo/backup] FAILED: the ZIP has no {' or '.join(missing)}")
on_disk = sum(len(files) for _, _, files in os.walk(filestore))
in_zip = sum(1 for n in names if n.startswith('filestore/') and not n.endswith('/'))
if on_disk and not in_zip:
    sys.exit(f"[odoo/backup] FAILED: {filestore} holds {on_disk} files but the ZIP "
             "has no filestore/ (attachments would be lost)")
print(f"[odoo/backup] checked: dump.sql, manifest.json, {in_zip} filestore files")
PY
then
  rm -f "${OUT}"
  exit 1
fi

SIZE="$(du -h "${OUT}" | cut -f1)"
case "$(realpath -m "${OUT}")/" in
  "$(realpath -m "${DATA_DIR}")"/*)
    echo "[odoo/backup] done: ${OUT} (${SIZE}). It is on Odoo's data volume, which survives restarts, next to the data it protects; copy it off the deployment for a separate copy" ;;
  *)
    echo "[odoo/backup] done: ${OUT} (${SIZE}). This folder is not on Odoo's data volume, so it goes when the container is replaced; copy it off to keep it" ;;
esac
