#!/usr/bin/env bash
# SuiteCRM skill: verify-health.sh
#
# A read-only report on this SuiteCRM: can the container be reached, has its start-up finished or does the
# container wait, is the image's state folder one that can be trusted, is an install, an upgrade or a restore
# under way or broken, did the image skip an upgrade, does the app answer, does the database answer and agree
# with the code on the version, do the scheduled jobs and the Messenger worker run, is anything left that
# should not be there, and how full is the disk. Run it first when something seems wrong, and again after a
# fix. It changes nothing, and it works while the image installs or upgrades and while the container waits,
# when the other scripts refuse.
#
# Usage: verify-health.sh
#
# Each check prints one line: OK, WARN or FAIL, the check's name, and what it found. The last line is
# "Overall: GREEN" (exit 0), "Overall: AMBER" (exit 2: something needs a look, SuiteCRM works) or
# "Overall: RED" (exit 3: SuiteCRM is down, half-upgraded or half-restored, its container is still starting or
# waits, or it can't be reached).
#
# The checks:
#   channel      the clouve-ops SSH channel into the SuiteCRM container. When it fails, the checks that read
#                inside the container are skipped, and the web and database checks still run.
#   start-up     PID 1 is Apache, which is the last thing the image's start-up becomes. When it is not: "the
#                container is waiting: a restore was cut off (run the restore again)" with a restore marker,
#                "the container is waiting: the image found a site that it must not start as it is" when the
#                image marks that (with what it found, from the image's note tmp/clouve-backup/needs-attention,
#                when that is there), "still running" during an install or an upgrade, "waiting or still
#                starting" otherwise.
#   state-dir    /var/www/html/tmp/clouve-backup, the image's state folder, is root's (or not there yet), and
#                so is this skill's backups folder. WARN when one is not (the web user can swap them; nothing
#                in such a folder is read) and when the image moved a state folder aside
#                (tmp/clouve-backup.untrusted-<UTC time>). Putting that right is a step for Clouve support.
#   install      no install-in-progress stamp
#   upgrade      no upgrade under way and none failed (upgrade-state.sh has the detail). WARN when the image
#                holds a newer version than the volume and did not start the upgrade, with the reason from the
#                image's upgrade-skipped note, or where to find it.
#   restore      no restore marker of this skill (tmp/clouve-backup/restore-in-progress, or the earlier
#                tmp/clouve-skill-backups/RESTORE-IN-PROGRESS)
#   web          http://<host>/session-status answers with "installed":true
#   database     the database answers over TCP
#   version      the version the database records as installed is the version of the code on the volume. SuiteCRM
#                8.10 writes that row as the last step of an install or an upgrade, so a missing or different
#                row means an upgrade that did not finish.
#   scheduler    not held (WARN when the hold file is there, when the image's scheduler setting is off, when
#                either could not be read, and when the image runs no job because a state folder is not
#                root's or staff's pause file is there), www-data's jobs ran in the last 15 minutes
#   worker       the Messenger worker runs, and little is waiting for it (WARN when it does not run; staff's
#                pause file stops it too)
#   migrations   no Manual Migration Task is waiting (after an upgrade there are seven)
#   leftovers    no config_si.php (the installer's file of clear-text passwords), the OAuth2 private key is
#                private, nothing in the caches, custom/ or upload/ belongs to a user other than www-data, no
#                upgrade work files
#   disk         the volume's use (WARN from 80%, FAIL from 95%), and what the backups take
#
# The database password goes to the mysql client in its environment (MYSQL_PWD), never in a command line.
#
# Env vars read:
#   SUITECRM_HOST                                         the SuiteCRM container
#   SUITECRM_DB_HOST, SUITECRM_DB_NAME, SUITECRM_DB_USER  the database
#   SUITECRM_DATABASE_PORT                                its port (default 3306)
#   the database password                                 from the agent's secret store (the loader line below)
#
# Exit codes: 0 GREEN; 2 AMBER; 3 RED; 1 a setting is missing.

set -uo pipefail
set +x
# run-in-suitecrm.sh prints a notice when its php, console or admin form is used by hand. This is not by hand.
export SC_SKILL_CALLER=verify-health.sh

case "${1:-}" in
    -h | --help)
        cat <<'USAGE'
Usage: verify-health.sh

