#!/usr/bin/env bash
# WordPress DevOps Skill — backup.sh
#
# Produces an AUDITED backup of the tenant's WordPress instance over the
# channels that actually exist from the Magneto Agent container:
#
#   1. [TCP-mysql] Full schema dump via mysqldump (--single-transaction,
#      --routines, --triggers) to a timestamped file under
#      $HOME/backups/wordpress/.
#   2. [TCP-mysql] Records siteurl/home/db_version + engine version in a
#      manifest, so a restore can be verified against known-good values.
#   3. [shell-only — probe first] wp-content/ + wp-config.php archive — a
#      complete WordPress backup is the SQL dump AND wp-content/ (see
#      ../SKILL.md, principle 1). This needs a file channel. Today's
#      WordPress images (both shapes) ship no sshd/clouve-ops account, so
#      the probe is EXPECTED to fail; the script says plainly what it could
#      not cover instead of pretending.
#
# See ../reference/backup-restore.md for what a complete backup is on each
# channel, and ../playbooks/rollback-from-backup.md for the restore order.
#
# Shapes (see ../reference/stack-and-runtime.md):
#   - Clouve-packaged app: MariaDB sibling (image tag floats — engine version
#     is recorded in the manifest for exactly that reason).
#   - Developer-submitted compose: often MySQL 8. Note MYSQL_RANDOM_ROOT_-
#     PASSWORD is common — you have the app-scoped DB user only, which is
#     all this script needs.
#
# Env vars read (injected by the platform's sidecar env fetcher; names vary
# per deployment — discover with `env | grep -iE 'wordpress|mysql|maria|host'`
# if the defaults below don't resolve):
#   WORDPRESS_DB_HOST        — pod-internal hostname of the DB sibling (required)
#   WORDPRESS_DB_PASSWORD    — DB password (required; never printed)
#   WORDPRESS_DB_USER        — DB user (default: wordpress)
#   WORDPRESS_DB_NAME        — DB name (default: wordpress)
#   WORDPRESS_TABLE_PREFIX   — table prefix for manifest metadata queries only
#                              (default: wp_; the dump itself is prefix-agnostic)
#   WORDPRESS_HOST           — pod-internal hostname of the WordPress sibling
#                              (default: wordpress; only used for the shell probe)
#   CLOUVE_OPS_PASSWORD      — optional; enables the shell probe when set
#
# Output:
#   $HOME/backups/wordpress/
#     ├── db-<timestamp>.sql.gz          (mysqldump output, gzipped)
#     ├── wp-content-<timestamp>.tar.gz  (ONLY if a file channel exists)
#     └── manifest-<timestamp>.txt       (sizes, checksums, coverage record)
#
# Exit codes:
#   0 — DB dump completed and verified (possibly PARTIAL: no wp-content —
#       read the coverage summary, it says so loudly)
#   1 — required env vars missing / required client tools missing
#   2 — mysqldump failed
#   3 — wp-content tar failed AFTER the shell probe succeeded (unexpected)
#   4 — dump artifact empty, truncated, or failed verification

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Produces an audited DB backup of the WordPress instance over TCP, plus a
wp-content archive when (and only when) a file channel exists.

Reads from env vars; see the script header for the full list.

Output goes to \$HOME/backups/wordpress/.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

: "${WORDPRESS_DB_HOST:?WORDPRESS_DB_HOST not set — run: env | grep -iE 'wordpress|mysql|maria|host' to discover the injected names}"
: "${WORDPRESS_DB_PASSWORD:?WORDPRESS_DB_PASSWORD not set — discover with: env | grep -iE 'wordpress|mysql|maria'}"
: "${WORDPRESS_DB_USER:=wordpress}"
: "${WORDPRESS_DB_NAME:=wordpress}"
: "${WORDPRESS_TABLE_PREFIX:=wp_}"
: "${WORDPRESS_HOST:=wordpress}"

# WordPress allows WORDPRESS_DB_HOST of the form host:port — split it.
DB_HOST="${WORDPRESS_DB_HOST%%:*}"
DB_PORT=3306
if [[ "${WORDPRESS_DB_HOST}" == *:* ]]; then
    DB_PORT="${WORDPRESS_DB_HOST##*:}"
fi

if ! command -v mysqldump >/dev/null 2>&1; then
    err "mysqldump not found — the plugin's install.sh hook installs the mysql client on container start; re-run it or check the stager log"
    exit 1
fi

