#!/usr/bin/env bash
# Nextcloud DevOps Skill: backup.sh
#
# Runs INSIDE the Nextcloud container, as root, never on the agent. run-in-nextcloud.sh sends it there over
# the clouve-ops SSH channel, as `sudo bash -s -- ARGS` with this file on stdin, or with --detach as a job in
# /run/clouve/jobs. sudo drops the container's environment, so no setting comes from the NEXTCLOUD_*
# variables: the database host, name, user and password, the data folder, the version and the instance id
# come from config/config.php. PHP reads that file as www-data and never as root, because config.php is code
# that www-data can change.
#
# Usage: backup.sh [--with-data] [--no-maintenance]
#        backup.sh --list
#
# A backup is the folder /var/www/html/data/clouve-backups/<UTC YYYYmmdd-HHMMSS>/. datadirectory in config.php must
# be that data folder: the image looks for the markers below there and nowhere else. clouve-backups and each backup
# folder are root's, mode 700, and every file in them is mode 600. A backup holds:
#   database.sql.gz  mariadb-dump of the database: one transaction, utf8mb4, routines and triggers, and no
#                    --databases, so it restores into a database of any name
#   config.tar.gz    config/
#   apps.tar.gz      custom_apps/ and themes/
#   data.tar.gz      with --with-data: the data folder, without clouve-backups and without the previews
#                    (appdata_*/preview, which Nextcloud makes again); .ncdata and .htaccess are kept
#   manifest.json    when it was made, the version, the instance id, the database name, with_data, with
#                    --with-data data_bytes (the space the users' files took on the data volume, du -s -B1, which
#                    restore.sh checks before it replaces them), and each archive with its size in bytes
#   SHA256SUMS       the checksums of the archives and the manifest
# It sits on Nextcloud's data volume, next to the data it protects, and nothing deletes it automatically.
#
# The data folder is www-data's, and so is /var/www/html around it: www-data can rename what is in them, or put a
# link in its place, at any time. So the script checks the data folder and clouve-backups once and then works from
# inside them (cd -P: a plain cd changes to "$PWD/NAME", through the path again). Every file it reads or writes in
# clouve-backups has a name relative to that folder, and the users' files are archived from its parent (..). A folder
# renamed or swapped for a link afterwards changes nothing for the run, and www-data can't move clouve-backups out of
# the data folder: that takes write access to clouve-backups itself.
#
# The steps, in order:
#   1. Checks: root, a readable config.php whose datadirectory is that data folder, `occ status` says installed, no
#      restore cut off half way (clouve-backups/RESTORE-IN-PROGRESS), no BACKUP-IN-PROGRESS (see 5), and the image's
#      init lock free. The script holds that lock (fd 9) until it ends: the image takes it to install or upgrade,
#      restore.sh takes it too, and the container's health probe reports healthy while it is held. So no upgrade,
#      restore or second backup runs meanwhile. The lock file is www-data's, so root opens it only as a plain file,
#      read-only, and gives up after 5 seconds (a named pipe swapped in would make the open wait forever).
#   2. The settings from config.php: dbtype (MySQL or MariaDB only), dbhost (a host, host:port or
#      host:/socket, split the way Nextcloud splits it), dbname, dbuser, dbpassword, datadirectory, version
#      and instanceid.
#   3. Space. The estimate is the database's size (data and indexes, from information_schema.tables), plus
#      config/, custom_apps/ and themes/, plus with --with-data the data folder without clouve-backups and the
#      previews. When the data volume has less than 1.2 times that free, it stops with exit 3 before it writes
#      anything, and gives both numbers in MB.
#   4. The folder.
#   5. Maintenance mode, unless --no-maintenance. When it is off, the script puts clouve-backups/
#      BACKUP-IN-PROGRESS in place (the backup's name on its first line), holding an exclusive flock on it (fd 8)
#      from before it appears (it is made, locked and written as a temporary file, then renamed), then turns
#      maintenance mode on. Once the archives are written it turns maintenance mode off, then removes the
#      marker and lets the lock go. If the run stops before that, the trap (EXIT, INT, TERM, HUP, PIPE) does
#      the same. If the container stops instead, the backup dies with it, the lock goes with the process, and
#      the image's next start finds the marker unlocked: it turns maintenance mode off and removes the marker.
#      When maintenance mode was on already, the script leaves it on and writes no marker.
#      A BACKUP-IN-PROGRESS that is there when the script starts stops it (exit 1). Locked, it belongs to a
#      backup that is running. Unlocked, to one that died, maybe with maintenance mode still on: the image's next
#      start clears both, without the init lock, so the script leaves them to it.
#   6. The archives. 7. The manifest and SHA256SUMS.
#   8. The check: sha256sum -c, and gzip -t of each archive. When it fails, the folder goes (exit 4).
#   9. The last line: `[nextcloud/backup] done: <folder> (<size>). ...`
# A step that fails removes the half-made folder and puts maintenance mode back as it was (exit 2). tar's exit
# 1 ("file changed as we read it") is a warning: the archive is whole, but that file may be newer or older than
# the rest. The database password reaches mariadb-dump and mariadb in a mode 600 --defaults-extra-file, in a
# mode 700 folder that is deleted at the end; it is never on a command line, and nothing prints it.
#
# --list prints one line per backup: its name, size, with_data, versionstring, and INCOMPLETE when its
# SHA256SUMS is missing (a backup cut off while it was made). It changes nothing.
#
# The whole script is one function, called on the last line with stdin from /dev/null. Under `bash -s` bash
# reads the script from stdin as it runs, so a command that read stdin would eat the rest of the script, and a
# script cut off on its way would run up to the cut. This way bash reads all of it first, and runs nothing
# when it is cut off.
#
# Exit codes:
#   0  done
#   1  usage, or this is not the place or the time: not root, no config.php, a datadirectory other than
#      /var/www/html/data, occ can't say, a restore was cut off, the init lock or a BACKUP-IN-PROGRESS is there,
#      a setting is missing or odd
#   2  a step failed: the half-made folder is removed and maintenance mode is back as it was
#   3  not enough space; nothing was written
#   4  the check of the new backup failed; the folder is removed
#   5  the backup is complete and kept, but maintenance mode could not be turned off at the end: it is still
#      on, and BACKUP-IN-PROGRESS stays, so the container's next start turns it off (stderr says how to do it now)
#   129, 130, 141, 143  stopped by HUP, INT, PIPE or TERM, and cleaned up as for exit 2
#
# Overrides, for tests: NC_ROOT (default /var/www/html) and NC_OCC (default
# "sudo -n -u www-data php $NC_ROOT/occ --no-interaction --no-warnings", split at spaces).

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the database password.
set +x

