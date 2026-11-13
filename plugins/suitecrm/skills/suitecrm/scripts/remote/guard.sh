# shellcheck shell=bash
# SuiteCRM skill: remote/guard.sh (sourced inside the SuiteCRM container by entry.sh, admin.sh, backup.sh and
# restore.sh; never run on the agent)
#
# One place for the paths this skill shares with Clouve's image, for what root trusts in SuiteCRM's tree, for
# the lock that lets one backup or restore run at a time, and for the question every script asks before it
# touches SuiteCRM: is the image installing or upgrading right now, or is a restore under way?
#
# The image's stamp for a new install is /var/www/html/.clouve-install-in-progress (root's): it is there from
# the moment an install starts until it has finished. The rest of its state is in
# /var/www/html/tmp/clouve-backup (root's, mode 700):
#   state                    name=value lines about an upgrade: phase (backup, upgrade, restore or failed, or
#                            as-is while staff finish one by hand), from, to, build, attempts, and reason
#                            once it failed
#   upgrade-failed           the last upgrade failed and the old version was put back
#   scheduler-held           the scheduler loop is held until someone releases it. This skill's restore
#                            writes it. (The image holds an install that never ran a scheduled job through a
#                            setting of its own in config_override.php, which scheduler.sh reads.)
#   restore-in-progress      this skill's restore is under way, or was cut off. restore.sh writes it before it
#                            changes anything and removes it when the restore is complete. While it is there the
#                            image runs no scheduler pass and no Messenger worker, and a container that starts
#                            waits for it to go, with only its stand-in page and the sshd up
#   <from>-to-<to>/          the backup the last upgrade kept
# Older names for the same things (install-in-progress in that folder, upgrade-in-progress) are read too.
# This skill keeps its backups next to it, in /var/www/html/tmp/clouve-skill-backups (root's, mode 700).
# tmp/ is on SuiteCRM's upgrade keep-list and Apache does not serve it (the web root is public/).
# What a run needs for itself (the lock, the database options file, error text) is in
# /run/clouve/suitecrm-skill (root's, mode 700), which is not on the volume and which www-data can't reach.
#
# sc_busy_reason prints why SuiteCRM must not be touched, or nothing when it is fine:
#   - an install stamp is there;
#   - the upgrade's phase is backup, upgrade, restore or as-is, or its in-progress marker is there;
#   - a restore marker is there (a restore is under way, or was cut off);
#   - PID 1 is not Apache: the image's start-up runs installs and upgrades before it becomes Apache, and it
#     waits there, without Apache, when a restore was cut off or the site is between two versions. The image
#     marks which wait it is in with an empty file of root's in /run, which its stand-in page reads:
#     /run/clouve-suitecrm-restoring while it waits for a restore's marker to go, and
#     /run/clouve-suitecrm-attention when it found a site that it must not start and a person has to repair.
# A phase of "failed" is not busy: the old version is running, and upgrade-state.sh reports it.
# Nothing in a state folder that is not trusted is read or believed: no phase, no marker, no hold. Such a
# folder is no reason by itself (the image goes on serving SuiteCRM too), and upgrade-state.sh and
# verify-health.sh report it. A restore that is running is still seen then, through its lock.
#
# Everything here reads, but for sc_make_root_dir, the lock and the run's own folder. sudo -n is used because
# the folders are root's and clouve-ops has passwordless sudo.

sc_root=/var/www/html
sc_image_dir="${sc_root}/tmp/clouve-backup"
sc_skill_dir="${sc_root}/tmp/clouve-skill-backups"
# The restore marker is in the image's state folder, where the image reads it too: while it is there the
# image's scheduler loop and Messenger worker don't run, and a container that starts waits for it to go.
sc_restore_marker="${sc_image_dir}/restore-in-progress"
# The name an earlier version of this skill used. It is still read, never written.
sc_restore_marker_old="${sc_skill_dir}/RESTORE-IN-PROGRESS"
# The file that holds the image's scheduler loop
# shellcheck disable=SC2034  # read by entry.sh and restore.sh
sc_scheduler_hold="${sc_image_dir}/scheduler-held"
# Root's work folder for backup.sh and restore.sh, and the lock in it
sc_run_dir=/run/clouve/suitecrm-skill
sc_lock_file="${sc_run_dir}/lock"

# sc_sudo CMD...: runs CMD as root (directly when already root)
sc_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}

