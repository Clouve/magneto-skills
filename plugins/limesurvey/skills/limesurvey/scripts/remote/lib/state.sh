# shellcheck shell=bash
# LimeSurvey skill: remote/lib/state.sh (sourced inside the LimeSurvey container, as root)
#
# Reads what the Clouve image and this skill's own scripts say is under way in this container, so that no script
# changes a site that is starting, being installed, upgraded or restored. run-in-limesurvey.sh's start-up code
# sources it before it runs anything, and state.sh, health.sh, backup.sh, restore.sh, backup-stream.sh and
# upgrade-backup.sh source it too.
#
# Whom it trusts. /var/www/html belongs to www-data, so PHP code could move the real clouve folder aside and put
# one of its own there. The image keeps clouve as root's, mode 700, and so nothing here reads, lists or writes
# anything under a clouve, a clouve/backups or a backup folder that is a link, is not a folder or does not belong
# to root. Such a folder is reported as untrusted and is never repaired here: the image moves it aside at its next
# start.
#
# What it reads, all under /var/www/html/clouve:
#   install-in-progress             the image's stamp while a first install runs
#   upgrade-<from>-to-<to>/state    the image's upgrade state: NAME=value lines. phase is backup, upgrade or restore
#                                   while the upgrade is under way, failed when it was undone and the old version
#                                   runs, and done (or no file) when it is over. step names the step within the
#                                   phase upgrade (moving, copying, updating, finishing), and rstep the step of
#                                   the way back (removing-new, moving-back).
#   upgrade-<from>-to-<to>/db-touched   there from before the upgrade's first write to the database until the
#                                   dump from before the upgrade is loaded again, or the upgrade is done
#   upgrade-<from>-to-<to>/active-plugins   the added plugins that were on before the upgrade, one name per line
#   upgrade-failed                  the image's note that it gave up on an upgrade: from, to, when and reason lines
#   upgrade-skipped                 the image's note that it did not try an upgrade (too little space, too few
#                                   inodes, or the backup could not be made): reason, from, to and a time
#   needs-attention                 the image's note that a start could not go on and waits: it keeps its
#                                   stand-in page and its sshd up, starts no LimeSurvey, and does not exit. It
#                                   does that when its own way back from a failed upgrade failed, when the code
#                                   and the database do not belong together and it has no backup it trusts, and
#                                   while it finds this skill's restore marker. The file is root's, mode 600, and
#                                   has one NAME=value line each for reason (the words of the image's log line; no
#                                   secret), since (when the wait began, in UTC), from (the version on the
#                                   volume, or "no code"), to (the image's version) and kind: repair when a
#                                   person has to repair the site, restore while it waits for this skill's
#                                   restore. The image removes it when the wait ends, when the container is
#                                   asked to stop, and at the next start. A note of kind restore without the
#                                   restore's marker is seconds old: the restore has finished, and the image is
#                                   about to go on with its start.
#   backups/RESTORE-IN-PROGRESS     this skill's restore.sh, from its first change to its last
#   backups/.lock                   held by a running backup.sh, restore.sh or backup-stream.sh
#   backups/.maintenance-by-backup  written by backup.sh before it locks the site and removed once the lock is
#                                   lifted, so that a later run can clean up after a backup that died
#
# clv_dir_trusted DIR    0 when DIR is a real folder (no link) that belongs to root
# clv_clouve             prints ok, missing or untrusted for /var/www/html/clouve
# clv_backups_enter HOW  changes into clouve/backups after checking, link by link, that clouve and clouve/backups
#                        are real folders of root's, and prints nothing. HOW is `make` (make clouve/backups, mode
#                        700, when clouve is there and trusted) or `existing`. Returns 1 with a sentence on stderr
#                        when a folder is untrusted, 2 when there is no clouve/backups (and HOW is existing). After
#                        it, the caller works with names relative to the current folder, which nobody but root can
#                        change.
#   clv_backup_trusted NAME   0 when ./NAME (in clouve/backups) is a real folder of root's whose six files are
#                        plain files of root's
# clv_waiting            prints the image's reason and returns 0 when the image is waiting, for a repair or for
#                        this skill's restore
# clv_waiting_note NAME  prints the value of NAME (since, from, to or kind) in the image's note, when it is there
# clv_aside              prints the names of the clouve.untrusted-* folders next to clouve, one per line: what the
#                        image moved aside because it was not root's own folder
# clv_state              prints NAME=value lines: clouve, clouve_aside, waiting, waiting_reason, waiting_kind,
#                        waiting_since, waiting_from, waiting_to, install,
#                        upgrade_phase, upgrade_step, upgrade_db_touched, upgrade_folder, upgrade_from,
#                        upgrade_to, upgrade_failed,
#                        upgrade_failed_reason, upgrade_failed_when, upgrade_skipped, upgrade_skipped_reason,
#                        upgrade_skipped_from, upgrade_skipped_to, upgrade_skipped_when, kept_backup,
#                        kept_backup_kb, restore, restore_backup, job_lock, backup_died, web_server
# clv_busy_reason HOW    prints one sentence and returns 0 when the caller must not run; returns 1 when it may.
#                        HOW says what the caller does:
#                          all         it changes survey data, sends email or runs LimeSurvey's own code. It runs
#                                      only on a site that is up, with nothing under way.
#                          restore-ok  a restore (restore.sh, and backup-stream.sh putting a backup in place). As
#                                      `all`, and it may also run over the restore's own marker, to finish a
#                                      restore that was cut off, also while the image waits for exactly that.
#                          repair      it runs none of LimeSurvey's code and touches no survey data (putting back
#                                      security.php alone). It may also run while the image waits for a repair.
#                        A script that only reads (state.sh, health.sh, a listing) does not ask.