A read-only report on SuiteCRM: the SSH channel, the start-up (finished, or the container waits), the image's
state folder, an install, upgrade or restore under way, an upgrade the image did not start, the web app, the
database and its version, the scheduled jobs, the Messenger worker, the Manual Migration Tasks, leftovers, and
disk use. One line per check (OK, WARN, FAIL), then Overall: GREEN, AMBER or RED.

Exit codes: 0 GREEN; 2 AMBER; 3 RED; 1 a setting is missing.
USAGE
        exit 0
        ;;
    '') ;;
    *) echo "[suitecrm/verify-health] verify-health.sh takes no arguments" >&2; exit 64 ;;
esac

for name in SUITECRM_HOST SUITECRM_DB_HOST SUITECRM_DB_NAME SUITECRM_DB_USER; do
    if [ -z "${!name:-}" ]; then
        echo "[suitecrm/verify-health] ${name} is not set" >&2
        exit 1
    fi
done
: "${SUITECRM_DB_PASSWORD:=$(clv-secret SUITECRM_DB_PASSWORD)}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run="${script_dir}/run-in-suitecrm.sh"
warns=0
fails=0
line() { printf '  %-5s %-11s %s\n' "$1" "$2" "$3"; }
good() { line OK "$1" "$2"; }
warn() { warns=$((warns + 1)); line WARN "$1" "$2"; }
fail() { fails=$((fails + 1)); line FAIL "$1" "$2"; }

echo "SuiteCRM health, $(date -u '+%Y-%m-%d %H:%M') UTC"

state="$("${run}" --allow-busy admin state 2> /dev/null)"
ssh_rc=$?
get() { printf '%s\n' "${state}" | sed -n "s/^$1=//p" | head -n 1; }
all() { printf '%s\n' "${state}" | sed -n "s/^$1=//p"; }
# newer A B: succeeds when version A is newer than version B
newer() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }
if [ "${ssh_rc}" -ne 0 ] || [ -z "${state}" ]; then
    fail channel "could not reach clouve-ops@${SUITECRM_HOST} (exit ${ssh_rc}). If the web check fails too, the platform has probably hidden the container because its health check fails; tell the user and Clouve support."
    have_state=0
else
    good channel "reached clouve-ops@${SUITECRM_HOST}"
    have_state=1
fi

