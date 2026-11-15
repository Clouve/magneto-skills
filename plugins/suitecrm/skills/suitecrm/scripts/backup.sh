#!/usr/bin/env bash
# SuiteCRM skill: backup.sh
#
# Takes a backup of this SuiteCRM: a dump of its database, and the files that hold the customer's own state.
# It runs inside the SuiteCRM container as root. From the agent, send it with run-in-suitecrm.sh:
#
#   run-in-suitecrm.sh [--detach] backup.sh
#   run-in-suitecrm.sh backup.sh --list
#   run-in-suitecrm.sh backup.sh --remove <name> --yes-remove
#
# A backup is a folder /var/www/html/tmp/clouve-skill-backups/<UTC YYYYmmdd-HHMMSS>/, root's, mode 700, with:
#   db.sql.gz      the database: one consistent dump (--single-transaction; SuiteCRM's tables are InnoDB)
#   state.tar.gz   the files, relative to /var/www/html:
#                    .env.local                                   the app secret and the database address
#                    public/legacy/config.php, config_override.php  SuiteCRM's settings
#                    public/legacy/custom/                         Studio changes, custom fields, layouts, hooks,
#                                                                  and custom/blowfish/, the key that decrypts
#                                                                  stored passwords such as the SMTP one
#                    public/legacy/upload/                         note and document files, installed packages
#                    public/legacy/cache/images/                   the pictures of email templates. SuiteCRM keeps
#                                                                  them in its cache folder, and nothing makes
#                                                                  them again. The rest of that folder is left out
#                    public/legacy/modules/<name>/                 modules that are not SuiteCRM's own
#                    public/legacy/Api/V8/OAuth2/private.key, public.key   the keys API tokens are signed with
#                    media/, public/media/ (8.9: uploads/, public/media-upload/)   files of file and image fields
#                    extensions/, public/extensions/               SuiteCRM 8 extensions
#                    .suitecrm_initialized, .suitecrm_url          the image's markers, when they are there
#   manifest.txt   when it was made, the SuiteCRM version, the address, the number of tables and files, sizes
#   SHA256SUMS     checksums of the two files
#   COMPLETE       written last. A folder without it is not a backup, and restore.sh refuses it.
# SuiteCRM's own code (vendor/, core/, public/dist/ and the rest) is not in it: it comes from the image. So
# a backup restores onto the same SuiteCRM version only. config_si.php, the installer's file of clear-text
# passwords, is never in it.
#
# The folder is on the same volume as SuiteCRM. It protects against a bad change, an import or a package that
# went wrong. It does not survive losing the volume: copy it off the deployment for that
# (playbooks/back-up.md). Nothing removes old backups by itself: each backup ends with how many the skill keeps
# and how large they are together, and --remove deletes one by name.
#
# What root trusts. SuiteCRM's tree is www-data's, tmp/ included, so the web user could move the backups
# folder aside and plant its own. Before anything in the folder is read or written it is checked: it has to be
# a real folder of root's that others can't write in (remote/guard.sh). One that is not is refused with exit 2
# and is never changed. A backup closes a folder that passed to mode 700, so that nobody but root reads the
# backups. Root reads SuiteCRM's settings through PHP that runs as www-data, and www-data's own tar reads the
# files: root includes no file of the web user's and follows no link of its.
#
# One backup or restore at a time. The script holds the skill's lock (/run/clouve/suitecrm-skill/lock) while it
# works. A second backup, restore or --remove that finds the lock held ends with exit 2 at once and changes
# nothing. The lock goes when the process ends, however it ends.
#
# Order: the backup is written as <name>.partial, checked (the dump's and gzip's exit codes, gzip -t, the dump's
# closing line, the archive's listing), renamed, and only then stamped COMPLETE. If anything fails, or the
# script is stopped, the partial folder is removed. A run that is killed outright can leave its <name>.partial
# behind: --list shows it, --remove takes its name, and the next backup removes one that is older than a day.
# The script stops before it writes anything when the volume has less free space than 1.2 times its estimate.
#
# The database password is read from SuiteCRM's own config.php, by PHP that runs as www-data, and given to the
# client in an options file of mode 600 in a folder of this run's own under /run/clouve/suitecrm-skill (root's,
# not on the volume), removed at the end. It is never in a command line or in the output.
#
# --list              the backups: name, complete or not, version, size, and the leftovers with the way to
#                     remove them
# --remove NAME       deletes one backup, or one <name>.partial leftover (a restore that was cut off blocks it:
#                     finishing may need it)
#
# Exit codes: 0 done; 64 usage, or --remove without --yes-remove; 1 SuiteCRM's settings or its database can't
# be read, or the database lacks SuiteCRM's tables; 2 not enough free space, another backup or restore is
# running, or the backups folder is not trusted; 3 the dump or the archive failed (nothing is kept); 4 no such
# backup.

