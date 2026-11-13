#!/usr/bin/env bash
# LimeSurvey skill: crm-link.sh
#
# For the Customer Kit only. There LimeSurvey has Clouve's SuiteCRM plugin: when someone completes a survey whose
# link is on, the plugin makes a lead or a case in SuiteCRM from the questions that are mapped to CRM fields. This
# script shows LimeSurvey's side of that link and changes a survey's part of it. In a LimeSurvey on its own it
# says that the plugin is not there.
#
# Usage: crm-link.sh status
#        crm-link.sh mappings --survey <id>
#        crm-link.sh map --question <question id> --field <Module:field> [--field <Module:field>]...
#        crm-link.sh unmap --question <question id>
#        crm-link.sh enable-survey --survey <id>
#        crm-link.sh disable-survey --survey <id>
#
#   status          whether the plugin is on, where it connects (SuiteCRM's address, the admin name and the database
#                   it reads the field list from; for each password only whether one is stored), whether SuiteCRM
#                   still has the API client the plugin made for itself (the plugin's own check, which asks
#                   SuiteCRM's database), which surveys have the link on, and how many answer sets were sent and
#                   how many failed
#   mappings        each question of one survey, with its id and the CRM fields it fills
#   map             sets the CRM fields one question fills, replacing what it had. A field is the module and the
#                   field name as SuiteCRM's API names them, such as Leads:first_name or Cases:description. Before
#                   anything is stored, the module is checked against the plugin's own list of the modules it
#                   writes to, and the field against the field list SuiteCRM gives for that module (the plugin's
#                   own call). One that is not there is refused, with the names that are (exit 1). So is every
#                   mapping while SuiteCRM does not answer and the plugin has no list of its fields yet.
#   unmap           clears a question's mapping
#   enable-survey   switches the link on for one survey (and removes duplicate rows of that setting, a known fault
#                   that leaves a survey switched off), disable-survey switches it off
#
# The admin can do the mapping themselves in LimeSurvey's classic question editor, in the "SuiteCRM Integration"
# section of a question. LimeSurvey 7 opens its new editor by default, and that one does not show the section.
#
# The plugin's connection settings come from the deployment and the image sets them again at every start, so this
# script does not change them.
#
# The work runs inside the LimeSurvey container (remote/ls-crm.php, sent by run-in-limesurvey.sh).
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    done
#   1    the plugin, the survey or the question is not there, or the call failed
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: crm-link.sh status
       crm-link.sh mappings --survey <id>
       crm-link.sh map --question <question id> --field <Module:field> [--field <Module:field>]...
       crm-link.sh unmap --question <question id>
       crm-link.sh enable-survey --survey <id>
       crm-link.sh disable-survey --survey <id>

For the Customer Kit: LimeSurvey's side of the link to SuiteCRM. status shows the plugin and its connection
(no password), mappings shows which CRM fields each question of a survey fills, map and unmap set them, and
enable-survey and disable-survey switch the link for one survey.

Exit codes: 0 done, 1 not there or a failed call, 64 usage, 75 LimeSurvey is being installed, upgraded or
restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/crm-link] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
sid=''
qid=''
fields=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey | --question | --field)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            case "$1" in
                --survey) sid="$2" ;;
                --question) qid="$2" ;;
                --field) fields+=("$2") ;;
            esac
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
    status) [ -z "${sid}${qid}" ] && [ "${#fields[@]}" -eq 0 ] || usage_error "status takes no options" ;;
    mappings | enable-survey | disable-survey) [[ "${sid}" =~ ^[0-9]{1,9}$ ]] || usage_error "${action} needs --survey with the survey's id" ;;
    map)
        [[ "${qid}" =~ ^[0-9]{1,9}$ ]] || usage_error "map needs --question with the question's id (crm-link.sh mappings shows the ids)"
        [ "${#fields[@]}" -gt 0 ] || usage_error "map needs at least one --field, such as Leads:first_name"
        for field in "${fields[@]}"; do
            [[ "${field}" =~ ^[A-Za-z][A-Za-z0-9_]*:[A-Za-z][A-Za-z0-9_]*$ ]] || usage_error "a field is Module:field, such as Leads:first_name, not $(printf '%q' "${field}")"
        done
        ;;
    unmap) [[ "${qid}" =~ ^[0-9]{1,9}$ ]] || usage_error "unmap needs --question with the question's id" ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: ${action}" ;;
