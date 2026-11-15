#!/usr/bin/env bash
# LimeSurvey skill: upgrade-state.sh
#
# Says where the Clouve image's install or in-place upgrade of LimeSurvey stands, and removes the backup an upgrade
# keeps once the admin has checked the site.
#
# Usage: upgrade-state.sh
#        upgrade-state.sh --remove-kept-backup <folder> --yes
#
# Without options it reads the image's state in the LimeSurvey container (remote/state.sh, which always runs, also
# while an install or upgrade is under way or the container waits for a repair) and says which of these holds:
#   - the container is still starting (it shows the image's stand-in page while it waits for its database);
#   - LimeSurvey is being installed;
#   - an upgrade is under way, and in which phase (backup, upgrade, restore) and step;
#   - the container is waiting for a repair: the image keeps its stand-in page and its sshd up, serves no
#     LimeSurvey and does not restart by itself. That happens when a restore of this skill was cut off, when the
#     image's own way back from a failed upgrade failed, or when the code and the database do not belong together
#     and the image has no backup it trusts. The upgrade's state can still say upgrade or restore then: the
#     image's note (clouve/needs-attention) is what tells a stop from work under way. The output gives the
#     image's reason, since when it waits and the two versions, all from that note (it holds no secret), where
#     the upgrade stopped, and the way out;
#   - the last upgrade failed and the old version was put back, with the image's reason;
#   - the image did not try an upgrade (too little space, too few inodes, or its backup could not be made), with
#     the image's reason. The site runs the old version, and the next start tries again;
#   - the last upgrade is done, and its backup is kept in clouve/upgrade-<from>-to-<to> (the old code and a dump of
#     the database from just before the upgrade, about 600 MB);
#   - nothing is under way and no upgrade backup is kept.
# It also says when a restore from a backup was cut off, since the skill's other scripts refuse to run then, and
# when the image moved a folder aside that stood in the place of its state folder and was not root's own
# (clouve.untrusted-<time>). Putting such a folder back is a step for Clouve support, never for the assistant.
#
# --remove-kept-backup <folder> --yes removes that folder (remote/upgrade-backup.sh). It is the only way back to
# the old version, so --yes comes only after the admin has checked the upgraded site and said yes. A folder of an
# upgrade that failed or is still under way is never removed.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   0    nothing is under way (or the backup was removed). An upgrade that was not tried is exit 0 too: the site
#        runs, on the old version
#   2    the container is starting, or an install, an upgrade or a restore is under way
#   3    the last upgrade failed
#   4    the container is waiting for a repair and serves no LimeSurvey, or the image's state folder is not
#        root's own
#   1    the folder is not there or may not be removed, or the call failed
#   64   usage
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: upgrade-state.sh
       upgrade-state.sh --remove-kept-backup <folder> --yes

Says where the image's install or upgrade of LimeSurvey stands: starting, under way (and in which phase), waiting
for a repair, failed (with the image's reason), not tried (with the reason), done with its backup kept, or
nothing. With --remove-kept-backup it removes the backup a finished upgrade keeps, after the admin has checked
the site and said yes.

Exit codes: 0 nothing is under way, 2 starting or an install, upgrade or restore is under way, 3 the last upgrade
failed, 4 waiting for a repair, 1 a failed call or a folder that may not be removed, 64 usage, 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/upgrade-state] %s\n' "$*" >&2; }

folder=''
yes=0
remove=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --remove-kept-backup)
            [ "$#" -ge 2 ] || { msg "--remove-kept-backup needs the folder's name"; exit 64; }
            remove=1
            folder="${2#clouve/}"
            shift 2
            ;;
        --yes) yes=1; shift ;;
        *) msg "unknown option: $1"; usage >&2; exit 64 ;;
    esac
