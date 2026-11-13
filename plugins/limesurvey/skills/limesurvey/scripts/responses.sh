#!/usr/bin/env bash
# LimeSurvey skill: responses.sh
#
# Reads the answers of one survey: exports them to a file in the Files pane, or gives a summary for the assistant
# to read. Answers are personal data. Run this only for the survey the admin named, and only when they ask for it.
#
# Usage: responses.sh export --survey <id> [--format csv|xlsx] [--completion complete|incomplete|all]
#                            [--headings code|full|abbreviated] [--answers long|short]
#        responses.sh summary --survey <id> [--completion complete|incomplete|all] [--with-text]
#        responses.sh statistics --survey <id> [--format pdf|xls|html]
#
#   export    saves the answers as ~/limesurvey-exports/survey-<id>-answers-<UTC time>.csv (or .xlsx), mode 600 in
#             a folder of mode 700, which the Files pane shows, and prints one line that names the file. The answers
#             are never printed. The defaults are a CSV of the completed answer sets, with question codes as column
#             headings and answer texts in the cells.
#   summary   prints, as JSON, how many answer sets there are and for each question how many people answered and how
#             the answers split. What people typed into free-text questions is counted and left out, unless
#             --with-text asks for it (200 answers per question at most). It has no names, addresses, access codes
#             or IP addresses.
#   statistics  saves LimeSurvey's own statistics report (counts and shares per question) as
#             ~/limesurvey-exports/survey-<id>-statistics-<UTC time>.pdf (or .xls, .html), a private file like an
#             export, and prints one line that names it.
#   --completion  which answer sets: complete (the default), incomplete, or all
#
# The work runs inside the LimeSurvey container through LimeSurvey's own export (remote/ls-results.php, sent by
# run-in-limesurvey.sh), so encrypted answers come out readable. Nothing is left in the container.
#
# Env vars read:
#   LIMESURVEY_HOST  for run-in-limesurvey.sh
#   HOME             where ~/limesurvey-exports lives
#
# Exit codes:
#   0    done
#   1    the survey is not there or has no answers, the call failed, or a tool is missing
#   3    export: the file could not be saved
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: responses.sh export --survey <id> [--format csv|xlsx] [--completion complete|incomplete|all]
                           [--headings code|full|abbreviated] [--answers long|short]
       responses.sh summary --survey <id> [--completion complete|incomplete|all] [--with-text]
       responses.sh statistics --survey <id> [--format pdf|xls|html]

export saves one survey's answers to a private file in ~/limesurvey-exports (the Files pane shows it) and prints
the file's name, never the answers. summary prints counts per question as JSON; what people typed is left out
unless --with-text asks for it. statistics saves LimeSurvey's own statistics report as a private file.

Answers are personal data: only for the survey the admin named, and only when they ask.

Exit codes: 0 done, 1 not there, no answers or a failed call, 3 the file was not saved, 64 usage,
75 LimeSurvey is being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/responses] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
sid=''
format=''
completion=complete
headings=code
answers=long
with_text=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey | --format | --completion | --headings | --answers)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            case "$1" in
                --survey) sid="$2" ;;
                --format) format="$2" ;;
                --completion) completion="$2" ;;
                --headings) headings="$2" ;;
                --answers) answers="$2" ;;
            esac
            shift 2
            ;;
        --with-text) with_text=true; shift ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            [ -z "${action}" ] || usage_error "give one of export, summary or statistics"
            action="$1"
            shift
            ;;
    esac
done
case "${action}" in
    export | summary | statistics) ;;
    '') usage_error "say export, summary or statistics" ;;
    *) usage_error "say export, summary or statistics, not ${action}" ;;
esac
[[ "${sid}" =~ ^[0-9]{1,9}$ ]] || usage_error "--survey needs the survey's id, a number"
if [ "${action}" = statistics ]; then
    [ -n "${format}" ] || format=pdf
    case "${format}" in pdf | xls | html) ;; *) usage_error "statistics: --format is pdf, xls or html" ;; esac
else
    [ -n "${format}" ] || format=csv
    case "${format}" in csv | xlsx) ;; *) usage_error "--format is csv or xlsx" ;; esac