# Sanitize the prefix before it goes anywhere near a query string.
prefix="${WORDPRESS_TABLE_PREFIX}"
if [[ ! "${prefix}" =~ ^[A-Za-z0-9_]+$ ]]; then
    log "WORDPRESS_TABLE_PREFIX contains unexpected characters; falling back to wp_ for metadata queries (dump is unaffected)"
    prefix="wp_"
fi

ts=$(date -u +%Y-%m-%d-%H-%M-%S)
out_dir="${HOME}/backups/wordpress"
mkdir -p "${out_dir}"

db_file="${out_dir}/db-${ts}.sql.gz"
content_file="${out_dir}/wp-content-${ts}.tar.gz"
manifest="${out_dir}/manifest-${ts}.txt"

{
    printf 'wordpress-backup\n'
    printf 'timestamp_utc: %s\n' "${ts}"
    printf 'db_host: %s\n' "${WORDPRESS_DB_HOST}"
    printf 'db_name: %s\n' "${WORDPRESS_DB_NAME}"
    printf 'table_prefix: %s\n' "${prefix}"
} > "${manifest}"

# Small helper for metadata queries. [TCP-mysql]
mysql_q() {
    MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql \
        -h "${DB_HOST}" -P "${DB_PORT}" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" \
        -sN --connect-timeout=5 -e "$1" 2>/dev/null
}

# --- 1. [TCP-mysql] Restore-verification metadata into the manifest.
#     Best-effort: a non-default prefix or unreadable option must not block
#     the dump itself (the dump covers every table regardless of prefix).
engine=$(mysql_q "SELECT VERSION()" || echo "unknown")
siteurl=$(mysql_q "SELECT option_value FROM ${prefix}options WHERE option_name='siteurl'" || echo "")
home_url=$(mysql_q "SELECT option_value FROM ${prefix}options WHERE option_name='home'" || echo "")
db_version=$(mysql_q "SELECT option_value FROM ${prefix}options WHERE option_name='db_version'" || echo "")
{
    printf 'engine_version: %s\n' "${engine:-unknown}"
    printf 'siteurl: %s\n' "${siteurl:-unknown (options table not readable — non-default prefix?)}"
    printf 'home: %s\n' "${home_url:-unknown}"
    printf 'db_version: %s\n' "${db_version:-unknown}"
} >> "${manifest}"

# --- 2. [TCP-mysql] The dump. --single-transaction gives a consistent
#     InnoDB snapshot without locking a live site; --routines/--triggers so
#     nothing schema-adjacent is silently dropped; --no-tablespaces avoids
#     needing the PROCESS privilege on MySQL 8 with an app-scoped user.
log "Dumping ${WORDPRESS_DB_NAME}@${WORDPRESS_DB_HOST} (mysqldump) → ${db_file}"
dump_err=$(mktemp "${TMPDIR:-/tmp}/wp-backup-err.XXXXXX")
trap 'rm -f "${dump_err}"' EXIT
if ! MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysqldump \
        -h "${DB_HOST}" \
        -P "${DB_PORT}" \
        -u "${WORDPRESS_DB_USER}" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --no-tablespaces \
        --lock-tables=false \
        --default-character-set=utf8mb4 \
        "${WORDPRESS_DB_NAME}" \
        2> "${dump_err}" | gzip > "${db_file}"; then
    err "mysqldump failed:"
    sed 's/^/    /' "${dump_err}" >&2
    if grep -qi 'authentication plugin\|caching_sha2' "${dump_err}"; then
        err "Hint: the developer-submitted shape often runs MySQL 8, whose default auth is caching_sha2_password. If your installed client is the MariaDB one it may not speak that plugin — verify client/server compatibility (see ../reference/stack-and-runtime.md) before assuming credentials are wrong."
    fi
    exit 2
fi

# --- 3. Verify the dump — non-empty, has tables, and mysqldump's own
#     completion marker is present (a truncated dump lacks the trailer).
if [[ ! -s "${db_file}" ]]; then
    err "DB dump file is empty or missing: ${db_file}"
    exit 4
fi
table_count=$(zcat "${db_file}" | grep -c '^CREATE TABLE' || true)
if [[ "${table_count}" -eq 0 ]]; then
    err "DB dump contains no CREATE TABLE statements — refusing to call this a backup"
    exit 4
fi
if ! zcat "${db_file}" | tail -n 5 | grep -q 'Dump completed'; then
    err "DB dump is missing mysqldump's 'Dump completed' trailer — likely truncated mid-stream; do not trust this artifact"
    exit 4
fi