clv_ls_root="${CLV_LS_ROOT:-/var/www/html}"
clv_state_dir="${clv_ls_root}/clouve"
clv_backups_dir="${clv_state_dir}/backups"
clv_backup_files=(SHA256SUMS manifest.json database.sql.gz upload.tar.gz config.tar.gz plugins.tar.gz)

clv_dir_trusted() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u -- "$1" 2> /dev/null)" = 0 ]
}

clv_clouve() {
    if [ ! -e "${clv_state_dir}" ] && [ ! -L "${clv_state_dir}" ]; then printf missing; return 0; fi
    if clv_dir_trusted "${clv_state_dir}"; then printf ok; else printf untrusted; fi
}

clv_backups_enter() {
    local how="${1:-existing}" root
    root="$(cd -P -- "${clv_ls_root}" 2> /dev/null && pwd -P)" || { echo "[limesurvey] ${clv_ls_root} is not there" >&2; return 1; }
    case "$(clv_clouve)" in
        missing)
            [ "${how}" = make ] || return 2
            echo "[limesurvey] ${clv_state_dir} is not there. The Clouve image makes it at its start, as root's own folder; nothing here makes it" >&2
            return 1
            ;;
        untrusted)
            echo "[limesurvey] ${clv_state_dir} is a link or does not belong to root, so it is not the folder the Clouve image made, and nothing in it is read or written. Someone or something replaced it. The image moves such a folder aside at its next start; tell the user to contact Clouve support" >&2
            return 1
            ;;
    esac
    # Each step changes folder by a relative name and then checks where it really is, so a link swapped in between
    # the check and the step is caught.
    cd -P -- "${root}/clouve" 2> /dev/null || { echo "[limesurvey] cannot open ${clv_state_dir}" >&2; return 1; }
    if [ "$(pwd -P)" != "${root}/clouve" ] || [ "$(stat -c %u . 2> /dev/null)" != 0 ]; then
        echo "[limesurvey] ${clv_state_dir} is not a folder of root's, so nothing in it is read or written" >&2
        return 1
    fi
    if [ ! -e backups ] && [ ! -L backups ]; then
        [ "${how}" = make ] || return 2
        # mkdir fails on a name that exists, a link included, and never follows one.
        (umask 077 && mkdir backups) 2> /dev/null || { echo "[limesurvey] could not make clouve/backups" >&2; return 1; }
    fi
    if [ -L backups ] || [ ! -d backups ] || [ "$(stat -c %u backups 2> /dev/null)" != 0 ]; then
        echo "[limesurvey] clouve/backups is a link or does not belong to root, so it is not the folder this skill made, and nothing in it is read, restored or written. Someone or something replaced it; tell the user to contact Clouve support" >&2
        return 1
    fi
    cd -P -- backups 2> /dev/null || { echo "[limesurvey] cannot open clouve/backups" >&2; return 1; }
    if [ "$(pwd -P)" != "${root}/clouve/backups" ] || [ "$(stat -c %u . 2> /dev/null)" != 0 ]; then
        echo "[limesurvey] clouve/backups is not a folder of root's, so nothing in it is read, restored or written" >&2
        return 1
    fi
    # Root's own folder, closed to everyone else, whatever it was made with.
    [ "$(stat -c %a .)" = 700 ] || chmod 700 . || return 1
}

