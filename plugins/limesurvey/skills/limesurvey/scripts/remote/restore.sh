#!/usr/bin/env bash
# LimeSurvey skill: remote/restore.sh
#
# Runs INSIDE the LimeSurvey container, as root, never on the agent. run-in-limesurvey.sh sends it there over the
# clouve-ops SSH channel. It puts a backup made by backup.sh back over this LimeSurvey, or only the backup's
# encryption keys.
#
# Usage: restore.sh --backup <name>                                  says what it would replace, changes nothing
#        restore.sh --backup <name> --yes-replace-current-data       restores
#        ... [--skip-safety-backup]   restore although no backup of the current state was made in the last hour
#        restore.sh --keys-only --backup <name>                      says whether the backup's keys read the data
#        restore.sh --keys-only --backup <name> --yes-replace-the-keys   puts back security.php alone
#        restore.sh --last-log        prints the log of the last restore
#
# What a restore replaces: every table of LimeSurvey's database (all surveys, answers, participants, accounts and
# settings), everything in upload/, the encryption keys (security.php), and the plugin folders the backup holds.
# What it keeps: this deployment's own config.php (its database settings and its address) and its
# allowed_hosts.php, when they are there. The Clouve image sets the database settings again at every start anyway.
#
# The order matters, and the script keeps to it:
#   1. Checks, before anything changes: root; clouve, clouve/backups and the backup's folder are real folders of
#      root's (lib/state.sh says why); the backup is whole (SHA256SUMS, gzip -t); its dump holds LimeSurvey's
#      settings table; it is not from a newer LimeSurvey than this container runs; the database answers; upload/
#      has room; no other backup or restore runs; and a backup of the current state exists that is less than an
#      hour old. An older one is named with its age and with how many answer sets the site has gained since, and
#      then --skip-safety-backup says that what was added since is not worth keeping. Neither is needed when a
#      restore was cut off. With the lock in hand, it also cleans up after a backup that died (lib/site.sh,
#      ls_recover_dead_backup), and says so: that is the one thing a run without the yes option changes.
#   2. The marker clouve/backups/RESTORE-IN-PROGRESS is written, before the database is touched. The skill's other
#      scripts refuse to run while it is there, and verify-health.sh reports it. The Clouve image, if the container
#      restarts while the marker is there, shows a "being restored" page, starts no LimeSurvey and waits, so that
#      this script can be run again. From here on a dropped connection does not stop the restore: it ignores HUP
#      and PIPE and goes on to the end, writing to clouve/backups/restore-<UTC time>.log.
#   3. Maintenance mode hard-cli, when this LimeSurvey is in a state to take it.
#   4. security.php from the backup goes in place, BEFORE any other LimeSurvey code runs. LimeSurvey makes a new
#      security.php, with new keys, the moment it starts without one, and with the wrong keys nothing encrypted
#      in the database can be read. The file that was there is kept in clouve/backups/before-restore-<UTC time>/.
#   5. The dump is loaded over the database as it is. A dump replaces each of its tables in turn, so LimeSurvey's
#      tables are there at every moment: the platform's health check keeps answering through a long load, and a
#      container that restarts in the middle finds a database it can start on. The tables are never dropped
#      first. When the load is done, the tables and views that the dump does not hold are removed (a failed
#      upgrade or a newer site can have left some).
#   6. upload/ is emptied and filled from the backup. The added plugins are put back, except the ones this
#      image's own LimeSurvey package ships. Files are unpacked as www-data, never as root, by name, without the
#      archive's owners and without setuid, setgid or sticky bits. Nothing but files, folders and links is kept.
#   7. When the backup's database is older than this LimeSurvey's code, the database update runs (console.php
#      updatedb, as www-data), and its result is checked.
#   8. The maintenance mode goes back to what the backup recorded (the dump was taken under hard-cli, so the
#      database it holds says hard-cli), the caches are flushed, LimeSurvey is started once on the restored data,
#      and the encryption keys are tested against what the database holds encrypted.
#   9. The marker is removed. The last line is `[limesurvey/restore] done: ...`.
# A step that fails after step 2 leaves the marker and ends with exit 4. The message names the step. Running the
# same restore again starts from step 3 and is safe to repeat, as often as it takes.
#
# --keys-only puts back application/config/security.php from the backup and nothing else: no table, no file in
# upload/. It is for a site whose security.php is missing or holds other keys than the data was encrypted with.
# It first tests the backup's keys against values the database holds encrypted (the stored SMTP password,
# encrypted participant fields, encrypted answers), and refuses keys that cannot read them. It also refuses when
# the keys in place already read the data. The file that was there is kept in clouve/backups/before-restore-<UTC
# time>/.
#
# The database password reaches the client in a mode 600 options file in a mode 700 folder that is removed at the
# end. It is never on a command line, and nothing prints it. No key is printed either.
#
# Exit codes:
#   0  restored; or, without the yes option, the checks passed and nothing was changed
#   1  usage, or this is not the place or the time: not root, no such backup, a folder that is not root's own,
#      another backup or restore running, no fresh backup of the current state
#   2  the backup is not usable: damaged, incomplete, or from a newer LimeSurvey; --keys-only: its keys do not
#      read the data, or the keys in place already do
#   3  not enough space, or the database does not answer; nothing was changed
#   4  the restore failed after it began: the marker stays, and the output names the step

