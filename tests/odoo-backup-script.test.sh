#!/bin/bash
# ============================================================================
# Odoo skill: scripts/backup.sh
# ============================================================================
# The assistant doesn't install backup.sh anywhere. It pipes the file from the
# skill's own folder into the Odoo container over the clouve-ops channel:
#
#   SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
#     "sudo bash -s -- <db>" < /clouve/skills/odoo/plugin/skills/odoo/scripts/backup.sh
#
# so the script runs inside the Odoo container, as root, with none of the
# agent's environment. This test runs it the same two ways (as a file and
# through `bash -s`) against fakes and checks that it:
#
#   - runs `odoo db dump <db> <out.zip>` with the config in ODOO_RC and no -c
#     (on Odoo 19 `odoo db dump -c ...` fails: "unrecognized arguments");
#   - never SSHes anywhere and never hand-rolls a pg_dump (a pg_dump alone
#     loses the filestore);
#   - writes <data_dir>/backups/<db>-<UTC timestamp>.zip by default, data_dir
#     read from odoo.conf;
#   - checks the ZIP: dump.sql, manifest.json, and filestore/ whenever the
#     database's filestore folder holds files; a database with no filestore
#     folder yet is fine without one;
#   - leaves nothing that looks like a backup when the dump or the check fails
#     (a failed `odoo db dump` leaves an empty file behind);
#   - refuses to overwrite an existing file, and stops before dumping when the
#     config file can't be read or no database is named.
#
# The fake `odoo` accepts only `db dump <db> <path>`, records ODOO_RC and its
# arguments, and writes a ZIP the way Odoo 19's dump_db does (dump.sql,
# filestore/<sha1[:2]>/<sha1>, manifest.json). Fake pg_dump, ssh and sshpass
# record any call and fail. The script runs under `env -i` with HOME and the
# data folder in a throwaway directory. No Odoo, PostgreSQL or network.
#
# Usage: bash tests/odoo-backup-script.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "${here}/../plugins/odoo/skills/odoo/scripts" && pwd)/backup.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/odoo-backup-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------
bin="${work}/bin"
mkdir -p "${bin}"

cat > "${bin}/odoo" <<'FAKE'
#!/bin/bash
printf 'odoo ODOO_RC=%s ARGS=%s\n' "${ODOO_RC-<unset>}" "$*" >> "${FAKE_CALLS}"
if [ "$#" -ne 4 ] || [ "$1" != db ] || [ "$2" != dump ]; then
  echo "fake odoo: wanted 'db dump <db> <path>', got: $*" >&2
  exit 2
fi
out="$4"
: > "${out}"   # Odoo opens the output file before pg_dump runs
case "${FAKE_ODOO_MODE:-ok}" in
  fail)
    echo "psycopg2.OperationalError: connection to server failed" >&2
    exit 1 ;;
  notzip)
    echo "not a zip" > "${out}" ;;
  ok|nofilestore)
    python3 -I - "${out}" "${FAKE_ODOO_MODE:-ok}" <<'PY'
import sys, zipfile
out, mode = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w') as z:
    z.writestr('dump.sql', '-- PostgreSQL database dump\n')
    if mode == 'ok':
        z.writestr('filestore/ab/ab12cd34', 'attachment bytes')
    z.writestr('manifest.json', '{"version": "19.0"}')
PY
    ;;
esac
exit 0
FAKE

for name in pg_dump ssh sshpass; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "${FAKE_CALLS}"\necho "fake %s: must not be called" >&2\nexit 99\n' \
    "${name}" "${name}" > "${bin}/${name}"