# sc_as_www CMD...: for root. Runs CMD as www-data, the owner of SuiteCRM's tree. Root never includes or runs a
# file www-data can write, and never writes, removes or unpacks in that tree itself: a link planted there
# would take root's hand somewhere else. The command starts in /, because root's own folders are closed to
# www-data, and setpriv becomes the command, so the exit status is the command's own. The descriptors of the
# lock and of the run's folder are closed for it.
sc_as_www() {
    (
        cd / || exit 1
        if command -v setpriv > /dev/null 2>&1; then
            exec setpriv --reuid=www-data --regid=www-data --init-groups -- "$@" 7>&- 8>&- 9>&-
        else
            exec sudo -n -u www-data -- "$@" 7>&- 8>&- 9>&-
        fi
    )
}

# What root trusts. SuiteCRM's whole tree, tmp/ included, belongs to www-data, so any PHP that runs as the web
# user can rename a folder of root's aside and put one of its own in its place. Root therefore checks before it
# reads or writes: a folder is trusted when tmp/ and the folder itself are real folders (no link on the way),
# the folder is root's, and neither its group nor others can write in it. That is the image's own rule
# (sc_state_dir_status in its lib.sh). Only root can make a folder of root's, and nobody else can put a file
# into one that only root can write in. The mode's other bits don't matter for trust: a folder made in tmp/
# takes over tmp/'s set-group-ID bit, so the image's state folder can have mode 2700. Anything else is refused
# with a plain message and never "fixed".
#
# Trust is one thing and privacy another: this skill makes its own folders with mode 700 (sc_make_root_dir),
# and backup.sh closes the backups folder and each backup to 700 once it knows the folder is root's.
#
# sc_root_folder PATH: succeeds when PATH is a real folder of root's that neither its group nor others can
# write in. A link is not one.
sc_root_folder() {
    [ -n "$(sc_sudo find "$1" -maxdepth 0 -type d -user 0 ! -perm /g=w,o=w 2> /dev/null)" ]
}

# sc_dir_state DIR: prints absent, trusted or untrusted. DIR is tmp/clouve-backup, tmp/clouve-skill-backups, or
# a folder right inside one of them (then the parent has to be trusted too).
sc_dir_state() {
    local dir="$1" parent
    if sc_sudo test -L "${sc_root}/tmp" || ! sc_sudo test -d "${sc_root}/tmp"; then
        if sc_sudo test -e "${sc_root}/tmp" || sc_sudo test -L "${sc_root}/tmp"; then echo untrusted; else echo absent; fi
        return 0
    fi
    parent="$(dirname -- "${dir}")"
    if [ "${parent}" != "${sc_root}/tmp" ]; then
        case "$(sc_dir_state "${parent}")" in
            trusted) ;;
            absent) echo absent; return 0 ;;
            *) echo untrusted; return 0 ;;
        esac
    fi
    if ! sc_sudo test -e "${dir}" && ! sc_sudo test -L "${dir}"; then
        echo absent
        return 0
    fi
    if sc_sudo test -L "${dir}" || ! sc_sudo test -d "${dir}"; then
        echo untrusted
        return 0
    fi
    if sc_root_folder "${dir}"; then echo trusted; else echo untrusted; fi
}

# sc_dir_trusted DIR: succeeds when sc_dir_state says trusted
sc_dir_trusted() { [ "$(sc_dir_state "$1")" = trusted ]; }

# sc_enter_trusted DIR: for root. Changes into DIR and checks again that the folder it is now in is a folder
# of root's that others can't write in. From then on paths relative to "." stay in that folder even if someone
# renames it aside, so use those.
sc_enter_trusted() {
    sc_dir_trusted "$1" || return 1
    cd -P -- "$1" 2> /dev/null || return 1
    sc_root_folder .
}

# sc_untrusted_message DIR: the plain refusal for a folder that is not trusted
sc_untrusted_message() {
    echo "${1} is not a folder of root's that others can't write in (it is a link, belongs to another user, others can write in it, or something else is in its place), so nothing in it is trusted and nothing was changed. That is a job for Clouve support: someone has to look at what is there before it is put back."
}