# SC2154: lib/state.sh and lib/site.sh, sourced below, set clv_backups_dir, ls_root, site_work and the db_* and
# code_* variables.
# shellcheck disable=SC2154

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the database password.
set +x
# What is unpacked gets plain modes, whatever umask the caller came with: no write access for group or others.
umask 022

log=''
say() {
    printf '[limesurvey/restore] %s\n' "$*" 2> /dev/null || :
    [ -z "${log}" ] || printf '%s [limesurvey/restore] %s\n' "$(date -u '+%H:%M:%S')" "$*" >> "${log}"
}
err() {
    printf '[limesurvey/restore] %s\n' "$*" >&2 2> /dev/null || :
    [ -z "${log}" ] || printf '%s [limesurvey/restore] %s\n' "$(date -u '+%H:%M:%S')" "$*" >> "${log}"
}

remote_dir="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${remote_dir}/lib/state.sh" || exit 1
# shellcheck source=/dev/null
. "${remote_dir}/lib/site.sh" || exit 1

marker=RESTORE-IN-PROGRESS
package_plugins=/clouve/limesurvey/package/plugins
config_dir="${ls_root}/application/config"

name=''
go=0
skip_safety=0
keys_only=0
keys_go=0
last_log=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --backup)
            [ "$#" -ge 2 ] || { err "--backup needs the backup's name"; exit 1; }
            name="$2"
            shift 2
            ;;
        --yes-replace-current-data) go=1; shift ;;
        --skip-safety-backup) skip_safety=1; shift ;;
        --keys-only) keys_only=1; shift ;;
        --yes-replace-the-keys) keys_go=1; shift ;;
        --last-log) last_log=1; shift ;;
        *) err "unknown option: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then err "this runs as root inside the LimeSurvey container (run-in-limesurvey.sh sends it there)"; exit 1; fi

# From here on the current folder is clouve/backups, checked to be root's own, and every name is relative to it.
clv_backups_enter existing
entered=$?
if [ "${last_log}" -eq 1 ]; then
    [ "${entered}" -ne 1 ] || exit 1
    last=''
    if [ "${entered}" -eq 0 ]; then
        for f in restore-*.log; do
            if [ -f "${f}" ] && [ ! -L "${f}" ]; then last="${f}"; fi
        done
    fi
    if [ -z "${last}" ]; then echo "[limesurvey/restore] no restore has run here"; exit 0; fi
    cat -- "${last}"
    exit 0
fi
[[ "${name}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { err "--backup needs a backup's name, such as 20261112-153000 (backup.sh --list shows them)"; exit 1; }
if [ "${keys_only}" -eq 1 ] && { [ "${go}" -eq 1 ] || [ "${skip_safety}" -eq 1 ]; }; then err "--keys-only goes with --yes-replace-the-keys, not with the options of a full restore"; exit 1; fi
if [ "${keys_only}" -eq 0 ] && [ "${keys_go}" -eq 1 ]; then err "--yes-replace-the-keys goes with --keys-only"; exit 1; fi
case "${entered}" in
    0) ;;
    2) err "there is no backup ${name} in clouve/backups (backup.sh --list shows them)"; exit 1 ;;
    *) exit 1 ;;
esac
dir="./${name}"
if [ ! -e "${dir}" ] && [ ! -L "${dir}" ]; then err "there is no backup ${name} in clouve/backups (backup.sh --list shows them)"; exit 1; fi
if ! clv_backup_trusted "${name}"; then
    err "clouve/backups/${name} is a link, or it or one of its files does not belong to root, so it is not a backup this skill put there. It is not restored. Tell the user to contact Clouve support"
    exit 1
