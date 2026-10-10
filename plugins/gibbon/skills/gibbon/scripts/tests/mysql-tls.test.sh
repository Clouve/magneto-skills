#!/bin/bash
# Gibbon DevOps Skill — tests/mysql-tls.test.sh
#
# Hermetic test: backup.sh, verify-health.sh and php-info.sh must reach the
# DB with EITHER mysql client flavour the Magneto Agent can end up with:
#
#   mysql8   Oracle MySQL 8.0 client — what `default-mysql-client` installs
#            on the agent's Ubuntu 24.04 base (8.0.46 as of 2026-10-09).
#            Rejects --skip-ssl / --ssl ("[ERROR] unknown option", exit 2);
#            disables TLS only via --ssl-mode=DISABLED.
#   mariadb  MariaDB >= 11.4 client — what `default-mysql-client` installs on
#            a Debian base. Rejects --ssl-mode / --get-server-public-key
#            (exit 7); verifies the server cert by default, so it fails on
#            the MySQL 8 server's self-signed cert unless given --skip-ssl.
#
# The fakes model the worst case observed against the real gibbon-mysql
# server (MySQL 8.0, caching_sha2_password app user): a COLD auth cache,
# e.g. right after the DB restarts. Then a non-TLS MySQL 8 login needs the
# server's RSA key: --ssl-mode=DISABLED without --get-server-public-key
# fails with ERROR 2061.
#
# Nothing here touches a real DB: fake mysql/mysqldump/mysqladmin/curl come
# first on PATH, the scripts run under `env -i` with made-up GIBBON_* values,
# and HOME is a throwaway directory.
#
# Run: bash scripts/tests/mysql-tls.test.sh   (exit 0 = all pass)

set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
scripts=$(dirname "${here}")
work=$(mktemp -d "${TMPDIR:-/tmp}/gibbon-mysql-tls-test.XXXXXX")
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0

# make_fakes <flavour> — writes ${work}/<flavour>/bin/{mysql,mysqldump,mysqladmin,curl}
make_fakes() {
  local flavour="$1"
  local bin="${work}/${flavour}/bin"
  mkdir -p "${bin}"
  {
    printf '#!/bin/bash\nFLAVOUR=%s\n' "${flavour}"
    cat <<'FAKE'
prog=${0##*/}
printf '%s %s\n' "${prog}" "$*" >> "${FAKE_CALLS:-/dev/null}"

if [ "${prog}" = curl ]; then
  case " $* " in
    *" -w "*) printf '200' ;;
    *" -sI "*) printf 'HTTP/1.1 200 OK\r\nServer: Apache/2.4.65 (Debian)\r\n\r\n' ;;
  esac
  exit 0
fi

# --help excerpts are verbatim from the real clients (trailing spaces included).
help_mysql8() {
  cat <<'EOF'
mysqldump  Ver 8.0.46 for Linux on x86_64 (MySQL Community Server - GPL)
Copyright (c) 2000, 2026, Oracle and/or its affiliates.
  --server-public-key-path=name
                      File path to the server public RSA key in PEM format.
  --get-server-public-key
                      Get server public key
  --ssl-mode=name     SSL connection mode.
  --ssl-ca=name       CA file in PEM format.
  --ssl-capath=name   CA directory.
  --ssl-cert=name     X509 cert in PEM format.
  --ssl-cipher=name   SSL cipher to use.
  --ssl-key=name      X509 key in PEM format.
  --ssl-crl=name      Certificate revocation list.
  --ssl-crlpath=name  Certificate revocation list path.
  --tls-version=name  TLS version to use, permitted values are: TLSv1.2,
                      TLSv1.3
server-public-key-path                    (No default value)
get-server-public-key                     FALSE
ssl-ca                                    (No default value)
EOF
}
help_mariadb() {
  cat <<'EOF'
mariadb-dump from 12.3.3-MariaDB, client 10.20 for debian-linux-gnu (x86_64)
Copyright (c) 2000, 2018, Oracle, MariaDB Corporation Ab and others.
  --ssl               Enable SSL for connection (automatically enabled with
                      other flags).
                      (Defaults to on; use --skip-ssl to disable.)
  --ssl-ca=name       CA file in PEM format (check OpenSSL docs, implies
                      --ssl).
  --ssl-capath=name   CA directory (check OpenSSL docs, implies --ssl).
  --ssl-cert=name     X509 cert in PEM format (implies --ssl).
  --ssl-cipher=name   SSL cipher to use (implies --ssl).
  --ssl-key=name      X509 key in PEM format (implies --ssl).
  --ssl-crl=name      Certificate revocation list (implies --ssl).
  --ssl-crlpath=name  Certificate revocation list path (implies --ssl).
  --tls-version=name  TLS protocol version for secure connection.
  --ssl-fp=name       Server certificate fingerprint (implies --ssl).
  --ssl-verify-server-cert
                      Verify server's certificate to prevent man-in-the-middle
                      attacks
                      (Defaults to on; use --skip-ssl-verify-server-cert to disable.)
EOF
}

tls_off=no
pubkey=no
want_sql=no
sql=""
cmd=""
for arg in "$@"; do
  if [ "${want_sql}" = yes ]; then sql="${arg}"; want_sql=no; continue; fi
  case "${FLAVOUR}:${arg}" in
    *:--help) "help_${FLAVOUR}"; exit 0 ;;
    mysql8:--skip-ssl|mysql8:--ssl)
      echo "${prog}: [ERROR] unknown option '${arg}'." >&2; exit 2 ;;
    mysql8:--ssl-mode=DISABLED) tls_off=yes ;;
    mysql8:--get-server-public-key) pubkey=yes ;;
    mariadb:--ssl-mode=*)
      echo "${prog}: unknown variable '${arg#--}'" >&2; exit 7 ;;
    mariadb:--get-server-public-key)
      echo "${prog}: unknown option '${arg}'" >&2; exit 7 ;;
    mariadb:--skip-ssl) tls_off=yes ;;
    *:-e) want_sql=yes ;;
    *:ping) cmd=ping ;;
  esac
