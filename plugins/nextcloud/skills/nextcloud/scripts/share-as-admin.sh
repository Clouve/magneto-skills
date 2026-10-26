#!/usr/bin/env bash
# Nextcloud DevOps Skill: share-as-admin.sh
#
# Creates, lists or revokes shares of the main admin's OWN files through Nextcloud's files_sharing
# OCS API. The API acts only as the account that signs in: no admin can create or change a
# share for another account (ShareAPIController has no admin override). So the script signs
# in as that admin, with a short-lived app password it makes with occ and always deletes.
# Other people share their own files; playbooks/share-files-and-links.md says how.
#
# Usage: share-as-admin.sh --as <uid> create --path <path> --type link|user|group|email
#                          [--with <uid|group|address>] [--permissions <1-31>] [--expire YYYY-MM-DD]
#                          [--password] [--note <text>] [--label <text>] [--send-mail]
#        share-as-admin.sh --as <uid> list [--path <path>]
#        share-as-admin.sh --as <uid> delete <share id>
#
#   --as UID         The account whose files they are. It must be an enabled member of the
#                    admin group, and the deployment's main admin when NEXTCLOUD_ADMIN_USER is
#                    set (exit 2 if not). Its spelling is taken from occ, so ADMIN finds admin.
#   --path PATH      Relative to that account's home, like /Documents/Q3 report.pdf.
#   --type           link (shareType 3), user (0), group (1) or email (4).
#   --with           Who gets it: required for user, group and email, refused for link.
#   --permissions    1 to 31, the sum of read 1, update 2, create 4, delete 8, share 16.
#                    Left out, the server's default applies.
#   --expire         YYYY-MM-DD. Nextcloud moves it to 23:59:59 in the account's time zone.
#   --password       For link and email shares: makes a 20-character password (the same
#                    generator temp-password.sh uses), sends it with the share and, once the
#                    share exists, saves ~/nextcloud-passwords/share-<id>-<UTC YYYYmmdd-HHMMSS>.txt
#                    (mode 600) with the link, the password and the expiry. The password is
#                    never printed. If the file can't be saved the share is deleted again and
#                    the exit code is 4.
#   --note TEXT      A note that Nextcloud shows with the share (any type).
#   --label TEXT     A label for the link (link and email shares only).
#   --send-mail      Let Nextcloud mail the recipient. Without it the script sends sendMail=false,
#                    because a request that leaves it out makes the server mail user-share
#                    recipients that have an address.
#   list             The shares the account made. With --path, only those of that path, and the
#                    ones other people made of it by resharing too (reshares=true).
#
# The steps, in order, so a refusal never leaves anything behind:
#   1. The arguments (exit 64), then the environment (exit 1).
#   2. The admin check: occ user:info shows the account and that it is enabled, occ group:list
#      shows that the admin group holds it. Else exit 2, and nothing has been made or called.
#      When NEXTCLOUD_ADMIN_USER is set the account must also be that one: this script acts only
#      as the deployment's main admin, because the assistant never makes an app password for
#      another person, and another admin is another person. Then, for a user share, --with is
#      looked up with occ user:info too, and the share goes to the login it returns: another
#      spelling of the login is taken, and anything else, such as an email address, is exit 2
#      with the login named.
#   3. The lock: an exclusive flock on ${TMPDIR:-/tmp}/clouve-share-as-admin.lock, taken before
#      anything is swept or made and held until the process exits, the clean-up included. A run
#      waits up to 120 seconds for it (exit 3 after that). The kernel drops it when a run dies,
#      SIGKILL included. Why: a second run's sweep would delete the first run's app password
#      while it is in use. The first run would get a 401, and Nextcloud counts each failed
#      Basic-auth login against the agent's address (Session::handleLoginFailed registers a
#      'login' attempt that nothing on this path resets; Throttler::sleepDelayOrThrowOnMax:
#      attempts count for 12 hours with growing delays, and more than 10 in 30 minutes is a 429
#      on every call from the address).
#   4. From here on an EXIT trap deletes the temporary app password, and INT, TERM and HUP
#      end the run through it (exit 130, 143, 129). A sweep first deletes every app password
#      of the account named clouve-ai-assistant-temporary, the kind an earlier run leaves if
#      it was killed with SIGKILL, and reads the list back to be sure they are gone.
#   5. occ user:auth-tokens:add makes the app password. It has no login password, so its
#      capabilities are limited, and it is enough for shares. The script keeps the last line
#      of occ's output that is 72 letters and digits. It never prints it.
#   6. One curl call to http://$NEXTCLOUD_HOST/ocs/v2.php/apps/files_sharing/api/v1/shares
#      (curl -q -sS -m 30 -K - --noproxy '*' [-G] -X METHOD): -q skips ~/.curlrc and --noproxy
#      ignores any proxy variable, so nothing but this one request can carry the credentials, and
#      curl follows no redirect. The public host from NEXTCLOUD_URL is the Host header, so the link
#      Nextcloud builds is the public one. The credentials, the headers and every field go in
#      curl's config on stdin (-K -), never in a command line. A value is written between double
#      quotes with backslash, quote, newline, return and tab escaped, so it can't end its line or
#      add an option such as url or output.
#   7. The result is read, and the EXIT trap deletes the app password and reads the list back.
#
# Output (stdout): one line per share, the same for create and list:
#   id=42 share_type=link path="/Docs/Q3 report.pdf" share_with=- permissions=17 expiration="2026-12-31 23:59:59" url="https://..."
# Text values are JSON strings, so a path with a quote or a line break stays on its line. A
# link's share_with is -, expiration is none without one, and url is there when Nextcloud returns
# it. With --password a second line says `password saved to nextcloud-passwords/<file>`. delete
# prints `deleted share <id>`. A list with no shares prints `no shares`.
#
# Env vars read:
#   NEXTCLOUD_HOST        pod-internal host name of the Nextcloud container (for occ.sh, and the OCS URL)
#   NEXTCLOUD_URL         the public address, https://host: its host is the Host header
#   NEXTCLOUD_ADMIN_USER  the deployment's main admin. When it is set, --as must be that account
#                         (compared without regard to case)
#   TMPDIR                where the lock file goes (default /tmp)
#   HOME                  where ~/nextcloud-passwords lives (--password only)
# It needs no agent-side secret itself: occ.sh loads the one it uses.
#
# Exit codes:
#   0   done
#   64  usage
#   1   NEXTCLOUD_HOST or NEXTCLOUD_URL is missing or malformed; jq, curl or flock is not installed;
#       HOME is not a folder (--password); no link password could be drawn; the lock file can't be
#       opened
#   2   the account is not an enabled admin, or is not the deployment's main admin; --with names no
#       account, or isn't the login of the one it finds (a user share)
#   3   Nextcloud refused or did not answer (the OCS message and the HTTP status are shown); an occ
#       call failed or printed no JSON; no app password could be made; the lock was not free within
#       120 seconds. Normally nothing was made and the request can be repeated; after a lost answer,
#       or an OK with no share id, look at list first.
#   4   the link password could not be saved (the share was deleted again; if that failed too, the
#       message says so and how to delete it)
#   5   the request went through (the share exists, or is gone, or the list is on stdout) but the
#       temporary app password could not be deleted afterwards. Do not repeat the request: delete
#       the app password with the command the warning shows. The next run's sweep deletes it, too.
#   128+n  killed by signal n (143 for SIGTERM): the app password is deleted first
#
# Things to know:
#   - A SIGKILL can't be caught. The app password stays until the next run's sweep, or until
#     occ.sh user:auth-tokens:delete removes it. The lock does not stay: the kernel drops it.
#   - Runs take turns, so a second call waits for the first. Anything else that deletes app
#     passwords named clouve-ai-assistant-temporary during a run still fails it with HTTP 401, and
#     each failed login counts toward Nextcloud's brute-force throttle for the agent's address.
#   - Nextcloud allows 20 new shares per 10 minutes for each account (HTTP 429 after that).
#   - delete takes any share id the account may delete. That includes a share someone else made
#     with the account: a user share is then deleted for everyone, and a group share only for the
#     account (ShareAPIController::deleteShare). Take the id from list, which shows the account's own.
#   - The request goes over plain HTTP inside the cluster, to the container's own address. The app
#     password it carries is limited (no login password behind it) and lives for a few seconds.
#   - Every run that makes its app password, a list included, leaves an entry in the account's Activity,
#     under Security: "An administrator created an app password for a session named "clouve-ai-assistant-temporary"".
#     occ has no signed-in user, so Nextcloud names no one and says "An administrator". Security
#     entries go out by email by default, and a user can't turn that off, so once Nextcloud can
#     send mail the account's address gets it, about an hour later with Activity's default batch
#     (an hour's entries in one email, sent by cron), unless Activity's emails are off for the
#     whole server. The delete adds no entry.
#
# Sources, all v35.0.2: apps/files_sharing/lib/Controller/ShareAPIController.php (createShare with
# its rate limit, formatShare, deleteShare), core/Command/User/AuthTokens/{Add,Delete,ListCommand}.php,
# core/Command/Group/ListCommand.php, and for the Activity entry
# apps/settings/lib/Listener/AppPasswordCreatedActivityListener.php and
# apps/settings/lib/Activity/{Provider,SecuritySetting}.php, with the Activity app 8.0.0 in the
# image (lib/Consumer.php and lib/UserSettings.php).

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the app password and the link password.
set +x