made_by='nextcloud skill backup.sh 0.1.0'
nc_root=${NC_ROOT:-/var/www/html}
occ_spec=${NC_OCC:-}
NC_OCC=()
if [ -n "${occ_spec}" ]; then
    read -r -a NC_OCC <<< "${occ_spec}"
else
    NC_OCC=(sudo -n -u www-data php "${nc_root}/occ" --no-interaction --no-warnings)
fi
config_file=${nc_root}/config/config.php

# The settings from config.php (setting fills them in).
data_setting='' db_type='' db_hostspec='' db_name='' db_user='' db_password='' cfg_version='' instance_id=''
# The data folder's real path and its device and inode (enter_data_dir), and clouve-backups' path, for the messages.
data_dir='' data_id='' backups_dir=''

# What the EXIT trap looks at. folder, marker and marker_tmp are names inside clouve-backups, the current folder once
# the script has checked it.
work=''
folder=''
folder_done=no
maint_ours=no
marker=BACKUP-IN-PROGRESS
marker_shown=''
marker_tmp=''
marker_held=no
keep_marker=no

# The PHP program, run as www-data: `php -r CODE -- get FILE KEY`.
IFS= read -r -d '' php_code <<'PHP' || :
// The config.php reader. These lines are the same in backup.sh and restore.sh, and the tests compare the two.
// Whatever a file prints while it loads is thrown away, and an error names the file and the line, never the text:
// config.php holds the passwords.
//   $load(FILE, VAR)  FILE's $CONFIG (VAR 'CONFIG') or $OC_Version (VAR 'OC_Version'); exit 2 when it has none
//   $get(FILE, KEY)   prints KEY's value in FILE's $CONFIG (true or false for a boolean, JSON for an array) and
//                     exits 0; exits 1 when it has no KEY
$load = static function (string $file, string $var): array {
    if (!is_file($file) || !is_readable($file)) {
        fwrite(STDERR, "cannot read $file\n");
        exit(2);
    }
    $CONFIG = null;
    $OC_Version = null;
    ob_start(static fn (string $buffer): string => '');
    try {
        include $file;
    } catch (Throwable $e) {
        ob_end_clean();
        fwrite(STDERR, "cannot read $file: " . get_class($e) . ' on line ' . $e->getLine() . "\n");
        exit(2);
    }
    ob_end_clean();
    $found = $var === 'OC_Version' ? $OC_Version : $CONFIG;
    if (!is_array($found)) {
        fwrite(STDERR, "$file does not set \$$var\n");
        exit(2);
    }
    return $found;
};
$get = static function (string $file, string $key) use ($load): void {
    $config = $load($file, 'CONFIG');
    if (!array_key_exists($key, $config)) {
        exit(1);
    }
    $value = $config[$key];
    if (is_bool($value)) {
        echo $value ? 'true' : 'false';
    } elseif (is_scalar($value) || $value === null) {
        echo (string) $value;
    } else {
        echo json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    }
    exit(0);
};
// The end of the config.php reader.
if (($argv[1] ?? '') === 'get' && count($argv) === 4) {
    $get($argv[2], $argv[3]);
}
fwrite(STDERR, "usage: get FILE KEY\n");
exit(64);
PHP

usage() {
    cat <<'EOF'
Usage: backup.sh [--with-data] [--no-maintenance]
       backup.sh --list

Backs up this Nextcloud into /var/www/html/data/clouve-backups/<UTC YYYYmmdd-HHMMSS>/: the database, config/,
custom_apps/ and themes/, and with --with-data the users' files. Maintenance mode is on while it works,
unless --no-maintenance. It runs inside the Nextcloud container as root: send it with run-in-nextcloud.sh.
--list shows the backups that are there, and changes nothing.

Exit codes: 0 done; 1 usage, or not the place or the time (see the message); 2 a step failed (the half-made
folder is removed, maintenance mode is back as it was); 3 not enough space (nothing written); 4 the check of
the new backup failed (the folder is removed); 5 the backup is complete, but maintenance mode is still on.
EOF
}

