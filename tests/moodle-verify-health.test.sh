#!/bin/bash
# ============================================================================
# Moodle skill: scripts/verify-health.sh
# ============================================================================
# Runs the script on the agent's side against fakes and checks the report:
#
#   - http_login_page: Moodle answers 303 to any host but its wwwroot's, so the
#     probe of the sibling (http://${MOODLE_HOST}/login/index.php) must send
#     "Host: <host[:port] of MOODLE_URL>". With an https MOODLE_URL the image
#     sets $CFG->sslproxy, so the host is all Moodle checks. With no MOODLE_URL
#     the probe goes out as before.
#   - code_version: the code's $version comes from version.php on the sibling
#     (public/version.php on Moodle 5.1+, else version.php at the root), read
#     over the clouve-ops channel. Not $CFG->version, which is the database's
#     version, and nothing the remote shell can expand on the way.
#   - version_invariant: code and database versions are compared as numbers
#     (version.php says 2026042000.00, mdl_config says 2026042000).
#   - cron_freshness: mdl_task_log.timestart is a decimal column, so
#     MAX(timestart) comes back as 1792790161.4598000000; the age is still
#     worked out in whole seconds, with no shell arithmetic error.
#
# Fakes, first on PATH:
#   curl     prints 200 when it was given "-H Host: ${FAKE_SITE_HOST}", 303
#            otherwise (what Moodle does), and records its arguments;
#   mysql    answers the script's three queries the way MySQL would
#            (FLOOR()/CAST() of MAX(timestart) gives whole seconds);
#   sshpass  plays the sibling: it runs the remote command (and any script on
#            stdin) in a real bash, with /var/www/html mapped to a temp folder,
#            so quoting and expansion bugs show up as they would over ssh;
#   sudo     runs the command without the -n/-u options;
#   php      `php -r CODE` behaves like PHP for the old one-liner: it prints
#            the DATABASE version for `require config.php; echo $CFG->version`
#            and fails like a parse error when $CFG was expanded away;
#            `php .../admin/cli/checks.php` passes.
# No Moodle, MySQL, network or ssh.
#
# Usage: bash tests/moodle-verify-health.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$(cd "${here}/../plugins/moodle/skills/moodle/scripts" && pwd)/verify-health.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/moodle-verify-health-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }

bin="${work}/bin"
mkdir -p "${bin}"

cat > "${bin}/curl" <<'FAKE'
#!/bin/bash
printf 'curl %s\n' "$*" >> "${FAKE_CALLS}"
host=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) shift; case "$1" in [Hh]ost:*) host="${1#*:}"; host="${host# }" ;; esac ;;
  esac
  shift
done
if [ -n "${host}" ] && [ "${host}" = "${FAKE_SITE_HOST}" ]; then printf '200'; else printf '303'; fi
FAKE

cat > "${bin}/mysql" <<'FAKE'
#!/bin/bash
q=""
while [ "$#" -gt 0 ]; do [ "$1" = "-e" ] && { shift; q="$1"; }; shift; done
case "${q}" in
  *"name='version'"*)             printf '%s\n' "${FAKE_DB_VERSION}" ;;
  *maintenance_enabled*)          printf '0\n' ;;
  *FLOOR*timestart*|*CAST*timestart*|*TRUNCATE*timestart*)
                                  printf '%s\n' "${FAKE_LAST_CRON%%.*}" ;;
  *timestart*)                    printf '%s\n' "${FAKE_LAST_CRON}" ;;
  *)                              echo "fake mysql: unexpected query: ${q}" >&2; exit 1 ;;
esac
FAKE

cat > "${bin}/sshpass" <<'FAKE'
#!/bin/bash
[ "$1" = "-e" ] && shift
[ "$1" = "ssh" ] && shift
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
target="$1"; shift
cmd="$*"
printf 'ssh %s %s\n' "${target}" "${cmd}" >> "${FAKE_CALLS}"
map() { sed "s#/var/www/html#${FAKE_WWW}#g"; }
# The remote side: a fresh bash (as sshd runs the command), with the sibling's
# files where it expects them. A script on stdin is mapped the same way.
map | env -i PATH="${FAKE_BIN}:/usr/bin:/bin" FAKE_DB_VERSION="${FAKE_DB_VERSION}" FAKE_CALLS="${FAKE_CALLS}" \
  bash -c "$(printf '%s' "${cmd}" | map)"
