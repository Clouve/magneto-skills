#!/usr/bin/env bash
# LimeSurvey skill: survey-import.sh
#
# Checks a survey file that the assistant wrote and imports it into LimeSurvey as an inactive draft for the admin
# to review. Nobody can answer the draft until the admin activates it.
#
# Usage: survey-import.sh [--check-only] <file>
#
#   <file>        a file on the agent: a tab-separated survey file (.txt or .tsv, the format
#                 reference/survey-file-format.md describes) or a LimeSurvey structure file (.lss).
#   --check-only  for a .txt or .tsv file: run the checks, print what they find and import nothing.
#
# What it does, in one run inside the LimeSurvey container (remote/ls-survey.php, sent by run-in-limesurvey.sh):
#   1. A tab-separated file is checked first (remote/lib/tsv-check.php has the rules). An error stops here and
#      nothing is imported. LimeSurvey's own importer would take most of these files and quietly drop rows.
#   2. LimeSurvey imports a copy of the file. Its importer deletes the file it reads, so it never gets the
#      original, which stays on the agent.
#   3. The new survey is read back: its id, its title, whether it is active, and how many groups, questions,
#      subquestions and answer options it has. For a tab-separated file those have to be the numbers of the file.
#   4. From the agent, the survey's public address is asked over HTTP, inside the pod. An inactive survey answers
#      401 to visitors.
# It prints the id, the page where the admin reviews the survey, and the preview link. Both links need the admin
# to be signed in.
#
# An .lsa archive is refused: importing one activates the survey. survey-archive.sh does that, after a yes.
#
# Env vars read:
#   LIMESURVEY_HOST  for run-in-limesurvey.sh, and for the HTTP check on port 8080
#
# Exit codes:
#   0    imported and checked (or, with --check-only, the file has no errors)
#   2    the file has errors; nothing was imported
#   3    the survey was imported, but something does not match (the counts, or it is not inactive): the message
#        says what, and the survey is there for the admin to look at or delete
#   1    a file or tool is missing, the file is too big, or LimeSurvey could not import it
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: survey-import.sh [--check-only] <file>

Checks a survey file and imports it into LimeSurvey as an inactive draft. <file> is a tab-separated survey file
(.txt or .tsv) or a LimeSurvey structure file (.lss) on the agent. It prints the new survey's id and the links
where the admin reviews and previews it, and proves that the survey is inactive.

  --check-only  check a .txt or .tsv file and import nothing

Exit codes: 0 done, 2 the file has errors and nothing was imported, 3 imported but something does not match,
1 a missing file or tool or a failed import, 64 usage, 75 LimeSurvey is being installed, upgraded or restored,
255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/survey-import] %s\n' "$*" >&2; }

check_only=0
file=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --check-only) check_only=1; shift ;;
        --) shift; [ "$#" -gt 0 ] && file="$1"; shift $#; break ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *)
            if [ -n "${file}" ]; then msg "give one file"; exit 64; fi
            file="$1"
            shift
            ;;
    esac
done
if [ -z "${file}" ]; then
    msg "no file given"
    usage >&2
    exit 64
fi
case "${file,,}" in
    *.txt | *.tsv) format=txt ;;
    *.lss) format=lss ;;
    *.lsa)
        msg "an .lsa archive is not a draft: importing one activates the survey and loads its answers and participants. survey-archive.sh import does that, after the admin's yes."
        exit 64
        ;;
    *) msg "the file has to end in .txt or .tsv (tab-separated) or .lss"; exit 64 ;;
esac
if [ "${check_only}" -eq 1 ] && [ "${format}" != txt ]; then
    msg "--check-only is for a tab-separated file (.txt or .tsv)"
    exit 64
fi
if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
    msg "${file} is not a file this can read"
    exit 1
fi
bytes="$(wc -c < "${file}" | tr -d ' ')"
if [ "${bytes}" -eq 0 ]; then msg "${file} is empty"; exit 1; fi
if [ "${bytes}" -gt 20971520 ]; then msg "${file} is over 20 MB, which is no survey file"; exit 1; fi
for tool in jq base64; do
    command -v "${tool}" > /dev/null 2>&1 || { msg "${tool} is not installed (the limesurvey plugin's install.sh adds what the scripts need)"; exit 1; }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