say() { printf '[nextcloud/backup] %s\n' "$*"; }
warn() { printf '[nextcloud/backup] WARNING: %s\n' "$*" >&2; }
die() {
    local code=$1
    shift
    printf '[nextcloud/backup] %s\n' "$*" >&2
    exit "${code}"
}

# first_line TEXT: its first line, cut at 300 characters
first_line() {
    local line=${1%%$'\n'*}
    printf '%s' "${line:0:300}"
}

# www COMMAND...: COMMAND as www-data, started from /: the script works from inside folders that are root's alone,
# and a tool such as find must be able to open the folder it starts in
www() { (cd / && exec sudo -n -u www-data "$@"); }

# php_run ARGS...: the PHP program above, as www-data. The caller gives stdin.
php_run() { www php -d display_errors=stderr -d log_errors=0 -r "${php_code}" -- "$@"; }

# setting VAR KEY [DEFAULT]: VAR = KEY's value in config.php; DEFAULT when config.php has no KEY, else exit 1
setting() {
    local var=$1 key=$2 value rc=0
    value=$(php_run get "${config_file}" "${key}" < /dev/null) || rc=$?
    case ${rc} in
        0) ;;
        1)
            if [ "$#" -lt 3 ]; then die 1 "config.php has no ${key}"; fi
            value=$3
            ;;
        *) die 1 "could not read ${key} from ${config_file} (php exited ${rc})" ;;
    esac
    printf -v "${var}" '%s' "${value}"
}

# json_flag JSON KEY: true or false, or nothing when KEY isn't a boolean there
json_flag() {
    case $1 in
        *"\"$2\":true"*) printf true ;;
        *"\"$2\":false"*) printf false ;;
    esac
}

# json_text JSON KEY: KEY's string value, or nothing
json_text() {
    local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ $1 =~ ${re} ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# json_str TEXT: TEXT as a JSON string; a control character becomes a space
json_str() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//[[:cntrl:]]/ }
    printf '"%s"' "${s}"
}

# read_status: status_json = the JSON line of `occ status --output=json`, or exit 1
read_status() {
    local text rc=0 line
    text=$(cd / && "${NC_OCC[@]}" status --output=json < /dev/null) || rc=$?
    status_json=''
    while IFS= read -r line; do
        case ${line} in '{'*'}') status_json=${line} ;; esac
    done <<< "${text}"
    if [ "${rc}" -ne 0 ] || [ -z "${status_json}" ]; then
        die 1 "occ status failed (exit ${rc}), so this backup does not start: $(first_line "${text}")"
    fi
}

# split_dbhost DBHOST: db_host, db_port and db_socket, split the way Nextcloud splits dbhost
# (lib/private/DB/ConnectionFactory.php, splitHostFromPortAndSocket): a last ":" with no "]" or ":" after it
# starts a port (digits) or a socket path. Brackets around an IPv6 address go.
split_dbhost() {
    local re='^(.*):([^]:]+)$' tail
    db_host=$1 db_port='' db_socket=''
    if [[ $1 =~ ${re} ]]; then
        db_host=${BASH_REMATCH[1]}
        tail=${BASH_REMATCH[2]}
        if [[ ${tail} =~ ^[0-9]+$ ]]; then db_port=${tail}; else db_socket=${tail}; fi
    fi
    case ${db_host} in '['*']') db_host=${db_host#[} && db_host=${db_host%]} ;; esac
}