fi

human() {
    local b="$1"
    if [ "${b}" -ge 1073741824 ]; then printf '%d.%d GB' $((b / 1073741824)) $(((b % 1073741824) * 10 / 1073741824))
    elif [ "${b}" -ge 1048576 ]; then printf '%d MB' $((b / 1048576))
    elif [ "${b}" -ge 1024 ]; then printf '%d KB' $((b / 1024))
    else printf '%d bytes' "${b}"; fi
}
# age SECONDS: a length of time a person can read
age() {
    local s="$1"
    if [ "${s}" -ge 172800 ]; then printf '%d days' $((s / 86400))
    elif [ "${s}" -ge 7200 ]; then printf '%d hours' $((s / 3600))
    elif [ "${s}" -ge 120 ]; then printf '%d minutes' $((s / 60))
    else printf '%d seconds' "${s}"; fi
}
# field NAME [FOLDER]: a number or a string from a backup's manifest
field() { sed -n "s/.*\"$1\": *\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "${2:-${dir}}/manifest.json" | head -n 1; }

# --- 1. Checks ---------------------------------------------------------------------------------------------------------
for f in "${clv_backup_files[@]}"; do
    [ -f "${dir}/${f}" ] || { err "the backup ${name} is incomplete: ${f} is missing. It cannot be restored"; exit 2; }
done
if ! (cd "${dir}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1); then
    err "the backup ${name} is damaged: its files do not match its checksums. It cannot be restored"
    exit 2
fi
for f in database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz; do
    gzip -t "${dir}/${f}" 2> /dev/null || { err "the backup ${name} is damaged: ${f} is not a whole archive"; exit 2; }
done
# security.php has to be in the backup as a plain file: the listing's first letter is "-" for one.
if ! tar -tvzf "${dir}/config.tar.gz" 2> /dev/null | grep -q '^-.* application/config/security\.php$'; then
    err "the backup ${name} holds no security.php, so its encrypted answers could never be read. It cannot be restored"
    exit 2
fi
# backup.sh archives files, folders and links. A device file in an archive is not from backup.sh, and it is the one
# thing www-data could not unpack, so such a backup is refused here, before anything is changed.
for f in upload.tar.gz plugins.tar.gz; do
    if tar -tvzf "${dir}/${f}" 2> /dev/null | cut -c1 | grep -q '[bc]'; then
        err "the backup ${name} holds a device file in ${f}, which no backup made by backup.sh has. It cannot be restored"
        exit 2
    fi
done
if [ ! -f "${config_dir}/version.php" ]; then
    err "LimeSurvey's code is not in ${ls_root}. The Clouve image puts it there at its first start; a restore needs it"
    exit 1
fi
for f in config.php security.php allowed_hosts.php; do
    if [ -L "${config_dir}/${f}" ]; then err "application/config/${f} is a link, not a file. Nothing was changed. Tell the user to contact Clouve support"; exit 1; fi
done

if [ -L .lock ]; then err "clouve/backups/.lock is a link. Nothing was changed"; exit 1; fi
exec 9> .lock || { err "could not open the lock in clouve/backups"; exit 1; }
if ! flock -n 9; then err "another backup or a restore is running in this container. Wait for it to end"; exit 1; fi

work="$(mktemp -d /tmp/clouve-ls-restore.XXXXXXXX)" || { err "could not make a work folder"; exit 1; }
finish() {
    local rc=$?
    trap - EXIT
    [ -z "${site_work}" ] || rm -rf -- "${site_work}"
    rm -rf -- "${work}"
    exit "${rc}"
}
trap finish EXIT

# The backup's own config files, for its keys and, when this site has no config.php, its database settings. Only
# the three files a backup can hold are taken out, by name, without the archive's owners or modes, and each has to
# come out as a plain file.
chmod 711 "${work}"
install -d -o root -g root -m 755 "${work}/config" || exit 1
members=()
for f in security.php config.php allowed_hosts.php; do
    if tar -tzf "${dir}/config.tar.gz" 2> /dev/null | grep -qx "application/config/${f}"; then members+=("application/config/${f}"); fi
done
if ! tar -xzf "${dir}/config.tar.gz" -C "${work}/config" --no-same-owner --no-same-permissions "${members[@]}" 2> /dev/null; then err "could not read the backup's config files"; exit 2; fi
backup_config="${work}/config/application/config"
for f in "${members[@]}"; do
    if [ ! -f "${work}/config/${f}" ] || [ -L "${work}/config/${f}" ]; then err "the backup's ${f##*/} is not a plain file. It cannot be restored"; exit 2; fi
done
# www-data reads them (PHP runs as www-data, never as root), and nobody else.
chown -R root:www-data "${work}/config" && chmod -R u=rwX,g=rX,o= "${work}/config" || exit 1

have_config=no
if [ -f "${config_dir}/config.php" ]; then
    have_config=yes
    ls_site_read || { err "could not read this site's database settings from application/config/config.php"; exit 1; }
else
    [ -f "${backup_config}/config.php" ] || { err "this site has no config.php, and the backup holds none"; exit 2; }
    ls_site_read "${backup_config}/config.php" || { err "this site has no config.php, and the backup's could not be read"; exit 2; }
fi
ls_site_client || exit 3
if ! ls_sql 'SELECT 1' > /dev/null 2> "${site_work}/err"; then
    err "the database does not answer with $([ "${have_config}" = yes ] && echo "this site's" || echo "the backup's") settings: $(head -c 300 "${site_work}/err")"
    exit 3
fi
stamp="$(LC_ALL=C date -u '+%Y%m%d-%H%M%S')"
[[ "${stamp}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { err "date gave no time stamp"; exit 1; }

# as_www COMMAND...: runs COMMAND as www-data, from a folder www-data can stand in. This script stands in
# clouve/backups, which is closed to everyone but root, and find, tar and the shell want to be able to come back
# to where they started.
as_www() {
    # The umask is set inside: sudo starts www-data with the system's default for that user, which lets its group
    # write.
    (cd / && sudo -n -u www-data sh -c 'umask 022 && exec "$@"' sh "$@")
}

# put_config FILE MODE: the backup's FILE goes into application/config as www-data's, with MODE. www-data does the
# copy, so that root never writes through a name in a folder that www-data owns. The file that was there is kept,
# for root only.
put_config() {
    local file="$1" mode="$2" keep="before-restore-${stamp}"
    if [ -L "${config_dir}/${file}" ]; then return 1; fi
    if [ -f "${config_dir}/${file}" ]; then
        if cmp -s "${config_dir}/${file}" "${backup_config}/${file}"; then
            as_www chmod "${mode}" "${config_dir}/${file}" 2> /dev/null || :
            return 0
        fi
        (umask 077 && mkdir -p -- "${keep}") || return 1
        (umask 077 && cat -- "${config_dir}/${file}" > "${keep}/${file}") || return 1
    fi
    as_www rm -f -- "${config_dir}/.${file}.restore" || return 1
    as_www sh -c 'umask 077 && cat -- "$1" > "$2" && chmod "$3" "$2" && mv -f -- "$2" "$4"' sh \
        "${backup_config}/${file}" "${config_dir}/.${file}.restore" "${mode}" "${config_dir}/${file}" < /dev/null
}

# --- Only the keys -----------------------------------------------------------------------------------------------------
if [ "${keys_only}" -eq 1 ]; then
    theirs="$(ls_keys_probe "${backup_config}/security.php")"
    if [ -f "${config_dir}/security.php" ]; then ours="$(ls_keys_probe "${config_dir}/security.php")"; else ours=missing; fi
    case "${ours}" in
        missing) say "this site: application/config/security.php is missing" ;;
        ok) say "this site: the keys in application/config/security.php read what the database holds encrypted" ;;
        wrong) say "this site: the keys in application/config/security.php cannot read what the database holds encrypted" ;;
        untested) say "this site: the database holds nothing encrypted to test the keys in place with" ;;
        *) say "this site: application/config/security.php holds no keys" ;;
    esac
    case "${theirs}" in
        ok) say "the backup ${name}: its keys read what the database holds encrypted" ;;
        wrong) say "the backup ${name}: its keys cannot read what the database holds encrypted" ;;
        untested) say "the backup ${name}: the database holds nothing encrypted to test its keys with" ;;
        *) say "the backup ${name}: its security.php holds no keys" ;;
    esac
    if [ "${ours}" = ok ]; then
        err "the keys in place already read the data, so they stay. Nothing was changed"
        exit 2
    fi
    if [ "${theirs}" = wrong ] || [ "${theirs}" = nokeys ]; then
        err "the keys of the backup ${name} are not the ones this database was encrypted with, so they were not put in place. Try an older or a newer backup (backup.sh --list). Nothing was changed"
        exit 2
    fi
    if [ "${theirs}" = untested ] && [ "${ours}" != missing ]; then
        err "the database holds nothing encrypted to test keys with, so there is no telling whether the backup's keys are better than the ones in place. They stay. Nothing was changed"
        exit 2
    fi
    if [ "${theirs}" = untested ]; then
        say "the database holds nothing encrypted, so no key is needed to read it. The backup's security.php would fill the gap, and LimeSurvey would not make a new one"
    fi
    say "this would put back application/config/security.php from the backup ${name}, and nothing else: no table and no file in upload/ changes"
    if [ "${keys_go}" -ne 1 ]; then
        say "the checks passed. Nothing was changed. To put the keys back, after the admin's yes, run this again with --yes-replace-the-keys"
        exit 0
    fi
    put_config security.php 600 || { err "could not put security.php in place. Nothing else was changed"; exit 4; }
    after="$(ls_keys_probe "${config_dir}/security.php")"
    if [ "${after}" != ok ] && [ "${after}" != untested ]; then
        err "security.php is the backup's now, and it still does not read what the database holds encrypted$([ "${ours}" = missing ] || echo ". The file that was there is in clouve/backups/before-restore-${stamp}/")"
        exit 4
    fi
    say "done: security.php is the backup's$([ "${ours}" = missing ] || echo " (the file that was there is kept in clouve/backups/before-restore-${stamp}/)"). verify-health.sh shows the keys line"
    exit 0