clv_backup_trusted() {
    local name="$1" f
    [ -d "${name}" ] && [ ! -L "${name}" ] && [ "$(stat -c %u -- "${name}" 2> /dev/null)" = 0 ] || return 1
    for f in "${clv_backup_files[@]}"; do
        [ -e "${name}/${f}" ] || [ -L "${name}/${f}" ] || continue
        [ -f "${name}/${f}" ] && [ ! -L "${name}/${f}" ] && [ "$(stat -c %u -- "${name}/${f}" 2> /dev/null)" = 0 ] || return 1
    done
}

clv_waiting() {
    local note="${clv_state_dir}/needs-attention" reason marker=no
    [ "$(clv_clouve)" = ok ] || return 1
    # A site that is served is not waiting, whatever an old note says.
    [ "$(clv_web_server)" != apache ] || return 1
    if clv_dir_trusted "${clv_backups_dir}" && [ -e "${clv_backups_dir}/RESTORE-IN-PROGRESS" ]; then marker=yes; fi
    if [ -f "${note}" ] && [ ! -L "${note}" ]; then
        # A note of kind restore says that the image waits for this skill's restore. Once the restore's marker is
        # gone, the image goes on with its start within seconds, and the note it has not removed yet means nothing.
        if [ "$(clv_waiting_note kind)" = restore ] && [ "${marker}" = no ]; then return 1; fi
        reason="$(clv_value "${note}" reason)"
        [ -n "${reason}" ] || reason="$(head -n 1 "${note}" 2> /dev/null | tr -d '\000-\037' | cut -c1-400)"
        printf '%s' "${reason:-the image gives no reason}"
        return 0
    fi
    if [ "${marker}" = yes ]; then
        printf 'a restore from a backup has not finished, and the start waits until it has'
        return 0
    fi
    return 1
}

clv_waiting_note() {
    local note="${clv_state_dir}/needs-attention" value
    [ "$(clv_clouve)" = ok ] && [ -f "${note}" ] && [ ! -L "${note}" ] || return 0
    value="$(clv_value "${note}" "$1")"
    case "$1" in
        kind) printf '%s' "${value}" | tr -cd 'a-z' ;;
        *) printf '%s' "${value}" | tr -cd '0-9A-Za-z:.+_ -' | cut -c1-60 ;;
    esac
}

clv_aside() {
    local d
    for d in "${clv_ls_root}"/clouve.untrusted-*; do
        [ -e "${d}" ] || [ -L "${d}" ] || continue
        printf '%s\n' "${d##*/}" | tr -cd '0-9A-Za-z._\n-'
    done
}

# clv_value FILE NAME: the value of the first NAME= line of FILE, without quotes and control characters
clv_value() {
    local line
    [ -f "$1" ] && [ ! -L "$1" ] || return 0
    while IFS= read -r line || [ -n "${line}" ]; do
        case "${line}" in
            "$2="*)
                line="${line#"$2="}"
                # A value in quotes loses them. A quote inside a value stays, as in "the skill's restore".
                case "${line}" in
                    \"*\" | \'*\') line="${line:1:${#line}-2}" ;;
                esac
                printf '%s' "${line}" | tr -d '\000-\037' | cut -c1-400
                return 0
                ;;
        esac
    done < "$1"
}

# clv_upgrade_folder: the path of the upgrade folder whose upgrade is under way, else of the newest one, or nothing
clv_upgrade_folder() {
    local d newest=''
    [ "$(clv_clouve)" = ok ] || return 0
    for d in "${clv_state_dir}"/upgrade-*-to-*; do
        [ -d "${d}" ] && [ ! -L "${d}" ] || continue
        case "$(clv_upgrade_phase "${d}")" in
            backup | upgrade | restore) printf '%s' "${d}"; return 0 ;;
        esac
        if [ -z "${newest}" ] || [ "${d}" -nt "${newest}" ]; then newest="${d}"; fi
    done
    printf '%s' "${newest}"
}

# clv_upgrade_phase FOLDER: the phase its state file names, in lower case; `none` without a state file
clv_upgrade_phase() {
    local f line phase=''
    for f in "$1/state" "$1/upgrade-state" "$1/STATE"; do
        [ -f "${f}" ] && [ ! -L "${f}" ] || continue
        while IFS= read -r line || [ -n "${line}" ]; do
            case "${line}" in
                phase=*) phase="${line#phase=}"; break ;;
                PHASE=*) phase="${line#PHASE=}"; break ;;
            esac
        done < "${f}"
        if [ -z "${phase}" ]; then IFS= read -r phase < "${f}" || :; fi
        phase="${phase%%[[:space:]]*}"
        phase="${phase//[\"\']/}"
        printf '%s' "${phase,,}"
        return 0
    done
    printf none
}