if [ "${have_state}" -eq 1 ]; then
    pid1="$(get pid1)"
    phase="$(get upgrade_phase)"
    marker="$(get restore_marker)"
    dir_state="$(get state_dir)"
    image="$(get image_version)"
    volume="$(get version_file)"
    since=''
    if [[ $(get pid1_seconds) =~ ^[0-9]+$ ]]; then since=", for $(($(get pid1_seconds) / 60)) minute(s) now"; fi
    waiting="$(get waiting)"
    # What the image's note of a wait says (tmp/clouve-backup/needs-attention), when it is there
    note_reason="$(get attention_reason)"
    note_since="$(get attention_since)"
    note_since="${note_since:+, since ${note_since} UTC}"
    note_text=''
    if [ -n "${note_reason}" ]; then note_text=". The image's note says${note_since}: ${note_reason%.}"; fi
    aside="$(all moved_aside | sed 's|^|tmp/|' | paste -sd ' ' -)"
    if [ "${pid1}" = apache2 ]; then
        good start-up "finished (PID 1 is Apache)"
    elif [ "${marker}" = yes ] || [ "${waiting}" = restoring ]; then
        fail start-up "the container is waiting: a restore was cut off (run the restore again: playbooks/restore-from-backup.md). PID 1 is ${pid1:-unknown}, not Apache${since}${note_text}"
    elif [ "${waiting}" = attention ] && [ -n "${note_reason}" ]; then
        fail start-up "the container is waiting: the image found a site that it must not start as it is, and a person has to repair it first. PID 1 is ${pid1:-unknown}, not Apache${since}. What it found, in the words of the image's note${note_since}: ${note_reason%.} (upgrade-state.sh has the way out)"
    elif [ "${waiting}" = attention ] && [ -n "${aside}" ] && [ "${dir_state}" = absent ]; then
        fail start-up "the container is waiting: the image set its state folder aside as untrusted (${aside}) and has made no new one. Clouve support has to check it and put it back. PID 1 is ${pid1:-unknown}, not Apache${since} (upgrade-state.sh has more)"
    elif [ "${waiting}" = attention ]; then
        fail start-up "the container is waiting: the image found a site that it must not start as it is, and a person has to repair it first. PID 1 is ${pid1:-unknown}, not Apache${since}. What it found is in the container's log, which only Clouve support can read (upgrade-state.sh has the way out)"
    elif [ -n "$(get install_stamp)" ] || [ "${phase}" = backup ] || [ "${phase}" = upgrade ] || [ "${phase}" = restore ] || [ "${phase}" = as-is ]; then
        fail start-up "still running (PID 1 is ${pid1:-unknown}, not Apache${since}): the image is installing or upgrading"
    elif [ "$(get image_waits)" = yes ]; then
        fail start-up "waiting or still starting (PID 1 is ${pid1:-unknown}, not Apache${since}). This image marks it when it waits for a person, and it has marked nothing, so this is a start: it waits up to five minutes for the database (upgrade-state.sh)"
    else
        fail start-up "waiting or still starting (PID 1 is ${pid1:-unknown}, not Apache${since}). A start takes a few minutes; if this stays, the container is waiting, and why is in its log, which only Clouve support can read (upgrade-state.sh has the way out)"
    fi

    wrong=''
    if [ "${dir_state}" = untrusted ]; then wrong+="tmp/clouve-backup is not a folder of root's with mode 700, so nothing in it was read: the upgrade's state, the scheduler's hold and a restore marker are not known; "; fi
    if [ -n "${aside}" ]; then wrong+="the image moved a state folder aside because it did not trust it (${aside}); "; fi
    if [ "$(get skill_dir)" = untrusted ]; then wrong+="tmp/clouve-skill-backups is not a folder of root's with mode 700, so this skill's backups were not read; "; fi
    if [ -n "${wrong}" ]; then
        warn state-dir "${wrong%; }. Putting that right is a step for Clouve support, not one to take by yourself: change nothing there (upgrade-state.sh)"
    elif [ "${dir_state}" = absent ]; then
        good state-dir "the image has no state folder yet (it makes one at its first upgrade, and a restore makes one)"
    else
        good state-dir "the image's state folder is root's"
    fi

    if [ -n "$(get install_stamp)" ]; then
        fail install "an install is under way or was cut off ($(get install_stamp))"
    else
        good install "no install under way"
    fi
    case "${phase}" in
        unknown) warn upgrade "not known: the state folder was not read (state-dir)" ;;
        failed) fail upgrade "the last upgrade failed and the old version was put back: $(all state_text | tr '\n' ' ' | cut -c1-200) (upgrade-state.sh, playbooks/failed-upgrade.md)" ;;
        backup | upgrade | restore | as-is) fail upgrade "an upgrade is under way, phase ${phase}: leave SuiteCRM alone until it finishes (upgrade-state.sh)" ;;
        *)
            if newer "${image}" "${volume}" && [ "${pid1}" = apache2 ]; then
                if [ "$(get upgrade_skipped)" = yes ] && [ -n "$(get skipped_reason)" ]; then
                    why="$(get skipped_reason)"
                    why=", because ${why%.}"
                    if [ -n "$(get skipped_at)" ]; then why+=" (at $(get skipped_at))"; fi
                    warn upgrade "the image has ${image}, the volume runs ${volume}: the image did not start the upgrade${why}. It tries again at its next start; see the disk line (upgrade-state.sh, playbooks/failed-upgrade.md)"
                else
                    warn upgrade "the image has ${image}, the volume runs ${volume}: the image did not start the upgrade. The reason is in the container's log line that starts with [clouve-upgrade], which only Clouve support can read; see the disk line (upgrade-state.sh, playbooks/failed-upgrade.md)"
                fi
            elif newer "${image}" "${volume}"; then
                warn upgrade "the image has ${image}, the volume runs ${volume}: the upgrade has not started yet, because the start-up has not finished"
            elif newer "${volume}" "${image}"; then
                warn upgrade "the volume runs ${volume}, which is newer than the image's ${image}: a request to Clouve support"
            else
                good upgrade "no upgrade under way"
            fi
            ;;
    esac
    case "${marker}" in
        yes)
            if [ "${pid1}" = apache2 ]; then
                fail restore "$(get restore_marker_file) is there: a restore is running or was cut off (playbooks/restore-from-backup.md)"
            else
                fail restore "the container is waiting: a restore was cut off (run the restore again: playbooks/restore-from-backup.md); $(get restore_marker_file) is there"
            fi
            ;;
        unknown) warn restore "not known: the state folder was not read (state-dir)" ;;
        *) good restore "no restore under way" ;;
    esac
fi

