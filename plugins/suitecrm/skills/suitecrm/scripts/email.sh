#!/usr/bin/env bash
# SuiteCRM skill: email.sh
#
# Checks SuiteCRM's outgoing email. The admin sets it up in SuiteCRM's own form (Admin > Email > Outbound
# Email), where the SMTP password is typed and never passes through the chat. This script reads the result
# without the password, sends a test message, and fixes the one setting that older tools leave wrong.
#
# Usage:
#   email.sh status
#   email.sh test <address> --yes-send
#   email.sh set-auth-basic --yes-change
#
#   status          the system account: server, port, security, user name, whether a password is stored (never
#                   the password), the sign-in type, the From name and address, and warnings.
#   test            sends one short test message to <address> through that account. It sends email, so it
#                   needs --yes-send. Exit 2 when SuiteCRM could not hand it to the server, with the reason.
#   set-auth-basic  SuiteCRM 8.10 signs in to the SMTP server only when the account's auth_type is "basic".
#                   An account saved by an older tool or script has a user name and password but no auth_type,
#                   so mail to a server that needs a sign-in fails. This sets it, and leaves the stored password
#                   as it is. It changes a setting, so it needs --yes-change.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, or the yes is missing; 65 not an email address; 2 no server is set, the
# message was not sent, or the change was not kept; 70, 75, 255 from run-in-suitecrm.sh.

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: email.sh status
       email.sh test <address> --yes-send
       email.sh set-auth-basic --yes-change

status reads SuiteCRM's system outgoing-mail account without its password. test sends one test message (it
sends email: --yes-send). set-auth-basic sets the account's sign-in type to "basic", which SuiteCRM 8.10
needs before it signs in to the server; the stored password stays (--yes-change).

Exit codes: 0 done; 64 usage or no yes; 65 bad address; 2 not set up, not sent or not kept; 70 the script
crashed; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/email] %s\n' "$*" >&2; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runner's direct forms say that the skill's checks don't apply to them, unless a script of the skill calls.
export SC_SKILL_CALLER=email.sh
run=("${script_dir}/run-in-suitecrm.sh" php email.php)

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    status)
        [ "$#" -eq 1 ] || { msg "status takes no arguments"; exit 64; }
        exec "${run[@]}" status
        ;;
    test)
        if [ "$#" -lt 2 ] || ! [[ "$2" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; then
            msg "test needs an address like name@example.com"
            exit 64
        fi
        if [ "${3:-}" != --yes-send ] || [ "$#" -ne 3 ]; then
            msg "nothing was sent. This sends one test message from SuiteCRM to $2. Show that to the user, and run it again with --yes-send after a clear yes."
            exit 64
        fi
        exec "${run[@]}" test "$2"
        ;;
    set-auth-basic)
        if [ "${2:-}" != --yes-change ] || [ "$#" -ne 2 ]; then
            msg "nothing was changed. This sets the sign-in type of SuiteCRM's outgoing-mail account to \"basic\" and leaves the stored password as it is. Show that to the user, and run it again with --yes-change after a clear yes."
            exit 64
        fi
        exec "${run[@]}" set-auth-basic
        ;;
    '') msg "no action given"; usage >&2; exit 64 ;;
    *) msg "unknown action: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
esac
