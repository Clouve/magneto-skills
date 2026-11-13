#!/usr/bin/env bash
# LimeSurvey skill: remote/health.sh
#
# Runs INSIDE the LimeSurvey container, as root, sent by run-in-limesurvey.sh (verify-health.sh is its front end on
# the agent, and turns what this prints into the report). It reads, with one exception: when a backup died and
# left the site locked or a half-made folder behind, it cleans that up (lib/site.sh, ls_recover_dead_backup), as
# backup.sh and restore.sh do, and says so. It prints NAME=value lines:
#
#   the state lines of lib/state.sh (clouve, install, upgrade_phase, upgrade_failed, upgrade_skipped, restore,
#                                       job_lock, backup_died, web_server, ...)
#   config_php, security_php            present, missing, or unreadable (www-data cannot read it)
#   code_version, code_dbversion, code_build, image_build
#   db                                  ok, or down:<the client's message>
#   db_version, db_update_incomplete, maintenance, surveys, surveys_active, admins, superadmins
#   tables_myisam, tables_innodb, db_bytes
#   email_method, sendmail              sendmail is yes or no: whether the container has the program
#   debug, publicurl, rpc_interface
#   plugins_off, plugins_load_error
#   web_root, web_version_info          the HTTP status of / and what /index.php/rest/v1/version-info says;
#                                       web_root is `skipped` while security.php is missing, because a request
#                                       would make LimeSurvey create new encryption keys
#   keys                                ok, wrong, untested (nothing encrypted is stored) or unknown: whether the keys
#                                       in security.php read what the database holds encrypted (the stored SMTP
#                                       password, encrypted participant fields, encrypted answers). LimeSurvey is
#                                       not started for it.
#   disk_html, disk_upload              <used percent> <free bytes> <size bytes>
#   root_owned_tmp                      how many files under tmp/ belong to root (www-data cannot replace those)
#   backups, backup_newest, backup_newest_age, backups_kb, backups_untrusted
#   backup_recovered                    what was cleaned up after a backup that died, or nothing
#   backup_recovery                     failed, when a dead backup's lock on the site could not be lifted yet
#
# It prints no password and no personal data. Exit code: 0, also when something it reports is wrong.

# SC2154: lib/state.sh and lib/site.sh, sourced below, set clv_backups_dir, ls_root, site_work and the db_*, code_*
# and cfg_* variables.
# shellcheck disable=SC2154

set -uo pipefail
set +x

remote_dir="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=/dev/null
. "${remote_dir}/lib/state.sh" || exit 1
# shellcheck source=/dev/null
. "${remote_dir}/lib/site.sh" || exit 1

trap '[ -z "${site_work}" ] || rm -rf -- "${site_work}"' EXIT

clv_state

config_dir="${ls_root}/application/config"
for f in config.php security.php; do
    key="${f%.php}_php"
    if [ ! -f "${config_dir}/${f}" ]; then
        echo "${key}=missing"
    elif ! sudo -n -u www-data test -r "${config_dir}/${f}" 2> /dev/null; then
        echo "${key}=unreadable"
    else
        echo "${key}=present"
    fi
done
if [ -f /clouve/limesurvey/image-build ]; then echo "image_build=$(head -n 1 /clouve/limesurvey/image-build | tr -cd '0-9A-Za-z.+_-')"; fi

# df LINE NAME: used percent, free bytes and size of the volume that holds a folder
disk() {
    df -PB1 "$2" 2> /dev/null | awk -v name="$1" 'NR == 2 { gsub("%", "", $5); print name "=" $5 " " $4 " " $2 }'
}
disk disk_html "${ls_root}"
disk disk_upload "${ls_root}/upload"
echo "root_owned_tmp=$(find "${ls_root}/tmp" -xdev -user root 2> /dev/null | head -n 1000 | wc -l | tr -d ' ')"

count=0
newest=''
untrusted=0
backups_ok=no
if [ "$(clv_clouve)" = ok ] && clv_dir_trusted "${clv_backups_dir}"; then
    backups_ok=yes
    for d in "${clv_backups_dir}"/[0-9]*-[0-9]*; do
        [ -e "${d}" ] || [ -L "${d}" ] || continue
        [[ "${d##*/}" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
        if ! (cd "${clv_backups_dir}" && clv_backup_trusted "${d##*/}"); then untrusted=$((untrusted + 1)); continue; fi
        [ -f "${d}/SHA256SUMS" ] || continue
        count=$((count + 1))
        newest="${d##*/}"
    done
    echo "backups_kb=$(du -sk "${clv_backups_dir}" 2> /dev/null | cut -f1)"
elif [ -e "${clv_backups_dir}" ] || [ -L "${clv_backups_dir}" ]; then
    untrusted=1
    echo backups_kb=0
else
    echo backups_kb=0
fi
echo "backups=${count}"
echo "backup_newest=${newest}"
if [[ "${newest}" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2})$ ]]; then
    made="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2> /dev/null)" && echo "backup_newest_age=$(($(date -u +%s) - made))"
