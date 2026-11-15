#!/usr/bin/env bash
# LimeSurvey skill: remote/backup.sh
#
# Runs INSIDE the LimeSurvey container, as root, never on the agent. run-in-limesurvey.sh sends it there over the
# clouve-ops SSH channel. An SSH session does not have the container's environment, so every setting comes from
# LimeSurvey's own config.php, which PHP reads as www-data.
#
# Usage: backup.sh [--no-maintenance]
#        backup.sh --list
#        backup.sh --delete <name> --yes-delete-this-backup
#
# A backup is the folder /var/www/html/clouve/backups/<UTC YYYYmmdd-HHMMSS>/. The Clouve image keeps
# /var/www/html/clouve out of the web. The folder is root's, mode 700, and every file in it is mode 600. It holds:
#   database.sql.gz  mariadb-dump of LimeSurvey's database: every survey, answer, participant, account and
#                    setting, with routines and triggers, and no --databases, so it loads into a database of any name
#   upload.tar.gz    upload/: files that participants uploaded, survey images, uploaded themes and plugins
#   config.tar.gz    application/config/config.php, security.php and, when it is there, allowed_hosts.php.
#                    security.php holds the encryption keys. Without it, encrypted answers, encrypted participant
#                    details and the SMTP password in the dump cannot be read by anyone.
#   plugins.tar.gz   the plugin folders under plugins/ that the admin added by hand (the ones the image's own
#                    LimeSurvey package does not ship)
#   manifest.json    when it was made, LimeSurvey's version and database version, the database name, the
#                    maintenance mode that was on before, the checksum of security.php, and each file's size
#   SHA256SUMS       the checksums of the files above
# It sits on LimeSurvey's own volume, next to the data it protects, and nothing deletes it automatically. To keep
# a copy elsewhere, the admin downloads it: playbooks/back-up.md says how.
#
# The steps:
#   1. Checks: root; clouve and clouve/backups are real folders of root's (lib/state.sh says why); LimeSurvey is
#      installed, with config.php and security.php; the database answers and has LimeSurvey's tables; no other
#      backup or restore is running (a lock on clouve/backups/.lock, held to the end); no restore was cut off
#      (clouve/backups/RESTORE-IN-PROGRESS).
#   2. Cleaning up after a backup that died. A backup whose process was killed leaves a half-made folder and, when
#      it had locked the site, the maintenance mode hard-cli. Once this run holds the lock, no other backup can be
#      alive, so it removes every half-made folder and puts the maintenance mode back to what the dead backup had
#      found, and only when that backup had set it (its note clouve/backups/.maintenance-by-backup says so).
#      restore.sh and health.sh do the same.
#   3. Space. The estimate is the database's size plus upload/ and the hand-added plugins. With less than 1.2
#      times that free on the volume, it stops before it writes anything (exit 3) and gives both numbers.
#   4. Maintenance mode, unless --no-maintenance: `setmaintenancemode hard-cli`, which keeps participants out and
#      locks the admin pages, RemoteControl and the REST API, so that nothing changes while the dump runs.
#      Existing installs have MyISAM tables, and a dump of those is only consistent while nothing writes. The mode
#      that was on before is written to the note first, and is put back at the end, and by the trap if the run
#      stops early: back to what it was, never simply to off. A mode of hard-cli that was on already is left alone.
#   5. The dump and the archives, written under a temporary name.
#   6. The check: the dump's last line says it is complete, gzip -t of each archive, sha256sum -c. A backup that
#      fails it is removed (exit 4).
#   7. The folder gets its name, and the last line names it: `[limesurvey/backup] done: <name> (<size>)`.
# A step that fails removes the half-made folder and puts the maintenance mode back (exit 2). The database
# password reaches the dump program in a mode 600 options file in a mode 700 folder that is removed at the end. It
# is never on a command line, and nothing prints it.
#
# --list prints one line per backup: its name, size, LimeSurvey's version, and INCOMPLETE when its SHA256SUMS is
# missing. --delete removes one backup by name, with --yes-delete-this-backup, which the playbook gives after the
# admin picked that backup and said yes.
#
# Exit codes:
#   0  done
#   1  usage, or this is not the place or the time: not root, clouve or clouve/backups is not root's own folder,
#      LimeSurvey not installed, the database does not answer, another backup or restore is running, a restore was
#      cut off
#   2  a step failed: the half-made folder is removed and the maintenance mode is back as it was
#   3  not enough space; nothing was written
#   4  the check of the new backup failed; the folder is removed
#   5  the backup is complete and kept, but the maintenance mode could not be put back: stderr says how to do it
#   129, 130, 141, 143  stopped by HUP, INT, PIPE or TERM, and cleaned up as for exit 2

