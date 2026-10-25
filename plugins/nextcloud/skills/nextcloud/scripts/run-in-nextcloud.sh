#!/usr/bin/env bash
# Nextcloud DevOps Skill: run-in-nextcloud.sh
#
# Sends backup.sh or restore.sh into the Nextcloud container and runs it there as root, over the clouve-ops SSH
# channel. Those two run inside the container (they read config.php there, talk to the database and read and
# write the data volume) and sit next to this script; this one runs on the agent.
#
# Usage: run-in-nextcloud.sh [--detach] <backup.sh|restore.sh> [args...]
#        run-in-nextcloud.sh --status <job>
#
# A plain run sends the script on the channel's stdin to `sudo -n bash -s -- ARGS`, each argument quoted with
# printf %q (the clouve-ops login shell is bash, which decodes that). The script's output streams through, and
# the exit code is the script's. The run lasts as long as the SSH session. An assistant's call that reaches its
# timeout (2 minutes unless it passes a longer one, 10 at most) moves to the background and keeps that session. When
# the assistant's session ends or the connection drops first, the script in the container finds its output gone:
# backup.sh then stops and cleans up after itself, and restore.sh carries on to the end with its output going
# nowhere. So use --detach for anything that can take long: a backup with the users' files, and every restore.
#
# --detach: the job is <backup|restore>-<UTC YYYYmmdd-HHMMSS>. The first call installs the script as
# /run/clouve/jobs/<job>.sh (`sudo install -d -m 700`, then `sudo tee` with the script on stdin, then chmod 700);
# a job of that name that is there already is left alone (exit 1). The second call starts it with setsid and
# nohup, its output going to <job>.log and its exit code to <job>.rc once it ends; that call returns before the
# job runs. The third waits up to 5 seconds for the job to show that it started (a process of the job, or its
# exit code). Then this prints `job: <job>` and the --status command to run, and exits 0. A job that does not
# start in that time (sudo refused it, say) is exit 1. The job keeps running after the SSH session ends.
#
# --status <job>: the last 40 lines of the job's log, then one of
#   status: running                         no exit code yet, and a process of the job is there
#   status: finished, exit <rc>
#   status: stopped without an exit code    no exit code and no process, and a log: the job was killed, or the
#                                           container restarted and kept /run (Docker keeps it on a restart)
#   status: not started                     no exit code, no process and no log
# A job runs as `sudo setsid nohup bash -c '...' /run/clouve/jobs/<job> ARGS`, and that outer bash runs
# `bash <job>.sh ARGS`, then writes <job>.rc. So every process of the job, from sudo to the outer bash writing the
# exit code, has /run/clouve/jobs/<job> or <job>.sh as one of its arguments: that is how --status finds them. An
# empty <job>.rc is one the outer bash is writing just then, so it is no exit code yet.
# /run/clouve/jobs is inside the container. On Kubernetes a container that restarts starts with none, and every
# job is then unknown.
#
# ssh gets the options in lib/nextcloud-ssh.sh. SSHPASS is set on the sshpass command only, never exported.
#
# Env vars read:
#   NEXTCLOUD_HOST    pod-internal hostname of the Nextcloud container
#   the ops password  for sshpass -e. A current agent keeps it out of the environment; the loader line below
#                     fetches it then.
#
# Exit codes:
#   plain run  the script's own (backup.sh and restore.sh list theirs); 255 when ssh could not reach the
#              container, or the session dropped
#   --detach   0 the job started (it is running, or has finished already); 1 it was not started, or did not
#              start (the message says why); 2 it was started, but whether it runs could not be read (sudo or
#              the container's shell failed); 255 ssh failed
#   --status   0 the job finished with exit 0; 1 it finished with another code, stopped without one, or never
#              started; 2 the status could not be read (sudo or the container's shell failed); 3 it is still
#              running; 64 there is no such job; 255 ssh failed
#   1          NEXTCLOUD_HOST or the ops password is not set, lib/nextcloud-ssh.sh did not load, or the script
#              is not next to this one
#   64         usage: no script, a script other than backup.sh or restore.sh, a name that is not a job's
#
# Telling an ssh failure from the script's own code in a plain run: ssh exits 255 when it fails itself, and neither
# script ends with 255. sshpass exits 5 for a wrong password and 6 or 7 for a host key it won't accept, but backup.sh
# ends with 5 too, when the backup is kept and maintenance mode could not be turned off. So after 5, 6 or 7 one more
# call of `true` over ssh shows whether the channel works, as in occ.sh, and only when it doesn't is the run's code
# 255. After 5, 6 or 7 that is a second connection attempt, up to 10 seconds more; after 255 there is none.