fi

# --- 1, continued ------------------------------------------------------------------------------------------------------
backup_dbversion="$(field database_dbversion)"
backup_version="$(field limesurvey_version)"
maintenance_after="$(field maintenance_before)"
upload_bytes="$(field upload_bytes)"
case "${maintenance_after}" in off | soft | hard) ;; *) maintenance_after=off ;; esac
[[ "${backup_dbversion}" =~ ^[0-9]+$ ]] || { err "the backup's manifest names no database version"; exit 2; }
[[ "${code_dbversion}" =~ ^[0-9]+$ ]] || { err "this LimeSurvey's version.php names no database version"; exit 1; }
[[ "${upload_bytes}" =~ ^[0-9]+$ ]] || upload_bytes=0
if [ "${backup_dbversion}" -gt "${code_dbversion}" ]; then
    err "the backup is from LimeSurvey ${backup_version} (database version ${backup_dbversion}), which is newer than the LimeSurvey ${code_version} this container runs (database version ${code_dbversion}). An older LimeSurvey cannot read a newer database, so it was not restored"
    exit 2
fi
# The tables the dump holds. LimeSurvey's settings table has to be one of them: a dump without it would leave a
# site that cannot start.
zcat "${dir}/database.sql.gz" | LC_ALL=C sed -n 's/^DROP TABLE IF EXISTS `\(.*\)`;$/\1/p; s/^CREATE TABLE `\(.*\)` ($/\1/p' | LC_ALL=C sort -u > "${site_work}/dump-tables"
if ! grep -qxF -- "$(ls_table settings_global)" "${site_work}/dump-tables"; then
    err "the dump of the backup ${name} holds no table $(ls_table settings_global), so it is not a LimeSurvey database for this site (its table prefix is \"$(field table_prefix)\", this site's is \"${db_prefix}\"). It cannot be restored here"
    exit 2