esac
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${action}" in
    status) request='{"action":"status"}' ;;
    mappings) request="$(jq -nc --argjson sid "${sid}" '{action: "mappings", sid: $sid}')" ;;
    enable-survey) request="$(jq -nc --argjson sid "${sid}" '{action: "set-survey-link", sid: $sid, enabled: true}')" ;;
    disable-survey) request="$(jq -nc --argjson sid "${sid}" '{action: "set-survey-link", sid: $sid, enabled: false}')" ;;
    unmap) request="$(jq -nc --argjson qid "${qid}" '{action: "set-mapping", qid: $qid, mappings: []}')" ;;
    map)
        request="$(printf '%s\n' "${fields[@]}" | jq -Rnc --argjson qid "${qid}" \
            '{action: "set-mapping", qid: $qid, mappings: [inputs | split(":") | {module: .[0], field: .[1]}]}')"
        ;;
esac
reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-crm.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi

case "${action}" in
    status)
        jq -r '.result
            | "SuiteCRM plugin: " + (if .on then "on" else "OFF" end) + (if .version then ", version \(.version)" else "" end)
                + (if .compatible == false then ", NOT compatible with this LimeSurvey" else "" end)
                + (if .folder_there then "" else ", its folder is missing" end)
                + (if .load_error then ", load error: \(.load_error)" else "" end),
              "  Link switched on for the whole site: " + (if .settings.enabled == "1" then "yes" else "no" end),
              "  SuiteCRM address: \(.settings.suitecrm_url // "(not set)")",
              "  SuiteCRM admin: \(.settings.suitecrm_admin_user // "(not set)"), password " + (if .settings.suitecrm_admin_password_stored then "stored" else "NOT stored" end),
              "  SuiteCRM database: \(.settings.suitecrm_db_user // "?")@\(.settings.suitecrm_db_host // "?")/\(.settings.suitecrm_db_name // "?"), password " + (if .settings.suitecrm_db_password_stored then "stored" else "NOT stored" end),
              "  Sign-in to SuiteCRM (OAuth2 client): " + (if .settings.oauth_initialized == "1" then (if .client_gone == true then "the plugin holds a client, but SuiteCRM no longer has it (it was deleted there, or a restore brought back a database from before it was made). Nothing is sent until an admin presses \"Initialize OAuth2\" on the plugin'"'"'s settings page, which makes a new one" else "set up" end) else "not set up yet" + (if (.settings.oauth_init_error // "") != "" then " (last error: \(.settings.oauth_init_error))" else "" end) end),
              (if .settings.debug_mode == "1" then "  Debug logging is ON: switch it off in the plugin'"'"'s settings when the diagnosis is done" else empty end),
              (if (.surveys | length) == 0 then "  No survey has the link switched on."
               else "  Surveys:", (.surveys[] | "    \(.sid): link " + (if .link_on then "on" else "off" end) + (if .active == "Y" then ", survey active" else ", survey inactive" end)
                   + (if .duplicate_rows then ", DUPLICATE setting rows (crm-link.sh enable-survey --survey \(.sid) repairs them)" else "" end)) end),
              "  Answer sets sent to SuiteCRM: \(.sent_to_suitecrm.success // 0) worked, \(.sent_to_suitecrm.failed // 0) failed" + (if (.sent_to_suitecrm.partial // 0) > 0 then ", \(.sent_to_suitecrm.partial) in part" else "" end)' <<< "${reply}"
        ;;
    mappings)
        jq -r '.result | "Survey \(.sid): the link is " + (if .link_on then "on" else "off" end),
            (.questions[] | "  \(.qid)\t\(.code)\t" + (if (.crm_fields | length) > 0 then (.crm_fields | join(", ")) else "(not mapped)" end) + "\t\(.question)")' <<< "${reply}"
        ;;
    map | unmap)
        jq -r '.result | "Question \(.code) (id \(.qid), survey \(.sid)) now fills: " + (if (.mappings | length) > 0 then (.mappings | map("\(.module): \(.field)") | join(", ")) else "no CRM field" end) + ". The plugin'"'"'s own table: \(.plugin_table)."' <<< "${reply}"
        ;;
    enable-survey | disable-survey)
        jq -r '.result | "The link to SuiteCRM is " + (if .link_on then "on" else "off" end) + " for survey \(.sid)." + (if .duplicate_rows_removed > 0 then " Removed \(.duplicate_rows_removed) duplicate setting row(s)." else "" end)' <<< "${reply}"
        ;;
esac