action=import
if [ "${check_only}" -eq 1 ]; then action=check; fi

# The file travels as base64 inside the request, on the channel's stdin.
reply="$(base64 -w0 < "${file}" | jq -Rc --arg action "${action}" --arg format "${format}" '{action: $action, format: $format, data_base64: .}' \
    | "${script_dir}/run-in-limesurvey.sh" --stdin ls-survey.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi
result="$(jq -c '.result' <<< "${reply}" 2> /dev/null)"
if [ -z "${result}" ] || [ "${result}" = null ]; then
    msg "the reply from the container could not be read"
    exit 1
fi

# list KEY HEADING: prints the strings of .KEY, one per line, under HEADING
list() {
    local n
    n="$(jq -r --arg k "$1" '(.[$k] // []) | length' <<< "${result}")"
    [ "${n}" -gt 0 ] || return 0
    printf '%s\n' "$2"
    jq -r --arg k "$1" '.[$k][] | "  - " + .' <<< "${result}"
}

if [ "${check_only}" -eq 1 ]; then
    list errors "Errors (the file can't be imported like this):"
    list warnings "Warnings:"
    jq -r '.summary | "The file: survey id \(.sid // "?"), language \(.language // "?"), \(.groups) groups, \(.questions) questions, \(.subquestions) subquestions, \(.answers) answer options."' <<< "${result}"
    if [ "$(jq -r '.errors | length' <<< "${result}")" -gt 0 ]; then
        echo "Not imported: fix the errors and check again."
        exit 2
    fi
    echo "No errors. Nothing was imported (--check-only)."
    exit 0
fi

if [ "$(jq -r '.imported' <<< "${result}")" != true ]; then
    list errors "Errors (nothing was imported):"
    list warnings "Warnings:"
    exit 2
fi

sid="$(jq -r '.sid' <<< "${result}")"
language="$(jq -r '.language' <<< "${result}")"
active="$(jq -r '.active' <<< "${result}")"
jq -r '"Imported \"\(.title // "(no title)")\" as survey \(.sid)."' <<< "${result}"
jq -r 'if .sid_note then "  Note: " + .sid_note + "." else empty end' <<< "${result}"
jq -r '"  It has \(.counts.groups) groups, \(.counts.questions) questions, \(.counts.subquestions) subquestions and \(.counts.answers) answer options."' <<< "${result}"

problems=0
if [ "${active}" = N ]; then
    echo "  It is inactive (active = N in LimeSurvey): nobody can answer it until the admin activates it."
else
    echo "  PROBLEM: LimeSurvey says the survey is active (active = ${active})."
    problems=1
fi
# A second look, from outside LimeSurvey: what a visitor gets at the survey's address inside the pod.
if command -v curl > /dev/null 2>&1 && [ -n "${LIMESURVEY_HOST:-}" ] && [[ "${sid}" =~ ^[0-9]+$ ]]; then
    http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${LIMESURVEY_HOST}:8080/index.php/${sid}?lang=${language}" 2> /dev/null)"
    case "${http}" in
        401) echo "  A visitor who opens its address gets HTTP 401 (checked just now), so it is not public." ;;
        000 | '') echo "  The check of its address over HTTP did not get an answer, so only LimeSurvey's own record says it is inactive." ;;
        *)
            echo "  PROBLEM: a visitor who opens its address gets HTTP ${http}, where an inactive survey answers 401."
            problems=1
            ;;
    esac
fi
if [ "$(jq -r '.mismatches | length' <<< "${result}")" -gt 0 ]; then
    echo "  PROBLEM: the survey is not what the file says:"
    jq -r '.mismatches[] | "    - " + .' <<< "${result}"
    problems=1
fi
jq -r '"Review and edit (the admin signs in first):  \(.admin_url)", "Preview as a participant (signed in as an admin):  \(.preview_url)"' <<< "${result}"
list warnings "Warnings from the check:"
if [ "${problems}" -ne 0 ]; then
    msg "the survey was imported, but something does not match. Tell the admin, and delete the draft if it is wrong (rc.sh --yes delete_survey, after their yes)."
    exit 3
fi
exit 0