FAKE

cat > "${bin}/sudo" <<'FAKE'
#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
FAKE

cat > "${bin}/php" <<'FAKE'
#!/bin/bash
printf 'php %s\n' "$*" >> "${FAKE_CALLS}"
if [ "$1" = "-r" ]; then
  case "$2" in
    *config.php*'$CFG->version'*) printf '%s' "${FAKE_DB_VERSION}" ;;
    *) echo "PHP Parse error: syntax error, unexpected token \"->\"" >&2; exit 255 ;;
  esac
  exit 0
fi
case "$*" in *admin/cli/checks.php*) echo "OK: all checks pass"; exit 0 ;; esac
echo "fake php: unexpected: $*" >&2; exit 1
FAKE

cat > "${bin}/clv-secret" <<'FAKE'
#!/bin/bash
echo "fake clv-secret: the test sets every password, so this must not run ($*)" >&2
exit 2
FAKE
chmod +x "${bin}"/*

# A sibling's code tree: version.php the way Moodle ships it.
make_www() { # <dir> <where: public|root> <version literal>
  local d="$1" where="$2" v="$3" f
  mkdir -p "${d}/public"
  if [ "${where}" = public ]; then f="${d}/public/version.php"; else f="${d}/version.php"; fi
  cat > "${f}" <<PHP
<?php
defined('MOODLE_INTERNAL') || die();

\$version  = ${v};              // YYYYMMDD      = weekly release date of this DEV branch.
\$release  = '5.2 (Build: 20260420)'; // Human-friendly version name
\$branch   = '502';                     // This version's branch.
\$maturity = MATURITY_STABLE;           // This version's maturity level.
PHP
}

# run_case <name> [VAR=value ...]: runs the script and leaves its output in
# ${out} and its exit code in ${rc}.
run_case() {
  local name="$1"; shift
  local dir="${work}/${name}"
  mkdir -p "${dir}"
  : > "${dir}/calls"
  out="$(env -i HOME="${dir}" PATH="${bin}:/usr/bin:/bin" FAKE_BIN="${bin}" FAKE_CALLS="${dir}/calls" \
      MOODLE_HOST=tkt-7-moodle MOODLE_DB_HOST=tkt-7-moodle-mysql MOODLE_DB_USER=moodle MOODLE_DB_NAME=moodle \
      MOODLE_DB_PASSWORD=db-pass CLOUVE_OPS_PASSWORD=ops-pass \
      FAKE_DB_VERSION=2026042000 FAKE_LAST_CRON="$(( $(date +%s) - 30 )).4598000000" \
      FAKE_WWW="${work}/www-public" FAKE_SITE_HOST=site.example.com MOODLE_URL=https://site.example.com \
      "$@" bash "${script}" </dev/null 2>&1)"
  rc=$?
  calls="$(cat "${dir}/calls")"
}

line() { printf '%s\n' "${out}" | grep -E "^$1 " | head -1; }

make_www "${work}/www-public" public 2026042000.00
make_www "${work}/www-root" root 2026042000.00
make_www "${work}/www-newer" public 2026042000.00
make_www "${work}/www-point" public 2024100700.01

echo "verify-health.sh: a healthy site on Kubernetes (https MOODLE_URL)"
run_case healthy
l="$(line http_login_page)"
if [[ "${l}" =~ http_login_page\ +OK\ +200 ]]; then ok "login page probe sends the site's host and gets 200"
else bad "login page probe: wanted OK 200, got: ${l:-<no line>}" "${calls}"; fi
if printf '%s\n' "${calls}" | grep -q -- "-H Host: site.example.com"; then ok "the probe sends Host: site.example.com"
else bad "the probe never sent Host: site.example.com" "${calls}"; fi
l="$(line code_version)"
if [[ "${l}" =~ code_version\ +OK\ +version=2026042000$ ]]; then ok "code version read from public/version.php (2026042000)"
else bad "code_version: wanted OK version=2026042000, got: ${l:-<no line>}" "${out}"; fi
l="$(line version_invariant)"
if [[ "${l}" =~ version_invariant\ +OK ]]; then ok "2026042000.00 in the code matches 2026042000 in the database"
else bad "version_invariant: wanted OK, got: ${l:-<no line>}" "${out}"; fi
l="$(line cron_freshness)"
if [[ "${l}" =~ cron_freshness\ +OK\ +(29|30|31|32)s\ ago ]]; then ok "cron age from a decimal MAX(timestart): ${l##* OK }"
else bad "cron_freshness: wanted OK ~30s ago, got: ${l:-<no line>}" "${out}"; fi
if printf '%s\n' "${out}" | grep -q 'syntax error'; then bad "the output holds a shell syntax error" "${out}"; else ok "no shell arithmetic error"; fi
if [ "${rc}" -eq 0 ] && printf '%s\n' "${out}" | grep -q '^Overall: GREEN'; then ok "Overall: GREEN, exit 0"
else bad "wanted Overall: GREEN and exit 0, got exit ${rc}" "${out}"; fi

echo "verify-health.sh: a local docker-compose stack (http MOODLE_URL with a port)"
run_case local MOODLE_URL=http://localhost:8080 FAKE_SITE_HOST=localhost:8080 MOODLE_HOST=moodle
l="$(line http_login_page)"
if [[ "${l}" =~ http_login_page\ +OK\ +200 ]] && printf '%s\n' "${calls}" | grep -q -- "-H Host: localhost:8080"; then ok "Host: localhost:8080 gets 200"
else bad "local probe: wanted OK 200 with Host: localhost:8080, got: ${l:-<no line>}" "${calls}"; fi

echo "verify-health.sh: version.php at the code root (no public/)"
run_case root FAKE_WWW="${work}/www-root"
l="$(line code_version)"
if [[ "${l}" =~ code_version\ +OK\ +version=2026042000$ ]]; then ok "code version read from version.php at the root"
else bad "code_version at the root: got: ${l:-<no line>}" "${out}"; fi

echo "verify-health.sh: code newer than the database (an upgrade pending)"
run_case newer FAKE_WWW="${work}/www-newer" FAKE_DB_VERSION=2025100600
l="$(line version_invariant)"
if [[ "${l}" =~ version_invariant\ +WARN\ +code=2026042000\ \>\ db=2025100600 ]]; then ok "WARN: code 2026042000 > db 2025100600"
else bad "version_invariant with a pending upgrade: got: ${l:-<no line>}" "${out}"; fi

echo "verify-health.sh: a weekly build's decimal version"
run_case point FAKE_WWW="${work}/www-point" FAKE_DB_VERSION=2024100700.01
l="$(line code_version)"; l2="$(line version_invariant)"
if [[ "${l}" =~ version=2024100700\.01$ ]] && [[ "${l2}" =~ version_invariant\ +OK ]]; then ok "2024100700.01 kept and matched"
else bad "decimal version: got: ${l:-<no line>} / ${l2:-<no line>}" "${out}"; fi

echo "verify-health.sh: no MOODLE_URL"
run_case nourl MOODLE_URL=
l="$(line http_login_page)"
if [[ "${l}" =~ http_login_page\ +FAIL\ +303 ]] && ! printf '%s\n' "${calls}" | grep -q -- "-H Host:"; then ok "probes as before, with no Host header"
else bad "no MOODLE_URL: wanted the old probe (FAIL 303, no Host header), got: ${l:-<no line>}" "${calls}"; fi

echo "verify-health.sh: no cron run yet"
run_case nocron FAKE_LAST_CRON=NULL
l="$(line cron_freshness)"
if [[ "${l}" =~ cron_freshness\ +WARN\ +no\ rows ]]; then ok "WARN: no rows in mdl_task_log yet"
else bad "no cron rows: got: ${l:-<no line>}" "${out}"; fi

echo
echo "moodle-verify-health: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
