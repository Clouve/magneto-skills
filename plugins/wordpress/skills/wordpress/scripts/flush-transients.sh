#!/usr/bin/env bash
# WordPress DevOps Skill — flush-transients.sh
#
# [TCP-mysql] only. Deletes EXPIRED transients from the options table:
# every `_transient_timeout_*` / `_site_transient_timeout_*` row whose
# Unix-timestamp value is in the past, plus its `_transient_*` /
# `_site_transient_*` value partner. Never touches unexpired transients,
# never touches transients that have no timeout row (no expiry by design).
#
# DRY-RUN BY DEFAULT. Prints the row counts and the exact DELETE statements,
# then stops. Re-run with --execute only after showing the counts to the
# user and getting their ack — this is a multi-row DELETE on wp_options,
# gated by the SKILL.md safety-gates table.
#
# Works on both deployment shapes (Clouve-packaged MariaDB and
# developer-compose MySQL 8) — it only needs the app-scoped DB user.
#
# NOTE: if a persistent object-cache drop-in is active, transients live
# outside the DB and this script will (correctly) find ~0 rows. See
# reference/caching.md.
#
# Env vars read (first match wins; discover with
#   env | grep -iE 'wordpress|mysql|maria|host'):
#   WORDPRESS_DB_HOST     | MYSQL_HOST      — DB sibling host (may be host:port)
#   WORDPRESS_DB_USER     | MYSQL_USER      — DB user
#   WORDPRESS_DB_PASSWORD | MYSQL_PASSWORD  — DB password (never printed)
#   WORDPRESS_DB_NAME     | MYSQL_DATABASE  — schema name (default: wordpress)
#   WORDPRESS_TABLE_PREFIX                  — table prefix (default: wp_)
#
# Exit codes:
#   0 — dry-run printed, or delete completed and verified
#   1 — required env missing, bad flag, or mysql client not installed
#   2 — DB unreachable, or options table not found under this prefix
#   3 — DELETE failed
#
# See: reference/caching.md (transient mechanics), SKILL.md (safety gates).

set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [--execute] [-h|--help]

Without flags: DRY RUN — prints how many expired-transient rows would be
deleted and the exact SQL, then exits. Nothing is modified.

--execute: performs the delete. Per SKILL.md safety gates, only run this
after the dry-run counts have been shown to the user and acked.
EOF
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

EXECUTE=0
for arg in "$@"; do
    case "${arg}" in
        --execute) EXECUTE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) err "unrecognised flag: ${arg}"; usage; exit 1 ;;
    esac
done

# --- Resolve connection params from env, with fallbacks -----------------------
DB_HOST_RAW="${WORDPRESS_DB_HOST:-${MYSQL_HOST:-}}"
DB_USER="${WORDPRESS_DB_USER:-${MYSQL_USER:-}}"
DB_PASSWORD="${WORDPRESS_DB_PASSWORD:-${MYSQL_PASSWORD:-}}"
DB_NAME="${WORDPRESS_DB_NAME:-${MYSQL_DATABASE:-wordpress}}"
TABLE_PREFIX="${WORDPRESS_TABLE_PREFIX:-wp_}"

