# shellcheck shell=bash
# LimeSurvey skill: remote/lib/site.sh (sourced inside the LimeSurvey container, as root, by backup.sh, restore.sh
# and health.sh)
#
# What those scripts need to know about the site, read once, and the database client set up so that the password
# is never on a command line.
#
# ls_site_read [CONFIG]   reads application/config/config.php (or CONFIG) and application/config/version.php, as
#                         www-data and never as root, because config.php is code that www-data can change. Sets:
#                           db_type db_host db_port db_socket db_name db_user db_password db_prefix
#                           code_version code_dbversion code_build cfg_debug cfg_publicurl
#                         Returns 1 when the file is missing or is not a LimeSurvey config for MySQL or MariaDB.
# ls_site_client          writes the database client's options (host, port or socket, user, password) to a mode 600
#                         file in a mode 700 folder that the caller's EXIT trap removes (site_work), and sets
#                         db_client to the client command and db_dump to the dump command, each with
#                         --defaults-extra-file as its first option
# ls_sql SQL              runs one statement and prints the rows, tab-separated, without a header
# ls_table NAME           the table's name with the site's prefix
# ls_console ARGS...      runs LimeSurvey's console.php as www-data
# ls_maintenance_mode     prints LimeSurvey's maintenance mode (off when the setting has no row). Returns 1 when the
#                         database cannot be asked.
# ls_answer_sets          prints how many answer sets the active surveys hold, all of them together
# ls_encrypted_samples    prints a few values that the database holds encrypted, one per line, as stored: the
#                         SMTP password, encrypted participant fields, the passwords Clouve's SuiteCRM plugin
#                         stores (Customer Kit), encrypted answers. They are what
#                         lib/keys-probe.php tests a security.php against. Nothing is decrypted here.
# ls_keys_probe FILE      prints ok, wrong, untested or nokeys: whether the keys in FILE read those values
# ls_recover_dead_backup  cleans up after a backup that died (its process was killed, the container was stopped):
#                         removes the half-made folders, and puts the maintenance mode back to what that backup
#                         recorded, and only when that backup set it. The caller holds clouve/backups/.lock, stands
#                         in clouve/backups (lib/state.sh, clv_backups_enter) and has called ls_site_read and
#                         ls_site_client. It prints what it did, one sentence, or nothing. Returns 1 when the
#                         maintenance mode could not be put back yet (the database is down, or security.php is
#                         missing): the note stays, and the next run tries again.
#
# Nothing here prints the database password. A caller's bash -x would, so the callers run with set +x.

# SC2034: the variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034

ls_root="${LS_ROOT:-/var/www/html}"
site_work=''

ls_site_read() {
    local config="${1:-${ls_root}/application/config/config.php}" out line key value
    db_type='' db_host='' db_port='' db_socket='' db_name='' db_user='' db_password='' db_prefix=''
    code_version='' code_dbversion='' code_build='' cfg_debug='' cfg_publicurl=''
    [ -f "${config}" ] || return 1
    # The values come back one per line as NAME=<base64>, so a value with a newline or a quote stays whole.
    # shellcheck disable=SC2016  # PHP code
    out="$(sudo -n -u www-data php -r '
        error_reporting(0);
        define("BASEPATH", "/nonexistent/");
        ob_start();
        $c = require $argv[1];
        ob_end_clean();
        if (!is_array($c) || !isset($c["components"]["db"]["connectionString"])) { exit(2); }
        $db = $c["components"]["db"];
        $out = array("type" => "", "host" => "", "port" => "", "socket" => "", "name" => "",
            "user" => isset($db["username"]) ? $db["username"] : "", "password" => isset($db["password"]) ? $db["password"] : "",
            "prefix" => isset($db["tablePrefix"]) ? $db["tablePrefix"] : "");
        $dsn = $db["connectionString"];
        $out["type"] = strtolower(substr($dsn, 0, strpos($dsn, ":")));
        foreach (explode(";", substr($dsn, strpos($dsn, ":") + 1)) as $part) {
            if (strpos($part, "=") === false) { continue; }
            list($k, $v) = explode("=", $part, 2);
            $k = strtolower(trim($k));
            if ($k === "host") { $out["host"] = $v; }
            if ($k === "port") { $out["port"] = $v; }
            if ($k === "unix_socket") { $out["socket"] = $v; }
            if ($k === "dbname") { $out["name"] = $v; }
        }
        $v = is_file($argv[2]) ? (include $argv[2]) : array();
        $out["code_version"] = isset($v["versionnumber"]) ? $v["versionnumber"] : "";
        $out["code_dbversion"] = isset($v["dbversionnumber"]) ? $v["dbversionnumber"] : "";
        $out["code_build"] = isset($v["buildnumber"]) ? $v["buildnumber"] : "";
        $out["cfg_debug"] = isset($c["config"]["debug"]) ? $c["config"]["debug"] : 0;
        $out["cfg_publicurl"] = isset($c["config"]["publicurl"]) ? $c["config"]["publicurl"] : "";
        foreach ($out as $k => $v) { echo $k, "=", base64_encode((string) $v), "\n"; }
    ' -- "${config}" "${ls_root}/application/config/version.php" < /dev/null 2> /dev/null)" || return 1
    while IFS= read -r line; do
        key="${line%%=*}"
        value="$(printf '%s' "${line#*=}" | base64 -d 2> /dev/null)" || value=''
        case "${key}" in
            type) db_type="${value}" ;;
            host) db_host="${value}" ;;
            port) db_port="${value}" ;;
            socket) db_socket="${value}" ;;
            name) db_name="${value}" ;;
            user) db_user="${value}" ;;
            password) db_password="${value}" ;;
            prefix) db_prefix="${value}" ;;
            code_version) code_version="${value}" ;;
            code_dbversion) code_dbversion="${value}" ;;
            code_build) code_build="${value}" ;;
            cfg_debug) cfg_debug="${value}" ;;
            cfg_publicurl) cfg_publicurl="${value}" ;;
        esac
    done <<< "${out}"
    case "${db_type}" in mysql | mariadb) ;; *) return 1 ;; esac
    [ -n "${db_name}" ] && [ -n "${db_user}" ] || return 1
    # The names go into SQL and file names: letters, digits and _ only.
    case "${db_prefix}" in *[!A-Za-z0-9_]*) return 1 ;; esac
    case "${db_name}" in *[!A-Za-z0-9_-]*) return 1 ;; esac
    return 0
}

