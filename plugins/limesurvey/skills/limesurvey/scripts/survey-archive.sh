#!/usr/bin/env bash
# LimeSurvey skill: survey-archive.sh
#
# Takes one survey out of LimeSurvey as a file, or brings one in from a file.
#
# Usage: survey-archive.sh export --survey <id> --format <lss|lsa>
#        survey-archive.sh import <file.lss>
#        survey-archive.sh import --yes-activates-the-survey <file.lsa>
#
#   export  saves the survey as ~/limesurvey-exports/survey-<id>-<UTC time>.lss or .lsa (mode 600, in a folder of
#           mode 700 that the Files pane shows) and prints one line that names the file.
#             lss  the structure: groups, questions, answer options, texts and settings. No answers and no
#                  participants. Use it to copy a survey or keep a version of it.
#             lsa  the archive: the structure, and the survey's answers and participants when it has them. It holds
#                  personal data. Files that participants uploaded are not in it. Use it to move one survey, with
#                  its data, to another LimeSurvey.
#   import  brings a file on the agent into LimeSurvey as a new survey and prints its id and links.
#             .lss  the new survey is inactive, a draft for the admin to review.
#             .lsa  LimeSurvey ACTIVATES the survey as it imports it, and loads its answers and participants. So
#                   an .lsa needs --yes-activates-the-survey, which the playbook gives only after the admin was
#                   told this and said yes. Encrypted answers in an archive can only be read where the same
#                   encryption keys (security.php) are in place.
#
# Neither is a backup of the site: accounts, permissions, settings, other surveys and the encryption keys are not
# in these files. backup.sh makes backups.
#
# The work runs inside the LimeSurvey container (remote/ls-survey.php, sent by run-in-limesurvey.sh). LimeSurvey
# imports a copy of the file; the file on the agent stays.
#
# Env vars read:
#   LIMESURVEY_HOST  for run-in-limesurvey.sh
#   HOME             where ~/limesurvey-exports lives
#
# Exit codes:
#   0    done
#   1    the survey or the file is not there, LimeSurvey refused, or a tool is missing
#   3    export: the file could not be saved
#   64   usage, or an .lsa import without --yes-activates-the-survey
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: survey-archive.sh export --survey <id> --format <lss|lsa>
       survey-archive.sh import <file.lss>
       survey-archive.sh import --yes-activates-the-survey <file.lsa>

export saves one survey to a private file in ~/limesurvey-exports (the Files pane shows it): lss is the questions
and settings, lsa also holds the answers and the participants. import brings a file on the agent in as a new
survey. An .lss arrives inactive. An .lsa is ACTIVATED by LimeSurvey as it is imported, with its answers and
participants, so it needs --yes-activates-the-survey, after the admin said yes to that.

Exit codes: 0 done, 1 not there or refused, 3 the file was not saved, 64 usage, 75 LimeSurvey is being installed,
upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/survey-archive] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
sid=''
format=''
file=''
confirmed=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey | --format)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            if [ "$1" = --survey ]; then sid="$2"; else format="$2"; fi
            shift 2
            ;;
        --yes-activates-the-survey) confirmed=true; shift ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            if [ -z "${action}" ]; then
                action="$1"
            elif [ -z "${file}" ]; then
                file="$1"
            else
                usage_error "too many words: $1"
            fi
            shift
            ;;
    esac