# SC2154: lib/state.sh and lib/site.sh, sourced below, set clv_backups_dir, ls_root, site_work and the db_* and
# code_* variables.
# shellcheck disable=SC2154

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the database password.
set +x

made_by='limesurvey skill backup.sh 0.1.0'
say() { printf '[limesurvey/backup] %s\n' "$*"; }
err() { printf '[limesurvey/backup] %s\n' "$*" >&2; }

remote_dir="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${remote_dir}/lib/state.sh" || exit 1
# shellcheck source=/dev/null
. "${remote_dir}/lib/site.sh" || exit 1

package_plugins=/clouve/limesurvey/package/plugins
note=.maintenance-by-backup

mode=backup
maintenance=1
target=''
confirmed=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) mode=list; shift ;;
        --delete)
            [ "$#" -ge 2 ] || { err "--delete needs the backup's name"; exit 1; }
            mode=delete
            target="$2"
            shift 2
            ;;
        --yes-delete-this-backup) confirmed=1; shift ;;
        --no-maintenance) maintenance=0; shift ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then err "this runs as root inside the LimeSurvey container (run-in-limesurvey.sh sends it there)"; exit 1; fi

# human BYTES: a size a person can read
human() {
    local b="$1"
    if [ "${b}" -ge 1073741824 ]; then printf '%d.%d GB' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
    elif [ "${b}" -ge 1048576 ]; then printf '%d MB' $((b / 1048576))
    elif [ "${b}" -ge 1024 ]; then printf '%d KB' $((b / 1024))
    else printf '%d bytes' "${b}"; fi
}

# valid_name NAME: a backup's name, and nothing that could lead out of the folder
valid_name() { [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; }

# From here on the current folder is clouve/backups, checked to be root's own, and every name is relative to it.
if [ "${mode}" = list ]; then
    clv_backups_enter existing
    case $? in
        0) ;;
        2) say "there are no backups in clouve/backups yet"; exit 0 ;;
        *) exit 1 ;;
    esac
    found=0
    for d in [0-9]*-[0-9]*; do
        [ -e "${d}" ] || [ -L "${d}" ] || continue
        valid_name "${d}" || continue
        found=1
        if ! clv_backup_trusted "${d}"; then
            printf '%s  NOT A FOLDER OF ROOT: it does not count as a backup and cannot be restored\n' "${d}"
            continue
        fi
        size="$(du -sb "${d}" 2> /dev/null | cut -f1)"
        version="$(sed -n 's/.*"limesurvey_version": *"\([^"]*\)".*/\1/p' "${d}/manifest.json" 2> /dev/null | head -n 1)"
        state=''
        [ -f "${d}/SHA256SUMS" ] || state='  INCOMPLETE'
        printf '%s  %s  LimeSurvey %s%s\n' "${d}" "$(human "${size:-0}")" "${version:-?}" "${state}"
    done
    [ "${found}" -eq 1 ] || say "there are no backups in clouve/backups yet"
    exit 0
fi

if [ "${mode}" = delete ]; then
    valid_name "${target}" || { err "a backup's name looks like 20261112-153000, not $(printf '%q' "${target}")"; exit 1; }
    clv_backups_enter existing
    case $? in
        0) ;;
        2) err "there is no backup ${target} (backup.sh --list shows them)"; exit 1 ;;
        *) exit 1 ;;
    esac
    if [ ! -d "${target}" ] || [ -L "${target}" ]; then err "there is no backup ${target} (backup.sh --list shows them)"; exit 1; fi
    if [ "${confirmed}" -ne 1 ]; then
        err "deleting a backup cannot be undone. After the admin picked ${target} and said yes, run this again with --yes-delete-this-backup"
        exit 1
    fi
    if [ -e RESTORE-IN-PROGRESS ]; then
        err "a restore was cut off (clouve/backups/RESTORE-IN-PROGRESS). Finishing or undoing it may need this backup, so nothing was deleted"
        exit 1
    fi
    rm -rf -- "./${target}" || { err "could not delete ${target}"; exit 1; }
    say "deleted the backup ${target}"
    exit 0