fi
if [ -L "${ls_root}/upload" ] || [ ! -d "${ls_root}/upload" ]; then err "${ls_root}/upload is not a folder. Nothing was changed. Tell the user to contact Clouve support"; exit 1; fi
upload_free="$(df -PB1 "${ls_root}/upload" 2> /dev/null | awk 'NR == 2 { print $4 }')"
upload_used="$(du -sb "${ls_root}/upload" 2> /dev/null | cut -f1)"
if [ "$((${upload_free:-0} + ${upload_used:-0}))" -lt "$((upload_bytes * 11 / 10))" ]; then
    err "upload/ has no room for the backup's files: they take $(human "${upload_bytes}") and the volume can hold $(human "$((${upload_free:-0} + ${upload_used:-0}))"). Nothing was changed"
    exit 3
fi

# What a backup that died left behind, now that this run holds the lock.
if recovered="$(ls_recover_dead_backup)"; then
    [ -z "${recovered}" ] || say "a backup that was cut off earlier left its traces: ${recovered}"
fi

# The newest complete backup of what is here now, other than the one to restore.
newest=''
newest_age=0
now="$(date -u +%s)"
for d in [0-9]*-[0-9]*; do
    [ "${d}" != "${name}" ] || continue
    [[ "${d}" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]] || continue
    clv_backup_trusted "${d}" && [ -f "${d}/SHA256SUMS" ] || continue
    made="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2> /dev/null)" || continue
    [ "$((now - made))" -ge 0 ] || continue
    newest="${d}"
    newest_age=$((now - made))