db_size=$(wc -c < "${db_file}")
log "DB dump verified: ${db_size} bytes, ${table_count} tables, completion trailer present"
{
    printf 'db_artifact: %s\n' "$(basename "${db_file}")"
    printf 'db_size_bytes: %s\n' "${db_size}"
    printf 'db_table_count: %s\n' "${table_count}"
} >> "${manifest}"

# --- 4. [shell-only — probe first] wp-content + wp-config.php archive.
#     wp-content holds uploads (media), plugins, themes, and debug.log; the
#     DB references media by URL/path but the bytes live only on disk.
#     Today's WordPress images ship no sshd and no clouve-ops account
#     (unlike moodle/gibbon), so expect the probe to fail — this branch
#     exists for the day a future image adds the channel.
content_covered="no"
probe_shell() {
    [[ -n "${CLOUVE_OPS_PASSWORD:-}" ]] || return 1
    command -v sshpass >/dev/null 2>&1 || return 1
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh \
        -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new -o BatchMode=no \
        "clouve-ops@${WORDPRESS_HOST}" true 2>/dev/null
}

if probe_shell; then
    log "Shell channel to ${WORDPRESS_HOST} exists — archiving wp-content/ + wp-config.php → ${content_file}"
    export SSHPASS="${CLOUVE_OPS_PASSWORD}"
    ssh_opts=(-o StrictHostKeyChecking=accept-new -o BatchMode=no)
    # cache/ and upgrade/ are ephemeral (page-cache output, half-unpacked
    # updates) — excluding them keeps the archive restorable, not smaller-but-broken.
    if ! sshpass -e ssh "${ssh_opts[@]}" "clouve-ops@${WORDPRESS_HOST}" "
        cd /var/www/html || exit 1
        if command -v sudo >/dev/null 2>&1; then
            sudo tar --exclude='wp-content/cache' --exclude='wp-content/upgrade' -czf - wp-content wp-config.php
        else
            tar --exclude='wp-content/cache' --exclude='wp-content/upgrade' -czf - wp-content wp-config.php
        fi
    " > "${content_file}"; then
        unset SSHPASS
        err "wp-content tar via SSH failed after a successful probe — treat this backup as DB-only"
        exit 3
    fi
    unset SSHPASS
    if [[ ! -s "${content_file}" ]]; then
        err "wp-content archive is empty: ${content_file}"
        exit 4
    fi
    content_size=$(wc -c < "${content_file}")
    content_covered="yes"
    log "wp-content archive complete: ${content_size} bytes"
    {
        printf 'content_artifact: %s\n' "$(basename "${content_file}")"
        printf 'content_size_bytes: %s\n' "${content_size}"
    } >> "${manifest}"
else
    log "No shell channel to ${WORDPRESS_HOST} (expected on today's WordPress images) — wp-content/ NOT archived"
fi
printf 'wp_content_covered: %s\n' "${content_covered}" >> "${manifest}"

# Checksums.
if command -v sha256sum >/dev/null 2>&1; then
    if [[ "${content_covered}" == "yes" ]]; then
        sha256sum "${db_file}" "${content_file}" >> "${manifest}"
    else
        sha256sum "${db_file}" >> "${manifest}"
    fi
fi

log "Backup finished: ${out_dir}"
log "Manifest:"
cat "${manifest}"

# --- Coverage summary — what this backup IS and IS NOT.
cat <<SUMMARY

Coverage summary
  COVERED   [TCP-mysql]  full schema dump of ${WORDPRESS_DB_NAME} (all tables, routines, triggers): $(basename "${db_file}")
  COVERED   [TCP-mysql]  restore-verification metadata (siteurl/home/db_version/engine) in $(basename "${manifest}")
SUMMARY

if [[ "${content_covered}" == "yes" ]]; then
    cat <<SUMMARY
  COVERED   [shell]      wp-content/ (uploads, plugins, themes) + wp-config.php: $(basename "${content_file}")
SUMMARY
else
    cat <<'SUMMARY'
  NOT COVERED (no file channel): wp-content/ — media uploads, plugin code, theme code, debug.log
  NOT COVERED (no file channel): wp-config.php — auth salts/keys (a restore without them logs every user out)

  This is a DB-ONLY backup. Core files are replaceable from the image, but
  media and installed plugin/theme code are not in the database. If you need
  the file half today: a maintained backup plugin installed via /wp-admin can
  archive wp-content from inside the site (source-vetting gate applies — see
  ../playbooks/install-plugin.md), or route the user to Clouve support for a
  volume-level copy. Details: ../reference/backup-restore.md.
SUMMARY
fi

cat <<'NOTE'

Restore order and verification canaries: ../playbooks/rollback-from-backup.md
NOTE
