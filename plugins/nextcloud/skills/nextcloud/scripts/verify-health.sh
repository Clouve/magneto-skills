#!/usr/bin/env bash
# Nextcloud DevOps Skill: verify-health.sh
#
# A read-only health report for the Nextcloud deployment, from the Magneto Agent's side: GREEN, AMBER
# or RED. Run it first when something seems wrong. It changes nothing: it reads with occ, asks the web
# server for two public pages, runs SELECT 1 on the database, and looks at a few files and disks over ssh.
#
# Usage: verify-health.sh [-h|--help]
#
# The report is a title line with the UTC time, the host lines, one line per check (the label in 26
# columns, OK, WARN or FAIL in 4, then the detail), and Overall. The checks, in the order they are printed.
# (s) marks a check that needs ssh to the Nextcloud container and is skipped when ssh_nextcloud fails. (o)
# marks one that reads with occ there, and is skipped when occ_status fails too:
#
#   ssh_nextcloud      ssh to the Nextcloud container works. It is tried with `occ.sh status --output=json`:
#                      "could not reach", or no answer within 60 s, is FAIL, and the checks marked (s) or (o)
#                      are skipped. The others still run.
#   occ_status (s)     occ answers that command (the last line of its output that starts with {). If ssh works
#                      and occ doesn't (PHP can't start, config.php can't be read), FAIL with occ's first
#                      line, and the checks marked (o) are skipped. Those marked (s) go on, so the cause still
#                      shows: an interrupted restore can leave PHP unable to start, and its marker is reported.
#   installed (o)      true, else FAIL.
#   maintenance (o)    off is OK; on is WARN (users see a maintenance page).
#   needs_db_upgrade (o)  no is OK; yes is FAIL (an upgrade is pending: playbooks/recover-stuck-upgrade-or-maintenance.md).
#   version (o)        OK, with the versionstring.
#   http_status        GET /status.php over HTTP to NEXTCLOUD_HOST with the public Host header (the host of
#                      NEXTCLOUD_URL). 200 with "installed":true is OK. 400 is FAIL: the host is not in
#                      trusted_domains. Anything else is FAIL, with the code.
#   http_login_page    GET /login, same Host. 200 is OK, else FAIL. The one exception: a 503 while status.php
#                      says maintenance mode is on is WARN, since Nextcloud answers every page but status.php
#                      with 503 then, and the maintenance check already warns about it.
#   database_tcp       mysql SELECT 1 over TCP to NEXTCLOUD_DB_HOST, TLS off, and no option files (--no-defaults:
#                      a password= in ~/.my.cnf would beat MYSQL_PWD): 1 is OK, else FAIL.
#   ssh_database       `true` over ssh to the database container: OK, else WARN (only diagnostics need it).
#   restore_marker (s) data/clouve-backups/RESTORE-IN-PROGRESS exists: FAIL (a restore is running or was
#                      interrupted: restore.sh keeps it while it runs, and leaves it, and maintenance mode on, when it stops half way).
#   init_lock (s)      the image's init lock (/var/www/html/nextcloud-init-sync.lock) is held: WARN. An install, an
#                      upgrade or its recovery (at start, or through occ.sh --init-lock), a backup or a restore holds it,
#                      and the container's health probe reports healthy meanwhile, so this is why the site may be down or
#                      in maintenance mode. A lock path that is not a plain file is WARN, and is not opened.
#   valkey (s)         `valkey-cli ping` on the socket the image makes, as www-data: PONG is OK, else FAIL.
#   cron_last_run (o)  the container's clock minus occ's core lastcron: up to 900 s is OK, up to 3600 s WARN,
#                      more is FAIL. A key that was never stored (or is empty or 0) is FAIL, never ran.
#   background_jobs_mode (o)  core backgroundjobs_mode: cron is OK, else WARN.
#   setup_checks (o)   `occ setupchecks --output=json`, under timeout 180: any error or warning is WARN, with
#                      the names of up to 8 of them and then +N more. Otherwise OK, with the info count.
#                      Skipped (WARN) in maintenance mode and with an upgrade pending: occ then loads no apps
#                      and the checks call the site, which answers 503. occ exits 1 whenever a result is not
#                      success, info included, so the exit code means nothing here and the JSON is read.
#   disk_nextcloud (s) df -P /var/www/html in the Nextcloud container: under 85% used is OK, under 95% WARN,
#                      else FAIL.
#   disk_database      df -P /var/lib/mysql in the database container: the same, and WARN when ssh to it fails.
#   url_setting (o)    occ's overwrite.cli.url equals NEXTCLOUD_URL: OK, else WARN (the image sets it from
#                      NEXTCLOUD_URL, so it changes when the container next starts).
#
# A check that can't be made is never reported OK. It is a WARN that says it could not check, with the reason,
# except where the failing probe is the finding itself (the two pages, the database, Valkey): that is a FAIL.
# Every occ.sh, ssh and mysql call runs under `timeout -k 5` (60 s, setupchecks 180 s, mysql 30 s): a command that
# ignores TERM is killed 5 seconds later, and timeout then exits 137, which counts as a timeout too. curl runs
# under -m. So the report always ends. occ.sh and every ssh call here use the options in lib/nextcloud-ssh.sh:
# the host keys of the containers change at every start, so no known_hosts file is kept.
#
# Env vars read:
#   NEXTCLOUD_HOST          pod-internal hostname of the Nextcloud container (ssh, and the pages over HTTP)
#   NEXTCLOUD_URL           the public address, https://host: its host is the Host header, and url_setting
#                           compares overwrite.cli.url with it
#   NEXTCLOUD_DB_HOST       the database's address for mysql
#   NEXTCLOUD_DB_NAME, NEXTCLOUD_DB_USER
#   NEXTCLOUD_MARIADB_HOST  the database container's host name for ssh; defaults to NEXTCLOUD_DB_HOST. It is the
#                           only variable read from the database container: its PID 1 runs as the mysql user,
#                           and root can't read that process's environment.
#   NEXTCLOUD_DB_PASSWORD and CLOUVE_OPS_PASSWORD
#                           the passwords. A current agent keeps them out of the environment; the loader lines
#                           below fetch them then. The database password goes to mysql in MYSQL_PWD and
#                           the ops password to sshpass in SSHPASS, each set on that one command and never exported.
#   TMPDIR                  where the temporary folder goes (default /tmp); it is removed when the script ends
#
# Exit codes:
#   0   GREEN: every check is OK
#   2   AMBER: at least one WARN, no FAIL
#   3   RED: at least one FAIL
#   1   a required setting is missing or malformed, a password is missing, or a tool is not installed
#   64  usage

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the passwords.
set +x

