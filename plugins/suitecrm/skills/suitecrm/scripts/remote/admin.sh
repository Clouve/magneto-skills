#!/bin/bash
# SuiteCRM skill: remote/admin.sh (runs inside the SuiteCRM container as root; run-in-suitecrm.sh's `admin`
# form sends it, for scheduler.sh, upgrade-state.sh and verify-health.sh)
#
# The few things that need root because the image's state folder, /var/www/html/tmp/clouve-backup, is root's:
#
#   admin.sh state                         what the image's state files say, as name=value lines (read-only)
#   admin.sh scheduler-held                three lines: hold_file=yes, no or unknown (the state folder is not
#                                          trusted), setting=on, off, none or unknown, and also= with the
#                                          other reasons why no job runs (see below)
#   admin.sh release-scheduler             releases the scheduler: removes the scheduler-held file and has the
#                                          image switch its setting on. Two lines: hold_file=removed or absent,
#                                          and setting=switched-on, on or none
#   admin.sh remove-upgrade-backup NAME    removes the backup the image kept from an upgrade
#
# The scheduler is held in two ways. The file scheduler-held in the state folder holds it for as long as it
# is there. And the image records in SuiteCRM's own settings whether its scheduler loop runs
# ($sugar_config['clouve']['scheduler'] = 'on' in config_override.php): on for a new install and after a
# release, not set on an install that existed before this image. The image's own tools read and write that
# setting, and this script calls them: `settings.php scheduler` in /clouve/suitecrm/installer prints on or off
# (it loads SuiteCRM's settings, so it runs as www-data), and release-scheduler.sh there removes the hold file
# and switches the setting on. An image that has no such setting (none) holds by the file alone, and this
# script removes the file itself.
# That image's loop runs no job in three more cases, which also= names: untrusted (the state folder is not
# root's) and moved-aside (a folder the image moved aside is on the volume), because a hold file in such a
# folder can't be read, and loops-paused (staff's own pause file for both loops is in the state folder). A
# release removes none of these.
#
# What the image keeps in that folder:
#   state                  name=value lines about an upgrade: phase (backup, upgrade, restore, failed, or
#                          as-is while staff finish one by hand), from, to, build, attempts, step, and reason
#                          once a try failed
#   upgrade-failed         a note: the upgrade failed twice and the old version was put back
#   upgrade-skipped        a note: the image did not start the upgrade. name=value lines: from, to, build,
#                          time and reason. The image removes it when an upgrade runs.
#   upgrade-console.log    what SuiteCRM's own upgrade commands printed
#   scheduler-held         the scheduler loop does nothing while this file is there
#   scheduler-hold-placed  an earlier build of the image wrote it next to a hold it placed; nothing reads it now
#   restore-in-progress    this skill's restore is running or was cut off: neither loop runs, and a container
#                          that starts waits for it to go
#   loops-paused           staff's own pause for both loops
#   needs-attention        why the container waits and starts no SuiteCRM, written for the AI Assistant, which
#                          can't read the container's log. name=value lines: reason (the words of the image's
#                          [clouve-upgrade] FAILED line, or of its log line about a restore; never a password),
#                          since (UTC), from (the version on the volume, as that line names it), to (the
#                          image's version) and kind (repair: a person has to repair the site; restore: the
#                          image waits for this skill's restore). It is there only while the container waits.
#   aside/                 the customer's upload folders while SuiteCRM's first upgrade command runs
#   <from>-to-<to>/        the backup the last upgrade kept
# A new install has no such folder. The image makes it at its first upgrade, and this skill's restore makes it.
#
# What root trusts. SuiteCRM's tree, tmp/ included, belongs to www-data, so the web user can move the folder
# aside and put one of its own there, with files that are links to anything. So the folder is checked first
# (guard.sh, sc_dir_state). A folder that is not trusted is never read and never changed: state says
# state_dir=untrusted, and the two subcommands that change something refuse. In a trusted folder this script
# works from inside it with relative paths, and prints only from plain files of root's, never through a link.
# The image moves a folder it does not trust aside, to tmp/clouve-backup.untrusted-<UTC time>; state lists
# those as moved_aside lines. The two VERSION files belong to www-data: what they hold is printed only when
# it is a version number.
#
# The lines state prints:
#   pid1, pid1_seconds            the name of PID 1, and how long it has been running
#   waiting                       attention, restoring or nothing: the page the image's stand-in shows while
#                                 the container waits (the image marks it with a file of root's in /run):
#                                 attention when it found a site it must not start and a person has to
#                                 repair, restoring while this skill's restore marker is there
#   image_waits                   yes when this image is one that waits and marks it that way, no when not
#   state_dir, skill_dir          absent, trusted or untrusted: the image's state folder, this skill's backups
#   moved_aside                   one line per folder the image moved aside
#   install_stamp                 the install stamp's path when one is there
#   upgrade_phase                 backup, upgrade, restore, as-is, failed, nothing, or unknown (folder not
#                                 trusted)
#   upgrade_state_file            the state file's path when it is there
#   upgrade_skipped               yes or no, then skipped_reason, skipped_from, skipped_to, skipped_at from the note
#   busy_reason                   why the skill's other scripts refuse right now, or nothing
#   scheduler_held                yes, no or unknown: the hold file
#   scheduler_setting             on, off, none (this image has no such setting) or unknown (it could not be read)
#   scheduler_also                the other reasons why no job runs: untrusted, moved-aside, loops-paused
#   restore_marker                yes, no or unknown, and restore_marker_file with its path
#   attention_reason, attention_since, attention_from, attention_to, attention_kind
#                                 what the image's note of a wait says, when the note is there
#   state_file                    one line per file of the list above that is there
#   messenger_worker, version_file, image_version, config_si, oauth_private_key_mode, not_owned_by_www_data,
#   disk_total, disk_used, disk_free, skill_backups, skill_backups_bytes, upgrade_leftover_bytes
#   kept_backup                   one line per kept backup: name, bytes, UTC time of the last change
#   state_text, skipped_text      the first lines of upgrade-failed, state and upgrade-skipped
#
# Exit codes: 0 done; 64 usage; 2 refused (the upgrade is not finished, the state folder is not trusted, or the
# name is not a kept backup); 3 no such backup.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${here}/guard.sh" || exit 1