ls_site_client() {
    local file escaped client dump
    site_work="$(mktemp -d /tmp/clouve-ls-db.XXXXXXXX)" || return 1
    chmod 700 "${site_work}" || return 1
    file="${site_work}/client.cnf"
    escaped="${db_password//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    (
        umask 077
        {
            echo '[client]'
            if [ -n "${db_socket}" ]; then
                printf 'socket=%s\n' "${db_socket}"
            else
                printf 'host=%s\n' "${db_host:-localhost}"
                printf 'port=%s\n' "${db_port:-3306}"
                echo 'protocol=tcp'
            fi
            printf 'user=%s\n' "${db_user}"
            printf 'password="%s"\n' "${escaped}"
            echo 'default-character-set=utf8mb4'
        } > "${file}"
    ) || return 1
    client="$(command -v mariadb || command -v mysql)" || { echo "[limesurvey] no database client (mariadb or mysql) in this container" >&2; return 1; }
    dump="$(command -v mariadb-dump || command -v mysqldump)" || { echo "[limesurvey] no dump program (mariadb-dump or mysqldump) in this container" >&2; return 1; }
    db_client=("${client}" "--defaults-extra-file=${file}")
    db_dump=("${dump}" "--defaults-extra-file=${file}")
}

ls_sql() {
    "${db_client[@]}" -N -B "${db_name}" -e "$1"
}

ls_table() {
    printf '%s%s' "${db_prefix}" "$1"
}

ls_console() {
    (cd "${ls_root}" && sudo -n -u www-data php application/commands/console.php "$@" < /dev/null)
}

ls_maintenance_mode() {
    local mode
    mode="$(ls_sql "SELECT stg_value FROM $(ls_table settings_global) WHERE stg_name = 'maintenancemode'" 2> /dev/null)" || return 1
    printf '%s' "${mode:-off}"
}

ls_answer_sets() {
    local table sql='SELECT 0'
    # One statement for all the tables: an install can have thousands of surveys.
    while IFS= read -r table; do
        [ -n "${table}" ] || continue
        case "${table}" in *[!A-Za-z0-9_]*) continue ;; esac
        sql+=" + (SELECT COUNT(*) FROM \`${table}\`)"
    done < <(ls_sql "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND (table_name REGEXP '^${db_prefix}responses_[0-9]+\$' OR table_name REGEXP '^${db_prefix}survey_[0-9]+\$')" 2> /dev/null)
    printf '%s;\n' "${sql}" | "${db_client[@]}" -N -B "${db_name}" 2> /dev/null
}

