# Gibbon DevOps Skill — lib/mysql-tls.sh (sourced by the scripts, not run)
#
# mysql_no_tls_args <client>
#   Prints the flags that make <client> (mysql, mysqldump, mysqladmin)
#   connect to gibbon-mysql without TLS, in the dialect that client speaks.
#   The two flavours `default-mysql-client` can install disagree:
#
#   Oracle MySQL 8.x — Ubuntu, i.e. the Magneto Agent image. Has no --ssl /
#     --skip-ssl ("unknown option '--skip-ssl'", exit 2). TLS off is
#     --ssl-mode=DISABLED, plus --get-server-public-key: the gibbon user is
#     caching_sha2_password, and without TLS a cold auth cache (e.g. right
#     after gibbon-mysql restarts) otherwise fails with ERROR 2061
#     "Authentication requires secure connection".
#   MariaDB — Debian. TLS off is --skip-ssl. It rejects --ssl-mode and
#     --get-server-public-key (exit 7), and 11.4+ refuses the MySQL
#     server's self-signed cert unless TLS is off.
#
#   Only flags the installed binary's own --help advertises are printed;
#   nothing if it advertises neither dialect.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/mysql-tls.sh"
#   read -r -a no_tls <<< "$(mysql_no_tls_args mysqldump)"
#   mysqldump ... "${no_tls[@]}" ...

mysql_no_tls_args() {
  local help
  help=$("$1" --help 2>/dev/null)
  if grep -qE -- '^[[:space:]]*--ssl-mode[=[:space:]]' <<< "${help}"; then
    printf '%s' '--ssl-mode=DISABLED'
    if grep -qE -- '^[[:space:]]*--get-server-public-key([[:space:]]|$)' <<< "${help}"; then
      printf ' %s' '--get-server-public-key'
    fi
    printf '\n'
  elif grep -qE -- '^[[:space:]]*--ssl([[:space:]]|$)' <<< "${help}"; then
    printf '%s\n' '--skip-ssl'
  fi
}
