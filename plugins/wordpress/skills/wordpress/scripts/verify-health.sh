#!/usr/bin/env bash
# WordPress DevOps Skill — verify-health.sh
#
# Reports the health of a WordPress instance from the Magneto Agent
# container's perspective, using ONLY the channels that always exist —
# HTTP (curl) and TCP mysql. No shell is assumed and none is probed.
# Combines:
#   - [HTTP]      front page: status, not the browser-installer page,
#                 not the .maintenance holding page
#   - [TCP-mysql] connectivity (SELECT 1) + engine version
#   - [TCP-mysql] install state via the options table; siteurl/home printed
#   - [TCP-mysql] db_version printed (code version is NOT in the DB —
#                 opportunistic hint from the HTTP meta generator only)
#   - [TCP-mysql] wp-cron staleness hint (timestamps inside the cron option)
#   - [TCP-mysql] active plugin count (from the active_plugins option)
#
# Read-only: this script does not change anything.
#
# Why this matters on the Clouve-packaged shape: the installer entrypoint
# runs `set +e`, so a half-failed install still execs Apache — a "running"
# pod does not mean a healthy install (see ../SKILL.md).
#
# Env vars read (names vary per deployment — discover with
# `env | grep -iE 'wordpress|mysql|maria|host'` if defaults don't resolve):
#   WORDPRESS_HOST           — pod-internal hostname of the WordPress sibling
#                              (default: wordpress)
#   WORDPRESS_DB_HOST        — pod-internal hostname of the DB sibling (required)
#   WORDPRESS_DB_PASSWORD    — DB password (required; never printed)
#   WORDPRESS_DB_USER        — DB user (default: wordpress)
#   WORDPRESS_DB_NAME        — DB name (default: wordpress)
#   WORDPRESS_TABLE_PREFIX   — table prefix (default: wp_)
#   WORDPRESS_SITE_URL       — if set (Clouve-packaged shape), compared
#                              against the DB siteurl
#
# Exit codes:
#   0 — all green
#   1 — required env missing
#   2 — at least one check returned WARN
#   3 — at least one check returned FAIL

set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [-h|--help]

Reports the health of the WordPress instance via several independent probes.
Read-only; TCP/HTTP only; does not mutate state.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage; exit 0
fi

: "${WORDPRESS_DB_HOST:?WORDPRESS_DB_HOST not set — run: env | grep -iE 'wordpress|mysql|maria|host'}"
: "${WORDPRESS_DB_PASSWORD:?WORDPRESS_DB_PASSWORD not set}"
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

P="${WORDPRESS_TABLE_PREFIX}"
if [[ ! "${P}" =~ ^[A-Za-z0-9_]+$ ]]; then
    printf 'ERROR: WORDPRESS_TABLE_PREFIX contains unexpected characters; refusing to interpolate it into SQL\n' >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/wp-health.XXXXXX")
trap 'rm -rf "${tmp}"' EXIT

worst=0
report=()

check() {
    # check <label> <status: OK|WARN|FAIL> <detail>
    local label="$1" status="$2" detail="$3"
    case "${status}" in
        OK)   ;;
        WARN) (( worst < 2 )) && worst=2 ;;
        FAIL) worst=3 ;;
    esac
    report+=("$(printf '%-26s %-4s %s' "${label}" "${status}" "${detail}")")
}

mysql_q() {
    # mysql_q <sql> [errfile]
    MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql \
        -h "${DB_HOST}" -P "${DB_PORT}" -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" \
        -sN --connect-timeout=5 -e "$1" 2>"${2:-/dev/null}"
}

# --- 1. [HTTP] Front page: status + which page it actually is.
body="${tmp}/body"
probe=$(curl -s -o "${body}" -w '%{http_code} %{redirect_url}' --max-time 10 \
    "http://${WORDPRESS_HOST}/" || echo "000 ")
http_code="${probe%% *}"
redirect_url="${probe#* }"

