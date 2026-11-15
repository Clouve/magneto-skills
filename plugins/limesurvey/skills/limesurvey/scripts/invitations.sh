#!/usr/bin/env bash
# LimeSurvey skill: invitations.sh
#
# Sends a survey's invitations or reminders to the people on its participant list, and only after it has shown
# what it would send. Without --send it sends nothing: it prints who the mail comes from, how many people would
# get it and how it would be sent, and stops. With --send it sends, and only when the number of recipients is
# still the number the admin agreed to.
#
# Usage: invitations.sh invite --survey <id> [--participant <id>]...
#        invitations.sh remind --survey <id> --min-days <N> [--max-reminders <N>] [--participant <id>]...
#        ... and to send, after the admin's yes:  --send --expect <N>
#
#   invite            people who have not been invited yet
#   remind            people who were invited and have not completed the survey
#   --min-days N      remind: only people whose invitation or last reminder is at least N days old. It is required
#                     and at least 1. Without a gap LimeSurvey reminds everyone again on every call.
#   --max-reminders N remind: only people who have had fewer than N reminders
#   --participant ID  only this person (their id on the list, from participants.sh list); repeat for more
#   --send            send. The playbook gives this option only after the admin has seen the preview and said yes.
#   --expect N        with --send: the number of recipients the preview showed and the admin agreed to. When the
#                     list now gives another number, nothing is sent.
#
# It refuses to send, and the preview says so, when:
#   - the survey is inactive (LimeSurvey itself would send the mails, with a link that does not work);
#   - the survey has no participant list, or has ended;
#   - the site has no public address, so the links would point at localhost;
#   - LimeSurvey's email method cannot deliver from this container (only SMTP can), or the stored SMTP password
#     cannot be read;
#   - the sender address is missing;
#   - a reminder has no --min-days of at least 1.
#
# The sender is the survey's own administrator name and address, not the site's. A mail server can refuse a sender
# it does not know, so the preview shows the address for the admin to check.
#
# The work runs inside the LimeSurvey container (remote/ls-mail.php, sent by run-in-limesurvey.sh), through
# LimeSurvey's own invitation code, batch after batch, until nobody is left or a batch sends nothing.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    the preview shows nothing that stops a send; or, with --send, every mail went out
#   2    it must not be sent as things are (the reasons are printed), or the number of recipients changed
#   3    --send: some or all mails were not sent. The output says how many, with LimeSurvey's reason for each
#        where it gave one, and the ids of the people it left out without a reason (an address its mailer does
#        not accept, most often)
#   1    the survey is not there, the call failed, or a tool is missing
#   64   usage
#   75   LimeSurvey is being installed, upgraded or restored, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: invitations.sh invite --survey <id> [--participant <id>]...
       invitations.sh remind --survey <id> --min-days <N> [--max-reminders <N>] [--participant <id>]...
       ... and to send, after the admin's yes:  --send --expect <N>

Without --send it sends nothing: it shows the sender, the number of recipients and how the mail would go, and
the reasons not to send when there are any. With --send --expect N it sends, and only when the list still gives
N recipients.

  --min-days N       remind: at least N days since the invitation or the last reminder (required, 1 or more)
  --max-reminders N  remind: only people with fewer than N reminders so far
  --participant ID   only this person on the list; repeat for more
  --send             send (only after the admin said yes to the preview)
  --expect N         with --send: the number of recipients the admin agreed to

Exit codes: 0 fine, 2 must not be sent as things are, 3 some mails were not sent, 1 a failed call, 64 usage,
75 LimeSurvey is being installed, upgraded or restored, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/invitations] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}
# number OPTION VALUE: VALUE, when it is a number of up to 9 digits
number() {
    [[ "$2" =~ ^[0-9]{1,9}$ ]] || usage_error "$1 needs a number"
    printf '%s' "$2"
}

kind=''
sid=''
min_days=''
max_reminders=''
send=0
expect=''
participants=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --survey | --min-days | --max-reminders | --participant | --expect)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            value="$(number "$1" "$2")" || exit 64
            case "$1" in
                --survey) sid="${value}" ;;
                --min-days) min_days="${value}" ;;
                --max-reminders) max_reminders="${value}" ;;
                --participant) participants+=("${value}") ;;
                --expect) expect="${value}" ;;
            esac
            shift 2
            ;;
        --send) send=1; shift ;;
        -*) usage_error "unknown option: $1" ;;
        *)
            [ -z "${kind}" ] || usage_error "give one of invite or remind"
            kind="$1"
            shift
            ;;
    esac
done
case "${kind}" in
    invite | remind) ;;
    '') usage_error "say invite or remind" ;;
    *) usage_error "say invite or remind, not ${kind}" ;;
esac
[ -n "${sid}" ] || usage_error "--survey needs the survey's id"
if [ "${kind}" = invite ] && { [ -n "${min_days}" ] || [ -n "${max_reminders}" ]; }; then
    usage_error "--min-days and --max-reminders go with remind"