done

case "${FLAVOUR}" in
  mysql8)
    if [ "${tls_off}" = yes ] && [ "${pubkey}" = no ]; then
      echo "ERROR 2061 (HY000): Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection." >&2
      exit 1
    fi ;;
  mariadb)
    if [ "${tls_off}" = no ]; then
      echo "ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain" >&2
      exit 1
    fi ;;
esac

case "${prog}" in
  mysqldump)
    printf '%s\n' \
      '-- MySQL dump 10.13  Distrib 8.0.46, for Linux (x86_64)' \
      'CREATE TABLE `gibbonPerson` (' \
      '  `gibbonPersonID` int unsigned NOT NULL' \
      ') ENGINE=InnoDB;' \
      'CREATE TABLE `gibbonSetting` (' \
      '  `name` varchar(50) NOT NULL' \
      ') ENGINE=InnoDB;' \
      '-- Dump completed on 2026-10-09 12:00:00' ;;
  mysqladmin)
    [ "${cmd}" = ping ] && echo "mysqld is alive" ;;
  mysql)
    case "${sql}" in
      *"name='version'"*)     echo "30.0.01" ;;
      *"name='absoluteURL'"*) echo "https://gibbon.example.test" ;;
      *gibbonSchoolYear*)     echo "1" ;;
      *gibbonLog*)            echo "2" ;;
    esac ;;
esac
exit 0
FAKE
  } > "${bin}/fake"
  chmod +x "${bin}/fake"
  local name
  for name in mysql mysqldump mysqladmin curl; do
    ln -s fake "${bin}/${name}"
  done
}

# run_script <flavour> <script> — sets $out (stdout+stderr) and $rc
run_script() {
  local flavour="$1" script="$2"
  local home="${work}/${flavour}/home"
  mkdir -p "${home}"
  : > "${work}/${flavour}/calls"
  out=$(env -i \
    HOME="${home}" \
    PATH="${work}/${flavour}/bin:/usr/bin:/bin" \
    FAKE_CALLS="${work}/${flavour}/calls" \
    GIBBON_HOST=gibbon.test \
    GIBBON_DB_HOST=gibbon-mysql.test \
    GIBBON_DB_USER=gibbon \
    GIBBON_DB_PASSWORD=not-a-real-password \
    GIBBON_DB_NAME=gibbon \
    "${BASH}" "${scripts}/${script}" 2>&1)
  rc=$?
}

# check <label> <flavour> <pass|fail>
check() {
  local label="$1" flavour="$2" ok="$3"
  if [ "${ok}" = pass ]; then
    printf "  ✓ %s\n" "${label}"
    pass=$((pass + 1))
  else
    printf "  ✗ %s (exit %s)\n" "${label}" "${rc}"
    printf '%s\n' "${out}" | sed 's/^/      | /'
    sed 's/^/      calls: /' "${work}/${flavour}/calls"
    fail=$((fail + 1))
  fi
}

echo "Gibbon scripts vs mysql client flavours"

for flavour in mysql8 mariadb; do
  make_fakes "${flavour}"
  echo
  echo "[${flavour}]"

  run_script "${flavour}" backup.sh
  dump=$(find "${work}/${flavour}/home/backups" -name gibbon.sql 2>/dev/null | head -n 1)
  if [ "${rc}" -eq 0 ] && [ -n "${dump}" ] && grep -q '^CREATE TABLE .gibbonSetting. (' "${dump}"; then
    check "backup.sh exits 0 and writes the dump" "${flavour}" pass
  else
    check "backup.sh exits 0 and writes the dump" "${flavour}" fail
  fi

  run_script "${flavour}" verify-health.sh
  if [ "${rc}" -eq 0 ] && grep -q '^6 passed, 0 failed$' <<< "${out}"; then
    check "verify-health.sh passes all six checks" "${flavour}" pass
  else
    check "verify-health.sh passes all six checks" "${flavour}" fail
  fi

  run_script "${flavour}" php-info.sh
  if grep -qx '30.0.01' <<< "${out}"; then
    check "php-info.sh reads the Gibbon version from the DB" "${flavour}" pass
  else
    check "php-info.sh reads the Gibbon version from the DB" "${flavour}" fail
  fi
done

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
