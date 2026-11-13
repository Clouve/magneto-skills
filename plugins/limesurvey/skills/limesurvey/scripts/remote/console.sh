#!/usr/bin/env bash
# LimeSurvey skill: remote/console.sh
#
# Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh (console.sh is its front end on
# the agent, and says what each command does). It runs one LimeSurvey console command, and only one of these:
#   flushassets, setmaintenancemode <mode>, importsurvey <file>, checkintegrity with --yes (it changes data), and
#   updatedb with --failed-upgrade-playbook.
# console.sh on the agent checks the same list first. The list is here too, so that wipe, demomode, install and
# resetpassword cannot run through this file whatever calls it.
#
# importsurvey imports a copy of the file, in a folder of its own under /tmp that is removed afterwards:
# LimeSurvey's importer rewrites and deletes the file it is given.
#
# Exit codes: the console command's own; 64 a command or argument that is not allowed; 1 LimeSurvey is not where
# it should be, or the file cannot be copied.

set -uo pipefail

say() { printf '[limesurvey/console] %s\n' "$*" >&2; }

ls_root="${LS_ROOT:-/var/www/html}"
console="${ls_root}/application/commands/console.php"

playbook=0
confirmed=0
if [ "${1:-}" = --failed-upgrade-playbook ]; then
    playbook=1
    shift
elif [ "${1:-}" = --yes ]; then
    confirmed=1
    shift
fi
command="${1:-}"
[ "$#" -gt 0 ] && shift

case "${command}" in
    flushassets)
        [ "$#" -eq 0 ] || { say "refused: ${command} takes no arguments"; exit 64; }
        ;;
    checkintegrity)
        [ "$#" -eq 0 ] || { say "refused: ${command} takes no arguments"; exit 64; }
        if [ "${confirmed}" -ne 1 ]; then
            say "refused: checkintegrity changes data (it applies its fixes without asking), so it runs only with --yes, after a backup and the admin's yes"
            exit 64
        fi
        ;;
    setmaintenancemode)
        case "${1:-}" in off | soft | hard | hard-cli) ;; *) say "refused: setmaintenancemode takes off, soft, hard or hard-cli"; exit 64 ;; esac
        [ "$#" -eq 1 ] || { say "refused: setmaintenancemode takes one mode"; exit 64; }
        ;;
    importsurvey)
        [ "$#" -eq 1 ] || { say "refused: importsurvey takes one file"; exit 64; }
        ;;
    updatedb)
        if [ "${playbook}" -ne 1 ] || [ "$#" -ne 0 ]; then
            say "refused: updatedb runs only as a step of playbooks/recover-from-a-failed-upgrade.md"
            exit 64
        fi
        ;;
    *)
        say "refused: this skill does not run the console command $(printf '%q' "${command}")"
        exit 64
        ;;
esac

if [ ! -f "${console}" ] || [ ! -f "${ls_root}/application/config/config.php" ]; then
    say "LimeSurvey is not installed in ${ls_root}"
    exit 1
fi
if [ ! -f "${ls_root}/application/config/security.php" ]; then
    say "application/config/security.php is missing. LimeSurvey would make new encryption keys if it started now, and the encrypted answers and the SMTP password could then not be read. Put the file back from a backup first (playbooks/restore-from-backup.md)."
    exit 1
fi
cd "${ls_root}" || exit 1

if [ "${command}" = importsurvey ]; then
    spec="$1"
    file="${spec}"
    language=''
    # <file>:<language> names the survey's base language, as the console command takes it.
    case "${spec}" in
        *.lss:* | *.txt:* | *.tsv:*) file="${spec%:*}"; language=":${spec##*:}" ;;
    esac
    case "${file,,}" in
        /*.lss | /*.txt | /*.tsv) ;;
        *) say "refused: importsurvey takes the full path of an .lss, .txt or .tsv file. An .lsa archive activates the survey: survey-archive.sh imports those"; exit 64 ;;
    esac
    if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
        say "${file} is not a file that www-data can read"
        exit 1
    fi
    copy_dir="$(mktemp -d /tmp/clouve-ls-import.XXXXXXXX)" || { say "could not make a folder for the copy"; exit 1; }
    trap 'rm -rf -- "${copy_dir}"' EXIT
    copy="${copy_dir}/import.${file##*.}"
    if ! cp -- "${file}" "${copy}"; then
        say "could not copy ${file}"
        exit 1
    fi
    php "${console}" importsurvey "${copy}${language}"
    exit $?
fi

exec php "${console}" "${command}" "$@"
