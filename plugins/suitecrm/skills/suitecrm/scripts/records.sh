#!/usr/bin/env bash
# SuiteCRM skill: records.sh
#
# Creates, reads, updates, links, lists, deletes and brings back accounts, contacts, leads and opportunities.
# It works through SuiteCRM's own code (remote/records.php, run in the SuiteCRM container as the web user), so
# the module's logic, the audit trail, logic hooks and workflows apply as they do in the browser. It prints
# JSON on stdout and its messages on stderr.
#
# Usage:
#   records.sh fields <Module>
#   records.sh create <Module> [--allow-duplicate]                 fields as a JSON object on stdin
#   records.sh get <Module> <id>
#   records.sh update <Module> <id>                                fields as a JSON object on stdin
#   records.sh link <Module> <id> <link> <other id> [--role ROLE]
#   records.sh unlink <Module> <id> <link> <other id>
#   records.sh list <Module> [--search TEXT] [--assigned LOGIN] [--deleted] [--limit N] [--offset N]
#   records.sh delete <Module> <id> [--yes-delete]
#   records.sh undelete <Module> <id>
#
# <Module> is Accounts, Contacts, Leads or Opportunities.
#
#   fields     the fields that can be set, their types, which are required, and each dropdown's values.
#   create     makes one record. A field that isn't the module's, a value outside a dropdown, a bad date or
#              number, or a missing required field stops it before anything is written (exit 65). A record
#              that looks like an existing one (an account of the same name; a contact or lead with the same
#              email address or the same first and last name; an opportunity of the same name on the same
#              account) is not created: it prints the matches and ends with 4. --allow-duplicate creates it
#              anyway, once the user has said it is a different one. An opportunity needs account_id, or
#              account_name when exactly one account has that name: a name never creates an account here.
#              The output says who owns the new record: assigned_to is that person's login, and
#              assigned_by_default is true when no owner was sent (assigned_user_name with a login, or
#              assigned_user_id), so the record went to the main admin.
#   get        one record: every field that holds something, and its account, contact and opportunity links.
#   update     changes the fields given and prints each one's value before and after. A new sales_stage sent
#              without a probability takes the stage's own probability, as picking a stage does in the browser.
#   link       links two records: Accounts contacts|opportunities, Contacts accounts|opportunities,
#              Opportunities accounts|contacts. --role sets the contact's role on an opportunity.
#   unlink     removes that link. Both records stay.
#   list       up to 200 records, newest change first, with the total. --search matches the name (accounts,
#              opportunities) or the name and email address (contacts, leads). --deleted lists deleted ones.
#   delete     without --yes-delete it changes nothing: it prints the record and what is linked to it. With
#              it, SuiteCRM marks the record deleted (the row stays in the database, out of view).
#   undelete   brings a deleted record back, with its email addresses and its account, contact and
#              opportunity links. Other links the delete cut (calls, meetings, notes, cases) stay cut.
#
# Values go in a JSON object on stdin, never in the command line, so a name with quotes or a $ needs no
# shell quoting:
#   records.sh create Accounts <<'JSON'
#   {"name": "Globex Corporation", "account_type": "Prospect"}
#   JSON
#
# Numbers and dates have one form, going in and coming out, whatever number and date format the main admin's
# own profile uses: a decimal point and no thousands separator (1234.56), dates as YYYY-MM-DD, and times in UTC
# as YYYY-MM-DD HH:MM:SS. A field that holds whole numbers, such as an opportunity's probability, refuses a
# number with a fraction (exit 65).
#
# Everything this script writes is recorded as the main admin's own work: "created by", "modified by" and the
# audit trail name the main admin, not the person who asked.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done (a delete preview included); 64 usage; 65 bad input, nothing written; 2 SuiteCRM did not
# keep what was sent; 3 no such record; 4 a likely duplicate, nothing written; 70, 75, 255 from
# run-in-suitecrm.sh (the script crashed; SuiteCRM is being installed or upgraded; ssh failed).

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: records.sh fields <Module>
       records.sh create <Module> [--allow-duplicate]              fields as a JSON object on stdin
       records.sh get <Module> <id>
       records.sh update <Module> <id>                             fields as a JSON object on stdin
       records.sh link <Module> <id> <link> <other id> [--role ROLE]
       records.sh unlink <Module> <id> <link> <other id>
       records.sh list <Module> [--search TEXT] [--assigned LOGIN] [--deleted] [--limit N] [--offset N]
       records.sh delete <Module> <id> [--yes-delete]
       records.sh undelete <Module> <id>

<Module> is Accounts, Contacts, Leads or Opportunities. Works through SuiteCRM's own code, so module logic,
audit and workflows apply. Prints JSON.