# No -e: ssh's exit status is the result, and it is read below.
set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the ops password.
set +x

usage() {
    cat <<'EOF'
Usage: run-in-nextcloud.sh [--detach] <backup.sh|restore.sh> [args...]
       run-in-nextcloud.sh --status <job>

Runs backup.sh or restore.sh inside the Nextcloud container, as root, over the clouve-ops SSH channel. A plain
run streams the script's output and ends with its exit code, and lasts only as long as this command. --detach
starts it as a job that keeps running after this command and the SSH session end (use it for a backup with
--with-data and for every restore), and prints the job's name. --status <job> shows the end of the job's log and
whether it is running, or how it ended.

Exit codes: a plain run gives the script's; --detach 0 started, 1 not started, 2 started but its state
can't be read; --status 0 finished with 0, 1 finished otherwise or never started, 2 the status can't be read,
3 still running, 64 no such job; 1 a missing setting, password or file; 64 usage; 255 ssh failed.

Needs NEXTCLOUD_HOST and the clouve-ops password the agent holds.
EOF
}

msg() { printf '[nextcloud/run-in-nextcloud] %s\n' "$*" >&2; }
usage_error() {
    msg "$1"
    usage >&2
    exit 64
}

jobs_dir=/run/clouve/jobs
mode=plain
job=''
script=''
case ${1:-} in
    -h | --help) usage; exit 0 ;;
    --status)
        if [ "$#" -ne 2 ]; then usage_error "--status takes one job name"; fi
        mode=status
        job=$2
        # The name goes into a remote command, so it is checked letter by letter (no locale ranges).
        if ! [[ ${job} =~ ^(backup|restore)-[0123456789]{8}-[0123456789]{6}$ ]]; then
            usage_error "not a job's name: $(printf '%q' "${job}") (a job is backup-YYYYmmdd-HHMMSS or restore-YYYYmmdd-HHMMSS)"
        fi
        ;;
    --detach) mode=detach && shift ;;
esac
if [ "${mode}" != status ]; then
    if [ "$#" -eq 0 ]; then usage_error "no script given"; fi
    script=$1
    shift
    case ${script} in
        backup.sh | restore.sh) ;;
        *) usage_error "only backup.sh and restore.sh run in the container this way, not $(printf '%q' "${script}")" ;;
    esac
fi

if [ -z "${NEXTCLOUD_HOST:-}" ]; then
    msg "NEXTCLOUD_HOST is not set"
    exit 1
fi
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${script}" ] && [ ! -f "${script_dir}/${script}" ]; then
    msg "${script} is not next to run-in-nextcloud.sh in ${script_dir}"
    exit 1
fi
# lib/nextcloud-ssh.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/nextcloud-ssh.sh" || exit 1
mapfile -t ssh_opts < <(nc_ssh_options)
if [ "${#ssh_opts[@]}" -eq 0 ]; then
    msg "lib/nextcloud-ssh.sh gave no ssh options"
    exit 1
fi

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
if [ -z "${CLOUVE_OPS_PASSWORD}" ]; then
    msg "CLOUVE_OPS_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
    exit 1
fi
target="clouve-ops@${NEXTCLOUD_HOST}"

# The script's arguments, each quoted with %q for the remote bash
quoted=''
for arg in "$@"; do
    printf -v q ' %q' "${arg}"
    quoted+=${q}
done

# unreachable RC: RC is a code that ssh or sshpass give when they fail themselves (ssh's 255, sshpass's 5, 6 or 7).
# The commands --detach and --status send never end with those, so there the code is ssh's. A plain run's code is the
# script's, which can be 5: see channel_works.
unreachable() {
    case $1 in 5 | 6 | 7 | 255) return 0 ;; esac
    return 1
}

# channel_works: one call of `true` over ssh succeeds. After a plain run's 5, 6 or 7 it tells sshpass's failure from the
# script's own code, as occ.sh does.
channel_works() {
    SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n "${ssh_opts[@]}" "${target}" true > /dev/null 2>&1
}