usage() {
    cat <<'EOF'
Usage: share-as-admin.sh --as <uid> create --path <path> --type link|user|group|email
                         [--with <uid|group|address>] [--permissions <1-31>] [--expire YYYY-MM-DD]
                         [--password] [--note <text>] [--label <text>] [--send-mail]
       share-as-admin.sh --as <uid> list [--path <path>]
       share-as-admin.sh --as <uid> delete <share id>

Creates, lists or revokes shares of the main admin's own files through Nextcloud's OCS API, signed in
with a short-lived app password that is always deleted again. <uid> must be the enabled main admin.

  --type        link, user, group or email; user, group and email need --with, link refuses it
  --note TEXT   a note shown with the share (any type)
  --label TEXT  a label for a link or email share
  --permissions 1 to 31: read 1, update 2, create 4, delete 8, share 16 (default: the server's)
  --expire      the last day the share works
  --password    link and email shares: make a password, send it, and save it in
                ~/nextcloud-passwords (never printed)
  --send-mail   let Nextcloud mail the recipient (without it, no mail goes out)

Prints one line per share. Exit codes: 0 done, 64 usage, 1 a missing setting or tool, 2 the
account is not the enabled main admin, 3 Nextcloud refused (or the lock was not free), 4 the link
password could not be saved, 5 the request went through but the temporary app password could not
be deleted (do not repeat the request; the warning shows the command that deletes it).
EOF
}

msg() { printf '[nextcloud/share-as-admin] %s\n' "$*" >&2; }

die() {
    local code="$1"
    shift
    msg "$@"
    exit "${code}"
}

usage_error() {
    msg "$@"
    usage >&2
    exit 64
}

# ---------------------------------------------------------------------------
# 1. Arguments
# ---------------------------------------------------------------------------
as_uid=""
path=""
share_type=""
with=""
permissions=""
expire=""
note=""
label=""
want_password=0
send_mail=0
given=()
positional=()

# set_option NAME VALUE: keeps the value of an option that takes one; empty is a usage error
set_option() {
    [ -n "$2" ] || usage_error "$1 needs a value"
    case "$1" in
        --as) as_uid="$2" ;;
        --path) path="$2" ;;
        --type) share_type="$2" ;;
        --with) with="$2" ;;
        --permissions) permissions="$2" ;;
        --expire) expire="$2" ;;
        --note) note="$2" ;;
        --label) label="$2" ;;
    esac
    given+=("$1")
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --password) want_password=1; given+=("$1"); shift ;;
        --send-mail) send_mail=1; given+=("$1"); shift ;;
        --as | --path | --type | --with | --permissions | --expire | --note | --label)
            [ "$#" -ge 2 ] || usage_error "$1 needs a value"
            set_option "$1" "$2"
            shift 2
            ;;
        --as=* | --path=* | --type=* | --with=* | --permissions=* | --expire=* | --note=* | --label=*)
            set_option "${1%%=*}" "${1#*=}"
            shift
            ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -?*) usage_error "unknown option: $1" ;;
        *) positional+=("$1"); shift ;;
    esac