done
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${remove}" -eq 1 ]; then
    if ! [[ "${folder}" =~ ^upgrade-[0-9][0-9A-Za-z.+-]*-to-[0-9][0-9A-Za-z.+-]*$ ]]; then
        msg "the folder's name looks like upgrade-6.16.1-to-7.10.0 (run this without options to see it)"
        exit 64
    fi
    if [ "${yes}" -ne 1 ]; then
        msg "removing clouve/${folder} removes the only way back to the old LimeSurvey version. After the admin has checked the site and said yes, run this again with --yes"
        exit 64
    fi
    exec "${script_dir}/run-in-limesurvey.sh" upgrade-backup.sh remove "${folder}" --yes-remove-the-kept-backup
fi
if [ "${yes}" -eq 1 ]; then msg "--yes goes with --remove-kept-backup"; exit 64; fi

state="$("${script_dir}/run-in-limesurvey.sh" state.sh)"
rc=$?
if [ "${rc}" -ne 0 ]; then exit "${rc}"; fi
get() {
    local line
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$1" ]; then printf '%s' "${line#*=}"; return 0; fi
    done <<< "${state}"
    return 1
}

code=0
bump() { if [ "$1" -gt "${code}" ]; then code="$1"; fi; }
waiting="$(get waiting)"
web="$(get web_server)"
restore="$(get restore)"
phase="$(get upgrade_phase)"

if [ "$(get clouve)" = untrusted ]; then
    echo "The image's state folder /var/www/html/clouve is a link or does not belong to root, so it is not the folder the Clouve image made."
    echo "  Nothing in it is read: where an install or an upgrade stands can't be told, and the backups in it don't count."
    echo "  Someone or something replaced it. The image moves such a folder aside at its next start. Tell the user to contact Clouve support."
    bump 4
fi
aside="$(get clouve_aside)"
if [ -n "${aside}" ]; then
    echo "The image moved aside what stood in the place of its state folder and was not root's own: ${aside}."
    echo "  It may hold the backup of an upgrade and this skill's backups. Nothing in it is read or restored from here."
    echo "  Putting such a folder back is a step for Clouve support, not for you: tell the user, with the folder's name."
fi

if [ "${waiting}" = yes ]; then
    echo "The LimeSurvey container is WAITING FOR A REPAIR. It shows a stand-in page, serves no LimeSurvey and does not restart by itself."
    echo "  The image's reason: $(get waiting_reason)"
    since="$(get waiting_since)"
    if [ -n "${since}" ]; then
        versions=''
        case "$(get waiting_from)" in
            '') ;;
            'no code') versions=", with no LimeSurvey code on the volume" ;;
            *) versions=", with LimeSurvey $(get waiting_from) on the volume" ;;
        esac
        if [ -n "${versions}" ] && [ -n "$(get waiting_to)" ]; then versions+=", $(get waiting_to) in the image"; fi
        echo "  It has waited since ${since} (UTC)${versions}. That is from the note the image leaves for you, clouve/needs-attention."
    fi
    echo "  On the Clouve dashboard the deployment shows as running, although nobody can use the site."
    if [ "${restore}" = in-progress ]; then
        echo "  The way out: a restore of the backup $(get restore_backup) was started and has not finished. Run the same restore again"
        echo "  (playbooks/restore-from-backup.md, \"When a restore was cut off\"). The image starts LimeSurvey once the restore is done."
    else
        case "${phase}" in
            backup | upgrade | restore)
                step="$(get upgrade_step)"
                echo "  Where it stopped: the upgrade from LimeSurvey $(get upgrade_from) to $(get upgrade_to), in phase ${phase}${step:+, step ${step}}. No work is going on."
                if [ "$(get upgrade_db_touched)" = yes ]; then
                    echo "  The upgrade had begun to change the database, and the dump from before it has not been loaded back."
                fi
                ;;
        esac
        echo "  The way out is Clouve's: the image can't put the site right by itself, and its reason says what it found."
        echo "  Change nothing. Tell the user to contact Clouve support, with these lines (playbooks/recover-from-a-failed-upgrade.md, \"The container is waiting for a repair\")."
    fi
    bump 4
