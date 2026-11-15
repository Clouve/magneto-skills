# shellcheck shell=bash
# SuiteCRM skill: lib/suitecrm-ssh.sh (sourced by the scripts, not run)
#
# The ssh options every script of this skill uses to reach the clouve-ops account in the SuiteCRM container,
# written once. run-in-suitecrm.sh sources this file, and so does any other script that calls ssh itself.
# Sourcing it only defines one function. It creates nothing, reads nothing, exports nothing, and leaves the
# shell's options, umask and traps as they were.
#
# sc_ssh_options
#   Prints the options, one per line:
#     StrictHostKeyChecking=accept-new  takes the key a host shows the first time it sees it.
#     UserKnownHostsFile=/dev/null      keeps no known_hosts file. The containers make new SSH host keys at
#                                       every start (none are baked into the images), so a kept key would
#                                       stop every call after the first restart.
#     LogLevel=ERROR                    keeps ssh from warning about a "permanently added" host on every call.
#     ConnectTimeout=10                 gives up on a host that doesn't answer after 10 seconds.
#
# Usage:
#   . "${script_dir}/lib/suitecrm-ssh.sh"
#   mapfile -t ssh_opts < <(sc_ssh_options)
#   SSHPASS="..." sshpass -e ssh -n "${ssh_opts[@]}" "clouve-ops@${host}" "${command}"

sc_ssh_options() {
    printf '%s\n' -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10
}
