#!/usr/bin/env bash
# LimeSurvey skill: remote/upgrade-backup.sh
#
# Runs INSIDE the LimeSurvey container, as root, sent by run-in-limesurvey.sh (upgrade-state.sh is its front end on
# the agent). It removes the backup that the Clouve image's upgrade keeps on the volume: the old LimeSurvey's code
# and a dump of the database from just before the upgrade, in /var/www/html/clouve/upgrade-<from>-to-<to>/, about
# 600 MB. That backup is the only way back to the old version, so it goes only once the admin has checked the
# upgraded site and said yes.
#
# Usage: upgrade-backup.sh remove <folder name> --yes-remove-the-kept-backup
#
# It refuses when the upgrade did not finish (its state says backup, upgrade, restore or failed): the image, and
# Clouve's staff, still need that folder then.
#
# Exit codes: 0 removed; 1 usage, no such folder, an upgrade that is not finished, or not root.

# SC2154: lib/state.sh, sourced below, sets clv_state_dir.
# shellcheck disable=SC2154

set -uo pipefail

err() { printf '[limesurvey/upgrade-backup] %s\n' "$*" >&2; }

remote_dir="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${remote_dir}/lib/state.sh" || exit 1

if [ "$(id -u)" -ne 0 ]; then err "this runs as root inside the LimeSurvey container"; exit 1; fi
if [ "${1:-}" != remove ]; then err "usage: upgrade-backup.sh remove <folder name> --yes-remove-the-kept-backup"; exit 1; fi
name="${2:-}"
confirmed="${3:-}"
[[ "${name}" =~ ^upgrade-[0-9][0-9A-Za-z.+-]*-to-[0-9][0-9A-Za-z.+-]*$ ]] || { err "the folder's name looks like upgrade-6.16.1-to-7.10.0 (upgrade-state.sh shows it)"; exit 1; }
if [ "$(clv_clouve)" != ok ]; then
    err "${clv_state_dir} is missing, is a link or does not belong to root, so it is not the folder the Clouve image made, and nothing in it is removed. Tell the user to contact Clouve support"
    exit 1
fi
folder="${clv_state_dir}/${name}"
clv_dir_trusted "${folder}" || { err "there is no folder clouve/${name} of root's"; exit 1; }
phase="$(clv_upgrade_phase "${folder}")"
case "${phase}" in
    backup | upgrade | restore)
        err "the upgrade is still under way (phase ${phase}), so its backup stays"
        exit 1
        ;;
    failed)
        err "that upgrade failed and the old version was put back. Its folder records the failure, and the image tries the upgrade again once the folder is gone, so this does not remove it. playbooks/recover-from-a-failed-upgrade.md says what to do"
        exit 1
        ;;
esac
if [ -e "${clv_state_dir}/upgrade-failed" ]; then
    err "the image recorded a failed upgrade (clouve/upgrade-failed), so the kept backup stays. playbooks/recover-from-a-failed-upgrade.md says what to do"
    exit 1
fi
if [ "${confirmed}" != --yes-remove-the-kept-backup ]; then
    err "this removes the only way back to the old LimeSurvey version. After the admin has checked the site and said yes, run it again with --yes-remove-the-kept-backup"
    exit 1
fi
size="$(du -sk "${folder}" 2> /dev/null | cut -f1)"
rm -rf -- "${folder}" || { err "could not remove clouve/${name}"; exit 1; }
printf '[limesurvey/upgrade-backup] removed clouve/%s (%s MB freed)\n' "${name}" "$((${size:-0} / 1024))"
