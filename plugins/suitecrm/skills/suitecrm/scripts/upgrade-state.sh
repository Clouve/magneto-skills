#!/usr/bin/env bash
# SuiteCRM skill: upgrade-state.sh
#
# Reads what Clouve's image says about installs and upgrades of this SuiteCRM, and removes the backup an upgrade
# kept, once the user has checked the upgraded site. It works while an install or an upgrade is under way and
# while the container waits, when the skill's other scripts refuse: it only reads then.
#
# SuiteCRM's version comes from the image. A newer image upgrades the install at its first start: it backs up
# the code and the database into /var/www/html/tmp/clouve-backup/<from>-to-<to>/, runs SuiteCRM's own two
# upgrade commands, and puts the old version back if they fail. It keeps a state file there with the phase
# (backup, upgrade, restore or failed; as-is while staff finish one by hand), and it keeps the backup of a
# finished upgrade until someone removes it. When it does not start an upgrade at all (too little room on the
# volume, a backup that could not be made), the old version keeps running and the image leaves a note,
# upgrade-skipped, with the reason. Nothing here starts, repeats or undoes an upgrade: that is the image's
# work at a start, and a restart is a request to Clouve support.
#
# Usage:
#   upgrade-state.sh
#   upgrade-state.sh --remove-kept-backup <name> --yes-remove
#
#   Without arguments it prints, one line each:
#     SuiteCRM version on the volume, and in the image
#     Start-up     finished (PID 1 is Apache); still running (an install or upgrade is under way); "the
#                  container is waiting: a restore was cut off (run the restore again)" when PID 1 is not Apache
#                  and a restore marker is there; "the container is waiting: the image found a site that it
#                  must not start as it is" when the image marks that (its stand-in page then says that
#                  SuiteCRM needs attention); "waiting or still starting" otherwise. Each with the way out.
#                  While the container waits, the image leaves a note for the assistant, which can't read
#                  the container's log: tmp/clouve-backup/needs-attention, with the reason in the image's own
#                  words, since when it waits, and the versions on the volume and in the image. It holds no
#                  secret, and the next line shows what it says. One wait has no note: while a state folder
#                  that the image moved aside is on the volume and no new one is there, the line says that the
#                  image set its state folder aside as untrusted and that Clouve support has to check it and
#                  put it back.
#     State folder only when something is wrong with /var/www/html/tmp/clouve-backup: it is not a folder of
#                  root's, so nothing in it was read, or the image moved such a folder aside
#                  (tmp/clouve-backup.untrusted-<UTC time>). Putting either right is a step for Clouve support.
#     Install      only while an install is under way or was cut off
#     Upgrade      "No upgrade is under way." only when the volume and the image hold the same version and the
#                  start-up has finished; the phase of one under way; a failed one, with the image's own note;
#                  "the image has <x>, the volume runs <y>: the image did not start the upgrade", with the reason
#                  and the time from the image's note, or where the reason is when there is no note
#     Restore      only when this skill's restore marker is there
#     Scheduler    held (by the hold file, by the image's scheduler setting, or both), not held, or not known
#     Backups kept by upgrades, with their sizes, and how to remove one when nothing can need it any more
#     Upgrade work files left in tmp/package/upgrade
#     Manual Migration Tasks by status (when SuiteCRM can be asked)
#   --remove-kept-backup deletes one kept backup, named as the report shows it (8.9.1-to-8.10.2). After that
#   there is no way back to the old version from this volume. It needs --yes-remove, and it is refused while
#   an upgrade is under way or has failed, while the container is starting or waiting, and when the state
#   folder is not root's.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, or the yes is missing; 2 refused (an upgrade is under way or failed, the
# container is starting or waiting, or the state folder is not trusted); 3 no such kept backup; 255 ssh failed.

set -uo pipefail
# run-in-suitecrm.sh prints a notice when its php, console or admin form is used by hand. This is not by hand.
export SC_SKILL_CALLER=upgrade-state.sh