done
cut_off=no
[ ! -e "${marker}" ] || cut_off=yes

tables_now="$(ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()" 2> /dev/null)"
answers_now="$(ls_answer_sets)"
[[ "${answers_now}" =~ ^[0-9]+$ ]] || answers_now=0
say "the backup ${name}: LimeSurvey ${backup_version}, database version ${backup_dbversion}, $(field tables) tables, $(field answer_sets) answer sets, upload/ $(human "${upload_bytes}")"
say "this site: LimeSurvey ${code_version} (database version ${code_dbversion}), ${tables_now:-0} tables in the database ${db_name}, ${answers_now} answer sets, upload/ $(human "${upload_used:-0}")"
say "a restore replaces: every table of the database, everything in upload/, the encryption keys (security.php) and the added plugins the backup holds"
say "a restore keeps: $([ "${have_config}" = yes ] && echo "this site's config.php (its database settings and address)" || echo "nothing of config.php, since this site has none: the backup's is used")"
if [ "${backup_dbversion}" -lt "${code_dbversion}" ]; then
    say "the backup's database is older than this LimeSurvey, so the database update runs after the dump is loaded"
fi
gained=''
if [ -n "${newest}" ]; then
    had="$(field answer_sets "./${newest}")"
    if [[ "${had}" =~ ^[0-9]+$ ]]; then
        if [ "${answers_now}" -gt "${had}" ]; then gained=", and the site has $((answers_now - had)) more answer sets than it holds"
        else gained=", and the site has no more answer sets than it holds"; fi
    fi
fi
if [ "${cut_off}" = yes ]; then
    say "a restore was cut off here before (the marker is there), so this one needs no fresh backup of the current state"
elif [ -n "${newest}" ] && [ "${newest_age}" -le 3600 ]; then
    say "the newest backup of the current state, ${newest}, is $(age "${newest_age}") old${gained}. It is the way back from this restore"
elif [ "${skip_safety}" -eq 1 ]; then
    if [ -n "${newest}" ]; then
        say "the newest backup of the current state, ${newest}, is $(age "${newest_age}") old${gained}. What was added since is lost with this restore (--skip-safety-backup)"
    else
        say "there is no backup of the current state. Everything that is on the site now is lost with this restore (--skip-safety-backup)"
    fi
else
    if [ -n "${newest}" ]; then
        err "the newest backup of the current state, ${newest}, is $(age "${newest_age}") old${gained}. Take a new one first (run-in-limesurvey.sh backup.sh), so that the restore can be undone. If the admin says that what was added since is not worth keeping, add --skip-safety-backup. Nothing was changed"
    else
        err "there is no backup of the current state. Take one first (run-in-limesurvey.sh backup.sh), so that the restore can be undone. If the admin says that nothing on the site now is worth keeping, add --skip-safety-backup. Nothing was changed"
    fi
    if [ ! -f "${config_dir}/security.php" ]; then
        err "security.php is missing here, and no backup can be taken without it. If only the keys are gone, put them back alone: restore.sh --keys-only --backup <name> (playbooks/restore-from-backup.md, \"Only the keys are missing or wrong\")"
    fi
    exit 1
fi

if [ "${go}" -ne 1 ]; then
    say "the checks passed. Nothing was changed. To restore, after the admin's yes, run this again with --yes-replace-current-data"
    exit 0
fi

# --- 2. The marker -----------------------------------------------------------------------------------------------------
log="restore-${stamp}.log"
(umask 077 && : > "${log}") || { err "could not start the log in clouve/backups"; exit 1; }
trap '' HUP PIPE
fail() {
    err "FAILED at step: $1. The restore is not finished, and LimeSurvey may not work. The marker clouve/backups/RESTORE-IN-PROGRESS stays. Run the same restore again, or restore the backup ${newest:-taken before this one}"
    exit 4
}
(umask 077 && printf '%s\nstarted %s UTC\n' "${name}" "${stamp}" > "${marker}.new" && mv -f -- "${marker}.new" "${marker}") || { err "could not write the marker"; exit 1; }
# On the disk before the database is touched: a container that is killed right now has to find it.
sync -f . 2> /dev/null || :
say "restore of ${name} started; the log is clouve/backups/restore-${stamp}.log"