done

[ -n "${as_uid}" ] || usage_error "--as <uid> is required"
[ "${#positional[@]}" -ge 1 ] || usage_error "give an action: create, list or delete"
action="${positional[0]}"
case "${action}" in
    create) allowed=" --as --path --type --with --permissions --expire --note --label --password --send-mail " ;;
    list) allowed=" --as --path " ;;
    delete) allowed=" --as " ;;
    *) usage_error "unknown action '${action}': use create, list or delete" ;;
esac
for opt in ${given[@]+"${given[@]}"}; do
    [[ "${allowed}" == *" ${opt} "* ]] || usage_error "${opt} does not go with ${action}"
done

type_n=""
share_id=""
case "${action}" in
    create)
        [ "${#positional[@]}" -eq 1 ] || usage_error "create takes options only, not '${positional[1]}'"
        [ -n "${path}" ] || usage_error "create needs --path"
        case "${share_type}" in
            link) type_n=3 ;;
            user) type_n=0 ;;
            group) type_n=1 ;;
            email) type_n=4 ;;
            '') usage_error "create needs --type link, user, group or email" ;;
            *) usage_error "unknown --type '${share_type}': use link, user, group or email" ;;
        esac
        if [ "${share_type}" = link ]; then
            [ -z "${with}" ] || usage_error "--with does not go with --type link: a link has no recipient"
        else
            [ -n "${with}" ] || usage_error "--type ${share_type} needs --with"
        fi
        if [ "${share_type}" = email ] && ! [[ "${with}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
            usage_error "--type email needs --with name@example.com"
        fi
        if [ "${share_type}" != link ] && [ "${share_type}" != email ]; then
            [ "${want_password}" -eq 0 ] || usage_error "--password only protects link and email shares"
            [ -z "${label}" ] || usage_error "--label only goes with link and email shares"
        fi
        if [ -n "${permissions}" ]; then
            if ! [[ "${permissions}" =~ ^[0-9]{1,2}$ ]] || [ "$((10#${permissions}))" -lt 1 ] || [ "$((10#${permissions}))" -gt 31 ]; then
                usage_error "--permissions needs a whole number from 1 to 31 (read 1, update 2, create 4, delete 8, share 16)"
            fi
            permissions="$((10#${permissions}))"
        fi
        if [ -n "${expire}" ] && ! [[ "${expire}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            usage_error "--expire needs a date like 2026-12-31 (YYYY-MM-DD)"
        fi
        ;;
    list)
        [ "${#positional[@]}" -eq 1 ] || usage_error "list takes options only, not '${positional[1]}'"
        ;;
    delete)
        [ "${#positional[@]}" -eq 2 ] || usage_error "delete needs exactly one share id"
        share_id="${positional[1]}"
        [[ "${share_id}" =~ ^[0-9]+$ ]] || usage_error "the share id is a number like 42 (list shows them)"
        ;;
esac

# ---------------------------------------------------------------------------
# The environment
# ---------------------------------------------------------------------------
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# lib/nextcloud-passwords.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/nextcloud-passwords.sh" || exit 1

re_host='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$'
[ -n "${NEXTCLOUD_HOST:-}" ] || die 1 "NEXTCLOUD_HOST is not set"
[ -n "${NEXTCLOUD_URL:-}" ] || die 1 "NEXTCLOUD_URL is not set"
[[ "${NEXTCLOUD_HOST}" =~ ${re_host} ]] || die 1 "NEXTCLOUD_HOST must be a plain host name like tkt-7-nextcloud"
public_host="${NEXTCLOUD_URL#*://}"
public_host="${public_host%%[/?#]*}"
[[ "${public_host}" =~ ${re_host} ]] || die 1 "NEXTCLOUD_URL must look like https://cloud.example.com"
command -v jq > /dev/null 2>&1 || die 1 "jq is not installed (the nextcloud plugin's install.sh adds it)"
command -v curl > /dev/null 2>&1 || die 1 "curl is not installed (the nextcloud plugin's install.sh adds it)"
command -v flock > /dev/null 2>&1 || die 1 "flock is not installed (it comes with util-linux)"
if [ "${want_password}" -eq 1 ]; then
    { [ -n "${HOME:-}" ] && [ -d "${HOME}" ]; } || die 1 "HOME is not an existing folder, so the link password has no place to be saved"
fi

temp_name=clouve-ai-assistant-temporary
ocs_url="http://${NEXTCLOUD_HOST}/ocs/v2.php/apps/files_sharing/api/v1/shares"
re_token='^[A-Za-z0-9]{72}$'

uid="${as_uid}"       # the account's own spelling, once occ has shown it
app_token=""          # the temporary app password: in this variable and curl's stdin, nowhere else
link_pw=""            # the link password, when --password asked for one
mint_attempted=0
sweep_error=""
temp_ids=()
cfg=""
ocs_http=""
ocs_body=""
ocs_code=""
ocs_msg=""
ocs_curl_rc=0

# The link password is made now, so a machine that can't draw one stops before anything is done.
if [ "${want_password}" -eq 1 ]; then
    link_pw="$(nc_generate_password)" || die 1 "could not make a link password"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# scrub TEXT: TEXT with the app password, the link password and anything that looks like a token
# blanked out. Every word of occ's or Nextcloud's that reaches stderr goes through this.
scrub() {
    local t="$1"
    if [ -n "${app_token}" ]; then t="${t//"${app_token}"/[hidden]}"; fi
    if [ -n "${link_pw}" ]; then t="${t//"${link_pw}"/[hidden]}"; fi
    printf '%s\n' "${t}" | sed -E 's/[A-Za-z0-9]{32,}/[hidden]/g'
}

# json_line TEXT: prints the first line of TEXT that is a JSON object or list, and fails if there is none.
# occ may print a notice or a PHP warning before its JSON.
json_line() {
    local line
    while IFS= read -r line; do
        case "${line}" in
            '{'* | '['*)
                if jq -e 'type == "object" or type == "array"' > /dev/null 2>&1 <<< "${line}"; then
                    printf '%s' "${line}"
                    return 0
                fi
                ;;
        esac
    done <<< "$1"
    return 1
}

# lookup_failed WHAT CODE TEXT: exit 3, because an occ call that decides who may share did not work
lookup_failed() {
    msg "could not check whether \"${as_uid}\" is an admin: $1"
    scrub "$3" >&2
    exit 3
}

# refuse REASON: exit 2
refuse() {
    msg "${as_uid} isn't an enabled admin; other people share their own files (see playbooks/share-files-and-links.md)"
    msg "  ($1)"
    exit 2
}

# ---------------------------------------------------------------------------
# 2. The admin check
# ---------------------------------------------------------------------------
check_admin() {
    local text rc json member enabled canonical
    text="$("${script_dir}/occ.sh" user:info --output=json -- "${as_uid}" 2>&1)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        # "user not found", on a line of its own with exit 1, is what occ says for an account that doesn't exist.
        # Any other text is another failure: occ.sh not getting the ops password says "clv-secret: command not
        # found", which must not be taken for a missing account.
        if [ "${rc}" -eq 1 ] && [[ $'\n'"${text}"$'\n' == *$'\nuser not found\n'* ]]; then
            refuse "there is no account called \"${as_uid}\""
        fi
        lookup_failed "user:info failed (exit ${rc}):" "${rc}" "${text}"
    fi
    json="$(json_line "${text}")" || lookup_failed "user:info printed no JSON:" 0 "${text}"
    canonical="$(jq -r '.user_id // empty | tostring' <<< "${json}" 2> /dev/null)" || canonical=""
    enabled="$(jq -r '.enabled' <<< "${json}" 2> /dev/null)" || enabled=""
    [ -n "${canonical}" ] || lookup_failed "user:info shows no user_id:" 0 "${text}"
    uid="${canonical}"

    text="$("${script_dir}/occ.sh" group:list --output=json admin 2>&1)"
    rc=$?
    [ "${rc}" -eq 0 ] || lookup_failed "group:list failed (exit ${rc}):" "${rc}" "${text}"
    json="$(json_line "${text}")" || lookup_failed "group:list printed no JSON:" 0 "${text}"
    # group:list admin also finds groups such as sub-admins, so only the exact admin key counts. With
    # no match at all PHP prints [] and not {}.
    member="$(jq -r --arg uid "${uid}" 'if type == "object" then ((.admin // []) | index($uid) != null) else false end' <<< "${json}" 2> /dev/null)" || member=""
    case "${member}" in
        true | false) ;;
        *) lookup_failed "group:list gave an answer that is not a list of members:" 0 "${text}" ;;
    esac
    [ "${member}" = true ] || refuse "the account is not in the admin group"
    [ "${enabled}" = true ] || refuse "the account is disabled"
    # The deployment's main admin is the only account this acts as: the assistant shares that admin's own files and
    # never makes an app password for another person, and another admin is another person.
    if [ -n "${NEXTCLOUD_ADMIN_USER:-}" ] && [ "${uid,,}" != "${NEXTCLOUD_ADMIN_USER,,}" ]; then
        msg "share-as-admin.sh acts only as the deployment's main admin (${NEXTCLOUD_ADMIN_USER}); other people, other admins included, share their own files"
        exit 2
    fi
}