usage() {
    cat <<'EOF'
Usage: verify-health.sh [-h|--help]

Reports the health of the Nextcloud deployment in one read-only pass, and changes nothing: occ for the
instance's own state, two public pages over HTTP, SELECT 1 on the database, the restore marker, the init
lock, Valkey, cron, the setup checks, disk use and the URL setting. Each check is OK, WARN or FAIL.

Prints a title line, the hosts, one line per check, then Overall: GREEN, AMBER (one or more WARN) or RED
(one or more FAIL). Exit codes: 0 GREEN, 2 AMBER, 3 RED, 1 a missing setting, password or tool, 64 usage.

Needs NEXTCLOUD_HOST, NEXTCLOUD_URL, NEXTCLOUD_DB_HOST, NEXTCLOUD_DB_NAME and NEXTCLOUD_DB_USER, and the
database password and the clouve-ops password the agent holds. NEXTCLOUD_MARIADB_HOST (the database
container, for ssh) defaults to NEXTCLOUD_DB_HOST.
EOF
}

msg() { printf '[nextcloud/verify-health] %s\n' "$*" >&2; }

die() {
    local code="$1"
    shift
    msg "$@"
    exit "${code}"
}

if [ "$#" -gt 0 ]; then
    case "$1" in
        -h | --help) usage; exit 0 ;;
        *) msg "unknown argument: $1"; usage >&2; exit 64 ;;
    esac
fi

# ---------------------------------------------------------------------------
# The environment
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/nextcloud-ssh.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/nextcloud-ssh.sh" || exit 1
mapfile -t ssh_opts < <(nc_ssh_options)

for var in NEXTCLOUD_HOST NEXTCLOUD_URL NEXTCLOUD_DB_HOST NEXTCLOUD_DB_NAME NEXTCLOUD_DB_USER; do
    [ -n "${!var:-}" ] || die 1 "${var} is not set"
done
db_ssh_host="${NEXTCLOUD_MARIADB_HOST:-${NEXTCLOUD_DB_HOST}}"

re_host='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
re_authority='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'
re_name='^[A-Za-z0-9_][A-Za-z0-9_.@-]*$'
[[ "${NEXTCLOUD_HOST}" =~ ${re_host} ]] || die 1 "NEXTCLOUD_HOST must be a plain host name like tkt-7-nextcloud"
[[ "${NEXTCLOUD_DB_HOST}" =~ ${re_host} ]] || die 1 "NEXTCLOUD_DB_HOST must be a plain host name like nextcloud-mariadb"
[[ "${db_ssh_host}" =~ ${re_host} ]] || die 1 "NEXTCLOUD_MARIADB_HOST must be a plain host name like tkt-7-nextcloud-mariadb"
[[ "${NEXTCLOUD_DB_NAME}" =~ ${re_name} ]] || die 1 "NEXTCLOUD_DB_NAME must be a plain database name like nextcloud"
[[ "${NEXTCLOUD_DB_USER}" =~ ${re_name} ]] || die 1 "NEXTCLOUD_DB_USER must be a plain user name like nextcloud"
# The public host is the Host header of the probes. A port stays in it; a user:password@ in front is refused.
public_host="${NEXTCLOUD_URL#*://}"
public_host="${public_host%%[/?#]*}"
[[ "${public_host}" =~ ${re_authority} ]] || die 1 "NEXTCLOUD_URL must look like https://cloud.example.com"

