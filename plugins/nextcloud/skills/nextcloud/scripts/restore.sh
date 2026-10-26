#!/usr/bin/env bash
# Nextcloud DevOps Skill: restore.sh
#
# Runs INSIDE the Nextcloud container, as root, never on the agent. run-in-nextcloud.sh sends it there over
# the clouve-ops SSH channel, as `sudo bash -s -- ARGS` with this file on stdin, or with --detach as a job in
# /run/clouve/jobs (a restore should always be detached). sudo drops the container's environment, so no
# setting comes from the NEXTCLOUD_* variables: the database credentials and the data folder come from
# config/config.php, and so do the settings the restore keeps. PHP reads and merges config.php as www-data and
# never as root, because config.php is code that www-data can change.
#
# Usage: restore.sh --backup <name> --yes-replace-current-data [--skip-data]
#
# Restores a backup that backup.sh made, from /var/www/html/data/clouve-backups/<name>/, over this Nextcloud.
# datadirectory in config.php must be that data folder, the one place the image looks for the markers.
#
# www-data owns config/, custom_apps/, themes/ and the data folder, and /var/www/html around them, and can rename
# what is in them, or put a link in its place, at any time. So root never writes, deletes or extracts in them: every
# change there is made by a command that runs as www-data (find and rm, tar -x, cat, chmod, mv), and root only opens
# the backup's archives and hands them over on a pipe. And root reads the backup from folders it checked once: the
# script works from inside clouve-backups (cd -P: a plain cd changes to "$PWD/NAME", through the path again), and opens
# the backup's files by names relative to it, so a data folder or a clouve-backups renamed or swapped for a link
# afterwards changes nothing for it.
#
#   1. Checks, before anything changes. Root; the data folder; the backup is a folder of root's in clouve-backups
#      with manifest.json and a SHA256SUMS that names only a backup's files (each root's) and passes sha256sum -c
#      (else exit 2); the backup's version against the code's from `occ status` (newer than the code, or more than
#      one major older, is exit 3); a backup without data.tar.gz needs --skip-data (else exit 2); www-data can
#      write in the folders the restore changes, and can empty them: no folder in config/, custom_apps/, themes/
#      or (with the users' files) the data folder is one www-data can't read, write in or go into (else exit 2,
#      naming it; the sticky bit is out of scope); with the users' files, the data volume has room for them: the free
#      space plus what the current users' files take (they go first) is at least the backup's data_bytes plus 5 %
#      (else exit 2, with the numbers in MB; a manifest without data_bytes gets a warning instead). Without
#      --yes-replace-current-data it then prints what would be replaced, and the newest other backup, and stops
#      with exit 1. Then the image's init lock, held to the end (fd 9): no install, upgrade, backup or second
#      restore runs meanwhile, and the container's health probe reports healthy while it is held, so a slow import
#      is never killed. The lock file is www-data's, so root opens it only as a plain file, read-only, and gives up
#      after 5 seconds (a named pipe swapped in would make the open wait forever).
#      When occ can't start and the marker below is there (an earlier restore was cut off, and the database may
#      be half imported), the code's version comes from version.php instead, so a restore can still put things
#      back. Without the marker, an occ that can't start stops the restore (exit 2). With the marker there, the
#      preview says that backup.sh refuses to back up the half-restored state, instead of advising a backup first.
#   2. The settings the image manages, read from the current config.php into a mode 600 file: dbhost, dbname,
#      dbuser, dbpassword, overwrite.cli.url, overwriteprotocol, trusted_domains, trusted_proxies,
#      memcache.distributed, memcache.locking, redis, preview_concurrency_new, preview_concurrency_all and
#      datadirectory.
#   3. The start. clouve-backups/RESTORE-IN-PROGRESS goes in first, with the backup's name on its first line (made
#      under a temporary name and renamed into place, so a marker from a restore that was cut off is replaced in one
#      step), then maintenance mode goes on. While the marker is there, the image's start-up leaves maintenance mode
#      and any pending upgrade alone, and verify-health.sh reports a restore that was cut off. If maintenance mode
#      can't be turned on, or the run is stopped in this step, maintenance mode goes back to how it was (off only if
#      this run turned it on), the new marker goes again, and nothing has changed (exit 2, or 130 or 143 for a signal).
#   4. The database: every table of the current schema is dropped (SET FOREIGN_KEY_CHECKS=0, then DROP TABLE,
#      or DROP VIEW, for each row of information_schema.tables), then the dump is imported into it.
#   5. config.php: the backup's, with the kept settings put back (trusted_domains is both lists, the current
#      entries first) and 'maintenance' => true. The backup's secret, passwordsalt and instanceid stay, since
#      the database was made with them. Root takes the backup's config.php out of config.tar.gz on a pipe, and
#      www-data writes it into config/; a PHP program, as www-data, writes the merge with var_export, and www-data
#      gives it the current file's mode and renames it over config.php. Then www-data empties the rest of config/ and
#      extracts the backup's other files of config/.
#   6. custom_apps/ and themes/: www-data empties them and extracts apps.tar.gz.
#   7. The users' files, unless --skip-data: www-data removes everything in the data folder but clouve-backups, then
#      extracts data.tar.gz. Everything www-data extracts is www-data's, with the modes in the archive (tar -p).
#   8. The finish. When the backup is older than the code, `occ upgrade`, with maintenance mode still on: occ
#      runs a pending upgrade in maintenance mode, and the Updater leaves a maintenance mode it found on as it is
#      (core/Command/Upgrade.php, lib/private/Updater.php:82-124). Then the steps after an upgrade
#      (db:add-missing-indices, -columns, -primary-keys, maintenance:repair --include-expensive; a failure there is
#      a warning, as in the image's own post-upgrade hook). Then `occ maintenance:data-fingerprint`, so desktop and
#      phone clients know a backup came back. Then `occ memcache:redis:command FLUSHDB` empties Valkey, which would
#      otherwise keep, for up to a day, the names, groups and Team shares it cached before (a failure is a warning).
#      Then maintenance mode off. Then, only when the users' files were restored whole, `occ files:scan --all`, and
#      `occ groupfolders:scan --all` when the Team folders app is enabled (Team folders live in __groupfolders, which
#      files:scan does not cover). These two are app commands, which occ does not load in maintenance mode. Then the
#      marker goes, and the last line is `[nextcloud/restore] done: <name>`.
# A step that fails after step 3 leaves the marker in place and, until step 8 turns it off, maintenance mode on:
# the output names the step, and the newest other backup with the command that puts it back (exit 4). A failure
# after maintenance mode is off says so: the restore is in place and only that step needs doing again.
#
# Signals: INT and TERM stop the restore after the command that is running. Before the start that is all (exit
# 130 or 143, nothing was changed); after it, the state is that of a failure (exit 4). HUP and PIPE mean the SSH
# session is gone: the restore carries on to the end, with its output going nowhere, since a restore cut short
# leaves Nextcloud broken and one that finishes leaves it working. occ's output goes through a file for the same
# reason. The marker shows afterwards whether it finished.
#
# The database password reaches mariadb in a mode 600 --defaults-extra-file in a mode 700 folder that is
# deleted at the end, and the kept settings sit in a mode 600 file beside it; neither is ever on a command line,
# and nothing prints them. The whole script is one function, called on the last line with stdin from
# /dev/null: under `bash -s` bash reads it all before it runs any of it.
#
# Exit codes:
#   0    done
#   1    usage, or not confirmed (nothing was changed)
#   2    the backup can't be used, or the restore can't start here (not root, a datadirectory other than
#        /var/www/html/data, occ can't say, the init lock is held, www-data can't write where it must or can't
#        empty a folder, not enough space, maintenance mode can't be turned on); nothing was changed
#   3    the versions don't fit; nothing was changed
#   4    a step failed, or the run was stopped, after the changes began; the marker stays
#   130  stopped by INT before the changes began; nothing was changed
#   143  stopped by TERM before the changes began; nothing was changed
#
# Overrides, for tests: NC_ROOT (default /var/www/html) and NC_OCC (default
# "sudo -n -u www-data php $NC_ROOT/occ --no-interaction --no-warnings", split at spaces).