# --- 3. Maintenance mode -----------------------------------------------------------------------------------------------
if [ "${have_config}" = yes ] && [ -f "${config_dir}/security.php" ] && [ "${tables_now:-0}" -gt 0 ]; then
    if ls_console setmaintenancemode hard-cli > /dev/null 2>&1; then
        say "maintenance mode on (hard-cli)"
    else
        say "the maintenance mode could not be turned on in the site as it is; going on"
    fi
fi

# --- 4. The encryption keys, before any other LimeSurvey code runs -------------------------------------------------------
put_config security.php 600 || fail "putting security.php (the encryption keys) in place"
say "security.php is the backup's now"
if [ "${have_config}" != yes ]; then
    put_config config.php 600 || fail "putting config.php in place"
    say "config.php is the backup's (this site had none)"
fi
if [ ! -f "${config_dir}/allowed_hosts.php" ] && [ -f "${backup_config}/allowed_hosts.php" ]; then
    put_config allowed_hosts.php 644 || fail "putting allowed_hosts.php in place"
fi

# --- 5. The database ---------------------------------------------------------------------------------------------------
# The dump is loaded over the tables that are there. It drops and makes each of its own tables in turn, so the
# database is never empty and LimeSurvey's settings table is gone only for the moment it is being replaced. The
# line put in below keeps the site locked from that moment on, also when the dump was taken without the lock: it
# sits inside the dump's own lock on the settings table, so nobody reads another value first.
settings="$(ls_table settings_global)"
say "loading the dump over the ${tables_now:-0} tables of ${db_name} (no table is dropped first)"
zcat "${dir}/database.sql.gz" | LC_ALL=C sed -e "/^LOCK TABLES \`${settings}\` WRITE;\$/,/^UNLOCK TABLES;\$/{/^UNLOCK TABLES;\$/i\\
REPLACE INTO \`${settings}\` (stg_name, stg_value) VALUES ('maintenancemode', 'hard-cli');
}" | "${db_client[@]}" "${db_name}" 2> "${site_work}/err"
codes=("${PIPESTATUS[@]}")
if [ "${codes[0]}" -ne 0 ] || [ "${codes[1]}" -ne 0 ] || [ "${codes[2]}" -ne 0 ]; then fail "loading the dump ($(head -c 300 "${site_work}/err"))"; fi
loaded="$(ls_sql "SELECT stg_value FROM ${settings} WHERE stg_name = 'DBVersion'" 2> /dev/null)"
[ "${loaded}" = "${backup_dbversion}" ] || fail "checking the loaded database (its version reads \"${loaded}\", the backup's is ${backup_dbversion})"
# Now the tables and views the dump does not hold.
extra_sql=''
extra=0
tables_after="$(ls_sql "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()" 2> "${site_work}/err")" || fail "listing the tables ($(head -c 200 "${site_work}/err"))"
while IFS=$'\t' read -r table kind; do
    [ -n "${table}" ] || continue
    if grep -qxF -- "${table}" "${site_work}/dump-tables"; then continue; fi
    case "${table}" in *'`'*) fail "removing the table ${table}, which the backup does not hold (its name cannot be quoted)" ;; esac
    if [ "${kind}" = VIEW ]; then extra_sql+="DROP VIEW IF EXISTS \`${table}\`;"$'\n'; else extra_sql+="DROP TABLE IF EXISTS \`${table}\`;"$'\n'; fi
    extra=$((extra + 1))
done <<< "${tables_after}"
if [ "${extra}" -gt 0 ]; then
    # On stdin: a site can have thousands of tables.
    printf 'SET FOREIGN_KEY_CHECKS = 0;\n%s' "${extra_sql}" | "${db_client[@]}" "${db_name}" 2> "${site_work}/err" || fail "removing the ${extra} tables the backup does not hold ($(head -c 200 "${site_work}/err"))"
fi
say "the database is the backup's ($(ls_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()") tables; ${extra} that the backup does not hold were removed)"

