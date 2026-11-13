#!/usr/bin/env bash
# SuiteCRM skill: run-in-suitecrm.sh
#
# Sends this skill's scripts into the SuiteCRM container and runs one of them there, over the clouve-ops SSH
# channel. It is the only script of the skill that calls ssh. The others (records.sh, users.sh, import-csv.sh
# and the rest) check their arguments on the agent and then call this one.
#
# Usage: run-in-suitecrm.sh [--detach] <backup.sh|restore.sh> [args...]
#        run-in-suitecrm.sh --status <job>
#        run-in-suitecrm.sh --check
#   and, for the skill's own scripts:
#        run-in-suitecrm.sh [--stdin] [--need-backup] [--allow-busy] php <name>.php [args...]
#        run-in-suitecrm.sh console <command> [args...]
#        run-in-suitecrm.sh [--allow-busy] admin <subcommand> [args...]
#
#   These three are the direct forms. The skill's own checks are in the scripts that call them (the yes flags,
#   the plan an import shows first, the backup rule), so they don't apply to a direct form run by hand. A
#   direct form prints one line on stderr that says so and names the script to use, unless SC_SKILL_CALLER is
#   set: each script of the skill exports it with its own name before it calls this one.
#
#   backup.sh, restore.sh  run inside the container as root. A plain run streams the output and ends with
#                          the script's exit code, and lasts as long as this command. --detach starts a job
#                          that goes on after this command and the SSH session end: use it for every restore
#                          and for a backup of a large install. --status <job> shows the end of the job's log
#                          and whether it is running or how it ended.
#   --check                runs nothing: exit 0 when SuiteCRM can be worked on, 75 when the image is installing
#                          or upgrading it, a restore is under way or was cut off, or the container is still
#                          starting or waiting (PID 1 is not Apache). stderr says which.
#   php <name>.php         runs remote/<name>.php as www-data, the web server's user, so that every file
#                          SuiteCRM writes stays writable by the web server. --stdin passes this command's stdin
#                          on to it (a JSON document, a CSV file, a zip, or a password on one line); without it
#                          the script gets no stdin.
#   console <command>      runs SuiteCRM's bin/console as www-data, for the commands lib/suitecrm-console.sh allows.
#   admin <subcommand>     runs remote/admin.sh as root: the upgrade's state, the held scheduler, the kept backup.
#   --need-backup          refuse (exit 76) unless this skill made a complete backup in the last 24 hours, in
#                          a backups folder that is root's.
#   --allow-busy           run even while the image installs or upgrades, or waits (reads of the state only).
#
# In a container that waits (a restore was cut off, or the image found a site it must not start), restore.sh,
# backup.sh --list and the forms with --allow-busy still run, so that the state can be read and a restore
# finished. Everything that changes CRM data, and a new backup, is refused there (remote/entry.sh).
#
# How it travels. The scripts folder's remote/ files, backup.sh and restore.sh go as one small tar.gz, base64
# text at the front of the channel's stdin; the container side reads exactly that many bytes, unpacks them to a
# temp folder, and starts remote/entry.sh, which checks the image's state, picks the user and removes the folder
# when the run ends. What follows on stdin (with --stdin) is the script's own input. So a password or a
# customer's file is never in a command line on either side, and never in a file the skill leaves behind.
# Arguments are quoted with printf %q, which the container's bash decodes.
#
# ssh gets the options in lib/suitecrm-ssh.sh. SSHPASS is set on the sshpass command only, never exported.
#
# Env vars read:
#   SUITECRM_HOST     pod-internal hostname of the SuiteCRM container
#   SC_SKILL_CALLER   the name of the skill's script that calls a direct form; set, it keeps the direct form's
#                     line about the skill's checks from being printed
#   the ops password  for sshpass -e. A current agent keeps it out of the environment; the loader line below
#                     fetches it then.
#
# Exit codes:
#   the script's own   records.sh, backup.sh and the others list theirs
#   64   usage
#   1    SUITECRM_HOST or the ops password is not set, or a file of the skill is missing
#   70   the container could not unpack or start the script, or the script crashed (a PHP fatal error)
#   75   refused: SuiteCRM is being installed or upgraded by the image, a restore is under way or was cut
#        off, or the container is still starting or waiting
#   76   refused: --need-backup and no complete backup from the last 24 hours, or the backups folder is not
#        trusted
#   255  ssh could not reach or log in to clouve-ops@<host>, or the session dropped; stderr says so
#   --detach   0 the job started; 1 it was not started, or did not start; 2 started, state unreadable
#   --status   0 finished with exit 0; 1 finished otherwise, stopped, or never started; 2 unreadable;
#              3 still running; 64 no such job
# No script of this skill ends with 5, 6, 7 or 255, so those always mean that sshpass or ssh failed.