set -uo pipefail
set +x
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${here}/remote/guard.sh" || exit 1

msg() { printf '[suitecrm/backup] %s\n' "$*" >&2; }

usage() {
    cat <<'USAGE'
Usage (inside the SuiteCRM container, as root; from the agent: run-in-suitecrm.sh [--detach] backup.sh ...):
  backup.sh                              take a backup
  backup.sh --list                       list the backups, and what a stopped backup left behind
  backup.sh --remove <name> --yes-remove delete one backup, or one <name>.partial leftover

A backup is the database dump and the customer's files (settings, custom/, upload/, the pictures of email
templates, added modules, media, extensions, the OAuth2 keys) in
/var/www/html/tmp/clouve-skill-backups/<UTC time>/. It restores onto the same
SuiteCRM version. One backup or restore runs at a time. Nothing removes old backups by itself.

Exit codes: 0 done; 64 usage or no yes; 1 settings or database unreadable; 2 not enough space, another backup
or restore is running, or the backups folder is not trusted; 3 the dump or archive failed; 4 no such backup.
USAGE
}

if [ "$(id -u)" -ne 0 ]; then
    msg "this runs as root inside the SuiteCRM container; send it with run-in-suitecrm.sh backup.sh"
    exit 64
fi

# enter_backups: changes into the backups folder once it is known to be root's. Status 1: there is none.
# A folder that is not trusted ends the script with exit 2. From here on every path is relative to ".".
enter_backups() {
    case "$(sc_dir_state "${sc_skill_dir}")" in
        absent) return 1 ;;
        untrusted)
            msg "refused: $(sc_untrusted_message "${sc_skill_dir}")"
            exit 2
            ;;
    esac
    if ! sc_enter_trusted "${sc_skill_dir}"; then
        msg "refused: $(sc_untrusted_message "${sc_skill_dir}")"
        exit 2
    fi
    return 0
}

# take_lock WHAT: the skill's lock, or exit 2
take_lock() {
    sc_lock_take "$1"
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
}

# backup_totals: prints how many complete backups the folder holds and the size of everything in it
backup_totals() {
    local n size
    n="$(find . -mindepth 2 -maxdepth 2 -name COMPLETE -type f 2> /dev/null | wc -l)"
    size="$(du -sh . 2> /dev/null | cut -f1)"
    if [ "${n}" = 1 ]; then printf '1 backup, %s in all' "${size:-?}"; else printf '%s backups, %s in all' "${n}" "${size:-?}"; fi
}

