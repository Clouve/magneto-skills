#!/usr/bin/env bash
# SuiteCRM skill: import-csv.sh
#
# Imports a CSV file of accounts, contacts, leads or opportunities through SuiteCRM's own Import module (the
# one behind the Import screen), in two steps: a plan that imports nothing, then the import of exactly that
# plan after the user's yes. It also lists the skill's imports, and undoes one of them by its receipt id.
#
# Usage:
#   import-csv.sh plan <Module> <file.csv> [--dup-fields f1,f2|none] [--update]
#   import-csv.sh run <Module> <file.csv> --plan <plan id> [--dup-fields f1,f2|none] [--update] --yes-import
#   import-csv.sh last <Module>
#   import-csv.sh undo <Module> <receipt id> [--yes-undo]
#
# <Module> is Accounts, Contacts, Leads or Opportunities. The file is on the agent, usually one the user put
# in the Files pane. It needs a header line, commas between cells, double quotes around a cell that holds a
# comma (a double quote inside a cell is written twice), UTF-8 text, numbers with a decimal point and no
# thousands separator (1234.56), dates as YYYY-MM-DD, and at most 20 MB and 50,000 rows. Numbers and dates
# are read that way whatever number and date format the main admin's own profile uses.
#
#   plan   reads the file and prints, as JSON: plan_id and file_sha256 (the plan is kept in SuiteCRM's tmp
#          folder with the file's checksum); how many rows it has; which column goes to which field (a
#          header cell is matched to a field by its name, such as last_name, or by its label, such as "Last
#          Name"); the columns that are not imported and why; required fields the file lacks; the likely
#          duplicates (already in SuiteCRM, or twice in the file); the accounts the import would create by
#          name; who the rows will belong to (rows_will_belong_to: the users named in an assigned_user_name
#          column, else the main admin); the cells that start with =, +, - or @ (formula_cells: they are
#          stored as given, and SuiteCRM's own CSV export writes them out unchanged); the active workflows
#          that run for the imported rows, with their actions and whether they send email
#          (workflows_that_run); the rows with a problem (a bad email address; a cell that ends in a
#          backslash, which SuiteCRM's CSV reader can't read; an assigned_user_name that is no user's
#          login); whether the file is ready; and all of it in words (what_the_import_does). Show this to
#          the user.
#   run    imports the file the plan was made for. --plan takes the plan_id that plan printed. It refuses
#          (exit 65, nothing written) when the file, the module, --update or the duplicate fields differ
#          from the plan, when the plan is older than 24 hours, and when a run has used the plan already (it
#          names that run: a repeated command does not import twice). Rows SuiteCRM finds to be duplicates
#          or invalid are skipped and reported with their line in the file. It prints the run's receipt id.
#          It needs --yes-import, and a backup made by this skill in the last 24 hours
#          (run-in-suitecrm.sh backup.sh): exit 76 without one.
#   last   the skill's imports into the module, newest first: receipt, made_utc, mode (import or update),
#          state (done, undone, or started for a run that is going on or was cut off), the counts, can_undo
#          and why_not.
#   undo   without --yes-undo it removes nothing: it prints what an undo of that one run would remove (how
#          many records in which modules, the accounts the import made by name), whether it can be undone
#          and, if not, why. Exit 64 when it can be undone, the refusal's own code when it can't. With
#          --yes-undo, and a recent backup, it removes exactly the records that run created, once, and marks
#          the receipt undone. The records are deleted from the database for good, with every edit people
#          made to them since: no undelete brings them back. It does not put back what an --update run
#          changed. It refuses: a run that is undone already or created nothing (exit 3); an --update run, a
#          run that did not finish, a run whose records SuiteCRM no longer tracks (an import the admin starts
#          in SuiteCRM's own Import screen clears that tracking, and so does restoring a backup from before
#          the import; an import by this skill never does), and a run that is not the newest import still
#          standing (exit 2: it names the newer one; newer imports are undone first, each with its own yes).
#          A receipt id that does not exist, or is of another module, is exit 3.
#
#   --dup-fields  the fields of the duplicate check: a row is skipped when a record with the same value in
#                 one of them exists. Default: name for Accounts and Opportunities, email1 for Contacts and
#                 Leads. "none" turns the check off.
#   --update      the file changes existing records and has an id column. An update has no undo.
#
# What to tell the user before the yes (the plan says it too): the import creates an account that is missing
# when a contact or an opportunity names one in account_name; duplicates are skipped, not merged; who the
# new records will belong to; which workflows run and how many emails they send; and the undo deletes for
# good. Everything the import writes is recorded as the main admin's own work.
#
# One import or undo runs at a time: a second one is refused (exit 2) until the first ends.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, the yes is missing (an undo's preview of a run that can be undone included),
# or the file can't be read; 65 the file can't be imported as it is, or it does not fit the plan (nothing was
# written); 76 no backup from the last 24 hours; 2 the importer failed, another import or undo is running, or
# the run can't be undone (an update, a run that did not finish, records SuiteCRM no longer tracks, or a
# newer import still stands); 3 no such run in that module, or it is undone already, or it created nothing;
# 70, 75, 255 from run-in-suitecrm.sh.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: import-csv.sh plan <Module> <file.csv> [--dup-fields f1,f2|none] [--update]
       import-csv.sh run <Module> <file.csv> --plan <plan id> [--dup-fields f1,f2|none] [--update] --yes-import
       import-csv.sh last <Module>
       import-csv.sh undo <Module> <receipt id> [--yes-undo]

