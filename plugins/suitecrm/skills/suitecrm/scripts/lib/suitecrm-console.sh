# shellcheck shell=bash
# SuiteCRM skill: lib/suitecrm-console.sh (sourced by console.sh and run-in-suitecrm.sh, not run)
#
# The allow-list for SuiteCRM's bin/console. SuiteCRM 8.10.2's console has no command for records, users,
# imports or repairs (the skill's other scripts do those), and several of its commands destroy data or print
# secrets. So only the commands below run, and everything else is refused by name.
#
# sc_console_refusal COMMAND [args...]
#   Prints why the command is refused, or nothing when it may run. Sourcing this file defines that one
#   function and nothing else.
#
# Allowed:
#   list, help                       what the console offers
#   suitecrm:version                 the installed version
#   cache:clear                      rebuilds Symfony's cache (safe, takes a few seconds)
#   schedulers:show                  the scheduled jobs
#   schedulers:run                   one scheduler pass, as the image's loop runs it (scheduler.sh refuses it
#                                    while the scheduler is held)
#   messenger:stats                  what the Messenger worker has queued
#   messenger:failed:show            messages that failed
#   messenger:failed:retry           retries them (needs -n or an id; it asks otherwise)
#   suitecrm:pre-upgrade-migrations:list, doctrine:migrations:status, doctrine:migrations:list  reads
#
# Refused, with the reason:
#   suitecrm:app:install, suitecrm:app:upgrade, suitecrm:app:upgrade-finalize, suitecrm:app:setup-legacy-migration,
#   suitecrm:pre-upgrade-migrations:run-*, doctrine:migrations:migrate and the other migration writers:
#       the image installs and upgrades SuiteCRM at its start
#   doctrine:schema:*, doctrine:database:*, doctrine:mapping:import|convert: they drop or rewrite tables that
#       are not Doctrine's
#   dbal:run-sql, doctrine:query:sql, doctrine:query:dql: they run any SQL, writes included; sql-read.sh reads
#   secrets:*, debug:dotenv, debug:container, debug:config, about: they print the app secret or the database URL
#   messenger:consume, messenger:stop-workers, messenger:setup-transports: the image runs the worker
#   everything else: not on the list

sc_console_refusal() {
    local cmd="${1:-}" arg
    for arg in "$@"; do
        case "${arg}" in
            --env | --env=* | -e | -e?* | --no-debug | --profile)
                echo "the option ${arg%%=*} changes how the console starts; leave it out"
                return 0
                ;;
        esac
    done
    case "${cmd}" in
        list | help | suitecrm:version | cache:clear | schedulers:show | schedulers:run | messenger:stats | \
            messenger:failed:show | messenger:failed:retry | suitecrm:pre-upgrade-migrations:list | \
            doctrine:migrations:status | doctrine:migrations:list)
            return 0
            ;;
        suitecrm:app:* | suitecrm:pre-upgrade-migrations:run-* | doctrine:migrations:*)
            echo "the image installs and upgrades SuiteCRM at its start; ${cmd} is never run by hand"
            ;;
        doctrine:schema:* | doctrine:database:* | doctrine:mapping:*)
            echo "${cmd} drops or rewrites tables: SuiteCRM's own tables are not Doctrine's"
            ;;
        dbal:run-sql | doctrine:query:*)
            echo "${cmd} runs any SQL, writes included; read with sql-read.sh and write through the skill's scripts"
            ;;
        secrets:* | debug:* | about | config:dump-reference)
            echo "${cmd} can print the app secret or the database URL"
            ;;
        messenger:consume | messenger:stop-workers | messenger:setup-transports | messenger:failed:remove)
            echo "the image runs the Messenger worker; ${cmd} is not run by hand"
            ;;
        '')
            echo "no console command given"
            ;;
        *)
            echo "${cmd} is not on this skill's list of console commands (console.sh --help shows it)"
            ;;
    esac
    return 0
}