usage() {
    cat <<'USAGE'
Usage: upgrade-state.sh
       upgrade-state.sh --remove-kept-backup <name> --yes-remove

Shows the state of the image's install and upgrade of SuiteCRM: the version on the volume and in the image,
whether the start-up has finished or the container waits, the phase of an upgrade under way, a failed upgrade
and its reason, an upgrade the image did not start and why, a state folder that is not trusted, the held
scheduler, the backups upgrades kept, and the Manual Migration Tasks. --remove-kept-backup deletes one kept
backup after the user's yes.

Exit codes: 0 done; 64 usage or no yes; 2 refused; 3 no such backup; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/upgrade-state] %s\n' "$*" >&2; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --remove-kept-backup)
        name="${2:-}"
        if ! [[ ${name} =~ ^[0-9][0-9.]*-to-[0-9][0-9.]*$ ]]; then
            msg "that is not the name of a kept upgrade backup (such as 8.9.1-to-8.10.2; upgrade-state.sh shows them)"
            exit 64
        fi
        if [ "${3:-}" != --yes-remove ] || [ "$#" -ne 3 ]; then
            msg "nothing was removed. This deletes the backup the upgrade kept (${name}): the old code and the database as they were before the upgrade. After that there is no way back to the old version from this volume. Have the user check the upgraded site first, then run this again with --yes-remove after a clear yes."
            exit 64
        fi
        exec "${run}" --allow-busy admin remove-upgrade-backup "${name}"
        ;;
    '') ;;
    *) msg "unknown argument: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
esac

state="$("${run}" --allow-busy admin state)" || exit $?
get() { printf '%s\n' "${state}" | sed -n "s/^$1=//p" | head -n 1; }
all() { printf '%s\n' "${state}" | sed -n "s/^$1=//p"; }
mb() { if [[ ${1:-} =~ ^[0-9]+$ ]]; then printf '%s MB' "$(($1 / 1048576))"; else printf 'unknown size'; fi; }
# newer A B: succeeds when version A is newer than version B
newer() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

volume="$(get version_file)"
image="$(get image_version)"
pid1="$(get pid1)"
phase="$(get upgrade_phase)"
stamp="$(get install_stamp)"
marker="$(get restore_marker)"
dir_state="$(get state_dir)"
since=''
if [[ $(get pid1_seconds) =~ ^[0-9]+$ ]]; then since=", for $(($(get pid1_seconds) / 60)) minute(s) now"; fi

echo "SuiteCRM version on the volume: ${volume:-unknown (VERSION is missing or does not hold a version)}"
echo "SuiteCRM version in the image: ${image:-unknown}"
waiting="$(get waiting)"
support="The way out is Clouve support: tell the user, and pass on this report and verify-health.sh's. Leave tmp/clouve-backup, a tmp/clouve-backup.untrusted folder and every backup as they are."
# The image's note of a wait (tmp/clouve-backup/needs-attention): its reason, the time and the two versions
note_reason="$(get attention_reason)"
note_line=''
if [ -n "${note_reason}" ]; then
    note_since="$(get attention_since)"
    note_from="$(get attention_from)"
    note_to="$(get attention_to)"
    note_versions=''
    if [[ ${note_from} =~ ^[0-9] ]] && [ -n "${note_to}" ]; then
        note_versions=" It names SuiteCRM ${note_from} on the volume and ${note_to} in the image."
    elif [ -n "${note_from}" ] && [ -n "${note_to}" ]; then
        note_versions=" For the version on the volume it has \"${note_from}\", and ${note_to} for the image."
    fi
    note_line="  Why it waits, in the image's own words (its note tmp/clouve-backup/needs-attention${note_since:+, since ${note_since} UTC}): ${note_reason%.}.${note_versions}"
fi
# A state folder the image moved aside because it did not trust it
aside="$(all moved_aside | sed 's|^|tmp/|' | paste -sd ' ' -)"
if [ "${pid1}" = apache2 ]; then
    echo "Start-up: finished (PID 1 is Apache)."