list_backups() {
    local d name state version size any=0 leftovers=()
    for d in ./[0-9]*/; do
        [ -d "${d}" ] && [ ! -L "${d%/}" ] || continue
        any=1
        name="${d#./}"
        name="${name%/}"
        size="$(du -sh "${d}" 2> /dev/null | cut -f1)"
        if [[ ${name} == *.partial ]] || [ ! -f "${d}COMPLETE" ]; then
            printf '%s  NOT complete  left by a backup that was stopped  %s\n' "${name}" "${size:-?}"
            leftovers+=("${name}")
            continue
        fi
        state=complete
        version="$(sed -n 's/^suitecrm_version: //p' "${d}manifest.txt" 2> /dev/null | head -n 1)"
        printf '%s  %s  SuiteCRM %s  %s\n' "${name}" "${state}" "${version:-?}" "${size:-?}"
    done
    if [ "${any}" -eq 0 ]; then
        echo "There are no backups in ${sc_skill_dir}."
        return 0
    fi
    echo "The skill keeps $(backup_totals), on the same volume as SuiteCRM."
    for name in ${leftovers[@]+"${leftovers[@]}"}; do
        echo "${name} is not a backup and can't be restored. Remove it with: run-in-suitecrm.sh backup.sh --remove ${name} --yes-remove"
    done
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    --list)
        if enter_backups; then list_backups; else echo "There are no backups in ${sc_skill_dir}."; fi
        exit 0
        ;;
    --remove)
        name="${2:-}"
        [[ ${name} =~ ^[0-9]{8}-[0-9]{6}(\.partial)?$ ]] || { msg "--remove takes a backup's name, such as 20261112-101500, or a leftover's, such as 20261112-101500.partial"; exit 64; }
        enter_backups || { msg "there is no backup named ${name}"; exit 4; }
        if [ ! -d "./${name}" ] || [ -L "./${name}" ]; then
            msg "there is no backup named ${name}"
            exit 4
        fi
        if [ "${3:-}" != --yes-remove ]; then
            if [[ ${name} == *.partial ]]; then
                msg "nothing was removed. This deletes ${name}, what a backup that was stopped left behind. Run it again with --yes-remove."
            else
                msg "nothing was removed. This deletes the backup ${name} for good. Run it again with --yes-remove after the user picked this backup by name and said yes."
            fi
            exit 64
        fi
        take_lock "removing the backup ${name}"
        rm -rf -- "./${name}"
        if [ -e "./${name}" ]; then
            msg "could not remove ${name}"
            exit 1
        fi
        if [[ ${name} == *.partial ]]; then echo "Removed the leftover ${name}."; else echo "Removed the backup ${name}."; fi
        echo "The skill now keeps $(backup_totals)."
        exit 0
        ;;
    '') ;;
    *) msg "unknown argument: $(printf '%q' "$1")"; usage >&2; exit 64 ;;
esac

# The backups folder: made when it is not there, never taken over when something else is
if ! enter_backups; then
    if ! sc_make_root_dir "${sc_skill_dir}" || ! enter_backups; then
        msg "could not make ${sc_skill_dir} as a folder of root's. Nothing was written."
        exit 1
    fi
fi
take_lock "a backup"
# The folder is root's and only root can write in it. It is closed to everyone else too: the leading zeros
# also clear the set-group-ID bit a folder takes from tmp/.
chmod 00700 . || { msg "could not close ${sc_skill_dir} to others. Nothing was written."; exit 1; }

partial=''
cleanup() {
    if [ -n "${partial}" ]; then rm -rf -- "./${partial}"; fi
    if [ -n "${sc_run_tmp}" ]; then rm -rf -- "${sc_run_tmp}"; fi
}
trap cleanup EXIT
trap 'exit 3' HUP INT TERM PIPE
sc_run_tmp_make || { msg "could not make a work folder in ${sc_run_dir}. Nothing was written."; exit 1; }

# What a killed backup left more than a day ago goes. A younger one stays for a look: --list shows it.
while IFS= read -r old; do
    old="${old#./}"
    [[ ${old} =~ ^[0-9]{8}-[0-9]{6}\.partial$ ]] || continue
    rm -rf -- "./${old}"
    echo "Removed ${old}: a backup that was stopped more than a day ago left it behind."
done < <(find . -mindepth 1 -maxdepth 1 -type d -name '*.partial' -mmin +1440 2> /dev/null)