fi
echo "backups_untrusted=${untrusted}"
if command -v sendmail > /dev/null 2>&1 || [ -x /usr/sbin/sendmail ]; then echo sendmail=yes; else echo sendmail=no; fi

# A request makes LimeSurvey start, and LimeSurvey makes a new security.php, with new keys, when it starts without
# one. So the web server is not asked while the file is missing.
if [ -f "${config_dir}/config.php" ] && [ ! -f "${config_dir}/security.php" ]; then
    echo web_root=skipped
else
    web="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/ 2> /dev/null)"
    echo "web_root=${web:-000}"
    info="$(curl -s --max-time 10 http://localhost:8080/index.php/rest/v1/version-info 2> /dev/null | tr -cd '0-9A-Za-z:,"{}' | head -c 200)"
    echo "web_version_info=${info}"
fi

if ! ls_site_read; then
    echo "db=down:LimeSurvey's database settings could not be read from config.php"
    exit 0
fi
echo "code_version=${code_version}"
echo "code_dbversion=${code_dbversion}"
echo "code_build=${code_build}"
echo "debug=${cfg_debug}"
echo "publicurl=${cfg_publicurl}"
if ! ls_site_client; then
    echo "db=down:no database client in the container"
    exit 0
fi
if ! ls_sql 'SELECT 1' > /dev/null 2> "${site_work}/err"; then
    echo "db=down:$(head -n 1 "${site_work}/err" | head -c 200)"
    exit 0
fi
echo db=ok

# A backup that died: with the lock in hand (so that no backup is alive), remove what it left half-made and put
# the maintenance mode back to what it had found. Nothing is done while a backup or a restore runs, or while a
# restore is unfinished.
if [ "${backups_ok}" = yes ] && [ ! -e "${clv_backups_dir}/RESTORE-IN-PROGRESS" ] && ! clv_busy_reason all > /dev/null; then
    (
        clv_backups_enter existing 2> /dev/null || exit 0
        [ -e .maintenance-by-backup ] || compgen -G '.making-*' > /dev/null || compgen -G '.incoming-*' > /dev/null || exit 0
        [ ! -L .lock ] || exit 0
        exec 9> .lock || exit 0
        flock -n 9 || exit 0
        if recovered="$(ls_recover_dead_backup)"; then
            echo "backup_recovered=${recovered}"
        else
            echo "backup_recovered=${recovered}"
            echo backup_recovery=failed
        fi
    )
fi
settings="$(ls_table settings_global)"
one() { ls_sql "$1" 2> /dev/null | head -n 1; }
echo "db_version=$(one "SELECT stg_value FROM ${settings} WHERE stg_name = 'DBVersion'")"
echo "db_update_incomplete=$(one "SELECT COUNT(*) FROM ${settings} WHERE stg_name = 'DBUpdateIncomplete'")"
mode="$(one "SELECT stg_value FROM ${settings} WHERE stg_name = 'maintenancemode'")"
echo "maintenance=${mode:-off}"
echo "surveys=$(one "SELECT COUNT(*) FROM $(ls_table surveys)")"
echo "surveys_active=$(one "SELECT COUNT(*) FROM $(ls_table surveys) WHERE active = 'Y'")"
echo "admins=$(one "SELECT COUNT(*) FROM $(ls_table users)")"
echo "superadmins=$(one "SELECT COUNT(*) FROM $(ls_table permissions) WHERE entity = 'global' AND permission = 'superadmin' AND read_p = 1")"
echo "tables_myisam=$(one "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND engine = 'MyISAM'")"
echo "tables_innodb=$(one "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND engine = 'InnoDB'")"
echo "db_bytes=$(one "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()")"
method="$(one "SELECT stg_value FROM ${settings} WHERE stg_name = 'emailmethod'")"
echo "email_method=${method:-mail}"
rpc="$(one "SELECT stg_value FROM ${settings} WHERE stg_name = 'RPCInterface'")"
echo "rpc_interface=${rpc:-off}"
echo "plugins_off=$(one "SELECT COUNT(*) FROM $(ls_table plugins) WHERE plugin_type <> 'core' AND active = 0")"
echo "plugins_load_error=$(one "SELECT COUNT(*) FROM $(ls_table plugins) WHERE load_error = 1")"

# The keys in security.php, tested against what the database holds encrypted. LimeSurvey is not started for it,
# so it also works on a site that is locked or half restored.
keys=unknown
if [ -f "${config_dir}/security.php" ] && [ ! -L "${config_dir}/security.php" ]; then
    case "$(ls_keys_probe "${config_dir}/security.php")" in
        ok) keys=ok ;;
        wrong) keys=wrong ;;
        untested) keys=untested ;;
    esac
fi
echo "keys=${keys}"
