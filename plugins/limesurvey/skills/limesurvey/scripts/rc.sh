#!/usr/bin/env bash
# LimeSurvey skill: rc.sh
#
# Calls one of LimeSurvey's RemoteControl methods in the LimeSurvey container, as the site's main admin. The call
# runs from the command line inside the container (remote/ls-rc.php, sent by run-in-limesurvey.sh): no HTTP, no
# password and no session key, and RemoteControl does not have to be switched on. Nothing is left behind.
#
# Usage: rc.sh [--yes] [--show-codes] <method>            a method that takes no parameters
#        rc.sh [--yes] [--show-codes] --stdin <method>    the method's parameters as JSON on stdin
#        rc.sh --methods                              the methods it runs, with their parameters (? marks an
#                                                     optional one), and the ones it refuses, with what to use
#        rc.sh --whoami                               the admin the calls run as, and LimeSurvey's version
#
#   <method>      a RemoteControl method, such as list_surveys or get_summary.
#   --stdin       read the parameters from stdin: the ones after the session key, as a JSON object keyed by
#                 parameter name ({"iSurveyID": 123456}) or a JSON array in the method's order. --methods shows
#                 each method's names. Parameters never go on the command line: they can hold people's names
#                 and addresses. Without --stdin the method is called with no parameters and stdin is not read.
#   --yes         needed for every method that changes the site: the set_ methods, add_survey, copy_survey,
#                 add_group, add_language, add_quota, import_group and import_question. Give it only once the
#                 admin has asked for or agreed to exactly this change. On a survey that is active, the change
#                 reaches the people who are answering it at once: say so first.
#   --show-codes  leave participants' access codes in the reply. Without it each one reads "(hidden)". An access
#                 code lets its holder answer as that person. Give it only when the admin asks for one person's
#                 link or code, and ask for that one person.
#
# It works from a list (remote/lib/rc-policy.php). A method that reads runs. A method that changes the site runs
# with --yes. These are refused, each with the name of the script that does the job with its checks:
#   invite_participants, remind_participants, mail_registered_participants   invitations.sh
#   activate_survey                                                           survey-activate.sh
#   every delete_ method                                                      delete.sh
#   activate_tokens, add_participants, cpd_importParticipants                 participants.sh
#   import_survey                                                             survey-import.sh, survey-archive.sh
#   export_responses, export_responses_by_token, export_statistics            responses.sh
#   add_response, update_response, upload_file, get_uploaded_files            not done by this skill
# A method that is not on the list is refused too.
#
# What it never prints, whatever the method: the encryption keys of security.php, a password, salt or hash, a
# session token, a password-link key, an API key. get_site_settings answers only for a list of settings that hold
# no secret. No reply is a file, so no answers are printed and nothing is written inside the container.
#
# Output: the reply, one line of JSON: {"result": ..., "error": null}. LimeSurvey's own refusals arrive inside
# result, as {"status": "...", "error_code": "ERR_..."}.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    the method ran
#   1    the call could not be run: the reply's "error" says why (a refused method, a change without --yes, wrong
#        parameters, a PHP error)
#   2    the method ran and LimeSurvey refused: the reply's result has an error_code
#   64   usage, or the parameters are not JSON
#   75   LimeSurvey is starting, or being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: rc.sh [--yes] [--show-codes] [--stdin] <method>
       rc.sh --methods
       rc.sh --whoami

Calls one RemoteControl method in the LimeSurvey container as the site's main admin, with no HTTP and no password.

  --stdin       read the method's parameters from stdin, as a JSON object keyed by name or a JSON array.
                Without it the method gets no parameters.
  --yes         for a method that changes the site, once the admin has asked for or agreed to exactly this change
  --show-codes  leave participants' access codes in the reply (only when the admin asks for one person's link)
  --methods     the methods it runs, with their parameters, and the ones it refuses, with what to use instead
  --whoami      the admin the calls run as, and LimeSurvey's version

It refuses the methods that send email, activate, delete, export or write answers, and names the script for each:
invitations.sh, survey-activate.sh, delete.sh, participants.sh, survey-import.sh, survey-archive.sh, responses.sh.
It never prints an encryption key, a password, a session token or a file.

Examples:
  rc.sh list_surveys
  printf '%s' '{"iSurveyID": 123456}' | rc.sh --stdin list_groups
  printf '%s' '{"iQuestionID": 12, "aQuestionData": {"mandatory": "Y"}}' | rc.sh --yes --stdin set_question_properties

Exit codes: 0 ran, 1 could not be run (refused, no --yes, wrong parameters), 2 LimeSurvey refused (error_code in
the result), 64 usage, 75 LimeSurvey is starting or being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/rc] %s\n' "$*" >&2; }

confirmed=false
show_codes=false
read_stdin=0
method=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --yes) confirmed=true; shift ;;
        --show-codes) show_codes=true; shift ;;
        --stdin) read_stdin=1; shift ;;
        --save-as | --save-as=*)
            msg "rc.sh saves no files. responses.sh export and responses.sh statistics save a survey's answers or its statistics report in the Files pane"
            exit 64
            ;;
        --methods) method=_methods; shift ;;
        --whoami) method=_whoami; shift ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *)
            if [ -n "${method}" ]; then msg "give one method, and its parameters on stdin with --stdin"; exit 64; fi
            method="$1"
            shift
            ;;
    esac
done
if [ -z "${method}" ]; then
    msg "no method given"
    usage >&2
    exit 64
fi
if ! [[ "${method}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    msg "$(printf '%q' "${method}") is not a method name"
    exit 64
fi
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The parameters: what is on stdin, when --stdin asks for it. Without the option stdin is left alone, so a call
# from a shell whose stdin stays open does not wait on it.
params='[]'
if [ "${read_stdin}" -eq 1 ]; then
    if [ -t 0 ]; then msg "--stdin needs the parameters piped in, as JSON"; exit 64; fi
    given="$(cat)"
    if [ -n "${given//[[:space:]]/}" ]; then params="${given}"; fi
fi
# jq reads the parameters from a here-string, so they are in no command line.
if ! request="$(jq -c --arg method "${method}" --argjson confirmed "${confirmed}" --argjson codes "${show_codes}" \
    'if (type == "array" or type == "object") then {method: $method, params: ., confirmed: $confirmed, show_codes: $codes} else error("not an array or object") end' <<< "${params}" 2> /dev/null)"; then
    msg "the parameters on stdin have to be one JSON array or object"
    exit 64
fi

reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-rc.php)"
rc=$?
if [ -n "${reply}" ]; then printf '%s\n' "${reply}"; fi
if [ "${rc}" -ne 0 ]; then exit "${rc}"; fi
if jq -e '(.result | type) == "object" and (.result | has("error_code"))' <<< "${reply}" > /dev/null 2>&1; then
    exit 2
fi
exit 0