# sc_make_root_dir DIR: for root. Makes tmp/clouve-backup or tmp/clouve-skill-backups as a folder of root's with
# mode 700 when nothing is there, and succeeds when the folder is trusted afterwards. It never changes a folder
# that is there already.
sc_make_root_dir() {
    case "$(sc_dir_state "$1")" in
        trusted) return 0 ;;
        untrusted) return 1 ;;
    esac
    [ -d "${sc_root}/tmp" ] && [ ! -L "${sc_root}/tmp" ] || return 1
    mkdir -m 700 -- "$1" 2> /dev/null || return 1
    # The new folder is root's because root made it. Its group and mode are set from inside it, so that a
    # folder swapped in under the same name is never changed. tmp/ has the set-group-ID bit, which a new folder
    # takes over; the leading zeros clear it.
    (cd -P -- "$1" 2> /dev/null && [ "$(stat -c %u . 2> /dev/null)" = 0 ] && chown root:root . && chmod 00700 .) || return 1
    sc_dir_trusted "$1"
}

# sc_install_stamp: prints the install stamp's path when one is there
sc_install_stamp() {
    local f
    for f in "${sc_root}/.clouve-install-in-progress" "${sc_root}/tmp/install-in-progress" "${sc_root}/install-in-progress"; do
        if sc_sudo test -e "${f}"; then
            printf '%s' "${f}"
            return 0
        fi
    done
    if sc_dir_trusted "${sc_image_dir}" && sc_sudo test -e "${sc_image_dir}/install-in-progress"; then
        printf '%s' "${sc_image_dir}/install-in-progress"
    fi
    return 0
}

# sc_upgrade_state_file: prints the path of the upgrade's state file when there is one. Nothing in a state
# folder that is not trusted is read.
sc_upgrade_state_file() {
    sc_dir_trusted "${sc_image_dir}" || return 0
    sc_sudo find "${sc_image_dir}" -maxdepth 2 -type f \
        \( -name state -o -name upgrade-state -o -name upgrade.state -o -name state.env \) 2> /dev/null | head -n 1
}

# sc_upgrade_phase: prints backup, upgrade, restore, as-is or failed, or nothing when no upgrade state is there
sc_upgrade_phase() {
    local file text phase
    sc_dir_trusted "${sc_image_dir}" || return 0
    file="$(sc_sudo find "${sc_image_dir}" -maxdepth 2 -type f \
        \( -name state -o -name upgrade-state -o -name upgrade.state -o -name state.env \) 2> /dev/null | head -n 1)"
    if [ -n "${file}" ]; then
        text="$(sc_sudo head -c 2000 "${file}" 2> /dev/null | tr 'A-Z' 'a-z')"
        phase="$(printf '%s\n' "${text}" | sed -nE 's/^.*(^|[^a-z])phase["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?([a-z]+(-[a-z]+)?).*$/\2/p' | head -n 1)"
        if [ -z "${phase}" ]; then
            phase="$(printf '%s\n' "${text}" | head -n 1 | tr -d '[:space:]')"
        fi
        case "${phase}" in
            backup | upgrade | restore | as-is | failed)
                printf '%s' "${phase}"
                return 0
                ;;
        esac
    fi
    if sc_sudo test -e "${sc_image_dir}/upgrade-in-progress"; then
        printf 'upgrade'
    elif sc_sudo test -e "${sc_image_dir}/upgrade-failed"; then
        printf 'failed'
    fi
    return 0
}

# sc_pid1: the name of PID 1
sc_pid1() {
    local name=''
    IFS= read -r name 2> /dev/null < /proc/1/comm || :
    printf '%s' "${name}"
}

# sc_restore_marker_there: prints the path of a restore marker that is there (the marker, or its earlier name
# in the skill's backups folder), or nothing. A marker in a folder that is not trusted is not one.
sc_restore_marker_there() {
    if sc_dir_trusted "${sc_image_dir}" && sc_sudo test -e "${sc_restore_marker}"; then
        printf '%s' "${sc_restore_marker}"
    elif sc_sudo test -e "${sc_restore_marker_old}" && sc_dir_trusted "${sc_skill_dir}"; then
        printf '%s' "${sc_restore_marker_old}"
    fi
    return 0
}

# The lock. One backup or restore of this skill runs at a time: backup.sh and restore.sh hold an flock on
# /run/clouve/suitecrm-skill/lock from before they change anything until they end. The kernel drops it when
# the process ends, however it ends, so a killed run never leaves a lock behind. The file's one line says which
# job holds it and since when.
#
# sc_run_dir_make: for root. Makes /run/clouve/suitecrm-skill (root's, 700). /run is root's, so nothing there
# can be swapped by www-data.
sc_run_dir_make() {
    [ -d /run/clouve ] || mkdir -m 700 /run/clouve 2> /dev/null || [ -d /run/clouve ] || return 1
    [ -d "${sc_run_dir}" ] || mkdir -m 700 "${sc_run_dir}" 2> /dev/null || [ -d "${sc_run_dir}" ] || return 1
    [ ! -L /run/clouve ] && [ ! -L "${sc_run_dir}" ] && [ "$(stat -c '%u %a' "${sc_run_dir}" 2> /dev/null)" = '0 700' ]
}

