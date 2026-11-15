#!/usr/bin/env bash
# LimeSurvey skill: mail-settings.sh
#
# Shows how LimeSurvey sends email, and sends a test message. It never shows the SMTP password and never sets
# one: the admin types the mail server's details into LimeSurvey's own form (Configuration, Global settings,
# Email settings), and this checks the result.
#
# Usage: mail-settings.sh show
#        mail-settings.sh test --to <address> --send
#
#   show   the email method, the SMTP server, user and encryption, the site's sender name and address, and the
#          batch size. For the password it says only whether one is stored and whether this site's keys can still
#          read it (they can't after security.php was lost or replaced).
#   test   sends LimeSurvey's own test message to <address> and prints what the mail server answered, with every
#          credential taken out. It sends an email, so it needs --send, which the playbook gives after the admin
#          has named the address and said yes.
#
# The work runs inside the LimeSurvey container (remote/ls-mail.php, sent by run-in-limesurvey.sh).
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    shown; or the test message was handed to the mail server
#   2    test: the message was not sent (the mail server's answer is printed)
#   1    the call failed, or a tool is missing
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: mail-settings.sh show
       mail-settings.sh test --to <address> --send

show prints LimeSurvey's email settings without the SMTP password (only whether one is stored and can be read).
test sends LimeSurvey's own test message to <address> and prints what the mail server answered. It sends an
email, so it needs --send, after the admin named the address and said yes.

Exit codes: 0 fine, 2 the test message was not sent, 1 a failed call, 64 usage, 75 LimeSurvey is being
installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/mail-settings] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

action=''
to=''
send=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --to)
            [ "$#" -ge 2 ] || usage_error "--to needs an address"
            to="$2"
            shift 2
            ;;
        --to=*) to="${1#--to=}"; shift ;;
        --send) send=1; shift ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            [ -z "${action}" ] || usage_error "give one of show or test"
            action="$1"
            shift
            ;;
    esac
done
case "${action}" in
    show)
        if [ -n "${to}" ] || [ "${send}" -eq 1 ]; then usage_error "show takes no options"; fi
        ;;
    test)
        [[ "${to}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] || usage_error "test needs --to with an address like name@example.com"
        [ "${send}" -eq 1 ] || usage_error "test sends an email, so it needs --send (after the admin named the address and said yes)"
        ;;
    '') usage_error "say show or test" ;;
    *) usage_error "say show or test, not ${action}" ;;
esac
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${action}" = show ]; then
    request='{"action":"settings"}'
else
    request="$(jq -nc --arg to "${to}" '{action: "test", to: $to, send: true}')"
fi
reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-mail.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi

settings_lines='
    "Email method: \(.method)" + (if .can_deliver then "" else " (cannot deliver from this container: it needs a sendmail program, and there is none. Only SMTP works here)" end),
    (if .method == "smtp" then
        "SMTP server: \(.smtp_host)",
        "SMTP user: " + (if .smtp_user == "" then "(none)" else .smtp_user end),
        "SMTP encryption: " + (if .smtp_encryption == "" then "none" else .smtp_encryption end),
        "SMTP password: " + (if .smtp_password_stored then (if .smtp_password_readable then "stored" else "stored, but this site'"'"'s keys cannot read it: the admin has to type it in again" end) else "none stored" end)
     else empty end),
    "Site sender: \(.site_sender_name) <\(.site_sender_email)>",
    (if .site_bounce_email != "" then "Bounces go to: \(.site_bounce_email)" else empty end),
    "Batch size for invitations: \(.batch_size)"'

if [ "${action}" = show ]; then
    jq -r ".result | ${settings_lines}" <<< "${reply}"
    echo "Each survey sends its invitations with its own administrator name and address, which invitations.sh shows."
    exit 0
fi
jq -r ".result | ${settings_lines}" <<< "${reply}"
if [ "$(jq -r '.result.sent' <<< "${reply}")" = true ]; then
    jq -r '.result | "The test message for \(.to) was handed to the mail server. Ask the admin whether it arrived (the spam folder too)."' <<< "${reply}"
    exit 0
fi
jq -r '.result | "The test message was NOT sent: \(.error // "no reason given")",
    (if (.dialogue // []) | length > 0 then "What the mail server said:", (.dialogue[] | "  " + .) else empty end)' <<< "${reply}"
exit 2
