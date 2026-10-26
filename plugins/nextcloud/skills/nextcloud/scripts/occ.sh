#!/usr/bin/env bash
# Nextcloud DevOps Skill: occ.sh
#
# Runs one occ command in the Nextcloud container, as www-data, over the
# clouve-ops SSH channel. occ's stdout and stderr pass through untouched and
# the exit code is occ's. The scripts that run on the agent and need occ go
# through this one.
#
# Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>
#
#   --password-stdin  Reads one line from stdin and hands it to occ as NC_PASS,
#                     for occ's --password-from-env options. The line travels as
#                     the first line of the SSH channel's stdin, so it is never
#                     in a command line, here or in the container. An empty line
#                     is a usage error.
#   --init-lock       Runs occ under flock on the image's init lock,
#                     /var/www/html/nextcloud-init-sync.lock. The container's
#                     health probe reports healthy while that lock is held, so a
#                     long `upgrade` isn't killed as unhealthy.
#   --                Ends occ.sh's own options. From the first other argument on,
#                     everything goes to occ unchanged, so occ's own `--` and
#                     `--help` keep their meaning.
#
# The remote command is
#   sudo -n -u www-data php /var/www/html/occ --no-interaction --no-warnings ARGS
# and with --password-stdin
#   IFS= read -r NC_PASS && export NC_PASS && exec sudo -n --preserve-env=NC_PASS -u www-data ...
# Each of ARGS is quoted with printf %q. The clouve-ops login shell in the
# container is bash and decodes that quoting, so a uid, group, display name or
# path with spaces, quotes, $, ;, &, a newline or non-ASCII letters reaches occ
# as one argument, unexpanded. Without --password-stdin the SSH call gets -n,
# so stdin is closed.
#
# ssh is called with the options in lib/nextcloud-ssh.sh, which keeps no known_hosts file because the containers
# make new host keys at every start. Scripts that call ssh themselves (verify-health.sh) source the same file.
#
# Env vars read:
#   NEXTCLOUD_HOST       pod-internal hostname of the Nextcloud container
#   CLOUVE_OPS_PASSWORD  for sshpass -e. A current agent keeps it out of the
#                        environment; the loader line below fetches it then.
#
# Exit codes:
#   occ's own  whatever occ exited with, failures included
#   1          NEXTCLOUD_HOST or the ops password is not set
#   64         usage: no occ command, or --password-stdin with an empty line
#   255        ssh could not reach or log in to clouve-ops@<host>; stderr says so
#
# Telling an ssh failure from occ's own 255 or 5: ssh exits 255 when it fails
# itself, and sshpass exits 5 for a wrong password and 6 or 7 for a host key it
# won't accept. But occ also ends with 255 after a PHP fatal error, and
# `occ upgrade` ends with 5 when it fails (ERROR_FAILURE, core/Command/Upgrade.php
# in v35.0.2). So after 5, 6, 7 or 255, one more call of `true` over ssh shows
# whether the channel works. Only when it doesn't does occ.sh report it. An
# unreachable host therefore takes two connection attempts, up to 20 seconds.

# No -e: ssh's exit status is the result, and it is read below.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>

Runs one occ command in the Nextcloud container, as www-data, over the
clouve-ops SSH channel. occ's output and exit code pass through.

  --password-stdin  read one line from stdin and give it to occ as NC_PASS,
                    for --password-from-env; it never appears in a command line
  --init-lock       run occ under the image's init lock (use it for upgrade)
  --                end of occ.sh's own options

Examples:
  occ.sh status --output=json
  occ.sh user:info -- alice
  printf '%s\n' "$pw" | occ.sh --password-stdin user:resetpassword --password-from-env -- alice
  occ.sh list                  (occ.sh help <command> describes one command)

Needs NEXTCLOUD_HOST and the clouve-ops password the agent holds.
EOF
}

password_stdin=0
init_lock=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --password-stdin) password_stdin=1; shift ;;
        --init-lock) init_lock=1; shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ "$#" -eq 0 ]; then
    echo "[nextcloud/occ] no occ command given" >&2
    usage >&2
    exit 64
fi

if [ -z "${NEXTCLOUD_HOST:-}" ]; then
    echo "[nextcloud/occ] NEXTCLOUD_HOST is not set" >&2
    exit 1
fi

# The line is kept byte for byte (IFS= and -r). -s keeps a terminal from echoing it.
nc_pass=""
if [ "${password_stdin}" -eq 1 ]; then
    IFS= read -rs nc_pass || [ -n "${nc_pass}" ]
    if [ -z "${nc_pass}" ]; then
        echo "[nextcloud/occ] --password-stdin needs the password as the first line of stdin" >&2
        exit 64
    fi
fi

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
if [ -z "${CLOUVE_OPS_PASSWORD}" ]; then
    echo "[nextcloud/occ] CLOUVE_OPS_PASSWORD is not set; clv-secret --list shows the passwords this agent has" >&2
    exit 1
fi

target="clouve-ops@${NEXTCLOUD_HOST}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/nextcloud-ssh.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/nextcloud-ssh.sh" || exit 1
mapfile -t ssh_opts < <(nc_ssh_options)

if [ "${password_stdin}" -eq 1 ]; then
    remote='IFS= read -r NC_PASS && export NC_PASS && exec sudo -n --preserve-env=NC_PASS -u www-data'
else
    remote='sudo -n -u www-data'
fi
if [ "${init_lock}" -eq 1 ]; then
    remote+=' flock /var/www/html/nextcloud-init-sync.lock'
fi
remote+=' php /var/www/html/occ --no-interaction --no-warnings'
for arg in "$@"; do
    printf -v quoted ' %q' "${arg}"
    remote+="${quoted}"
done

# SSHPASS is set on the sshpass command only. The password line comes from a
# process substitution, which is a pipe: no file, and printf is a builtin, so
# no argv either.
if [ "${password_stdin}" -eq 1 ]; then
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "${remote}" < <(printf '%s\n' "${nc_pass}")
    rc=$?
else
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n "${ssh_opts[@]}" "${target}" "${remote}"
    rc=$?
fi

case "${rc}" in
    5 | 6 | 7 | 255)
        if ! SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n "${ssh_opts[@]}" "${target}" true > /dev/null 2>&1; then
            echo "[nextcloud/occ] could not reach ${target}" >&2
            exit 255
        fi
        ;;
esac
exit "${rc}"
