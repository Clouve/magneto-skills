#!/usr/bin/env bash
# SuiteCRM skill: scheduler.sh
#
# SuiteCRM's scheduled jobs and its Messenger worker: whether they run, what ran, what is waiting, and the
# release of a scheduler that is held.
#
# The image runs two loops as www-data: the scheduler (bin/console schedulers:run once a minute) and, from
# SuiteCRM 8.10 on, the Messenger worker (messenger:consume). An install that existed before this image never
# ran a scheduled job. Starting them all at once could send campaign email that has been waiting for months
# and run workflows over old records, so the image holds the scheduler on such an install. This skill's
# restore holds it too, because a restore brings the campaign email queue back as it was. Until someone has
# looked at what is waiting and says go, no scheduled job runs. There are two holds:
#   - the file /var/www/html/tmp/clouve-backup/scheduler-held (root's): the scheduler is held while it is there.
#     The restore writes it.
#   - the image's scheduler setting, in SuiteCRM's own settings: the image's loop runs only when it is on. It
#     is on after a new install and after a release, and not set on an install that existed before the image.
#     The image's own tools read it and switch it on, and this skill calls them. An image that has no such
#     setting holds by the file alone.
# That image's loop also runs no job while the state folder is not root's, while a state folder the image moved
# aside (tmp/clouve-backup.untrusted-<UTC time>) is on the volume, and while staff's pause file loops-paused is
# there. status names those too. A release removes none of them: they are for Clouve support.
#
# Usage:
#   scheduler.sh status
#   scheduler.sh queued
#   scheduler.sh release [--yes-release]
#   scheduler.sh run-once
#
#   status    one JSON document: whether the scheduler is held ("held": true, false, or null when that is not
#             known) and why ("held_by": the reasons; "hold_file": yes, no or unknown; "image_setting": on, off,
#             none when the image has no such setting, or unknown), whether www-data may run it, when jobs
#             last ran, each scheduled job with its last run, the last day's job results and last failures,
#             whether the Messenger worker is running and what it has waiting, and the Manual Migration Tasks
#             by status.
#   queued    one JSON document: what a release would start: campaign emails waiting and due now, active
#             workflows (and how many run on all records), scheduled reports, inbound mailboxes, waiting jobs.
#   release   without --yes-release it changes nothing: it prints what a release would start, as plain lines,
#             and says so (exit 64). Show those numbers to the user. With --yes-release, after the user's yes,
#             it removes the hold file, has the image switch its scheduler setting on, and prints the same
#             numbers as what starts now. From then on every active scheduled job runs.
#   run-once  one scheduler pass by hand (bin/console schedulers:run), for a check after a fix. Refused while
#             the scheduler is held.
#
# When the image's state folder is not root's (the web user can swap it), the hold file is not read: status
# says "hold_file": "unknown", and release and run-once refuse. That is a job for Clouve support.
#
# Turning one scheduled job off or on is done in SuiteCRM (Admin > Scheduler): tell the user where.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 done; 64 usage, the yes is missing, or run-once while held; 2 the hold could not be removed, the
# image's setting could not be read or switched on, or the state folder is not trusted; 70, 75, 255 from
# run-in-suitecrm.sh.

set -uo pipefail
# run-in-suitecrm.sh prints a notice when its php, console or admin form is used by hand. This is not by hand.
export SC_SKILL_CALLER=scheduler.sh

