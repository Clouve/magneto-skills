#!/usr/bin/env bash
# LimeSurvey skill: participants.sh
#
# Works on one survey's participant list: makes the list, adds people to it, counts them and lists them. It sends
# no email (invitations.sh does that), and it never prints an access code.
#
# Usage: participants.sh create-list --survey <id> [--yes-closes-the-open-survey]
#        participants.sh add --survey <id> [--csv | --json]       the people on stdin
#        participants.sh count --survey <id>
#        participants.sh list --survey <id> [--start N] [--limit N]
#
#   create-list  makes the survey's participant list. Once a survey has a list, only people on it can answer,
#                each with their own access code. On a draft that changes nothing for anyone yet, and it does not
#                activate the survey. On a survey that is ACTIVE and open, it closes the survey at once: everyone
#                who has the link and no access code sees "Enter access code". So there it changes nothing and
#                says so (exit 2), unless --yes-closes-the-open-survey is given, which the playbook gives only
#                after the admin was told exactly that and said yes.
#   add          reads the people from stdin, never from the command line: they are names and addresses.
#                CSV: a header row, then one person per row. The header names the columns; email has to be one of
#                them, and firstname, lastname and language are read too. JSON: an array of objects with the same
#                names. Without --csv or --json the format is guessed from the first character.
#                A row without a valid email address is skipped, and so is an address the list already has. The
#                counts say how many of each. LimeSurvey makes each person's access code.
#   count        how many people are on the list, and how many were invited, were reminded and have completed
#   list         each person's id, name, email address and state (email status, invited, reminded, completed),
#                50 per call unless --limit says otherwise (100 at most), from --start on. These are people's
#                details: run it only when the admin asks to see the list.
#
# The work runs inside the LimeSurvey container through LimeSurvey's own participant methods
# (remote/ls-participants.php, sent by run-in-limesurvey.sh), so encrypted fields are stored as LimeSurvey stores
# them.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    done
#   1    the survey or its list is not there, LimeSurvey refused, or a tool is missing (stderr says which)
#   2    add: nobody was added (every row was skipped). create-list: the survey is active and open, and nothing
#        was changed (see --yes-closes-the-open-survey)
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: participants.sh create-list --survey <id> [--yes-closes-the-open-survey]
       participants.sh add --survey <id> [--csv | --json]       (the people on stdin)
       participants.sh count --survey <id>
       participants.sh list --survey <id> [--start N] [--limit N]

Works on one survey's participant list. It sends no email and never prints an access code.

  create-list on a survey that is active and open closes it at once to everyone without an access code. It does
  that only with --yes-closes-the-open-survey, after the admin was told so and said yes.

  add reads a CSV (a header row with email, and firstname, lastname, language if you have them) or a JSON array
  of objects from stdin. Rows without a valid email address, and addresses already on the list, are skipped.

Exit codes: 0 done, 1 not there or refused, 2 nobody was added or an open survey was not closed, 64 usage,
75 LimeSurvey is starting or being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/participants] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
sid=''
format=''
start=0
limit=50
closes=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey)
            [ "$#" -ge 2 ] || usage_error "--survey needs the survey's id"
            sid="$2"
            shift 2
            ;;
        --survey=*) sid="${1#--survey=}"; shift ;;
        --yes-closes-the-open-survey) closes=true; shift ;;
        --csv) format=csv; shift ;;
        --json) format=json; shift ;;
        --start)
            [ "$#" -ge 2 ] || usage_error "--start needs a number"
            start="$2"
            shift 2
            ;;
        --limit)
            [ "$#" -ge 2 ] || usage_error "--limit needs a number"
            limit="$2"
            shift 2
            ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            [ -z "${action}" ] || usage_error "give one action"
            action="$1"
            shift
            ;;
    esac
done
case "${action}" in
    create-list | add | count | list) ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: ${action}" ;;
