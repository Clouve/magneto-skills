#!/usr/bin/env bash
# LimeSurvey skill: delete.sh
#
# Deletes one thing in LimeSurvey: a survey, a group, a question, a language of a survey, people on a participant
# list, an answer set or a quota. Without the yes option it deletes nothing: it says what would go and what goes
# with it, and stops. rc.sh refuses LimeSurvey's own delete methods, so this is the one way the skill deletes.
#
# Usage: delete.sh survey --survey <id>
#        delete.sh group --survey <id> --group <id>
#        delete.sh question --question <id>
#        delete.sh language --survey <id> --language <code>
#        delete.sh participant --survey <id> --participant <id> [--participant <id>]...
#        delete.sh response --survey <id> --response <id>
#        delete.sh quota --quota <id>
#        ... and to delete, after the admin's yes:  --yes-delete
#
#   survey       the survey with everything that belongs to it: its questions, its answers, its participant list,
#                the files participants uploaded. The preview gives the counts.
#   group        a group with its questions. LimeSurvey refuses this on an active survey.
#   question     a question (or a subquestion) with its subquestions and answer options. Refused on an active
#                survey, and when a condition of another question relies on it.
#   language     one additional language of a survey, with every text in it. The base language stays.
#   participant  people on a survey's participant list, by their ids (participants.sh list shows them). Their
#                invitation links stop working. Answers they gave stay.
#   response     one answer set, by its id.
#   quota        a quota. No answer is deleted.
#
# A delete cannot be undone, except by restoring a backup, which puts the whole site back to that backup. So the
# order is: back up (run-in-limesurvey.sh backup.sh), show the admin the preview's lines, wait for a clear yes
# that names the thing, then run the same command with --yes-delete.
#
# No name, address, access code or answer is printed.
#
# The work runs inside the LimeSurvey container (remote/ls-change.php, sent by run-in-limesurvey.sh), through
# LimeSurvey's own delete methods.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    the preview shows nothing that stops the delete; or, with --yes-delete, it is deleted
#   2    it cannot be deleted as things are (the reasons are printed); nothing was changed
#   1    the thing is not there, LimeSurvey refused, or a tool is missing
#   64   usage
#   75   LimeSurvey is starting, or being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: delete.sh survey --survey <id>
       delete.sh group --survey <id> --group <id>
       delete.sh question --question <id>
       delete.sh language --survey <id> --language <code>
       delete.sh participant --survey <id> --participant <id> [--participant <id>]...
       delete.sh response --survey <id> --response <id>
       delete.sh quota --quota <id>
       ... and to delete, after the admin's yes:  --yes-delete

Without --yes-delete it deletes nothing: it says what would go and what goes with it. A delete cannot be undone
except by restoring a backup of the whole site, so back up first, show the admin the preview, and wait for a
clear yes.

Exit codes: 0 fine, 2 cannot be deleted as things are, 1 not there or refused, 64 usage, 75 LimeSurvey is
starting or being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/delete] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

kind=''
sid=''
gid=''
qid=''
language=''
response=''
quota=''
confirmed=false
participants=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --yes-delete) confirmed=true; shift ;;
        --survey | --group | --question | --participant | --response | --quota)
            [ "$#" -ge 2 ] || usage_error "$1 needs an id"
            [[ "$2" =~ ^[0-9]{1,9}$ ]] || usage_error "$1 needs an id, a number"
            case "$1" in
                --survey) sid="$2" ;;
                --group) gid="$2" ;;
                --question) qid="$2" ;;
                --participant) participants+=("$2") ;;
                --response) response="$2" ;;
                --quota) quota="$2" ;;
            esac
            shift 2
            ;;
        --language)
            [ "$#" -ge 2 ] || usage_error "--language needs a language code"
            [[ "$2" =~ ^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$ ]] || usage_error "--language needs a code such as de or pt-BR"
            language="$2"
            shift 2
            ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            [ -z "${kind}" ] || usage_error "give one kind of thing to delete"
            kind="$1"
            shift
            ;;
    esac
done
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

# need NAME VALUE: a usage error when the option the kind needs is missing
need() { [ -n "$2" ] || usage_error "delete.sh ${kind} needs $1"; }
base='{action: "delete", kind: $kind, confirmed: $confirmed}'
case "${kind}" in
    survey)
        need --survey "${sid}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson sid "${sid}" "${base} + {sid: \$sid}")"
        ;;
    group)
        need --survey "${sid}"
        need --group "${gid}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson sid "${sid}" --argjson gid "${gid}" "${base} + {sid: \$sid, gid: \$gid}")"
        ;;
    question)
        need --question "${qid}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson qid "${qid}" "${base} + {qid: \$qid}")"
        ;;
    language)
        need --survey "${sid}"
        need --language "${language}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson sid "${sid}" --arg language "${language}" "${base} + {sid: \$sid, language: \$language}")"
        ;;
    participant)
        need --survey "${sid}"
        [ "${#participants[@]}" -gt 0 ] || usage_error "delete.sh participant needs --participant (participants.sh list shows the ids)"
        ids="$(printf '%s\n' "${participants[@]}" | jq -Rnc '[inputs | tonumber]')"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson sid "${sid}" --argjson ids "${ids}" "${base} + {sid: \$sid, ids: \$ids}")"
        ;;
    response)
        need --survey "${sid}"
        need --response "${response}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson sid "${sid}" --argjson id "${response}" "${base} + {sid: \$sid, id: \$id}")"
        ;;
    quota)
        need --quota "${quota}"
        request="$(jq -nc --arg kind "${kind}" --argjson confirmed "${confirmed}" --argjson id "${quota}" "${base} + {id: \$id}")"
        ;;
    '') usage_error "say what to delete: survey, group, question, language, participant, response or quota" ;;
    *) usage_error "delete.sh deletes a survey, group, question, language, participant, response or quota, not $(printf '%q' "${kind}")" ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-change.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi
result="$(jq -c '.result' <<< "${reply}")"

if [ "$(jq -r '.deleted' <<< "${result}")" = true ]; then
    jq -r '"Deleted: \(.what).", "It took with it:", (.goes_with[] | "  - " + .)' <<< "${result}"
    exit 0
fi
jq -r '"This would delete: \(.what).", "With it go:", (.goes_with[] | "  - " + .)' <<< "${result}"
if [ "$(jq -r '.blockers | length' <<< "${result}")" -gt 0 ]; then
    echo "It cannot be deleted as things are:"
    jq -r '.blockers[] | "  - " + .' <<< "${result}"
    echo "Nothing was deleted."
    exit 2
fi
echo "Nothing was deleted. This was the preview."
echo "A delete cannot be undone, except by restoring a backup of the whole site. Back up first (run-in-limesurvey.sh backup.sh)."
echo "Show the admin the lines above. After a clear yes, run the same command again with: --yes-delete"
exit 0