web="$(curl -sS -m 20 -o - -w '\n%{http_code}' "http://${SUITECRM_HOST}/session-status" 2> /dev/null)"
web_code="${web##*$'\n'}"
case "${web}" in
    *'"installed":true'*) good web "the app answers and says it is installed" ;;
    *) fail web "http://${SUITECRM_HOST}/session-status did not answer as an installed app (HTTP ${web_code:-none})" ;;
esac

# query SQL: one value from the database over TCP; fails when it can't be reached
query() {
    MYSQL_PWD="${SUITECRM_DB_PASSWORD}" mysql --no-defaults -h "${SUITECRM_DB_HOST}" -P "${SUITECRM_DATABASE_PORT:-3306}" \
        -u "${SUITECRM_DB_USER}" --connect-timeout=10 -N -B "${SUITECRM_DB_NAME}" -e "$1" 2> /dev/null
}
if [ -z "${SUITECRM_DB_PASSWORD}" ]; then
    fail database "SUITECRM_DB_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
    have_db=0
elif ! command -v mysql > /dev/null 2>&1; then
    fail database "the mysql client is not installed (the suitecrm plugin's install.sh adds it)"
    have_db=0
elif [ "$(query 'SELECT 1')" = 1 ]; then
    good database "answers on ${SUITECRM_DB_HOST}"
    have_db=1
else
    fail database "${SUITECRM_DB_HOST} does not answer, or refuses the app's account"
    have_db=0
fi

if [ "${have_db}" -eq 1 ]; then
    row="$(query "SELECT value FROM config WHERE category = 'info' AND name = 'suitecrm_version'")"
    code="$(get version_file)"
    if [ -n "${row}" ] && { [ "${have_state}" -eq 0 ] || [ "${row}" = "${code}" ]; }; then
        good version "SuiteCRM ${row}"
    elif [ -z "${row}" ] && [[ ${code} == 8.9.* ]]; then
        good version "SuiteCRM ${code} (this version keeps no installed-version row)"
    elif [ -z "${row}" ]; then
        fail version "the code on the volume is ${code:-unknown} and the database records no installed version: an install or upgrade did not finish"
    else
        fail version "the code on the volume is ${code:-unknown} and the database records ${row}: an upgrade did not finish"
    fi

    held_why=''
    stuck_why=''
    if [ "${have_state}" -eq 1 ]; then
        if [ "$(get scheduler_held)" = yes ]; then held_why="tmp/clouve-backup/scheduler-held is there"; fi
        if [ "$(get scheduler_setting)" = off ]; then held_why="${held_why:+${held_why}, and }the image's scheduler setting is off, as on an install that existed before this image"; fi
        case " $(get scheduler_also) " in *' untrusted '* | *' moved-aside '*) stuck_why="a state folder that is not root's is on the volume, and a hold file in it can't be read (state-dir)" ;; esac
        case " $(get scheduler_also) " in *' loops-paused '*) stuck_why="${stuck_why:+${stuck_why}, and }staff's pause file tmp/clouve-backup/loops-paused is there" ;; esac
    fi
    if [ -n "${held_why}" ]; then
        warn scheduler "held (${held_why}): no scheduled job runs, so no workflows, reminders, inbound mail or campaign mail. scheduler.sh release shows what would start, then scheduler.sh release --yes-release after the user's yes${stuck_why:+. The image also runs no scheduled job for now because ${stuck_why}: a request to Clouve support}"
    elif [ -n "${stuck_why}" ]; then
        warn scheduler "the image runs no scheduled job for now, because ${stuck_why}. A release does not change that: a request to Clouve support"
    elif [ "${have_state}" -eq 1 ] && [ "$(get scheduler_held)" = unknown ]; then
        warn scheduler "whether it is held is not known: the state folder was not read (state-dir)"
    elif [ "${have_state}" -eq 1 ] && [ "$(get scheduler_setting)" = unknown ]; then
        warn scheduler "whether it is held is not known: the image's scheduler setting could not be read"
    else
        minutes="$(query "SELECT TIMESTAMPDIFF(MINUTE, MAX(last_run), UTC_TIMESTAMP()) FROM schedulers WHERE deleted = 0")"
        if [[ ${minutes} =~ ^-?[0-9]+$ ]] && [ "${minutes}" -le 15 ]; then
            good scheduler "scheduled jobs ran ${minutes} minute(s) ago"
        elif [[ ${minutes} =~ ^[0-9]+$ ]]; then
            warn scheduler "no scheduled job has run for ${minutes} minutes (scheduler.sh status)"
        else
            warn scheduler "no scheduled job has run yet (on a new install the first pass comes within a few minutes; scheduler.sh status)"
        fi
    fi

    # The Messenger worker came with 8.10. The code's version says which is running: 8.9 keeps no version row.
    running="${code:-${row}}"
    if [[ ${running} == 8.9.* ]]; then
        good worker "SuiteCRM ${running} has no Messenger worker"
    else
        waiting="$(query "SELECT COUNT(*) FROM messenger_messages WHERE queue_name <> 'failed' AND delivered_at IS NULL")"
        if [ "${have_state}" -eq 1 ] && [ "$(get messenger_worker)" != yes ] && [[ " $(get scheduler_also) " == *' loops-paused '* ]]; then
            warn worker "the Messenger worker is not running, because staff's pause file tmp/clouve-backup/loops-paused is there, so background tasks wait (${waiting:-?} waiting). Only Clouve support removes that file"
        elif [ "${have_state}" -eq 1 ] && [ "$(get messenger_worker)" != yes ]; then
            warn worker "the Messenger worker is not running, so background tasks wait (${waiting:-?} waiting). The image restarts it; tell Clouve support if it stays down"
        elif [[ ${waiting} =~ ^[0-9]+$ ]] && [ "${waiting}" -gt 100 ]; then
            warn worker "${waiting} messages are waiting for the Messenger worker (scheduler.sh status)"
        else
            good worker "running, ${waiting:-0} message(s) waiting"
        fi
        tasks="$(query "SELECT COUNT(*) FROM manual_migration_tasks WHERE status = 'initial'")"
        if [[ ${tasks} =~ ^[0-9]+$ ]] && [ "${tasks}" -gt 0 ]; then
            warn migrations "${tasks} Manual Migration Task(s) wait for an admin to start them (playbooks/after-an-upgrade.md)"
        else
            good migrations "no Manual Migration Task is waiting"
        fi
    fi
