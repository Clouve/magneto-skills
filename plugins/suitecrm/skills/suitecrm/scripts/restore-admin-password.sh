#!/usr/bin/env bash
# SuiteCRM skill: restore-admin-password.sh
#
# Puts the main admin's password back to the one the Clouve dashboard shows, the password the account got
# when SuiteCRM was installed. Use it when the admin is locked out (playbooks/regain-admin-access.md). The
# account is made active and an admin again if it was not; the output says what it was (was_status,
# was_admin).
#
# What it does not do: it does not end SuiteCRM's sign-in throttle. After 5 wrong tries SuiteCRM refuses
# that login from that network address for up to 30 minutes, the right password included, and says "Too
# many failed login attempts". The throttle lives in SuiteCRM's own cache, per login and address, and this
# script leaves it alone. Wait 30 minutes, or sign in from another network (a phone off the Wi-Fi). The
# JSON's note says the same. (repair.sh and console.sh cache:clear empty that cache, and with it the
# counters of every login at once. That is a side effect, not a way to unlock one person.)
#
# In the Customer Kit, LimeSurvey signs in to SuiteCRM as this account with this same password, so this is
# also the fix when someone changed the admin's password and survey responses stopped arriving.
#
# Usage: restore-admin-password.sh --yes-reset
#
# Without --yes-reset it changes nothing and says what it would do. The password travels from the agent's
# secret store to SuiteCRM on the SSH channel's stdin. It is never printed and never in a command line.
#
# Output: JSON. password_restored, reactivated (true when the account had to be made active or an admin
# again), was_status, was_admin, the account as it is now, and the note about the sign-in throttle.
#
# Env vars read:
#   SUITECRM_ADMIN_USER  the main admin's login
#   the admin password   from the agent's secret store (the loader line below)
#   SUITECRM_HOST        through run-in-suitecrm.sh
#
# Exit codes: 0 done; 64 usage, or no --yes-reset; 1 a setting or the password is missing; 2 SuiteCRM did
# not keep the password, or did not keep the account active and an admin; 3 the main admin account could not
# be found; 70, 75, 255 from run-in-suitecrm.sh.

set -uo pipefail
set +x

usage() {
    cat <<'USAGE'
Usage: restore-admin-password.sh --yes-reset

Sets the main admin's password back to the one the Clouve dashboard shows, and makes the account active and
an admin again. The password is never printed. Without --yes-reset nothing changes.

It does not end SuiteCRM's sign-in throttle: after 5 wrong tries SuiteCRM refuses that login from that
network address for up to 30 minutes, the right password included. Wait 30 minutes, or sign in from another
network, such as a phone off the Wi-Fi.

Exit codes: 0 done; 64 usage; 1 a missing setting or password; 2 not kept; 3 no main admin found; 70 the
script crashed; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/restore-admin-password] %s\n' "$*" >&2; }

# The runner's php form says which script of the skill called it.
export SC_SKILL_CALLER=restore-admin-password.sh

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --yes-reset) [ "$#" -eq 1 ] || { msg "too many arguments"; usage >&2; exit 64; } ;;
    '')
        msg "nothing was changed. This sets the password of the main admin (${SUITECRM_ADMIN_USER:-the first admin}) back to the one on the Clouve dashboard and makes the account active and an admin. The password it has now stops working at once and can't be brought back. It does not end SuiteCRM's sign-in throttle (5 wrong tries, then up to 30 minutes for that login from that network address). Show that to the user, and run it again with --yes-reset after a clear yes."
        exit 64
        ;;
    *) msg "unknown argument: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
esac

: "${SUITECRM_ADMIN_PASSWORD:=$(clv-secret SUITECRM_ADMIN_PASSWORD)}"
if [ -z "${SUITECRM_ADMIN_PASSWORD}" ]; then
    msg "SUITECRM_ADMIN_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# printf is a builtin, so the password is in no process's arguments.
printf '%s\n' "${SUITECRM_ADMIN_PASSWORD}" | "${script_dir}/run-in-suitecrm.sh" --stdin php users.php restore-admin-password "${SUITECRM_ADMIN_USER:--}"
exit "${PIPESTATUS[1]}"
