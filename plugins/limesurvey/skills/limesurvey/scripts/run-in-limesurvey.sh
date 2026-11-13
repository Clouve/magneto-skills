#!/usr/bin/env bash
# LimeSurvey skill: run-in-limesurvey.sh
#
# Sends one of this skill's in-container scripts (the files in remote/) into the LimeSurvey container and runs it
# there, over the clouve-ops SSH channel. The other scripts of the skill call this one, so it is the only place
# that opens the channel, and the only one that handles the clouve-ops password.
#
# Usage: run-in-limesurvey.sh [--stdin] [--debug] <script> [args...]
#
#   <script>   a file name in remote/: a .php file runs as www-data with LimeSurvey's own PHP, in /var/www/html.
#              backup.sh, restore.sh, backup-stream.sh, upgrade-backup.sh, state.sh and health.sh run as root. Any
#              other .sh file runs as www-data.
#   --stdin    hand this command's stdin to the script. Without it the script reads an empty stdin. Requests
#              that hold people's data or a password travel this way, never as arguments.
#   --debug    for a .php script: show every PHP warning on stderr (LS_RC_DEBUG=1).
#
# How it works. The files of remote/ are packed into one small archive. The SSH channel's stdin carries a line with
# the archive's size, then the archive, then (with --stdin) this command's stdin. In the container, start-up code
# that runs as root reads exactly that much into a work folder under /tmp that only this run uses, checks the state
# of the site, runs the script, and removes the folder. Nothing is left in the container and nothing is written to
# the LimeSurvey volume. The script's output and exit code pass through. Each argument is quoted with printf %q,
# which the clouve-ops login shell (bash) decodes, so an argument with spaces, quotes or $ arrives as it was given.
#
# The state check. While the container is still starting, while the Clouve image is installing or upgrading
# LimeSurvey or waiting for a repair, and while a restore from a backup has not finished, nothing may change the
# site. The start-up code reads the image's state (remote/lib/state.sh says what) and stops with exit 75 and the
# reason. What a script does decides how strict the check is:
#   - state.sh, health.sh, backup.sh --list, restore.sh --last-log and backup-stream.sh send only read, so they
#     always run;
#   - restore.sh and backup-stream.sh receive may run over the restore's own marker, to finish a restore that was
#     cut off, also while the image waits for exactly that;
#   - restore.sh --keys-only runs none of LimeSurvey's code, so it may also run while the image waits for a repair;
#   - everything else runs only on a site that is up, with nothing under way.
#
# ssh gets the options in lib/limesurvey-ssh.sh. SSHPASS is set on the sshpass command only, never exported.
#
# Env vars read:
#   LIMESURVEY_HOST   the LimeSurvey container's host name inside the pod
#   the ops password  for sshpass -e. A current agent keeps it out of the environment; the loader line below
#                     fetches it then.
#
# Exit codes:
#   the script's own  whatever it ended with
#   1    LIMESURVEY_HOST or the ops password is not set, or a tool or file this needs is missing
#   64   usage: no script, or a name that is not a file in remote/
#   70   the start-up code in the container failed before the script ran (stderr says why)
#   75   the site is starting, being installed, upgraded or restored, or waiting for a repair, so nothing was run
#        (stderr says which)
#   255  ssh could not reach or sign in to clouve-ops@<host>; stderr says so
#
# Telling an ssh failure from a script's own code: ssh exits 255 when it fails itself, and sshpass exits 5 for a
# wrong password and 6 or 7 for a host key it won't accept. So after 5, 6, 7 or 255 one more call of `true` over
# ssh shows whether the channel works, and only when it doesn't is the code 255 with "could not reach".

# No -e: ssh's exit status is the result, and it is read below.
set -uo pipefail
# A caller's bash -x or SHELLOPTS=xtrace would print the ops password.
set +x

usage() {
    cat <<'USAGE'
Usage: run-in-limesurvey.sh [--stdin] [--debug] <script> [args...]

Runs one of the skill's in-container scripts (a file in remote/) inside the LimeSurvey container, over the
clouve-ops SSH channel. A .php script runs as www-data; backup.sh, restore.sh, backup-stream.sh, upgrade-backup.sh,
state.sh and health.sh run as root. The script's output and exit code pass through. Nothing is left in the
container.

  --stdin   hand this command's stdin to the script (requests with people's data or a password go this way)
  --debug   show every PHP warning of a .php script on stderr

Exit codes: the script's own; 1 a missing setting, password or tool; 64 usage; 70 the start-up in the container
failed; 75 LimeSurvey is starting, being installed, upgraded or restored, or waiting for a repair, so nothing was
run; 255 ssh failed.

Needs LIMESURVEY_HOST and the clouve-ops password the agent holds.
USAGE
}

msg() { printf '[limesurvey/run] %s\n' "$*" >&2; }

pass_stdin=0
debug=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --stdin) pass_stdin=1; shift ;;
        --debug) debug=1; shift ;;
        --) shift; break ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *) break ;;
    esac
done
if [ "$#" -eq 0 ]; then
    msg "no script given"
    usage >&2
    exit 64
fi
script="$1"
shift

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The name goes into a command that root runs in the container, so it is checked letter by letter.
if ! [[ "${script}" =~ ^[abcdefghijklmnopqrstuvwxyz][abcdefghijklmnopqrstuvwxyz0123456789-]*\.(php|sh)$ ]] || [ ! -f "${script_dir}/remote/${script}" ]; then
    msg "$(printf '%q' "${script}") is not one of the scripts in remote/"
    exit 64
fi