for tool in jq curl mysql sshpass ssh timeout mktemp; do
    command -v "${tool}" > /dev/null 2>&1 || die 1 "${tool} is not installed (the nextcloud plugin's install.sh adds jq, curl, mysql, sshpass and ssh)"
done

: "${NEXTCLOUD_DB_PASSWORD:=$(clv-secret NEXTCLOUD_DB_PASSWORD)}"
: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
[ -n "${NEXTCLOUD_DB_PASSWORD}" ] || die 1 "NEXTCLOUD_DB_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
[ -n "${CLOUVE_OPS_PASSWORD}" ] || die 1 "CLOUVE_OPS_PASSWORD is not set; clv-secret --list shows the passwords this agent has"

# One private folder for the page body and the error streams. It goes when the script ends. Bash runs the EXIT trap
# also when SIGHUP, SIGINT or SIGTERM ends the script: at once for SIGHUP and SIGTERM, and for SIGINT when the command
# it is running ends. Only SIGKILL leaves the folder, which holds nothing secret.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-health.XXXXXX")" || die 1 "could not make a temporary folder"
trap 'rm -rf -- "${work_dir}"' EXIT

marker_path=/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
lock_path=/var/www/html/nextcloud-init-sync.lock
valkey_socket=/run/clouve/valkey/valkey.sock

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
worst=0
report=()
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# tidy TEXT: TEXT on one line, with the passwords blanked out and cut at 240 characters. Every word of a tool's that
# reaches the report goes through this.
tidy() {
    local t="$1"
    t="${t//[[:cntrl:]]/ }"
    if [ "${#NEXTCLOUD_DB_PASSWORD}" -ge 6 ]; then t="${t//"${NEXTCLOUD_DB_PASSWORD}"/[hidden]}"; fi
    if [ "${#CLOUVE_OPS_PASSWORD}" -ge 6 ]; then t="${t//"${CLOUVE_OPS_PASSWORD}"/[hidden]}"; fi
    if [ "${#t}" -gt 240 ]; then t="${t:0:237}..."; fi
    printf '%s' "${t}"
}

# check LABEL OK|WARN|FAIL DETAIL: adds a line to the report and raises the worst status
check() {
    local label="$1" status="$2" detail
    case "${status}" in
        OK) ;;
        WARN) [ "${worst}" -ge 2 ] || worst=2 ;;
        FAIL) worst=3 ;;
    esac
    detail="$(tidy "$3")"
    report+=("$(printf '%-26s %-4s %s' "${label}" "${status}" "${detail}")")
}

# first_line TEXT and last_line TEXT
first_line() { local t="$1"; printf '%s' "${t%%$'\n'*}"; }
last_line() { local t="$1"; printf '%s' "${t##*$'\n'}"; }

# timed_out CODE: timeout stopped the command for taking too long. It exits 124, or 137 (128 + 9) when the command ignored
# TERM and was killed 5 seconds later (timeout -k 5).
timed_out() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }

# last_json_line TEXT: the last line of TEXT that starts with {, which is how occ --output=json ends (it may
# print a notice or a PHP warning before)
last_json_line() {
    local line found=""
    while IFS= read -r line; do
        case "${line}" in '{'*) found="${line}" ;; esac
    done <<< "$1"
    printf '%s' "${found}"
}

# without_notices TEXT: occ's stderr without the notices its loader writes in maintenance mode and with an upgrade pending
# (lib/private/Console/Application.php, v35.0.2). occ.sh passes --no-warnings, which silences these; they are filtered in
# case that changes. What is left is a real error.
without_notices() {
    local line out=""
    while IFS= read -r line; do
        case "${line}" in
            '' | 'Nextcloud is in maintenance mode'* | 'Commands provided by'* | 'Nextcloud or one of the apps require upgrade'* | 'You may use your browser or the occ upgrade'*) ;;
            *) out+="${line}"$'\n' ;;
        esac
    done <<< "$1"
    printf '%s' "${out%$'\n'}"
}