usage() {
    cat <<'USAGE'
Usage: scheduler.sh status
       scheduler.sh queued
       scheduler.sh release [--yes-release]
       scheduler.sh run-once

status shows whether SuiteCRM's scheduled jobs and Messenger worker run and what they did. queued shows what
a held scheduler would start. release without --yes-release prints what would start and changes nothing; with
it (after the user's yes) it removes the hold file, has the image switch its scheduler setting on, and prints
what starts. run-once runs one scheduler pass by hand, and is refused while the scheduler is held.

Exit codes: 0 done; 64 usage, no yes, or run-once while held; 2 the hold could not be removed, the image's
setting could not be read or switched on, or the image's state folder is not trusted; 70 the script crashed;
75 SuiteCRM is being installed or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/scheduler] %s\n' "$*" >&2; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"

# read_hold: asks remote/admin.sh and sets hold (the hold file: yes, no or unknown), setting (the image's
# scheduler setting: on, off, none or unknown) and also (the other reasons why the image's loop runs no job:
# untrusted, moved-aside, loops-paused, separated by spaces); ends the script when the container can't be asked
read_hold() {
    local answer
    answer="$("${run}" admin scheduler-held)" || exit $?
    hold="$(sed -n 's/^hold_file=//p' <<< "${answer}" | head -n 1)"
    setting="$(sed -n 's/^setting=//p' <<< "${answer}" | head -n 1)"
    also="$(sed -n 's/^also=//p' <<< "${answer}" | head -n 1)"
    case "${also}" in
        *[!abcdefghijklmnopqrstuvwxyz\ -]*)
            msg "could not read whether the scheduler is held"
            exit 70
            ;;
    esac
    case "${hold}:${setting}" in
        yes:on | yes:off | yes:none | yes:unknown | no:on | no:off | no:none | no:unknown) ;;
        unknown:on | unknown:off | unknown:none | unknown:unknown) ;;
        *)
            msg "could not read whether the scheduler is held"
            exit 70
            ;;
    esac
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    status)
        [ "$#" -eq 1 ] || { msg "status takes no arguments"; exit 64; }
        read_hold
        also="${also// /,}"
        exec "${run}" php scheduler.php status "${hold}" "${setting}" "${also:--}"
        ;;
    queued)
        [ "$#" -eq 1 ] || { msg "queued takes no arguments"; exit 64; }
        exec "${run}" php scheduler.php queued
        ;;
    release)
        if [ "${2:-}" != --yes-release ] || [ "$#" -ne 2 ]; then
            "${run}" php scheduler.php queued-text before
            rc=$?
            if [ "${rc}" -ne 0 ]; then msg "what is waiting could not be read (exit ${rc})."; fi
            msg "nothing was changed. A release lets every active scheduled job run from the next minute on: waiting campaign emails go out, workflows run, mailboxes are read. Show the numbers above to the user, and run this again with --yes-release after a clear yes."
            exit 64
        fi
        read_hold
        if [ "${hold}" = unknown ] || [ "${setting}" = unknown ]; then
            # remote/admin.sh refuses, and says why
            "${run}" admin release-scheduler > /dev/null
            rc=$?
            if [ "${rc}" -eq 0 ]; then rc=2; fi
            exit "${rc}"
        fi
        if [ "${hold}" = no ] && [ "${setting}" != off ]; then
            if [ -n "${also}" ]; then
                msg "nothing was changed. The scheduler has no hold that a release removes, and it still runs no job (${also// /, }): scheduler.sh status says why. That is a request to Clouve support."
                exit 2
            fi
            echo "The scheduler was not held. Nothing was changed."
            exit 0
        fi
        queue="$("${run}" php scheduler.php queued-text now)"
        rc=$?
        if [ "${rc}" -ne 0 ]; then
            msg "what is waiting could not be read (exit ${rc}), so the scheduler was not released. Nothing was changed."
            exit "${rc}"
        fi
        result="$("${run}" admin release-scheduler)" || exit $?
        done_file="$(sed -n 's/^hold_file=//p' <<< "${result}" | head -n 1)"
        done_setting="$(sed -n 's/^setting=//p' <<< "${result}" | head -n 1)"
        case "${done_file}:${done_setting}" in
            removed:switched-on) echo "Released: the hold file is gone and the image's scheduler setting is on. The image's scheduler loop runs SuiteCRM's scheduled jobs from its next pass, within a minute." ;;
            removed:*) echo "Released: the hold file is gone. The image's scheduler loop runs SuiteCRM's scheduled jobs from its next pass, within a minute." ;;
            *:switched-on) echo "Released: the image's scheduler setting is on. The image's scheduler loop runs SuiteCRM's scheduled jobs from its next pass, within a minute." ;;
            *)
                echo "The scheduler was not held. Nothing was changed."
                exit 0
                ;;
        esac
        printf '%s\n' "${queue}"
        case " ${also} " in
            *' loops-paused '*) echo "Nothing starts yet, though: staff's pause file tmp/clouve-backup/loops-paused is still there, and the scheduler runs no job until Clouve support removes it." ;;
        esac
        exit 0
        ;;
    run-once)
        [ "$#" -eq 1 ] || { msg "run-once takes no arguments"; exit 64; }
        read_hold
        if [ "${hold}" = yes ] || [ "${setting}" = off ]; then
            why="/var/www/html/tmp/clouve-backup/scheduler-held is there"
            if [ "${hold}" != yes ]; then why="the image's scheduler setting is off"; fi
            msg "refused: the scheduler is held (${why}), so no scheduled job runs yet. scheduler.sh release shows what would start, and lets it go with --yes-release after the user's yes."
            exit 64
        fi
        if [ -n "${also}" ]; then
            msg "refused: the image runs no scheduled job for now (${also// /, }): scheduler.sh status says why. That is a request to Clouve support. Nothing was run."
            exit 64
        fi
        if [ "${hold}" = unknown ]; then
            msg "refused: /var/www/html/tmp/clouve-backup is not a folder of root's, so whether the scheduler is held is not known. That is a job for Clouve support. Nothing was run."
            exit 64
        fi
        if [ "${setting}" = unknown ]; then
            msg "refused: the image's scheduler setting could not be read, so whether the scheduler is held is not known. Nothing was run."
            exit 64
        fi
        exec "${run}" console schedulers:run --no-interaction
        ;;
    '') msg "no action given"; usage >&2; exit 64 ;;
    *) msg "unknown action: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
esac
