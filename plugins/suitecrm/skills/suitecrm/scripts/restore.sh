#!/usr/bin/env bash
# SuiteCRM skill: restore.sh
#
# Restores a backup that backup.sh made over this SuiteCRM: the database is replaced by the dump, and the
# customer's files by the archive. It runs inside the SuiteCRM container as root. From the agent, always send
# it as a job that outlives the SSH session:
#
#   run-in-suitecrm.sh restore.sh --backup <name>                                        the preview
#   run-in-suitecrm.sh --detach restore.sh --backup <name> --yes-replace-current-data    the restore
#   run-in-suitecrm.sh --status <job>                                                    how it went
#
# Without --yes-replace-current-data it changes nothing: it checks the backup and says what a restore would
# replace, how many campaign emails the backup's queue holds, and that the restore holds the scheduler
# (exit 64).
#
# What a restore replaces: every table of SuiteCRM's database (all records, users, roles, settings, the audit
# trail, everything entered since the backup is gone), and public/legacy/custom, public/legacy/upload, the
# pictures of email templates (public/legacy/cache/images), the added modules, media/, public/media/,
# extensions/, public/extensions/, config_override.php and the OAuth2 keys. A backup whose archive has no
# cache/images folder leaves the pictures that are there. What it keeps from this deployment, whatever the
# backup holds: the database's address, name, user and
# password in config.php, the site address (site_url and host_name), and .env.local. So a backup of one
# deployment can be restored onto another, and a restored SuiteCRM still answers at this deployment's address.
#
# Before it changes anything it checks, and refuses when a check fails (nothing is changed):
#   - no other backup or restore of this skill is running (exit 2). The script holds the skill's lock
#     (/run/clouve/suitecrm-skill/lock) from here to its end; the lock goes when the process ends, however it
#     ends, so a killed restore never blocks the next one;
#   - the backups folder, the backup and the image's state folder are real folders of root's that others
#     can't write in (exit 2; remote/guard.sh says why). www-data owns tmp/ and could plant its own;
#   - the backup has its COMPLETE stamp, its checksums hold and both files are whole (exit 3 if not);
#   - the archive holds only files, folders and links that stay inside SuiteCRM's tree: no device, no FIFO, no
#     absolute path, no .. path, no link that points outside (exit 3);
#   - the backup's SuiteCRM version is the installed one (exit 2): the archive has no code, and a database of
#     another version on this code would break SuiteCRM. The image upgrades and downgrades; this does not;
#   - there is a complete backup of the current state from the last 24 hours, other than the one being
#     restored (exit 2). The one exception is a restore that was cut off: then the restore marker is there, a
#     backup of the half-restored state is worth nothing, and the backup taken before the first restore is
#     the way back;
#   - the backup's files fit on the volume: their unpacked size, a block for each file and 50 MB, against the
#     free space plus what the folders it replaces hold now (exit 2).
#
# Order, once it starts:
#   1. Hold the scheduler: write tmp/clouve-backup/scheduler-held (root's, 600) unless it is there. The dump
#      brings the campaign email queue, the workflows and the scheduled reports back as they were when the
#      backup was made. Email that went out after that would go out a second time. So the hold stays when the
#      restore ends, until the user has seen what is waiting (scheduler.sh queued) and says to release it
#      (scheduler.sh release --yes-release).
#   2. Write the marker tmp/clouve-backup/restore-in-progress (root's). While it is there the skill's other
#      scripts refuse to run, the image runs no scheduler pass and no Messenger worker, and a container that
#      starts waits for it to go.
#   3. Drop every table and load the dump.
#   4. Replace the files. www-data's own tar unpacks the archive, with no owner and no set-user-ID or
#      set-group-ID bit taken from it, so everything it brings is www-data's. Root writes nothing into the
#      tree and removes nothing from it.
#   5. Put this deployment's database settings and address into the backup's config.php, by PHP that runs as
#      www-data, and move it into place in one step. config.php never holds another deployment's settings.
#   6. Set the OAuth2 private key to mode 600, clear SuiteCRM's caches, check that the tables are back, that
#      SuiteCRM reports the version and, when Apache runs, that the app answers.
#   7. Remove the marker (and RESTORE-IN-PROGRESS in the backups folder, the name an earlier version used).
# A failure after the start ends with exit 4 and keeps the marker and the hold, and the output names the step.
# Run the restore again, of this backup or of the one taken just before it. Running it again is always safe,
# also after the container restarted: when the container waits for the marker (PID 1 is not Apache then), the
# restore skips the check that the app answers, and the container finishes its start once the marker is gone.
# In a container that is still starting a restore does not start (exit 75): the start-up may be about to
# install or upgrade. It starts there only to finish a restore that was cut off, or when the image says that it
# is waiting for a person (its file /run/clouve-suitecrm-attention is there).
#
# People who are signed in during a restore can lose what they save in those seconds. Ask the user to have
# everyone stay out until it is done. A table that something else makes during the restore does not stop it
# (see the drop and the load below).
#
# The database password is read from SuiteCRM's config.php, by PHP that runs as www-data, and given to the
# client in an options file of mode 600 in a folder of this run's own under /run/clouve/suitecrm-skill (root's,
# not on the volume), removed at the end. It is never in a command line or in the output.
#
# Exit codes: 0 restored; 64 usage, or the preview; 1 SuiteCRM's settings or database can't be read; 2 a check
# refused it (another version, no fresh backup, not enough free space, another backup or restore is running, a
# folder that is not trusted); 3 no such backup, or it is not complete, not whole, or holds what a backup never
# holds; 4 the restore failed after it began (the marker and the hold are kept); 75 the image is installing or
# upgrading, or the container is still starting or waiting and no restore was cut off.