if ! sc_as_www test -f "${sc_root}/public/legacy/config.php"; then
    msg "SuiteCRM's config.php is not there"
    exit 1
fi

# The database settings SuiteCRM itself uses, one per line. PHP reads config.php as www-data, never as root:
# the file is the web user's. The password is read into a variable here and written to the options file below;
# it is in no argument list.
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
    msg "could not read the database settings from SuiteCRM's config.php"
    exit 1
fi

stamp="$(date -u +%Y%m%d-%H%M%S)"
[[ ${stamp} =~ ^[0-9]{8}-[0-9]{6}$ ]] || { msg "date gave no time stamp"; exit 1; }
if [ -e "./${stamp}" ] || [ -e "./${stamp}.partial" ]; then
    msg "a backup named ${stamp} is there already; run this again in a second"
    exit 1
fi
final="${sc_skill_dir}/${stamp}"

cnf="${sc_run_tmp}/client.cnf"
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
if ! tables="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")" || [ -z "${tables}" ]; then
    msg "could not reach SuiteCRM's database with the settings in config.php"
    exit 1
fi
core="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name IN ('users', 'config', 'accounts')")"
if [ "${core}" != 3 ]; then
    msg "the database ${db_name} does not hold SuiteCRM's tables (users, config and accounts are not all there), so a backup of it would be worth nothing. Nothing was written. If a restore was cut off, run it again (playbooks/restore-from-backup.md)."
    exit 1
