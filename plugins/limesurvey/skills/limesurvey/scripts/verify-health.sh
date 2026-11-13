#!/usr/bin/env bash
# LimeSurvey skill: verify-health.sh
#
# A report on this LimeSurvey: the SSH channel, the state of an install, upgrade or restore, a container that is
# still starting or waiting for a repair, the web server, the database, the versions, the encryption keys,
# maintenance mode, email, plugins, disk space and backups. Run it first when something seems wrong, and again
# after a fix. It prints no password and no personal data.
#
# It reads, with one exception. When a backup died (its process was killed, the container was stopped) and left
# the site locked in maintenance mode or a half-made folder behind, this cleans that up, as the next backup or
# restore would: it puts the maintenance mode back to what that backup had found, and only when that backup had
# set it, and removes the half-made folder. The report says so in a [WARN] line. It never does this while a
# backup or a restore is running.
#
# Usage: verify-health.sh
#
# Each line is `[OK]`, `[WARN]` or `[FAIL]`, a name and what was found. The last line is
# `Overall: GREEN`, `AMBER` (at least one WARN) or `RED` (at least one FAIL).
#
# While security.php is missing it asks the web server nothing: a request makes LimeSurvey start, and LimeSurvey
# makes a new security.php, with new keys, when it starts without one.
#
# What it reads:
#   - from inside the LimeSurvey container, in one call (remote/health.sh, sent by run-in-limesurvey.sh): the
#     image's state files, LimeSurvey's config and version files, the database through LimeSurvey's own settings,
#     the disks, and the web server on the container's own port;
#   - from the agent: the web server at http://<LIMESURVEY_HOST>:8080/ and the database over TCP, with the
#     password in the environment of that one command.
#
# Env vars read:
#   LIMESURVEY_HOST                        the LimeSurvey container
#   LIMESURVEY_DB_HOST, LIMESURVEY_DB_PORT, LIMESURVEY_DB_NAME, LIMESURVEY_DB_USER   the database, for the TCP check
#   the database password                  for that check. A current agent keeps it out of the environment; the
#                                          loader line below fetches it then.
#
# Exit codes:
#   0    GREEN
#   2    AMBER
#   3    RED
#   1    LIMESURVEY_HOST is not set, or a tool is missing

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the database password.
set +x

usage() {
    cat <<'USAGE'
Usage: verify-health.sh

A report on this LimeSurvey: the SSH channel, an install, upgrade or restore under way, a container that is
starting or waiting for a repair, the web server, the database, the versions, the encryption keys, maintenance
mode, email, plugins, disk space and backups. Each line is [OK], [WARN] or [FAIL]. It prints no password.

It reads, with one exception: when a backup died and left the site locked or a half-made folder behind, it puts
the maintenance mode back to what that backup had found and removes the folder, and says so.

Exit codes: 0 GREEN, 2 AMBER (a warning), 3 RED (a failure), 1 a missing setting or tool.
USAGE
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) echo "[limesurvey/verify-health] unknown option: $1" >&2; usage >&2; exit 1 ;;
esac

if [ -z "${LIMESURVEY_HOST:-}" ]; then
    echo "[limesurvey/verify-health] LIMESURVEY_HOST is not set (compgen -e | grep -i limesurvey lists the settings this agent has)" >&2
    exit 1
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warns=0
fails=0
ok() { printf '[OK]   %s: %s\n' "$1" "$2"; }
warn() { printf '[WARN] %s: %s\n' "$1" "$2"; warns=$((warns + 1)); }
fail() { printf '[FAIL] %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }
finish() {
    if [ "${fails}" -gt 0 ]; then echo "Overall: RED"; exit 3; fi
    if [ "${warns}" -gt 0 ]; then echo "Overall: AMBER"; exit 2; fi
    echo "Overall: GREEN"
    exit 0
}
# mb BYTES: megabytes, rounded down
mb() { printf '%s' "$((${1:-0} / 1048576))"; }

# --- Inside the LimeSurvey container ---------------------------------------------------------------------------------
report="$("${script_dir}/run-in-limesurvey.sh" health.sh 2> /dev/null)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    case "${rc}" in
        255) fail channel "could not reach clouve-ops@${LIMESURVEY_HOST}. The platform hides a pod whose health check fails, so look at the database first" ;;
        1) fail channel "the clouve-ops password or a tool is missing on the agent (run-in-limesurvey.sh state.sh says which)" ;;
        *) fail channel "the report from inside the container failed (exit ${rc})" ;;
    esac
