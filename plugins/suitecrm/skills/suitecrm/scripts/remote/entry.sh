#!/bin/bash
# SuiteCRM skill: remote/entry.sh (runs inside the SuiteCRM container, as clouve-ops; run-in-suitecrm.sh
# sends it there with the rest of the scripts folder and starts it)
#
# Usage: entry.sh DIR FLAGS MODE NAME [args...]
#   DIR    the folder the scripts were unpacked to
#   FLAGS  a comma-separated list, or "-": allow-busy (run even while the image installs or upgrades, or
#          waits; for reads of the state only), need-backup (refuse unless this skill made a complete backup
#          in the last 24 hours), keep (don't remove DIR: a detached job's files stay until its log is read)
#   MODE   php      runs DIR/remote/NAME as www-data, with what is left of stdin
#          console  runs SuiteCRM's bin/console NAME [args...] as www-data, in /var/www/html
#          root     runs DIR/NAME (backup.sh, restore.sh, remote/admin.sh) as root
#          check    runs nothing: only the checks
#
# The busy check (guard.sh, sc_busy_reason) refuses while the image installs or upgrades, while a restore
# marker is there, and while PID 1 is not Apache (the container is still starting, or waits). Nothing in a
# state folder that is not root's is believed. Two scripts get past part of the check, because they are the
# way out:
#   restore.sh         runs over a restore marker. While PID 1 is not Apache it runs when a marker is there,
#                      so that a restore that was cut off can be finished in a container that waits for it,
#                      and when the image says that it waits for a person. It does not run in a container
#                      that is still starting
#   backup.sh --list   runs over a restore marker and while PID 1 is not Apache: it only reads
# Everything that changes CRM data, and a new backup, is refused in those states.
#
# Exit codes of its own: 75 SuiteCRM is being installed or upgraded, a restore is under way or was cut off, or
# the container is still starting or waiting; 76 no recent backup, or the backups folder is not trusted; 64
# usage, or bin/console schedulers:run while the image holds its scheduler or its state folder is not trusted;
# 70 whether the scheduler is held could not be read. Anything else is the script's.
set -uo pipefail

dir="${1:-}"
flags="${2:-}"
mode="${3:-}"
name="${4:-}"
if [ "$#" -lt 3 ] || [ ! -d "${dir}" ]; then
    echo "[suitecrm] entry.sh: usage: entry.sh DIR FLAGS MODE NAME [args...]" >&2
    exit 64
fi
shift 3
if [ "$#" -gt 0 ]; then shift; fi

keep=0
case ",${flags}," in *,keep,*) keep=1 ;; esac
cleanup() {
    if [ "${keep}" -eq 0 ]; then rm -rf -- "${dir}"; fi
}
trap cleanup EXIT

# shellcheck source=/dev/null
. "${dir}/remote/guard.sh" || exit 1

busy_mode=''
if [ "${mode}" = root ] && [ "${name}" = restore.sh ]; then busy_mode=restore-ok; fi
if [ "${mode}" = root ] && [ "${name}" = backup.sh ] && [ "${1:-}" = --list ]; then busy_mode=read-ok; fi
case ",${flags}," in
    *,allow-busy,*) ;;
    *)
        reason="$(sc_busy_reason ${busy_mode})"
        if [ -n "${reason}" ]; then
            echo "[suitecrm] refused: ${reason} Nothing was changed." >&2
            exit 75
        fi
        ;;
esac
case ",${flags}," in
    *,need-backup,*)
        sc_recent_backup 24
        case $? in
            0) ;;
            2)
                echo "[suitecrm] refused: this changes or removes many records at once and needs a backup first, and $(sc_untrusted_message "${sc_skill_dir}")" >&2
                exit 76
                ;;
            *)
                echo "[suitecrm] refused: this changes or removes many records at once, and there is no complete backup from the last 24 hours. Take one first: run-in-suitecrm.sh backup.sh. Nothing was changed." >&2
                exit 76
                ;;
        esac
        ;;
esac

