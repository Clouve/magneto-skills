#!/usr/bin/env bash
# LimeSurvey skill: survey-info.sh
#
# Shows one survey: its title, whether it is active, how many groups, questions, participants and answers it has,
# the sender its emails carry, and its links. It reads counts only, never an answer or a participant.
#
# Usage: survey-info.sh <survey id>
#        survey-info.sh --json <survey id>     the same as one line of JSON
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes: 0 shown; 1 there is no such survey, or the call failed; 64 usage; 75 LimeSurvey is being installed,
# upgraded or restored; 255 ssh failed.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: survey-info.sh [--json] <survey id>

Shows one survey: title, state, counts, the sender of its emails and its links. It reads counts only, never an
answer or a participant.

Exit codes: 0 shown, 1 no such survey or a failed call, 64 usage, 75 LimeSurvey is being installed, upgraded or
restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/survey-info] %s\n' "$*" >&2; }

json=0
sid=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --json) json=1; shift ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *) sid="$1"; shift ;;
    esac
done
if ! [[ "${sid}" =~ ^[0-9]{1,9}$ ]]; then
    msg "give the survey's id, a number (rc.sh list_surveys shows the surveys)"
    exit 64
fi
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reply="$(jq -nc --argjson sid "${sid}" '{action: "info", sid: $sid}' | "${script_dir}/run-in-limesurvey.sh" --stdin ls-survey.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi
if [ "${json}" -eq 1 ]; then
    jq -c '.result' <<< "${reply}"
    exit 0
fi
jq -r '.result
    | "Survey \(.sid): \(.title // "(no title)")",
      "  State: " + (if .active == "Y" then "active (people can answer it)" else "inactive (a draft: nobody can answer it)" end),
      "  Language: \(.language)" + (if .additional_languages != "" then ", also \(.additional_languages)" else "" end),
      "  Content: \(.counts.groups) groups, \(.counts.questions) questions, \(.counts.subquestions) subquestions, \(.counts.answers) answer options",
      "  Participant list: " + (if .has_participant_list then "\(.participants) people" else "none" end),
      "  Answers: " + (if .responses == null then "none (the survey is not active)" else "\(.responses)" end),
      "  Emails are sent as: \(.sender_name) <\(.sender_email)>",
      "  Review and edit: \(.admin_url)",
      "  Preview (signed in as an admin): \(.preview_url)",
      "  Public address: \(.public_url)"' <<< "${reply}"