# cnf_quote VAR TEXT: VAR = TEXT as a double-quoted value in a MariaDB options file, which reads \\ \" \n \r \t
# and \b inside the quotes (mysys/my_default.c), and a # there as text
cnf_quote() {
    local text=$2
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    text=${text//$'\n'/\\n}
    text=${text//$'\r'/\\r}
    text=${text//$'\t'/\\t}
    text=${text//$'\b'/\\b}
    printf -v "$1" '"%s"' "${text}"
}

# write_client_cnf: the [client] options file mariadb and mariadb-dump read, mode 600 in the work folder. printf
# is a builtin, so the password is in no argv on its way there.
write_client_cnf() {
    local q
    cnf=${work}/client.cnf
    {
        printf '[client]\n'
        if [ -n "${db_host}" ]; then cnf_quote q "${db_host}" && printf 'host=%s\n' "${q}"; fi
        if [ -n "${db_port}" ]; then printf 'port=%s\n' "${db_port}"; fi
        if [ -n "${db_socket}" ]; then cnf_quote q "${db_socket}" && printf 'socket=%s\n' "${q}"; fi
        cnf_quote q "${db_user}" && printf 'user=%s\n' "${q}"
        cnf_quote q "${db_password}" && printf 'password=%s\n' "${q}"
    } > "${cnf}" || die 1 "could not write the database options file in ${work}"
}

# db_query SQL: mariadb's answer, without column names. --skip-ssl: the 11.4 and later clients check the server's
# certificate, the database container's is self-signed, and the traffic stays inside the pod network.
db_query() {
    mariadb --defaults-extra-file="${cnf}" --skip-ssl -N -B -e "$1" "${db_name}" < /dev/null
}

# digits TEXT: succeeds when TEXT is a number bash can add without wrapping
digits() {
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 18 ]
}

# du_bytes PATH [disk]: PATH's apparent size in bytes (du -sb), or with disk the space it takes on its volume
# (du -s -B1). Each path on its own: du counts a folder once, so a path inside an earlier argument would print
# nothing. 0 when PATH isn't there.
du_bytes() {
    local n='' opts=(-sb)
    if [ "${2:-}" = disk ]; then opts=(-s -B1); fi
    if [ ! -e "$1" ]; then printf 0; return 0; fi
    read -r n _ < <(du "${opts[@]}" -- "$1" 2> /dev/null) || n=''
    digits "${n}" || return 1
    printf '%s' "$((10#${n}))"
}

# free_bytes PATH: the bytes free on PATH's file system (df -PB1, the Available column)
free_bytes() {
    local line='' avail=''
    line=$(df -PB1 -- "$1" 2> /dev/null | tail -n 1) || return 1
    read -r _ _ _ avail _ <<< "${line}"
    case ${avail} in '' | *[!0-9]*) return 1 ;; esac
    if [ "${#avail}" -gt 18 ]; then avail=999999999999999999; fi
    printf '%s' "$((10#${avail}))"
}

# in_mb BYTES: "N.N MB", rounded to the nearest tenth (1 MB is 1048576 bytes)
in_mb() {
    local t=$((($1 * 10 + 524288) / 1048576))
    printf '%d.%d MB' "$((t / 10))" "$((t % 10))"
}

# human BYTES: "N B", or KB, MB or GB with one decimal (1024-based)
human() {
    local bytes=$1 unit=B div=1 t
    if [ "${bytes}" -ge 1073741824 ]; then unit=GB div=1073741824
    elif [ "${bytes}" -ge 1048576 ]; then unit=MB div=1048576
    elif [ "${bytes}" -ge 1024 ]; then unit=KB div=1024
    fi
    if [ "${unit}" = B ]; then printf '%s B' "${bytes}"; return 0; fi
    t=$(((bytes * 10 + div / 2) / div))
    printf '%d.%d %s' "$((t / 10))" "$((t % 10))" "${unit}"
}

# marker_name FILE: the backup's name from a marker's first line, for a message: only letters, digits, dot,
# hyphen and underscore, at most 64 of them; "unnamed" when there is none. It reads a plain file only.
marker_name() {
    local line='' n
    if [ -f "$1" ] && [ ! -L "$1" ]; then IFS= read -r line < "$1" || :; fi
    n=${line//[!A-Za-z0-9._-]/_}
    n=${n:0:64}
    printf '%s' "${n:-unnamed}"
}

# enter_data_dir: datadirectory (data_setting) must be NC_ROOT/data, a folder and not a link: the image looks for
# clouve-backups and its markers there and nowhere else. The script then works from inside it. Sets data_dir (its
# real path, for the messages and for www-data's commands) and data_id (its device and inode).
enter_data_dir() {
    local want=${nc_root}/data real=''
    case ${data_setting} in /*) ;; *) die 1 "datadirectory in config.php is not an absolute path: $(printf '%q' "${data_setting}")" ;; esac
    if [ -L "${want}" ] || [ ! -d "${want}" ]; then die 1 "${want} is not a folder (it is missing, or a link)"; fi
    real=$(cd -P -- "${data_setting}" 2> /dev/null && pwd -P) || real=''
    if [ -z "${real}" ] || [ "${real}" != "$(cd -P -- "${want}" && pwd -P)" ]; then
        die 1 "datadirectory in config.php is $(printf '%q' "${data_setting}"), and this works only with ${want}, where the image looks for clouve-backups and its markers"
    fi
    data_id=$(stat -c %d:%i -- "${want}") || die 1 "cannot read ${want}"
    cd -P -- "${want}" || die 1 "cannot open ${want}"
    if [ "$(stat -c %d:%i -- .)" != "${data_id}" ]; then die 1 "${want} changed while it was checked"; fi
    data_dir=$(pwd -P)
}

# enter_backups_dir: clouve-backups, in the data folder (the current folder), must be a folder of the user this runs
# as (root, in the container), not a link: anything else could have been put there by www-data. The script then
# works from inside it, and makes it mode 700 when it is not. Its parent must still be the data folder: www-data can
# rename clouve-backups within the data folder, but only root can move a folder of root's into another folder.
enter_backups_dir() {
    local st
    st=$(stat -c '%F %u %d:%i' -- clouve-backups 2> /dev/null) || die 1 "cannot read ${backups_dir}"
    case ${st} in
        "directory ${owner_me} "*) ;;
        directory\ *) die 1 "${backups_dir} is not root's, so something else made it. Move it away and run this again." ;;
        *) die 1 "${backups_dir} is not a folder (it is a link or a file). Move it away and run this again." ;;
    esac
    cd -P -- clouve-backups || die 1 "cannot open ${backups_dir}"
    if [ "$(stat -c '%F %u %d:%i' -- .)" != "${st}" ]; then die 1 "${backups_dir} changed while it was checked"; fi
    if [ "$(stat -c %d:%i -- ..)" != "${data_id}" ]; then die 1 "${backups_dir} is not in the data folder any more"; fi
    if [ "$(stat -c %a -- .)" != 700 ]; then chmod 700 . || die 1 "could not make ${backups_dir} mode 700"; fi
}

# open_init_lock FILE: FILE on fd 9, read-only (never created), then the check that fd 9 is FILE itself, a plain
# file: the same device and inode as FILE's own (stat without -L), which a link, or a file swapped in, does not have.
# The open gives up after 5 seconds, as the image's own probe of a lock does (lib.sh, _nc_backup_lock): a reader of
# the timer pipe sends ALRM when the pipe stays open that long, bash breaks off the open to run the trap, and the trap
# ends the script. Closing the pipe ends the reader. Fails when fd 9 is not FILE, a plain file.
open_init_lock() {
    local file=$1 timer timer_pid
    trap 'die 1 "could not open ${file} within 5 seconds (something put another kind of file in its place)"' ALRM
    exec {timer}> >(read -r -t 5 _; [ "$?" -le 128 ] || kill -s ALRM "$$" 2> /dev/null)
    timer_pid=$!
    exec 9< "${file}" || die 1 "could not open ${file}"
    exec {timer}>&-
    wait "${timer_pid}" 2> /dev/null
    trap - ALRM
    if [ ! -f /proc/self/fd/9 ] ||
        [ "$(stat -L -c %d:%i -- /proc/self/fd/9 2> /dev/null)" != "$(stat -c %d:%i -- "${file}" 2> /dev/null)" ]; then
        exec 9<&-
        return 1
    fi
}

# take_init_lock: the image's init lock, on fd 9, held until the script ends, and taken without waiting. The file is
# www-data's, in a folder of www-data's: root opens it only when it is a plain file (open_init_lock), and never
# creates it, since a root-owned lock file would lock www-data's hooks out.
take_init_lock() {
    local lock=${nc_root}/nextcloud-init-sync.lock
    if [ ! -e "${lock}" ] && [ ! -L "${lock}" ]; then
        warn "the image's init lock (${lock}) is not there, so nothing keeps an upgrade or a restore out while this runs"
        return 0
    fi
    if [ -L "${lock}" ] || [ ! -f "${lock}" ]; then die 1 "the image's init lock ${lock} is not a plain file, so this backup does not open it"; fi
    open_init_lock "${lock}" || die 1 "the image's init lock ${lock} changed while it was opened"
    if ! flock -n 9; then
        die 1 "the image's init lock is held: an install, an upgrade or its recovery is running, or a backup or a restore. Run this again when it is done."
    fi
}

# check_backup_marker: a BACKUP-IN-PROGRESS that is there already stops this run (exit 1). Locked, it belongs to a
# backup that is running. Unlocked, to a backup that died, maybe leaving maintenance mode on: the image's next start
# turns that off and removes the marker, without the init lock, so this run leaves both to it.
check_backup_marker() {
    local stale
    if [ ! -e "${marker}" ] && [ ! -L "${marker}" ]; then return 0; fi
    if [ -L "${marker}" ] || [ ! -f "${marker}" ]; then
        die 1 "${marker_shown} is not a plain file. Move it away and run this again."
    fi
    exec 8< "${marker}" || die 1 "could not open ${marker_shown}"
    if ! flock -n 8; then
        die 1 "another backup is running and holds maintenance mode (${marker_shown}, for backup $(marker_name "${marker}"), is locked)"
    fi
    exec 8<&-
    stale="a backup that stopped ($(marker_name "${marker}")) left ${marker_shown}, and maybe maintenance mode on. The container's next start turns maintenance mode off and removes the marker, so this backup leaves both alone and does not start."
    stale+=" To clear them now instead, first turn maintenance mode off: occ.sh maintenance:mode --off"
    stale+=". Then remove the marker (sudo rm -f ${marker_shown}) and run this again."
    die 1 "${stale}"
}

# hold_marker: BACKUP-IN-PROGRESS with the backup's name on its first line, under an exclusive flock on fd 8. The
# image clears a marker it can lock, so this one is never seen unlocked: it is made as a temporary file beside it
# (mode 600), locked and written there, then renamed into place. The lock belongs to the file, so it comes along.
hold_marker() {
    marker_tmp=$(mktemp .BACKUP-IN-PROGRESS.XXXXXX) || die 2 "could not make a file in ${backups_dir}"
    exec 8<> "${marker_tmp}" || die 2 "could not open ${backups_dir}/${marker_tmp}"
    flock -n 8 || die 2 "could not lock ${backups_dir}/${marker_tmp}"
    printf '%s\n' "${name}" >&8 || die 2 "could not write ${backups_dir}/${marker_tmp}"
    mv -f -- "${marker_tmp}" "${marker}" || die 2 "could not put ${marker_shown} in place"
    marker_tmp=''
    marker_held=yes
}

# on_exit: the EXIT trap. Maintenance mode back off when this run holds it, then the marker (unless maintenance mode
# could not be turned off: then the marker stays, for the image's next start), the unfinished folder, the work folder.
# shellcheck disable=SC2329  # the EXIT trap calls it
on_exit() {
    local rc=$? out
    trap '' INT TERM HUP PIPE
    if [ "${maint_ours}" = yes ]; then
        if out=$(cd / && "${NC_OCC[@]}" maintenance:mode --off < /dev/null 2>&1); then
            maint_ours=no
            warn "maintenance mode is off again"
        else
            keep_marker=yes
            warn "could not turn maintenance mode off: $(first_line "${out}"). Run occ.sh maintenance:mode --off to turn it off. ${marker_shown} stays, so the container's next start turns it off too."
        fi
    fi
    if [ "${marker_held}" = yes ] && [ "${keep_marker}" != yes ]; then
        rm -f -- "${marker}"
    fi
    if [ -n "${marker_tmp}" ]; then rm -f -- "${marker_tmp}"; fi
    if [ -n "${folder}" ] && [ "${folder_done}" != yes ] && [ -d "${folder}" ]; then
        if rm -rf -- "${folder}"; then warn "the unfinished backup ${backups_dir}/${folder} is removed"; else warn "could not remove the unfinished backup ${backups_dir}/${folder}"; fi
    fi
    if [ -n "${work}" ]; then rm -rf -- "${work}"; fi
    exit "${rc}"
}

# make_archive NAME TAR-ARGUMENTS...: tar -czf <folder>/NAME TAR-ARGUMENTS. tar's exit 1 ("file changed as we
# read it") leaves a whole archive and is a warning; anything else fails the step.
make_archive() {
    local archive=$1 rc=0
    shift
    tar -czf "${folder}/${archive}" "$@" < /dev/null || rc=$?
    case ${rc} in
        0) ;;
        1) warn "tar says a file changed while ${archive} was being written (exit 1). The archive is whole, but that file may be newer or older than the rest of the backup." ;;
        *) die 2 "tar failed while it wrote ${archive} (exit ${rc})" ;;
    esac
    say "${archive} written ($(human "$(stat -c %s -- "${folder}/${archive}")"))"
}

# do_list: the backups in clouve-backups, the current folder
do_list() {
    local d m size wd vs flag count=0 bytes
    for d in *; do
        [[ ${d} =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
        if [ -L "${d}" ] || [ ! -d "${d}" ]; then continue; fi
        bytes=$(du_bytes "${d}") || bytes=0
        size=$(human "${bytes}")
        wd='?' vs='?' flag=''
        if [ -f "${d}/manifest.json" ] && [ ! -L "${d}/manifest.json" ]; then
            m=$(< "${d}/manifest.json")
            case ${m} in
                *'"with_data": true'*) wd=true ;;
                *'"with_data": false'*) wd=false ;;
            esac
            vs=$(json_text "${m}" versionstring)
            vs=${vs:-?}
        fi
        if [ ! -f "${d}/SHA256SUMS" ]; then flag='  INCOMPLETE'; fi
        printf '%s  %s  with_data=%s  %s%s\n' "${d}" "${size}" "${wd}" "${vs//[[:cntrl:]]/ }" "${flag}"
        count=$((count + 1))
    done
    if [ "${count}" -eq 0 ]; then say "no backups in ${backups_dir}"; fi
}

main() {
    local with_data=0 list=0 arg st db_bytes files_bytes data_bytes data_disk n p estimate need free stamp created
    local status_version versionstring check out v1 v2 v3 name_re in_backups=no data_here=. off_failed=no mode m
    local -a parts=() sizes=() app_dirs=()
    no_maintenance=0
    for arg in "$@"; do
        case ${arg} in
            --with-data) with_data=1 ;;
            --no-maintenance) no_maintenance=1 ;;
            --list) list=1 ;;
            -h | --help) usage; exit 0 ;;
            *) printf '[nextcloud/backup] unknown argument: %q\n' "${arg}" >&2; usage >&2; exit 1 ;;
        esac
    done
    if [ "${list}" -eq 1 ] && [ $((with_data + no_maintenance)) -gt 0 ]; then
        printf '[nextcloud/backup] --list takes no other option\n' >&2
        usage >&2
        exit 1
    fi

    umask 077
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    # The output pipe is gone (a plain run whose SSH session ended): stop and clean up, as for HUP. Untrapped,
    # SIGPIPE would end bash at once, without the EXIT trap.
    trap 'exit 141' PIPE

    # 1. Checks
    if [ "$(id -u 2> /dev/null)" != 0 ]; then
        die 1 "this runs inside the Nextcloud container as root; run-in-nextcloud.sh sends it there with sudo"
    fi
    if [ ! -f "${config_file}" ] || [ ! -r "${config_file}" ]; then
        die 1 "cannot read ${config_file}"
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/clouve-backup.XXXXXX") || die 1 "could not make a temporary folder"
    owner_me=$(stat -c %u -- "${work}") || die 1 "cannot read the owner of ${work}"

    # 2. The settings (the --list path needs only the data folder). From here on the script works inside the data
    # folder, and inside clouve-backups once that is there.
    setting data_setting datadirectory "${nc_root}/data"
    enter_data_dir
    backups_dir=${data_dir}/clouve-backups
    marker_shown=${backups_dir}/${marker}
    if [ -e clouve-backups ] || [ -L clouve-backups ]; then
        enter_backups_dir
        in_backups=yes
        data_here=..
    fi
    if [ "${list}" -eq 1 ]; then
        if [ "${in_backups}" = yes ]; then do_list; else say "no backups: ${backups_dir} is not there yet"; fi
        exit 0
    fi

    read_status
    case ${status_json} in
        *'"installed":true'*) ;;
        *) die 1 "Nextcloud is not installed, so there is nothing to back up" ;;
    esac
    maint_before=$(json_flag "${status_json}" maintenance)
    status_version=$(json_text "${status_json}" version)

    setting db_type dbtype sqlite3
    if [ "${db_type}" != mysql ]; then die 1 "this backs up MySQL and MariaDB only, and config.php says dbtype ${db_type}"; fi
    setting db_hostspec dbhost localhost
    setting db_name dbname
    setting db_user dbuser
    setting db_password dbpassword ''
    setting cfg_version version
    setting instance_id instanceid
    split_dbhost "${db_hostspec}"
    name_re='^[A-Za-z0-9_$][A-Za-z0-9_$-]*$'
    if ! [[ ${db_name} =~ ${name_re} ]] || [ "${#db_name}" -gt 64 ]; then
        die 1 "dbname in config.php has characters this script does not pass to mariadb-dump: $(printf '%q' "${db_name}")"
    fi
    if ! [[ ${cfg_version} =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
        die 1 "version in config.php is not a version: $(printf '%q' "${cfg_version}")"
    fi
    if [ "${status_version}" = "${cfg_version}" ]; then
        versionstring=$(json_text "${status_json}" versionstring)
    else
        # An upgrade is pending: the data is still at config.php's version, and occ's versionstring is the code's.
        IFS=. read -r v1 v2 v3 _ <<< "${cfg_version}"
        versionstring=${v1}.${v2}.${v3:-0}
    fi

    if [ "${in_backups}" = yes ] && { [ -e RESTORE-IN-PROGRESS ] || [ -L RESTORE-IN-PROGRESS ]; }; then
        die 1 "a restore was cut off: ${backups_dir}/RESTORE-IN-PROGRESS names backup $(marker_name RESTORE-IN-PROGRESS). A backup now would hold a half-restored Nextcloud, and it would become the newest backup. Finish or undo that restore first (restore.sh)."
    fi
    take_init_lock
    if [ "${in_backups}" = yes ]; then check_backup_marker; fi

    # 3. Space
    write_client_cnf
    db_bytes=$(db_query "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()") ||
        die 1 "could not ask the database for its size"
    db_bytes=${db_bytes//[[:space:]]/}
    digits "${db_bytes}" || die 1 "the database's size is not a number: $(first_line "${db_bytes}")"
    db_bytes=$((10#${db_bytes}))
    files_bytes=0
    for p in config custom_apps themes; do
        n=$(du_bytes "${nc_root}/${p}") || die 1 "could not measure ${nc_root}/${p}"
        files_bytes=$((files_bytes + n))
    done
    data_bytes=0
    data_disk=0
    if [ "${with_data}" -eq 1 ]; then
        # the data folder (. or .., by where the script is now) without clouve-backups and the previews; apparent sizes
        # for the estimate, and the space they take on the volume for the manifest
        for mode in size disk; do
            n=$(du_bytes "${data_here}" "${mode}") || die 1 "could not measure ${data_dir}"
            if [ "${in_backups}" = yes ]; then
                p=$(du_bytes . "${mode}") || die 1 "could not measure ${backups_dir}"
                n=$((n - p))
            fi
            for p in "${data_here}"/appdata_*/preview; do
                [ -d "${p}" ] || continue
                m=$(du_bytes "${p}" "${mode}") || die 1 "could not measure ${data_dir}/${p#"${data_here}"/}"
                n=$((n - m))
            done
            if [ "${n}" -lt 0 ]; then n=0; fi
            if [ "${mode}" = size ]; then data_bytes=${n}; else data_disk=${n}; fi
        done
    fi
    estimate=$((db_bytes + files_bytes + data_bytes))
    need=$(((estimate * 12 + 9) / 10))
    free=$(free_bytes .) || die 1 "could not read the free space of ${data_dir}"
    if [ "${free}" -lt "${need}" ]; then
        die 3 "not enough free space for this backup: it needs $(in_mb "${need}") (1.2 times the $(in_mb "${estimate}") it would hold), and $(in_mb "${free}") are free on the data volume. Nothing was written. Free some space first (old backups in ${backups_dir} count too)."
    fi

    # 4. The folder
    read -r stamp created <<< "$(date -u '+%Y%m%d-%H%M%S %Y-%m-%dT%H:%M:%SZ')"
    [[ ${stamp} =~ ^[0-9]{8}-[0-9]{6}$ ]] || die 1 "date gave no time stamp"
    name=${stamp}
    if [ "${in_backups}" != yes ]; then
        # mkdir makes a new folder or fails: it never takes one that www-data put there in the meantime
        mkdir -m 700 -- clouve-backups || die 1 "could not make ${backups_dir}"
        enter_backups_dir
        in_backups=yes
    fi
    if [ -e "${name}" ] || [ -L "${name}" ]; then
        die 1 "a backup named ${name} is there already; run this again in a second"
    fi
    mkdir -m 700 -- "${name}" || die 2 "could not make ${backups_dir}/${name}"
    folder=${name}
    say "backup ${name}: $([ "${with_data}" -eq 1 ] && echo "the database, config/, the apps and the users' files" || echo "the database, config/ and the apps (not the users' files)")"

    # 5. Maintenance mode
    if [ "${no_maintenance}" -eq 0 ]; then
        if [ "${maint_before}" = false ]; then
            hold_marker
            maint_ours=yes
            (cd / && exec "${NC_OCC[@]}" maintenance:mode --on) < /dev/null || die 2 "occ maintenance:mode --on failed"
            say "maintenance mode is on: people see a maintenance page until the archives are written"
        else
            say "maintenance mode was already on; this backup leaves it on"
        fi
    fi

    # 6. The archives
    say "dumping the database ${db_name}"
    mariadb-dump --defaults-extra-file="${cnf}" --skip-ssl --single-transaction --quick --hex-blob \
        --default-character-set=utf8mb4 --routines --triggers "${db_name}" < /dev/null | gzip > "${folder}/database.sql.gz"
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -ne 0 ]; then die 2 "mariadb-dump failed (exit ${st[0]})"; fi
    if [ "${st[1]}" -ne 0 ]; then die 2 "gzip failed while it wrote database.sql.gz (exit ${st[1]})"; fi
    say "database.sql.gz written ($(human "$(stat -c %s -- "${folder}/database.sql.gz")"))"
    parts=(database.sql.gz)
    make_archive config.tar.gz -C "${nc_root}" config
    parts+=(config.tar.gz)
    for p in custom_apps themes; do
        if [ -d "${nc_root}/${p}" ]; then app_dirs+=("${p}"); fi
    done
    if [ "${#app_dirs[@]}" -gt 0 ]; then make_archive apps.tar.gz -C "${nc_root}" "${app_dirs[@]}"
    else make_archive apps.tar.gz -C "${nc_root}" -T /dev/null; fi
    parts+=(apps.tar.gz)
    if [ "${with_data}" -eq 1 ]; then
        # -C ..: the data folder, as the parent of clouve-backups, whatever its name is now. --anchored and
        # --no-wildcards-match-slash: the patterns match from ./ and * stops at a /, so only the data folder's own
        # clouve-backups and the appdata_<id>/preview folders stay out
        make_archive data.tar.gz -C .. --anchored --no-wildcards-match-slash \
            --exclude=./clouve-backups --exclude='./appdata_*/preview' .
        parts+=(data.tar.gz)
    fi

    # Maintenance mode back off, then the marker goes and its lock with it
    if [ "${maint_ours}" = yes ]; then
        if out=$(cd / && "${NC_OCC[@]}" maintenance:mode --off < /dev/null 2>&1); then
            maint_ours=no
            rm -f -- "${marker}"
            exec 8<&-
            marker_held=no
            say "maintenance mode is off again"
        else
            maint_ours=no
            keep_marker=yes
            off_failed=yes
            warn "could not turn maintenance mode off: $(first_line "${out}"). Run occ.sh maintenance:mode --off to turn it off. ${marker_shown} stays, so the container's next start turns it off too."
        fi
    fi

    # 7. The manifest and SHA256SUMS
    for p in "${parts[@]}"; do
        n=$(stat -c %s -- "${folder}/${p}") || die 2 "could not read the size of ${p}"
        digits "${n}" || die 2 "the size of ${p} is not a number"
        sizes+=("${n}")
    done
    {
        printf '{\n'
        printf '  "created": %s,\n' "$(json_str "${created}")"
        printf '  "version": %s,\n' "$(json_str "${cfg_version}")"
        printf '  "versionstring": %s,\n' "$(json_str "${versionstring}")"
        printf '  "instanceid": %s,\n' "$(json_str "${instance_id}")"
        printf '  "dbname": %s,\n' "$(json_str "${db_name}")"
        printf '  "with_data": %s,\n' "$([ "${with_data}" -eq 1 ] && echo true || echo false)"
        if [ "${with_data}" -eq 1 ]; then printf '  "data_bytes": %s,\n' "${data_disk}"; fi
        printf '  "files": [\n'
        for ((n = 0; n < ${#parts[@]}; n++)); do
            printf '    {"name": "%s", "bytes": %s}%s\n' "${parts[n]}" "${sizes[n]}" "$([ "$((n + 1))" -lt "${#parts[@]}" ] && echo ,)"
        done
        printf '  ],\n'
        printf '  "made_by": %s\n' "$(json_str "${made_by}")"
        printf '}\n'
    } > "${folder}/manifest.json" || die 2 "could not write manifest.json"
    (cd -P -- "${folder}" && sha256sum -- "${parts[@]}" manifest.json > SHA256SUMS) || die 2 "could not write SHA256SUMS"

    # 8. The check
    if ! check=$(cd -P -- "${folder}" && sha256sum -c --quiet SHA256SUMS 2>&1); then
        die 4 "the check of the new backup failed (sha256sum -c): $(first_line "${check}")"
    fi
    for p in "${parts[@]}"; do
        if ! check=$(gzip -t -- "${folder}/${p}" 2>&1); then
            die 4 "the check of the new backup failed (gzip -t ${p}): $(first_line "${check}")"
        fi
    done

    # 9. Done
    folder_done=yes
    n=$(du_bytes "${folder}") || n=0
    if [ "${off_failed}" = yes ]; then
        warn "the backup is complete, but maintenance mode is still on (see above)"
    fi
    say "done: ${backups_dir}/${folder} ($(human "${n}")). It is on Nextcloud's data volume next to the data it protects; it is never deleted automatically."
    if [ "${off_failed}" = yes ]; then exit 5; fi
    exit 0
}

main "$@" < /dev/null