# No -e: ssh's exit status is the result, and it is read below.
set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the ops password.
set +x

usage() {
    cat <<'USAGE'
Usage: run-in-suitecrm.sh [--detach] <backup.sh|restore.sh> [args...]
       run-in-suitecrm.sh --status <job>
       run-in-suitecrm.sh --check

Runs backup.sh or restore.sh inside the SuiteCRM container, as root, over the clouve-ops SSH channel. A plain
run streams the script's output and ends with its exit code. --detach starts it as a job that keeps running
after this command ends (use it for every restore, and for a backup of a large install), and prints the job's
name. --status <job> shows the end of the job's log and whether it is running, or how it ended. --check exits 0
when SuiteCRM can be worked on and 75 when it can't, and says why: the image installs or upgrades it, a restore
is under way or was cut off, or the container is still starting or waiting.

The skill's other scripts call it as `php <name>.php`, `console <command>` and `admin <subcommand>`. Use those
scripts, not these direct forms: the skill's own checks (the yes flags, the plan, the backup rule) don't apply
to a direct form, and each one says so in one line on stderr and names the script to use.

Exit codes: the script's own; 64 usage; 1 a missing setting, password or file; 70 the script could not start
or crashed; 75 SuiteCRM is being installed or upgraded, a restore is under way or was cut off, or the container
is still starting or waiting; 76 no backup from the last 24 hours; 255 ssh failed.
--detach: 0 started, 1 not started, 2 state unreadable. --status: 0 finished with 0, 1 finished otherwise or
never started, 2 unreadable, 3 running, 64 no such job.

Needs SUITECRM_HOST and the clouve-ops password the agent holds.
USAGE
}

msg() { printf '[suitecrm/run-in-suitecrm] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

# direct_note FORM SCRIPTS: the one line a direct form prints when no script of the skill called it
direct_note() {
    if [ -n "${SC_SKILL_CALLER:-}" ]; then return 0; fi
    msg "note: this is the runner's direct form ($1), so the skill's own checks (the yes flags, the plan, the backup rule) don't apply to it. Use $2 instead."
}
# script_for_php NAME.php: the script of the skill that calls it
script_for_php() {
    case "$1" in
        records.php) echo 'records.sh' ;;
        users.php) echo 'users.sh, temp-password.sh or restore-admin-password.sh' ;;
        import.php) echo 'import-csv.sh' ;;
        packages.php) echo 'packages.sh' ;;
        repair.php) echo 'repair.sh' ;;
        scheduler.php) echo 'scheduler.sh' ;;
        email.php) echo 'email.sh' ;;
        sqlread.php) echo 'sql-read.sh' ;;
        *) echo "the skill's script for it (SKILL.md lists them)" ;;
    esac
}
# script_for_admin SUBCOMMAND
script_for_admin() {
    case "$1" in
        scheduler-held | release-scheduler) echo 'scheduler.sh' ;;
        *) echo 'upgrade-state.sh or verify-health.sh' ;;
    esac
}

