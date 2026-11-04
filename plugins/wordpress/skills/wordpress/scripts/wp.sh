#!/usr/bin/env bash
# WordPress DevOps Skill: wp.sh
#
# Runs one wp-cli command in the WordPress container, as www-data, over the clouve-ops SSH
# channel, with WordPress's own database settings. wp's stdout and stderr pass through untouched
# and the exit code is wp's. Run every wp command through it: a plain `sudo -u www-data wp ...`
# over SSH can't reach the database (lib/wp-remote.sh says why).
#
# Usage: wp.sh [--] <wp arguments...>
#
#   --   Ends wp.sh's own options, so a wp command can start with -h or --help
#        (wp.sh -- --help). Any other first argument already starts the wp command, wp's own
#        options included (wp.sh --skip-plugins plugin list).
#
# The remote command is lib/wp-remote.sh's: the WORDPRESS_* settings of the container's first
# process go into wp's environment, never onto a command line, and then
#   sudo -n --preserve-env=<their names> -u www-data wp --path=/var/www/html ARGS
# Each of ARGS is quoted with printf %q, so a URL, a search string or a path with spaces, quotes,
# $, ;, &, a newline or a * reaches wp as one argument, unexpanded. stdin is closed (ssh -n).
#
# Since wp sees WordPress's real settings, `config list` and `config get` of DB_PASSWORD or any
# *_KEY or *_SALT would print secrets into the chat: wp.sh refuses them with exit 64.
# `config list --fields=name` (the names only) and `config has <NAME>` are fine.
#
# ssh takes the host key the container shows and keeps none (StrictHostKeyChecking=accept-new,
# UserKnownHostsFile=/dev/null), since the containers can make new host keys at a start, and
# LogLevel=ERROR keeps ssh's notice about that key off stderr.
#
# Env vars read:
#   WORDPRESS_HOST       the WordPress container (required)
#   CLOUVE_OPS_PASSWORD  the clouve-ops password, for sshpass -e (never printed). A current
#                        agent keeps it out of the environment; the loader line below fetches it.
#
# Exit codes:
#   wp's own  whatever wp exited with, failures included
#   1         WORDPRESS_HOST or the clouve-ops password isn't set, or ssh or sshpass is missing
#   64        usage: no wp command, or one that would print a secret (above)
#   255       the SSH connection to the WordPress container failed; stderr says so
#
# Telling an SSH failure from wp's own 255: ssh exits 255 when it fails itself, and sshpass exits
# 5 for a wrong password and 6 or 7 for a host key it won't accept. wp-cli also ends with 255
# after a PHP fatal error. So after 5, 6, 7 or 255, one more call of `true` over ssh shows whether
# the channel works, and only when it doesn't does wp.sh say so.

# No -e: ssh's exit status is the result, and it is read below.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage: wp.sh [--] <wp arguments...>

Runs one wp-cli command in the WordPress container, as www-data, over the clouve-ops SSH
channel, with WordPress's own database settings. wp's output and exit code pass through.

  --   end of wp.sh's own options (wp.sh -- --help shows wp's help)

It refuses config list and config get of DB_PASSWORD, a key or a salt: they would print
secrets. config list --fields=name and config has <NAME> are fine.

Examples:
  wp.sh core version
  wp.sh option get siteurl
  wp.sh plugin list --status=active
  wp.sh search-replace 'https://old.example.com' 'https://new.example.com' --skip-columns=guid --dry-run

Needs WORDPRESS_HOST and the clouve-ops password the agent holds.
EOF
}

msg() { printf '[wordpress/wp] %s\n' "$*" >&2; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

if [ "$#" -eq 0 ]; then
    msg "no wp command given"
    usage >&2
    exit 64
fi

# wp gets WordPress's real settings, so a command that prints wp-config.php's constants would put
# the database password, the keys and the salts into the chat: `config list` (unless it shows only
# the names) and `config get` of DB_PASSWORD or any *_KEY or *_SALT are refused. The command words
# are the arguments that don't start with -, so a wp option before them changes nothing.
refuse() {
    msg "refused: wp.sh $1 would print the database password, a key or a salt into the chat."
    msg "Use 'wp.sh config has <NAME>' to see whether a constant is set, or 'wp.sh config list --fields=name' for the names."
    exit 64
}
words=()
names_only=0
for arg in "$@"; do
    case "${arg}" in
        --fields=name | --field=name) names_only=1 ;;
        -*) ;;
        *) words+=("${arg}") ;;
    esac
done
if [ "${words[0]:-}" = config ]; then
    case "${words[1]:-}" in
        list) [ "${names_only}" -eq 1 ] || refuse "config list" ;;
        get)
            constant="${words[2]:-}"
            case "${constant^^}" in
                DB_PASSWORD | *_KEY | *_SALT) refuse "config get ${constant}" ;;
            esac
            ;;
    esac
fi

if [ -z "${WORDPRESS_HOST:-}" ]; then
    msg "WORDPRESS_HOST is not set (compgen -e | grep -i wordpress lists the names this agent has)"
    exit 1
fi

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
if [ -z "${CLOUVE_OPS_PASSWORD:-}" ]; then
    msg "CLOUVE_OPS_PASSWORD is not set, so there is no clouve-ops shell to use (clv-secret --list shows the passwords this agent has)"
    exit 1
fi
if ! command -v sshpass > /dev/null 2>&1 || ! command -v ssh > /dev/null 2>&1; then
    msg "sshpass or ssh is not installed (the wordpress plugin's install.sh adds them)"
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wp-remote.sh
. "${script_dir}/lib/wp-remote.sh" || { msg "could not load lib/wp-remote.sh next to wp.sh"; exit 1; }

remote="$(wp_remote_command "$@")"

# SSHPASS is set on the sshpass command only, so the password is on no command line. The options
# are written out on each ssh line, where tests/lib/ssh-host-key-check.py can check them.
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "clouve-ops@${WORDPRESS_HOST}" "${remote}"
rc=$?

case "${rc}" in
    5 | 6 | 7 | 255)
        if ! SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "clouve-ops@${WORDPRESS_HOST}" true > /dev/null 2>&1; then
            msg "could not reach clouve-ops@${WORDPRESS_HOST} over SSH (reference/shell-access.md has the probe and the failure modes)"
            exit 255
        fi
        ;;
esac
exit "${rc}"