# sc_lock_holder: prints the line of the job that holds the lock, or nothing when the lock is free
sc_lock_holder() {
    local line=''
    sc_sudo test -f "${sc_lock_file}" || return 0
    if sc_sudo flock -n "${sc_lock_file}" true 2> /dev/null; then return 0; fi
    line="$(sc_sudo head -n 1 "${sc_lock_file}" 2> /dev/null | cut -c1-200)"
    printf '%s' "${line:-another backup or restore}"
}

# sc_lock_take WHAT: for root. Takes the lock for the life of this process, on descriptor 9, and writes WHAT
# and the time into the lock file. Status 1: another job holds it (sc_lock_refusal says which). Status 2: the
# lock could not be made.
sc_lock_take() {
    command -v flock > /dev/null 2>&1 || return 2
    sc_run_dir_make || return 2
    { exec 9>> "${sc_lock_file}"; } 2> /dev/null || return 2
    if ! flock -n 9; then
        # A second look: a check of the lock by another script holds it for a moment.
        sleep 0.3
        if ! flock -n 9; then
            exec 9>&-
            return 1
        fi
    fi
    printf '%s, started %s UTC, process %s\n' "$1" "$(date -u '+%Y-%m-%d %H:%M:%S')" "$$" > "${sc_lock_file}"
    return 0
}

# sc_lock_refusal: the plain refusal for a lock that is held
sc_lock_refusal() {
    local holder
    holder="$(head -n 1 "${sc_lock_file}" 2> /dev/null | cut -c1-200)"
    echo "refused: another backup or restore of this skill is running (${holder:-it has not said which yet}), and only one runs at a time. It holds the lock ${sc_lock_file}, which is free again the moment that job ends. Nothing was changed. Wait for that job (run-in-suitecrm.sh --status <job>), then run this again if it is still wanted."
}

# sc_run_tmp_make: for root. Makes a folder of this run's own in the work folder, for the database options file
# and error text, and sets sc_run_tmp to it. The run holds a lock on a file in it (descriptor 8) for as long as
# it lives, so a folder whose lock is free is one a killed run left behind: those are removed here first.
# The caller removes its own folder when it ends.
sc_run_tmp=''
sc_run_tmp_make() {
    local d rc=0
    sc_run_dir_make || return 1
    { exec 7>> "${sc_run_dir}/tmp.lock"; } 2> /dev/null || return 1
    flock 7 || return 1
    for d in "${sc_run_dir}"/run.*/; do
        [ -d "${d}" ] && [ ! -L "${d%/}" ] || continue
        if [ ! -e "${d}alive" ] || flock -n "${d}alive" true 2> /dev/null; then rm -rf -- "${d}"; fi
    done
    sc_run_tmp="$(mktemp -d "${sc_run_dir}/run.XXXXXXXX")" || rc=1
    if [ "${rc}" -eq 0 ]; then
        { exec 8>> "${sc_run_tmp}/alive"; } 2> /dev/null && flock -n 8 || rc=1
    fi
    exec 7>&-
    return "${rc}"
}

# sc_waiting_page: prints restoring or attention when the image marks that its start waits, or nothing. The
# marks are empty files of root's in /run that the image's stand-in page reads (remote/admin.sh prints the same
# as waiting=). restoring: it waits for this skill's restore marker to go. attention: it found a site that it
# must not start, and a person has to repair it; it goes on by itself when a restore starts, and then waits
# for that restore to finish.
sc_waiting_page() {
    if [ -e /run/clouve-suitecrm-restoring ]; then
        printf 'restoring'
    elif [ -e /run/clouve-suitecrm-attention ]; then
        printf 'attention'
    fi
}