fi
db_bytes="$(sql "SELECT IFNULL(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()")"
db_version="$(sql "SELECT value FROM config WHERE category = 'info' AND name = 'suitecrm_version'")"
# VERSION is the web user's file too: it is read as www-data and has to look like a version.
code_version="$(sc_as_www head -c 40 "${sc_root}/VERSION" 2> /dev/null | tr -d '[:space:]')"
[[ ${code_version} =~ ^[0-9]{1,5}(\.[0-9]{1,5}){1,3}$ ]] || code_version=''

# The state paths that exist on this install
paths=()
for p in .env.local .suitecrm_initialized .suitecrm_url extensions media public/media uploads public/media-upload \
    public/extensions public/legacy/upload public/legacy/custom public/legacy/cache/images public/legacy/config.php public/legacy/config_override.php \
    public/legacy/Api/V8/OAuth2/private.key public/legacy/Api/V8/OAuth2/public.key; do
    if [ -e "${sc_root}/${p}" ]; then paths+=("${p}"); fi
done
# Modules that are not SuiteCRM's own: those the image's pristine copy does not have
pristine=/clouve/suitecrm/app/public/legacy/modules
added_modules=0
if [ -d "${pristine}" ]; then
    for d in "${sc_root}"/public/legacy/modules/*/; do
        name="$(basename "${d}")"
        if [ ! -e "${pristine}/${name}" ]; then
            paths+=("public/legacy/modules/${name}")
            added_modules=$((added_modules + 1))
        fi
    done
else
    paths+=(public/legacy/modules)
    added_modules=all
fi

# shellcheck disable=SC2016  # $1 and $@ are for the inner bash
files_bytes="$(sc_as_www bash -c 'cd "$1" && shift && du -sbc -- "$@" 2> /dev/null | tail -n 1 | cut -f1' _ "${sc_root}" "${paths[@]}")"
[[ ${files_bytes} =~ ^[0-9]+$ ]] || files_bytes=0
[[ ${db_bytes} =~ ^[0-9]+$ ]] || db_bytes=0
need=$(((files_bytes + db_bytes / 2) * 12 / 10 + 52428800))
free="$(df -PB1 . | awk 'NR == 2 { print $4 }')"
if [ "${free:-0}" -lt "${need}" ]; then
    msg "not enough free space for a backup: about $((need / 1048576)) MB needed, $((${free:-0} / 1048576)) MB free on the volume. Nothing was written. The skill keeps $(backup_totals); old backups can be removed by name (backup.sh --list, then --remove), or the user moves to a larger plan."
    exit 2
fi

partial="${stamp}.partial"
mkdir -m 700 "./${partial}" && chown root:root "./${partial}" && chmod 00700 "./${partial}" || { msg "could not make ${final}.partial"; exit 1; }
echo "Backing up SuiteCRM ${code_version:-?} (${tables} tables, $((files_bytes / 1048576)) MB of files)..."

# The dump. Each part of the pipe is checked, then the file itself.
mysqldump --defaults-extra-file="${cnf}" --single-transaction --routines --triggers --no-tablespaces "${db_name}" 2> "${sc_run_tmp}/dump.err" | gzip > "./${partial}/db.sql.gz"
status=("${PIPESTATUS[@]}")
if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ] || ! gzip -t "./${partial}/db.sql.gz" 2> /dev/null \
    || ! zcat "./${partial}/db.sql.gz" | tail -n 5 | grep -q 'Dump completed'; then
    msg "the database dump failed or is not whole: $(head -n 3 "${sc_run_tmp}/dump.err" 2> /dev/null | tr '\n' ' ')"
    msg "Nothing was kept."
    exit 3
fi

# The files. www-data's own tar reads them and root writes what it sends into root's folder, so a link planted
# in the tree never makes root read a file that is not the web user's.
if ! sc_as_www tar -C "${sc_root}" --exclude=public/legacy/upload/import -czf - "${paths[@]}" > "./${partial}/state.tar.gz" 2> "${sc_run_tmp}/tar.err" \
    || ! gzip -t "./${partial}/state.tar.gz" 2> /dev/null || ! tar -tzf "./${partial}/state.tar.gz" > "${sc_run_tmp}/files.txt" 2> /dev/null \
    || ! grep -qx 'public/legacy/config.php' "${sc_run_tmp}/files.txt"; then
    msg "the archive of the files failed or is not whole: $(head -n 3 "${sc_run_tmp}/tar.err" 2> /dev/null | tr '\n' ' ')"
    msg "Nothing was kept."
    exit 3
fi
file_count="$(wc -l < "${sc_run_tmp}/files.txt")"

{
    printf 'backup: %s\n' "${stamp}"
    printf 'made_utc: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf 'suitecrm_version: %s\n' "${code_version}"
    printf 'installed_version_row: %s\n' "${db_version}"
    printf 'site_url: %s\n' "${site_url}"
    printf 'tables: %s\n' "${tables}"
    printf 'files_in_archive: %s\n' "${file_count}"
    printf 'added_modules: %s\n' "${added_modules}"
    printf 'db_dump_bytes: %s\n' "$(stat -c %s "./${partial}/db.sql.gz")"
    printf 'state_archive_bytes: %s\n' "$(stat -c %s "./${partial}/state.tar.gz")"
} > "./${partial}/manifest.txt"
(cd "./${partial}" && sha256sum db.sql.gz state.tar.gz > SHA256SUMS) || { msg "could not write the checksums. Nothing was kept."; exit 3; }
chmod 600 "./${partial}"/* || exit 3

mv -- "./${partial}" "./${stamp}" || { msg "could not move the backup into place. Nothing was kept."; exit 3; }
partial=''
: > "./${stamp}/COMPLETE"
chmod 600 "./${stamp}/COMPLETE"

echo "Backup ${stamp} is complete: database $(($(stat -c %s "./${stamp}/db.sql.gz") / 1024)) KB, files $(($(stat -c %s "./${stamp}/state.tar.gz") / 1024)) KB, in ${final}."
echo "It is on the same volume as SuiteCRM. $(($(df -PB1 . | awk 'NR == 2 { print $4 }') / 1048576)) MB are free."
echo "This skill now keeps $(backup_totals). Nothing removes old backups by itself: backup.sh --list shows them, and --remove deletes one by name."
exit 0
