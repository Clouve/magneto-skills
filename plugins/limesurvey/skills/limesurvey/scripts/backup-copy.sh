#!/usr/bin/env bash
# LimeSurvey skill: backup-copy.sh
#
# Copies one backup between the LimeSurvey container and the agent's Files pane. A backup that backup.sh makes
# sits on LimeSurvey's own volume, so it is lost with that volume. Pulling it to the Files pane lets the admin
# download a copy. Pushing puts a backup the admin uploaded, from this or another deployment, where restore.sh
# finds it.
#
# Usage: backup-copy.sh pull <name>     from the container to ~/limesurvey-backups/<name>/
#        backup-copy.sh push <name>     from ~/limesurvey-backups/<name>/ to the container
#        backup-copy.sh list            the backups in ~/limesurvey-backups
#
# ~/limesurvey-backups is mode 700 and its files are mode 600. A backup holds every answer, every participant and
# the encryption keys, so tell the admin to keep the downloaded copy somewhere safe and to delete it from the
# Files pane afterwards.
#
# The backup travels as a tar stream on the SSH channel (remote/backup-stream.sh, sent by run-in-limesurvey.sh).
# The receiving side takes only a backup's own six files and checks them against the backup's checksums. A name
# that is there already is never overwritten.
#
# Env vars read:
#   LIMESURVEY_HOST  for run-in-limesurvey.sh
#   HOME             where ~/limesurvey-backups lives
#
# Exit codes:
#   0    done
#   1    the backup is not there, the name is taken, or the copy is not whole
#   64   usage
#   75   LimeSurvey is being installed or upgraded, so nothing was run
#   255  ssh could not reach the container

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: backup-copy.sh pull <name>
       backup-copy.sh push <name>
       backup-copy.sh list

pull copies a backup from the LimeSurvey container to ~/limesurvey-backups/<name>/ (the Files pane shows it), for
the admin to download. push copies ~/limesurvey-backups/<name>/ into the container, where restore.sh finds it.
A backup holds every answer and the encryption keys: keep copies safe, and delete them from the Files pane.

Exit codes: 0 done, 1 not there, taken or not whole, 64 usage, 75 LimeSurvey is being installed or upgraded,
255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/backup-copy] %s\n' "$*" >&2; }

action="${1:-}"
name="${2:-}"
case "${action}" in
    -h | --help) usage; exit 0 ;;
    pull | push)
        [[ "${name}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { msg "a backup's name looks like 20261112-153000"; usage >&2; exit 64; }
        ;;
    list) [ -z "${name}" ] || { msg "list takes no name"; exit 64; } ;;
    *) msg "say pull, push or list"; usage >&2; exit 64 ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${script_dir}/lib/limesurvey-files.sh" || exit 1
dir="$(ls_private_dir limesurvey-backups)" || exit 1
files=(SHA256SUMS manifest.json database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz)

case "${action}" in
    list)
        found=0
        for d in "${dir}"/[0-9]*-[0-9]*; do
            [ -d "${d}" ] || continue
            found=1
            printf '%s  %s\n' "${d##*/}" "$(du -sh "${d}" 2> /dev/null | cut -f1)"
        done
        [ "${found}" -eq 1 ] || echo "There are no backups in limesurvey-backups in the Files pane."
        ;;
    pull)
        if [ -e "${dir}/${name}" ]; then msg "limesurvey-backups/${name} is there already. Nothing was copied"; exit 1; fi
        incoming="${dir}/.incoming-${name}"
        rm -rf -- "${incoming}"
        (umask 077 && mkdir -- "${incoming}") || { msg "could not make a folder in limesurvey-backups"; exit 1; }
        trap 'rm -rf -- "${incoming}"' EXIT
        "${script_dir}/run-in-limesurvey.sh" backup-stream.sh send "${name}" | (umask 077 && tar -xf - -C "${incoming}" --no-same-owner "${files[@]/#/${name}/}" 2> /dev/null)
        codes=("${PIPESTATUS[@]}")
        if [ "${codes[0]}" -ne 0 ]; then exit "${codes[0]}"; fi
        if [ "${codes[1]}" -ne 0 ]; then msg "what arrived is not a whole backup. Nothing was kept"; exit 1; fi
        chmod 700 "${incoming}/${name}" && chmod 600 "${incoming}/${name}"/* || exit 1
        if ! (cd "${incoming}/${name}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then
            msg "the copy does not match the backup's checksums. Nothing was kept"
            exit 1
        fi
        mv -- "${incoming}/${name}" "${dir}/${name}" || exit 1
        printf 'Copied the backup %s to limesurvey-backups/%s in the Files pane (%s).\n' "${name}" "${name}" "$(du -sh "${dir}/${name}" | cut -f1)"
        echo "It holds every answer, every participant and the encryption keys. Ask the admin to download the folder, keep it somewhere safe, and delete it from the Files pane."
        ;;
    push)
        for f in "${files[@]}"; do
            if [ ! -f "${dir}/${name}/${f}" ]; then msg "limesurvey-backups/${name}/${f} is missing: a backup has ${files[*]}"; exit 1; fi
        done
        if ! (cd "${dir}/${name}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then
            msg "limesurvey-backups/${name} does not match its own checksums, so it is damaged or incomplete. Nothing was copied"
            exit 1
        fi
        tar -cf - -C "${dir}" "${files[@]/#/${name}/}" | "${script_dir}/run-in-limesurvey.sh" --stdin backup-stream.sh receive "${name}"
        codes=("${PIPESTATUS[@]}")
        if [ "${codes[1]}" -ne 0 ]; then exit "${codes[1]}"; fi
        if [ "${codes[0]}" -ne 0 ]; then msg "could not read limesurvey-backups/${name}"; exit 1; fi
        echo "The backup ${name} is in the LimeSurvey container now. restore.sh --backup ${name} shows what a restore would replace."
        ;;
esac