# scalar_of TEXT: the value a config read printed: the last line of TEXT that is not a PHP warning, notice or deprecation,
# with the blanks around it taken off. One stray line next to the value must not turn the read into a warning.
scalar_of() {
    local line found=""
    while IFS= read -r line; do
        case "${line}" in
            'PHP Warning:'* | 'PHP Notice:'* | 'PHP Deprecated:'* | 'Warning:'* | 'Notice:'* | 'Deprecated:'*) ;;
            *) found="${line}" ;;
        esac
    done <<< "$1"
    found="${found#"${found%%[![:space:]]*}"}"
    found="${found%"${found##*[![:space:]]}"}"
    printf '%s' "${found}"
}

# occ_run SECONDS ARGS...: occ.sh under timeout -k 5. Leaves the exit code in occ_rc, stdout in occ_out, the value a config
# read printed in occ_val, and stderr, without occ's notices, in occ_err. CLOUVE_OPS_PASSWORD goes to occ.sh in its
# environment, so it doesn't ask clv-secret again.
occ_run() {
    local limit="$1"
    shift
    occ_out="$(CLOUVE_OPS_PASSWORD="${CLOUVE_OPS_PASSWORD}" timeout -k 5 "${limit}" "${script_dir}/occ.sh" "$@" 2> "${work_dir}/occ.err")"
    occ_rc=$?
    occ_err="$(without_notices "$(< "${work_dir}/occ.err")")"
    occ_val="$(scalar_of "${occ_out}")"
}

# occ_key_unset: the last occ_run was a config:*:get of a key that is not stored (exit 1, no value, no error)
occ_key_unset() { [ "${occ_rc}" -eq 1 ] && [ -z "${occ_val}" ] && [ -z "${occ_err}" ]; }

# ssh_run HOST COMMAND: COMMAND on clouve-ops@HOST under timeout -k 5 60, stdin closed. Leaves the exit code in ssh_rc,
# stdout in ssh_out and stderr in ssh_err. SSHPASS is set on the sshpass command only.
ssh_run() {
    ssh_out="$(SSHPASS="${CLOUVE_OPS_PASSWORD}" timeout -k 5 60 sshpass -e ssh -n "${ssh_opts[@]}" "clouve-ops@$1" "$2" 2> "${work_dir}/ssh.err")"
    ssh_rc=$?
    ssh_err="$(< "${work_dir}/ssh.err")"
}

# why TEXT_OUT TEXT_ERR: the reason a command gave for failing, in few words: the first line of its stderr, else of
# its stdout, cut at 120 characters so that what the caller adds after it still fits in a report line
why() {
    local t="${2:-}"
    [ -n "${t}" ] || t="${1:-}"
    t="$(first_line "${t}")"
    if [ "${#t}" -gt 120 ]; then t="${t:0:117}..."; fi
    printf '%s' "${t}"
}

# curl_reason CODE: what curl's exit code means
curl_reason() {
    case "$1" in
        0) printf 'no HTTP status' ;;
        6) printf 'curl exit 6: could not resolve the host' ;;
        7) printf 'curl exit 7: connection refused' ;;
        28) printf 'curl exit 28: timed out' ;;
        52) printf 'curl exit 52: empty reply' ;;
        56) printf 'curl exit 56: connection reset' ;;
        *) printf 'curl exit %s' "$1" ;;
    esac
}

# http_get PATH BODY_FILE: GET http://NEXTCLOUD_HOST/PATH with the public Host header. -q keeps ~/.curlrc out and
# --noproxy '*' keeps a proxy variable out, so nothing but this request is made, and to this host. Leaves the status
# in http_code (000 when nothing answered) and curl's exit code in http_rc.
http_get() {
    http_code="$(curl -q -s -m 15 --noproxy '*' -o "$2" -w '%{http_code}' -H "Host: ${public_host}" "http://${NEXTCLOUD_HOST}$1")"
    http_rc=$?
    [[ "${http_code}" =~ ^[0-9]{3}$ ]] || http_code=000
}