# --- 6. The files ------------------------------------------------------------------------------------------------------
# www-data unpacks, by name: only upload/ and the named plugin folders leave the archives, they belong to www-data
# whatever the archive says, and www-data can make no device file. Then the modes are made plain.
[ "$(stat -c %U "${ls_root}/upload")" = www-data ] || chown -h www-data:www-data "${ls_root}/upload" || fail "giving upload/ to www-data"
find "${ls_root}/upload" -xdev -mindepth 1 -delete 2> "${site_work}/err" || fail "emptying upload/ ($(head -c 200 "${site_work}/err"))"
as_www tar -xzf - -C "${ls_root}" --no-same-owner --no-same-permissions upload < "${dir}/upload.tar.gz" 2> "${site_work}/err" || fail "unpacking upload/ ($(head -c 200 "${site_work}/err"))"
# plain_modes FOLDER: no setuid, setgid or sticky bit, and nothing but files, folders and links, under FOLDER
plain_modes() {
    as_www find "$1" -xdev \( -type b -o -type c -o -type p -o -type s \) -delete < /dev/null \
        && as_www find "$1" -xdev \( -type f -o -type d \) -perm /7000 -exec chmod ug-s,-t {} + < /dev/null
}
plain_modes "${ls_root}/upload" || fail "making the modes in upload/ plain"
say "upload/ is the backup's"
restored_plugins=0
while IFS= read -r plugin; do
    [ -n "${plugin}" ] || continue
    case "${plugin}" in *[!A-Za-z0-9_-]*) continue ;; esac
    if [ -d "${package_plugins}" ] && [ -e "${package_plugins}/${plugin}" ]; then
        say "the plugin ${plugin} comes with this image's LimeSurvey, so the image's copy stays"
        continue
    fi
    as_www rm -rf -- "${ls_root}/plugins/${plugin}" < /dev/null || fail "removing the old copy of the plugin ${plugin}"
    as_www tar -xzf - -C "${ls_root}" --no-same-owner --no-same-permissions "plugins/${plugin}" < "${dir}/plugins.tar.gz" 2> "${site_work}/err" || fail "unpacking the plugin ${plugin}"
    plain_modes "${ls_root}/plugins/${plugin}" || fail "making the modes of the plugin ${plugin} plain"
    restored_plugins=$((restored_plugins + 1))
done < <(tar -tzf "${dir}/plugins.tar.gz" 2> /dev/null | sed -n 's|^plugins/\([^/]*\)/$|\1|p')

# --- 7. The database update, when the backup is older than the code ------------------------------------------------------
if [ "${backup_dbversion}" -lt "${code_dbversion}" ]; then
    say "updating the database from version ${backup_dbversion} to ${code_dbversion}"
    ls_console updatedb > "${site_work}/out" 2>&1 || fail "the database update ($(tail -n 3 "${site_work}/out" | tr '\n' ' '))"
    updated="$(ls_sql "SELECT stg_value FROM ${settings} WHERE stg_name = 'DBVersion'" 2> /dev/null)"
    incomplete="$(ls_sql "SELECT COUNT(*) FROM ${settings} WHERE stg_name = 'DBUpdateIncomplete'" 2> /dev/null)"
    if [ "${updated}" != "${code_dbversion}" ] || [ "${incomplete:-1}" != 0 ]; then fail "the database update (the database is at version ${updated:-?})"; fi
fi

# --- 8. Maintenance mode back, caches, keys ------------------------------------------------------------------------------
ls_console setmaintenancemode "${maintenance_after}" > "${site_work}/out" 2>&1 || fail "setting the maintenance mode to ${maintenance_after} ($(tail -n 2 "${site_work}/out" | tr '\n' ' '))"
ls_console flushassets > /dev/null 2>&1 || say "the caches could not be flushed; console.sh flushassets does it"
started="$(cd "${ls_root}" && sudo -n -u www-data php "${remote_dir}/lib/keys-check.php" < /dev/null 2> /dev/null)"
case "${started}" in
    *'"keys_ok":'*) ;;
    *) fail "starting LimeSurvey on the restored data ($(printf '%s' "${started}" | head -c 300))" ;;
esac
case "$(ls_keys_probe "${config_dir}/security.php")" in
    ok) say "the encryption keys read what the database holds encrypted" ;;
    untested) say "the database holds nothing encrypted to test the keys with" ;;
    *) fail "testing the encryption keys: they cannot read what the database holds encrypted" ;;
esac

# --- 9. Done -----------------------------------------------------------------------------------------------------------
rm -f -- "${marker}" || fail "removing the marker"
say "done: ${name} is restored (LimeSurvey ${code_version}, database version $(ls_sql "SELECT stg_value FROM ${settings} WHERE stg_name = 'DBVersion'" 2> /dev/null), ${restored_plugins} added plugin(s) put back). Maintenance mode is ${maintenance_after}"