fi

# --- 1. Checks ------------------------------------------------------------------------------------------------------
config_dir="${ls_root}/application/config"
if [ ! -f "${config_dir}/config.php" ] || [ ! -f "${config_dir}/version.php" ]; then
    err "LimeSurvey is not installed in ${ls_root}"
    exit 1
fi
if [ ! -f "${config_dir}/security.php" ]; then
    err "application/config/security.php is missing. It holds the encryption keys, and a backup without it could not read its own encrypted answers. Nothing was backed up. To put the keys back from an earlier backup: run-in-limesurvey.sh restore.sh --keys-only --backup <name> (playbooks/restore-from-backup.md, \"Only the keys are missing or wrong\")"
    exit 1
fi
for f in config.php security.php; do
    if [ -L "${config_dir}/${f}" ]; then err "application/config/${f} is a link, not a file. Nothing was backed up. Tell the user to contact Clouve support"; exit 1; fi
done
clv_backups_enter make || exit 1
if [ -e RESTORE-IN-PROGRESS ]; then
    err "a restore was cut off (clouve/backups/RESTORE-IN-PROGRESS). Finish it first: playbooks/restore-from-backup.md"
    exit 1
fi
if [ -L .lock ]; then err "clouve/backups/.lock is a link. Nothing was backed up"; exit 1; fi
exec 9> .lock || { err "could not open the lock in clouve/backups"; exit 1; }
if ! flock -n 9; then
    err "another backup or a restore is running in this container. Wait for it to end"
    exit 1
fi
if ! ls_site_read; then
    err "could not read LimeSurvey's database settings from application/config/config.php"
    exit 1
fi