jobs_dir=/run/clouve/jobs
mode=''
name=''
job=''
detach=0
pass_stdin=0
flags=''
add_flag() { flags="${flags:+${flags},}$1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --detach) detach=1; shift ;;
        --stdin) pass_stdin=1; shift ;;
        --need-backup) add_flag need-backup; shift ;;
        --allow-busy) add_flag allow-busy; shift ;;
        --check) mode=check; shift; [ "$#" -eq 0 ] || usage_error "--check takes nothing else"; break ;;
        --status)
            [ "$#" -eq 2 ] || usage_error "--status takes one job name"
            mode=status
            job="$2"
            # The name goes into a remote command, so it is checked letter by letter (no locale ranges).
            if ! [[ ${job} =~ ^(backup|restore)-[0123456789]{8}-[0123456789]{6}$ ]]; then
                usage_error "not a job's name: $(printf '%q' "${job}") (a job is backup-YYYYmmdd-HHMMSS or restore-YYYYmmdd-HHMMSS)"
            fi
            shift 2
            break
            ;;
        backup.sh | restore.sh) mode=root; name="$1"; shift; break ;;
        php)
            [ "$#" -ge 2 ] || usage_error "php needs a script name"
            mode=php
            name="$2"
            shift 2
            case "${name}" in
                *[!abcdefghijklmnopqrstuvwxyz.-]* | '' | .* | *..*) usage_error "not a script of this skill: $(printf '%q' "${name}")" ;;
                *.php) ;;
                *) usage_error "not a script of this skill: $(printf '%q' "${name}")" ;;
            esac
            direct_note "php ${name}" "$(script_for_php "${name}")"
            break
            ;;
        console)
            [ "$#" -ge 2 ] || usage_error "console needs a command"
            mode=console
            name="$2"
            shift 2
            direct_note console 'console.sh'
            break
            ;;
        admin)
            [ "$#" -ge 2 ] || usage_error "admin needs a subcommand"
            mode=root
            name=remote/admin.sh
            shift
            direct_note admin "$(script_for_admin "$1")"
            break
            ;;
        *) usage_error "only backup.sh and restore.sh run in the container this way, not $(printf '%q' "$1")" ;;
    esac
done
[ -n "${mode}" ] || usage_error "nothing to run"
if [ "${detach}" -eq 1 ] && { [ "${mode}" != root ] || [ "${name}" = remote/admin.sh ]; }; then
    usage_error "--detach is for backup.sh and restore.sh"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in lib/suitecrm-ssh.sh lib/suitecrm-console.sh remote/entry.sh remote/guard.sh backup.sh restore.sh; do
    if [ ! -f "${script_dir}/${f}" ]; then
        msg "${f} is not next to run-in-suitecrm.sh in ${script_dir}"
        exit 1
    fi
done
if [ "${mode}" = php ] && [ ! -f "${script_dir}/remote/${name}" ]; then
    usage_error "there is no remote/${name} in this skill"
fi
if [ "${mode}" = console ]; then
    # shellcheck source=/dev/null
    . "${script_dir}/lib/suitecrm-console.sh" || exit 1
    refusal="$(sc_console_refusal "${name}" "$@")"
    if [ -n "${refusal}" ]; then
        msg "refused: ${refusal}"
        exit 64
    fi
fi

if [ -z "${SUITECRM_HOST:-}" ]; then
    msg "SUITECRM_HOST is not set"
    exit 1
fi
# shellcheck source=/dev/null
. "${script_dir}/lib/suitecrm-ssh.sh" || exit 1
mapfile -t ssh_opts < <(sc_ssh_options)
if [ "${#ssh_opts[@]}" -eq 0 ]; then
    msg "lib/suitecrm-ssh.sh gave no ssh options"
    exit 1
fi

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
if [ -z "${CLOUVE_OPS_PASSWORD}" ]; then
    msg "CLOUVE_OPS_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
    exit 1
fi
target="clouve-ops@${SUITECRM_HOST}"

# The arguments, each quoted with %q for the container's bash
quoted=''
for arg in "$@"; do
    printf -v q ' %q' "${arg}"
    quoted+=${q}