check_admin

# check_with: for a user share. Nextcloud takes shareWith as it is given, as long as an account answers to it, and an
# account answers to its login in any case and to its email address. But a person sees only the shares stored under
# their exact login. So --with is looked up first, and the share goes to the login user:info returns. Another spelling of
# that login is fine. Anything else, such as an email address, is refused with the login named, because two accounts can
# share an address and the lookup would pick one of them.
check_with() {
    local text rc json canonical
    text="$("${script_dir}/occ.sh" user:info --output=json -- "${with}" 2>&1)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        if [ "${rc}" -eq 1 ] && [[ $'\n'"${text}"$'\n' == *$'\nuser not found\n'* ]]; then
            die 2 "there is no account \"${with}\" to share with (occ.sh user:list shows the logins). Nothing was shared."
        fi
        msg "could not look up \"${with}\": user:info failed (exit ${rc}):"
        scrub "${text}" >&2
        exit 3
    fi
    json="$(json_line "${text}")" || { msg "could not look up \"${with}\": user:info printed no JSON:"; scrub "${text}" >&2; exit 3; }
    canonical="$(jq -r '.user_id // empty | tostring' <<< "${json}" 2> /dev/null)" || canonical=""
    [ -n "${canonical}" ] || { msg "could not look up \"${with}\": user:info shows no user_id:"; scrub "${text}" >&2; exit 3; }
    if [ "${canonical}" != "${with}" ]; then
        if [ "${canonical,,}" != "${with,,}" ]; then
            die 2 "\"${with}\" is not a login: Nextcloud finds the account \"${canonical}\" by it (its email address, or another spelling). Check with the user that this is the person, then run this again with --with $(printf '%q' "${canonical}"). Nothing was shared."
        fi
        msg "the login is spelled ${canonical}, so the share is made for that"
        with="${canonical}"
    fi
}