set -uo pipefail
set +x
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${here}/remote/guard.sh" || exit 1

msg() { printf '[suitecrm/restore] %s\n' "$*" >&2; }

usage() {
    cat <<'USAGE'
Usage (inside the SuiteCRM container, as root; from the agent, through run-in-suitecrm.sh):
  restore.sh --backup <name>                               preview: checks the backup, changes nothing
  restore.sh --backup <name> --yes-replace-current-data    restores it over this SuiteCRM

Replaces the database and the customer's files with the backup's, and keeps this deployment's database
settings, site address and .env.local. Needs a backup of the same SuiteCRM version, and a fresh backup of
the current state. It holds the scheduler and leaves it held: the backup's campaign email queue and scheduled
work come back, so the user looks at scheduler.sh queued and then says scheduler.sh release --yes-release.
One backup or restore runs at a time. A restore that was cut off is finished by running it again.

Exit codes: 0 restored; 64 usage or the preview; 1 settings or database unreadable; 2 refused (another
version, no fresh backup, not enough space, another backup or restore is running, a folder that is not
trusted); 3 the backup is missing, incomplete, damaged or holds what a backup never holds; 4 failed after it
began; 75 SuiteCRM is being installed or upgraded, or its container is still starting or waiting.
USAGE
}

if [ "$(id -u)" -ne 0 ]; then
    msg "this runs as root inside the SuiteCRM container; send it with run-in-suitecrm.sh restore.sh"
    exit 64
fi

name=''
yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --backup)
            [[ ${2:-} =~ ^[0-9]{8}-[0-9]{6}$ ]] || { msg "--backup takes a backup's name, such as 20261112-101500 (backup.sh --list shows them)"; exit 64; }
            name="$2"
            shift 2
            ;;
        --yes-replace-current-data) yes=1; shift ;;
        *) msg "unknown argument: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
    esac
done
[ -n "${name}" ] || { msg "no backup named"; usage >&2; exit 64; }

# count_noun N SINGULAR PLURAL: "1 campaign email", "3 campaign emails"
count_noun() { if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %s' "$1" "$3"; fi; }

# One backup or restore at a time. The lock comes first, so that a second run never takes the marker of a
# restore that is still running for one that was cut off.
if [ "${yes}" -eq 1 ]; then
    sc_lock_take "restore of ${name}"
    case $? in
        0) ;;
        1)
            msg "$(sc_lock_refusal)"
            exit 2
            ;;
        *)
            msg "could not make the lock in ${sc_run_dir}. Nothing was changed."
            exit 1
            ;;
    esac
    # entry.sh has asked this already. It is asked again for a run started by hand in the container.
    reason="$(sc_busy_reason restore-ok)"
    if [ -n "${reason}" ]; then
        msg "refused: ${reason} Nothing was changed."
        exit 75
    fi
fi

# The backups folder and the backup: checked before anything in them is trusted. From here on the script is
# inside the folder and every path into it is relative to ".".
case "$(sc_dir_state "${sc_skill_dir}")" in
    absent)
        msg "there is no backup named ${name}. backup.sh --list shows the backups."
        exit 3
        ;;
    untrusted)
        msg "refused: $(sc_untrusted_message "${sc_skill_dir}")"
        exit 2
        ;;
esac
if ! sc_enter_trusted "${sc_skill_dir}"; then
    msg "refused: $(sc_untrusted_message "${sc_skill_dir}")"
    exit 2
fi
dir="./${name}"
if [ ! -d "${dir}" ] && [ ! -L "${dir}" ]; then
    msg "there is no backup named ${name}. backup.sh --list shows the backups."
    exit 3