# The state of a job, read in the container: sent on stdin to `sudo -n bash -s -- DIR JOB [WAIT]`, as functions and
# one call, so bash reads all of it before it runs. Without WAIT it prints the end of the job's log, then the
# status line. With WAIT (seconds) it prints the status line alone, once the job shows that it started, or WAIT
# seconds have gone by.
IFS= read -r -d '' status_script <<'EOS' || :
# job_rc FILE: the job's exit code, when FILE.rc holds one (an empty FILE.rc is one being written). The 2> comes first:
# bash applies redirections in order, so a missing FILE.rc would otherwise print its error before 2> is set.
job_rc() {
    local text=''
    IFS= read -r text 2> /dev/null < "$1.rc" || :
    case ${text} in '' | *[!0123456789]*) return 1 ;; esac
    printf '%s' "${text}"
}
# job_alive FILE: a process has FILE or FILE.sh as one of its arguments
job_alive() {
    local cmdline arg
    for cmdline in /proc/[0123456789]*/cmdline; do
        while IFS= read -r -d '' arg; do
            if [ "${arg}" = "$1" ] || [ "${arg}" = "$1.sh" ]; then return 0; fi
        done 2> /dev/null < "${cmdline}"
    done
    return 1
}
# job_state FILE: the status. The exit code is read again after the processes: a job that ends while they are read
# has its exit code by then.
job_state() {
    local rc
    if rc=$(job_rc "$1"); then echo "finished, exit ${rc}"; return 0; fi
    if job_alive "$1"; then echo running; return 0; fi
    if rc=$(job_rc "$1"); then echo "finished, exit ${rc}"; return 0; fi
    if [ -e "$1.log" ]; then echo 'stopped without an exit code'; else echo 'not started'; fi
}
status_main() {
    local f="$1/$2" wait=${3:-} state tries=0
    if [ ! -f "${f}.sh" ]; then
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

case ${mode} in
    plain)
        SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "sudo -n bash -s --${quoted}" < "${script_dir}/${script}"
        rc=$?
        # 255 is ssh's: neither script ends with it. 5, 6 and 7 are sshpass's only when the channel doesn't work.
        if [ "${rc}" -eq 255 ] || { unreachable "${rc}" && ! channel_works; }; then
            if [ "${script}" = backup.sh ]; then
                msg "ssh to ${target} failed, or the session dropped (exit ${rc}). A backup.sh that had started stops when it finds its output gone, and cleans up: no half-made backup is left, and maintenance mode is back as it was. Use --detach for long runs."
            else
                msg "ssh to ${target} failed, or the session dropped (exit ${rc}). A restore.sh that had started goes on to the end with its output gone; RESTORE-IN-PROGRESS is gone once it has finished (verify-health.sh's restore_marker shows it). Use --detach for every restore."
            fi
            exit 255
        fi
        exit "${rc}"
        ;;

    detach)
        stamp=$(date -u +%Y%m%d-%H%M%S)
        if ! [[ ${stamp} =~ ^[0123456789]{8}-[0123456789]{6}$ ]]; then
            msg "date gave no time stamp, so the job was not started"
            exit 1
        fi
        job=${script%.sh}-${stamp}
        file=${jobs_dir}/${job}
        SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" \
            "sudo -n install -d -m 700 ${jobs_dir} || exit 1; if sudo -n test -e ${file}.sh; then exit 17; fi; sudo -n tee ${file}.sh > /dev/null && sudo -n chmod 700 ${file}.sh" \
            < "${script_dir}/${script}"
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
            "sudo -n setsid nohup bash -c 'bash \"\$0.sh\" \"\$@\" > \"\$0.log\" 2>&1; echo \$? > \"\$0.rc\"' ${file}${quoted} < /dev/null > /dev/null 2>&1 &"
        rc=$?
        if unreachable "${rc}"; then
            msg "ssh to ${target} failed (exit ${rc}) while the job was being started; check with --status ${job}"
            exit 255
        fi
        if [ "${rc}" -ne 0 ]; then
            msg "the job ${job} could not be started (exit ${rc})"
            exit 1
        fi
        # The start call returned before the job ran: see that it did
        remote_status 5
        if unreachable "${rc}"; then
            msg "ssh to ${target} failed (exit ${rc}) after the job ${job} was started, so whether it runs is not known; check with --status ${job}"
            exit 255
        fi
        case ${last} in
            'status: running' | 'status: finished, exit '*) ;;
            'status: not started')
                msg "the job ${job} did not start: after 5 seconds there is no process of it, no log and no exit code (sudo may have refused it)"
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
        printf 'check it with: %s --status %s\n' "${script_dir}/run-in-nextcloud.sh" "${job}"
        exit 0
        ;;

    status)
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
                msg "there is no job ${job} in ${jobs_dir} (a container that restarts on Kubernetes starts with none)"
                exit 64
                ;;
        esac
        msg "could not read the job's status (exit ${rc}): sudo or the container's shell failed"
        exit 2
        ;;
esac
