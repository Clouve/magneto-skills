#!/bin/bash
# Entrypoint of the database stand-in (tests only): the clouve-ops sshd, then MariaDB's own entrypoint.
set -e
if [ -n "${CLOUVE_OPS_PASSWORD:-}" ]; then
    ssh-keygen -A > /dev/null 2>&1
    echo "clouve-ops:${CLOUVE_OPS_PASSWORD}" | chpasswd
    mkdir -p /run/sshd
    /usr/sbin/sshd
fi
unset CLOUVE_OPS_PASSWORD
exec docker-entrypoint.sh "$@"