# disk_check LABEL HOST PATH: df -P PATH on HOST. Under 85% used is OK, under 95% WARN, else FAIL.
disk_check() {
    local label="$1" host="$2" path="$3" line total used avail pct tenths free_gb detail
    ssh_run "${host}" "df -P ${path}"
    if [ "${ssh_rc}" -ne 0 ]; then
        check "${label}" WARN "could not read df on ${host} (exit ${ssh_rc}): $(why "${ssh_out}" "${ssh_err}")"
        return
    fi
    line="$(last_line "${ssh_out}")"
    read -r _ total used avail pct _ <<< "${line}"
    # avail goes into arithmetic: up to 15 digits, so that it can't overflow, and 10# below so that a leading zero is not read as octal
    if ! [[ "${total:-}" =~ ^[0-9]+$ && "${used:-}" =~ ^[0-9]+$ && "${avail:-}" =~ ^[0-9]{1,15}$ && "${pct:-}" =~ ^[0-9]{1,3}%$ ]]; then
        check "${label}" WARN "could not read df on ${host}: ${line:-no output}"
        return
    fi
    pct="${pct%\%}"
    tenths=$((10#${avail} * 10 / 1048576))
    free_gb="$((tenths / 10)).$((tenths % 10))"
    detail="${pct}% used, ${free_gb} GB free"
    if [ "${pct}" -lt 85 ]; then
        check "${label}" OK "${detail}"
    elif [ "${pct}" -lt 95 ]; then
        check "${label}" WARN "${detail}"
    else
        check "${label}" FAIL "${detail}; see playbooks/free-up-space.md"
    fi
}

# ---------------------------------------------------------------------------
# 1. ssh_nextcloud, and the flags occ status gives
# ---------------------------------------------------------------------------
# ssh_up: ssh to the Nextcloud container works. nc_up: and occ answers there. `occ.sh status` is the probe for both. It says
# "could not reach" only after a second, plain ssh call failed too, so any other way for it to fail means that ssh works.
ssh_up=0
nc_up=0
status_json=""
occ_run 60 status --output=json
status_line="$(last_json_line "${occ_out}")"
if timed_out "${occ_rc}"; then
    check ssh_nextcloud FAIL "occ status gave no answer in 60 s; the checks that need the container were skipped"
elif [[ "${occ_err}" == *'[nextcloud/occ] could not reach'* ]]; then
    reason="could not reach clouve-ops@${NEXTCLOUD_HOST}"
    ssh_said="$(grep -v '^\[nextcloud/occ\]' <<< "${occ_err}" | head -n 1)"
    [ -z "${ssh_said}" ] || reason+=": ${ssh_said}"
    check ssh_nextcloud FAIL "${reason}; the checks that need the container were skipped"
else
    ssh_up=1
    check ssh_nextcloud OK "clouve-ops@${NEXTCLOUD_HOST} answers"
    if [ "${occ_rc}" -eq 0 ] && [ -n "${status_line}" ] && jq -e 'type == "object" and has("installed")' > /dev/null 2>&1 <<< "${status_line}"; then
        nc_up=1
        status_json="${status_line}"
        check occ_status OK "occ answers"
    else
        occ_said="$(why "${occ_out}" "${occ_err}")"
        if [ "${occ_rc}" -ne 0 ]; then
            reason="occ can't run (exit ${occ_rc})${occ_said:+: ${occ_said}}"
        else
            reason="occ status printed no JSON${occ_said:+: ${occ_said}}"
        fi
        check occ_status FAIL "${reason}; the checks that read with occ were skipped"
    fi
fi

if [ "${nc_up}" -eq 1 ]; then
    IFS='|' read -r st_installed st_maintenance st_upgrade st_version <<< "$(jq -r '[(.installed | tostring), (.maintenance | tostring), (.needsDbUpgrade | tostring), ((.versionstring // .version // "") | tostring)] | join("|")' <<< "${status_json}")"
    if [ "${st_installed}" = true ]; then
        check installed OK "yes"
    else
        check installed FAIL "occ status says installed is ${st_installed}"
    fi
    case "${st_maintenance}" in
        false) check maintenance OK "off" ;;
        true) check maintenance WARN "users see a maintenance page (see playbooks/recover-stuck-upgrade-or-maintenance.md)" ;;
        *) check maintenance WARN "occ status did not say (maintenance is ${st_maintenance})" ;;
    esac
    case "${st_upgrade}" in
        false) check needs_db_upgrade OK "no" ;;
        true) check needs_db_upgrade FAIL "an upgrade is pending; see playbooks/recover-stuck-upgrade-or-maintenance.md" ;;
        *) check needs_db_upgrade WARN "occ status did not say (needsDbUpgrade is ${st_upgrade})" ;;
    esac
    if [ -n "${st_version}" ]; then
        check version OK "${st_version}"
    else
        check version WARN "occ status gave no version"
    fi
fi

# ---------------------------------------------------------------------------
# 2. The two public pages, over HTTP to NEXTCLOUD_HOST with the public Host header
# ---------------------------------------------------------------------------
site_maintenance=""
http_get /status.php "${work_dir}/status.json"
case "${http_code}" in
    200)
        if jq -e '.installed == true' "${work_dir}/status.json" > /dev/null 2>&1; then
            check http_status OK "200, installed"
            site_maintenance="$(jq -r '(.maintenance // false) | tostring' "${work_dir}/status.json" 2> /dev/null)"
        else
            check http_status FAIL "200 but status.php does not say installed is true"
        fi
        ;;
    400) check http_status FAIL "trusted domain error: ${public_host} isn't in trusted_domains" ;;
    000) check http_status FAIL "no response ($(curl_reason "${http_rc}"))" ;;
    500) check http_status FAIL "500 (Nextcloud could not finish the request; the database may be down)" ;;
    *) check http_status FAIL "${http_code}" ;;
