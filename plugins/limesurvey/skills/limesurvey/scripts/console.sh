#!/usr/bin/env bash
# LimeSurvey skill: console.sh
#
# Runs one of LimeSurvey's own console commands (application/commands/console.php) in the LimeSurvey container, as
# www-data, over the clouve-ops SSH channel. Only the commands on the list below run. The command's output and
# exit code pass through. LimeSurvey's console prints the full error and its stack trace when something fails,
# which makes it the place to see an error that the web pages hide.
#
# Usage: console.sh flushassets
#        console.sh checkintegrity --yes
#        console.sh setmaintenancemode <off|soft|hard|hard-cli>
#        console.sh importsurvey <file in the container>
#        console.sh --failed-upgrade-playbook updatedb
#
#   flushassets          empties LimeSurvey's asset and page caches (tmp/assets, tmp/runtime/cache). Safe at any
#                        time; the next pages are slower while the caches fill again.
#   checkintegrity       runs LimeSurvey's "Check data integrity" tool, which applies its fixes without asking:
#                        it is not a check that only looks. On a healthy site it has been seen to renumber the
#                        order of questions. It never deletes a table that still holds answers; it lists those.
#                        Exit 0 clean, 1 a fix could not be applied, 2 it did not settle. It changes data, so it
#                        runs only with --yes, which the playbook gives after a backup and the admin's yes.
#   setmaintenancemode   off, soft (people who started can finish, nobody new starts), hard (no participant gets
#                        in) or hard-cli (hard, and the admin pages, RemoteControl and the REST API are locked too;
#                        only this command lifts it). Everyone sees a maintenance page, so announce it first.
#   importsurvey         imports an .lss or tab-separated .txt file that is already in the container, as an
#                        inactive survey, and prints the new survey's id. LimeSurvey's importer deletes the file it
#                        reads, so this imports a copy and the file stays. survey-import.sh is the usual way: it
#                        takes a file from the agent, checks it and proves the result. An .lsa archive is refused
#                        here, because importing one activates the survey: survey-archive.sh does that, after a yes.
#   updatedb             LimeSurvey's database update. The Clouve image runs it during an upgrade, before the web
#                        server starts. It runs here only with --failed-upgrade-playbook, which the playbook
#                        playbooks/recover-from-a-failed-upgrade.md gives at the step that needs it.
#
# Refused, whatever the arguments: wipe and demomode (they empty the site: any first argument starts them, also
# "no"), install and installfromconfig (the image installs the site), resetpassword (it takes the password as an
# argument, where the process list shows it; admin-users.sh sets a password from stdin), and every command that is
# not on the list above.
#
# Env vars read: LIMESURVEY_HOST (run-in-limesurvey.sh uses it and loads the clouve-ops password).
#
# Exit codes:
#   the command's own  whatever console.php ended with
#   64   usage, or a command that is refused
#   1, 70, 75, 255     run-in-limesurvey.sh's: a missing setting, a failed start in the container, LimeSurvey is
#                      being installed, upgraded or restored, ssh failed

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: console.sh flushassets
       console.sh checkintegrity --yes
       console.sh setmaintenancemode <off|soft|hard|hard-cli>
       console.sh importsurvey <file in the container>
       console.sh --failed-upgrade-playbook updatedb

Runs one of LimeSurvey's console commands in the LimeSurvey container, as www-data. Only these five run, and
updatedb only in the hands of playbooks/recover-from-a-failed-upgrade.md. checkintegrity changes data (it applies
its fixes without asking), so it needs --yes, after a backup and the admin's yes. wipe, demomode, install,
installfromconfig and resetpassword are refused whatever the arguments, and so is any other command.

Exit codes: the command's own; 64 usage or a refused command; 75 LimeSurvey is being installed, upgraded or
restored; 255 ssh failed.
USAGE
}