case "${http_code}" in
    200)
        if grep -qiE 'wp-admin/install\.php|WordPress[^<]*Installation' "${body}"; then
            check "http_front_page" "FAIL" "200 but serving the browser INSTALLER — site is not installed"
        else
            check "http_front_page" "OK" "200"
        fi
        ;;
    301|302|307|308)
        if [[ "${redirect_url}" == *install.php* ]]; then
            check "http_front_page" "FAIL" "${http_code} → browser installer (site not installed)"
        else
            check "http_front_page" "OK" "${http_code} → ${redirect_url} (canonical redirect to siteurl — normal when probing the pod-internal hostname)"
        fi
        ;;
    503)
        if grep -q 'Briefly unavailable for scheduled maintenance' "${body}"; then
            check "http_front_page" "FAIL" "503 — .maintenance file present (interrupted update?); removal needs a file channel, see ../reference/troubleshooting.md"
        else
            check "http_front_page" "WARN" "503 (container starting, or upstream error)"
        fi
        ;;
    500)
        check "http_front_page" "FAIL" "500 — see ../playbooks/diagnose-500.md"
        ;;
    000)
        check "http_front_page" "FAIL" "no response from ${WORDPRESS_HOST}:80 (container down or hostname wrong — discover with: env | grep -iE 'wordpress|host')"
        ;;
    *)
        check "http_front_page" "FAIL" "${http_code}"
        ;;
esac

# --- 2. [TCP-mysql] Connectivity + engine version. The packaged shape's
#     MariaDB image tag floats, so the live engine version is worth printing
#     every time rather than assuming.
ping=$(mysql_q "SELECT 1" "${tmp}/db_err" || echo "")
if [[ "${ping}" != "1" ]]; then
    detail="unreachable"
    grep -qi 'access denied' "${tmp}/db_err" 2>/dev/null && detail="access denied (credentials)"
    check "db_connect" "FAIL" "${detail} (${WORDPRESS_DB_NAME}@${WORDPRESS_DB_HOST})"
else
    engine=$(mysql_q "SELECT VERSION()" || echo "unknown")
    check "db_connect" "OK" "SELECT 1 ok, engine=${engine}"
fi

# --- 3. [TCP-mysql] Install state. Install state IS the options table on
#     these deployments (no marker file): if ${P}options is missing or empty,
#     WordPress is not installed — matching what the packaged entrypoint
#     itself probes (against the hardcoded wp_ prefix; principle 10).
siteurl=""; home_url=""
opt_count=$(mysql_q "SELECT COUNT(*) FROM ${P}options" "${tmp}/opt_err" || echo "")
if [[ -z "${opt_count}" ]]; then
    if grep -qi "doesn't exist" "${tmp}/opt_err" 2>/dev/null; then
        check "install_state" "FAIL" "${P}options table does not exist — not installed (or wrong WORDPRESS_TABLE_PREFIX)"
    else
        check "install_state" "FAIL" "could not read ${P}options"
    fi
elif (( opt_count == 0 )); then
    check "install_state" "FAIL" "${P}options is empty — install did not complete"
else
    check "install_state" "OK" "${P}options has ${opt_count} rows"
    siteurl=$(mysql_q "SELECT option_value FROM ${P}options WHERE option_name='siteurl'" || echo "")
    home_url=$(mysql_q "SELECT option_value FROM ${P}options WHERE option_name='home'" || echo "")
    check "siteurl" "$( [[ -n "${siteurl}" ]] && echo OK || echo WARN )" "${siteurl:-missing}"
    check "home" "$( [[ -n "${home_url}" ]] && echo OK || echo WARN )" "${home_url:-missing}"
    # On the Clouve-packaged shape the entrypoint re-asserts both options from
    # WORDPRESS_SITE_URL at every boot — a mismatch here means a hand edit that
    # will silently revert, or a pending platform-side URL change.
    if [[ -n "${WORDPRESS_SITE_URL:-}" && -n "${siteurl}" && "${WORDPRESS_SITE_URL}" != "${siteurl}" ]]; then
        check "siteurl_vs_env" "WARN" "DB siteurl differs from WORDPRESS_SITE_URL env — the env reconciler wins at next boot (see ../playbooks/change-site-url.md)"
    fi