fi
if ! sc_root_folder "${dir}"; then
    msg "refused: $(sc_untrusted_message "${sc_skill_dir}/${name}")"
    exit 2
fi
if [ ! -f "${dir}/COMPLETE" ] || [ -L "${dir}/COMPLETE" ]; then
    msg "the backup ${name} has no COMPLETE stamp: it was never finished, and is not restored."
    exit 3
fi
damaged() {
    msg "the backup ${name} is damaged: ${1:-a checksum does not hold, or a file is not whole}. It is not restored. Nothing was changed."
    exit 3
}
for f in db.sql.gz state.tar.gz manifest.txt SHA256SUMS; do
    if [ ! -f "${dir}/${f}" ] || [ -L "${dir}/${f}" ]; then damaged "${f} is not there as a plain file"; fi
done
if ! (cd "${dir}" && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1) || ! gzip -t "${dir}/db.sql.gz" 2> /dev/null \
    || ! gzip -t "${dir}/state.tar.gz" 2> /dev/null; then
    damaged
fi

cleanup() {
    if [ -n "${sc_run_tmp}" ]; then rm -rf -- "${sc_run_tmp}"; fi
}
trap cleanup EXIT
sc_run_tmp_make || { msg "could not make a work folder in ${sc_run_dir}. Nothing was changed."; exit 1; }