image_version_file=/clouve/suitecrm/app/VERSION
# The image's own scripts. The folder is root's, and www-data can't write there.
installer=/clouve/suitecrm/installer

# as_www CMD...: runs CMD as www-data
as_www() {
    if command -v setpriv > /dev/null 2>&1; then
        setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"
    else
        sudo -n -u www-data -- "$@"
    fi
}

# root_only PATH: PATH is root's, is not a link, and nobody but root can write it
root_only() {
    [ ! -L "$1" ] && [ -e "$1" ] && [ "$(stat -c %u -- "$1" 2> /dev/null)" = 0 ] || return 1
    [ -z "$(find "$1" -maxdepth 0 \( -perm /o=w -o \( -perm /g=w ! -gid 0 \) \) 2> /dev/null)" ]
}

# image_tool NAME: succeeds when the image's own script NAME is there, and it and every folder above it are
# root's alone. Root runs nothing else from there.
image_tool() {
    root_only /clouve && root_only /clouve/suitecrm && root_only "${installer}" && root_only "${installer}/$1" && [ -f "${installer}/$1" ]
}

# scheduler_setting: what SuiteCRM's own settings say about the image's scheduler loop, read by the image's
# settings.php as www-data: on or off. none when this image's settings.php knows no such setting, unknown
# when it does and gave no answer.
scheduler_setting() {
    local value
    if [ ! -f "${installer}/settings.php" ] || ! grep -qw scheduler "${installer}/settings.php" 2> /dev/null; then
        echo none
        return 0
    fi
    value="$(cd "${sc_root}" 2> /dev/null && as_www timeout 30 php "${installer}/settings.php" scheduler 2> /dev/null)" || value=''
    case "${value}" in
        on | off) echo "${value}" ;;
        *) echo unknown ;;
    esac
}

# read_version FILE: the version in FILE's first line, or nothing when FILE is a link, is not a plain file, or
# holds anything else
read_version() {
    local line=''
    [ ! -L "$1" ] && [ -f "$1" ] || return 0
    IFS= read -r -n 40 line 2> /dev/null < "$1" || :
    line="${line//[[:space:]]/}"
    if [[ ${line} =~ ^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$ ]]; then printf '%s' "${line}"; fi
}

