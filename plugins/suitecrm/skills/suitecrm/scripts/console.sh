#!/usr/bin/env bash
# SuiteCRM skill: console.sh
#
# Runs one command of SuiteCRM's bin/console in the SuiteCRM container, as www-data, over the clouve-ops SSH
# channel. Only the commands on the skill's allow-list run (lib/suitecrm-console.sh has the list and the
# reason for each refusal). The command's output and exit code pass through.
#
# Usage: console.sh <command> [arguments...]
#
# Allowed commands:
#   list, help <command>             what the console offers
#   suitecrm:version                 the installed version
#   cache:clear                      rebuilds Symfony's cache
#   schedulers:show                  the scheduled jobs
#   schedulers:run                   one scheduler pass (refused while the scheduler is held)
#   messenger:stats                  what the Messenger worker has queued
#   messenger:failed:show            messages that failed
#   messenger:failed:retry           retries them
#   suitecrm:pre-upgrade-migrations:list, doctrine:migrations:status, doctrine:migrations:list
#
# SuiteCRM 8.10.2's console has no command for records, users, imports, repairs or packages: use records.sh,
# users.sh, import-csv.sh, repair.sh and packages.sh. It can run SQL, drop the schema, and install or upgrade
# SuiteCRM, and all of that is refused here: the image installs and upgrades, sql-read.sh reads, and the
# other scripts write through SuiteCRM's own code.
#
# --no-interaction is always added, so a command never waits at a prompt. Every argument reaches the console
# as one word, unexpanded.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: the console's own; 64 no command, or a command or option that is refused; 70 the console
# crashed; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: console.sh <command> [arguments...]

Runs one command of SuiteCRM's bin/console as www-data in the SuiteCRM container. Allowed: list, help,
suitecrm:version, cache:clear, schedulers:show, schedulers:run, messenger:stats, messenger:failed:show,
messenger:failed:retry, suitecrm:pre-upgrade-migrations:list, doctrine:migrations:status,
doctrine:migrations:list. Everything else is refused, with the reason.

Exit codes: the console's own; 64 refused or no command; 70 it crashed; 75 SuiteCRM is being installed or
upgraded; 255 ssh failed.
USAGE
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runner's direct forms say that the skill's checks don't apply to them, unless a script of the skill calls.
export SC_SKILL_CALLER=console.sh
# shellcheck source=/dev/null
. "${script_dir}/lib/suitecrm-console.sh" || exit 1
refusal="$(sc_console_refusal "$@")"
if [ -n "${refusal}" ]; then
    printf '[suitecrm/console] refused: %s\n' "${refusal}" >&2
    exit 64
fi
exec "${script_dir}/run-in-suitecrm.sh" console "$@" --no-interaction