else
    if [ "$(get install)" = in-progress ]; then
        echo "LimeSurvey is being installed in this container right now. Wait until the site answers."
        bump 2
    fi
    case "${phase}" in
        backup | upgrade | restore)
            step="$(get upgrade_step)"
            echo "An upgrade from LimeSurvey $(get upgrade_from) to $(get upgrade_to) is under way, in phase ${phase}${step:+, step ${step}}:"
            case "${phase}" in
                backup) echo "  the image is saving the old code and a dump of the database. Nothing in the site has changed yet." ;;
                upgrade) echo "  the backup is complete, and the image is putting the new code in and updating the database." ;;
                restore) echo "  the upgrade did not work, and the image is putting the old version back from its backup." ;;
            esac
            echo "  Nothing may change the site until it has finished. The site shows a short stand-in page meanwhile."
            bump 2
            ;;
    esac
    if [ "${code}" -eq 0 ] && [ -n "${web}" ] && [ "${web}" != apache ] && [ "${restore}" != in-progress ]; then
        echo "The LimeSurvey container is still starting: its web server is not up yet, and it shows the image's stand-in page."
        echo "  The image shows that page while it waits for its database, before an install or an upgrade begins. It waits up to five"
        echo "  minutes, then the container stops and starts again. If this goes on, the database is not answering: verify-health.sh shows it."
        bump 2
    fi
fi

if [ "$(get upgrade_failed)" = yes ]; then
    from="$(get upgrade_from)"
    to="$(get upgrade_to)"
    echo "The upgrade${from:+ from LimeSurvey ${from}}${to:+ to ${to}} FAILED, and the image put the old version back."
    reason="$(get upgrade_failed_reason)"
    echo "  The image's reason: ${reason:-it recorded none}"
    when="$(get upgrade_failed_when)"
    [ -z "${when}" ] || echo "  It gave up on ${when}."
    echo "  The site runs the old version with its data. The image does not try again until a newer image arrives."
    echo "  playbooks/recover-from-a-failed-upgrade.md says what to check and what to tell the user."
    bump 3
elif [ "${code}" -eq 0 ] && [ -n "$(get kept_backup)" ]; then
    echo "The upgrade from LimeSurvey $(get upgrade_from) to $(get upgrade_to) is done."
    echo "  Its backup is kept in $(get kept_backup) ($(($(get kept_backup_kb) / 1024)) MB): the old code and a dump of the database from just before the upgrade."
    echo "  It is the only way back to the old version. Once the admin has checked the site and said yes, remove it with:"
    echo "  upgrade-state.sh --remove-kept-backup $(get kept_backup | sed 's|^clouve/||') --yes"
elif [ "${code}" -eq 0 ] && [ "$(get upgrade_skipped)" != yes ]; then
    echo "No install or upgrade is under way, and no upgrade backup is kept."
fi
if [ "$(get upgrade_skipped)" = yes ]; then
    from="$(get upgrade_skipped_from)"
    to="$(get upgrade_skipped_to)"
    echo "The image did NOT try the upgrade${from:+ from LimeSurvey ${from}}${to:+ to ${to}} at its last start, and nothing was changed."
    reason="$(get upgrade_skipped_reason)"
    echo "  The image's reason: ${reason:-it recorded none}"
    when="$(get upgrade_skipped_when)"
    [ -z "${when}" ] || echo "  It decided that on ${when}."
    echo "  The site runs the old version with its data, and the image tries again at its next start."
    echo "  playbooks/recover-from-a-failed-upgrade.md (\"The upgrade was not tried\") says what to free up and what to tell the user."
fi
if [ "${restore}" = in-progress ] && [ "${waiting}" != yes ]; then
    echo "A restore of the backup $(get restore_backup) was started and has not finished. playbooks/restore-from-backup.md says how to finish it."
    bump 2
fi
exit "${code}"