create stops at a likely duplicate (exit 4) unless --allow-duplicate, and says who owns the new record
(assigned_to; assigned_by_default is true when no owner was sent and it went to the main admin). delete without
--yes-delete only shows what would go; with it the record is marked deleted, and undelete brings it back with
its email addresses and its account, contact and opportunity links.

Numbers take a decimal point and no thousands separator (1234.56), dates are YYYY-MM-DD, times are UTC as
YYYY-MM-DD HH:MM:SS, whatever the main admin's profile shows. What it writes is recorded as the main admin's work.

Exit codes: 0 done; 64 usage; 65 bad input; 2 SuiteCRM did not keep it; 3 no such record; 4 likely duplicate;
70 the script crashed; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/records] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run=("${script_dir}/run-in-suitecrm.sh")
# Tells run-in-suitecrm.sh that one of the skill's own scripts calls it.
export SC_SKILL_CALLER=records.sh

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    '') usage_error "no action given" ;;
esac
action="$1"
shift
module="${1:-}"
case "${module}" in
    Accounts | Contacts | Leads | Opportunities) shift ;;
    '') usage_error "no module given" ;;
    *) usage_error "the module must be Accounts, Contacts, Leads or Opportunities, not $(printf '%q' "${module}")" ;;
esac

# need_id VALUE: a record id is letters, digits, - and _
need_id() {
    if ! [[ ${1:-} =~ ^[A-Za-z0-9_-]{1,36}$ ]]; then usage_error "that is not a record id: $(printf '%q' "${1:-}")"; fi
}

case "${action}" in
    fields)
        [ "$#" -eq 0 ] || usage_error "fields takes only the module"
        exec "${run[@]}" php records.php fields "${module}"
        ;;
    create)
        dup=''
        case "${1:-}" in
            --allow-duplicate) dup=allow-duplicate; shift ;;
        esac
        [ "$#" -eq 0 ] || usage_error "create takes the fields as a JSON object on stdin, not as arguments"
        exec "${run[@]}" --stdin php records.php create "${module}" ${dup:+"${dup}"}
        ;;
    get | undelete)
        [ "$#" -eq 1 ] || usage_error "${action} takes one record id"
        need_id "$1"
        exec "${run[@]}" php records.php "${action}" "${module}" "$1"
        ;;
    update)
        [ "$#" -eq 1 ] || usage_error "update takes one record id, and the fields as a JSON object on stdin"
        need_id "$1"
        exec "${run[@]}" --stdin php records.php update "${module}" "$1"
        ;;
    link | unlink)
        [ "$#" -ge 3 ] || usage_error "${action} takes <id> <link> <other id>"
        need_id "$1"
        need_id "$3"
        id="$1" link="$2" other="$3"
        shift 3
        role=''
        if [ "${1:-}" = --role ]; then
            [ "${action}" = link ] || usage_error "--role goes with link"
            [ "$#" -eq 2 ] && [ -n "$2" ] || usage_error "--role needs a value"
            role="$2"
            shift 2
        fi
        [ "$#" -eq 0 ] || usage_error "too many arguments for ${action}"
        case "${link}" in
            accounts | contacts | opportunities) ;;
            *) usage_error "the link must be accounts, contacts or opportunities, not $(printf '%q' "${link}")" ;;
        esac
        exec "${run[@]}" php records.php "${action}" "${module}" "${id}" "${link}" "${other}" ${role:+"${role}"}
        ;;
    list)
        search='' assigned='' deleted=0 limit=20 offset=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --search) [ "$#" -ge 2 ] || usage_error "--search needs a value"; search="$2"; shift 2 ;;
                --assigned) [ "$#" -ge 2 ] || usage_error "--assigned needs a login"; assigned="$2"; shift 2 ;;
                --deleted) deleted=1; shift ;;
                --limit) [[ ${2:-} =~ ^[0-9]{1,3}$ ]] || usage_error "--limit needs a number from 1 to 200"; limit="$2"; shift 2 ;;
                --offset) [[ ${2:-} =~ ^[0-9]{1,9}$ ]] || usage_error "--offset needs a number"; offset="$2"; shift 2 ;;
                *) usage_error "unknown option for list: $(printf '%q' "$1")" ;;
            esac
        done
        exec "${run[@]}" php records.php list "${module}" "${search}" "${assigned}" "${deleted}" "${limit}" "${offset}"
        ;;
    delete)
        [ "$#" -ge 1 ] || usage_error "delete takes one record id"
        need_id "$1"
        confirm=preview
        if [ "${2:-}" = --yes-delete ]; then
            confirm=yes
            [ "$#" -eq 2 ] || usage_error "too many arguments for delete"
        elif [ "$#" -ne 1 ]; then
            usage_error "delete takes one record id, and --yes-delete after the user's yes"
        fi
        exec "${run[@]}" php records.php delete "${module}" "$1" "${confirm}"
        ;;
    *) usage_error "unknown action: $(printf '%q' "${action}")" ;;
esac
