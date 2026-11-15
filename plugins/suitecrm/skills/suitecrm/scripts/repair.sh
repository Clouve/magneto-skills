#!/usr/bin/env bash
# SuiteCRM skill: repair.sh
#
# SuiteCRM's Quick Repair and Rebuild (Admin > Repair > Quick Repair and Rebuild), from the shell, as the web
# user. It clears the legacy caches, rebuilds the extensions and audit tables, and compares the database with
# SuiteCRM's field definitions.
#
# Usage:
#   repair.sh [--module <Module>]
#   repair.sh [--module <Module>] --execute --yes-repair
#
#   Without --execute it is a dry run: the caches are cleared (that is safe), and the SQL that would bring
#   the tables in line with the field definitions is printed, not run.
#   --execute runs that SQL too. It changes tables, so it needs --yes-repair, and a backup made by this skill
#   in the last 24 hours (exit 76 without one). After the run it compares the database with the field
#   definitions once more: database_in_sync is what that second look finds, and sql_still_needed lists what
#   a repair would still run. When the database is still not in sync the exit code is 2, with the JSON.
#   --module limits the cache clearing to one module, named as in its address (Accounts, Opportunities).
#   The comparison with the database, and the SQL that --execute runs, always cover every module: that is
#   how SuiteCRM's own Quick Repair works.
#
# One more thing a repair clears, the dry run included: SuiteCRM's own cache folder (cache/prod), and with
# it the counters of the sign-in throttle, for every login and address at once. Someone who was refused
# after 5 wrong tries can sign in again right after a repair, and so can someone who was guessing.
#
# When it is needed: after a field, a layout, a language file or a logic hook was added or changed by hand;
# when a screen shows old labels or layouts; when SuiteCRM's log names a column that is missing. Module Loader
# and the image's upgrade run their own repair, so it is not needed after those.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, or --execute without --yes-repair; 76 no backup from the last 24 hours;
# 2 the repair stopped, or --execute ran and the database is still not in sync; 3 no such module; 70, 75,
# 255 from run-in-suitecrm.sh.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: repair.sh [--module <Module>]
       repair.sh [--module <Module>] --execute --yes-repair

Quick Repair and Rebuild as the web user. Without --execute it clears the caches and prints the SQL the
repair would run. With --execute --yes-repair it runs that SQL too, after a backup, then compares the
database with the field definitions again and reports what it finds (database_in_sync, sql_still_needed).
--module limits the cache clearing to one module; the database is always compared for every module.

Exit codes: 0 done; 64 usage or no yes; 76 no backup from the last 24 hours; 2 the repair stopped, or it ran
and the database is still not in sync; 3 no such module; 70 the script crashed; 75 SuiteCRM is being
installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/repair] %s\n' "$*" >&2; }

# The runner's php form says which script of the skill called it.
export SC_SKILL_CALLER=repair.sh
module=''
execute=0
yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --module)
            [[ ${2:-} =~ ^[A-Za-z0-9_]{1,60}$ ]] || { msg "--module needs a module name such as Accounts"; exit 64; }
            module="$2"
            shift 2
            ;;
        --execute) execute=1; shift ;;
        --yes-repair) yes=1; shift ;;
        *) msg "unknown argument: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"
if [ "${execute}" -eq 0 ]; then
    [ "${yes}" -eq 0 ] || { msg "--yes-repair goes with --execute"; exit 64; }
    exec "${run}" php repair.php dry ${module:+"${module}"}
fi
if [ "${yes}" -ne 1 ]; then
    msg "nothing was run. --execute runs the SQL that the dry run prints, which changes tables. Show that SQL to the user, and run this again with --execute --yes-repair after a clear yes."
    exit 64
fi
exec "${run}" --need-backup php repair.php execute ${module:+"${module}"}