elif [ "${marker}" = yes ] || [ "${waiting}" = restoring ]; then
    echo "Start-up: the container is waiting: a restore was cut off (run the restore again). PID 1 is ${pid1:-unknown}, not Apache${since}. The image keeps only its stand-in page and the SSH channel up while the restore marker is there, and finishes its start by itself once the restore is complete. playbooks/restore-from-backup.md has the steps."
    if [ -n "${note_line}" ]; then echo "${note_line}"; fi
elif [ "${waiting}" = attention ] && [ -n "${note_line}" ]; then
    echo "Start-up: the container is waiting: the image found a site that it must not start as it is, and a person has to repair it first. PID 1 is ${pid1:-unknown}, not Apache${since}. The image keeps only its stand-in page, which says that SuiteCRM needs attention, and the SSH channel up. The start goes on by itself once the site is repaired. ${support}"
    echo "${note_line}"
elif [ "${waiting}" = attention ] && [ -n "${aside}" ] && [ "${dir_state}" = absent ]; then
    # The one wait without a note: the image makes no new state folder while one it moved aside is on the
    # volume, so that staff can put the old one back. The folder's name is the sign.
    echo "Start-up: the container is waiting: the image set its state folder aside as untrusted (${aside}) and has made no new one. Clouve support has to check it and put it back. PID 1 is ${pid1:-unknown}, not Apache${since}. The image keeps only its stand-in page, which says that SuiteCRM needs attention, and the SSH channel up, and the start goes on by itself once the folder is back. Tell the user, and pass on this report and verify-health.sh's. Leave that folder and every backup as they are."
elif [ "${waiting}" = attention ]; then
    echo "Start-up: the container is waiting: the image found a site that it must not start as it is, and a person has to repair it first. PID 1 is ${pid1:-unknown}, not Apache${since}. The image keeps only its stand-in page, which says that SuiteCRM needs attention, and the SSH channel up. What it found is in the container's log, in the line that starts with [clouve-upgrade] FAILED, which only Clouve support can read. The start goes on by itself once the site is repaired. ${support}"
elif [ -n "${stamp}" ] || [ "${phase}" = backup ] || [ "${phase}" = upgrade ] || [ "${phase}" = restore ] || [ "${phase}" = as-is ]; then
    echo "Start-up: still running (PID 1 is ${pid1:-unknown}, not Apache${since}). The image installs and upgrades before Apache starts; the lines below say which."
elif [ "$(get image_waits)" = yes ]; then
    echo "Start-up: waiting or still starting (PID 1 is ${pid1:-unknown}, not Apache${since}). This image marks it when it waits for a person, and it has marked nothing, so this is a start: it waits up to five minutes for the database before it installs, upgrades or starts SuiteCRM. If this line stays for longer, tell the user and Clouve support."
else
    echo "Start-up: waiting or still starting (PID 1 is ${pid1:-unknown}, not Apache${since}). A start takes a few minutes: the image waits up to five minutes for the database. If this line stays, the container is waiting: the image found a site it will not start as it is (between two versions with no backup it trusts, for example). It keeps only its stand-in page and the SSH channel up, and has written what it found to the container's log, which only Clouve support can read. ${support}"
fi
if [ "${dir_state}" = untrusted ]; then
    echo "State folder: /var/www/html/tmp/clouve-backup is not a folder of root's with mode 700 (it is a link, belongs to another user, or something else is in its place). Nothing in it was read, so the upgrade's state, the scheduler's hold and a restore marker are not known. The image moves such a folder aside at its next start. Looking at what is in it and putting it right is a step for Clouve support, not one to take by yourself: change nothing in it, and tell the user and Clouve support."
fi
if [ -n "${aside}" ]; then
    echo "State folder: the image moved a state folder aside because it did not trust it: ${aside}. It may hold an upgrade's backup or the scheduler's hold. Putting it back is a step for Clouve support, who check what is in it first, not one to take by yourself: leave it as it is, and tell the user and Clouve support."