done
chmod +x "${bin}"/*

# ---------------------------------------------------------------------------
# Sandbox: odoo.conf, data_dir with a filestore for database "acme"
# ---------------------------------------------------------------------------
data="${work}/data"
conf="${work}/odoo.conf"
printf '[options]\ndb_host = odoo-postgres\ndata_dir = %s\n' "${data}" > "${conf}"

reset_filestore() {
  rm -rf "${data}"
  mkdir -p "${data}/filestore/acme/ab"
  printf 'attachment bytes' > "${data}/filestore/acme/ab/ab12cd34"
}

# run <mode> <how: file|stdin> [args...] — sets $out, $rc, $calls
run() {
  local mode="$1" how="$2"
  shift 2
  : > "${work}/calls"
  if [ "${how}" = stdin ]; then
    out=$(env -i HOME="${work}/home" PATH="${bin}:/usr/bin:/bin" ODOO_RC="${ODOO_RC_FOR_TEST:-${conf}}" \
      FAKE_CALLS="${work}/calls" FAKE_ODOO_MODE="${mode}" bash -s -- "$@" < "${script}" 2>&1)
  else
    out=$(env -i HOME="${work}/home" PATH="${bin}:/usr/bin:/bin" ODOO_RC="${ODOO_RC_FOR_TEST:-${conf}}" \
      FAKE_CALLS="${work}/calls" FAKE_ODOO_MODE="${mode}" bash "${script}" "$@" 2>&1)
  fi
  rc=$?
  calls="$(cat "${work}/calls")"
}

check() { # <label> <condition-result: 0 = pass>
  if [ "$2" -eq 0 ]; then
    printf '  ✓ %s\n' "$1"
    pass=$((pass + 1))
  else
    printf '  ✗ %s (exit %s)\n' "$1" "${rc}"
    printf '%s\n' "${out}" | sed 's/^/      | /'
    [ -n "${calls}" ] && printf '%s\n' "${calls}" | sed 's/^/      calls: /'
    fail=$((fail + 1))
  fi
}

zip_has() { # <zip> <name> — 0 when the archive holds <name>
  python3 -I -c 'import sys, zipfile; sys.exit(0 if sys.argv[2] in zipfile.ZipFile(sys.argv[1]).namelist() else 1)' "$1" "$2" 2>/dev/null
}

echo "Odoo skill: scripts/backup.sh (runs inside the Odoo container)"

# 1. As a file: the dump command, the ZIP, nothing else called.
reset_filestore
target="${work}/out/acme-test.zip"
run ok file acme "${target}"
[ "${rc}" -eq 0 ]; check "exits 0 when the dump and the check succeed" $?
[ "${calls}" = "odoo ODOO_RC=${conf} ARGS=db dump acme ${target}" ]
check "runs exactly 'odoo db dump acme <out>' with ODOO_RC set to odoo.conf, nothing else" $?
[ -f "${target}" ] && zip_has "${target}" dump.sql && zip_has "${target}" manifest.json && zip_has "${target}" filestore/ab/ab12cd34
check "creates the output folder and leaves the ZIP there" $?
grep -qF "${target}" <<< "${out}"; check "prints where the backup is" $?

# 2. Through `bash -s`, the way the playbook pipes it over SSH.
reset_filestore
target="${work}/out/acme-piped.zip"
run ok stdin acme "${target}"
[ "${rc}" -eq 0 ] && [ -f "${target}" ] && [ "${calls}" = "odoo ODOO_RC=${conf} ARGS=db dump acme ${target}" ]
check "works the same when piped through 'bash -s -- acme <out>'" $?

# 3. Default output path from data_dir.
reset_filestore
run ok stdin acme
made="$(find "${data}/backups" -maxdepth 1 -type f -name 'acme-*.zip' 2>/dev/null)"
[ "${rc}" -eq 0 ] && [ "$(printf '%s\n' "${made}" | grep -c .)" -eq 1 ] \
  && [[ "$(basename "${made}")" =~ ^acme-[0-9]{8}-[0-9]{6}\.zip$ ]]
check "defaults to <data_dir>/backups/<db>-<YYYYmmdd-HHMMSS>.zip" $?

# 4. odoo db dump fails: non-zero, and the empty file it left is gone.
reset_filestore
target="${work}/out/acme-fail.zip"
run fail stdin acme "${target}"
[ "${rc}" -ne 0 ] && [ ! -e "${target}" ]
check "fails, and removes the empty file, when odoo db dump fails" $?

# 5. Filestore holds files but the ZIP has none: fail and remove the ZIP.
reset_filestore
target="${work}/out/acme-nofs.zip"
run nofilestore stdin acme "${target}"
[ "${rc}" -ne 0 ] && [ ! -e "${target}" ] && grep -qi filestore <<< "${out}"
check "fails when the filestore has files but the ZIP has no filestore/" $?

# 6. No filestore folder yet (nothing attached): a ZIP without filestore/ is right.
reset_filestore
rm -rf "${data}/filestore/acme"
target="${work}/out/acme-empty.zip"
run nofilestore stdin acme "${target}"
[ "${rc}" -eq 0 ] && [ -f "${target}" ]
check "passes when the database has no filestore folder" $?

# 7. Not a ZIP at all.
reset_filestore
target="${work}/out/acme-notzip.zip"
run notzip stdin acme "${target}"
[ "${rc}" -ne 0 ] && [ ! -e "${target}" ]
check "fails, and removes the file, when the dump isn't a ZIP" $?

# 8. Never overwrite an existing file.
reset_filestore
target="${work}/out/acme-keep.zip"
mkdir -p "${work}/out"
printf 'an older backup' > "${target}"
run ok stdin acme "${target}"
[ "${rc}" -ne 0 ] && [ "$(cat "${target}")" = "an older backup" ] && [ -z "${calls}" ]
check "refuses to overwrite an existing file, without dumping" $?

# 9. Config file missing: stop before dumping.
reset_filestore
ODOO_RC_FOR_TEST="${work}/missing.conf" run ok stdin acme "${work}/out/acme-noconf.zip"
[ "${rc}" -ne 0 ] && [ -z "${calls}" ] && grep -qF "missing.conf" <<< "${out}"
check "stops before dumping when the config file can't be read" $?

# 10. No database named.
run ok stdin
[ "${rc}" -ne 0 ] && [ -z "${calls}" ]
check "stops before dumping when no database is named" $?

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
