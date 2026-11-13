#!/usr/bin/env bash
# LimeSurvey skill: survey-activate.sh
#
# Activates a survey: from then on people can answer it. Without the yes option it activates nothing: it shows
# what would go live and stops. rc.sh refuses LimeSurvey's own activate_survey method, so this is the one way the
# skill activates a survey.
#
# Usage: survey-activate.sh <survey id>                   shows what would go live, changes nothing
#        survey-activate.sh <survey id> --yes-activate    activates the survey
#
# The preview shows the survey's title and id, how many groups and questions it has, who can answer it (anyone
# with the link, or only the people on its participant list), whether answers are anonymized, its end date, the
# sender of its emails and its public address. Show the admin those lines and wait for a clear yes. Then run the
# same command with --yes-activate.
#
# What activation means, for the admin to hear first:
#   - People can answer the survey from that moment.
#   - A survey without a participant list is open to anyone who has its address. For named people only, make the
#     list first (participants.sh create-list), then activate.
#   - Once it is active, groups and questions can no longer be added or removed, and "anonymized" can no longer
#     be changed. Taking it back means deactivating it in LimeSurvey, which archives the answers.
#
# It refuses, and the preview says so, when the survey is active already, has no questions, or has an end date
# that is past.
#
# The work runs inside the LimeSurvey container (remote/ls-change.php, sent by run-in-limesurvey.sh), through
# LimeSurvey's own activation.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    the preview shows nothing that stops an activation; or, with --yes-activate, the survey is active now
#   2    it cannot be activated as things are (the reasons are printed); nothing was changed
#   1    the survey is not there, LimeSurvey refused, or a tool is missing
#   64   usage
#   75   LimeSurvey is starting, or being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: survey-activate.sh <survey id>
       survey-activate.sh <survey id> --yes-activate

Without --yes-activate it changes nothing: it shows the survey's title, its questions, who can answer it, its
sender and its public address. With --yes-activate, after the admin has seen those lines and said yes, it
activates the survey: people can answer it from then on, and its groups and questions can no longer be added or
removed.

Exit codes: 0 fine, 2 cannot be activated as things are, 1 not there or refused, 64 usage, 75 LimeSurvey is
starting or being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/survey-activate] %s\n' "$*" >&2; }

sid=''
confirmed=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --yes-activate) confirmed=true; shift ;;
        --survey)
            [ "$#" -ge 2 ] || { msg "--survey needs the survey's id"; exit 64; }
            sid="$2"
            shift 2
            ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *)
            if [ -n "${sid}" ]; then msg "give one survey id"; exit 64; fi
            sid="$1"
            shift
            ;;
    esac
done
if ! [[ "${sid}" =~ ^[0-9]{1,9}$ ]]; then
    msg "give the survey's id, a number (rc.sh list_surveys shows the surveys)"
    usage >&2
    exit 64
fi
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reply="$(jq -nc --argjson sid "${sid}" --argjson confirmed "${confirmed}" '{action: "activate", sid: $sid, confirmed: $confirmed}' \
    | "${script_dir}/run-in-limesurvey.sh" --stdin ls-change.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi
result="$(jq -c '.result' <<< "${reply}")"

jq -r '
    "Survey \(.sid): \(.title)",
    "  Content: \(.counts.groups) groups, \(.counts.questions) questions",
    "  Who can answer: " + (if .closed then "only the \(.participants) people on its participant list, each with their own access code"
        else "ANYONE who has its address. It has no participant list" end),
    "  Answers: " + (if .anonymized == "Y" then "anonymized (they cannot be tied to a participant)" else "not anonymized" end),
    (if (.expires // "") != "" then "  It ends on: \(.expires) UTC" else empty end),
    (if (.starts // "") != "" then "  It starts on: \(.starts) UTC" else empty end),
    "  Emails are sent as: \(.sender_name) <\(.sender_email)>",
    "  Public address: \(.public_url)"' <<< "${result}"

if [ "$(jq -r '.blockers | length' <<< "${result}")" -gt 0 ]; then
    echo "It cannot be activated as things are:"
    jq -r '.blockers[] | "  - " + .' <<< "${result}"
    echo "Nothing was changed."
    exit 2
fi
if [ "${confirmed}" != true ]; then
    echo "Nothing was changed. This was the preview."
    echo "Activating it lets people answer it from that moment. Its groups and questions can then no longer be added or removed."
    echo "Show the admin the lines above. After a clear yes, run the same command again with: --yes-activate"
    exit 0
fi
if [ "$(jq -r '.activated' <<< "${result}")" = true ]; then
    echo "Survey ${sid} is ACTIVE now: people can answer it."
    exit 0
fi
msg "the survey was not activated"
exit 1