esac
[[ "${sid}" =~ ^[0-9]{1,9}$ ]] || usage_error "--survey needs the survey's id, a number"
[[ "${start}" =~ ^[0-9]{1,9}$ ]] || usage_error "--start needs a number"
[[ "${limit}" =~ ^[0-9]{1,3}$ ]] || usage_error "--limit needs a number up to 100"
if [ "${closes}" = true ] && [ "${action}" != create-list ]; then usage_error "--yes-closes-the-open-survey goes with create-list"; fi
for tool in jq base64; do
    command -v "${tool}" > /dev/null 2>&1 || { msg "${tool} is not installed (the limesurvey plugin's install.sh adds what the scripts need)"; exit 1; }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# call REQUEST: sends the request to ls-participants.php on the channel's stdin (printf is a builtin, so the request
# is in no command line); leaves the reply in reply, and exits on a failure
reply=''
call() {
    local rc error
    reply="$(printf '%s' "$1" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-participants.php)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
        if [ -n "${error}" ]; then msg "${error}"; fi
        exit "${rc}"
    fi
}

case "${action}" in
    create-list)
        call "$(jq -nc --argjson sid "${sid}" --argjson closes "${closes}" '{action: "create-list", sid: $sid, confirmed_closes_open_survey: $closes}')"
        if [ "$(jq -r '.result.refused // false' <<< "${reply}")" = true ]; then
            echo "Survey ${sid} is ACTIVE and open: anyone who has its address can answer it now ($(jq -r '.result.answers' <<< "${reply}") answer sets so far)."
            echo "A participant list closes it at once. From then on only the people on the list get in, each with their own access code, and everyone else sees \"Enter access code\"."
            echo "Nothing was changed. Tell the admin exactly that. After a clear yes, run this again with: --yes-closes-the-open-survey"
            exit 2
        fi
        if [ "$(jq -r '.result.created' <<< "${reply}")" = true ]; then
            if [ "$(jq -r '.result.active' <<< "${reply}")" = Y ]; then
                echo "Survey ${sid} now has a participant list, and it is CLOSED to everyone who is not on it. Only people on the list can answer, each with their own access code."
            else
                echo "Survey ${sid} now has a participant list. Only people on it can answer, each with their own access code."
            fi
        else
            echo "Survey ${sid} already has a participant list. Nothing was changed."
        fi
        ;;
    add)
        if [ -t 0 ]; then usage_error "add reads the people from stdin: a CSV or a JSON array"; fi
        # The people go from stdin into the request as base64. They are in no command line.
        people="$(base64 -w0)"
        [ -n "${people}" ] || { msg "nothing on stdin"; exit 64; }
        if [ -z "${format}" ]; then
            case "$(base64 -d <<< "${people}" 2> /dev/null | tr -d '[:space:]' | head -c 1)" in
                '[') format=json ;;
                *) format=csv ;;
            esac
        fi
        call "$(jq -Rc --argjson sid "${sid}" --arg format "${format}" '{action: "add", sid: $sid, format: $format, data_base64: .}' <<< "${people}")"
        jq -r '.result
            | "Added \(.added) of the people given. Skipped: \(.skipped_invalid) without a valid email address, \(.skipped_duplicate) already on the list" + (if .not_added > 0 then ", \(.not_added) that LimeSurvey did not take" else "" end) + ".",
              "The list now has \(.total) people."' <<< "${reply}"
        if [ "$(jq -r '.result.added' <<< "${reply}")" -eq 0 ]; then exit 2; fi
        ;;
    count)
        call "$(jq -nc --argjson sid "${sid}" '{action: "count", sid: $sid}')"
        jq -r '.result | "Survey '"${sid}"': \(.total) people on the list, \(.invited) invited, \(.reminded) reminded, \(.completed) completed" + (if .email_not_ok > 0 then ", \(.email_not_ok) with an email status that is not OK (they get no mail)" else "" end) + "."' <<< "${reply}"
        ;;
    list)
        call "$(jq -nc --argjson sid "${sid}" --argjson start "${start}" --argjson limit "${limit}" '{action: "list", sid: $sid, start: $start, limit: $limit}')"
        jq -r '.result | "People \(.start + 1) to \(.start + (.people | length)) of \(.total):",
            (.people[] | "  \(.id)\t\(.firstname) \(.lastname)\t\(.email)\temail \(.emailstatus)\tinvited \(.invited)\treminded \(.reminded)\tcompleted \(.completed)")' <<< "${reply}"
        ;;
esac