done
printf -v quoted_name '%q' "${name:--}"

# unreachable RC: ssh's 255, or sshpass's 5 (wrong password), 6 or 7 (host key). No script of the skill ends with them.
unreachable() {
    case $1 in 5 | 6 | 7 | 255) return 0 ;; esac
    return 1
}

# The scripts, as base64 text. tar's own options keep the archive the same from run to run.
bundle="$(tar -C "${script_dir}" --owner=0 --group=0 --mode=u+rwX,go+rX -czf - remote backup.sh restore.sh 2> /dev/null | base64 -w 0)"
if [ -z "${bundle}" ]; then
    msg "could not pack the scripts in ${script_dir}"
    exit 1
fi
bundle_bytes=${#bundle}

# The state of a job, read in the container: sent on stdin to `sudo -n bash -s -- DIR JOB [WAIT]`.
IFS= read -r -d '' status_script <<'EOS' || :
# job_rc FILE: the job's exit code, when FILE.rc holds one (an empty FILE.rc is one being written)
job_rc() {
    local text=''
    IFS= read -r text 2> /dev/null < "$1.rc" || :
    case ${text} in '' | *[!0123456789]*) return 1 ;; esac
    printf '%s' "${text}"
}
# job_alive FILE: a process has FILE, or a path under FILE.d, as one of its arguments
job_alive() {
    local cmdline arg
    for cmdline in /proc/[0123456789]*/cmdline; do
        while IFS= read -r -d '' arg; do
            case "${arg}" in "$1" | "$1.d" | "$1.d/"*) return 0 ;; esac
        done 2> /dev/null < "${cmdline}"
    done
    return 1
}
job_state() {
    local rc
    if rc=$(job_rc "$1"); then echo "finished, exit ${rc}"; return 0; fi
    if job_alive "$1"; then echo running; return 0; fi
    if rc=$(job_rc "$1"); then echo "finished, exit ${rc}"; return 0; fi
    if [ -e "$1.log" ]; then echo 'stopped without an exit code'; else echo 'not started'; fi
}
status_main() {
    local f="$1/$2" wait=${3:-} state tries=0
    if [ ! -d "${f}.d" ]; then
        echo 'status: unknown job'
        return 0
    fi
    state=$(job_state "${f}")
    if [ -n "${wait}" ]; then
        while [ "${state}" = 'not started' ] && [ "${tries}" -lt $((wait * 5)) ]; do
            sleep 0.2
            tries=$((tries + 1))
            state=$(job_state "${f}")
        done
    else
        tail -n 40 -- "${f}.log" 2> /dev/null
        if [ -s "${f}.log" ] && [ -n "$(tail -c 1 -- "${f}.log" 2> /dev/null)" ]; then echo; fi
    fi
    echo "status: ${state}"
}
status_main "$@" < /dev/null
EOS

# remote_status [WAIT]: runs the script above for the job; out = what it printed, last = its last line, rc = ssh's
remote_status() {
    out=$(SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "sudo -n bash -s -- ${jobs_dir} ${job}${1:+ $1}" <<< "${status_script}")
    rc=$?
    last=${out##*$'\n'}
}

if [ "${mode}" = status ]; then
    remote_status
    if unreachable "${rc}"; then
        msg "ssh to ${target} failed (exit ${rc})"
        exit 255
    fi
    if [ "${last}" != "${out}" ]; then printf '%s\n' "${out%$'\n'*}"; fi
    printf '%s\n' "${last}"
    case ${last} in
        'status: running') exit 3 ;;
        'status: finished, exit 0') exit 0 ;;
        'status: finished, exit '* | 'status: stopped without an exit code' | 'status: not started') exit 1 ;;
        'status: unknown job')
            msg "there is no job ${job} in ${jobs_dir} (a container that restarts starts with none)"
            exit 64
            ;;
    esac
    msg "could not read the job's status (exit ${rc}): sudo or the container's shell failed"
    exit 2
fi