# sc_busy_reason [MODE]: prints why SuiteCRM must not be touched now, or nothing.
#   no MODE      every reason counts
#   restore-ok   for restore.sh: a restore marker is no reason, and PID 1 need not be Apache when a marker is
#                there or the image says that it is waiting for a person. So a restore that was cut off can
#                be finished in a container that waits for it. A container that is still starting stays a
#                reason: its start-up may be about to install or upgrade
#   read-ok      for backup.sh --list: neither a restore marker nor PID 1 is a reason
sc_busy_reason() {
    local mode="${1:-}" stamp phase pid1 marker holder page
    stamp="$(sc_install_stamp)"
    if [ -n "${stamp}" ]; then
        echo "SuiteCRM is being installed (the image's install-in-progress stamp is there). Wait for the start-up to finish."
        return 0
    fi
    if [ -z "${mode}" ] && [ "$(sc_dir_state "${sc_image_dir}")" = untrusted ]; then
        # The marker can't be read from a folder that is not trusted. The lock still shows a running restore.
        holder="$(sc_lock_holder)"
        case "${holder}" in
            'restore of '*)
                echo "a restore by this skill is under way (${holder}). Wait for it to end: run-in-suitecrm.sh --status <job> shows it."
                return 0
                ;;
        esac
    fi
    phase="$(sc_upgrade_phase)"
    case "${phase}" in
        backup | upgrade | restore)
            echo "SuiteCRM is being upgraded by the image (phase: ${phase}). Wait for it to finish; upgrade-state.sh shows the state."
            return 0
            ;;
        as-is)
            echo "Clouve staff are finishing an upgrade of SuiteCRM by hand, on the site as it is (phase: ${phase}). Leave SuiteCRM alone until they are done; upgrade-state.sh shows the state."
            return 0
            ;;
    esac
    marker="$(sc_restore_marker_there)"
    if [ -n "${marker}" ] && [ -z "${mode}" ]; then
        holder="$(sc_lock_holder)"
        if [ -n "${holder}" ]; then
            echo "a restore by this skill is under way (${holder}; ${marker} is there). Wait for it to end: run-in-suitecrm.sh --status <job> shows it."
        else
            echo "a restore by this skill is under way or was cut off (${marker} is there), and no restore is running now. Run the restore again to finish it: playbooks/restore-from-backup.md."
        fi
        return 0
    fi
    pid1="$(sc_pid1)"
    if [ "${pid1}" != apache2 ]; then
        if [ "${mode}" = read-ok ]; then return 0; fi
        page="$(sc_waiting_page)"
        if [ "${mode}" = restore-ok ] && { [ -n "${marker}" ] || [ "${page}" = attention ]; }; then return 0; fi
        case "${page}" in
            attention)
                echo "SuiteCRM's container is waiting (PID 1 is ${pid1:-unknown}, not Apache): the image found a site that it must not start, and a person has to look at it. upgrade-state.sh says what it found."
                ;;
            restoring)
                echo "SuiteCRM's container is going on with its start after a restore (PID 1 is ${pid1:-unknown}, not Apache; the restore's marker is gone and the image has not seen that yet). Wait a minute; upgrade-state.sh shows the state."
                ;;
            *)
                echo "SuiteCRM's container is still starting, or waiting (PID 1 is ${pid1:-unknown}, not Apache): upgrade-state.sh says which."
                ;;
        esac
        return 0
    fi
    return 0
}

# sc_recent_backup HOURS: succeeds when this skill has a complete backup made in the last HOURS hours. Only a
# backups folder that is trusted counts, and in it only a backup that is a folder of root's that others can't
# write in, with a COMPLETE file of root's. Status 1: there is none. Status 2: the backups folder is not
# trusted.
sc_recent_backup() {
    local found
    case "$(sc_dir_state "${sc_skill_dir}")" in
        trusted) ;;
        untrusted) return 2 ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2016  # $1 and $2 are for the inner bash, which runs as root inside the folder
    found="$(sc_sudo bash -c '
        ours() { [ -n "$(find "$1" -maxdepth 0 -type d -user 0 ! -perm /g=w,o=w 2> /dev/null)" ]; }
        cd -P -- "$1" 2> /dev/null || exit 0
        ours . || exit 0
        find . -mindepth 2 -maxdepth 2 -name COMPLETE -type f -user 0 -mmin "-$2" 2> /dev/null | while IFS= read -r f; do
            d="${f%/COMPLETE}"
            [[ ${d#./} =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
            if ours "${d}"; then echo "${d}"; break; fi
        done' _ "${sc_skill_dir}" "$(($1 * 60))" 2> /dev/null)"
    [ -n "${found}" ]
}