fi
case "${completion}" in complete | incomplete | all) ;; *) usage_error "--completion is complete, incomplete or all" ;; esac
case "${headings}" in code | full | abbreviated) ;; *) usage_error "--headings is code, full or abbreviated" ;; esac
case "${answers}" in long | short) ;; *) usage_error "--answers is long or short" ;; esac
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${action}" = summary ]; then
    reply="$(jq -nc --argjson sid "${sid}" --arg completion "${completion}" --argjson text "${with_text}" \
        '{action: "summary", sid: $sid, completion: $completion, with_text: $text}' | "${script_dir}/run-in-limesurvey.sh" --stdin ls-results.php)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
        if [ -n "${error}" ]; then msg "${error}"; fi
        exit "${rc}"
    fi
    jq '.result' <<< "${reply}"
    exit 0
fi

# shellcheck source=/dev/null
. "${script_dir}/lib/limesurvey-files.sh" || exit 1
dir="$(ls_private_dir limesurvey-exports)" || exit 3
stamp="$(LC_ALL=C date -u '+%Y%m%d-%H%M%S')"
[[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { msg "date gave no time stamp"; exit 1; }
if [ "${action}" = statistics ]; then
    name="$(ls_free_name "${dir}" "survey-${sid}-statistics-${stamp}" "${format}")" || exit 3
    jq -nc --argjson sid "${sid}" --arg format "${format}" '{action: "statistics", sid: $sid, format: $format}' \
        | "${script_dir}/run-in-limesurvey.sh" --stdin ls-results.php | ls_write_private_file limesurvey-exports "${name}"
    codes=("${PIPESTATUS[@]}")
    if [ "${codes[2]}" -ne 0 ]; then exit 3; fi
    if [ "${codes[1]}" -ne 0 ]; then
        # What was saved is the reply that says why there is no file.
        error="$(jq -r '.error // empty' < "${dir}/${name}" 2> /dev/null)"
        ls_delete_private_file "${dir}/${name}" || msg "could not remove limesurvey-exports/${name}"
        if [ -n "${error}" ]; then msg "${error}"; fi
        exit "${codes[1]}"
    fi
    printf 'Saved the statistics report of survey %s to limesurvey-exports/%s in the Files pane (%s bytes).\n' "${sid}" "${name}" "$(wc -c < "${dir}/${name}" | tr -d ' ')"
    echo "It holds counts and shares per question. Delete it from the Files pane once the admin has it."
    exit 0
fi
name="$(ls_free_name "${dir}" "survey-${sid}-answers-${stamp}" "${format}")" || exit 3

jq -nc --argjson sid "${sid}" --arg format "${format}" --arg completion "${completion}" --arg headings "${headings}" --arg answers "${answers}" \
    '{action: "export", sid: $sid, format: $format, completion: $completion, headings: $headings, answers: $answers}' \
    | "${script_dir}/run-in-limesurvey.sh" --stdin ls-results.php | ls_write_private_file limesurvey-exports "${name}"
codes=("${PIPESTATUS[@]}")
if [ "${codes[2]}" -ne 0 ]; then exit 3; fi
if [ "${codes[1]}" -ne 0 ]; then
    # What was saved is the reply that says why there is no file.
    error="$(jq -r '.error // empty' < "${dir}/${name}" 2> /dev/null)"
    ls_delete_private_file "${dir}/${name}" || msg "could not remove limesurvey-exports/${name}"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${codes[1]}"
fi
size="$(wc -c < "${dir}/${name}" | tr -d ' ')"
if [ "${format}" = csv ]; then
    rows="$(($(wc -l < "${dir}/${name}") - 1))"
    printf 'Saved the answers of survey %s to limesurvey-exports/%s in the Files pane (%s bytes, about %s answer sets).\n' "${sid}" "${name}" "${size}" "${rows}"
else
    printf 'Saved the answers of survey %s to limesurvey-exports/%s in the Files pane (%s bytes).\n' "${sid}" "${name}" "${size}"
fi
echo "The file holds people's answers. Delete it from the Files pane once the admin has it."