if [ "${action}" = create ] && [ "${type_n}" = 0 ]; then
    check_with
fi

# ---------------------------------------------------------------------------
# 3. The lock: one run at a time
# ---------------------------------------------------------------------------
# A second run's sweep would delete the first run's app password while it is in use. The first run would get a 401,
# and every failed Basic-auth login is registered as a 'login' attempt for the agent's address that nothing here
# resets (Session::handleLoginFailed): attempts count for 12 hours with growing delays, and more than 10 in 30
# minutes is a 429 on every call (Throttler::sleepDelayOrThrowOnMax). So the lock is taken before the sweep and
# kept, on file descriptor 9, until the process exits: the clean-up runs first, and the kernel drops the lock when a
# run is killed, SIGKILL included. The file is only a name for the lock, and stays empty.
lock_file="${TMPDIR:-/tmp}/clouve-share-as-admin.lock"
exec 9>> "${lock_file}" || die 1 "could not open the lock file ${lock_file}"
flock -w 120 9 || die 3 "the lock ${lock_file} was not free within 120 seconds: another share-as-admin.sh run is still going. Try again when it has finished."

# ---------------------------------------------------------------------------
# 4. The app password's life: swept before, deleted after, however the run ends
# ---------------------------------------------------------------------------
# temp_token_ids: fills temp_ids with the ids of the account's app passwords named clouve-ai-assistant-temporary.
# Fails, with the reason in sweep_error, if occ fails or prints no list.
temp_token_ids() {
    local text rc json ids id
    temp_ids=()
    text="$("${script_dir}/occ.sh" user:auth-tokens:list --output=json -- "${uid}" 2>&1)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        sweep_error="could not list the app passwords of \"${uid}\" (exit ${rc}): ${text}"
        return 1
    fi
    if ! json="$(json_line "${text}")"; then
        sweep_error="could not list the app passwords of \"${uid}\": occ printed no JSON: ${text}"
        return 1
    fi
    if ! ids="$(jq -r --arg name "${temp_name}" 'if type == "array" then .[] | select(.name == $name) | .id else error("not a list") end' <<< "${json}" 2> /dev/null)"; then
        sweep_error="could not list the app passwords of \"${uid}\": occ's answer is not a list: ${text}"
        return 1
    fi
    while IFS= read -r id; do
        [ -n "${id}" ] || continue
        if ! [[ "${id}" =~ ^[0-9]+$ ]]; then
            sweep_error="could not list the app passwords of \"${uid}\": '${id}' is not an id"
            return 1
        fi
        temp_ids+=("${id}")
    done <<< "${ids}"
}