fi
if [ "${send}" -eq 1 ] && [ -z "${expect}" ]; then
    usage_error "--send needs --expect <N>: the number of recipients the preview showed and the admin agreed to"
fi
if [ "${send}" -eq 0 ] && [ -n "${expect}" ]; then
    usage_error "--expect goes with --send"
fi
command -v jq > /dev/null 2>&1 || { msg "jq is not installed (the limesurvey plugin's install.sh adds it)"; exit 1; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ids_json="$(printf '%s\n' ${participants[@]+"${participants[@]}"} | jq -Rnc '[inputs | select(length > 0) | tonumber]')"

request="$(jq -nc --arg kind "${kind}" --argjson sid "${sid}" --arg min "${min_days}" --arg max "${max_reminders}" \
    --argjson ids "${ids_json}" --argjson send "${send}" --arg expect "${expect}" \
    '{action: (if $send == 1 then "send" else "preview" end), kind: $kind, sid: $sid, token_ids: $ids}
     + (if $min != "" then {min_days: ($min | tonumber)} else {} end)
     + (if $max != "" then {max_reminders: ($max | tonumber)} else {} end)
     + (if $send == 1 then {send: true, expect: ($expect | tonumber)} else {} end)')"

reply="$(printf '%s' "${request}" | "${script_dir}/run-in-limesurvey.sh" --stdin ls-mail.php)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    error="$(jq -r '.error // empty' <<< "${reply}" 2> /dev/null)"
    if [ -n "${error}" ]; then msg "${error}"; fi
    exit "${rc}"
fi
result="$(jq -c '.result' <<< "${reply}")"

what=invitations
if [ "${kind}" = remind ]; then what=reminders; fi

# The same lines before a send and after one: what goes out, to how many, from whom, and how.
jq -r --arg what "${what}" '
    "Survey \(.sid): \(.title // "(no title)") (" + (if .active == "Y" then "active" else "INACTIVE" end) + ")",
    "  Recipients: \(.recipients) " + (if .token_ids | length > 0 then "of the \(.token_ids | length) people named" else "people" end)
        + (if .kind == "remind" and .min_days != null then ", invited or last reminded at least \(.min_days) day(s) ago" else "" end)
        + (if .max_reminders != null then ", with fewer than \(.max_reminders) reminders so far" else "" end),
    (if .participants then "  The list: \(.participants.total) people, \(.participants.invited) invited, \(.participants.completed) completed" + (if .participants.email_not_ok > 0 then ", \(.participants.email_not_ok) with an email status that is not OK" else "" end) else empty end),
    "  From: \(.sender_name) <\(.sender_email)>" + (if .return_path != "" and .return_path != .sender_email then " (bounces go to \(.return_path))" else "" end),
    "  Subject: \(.subject // "(none)")",
    "  Sent through: \(.method)" + (if .method == "smtp" then " (\(.smtp_host))" else "" end) + ", \(.batch_size) per batch",
    "  The link in each mail: \(.link_example)"
' <<< "${result}"

blockers="$(jq -r '.blockers | length' <<< "${result}")"
if [ "${send}" -eq 0 ]; then
    if [ "${blockers}" -gt 0 ]; then
        echo "The ${what} must not be sent as things are:"
        jq -r '.blockers[] | "  - " + .' <<< "${result}"
        echo "Nothing was sent."
        exit 2
    fi
    recipients="$(jq -r '.recipients' <<< "${result}")"
    echo "Nothing was sent. This was the preview."
    if [ "${recipients}" -gt 0 ]; then
        echo "Show the admin the lines above. After a clear yes, run the same command again with: --send --expect ${recipients}"
    else
        echo "Nobody on the list would get mail."
    fi
    exit 0
fi

if [ "$(jq -r '.refused' <<< "${result}")" = true ]; then
    echo "Nothing was sent:"
    jq -r '.blockers[] | "  - " + .' <<< "${result}"
    exit 2
fi
jq -r --arg what "${what}" '"Sent \(.sent) \($what)." + (if (.failed | length) > 0 then " \(.failed | length) were not sent:" else "" end),
    (.failed[] | "  - participant \(.id): \(.error)"),
    (if (.not_mailed // 0) > 0 then
        "\(.not_mailed) of the \(.expect_was) people were not mailed, and LimeSurvey gave no reason. Its mailer leaves out an address it does not accept. Their ids on the list: " + (.not_mailed_ids | map(tostring) | join(", ")) + (if .not_mailed > (.not_mailed_ids | length) then ", and more" else "" end) + ".",
        "  Ask the admin to check those people'"'"'s addresses (participants.sh list shows them). They are still uninvited, so a later send would try them again."
     else empty end),
    (if .stopped then "  " + .stopped else empty end)' <<< "$(jq -c --argjson expect "${expect}" '. + {expect_was: $expect}' <<< "${result}")"
if [ "$(jq -r '(.failed | length) + (.not_mailed // 0) + (if .stopped then 1 else 0 end)' <<< "${result}")" -gt 0 ]; then
    exit 3
fi
exit 0
