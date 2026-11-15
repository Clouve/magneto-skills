#!/usr/bin/env bash
# LimeSurvey skill: admin-users.sh
#
# Lists LimeSurvey's admin accounts and changes what they may do, through LimeSurvey's own models. It never
# prints a password, and takes one only on stdin.
#
# Usage: admin-users.sh list
#        admin-users.sh show <login>
#        admin-users.sh grant <login> --survey <id> --role <full|editor|results|none>
#        admin-users.sh grant <login> --create-surveys | --no-create-surveys
#        admin-users.sh grant <login> --superadmin | --no-superadmin
#        admin-users.sh deactivate <login>
#        admin-users.sh activate <login>
#        admin-users.sh set-password <login>          the password is the first line of stdin
#        admin-users.sh clear-lockouts
#
#   list            every admin account: login, name, email, active or not, superadmin or not, may create surveys
#   show            one account, with its permissions on each survey and the surveys it owns
#   grant           --survey with --role sets what the account may do on one survey, replacing what it had:
#                     full     everything, as the survey's owner has
#                     editor   questions, groups, texts, quotas and settings; not the answers, the participants,
#                              activation or who else may work on the survey
#                     results  read and export the answers and statistics; change nothing
#                     none     no access to that survey
#                   --create-surveys lets the account make its own surveys (it has every right on those).
#                   --superadmin gives full control of the whole site, every survey and every answer. Say so, and
#                   wait for the admin's yes.
#   deactivate      switches an account off: it cannot sign in, and nothing it made is deleted. activate turns it
#                   back on.
#   set-password    reads the new password from the first line of stdin and sets it. Use it to put the main admin's
#                   password back to the one the Clouve dashboard shows (playbooks/regain-admin-access.md). For
#                   anyone else, temp-password.sh makes a password and saves it in a private file.
#   clear-lockouts  forgets LimeSurvey's record of failed sign-ins, which locks an address out for a while after
#                   too many wrong passwords
#
# New accounts are made by temp-password.sh --create, which also saves their first password.
#
# It refuses to take the superadmin permission from the site's main admin, or to switch that account off.
#
# The work runs inside the LimeSurvey container (remote/ls-users.php, sent by run-in-limesurvey.sh).
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    done
#   1    the account or survey is not there, LimeSurvey refused, or a tool is missing (stderr says which)
#   64   usage, or set-password with no password on stdin
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print a password read from stdin.
set +x

usage() {
    cat <<'USAGE'
Usage: admin-users.sh list
       admin-users.sh show <login>
       admin-users.sh grant <login> --survey <id> --role <full|editor|results|none>
       admin-users.sh grant <login> --create-surveys | --no-create-surveys
       admin-users.sh grant <login> --superadmin | --no-superadmin
       admin-users.sh deactivate <login>
       admin-users.sh activate <login>
       admin-users.sh set-password <login>          (the password is the first line of stdin)
       admin-users.sh clear-lockouts

Lists LimeSurvey's admin accounts and changes what they may do. It never prints a password. New accounts are
made by temp-password.sh --create.

Exit codes: 0 done, 1 not there or refused, 64 usage, 75 LimeSurvey is being installed, upgraded or restored,
255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/admin-users] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
login=''
sid=''
role=''
flag=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey | --role)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            if [ "$1" = --survey ]; then sid="$2"; else role="$2"; fi
            shift 2
            ;;
        --create-surveys | --no-create-surveys | --superadmin | --no-superadmin)
            [ -z "${flag}" ] || usage_error "give one permission at a time"
            flag="$1"
            shift
            ;;
        --) shift; [ "$#" -gt 0 ] && login="$1"; shift $#; break ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            if [ -z "${action}" ]; then
                action="$1"
            elif [ -z "${login}" ]; then
                login="$1"
            else
                usage_error "too many words: $1"
            fi
            shift
            ;;
    esac
done
case "${action}" in
    list | clear-lockouts) [ -z "${login}" ] || usage_error "${action} takes no login" ;;
    show | grant | deactivate | activate | set-password) [ -n "${login}" ] || usage_error "${action} needs the account's login" ;;
    '') usage_error "no action given" ;;
    *) usage_error "unknown action: ${action}" ;;
