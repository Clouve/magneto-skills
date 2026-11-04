#!/bin/bash
# Gibbon DevOps Skill — php-info.sh
#
# Prints what can be learned about the gibbon container's PHP without a
# shell: the Gibbon version (from the DB) and the HTTP headers. It is
# read-only and writes nothing into the container.
#
# For the full PHP settings, run `php -i` in the gibbon container over the
# clouve-ops SSH channel (../reference/shell-access.md). The CLI reads the
# same php.ini as Apache, but not /var/www/html/.htaccess, which sets
# max_input_vars for Apache.
#
# Env vars:
#   GIBBON_HOST (default: gibbon)

set -u

: "${GIBBON_DB_PASSWORD:=$(clv-secret GIBBON_DB_PASSWORD)}"

. "$(dirname "${BASH_SOURCE[0]}")/lib/mysql-tls.sh"

: "${GIBBON_HOST:=gibbon}"

echo "Gibbon container PHP probe via http://${GIBBON_HOST}"
echo

# 1. Version
echo "--- Gibbon version (from the DB) ---"
if [ -n "${GIBBON_DB_HOST:-}" ] && [ -n "${GIBBON_DB_PASSWORD:-}" ]; then
  # TLS off, in whichever dialect the installed client speaks (lib/mysql-tls.sh).
  read -r -a no_tls <<< "$(mysql_no_tls_args mysql)"
  MYSQL_PWD="${GIBBON_DB_PASSWORD}" mysql \
    -h "${GIBBON_DB_HOST}" -u "${GIBBON_DB_USER:-gibbon}" "${GIBBON_DB_NAME:-gibbon}" \
    "${no_tls[@]}" -sN -e \
    "SELECT value FROM gibbonSetting WHERE scope='System' AND name='version';" 2>/dev/null
  unset MYSQL_PWD
else
  echo "  (GIBBON_DB_* env not set — cannot query)"
fi
echo

# 2. HTTP headers — tells us PHP version and the Apache config
echo "--- HTTP headers from /index.php ---"
curl -sI "http://${GIBBON_HOST}/index.php" | sed 's/^/  /'
echo

# 3. Server-version header (if Apache is configured to send it)
echo "--- Server header ---"
curl -sI "http://${GIBBON_HOST}/" | grep -i "^server:" | sed 's/^/  /'
echo

# 4. Helpful reminders
echo "--- Not covered here ---"
echo "  For the full PHP settings, run 'php -i' in the gibbon container over"
echo "  the clouve-ops SSH channel (see reference/shell-access.md), e.g."
echo "  php -i | grep -E 'max_input_vars|memory_limit|upload_max_filesize'."
echo
echo "  For max_input_vars, memory_limit, upload_max_filesize: see the"
echo "  image's php.ini settings at apps/gibbon/image/Dockerfile — they are"
echo "  fixed at build time (max_input_vars=8000, memory_limit=512M,"
echo "  upload_max_filesize=20M, post_max_size=20M)."
echo "  .htaccess at /var/www/html/.htaccess may override max_input_vars."
