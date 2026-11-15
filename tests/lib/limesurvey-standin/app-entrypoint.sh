#!/bin/bash
# Entrypoint of the LimeSurvey stand-in (tests only). It does the things of the real image's entrypoint that the
# skill's scripts can see, runs upstream's entrypoint as www-data for the install, and starts Apache as PID 1:
#   1. exports LIMESURVEY_DB_USER, as the real image does for the assistant's persona;
#   2. starts the clouve-ops sshd when CLOUVE_OPS_PASSWORD is set, and takes the password out of the environment;
#   3. makes /var/www/html/clouve, where the real image keeps its install and upgrade state, as root's own folder
#      with mode 700. A clouve that is a link, is not a folder or does not belong to root is moved aside first, as
#      the real image does, and nothing in it is read;
#   4. while the skill's restore marker (clouve/backups/RESTORE-IN-PROGRESS) is there, answers on Apache's port
#      with a "being restored" page and waits, so that a restore that was cut off by a restart can be run again
#      before LimeSurvey starts on a half-loaded database.
set -e

export LIMESURVEY_DB_USER="${DB_USERNAME:-limesurvey}"
export DB_MYSQL_ENGINE="${DB_MYSQL_ENGINE:-InnoDB}"

if [ -n "${CLOUVE_OPS_PASSWORD:-}" ]; then
    ssh-keygen -A > /dev/null 2>&1
    echo "clouve-ops:${CLOUVE_OPS_PASSWORD}" | chpasswd
    mkdir -p /run/sshd
    /usr/sbin/sshd
fi
unset CLOUVE_OPS_PASSWORD

# A volume mounted at /var/www/html/upload starts as root's.
chown www-data:www-data /var/www/html /var/www/html/upload

clouve=/var/www/html/clouve
if [ -L "${clouve}" ] || { [ -e "${clouve}" ] && { [ ! -d "${clouve}" ] || [ "$(stat -c %u "${clouve}")" != 0 ]; }; }; then
    mv -- "${clouve}" "${clouve}.untrusted-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "[limesurvey-standin] ${clouve} was not root's own folder and was moved aside" >&2
fi
install -d -o root -g root -m 700 "${clouve}"

marker="${clouve}/backups/RESTORE-IN-PROGRESS"
if [ -d "${clouve}/backups" ] && [ ! -L "${clouve}/backups" ] && [ "$(stat -c %u "${clouve}/backups")" = 0 ] && [ -e "${marker}" ]; then
    echo "[limesurvey-standin] a restore has not finished: showing the \"being restored\" page until its marker is gone"
    setpriv --reuid=www-data --regid=www-data --init-groups php -S 0.0.0.0:8080 /clouve/standin/restoring.php > /dev/null 2>&1 &
    page=$!
    while [ -e "${marker}" ]; do sleep 1; done
    kill "${page}" 2> /dev/null || true
    wait "${page}" 2> /dev/null || true
    echo "[limesurvey-standin] the restore's marker is gone: starting LimeSurvey"
fi

# Upstream's entrypoint writes config.php, installs LimeSurvey when the database is empty, and ends by running the
# command it is given. Apache then starts as root, as in the real image, with its workers as www-data.
setpriv --reuid=www-data --regid=www-data --init-groups /usr/local/bin/entrypoint.sh true
exec "$@"