esac

http_get /login /dev/null
case "${http_code}" in
    200) check http_login_page OK "200" ;;
    503)
        if [ "${site_maintenance}" = true ]; then
            check http_login_page WARN "503 while maintenance mode is on"
        else
            check http_login_page FAIL "503 outside maintenance mode"
        fi
        ;;
    400) check http_login_page FAIL "400 (the host is not in trusted_domains: see http_status)" ;;
    000) check http_login_page FAIL "no response ($(curl_reason "${http_rc}"))" ;;
    *) check http_login_page FAIL "${http_code}" ;;
esac

# ---------------------------------------------------------------------------
# 3. The database over TCP, and ssh to its container
# ---------------------------------------------------------------------------
# TLS off, in the dialect of the installed client: the MySQL 8 client the agent has lists --ssl-mode, MariaDB's does not.
# --no-defaults, which has to be the first option, keeps ~/.my.cnf and the other option files out: a password= in one beats
# MYSQL_PWD, and a host= or ssl setting could point the probe somewhere else.
mysql_help="$(mysql --no-defaults --help 2> /dev/null)"
mysql_tls=--skip-ssl
if grep -qE -- '^[[:space:]]*--ssl-mode([=[:space:]]|$)' <<< "${mysql_help}"; then mysql_tls=--ssl-mode=DISABLED; fi
db_out="$(MYSQL_PWD="${NEXTCLOUD_DB_PASSWORD}" timeout -k 5 30 mysql --no-defaults -h "${NEXTCLOUD_DB_HOST}" -u "${NEXTCLOUD_DB_USER}" "${NEXTCLOUD_DB_NAME}" "${mysql_tls}" --connect-timeout=5 -N -e 'SELECT 1' 2> "${work_dir}/mysql.err")"
db_rc=$?
db_err="$(< "${work_dir}/mysql.err")"
db_out="${db_out//[[:space:]]/}"
# The error is the line that starts with ERROR: a MariaDB client run as mysql prints a "deprecated program name" notice before it.
db_error="$(grep -m 1 -E '^ERROR' <<< "${db_err}")"
[ -n "${db_error}" ] || db_error="$(why "${db_out}" "${db_err}")"
if timed_out "${db_rc}"; then
    check database_tcp FAIL "timed out after 30 s"
elif [ "${db_rc}" -ne 0 ]; then
    check database_tcp FAIL "$(why "" "${db_error}")"
elif [ "${db_out}" = 1 ]; then
    check database_tcp OK "${NEXTCLOUD_DB_USER}@${NEXTCLOUD_DB_HOST} answers"
elif [ -z "${db_out}" ]; then
    check database_tcp FAIL "no answer to SELECT 1"
else
    check database_tcp FAIL "answered \"${db_out}\", wanted 1"
fi

ssh_run "${db_ssh_host}" true
if [ "${ssh_rc}" -eq 0 ]; then
    check ssh_database OK "clouve-ops@${db_ssh_host} answers"
else
    check ssh_database WARN "could not log in to clouve-ops@${db_ssh_host} (exit ${ssh_rc}); only the diagnostics need it"
fi