fi

if [ "${have_state}" -eq 1 ]; then
    left=''
    if [ "$(get config_si)" = yes ]; then left+="public/legacy/config_si.php is there (the installer's clear-text passwords; the image removes it at a start); "; fi
    case "$(get oauth_private_key_mode)" in
        400 | 440 | 600 | 640 | 660 | '') ;;
        *) left+="the OAuth2 private key is mode $(get oauth_private_key_mode), not 600; " ;;
    esac
    stray="$(get not_owned_by_www_data)"
    if [[ ${stray} =~ ^[0-9]+$ ]] && [ "${stray}" -gt 0 ]; then left+="${stray} file(s) in the caches, custom/ or upload/ do not belong to www-data (something ran as root); "; fi
    work="$(get upgrade_leftover_bytes)"
    if [[ ${work} =~ ^[0-9]+$ ]] && [ "${work}" -gt 1048576 ]; then left+="$((work / 1048576)) MB of upgrade work files in tmp/package/upgrade; "; fi
    if [ -n "${left}" ]; then warn leftovers "${left%; }"; else good leftovers "nothing that should not be there"; fi

    total="$(get disk_total)"
    used="$(get disk_used)"
    if [[ ${total} =~ ^[0-9]+$ ]] && [[ ${used} =~ ^[0-9]+$ ]] && [ "${total}" -gt 0 ]; then
        pct=$((used * 100 / total))
        kept_bytes="$(printf '%s\n' "${state}" | sed -n 's/^kept_backup=//p' | awk -F'\t' '{ s += $2 } END { print s + 0 }')"
        skill_bytes="$(get skill_backups_bytes)"
        note="${pct}% of $((total / 1073741824)) GB used; this skill's backups $((${skill_bytes:-0} / 1048576)) MB, backups kept by upgrades $((kept_bytes / 1048576)) MB"
        if [ "${pct}" -ge 95 ]; then
            fail disk "${note}. SuiteCRM stops working when the volume is full"
        elif [ "${pct}" -ge 80 ]; then
            warn disk "${note}"
        else
            good disk "${note}"
        fi
    fi
fi

if [ "${fails}" -gt 0 ]; then
    echo "Overall: RED (${fails} failed, ${warns} to look at)"
    exit 3
fi
if [ "${warns}" -gt 0 ]; then
    echo "Overall: AMBER (${warns} to look at)"
    exit 2
fi
echo "Overall: GREEN"
exit 0