if [ "${detach}" -eq 1 ]; then
    stamp=$(date -u +%Y%m%d-%H%M%S)
    if ! [[ ${stamp} =~ ^[0123456789]{8}-[0123456789]{6}$ ]]; then
        msg "date gave no time stamp, so the job was not started"
        exit 1
    fi
    job=${name%.sh}-${stamp}
    file=${jobs_dir}/${job}
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" \
        "set -o pipefail; sudo -n install -d -m 700 ${jobs_dir} || exit 1; if sudo -n test -e ${file}.d; then exit 17; fi; sudo -n install -d -m 700 ${file}.d || exit 1; head -c ${bundle_bytes} | base64 -d | sudo -n tar -xzf - -C ${file}.d" \
        <<< "${bundle}"
    rc=$?
    if [ "${rc}" -eq 17 ]; then
        msg "a job named ${job} is there already, so this one was not started; run this again in a second"
        exit 1
    fi
    if unreachable "${rc}"; then
        msg "ssh to ${target} failed (exit ${rc}); the job was not started"
        exit 255
    fi
    if [ "${rc}" -ne 0 ]; then
        msg "could not put the job in ${jobs_dir} (exit ${rc}); it was not started"
        exit 1
    fi
    # shellcheck disable=SC2016  # $0, $@ and $? are for the job's own bash in the container
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n "${ssh_opts[@]}" "${target}" \
        "sudo -n setsid nohup bash -c 'bash \"\$0.d/remote/entry.sh\" \"\$0.d\" keep${flags:+,${flags}} root \"\$@\" > \"\$0.log\" 2>&1; echo \$? > \"\$0.rc\"' ${file} ${quoted_name}${quoted} < /dev/null > /dev/null 2>&1 &"
    rc=$?
    if unreachable "${rc}"; then
        msg "ssh to ${target} failed (exit ${rc}) while the job was being started; check with --status ${job}"
        exit 255
    fi
    if [ "${rc}" -ne 0 ]; then
        msg "the job ${job} could not be started (exit ${rc})"
        exit 1
    fi
    remote_status 5
    if unreachable "${rc}"; then
        msg "ssh to ${target} failed (exit ${rc}) after the job ${job} was started, so whether it runs is not known; check with --status ${job}"
        exit 255
    fi
    case ${last} in
        'status: running' | 'status: finished, exit '*) ;;
        'status: not started')
            msg "the job ${job} did not start: after 5 seconds there is no process of it, no log and no exit code"
            exit 1
            ;;
        'status: stopped without an exit code')
            msg "the job ${job} started and stopped at once, without an exit code; its log may say why: --status ${job}"
            exit 1
            ;;
        *)
            msg "the job ${job} was started, but whether it runs could not be read (exit ${rc}); check with --status ${job}"
            exit 2
            ;;
    esac
    printf 'job: %s\n' "${job}"
    printf 'check it with: %s --status %s\n' "${script_dir}/run-in-suitecrm.sh" "${job}"
    exit 0
fi

# A plain run. The container side: unpack exactly the bundle's bytes, then entry.sh takes over the rest of stdin.
remote="set -o pipefail; d=\$(mktemp -d /tmp/clv-sc.XXXXXXXX) || exit 70; chmod 755 \"\$d\"; if ! head -c ${bundle_bytes} | base64 -d | tar -xzf - -C \"\$d\"; then rm -rf \"\$d\"; exit 70; fi; exec bash \"\$d/remote/entry.sh\" \"\$d\" ${flags:--} ${mode} ${quoted_name}${quoted}"
if [ "${pass_stdin}" -eq 1 ]; then
    { printf '%s' "${bundle}"; cat; } | SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "${remote}"
    rc=${PIPESTATUS[1]}
else
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "${remote}" < <(printf '%s' "${bundle}")
    rc=$?
fi
if unreachable "${rc}"; then
    msg "ssh to ${target} failed, or the session dropped (exit ${rc}). Read the state back before you run this again: a script that had started may have finished."
    exit 255
fi
exit "${rc}"