# pid1_seconds: how long PID 1 has been running, from its start time in /proc/1/stat and the uptime
pid1_seconds() {
    local stat up hz
    local -a field
    IFS= read -r stat 2> /dev/null < /proc/1/stat || return 0
    read -r -a field <<< "${stat##*) }"
    IFS=' .' read -r up _ 2> /dev/null < /proc/uptime || return 0
    hz="$(getconf CLK_TCK 2> /dev/null)"
    [[ ${field[19]:-} =~ ^[0-9]+$ ]] && [[ ${up} =~ ^[0-9]+$ ]] || return 0
    [[ ${hz} =~ ^[1-9][0-9]*$ ]] || hz=100
    printf '%s' "$((up - field[19] / hz))"
}

# moved_aside: the folders the image moved aside because it did not trust them, one name per line. tmp/ is
# www-data's, so a name is printed only when it is made of plain characters.
moved_aside() {
    local d name
    [ -d "${sc_root}/tmp" ] && [ ! -L "${sc_root}/tmp" ] || return 0
    for d in "${sc_root}/tmp/clouve-backup.untrusted-"*; do
        [ -e "${d}" ] || [ -L "${d}" ] || continue
        name="${d##*/}"
        case "${name}" in
            *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:+-]*) continue ;;
        esac
        printf '%s\n' "${name}"
    done | head -n 20
}

# moved_aside_any: succeeds when the volume holds a folder the image moved aside, whatever its name ends in
moved_aside_any() {
    local d
    [ -d "${sc_root}/tmp" ] && [ ! -L "${sc_root}/tmp" ] || return 1
    for d in "${sc_root}/tmp/clouve-backup.untrusted-"*; do
        if [ -e "${d}" ] || [ -L "${d}" ]; then return 0; fi
    done
    return 1
}

# waiting_page: attention or restoring when the image marks that its start waits, with a file of root's in
# /run that its stand-in page reads; nothing when not
waiting_page() {
    if [ -e /run/clouve-suitecrm-restoring ]; then
        printf 'restoring'
    elif [ -e /run/clouve-suitecrm-attention ]; then
        printf 'attention'
    fi
}

# The functions below read the image's state folder. They work on "." and are called only after
# sc_enter_trusted has put this shell inside the folder.

# root_file NAME: ./NAME is a plain file of root's, not a link
root_file() { [ ! -L "./$1" ] && [ -f "./$1" ] && [ "$(stat -c %u -- "./$1" 2> /dev/null)" = 0 ]; }

# first_lines NAME [WIDTH]: the first 8 lines of ./NAME that are not empty, without control characters, each
# cut to WIDTH characters (300 when not given)
first_lines() {
    root_file "$1" || return 0
    head -n 12 -- "./$1" | tr -d '\000-\010\013-\037\177' | sed '/^[[:space:]]*$/d' | head -n 8 | cut -c1-"${2:-300}"
}

# attention_value KEY: the value of KEY in the image's note of a wait, ./needs-attention. The reason is a
# sentence or two, so a line may be 1,000 characters long here.
attention_value() {
    local line
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$1" ] && [ "${line}" != "$1" ]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done < <(first_lines needs-attention 1000)
}

# note_value NAME KEY...: the value of the first KEY that ./NAME has as a name=value line
note_value() {
    local name="$1" key line
    shift
    for key in "$@"; do
        while IFS= read -r line; do
            if [ "${line%%=*}" = "${key}" ] && [ "${line}" != "${key}" ]; then
                printf '%s' "${line#*=}"
                return 0
            fi
        done < <(first_lines "${name}")
    done
}

# upgrade_phase: backup, upgrade, restore or failed, from the image's state file, or nothing
upgrade_phase() {
    local phase
    phase="$(note_value state phase)"
    case "${phase}" in
        backup | upgrade | restore | as-is | failed)
            printf '%s' "${phase}"
            return 0
            ;;
    esac
    if root_file upgrade-failed; then printf 'failed'; fi
}

# scheduler_also: the other reasons why this image's scheduler loop runs no job, as words on one line:
# untrusted, moved-aside, loops-paused (the header says what each means). Only an image whose loops.sh knows
# them gets a word. It reads dir_state, so enter_state_dir comes first.
scheduler_also() {
    local words=''
    if grep -q 'untrusted' "${installer}/loops.sh" 2> /dev/null; then
        if [ "${dir_state}" = untrusted ]; then words+='untrusted '; fi
        if moved_aside_any; then words+='moved-aside '; fi
    fi
    if [ "${dir_state}" = trusted ] && grep -q 'loops-paused' "${installer}/loops.sh" 2> /dev/null && root_file loops-paused; then
        words+='loops-paused '
    fi
    printf '%s' "${words% }"
}