fi
if [ "$(get skill_dir)" = untrusted ]; then
    echo "Backups folder: /var/www/html/tmp/clouve-skill-backups is not a folder of root's with mode 700, so this skill's backups in it were not read, and backup.sh and restore.sh refuse. Putting it right is a step for Clouve support: change nothing in it."
fi
files="$(all state_file | paste -sd ' ' - | sed 's/ /, /g')"
if [ -n "${files}" ]; then echo "Files in the image's state folder (tmp/clouve-backup): ${files}."; fi
if [ -n "${stamp}" ]; then
    echo "Install: a new install is under way or was cut off (${stamp} is there). The next start cleans up and installs again."
fi

versions="the image has ${image:-an unknown version}, the volume runs ${volume:-an unknown version}"
room="See the disk line of verify-health.sh: an upgrade needs room for the new code and for a backup of the old code and the database. playbooks/failed-upgrade.md has the next steps."
skipped=''
if [ "$(get upgrade_skipped)" = yes ]; then
    skipped="$(get skipped_reason)"
    if [ -n "${skipped}" ]; then
        skipped=", because ${skipped%.}"
        if [ -n "$(get skipped_at)" ]; then skipped+=" (at $(get skipped_at))"; fi
    else
        skipped=" (the image's note is below)"
    fi
fi
case "${phase}" in
    unknown)
        echo "Upgrade: not known, because the state folder was not read. ${versions^}."
        ;;
    failed)
        echo "Upgrade: the last upgrade failed and the image put the old version back. It does not try again until a newer image arrives or Clouve clears the state. See playbooks/failed-upgrade.md."
        ;;
    backup | upgrade | restore)
        echo "Upgrade: under way, phase: ${phase}. Leave SuiteCRM alone until it finishes. If the container restarts now, the next start picks the upgrade up from this phase."
        ;;
    as-is)
        echo "Upgrade: under way, phase: as-is. Clouve staff are finishing a cut-off upgrade by hand on the site as it is. Leave SuiteCRM alone until they are done."
        ;;
    *)
        if newer "${image}" "${volume}" && [ "${pid1}" = apache2 ]; then
            if [ -n "${skipped}" ]; then
                echo "Upgrade: ${versions}: the image did not start the upgrade${skipped}. Nothing was changed, ${volume} keeps running, and the image tries again at its next start. ${room}"
            else
                echo "Upgrade: ${versions}: the image did not start the upgrade. It leaves no note for this on the volume: the reason is in the container's log, in the line that starts with [clouve-upgrade], which only Clouve support can read. Nothing was changed and ${volume} keeps running. ${room}"
            fi
        elif newer "${image}" "${volume}"; then
            echo "Upgrade: ${versions}. The image has not started the upgrade yet; it does that during the start-up${skipped:+. At an earlier start it did not start it${skipped}}."
        elif newer "${volume}" "${image}"; then
            echo "Upgrade: ${versions}. The volume's version is newer than the image's, and an older SuiteCRM can't run a newer one's database. That is a request to Clouve support."
        elif [ -z "${image}" ] || [ -z "${volume}" ]; then
            echo "Upgrade: no upgrade state is recorded. ${versions^}, so the two could not be compared."
        elif [ "${pid1}" != apache2 ]; then
            echo "Upgrade: no upgrade state is recorded, and the start-up has not finished. verify-health.sh's version line says whether the code and the database are on the same version."
        else
            echo "Upgrade: No upgrade is under way."
        fi
        ;;
esac
all state_text | sed 's/^/  /'
if [ "$(get upgrade_skipped)" = yes ] && [ -z "$(get skipped_reason)" ] && newer "${image}" "${volume}"; then all skipped_text | sed 's/^/  upgrade-skipped: /'; fi
if [ "${marker}" = yes ] && [ "${pid1}" = apache2 ]; then
    echo "Restore: a restore by this skill is running or was cut off ($(get restore_marker_file) is there). The other scripts refuse until it has finished: playbooks/restore-from-backup.md."
