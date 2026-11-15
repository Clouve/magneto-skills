#!/usr/bin/env bash
# LimeSurvey skill: remote/backup-stream.sh
#
# Runs INSIDE the LimeSurvey container, as root, sent by run-in-limesurvey.sh (backup-copy.sh is its front end on
# the agent). It moves one backup between the container and the agent as a tar stream on the SSH channel, so that
# the admin can download a backup from the Files pane, or put one from another deployment in place for a restore.
#
# Usage: backup-stream.sh send <name>      writes a tar of clouve/backups/<name> to stdout, and nothing else
#        backup-stream.sh receive <name>   reads a tar from stdin and unpacks it as clouve/backups/<name>
#
# Both check first that clouve, clouve/backups and the backup's folder are real folders of root's
# (lib/state.sh says why), and stop when they are not. receive takes only a backup's own files (the six that
# backup.sh writes), without the stream's owners or modes, refuses a name that is there already, makes the folder
# root's with mode 700 and its files mode 600, and checks the files against the backup's SHA256SUMS. It holds the
# lock of backup.sh and restore.sh while it writes. A stream that fails any of this leaves nothing behind.
#
# Exit codes: 0 done; 1 usage, no such backup, a name that is taken, a folder that is not root's own, another
# backup or restore running, or not root; 2 the stream is not a whole backup.

# SC2154: lib/state.sh, sourced below, sets clv_backup_files.
# shellcheck disable=SC2154

set -uo pipefail

err() { printf '[limesurvey/backup-stream] %s\n' "$*" >&2; }

remote_dir="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${remote_dir}/lib/state.sh" || exit 1

action="${1:-}"
name="${2:-}"
if [ "$(id -u)" -ne 0 ]; then err "this runs as root inside the LimeSurvey container"; exit 1; fi
[[ "${name}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { err "a backup's name looks like 20261112-153000"; exit 1; }
files=("${clv_backup_files[@]}")

# From here on the current folder is clouve/backups, checked to be root's own, and every name is relative to it.
case "${action}" in
    send)
        clv_backups_enter existing
        case $? in
            0) ;;
            2) err "there is no complete backup ${name} in clouve/backups"; exit 1 ;;
            *) exit 1 ;;
        esac
        if [ ! -e "${name}" ] && [ ! -L "${name}" ]; then err "there is no complete backup ${name} in clouve/backups"; exit 1; fi
        if ! clv_backup_trusted "${name}"; then err "clouve/backups/${name} is a link, or it or one of its files does not belong to root, so it is not a backup this skill put there. It is not copied"; exit 1; fi
        [ -f "${name}/SHA256SUMS" ] || { err "there is no complete backup ${name} in clouve/backups"; exit 1; }
        exec tar -cf - "${files[@]/#/${name}/}"
        ;;
    receive)
        clv_backups_enter make || exit 1
        if [ -L .lock ]; then err "clouve/backups/.lock is a link. Nothing was changed"; exit 1; fi
        exec 9> .lock || { err "could not open the lock in clouve/backups"; exit 1; }
        if ! flock -n 9; then err "a backup or a restore is running in this container. Wait for it to end"; exit 1; fi
        if [ -e "${name}" ] || [ -L "${name}" ]; then err "a backup named ${name} is in clouve/backups already. Nothing was changed"; exit 1; fi
        incoming=".incoming-${name}"
        rm -rf -- "./${incoming}"
        (umask 077 && mkdir -- "${incoming}") || exit 1
        trap 'rm -rf -- "./${incoming}"' EXIT
        # Only the backup's own files are taken out of the stream, under their own names.
        if ! tar -xf - -C "${incoming}" --no-same-owner --no-same-permissions "${files[@]/#/${name}/}" 2> /dev/null; then
            err "the stream is not a backup named ${name} (it lacks one of: ${files[*]})"
            exit 2
        fi
        if [ -L "${incoming}/${name}" ] || [ ! -d "${incoming}/${name}" ]; then err "the stream's ${name} is not a folder"; exit 2; fi
        for f in "${files[@]}"; do
            if [ ! -f "${incoming}/${name}/${f}" ] || [ -L "${incoming}/${name}/${f}" ]; then err "the stream's ${f} is not a plain file"; exit 2; fi
        done
        chown -h root:root "${incoming}/${name}" "${files[@]/#/${incoming}/${name}/}" && chmod 700 "${incoming}/${name}" && chmod 600 "${files[@]/#/${incoming}/${name}/}" || exit 1
        if ! (cd "${incoming}/${name}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then
            err "the backup's files do not match its checksums, so it was not kept"
            exit 2
        fi
        mv -- "${incoming}/${name}" "./${name}" || { err "could not put the backup in place"; exit 1; }
        printf '[limesurvey/backup-stream] the backup %s is in clouve/backups now\n' "${name}"
        ;;
    *)
        err "say send or receive"
        exit 1
        ;;
esac