# kept_backups: the folders the image's upgrade keeps, one per line: name, bytes, UTC time of the last change
kept_backups() {
    local d name
    for d in ./*-to-*/; do
        d="${d%/}"
        [ -d "${d}" ] && [ ! -L "${d}" ] || continue
        name="${d#./}"
        case "${name}" in
            *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-]*) continue ;;
        esac
        printf '%s\t%s\t%s\n' "${name}" "$(du -sb -- "${d}" 2> /dev/null | cut -f1)" "$(date -u -r "${d}" '+%Y-%m-%d %H:%M' 2> /dev/null)"
    done
}

# refuse_untrusted: the refusal of the subcommands that change something
refuse_untrusted() {
    echo "[suitecrm] refused: $(sc_untrusted_message "${sc_image_dir}")" >&2
    exit 2
}

# enter_state_dir: sets dir_state to absent, trusted or untrusted for the image's state folder and, when it is
# trusted, leaves this shell inside it. From then on the functions above read that very folder, even if
# someone renames it aside.
enter_state_dir() {
    dir_state="$(sc_dir_state "${sc_image_dir}")"
    if [ "${dir_state}" = trusted ] && ! sc_enter_trusted "${sc_image_dir}"; then dir_state=untrusted; fi
}

case "${1:-}" in
    state)
        enter_state_dir
        skill_state="$(sc_dir_state "${sc_skill_dir}")"
        pid1="$(sc_pid1)"
        printf 'pid1=%s\n' "${pid1}"
        printf 'pid1_seconds=%s\n' "$(pid1_seconds)"
        printf 'waiting=%s\n' "$(waiting_page)"
        if grep -q 'clouve-suitecrm-attention' "${installer}/lib.sh" 2> /dev/null; then echo 'image_waits=yes'; else echo 'image_waits=no'; fi
        printf 'state_dir=%s\n' "${dir_state}"
        printf 'skill_dir=%s\n' "${skill_state}"
        moved_aside | sed 's/^/moved_aside=/'

        held=no
        marker=no
        marker_file=''
        phase=''
        skipped=no
        case "${dir_state}" in
            trusted)
                printf 'install_stamp=%s\n' "$(sc_install_stamp)"
                phase="$(upgrade_phase)"
                if [ -e ./scheduler-held ]; then held=yes; fi
                if [ -e ./restore-in-progress ]; then marker=yes; marker_file="${sc_restore_marker}"; fi
                if root_file upgrade-skipped; then skipped=yes; fi
                busy="$(sc_busy_reason)"
                ;;
            absent)
                printf 'install_stamp=%s\n' "$(sc_install_stamp)"
                busy="$(sc_busy_reason)"
                ;;
            *)
                # Nothing in the folder is read. The stamp at the top of the install and PID 1 are outside it.
                stamp=''
                busy=''
                if [ -e "${sc_root}/.clouve-install-in-progress" ]; then
                    stamp="${sc_root}/.clouve-install-in-progress"
                    busy="SuiteCRM is being installed (the image's install-in-progress stamp is there). Wait for the start-up to finish."
                elif [ "${pid1}" != apache2 ]; then
                    busy="SuiteCRM's container is still starting, or waiting (PID 1 is ${pid1:-unknown}, not Apache)."
                fi
                printf 'install_stamp=%s\n' "${stamp}"
                phase=unknown
                held=unknown
                marker=unknown
                ;;
        esac
        if [ "${skill_state}" = trusted ] && [ -e "${sc_restore_marker_old}" ]; then
            marker=yes
            marker_file="${marker_file:-${sc_restore_marker_old}}"
        fi
        printf 'upgrade_phase=%s\n' "${phase}"
        if [ "${dir_state}" = trusted ] && root_file state; then
            printf 'upgrade_state_file=%s\n' "${sc_image_dir}/state"
        else
            echo 'upgrade_state_file='
        fi
        printf 'upgrade_skipped=%s\n' "${skipped}"
        if [ "${skipped}" = yes ]; then
            # The image writes from, to, build, time and reason, one name=value line each
            printf 'skipped_reason=%s\n' "$(note_value upgrade-skipped reason)"
            printf 'skipped_from=%s\n' "$(note_value upgrade-skipped from)"
            printf 'skipped_to=%s\n' "$(note_value upgrade-skipped to)"
            printf 'skipped_at=%s\n' "$(note_value upgrade-skipped time)"
        fi
        printf 'busy_reason=%s\n' "${busy}"
        printf 'scheduler_held=%s\n' "${held}"
        printf 'scheduler_setting=%s\n' "$(scheduler_setting)"
        printf 'scheduler_also=%s\n' "$(scheduler_also)"
        printf 'restore_marker=%s\n' "${marker}"
        printf 'restore_marker_file=%s\n' "${marker_file}"
        # The image's note of a wait: only a plain file of root's in the trusted folder is read. The reason is
        # the image's own sentence, and the other four are kept to the characters such values have.
        if [ "${dir_state}" = trusted ] && root_file needs-attention; then
            printf 'attention_reason=%s\n' "$(attention_value reason)"
            printf 'attention_since=%s\n' "$(attention_value since | tr -cd '0123456789TZ:.+-' | cut -c1-40)"
            printf 'attention_from=%s\n' "$(attention_value from | tr -cd 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -' | cut -c1-40)"
            printf 'attention_to=%s\n' "$(attention_value to | tr -cd 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._ -' | cut -c1-40)"
            printf 'attention_kind=%s\n' "$(attention_value kind | tr -cd 'abcdefghijklmnopqrstuvwxyz' | cut -c1-20)"
        fi
        if [ "${dir_state}" = trusted ]; then
            for f in state upgrade-failed upgrade-skipped upgrade-console.log scheduler-held scheduler-hold-placed restore-in-progress loops-paused needs-attention aside; do
                if [ -e "./${f}" ] || [ -L "./${f}" ]; then printf 'state_file=%s\n' "${f}"; fi
            done
        fi
        worker=no
        for f in /proc/[0-9]*/cmdline; do
            # A process may be gone by now: the redirection's own error is silenced too
            if { tr '\0' ' ' < "${f}"; } 2> /dev/null | grep -q 'php.*messenger:consume'; then worker=yes; break; fi
        done
        printf 'messenger_worker=%s\n' "${worker}"
        printf 'version_file=%s\n' "$(read_version "${sc_root}/VERSION")"
        printf 'image_version=%s\n' "$(read_version "${image_version_file}")"
        if [ -e "${sc_root}/public/legacy/config_si.php" ]; then echo 'config_si=yes'; else echo 'config_si=no'; fi
        printf 'oauth_private_key_mode=%s\n' "$(stat -c %a "${sc_root}/public/legacy/Api/V8/OAuth2/private.key" 2> /dev/null)"
        printf 'not_owned_by_www_data=%s\n' "$(find "${sc_root}/cache" "${sc_root}/public/legacy/cache" "${sc_root}/public/legacy/custom" "${sc_root}/public/legacy/upload" ! -user www-data 2> /dev/null | head -n 200 | wc -l)"
        df -PB1 "${sc_root}" 2> /dev/null | awk 'NR == 2 { printf "disk_total=%s\ndisk_used=%s\ndisk_free=%s\n", $2, $3, $4 }'
        if [ "${skill_state}" = trusted ]; then
            printf 'skill_backups=%s\n' "$(find "${sc_skill_dir}" -mindepth 2 -maxdepth 2 -name COMPLETE 2> /dev/null | wc -l)"
            printf 'skill_backups_bytes=%s\n' "$(du -sb "${sc_skill_dir}" 2> /dev/null | cut -f1)"
        else
            printf 'skill_backups=0\nskill_backups_bytes=\n'
        fi
        printf 'upgrade_leftover_bytes=%s\n' "$(du -sb "${sc_root}/tmp/package/upgrade" 2> /dev/null | cut -f1)"
        if [ "${dir_state}" = trusted ]; then
            kept_backups | sed 's/^/kept_backup=/'
            # What the image wrote about a failed or a skipped upgrade: the first lines, which name versions
            # and a reason, never a secret
            first_lines upgrade-failed | sed 's/^/state_text=upgrade-failed: /'
            first_lines state | sed 's/^/state_text=state: /'
            first_lines upgrade-skipped | sed 's/^/skipped_text=/'
        fi
        exit 0
        ;;
    scheduler-held)
        enter_state_dir
        case "${dir_state}" in
            trusted) if [ -e ./scheduler-held ]; then echo 'hold_file=yes'; else echo 'hold_file=no'; fi ;;
            absent) echo 'hold_file=no' ;;
            *) echo 'hold_file=unknown' ;;
        esac
        printf 'setting=%s\n' "$(scheduler_setting)"
        printf 'also=%s\n' "$(scheduler_also)"
        exit 0
        ;;
    release-scheduler)
        enter_state_dir
        if [ "${dir_state}" = untrusted ]; then refuse_untrusted; fi
        file=absent
        if [ "${dir_state}" = trusted ] && { [ -e ./scheduler-held ] || [ -L ./scheduler-held ]; }; then file=there; fi
        setting="$(scheduler_setting)"
        if [ "${setting}" = unknown ]; then
            echo "[suitecrm] refused: the image's scheduler setting could not be read (${installer}/settings.php scheduler gave no answer), so the scheduler was not released. Nothing was changed." >&2
            exit 2
        fi
        if [ "${file}" = absent ] && [ "${setting}" != off ]; then
            printf 'hold_file=absent\nsetting=%s\n' "${setting}"
            exit 0
        fi
        release="${installer}/release-scheduler.sh"
        if image_tool release-scheduler.sh; then
            # The image's own release: it removes the hold file and switches the setting on through SuiteCRM's
            # Configurator, as www-data. It refuses while a state folder that is not root's is on the volume and
            # while a restore is under way, and says so.
            said="$(cd "${sc_root}" && timeout 300 bash "${release}" 2>&1)"
            rc=$?
            if [ "${rc}" -ne 0 ]; then
                echo "[suitecrm] the image's own release (${release}) did not release the scheduler (exit ${rc}): $(printf '%s' "${said}" | tr -d '\000-\010\013-\037\177' | tail -n 3 | cut -c1-600 | tr '\n' ' ')If that names a step for staff, it is a request to Clouve support." >&2
                exit 2
            fi
            if [ "$(scheduler_setting)" != on ]; then
                echo "[suitecrm] the image's own release (${release}) ended without an error, but the image's scheduler setting is not on, so the scheduler is not released. That is a request to Clouve support." >&2
                exit 2
            fi
            if [ "${setting}" = off ]; then setting=switched-on; fi
        elif [ "${setting}" = off ]; then
            echo "[suitecrm] refused: the image's scheduler setting is off, and this image has no ${release} to switch it on. That is a request to Clouve support. Nothing was changed." >&2
            exit 2
        fi
        if [ "${file}" = there ]; then
            rm -f -- ./scheduler-held
            if [ -e ./scheduler-held ] || [ -L ./scheduler-held ]; then
                echo "[suitecrm] could not remove ${sc_image_dir}/scheduler-held" >&2
                exit 2
            fi
            file=removed
        fi
        printf 'hold_file=%s\nsetting=%s\n' "${file}" "${setting}"
        exit 0
        ;;
    remove-upgrade-backup)
        name="${2:-}"
        case "${name}" in
            *[!0123456789.to-]* | '' | .* | *..* | */*) echo "[suitecrm] not the name of a kept upgrade backup" >&2; exit 64 ;;
            *-to-*) ;;
            *) echo "[suitecrm] not the name of a kept upgrade backup" >&2; exit 64 ;;
        esac
        enter_state_dir
        if [ "${dir_state}" = untrusted ]; then refuse_untrusted; fi
        if [ "${dir_state}" != trusted ] || [ ! -d "./${name}" ] || [ -L "./${name}" ]; then
            echo "[suitecrm] there is no kept backup named ${name}" >&2
            exit 3
        fi
        phase="$(upgrade_phase)"
        if [ -n "${phase}" ]; then
            echo "[suitecrm] refused: the upgrade's state is \"${phase}\", so its backup may still be needed. Nothing was removed." >&2
            exit 2
        fi
        if [ "$(sc_pid1)" != apache2 ]; then
            echo "[suitecrm] refused: SuiteCRM's container is still starting or waiting, so the backup may still be needed. Nothing was removed." >&2
            exit 2
        fi
        bytes="$(du -sb -- "./${name}" 2> /dev/null | cut -f1)"
        rm -rf -- "./${name:?}"
        if [ -e "./${name}" ]; then
            echo "[suitecrm] could not remove ${name}" >&2
            exit 2
        fi
        echo "Removed the kept upgrade backup ${name} (${bytes:-0} bytes). There is no way back to the old version from this volume now."
        exit 0
        ;;
    *)
        echo "[suitecrm] admin.sh: unknown subcommand" >&2
        exit 64
        ;;
esac