missing=()
[[ -n "${DB_HOST_RAW}" ]] || missing+=("WORDPRESS_DB_HOST (or MYSQL_HOST)")
[[ -n "${DB_USER}" ]]     || missing+=("WORDPRESS_DB_USER (or MYSQL_USER)")
[[ -n "${DB_PASSWORD}" ]] || missing+=("WORDPRESS_DB_PASSWORD (or MYSQL_PASSWORD)")
if (( ${#missing[@]} > 0 )); then
    err "missing env: ${missing[*]}"
    err "discover the injected names with: env | grep -iE 'wordpress|mysql|maria|host'"
    exit 1
fi

# WordPress allows WORDPRESS_DB_HOST of the form host:port — split it.
DB_HOST="${DB_HOST_RAW%%:*}"
DB_PORT=3306
if [[ "${DB_HOST_RAW}" == *:* ]]; then
    DB_PORT="${DB_HOST_RAW##*:}"
fi

# The prefix is interpolated into SQL — accept only sane identifiers.
if [[ ! "${TABLE_PREFIX}" =~ ^[A-Za-z0-9_]+$ ]]; then
    err "refusing table prefix '${TABLE_PREFIX}' — expected only [A-Za-z0-9_]"
    exit 1
fi
T="${TABLE_PREFIX}options"

if ! command -v mysql >/dev/null 2>&1; then
    err "mysql client not found on PATH. The wordpress plugin's install.sh"
    err "installs it on container start; if it is missing, re-run the plugin"
    err "install hook or apt-get install default-mysql-client, then retry."
    exit 1
fi

export MYSQL_PWD="${DB_PASSWORD}"
sql() {
    # -N: no headers, -B: batch/tab output. Password comes from MYSQL_PWD —
    # never on the command line, never printed.
    mysql --connect-timeout=5 -N -B \
        -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" "${DB_NAME}" -e "$1"
}

log "Connecting to ${DB_NAME}@${DB_HOST}:${DB_PORT} as ${DB_USER} (password from env, not shown)"
if ! sql "SELECT 1" >/dev/null 2>&1; then
    err "cannot reach MySQL/MariaDB at ${DB_HOST}:${DB_PORT} as ${DB_USER}."
    err "This script is TCP-only and cannot proceed. Check:"
    err "  - is the DB sibling container up? (curl the wordpress sibling; check pod status)"
    err "  - are the env var names right? env | grep -iE 'wordpress|mysql|maria|host'"
    err "  - Shape B runs MySQL 8 (caching_sha2_password default) — if auth fails"
    err "    only from here, the installed client may lack that auth plugin."
    exit 2
fi

if [[ -z "$(sql "SHOW TABLES LIKE '${T}'")" ]]; then
    err "table '${T}' not found in ${DB_NAME} — wrong prefix or wrong database."
    err "List candidates with: SHOW TABLES LIKE '%options'"
    exit 2
fi

# --- SQL --------------------------------------------------------------------
# '_transient_timeout_' is 19 chars → key starts at 20.
# '_site_transient_timeout_' is 24 chars → key starts at 25.
# \_ escapes the LIKE wildcard so literal underscores match only themselves.
# The REGEXP guard keeps VALUE rows out of the timeout predicate: a transient
# whose own key begins with 'timeout_' has a value row whose NAME matches the
# timeout LIKE pattern but whose serialized value CASTs to 0 — only rows whose
# value is a pure Unix-timestamp integer are real timeout rows.
WHERE_EXPIRED="t.option_value REGEXP '^[0-9]+\$' AND CAST(t.option_value AS UNSIGNED) < UNIX_TIMESTAMP()"

COUNT_SQL="
SELECT
  (SELECT COUNT(*) FROM ${T}) AS total_rows,
  (SELECT COUNT(*) FROM ${T} t
     WHERE t.option_name LIKE '\_transient\_timeout\_%' AND ${WHERE_EXPIRED}) AS expired_timeouts,
  (SELECT COUNT(*) FROM ${T} t JOIN ${T} v
       ON v.option_name = CONCAT('_transient_', SUBSTRING(t.option_name, 20))
     WHERE t.option_name LIKE '\_transient\_timeout\_%' AND ${WHERE_EXPIRED}) AS expired_values,
  (SELECT COUNT(*) FROM ${T} t
     WHERE t.option_name LIKE '\_site\_transient\_timeout\_%' AND ${WHERE_EXPIRED}) AS expired_site_timeouts,
  (SELECT COUNT(*) FROM ${T} t JOIN ${T} v
       ON v.option_name = CONCAT('_site_transient_', SUBSTRING(t.option_name, 25))
     WHERE t.option_name LIKE '\_site\_transient\_timeout\_%' AND ${WHERE_EXPIRED}) AS expired_site_values;
"

DELETE_TRANSIENTS="DELETE t, v FROM ${T} t
  LEFT JOIN ${T} v ON v.option_name = CONCAT('_transient_', SUBSTRING(t.option_name, 20))
  WHERE t.option_name LIKE '\_transient\_timeout\_%'
    AND ${WHERE_EXPIRED};"

DELETE_SITE_TRANSIENTS="DELETE t, v FROM ${T} t
  LEFT JOIN ${T} v ON v.option_name = CONCAT('_site_transient_', SUBSTRING(t.option_name, 25))
  WHERE t.option_name LIKE '\_site\_transient\_timeout\_%'
    AND ${WHERE_EXPIRED};"

read_counts() {
    local row
    row="$(sql "${COUNT_SQL}")" || return 1
    IFS=$'\t' read -r C_TOTAL C_EXP_T C_EXP_V C_EXP_ST C_EXP_SV <<< "${row}"
    C_DELETABLE=$(( C_EXP_T + C_EXP_V + C_EXP_ST + C_EXP_SV ))
}

if ! read_counts; then
    err "count query failed"
    exit 2
fi

log "Counts BEFORE (table ${T}):"
printf '  %-42s %s\n' \
    "total option rows:"                       "${C_TOTAL}" \
    "expired _transient_timeout_ rows:"        "${C_EXP_T}" \
    "  ... their _transient_ value partners:"  "${C_EXP_V}" \
    "expired _site_transient_timeout_ rows:"   "${C_EXP_ST}" \
    "  ... their _site_transient_ partners:"   "${C_EXP_SV}" \
    "TOTAL rows to delete:"                    "${C_DELETABLE}"

if (( C_DELETABLE == 0 )); then
    log "Nothing expired — no action needed."
    log "(0 rows on a busy site can also mean an object-cache drop-in holds the"
    log " transients outside the DB — see reference/caching.md.)"
    exit 0
fi

if (( EXECUTE == 0 )); then
    log "DRY RUN — nothing deleted. The statements --execute would run:"
    printf '\n%s\n\n%s\n\n' "${DELETE_TRANSIENTS}" "${DELETE_SITE_TRANSIENTS}"
    log "Per the SKILL.md safety gates (multi-row DELETE on ${T}): show the"
    log "counts above to the user, get their ack, then re-run with --execute."
    exit 0
fi

log "Executing delete of ${C_DELETABLE} expired-transient rows..."
if ! sql "${DELETE_TRANSIENTS}"; then
    err "DELETE (regular transients) failed — table unchanged or partially cleaned; re-run dry-run to see current state"
    exit 3
fi
if ! sql "${DELETE_SITE_TRANSIENTS}"; then
    err "DELETE (site transients) failed after regular transients were cleaned; re-run dry-run to see current state"
    exit 3
fi

if ! read_counts; then
    err "post-delete count query failed — verify manually with a dry-run"
    exit 2
fi

log "Counts AFTER:"
printf '  %-42s %s\n' \
    "total option rows:"          "${C_TOTAL}" \
    "expired rows remaining:"     "${C_DELETABLE}"

if (( C_DELETABLE > 0 )); then
    log "NOTE: ${C_DELETABLE} expired rows remain — transients can legitimately"
    log "expire while the delete runs. Re-run if the number is large."
fi
log "Done."