else
    ok channel "clouve-ops@${LIMESURVEY_HOST} answers over SSH"
fi
# get NAME: the value of NAME in the report
get() {
    local line
    while IFS= read -r line; do
        if [ "${line%%=*}" = "$1" ]; then printf '%s' "${line#*=}"; return 0; fi
    done <<< "${report}"
    return 1
}

busy=no
if [ "${rc}" -eq 0 ]; then
    if [ "$(get clouve)" = untrusted ]; then
        fail clouve "/var/www/html/clouve is a link or does not belong to root, so it is not the folder the Clouve image made. Nothing in it is read: the state of an install or upgrade can't be told, and the backups in it don't count. The image moves such a folder aside at its next start. Tell the user to contact Clouve support"
    fi
    aside="$(get clouve_aside)"
    if [ -n "${aside}" ]; then
        warn clouve "the image moved aside what stood in the place of its state folder and was not root's own: ${aside}. It may hold an upgrade's backup and this skill's backups. Putting it back is a step for Clouve support, not for you: tell the user"
    fi
    waiting="$(get waiting)"
    if [ "${waiting}" = yes ]; then
        # The reason and the time are the image's own, from its note clouve/needs-attention.
        since="$(get waiting_since)"
        since="${since:+, since ${since} UTC}"
        if [ "$(get restore)" = in-progress ]; then
            fail waiting "the container is waiting for a repair and serves no LimeSurvey ($(get waiting_reason))${since}. The way out: run the unfinished restore again (playbooks/restore-from-backup.md). The Clouve dashboard shows the deployment as running meanwhile"
        else
            fail waiting "the container is waiting for a repair and serves no LimeSurvey ($(get waiting_reason))${since}. It does not restart by itself, and the Clouve dashboard shows the deployment as running. Change nothing and tell the user to contact Clouve support (playbooks/recover-from-a-failed-upgrade.md)"
        fi
        busy=yes
    elif [ "$(get install)" != in-progress ] && [ -n "$(get web_server)" ] && [ "$(get web_server)" != apache ]; then
        case "$(get upgrade_phase)" in
            backup | upgrade | restore) ;;
            *)
                warn starting "the container is still starting: its web server is not up yet, and it shows the image's stand-in page. The image shows that page while it waits for its database (up to five minutes, then the container starts again). The database line below says whether it answers"
                busy=yes
                ;;
        esac
    fi
    if [ "$(get install)" = in-progress ]; then
        warn install "LimeSurvey is being installed right now. Wait until the site answers"
        busy=yes
    fi
    phase="$(get upgrade_phase)"
    case "${phase}" in
        backup | upgrade | restore)
            warn upgrade "an upgrade from $(get upgrade_from) to $(get upgrade_to) is under way (phase ${phase}). Nothing may change the site until it has finished"
            busy=yes
            ;;
    esac
    if [ "$(get upgrade_failed)" = yes ]; then
        from="$(get upgrade_from)"
        to="$(get upgrade_to)"
        reason="$(get upgrade_failed_reason)"
        fail upgrade "the upgrade${from:+ from ${from}}${to:+ to ${to}} failed and the old version was put back. The image's reason: ${reason:-it recorded none}. playbooks/recover-from-a-failed-upgrade.md"
    elif [ "${busy}" = no ] && [ -n "$(get kept_backup)" ]; then
        ok upgrade "the upgrade from $(get upgrade_from) to $(get upgrade_to) is done. Its backup is kept in $(get kept_backup) ($(($(get kept_backup_kb) / 1024)) MB): remove it once the admin has checked the site (upgrade-state.sh)"
    elif [ "${busy}" = no ]; then
        ok upgrade "no upgrade is under way"
    fi
    if [ "$(get upgrade_skipped)" = yes ]; then
        from="$(get upgrade_skipped_from)"
        to="$(get upgrade_skipped_to)"
        reason="$(get upgrade_skipped_reason)"
        warn upgrade "the image did not try the upgrade${from:+ from ${from}}${to:+ to ${to}} at its last start, and changed nothing. Its reason: ${reason:-it recorded none}. The site runs the old version, and the next start tries again. playbooks/recover-from-a-failed-upgrade.md (\"The upgrade was not tried\")"
    fi
    if [ "$(get restore)" = in-progress ]; then
        fail restore "a restore of the backup $(get restore_backup) was started and has not finished. playbooks/restore-from-backup.md says how to finish it"
    fi
    if [ "$(get job_lock)" = held ]; then
        warn jobs "a backup or a restore is running in the container right now. Maintenance mode is on while it runs: leave it, and wait for the run to end"
    fi
    recovered="$(get backup_recovered)"
    if [ "$(get backup_recovery)" = failed ]; then
        fail backup "a backup was cut off earlier and left LimeSurvey locked in maintenance mode, and the lock could not be lifted from here${recovered:+ (done so far: ${recovered})}. When no backup or restore is running, console.sh setmaintenancemode off lifts it, after a yes"
    elif [ -n "${recovered}" ]; then
        warn backup "a backup was cut off earlier (its process was killed, or the container was stopped). This run cleaned up after it: ${recovered}. No backup was made by that run: take a new one"
    fi

    for f in config_php security_php; do
        name="application/config/${f%_php}.php"
        case "$(get "${f}")" in
            present) ok "${f%_php}.php" "${name} is there" ;;
            unreadable) fail "${f%_php}.php" "${name} is there, but www-data cannot read it" ;;
            *)
                if [ "${busy}" = yes ]; then
                    warn "${f%_php}.php" "${name} is not there yet"
                elif [ "${f}" = security_php ]; then
                    fail security.php "${name} is missing. It holds the encryption keys. Do not start anything in LimeSurvey: it would make new keys. Put the keys back alone from a backup (playbooks/restore-from-backup.md, \"Only the keys are missing or wrong\")"
                else
                    fail config.php "${name} is missing, so LimeSurvey is not installed"
                fi
                ;;
        esac
    done

    code="$(get code_version)"
    case "${code}" in
        '') [ "${busy}" = yes ] || fail version "LimeSurvey's version could not be read" ;;
        7.10.*) ok version "LimeSurvey ${code}, build $(get code_build)$(get image_build > /dev/null && printf ' (image %s)' "$(get image_build)")" ;;
        *) warn version "LimeSurvey ${code}. This skill was written and tested against 7.10.0, so check what you read here against what you see" ;;
    esac

    db="$(get db)"
    if [ "${db}" = ok ]; then
        dbv="$(get db_version)"
        codev="$(get code_dbversion)"
        if [ "$(get db_update_incomplete)" != 0 ]; then
            fail database "a database update was cut off (DBUpdateIncomplete). playbooks/recover-from-a-failed-upgrade.md"
        elif [ -z "${dbv}" ]; then
            fail database "the database answers but has no LimeSurvey tables"
        elif [ "${dbv}" = "${codev}" ]; then
            ok database "answers, at version ${dbv}, as the code expects ($(get surveys) surveys, $(get surveys_active) active, $(mb "$(get db_bytes)") MB)"
        elif [ "${dbv}" -lt "${codev}" ] 2> /dev/null; then
            fail database "is at version ${dbv} and the code needs ${codev}: the database update has not run. playbooks/recover-from-a-failed-upgrade.md"
        else
            fail database "is at version ${dbv}, newer than the code's ${codev}. LimeSurvey must not run like this. Tell the user; this needs Clouve's help"
        fi
        mode="$(get maintenance)"
        case "${mode}" in
            off | '') ok maintenance "off" ;;
            hard-cli)
                if [ "$(get job_lock)" = held ]; then
                    warn maintenance "hard-cli: participants and admins are locked out while the backup or restore that is running holds the lock. Leave it"
                else
                    warn maintenance "hard-cli: participants and admins are locked out, and no backup or restore is running in the container. Nothing lifts this mode by itself: an admin set it, or an upgrade that was cut off and repaired by hand left it on. If no upgrade is under way either, console.sh setmaintenancemode off lifts it, after a yes"
                fi
                ;;
            *) warn maintenance "${mode}: participants see a maintenance page" ;;
        esac
        if [ "$(get superadmins)" = 0 ]; then fail admins "no account has the superadmin permission"; else ok admins "$(get admins) admin accounts, $(get superadmins) superadmin"; fi
        if [ "$(get tables_myisam)" != 0 ]; then
            ok tables "$(get tables_myisam) MyISAM and $(get tables_innodb) InnoDB tables (an older install keeps MyISAM; backup.sh locks the site while it dumps for that reason)"
        fi
        method="$(get email_method)"
        if [ "${method}" = smtp ] || [ "${method}" = plugin ]; then
            ok email "method ${method} (mail-settings.sh show has the details)"
        elif [ "$(get sendmail)" = yes ]; then
            ok email "method ${method}"
        else
            warn email "method ${method}, which needs a sendmail program, and the container has none: no mail can go out until the admin sets up SMTP (playbooks/set-up-email.md)"
        fi
        if [ "$(get plugins_load_error)" != 0 ]; then
            warn plugins "$(get plugins_load_error) plugin(s) are marked as broken (extensions.sh plugins shows which)"
        elif [ "$(get plugins_off)" != 0 ]; then
            ok plugins "$(get plugins_off) added plugin(s) are off (extensions.sh plugins-off-after-upgrade)"
        else
            ok plugins "no added plugin is off"
        fi
        case "$(get keys)" in
            ok) ok keys "the encryption keys read what the database holds encrypted" ;;
            wrong) fail keys "security.php does not hold the keys the database was encrypted with: encrypted answers, participant details and the SMTP password cannot be read. Put the original keys back alone from a backup (playbooks/restore-from-backup.md, \"Only the keys are missing or wrong\")" ;;
            untested) ok keys "nothing encrypted is stored yet, so there was nothing to test the keys with" ;;
            *) [ "${busy}" = yes ] || warn keys "the encryption keys were not tested (security.php is missing or holds no keys)" ;;
        esac
    elif [ -n "${db}" ]; then
        if [ "${busy}" = yes ]; then warn database "does not answer from the LimeSurvey container yet"; else fail database "does not answer from the LimeSurvey container: ${db#down:}"; fi
    fi

    debug="$(get debug)"
    if [ -n "${debug}" ] && [ "${debug}" != 0 ]; then
        warn debug "debug is ${debug} in config.php: every visitor sees error details. playbooks/diagnose-problems.md has the one command that sets it back to 0"
    fi
    if [ -n "$(get code_version)" ] && [ -z "$(get publicurl)" ]; then
        warn publicurl "config.php has no public address, so links in emails would point at localhost"
    fi

    web="$(get web_root)"
    if [ "${web}" = skipped ]; then
        warn web "not asked: a request would make LimeSurvey start, and without security.php it would make new encryption keys"
    elif [ "${web}" = 200 ]; then
        if [ "$(get web_server)" = standin ] || [ "${busy}" = yes ]; then
            warn web "the container answers with the image's stand-in page, not with LimeSurvey. It shows while an install or an upgrade runs, while a start waits for the database, and while the container waits for a repair"
        else
            ok web "LimeSurvey answers on its own port (HTTP 200)"
        fi
    elif [ "${busy}" = yes ]; then
        warn web "the container does not answer on port 8080 yet (HTTP ${web})"
    else
        fail web "LimeSurvey does not answer on its own port (HTTP ${web})"
    fi

    for d in disk_html disk_upload; do
        read -r pct free size <<< "$(get "${d}")"
        [ -n "${pct:-}" ] || continue
        label="disk /var/www/html"
        if [ "${d}" = disk_upload ]; then
            # The two can be one volume in a local run.
            [ "$(get disk_upload)" != "$(get disk_html)" ] || continue
            label="disk /var/www/html/upload"
        fi
        text="${pct}% used, $(mb "${free}") MB free of $(mb "${size}") MB"
        if [ "${pct}" -ge 95 ]; then fail "${label}" "${text}. LimeSurvey stops working when the disk is full"
        elif [ "${pct}" -ge 85 ]; then warn "${label}" "${text}"
        else ok "${label}" "${text}"; fi
    done
    if [ "$(get root_owned_tmp)" != 0 ] && [ -n "$(get root_owned_tmp)" ]; then
        warn "tmp files" "$(get root_owned_tmp) files under tmp/ belong to root, so LimeSurvey cannot replace them (reference/troubleshooting.md has the fix)"
    fi
    backups="$(get backups)"
    if [ "$(get backups_untrusted)" != 0 ] && [ -n "$(get backups_untrusted)" ]; then
        fail backups "clouve/backups, or $(get backups_untrusted) folder(s) in it, is a link or does not belong to root. Such a folder is not a backup this skill made: it is not listed and can't be restored. Someone or something put it there. Tell the user to contact Clouve support"
    fi
    if [ "${backups:-0}" = 0 ]; then
        warn backups "there is no backup of this site yet (playbooks/back-up.md)"
    else
        age="$(get backup_newest_age)"
        how_old=''
        if [[ "${age}" =~ ^[0-9]+$ ]]; then
            if [ "${age}" -ge 172800 ]; then how_old=", made $((age / 86400)) days ago"
            elif [ "${age}" -ge 7200 ]; then how_old=", made $((age / 3600)) hours ago"
            else how_old=", made $((age / 60)) minutes ago"; fi
        fi
        ok backups "${backups} backup(s), the newest is $(get backup_newest)${how_old} ($(($(get backups_kb) / 1024)) MB in all, on LimeSurvey's own volume)"
    fi
    if [ "$(get rpc_interface)" != off ] && [ -n "$(get rpc_interface)" ]; then
        ok remotecontrol "the admin has LimeSurvey's RemoteControl switched on ($(get rpc_interface)). This skill does not need it and leaves it alone"
    fi