msg() { printf '[limesurvey/console] %s\n' "$*" >&2; }
refuse() {
    msg "refused: $1"
    exit 64
}

playbook=0
confirmed=0
# --yes may come before or after the command.
args=()
for arg in "$@"; do
    if [ "${arg}" = --yes ]; then confirmed=1; else args+=("${arg}"); fi
done
set -- ${args[@]+"${args[@]}"}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --failed-upgrade-playbook) playbook=1; shift ;;
        --) shift; break ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *) break ;;
    esac
done
if [ "$#" -eq 0 ]; then
    msg "no console command given"
    usage >&2
    exit 64
fi
command="$1"
shift

case "${command,,}" in
    wipe | demomode)
        refuse "${command,,} empties the whole site (surveys, answers, accounts), and any first argument starts it, also \"no\". This skill never runs it."
        ;;
    install | installfromconfig)
        refuse "${command,,} sets up a new site. The Clouve image installs LimeSurvey at its first start, and nothing here does it again."
        ;;
    resetpassword)
        refuse "resetpassword takes the new password as an argument, where the container's process list shows it. Use admin-users.sh set-password, which reads the password from stdin, or temp-password.sh."
        ;;
    flushassets)
        [ "$#" -eq 0 ] || refuse "${command} takes no arguments."
        ;;
    checkintegrity)
        [ "$#" -eq 0 ] || refuse "${command} takes no arguments but --yes."
        if [ "${confirmed}" -ne 1 ]; then
            refuse "checkintegrity changes data: it applies its fixes without asking, and it can renumber the order of questions on a healthy site. Back up first, tell the admin, and after a clear yes run it again with --yes."
        fi
        ;;
    setmaintenancemode)
        [ "$#" -eq 1 ] || refuse "setmaintenancemode takes one mode: off, soft, hard or hard-cli."
        case "$1" in
            off | soft | hard | hard-cli) ;;
            *) refuse "setmaintenancemode takes off, soft, hard or hard-cli, not $(printf '%q' "$1")." ;;
        esac
        ;;
    importsurvey)
        [ "$#" -eq 1 ] || refuse "importsurvey takes one file in the container."
        case "${1,,}" in
            *.lsa | *.lsa:*)
                refuse "importing an .lsa archive activates the survey and loads its answers and participants. survey-archive.sh import does that, after the admin's yes."
                ;;
            /*.lss | /*.txt | /*.tsv | /*.lss:* | /*.txt:* | /*.tsv:*) ;;
            *) refuse "importsurvey takes the full path of an .lss, .txt or .tsv file in the container." ;;
        esac
        ;;
    updatedb)
        [ "$#" -eq 0 ] || refuse "updatedb takes no arguments here."
        if [ "${playbook}" -ne 1 ]; then
            refuse "updatedb is the image's job: it runs during an upgrade, before the web server starts. It runs here only as a step of playbooks/recover-from-a-failed-upgrade.md, which gives the option for it."
        fi
        ;;
    *)
        refuse "$(printf '%q' "${command}") is not one of the console commands this skill runs (flushassets, checkintegrity, setmaintenancemode, importsurvey, and updatedb in the failed-upgrade playbook)."
        ;;
esac
if [ "${playbook}" -eq 1 ] && [ "${command,,}" != updatedb ]; then
    refuse "--failed-upgrade-playbook goes with updatedb only."
fi
if [ "${confirmed}" -eq 1 ] && [ "${command,,}" != checkintegrity ]; then
    refuse "--yes goes with checkintegrity only."
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${playbook}" -eq 1 ]; then
    exec "${script_dir}/run-in-limesurvey.sh" console.sh --failed-upgrade-playbook "${command,,}" "$@"
fi
if [ "${command,,}" = checkintegrity ]; then
    exec "${script_dir}/run-in-limesurvey.sh" console.sh --yes checkintegrity
fi
exec "${script_dir}/run-in-limesurvey.sh" console.sh "${command,,}" "$@"