ls_encrypted_samples() {
    local value sid options column qid n=0
    value="$(ls_sql "SELECT stg_value FROM $(ls_table settings_global) WHERE stg_name = 'emailsmtppassword'" 2> /dev/null)"
    [ -z "${value}" ] || printf '%s\n' "${value}"
    # Participant lists whose fields are encrypted.
    while IFS=$'\t' read -r sid options; do
        case "${sid}" in '' | *[!0-9]*) continue ;; esac
        for column in email firstname lastname; do
            case "${options}" in *"\"${column}\":\"Y\""*) ;; *) continue ;; esac
            value="$(ls_sql "SELECT \`${column}\` FROM \`$(ls_table "tokens_${sid}")\` WHERE \`${column}\` IS NOT NULL AND \`${column}\` <> '' LIMIT 1" 2> /dev/null)" || continue
            if [ -n "${value}" ]; then printf '%s\n' "${value}"; n=$((n + 1)); fi
        done
        [ "${n}" -lt 6 ] || break
    done < <(ls_sql "SELECT sid, tokenencryptionoptions FROM $(ls_table surveys) WHERE tokenencryptionoptions LIKE '%\"enabled\":\"Y\"%' ORDER BY sid DESC LIMIT 20" 2> /dev/null)
    # The settings Clouve's SuiteCRM plugin stores encrypted (Customer Kit): each is a JSON string.
    # --raw: without it the client doubles the backslashes that JSON puts before each slash.
    while IFS= read -r value; do
        [ -z "${value}" ] || printf '%s\n' "${value}"
    done < <("${db_client[@]}" -N -B --raw "${db_name}" -e "SELECT s.value FROM $(ls_table plugin_settings) s JOIN $(ls_table plugins) p ON p.id = s.plugin_id WHERE p.name = 'SuiteCRMIntegration' AND s.model IS NULL AND s.\`key\` IN ('suitecrm_admin_password', 'suitecrm_db_password', 'oauth_client_secret') AND s.value IS NOT NULL AND s.value NOT IN ('', '\"\"', 'null')" 2> /dev/null)
    # Answers to questions marked as encrypted, in surveys that are active.
    n=0
    while IFS=$'\t' read -r sid qid; do
        case "${sid}${qid}" in '' | *[!0-9]*) continue ;; esac
        value="$(ls_sql "SELECT \`Q${qid}\` FROM \`$(ls_table "responses_${sid}")\` WHERE \`Q${qid}\` IS NOT NULL AND \`Q${qid}\` <> '' LIMIT 1" 2> /dev/null)" || continue
        if [ -n "${value}" ]; then printf '%s\n' "${value}"; n=$((n + 1)); fi
        [ "${n}" -lt 4 ] || break
    done < <(ls_sql "SELECT q.sid, q.qid FROM $(ls_table questions) q JOIN $(ls_table surveys) s ON s.sid = q.sid WHERE q.encrypted = 'Y' AND q.parent_qid = 0 AND s.active = 'Y' ORDER BY q.qid DESC LIMIT 20" 2> /dev/null)
}

ls_keys_probe() {
    local remote_lib word
    remote_lib="${CLV_LS_REMOTE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/lib"
    word="$(ls_encrypted_samples | sudo -n -u www-data php "${remote_lib}/keys-probe.php" "$1" 2> /dev/null | head -n 1)"
    case "${word}" in ok | wrong | untested | nokeys) printf '%s' "${word}" ;; *) printf nokeys ;; esac
}

ls_recover_dead_backup() {
    local note=.maintenance-by-backup before now d did=''
    for d in .making-* .incoming-*; do
        [ -e "${d}" ] || [ -L "${d}" ] || continue
        if rm -rf -- "./${d}"; then did+="removed the half-made folder ${d}; "; fi
    done
    if [ -f "${note}" ] && [ ! -L "${note}" ]; then
        before="$(head -n 1 "${note}" | tr -cd 'a-z-')"
        case "${before}" in off | soft | hard) ;; *) before=off ;; esac
        # Without an answer from the database there is no telling whether the lock is still on, and without
        # security.php LimeSurvey's console must not start. The note stays for the next run.
        if ! now="$(ls_maintenance_mode)" || [ ! -f "${ls_root}/application/config/security.php" ]; then
            printf '%s' "${did}"
            return 1
        fi
        if [ "${now}" = hard-cli ]; then
            if ! ls_console setmaintenancemode "${before}" > /dev/null 2>&1; then
                printf '%s' "${did}"
                return 1
            fi
            did+="put the maintenance mode back to ${before}, which that backup had found; "
        fi
        rm -f -- "${note}"
    fi
    printf '%s' "${did%; }"
}