done
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${action}" in
    export)
        [ -z "${file}" ] || usage_error "export takes --survey and --format"
        [[ "${sid}" =~ ^[0-9]{1,9}$ ]] || usage_error "--survey needs the survey's id, a number"
        case "${format}" in lss | lsa) ;; *) usage_error "--format is lss (questions and settings) or lsa (with answers and participants)" ;; esac
        # shellcheck source=/dev/null
        . "${script_dir}/lib/limesurvey-files.sh" || exit 1
        dir="$(ls_private_dir limesurvey-exports)" || exit 3
        stamp="$(LC_ALL=C date -u '+%Y%m%d-%H%M%S')"
        [[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { msg "date gave no time stamp"; exit 1; }
        name="$(ls_free_name "${dir}" "survey-${sid}-${stamp}" "${format}")" || exit 3
        jq -nc --argjson sid "${sid}" --arg format "${format}" '{action: "archive-export", sid: $sid, format: $format}' \
            | "${script_dir}/run-in-limesurvey.sh" --stdin ls-survey.php | ls_write_private_file limesurvey-exports "${name}"
        codes=("${PIPESTATUS[@]}")
        if [ "${codes[2]}" -ne 0 ]; then exit 3; fi
        if [ "${codes[1]}" -ne 0 ]; then
            # What was saved is the reply that says why there is no file.
            error="$(jq -r '.error // empty' < "${dir}/${name}" 2> /dev/null)"
            ls_delete_private_file "${dir}/${name}" || msg "could not remove limesurvey-exports/${name}"
            if [ -n "${error}" ]; then msg "${error}"; fi
            exit "${codes[1]}"
        fi
        printf 'Saved survey %s to limesurvey-exports/%s in the Files pane (%s bytes).\n' "${sid}" "${name}" "$(wc -c < "${dir}/${name}" | tr -d ' ')"
        if [ "${format}" = lsa ]; then
            echo "The archive holds the survey's answers and participants. Delete it from the Files pane once the admin has it."
        fi
        ;;
    import)
        [ -z "${sid}${format}" ] || usage_error "import takes the file"
        [ -n "${file}" ] || usage_error "import needs the file"
        case "${file,,}" in
            *.lss) kind=lss ;;
            *.lsa) kind=lsa ;;
            *.txt | *.tsv) usage_error "a tab-separated survey file goes through survey-import.sh, which checks it first" ;;
            *) usage_error "import takes an .lss or .lsa file" ;;
        esac
        if [ "${kind}" = lsa ] && [ "${confirmed}" != true ]; then
            msg "an .lsa archive is not imported as a draft: LimeSurvey activates the survey as it imports it, and loads its answers and participants. Tell the admin, and after a clear yes run this again with --yes-activates-the-survey."
            exit 64
        fi
        if [ "${kind}" = lss ] && [ "${confirmed}" = true ]; then
            usage_error "--yes-activates-the-survey goes with an .lsa file"
        fi
        if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then msg "${file} is not a file this can read"; exit 1; fi
        bytes="$(wc -c < "${file}" | tr -d ' ')"
        if [ "${bytes}" -eq 0 ]; then msg "${file} is empty"; exit 1; fi
        if [ "${bytes}" -gt 209715200 ]; then msg "${file} is over 200 MB. Move a survey that big with a full backup instead (playbooks/back-up.md)"; exit 1; fi
        command -v base64 > /dev/null 2>&1 || { msg "base64 is not installed"; exit 1; }
        reply="$(base64 -w0 < "${file}" | jq -Rc --arg format "${kind}" --argjson confirmed "${confirmed}" \
            '{action: "archive-import", format: $format, confirmed: $confirmed, data_base64: .}' | "${script_dir}/run-in-limesurvey.sh" --stdin ls-survey.php)"
        rc=$?
        if [ "${rc}" -ne 0 ]; then
            error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
            if [ -n "${error}" ]; then msg "${error}"; fi
            exit "${rc}"
        fi
        jq -r '.result
            | "Imported \"\(.title // "(no title)")\" as survey \(.sid).",
              "  State: " + (if .active == "Y" then "ACTIVE: people can answer it now" else "inactive (a draft: nobody can answer it)" end),
              "  Content: \(.counts.groups) groups, \(.counts.questions) questions, \(.counts.subquestions) subquestions, \(.counts.answers) answer options",
              (if .has_participant_list then "  Participants: \(.participants)" else empty end),
              (if .responses != null then "  Answers: \(.responses)" else empty end),
              "Review and edit (the admin signs in first):  \(.admin_url)",
              (if .active == "Y" then "Public address:  \(.public_url)" else "Preview (signed in as an admin):  \(.preview_url)" end)' <<< "${reply}"
        ;;
    '') usage_error "say export or import" ;;
    *) usage_error "say export or import, not ${action}" ;;
esac