fi

# --- From the agent ---------------------------------------------------------------------------------------------------
if [ "${rc}" -eq 0 ] && [ "$(get web_root)" = skipped ]; then
    : # not asked, for the reason above
elif command -v curl > /dev/null 2>&1; then
    http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${LIMESURVEY_HOST}:8080/" 2> /dev/null)"
    if [ "${http}" = 200 ]; then
        ok "web from the agent" "http://${LIMESURVEY_HOST}:8080/ answers 200"
    elif [ "${busy}" = yes ]; then
        warn "web from the agent" "http://${LIMESURVEY_HOST}:8080/ answers ${http:-nothing}"
    else
        fail "web from the agent" "http://${LIMESURVEY_HOST}:8080/ answers ${http:-nothing}"
    fi
else
    warn "web from the agent" "curl is not installed on the agent (the limesurvey plugin's install.sh adds it)"
fi

# The database password, for the one command below that checks the database over TCP.
: "${LIMESURVEY_DB_PASSWORD:=$(clv-secret LIMESURVEY_DB_PASSWORD)}"
if [ -n "${LIMESURVEY_DB_HOST:-}" ] && [ -n "${LIMESURVEY_DB_NAME:-}" ] && [ -n "${LIMESURVEY_DB_USER:-}" ]; then
    client="$(command -v mysql || command -v mariadb || true)"
    if [ -z "${client}" ]; then
        warn "database from the agent" "no mysql client on the agent (the limesurvey plugin's install.sh adds it)"
    else
        if [ -z "${LIMESURVEY_DB_PASSWORD}" ]; then
            warn "database from the agent" "the database password is not available on this agent (clv-secret --list shows the passwords it has)"
        elif answer="$(MYSQL_PWD="${LIMESURVEY_DB_PASSWORD}" "${client}" --no-defaults -h "${LIMESURVEY_DB_HOST}" -P "${LIMESURVEY_DB_PORT:-3306}" -u "${LIMESURVEY_DB_USER}" --connect-timeout=10 -N -B -e 'SELECT 1' "${LIMESURVEY_DB_NAME}" 2>&1)" && [ "${answer}" = 1 ]; then
            ok "database from the agent" "${LIMESURVEY_DB_HOST} answers over TCP"
        else
            fail "database from the agent" "${LIMESURVEY_DB_HOST} does not answer over TCP: $(printf '%s' "${answer}" | head -n 1 | cut -c1-160)"
        fi
    fi
else
    warn "database from the agent" "LIMESURVEY_DB_HOST, LIMESURVEY_DB_NAME or LIMESURVEY_DB_USER is not set on this agent"
fi

finish