# ---------------------------------------------------------------------------
# 4. Inside the Nextcloud container: the restore marker, the init lock, Valkey
# ---------------------------------------------------------------------------
if [ "${ssh_up}" -eq 1 ]; then
    # present, absent, or unknown: sudo that fails (it exits 1, as test does for a missing file) must not read as "absent"
    # Root tests a path in www-data's data folder here, without the plain-file and inode checks that backup.sh and
    # restore.sh make before they read a marker. A test is enough: test -e opens nothing and makes nothing, so a link
    # that www-data puts in the path can only show whether its target exists.
    ssh_run "${NEXTCLOUD_HOST}" "if sudo -n test -e ${marker_path}; then echo present; elif sudo -n test ! -e ${marker_path}; then echo absent; else echo unknown; fi"
    marker_state="$(last_line "${ssh_out}")"
    if [ "${ssh_rc}" -eq 0 ] && [ "${marker_state}" = present ]; then
        check restore_marker FAIL "a restore is running or was interrupted; see playbooks/restore-from-backup.md"
    elif [ "${ssh_rc}" -eq 0 ] && [ "${marker_state}" = absent ]; then
        check restore_marker OK "none"
    elif [ "${ssh_rc}" -eq 0 ]; then
        check restore_marker WARN "could not check (sudo could not test for ${marker_path})"
    else
        check restore_marker WARN "could not check (exit ${ssh_rc}): $(why "${ssh_out}" "${ssh_err}")"
    fi

    # The probe runs as www-data, whose file the lock is, and opens it only when it is a plain file. flock opens the file
    # by name and would make it if it were missing; as www-data that can only make a file www-data could make anyway, so
    # a link that www-data swaps into the path gains it nothing (run as root, flock could have been pointed at any path,
    # such as /etc/nologin). 10: no file. 11: not a plain file (a link, a pipe or a folder), left unopened, so a pipe
    # can't hold the probe. 99: the lock is held. The lock it asks for is shared (-s), as the container's health probe's
    # is: two shared locks never conflict, so this never reports that probe, while every holder that counts (an
    # install, an upgrade, a recovery, a backup, a restore, occ.sh --init-lock) holds the lock exclusively.
    ssh_run "${NEXTCLOUD_HOST}" "sudo -n -u www-data bash -c '[ -e \"\$1\" ] || [ -L \"\$1\" ] || exit 10; [ -f \"\$1\" ] && [ ! -L \"\$1\" ] || exit 11; exec flock -n -s -E 99 \"\$1\" true' _ ${lock_path}"
    case "${ssh_rc}" in
        0) check init_lock OK "free" ;;
        10) check init_lock OK "no lock file yet" ;;
        11) check init_lock WARN "the lock path is not a plain file (a link, a pipe or a folder), so it was not opened" ;;
        99) check init_lock WARN "an install, upgrade, recovery, backup or restore holds the lock" ;;
        *) check init_lock WARN "could not check (exit ${ssh_rc})" ;;
    esac

    ssh_run "${NEXTCLOUD_HOST}" "sudo -n -u www-data valkey-cli -s ${valkey_socket} ping"
    if [ "${ssh_rc}" -eq 0 ] && [ "$(last_line "${ssh_out}")" = PONG ]; then
        check valkey OK "PONG"
    elif timed_out "${ssh_rc}"; then
        check valkey FAIL "no PONG: timed out after 60 s"
    else
        check valkey FAIL "no PONG: $(why "${ssh_out}" "${ssh_err}")"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Cron, background jobs