set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the database password.
set +x

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
data_setting='' db_type='' db_hostspec='' db_name='' db_user='' db_password='' cur_instance=''
# The data folder's real path and its device and inode (enter_data_dir), and clouve-backups' path, for the messages.
data_dir='' data_id='' backups_dir=''

# What the EXIT trap looks at. marker and marker_tmp are names inside clouve-backups, the current folder once the
# script has checked it; cfg_input and cfg_output are www-data's temporary files in config/.
work=''
cfg_input=''
cfg_output=''
started=no
finished=no
step=''
maint_off_done=no
marker=RESTORE-IN-PROGRESS
marker_shown=''
marker_tmp=''
marker_placed=no
marker_before=no
maint_on_tried=no
signal=''
prev=''
prev_created=''
prev_skip=''
skip_flag=''
name=''

# The PHP program, run as www-data: `php -r CODE -- MODE ARGS...`. The modes:
#   get FILE KEY       KEY's value in FILE's $CONFIG (true or false for a boolean, JSON for an array); exit 1 when
#                      FILE has no KEY, 2 when FILE can't be read
#   managed FILE       the settings the image manages that FILE has, in serialize() form
#   merge FROM         FROM's $CONFIG with the kept settings (stdin, as managed printed them) put back: a managed key
#                      the current config.php has takes its value, one it lacks is left out. trusted_domains is both
#                      lists, the kept entries first, each once. Then 'maintenance' => true, and the whole config.php
#                      on stdout (var_export). It writes no file.
#   code-version FILE  version.php's $OC_Version, dotted
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
$managed = ['dbhost', 'dbname', 'dbuser', 'dbpassword', 'overwrite.cli.url', 'overwriteprotocol', 'trusted_domains',
    'trusted_proxies', 'memcache.distributed', 'memcache.locking', 'redis', 'preview_concurrency_new',
    'preview_concurrency_all', 'datadirectory'];
$mode = $argv[1] ?? '';
if ($mode === 'get' && count($argv) === 4) {
    $get($argv[2], $argv[3]);
}
if ($mode === 'managed' && count($argv) === 3) {
    $config = $load($argv[2], 'CONFIG');
    $kept = [];
    foreach ($managed as $key) {
        if (array_key_exists($key, $config)) {
            $kept[$key] = $config[$key];
        }
    }
    echo serialize($kept);
    exit(0);
}
if ($mode === 'merge' && count($argv) === 3) {
    $kept = @unserialize((string) stream_get_contents(STDIN), ['allowed_classes' => false]);
    if (!is_array($kept)) {
        fwrite(STDERR, "the kept settings on stdin can't be read\n");
        exit(2);
    }
    $new = $load($argv[2], 'CONFIG');
    foreach ($managed as $key) {
        if ($key === 'trusted_domains') {
            continue;
        }
        if (array_key_exists($key, $kept)) {
            $new[$key] = $kept[$key];
        } else {
            unset($new[$key]);
        }
    }
    $domains = [];
    foreach ([$kept['trusted_domains'] ?? [], $new['trusted_domains'] ?? []] as $list) {
        foreach ((array) $list as $domain) {
            if (is_string($domain) && $domain !== '' && !in_array($domain, $domains, true)) {
                $domains[] = $domain;
            }
        }
    }
    if ($domains === []) {
        unset($new['trusted_domains']);
    } else {
        $new['trusted_domains'] = $domains;
    }
    $new['maintenance'] = true;
    echo "<?php\n\$CONFIG = " . var_export($new, true) . ";\n";
    exit(0);
}
if ($mode === 'code-version' && count($argv) === 3) {
    echo implode('.', $load($argv[2], 'OC_Version'));
    exit(0);
}
fwrite(STDERR, "usage: get FILE KEY | managed FILE | merge FROM | code-version FILE\n");
exit(64);
PHP

usage() {
    cat <<'EOF'
Usage: restore.sh --backup <name> --yes-replace-current-data [--skip-data]

Restores a backup that backup.sh made (/var/www/html/data/clouve-backups/<name>/) over this Nextcloud: the
database, config/ (keeping this server's database, address, domains, proxies, cache, previews and data folder
settings), custom_apps/ and themes/, and the users' files unless --skip-data. Without
--yes-replace-current-data it only says what it would replace. It runs inside the Nextcloud container as root:
send it with run-in-nextcloud.sh --detach. Back up the current state first; after a restore that was cut off,
backup.sh refuses, and the preview says what to do.

Exit codes: 0 done; 1 usage, or not confirmed; 2 the backup can't be used, or the restore can't start here;
3 the versions don't fit; 4 a step failed after the changes began (the marker stays); 130 and 143 stopped by
INT or TERM before the changes began. 1, 2, 3, 130 and 143 change nothing.
EOF
}