# clv_web_server: apache when Apache runs, standin when the image's stand-in page holds the port, else none
clv_web_server() {
    local comm
    for comm in /proc/[0123456789]*/comm; do
        if [ "$(cat "${comm}" 2> /dev/null)" = apache2 ]; then printf apache; return 0; fi
    done
    for comm in /proc/[0123456789]*/cmdline; do
        if tr '\0' ' ' < "${comm}" 2> /dev/null | grep -q -- 'php .*-S '; then printf standin; return 0; fi
    done
    printf none
}

# clv_job_lock: held when a backup, a restore or a backup copy holds clouve/backups/.lock, else free
clv_job_lock() {
    if [ "$(clv_clouve)" = ok ] && clv_dir_trusted "${clv_backups_dir}" && [ -f "${clv_backups_dir}/.lock" ] && [ ! -L "${clv_backups_dir}/.lock" ] \
        && ! flock -n "${clv_backups_dir}/.lock" true 2> /dev/null; then
        printf held
    else
        printf free
    fi
}

clv_state() {
    local folder phase='' name kb marker clouve failed skipped d died=no
    clouve="$(clv_clouve)"
    echo "clouve=${clouve}"
    echo "clouve_aside=$(clv_aside | tr '\n' ' ' | sed 's/ $//')"
    if name="$(clv_waiting)"; then
        echo waiting=yes
        echo "waiting_reason=${name}"
        # restore: the image waits for this skill's restore to finish. repair: a person has to repair the site.
        if clv_dir_trusted "${clv_backups_dir}" && [ -e "${clv_backups_dir}/RESTORE-IN-PROGRESS" ]; then
            echo waiting_kind=restore
        else
            echo waiting_kind=repair
        fi
        echo "waiting_since=$(clv_waiting_note since)"
        echo "waiting_from=$(clv_waiting_note from)"
        echo "waiting_to=$(clv_waiting_note to)"
    else
        echo waiting=no
    fi
    if [ "${clouve}" != ok ]; then
        # Nothing in an untrusted or missing folder is read.
        echo install=none
        echo upgrade_phase=none
        echo upgrade_failed=no
        echo upgrade_skipped=no
        echo restore=none
        echo job_lock=free
        echo backup_died=no
        echo "web_server=$(clv_web_server)"
        return 0
    fi
    if [ -e "${clv_state_dir}/install-in-progress" ]; then echo install=in-progress; else echo install=none; fi
    folder="$(clv_upgrade_folder)"
    if [ -n "${folder}" ]; then
        phase="$(clv_upgrade_phase "${folder}")"
        name="${folder##*/}"
        echo "upgrade_phase=${phase}"
        # The step within the phase: the image writes step= while it upgrades and rstep= on its way back.
        case "${phase}" in
            restore) echo "upgrade_step=$(clv_value "${folder}/state" rstep | tr -cd '0-9A-Za-z._-')" ;;
            backup | upgrade) echo "upgrade_step=$(clv_value "${folder}/state" step | tr -cd '0-9A-Za-z._-')" ;;
            *) echo upgrade_step= ;;
        esac
        if [ -e "${folder}/db-touched" ] || [ -L "${folder}/db-touched" ]; then echo upgrade_db_touched=yes; else echo upgrade_db_touched=no; fi
        echo "upgrade_folder=clouve/${name}"
        name="${name#upgrade-}"
        echo "upgrade_from=${name%%-to-*}"
        echo "upgrade_to=${name#*-to-}"
        kb="$(du -sk "${folder}" 2> /dev/null | cut -f1)"
        echo "kept_backup=clouve/${folder##*/}"
        echo "kept_backup_kb=${kb:-0}"
    else
        echo upgrade_phase=none
    fi
    failed="${clv_state_dir}/upgrade-failed"
    if [ -e "${failed}" ] || [ "${phase}" = failed ]; then
        echo upgrade_failed=yes
        # The image's note has the versions and the reason, also when it gave up before it made a folder.
        if [ -z "${folder}" ]; then
            echo "upgrade_from=$(clv_value "${failed}" from | tr -cd '0-9A-Za-z.+_-')"
            echo "upgrade_to=$(clv_value "${failed}" to | tr -cd '0-9A-Za-z.+_-')"
        fi
        echo "upgrade_failed_reason=$(clv_value "${failed}" reason)"
        echo "upgrade_failed_when=$(clv_value "${failed}" when | tr -cd '0-9A-Za-z:.+_ -')"
    else
        echo upgrade_failed=no
    fi
    skipped="${clv_state_dir}/upgrade-skipped"
    if [ -f "${skipped}" ] && [ ! -L "${skipped}" ]; then
        echo upgrade_skipped=yes
        echo "upgrade_skipped_reason=$(clv_value "${skipped}" reason)"
        echo "upgrade_skipped_from=$(clv_value "${skipped}" from | tr -cd '0-9A-Za-z.+_-')"
        echo "upgrade_skipped_to=$(clv_value "${skipped}" to | tr -cd '0-9A-Za-z.+_-')"
        name="$(clv_value "${skipped}" when)"
        [ -n "${name}" ] || name="$(clv_value "${skipped}" time)"
        echo "upgrade_skipped_when=$(printf '%s' "${name}" | tr -cd '0-9A-Za-z:.+_ -')"
    else
        echo upgrade_skipped=no
    fi
    marker="${clv_backups_dir}/RESTORE-IN-PROGRESS"
    if clv_dir_trusted "${clv_backups_dir}" && [ -e "${marker}" ]; then
        echo restore=in-progress
        echo "restore_backup=$(head -n 1 "${marker}" 2> /dev/null | tr -cd '0-9A-Za-z._-')"
    else
        echo restore=none
    fi
    name="$(clv_job_lock)"
    echo "job_lock=${name}"
    # What a backup that died leaves: its note about the maintenance mode, or a half-made folder.
    if [ "${name}" = free ] && clv_dir_trusted "${clv_backups_dir}"; then
        [ ! -e "${clv_backups_dir}/.maintenance-by-backup" ] || died=yes
        for d in "${clv_backups_dir}"/.making-* "${clv_backups_dir}"/.incoming-*; do
            if [ -e "${d}" ] || [ -L "${d}" ]; then died=yes; fi
        done
    fi
    echo "backup_died=${died}"
    echo "web_server=$(clv_web_server)"
}