# One pass over the dump: its closing line, the tables it holds, and the rows of the campaign email queue.
# A row is counted at each opening bracket outside a quoted value, from the INSERT's VALUES to its closing
# semicolon. The dump tool writes the rows on the INSERT's own line or one on each line after it.
scan="$(zcat "${dir}/db.sql.gz" 2> /dev/null | LC_ALL=C awk -v tables="${sc_run_tmp}/tables.txt" '
    function count_rows(s,   i, n, c) {
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (quoted) {
                if (c == "\\") i++
                else if (c == "\047") quoted = 0
            } else if (c == "\047") quoted = 1
            else if (c == "(") { if (depth == 0) rows++; depth++ }
            else if (c == ")") depth--
            else if (c == ";" && depth == 0) { inside = 0; return }
        }
    }
    { last[NR % 5] = $0 }
    /^DROP TABLE IF EXISTS `/ {
        t = $0
        sub(/^DROP TABLE IF EXISTS `/, "", t)
        sub(/`;$/, "", t)
        print t > tables
        next
    }
    /^INSERT INTO `emailman` / {
        at = index($0, " VALUES")
        if (at) {
            inside = 1
            depth = 0
            quoted = 0
            count_rows(substr($0, at + 7))
        }
        next
    }
    inside { count_rows($0) }
    END {
        whole = 0
        for (k in last) if (last[k] ~ /Dump completed/) whole = 1
        printf "%d %d\n", rows, whole
    }')" || scan=''
read -r queue_rows dump_whole <<< "${scan}"
if [ "${dump_whole:-0}" != 1 ]; then damaged "the database dump has no closing line"; fi
[ -f "${sc_run_tmp}/tables.txt" ] || : > "${sc_run_tmp}/tables.txt"

# The archive's listing: what it holds, and how large it is unpacked. Names come from the plain listing and
# kinds, sizes and link targets from the long one; both have one line for each member, in the same order.
if ! tar -tzf "${dir}/state.tar.gz" > "${sc_run_tmp}/names.txt" 2> /dev/null \
    || ! tar --numeric-owner -tvzf "${dir}/state.tar.gz" > "${sc_run_tmp}/long.txt" 2> /dev/null \
    || [ "$(wc -l < "${sc_run_tmp}/names.txt")" != "$(wc -l < "${sc_run_tmp}/long.txt")" ]; then
    damaged "the archive of the files can't be listed"
fi
listing="$(LC_ALL=C awk '
    function outside(path) { return path ~ /^\// || path ~ /(^|\/)\.\.(\/|$)/ }
    NR == FNR { name[FNR] = $0; next }
    {
        kind = substr($0, 1, 1)
        nm = name[FNR]
        if (kind != "-" && kind != "d" && kind != "l" && kind != "h") {
            what = "a member that is not a file, a folder or a link"
            if (kind == "c" || kind == "b") what = "a device"
            if (kind == "p") what = "a FIFO"
            print "bad " what ": " nm
            exit
        }
        if (nm ~ /^\//) { print "bad an absolute path: " nm; exit }
        if (nm ~ /(^|\/)\.\.(\/|$)/) { print "bad a path with .. in it: " nm; exit }
        if (kind == "l") {
            at = index($0, " " nm " -> ")
            if (!at) { print "bad a link whose target can not be read: " nm; exit }
            target = substr($0, at + length(nm) + 5)
            if (target ~ /^\//) { print "bad a link that points outside the tree: " nm " -> " target; exit }
            depth = 0
            parts = split(nm, piece, "/")
            for (i = 1; i < parts; i++) if (piece[i] != "" && piece[i] != ".") depth++
            parts = split(target, piece, "/")
            for (i = 1; i <= parts; i++) {
                if (piece[i] == "..") { depth--; if (depth < 0) { print "bad a link that points outside the tree: " nm " -> " target; exit } }
                else if (piece[i] != "" && piece[i] != ".") depth++
            }
        }
        if (kind == "h") {
            at = index($0, " " nm " link to ")
            if (!at) { print "bad a link whose target can not be read: " nm; exit }
            target = substr($0, at + length(nm) + 10)
            if (outside(target)) { print "bad a link that points outside the tree: " nm " -> " target; exit }
        }
        if (kind == "-") bytes += $3
        members++
    }
    END { printf "ok %.0f %d\n", bytes, members }' "${sc_run_tmp}/names.txt" "${sc_run_tmp}/long.txt" | head -n 1)"
case "${listing}" in
    'ok '*) read -r _ unpacked_bytes members <<< "${listing}" ;;
    'bad '*)
        msg "the backup ${name} is not restored: its archive holds something a backup never holds (${listing#bad }). An archive holds files, folders and links inside SuiteCRM's tree only. Nothing was changed."
        exit 3
        ;;
    *) damaged "the archive of the files can't be read" ;;
esac
[[ ${unpacked_bytes} =~ ^[0-9]+$ ]] && [[ ${members} =~ ^[0-9]+$ ]] || damaged "the archive of the files can't be read"

if ! sc_as_www test -f "${sc_root}/public/legacy/config.php"; then
    msg "SuiteCRM's config.php is not there"
    exit 1
fi
backup_version="$(sed -n 's/^suitecrm_version: //p' "${dir}/manifest.txt" | head -n 1)"
# VERSION is the web user's file: it is read as www-data and has to look like a version.
code_version="$(sc_as_www head -c 40 "${sc_root}/VERSION" 2> /dev/null | tr -d '[:space:]')"
[[ ${code_version} =~ ^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$ ]] || code_version=''
if [ -z "${backup_version}" ] || [ "${backup_version}" != "${code_version}" ]; then
    msg "refused: the backup ${name} is of SuiteCRM ${backup_version:-an unknown version} and this install is ${code_version:-unknown}. A backup holds no code, so it restores onto the same version only. Nothing was changed."
    exit 2
fi

# This deployment's database settings, for the database client. PHP reads config.php as www-data, never as
# root: the file is the web user's.
# shellcheck disable=SC2016  # PHP's variables
settings="$(sc_as_www php -r 'include "/var/www/html/public/legacy/config.php"; $d = $sugar_config["dbconfig"] ?? []; foreach (["db_host_name", "db_port", "db_user_name", "db_name", "db_password"] as $k) { echo str_replace("\n", "", (string) ($d[$k] ?? "")), "\n"; } echo str_replace("\n", "", (string) ($sugar_config["site_url"] ?? "")), "\n";' 2> /dev/null)" || settings=''
{
    IFS= read -r db_host
    IFS= read -r db_port
    IFS= read -r db_user
    IFS= read -r db_name
    IFS= read -r db_pass
    IFS= read -r site_url
} <<< "${settings}"
if [ -z "${db_host}" ] || [ -z "${db_user}" ] || [ -z "${db_name}" ]; then
    msg "could not read the database settings from SuiteCRM's config.php. Nothing was changed."
    exit 1
fi

cnf="${sc_run_tmp}/client.cnf"
err="${sc_run_tmp}/restore.err"
(umask 077 && : > "${cnf}") || exit 1
{
    printf '[client]\n'
    printf 'user=%s\n' "${db_user}"
    # In an options file a value in double quotes takes \\ and \" as escapes.
    esc="${db_pass//\\/\\\\}"
    printf 'password="%s"\n' "${esc//\"/\\\"}"
    printf 'host=%s\n' "${db_host}"
    printf 'port=%s\n' "${db_port:-3306}"
} > "${cnf}"

sql() { mysql --defaults-extra-file="${cnf}" -N -B "${db_name}" -e "$1" 2> /dev/null; }
if ! now_tables="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")" || [ -z "${now_tables}" ]; then
    msg "could not reach SuiteCRM's database with the settings in config.php. Nothing was changed."
    exit 1
fi
count_of() { sql "SELECT COUNT(*) FROM $1 WHERE deleted = 0" || echo '?'; }

# Space. The restore empties the folders the archive brings and then unpacks it, so what counts is the free
# space plus what those folders hold now, against the unpacked size, a block for each member and 50 MB.
replaced=()
for p in public/legacy/custom public/legacy/upload public/legacy/cache/images media public/media uploads public/media-upload extensions public/extensions; do
    if grep -qE "^(\./)?${p}(/|\$)" "${sc_run_tmp}/names.txt"; then replaced+=("${p}"); fi
done
# The pictures of email templates: in the archive, or not (SuiteCRM had no such folder when it was made)
pictures=no
case " ${replaced[*]-} " in *' public/legacy/cache/images '*) pictures=yes ;; esac
held_now=0
if [ "${#replaced[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016  # $1 and $@ are for the inner bash
    held_now="$(sc_as_www bash -c 'cd "$1" && shift && du -sB1 -c -- "$@" 2> /dev/null | tail -n 1 | cut -f1' _ "${sc_root}" "${replaced[@]}")"
    [[ ${held_now} =~ ^[0-9]+$ ]] || held_now=0
fi
free="$(df -PB1 "${sc_root}" | awk 'NR == 2 { print $4 }')"
[[ ${free} =~ ^[0-9]+$ ]] || free=0
need=$((unpacked_bytes + members * 4096 + 52428800))
fits=1
if [ $((free + held_now)) -lt "${need}" ]; then fits=0; fi
space_text="the backup's files need about $((need / 1048576)) MB unpacked; $((free / 1048576)) MB are free on the volume, and the folders the restore replaces hold $((held_now / 1048576)) MB now"

if [ "${yes}" -ne 1 ]; then
    echo "Preview of a restore of the backup ${name}. Nothing was changed."
    echo
    sed -n 's/^made_utc: /  made (UTC):        /p; s/^suitecrm_version: /  SuiteCRM version:  /p; s/^site_url: /  from the address:  /p; s/^tables: /  tables:            /p; s/^files_in_archive: /  files:             /p' "${dir}/manifest.txt"
    echo
    echo "A restore replaces everything in SuiteCRM's database: now ${now_tables} tables, $(count_of accounts) accounts, $(count_of contacts) contacts, $(count_of leads) leads, $(count_of opportunities) opportunities and $(count_of users) users. Whatever was entered or changed since the backup is gone."
    echo "It also replaces custom/, upload/, the added modules, media, extensions, config_override.php and the OAuth2 keys with the backup's."
    if [ "${pictures}" = yes ]; then
        echo "The pictures of email templates (public/legacy/cache/images) are replaced with the backup's too."
    else
        echo "This backup holds no pictures of email templates, so the pictures that are there now stay."
    fi
    echo "It keeps this deployment's database settings, its address (${site_url:-not set}) and .env.local."
    echo
    echo "$(count_noun "${queue_rows}" "campaign email was" "campaign emails were") waiting in the queue when the backup was made. A restore brings that queue back as it was, and the workflows and scheduled reports with it: email that went out since then would go out a second time."
    echo "So the restore holds the scheduler (${sc_scheduler_hold}) and leaves it held. Nothing scheduled runs until the user has seen what is waiting (scheduler.sh queued) and says to release it (scheduler.sh release --yes-release)."
    echo
    if [ "${fits}" -eq 1 ]; then
        echo "Space: ${space_text}."
    else
        echo "Space: NOT enough. A restore would be refused: ${space_text}."
    fi
    echo
    echo "To restore: take a backup of the current state first (run-in-suitecrm.sh backup.sh), then, after the user's clear yes,"
    echo "  run-in-suitecrm.sh --detach restore.sh --backup ${name} --yes-replace-current-data"
    exit 64
fi

# The image's state folder, where the hold and the marker go
if [ "$(sc_dir_state "${sc_image_dir}")" = untrusted ]; then
    msg "refused: $(sc_untrusted_message "${sc_image_dir}")"
    exit 2
fi
# in_state_dir CMD...: runs CMD inside the image's state folder, once it is known to be root's
in_state_dir() { (sc_enter_trusted "${sc_image_dir}" && "$@"); }

cut_off=0
if in_state_dir test -e ./restore-in-progress || [ -e ./RESTORE-IN-PROGRESS ]; then cut_off=1; fi
if [ "${cut_off}" -eq 0 ]; then
    fresh="$(find . -mindepth 2 -maxdepth 2 -name COMPLETE -type f -mmin -1440 ! -path "./${name}/COMPLETE" 2> /dev/null | head -n 1)"
    if [ -z "${fresh}" ]; then
        if [ "$(sc_pid1)" = apache2 ]; then
            msg "refused: there is no complete backup of the current state from the last 24 hours, other than the one being restored. Take one first (run-in-suitecrm.sh backup.sh), so that this restore can be undone. Nothing was changed."
        else
            msg "refused: there is no complete backup of the current state from the last 24 hours, other than the one being restored, and none can be taken while SuiteCRM's container waits without Apache. Without one this restore could not be undone, so it is a job for Clouve support. Nothing was changed."
        fi
        exit 2
    fi
fi
if [ "${fits}" -ne 1 ]; then
    msg "refused: not enough free space for this restore: ${space_text}. Nothing was changed. Old backups can be removed by name (backup.sh --list, then --remove), or the user moves to a larger plan."
    exit 2
fi

step=''
failed() {
    msg "the restore FAILED at this step: ${step}. ${1:-}"
    msg "SuiteCRM may be half restored. The marker ${sc_restore_marker} is kept, the skill's other scripts refuse to run until a restore finishes, and the scheduler stays held. Run the restore again, of ${name} or of the backup taken just before it (playbooks/restore-from-backup.md)."
    exit 4
}
# A dropped session must not stop a restore half-way.
trap '' HUP PIPE

# write_hold: the scheduler's hold file, unless one is there (the image's own, or an earlier restore's)
# shellcheck disable=SC2329  # called through in_state_dir, as write_marker is
write_hold() {
    if [ -e ./scheduler-held ] || [ -L ./scheduler-held ]; then return 0; fi
    printf 'held by the restore of the backup %s, %s UTC. scheduler.sh release --yes-release lets it go.\n' "${name}" "$(date -u '+%Y-%m-%d %H:%M:%S')" > ./scheduler-held && chmod 600 ./scheduler-held
}
# shellcheck disable=SC2329
write_marker() {
    printf 'restore of %s started %s UTC\n' "${name}" "$(date -u '+%Y-%m-%d %H:%M:%S')" >> ./restore-in-progress && chmod 600 ./restore-in-progress
}
if ! sc_make_root_dir "${sc_image_dir}"; then
    msg "refused: could not make ${sc_image_dir} as a folder of root's, so the scheduler can't be held and the restore can't be marked. Nothing was changed."
    exit 2
fi
if ! in_state_dir write_hold; then
    msg "refused: could not write ${sc_scheduler_hold}, so the scheduler can't be held. Nothing was changed."
    exit 2
fi
if ! in_state_dir write_marker; then
    msg "refused: could not write ${sc_restore_marker}. Nothing was changed, but the scheduler is held now: scheduler.sh release --yes-release lets it go."
    exit 2
fi
echo "Restoring the backup ${name} over this SuiteCRM (${now_tables} tables now). The scheduler is held."

# The image's Messenger worker and scheduler may still be running a job when a restore starts, and the worker
# makes its table again whenever it finds it gone. So the drop is repeated until nothing is left or three
# passes are done, a table that is still there then is left to the dump (which drops and makes again every
# table it holds), and a load that such a table stops is tried again from the drop, three times at most.
drop_all() {
    local pass drops
    for pass in 1 2 3; do
        drops="$(sql "SELECT CONCAT('DROP ', IF(table_type = 'VIEW', 'VIEW', 'TABLE'), ' IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = DATABASE()")" || return 1
        [ -n "${drops}" ] || return 0
        printf 'SET FOREIGN_KEY_CHECKS = 0;\n%s\n' "${drops}" | mysql --defaults-extra-file="${cnf}" "${db_name}" 2> /dev/null || return 1
    done
    return 0
}
loaded=0
for attempt in 1 2 3; do
    step="dropping the current tables"
    drop_all || failed "The database refused to drop a table."
    step="loading the database dump"
    zcat "${dir}/db.sql.gz" | mysql --defaults-extra-file="${cnf}" "${db_name}" 2> "${err}"
    status=("${PIPESTATUS[@]}")
    if [ "${status[0]}" -eq 0 ] && [ "${status[1]}" -eq 0 ]; then
        loaded=1
        break
    fi
    echo "The load stopped (try ${attempt} of 3): $(head -n 1 "${err}" | cut -c1-200)"
done
[ "${loaded}" -eq 1 ] || failed "$(head -n 2 "${err}" | tr '\n' ' ')"
# Tables that are not the backup's: something else made them, and they are left as they are.
extra="$(comm -13 <(LC_ALL=C sort -u "${sc_run_tmp}/tables.txt") \
    <(sql "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE()" | LC_ALL=C sort -u) | tr '\n' ' ')"
if [ -n "${extra// /}" ]; then
    echo "Note: these tables are in the database and not in the backup, and were left as they are: ${extra}"
fi
want_tables="$(sed -n 's/^tables: //p' "${dir}/manifest.txt" | head -n 1)"
got_tables="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")"
if ! [[ ${got_tables} =~ ^[0-9]+$ ]] || [ "${got_tables}" -lt "${want_tables:-1}" ]; then
    failed "The database has ${got_tables:-no} tables after the load and the backup had ${want_tables}."
fi

step="replacing the files"
# The folders the archive brings are emptied first, so that a file made after the backup does not survive it.
# www-data removes and unpacks: the tree is its own, and root follows no link in it.
if [ "${#replaced[@]}" -gt 0 ]; then
    # shellcheck disable=SC2016  # $1 and $@ are for the inner bash
    sc_as_www bash -c 'cd "$1" && shift && rm -rf -- "$@"' _ "${sc_root}" "${replaced[@]}" 2> "${err}" || failed "$(head -n 2 "${err}" | tr '\n' ' ')"
fi
# config.php is written in the next step, and .env.local stays this deployment's when it has one.
exclude=(--anchored --exclude=public/legacy/config.php --exclude=./public/legacy/config.php)
if sc_as_www test -f "${sc_root}/.env.local"; then exclude+=(--exclude=.env.local --exclude=./.env.local); fi
# No owner and no set-user-ID or set-group-ID bit is taken from the archive: what www-data unpacks is
# www-data's, with the archive's modes less the umask. A folder that is there already keeps its mode, and a new
# one takes the set-group-ID bit of the folder it is made in, as every folder of the image's tree has it.
# (tar's --no-overwrite-dir is not used: it puts an existing folder's mode back without that bit.)
# shellcheck disable=SC2016  # $1 and $@ are for the inner bash
sc_as_www bash -c 'umask 022; cd "$1" && shift && exec tar -xzf - --no-same-owner --no-same-permissions "$@"' _ "${sc_root}" "${exclude[@]}" \
    < "${dir}/state.tar.gz" 2> "${err}" || failed "$(head -n 2 "${err}" | tr '\n' ' ')"
# shellcheck disable=SC2016  # $1 is for the inner bash
sc_as_www bash -c 'cd "$1" || exit 1
    rm -f public/legacy/config_si.php
    for p in public/legacy/custom public/legacy/upload public/legacy/cache/images public/legacy/modules media public/media uploads public/media-upload extensions public/extensions; do
        [ -d "$p" ] && [ ! -L "$p" ] || continue
        find "$p" -xdev -type f -perm /6000 -exec chmod u-s,g-s {} +
        # The tree has the set-group-ID bit on its folders when its top folder has it.
        if [ -g . ]; then find "$p" -xdev -type d ! -perm -2000 -exec chmod g+s {} +; fi
    done' _ "${sc_root}" 2> "${err}" || failed "$(head -n 2 "${err}" | tr '\n' ' ')"

step="writing this deployment's settings into config.php"
# The backup's config.php comes out of the archive as text, on the standard input of PHP that runs as
# www-data. That PHP takes this deployment's database settings and address from the config.php that is there,
# puts them into the backup's settings and moves the result into place in one step. So no password passes
# through root here, and config.php names this deployment's database at every moment.
member="$(grep -m 1 -xE '(\./)?public/legacy/config\.php' "${sc_run_tmp}/names.txt" || true)"
if [ -n "${member}" ]; then
    # shellcheck disable=SC2016  # PHP's variables
    tar -xzOf "${dir}/state.tar.gz" "${member}" 2> /dev/null | sc_as_www php -r '
        $file = "/var/www/html/public/legacy/config.php";
        foreach (glob(dirname($file) . "/config.restore-*.php") ?: [] as $old) { @unlink($old); }
        $text = stream_get_contents(STDIN);
        if ($text === false || trim($text) === "") { exit(1); }
        $read = function (string $code) { $sugar_config = null; eval("?>" . $code); return is_array($sugar_config) ? $sugar_config : null; };
        $here = $read((string) file_get_contents($file));
        $new = $read($text);
        if ($here === null || $new === null) { exit(1); }
        foreach (["db_host_name", "db_port", "db_user_name", "db_name", "db_password"] as $k) {
            $new["dbconfig"][$k] = $here["dbconfig"][$k] ?? "";
        }
        foreach (["site_url", "host_name"] as $k) {
            if (($here[$k] ?? "") !== "") { $new[$k] = $here[$k]; }
        }
        ksort($new);
        $out = "<?php\n// created: " . gmdate("Y-m-d H:i:s") . "\n\$sugar_config = " . var_export($new, true) . ";\n";
        $mode = fileperms($file) & 0777;
        $tmp = dirname($file) . "/config.restore-" . getmypid() . ".php";
        if (file_put_contents($tmp, $out) === false || !chmod($tmp, $mode) || !rename($tmp, $file)) { @unlink($tmp); exit(1); }
    ' 2> "${err}"
    status=("${PIPESTATUS[@]}")
    if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then failed "config.php could not be rewritten. $(head -n 2 "${err}" | tr '\n' ' ')"; fi
fi

step="closing the OAuth2 private key"
# shellcheck disable=SC2016  # $1 is for the inner bash
sc_as_www bash -c 'f="$1/public/legacy/Api/V8/OAuth2/private.key"; if [ -f "$f" ] && [ ! -L "$f" ]; then chmod 600 "$f"; fi' _ "${sc_root}" || failed

step="clearing SuiteCRM's caches"
# cache/images holds the pictures of the customer's email templates. The archive has just put the backup's
# there, or, with a backup that holds none, the ones that were there are kept: either way it stays.
# shellcheck disable=SC2016  # $1 is for the inner bash
sc_as_www bash -c 'cd "$1" && find public/legacy/cache -mindepth 1 -maxdepth 1 ! -name index.html ! -name images -exec rm -rf {} + 2> /dev/null; cd "$1" && exec php bin/console cache:clear --no-interaction' _ "${sc_root}" > /dev/null 2>&1 || failed "bin/console cache:clear did not run."

step="checking the result"
# shellcheck disable=SC2016  # $1 is for the inner bash
version="$(sc_as_www bash -c 'cd "$1" && exec php bin/console suitecrm:version --no-interaction' _ "${sc_root}" 2> /dev/null | tr -d '[:space:]')"
[ "${version}" = "${code_version}" ] || failed "SuiteCRM reports the version \"${version}\", not ${code_version}."
pid1="$(sc_pid1)"
if [ "${pid1}" = apache2 ]; then
    if command -v curl > /dev/null 2>&1; then
        answer="$(curl -fsS -m 30 http://localhost/session-status 2> /dev/null || true)"
        case "${answer}" in
            *'"installed":true'*) ;;
            *) failed "SuiteCRM does not answer as an installed app on http://localhost/session-status." ;;
        esac
    fi
fi

# What is waiting as of the backup, for the closing lines
q() { local n; n="$(sql "$1")" && [[ ${n} =~ ^[0-9]+$ ]] && printf '%s' "${n}" || printf '?'; }
q_waiting="$(q "SELECT COUNT(*) FROM emailman WHERE deleted = 0")"
q_due="$(q "SELECT COUNT(*) FROM emailman WHERE deleted = 0 AND (send_date_time IS NULL OR send_date_time <= UTC_TIMESTAMP())")"
q_flows="$(q "SELECT COUNT(*) FROM aow_workflow WHERE deleted = 0 AND status = 'Active' AND (run_when IN ('Always', 'In_Scheduler', 'Create') OR flow_run_on = 'All_Records')")"
q_reports="$(q "SELECT COUNT(*) FROM aor_scheduled_reports WHERE deleted = 0 AND status = 'active'")"

step="removing the marker"
in_state_dir rm -f ./restore-in-progress || failed
rm -f ./RESTORE-IN-PROGRESS
echo "Restore of ${name} is complete: ${got_tables} tables, $(count_of accounts) accounts, $(count_of contacts) contacts, $(count_of leads) leads, $(count_of opportunities) opportunities, $(count_of users) users."
echo "SuiteCRM keeps this deployment's database settings and its address (${site_url:-not set}). People have to sign in again."
echo "As of the backup, this is waiting: $(count_noun "${q_waiting}" "campaign email" "campaign emails") in the queue (${q_due} due now), $(count_noun "${q_flows}" "active workflow that runs" "active workflows that run") on a schedule or on all records, and $(count_noun "${q_reports}" "active scheduled report" "active scheduled reports")."
echo "The scheduler is held (${sc_scheduler_hold} is there), so none of that has started. Email that went out after the backup was made would go out a second time. Show the user what is waiting (scheduler.sh queued). The scheduler stays held until the user says to release it: scheduler.sh release --yes-release."
if [ "${pid1}" != apache2 ]; then
    echo "SuiteCRM's container was waiting for this restore (PID 1 is ${pid1:-unknown}, not Apache), so whether the app answers was not checked. The container finishes its start by itself now that the marker is gone: upgrade-state.sh shows the state, and verify-health.sh checks SuiteCRM once it is up."
fi
echo "Check it with verify-health.sh, and run repair.sh (a dry run) to see that the database and the files match."
exit 0