fi

# --- 4. [TCP-mysql] db_version. The CODE version is not in the DB; the meta
#     generator tag on the front page is an opportunistic hint only (many
#     sites strip it). The code↔db_version invariant is in ../reference/upgrade.md.
db_version=$(mysql_q "SELECT option_value FROM ${P}options WHERE option_name='db_version'" || echo "")
if [[ -n "${db_version}" ]]; then
    check "db_version" "OK" "${db_version}"
else
    check "db_version" "WARN" "db_version row missing/unreadable"
fi
code_hint=$(grep -oiE '<meta name="generator" content="WordPress [0-9.]+' "${body}" 2>/dev/null \
    | grep -oE '[0-9.]+$' | head -n 1 || true)
if [[ -n "${code_hint}" ]]; then
    check "code_version_hint" "OK" "${code_hint} (from HTTP meta generator)"
else
    check "code_version_hint" "OK" "not exposed over HTTP (common hardening; not a fault)"
fi

# --- 5. [TCP-mysql] wp-cron staleness HINT. There is no system cron in
#     either image — wp-cron fires on HTTP traffic only, so overdue events on
#     a quiet site are expected, not a bug (../reference/cron-and-tasks.md).
#     Heuristic: the cron option is a serialized array keyed by due-time
#     epochs; we extract 10-digit ints without parsing PHP serialization.
cron_raw=$(mysql_q "SELECT option_value FROM ${P}options WHERE option_name='cron'" || echo "")
next_ts=$(printf '%s' "${cron_raw}" | grep -oE 'i:1[0-9]{9}' | cut -c3- | sort -n | head -n 1 || true)
now=$(date +%s)
if [[ -z "${next_ts}" ]]; then
    check "cron_staleness" "WARN" "cron option missing/unparseable (hint only)"
elif (( next_ts > now )); then
    check "cron_staleness" "OK" "next event due in $(( next_ts - now ))s"
else
    overdue=$(( now - next_ts ))
    if (( overdue < 600 )); then
        check "cron_staleness" "OK" "events due ${overdue}s ago (will fire on the next HTTP hit)"
    else
        check "cron_staleness" "WARN" "earliest event overdue by ${overdue}s — quiet site, or cron is stuck (hint only; wp-cron is traffic-driven)"
    fi
fi

# --- 6. [TCP-mysql] Active plugin count, read from the serialization header
#     of the active_plugins option (a:N:{...}). Plugin FILES live on disk —
#     the DB only knows the active list, so this cannot count installed-but-
#     inactive plugins. Never hand-edit this blob (../reference/data-model.md).
ap=$(mysql_q "SELECT option_value FROM ${P}options WHERE option_name='active_plugins'" || echo "")
if [[ -z "${ap}" ]]; then
    check "active_plugins" "WARN" "option missing/unreadable"
else
    ap_count=$(printf '%s' "${ap}" | sed -n 's/^a:\([0-9][0-9]*\):.*/\1/p')
    if [[ -n "${ap_count}" ]]; then
        check "active_plugins" "OK" "${ap_count} active (DB knows the active list only, not what is installed on disk)"
    else
        check "active_plugins" "WARN" "unparseable serialized value — inspect, do not edit"
    fi
fi

# --- Output
printf '\nWordPress health report — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'site: http://%s/ (pod-internal)\n' "${WORDPRESS_HOST}"
printf 'db:   %s@%s  prefix: %s\n\n' "${WORDPRESS_DB_NAME}" "${WORDPRESS_DB_HOST}" "${P}"
for line in "${report[@]}"; do
    printf '%s\n' "${line}"
done
printf '\n'

case "${worst}" in
    0) printf 'Overall: GREEN\n' ;;
    2) printf 'Overall: AMBER (one or more WARN)\n' ;;
    3) printf 'Overall: RED (one or more FAIL)\n' ;;
esac
exit "${worst}"
