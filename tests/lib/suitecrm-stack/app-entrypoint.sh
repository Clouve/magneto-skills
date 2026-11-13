#!/bin/bash
# Stand-in entrypoint for the tests. It follows the order the real image's contract gives:
# the SUITECRM_DB_* aliases in PID 1's environment, the clouve-ops sshd, the database wait, a wait for the
# skill's restore when its marker is there, a new install as www-data behind an install-in-progress stamp, the
# scheduler loop and the Messenger worker, Apache as PID 1.
#
# The parts of the contract the skill's scripts lean on:
#   - The state folder tmp/clouve-backup is root's, mode 700. One that is a link, not a folder, not root's,
#     or that its group or others can write in is never read and never taken over: a start moves it aside to
#     tmp/clouve-backup.untrusted-<UTC time>.
#   - While tmp/clouve-backup/restore-in-progress is there (a plain file of root's), no scheduler pass and no
#     Messenger worker runs: a worker that is running is ended. A start that finds it keeps a stand-in page on
#     port 80 and the sshd up and waits for it to go, so PID 1 is this script then, not Apache.
#   - tmp/clouve-backup/scheduler-held holds the scheduler loop until it is removed.
# Passwords here are made up by the tests.
set -uo pipefail
root=/var/www/html
state="${root}/tmp/clouve-backup"
log() { echo "[standin] $*"; }

if [ -z "${SUITECRM_DB_HOST:-}" ]; then
    export SUITECRM_DB_HOST="${DATABASE_HOST}" SUITECRM_DB_NAME="${DATABASE_NAME}" \
        SUITECRM_DB_USER="${DATABASE_USER}" SUITECRM_DB_PASSWORD="${DATABASE_PASSWORD}"
    exec "$0" "$@"
fi

if [ -n "${CLOUVE_OPS_PASSWORD:-}" ]; then
    ssh-keygen -A > /dev/null
    printf 'clouve-ops:%s\n' "${CLOUVE_OPS_PASSWORD}" | chpasswd
    /usr/sbin/sshd -D -e 2> /var/log/standin-sshd.log &
fi
unset CLOUVE_OPS_PASSWORD

cnf="$(mktemp)"
chmod 600 "${cnf}"
printf '[client]\nuser=%s\npassword=%s\nhost=%s\nport=%s\n' "${DATABASE_USER}" "${DATABASE_PASSWORD}" \
    "${DATABASE_HOST}" "${DATABASE_PORT:-3306}" > "${cnf}"
for _ in $(seq 1 90); do
    if mysql --defaults-extra-file="${cnf}" -e 'SELECT 1' > /dev/null 2>&1; then break; fi
    sleep 1
done
rm -f "${cnf}"

# state_trusted: tmp/ and the state folder are real folders, the state folder is root's, and neither its group
# nor others can write in it (the image's rule: the mode's other bits don't matter)
state_trusted() {
    [ -d "${root}/tmp" ] && [ ! -L "${root}/tmp" ] && [ -d "${state}" ] && [ ! -L "${state}" ] \
        && [ "$(stat -c %u "${state}")" = 0 ] && [ -z "$(find "${state}" -maxdepth 0 -perm /g=w,o=w)" ]
}
# state_has NAME: the trusted state folder holds NAME as a plain file of root's
state_has() {
    state_trusted && [ -f "${state}/$1" ] && [ ! -L "${state}/$1" ] && [ "$(stat -c %u "${state}/$1")" = 0 ]
}
# A state folder that is not root's is moved aside, never read and never taken over.
if { [ -e "${state}" ] || [ -L "${state}" ]; } && ! state_trusted; then
    aside="${state}.untrusted-$(date -u +%Y%m%dT%H%M%SZ)"
    if mv -T -- "${state}" "${aside}"; then log "${state} was not a folder of root's: moved aside to ${aside}, nothing in it was read"; fi
fi