# ---------------------------------------------------------------------------
if [ "${nc_up}" -eq 1 ]; then
    occ_run 60 config:app:get core lastcron
    last_cron="${occ_val}"
    if timed_out "${occ_rc}"; then
        check cron_last_run WARN "timed out after 60 s"
    elif occ_key_unset || { [ "${occ_rc}" -eq 0 ] && { [ -z "${last_cron}" ] || [[ "${last_cron}" =~ ^0+$ ]]; }; }; then
        check cron_last_run FAIL "never ran (cron runs every 300 s; the first run comes within 5 minutes of the install)"
    elif [ "${occ_rc}" -ne 0 ]; then
        check cron_last_run WARN "could not read lastcron (exit ${occ_rc}): $(why "${occ_out}" "${occ_err}")"
    elif ! [[ "${last_cron}" =~ ^[0-9]{1,18}$ ]]; then
        check cron_last_run WARN "unreadable lastcron value: ${last_cron}"
    else
        ssh_run "${NEXTCLOUD_HOST}" 'date +%s'
        now_epoch="$(last_line "${ssh_out}")"
        # up to 18 digits fit in the shell's arithmetic; 10# keeps a leading zero (08, 09) from being read as a bad octal number
        if [ "${ssh_rc}" -ne 0 ]; then
            check cron_last_run WARN "could not read the container's clock (exit ${ssh_rc})"
        elif ! [[ "${now_epoch}" =~ ^[0-9]{1,18}$ ]]; then
            check cron_last_run WARN "could not read the container's clock (it printed: ${now_epoch:-nothing})"
        else
            age=$((10#${now_epoch} - 10#${last_cron}))
            [ "${age}" -ge 0 ] || age=0
            if [ "${age}" -le 900 ]; then
                check cron_last_run OK "${age} s ago"
            elif [ "${age}" -le 3600 ]; then
                check cron_last_run WARN "${age} s ago (cron runs every 300 s)"
            else
                check cron_last_run FAIL "${age} s ago (cron has stalled)"
            fi
        fi
    fi

    occ_run 60 config:app:get core backgroundjobs_mode
    bg_mode="${occ_val}"
    if timed_out "${occ_rc}"; then
        check background_jobs_mode WARN "timed out after 60 s"
    elif occ_key_unset || { [ "${occ_rc}" -eq 0 ] && [ -z "${bg_mode}" ]; }; then
        check background_jobs_mode WARN "not set, expected cron"
    elif [ "${occ_rc}" -ne 0 ]; then
        check background_jobs_mode WARN "could not read backgroundjobs_mode (exit ${occ_rc}): $(why "${occ_out}" "${occ_err}")"
    elif [ "${bg_mode}" = cron ]; then
        check background_jobs_mode OK "cron"
    else
        check background_jobs_mode WARN "${bg_mode}, expected cron"
    fi
fi

# ---------------------------------------------------------------------------
# 6. The setup checks
# ---------------------------------------------------------------------------
if [ "${nc_up}" -eq 1 ]; then
    if [ "${st_maintenance}" = true ]; then
        check setup_checks WARN "skipped, maintenance mode is on (occ loads no apps and the checks call the site)"
    elif [ "${st_upgrade}" = true ]; then
        check setup_checks WARN "skipped, an upgrade is pending (occ loads no apps and the checks call the site)"
    else
        occ_run 180 setupchecks --output=json
        sc_json="$(last_json_line "${occ_out}")"
        if timed_out "${occ_rc}"; then
            check setup_checks WARN "timed out after 180 s"
        elif [ -z "${sc_json}" ] || ! jq -e 'type == "object"' > /dev/null 2>&1 <<< "${sc_json}"; then
            check setup_checks WARN "could not read the answer (exit ${occ_rc}): $(why "${occ_out}" "${occ_err}")"
        else
            # total results, info results, then the names of the errors and warnings. The exit code is not read: occ exits 1
            # when any result is not success, info included.
            sc_total=0
            sc_info=0
            sc_names=()
            {
                read -r sc_total
                read -r sc_info
                mapfile -t sc_names
            } < <(jq -r '
                [ to_entries[]? | .value | to_entries[]? | select(.value | type == "object" and has("severity"))
                  | {sev: .value.severity, name: (.value.name // (.key | split("\\") | last))} ] as $r
                | ($r | length), ($r | map(select(.sev == "info")) | length),
                  ($r[] | select(.sev == "error" or .sev == "warning") | .name)' <<< "${sc_json}")
            if [ "${sc_total}" -eq 0 ]; then
                check setup_checks WARN "setupchecks returned no results"
            elif [ "${#sc_names[@]}" -eq 0 ]; then
                check setup_checks OK "nothing needs attention (${sc_info} info)"
            else
                sc_list=""
                for ((i = 0; i < ${#sc_names[@]} && i < 8; i++)); do
                    [ -z "${sc_list}" ] || sc_list+=", "
                    sc_list+="${sc_names[i]}"
                done
                [ "${#sc_names[@]}" -le 8 ] || sc_list+=" +$((${#sc_names[@]} - 8)) more"
                check setup_checks WARN "${sc_list}"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 7. Disk use, and the URL setting
# ---------------------------------------------------------------------------
if [ "${ssh_up}" -eq 1 ]; then disk_check disk_nextcloud "${NEXTCLOUD_HOST}" /var/www/html; fi
disk_check disk_database "${db_ssh_host}" /var/lib/mysql

if [ "${nc_up}" -eq 1 ]; then
    occ_run 60 config:system:get overwrite.cli.url
    url_value="${occ_val}"
    if timed_out "${occ_rc}"; then
        check url_setting WARN "timed out after 60 s"
    elif occ_key_unset; then
        check url_setting WARN "overwrite.cli.url is not set (NEXTCLOUD_URL is ${NEXTCLOUD_URL}); it is set when the container next starts"
    elif [ "${occ_rc}" -ne 0 ]; then
        check url_setting WARN "could not read overwrite.cli.url (exit ${occ_rc}): $(why "${occ_out}" "${occ_err}")"
    elif [ "${url_value}" = "${NEXTCLOUD_URL}" ]; then
        check url_setting OK "${NEXTCLOUD_URL}"
    else
        check url_setting WARN "overwrite.cli.url is ${url_value} but NEXTCLOUD_URL is ${NEXTCLOUD_URL}; it changes when the container next starts"
    fi
fi

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------
printf 'Nextcloud health report, %s\n' "${started}"
printf 'host: %s\n' "${NEXTCLOUD_HOST}"
printf 'db:   %s@%s\n' "${NEXTCLOUD_DB_NAME}" "${NEXTCLOUD_DB_HOST}"
printf 'url:  %s\n\n' "$(tidy "${NEXTCLOUD_URL}")"
printf '%s\n' "${report[@]}"
printf '\n'
case "${worst}" in
    0) printf 'Overall: GREEN\n' ;;
    2) printf 'Overall: AMBER (one or more WARN)\n' ;;
    3) printf 'Overall: RED (one or more FAIL)\n' ;;
esac
exit "${worst}"