Imports a CSV file through SuiteCRM's own Import module. plan imports nothing and prints a plan_id, the column
mapping, the row count, likely duplicates, the accounts the import would create by name, who the rows will
belong to, formula cells and the workflows that run. run imports the file that plan was made for (after the
user's yes and a backup) and prints a receipt id. last lists the skill's imports with their receipt ids. undo
shows what an undo of one run would remove, and with --yes-undo removes exactly that, for good.

Exit codes: 0 done; 64 usage or no yes; 65 the file is not ready or does not fit the plan; 76 no backup from
the last 24 hours; 2 failed, another import is running, or the run can't be undone; 3 no such run, undone
already, or it created nothing; 70 the script crashed; 75 SuiteCRM is being installed or upgraded; 255 ssh
failed.
USAGE
}

msg() { printf '[suitecrm/import-csv] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"
# Tells run-in-suitecrm.sh that one of the skill's own scripts calls it.
export SC_SKILL_CALLER=import-csv.sh

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    plan | run | last | undo) action="$1"; shift ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: $(printf '%q' "$1")" ;;
esac
module="${1:-}"
case "${module}" in
    Accounts | Contacts | Leads | Opportunities) shift ;;
    *) usage_error "the module must be Accounts, Contacts, Leads or Opportunities" ;;
esac

case "${action}" in
    last)
        [ "$#" -eq 0 ] || usage_error "last takes only the module"
        exec "${run}" php import.php last "${module}"
        ;;
    undo)
        receipt="${1:-}"
        case "${receipt}" in
            '' | -*) usage_error "nothing was removed. undo needs the receipt id of the import to undo: import-csv.sh undo ${module} <receipt id>. import-csv.sh last ${module} lists the imports with their receipt ids." ;;
        esac
        if ! [[ ${receipt} =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
            usage_error "nothing was removed. That is not a receipt id: $(printf '%q' "${receipt}"). import-csv.sh last ${module} lists them."
        fi
        shift
        case "$#:${1:-}" in
            0:) exec "${run}" php import.php undo "${module}" "${receipt}" preview ;;
            1:--yes-undo) exec "${run}" --need-backup php import.php undo "${module}" "${receipt}" yes ;;
            *) usage_error "nothing was removed. undo takes the module, one receipt id, and --yes-undo after the user's yes" ;;
        esac
        ;;
esac

[ "$#" -ge 1 ] || usage_error "${action} needs the CSV file"
file="$1"
shift
# A path from the Files pane is often written ~/name, and inside quotes the shell leaves the ~ as it is.
# shellcheck disable=SC2088  # the pattern is a literal ~/ on purpose
case "${file}" in "~/"*) file="${HOME}/${file#"~/"}" ;; esac
mode=import
dups=default
yes=0
plan=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --update) mode=update; shift ;;
        --dup-fields)
            [[ ${2:-} =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]] || usage_error "--dup-fields takes field names separated by commas, or none"
            dups="$2"
            shift 2
            ;;
        --plan)
            [[ ${2:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || usage_error "--plan takes the plan_id that import-csv.sh plan printed"
            plan="$2"
            shift 2
            ;;
        --yes-import) yes=1; shift ;;
        *) usage_error "unknown option: $(printf '%q' "$1")" ;;
    esac
done
if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    usage_error "can't read the file $(printf '%q' "${file}")"
fi
size="$(stat -c %s -- "${file}" 2> /dev/null || echo 0)"
[ "${size}" -gt 0 ] || usage_error "the file is empty"
[ "${size}" -le 20971520 ] || usage_error "the file is larger than 20 MB; split it"

if [ "${action}" = plan ]; then
    [ "${yes}" -eq 0 ] || usage_error "--yes-import goes with run"
    [ -z "${plan}" ] || usage_error "--plan goes with run"
    "${run}" --stdin php import.php plan "${module}" "${mode}" "${dups}" < "${file}"
    exit $?
fi
if [ "${yes}" -ne 1 ] || [ -z "${plan}" ]; then
    msg "nothing was imported. Run the plan first (import-csv.sh plan ${module} <file>), show the user its row count, column mapping, likely duplicates, the accounts it would create, who the rows will belong to and the workflows that run, and run this again with --plan <the plan_id it printed> and --yes-import after a clear yes."
    exit 64
fi
"${run}" --stdin --need-backup php import.php run "${module}" "${mode}" "${dups}" "${plan}" < "${file}"
exit $?