# sweep_tokens: deletes every app password named clouve-ai-assistant-temporary, then lists them again.
# Returns 0 when none is left, with the number it removed in sweep_removed. Otherwise returns 1 and
# leaves the reason in sweep_error and the ids that may still be there in sweep_left: an occ call
# failed, or the list still shows one (occ exits 0 for a delete that did nothing). It stops at the
# first delete that fails; the run that comes next sweeps the rest.
sweep_removed=0
sweep_left=""
sweep_tokens() {
    local i found=() delete_text
    sweep_removed=0
    sweep_left=""
    temp_token_ids || return 1
    [ "${#temp_ids[@]}" -gt 0 ] || return 0
    found=("${temp_ids[@]}")
    for ((i = 0; i < ${#found[@]}; i++)); do
        if ! delete_text="$("${script_dir}/occ.sh" user:auth-tokens:delete -- "${uid}" "${found[i]}" 2>&1)"; then
            sweep_left="${found[*]:i}"
            sweep_error="could not delete the app password ${found[i]} named ${temp_name}: ${delete_text}"
            return 1
        fi
    done
    temp_token_ids || return 1
    if [ "${#temp_ids[@]}" -gt 0 ]; then
        sweep_left="${temp_ids[*]}"
        sweep_error="the app password(s) named ${temp_name} are still there after deleting them (id ${sweep_left})"
        return 1
    fi
    sweep_removed="${#found[@]}"
}

# cleanup: the EXIT trap. A signal during it is ignored, so a second Ctrl-C can't stop the delete.
cleanup() {
    local rc=$? quoted_uid id left_ids=()
    trap '' INT TERM HUP PIPE
    if [ "${mint_attempted}" -eq 1 ]; then
        if ! sweep_tokens; then
            printf -v quoted_uid '%q' "${uid}"
            msg "WARNING: the temporary app password named ${temp_name} could not be deleted, so it is still valid."
            scrub "${sweep_error}" >&2
            if [ "${rc}" -eq 0 ]; then msg "The request itself went through; do not repeat it."; fi
            read -ra left_ids <<< "${sweep_left}"
            if [ "${#left_ids[@]}" -gt 0 ]; then
                for id in "${left_ids[@]}"; do
                    msg "Delete it with: ${script_dir}/occ.sh user:auth-tokens:delete -- ${quoted_uid} ${id}"
                done
            else
                msg "Find its id with: ${script_dir}/occ.sh user:auth-tokens:list -- ${quoted_uid} (the one named ${temp_name}), then delete it with user:auth-tokens:delete."
            fi
            msg "The next run of this script deletes it, too."
            if [ "${rc}" -eq 0 ]; then rc=5; fi
        fi
    fi
    exit "${rc}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if ! sweep_tokens; then
    msg "an earlier app password could not be cleared, so no new one was made:"
    scrub "${sweep_error}" >&2
    exit 3
fi
if [ "${sweep_removed}" -gt 0 ]; then
    msg "removed ${sweep_removed} leftover app password(s) named ${temp_name} from an earlier run"
fi

# ---------------------------------------------------------------------------
# 5. Making the app password
# ---------------------------------------------------------------------------
mint_token() {
    local out rc rest line
    mint_attempted=1
    out="$("${script_dir}/occ.sh" user:auth-tokens:add "--name=${temp_name}" -- "${uid}" 2>&1)"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        msg "could not make the temporary app password (exit ${rc}):"
        scrub "${out}" >&2
        exit 3
    fi
    # The last line that is 72 letters and digits. rest walks the output line by line with parameter
    # expansion: a here-string would do, but older bashes write it to a temporary file.
    rest="${out}"
    while [ -n "${rest}" ]; do
        line="${rest%%$'\n'*}"
        if [ "${line}" = "${rest}" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
        if [[ "${line}" =~ ${re_token} ]]; then app_token="${line}"; fi
    done
    if [ -z "${app_token}" ]; then
        msg "occ printed no app password (a line of 72 letters and digits), so there is nothing to sign in with:"
        scrub "${out}" >&2
        exit 3
    fi
    out=""
}
mint_token

# ---------------------------------------------------------------------------
# 6. The OCS call
# ---------------------------------------------------------------------------
# cfg_add OPTION VALUE: appends a line of curl's config. The value sits between double quotes, where curl
# reads \\ \" \n \r \t \v, so a quote, a backslash or a line break in it stays part of the value and can
# neither end the line nor start another option.
cfg_add() {
    local v="$2"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    v="${v//$'\v'/\\v}"
    cfg+="$1 = \"${v}\""$'\n'
}

# ocs METHOD URL [NAME=VALUE]...: one call, signed in as the account with the app password. The fields go
# in curl's config, so none of it is in a command line. For GET they are sent in the query (-G), else in the
# body. Leaves the HTTP status in ocs_http, the body in ocs_body and curl's exit code in ocs_curl_rc.
ocs() {
    local method="$1" url="$2" field resp
    local get=()
    shift 2
    cfg=""
    cfg_add user "${uid}:${app_token}"
    cfg_add header "Host: ${public_host}"
    cfg_add header "OCS-APIRequest: true"
    cfg_add header "Accept: application/json"
    for field in "$@"; do cfg_add data-urlencode "${field}"; done
    if [ "$#" -gt 0 ] && [ "${method}" = GET ]; then get=(-G); fi
    resp="$(printf '%s' "${cfg}" | curl -q -sS -m 30 -K - --noproxy '*' ${get[@]+"${get[@]}"} -X "${method}" -w '\n%{http_code}' "${url}")"
    ocs_curl_rc=$?
    cfg=""
    ocs_http="${resp##*$'\n'}"
    ocs_body="${resp%$'\n'*}"
    if ! [[ "${ocs_http}" =~ ^[0-9]{3}$ ]]; then
        ocs_http=000
        ocs_body="${resp}"
    fi
    ocs_code=""
    ocs_msg=""
    ocs_code="$(jq -r '.ocs.meta.statuscode // empty' <<< "${ocs_body}" 2> /dev/null)" || ocs_code=""
    ocs_msg="$(jq -r '.ocs.meta.message // empty' <<< "${ocs_body}" 2> /dev/null)" || ocs_msg=""
}

# answer_ok: true when the last call came back with OCS status 200
answer_ok() { [ "${ocs_curl_rc}" -eq 0 ] && [ "${ocs_code}" = 200 ]; }

# answer_failed: exit 3 with what curl or Nextcloud said
answer_failed() {
    local excerpt
    if [ "${ocs_curl_rc}" -ne 0 ]; then
        die 3 "curl got no answer from http://${NEXTCLOUD_HOST} (exit ${ocs_curl_rc}); curl's own message is above"
    fi
    if [ -n "${ocs_code}" ]; then
        msg "Nextcloud refused the request (HTTP ${ocs_http}): $(scrub "${ocs_msg:-no message}")"
    else
        # The whole body is scrubbed before it is cut: a password that straddled the cut would escape a scrub of the piece.
        excerpt="$(scrub "${ocs_body}" | sed -E 's/<[^>]*>/ /g' | tr -s '[:space:]' ' ' | cut -c1-200)"
        msg "Nextcloud's answer was not OCS JSON (HTTP ${ocs_http})${excerpt:+: ${excerpt}}"
    fi
    case "${ocs_http}" in
        401) msg "Nextcloud did not accept the temporary app password. Each failed login counts toward Nextcloud's brute-force throttle for this address, so do not retry in a loop. Runs of this script take turns, so look for something else that deletes app passwords named ${temp_name}." ;;
        429) msg "Nextcloud allows 20 new shares per 10 minutes for each account. It also throttles an address after failed logins: more than 10 in 30 minutes is a 429 on every call from it, and attempts count for 12 hours. Wait a while before trying again." ;;
    esac
    exit 3
}

# The jq text for one share: the same line for create and list. Text values are JSON strings.
share_line='
def tname: if . == 0 then "user" elif . == 1 then "group" elif . == 3 then "link" elif . == 4 then "email"
  elif . == 6 then "remote" elif . == 7 then "team" elif . == 9 then "remote_group" elif . == 10 then "talk"
  elif . == 12 then "deck" else tostring end;
def idtext: tostring | if test("^[0-9A-Za-z:._-]+$") then . else @json end;
"id=\(.id | idtext) share_type=\(.share_type | tname) path=\(.path // "" | @json)"
+ " share_with=\(if .share_type == 3 or .share_with == null then "-" else (.share_with | tostring | @json) end)"
+ " permissions=\(.permissions) expiration=\(if .expiration then (.expiration | @json) else "none" end)"
+ (if .url then " url=\(.url | @json)" else "" end)'

do_create() {
    local fields=() created id safe_id link token share_path expires stamp made_date made_time file_name content=() text quoted_uid quoted_id
    fields+=("path=${path}" "shareType=${type_n}")
    if [ -n "${with}" ]; then fields+=("shareWith=${with}"); fi
    if [ -n "${permissions}" ]; then fields+=("permissions=${permissions}"); fi
    if [ -n "${expire}" ]; then fields+=("expireDate=${expire}"); fi
    if [ "${want_password}" -eq 1 ]; then fields+=("password=${link_pw}"); fi
    if [ -n "${note}" ]; then fields+=("note=${note}"); fi
    if [ -n "${label}" ]; then fields+=("label=${label}"); fi
    if [ "${send_mail}" -eq 1 ]; then fields+=("sendMail=true"); else fields+=("sendMail=false"); fi

    ocs POST "${ocs_url}?format=json" "${fields[@]}"
    answer_ok || answer_failed
    created="$(jq -c '.ocs.data | if type == "array" then .[0] else . end' <<< "${ocs_body}" 2> /dev/null)" || created=""
    id="$(jq -r '.id // empty | tostring' <<< "${created}" 2> /dev/null)" || id=""
    if [ -z "${id}" ] || [ "${id}" = null ]; then
        printf -v quoted_uid '%q' "${uid}"
        die 3 "Nextcloud answered OK but the answer has no share id, so the share can't be reported, saved or deleted. Check with: ${script_dir}/share-as-admin.sh --as ${quoted_uid} list"
    fi

    if [ "${want_password}" -eq 1 ]; then
        safe_id="${id//[^A-Za-z0-9._-]/_}"
        read -r stamp made_date made_time <<< "$(LC_ALL=C date -u '+%Y%m%d-%H%M%S %Y-%m-%d %H:%M:%S')"
        file_name="share-${safe_id}-${stamp}.txt"
        link="$(jq -r '.url // empty' <<< "${created}" 2> /dev/null)" || link=""
        if [ -z "${link}" ]; then
            token="$(jq -r '.token // empty' <<< "${created}" 2> /dev/null)" || token=""
            if [ -n "${token}" ]; then link="${NEXTCLOUD_URL%/}/index.php/s/${token}"; fi
        fi
        share_path="$(jq -r '.path // empty' <<< "${created}" 2> /dev/null)" || share_path=""
        share_path="${share_path:-${path}}"
        share_path="${share_path//[[:cntrl:]]/?}"
        expires="$(jq -r '.expiration // empty' <<< "${created}" 2> /dev/null)" || expires=""
        content=("Nextcloud share password" "" "Share: ${id}" "Path: ${share_path}"
            "Link: ${link:-not returned by Nextcloud; open the share in the Files app}")
        if [ -n "${expires}" ]; then content+=("Expires: ${expires}"); fi
        content+=("Made: ${made_date} ${made_time} UTC" "" "Password:" "${link_pw}" ""
            "Send the link and the password by different routes. Delete this file once they're handed over.")
        printf -v text '%s\n' "${content[@]}"
        if ! printf '%s' "${text}" | nc_write_private_file "${file_name}"; then
            text=""
            msg "could not save the link password to nextcloud-passwords/${file_name}."
            ocs DELETE "${ocs_url}/${id}?format=json"
            if answer_ok; then
                msg "share ${id} was deleted again, so nothing is shared."
            else
                msg "share ${id} could not be deleted either (HTTP ${ocs_http}${ocs_msg:+: $(scrub "${ocs_msg}")}). It has a password nobody has seen."
                printf -v quoted_uid '%q' "${uid}"
                printf -v quoted_id '%q' "${id}"
                msg "Delete it with: ${script_dir}/share-as-admin.sh --as ${quoted_uid} delete ${quoted_id}"
            fi
            exit 4
        fi
        text=""
    fi

    jq -r "${share_line}" <<< "${created}"
    if [ "${want_password}" -eq 1 ]; then printf 'password saved to nextcloud-passwords/%s\n' "${file_name}"; fi
}

do_list() {
    local fields=() count
    if [ -n "${path}" ]; then fields+=("path=${path}" "reshares=true"); fi
    ocs GET "${ocs_url}?format=json" ${fields[@]+"${fields[@]}"}
    answer_ok || answer_failed
    count="$(jq -r '.ocs.data | if type == "array" then length elif type == "object" then 1 else "?" end' <<< "${ocs_body}" 2> /dev/null)" || count="?"
    case "${count}" in
        0) echo "no shares" ;;
        '' | *[!0-9]*) die 3 "Nextcloud's list is not in the form this script reads (data is neither a list nor a share)" ;;
        *) jq -r ".ocs.data | (if type == \"array\" then .[] else . end) | ${share_line}" <<< "${ocs_body}" ;;
    esac
}

do_delete() {
    ocs DELETE "${ocs_url}/${share_id}?format=json"
    answer_ok || answer_failed
    printf 'deleted share %s\n' "${share_id}"
}

case "${action}" in
    create) do_create ;;
    list) do_list ;;
    delete) do_delete ;;
esac