# Who runs it, and whether it may run while the site is busy.
case "${script}" in
    backup.sh | restore.sh | backup-stream.sh | upgrade-backup.sh | state.sh | health.sh) run_as=root ;;
    *) run_as=www-data ;;
esac
# has_arg WORD: whether WORD is one of the script's arguments
has_arg() {
    local arg
    for arg in ${script_args[@]+"${script_args[@]}"}; do
        if [ "${arg}" = "$1" ]; then return 0; fi
    done
    return 1
}
script_args=("$@")
case "${script}" in
    state.sh | health.sh) busy=ok ;;
    backup.sh) if has_arg --list; then busy=ok; else busy=all; fi ;;
    restore.sh)
        if has_arg --last-log; then busy=ok
        elif has_arg --keys-only; then busy=repair
        else busy=restore-ok; fi
        ;;
    backup-stream.sh) if [ "${1:-}" = send ]; then busy=ok; else busy=restore-ok; fi ;;
    *) busy=all ;;
esac

if [ -z "${LIMESURVEY_HOST:-}" ]; then
    msg "LIMESURVEY_HOST is not set (compgen -e | grep -i limesurvey lists the settings this agent has)"
    exit 1
fi
for tool in ssh sshpass tar; do
    if ! command -v "${tool}" > /dev/null 2>&1; then
        msg "${tool} is not installed (the limesurvey plugin's install.sh adds what the scripts need)"
        exit 1
    fi
done
# lib/limesurvey-ssh.sh is checked on its own.
# shellcheck source=/dev/null
. "${script_dir}/lib/limesurvey-ssh.sh" || exit 1
mapfile -t ssh_opts < <(ls_ssh_options)
if [ "${#ssh_opts[@]}" -eq 0 ]; then
    msg "lib/limesurvey-ssh.sh gave no ssh options"
    exit 1
fi

: "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"
if [ -z "${CLOUVE_OPS_PASSWORD}" ]; then
    msg "CLOUVE_OPS_PASSWORD is not set; clv-secret --list shows the passwords this agent has"
    exit 1
fi
target="clouve-ops@${LIMESURVEY_HOST}"

# The files of remote/, as one archive. They hold no secret.
bundle="$(mktemp "${TMPDIR:-/tmp}/limesurvey-remote.XXXXXX")" || { msg "could not make a temporary file"; exit 1; }
trap 'rm -f -- "${bundle}"' EXIT
if ! tar -czf "${bundle}" -C "${script_dir}/remote" . 2> /dev/null; then
    msg "could not pack ${script_dir}/remote"
    exit 1
fi
size="$(wc -c < "${bundle}")"
size="${size//[!0123456789]/}"

# The start-up code, run in the container as root by `sudo -n bash -c`. Its arguments: who runs the script, the
# script's name, the busy rule, the debug switch, then the script's own arguments.
IFS= read -r -d '' startup <<'STARTUP' || :
set -u
run_as=$1 script=$2 busy=$3 debug=$4
shift 4
say() { printf '[limesurvey/run] %s\n' "$*" >&2; }
work=$(mktemp -d /tmp/clouve-ls.XXXXXXXX) || { say "could not make a work folder in the container"; exit 70; }
trap 'rm -rf -- "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
IFS= read -r size || size=''
case $size in '' | *[!0123456789]*) say "the scripts did not arrive (no size line)"; exit 70 ;; esac
if ! dd bs="$size" count=1 iflag=fullblock status=none | tar -xzf - -C "$work"; then
    say "the scripts did not arrive whole"
    exit 70
fi
chmod -R a+rX "$work"
if [ ! -f "$work/$script" ] || [ ! -f "$work/lib/state.sh" ]; then
    say "$script is not among the scripts that arrived"
    exit 70
fi
. "$work/lib/state.sh" || exit 70
if [ "$busy" != ok ] && reason=$(clv_busy_reason "$busy"); then
    say "$reason"
    exit 75
fi
export CLV_LS_REMOTE_DIR=$work
case $run_as:$script in
    root:*.sh) bash "$work/$script" "$@" ;;
    www-data:*.php)
        cd /var/www/html 2> /dev/null || cd /
        if [ -n "$debug" ]; then
            sudo -n -u www-data env LS_RC_DEBUG=1 php "$work/$script" "$@"
        else
            sudo -n -u www-data php "$work/$script" "$@"
        fi
        ;;
    www-data:*.sh)
        cd /var/www/html 2> /dev/null || cd /
        sudo -n -u www-data bash "$work/$script" "$@"
        ;;
    *) say "no way to run $script as $run_as"; exit 70 ;;
esac
STARTUP

printf -v remote 'sudo -n bash -c %q limesurvey-run %q %q %q %q' "${startup}" "${run_as}" "${script}" "${busy}" "${debug}"
for arg in "$@"; do
    printf -v quoted ' %q' "${arg}"
    remote+="${quoted}"
done

# The channel's stdin: the size line, the archive, then this command's stdin when --stdin asks for it.
feed() {
    printf '%s\n' "${size}"
    cat -- "${bundle}"
    if [ "${pass_stdin}" -eq 1 ]; then cat; fi
}

# SSHPASS is set on the sshpass command only.
feed | SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${target}" "${remote}"
rc="${PIPESTATUS[1]}"

case "${rc}" in
    5 | 6 | 7 | 255)
        if ! SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -n "${ssh_opts[@]}" "${target}" true > /dev/null 2>&1; then
            msg "could not reach ${target}"
            exit 255
        fi
        ;;
esac
exit "${rc}"
