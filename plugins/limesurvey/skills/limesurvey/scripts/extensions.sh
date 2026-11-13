#!/usr/bin/env bash
# LimeSurvey skill: extensions.sh
#
# Lists LimeSurvey's plugins and survey themes, switches a plugin on or off, and registers a theme folder the admin
# uploaded. It goes through LimeSurvey's own models and makes the checks LimeSurvey's own pages make.
#
# Usage: extensions.sh plugins
#        extensions.sh plugins-off-after-upgrade
#        extensions.sh plugin-activate <Name>
#        extensions.sh plugin-deactivate <Name>
#        extensions.sh themes
#        extensions.sh theme-register <name>
#
#   plugins                    every plugin: its type (core, user, upload), on or off, its version, and whether its
#                              config.xml lists this LimeSurvey major version. Plugin folders LimeSurvey has not
#                              registered yet are listed too.
#   plugins-off-after-upgrade  the added plugins that are off now. A LimeSurvey upgrade switches every added plugin
#                              off. For each one it says whether it was on before the upgrade (from the list the
#                              image's upgrade keeps in its backup folder) and whether it can be switched on again.
#   plugin-activate            switches a plugin on, as LimeSurvey's plugin manager does: the plugin's config.xml has
#                              to list this LimeSurvey major version, and the plugin's own activation step runs. A
#                              plugin is code that runs with LimeSurvey's rights, so this needs the admin's yes.
#   plugin-deactivate          switches a plugin off. Nothing is deleted.
#   themes                     the survey themes LimeSurvey has registered, how many surveys use each, and the theme
#                              folders in upload/themes/survey that are not registered yet
#   theme-register             registers the theme folder upload/themes/survey/<name>. Its config.xml has to name it,
#                              list this LimeSurvey major version, and build on a theme that is installed.
#
# The work runs inside the LimeSurvey container (remote/ls-extensions.php and remote/state.sh, sent by
# run-in-limesurvey.sh).
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    done
#   1    not there, not compatible, LimeSurvey refused, or a tool is missing (stderr says which)
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: extensions.sh plugins
       extensions.sh plugins-off-after-upgrade
       extensions.sh plugin-activate <Name>
       extensions.sh plugin-deactivate <Name>
       extensions.sh themes
       extensions.sh theme-register <name>

Lists LimeSurvey's plugins and survey themes, switches a plugin on or off, and registers a theme folder that the
admin uploaded to upload/themes/survey/. A plugin that does not list this LimeSurvey major version in its
config.xml is refused, as in LimeSurvey's own plugin manager.

Exit codes: 0 done, 1 not there, not compatible or refused, 64 usage, 75 LimeSurvey is being installed, upgraded
or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/extensions] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
name=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            if [ -z "${action}" ]; then
                action="$1"
            elif [ -z "${name}" ]; then
                name="$1"
            else
                usage_error "too many words: $1"
            fi
            shift
            ;;
    esac
done
case "${action}" in
    plugins | plugins-off-after-upgrade | themes) [ -z "${name}" ] || usage_error "${action} takes no name" ;;
    plugin-activate | plugin-deactivate | theme-register)
        [[ "${name}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || usage_error "${action} needs the name: letters, digits, _ and -"
        ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: ${action}" ;;
esac
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# call REQUEST: sends the request to ls-extensions.php; leaves the reply in reply, and exits on a failure
reply=''
call() {
    local rc error
    reply="$(printf '%s' "$1" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-extensions.php)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
        if [ -n "${error}" ]; then msg "${error}"; fi
        exit "${rc}"
    fi
}

plugin_line='"\(.name)\t\(.type)\t" + (if .on then "on" else "off" end) + (if .version then "\tversion \(.version)" else "" end)
    + (if .registered then "" else "\tnot registered yet" end)
    + (if .compatible == true then "" elif .compatible == false then "\tNOT compatible with this LimeSurvey" else "\tno readable config.xml" end)
    + (if .folder_there then "" else "\tits folder is missing" end)
    + (if .load_error then "\tload error: \(.load_error)" else "" end)'

case "${action}" in
    plugins)
        call '{"action":"plugin-list"}'
        jq -r ".result | \"Plugins (LimeSurvey \(.limesurvey_version)):\", (.plugins[] | \"  \" + ${plugin_line})" <<< "${reply}"
        ;;
    plugins-off-after-upgrade)
        call '{"action":"plugin-list"}'
        # The names that were on before the last upgrade, when the image kept the list. An empty list is fine.
        before="$("${script_dir}/run-in-limesurvey.sh" state.sh plugins-before)" || before=''
        before_json="$(printf '%s\n' "${before}" | jq -Rnc '[inputs | select(length > 0)]')"
        jq -r --argjson before "${before_json}" '
            [.result.plugins[] | select(.type != "core" and (.on | not))] as $off
            | if ($off | length) == 0 then "No added plugin is off."
              else "Added plugins that are off:",
                   ($off[] | "  \(.name)\t\(.type)"
                       + (if (.name | IN($before[])) then "\twas on before the upgrade" elif ($before | length) > 0 then "\twas off before the upgrade too" else "" end)
                       + (if .compatible == true then "\tcan be switched on (extensions.sh plugin-activate \(.name), after the admin'"'"'s yes)"
                          elif .compatible == false then "\tNOT compatible with this LimeSurvey: it needs a newer version from its author"
                          else "\tno readable config.xml" end))
              end,
              (if ($before | length) == 0 then "(The upgrade left no list of the plugins that were on before, so this shows what is off now.)" else empty end)' <<< "${reply}"
        ;;
    plugin-activate | plugin-deactivate)
        call "$(jq -nc --arg action "${action}" --arg name "${name}" '{action: $action, name: $name}')"
        jq -r ".result | (if .changed then \"Done: \" else \"Nothing changed (\" + .note + \"): \" end) + ${plugin_line}" <<< "${reply}"
        ;;
    themes)
        call '{"action":"theme-list"}'
        jq -r '.result | "Survey themes (the default is \(.default_theme)):",
            (.themes[] | "  \(.name)\t" + (if .registered then (if .uploaded then "uploaded" else "comes with LimeSurvey" end) + "\tused by \(.surveys) surveys" + (if .extends != "" then "\tbuilds on \(.extends)" else "" end)
                else "in upload/themes/survey, not registered yet" + (if .compatible == false then "\tNOT compatible with this LimeSurvey" else "" end) end))' <<< "${reply}"
        ;;
    theme-register)
        call "$(jq -nc --arg name "${name}" '{action: "theme-register", name: $name}')"
        jq -r '.result | if .changed then "Registered the theme \(.name)" + (if .extends != "" then " (it builds on \(.extends))" else "" end) + ". The admin can now pick it for a survey."
            else "Nothing changed: \(.note)." end' <<< "${reply}"
        ;;
esac