# A restore by the skill is under way, or was cut off: wait for its marker to go. Only a stand-in page and the
# sshd are up meanwhile.
if state_has restore-in-progress; then
    log "a restore is under way (${state}/restore-in-progress is there), so this start waits: nothing is installed or started until the restore has removed its marker. The stand-in answers on port 80 and the sshd is up."
    # shellcheck disable=SC2016  # PHP's variables
    printf '%s\n' '<?php header("X-Clouve-Standin: suitecrm"); if (($_SERVER["REQUEST_URI"] ?? "") !== "/") { http_response_code(503); } echo "SuiteCRM is being restored.\n";' > /run/standin-router.php
    php -S 0.0.0.0:80 /run/standin-router.php > /dev/null 2>&1 &
    standin=$!
    # PID 1 takes no signal it has no handler for; this lets a stop end the wait at once.
    trap 'kill "${standin}" 2> /dev/null; exit 0' TERM INT
    while state_has restore-in-progress; do sleep 1; done
    trap - TERM INT
    kill "${standin}" 2> /dev/null
    wait "${standin}" 2> /dev/null
    log "the restore's marker is gone, so the start goes on"
fi

if [ "$(stat -c %U "${root}")" != www-data ]; then chown www-data:www-data "${root}"; fi
if [ ! -f "${root}/VERSION" ]; then
    log "new install"
    install -d -o www-data -g www-data "${root}/tmp"
    touch "${root}/.clouve-install-in-progress"
    cp -a /clouve/suitecrm/app/. "${root}/"
    chown -R www-data:www-data "${root}"
    cd "${root}" || exit 1
    find . -type d -not -perm 2755 -exec chmod 2755 {} +
    find . -type f -not -perm 0644 -exec chmod 0644 {} +
    chmod +x bin/console
    if ! su -s /bin/bash www-data -c './bin/console suitecrm:app:install -n -u "$SUITECRM_ADMIN_USER" -p "$SUITECRM_ADMIN_PASSWORD" -U "$DATABASE_USER" -P "$DATABASE_PASSWORD" -H "$DATABASE_HOST" -Z "${DATABASE_PORT:-3306}" -N "$DATABASE_NAME" -S "$SUITECRM_URL" -d no -W true' > /var/log/standin-install.log 2>&1; then
        log "install failed; see /var/log/standin-install.log"
        exit 1
    fi
    rm -f public/legacy/config_si.php
    keys=public/legacy/Api/V8/OAuth2
    openssl genrsa -out "${keys}/private.key" 2048 2> /dev/null
    openssl rsa -in "${keys}/private.key" -pubout -out "${keys}/public.key" 2> /dev/null
    chown www-data:www-data "${keys}/private.key" "${keys}/public.key"
    chmod 600 "${keys}/private.key" "${keys}/public.key"
    # The state folder: root's, mode 700. The leading zeros clear the set-group-ID bit it takes from tmp/.
    if [ ! -e "${state}" ] && [ ! -L "${state}" ]; then
        mkdir "${state}" && chown root:root "${state}" && chmod 00700 "${state}"
    fi
    rm -f "${root}/.clouve-install-in-progress"
    log "install done"
fi

cd "${root}" || exit 1
(
    while :; do
        if ! state_has scheduler-held && ! state_has restore-in-progress; then
            su -s /bin/bash www-data -c 'php bin/console schedulers:run' > /dev/null 2>&1
        fi
        sleep 60
    done
) &
(
    while :; do
        if state_has restore-in-progress; then
            sleep 2
            continue
        fi
        setpriv --reuid=www-data --regid=www-data --init-groups -- php bin/console messenger:consume internal-async --time-limit=3600 --memory-limit=256M > /dev/null 2>&1 &
        worker=$!
        while kill -0 "${worker}" 2> /dev/null; do
            if state_has restore-in-progress; then kill "${worker}" 2> /dev/null; fi
            sleep 2
        done
        wait "${worker}" 2> /dev/null
        sleep 5
    done
) &

exec apache2-foreground