case "${mode}" in
    check)
        exit 0
        ;;
    php)
        case "${name}" in
            *[!abcdefghijklmnopqrstuvwxyz.-]* | '' | .* | *..*) echo "[suitecrm] entry.sh: not a script name" >&2; exit 64 ;;
        esac
        [ -f "${dir}/remote/${name}" ] || { echo "[suitecrm] entry.sh: no remote/${name}" >&2; exit 64; }
        sudo -n -u www-data -- php -d display_errors=stderr -d log_errors=0 -d memory_limit=512M "${dir}/remote/${name}" "$@"
        rc=$?
        # PHP ends with 255 after a fatal error, and 255 is what ssh uses for its own failures.
        if [ "${rc}" -eq 255 ]; then
            echo "[suitecrm] ${name} crashed (PHP ended with a fatal error). Read the state back before you run it again." >&2
            rc=70
        fi
        exit "${rc}"
        ;;
    console)
        # A scheduler pass by hand would start everything the image holds back: on an install that never ran a
        # scheduled job, and after a restore. remote/admin.sh knows every way the image holds its scheduler
        # (the hold file, the image's own setting, a state folder it does not trust, staff's pause), so its
        # answer is asked, the same one scheduler.sh run-once reads. On an image without the setting, only the
        # hold file counts.
        if [ "${name}" = schedulers:run ]; then
            answer="$(sudo -n -- bash "${dir}/remote/admin.sh" scheduler-held 2> /dev/null)" || answer=''
            hold="$(sed -n 's/^hold_file=//p' <<< "${answer}" | head -n 1)"
            setting="$(sed -n 's/^setting=//p' <<< "${answer}" | head -n 1)"
            also="$(sed -n 's/^also=//p' <<< "${answer}" | head -n 1)"
            case "${also}" in *[!abcdefghijklmnopqrstuvwxyz\ -]*) hold='' ;; esac
            case "${hold}:${setting}" in
                yes:on | yes:off | yes:none | yes:unknown)
                    echo "[suitecrm] refused: the scheduler is held (${sc_scheduler_hold} is there), so no scheduled job runs yet. scheduler.sh queued shows what would start, and scheduler.sh release lets it go after the user's yes." >&2
                    exit 64
                    ;;
                no:off)
                    echo "[suitecrm] refused: the scheduler is held (the image's scheduler setting is off), so no scheduled job runs yet. scheduler.sh queued shows what would start, and scheduler.sh release lets it go after the user's yes." >&2
                    exit 64
                    ;;
                unknown:on | unknown:off | unknown:none | unknown:unknown)
                    echo "[suitecrm] refused: $(sc_untrusted_message "${sc_image_dir}") So whether the scheduler is held is not known, and no scheduler pass was run." >&2
                    exit 64
                    ;;
                no:unknown)
                    echo "[suitecrm] refused: the image's scheduler setting could not be read, so whether the scheduler is held is not known. Nothing was run." >&2
                    exit 64
                    ;;
                no:on | no:none) ;;
                *)
                    echo "[suitecrm] refused: could not read whether the scheduler is held (remote/admin.sh scheduler-held gave no answer). Nothing was run." >&2
                    exit 70
                    ;;
            esac
            if [ -n "${also}" ]; then
                echo "[suitecrm] refused: the image runs no scheduled job for now (${also// /, }): scheduler.sh status says why. That is a request to Clouve support. Nothing was run." >&2
                exit 64
            fi
        fi
        cd "${sc_root}" || exit 1
        sudo -n -u www-data -- php bin/console "${name}" "$@" < /dev/null
        rc=$?
        if [ "${rc}" -eq 255 ]; then
            echo "[suitecrm] bin/console ${name} crashed (PHP ended with a fatal error)." >&2
            rc=70
        fi
        exit "${rc}"
        ;;
    root)
        case "${name}" in
            backup.sh | restore.sh | remote/admin.sh) ;;
            *) echo "[suitecrm] entry.sh: ${name} does not run as root" >&2; exit 64 ;;
        esac
        sudo -n -- bash "${dir}/${name}" "$@"
        exit $?
        ;;
    *)
        echo "[suitecrm] entry.sh: unknown mode ${mode}" >&2
        exit 64
        ;;
esac