work=''
folder=''
maintenance_before=''
maintenance_ours=no
finished=no
# put_mode_back: the maintenance mode goes back to what this run found, and the note goes once it is back
put_mode_back() {
    [ "${maintenance_ours}" = yes ] || return 0
    if ls_console setmaintenancemode "${maintenance_before}" > /dev/null 2>&1; then
        maintenance_ours=no
        rm -f -- "${note}"
        return 0
    fi
    return 1
}
cleanup() {
    local rc=$?
    trap - EXIT HUP INT TERM PIPE
    if [ "${finished}" != yes ] && [ -n "${folder}" ] && [ -d "./${folder}" ]; then
        rm -rf -- "./${folder}"
    fi
    if ! put_mode_back; then
        err "could not put the maintenance mode back to ${maintenance_before}. LimeSurvey is still locked. The next backup, restore or verify-health.sh run puts it back; console.sh setmaintenancemode ${maintenance_before} does it now"
        if [ "${finished}" = yes ]; then rc=5; fi
    fi
    [ -z "${site_work}" ] || rm -rf -- "${site_work}"
    [ -z "${work}" ] || rm -rf -- "${work}"
    exit "${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 141' PIPE
trap 'exit 143' TERM

ls_site_client || exit 1
if ! db_version="$(ls_sql "SELECT stg_value FROM $(ls_table settings_global) WHERE stg_name = 'DBVersion'" 2> "${site_work}/err")" || [ -z "${db_version}" ]; then
    err "the database does not answer, or has no LimeSurvey tables: $(head -c 300 "${site_work}/err" 2> /dev/null)"
    exit 1
fi

# --- 2. After a backup that died ---------------------------------------------------------------------------------------
# This run holds the lock, so no other backup is alive: what is half-made is nobody's.
if recovered="$(ls_recover_dead_backup)"; then
    [ -z "${recovered}" ] || say "a backup that was cut off earlier left its traces: ${recovered}"
else
    err "a backup that was cut off earlier left LimeSurvey locked (maintenance mode hard-cli), and the mode could not be put back. Nothing was backed up. console.sh setmaintenancemode off lifts the lock"
    exit 1
fi

# --- 3. Space --------------------------------------------------------------------------------------------------------
db_bytes="$(ls_sql "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()")" || db_bytes=0
upload_bytes="$(du -sb "${ls_root}/upload" 2> /dev/null | cut -f1)"
# The hand-added plugins: the folders under plugins/ that the image's package does not ship.
extra_plugins=()
for d in "${ls_root}"/plugins/*/; do
    [ -d "${d}" ] && [ ! -L "${d%/}" ] || continue
    name="$(basename "${d}")"
    case "${name}" in *[!A-Za-z0-9_-]*) continue ;; esac
    if [ -d "${package_plugins}" ] && [ -e "${package_plugins}/${name}" ]; then continue; fi
    extra_plugins+=("${name}")
done
plugin_bytes=0
for name in ${extra_plugins[@]+"${extra_plugins[@]}"}; do
    b="$(du -sb "${ls_root}/plugins/${name}" 2> /dev/null | cut -f1)"
    plugin_bytes=$((plugin_bytes + ${b:-0}))
done
estimate=$((${db_bytes%%.*} + ${upload_bytes:-0} + plugin_bytes + 1048576))
free="$(df -PB1 . | awk 'NR == 2 { print $4 }')"
need=$((estimate * 12 / 10))
if [ "${free:-0}" -lt "${need}" ]; then
    err "not enough space for a backup: it needs about $(human "${need}") and the volume has $(human "${free:-0}") free. Nothing was written. Older backups can be deleted (backup.sh --list, then --delete), or the plan can get a bigger disk"
    exit 3
fi

# --- 4. Maintenance mode ---------------------------------------------------------------------------------------------
stamp="$(LC_ALL=C date -u '+%Y%m%d-%H%M%S')"
valid_name "${stamp}" || { err "date gave no time stamp"; exit 1; }
if [ -e "${stamp}" ] || [ -L "${stamp}" ]; then err "a backup named ${stamp} is there already; run this again in a second"; exit 1; fi
folder=".making-${stamp}"
(umask 077 && mkdir -- "${folder}") || { err "could not make the backup folder"; exit 2; }
umask 077

if ! maintenance_before="$(ls_maintenance_mode)"; then err "could not read the maintenance mode"; exit 2; fi
case "${maintenance_before}" in off | soft | hard | hard-cli) ;; *) maintenance_before=off ;; esac
if [ "${maintenance}" -eq 1 ]; then
    if [ "${maintenance_before}" = hard-cli ]; then
        say "the maintenance mode is hard-cli already, so it is left as it is"
    else
        say "maintenance mode on (hard-cli): participants and admins get a maintenance page until the backup is done"
        # The note first: if this run dies from here on, the next one knows that the lock is this backup's and
        # what to put back.
        printf '%s\n%s\n' "${maintenance_before}" "${folder}" > "${note}" || { err "could not write the note about the maintenance mode"; exit 2; }
        maintenance_ours=yes
        if ! ls_console setmaintenancemode hard-cli > "${site_work}/out" 2>&1; then
            err "could not turn the maintenance mode on: $(tail -n 3 "${site_work}/out")"
            exit 2
        fi
    fi
else
    say "no maintenance mode (--no-maintenance): answers that arrive while this runs may be in the backup only in part"
fi

# --- 5. The dump and the archives --------------------------------------------------------------------------------------
dir="./${folder}"
answer_sets="$(ls_answer_sets)"
say "dumping the database ${db_name}"
"${db_dump[@]}" --single-transaction --routines --triggers --hex-blob --default-character-set=utf8mb4 "${db_name}" 2> "${site_work}/err" | gzip > "${dir}/database.sql.gz"
codes=("${PIPESTATUS[@]}")
if [ "${codes[0]}" -ne 0 ] || [ "${codes[1]}" -ne 0 ]; then
    err "the database dump failed: $(head -c 400 "${site_work}/err")"
    exit 2
fi
say "archiving upload/ ($(human "${upload_bytes:-0}"))"
tar -czf "${dir}/upload.tar.gz" -C "${ls_root}" upload 2> "${site_work}/err"
rc=$?
# tar's exit 1 means a file changed while it was read: the archive is whole.
if [ "${rc}" -gt 1 ]; then err "archiving upload/ failed: $(head -c 400 "${site_work}/err")"; exit 2; fi
config_files=(application/config/config.php application/config/security.php)
if [ -f "${config_dir}/allowed_hosts.php" ] && [ ! -L "${config_dir}/allowed_hosts.php" ]; then config_files+=(application/config/allowed_hosts.php); fi
if ! tar -czf "${dir}/config.tar.gz" -C "${ls_root}" "${config_files[@]}" 2> "${site_work}/err"; then
    err "archiving the config files failed: $(head -c 400 "${site_work}/err")"
    exit 2
fi
plugin_paths=()
for name in ${extra_plugins[@]+"${extra_plugins[@]}"}; do plugin_paths+=("plugins/${name}"); done
if [ "${#plugin_paths[@]}" -gt 0 ]; then
    tar -czf "${dir}/plugins.tar.gz" -C "${ls_root}" "${plugin_paths[@]}" 2> "${site_work}/err"
else
    tar -czf "${dir}/plugins.tar.gz" -T /dev/null 2> "${site_work}/err"
fi
rc=$?
if [ "${rc}" -gt 1 ]; then err "archiving the added plugins failed: $(head -c 400 "${site_work}/err")"; exit 2; fi

# --- 6. The manifest and the check -------------------------------------------------------------------------------------
security_sum="$(sha256sum "${config_dir}/security.php" | cut -d' ' -f1)"
tables="$(ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")"
plugins_json=''
for name in ${extra_plugins[@]+"${extra_plugins[@]}"}; do plugins_json+="${plugins_json:+, }\"${name}\""; done
{
    echo '{'
    echo "  \"made_by\": \"${made_by}\","
    echo "  \"made_utc\": \"${stamp}\","
    echo "  \"limesurvey_version\": \"${code_version}\","
    echo "  \"limesurvey_build\": \"${code_build}\","
    echo "  \"code_dbversion\": ${code_dbversion:-0},"
    echo "  \"database_dbversion\": ${db_version:-0},"
    echo "  \"database_name\": \"${db_name}\","
    echo "  \"table_prefix\": \"${db_prefix}\","
    echo "  \"tables\": ${tables:-0},"
    echo "  \"answer_sets\": ${answer_sets:-0},"
    echo "  \"maintenance_before\": \"${maintenance_before}\","
    echo "  \"with_maintenance\": $([ "${maintenance}" -eq 1 ] && echo true || echo false),"
    echo "  \"security_sha256\": \"${security_sum}\","
    echo "  \"added_plugins\": [${plugins_json}],"
    echo "  \"upload_bytes\": ${upload_bytes:-0},"
    echo '  "files": {'
    first=1
    for f in database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz; do
        [ "${first}" -eq 1 ] || echo ','
        first=0
        printf '    "%s": %s' "${f}" "$(stat -c %s "${dir}/${f}")"
    done
    echo
    echo '  }'
    echo '}'
} > "${dir}/manifest.json"
(cd "${dir}" && sha256sum database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz manifest.json > SHA256SUMS) || { err "could not write the checksums"; exit 2; }
chmod 600 "${dir}"/* || exit 2

if ! (cd "${dir}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then err "the new backup's checksums do not match its files, so it was removed"; exit 4; fi
for f in database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz; do
    if ! gzip -t "${dir}/${f}" 2> /dev/null; then err "${f} of the new backup is damaged, so the backup was removed"; exit 4; fi
done
if ! zcat "${dir}/database.sql.gz" | tail -n 5 | grep -q -- '-- Dump completed'; then
    err "the database dump has no end line, so it is not whole, and the backup was removed"
    exit 4
fi
if ! tar -tzf "${dir}/config.tar.gz" 2> /dev/null | grep -qx 'application/config/security.php'; then
    err "the new backup has no security.php, so it was removed"
    exit 4
fi

# --- 7. The name -------------------------------------------------------------------------------------------------------
if ! mv -- "${dir}" "./${stamp}"; then err "could not give the backup its name"; exit 2; fi
folder="${stamp}"
finished=yes
total="$(du -sb "./${stamp}" | cut -f1)"
if [ "${maintenance_ours}" = yes ] && put_mode_back; then
    say "maintenance mode back to ${maintenance_before}"
fi
say "LimeSurvey ${code_version}, database version ${db_version}, ${tables} tables, ${answer_sets:-0} answer sets, upload/ $(human "${upload_bytes:-0}"), ${#extra_plugins[@]} added plugin(s)"
say "done: ${stamp} ($(human "${total}")), in clouve/backups on LimeSurvey's own volume"