esac
if [ "${action}" = grant ]; then
    if [ -n "${sid}" ] || [ -n "${role}" ]; then
        [ -z "${flag}" ] || usage_error "give --survey with --role, or one of the site-wide permissions, not both"
        [[ "${sid}" =~ ^[0-9]{1,9}$ ]] || usage_error "--survey needs the survey's id, a number"
        case "${role}" in full | editor | results | none) ;; *) usage_error "--role is full, editor, results or none" ;; esac
    elif [ -z "${flag}" ]; then
        usage_error "grant needs --survey with --role, --create-surveys, --no-create-surveys, --superadmin or --no-superadmin"
    fi
elif [ -n "${sid}${role}${flag}" ]; then
    usage_error "--survey, --role and the permission options go with grant"
fi
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${action}" in
    list) request='{"action":"list"}' ;;
    clear-lockouts) request='{"action":"clear-lockouts"}' ;;
    show) request="$(jq -nc --arg login "${login}" '{action: "show", login: $login}')" ;;
    deactivate) request="$(jq -nc --arg login "${login}" '{action: "set-active", login: $login, active: false}')" ;;
    activate) request="$(jq -nc --arg login "${login}" '{action: "set-active", login: $login, active: true}')" ;;
    grant)
        case "${flag}" in
            --create-surveys) request="$(jq -nc --arg login "${login}" '{action: "grant", login: $login, can_create_surveys: true}')" ;;
            --no-create-surveys) request="$(jq -nc --arg login "${login}" '{action: "grant", login: $login, can_create_surveys: false}')" ;;
            --superadmin) request="$(jq -nc --arg login "${login}" '{action: "grant", login: $login, superadmin: true}')" ;;
            --no-superadmin) request="$(jq -nc --arg login "${login}" '{action: "grant", login: $login, superadmin: false}')" ;;
            *) request="$(jq -nc --arg login "${login}" --argjson sid "${sid}" --arg role "${role}" '{action: "grant", login: $login, sid: $sid, role: $role}')" ;;
        esac
        ;;
    set-password)
        if [ -t 0 ]; then usage_error "set-password reads the password from stdin, never from the command line"; fi
        # The line is kept byte for byte (IFS= and -r).
        password=''
        IFS= read -r password || [ -n "${password}" ]
        [ -n "${password}" ] || usage_error "set-password needs the password as the first line of stdin"
        # jq gets the password on its stdin, so it is in no command line.
        request="$(printf '%s' "${password}" | jq -Rsc --arg login "${login}" '{action: "set-password", login: $login, password: .}')"
        password=''
        ;;
esac

reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-users.php)"
rc=$?
request=''
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi

account_line='"\(.login)\t\(.full_name)\t<\(.email)>\t" + (if .active then "active" else "switched off" end)
    + (if .superadmin then ", superadmin" else "" end) + (if .can_create_surveys then ", may create surveys" else "" end)
    + (if .can_sign_in_with_password then "" else ", no password sign-in" end)
    + (if .expires then ", expires \(.expires)" else "" end)'

case "${action}" in
    list)
        jq -r ".result | \"The site's main admin is \(.main_admin).\", (.accounts[] | \"  \" + ${account_line})" <<< "${reply}"
        ;;
    show)
        jq -r ".result | ${account_line}, (if .is_main_admin then \"  This is the site's main admin.\" else empty end),
            (if (.owns_surveys | length) > 0 then \"  Owns the surveys: \" + (.owns_surveys | map(tostring) | join(\", \")) else empty end),
            (.survey_permissions | to_entries[] | \"  On survey \(.key): \" + (.value | to_entries | map(\"\(.key) (\(.value | join(\" \")))\") | join(\", \")))" <<< "${reply}"
        ;;
    clear-lockouts)
        jq -r '.result | "Removed \(.removed) records of failed sign-ins. Anyone who was locked out can try again now."' <<< "${reply}"
        ;;
    set-password)
        jq -r '.result | "The password of \(.login) is set. The account'"'"'s open sessions are signed out."' <<< "${reply}"
        ;;
    *)
        jq -r ".result | \"Done: \" + ${account_line}" <<< "${reply}"
        ;;
esac