say() { printf '[nextcloud/restore] %s\n' "$*"; }
msg() { printf '[nextcloud/restore] %s\n' "$*" >&2; }
warn() { printf '[nextcloud/restore] WARNING: %s\n' "$*" >&2; }
die() {
    local code=$1
    shift
    msg "$@"
    exit "${code}"
}
usage_error() {
    msg "$1"
    usage >&2
    exit 1
}

# fail WHAT: a step after the start failed. The EXIT trap says what state Nextcloud is in, and exits 4.
fail() {
    msg "FAILED in step ${step}: $1"
    exit 4
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

# setting VAR KEY [DEFAULT]: VAR = KEY's value in config.php; DEFAULT when config.php has no KEY, else exit 2
setting() {
    local var=$1 key=$2 value rc=0
    value=$(php_run get "${config_file}" "${key}" < /dev/null) || rc=$?
    case ${rc} in
        0) ;;
        1)
            if [ "$#" -lt 3 ]; then die 2 "config.php has no ${key}"; fi
            value=$3
            ;;
        *) die 2 "could not read ${key} from ${config_file} (php exited ${rc})" ;;
    esac
    printf -v "${var}" '%s' "${value}"
}

# occ_run "${NC_OCC[@]}" ARGS...: runs that occ command (from /) with its output kept in the work folder, and prints
# the output, indented, once occ has ended. A session that drops can then not make occ's own writes fail. The callers
# spell the occ command out, so that every occ call in this file shows its subcommand and options.
occ_run() {
    local rc=0 line
    (cd / && exec "$@") < /dev/null > "${work}/occ.out" 2>&1 || rc=$?
    while IFS= read -r line || [ -n "${line}" ]; do printf '  %s\n' "${line}"; done < "${work}/occ.out"
    return "${rc}"
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

# a_version TEXT: succeeds when TEXT is a dotted version of two to four short numbers
a_version() {
    [[ $1 =~ ^[0-9]{1,9}(\.[0-9]{1,9}){1,3}$ ]]
}

# ver_cmp A B: -1, 0 or 1, comparing the numbers part by part (a missing part is 0)
ver_cmp() {
    local -a a=() b=()
    local i x y
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    for i in 0 1 2 3; do
        x=$((10#${a[i]:-0}))
        y=$((10#${b[i]:-0}))
        if [ "${x}" -lt "${y}" ]; then printf -- -1 && return 0; fi
        if [ "${x}" -gt "${y}" ]; then printf 1 && return 0; fi
    done
    printf 0
}

# read_status: status_json = the JSON line of `occ status --output=json`, and status_error = what occ said when
# there is none. Fails when there is none.
read_status() {
    local text rc=0 line
    text=$(cd / && "${NC_OCC[@]}" status --output=json < /dev/null) || rc=$?
    status_json=''
    while IFS= read -r line; do
        case ${line} in '{'*'}') status_json=${line} ;; esac
    done <<< "${text}"
    status_error="exit ${rc}: $(first_line "${text}")"
    [ "${rc}" -eq 0 ] && [ -n "${status_json}" ]
}

# split_dbhost DBHOST: db_host, db_port and db_socket, split the way Nextcloud splits dbhost
# (lib/private/DB/ConnectionFactory.php, splitHostFromPortAndSocket)
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

# cnf_quote VAR TEXT: VAR = TEXT as a double-quoted value in a MariaDB options file (mysys/my_default.c)
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

# write_client_cnf: the [client] options file mariadb reads, mode 600 in the work folder
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
    } > "${cnf}" || die 2 "could not write the database options file in ${work}"
}

# db_query SQL: mariadb's answer, without column names (--skip-ssl: the server's certificate is self-signed)
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
    case ${data_setting} in /*) ;; *) die 2 "datadirectory in config.php is not an absolute path: $(printf '%q' "${data_setting}")" ;; esac
    if [ -L "${want}" ] || [ ! -d "${want}" ]; then die 2 "${want} is not a folder (it is missing, or a link)"; fi
    real=$(cd -P -- "${data_setting}" 2> /dev/null && pwd -P) || real=''
    if [ -z "${real}" ] || [ "${real}" != "$(cd -P -- "${want}" && pwd -P)" ]; then
        die 2 "datadirectory in config.php is $(printf '%q' "${data_setting}"), and this works only with ${want}, where the image looks for clouve-backups and its markers"
    fi
    data_id=$(stat -c %d:%i -- "${want}") || die 2 "cannot read ${want}"
    cd -P -- "${want}" || die 2 "cannot open ${want}"
    if [ "$(stat -c %d:%i -- .)" != "${data_id}" ]; then die 2 "${want} changed while it was checked"; fi
    data_dir=$(pwd -P)
}

# enter_backups_dir: clouve-backups, in the data folder (the current folder), must be a folder of the user this runs
# as (root, in the container), not a link: anything else could have been put there by www-data. The script then
# works from inside it, and makes it mode 700 when it is not. Its parent must still be the data folder: www-data can
# rename clouve-backups within the data folder, but only root can move a folder of root's into another folder.
enter_backups_dir() {
    local st
    st=$(stat -c '%F %u %d:%i' -- clouve-backups 2> /dev/null) || die 2 "cannot read ${backups_dir}"
    case ${st} in
        "directory ${owner_me} "*) ;;
        directory\ *) die 2 "${backups_dir} is not root's, so something else made it. Move it away and run this again." ;;
        *) die 2 "${backups_dir} is not a folder (it is a link or a file). Move it away and run this again." ;;
    esac
    cd -P -- clouve-backups || die 2 "cannot open ${backups_dir}"
    if [ "$(stat -c '%F %u %d:%i' -- .)" != "${st}" ]; then die 2 "${backups_dir} changed while it was checked"; fi
    if [ "$(stat -c %d:%i -- ..)" != "${data_id}" ]; then die 2 "${backups_dir} is not in the data folder any more"; fi
    if [ "$(stat -c %a -- .)" != 700 ]; then chmod 700 . || die 2 "could not make ${backups_dir} mode 700"; fi
}

# open_init_lock FILE: FILE on fd 9, read-only (never created), then the check that fd 9 is FILE itself, a plain
# file: the same device and inode as FILE's own (stat without -L), which a link, or a file swapped in, does not have.
# The open gives up after 5 seconds, as the image's own probe of a lock does (lib.sh, _nc_backup_lock): a reader of
# the timer pipe sends ALRM when the pipe stays open that long, bash breaks off the open to run the trap, and the trap
# ends the script. Closing the pipe ends the reader. Fails when fd 9 is not FILE, a plain file.
open_init_lock() {
    local file=$1 timer timer_pid
    trap 'die 2 "could not open ${file} within 5 seconds (something put another kind of file in its place)"' ALRM
    exec {timer}> >(read -r -t 5 _; [ "$?" -le 128 ] || kill -s ALRM "$$" 2> /dev/null)
    timer_pid=$!
    exec 9< "${file}" || die 2 "could not open ${file}"
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
        warn "the image's init lock (${lock}) is not there, so nothing keeps an upgrade out while this runs"
        return 0
    fi
    if [ -L "${lock}" ] || [ ! -f "${lock}" ]; then die 2 "the image's init lock ${lock} is not a plain file, so this restore does not open it. Nothing was changed."; fi
    open_init_lock "${lock}" || die 2 "the image's init lock ${lock} changed while it was opened. Nothing was changed."
    if ! flock -n 9; then
        die 2 "the image's init lock is held: an install, an upgrade or its recovery is running, or a backup or another restore. Nothing was changed; run this again when it is done."
    fi
}

# own_folder NAME WHAT: NAME, in clouve-backups, is a folder of root's, not a link
own_folder() {
    if [ -L "$1" ] || [ ! -d "$1" ]; then die 2 "$2 (${backups_dir}/$1) is not a folder"; fi
    if [ "$(stat -c %u -- "$1")" != "${owner_me}" ]; then die 2 "$2 (${backups_dir}/$1) is not root's, so restore.sh does not trust it"; fi
}

# check_sums_file: SHA256SUMS names only the files of a backup, each once, and all four that every backup has, and
# each of them is a plain file of root's. Sets has_data when it names data.tar.gz.
check_sums_file() {
    local line f seen=' ' re='^[0-9a-f]{64} [ *](.+)$'
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -n "${line}" ] || continue
        [[ ${line} =~ ${re} ]] || die 2 "SHA256SUMS of ${name} has a line that is not a checksum"
        f=${BASH_REMATCH[1]}
        case ${f} in
            database.sql.gz | config.tar.gz | apps.tar.gz | data.tar.gz | manifest.json) ;;
            *) die 2 "SHA256SUMS of ${name} names a file that is no part of a backup: $(printf '%q' "${f}")" ;;
        esac
        case ${seen} in *" ${f} "*) die 2 "SHA256SUMS of ${name} names ${f} twice" ;; esac
        seen+="${f} "
    done < "${name}/SHA256SUMS"
    for f in database.sql.gz config.tar.gz apps.tar.gz manifest.json; do
        case ${seen} in *" ${f} "*) ;; *) die 2 "SHA256SUMS of ${name} does not cover ${f}" ;; esac
    done
    has_data=no
    case ${seen} in *' data.tar.gz '*) has_data=yes ;; esac
    for f in ${seen}; do
        if [ -L "${name}/${f}" ] || [ ! -f "${name}/${f}" ]; then die 2 "the backup ${name} has no file ${f}"; fi
        if [ "$(stat -c %u -- "${name}/${f}")" != "${owner_me}" ]; then die 2 "${f} of the backup ${name} is not root's, so restore.sh does not trust it"; fi
    done
}

# find_prev: prev = the newest other complete backup in clouve-backups (for the messages), with prev_created,
# and prev_skip " --skip-data" when it holds no users' files
find_prev() {
    local d m
    prev='' prev_created='' prev_skip=''
    for d in *; do
        [[ ${d} =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
        [ "${d}" != "${name}" ] || continue
        if [ -L "${d}" ] || [ ! -d "${d}" ] || [ ! -f "${d}/SHA256SUMS" ] || [ ! -f "${d}/manifest.json" ]; then continue; fi
        prev=${d}
    done
    if [ -n "${prev}" ]; then
        m=$(< "${prev}/manifest.json")
        prev_created=$(json_text "${m}" created)
        if [ ! -f "${prev}/data.tar.gz" ]; then prev_skip=' --skip-data'; fi
    fi
}

# check_writable: www-data must be able to write in each folder the restore changes, since www-data's commands make
# the changes: config/, custom_apps/, themes/ (or /var/www/html, for one that isn't there) and, with the users'
# files, the data folder. Exit 2 otherwise, before anything changes.
check_writable() {
    local d p
    for d in config custom_apps themes; do
        p=${nc_root}/${d}
        if [ ! -e "${p}" ] && [ ! -L "${p}" ]; then p=${nc_root}; fi
        www test -w "${p}" || die 2 "www-data can't write in ${p}, and the restore changes it as www-data. Nothing was changed."
    done
    if [ "${with_data}" = yes ]; then
        www test -w "${data_dir}" || die 2 "www-data can't write in ${data_dir}, and the restore changes it as www-data. Nothing was changed."
    fi
}

# glob_quote TEXT: TEXT with the characters that find's -path reads as a pattern (\ * ? [) escaped
glob_quote() {
    local text=$1
    text=${text//\\/\\\\}
    text=${text//\*/\\*}
    text=${text//\?/\\?}
    text=${text//\[/\\[}
    printf '%s' "${text}"
}

# check_emptiable: www-data must be able to empty each folder the restore empties: config/ (all of it but config.php),
# custom_apps/ and themes/ (each when it is there) and, with the users' files, the data folder (but clouve-backups at
# depth 1, which www-data can't go into). One folder in them that www-data can't read, write in or go into (a folder
# root made, or one of mode 555 or 000) would stop the restore halfway, after the database is the backup's, and every
# run after would stop there again. So find, as www-data and from / like www-data's other commands, looks for the
# first such folder (-readable, -writable and -executable test www-data's own access), and the restore stops before
# anything changes (exit 2). The sticky bit is out of scope: Nextcloud never sets one (in a folder that has it,
# www-data could remove only its own files).
check_emptiable() {
    local d
    emptiable_in "${nc_root}/config" "${nc_root}/config/config.php"
    for d in custom_apps themes; do
        if [ -d "${nc_root}/${d}" ]; then emptiable_in "${nc_root}/${d}"; fi
    done
    if [ "${with_data}" = yes ]; then emptiable_in "${data_dir}" "${data_dir}/clouve-backups"; fi
}

# emptiable_in TOP [SKIP]: the check of check_emptiable for the folder TOP, leaving out the path SKIP
emptiable_in() {
    local top=$1 hit='' rc=0
    local -a skip=()
    if [ -n "${2:-}" ]; then skip=(-path "$(glob_quote "$2")" -prune -o); fi
    www find "${top}" ${skip[@]+"${skip[@]}"} -type d \( ! -readable -o ! -writable -o ! -executable \) -print0 -quit \
        > "${work}/emptiable" 2> "${work}/emptiable.err" || rc=$?
    IFS= read -r -d '' hit < "${work}/emptiable" || :
    if [ -n "${hit}" ]; then
        die 2 "www-data can't empty $(printf '%q' "${hit}"), a folder it can't read, write in or go into, so the restore would stop halfway. Nothing was changed."
    fi
    if [ "${rc}" -ne 0 ]; then
        die 2 "could not check ${top} for folders www-data can't empty: find, as www-data, ended with exit ${rc}: $(first_line "$(< "${work}/emptiable.err")"). Nothing was changed."
    fi
}

# check_space: the users' files are replaced, so the data volume must hold the backup's: its free space plus what
# the current users' files take (everything in the data folder but clouve-backups, which goes first) must be at least
# the space they took when the backup was made (data_bytes in manifest.json, du -s -B1) plus 5 %. Exit 2 otherwise,
# before anything changes. A manifest without data_bytes gets a warning.
check_space() {
    local free cur cb need
    if [ -z "${b_data_bytes}" ]; then
        warn "manifest.json of ${name} does not say how much space its users' files take (data_bytes), so the free space was not checked"
        return 0
    fi
    digits "${b_data_bytes}" || die 2 "manifest.json of ${name} has a data_bytes that is not a number"
    free=$(free_bytes .) || die 2 "could not read the free space of the data volume"
    cur=$(du_bytes .. disk) || die 2 "could not measure ${data_dir}"
    cb=$(du_bytes . disk) || die 2 "could not measure ${backups_dir}"
    cur=$((cur - cb))
    if [ "${cur}" -lt 0 ]; then cur=0; fi
    need=$(((10#${b_data_bytes} * 105 + 99) / 100))
    if [ $((free + cur)) -lt "${need}" ]; then
        die 2 "not enough space to restore the users' files: they need $(in_mb "${need}") (the $(in_mb "$((10#${b_data_bytes}))") they took when the backup was made, plus 5 %), and the data volume has $(in_mb "${free}") free plus the $(in_mb "${cur}") the current users' files take, which go first. Nothing was changed. Free some space first (old backups in ${backups_dir} count too)."
    fi
}

# new_config_name VAR: VAR = a path in config/ named .config.php.<12 hex digits> that is not there yet, the name the
# image's start-up sweeps away when a killed run leaves one (nc_sweep_leftovers). www-data makes the file.
new_config_name() {
    local hex path i
    for i in 1 2 3; do
        printf -v hex '%04x%04x%04x' "${RANDOM}" "${RANDOM}" "${RANDOM}"
        path=${nc_root}/config/.config.php.${hex}
        if [ ! -e "${path}" ] && [ ! -L "${path}" ]; then
            printf -v "$1" '%s' "${path}"
            return 0
        fi
    done
    return 1
}

# www_write FILE: stdin into FILE, a new file that www-data makes (noclobber, so never one that is there already)
# shellcheck disable=SC2016  # $1 is for www-data's bash
www_write() { www bash -c 'set -C && cat > "$1"' www_write "$1"; }

# put_marker: RESTORE-IN-PROGRESS with the backup's name on its first line, written under a temporary name beside it
# and renamed into place, so that a marker from a restore that was cut off is replaced in one step, never missing
put_marker() {
    marker_tmp=$(mktemp .RESTORE-IN-PROGRESS.XXXXXX) || return 1
    printf '%s\n' "${name}" > "${marker_tmp}" || return 1
    mv -f -- "${marker_tmp}" "${marker}" || return 1
    marker_tmp=''
}

# undo_start: the run stopped in step 3, before anything else changed. Maintenance mode goes back off when this run
# asked for it, and the marker goes when there was none before (the marker of a restore that was cut off stays).
# Fails when maintenance mode can't be turned back off.
# shellcheck disable=SC2329  # on_exit, the EXIT trap, calls it
undo_start() {
    if [ "${maint_on_tried}" = yes ] && ! occ_run "${NC_OCC[@]}" maintenance:mode --off; then
        msg "maintenance mode could not be turned back off"
        return 1
    fi
    if [ "${marker_before}" = yes ]; then
        msg "Nothing was changed: maintenance mode is as it was, and ${marker_shown}, there since a restore was cut off before this one, stays (it names $(marker_name "${marker}") now)."
    else
        rm -f -- "${marker}"
        msg "Nothing was changed: maintenance mode is as it was, and the marker is gone."
    fi
}

# recovery: what the output says after a failure or a stop past step 3
# shellcheck disable=SC2329  # on_exit, the EXIT trap, calls it
recovery() {
    if [ "${maint_off_done}" = yes ]; then
        msg "The database, config/, the apps and the users' files are restored, and maintenance mode is off, so people can sign in again; only this step did not finish. Run it again (with occ.sh), then remove the marker: sudo rm -f ${marker_shown}"
        return 0
    fi
    msg "Nextcloud stays closed to its users (maintenance mode, or an upgrade it still needs), and ${marker_shown} stays, so nobody works in a half-restored Nextcloud; verify-health.sh reports it."
    if [ "${marker_before}" = yes ]; then
        msg "This run started from a restore that had been cut off, so no backup holds the state before it. Fix the cause, then run this restore again: restore.sh --backup ${name} --yes-replace-current-data${skip_flag}"
    elif [ -n "${prev}" ]; then
        msg "The newest other backup is ${prev}, made ${prev_created:-at an unknown time}. If it was made just before this restore, this puts that state back: restore.sh --backup ${prev} --yes-replace-current-data${prev_skip}"
        msg "Or fix the cause, then run this restore again: restore.sh --backup ${name} --yes-replace-current-data${skip_flag}"
    else
        msg "There is no other backup here. Fix the cause, then run this restore again: restore.sh --backup ${name} --yes-replace-current-data${skip_flag}"
    fi
}

# on_exit: the EXIT trap. Before the start, a stop by a signal says that nothing was changed, and a stop in step 3
# undoes the start first. After the start, a run that did not finish exits 4 and says what state Nextcloud is in.
# Then the temporary files go.
# shellcheck disable=SC2329  # the EXIT trap calls it
on_exit() {
    local rc=$?
    trap '' INT TERM HUP PIPE
    if [ "${started}" != yes ] && [ "${marker_placed}" = yes ]; then
        if [ -n "${signal}" ]; then msg "STOPPED by SIG${signal} in step ${step}, before the restore began."; fi
        undo_start || started=yes
    elif [ "${started}" != yes ]; then
        if [ -n "${signal}" ]; then msg "STOPPED by SIG${signal} before the restore began. Nothing was changed."; fi
    elif [ "${finished}" != yes ] && [ -n "${signal}" ]; then
        msg "STOPPED by SIG${signal} in step ${step}."
    fi
    if [ "${started}" = yes ] && [ "${finished}" != yes ]; then
        recovery
        rc=4
    fi
    if [ -n "${marker_tmp}" ]; then rm -f -- "${marker_tmp}"; fi
    if [ -n "${cfg_input}" ]; then www rm -f -- "${cfg_input}"; fi
    if [ -n "${cfg_output}" ]; then www rm -f -- "${cfg_output}"; fi
    if [ -n "${work}" ]; then rm -rf -- "${work}"; fi
    exit "${rc}"
}

# session_gone: HUP or PIPE, the SSH session that ran this is gone. The output goes nowhere from now on, and the
# restore carries on.
# shellcheck disable=SC2329  # the HUP and PIPE traps call it
session_gone() {
    exec > /dev/null 2>&1
}

main() {
    local confirmed=no skip_data=no rc st m code_version maint_before b_version b_versionstring b_created
    local b_with_data b_instance upgrade=no tables tname ttype sql q d check apps_json size
    b_data_bytes='' with_data=no
    while [ "$#" -gt 0 ]; do
        case $1 in
            --backup)
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage_error "--backup needs a backup's name"; fi
                name=$2
                shift 2
                ;;
            --yes-replace-current-data) confirmed=yes && shift ;;
            --skip-data) skip_data=yes && skip_flag=' --skip-data' && shift ;;
            -h | --help) usage && exit 0 ;;
            *) usage_error "unknown argument: $(printf '%q' "$1")" ;;
        esac
    done
    if [ -z "${name}" ]; then usage_error "--backup <name> is missing"; fi

    umask 077
    trap on_exit EXIT
    trap 'signal=INT; exit 130' INT
    trap 'signal=TERM; exit 143' TERM
    trap session_gone HUP PIPE

    # 1. Checks, before anything changes
    if [ "$(id -u 2> /dev/null)" != 0 ]; then
        die 2 "this runs inside the Nextcloud container as root; run-in-nextcloud.sh sends it there with sudo"
    fi
    if [ ! -f "${config_file}" ] || [ ! -r "${config_file}" ]; then die 2 "cannot read ${config_file}"; fi
    if ! [[ ${name} =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        die 2 "$(printf '%q' "${name}") is not the name of a backup (backup.sh names them like 20261024-101500; backup.sh --list shows them)"
    fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/clouve-restore.XXXXXX") || die 2 "could not make a temporary folder"
    owner_me=$(stat -c %u -- "${work}") || die 2 "cannot read the owner of ${work}"

    # From here on the script works inside the data folder's clouve-backups.
    setting data_setting datadirectory "${nc_root}/data"
    enter_data_dir
    backups_dir=${data_dir}/clouve-backups
    marker_shown=${backups_dir}/${marker}
    if [ ! -e clouve-backups ] && [ ! -L clouve-backups ]; then die 2 "there are no backups: ${backups_dir} is not there"; fi
    enter_backups_dir
    if [ -e "${marker}" ] || [ -L "${marker}" ]; then marker_before=yes; fi

    if read_status; then
        case ${status_json} in
            *'"installed":true'*) ;;
            *) die 2 "Nextcloud is not installed here, and restore.sh restores into an installed Nextcloud" ;;
        esac
        code_version=$(json_text "${status_json}" version)
        maint_before=$(json_flag "${status_json}" maintenance)
    elif [ "${marker_before}" = yes ]; then
        code_version=$(php_run code-version "${nc_root}/version.php" < /dev/null) || die 2 "occ can't report the status (${status_error}), and version.php can't be read either"
        maint_before=$(php_run get "${config_file}" maintenance < /dev/null) || maint_before=false
        say "occ can't report the status (${status_error}), and ${marker_shown} shows that a restore of $(marker_name "${marker}") was cut off, so the code's version comes from version.php: ${code_version}"
    else
        die 2 "occ status failed (${status_error}), so this restore does not start"
    fi
    a_version "${code_version}" || die 2 "the code's version is not a version: $(printf '%q' "${code_version}")"

    if [ ! -e "${name}" ] && [ ! -L "${name}" ]; then die 2 "there is no backup ${name} in ${backups_dir} (backup.sh --list shows them)"; fi
    own_folder "${name}" "the backup ${name}"
    if [ -L "${name}/SHA256SUMS" ] || [ ! -f "${name}/SHA256SUMS" ]; then die 2 "the backup ${name} has no SHA256SUMS, so it was cut off while it was made"; fi
    if [ "$(stat -c %u -- "${name}/SHA256SUMS")" != "${owner_me}" ]; then die 2 "SHA256SUMS of the backup ${name} is not root's, so restore.sh does not trust it"; fi
    if [ ! -f "${name}/manifest.json" ] || [ -L "${name}/manifest.json" ]; then die 2 "the backup ${name} has no manifest.json"; fi
    check_sums_file
    if ! check=$(cd -P -- "${name}" && sha256sum -c --quiet SHA256SUMS 2>&1); then
        die 2 "the backup ${name} is damaged: sha256sum -c says $(first_line "${check}")"
    fi
    m=$(< "${name}/manifest.json")
    b_version=$(json_text "${m}" version)
    b_versionstring=$(json_text "${m}" versionstring)
    b_created=$(json_text "${m}" created)
    b_instance=$(json_text "${m}" instanceid)
    if [[ ${m} =~ \"data_bytes\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then b_data_bytes=${BASH_REMATCH[1]}; fi
    case ${m} in
        *'"with_data": true'*) b_with_data=yes ;;
        *'"with_data": false'*) b_with_data=no ;;
        *) die 2 "manifest.json of ${name} does not say with_data" ;;
    esac
    a_version "${b_version}" || die 2 "manifest.json of ${name} has no version that is a version: $(printf '%q' "${b_version}")"
    if [ "${b_with_data}" != "${has_data}" ]; then die 2 "the backup ${name} is damaged: manifest.json and SHA256SUMS disagree about data.tar.gz"; fi

    if [ "$(ver_cmp "${b_version}" "${code_version}")" = 1 ]; then
        die 3 "the backup ${name} is from Nextcloud ${b_version}, newer than the code here (${code_version}); Nextcloud can't go back to an older version"
    fi
    if [ $((10#${code_version%%.*} - 10#${b_version%%.*})) -gt 1 ]; then
        die 3 "the backup ${name} is from Nextcloud ${b_version}, more than one major version older than the code here (${code_version}); Nextcloud upgrades one major version at a time"
    fi
    if [ "$(ver_cmp "${b_version}" "${code_version}")" = -1 ]; then upgrade=yes; fi
    if [ "${has_data}" = no ] && [ "${skip_data}" = no ]; then
        die 2 "this backup has no users' files; add --skip-data to restore the rest"
    fi
    if [ "${has_data}" = yes ] && [ "${skip_data}" = no ]; then with_data=yes; fi

    setting db_type dbtype sqlite3
    if [ "${db_type}" != mysql ]; then die 2 "this restores into MySQL and MariaDB only, and config.php says dbtype ${db_type}"; fi
    setting db_hostspec dbhost localhost
    setting db_name dbname
    setting db_user dbuser
    setting db_password dbpassword ''
    setting cur_instance instanceid ''
    split_dbhost "${db_hostspec}"
    if [[ ${db_name} == -* ]]; then die 2 "dbname in config.php starts with -, which mariadb would read as an option"; fi
    find_prev
    check_writable
    check_emptiable
    if [ "${with_data}" = yes ]; then check_space; fi

    if [ "${confirmed}" != yes ]; then
        size=$(du_bytes "${name}") || size=0
        say "backup ${name}: made ${b_created:-at an unknown time} by Nextcloud ${b_versionstring:-?} (${b_version}), $([ "${has_data}" = yes ] && echo "with the users' files" || echo "without the users' files"), $(human "${size}")."
        say "Restoring it replaces, on this Nextcloud:"
        say "  - every table of the database ${db_name}, with the backup's"
        say "  - config/config.php and the other files in config/, with the backup's; this server's database, address, trusted domains, proxies, cache, previews and data folder settings are kept"
        say "  - custom_apps/ and themes/"
        if [ "${with_data}" = yes ]; then say "  - the users' files: everything in ${data_dir} but clouve-backups"
        else say "  - none of the users' files (--skip-data): they stay as they are"; fi
        if [ "${upgrade}" = yes ]; then say "Then occ upgrade runs, since the backup (${b_version}) is older than the code (${code_version})."; fi
        say "Then the data fingerprint changes, so desktop and phone clients see that a backup came back$([ "${with_data}" = yes ] && echo ", and files:scan --all reads the files again")."
        say "People see a maintenance page while it runs."
        if [ -n "${b_instance}" ] && [ -n "${cur_instance}" ] && [ "${b_instance}" != "${cur_instance}" ]; then
            say "Note: the backup is of the Nextcloud instance ${b_instance}, and this one is ${cur_instance}."
        fi
        if [ "${marker_before}" = yes ]; then
            # backup.sh refuses while the marker is there, so the usual advice to back up first can't be followed
            cut_name=$(marker_name "${marker}")
            say "A restore of ${cut_name} was cut off (${marker_shown} is there), so backup.sh refuses to run until a restore finishes, and the current, half-restored state can't be backed up first."
            if [ "${cut_name}" = "${name}" ]; then
                if [ -n "${prev}" ]; then
                    say "Restoring it again finishes that restore. To put back the state from before it instead, restore the backup made just before it, if one was made; the newest other backup here is ${prev}, made ${prev_created:-at an unknown time}."
                else
                    say "Restoring it again finishes that restore. There is no other backup here."
                fi
            else
                say "Restoring ${name} puts its state in place of the half-restored one. To finish the cut-off restore instead, run restore.sh --backup ${cut_name} again, with the options it had."
                if [ -n "${prev}" ]; then say "The newest other backup here is ${prev}, made ${prev_created:-at an unknown time}."; fi
            fi
        elif [ -n "${prev}" ]; then
            say "Back up the current state first (run-in-nextcloud.sh --detach backup.sh --with-data). The newest other backup here is ${prev}, made ${prev_created:-at an unknown time}."
        else
            say "Back up the current state first (run-in-nextcloud.sh --detach backup.sh --with-data): there is no other backup here."
        fi
        say "Nothing was changed. To restore, run this again with --yes-replace-current-data."
        exit 1
    fi

    take_init_lock

    # 2. The settings the image manages, kept in a mode 600 file
    write_client_cnf
    php_run managed "${config_file}" < /dev/null > "${work}/kept" || die 2 "could not read the settings to keep from config.php"

    # 3. The start: the marker first, then maintenance mode. Until started is yes, the EXIT trap undoes this step.
    step='3 (the start)'
    marker_placed=yes
    put_marker || die 2 "could not write ${marker_shown}"
    if [ "${maint_before}" = true ]; then
        say "maintenance mode is on already"
    else
        maint_on_tried=yes
        occ_run "${NC_OCC[@]}" maintenance:mode --on || die 2 "occ maintenance:mode --on failed, so the restore did not start"
    fi
    started=yes
    say "restoring ${name}: maintenance mode is on, and ${marker_shown} is there until the restore is done"

    # 4. The database
    step='4 (the database)'
    tables=$(db_query "SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()") ||
        fail "could not list the tables of ${db_name}"
    sql='SET FOREIGN_KEY_CHECKS=0;'
    while IFS=$'\t' read -r tname ttype; do
        [ -n "${tname}" ] || continue
        q=${tname//\`/\`\`}
        case ${ttype} in
            VIEW) sql+=" DROP VIEW \`${q}\`;" ;;
            *) sql+=" DROP TABLE \`${q}\`;" ;;
        esac
    done <<< "${tables}"
    db_query "${sql}" > /dev/null || fail "could not drop the tables of ${db_name}"
    gzip -dc -- "${name}/database.sql.gz" | mariadb --defaults-extra-file="${cnf}" --skip-ssl --default-character-set=utf8mb4 "${db_name}"
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -ne 0 ]; then fail "could not read database.sql.gz (gzip exit ${st[0]})"; fi
    if [ "${st[1]}" -ne 0 ]; then fail "the import of database.sql.gz into ${db_name} failed (mariadb exit ${st[1]})"; fi
    say "the database ${db_name} is the backup's"

    # 5. config.php and the other files of config/, all written by www-data
    step='5 (config/)'
    new_config_name cfg_input || fail "could not find a free temporary name in ${nc_root}/config"
    tar -xzOf "${name}/config.tar.gz" config/config.php < /dev/null | www_write "${cfg_input}"
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -ne 0 ]; then fail "could not take config/config.php out of config.tar.gz (tar exit ${st[0]})"; fi
    if [ "${st[1]}" -ne 0 ]; then fail "www-data could not write the backup's config.php into ${nc_root}/config (exit ${st[1]})"; fi
    new_config_name cfg_output || fail "could not find a free temporary name in ${nc_root}/config"
    php_run merge "${cfg_input}" < "${work}/kept" | www_write "${cfg_output}"
    st=("${PIPESTATUS[@]}")
    if [ "${st[0]}" -ne 0 ]; then fail "the merge of config.php failed (php exit ${st[0]})"; fi
    if [ "${st[1]}" -ne 0 ]; then fail "www-data could not write the new config.php (exit ${st[1]})"; fi
    # shellcheck disable=SC2016  # $1 and $2 are for www-data's bash
    www bash -c '[ -s "$1" ] && chmod --reference="$2" -- "$1" && mv -f -- "$1" "$2"' put_config "${cfg_output}" "${config_file}" ||
        fail "could not put the new config.php in place"
    cfg_output=''
    www rm -f -- "${cfg_input}"
    cfg_input=''
    www find "${nc_root}/config" -mindepth 1 -maxdepth 1 ! -name config.php -exec rm -rf -- {} + || fail "could not clear ${nc_root}/config"
    www tar -xzpf - -C "${nc_root}" --anchored --exclude=config/config.php < "${name}/config.tar.gz" ||
        fail "could not extract the other files of config.tar.gz"
    say "config/ is the backup's, with this server's settings kept"

    # 6. custom_apps/ and themes/
    step='6 (custom_apps/ and themes/)'
    for d in custom_apps themes; do
        if [ -d "${nc_root}/${d}" ]; then
            www find "${nc_root}/${d}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || fail "could not clear ${d}/"
        fi
    done
    www tar -xzpf - -C "${nc_root}" < "${name}/apps.tar.gz" || fail "could not extract apps.tar.gz"
    say "custom_apps/ and themes/ are the backup's"

    # 7. The users' files
    if [ "${with_data}" = yes ]; then
        step="7 (the users' files)"
        www find "${data_dir}" -mindepth 1 -maxdepth 1 ! -name clouve-backups -exec rm -rf -- {} + || fail "could not clear ${data_dir}"
        www tar -xzpf - -C "${data_dir}" --anchored --exclude=./clouve-backups < "${name}/data.tar.gz" || fail "could not extract data.tar.gz"
        say "the users' files are the backup's"
    fi

    # 8. The finish. Maintenance mode stays on through occ upgrade and the steps after it.
    if [ "${upgrade}" = yes ]; then
        step='8 (occ upgrade)'
        rc=0
        occ_run "${NC_OCC[@]}" upgrade || rc=$?
        if [ "${rc}" -ne 0 ]; then fail "occ upgrade failed (exit ${rc})"; fi
        step='8 (the steps after an upgrade)'
        occ_run "${NC_OCC[@]}" db:add-missing-indices || warn "occ db:add-missing-indices failed; the next step runs, as after the image's own upgrades"
        occ_run "${NC_OCC[@]}" db:add-missing-columns || warn "occ db:add-missing-columns failed; the next step runs, as after the image's own upgrades"
        occ_run "${NC_OCC[@]}" db:add-missing-primary-keys || warn "occ db:add-missing-primary-keys failed; the next step runs, as after the image's own upgrades"
        occ_run "${NC_OCC[@]}" maintenance:repair --include-expensive || warn "occ maintenance:repair --include-expensive failed; the restore goes on, as after the image's own upgrades"
    fi
    step='8 (the data fingerprint)'
    occ_run "${NC_OCC[@]}" maintenance:data-fingerprint || fail "occ maintenance:data-fingerprint failed"
    # Valkey keeps what it cached before the restore (people's names for a day, groups' names, the shares people
    # get through Teams, mount set-ups), and only a restart of the container empties it. occ memcache:distributed:clear
    # can't reach those entries now: in maintenance mode Nextcloud keys its cache under another prefix
    # (lib/private/Memcache/Factory.php:116-139). So the database Nextcloud uses in Valkey is emptied whole, as a
    # restart would. Nothing runs in maintenance mode, so it holds no lock now, and PHP keeps its sessions in files.
    step='8 (the cache)'
    occ_run "${NC_OCC[@]}" memcache:redis:command FLUSHDB || warn "occ memcache:redis:command FLUSHDB failed, so names, groups and Team shares that Valkey cached before the restore can show for up to a day; run occ.sh memcache:distributed:clear"
    step='8 (maintenance mode off)'
    occ_run "${NC_OCC[@]}" maintenance:mode --off || fail "occ maintenance:mode --off failed"
    maint_off_done=yes
    if [ "${with_data}" = yes ]; then
        step='8 (files:scan --all)'
        apps_json=$(cd / && "${NC_OCC[@]}" app:list --enabled --output=json < /dev/null 2> /dev/null) || apps_json=''
        occ_run "${NC_OCC[@]}" files:scan --all || fail "occ files:scan --all failed"
        case ${apps_json} in
            *'"enabled":{'*)
                apps_json=${apps_json#*\"enabled\":\{}
                apps_json=${apps_json%%\}*}
                case ${apps_json} in
                    *'"groupfolders":'*)
                        step='8 (groupfolders:scan --all)'
                        occ_run "${NC_OCC[@]}" groupfolders:scan --all || fail "occ groupfolders:scan --all failed"
                        ;;
                esac
                ;;
            *) warn "occ app:list gave no list of the enabled apps, so Team folders were not scanned; if the Team folders app is enabled, run occ.sh groupfolders:scan --all" ;;
        esac
    fi
    step='8 (the marker)'
    rm -f -- "${marker}" || fail "could not remove ${marker_shown}"
    finished=yes
    say "the data fingerprint changed: desktop and phone clients see that a backup came back. Check the result with verify-health.sh."
    say "done: ${name}"
    exit 0
}

main "$@" < /dev/null