fi
held_why=''
if [ "$(get scheduler_held)" = yes ]; then held_why="tmp/clouve-backup/scheduler-held is there"; fi
if [ "$(get scheduler_setting)" = off ]; then held_why="${held_why:+${held_why}, and }the image's scheduler setting is off, as on an install that existed before this image"; fi
stuck_why=''
case " $(get scheduler_also) " in *' untrusted '* | *' moved-aside '*) stuck_why="a state folder that is not root's is on the volume, and a hold file in it can't be read" ;; esac
case " $(get scheduler_also) " in *' loops-paused '*) stuck_why="${stuck_why:+${stuck_why}, and }staff's pause file tmp/clouve-backup/loops-paused is there" ;; esac
if [ -n "${held_why}" ]; then
    echo "Scheduler: held (${held_why}). No scheduled job runs until it is released: scheduler.sh release shows what would start, and lets it go with --yes-release after the user's yes.${stuck_why:+ The image also runs no scheduled job for now because ${stuck_why}: a release does not change that, it is a request to Clouve support.}"
elif [ -n "${stuck_why}" ]; then
    echo "Scheduler: the image runs no scheduled job for now, because ${stuck_why}. A release does not change that: it is a request to Clouve support."
elif [ "$(get scheduler_held)" = unknown ]; then
    echo "Scheduler: not known, because the state folder was not read."
elif [ "$(get scheduler_setting)" = unknown ]; then
    echo "Scheduler: not known, because the image's scheduler setting could not be read."
else
    echo "Scheduler: not held."
fi
kept="$(all kept_backup)"
if [ -n "${kept}" ]; then
    echo "Backups kept by upgrades:"
    while IFS=$'\t' read -r kname kbytes ktime; do
        echo "  ${kname}  $(mb "${kbytes}")  last changed ${ktime} UTC"
    done <<< "${kept}"
    if [ "${pid1}" != apache2 ]; then
        echo "  Leave them as they are while the container is starting or waiting: the image may need them."
    elif [ "${phase}" = failed ]; then
        echo "  Keep them: Clouve support may need them to find out why the upgrade failed."
    elif [ -n "${phase}" ]; then
        echo "  Leave them as they are: the upgrade uses them for its way back."
    else
        echo "  Remove one with upgrade-state.sh --remove-kept-backup <name> --yes-remove, once the user has checked the upgraded site."
    fi
elif [ "${dir_state}" = untrusted ]; then
    echo "Backups kept by upgrades: not known, because the state folder was not read."
else
    echo "Backups kept by upgrades: none."
fi
left="$(get upgrade_leftover_bytes)"
if [[ ${left} =~ ^[0-9]+$ ]] && [ "${left}" -gt 1048576 ]; then
    echo "Upgrade work files: $(mb "${left}") in tmp/package/upgrade. The image removes them after an upgrade; tell Clouve support if they stay."
fi
busy="$(get busy_reason)"
if [ -n "${busy}" ]; then
    echo "The skill's other scripts refuse for now: ${busy}"
    echo "Manual Migration Tasks: not read, because SuiteCRM can't be asked right now."
else
    tasks="$("${run}" php scheduler.php migrations 2> /dev/null)" || tasks=''
    if [ -z "${tasks}" ]; then
        echo "Manual Migration Tasks: not read, because SuiteCRM can't be asked right now."
    elif command -v jq > /dev/null 2>&1; then
        if [ "$(jq -r '.available' <<< "${tasks}" 2> /dev/null)" = true ]; then
            echo "Manual Migration Tasks: $(jq -r '(.by_status | objects) // {} | to_entries | map("\(.value) \(.key)") | join(", ") | if . == "" then "none" else . end' <<< "${tasks}")."
            if [ "$(jq -r '(.by_status | objects | .initial) // 0' <<< "${tasks}")" != 0 ]; then
                echo "  An admin starts them in SuiteCRM under Admin > Migrations (playbooks/after-an-upgrade.md)."
            fi
        else
            echo "Manual Migration Tasks: this SuiteCRM version has none."
        fi
    fi
fi
exit 0