clv_busy_reason() {
    local how="${1:-all}" folder phase restoring=no waiting=no why='' web
    if why="$(clv_waiting)"; then waiting=yes; fi
    if [ "$(clv_clouve)" = ok ]; then
        if clv_dir_trusted "${clv_backups_dir}" && [ -e "${clv_backups_dir}/RESTORE-IN-PROGRESS" ]; then restoring=yes; fi
        # While the image waits for a repair, its install and upgrade notes are what it stopped at, not work
        # that is going on.
        if [ "${waiting}" = no ]; then
            if [ -e "${clv_state_dir}/install-in-progress" ]; then
                echo "LimeSurvey is being installed in this container right now (clouve/install-in-progress is there). Nothing may change the site until the install has finished. Wait until the site answers, then run this again."
                return 0
            fi
            folder="$(clv_upgrade_folder)"
            if [ -n "${folder}" ]; then
                phase="$(clv_upgrade_phase "${folder}")"
                case "${phase}" in
                    backup | upgrade | restore)
                        echo "LimeSurvey is being upgraded right now (phase ${phase}, in clouve/${folder##*/}). Nothing may change the site until the upgrade has finished. upgrade-state.sh shows where it is."
                        return 0
                        ;;
                esac
            fi
        fi
        if [ "${restoring}" = yes ]; then
            if [ "${how}" = restore-ok ] || [ "${how}" = repair ]; then return 1; fi
            echo "A restore from a backup was started in this container and has not finished (clouve/backups/RESTORE-IN-PROGRESS is there). Finish it first, as playbooks/restore-from-backup.md says. verify-health.sh shows its state."
            return 0
        fi
    fi
    # The image starts its sshd first and Apache last. Until Apache runs, LimeSurvey is not served: the container
    # is waiting for its database, installing or upgrading, or waiting for a repair.
    web="$(clv_web_server)"
    if [ "${web}" != apache ]; then
        if [ "${waiting}" = yes ]; then
            if [ "${how}" = repair ]; then return 1; fi
            echo "The LimeSurvey container is waiting for a repair and serves no LimeSurvey (${why}). Nothing that changes survey data, sends email or runs LimeSurvey's own code works until it is repaired. upgrade-state.sh and verify-health.sh say what state it is in and what gets it out."
            return 0
        fi
        echo "The LimeSurvey container is still starting: its web server is not up yet. It may be waiting for its database, or installing or upgrading LimeSurvey. Nothing may change the site until it has finished. Wait until the site answers, then run this again. upgrade-state.sh and verify-health.sh show where it is."
        return 0
    fi
    return 1
}
