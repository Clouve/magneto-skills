#!/bin/bash
# ============================================================================
# Nextcloud skill: the scripts in plugins/nextcloud/skills/nextcloud/scripts/
# ============================================================================
# One harness for every script of the plugin. It runs each script against fakes
# in a throwaway tree, the way tests/moodle-verify-health.test.sh does, so no
# Nextcloud, Docker, database, ssh or network is involved.
#
# The file has five parts. A task adds its fakes to part 2 and its section to
# part 4, and leaves the rest alone:
#
#   1. Setup     paths, counters, the test's CLOUVE_OPS_PASSWORD
#   2. Fakes     one `fake <name> <<'FAKE'` block per binary, first on PATH
#   3. Helpers   new_case, run_script, the FAKE_OUT / FAKE_ERR / FAKE_RC /
#                FAKE_HANDLER answer setters, and the expect_* checks
#   4. Sections  one per script, in the order the scripts were written
#   5. Summary
#
# Sections:
#   occ.sh            every argument reaches occ as one entry, unexpanded; the
#                     password travels on stdin and never in a command line; the
#                     exit code and both output streams pass through; the SSH
#                     failure code
#   temp-password.sh  and lib/nextcloud-passwords.sh: the file (name, modes,
#                     content), the order (file first, then Nextcloud), the occ
#                     calls and their read-back, every refusal, --remove, and a
#                     sweep for the password in every argv, log and stream
#   share-as-admin.sh the admin check; the temporary app password's life (swept,
#                     made, used, always deleted, also when the run is killed);
#                     the OCS call as curl's -K - config (quoting, no injection);
#                     the link-password file, and the share deleted again when it
#                     can't be saved; every refusal; and a sweep for the app
#                     password and the link password in every argv, environment,
#                     log and stream
#   lib/nextcloud-ssh.sh  the ssh options, written once; occ.sh and verify-health.sh
#                     take them from it
#   backup.sh         and restore.sh, which run inside the Nextcloud container as
#                     root (as a file and through `bash -s`, as run-in-nextcloud.sh
#                     sends them): the backup's files, modes, checksums and manifest;
#                     maintenance mode and the two markers; the space check; every
#                     failure and signal, each leaving a known state; the restore's
#                     order, its checks, its versions, and its recovery; and a sweep
#                     for the database password in every argv, environment, log and
#                     stream
#   run-in-nextcloud.sh  the plain run, --detach and --status
#   verify-health.sh  the checks and their statuses (OK, WARN, FAIL), the Overall
#                     line and the exit code that goes with it (0, 2, 3); the checks
#                     that are skipped when ssh to the Nextcloud container fails, and
#                     the ones that go on when only occ can't run;
#                     maintenance mode, a pending upgrade, an interrupted restore;
#                     the ssh, curl, mysql and occ calls it makes, and that it
#                     changes nothing; and a sweep for the database password and the
#                     ops password in every argv, environment, log and stream
#
# The fakes. All of them log one line per call to $FAKE_CALLS, with the
# container paths (/var/www/html, /run/clouve) shown, never a password:
#   sshpass     checks `-e` and that SSHPASS is the test's CLOUVE_OPS_PASSWORD,
#               then plays the Nextcloud container: it maps /var/www/html and
#               /run/clouve in the remote command to temp folders and runs it in
#               a real `bash -c`, from a clean environment with the fakes on
#               PATH. It owns the SSH channel: the client's stdin is copied to
#               a file first, so the call can log how many bytes were sent
#               (stdin_bytes=), and the container shell reads that file (empty
#               when ssh got -n). $FAKE_SSH_FAIL ("host=code ...", "*" for every
#               host) makes a connection fail the way ssh or sshpass would,
#               with nothing sent;
#   sudo        drops -n, -u and --preserve-env=, unsets NC_PASS unless
#               --preserve-env names it (what env_reset does), runs the rest;
#   php         plays occ when its first argument ends in /occ. It appends the
#               argv to $FAKE_OCC_LOG as one JSON array per line and, when
#               --password-from-env is among the arguments, the SHA-256 of
#               NC_PASS to $FAKE_OCC_LOG.pass. It never reads stdin, so a script
#               run through `bash -s` keeps its text. Its answers come from
#               $FAKE_OCC/<subcommand> (stdout), <subcommand>.err (stderr) and
#               <subcommand>.rc (exit code); <subcommand>.handler, an
#               executable that gets the arguments after the subcommand,
#               replaces all three;
#   flock       records the lock path and runs its command;
#   clv-secret  answers from FAKE_SECRET_<NAME>, like the agent's tool;
#   date        the real date, with "now" fixed to $FAKE_NOW (UTC) when that is set;
#   shred       logs the call, then runs the real shred ($FAKE_SHRED_FAIL makes it fail);
#   rm          the real rm ($FAKE_RM_FAIL makes it fail without removing anything);
#   cat         the real cat ($FAKE_CAT_FAIL makes it fail, as a full disk would);
#   curl        plays Nextcloud's OCS share API (see the block below): it saves
#               the `-K -` config it is sent, checks the credentials in it against
#               the token table, and answers from $FAKE_CURL_RESPONSE / _HTTP;
#   mysql, valkey-cli, df, timeout, and curl in probe mode (FAKE_CURL_MODE=probe):
#               what verify-health.sh runs against; see "The fakes of the
#               verify-health.sh cases" below. df and timeout are the real ones unless
#               a health case gives them a knob;
#   php -r, mariadb, mariadb-dump, id, chown, tar, gzip, and df -PB1: what backup.sh
#               and restore.sh run in the container; see "The fakes of the backup.sh
#               and restore.sh cases" below. Outside those cases mariadb and
#               mariadb-dump stay deny stubs, and id, tar, gzip and df are the real ones;
#   ssh, wget, nc, docker ... (the list at the top of this part): denied.
#               A tool nobody fakes yet exits 99 with a message instead of running
#               the real binary, so no test can leave this machine. A `fake <name>`
#               block replaces its stub.
# Not a fake but alongside them: install_user_fakes gives the php fake working
# user:add, user:info, user:setting and user:resetpassword over a small account
# store (see nc-users-lib.sh below), install_share_fakes adds group:list and the
# user:auth-tokens:* commands over a token table (nc-tokens-lib.sh), and the argv
# shims in ${shim_bin} log every call of the common tools, and the environment it
# got, to $FAKE_ARGV_LOG before running the real one. A section that must prove a
# password is in no argv puts that folder first on PATH (new_pw_case does).
# To add a fake, write another `fake <name> <<'FAKE'` block. The shell
# variables named FAKE_* are passed to the scripts and to the container side.
#
# Usage: bash tests/nextcloud-scripts.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: the checks hand literal "$HOME", "$5" and the like to the scripts on purpose.
# SC2034: run_script passes every FAKE_* shell variable on, so they are read indirectly.
# shellcheck disable=SC2016,SC2034

set -uo pipefail
# A script gets a closed stdin unless the call that runs it redirects one.
exec </dev/null

# ---------------------------------------------------------------------------
# 1. Setup
# ---------------------------------------------------------------------------
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$(cd "${here}/.." && pwd)/plugins/nextcloud/skills/nextcloud/scripts"
occ_sh="${scripts}/occ.sh"
temp_pw="${scripts}/temp-password.sh"
pw_lib="${scripts}/lib/nextcloud-passwords.sh"
ssh_lib="${scripts}/lib/nextcloud-ssh.sh"
share_sh="${scripts}/share-as-admin.sh"
health_sh="${scripts}/verify-health.sh"
backup_sh="${scripts}/backup.sh"
restore_sh="${scripts}/restore.sh"
run_in_sh="${scripts}/run-in-nextcloud.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-scripts-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

for tool in python3 jq sha256sum flock tar gzip setsid; do
  command -v "${tool}" >/dev/null || { echo "nextcloud-scripts: this test needs ${tool} on PATH" >&2; exit 1; }
done
env -i --default-signal=HUP true 2>/dev/null || { echo "nextcloud-scripts: this test needs an env with --default-signal (GNU coreutils 8.31 or later, or uutils)" >&2; exit 1; }

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }

# The password the agent holds for the container's clouve-ops account. The fake
# sshpass accepts only this one, and every run is checked for it (see run_script).
ops_pw='Ops-Pw-7hQk2Vx9mT'

# ---------------------------------------------------------------------------
# 2. Fakes
# ---------------------------------------------------------------------------
bin="${work}/bin"
fake_lib="${work}/fake-lib.sh"
mkdir -p "${bin}"

# fake <name>: writes the script on stdin to ${bin}/<name>
fake() { cat > "${bin}/$1"; chmod +x "${bin}/$1"; }

# Deny stubs. Each of these tools reaches beyond this machine (a network client, a database client, a container
# tool). A tool nobody fakes yet must not run the real binary: the stub says so and exits 99. A test that needs
# one writes a `fake <name>` block further down, which replaces its stub (fake overwrites the file).
for tool in ssh scp sftp rsync wget nc ncat netcat socat telnet ftp ping dig nslookup host \
  mysql mariadb mysqldump mariadb-dump mysqladmin mysqlcheck valkey-cli redis-cli docker kubectl gcloud; do
  fake "${tool}" <<'FAKE'
#!/bin/bash
. "${FAKE_LIB}"
fake_log_args "denied-${0##*/}" "$@"
echo "fake ${0##*/}: this harness does not fake ${0##*/}, and the real one would reach beyond this machine (add a 'fake ${0##*/}' block to the test)" >&2
exit 99
FAKE
done

# Sourced by the fakes. The container side runs with /var/www/html and
# /run/clouve mapped to temp folders; what the fakes log shows the container
# paths again, so the checks read the way the scripts do.
cat > "${fake_lib}" <<'LIB'
# unmap_var NAME: puts the container paths back into $NAME
unmap_var() {
  local -n _unmap_ref="$1"
  local www_to=/var/www/html run_to=/run/clouve
  _unmap_ref="${_unmap_ref//"${FAKE_WWW}"/"${www_to}"}"
  _unmap_ref="${_unmap_ref//"${FAKE_RUN}"/"${run_to}"}"
}

# fake_log TEXT...: one line in $FAKE_CALLS
fake_log() { printf '%s\n' "$*" >> "${FAKE_CALLS}"; }

# fake_log_args HEAD ARG...: HEAD, then each argument in %q form, so a call is
# one line whatever its arguments hold
fake_log_args() {
  local line="$1" arg
  shift
  for arg in "$@"; do
    unmap_var arg
    printf -v arg ' %q' "${arg}"
    line+="${arg}"
  done
  fake_log "${line}"
}
LIB

fake sshpass <<'FAKE'
#!/bin/bash
# sshpass -e ssh [-n] [-o K=V]... USER@HOST COMMAND...
. "${FAKE_LIB}"
if [ "${1:-}" != "-e" ]; then
  echo "fake sshpass: the password must come from SSHPASS (-e), got: $*" >&2
  exit 1
fi
shift
if [ "${1:-}" != "ssh" ]; then echo "fake sshpass: wanted ssh after -e, got: $*" >&2; exit 1; fi
shift
opts=()
stdin=open
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) opts+=(-n); stdin=closed; shift ;;
    -o) opts+=(-o "$2"); shift 2 ;;
    -*) echo "fake sshpass: unexpected ssh option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
target="$1"
shift
cmd="$*"
host="${target#*@}"

log_ssh() { fake_log "ssh opts=${opts[*]} target=${target} stdin=${stdin} stdin_bytes=$1 cmd=${cmd}"; }
# refuse CODE [MESSAGE]: the connection fails before any command runs, so nothing was sent.
refuse() {
  log_ssh 0
  [ -n "${2:-}" ] && echo "$2" >&2
  exit "$1"
}

# A host that cannot be reached, or whose key changed.
read -ra failing <<< "${FAKE_SSH_FAIL:-}"
for spec in "${failing[@]}"; do
  if [ "${spec%%=*}" = "${host}" ] || [ "${spec%%=*}" = '*' ]; then
    message=""
    [ "${spec#*=}" = 255 ] && message="ssh: connect to host ${host} port 22: Connection refused"
    refuse "${spec#*=}" "${message}"
  fi
done
[ -n "${SSHPASS+x}" ] || refuse 1 "sshpass: -e option given but SSHPASS environment variable not set"
[ "${SSHPASS}" = "${FAKE_OPS_PASSWORD}" ] || refuse 5 "Permission denied, please try again."   # sshpass: incorrect password
# FAKE_HEALTH_SSH_FAIL_CMD: a connection that is lost in the middle of a run. A command with this text in it fails the way
# a dropped connection does (255, nothing run), though earlier commands worked.
if [ -n "${FAKE_HEALTH_SSH_FAIL_CMD:-}" ] && [[ "${cmd}" == *"${FAKE_HEALTH_SSH_FAIL_CMD}"* ]]; then
  refuse 255 "Connection to ${host} closed by remote host.${FAKE_HEALTH_SSH_ECHO_PW:+ [${SSHPASS}]}"   # a message that repeats the password, when asked to
fi

# The channel is up, and its input is what the client sends on stdin. Copy it to a
# file: that gives its size, and the container shell reads the file (empty after
# ssh -n). The copy holds a password for a moment, so it is removed after the call.
channel="$(mktemp "${TMPDIR:-/tmp}/channel.XXXXXX")"
if [ "${stdin}" = open ]; then cat > "${channel}"; fi
log_ssh "$(wc -c < "${channel}" | tr -d ' ')"

# The container side: a fresh bash, as sshd runs the command, in the ops user's
# home, with its own environment and the fakes on PATH. The agent's secrets stay out.
orig_cmd="${cmd}"
cmd="${cmd//"/var/www/html"/"${FAKE_WWW}"}"
cmd="${cmd//"/run/clouve"/"${FAKE_RUN}"}"
remote_env=()
for name in $(compgen -e FAKE_); do
  case "${name}" in FAKE_OPS_PASSWORD | FAKE_SECRET_*) continue ;; esac
  remote_env+=("${name}=${!name}")
done
remote_env+=("FAKE_SIDE=container")   # the argv shims log which side a call ran on
cd "${FAKE_OPS_HOME}" || exit 1
env -i HOME="${FAKE_OPS_HOME}" PATH="${PATH}" "${remote_env[@]}" bash -c "${cmd}" < "${channel}"
code=$?
rm -f "${channel}"
# FAKE_HEALTH_SSH_LOST_AFTER: the connection drops after the command has run and printed its output: a command with this text in it
# exits 255, with its output delivered
if [ -n "${FAKE_HEALTH_SSH_LOST_AFTER:-}" ] && [[ "${orig_cmd}" == *"${FAKE_HEALTH_SSH_LOST_AFTER}"* ]]; then code=255; fi
exit "${code}"
FAKE

fake sudo <<'FAKE'
#!/bin/bash
# sudo [-n] [-u USER] [--preserve-env=LIST] COMMAND...
. "${FAKE_LIB}"
user=root
preserve=-
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) shift ;;
    -u) user="$2"; shift 2 ;;
    --preserve-env=*) preserve="${1#*=}"; shift ;;
    -*) echo "fake sudo: unexpected option $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
# FAKE_HEALTH_SUDO_FAIL=<command>: sudo refuses to run that command, as it does for an account that may not: exit 1, nothing run.
if [ -n "${FAKE_HEALTH_SUDO_FAIL:-}" ] && [ "${1:-}" = "${FAKE_HEALTH_SUDO_FAIL}" ]; then
  echo "sudo: a password is required" >&2
  exit 1
fi
reached=unset
[ -n "${NC_PASS+x}" ] && reached=set
# env_reset: NC_PASS survives only when --preserve-env names it.
case ",${preserve}," in *,NC_PASS,*) ;; *) unset NC_PASS ;; esac
# the log shows <php code> for the program of a php -r, so a line stays readable
shown=()
prev=""
for arg in "$@"; do
  if [ "${prev}" = -r ] && [ "${1:-}" = php ]; then shown+=("<php code>"); else shown+=("${arg}"); fi
  prev="${arg}"
done
fake_log_args "sudo user=${user} preserve=${preserve} NC_PASS=${reached} ::" "${shown[@]}"
# the user the command runs as, for the argv shims' .as log (the cases can't switch users for real)
export FAKE_RUN_AS="${user}"
exec "$@"
FAKE

fake php <<'FAKE'
#!/bin/bash
# php <dir>/occ ...: plays occ. php [-d K=V]... -r CODE -- ... goes to fake-php-r (the programs of backup.sh and restore.sh).
# It never reads stdin, as occ --no-interaction doesn't: a script run through `bash -s` is on it.
. "${FAKE_LIB}"
case "${1:-}" in
  */occ) ;;
  -d | -r) exec "${FAKE_LIB%/*}/fake-php-r" "$@" ;;
  *) echo "fake php: only 'php <dir>/occ ...' and 'php [-d K=V]... -r CODE -- ...' are played, got: $*" >&2; exit 1 ;;
esac
fake_log_args php "$@"
python3 -I -c '
import json, os, sys
www, run = os.environ["FAKE_WWW"], os.environ["FAKE_RUN"]
print(json.dumps([a.replace(www, "/var/www/html").replace(run, "/run/clouve") for a in sys.argv[1:]]))
' "$@" >> "${FAKE_OCC_LOG}"
shift
# The subcommand is the first argument that is not an option; "rest" follows it.
sub=""
rest=()
i=0
for arg in "$@"; do
  i=$((i + 1))
  case "${arg}" in -*) continue ;; esac
  sub="${arg}"
  rest=("${@:i+1}")
  break
done
# --password-from-env: occ reads NC_PASS, then OC_PASS, and refuses when both are empty.
for arg in "$@"; do
  [ "${arg}" = "--" ] && break
  if [ "${arg}" = "--password-from-env" ]; then
    pw="${NC_PASS:-${OC_PASS:-}}"
    if [ -z "${pw}" ]; then
      echo "--password-from-env given, but NC_PASS/OC_PASS is empty!"
      exit 1
    fi
    # Only the hash is kept, so no fake log ever holds a password.
    printf '%s' "${pw}" | sha256sum | cut -d' ' -f1 >> "${FAKE_OCC_LOG}.pass"
  fi
done
if [ -n "${sub}" ] && [ -x "${FAKE_OCC}/${sub}.handler" ]; then
  exec "${FAKE_OCC}/${sub}.handler" "${rest[@]}"
fi
[ -f "${FAKE_OCC}/${sub}.err" ] && cat "${FAKE_OCC}/${sub}.err" >&2
[ -f "${FAKE_OCC}/${sub}" ] && cat "${FAKE_OCC}/${sub}"
code=0
[ -f "${FAKE_OCC}/${sub}.rc" ] && code="$(cat "${FAKE_OCC}/${sub}.rc")"
exit "${code}"
FAKE

# flock, in two forms. The container side (occ.sh --init-lock) is `flock [options] LOCKFILE COMMAND...`: it logs the lock
# path and runs the command. The agent side (share-as-admin.sh) is `flock -w N FD`: it locks the caller's file descriptor FD
# for real, with the real flock, so two runs really take turns (the lock belongs to the open file the caller and its children
# share, so it outlives this process). It logs `flock-fd <the arguments as given>`, and waits at most $FAKE_FLOCK_WAIT seconds
# (default 30) whatever -w says, so a test never sits through the script's two minutes.
real_flock="$(command -v flock)"
fake flock <<FAKE
#!/bin/bash
. "\${FAKE_LIB}"
args=("\$@")
nonblock=0
conflict=1
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -w) shift 2 ;;
    -E) conflict="\$2"; shift 2 ;;
    -n) nonblock=1; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
lock="\$1"
shift
if [ "\$#" -eq 0 ] && [[ "\${lock}" =~ ^[0-9]+\$ ]]; then
  fake_log "flock-fd \${args[*]}"
  # the file that descriptor is open on (the backup.sh cases check which file a lock lands on)
  fd_path="\$(readlink "/proc/\$\$/fd/\${lock}" 2> /dev/null)"
  unmap_var fd_path
  fake_log "flock-fd-file \${lock} \${fd_path}"
  capped=()
  for ((i = 0; i < \${#args[@]}; i++)); do
    if [ "\${args[i]}" = -w ]; then capped+=(-w "\${FAKE_FLOCK_WAIT:-30}"); i=\$((i + 1)); else capped+=("\${args[i]}"); fi
  done
  exec "${real_flock}" "\${capped[@]}"
fi
unmap_var lock
fake_log "flock \${lock}"
# FAKE_HEALTH_INIT_LOCK: the image's init lock is held by an install, an upgrade, a recovery, a backup or a restore: flock -n gives up with its -E code
if [ "\${nonblock}" -eq 1 ] && [ -n "\${FAKE_HEALTH_INIT_LOCK:-}" ]; then exit "\${conflict}"; fi
exec "\$@"
FAKE

fake clv-secret <<'FAKE'
#!/bin/bash
# clv-secret NAME | --list | --has NAME: the value of FAKE_SECRET_<NAME>, like the agent's tool
. "${FAKE_LIB}"
fake_log "clv-secret $*"
case "${1:-}" in
  --list) compgen -e FAKE_SECRET_ | sed 's/^FAKE_SECRET_//'; exit 0 ;;
  --has) var="FAKE_SECRET_${2:-}"; [ -n "${!var+x}" ]; exit ;;
esac
var="FAKE_SECRET_${1:-}"
if [ -z "${!var+x}" ]; then
  echo "clv-secret: ${1:-} is not set on this server" >&2
  exit 2
fi
printf '%s' "${!var}"
FAKE

# date: the real date, with "now" fixed to $FAKE_NOW (UTC, anything date -d reads) when that is
# set. A case that needs two runs in the same second, or a known file name, sets it.
real_date="$(command -v date)"
fake date <<FAKE
#!/bin/bash
# date [options] [+FORMAT]. It never reads stdin. FAKE_HEALTH_DATE_RAW is what date +%s prints, whatever the time is
# (the container's clock, in the health cases).
if [ -n "\${FAKE_HEALTH_DATE_RAW+x}" ] && [ "\$*" = '+%s' ]; then printf '%s\n' "\${FAKE_HEALTH_DATE_RAW}"; exit 0; fi
if [ -n "\${FAKE_NOW:-}" ]; then
  TZ=UTC exec "${real_date}" -d "\${FAKE_NOW}" "\$@"
fi
exec "${real_date}" "\$@"
FAKE

# shred: logs the call, then runs the real shred. $FAKE_SHRED_FAIL makes it fail, as the real one
# does on a file system that cannot be overwritten in place. With no real shred on this machine
# it only unlinks, so the cases still run.
real_shred="$(command -v shred || true)"
fake shred <<FAKE
#!/bin/bash
. "\${FAKE_LIB}"
fake_log_args shred "\$@"
if [ -n "\${FAKE_SHRED_FAIL:-}" ]; then echo "shred: fake failure" >&2; exit 1; fi
if [ -n "${real_shred}" ]; then exec "${real_shred}" "\$@"; fi
for arg in "\$@"; do case "\${arg}" in -*) ;; *) rm -f -- "\${arg}" ;; esac; done
FAKE

# rm: the real rm. $FAKE_RM_FAIL makes it fail without removing anything, so a case can have a file that
# neither shred nor rm can delete.
real_rm="$(command -v rm)"
fake rm <<FAKE
#!/bin/bash
if [ -n "\${FAKE_RM_FAIL:-}" ]; then echo "rm: fake failure" >&2; exit 1; fi
exec "${real_rm}" "\$@"
FAKE

# cat: the real cat. $FAKE_CAT_FAIL makes it fail, as a full disk would, so a case can make the
# write of the password file fail.
real_cat="$(command -v cat)"
fake cat <<FAKE
#!/bin/bash
if [ -n "\${FAKE_CAT_FAIL:-}" ]; then echo "cat: fake write error" >&2; exit 1; fi
exec "${real_cat}" "\$@"
FAKE

# curl: plays Nextcloud's OCS share API for share-as-admin.sh. It takes only the options the script uses
# (-q first, -sS, -m N, -K -, --noproxy '*', -X METHOD, -G, -w FORMAT, one URL); any other is exit 2, as a typo would be.
# -q has to come first, or curl reads ~/.curlrc; --noproxy '*' keeps a proxy variable from getting the credentials. Per call n:
#   - it reads the `-K -` config from stdin and saves it byte for byte as $FAKE_CURL_CFG.<n>. The config must be
#     lines of `user|header|data-urlencode = "VALUE"` and nothing else, with curl's backslash rules inside the
#     quotes (\\ \" \t \n \r \v). Anything else is exit 2: a value that got out of its line would be a new
#     option, such as url or output, to the real curl. It never prints a config line (they hold the token);
#   - it logs its argv to $FAKE_CALLS, then `curl-call n=<n> method=<M> auth=<ok|fail> uid=<uid>`. auth is ok
#     when the user line matches a row of the token table $FAKE_TOKENS (what the fake occ keeps), so a call made
#     with a token that was never made, or was already deleted, gets the 401 a real server gives;
#   - it answers $FAKE_CURL_RESPONSE with status $FAKE_CURL_HTTP (default when unset: a bare OCS 200; set
#     but empty is an empty body), and for call n $FAKE_CURL_RESPONSE_<n> / $FAKE_CURL_HTTP_<n> instead. An
#     unauthenticated call is always the 401;
#   - @PASSWORD@ and @TOKEN@ in the answer become the password= field and the app password the script sent, for
#     the cases where a server echoes what it was given;
#   - $FAKE_CURL_EXIT=7 or 28 makes it fail the way curl does: the error on stderr, no body, status 000;
#   - $FAKE_CURL_DELAY=<seconds> (or $FAKE_CURL_DELAY_<n> for call n) makes it wait that long after it has read the
#     config and before it looks at the credentials, as a slow server would: a token deleted meanwhile is refused;
#   - $FAKE_CURL_KILL=<signal> sends that signal to the script (its PID is in $FAKE_PIDFILE) when it is called,
#     and $FAKE_CURL_REVOKE=1 deletes the temporary tokens first, as a second run's sweep would. With
#     $FAKE_CURL_LINGER=<seconds> it then keeps running that long and logs `curl-done n=<n>`: a script that
#     traps the signal waits for the request first, so the line is there, one that does not is gone before it;
#   - it appends its environment to $FAKE_ARGV_LOG.env, as the argv shims do.
# The -w FORMAT is played for \n and %{http_code}, which is what the script asks for. As curl does with -w, the
# write-out is printed even when the transfer failed.
fake curl <<'FAKE'
#!/bin/bash
. "${FAKE_LIB}"
# verify-health.sh's probe of the public pages is another conversation: FAKE_CURL_MODE=probe hands it to its own fake (below)
if [ "${FAKE_CURL_MODE:-}" = probe ]; then exec "${FAKE_LIB%/*}/fake-curl-probe" "$@"; fi
bail() { echo "fake curl: $*" >&2; exit 2; }
n=0
if [ -f "${FAKE_CURL_CFG}.n" ]; then read -r n < "${FAKE_CURL_CFG}.n"; fi
n=$((n + 1))
printf '%s\n' "${n}" > "${FAKE_CURL_CFG}.n"

args=("$@")
method="" fmt="" url="" cfg_stdin=0
[ "${1:-}" = -q ] || bail "the first argument must be -q, or curl reads ~/.curlrc and whatever it holds"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q | -sS | -s | -S | -G) ;;
    --noproxy) [ "${2:-}" = '*' ] || bail "--noproxy must be '*', got '${2:-}'"; noproxy=1; shift ;;
    -m) [ -n "${2:-}" ] || bail "-m needs a value"; shift ;;
    -K) [ "${2:-}" = - ] || bail "only -K - is played, got -K ${2:-}"; cfg_stdin=1; shift ;;
    -X) method="${2:-}"; shift ;;
    -w) fmt="${2:-}"; shift ;;
    -*) bail "unexpected option $1" ;;
    *) [ -z "${url}" ] || bail "two URLs: ${url} and $1"; url="$1" ;;
  esac
  shift
done
[ "${cfg_stdin}" -eq 1 ] || bail "the script must hand its credentials over with -K -"
[ "${noproxy:-0}" -eq 1 ] || bail "the script must pass --noproxy '*': it sends credentials, and a proxy variable must not get them"
[ -n "${url}" ] || bail "no URL"
fake_log_args curl "${args[@]}"

IFS= read -r -d '' cfg_text || true
printf '%s' "${cfg_text}" > "${FAKE_CURL_CFG}.${n}"
for name in $(compgen -e); do printf 'agent %s=%s\n' "${name}" "${!name}"; done >> "${FAKE_ARGV_LOG}.env"

# unq TEXT: TEXT as curl reads it between the double quotes. Fails on a quote that is not escaped.
unq() {
  local s="$1" out="" c
  unq_out=""
  while [ -n "${s}" ]; do
    c="${s:0:1}"
    s="${s:1}"
    case "${c}" in
      '"') return 1 ;;
      '\')
        c="${s:0:1}"
        s="${s:1}"
        [ -n "${c}" ] || return 1
        case "${c}" in t) c=$'\t' ;; n) c=$'\n' ;; r) c=$'\r' ;; v) c=$'\v' ;; esac
        ;;
    esac
    out+="${c}"
  done
  unq_out="${out}"
}
cfg_user="" got_pw=""
line_re='^(user|header|data-urlencode) = "(.*)"$'
ln=0
while IFS= read -r line || [ -n "${line}" ]; do
  ln=$((ln + 1))
  [ -n "${line}" ] || continue
  [[ "${line}" =~ ${line_re} ]] || bail "config line ${ln} is not 'user|header|data-urlencode = \"...\"'"
  unq "${BASH_REMATCH[2]}" || bail "config line ${ln} has a quote or a trailing backslash that is not escaped"
  if [ "${BASH_REMATCH[1]}" = user ]; then cfg_user="${unq_out}"; fi
  if [ "${BASH_REMATCH[1]}" = data-urlencode ] && [[ "${unq_out}" == password=* ]]; then got_pw="${unq_out#password=}"; fi
done < "${FAKE_CURL_CFG}.${n}"

delay="${FAKE_CURL_DELAY:-}"
delay_var="FAKE_CURL_DELAY_${n}"
if [ -n "${!delay_var+x}" ]; then delay="${!delay_var}"; fi
if [ -n "${delay}" ]; then sleep "${delay}"; fi

# $FAKE_CURL_REVOKE: another run's sweep deleted the temporary tokens before this call got to the server
if [ -n "${FAKE_CURL_REVOKE:-}" ] && [ -f "${FAKE_TOKENS}" ]; then
  keep=()
  while IFS=$'\t' read -r tid tuid tname tsecret; do
    if [ "${tname}" != clouve-ai-assistant-temporary ]; then keep+=("${tid}"$'\t'"${tuid}"$'\t'"${tname}"$'\t'"${tsecret}"); fi
  done < "${FAKE_TOKENS}"
  : > "${FAKE_TOKENS}"
  for row in ${keep[@]+"${keep[@]}"}; do printf '%s\n' "${row}" >> "${FAKE_TOKENS}"; done
fi

auth=fail
cfg_uid="${cfg_user%%:*}"
cfg_secret="${cfg_user#*:}"
if [ -f "${FAKE_TOKENS}" ] && [ "${cfg_user}" != "${cfg_uid}" ] && [ -n "${cfg_secret}" ]; then
  while IFS=$'\t' read -r tid tuid tname tsecret; do
    if [ "${tuid,,}" = "${cfg_uid,,}" ] && [ "${tsecret}" = "${cfg_secret}" ]; then auth=ok; fi
  done < "${FAKE_TOKENS}"
fi
fake_log "curl-call n=${n} method=${method} auth=${auth} uid=${cfg_uid}"

if [ -n "${FAKE_CURL_KILL:-}" ]; then
  kill -s "${FAKE_CURL_KILL}" "$(< "${FAKE_PIDFILE}")"
  if [ -n "${FAKE_CURL_LINGER:-}" ]; then sleep "${FAKE_CURL_LINGER}"; fake_log "curl-done n=${n}"; fi
fi

ok_body='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[]}}'
body="${FAKE_CURL_RESPONSE-${ok_body}}"
http="${FAKE_CURL_HTTP-200}"
body_var="FAKE_CURL_RESPONSE_${n}"
http_var="FAKE_CURL_HTTP_${n}"
if [ -n "${!body_var+x}" ]; then body="${!body_var}"; fi
if [ -n "${!http_var+x}" ]; then http="${!http_var}"; fi
body="${body//@PASSWORD@/${got_pw}}"
body="${body//@TOKEN@/${cfg_secret}}"
code=0
if [ "${auth}" != ok ]; then
  http=401
  body='{"ocs":{"meta":{"status":"failure","statuscode":997,"message":"Current user is not logged in"},"data":[]}}'
fi
if [ -n "${FAKE_CURL_EXIT:-}" ]; then
  case "${FAKE_CURL_EXIT}" in
    7) echo "curl: (7) Failed to connect to ${url#http://}: Connection refused" >&2 ;;
    28) echo "curl: (28) Operation timed out after 30001 milliseconds with 0 bytes received" >&2 ;;
  esac
  body="" http=000 code="${FAKE_CURL_EXIT}"
fi
printf '%s' "${body}"
if [ -n "${fmt}" ]; then
  out="${fmt//'%{http_code}'/${http}}"
  printf '%s' "${out//'\n'/$'\n'}"
fi
exit "${code}"
FAKE

# argv shims. A section that must prove a secret is in no argv puts ${shim_bin} first on PATH.
# Each shim logs "<tool> <args>" to $FAKE_ARGV_LOG and the names and values of the variables it
# got to $FAKE_ARGV_LOG.env (each line starts with agent or container: the sshpass fake sets
# FAKE_SIDE=container for what it runs), then runs the next command of that name on PATH, so
# it composes with the fakes above. It never reads stdin. It also logs "<user> <tool> <args>" to
# $FAKE_ARGV_LOG.as: the user the fake sudo ran it as, or root for a command the script ran itself
# (the backup.sh and restore.sh cases play root in the container).
shim_bin="${work}/shims"
mkdir -p "${shim_bin}"
cat > "${shim_bin}/.shim" <<'SHIM'
#!/bin/bash
tool="${0##*/}"
if [ -n "${FAKE_ARGV_LOG:-}" ]; then
  { printf '%q' "${tool}"; printf ' %q' "$@"; printf '\n'; } >> "${FAKE_ARGV_LOG}"
  { printf '%s %q' "${FAKE_RUN_AS:-root}" "${tool}"; printf ' %q' "$@"; printf '\n'; } >> "${FAKE_ARGV_LOG}.as"
  for name in $(compgen -e); do printf '%s %s=%s\n' "${FAKE_SIDE:-agent}" "${name}" "${!name}"; done >> "${FAKE_ARGV_LOG}.env"
  # jq's environments on their own: of the shimmed tools, jq is the one the scripts call themselves (the fake sshpass runs the others)
  if [ "${tool}" = jq ]; then
    for name in $(compgen -e); do printf '%s %s=%s\n' "${FAKE_SIDE:-agent}" "${name}" "${!name}"; done >> "${FAKE_ARGV_LOG}.env.jq"
  fi
fi
PATH=":${PATH}:"
PATH="${PATH//:${0%/*}:/:}"
PATH="${PATH#:}"
exec "${tool}" "$@"
SHIM
chmod +x "${shim_bin}/.shim"
for tool in basename cat chmod cp cut date dirname find grep head install jq ln ls mkdir mktemp mv realpath rm sed shred sleep stat tar tee test touch tr wc; do
  ln -s .shim "${shim_bin}/${tool}"
done

# nc-users-lib.sh: a stand-in for Nextcloud's account store, for the user:* commands. The handlers
# that install_user_fakes writes source it. One JSON file per account in $FAKE_USERS, named by the
# hash of the lower-cased uid, because Nextcloud compares uids without regard to case. It never
# stores a password. Every message goes to stdout, as occ prints them. Knobs (empty is off):
#   FAKE_PW_MINLEN     shortest password accepted (default 10, Nextcloud's own default)
#   FAKE_PW_POLICY     extra rules, any of: upper lower digit
#   FAKE_GROUP_FAIL    groups user:add silently skips (Add.php skips a group it cannot create)
#   FAKE_GROUP_CASE    "asked=stored ...": user:add puts the account in a group spelled differently from
#                      the one asked for (group names are case-sensitive, so that is another group)
#   FAKE_ADD_NODISPLAY user:add does not set the display name (it prints nothing about it)
#   FAKE_ADD_LOGIN     user:info shows this as the new account's user_id instead of the uid it was given
#   FAKE_INFO_NOJSON   user:info exits 0 and prints a notice instead of JSON
#   FAKE_INFO_NOTFOUND_TEXT / FAKE_INFO_NOTFOUND_RC   what user:info says, and exits with, for an account that does not
#                      exist (default: "user not found" and 1, which is what occ does)
#   FAKE_INFO_NOISE    user:info prints a PHP warning line before the JSON
#   FAKE_INFO_NO_UID   user:info's JSON has no user_id
#   FAKE_ADD_NOOP      user:add says it created the account and creates nothing
#   FAKE_ADD_FAIL_AFTER  "account" or "display": user:add makes the account and then throws, as Add.php
#                      can ("Invalid displayname"). With "display" the display name was set first; groups never are
#   FAKE_ENCRYPTION    app:list: "enabled" lists the encryption app as enabled (default: it is listed under
#                      disabled, as in a stock instance); "fail" exits 1; "nojson" exits 0 with no JSON;
#                      "odd" prints JSON that has no "enabled" list
#   FAKE_MASTER_KEY    config:app:get encryption useMasterKey: any text prints as the stored value, "blank" is a
#                      stored empty string (an empty line), "fail" exits 2, "exception" exits 1 with an error on
#                      stderr, as occ does for an exception whose code is no number, such as a PDOException's
#                      SQLSTATE (default: the key is not set: exit 1 and nothing printed, as the real command does)
#   FAKE_SETTING_NOOP  user:setting exits 0 and stores nothing
#   FAKE_SETTING_FAIL  user:setting fails with exit 1
#   FAKE_ECHO_PW_FILE  user:add and user:resetpassword write the password to this file and echo it
#                      in their refusal (to prove the script hides it)
# The handlers also log, to $FAKE_CALLS, whether a password file holding the password they were
# given was already in $FAKE_PW_DIR: the proof that the file is written before Nextcloud changes.
users_lib="${work}/nc-users-lib.sh"
cat > "${users_lib}" <<'LIB'
nc_fake_file() { printf '%s/%s' "${FAKE_USERS}" "$(printf '%s' "${1,,}" | sha256sum | cut -c1-16)"; }

# nc_fake_resolve NAME: the account file for NAME, found the way Nextcloud 35 finds an account
# (Database::userExists): its login in any case, else the first account whose email address is NAME.
# Prints nothing and fails when there is none.
nc_fake_resolve() {
  local f e
  f="$(nc_fake_file "$1")"
  if [ -e "${f}" ]; then printf '%s' "${f}"; return 0; fi
  for f in "${FAKE_USERS}"/????????????????; do
    [ -f "${f}" ] || continue
    e="$(jq -r '.email // ""' "${f}" 2>/dev/null)"
    if [ -n "${e}" ] && [ "${e}" = "${1,,}" ]; then printf '%s' "${f}"; return 0; fi
  done
  return 1
}

# nc_fake_args ARG...: sets fa_display, fa_output, fa_groups[] and fa_pos[] the way occ reads them
nc_fake_args() {
  fa_display=""; fa_output=""; fa_groups=(); fa_pos=()
  local past=0
  while [ "$#" -gt 0 ]; do
    if [ "${past}" -eq 1 ]; then fa_pos+=("$1"); shift; continue; fi
    case "$1" in
      --) past=1 ;;
      --password-from-env) ;;
      --display-name=*) fa_display="${1#*=}" ;;
      --output=*) fa_output="${1#*=}" ;;
      --email=*) ;;
      -g) shift; fa_groups+=("${1-}") ;;
      -*) echo "The \"$1\" option does not exist."; return 1 ;;
      *) fa_pos+=("$1") ;;
    esac
    shift
  done
}

# nc_fake_create UID DISPLAY EMAIL GROUP...: writes an account
nc_fake_create() {
  local uid="$1" display="$2" email="$3"
  shift 3
  mkdir -p "${FAKE_USERS}"
  jq -n --arg uid "${uid}" --arg display "${display:-${uid}}" --arg email "${email}" --arg shown "${FAKE_ADD_LOGIN:-}" '{
      user_id: (if $shown != "" then $shown else $uid end), display_name: $display, email: $email, cloud_id: "\($uid)@abc.clouve.app",
      enabled: true, groups: $ARGS.positional, quota: "none", storage: [], first_seen: "never",
      last_seen: "never", user_directory: "/var/www/html/data/\($uid)", backend: "Database"}' \
    --args "$@" > "$(nc_fake_file "${uid}")"
}

# nc_fake_password_ok: Nextcloud's password policy as far as the cases need it. Prints the reason and fails when NC_PASS is refused.
nc_fake_password_ok() {
  local pw="${NC_PASS:-}" min="${FAKE_PW_MINLEN:-10}"
  if [ -n "${FAKE_ECHO_PW_FILE:-}" ]; then
    printf '%s' "${pw}" > "${FAKE_ECHO_PW_FILE}"
    echo "Rejected the password ${pw}"
    return 1
  fi
  if [ "${#pw}" -lt "${min}" ]; then echo "Password needs to be at least ${min} characters long."; return 1; fi
  case " ${FAKE_PW_POLICY:-} " in
    *' upper '*) case "${pw}" in *[[:upper:]]*) ;; *) echo "Password needs to contain at least one upper case letter."; return 1 ;; esac ;;
  esac
  case " ${FAKE_PW_POLICY:-} " in
    *' lower '*) case "${pw}" in *[[:lower:]]*) ;; *) echo "Password needs to contain at least one lower case letter."; return 1 ;; esac ;;
  esac
  case " ${FAKE_PW_POLICY:-} " in
    *' digit '*) case "${pw}" in *[[:digit:]]*) ;; *) echo "Password needs to contain at least one numeric character."; return 1 ;; esac ;;
  esac
}

# nc_fake_password_saved CMD: logs whether some file in $FAKE_PW_DIR holds NC_PASS on a line of its
# own. Pure bash, so the password is in no argv.
nc_fake_password_saved() {
  local f line found=no
  for f in "${FAKE_PW_DIR}"/*; do
    [ -f "${f}" ] || continue
    while IFS= read -r line || [ -n "${line}" ]; do
      if [ "${line}" = "${NC_PASS:-}" ]; then found=yes; fi
    done < "${f}"
  done
  fake_log "$1: password file already saved: ${found}"
}

fake_user_add() {
  nc_fake_args "$@" || return 1
  local uid="${fa_pos[0]-}" g pair display kept=()
  nc_fake_password_saved user:add
  if nc_fake_resolve "${uid}" > /dev/null; then echo "The account \"${uid}\" already exists."; return 1; fi
  nc_fake_password_ok || return 1
  if [ -n "${FAKE_ADD_NOOP:-}" ]; then echo "The account \"${uid}\" was created successfully"; return 0; fi
  if [ -n "${FAKE_ADD_FAIL_AFTER:-}" ]; then
    display=""
    if [ "${FAKE_ADD_FAIL_AFTER}" = display ]; then display="${fa_display}"; fi
    nc_fake_create "${uid}" "${display}" ""
    echo "The account \"${uid}\" was created successfully"
    if [ -n "${display}" ]; then echo "Display name set to \"${display}\""; fi
    printf '\n  Invalid displayname\n\n'
    return 1
  fi
  for g in "${fa_groups[@]}"; do
    case " ${FAKE_GROUP_FAIL:-} " in *" ${g} "*) continue ;; esac
    for pair in ${FAKE_GROUP_CASE:-}; do                       # a differently spelled group
      if [ "${pair%%=*}" = "${g}" ]; then g="${pair#*=}"; fi
    done
    kept+=("${g}")
  done
  display="${fa_display#"${fa_display%%[![:space:]]*}"}"     # Nextcloud trims the display name
  display="${display%"${display##*[![:space:]]}"}"
  if [ -n "${FAKE_ADD_NODISPLAY:-}" ]; then display=""; fi
  nc_fake_create "${uid}" "${display}" "" "${kept[@]}"
  echo "The account \"${uid}\" was created successfully"
  if [ -n "${display}" ]; then echo "Display name set to \"${display}\""; fi
  for g in "${kept[@]}"; do echo "Account \"${uid}\" added to group \"${g}\""; done
}

fake_user_setting() {
  nc_fake_args "$@" || return 1
  local uid="${fa_pos[0]-}" app="${fa_pos[1]-}" key="${fa_pos[2]-}" value="${fa_pos[3]-}" f
  f="$(nc_fake_file "${uid}")"
  if [ ! -e "${f}" ]; then echo "The user \"${uid}\" does not exist."; return 1; fi
  if [ "${#fa_pos[@]}" -ge 4 ] && [ "${app}" = settings ] && [ "${key}" = email ]; then
    if [ -n "${FAKE_SETTING_FAIL:-}" ]; then echo "Could not save the setting."; return 1; fi
    if [ -n "${FAKE_SETTING_NOOP:-}" ]; then return 0; fi
    value="${value#"${value%%[![:space:]]*}"}"                 # Nextcloud trims and lower-cases it
    value="${value%"${value##*[![:space:]]}"}"
    jq --arg e "${value,,}" '.email = $e' "${f}" > "${f}.new" && mv "${f}.new" "${f}"
    return 0
  fi
  echo "(fake) unsupported user:setting call: $*"
  return 1
}

fake_user_info() {
  nc_fake_args "$@" || return 1
  local uid="${fa_pos[0]-}" f
  f="$(nc_fake_resolve "${uid}")" || f="$(nc_fake_file "${uid}")"
  if [ ! -e "${f}" ]; then echo "${FAKE_INFO_NOTFOUND_TEXT:-user not found}"; return "${FAKE_INFO_NOTFOUND_RC:-1}"; fi
  if [ -n "${FAKE_INFO_NOJSON:-}" ]; then echo "Nextcloud is in maintenance mode, no apps are loaded."; return 0; fi
  if [ -n "${FAKE_INFO_NOISE:-}" ]; then echo "PHP Warning:  Undefined array key in /var/www/html/lib/private/x.php on line 1"; fi
  if [ "${fa_output}" = json ]; then
    if [ -n "${FAKE_INFO_NO_UID:-}" ]; then jq -c 'del(.user_id)' "${f}"; else jq -c . "${f}"; fi
  else
    jq -r 'to_entries[] | "  - \(.key): \(.value)"' "${f}"
  fi
}

fake_app_list() {
  case "${FAKE_ENCRYPTION:-}" in
    fail) echo "Could not list the apps."; return 1 ;;
    nojson) echo "Nextcloud is in maintenance mode, no apps are loaded."; return 0 ;;
    odd) echo '{"apps":[]}' ;;
    enabled) echo '{"enabled":{"files":"2.4.0","settings":"1.17.0","encryption":"3.0.1"},"disabled":{"admin_audit":"1.24.0"}}' ;;
    *) echo '{"enabled":{"files":"2.4.0","settings":"1.17.0"},"disabled":{"admin_audit":"1.24.0","encryption":"3.0.1"}}' ;;
  esac
}

fake_config_app_get() {
  local app="" key="" arg
  for arg in "$@"; do
    case "${arg}" in
      -*) ;;
      *) if [ -z "${app}" ]; then app="${arg}"; elif [ -z "${key}" ]; then key="${arg}"; fi ;;
    esac
  done
  if [ "${app}" != encryption ] || [ "${key}" != useMasterKey ]; then return 1; fi
  case "${FAKE_MASTER_KEY:-}" in
    '') return 1 ;;
    blank) echo ;;
    fail) echo "Could not read the setting."; return 2 ;;
    exception) echo "In ExceptionConverter.php line 117: An exception occurred in the driver: SQLSTATE[HY000] [2002] Connection refused" >&2; return 1 ;;
    *) printf '%s\n' "${FAKE_MASTER_KEY}" ;;
  esac
}

fake_user_resetpassword() {
  nc_fake_args "$@" || return 1
  local uid="${fa_pos[0]-}"
  nc_fake_password_saved user:resetpassword
  if ! nc_fake_resolve "${uid}" > /dev/null; then echo "User does not exist"; return 1; fi
  nc_fake_password_ok || return 1
  echo "Successfully reset password for ${uid}"
}
LIB

# nc-tokens-lib.sh: a stand-in for Nextcloud's app-password table and for group:list (share-as-admin.sh). The
# handlers that install_share_fakes writes source it after nc-users-lib.sh. The table is $FAKE_TOKENS, one row
# per token: id, uid, name and secret, tab-separated. Nothing but the add handler's stdout and this table ever
# holds a secret: list leaves it out, as the real command does, and no handler puts one in an argument. The fake
# add always makes the same token, the 72 letters and digits in nc_fake_token. Knobs (empty is off):
#   FAKE_TOKEN_ADD_FAIL     user:auth-tokens:add fails (exit 1) and makes nothing; "echo" and "echo-err" put the token in its message, on stdout and on stderr
#   FAKE_TOKEN_ADD_NOTOKEN  add makes the token but prints no token line
#   FAKE_TOKEN_ADD_DECOY    add prints a 72-character line before the real token, as a notice that looks like one
#   FAKE_TOKEN_ADD_TRAILER  add prints a 72-character line of punctuation after the token (not a token: no letters or digits)
#   FAKE_TOKEN_ADD_SHORT    add prints a 71-character token line
#   FAKE_TOKEN_ADD_KILL     add sends this signal to the script (PID in $FAKE_PIDFILE) once the token exists
#   FAKE_TOKEN_LIST_FAIL    list fails (exit 1)
#   FAKE_TOKEN_LIST_FAIL_FROM=N  list fails (exit 1) from its Nth call of the run on
#   FAKE_TOKEN_LIST_NOJSON  list exits 0 and prints a notice instead of JSON
#   FAKE_TOKEN_LIST_NOISE   list prints a PHP warning line before the JSON
#   FAKE_TOKEN_DELETE_FAIL  delete fails (exit 1) and removes nothing
#   FAKE_TOKEN_DELETE_NOOP  delete exits 0 and removes nothing (occ exits 0 for an id it does not find)
#   FAKE_TOKEN_DELETE_KILL  delete does its work, then sends this signal to the script
#   FAKE_TOKEN_DELETE_DELAY_<n>  the n-th delete of the case (1, 2, ...) waits this many seconds before it removes anything
#   FAKE_GROUP_LIST_FAIL    group:list fails (exit 1); "json" prints a list with the admin in it first
#   FAKE_GROUP_LIST_NOJSON  group:list exits 0 and prints a notice instead of JSON
tokens_lib="${work}/nc-tokens-lib.sh"
cat > "${tokens_lib}" <<'LIB'
nc_fake_token='JvWiVv3jsB9qKdVHW37ZrPxZT6L7Wgxa9GagUFxUbvRFdbpufkvkKeE2xfskKeR6iIU0C0Fu'
nc_fake_decoy='zNycqXMX9DGJWc401hQvJEgeyz2mCyRaq6LUopYL0lb9Qfgh8SlbiS5FNNaQDG1Wk1WIsICV'

# nc_tok_args ARG...: sets ta_name, ta_output and ta_pos[] the way occ reads the user:auth-tokens:* arguments
nc_tok_args() {
  ta_name=""; ta_output=""; ta_pos=()
  local past=0
  while [ "$#" -gt 0 ]; do
    if [ "${past}" -eq 1 ]; then ta_pos+=("$1"); shift; continue; fi
    case "$1" in
      --) past=1 ;;
      --name=*) ta_name="${1#*=}" ;;
      --output=*) ta_output="${1#*=}" ;;
      --password-from-env | --cancel-wipe) ;;
      -*) echo "The \"$1\" option does not exist."; return 1 ;;
      *) ta_pos+=("$1") ;;
    esac
    shift
  done
}

# nc_tok_canonical UID: the uid as the account store spells it (Nextcloud finds accounts without regard to case)
nc_tok_canonical() { jq -r '.user_id' "$(nc_fake_file "$1")"; }

fake_user_auth_tokens_add() {
  nc_tok_args "$@" || return 1
  local uid="${ta_pos[0]-}" f id max=0 tid rest
  f="$(nc_fake_file "${uid}")"
  if [ "${FAKE_TOKEN_ADD_FAIL:-}" = echo ]; then echo "Could not store the app password ${nc_fake_token}."; return 1; fi
  if [ "${FAKE_TOKEN_ADD_FAIL:-}" = echo-err ]; then echo "Could not store the app password ${nc_fake_token}." >&2; return 1; fi
  if [ -n "${FAKE_TOKEN_ADD_FAIL:-}" ]; then echo "Could not make the app password."; return 1; fi
  if [ ! -e "${f}" ]; then echo "Account does not exist"; return 1; fi
  if [ -f "${FAKE_TOKENS}" ]; then
    while IFS=$'\t' read -r tid rest; do
      if [ "${tid}" -gt "${max}" ] 2> /dev/null; then max="${tid}"; fi
    done < "${FAKE_TOKENS}"
  fi
  id=$((max + 1))
  printf '%s\t%s\t%s\t%s\n' "${id}" "$(nc_tok_canonical "${uid}")" "${ta_name:-cli}" "${nc_fake_token}" >> "${FAKE_TOKENS}"
  if [ -n "${FAKE_TOKEN_ADD_KILL:-}" ]; then kill -s "${FAKE_TOKEN_ADD_KILL}" "$(< "${FAKE_PIDFILE}")"; fi
  echo "No password provided. The generated app password will therefore have limited capabilities. Any operation that requires the login password will fail."
  if [ -n "${FAKE_TOKEN_ADD_DECOY:-}" ]; then echo "${nc_fake_decoy}"; fi
  echo "app password:"
  if [ -n "${FAKE_TOKEN_ADD_NOTOKEN:-}" ]; then return 0; fi
  if [ -n "${FAKE_TOKEN_ADD_SHORT:-}" ]; then echo "${nc_fake_token:1}"; else echo "${nc_fake_token}"; fi
  if [ -n "${FAKE_TOKEN_ADD_TRAILER:-}" ]; then printf '#%.0s' {1..72}; echo; fi
}

fake_user_auth_tokens_list() {
  nc_tok_args "$@" || return 1
  local uid="${ta_pos[0]-}"
  if [ ! -e "$(nc_fake_file "${uid}")" ]; then echo "user not found"; return 1; fi
  if [ -n "${FAKE_TOKEN_LIST_FAIL:-}" ]; then echo "Could not list the tokens."; return 1; fi
  if [ -n "${FAKE_TOKEN_LIST_FAIL_FROM:-}" ]; then
    local calls=0
    if [ -f "${FAKE_TOKENS}.lists" ]; then read -r calls < "${FAKE_TOKENS}.lists"; fi
    calls=$((calls + 1))
    echo "${calls}" > "${FAKE_TOKENS}.lists"
    if [ "${calls}" -ge "${FAKE_TOKEN_LIST_FAIL_FROM}" ]; then echo "Could not list the tokens."; return 1; fi
  fi
  if [ -n "${FAKE_TOKEN_LIST_NOJSON:-}" ]; then echo "Nextcloud is in maintenance mode, no apps are loaded."; return 0; fi
  if [ -n "${FAKE_TOKEN_LIST_NOISE:-}" ]; then echo "PHP Warning:  Undefined array key in /var/www/html/lib/private/x.php on line 1"; fi
  if [ "${ta_output}" != json ]; then echo "(a table, which the scripts do not read)"; return 0; fi
  if [ ! -s "${FAKE_TOKENS}" ]; then echo '[]'; return 0; fi
  # the secret column (field 4) is never read
  jq -Rcn --arg uid "$(nc_tok_canonical "${uid}")" '[inputs | split("\t") | select((.[1] | ascii_downcase) == ($uid | ascii_downcase))
    | {id: (.[0] | tonumber), name: .[2], lastActivity: 1792808970, type: 1, scope: {filesystem: true}}]' < "${FAKE_TOKENS}"
}

fake_user_auth_tokens_delete() {
  nc_tok_args "$@" || return 1
  local uid="${ta_pos[0]-}" id="${ta_pos[1]-}" tid tuid tname tsecret row rows=()
  if [ -n "${FAKE_TOKEN_DELETE_FAIL:-}" ]; then echo "Could not delete the token."; return 1; fi
  if [ -n "${FAKE_TOKEN_DELETE_NOOP:-}" ] || [ ! -f "${FAKE_TOKENS}" ]; then return 0; fi
  local calls=0 delay_var
  if [ -f "${FAKE_TOKENS}.deletes" ]; then read -r calls < "${FAKE_TOKENS}.deletes"; fi
  calls=$((calls + 1))
  echo "${calls}" > "${FAKE_TOKENS}.deletes"
  delay_var="FAKE_TOKEN_DELETE_DELAY_${calls}"
  if [ -n "${!delay_var:-}" ]; then sleep "${!delay_var}"; fi
  while IFS=$'\t' read -r tid tuid tname tsecret; do
    if [ "${tid}" = "${id}" ] && [ "${tuid,,}" = "${uid,,}" ]; then continue; fi
    rows+=("${tid}"$'\t'"${tuid}"$'\t'"${tname}"$'\t'"${tsecret}")
  done < "${FAKE_TOKENS}"
  : > "${FAKE_TOKENS}"
  for row in ${rows[@]+"${rows[@]}"}; do printf '%s\n' "${row}" >> "${FAKE_TOKENS}"; done
  if [ -n "${FAKE_TOKEN_DELETE_KILL:-}" ]; then kill -s "${FAKE_TOKEN_DELETE_KILL}" "$(< "${FAKE_PIDFILE}")"; fi
}

# group:list [--output=json] [SEARCH]: every group of the account store with its members, those whose name
# contains SEARCH (in any case, as the real search does). Like PHP's json_encode, no match is [] and not {}.
fake_group_list() {
  local q="" arg
  for arg in "$@"; do
    case "${arg}" in
      -*) ;;
      *) q="${arg}" ;;
    esac
  done
  if [ "${FAKE_GROUP_LIST_FAIL:-}" = json ]; then echo '{"admin":["admin"]}'; return 1; fi
  if [ -n "${FAKE_GROUP_LIST_FAIL:-}" ]; then echo "Could not list the groups."; return 1; fi
  if [ -n "${FAKE_GROUP_LIST_NOJSON:-}" ]; then echo "Nextcloud is in maintenance mode, no apps are loaded."; return 0; fi
  local files=("${FAKE_USERS}"/*)
  if [ ! -e "${files[0]}" ]; then echo '[]'; return 0; fi
  jq -sc --arg q "${q}" '[.[] | .user_id as $u | (.groups // [])[] | {g: ., u: $u}] | group_by(.g)
    | map({key: .[0].g, value: [.[].u]}) | from_entries
    | with_entries(select(.key | ascii_downcase | contains($q | ascii_downcase)))
    | if length == 0 then [] else . end' "${files[@]}"
}
LIB

# ---------------------------------------------------------------------------
# The fakes of the verify-health.sh cases. Their knobs are FAKE_HEALTH_* shell variables; new_case resets them all.
# ---------------------------------------------------------------------------

# nc-health-lib.sh: what the fake occ answers for verify-health.sh (status, config:app:get, config:system:get,
# setupchecks), and the logic of the fake df and timeout. The handlers that install_health_fakes writes source it.
# The state of the fake instance is FAKE_HEALTH_NC_STATE: ok (default), maintenance, upgrade (an upgrade is pending),
# upgrading (an upgrade is running: maintenance mode on and the upgrade still pending) or dbdown (the database does not
# answer: only the web pages see it). The same state shapes the fake curl's answers.
# Knobs (empty is off, "unset" and the like are words, not empty values):
#   FAKE_HEALTH_STATUS_FAIL / _NOISE / _RAW / _RC / FAKE_HEALTH_INSTALLED   occ status: exits 255; prints a PHP warning first;
#                      prints this text instead of the JSON; exits with this code after its answer; "false" makes installed false
#   FAKE_HEALTH_LASTCRON_AGE   seconds since the last cron run (default 120), or unset (the key is not stored: exit 1, no
#                      output), empty (a stored empty string), zero, garbage, silent (exit 3, nothing printed), fail (an
#                      exception, as with the database down)
#   FAKE_HEALTH_LASTCRON_RAW   prints this text as the value of lastcron
#   FAKE_HEALTH_SCALAR_NOISE   the config reads print a stray line with their answer: before (or 1), after, or text (a line that
#                      is no PHP warning); FAKE_HEALTH_SCALAR_NOISE_LINE is the stray line (default: a PHP warning)
#   FAKE_HEALTH_DATE_RAW       what `date +%s` prints in the container
#   FAKE_HEALTH_BGMODE         backgroundjobs_mode: its value (default cron), or unset, empty, fail
#   FAKE_HEALTH_URL            overwrite.cli.url: its value (default https://abc.clouve.app), or unset, fail
#   FAKE_HEALTH_SETUPCHECKS    clean (default: three info results), warning (one warning named PHP memory limit and the
#                      three info), error, many (12 warnings), longnames (three warnings with 100-character names), success (no info, exit 0), nojson, fail, noise, unnamed, empty
#   FAKE_HEALTH_DF_WWW / _MYSQL   the use of /var/www/html and /var/lib/mysql in percent, or error, garbage, padded (42%, the
#                      numbers with leading zeros), huge (numbers of 20 digits)
#   FAKE_HEALTH_TIMEOUT        set: the fake timeout logs its calls; its value, a word, makes the call that has it time out,
#                      with exit 124 or FAKE_HEALTH_TIMEOUT_RC (137 is what timeout -k gives when it had to send KILL)
nc_health_lib="${work}/nc-health-lib.sh"
cat > "${nc_health_lib}" <<'LIB'
# fh_now: the container's clock (the health cases fix FAKE_NOW as @<epoch seconds>)
fh_now() { printf '%s' "${FAKE_NOW#@}"; }

# fh_notice: the notices occ's loader writes to stderr in maintenance mode and with an upgrade pending
# (lib/private/Console/Application.php, v35.0.2). occ.sh passes --no-warnings, which sets the output to quiet before the loader
# writes them, so a real run through occ.sh does not show them. The fake prints them anyway, to show that the script filters them
# out in case that changes.
fh_notice() {
  case "${FAKE_HEALTH_NC_STATE:-ok}" in
    maintenance)
      echo "Nextcloud is in maintenance mode, no apps are loaded." >&2
      echo "Commands provided by apps are unavailable." >&2 ;;
    upgrade | upgrading)
      echo "Nextcloud or one of the apps require upgrade - only a limited number of commands are available" >&2
      echo "You may use your browser or the occ upgrade command to do the upgrade" >&2 ;;
  esac
}

fake_health_status() {
  if [ -n "${FAKE_HEALTH_STATUS_FAIL:-}" ]; then
    echo "Output that came before the failure"
    echo "PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted" >&2
    echo "PHP Stack trace:" >&2
    return 255
  fi
  if [ -n "${FAKE_HEALTH_STATUS_NOISE:-}" ]; then echo 'PHP Warning:  Undefined array key "x" in /var/www/html/lib/private/x.php on line 1'; fi
  if [ -n "${FAKE_HEALTH_STATUS_RAW+x}" ]; then printf '%s\n' "${FAKE_HEALTH_STATUS_RAW}"; return "${FAKE_HEALTH_STATUS_RC:-0}"; fi
  local installed=true maintenance=false upgrade=false
  if [ "${FAKE_HEALTH_INSTALLED:-}" = false ]; then installed=false; fi
  case "${FAKE_HEALTH_NC_STATE:-ok}" in maintenance) maintenance=true ;; upgrade) upgrade=true ;; upgrading) maintenance=true; upgrade=true ;; esac
  printf '{"installed":%s,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","maintenance":%s,"needsDbUpgrade":%s,"productname":"Nextcloud","extendedSupport":false}\n' \
    "${installed}" "${maintenance}" "${upgrade}"
  return "${FAKE_HEALTH_STATUS_RC:-0}"
}

# fh_noisy COMMAND ARGS...: runs a config read, and with FAKE_HEALTH_SCALAR_NOISE puts a stray line on stdout next to its answer
fh_noisy() {
  local noise="${FAKE_HEALTH_SCALAR_NOISE_LINE-PHP Warning:  Undefined array key \"x\" in /var/www/html/lib/private/x.php on line 1}" code
  case "${FAKE_HEALTH_SCALAR_NOISE:-}" in before | 1) echo "${noise}" ;; text) echo "Nextcloud says hello" ;; esac
  "$@"
  code=$?
  case "${FAKE_HEALTH_SCALAR_NOISE:-}" in after) echo "${noise}" ;; esac
  return "${code}"
}

fake_health_config_app_get() { fh_noisy fh_config_app_get "$@"; }
fake_health_config_system_get() { fh_noisy fh_config_system_get "$@"; }

fh_config_app_get() {
  fh_notice
  local app="" key="" arg age mode
  for arg in "$@"; do
    case "${arg}" in
      -*) ;;
      *) if [ -z "${app}" ]; then app="${arg}"; elif [ -z "${key}" ]; then key="${arg}"; fi ;;
    esac
  done
  case "${app} ${key}" in
    "core lastcron")
      if [ -n "${FAKE_HEALTH_LASTCRON_RAW+x}" ]; then printf '%s\n' "${FAKE_HEALTH_LASTCRON_RAW}"; return 0; fi
      age="${FAKE_HEALTH_LASTCRON_AGE-120}"
      case "${age}" in
        unset) return 1 ;;                                  # the real command: exit 1 and no output for a key that is not stored
        empty) echo ;;
        zero) echo 0 ;;
        garbage) echo "yesterday" ;;
        silent) return 3 ;;                                 # fails and says nothing
        fail) echo "In Connection.php line 76: SQLSTATE[HY000] [2002] Connection refused" >&2; return 1 ;;
        *) echo $(($(fh_now) - age)) ;;
      esac ;;
    "core backgroundjobs_mode")
      mode="${FAKE_HEALTH_BGMODE-cron}"
      case "${mode}" in
        unset) return 1 ;;
        empty) echo ;;
        fail) echo "In Connection.php line 76: SQLSTATE[HY000] [2002] Connection refused" >&2; return 1 ;;
        *) printf '%s\n' "${mode}" ;;
      esac ;;
    *) return 1 ;;
  esac
}

fh_config_system_get() {
  fh_notice
  local value="${FAKE_HEALTH_URL-https://abc.clouve.app}"
  if [ "$1" != overwrite.cli.url ]; then return 1; fi
  case "${value}" in
    unset) return 1 ;;
    fail) echo "In Connection.php line 76: SQLSTATE[HY000] [2002] Connection refused" >&2; return 1 ;;
    *) printf '%s\n' "${value}" ;;
  esac
}

# fh_rows: the setup results as category|name|severity rows
fh_rows() {
  printf '%s\n' 'database|Database version|success' 'network|Internet connectivity|success' 'security|HTTP headers|success' 'system|Maintenance window start|success'
  case "${FAKE_HEALTH_SETUPCHECKS:-clean}" in
    clean | noise) printf '%s\n' 'system|Email test|info' 'security|Second factor configuration|info' 'system|Default phone region|info' ;;
    warning) printf '%s\n' 'php|PHP memory limit|warning' 'system|Email test|info' 'security|Second factor configuration|info' 'system|Default phone region|info' ;;
    error) printf '%s\n' 'system|Cron last run|error' 'system|Mimetype migrations available|warning' 'system|Email test|info' ;;
    many) local i; for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf '%s\n' "system|Warning check ${i}|warning"; done ;;
    unnamed) printf '%s\n' 'php|-|warning' ;;
    longnames) local i; for i in a b c; do printf '%s\n' "system|Long name ${i} $(printf 'x%.0s' {1..90})|warning"; done ;;
    success | empty) ;;
  esac
}

fake_health_setupchecks() {
  case "${FAKE_HEALTH_SETUPCHECKS:-clean}" in
    nojson) echo "Nextcloud is not installed - only a limited number of commands are available"; return 1 ;;
    fail) echo "PHP Fatal error:  Uncaught Error: Call to undefined function" >&2; return 255 ;;
    empty) echo '{}'; return 0 ;;
    noise) echo "PHP Warning:  Undefined array key in /var/www/html/lib/private/x.php on line 1" ;;
  esac
  # a result with no name is how a check that sets none shows up: the key is the class
  fh_rows | jq -Rnc '[inputs | split("|")] | reduce .[] as $r ({};
      .[$r[0]]["OCA\\Fake\\SetupChecks\\" + (if $r[1] == "-" then "Unnamed" else ($r[1] | gsub("[^A-Za-z0-9]"; "")) end)] =
        {name: (if $r[1] == "-" then null else $r[1] end), severity: $r[2], description: null, descriptionParameters: null, linkToDoc: null})'
  # occ exits 1 when any result is not success, info included
  if [ "${FAKE_HEALTH_SETUPCHECKS:-clean}" = success ] || [ "${FAKE_HEALTH_SETUPCHECKS:-clean}" = empty ]; then return 0; fi
  return 1
}

# fake_health_df ARGS...: `df -P PATH` for the two paths the health cases care about; exits 99 when it does not handle the call
fake_health_df() {
  local path val total used avail
  if [ "$#" -ne 2 ] || [ "$1" != -P ]; then return 99; fi
  path="$2"; unmap_var path
  case "${path}" in
    /var/www/html) val="${FAKE_HEALTH_DF_WWW-}"; total=20971520 ;;
    /var/lib/mysql) val="${FAKE_HEALTH_DF_MYSQL-}"; total=10485760 ;;
    *) return 99 ;;
  esac
  if [ -z "${val}" ]; then return 99; fi
  fake_log_args df "$@"
  case "${val}" in
    error) echo "df: ${path}: No such file or directory" >&2; return 1 ;;
    garbage) echo "df: cannot read table of mounted file systems"; return 0 ;;
    padded | huge) val=42 ;;
  esac
  used=$((total * val / 100))
  avail=$((total - used))
  printf 'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
  case "${FAKE_HEALTH_DF_WWW-}${FAKE_HEALTH_DF_MYSQL-}" in
    *padded*) printf '/dev/vdb1       %010d  %010d  %010d      %s%% %s\n' "${total}" "${used}" "${avail}" "${val}" "${path}"; return 0 ;;
    *huge*) printf '/dev/vdb1       %s  %s  99999999999999999999      %s%% %s\n' "${total}" "${used}" "${val}" "${path}"; return 0 ;;
  esac
  printf '/dev/vdb1         %s  %s  %s      %s%% %s\n' "${total}" "${used}" "${avail}" "${val}" "${path}"
}

# fake_health_timeout ARGS...: logs the call when FAKE_HEALTH_TIMEOUT is set, and exits 124 (what timeout does when the
# command runs out of time; FAKE_HEALTH_TIMEOUT_RC=137 is what timeout -k gives when the command ignored TERM and was killed)
# when the call has the word FAKE_HEALTH_TIMEOUT holds
fake_health_timeout() {
  if [ -z "${FAKE_HEALTH_TIMEOUT+x}" ]; then return 0; fi
  fake_log_args timeout "$@"
  case " $* " in
    *" ${FAKE_HEALTH_TIMEOUT} "*) if [ -n "${FAKE_HEALTH_TIMEOUT}" ]; then exit "${FAKE_HEALTH_TIMEOUT_RC:-124}"; fi ;;
  esac
}
LIB

# df: the real df, except for the two paths the health cases give a use for
real_df="$(command -v df)"
fake df <<FAKE
#!/bin/bash
. "\${FAKE_LIB}"
. "\${FAKE_LIB%/*}/nc-health-lib.sh"
# FAKE_DF_AVAIL: the free bytes \`df -PB1 PATH\` gives (the backup.sh cases)
if [ -n "\${FAKE_DF_AVAIL:-}" ] && [ "\${1:-}" = -PB1 ]; then
  fake_log_args df "\$@"
  printf 'Filesystem        1-blocks       Used    Available Capacity Mounted on\n'
  printf '/dev/vdb1      21474836480 1073741824 %s       5%% /var/www/html\n' "\${FAKE_DF_AVAIL}"
  exit 0
fi
fake_health_df "\$@"
code=\$?
if [ "\${code}" -ne 99 ]; then exit "\${code}"; fi
exec "${real_df}" "\$@"
FAKE

# timeout: the real timeout. With FAKE_HEALTH_TIMEOUT set it also logs the call, and a call that has the word FAKE_HEALTH_TIMEOUT
# holds times out at once (exit 124), so a case does not wait 180 seconds to see what the script does about it.
real_timeout="$(command -v timeout)"
fake timeout <<FAKE
#!/bin/bash
. "\${FAKE_LIB}"
. "\${FAKE_LIB%/*}/nc-health-lib.sh"
fake_health_timeout "\$@"
exec "${real_timeout}" "\$@"
FAKE

# mysql: the client verify-health.sh asks `SELECT 1` with. FAKE_HEALTH_MYSQL_FLAVOUR is mysql8 (default: Oracle's 8.x, as on the
# agent) or mariadb (Debian's); --help lists the flags that dialect knows, from the real clients, and a flag of the other dialect
# is refused as the real one refuses it. A call is accepted only as `--no-defaults -h $NEXTCLOUD_DB_HOST -u $NEXTCLOUD_DB_USER
# $NEXTCLOUD_DB_NAME <TLS off> -N -e 'SELECT 1'` with the password in MYSQL_PWD and nowhere on the command line. --no-defaults has
# to be the first argument, as for the real client; without it a `password=` in ~/.my.cnf beats MYSQL_PWD, as it does for the real
# client. The password it wants is read from the file FAKE_HEALTH_DB_PW_FILE, so no environment holds it. FAKE_HEALTH_MYSQL picks the answer: ok
# (default), down, denied, wrong (prints 2), empty, echo-pw (an error that repeats the password it was given), nonsql
# (an error with no ERROR in front).
fake mysql <<'FAKE'
#!/bin/bash
. "${FAKE_LIB}"
flavour="${FAKE_HEALTH_MYSQL_FLAVOUR:-mysql8}"
args=("$@")
no_defaults=0
if [ "${1:-}" = --no-defaults ]; then no_defaults=1; shift; fi
if [ "${1:-}" = --help ]; then
  fake_log_args mysql "${args[@]}"
  case "${flavour}" in
    mysql8) cat <<'HELP'
mysql  Ver 8.0.46 for Linux on x86_64 (MySQL Community Server - GPL)
  --get-server-public-key
                      Get server public key
  --ssl-mode=name     SSL connection mode.
  --ssl-ca=name       CA file in PEM format.
HELP
      ;;
    mariadb) cat <<'HELP'
mariadb from 11.8.3-MariaDB, client 15.2 for debian-linux-gnu (x86_64)
  --ssl               Enable SSL for connection (automatically enabled with
                      other flags).
                      (Defaults to on; use --skip-ssl to disable.)
  --ssl-ca=name       CA file in PEM format (check OpenSSL docs, implies
                      --ssl).
HELP
      ;;
  esac
  exit 0
fi
want=""
if [ -r "${FAKE_HEALTH_DB_PW_FILE:-}" ]; then IFS= read -r -d '' want < "${FAKE_HEALTH_DB_PW_FILE}"; fi
for a in "${args[@]}"; do
  case "${a}" in
    *"${want:-@@no password@@}"*) fake_log "mysql <the password is on the command line>"; echo "fake mysql: the password is on the command line" >&2; exit 2 ;;
  esac
done
fake_log_args mysql "${args[@]}"
fake_log "mysql-env MYSQL_PWD=$([ -n "${MYSQL_PWD+x}" ] && echo set || echo unset)"
# the MariaDB client, run under the old name, says so on stderr before anything else
if [ "${flavour}" = mariadb ]; then echo "mysql: Deprecated program name. It will be removed in a future release, use '/usr/bin/mariadb' instead" >&2; fi
# an option file's password beats MYSQL_PWD; --no-defaults, first, keeps the option files out
cnf_password=""
if [ "${no_defaults}" -eq 0 ] && [ -r "${HOME}/.my.cnf" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ^[[:space:]]*password[[:space:]]*=[[:space:]]*(.*)$ ]]; then cnf_password="${BASH_REMATCH[1]}"; fi
  done < "${HOME}/.my.cnf"
fi
given="${MYSQL_PWD-}"
if [ -n "${cnf_password}" ]; then given="${cnf_password}"; fi
host="" user="" db="" tls="" sql="" nflag=0 ctimeout=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h) host="${2:-}"; shift 2 ;;
    -u) user="${2:-}"; shift 2 ;;
    -N) nflag=1; shift ;;
    -e) sql="${2:-}"; shift 2 ;;
    --connect-timeout=*) ctimeout="${1#*=}"; shift ;;
    --ssl-mode=*)
      if [ "${flavour}" = mariadb ]; then echo "mysql: unknown variable '${1#--}'" >&2; exit 7; fi
      tls="$1"; shift ;;
    --skip-ssl)
      if [ "${flavour}" = mysql8 ]; then echo "mysql: [ERROR] unknown option '--skip-ssl'." >&2; exit 2; fi
      tls="$1"; shift ;;
    -*) echo "mysql: [ERROR] unknown option '$1'." >&2; exit 2 ;;
    *) if [ -n "${db}" ]; then echo "mysql: too many arguments" >&2; exit 2; fi; db="$1"; shift ;;
  esac
done
if [ -z "${tls}" ]; then echo "fake mysql: the script must switch TLS off (--ssl-mode=DISABLED or --skip-ssl)" >&2; exit 2; fi
if [ -n "${ctimeout}" ] && ! [[ "${ctimeout}" =~ ^[0-9]+$ ]]; then echo "mysql: --connect-timeout needs a number" >&2; exit 2; fi
if [ "${host}" != "${NEXTCLOUD_DB_HOST:-}" ]; then echo "ERROR 2005 (HY000): Unknown server host '${host}' (-2)" >&2; exit 1; fi
if [ "${given}" != "${want}" ] || [ "${user}" != "${NEXTCLOUD_DB_USER:-}" ] || [ "${db}" != "${NEXTCLOUD_DB_NAME:-}" ]; then
  echo "ERROR 1045 (28000): Access denied for user '${user}'@'10.0.3.7' (using password: $([ -n "${given}" ] && echo YES || echo NO))" >&2
  exit 1
fi
if [ "${sql}" != 'SELECT 1' ]; then echo "ERROR 1064 (42000): You have an error in your SQL syntax" >&2; exit 1; fi
case "${FAKE_HEALTH_MYSQL:-ok}" in
  down) echo "ERROR 2002 (HY000): Can't connect to server on '${host}' (115)" >&2; exit 1 ;;
  denied) echo "ERROR 1045 (28000): Access denied for user '${user}'@'10.0.3.7' (using password: YES)" >&2; exit 1 ;;
  echo-pw) echo "ERROR 1045 (28000): Access denied for user '${user}' (using password: YES), password ${MYSQL_PWD}" >&2; exit 1 ;;
  nonsql) echo "mysql: unable to connect: protocol error" >&2; exit 1 ;;     # an error that has no ERROR in front
  empty) exit 0 ;;
  wrong) if [ "${nflag}" -eq 0 ]; then echo 1; fi; echo 2; exit 0 ;;
esac
if [ "${nflag}" -eq 0 ]; then echo 1; fi        # in batch mode mysql prints the column name first unless -N is given
echo 1
FAKE

# valkey-cli: `valkey-cli -s <socket> ping`, the only call played. The answer is FAKE_HEALTH_VALKEY (default PONG), or down /
# loading, which fail as the real client does. The socket must be the one the image makes.
fake valkey-cli <<'FAKE'
#!/bin/bash
. "${FAKE_LIB}"
fake_log_args valkey-cli "$@"
if [ "$#" -ne 3 ] || [ "$1" != -s ] || [ "$3" != ping ]; then echo "fake valkey-cli: only 'valkey-cli -s <socket> ping' is played, got: $*" >&2; exit 2; fi
sock="$2"
unmap_var sock
if [ "${sock}" != /run/clouve/valkey/valkey.sock ]; then echo "Could not connect to Valkey at ${sock}: No such file or directory" >&2; exit 1; fi
case "${FAKE_HEALTH_VALKEY:-PONG}" in
  down) echo "Could not connect to Valkey at ${sock}: No such file or directory" >&2; exit 1 ;;
  loading) echo "LOADING Valkey is loading the dataset in memory" >&2; exit 1 ;;
  *) printf '%s\n' "${FAKE_HEALTH_VALKEY:-PONG}" ;;
esac
FAKE

# The probe's curl (FAKE_CURL_MODE=probe: the curl fake hands over to this): Nextcloud's two public pages, as
# verify-health.sh asks for them. Only `curl -q -s -m N --noproxy '*' -o FILE -w %{http_code} -H "Host: H" http://$NEXTCLOUD_HOST/PAGE` is
# played, PAGE being status.php or login. Whatever else is exit 2: a typo would be an error to the real curl too, and -q
# first and --noproxy '*' are what keep ~/.curlrc and a proxy variable out of a probe. A Host that is not in
# FAKE_HEALTH_TRUSTED (default: abc.clouve.app; localhost is always trusted) gets Nextcloud's 400. The rest follows
# FAKE_HEALTH_NC_STATE (ok, maintenance, upgrade, dbdown). Knobs: FAKE_HEALTH_STATUS_CODE / _BODY and FAKE_HEALTH_LOGIN_CODE
# replace the answers; FAKE_HEALTH_CURL_EXIT (6, 7 or 28) makes both calls fail as curl does, with status 000 and
# FAKE_HEALTH_CURL_EXIT_LOGIN only the login page; FAKE_HEALTH_KILL=<signal> sends that signal to the script (its PID is in
# $FAKE_HEALTH_PIDFILE, which the launcher of the kill cases writes) on the first call.
cat > "${work}/fake-curl-probe" <<'PROBE'
#!/bin/bash
. "${FAKE_LIB}"
bail() { echo "fake curl (probe): $*" >&2; exit 2; }
args=("$@")
[ "${1:-}" = -q ] || bail "the first argument must be -q, or curl reads ~/.curlrc and whatever it holds"
host_header="" url="" out="" fmt="" maxtime="" noproxy=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q | -s | -sS | -S) ;;
    --noproxy) [ "${2:-}" = '*' ] || bail "--noproxy must be '*', got '${2:-}'"; noproxy=1; shift ;;
    -m) maxtime="${2:-}"; shift ;;
    -o) out="${2:-}"; shift ;;
    -w) fmt="${2:-}"; shift ;;
    -H)
      [ -z "${host_header}" ] || bail "two headers: only the Host header is played"
      case "${2:-}" in 'Host: '?*) host_header="${2#Host: }" ;; *) bail "unexpected header '${2:-}'" ;; esac
      shift ;;
    -*) bail "unexpected option $1" ;;
    *) [ -z "${url}" ] || bail "two URLs: ${url} and $1"; url="$1" ;;
  esac
  shift
done
[ "${noproxy}" -eq 1 ] || bail "the probe must pass --noproxy '*', or a proxy variable catches it"
[[ "${maxtime}" =~ ^[0-9]+$ ]] || bail "the probe must pass -m <seconds>, or a dead host holds it for minutes"
[ -n "${out}" ] || bail "the probe must pass -o <file>"
[ "${fmt}" = '%{http_code}' ] || bail "the probe must pass -w '%{http_code}', got '${fmt}'"
[ -n "${host_header}" ] || bail "the probe must send a Host header"
page="${url#"http://${NEXTCLOUD_HOST}"}"
case "${page}" in /status.php | /login) ;; *) bail "unexpected URL ${url}" ;; esac
fake_log_args curl "${args[@]}"

if [ -n "${FAKE_HEALTH_KILL:-}" ] && [ ! -e "${FAKE_CALLS}.killed" ]; then
  : > "${FAKE_CALLS}.killed"
  kill -s "${FAKE_HEALTH_KILL}" "$(< "${FAKE_HEALTH_PIDFILE}")"
  sleep 2
  : > "${FAKE_CALLS}.probe-finished"       # a script that waited for this command has seen this file
  exit 0
fi

status_json() { printf '{"installed":true,"version":"35.0.2.2","versionstring":"35.0.2","edition":"","maintenance":%s,"needsDbUpgrade":%s,"productname":"Nextcloud","extendedSupport":false}' "$1" "$2"; }
case "${FAKE_HEALTH_NC_STATE:-ok}" in
  ok) status_code=200; status_body="$(status_json false false)"; login_code=200 ;;
  maintenance) status_code=200; status_body="$(status_json true false)"; login_code=503 ;;   # base.php: every page but status.php answers 503
  upgrade) status_code=200; status_body="$(status_json false true)"; login_code=200 ;;      # the update page
  upgrading) status_code=200; status_body="$(status_json true true)"; login_code=503 ;;
  dbdown) status_code=500; status_body=""; login_code=500 ;;
  *) bail "unknown FAKE_HEALTH_NC_STATE ${FAKE_HEALTH_NC_STATE}" ;;
esac
status_code="${FAKE_HEALTH_STATUS_CODE:-${status_code}}"
status_body="${FAKE_HEALTH_STATUS_BODY-${status_body}}"
login_code="${FAKE_HEALTH_LOGIN_CODE:-${login_code}}"
trusted=" ${FAKE_HEALTH_TRUSTED-abc.clouve.app} localhost "
if [[ "${trusted}" != *" ${host_header%%:*} "* ]]; then
  status_code=400; status_body='{"error": "Trusted domain error.", "code": 15}'; login_code=400
fi
case "${page}" in
  /status.php) code="${status_code}"; body="${status_body}"; curl_exit="${FAKE_HEALTH_CURL_EXIT:-}" ;;
  /login) code="${login_code}"; body="<html>login</html>"; curl_exit="${FAKE_HEALTH_CURL_EXIT_LOGIN:-${FAKE_HEALTH_CURL_EXIT:-}}" ;;
esac
if [ -n "${curl_exit}" ]; then fake_log "curl-probe page=${page} host=${host_header} code=000 curl_exit=${curl_exit}"
else fake_log "curl-probe page=${page} host=${host_header} code=${code}"; fi
if [ -n "${curl_exit}" ]; then
  [ "${out}" = /dev/null ] || : > "${out}"
  printf '%s' "${fmt//'%{http_code}'/000}"
  exit "${curl_exit}"
fi
[ "${out}" = /dev/null ] || printf '%s' "${body}" > "${out}"
printf '%s' "${fmt//'%{http_code}'/${code}}"
PROBE
chmod +x "${work}/fake-curl-probe"

# ---------------------------------------------------------------------------
# The fakes of the backup.sh and restore.sh cases. Those two scripts run inside the Nextcloud container as root, so these
# fakes play the container: occ (through the php fake's handlers), the PHP programs that read config.php, MariaDB's two
# clients, and id, chown, tar, gzip and df. Their knobs are FAKE_BR_* shell variables, plus FAKE_CFG and FAKE_DF_AVAIL (the
# brief's names); new_case resets them all. Outside those cases they change nothing: mariadb and mariadb-dump stay deny
# stubs, id is the real id, and tar, gzip and df are the real ones.
# ---------------------------------------------------------------------------

# The PHP programs (php [-d KEY=VALUE]... -r CODE -- MODE ARG...): the php fake hands them over to this. The code is not run
# (there is no PHP here; Plan 3 runs the real one): the fake answers by MODE, the way the programs' own comments describe
# them, and checks how it was called. Each call logs `php-r <mode> display_errors=<value> <args>`, and is refused unless
# display_errors=stderr, because this image's php prints its errors on stdout, where a caller that captures stdout would
# take them for the answer.
#   get FILE KEY       prints $FAKE_CFG/KEY as it is: exit 1 when there is no such file (config.php has no KEY), exit 2 when
#                      FILE can't be read. FAKE_BR_PHP_FAIL=get makes every read fail (exit 2)
#   managed FILE       restore.sh's copy of the settings the image manages, in PHP's serialize() form on stdout: a stand-in.
#                      It logs what its stdout is, since the real one holds the database password (php-r-managed stdout=...)
#   merge FROM         the new config.php on stdout: FROM (the backup's config.php) with a last line `// merged`. Like the real
#                      one it reads the kept settings on stdin, and logs only how many bytes came. FAKE_BR_PHP_FAIL=merge fails
#   code-version FILE  the code's version, from version.php: $FAKE_BR_CODE_VERSION (default 35.0.2.2)
cat > "${work}/fake-php-r" <<'PHPR'
#!/bin/bash
. "${FAKE_LIB}"
display=unset
code=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) case "${2:-}" in display_errors=*) display="${2#display_errors=}" ;; esac; shift 2 ;;
    -r) code="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "fake php: unexpected argument before --: $1" >&2; exit 1 ;;
  esac
done
mode="${1:-}"
[ "$#" -gt 0 ] && shift
fake_log_args "php-r ${mode} display_errors=${display}" "$@"
if [ -z "${code}" ]; then echo "fake php: no -r CODE" >&2; exit 1; fi
if [ "${display}" != stderr ]; then echo "fake php: a php -r whose output is read must run with -d display_errors=stderr" >&2; exit 1; fi
case "${mode}" in
  get)
    if [ "$#" -ne 2 ]; then echo "fake php: get FILE KEY" >&2; exit 64; fi
    if [ ! -r "$1" ]; then echo "cannot read $1" >&2; exit 2; fi
    if [ "${FAKE_BR_PHP_FAIL:-}" = get ]; then echo "cannot read $1: ParseError on line 3" >&2; exit 2; fi
    if [ ! -f "${FAKE_CFG}/$2" ]; then exit 1; fi
    cat "${FAKE_CFG}/$2"
    ;;
  managed)
    if [ "$#" -ne 1 ]; then echo "fake php: managed FILE" >&2; exit 64; fi
    if [ ! -r "$1" ]; then echo "cannot read $1" >&2; exit 2; fi
    if [ -f "/proc/$$/fd/1" ]; then fake_log "php-r-managed stdout=file mode=$(stat -L -c %a "/proc/$$/fd/1")"
    else fake_log "php-r-managed stdout=not-a-file"; fi
    printf 'a:2:{s:6:"dbname";s:9:"nextcloud";s:6:"dbhost";s:17:"nextcloud-mariadb";}'
    ;;
  merge)
    if [ "$#" -ne 1 ]; then echo "fake php: merge FROM" >&2; exit 64; fi
    if [ -f "/proc/$$/fd/0" ]; then fake_log "php-r-merge stdin=file mode=$(stat -L -c %a "/proc/$$/fd/0")"; else fake_log "php-r-merge stdin=not-a-file"; fi
    fake_log "php-r-merge stdin_bytes=$(wc -c | tr -d ' ')"
    if [ ! -r "$1" ]; then echo "cannot read $1" >&2; exit 2; fi
    if [ "${FAKE_BR_PHP_FAIL:-}" = merge ]; then echo "cannot read $1: ParseError on line 3" >&2; exit 2; fi
    cat "$1"
    printf '// merged\n'
    ;;
  code-version)
    if [ "$#" -ne 1 ]; then echo "fake php: code-version FILE" >&2; exit 64; fi
    if [ ! -r "$1" ]; then echo "cannot read $1" >&2; exit 2; fi
    printf '%s' "${FAKE_BR_CODE_VERSION:-35.0.2.2}"
    ;;
  *) echo "fake php: unknown program '${mode}'" >&2; exit 64 ;;
esac
PHPR
chmod +x "${work}/fake-php-r"

# nc-br-lib.sh: the fake Nextcloud of the backup.sh and restore.sh cases. The handlers that install_br_fakes writes source it,
# and so do the database, tar and gzip fakes. Maintenance mode is $FAKE_BR_STATE/maintenance (on or off, default off):
# status reports it, and as in Nextcloud 35 the commands of the apps (files:scan, groupfolders:scan) are not there while it
# is on. Each handler logs a `br-occ <command> maintenance=<on|off> backup-marker=... restore-marker=...` line, so a case can
# check what was true when a command ran. Knobs (empty is off):
#   FAKE_BR_CODE_VERSION  the code's version status reports (default 35.0.2.2; the versionstring drops the fourth part)
#   FAKE_BR_STATUS_FAIL   status prints a database error and exits 1 (the tables are gone, so occ can't start)
#   FAKE_BR_INSTALLED     "false": status says installed false
#   FAKE_BR_MAINT_FAIL    on or off: maintenance:mode --on or --off fails
#   FAKE_BR_UPGRADE_FAIL  upgrade fails (exit 5) and leaves maintenance mode on, as the Updater does
#   FAKE_BR_REPAIR_FAIL / FAKE_BR_FP_FAIL / FAKE_BR_SCAN_FAIL   maintenance:repair, maintenance:data-fingerprint, files:scan fail
#   FAKE_BR_CACHE_FAIL    memcache:redis:command fails, as occ does when Valkey refuses the command
#   FAKE_BR_GROUPFOLDERS  "enabled": app:list lists the groupfolders app among the enabled ones; FAKE_BR_APPLIST_FAIL: app:list fails
#   FAKE_BR_KILL_AT       a point: dump, import, drop, tar-<archive>, untar-<archive>, occ-<command>. There the fake sends
#                         FAKE_BR_KILL_SIG (default TERM) to the script, whose PID is in $FAKE_PIDFILE, then does its work
#   FAKE_BR_SWAP_AT       a point: occ-status, dump or import. There the fake runs the shell command $FAKE_BR_SWAP_CMD, as
#                         www-data would when it renames or swaps folders under a script that is running
br_lib="${work}/nc-br-lib.sh"
# the real flock, for br_markers: the fake flock on PATH does not lock a file it is given by name
printf 'br_real_flock=%q\n' "${real_flock}" > "${br_lib}"
cat >> "${br_lib}" <<'LIB'
br_maint() { local m=off; if [ -f "${FAKE_BR_STATE}/maintenance" ]; then read -r m < "${FAKE_BR_STATE}/maintenance"; fi; printf '%s' "${m}"; }
br_set_maint() { printf '%s\n' "$1" > "${FAKE_BR_STATE}/maintenance"; }

# br_markers: the two markers in the case's clouve-backups now. The backup marker is absent, or locked (a process holds an
# exclusive flock on it, as backup.sh does while it holds maintenance mode) or unlocked, then a colon and its first line;
# the restore marker is absent or present, then a colon and its first line. The lock is probed with the real flock -n on
# the file opened read-only, as the image's start-up does before it clears a leftover marker.
br_markers() {
  local d="${FAKE_WWW}/data/clouve-backups" b=absent r=absent line
  # opened read-only on a descriptor, as the image does: flock FILE would make a file that is not there
  if [ -e "${d}/BACKUP-IN-PROGRESS" ] && exec 7< "${d}/BACKUP-IN-PROGRESS"; then
    if "${br_real_flock}" -n 7; then b=unlocked; else b=locked; fi
    exec 7<&-
    line=""
    IFS= read -r line < "${d}/BACKUP-IN-PROGRESS" || true
    b+=":${line}"
  fi
  if [ -e "${d}/RESTORE-IN-PROGRESS" ]; then
    line=""
    IFS= read -r line < "${d}/RESTORE-IN-PROGRESS" || true
    r="present:${line}"
  fi
  printf 'backup-marker=%s restore-marker=%s' "${b}" "${r}"
}

# br_kill_at POINT: sends the signal to the script when FAKE_BR_KILL_AT names this point
br_kill_at() {
  if [ -n "${FAKE_BR_KILL_AT:-}" ] && [ "${FAKE_BR_KILL_AT}" = "$1" ]; then
    fake_log "br-kill at $1 with ${FAKE_BR_KILL_SIG:-TERM}"
    kill -s "${FAKE_BR_KILL_SIG:-TERM}" "$(< "${FAKE_PIDFILE}")"
  fi
}

# br_swap_at POINT: runs $FAKE_BR_SWAP_CMD when FAKE_BR_SWAP_AT names this point
br_swap_at() {
  if [ -n "${FAKE_BR_SWAP_AT:-}" ] && [ "${FAKE_BR_SWAP_AT}" = "$1" ]; then
    fake_log "br-swap at $1"
    eval "${FAKE_BR_SWAP_CMD:-}" || fake_log "br-swap at $1 failed"
  fi
}

# br_occ_log COMMAND...: the state line of an occ command
br_occ_log() { fake_log "br-occ $* maintenance=$(br_maint) $(br_markers)"; }

fake_br_status() {
  br_occ_log status
  br_swap_at occ-status
  br_kill_at occ-status
  if [ -n "${FAKE_BR_STATUS_FAIL:-}" ]; then
    echo "An unhandled exception has been thrown:"
    echo "Doctrine\\DBAL\\Exception\\TableNotFoundException: An exception occurred while executing a query: SQLSTATE[42S02]: Base table or view not found: 1146 Table 'nextcloud.oc_appconfig' doesn't exist"
    return 1
  fi
  local v="${FAKE_BR_CODE_VERSION:-35.0.2.2}" m=false
  if [ "$(br_maint)" = on ]; then m=true; fi
  printf '{"installed":%s,"version":"%s","versionstring":"%s","edition":"","maintenance":%s,"needsDbUpgrade":false,"productname":"Nextcloud","extendedSupport":false}\n' \
    "${FAKE_BR_INSTALLED:-true}" "${v}" "${v%.*}" "${m}"
}

fake_br_maintenance_mode() {
  br_occ_log maintenance:mode "$@"
  br_kill_at "occ-maintenance:mode${1:+ $1}"
  case "${1:-}" in
    --on)
      if [ "${FAKE_BR_MAINT_FAIL:-}" = on ]; then echo "Could not write the config file" >&2; return 1; fi
      if [ "$(br_maint)" = on ]; then echo "Maintenance mode already enabled"; else br_set_maint on; echo "Maintenance mode enabled"; fi ;;
    --off)
      if [ "${FAKE_BR_MAINT_FAIL:-}" = off ]; then echo "Could not write the config file" >&2; return 1; fi
      if [ "$(br_maint)" = off ]; then echo "Maintenance mode already disabled"; else br_set_maint off; echo "Maintenance mode disabled"; fi ;;
    *) echo "Maintenance mode is currently $([ "$(br_maint)" = on ] && echo enabled || echo disabled)" ;;
  esac
}

fake_br_upgrade() {
  local before
  before="$(br_maint)"
  br_occ_log upgrade
  br_kill_at occ-upgrade
  br_set_maint on
  if [ -n "${FAKE_BR_UPGRADE_FAIL:-}" ]; then echo "Update failed"; return 5; fi
  echo "Update successful"
  # The Updater turns maintenance mode off at its end only when it found it off (lib/private/Updater.php:82-124)
  if [ "${before}" = off ]; then br_set_maint off; fi
}

fake_br_db_add_missing_indices() { br_occ_log db:add-missing-indices; echo "Done."; }
fake_br_db_add_missing_columns() { br_occ_log db:add-missing-columns; echo "Done."; }
fake_br_db_add_missing_primary_keys() { br_occ_log db:add-missing-primary-keys; echo "Done."; }

fake_br_maintenance_repair() {
  local before
  before="$(br_maint)"
  br_occ_log maintenance:repair "$@"
  if [ -n "${FAKE_BR_REPAIR_FAIL:-}" ]; then echo "Repair step failed" >&2; return 1; fi
  # it turns maintenance mode on while it runs and puts back the value it found (core/Command/Maintenance/Repair.php)
  br_set_maint on
  echo " - Repair mime types"
  br_set_maint "${before}"
}

fake_br_maintenance_data_fingerprint() {
  br_occ_log maintenance:data-fingerprint
  br_kill_at occ-maintenance:data-fingerprint
  if [ -n "${FAKE_BR_FP_FAIL:-}" ]; then echo "Could not write the config file" >&2; return 1; fi
  echo "Updated data-fingerprint to 0f6a1c2d3e4b5a69788796a5b4c3d2e1"
}

fake_br_memcache_redis_command() {
  br_occ_log memcache:redis:command "$@"
  if [ -n "${FAKE_BR_CACHE_FAIL:-}" ]; then echo "Redis command failed"; return 1; fi
  echo "OK"
}

# br_app_command NAMESPACE: fails as occ does while maintenance mode is on: the apps and their commands are not loaded
br_app_command() {
  if [ "$(br_maint)" = on ]; then echo "There are no commands defined in the \"$1\" namespace." >&2; return 1; fi
}

fake_br_files_scan() {
  br_occ_log files:scan "$@"
  br_kill_at occ-files:scan
  br_app_command files || return 1
  if [ -n "${FAKE_BR_SCAN_FAIL:-}" ]; then echo "Exception during scan: An exception occurred in the driver"; return 1; fi
  echo "Starting scan for user 1 out of 1 (alice)"
}

fake_br_groupfolders_scan() {
  br_occ_log groupfolders:scan "$@"
  br_app_command groupfolders || return 1
  echo "Scanning Team folder 1"
}

fake_br_app_list() {
  br_occ_log app:list "$@"
  if [ -n "${FAKE_BR_APPLIST_FAIL:-}" ]; then echo "An exception occurred while listing the apps" >&2; return 1; fi
  if [ "${FAKE_BR_GROUPFOLDERS:-}" = enabled ]; then echo '{"enabled":{"calendar":"6.0.1","files":"2.4.0","groupfolders":"23.0.1"}}'
  else echo '{"enabled":{"calendar":"6.0.1","files":"2.4.0"}}'; fi
}
LIB

# nc-db-lib.sh: what the two fake MariaDB clients share. Knobs (empty is off):
#   FAKE_BR_DB            the cases that need a database switch the clients on; anywhere else they are the deny stubs they were
#   FAKE_BR_DB_SIZE       what the size query answers, in bytes (default 5242880)
#   FAKE_BR_TABLES / FAKE_BR_VIEWS   the base tables and the views of the schema (default "oc_appconfig oc_filecache oc_users" / none)
#   FAKE_BR_DUMP_FAIL / FAKE_BR_IMPORT_FAIL / FAKE_BR_DROP_FAIL   the dump, the import, the drops fail as MariaDB's clients do
#   FAKE_BR_DUMP_SLEEP    the dump takes this many seconds
#   FAKE_SQL_LOG          each statement the clients ran, one per line, and IMPORT <first line> for an import from stdin
db_lib="${work}/nc-db-lib.sh"
cat > "${db_lib}" <<'LIB'
# br_db_on TOOL ARGS...: the deny stub, unless a backup or restore case switched the clients on
br_db_on() {
  if [ -z "${FAKE_BR_DB:-}" ]; then
    fake_log_args "denied-$1" "${@:2}"
    echo "fake $1: this harness does not fake $1 outside the backup and restore cases, and the real one would reach beyond this machine" >&2
    exit 99
  fi
}

# br_db_cnf FILE: the client's options file, read the way MariaDB reads one (mysys/my_default.c: a # outside quotes starts a
# comment; quotes around a value go; inside it \" \' \\ \n \t \r \b \s are one character each): "mode=<file mode>
# dir=<its folder's mode> host=... port=... socket=... user=... password=ok|wrong|missing". The password is compared with
# $FAKE_CFG/dbpassword and never printed.
br_db_cnf() {
  python3 -I -c '
import os, sys
path, want_file = sys.argv[1], sys.argv[2]
st = os.stat(path)
mode = "%o" % (st.st_mode & 0o777)
dmode = "%o" % (os.stat(os.path.dirname(path) or ".").st_mode & 0o777)
want = open(want_file, encoding="utf-8", errors="surrogateescape").read() if os.path.exists(want_file) else ""
vals, section = {}, None
for raw in open(path, encoding="utf-8", errors="surrogateescape").read().split("\n"):
    line = raw.strip()
    if not line or line[0] in "#;":
        continue
    if line.startswith("["):
        section = line.strip("[]").strip()
        continue
    if section != "client":
        continue
    out, quote, esc = [], None, False
    for ch in line:
        if ch in "\x27\x22" and not esc:
            if quote is None:
                quote = ch
            elif quote == ch:
                quote = None
        if quote is None and ch == "#":
            break
        esc = quote is not None and ch == "\\" and not esc
        out.append(ch)
    line = "".join(out)
    if "=" not in line:
        vals[line.strip()] = ""
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip()
    if len(v) > 1 and v[0] in "\x27\x22" and v[0] == v[-1]:
        v = v[1:-1]
    res, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i != len(v) - 1:
            i += 1
            n = v[i]
            res.append({"n": "\n", "t": "\t", "r": "\r", "b": "\b", "s": " ", "\x22": "\x22", "\x27": "\x27", "\\": "\\"}.get(n, "\\" + n))
        else:
            res.append(c)
        i += 1
    vals[k] = "".join(res)
pw = vals.get("password")
state = "missing" if pw is None else ("ok" if pw == want else "wrong")
print("mode=%s dir=%s host=%s port=%s socket=%s user=%s password=%s" % (mode, dmode, vals.get("host", "-"), vals.get("port", "-"),
      vals.get("socket", "-"), vals.get("user", "-"), state))
' "$1" "${FAKE_CFG}/dbpassword"
}

# br_db_args TOOL ARGS...: what both clients check before anything else. --defaults-extra-file=FILE comes first, as MariaDB's
# clients require, and no argument holds the password. Sets cnf.
br_db_args() {
  local tool="$1" want="" a
  shift
  if [ -f "${FAKE_CFG}/dbpassword" ]; then want="$(cat "${FAKE_CFG}/dbpassword"; printf x)"; want="${want%x}"; fi
  for a in "$@"; do
    if [ -n "${want}" ] && [[ "${a}" == *"${want}"* ]]; then
      fake_log "${tool} <the database password is on the command line>"
      echo "fake ${tool}: the database password is on the command line" >&2
      exit 2
    fi
  done
  case "${1:-}" in
    --defaults-extra-file=?*) cnf="${1#--defaults-extra-file=}" ;;
    *) echo "fake ${tool}: --defaults-extra-file=FILE must be the first argument" >&2; exit 2 ;;
  esac
  if [ ! -r "${cnf}" ]; then echo "${tool}: Could not open required defaults file: ${cnf}" >&2; exit 2; fi
}

# br_sql_log TEXT: each statement of TEXT on a line of its own in $FAKE_SQL_LOG, spaces trimmed
br_sql_log() {
  local stmt
  while IFS= read -r -d ';' stmt || [ -n "${stmt}" ]; do
    stmt="$(printf '%s' "${stmt}" | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "${stmt}" ]; then printf '%s\n' "${stmt}" >> "${FAKE_SQL_LOG}"; fi
  done <<< "$1"
}
LIB

fake mariadb-dump <<'FAKE'
#!/bin/bash
# mariadb-dump --defaults-extra-file=FILE OPTIONS... DB: prints a stand-in dump of DB
. "${FAKE_LIB}"
. "${FAKE_LIB%/*}/nc-db-lib.sh"
. "${FAKE_LIB%/*}/nc-br-lib.sh"
br_db_on mariadb-dump "$@"
br_db_args mariadb-dump "$@"
fake_log_args mariadb-dump "$@"
fake_log "mariadb-dump-cnf $(br_db_cnf "${cnf}")"
fake_log "mariadb-dump-state maintenance=$(br_maint) $(br_markers)"
shift
need=" --skip-ssl --single-transaction --quick --hex-blob --default-character-set=utf8mb4 --routines --triggers "
db=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-ssl | --single-transaction | --quick | --hex-blob | --default-character-set=utf8mb4 | --routines | --triggers) need="${need/ $1 / }" ;;
    -B | --databases | -A | --all-databases) echo "fake mariadb-dump: $1 would tie the dump to its database name" >&2; exit 2 ;;
    -*) echo "mariadb-dump: unknown option '$1'" >&2; exit 7 ;;
    *) if [ -n "${db}" ]; then echo "fake mariadb-dump: one database only, got ${db} and $1" >&2; exit 2; fi; db="$1" ;;
  esac
  shift
done
if [ "${need}" != " " ]; then echo "fake mariadb-dump: missing option(s):${need% }" >&2; exit 2; fi
if [ "${db}" != "$(cat "${FAKE_CFG}/dbname")" ]; then echo "mariadb-dump: Got error: 1049: \"Unknown database '${db}'\" when selecting the database" >&2; exit 2; fi
br_swap_at dump
br_kill_at dump
if [ -n "${FAKE_BR_DUMP_SLEEP:-}" ]; then sleep "${FAKE_BR_DUMP_SLEEP}"; fi
if [ -n "${FAKE_BR_DUMP_FAIL:-}" ]; then
  echo "mariadb-dump: Got error: 2002: \"Can't connect to server on 'nextcloud-mariadb' (115)\" when trying to connect" >&2
  exit 2
fi
printf -- '-- dump of %s\n' "${db}"
printf 'CREATE TABLE `oc_users` (`uid` varchar(64) NOT NULL);\nINSERT INTO `oc_users` VALUES (0x616c696365);\n'
fake_log "mariadb-dump-finished"
FAKE

fake mariadb <<'FAKE'
#!/bin/bash
# mariadb --defaults-extra-file=FILE --skip-ssl [-N] [-B] [-e SQL] DB: runs SQL (records each statement and answers the size
# and table queries), or, with no -e, imports what stdin holds, as the real client does
. "${FAKE_LIB}"
. "${FAKE_LIB%/*}/nc-db-lib.sh"
. "${FAKE_LIB%/*}/nc-br-lib.sh"
br_db_on mariadb "$@"
br_db_args mariadb "$@"
fake_log_args mariadb "$@"
fake_log "mariadb-cnf $(br_db_cnf "${cnf}")"
shift
sql="" have_e=0 db="" tls=on
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-ssl) tls=off ;;
    -N | -B | --batch | --skip-column-names | --default-character-set=utf8mb4) ;;
    -e) have_e=1; sql="${2:-}"; shift ;;
    -*) echo "mariadb: unknown option '$1'" >&2; exit 7 ;;
    *) if [ -n "${db}" ]; then echo "mariadb: too many arguments" >&2; exit 1; fi; db="$1" ;;
  esac
  shift
done
# MariaDB's 11.4 and later clients check the server's certificate, and the server's is self-signed
if [ "${tls}" = on ]; then echo "ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain" >&2; exit 1; fi
if [ "${db}" != "$(cat "${FAKE_CFG}/dbname")" ]; then echo "ERROR 1049 (42000): Unknown database '${db}'" >&2; exit 1; fi
if [ "${have_e}" -eq 1 ]; then
  br_sql_log "${sql}"
  case "${sql}" in
    *'SUM(data_length'*'information_schema.tables'*) printf '%s\n' "${FAKE_BR_DB_SIZE:-5242880}" ;;
    *'information_schema.tables'*)
      for t in ${FAKE_BR_TABLES-oc_appconfig oc_filecache oc_users}; do printf '%s\tBASE TABLE\n' "${t}"; done
      for t in ${FAKE_BR_VIEWS:-}; do printf '%s\tVIEW\n' "${t}"; done ;;
    *DROP*)
      br_kill_at drop
      if [ -n "${FAKE_BR_DROP_FAIL:-}" ]; then echo "ERROR 1142 (42000): DROP command denied to user 'nextcloud'@'10.0.3.7'" >&2; exit 1; fi ;;
  esac
  exit 0
fi
first=""
IFS= read -r first || true
rest="$(wc -c | tr -d ' ')"
printf 'IMPORT %s\n' "${first}" >> "${FAKE_SQL_LOG}"
fake_log "mariadb-import first-line=${first} more-bytes=${rest} maintenance=$(br_maint) $(br_markers)"
br_swap_at import
br_kill_at import
if [ -n "${FAKE_BR_IMPORT_FAIL:-}" ]; then echo "ERROR 1050 (42S01) at line 2: Table 'oc_users' already exists" >&2; exit 1; fi
FAKE

# id: the real id, except that `id -u` is 0 in the backup and restore cases (FAKE_BR_ROOT), which run as root in the container
real_id="$(command -v id)"
fake id <<FAKE
#!/bin/bash
if [ -n "\${FAKE_BR_ROOT:-}" ] && [ "\$*" = -u ]; then echo 0; exit 0; fi
exec "${real_id}" "\$@"
FAKE

# chown: logs the call and changes nothing. The cases don't run as root, so a real chown to www-data would fail.
# FAKE_BR_CHOWN_FAIL makes it fail.
fake chown <<'FAKE'
#!/bin/bash
. "${FAKE_LIB}"
fake_log_args chown "$@"
if [ -n "${FAKE_BR_CHOWN_FAIL:-}" ]; then echo "chown: changing ownership: Operation not permitted" >&2; exit 1; fi
FAKE

# stat: the real stat. A case can't make a file of another user without root, so FAKE_BR_FOREIGN=<name> plays one: for
# a path whose last part is <name>, the owner stat prints (the format %u, or the second to last field of '%F %u %d:%i')
# is 4242. Every other call is the real stat, exec'd, so /proc/self is the real one's.
{ printf '#!/bin/bash\nreal_stat=%q\n' "$(command -v stat)"; cat <<'FAKE'
fmt=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[i]}" = -c ]; then fmt="${args[i + 1]:-}"; fi
done
path="${args[${#args[@]} - 1]:-}"
if [ -n "${FAKE_BR_FOREIGN:-}" ] && [ "${path##*/}" = "${FAKE_BR_FOREIGN}" ]; then
  case "${fmt}" in
    %u) echo 4242; exit 0 ;;
    '%F %u %d:%i')
      out="$("${real_stat}" "$@")" || exit
      kind="${out% * *}"
      printf '%s 4242 %s\n' "${kind}" "${out##* }"
      exit 0 ;;
  esac
fi
exec "${real_stat}" "$@"
FAKE
} | fake stat

# tar: the real GNU tar, logged. For the archive a call names (-c...f, -x...f or -t...f FILE; for -f -, the file on its stdin,
# or on its stdout for -c), it logs `tar-file <tar|untar|list> <file name>`. FAKE_BR_TAR_FAIL=<file name> makes writing or
# extracting it fail (exit 2, as tar does on a full disk or a short archive), FAKE_BR_TAR_CHANGED=<file name> makes a write
# end with exit 1 and tar's "file changed as we read it" once the archive is whole, and FAKE_BR_KILL_AT=tar-<name> or
# untar-<name> sends the signal first.
real_tar="$(command -v tar)"
fake tar <<FAKE
#!/bin/bash
. "\${FAKE_LIB}"
. "\${FAKE_LIB%/*}/nc-br-lib.sh"
fake_log_args tar "\$@"
op="" archive=""
case "\${1:-}" in
  -c*f) op=tar; archive="\${2:-}" ;;
  -x*f) op=untar; archive="\${2:-}" ;;
  -t*f) op=list; archive="\${2:-}" ;;
esac
if [ "\${archive}" = - ]; then
  if [ "\${op}" = tar ]; then archive="\$(readlink "/proc/\$\$/fd/1" 2> /dev/null)"; else archive="\$(readlink "/proc/\$\$/fd/0" 2> /dev/null)"; fi
fi
name="\${archive##*/}"
if [ -n "\${op}" ]; then fake_log "tar-file \${op} \${name}"; fi
if [ "\${op}" = tar ] || [ "\${op}" = untar ]; then
  br_kill_at "\${op}-\${name}"
  if [ -n "\${name}" ] && [ "\${FAKE_BR_TAR_FAIL:-}" = "\${name}" ]; then
    if [ "\${op}" = tar ]; then : > "\${archive}"; echo "tar: \${name}: Cannot write: No space left on device" >&2
    else echo "tar: Unexpected EOF in archive" >&2; fi
    exit 2
  fi
fi
"${real_tar}" "\$@"
code=\$?
if [ "\${code}" -eq 0 ] && [ "\${op}" = tar ] && [ -n "\${name}" ] && [ "\${FAKE_BR_TAR_CHANGED:-}" = "\${name}" ]; then
  echo "tar: ./nextcloud.log: file changed as we read it" >&2
  exit 1
fi
exit "\${code}"
FAKE

# gzip: the real gzip (tar -z runs it too). FAKE_BR_GZIP_T_FAIL makes gzip -t fail, as it does on a damaged archive.
real_gzip="$(command -v gzip)"
fake gzip <<FAKE
#!/bin/bash
if [ -n "\${FAKE_BR_GZIP_T_FAIL:-}" ] && [ "\${1:-}" = -t ]; then echo "gzip: \${2:-}: unexpected end of file" >&2; exit 1; fi
exec "${real_gzip}" "\$@"
FAKE

# ---------------------------------------------------------------------------
# 3. Helpers
# ---------------------------------------------------------------------------
declare -A default_env=()
cases=0
case_label=""
case_dir=""
rc=0
out=""
err=""

# new_case <label>: a clean container (empty folders, no answers, no logs) and
# the label that heads this case's ok/FAIL lines.
new_case() {
  case_label="$1"
  cases=$((cases + 1))
  case_dir="${work}/case-${cases}"
  mkdir -p "${case_dir}"/{www,run,occ,agent-home,ops-home,tmp}
  # Files in the ops user's home, so an unquoted * would expand to something.
  : > "${case_dir}/ops-home/glob1.txt"
  : > "${case_dir}/ops-home/glob2.txt"
  {
    FAKE_LIB="${fake_lib}"
    FAKE_CALLS="${case_dir}/calls"
    FAKE_OCC="${case_dir}/occ"
    FAKE_OCC_LOG="${case_dir}/occ.log"
    FAKE_WWW="${case_dir}/www"
    FAKE_RUN="${case_dir}/run"
    FAKE_OPS_HOME="${case_dir}/ops-home"
    FAKE_OPS_PASSWORD="${ops_pw}"
    FAKE_SECRET_CLOUVE_OPS_PASSWORD="${ops_pw}"
    FAKE_SSH_FAIL=""
    # The temp-password.sh cases': the fake account store, the argv log the shims write, the
    # agent's password folder the fake account store peeks into, and knobs (empty is off).
    # Resetting them here keeps one case's knob out of the next case and out of other sections.
    FAKE_USERS="${case_dir}/nc-users"
    FAKE_ARGV_LOG="${case_dir}/argv.log"
    FAKE_PW_DIR="${case_dir}/agent-home/nextcloud-passwords"
    FAKE_NOW=""
    FAKE_SHRED_FAIL=""
    FAKE_RM_FAIL=""
    FAKE_PW_MINLEN=""
    FAKE_PW_POLICY=""
    FAKE_GROUP_FAIL=""
    FAKE_GROUP_CASE=""
    FAKE_ADD_NODISPLAY=""
    FAKE_ADD_LOGIN=""
    FAKE_CAT_FAIL=""
    FAKE_INFO_NOJSON=""
    FAKE_INFO_NOISE=""
    FAKE_INFO_NO_UID=""
    FAKE_INFO_NOTFOUND_TEXT=""
    FAKE_INFO_NOTFOUND_RC=""
    FAKE_ADD_NOOP=""
    FAKE_ADD_FAIL_AFTER=""
    FAKE_ENCRYPTION=""
    FAKE_MASTER_KEY=""
    FAKE_SETTING_NOOP=""
    FAKE_SETTING_FAIL=""
    FAKE_ECHO_PW_FILE=""
    # The share-as-admin.sh cases': the token table the fake occ and the fake curl share, the curl config
    # files, the file the script's PID goes to (only when a case sets it), and the knobs of nc-tokens-lib.sh
    # and of the curl fake, including the per-call answers FAKE_CURL_RESPONSE_<n> and FAKE_CURL_HTTP_<n>.
    local knob
    for knob in $(compgen -v FAKE_CURL_) $(compgen -v FAKE_TOKEN_) $(compgen -v FAKE_GROUP_LIST_) $(compgen -v FAKE_FLOCK_) $(compgen -v FAKE_HEALTH_); do unset "${knob}"; done
    # The backup.sh, restore.sh and run-in-nextcloud.sh cases' knobs, and the brief's FAKE_CFG and FAKE_DF_AVAIL.
    for knob in $(compgen -v FAKE_BR_); do unset "${knob}"; done
    unset FAKE_CFG FAKE_DF_AVAIL FAKE_SQL_LOG
    FAKE_TOKENS="${case_dir}/tokens.tsv"
    FAKE_CURL_CFG="${case_dir}/curl-cfg"
    FAKE_PIDFILE=""
  }
  # What a script under test sees, as on the agent. A task adds its variables here.
  default_env=(
    [HOME]="${case_dir}/agent-home"
    [TMPDIR]="${case_dir}/tmp"
    [PATH]="${bin}:${BASH%/*}:/usr/bin:/bin"
    [NEXTCLOUD_HOST]=nc.test
    [NEXTCLOUD_URL]=https://abc.clouve.app
    [NEXTCLOUD_MARIADB_HOST]=nc-db.test
    [NEXTCLOUD_DB_HOST]=nc-db.test
    [NEXTCLOUD_DB_NAME]=nextcloud
    [NEXTCLOUD_DB_USER]=nextcloud
    [NEXTCLOUD_ADMIN_USER]=admin
    [NEXTCLOUD_ADMIN_EMAIL]=admin@example.com
    [CLOUVE_OPS_PASSWORD]="${ops_pw}"
  )
}

# run_env [NAME=value | -NAME]... --
# Builds the environment a script is run in: default_env, then every FAKE_* shell variable, then the overrides
# (NAME=value sets or replaces a variable for this run, -NAME leaves one out). The result is run_pairs (the
# NAME=value words for env -i), run_ops_pw (the ops password that environment holds) and run_nargs (how many
# arguments it read, the -- included, for the caller to shift).
run_env() {
  local -A env_map=()
  local key spec
  run_pairs=()
  run_nargs=0
  for key in "${!default_env[@]}"; do env_map[${key}]="${default_env[${key}]}"; done
  for key in $(compgen -v FAKE_); do env_map[${key}]="${!key}"; done
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    spec="$1"
    case "${spec}" in
      -*) unset "env_map[${spec#-}]" ;;
      *=*) env_map[${spec%%=*}]="${spec#*=}" ;;
      *) echo "run_script: not NAME=value or -NAME: ${spec}" >&2; return 2 ;;
    esac
    shift
    run_nargs=$((run_nargs + 1))
  done
  run_nargs=$((run_nargs + 1))
  for key in "${!env_map[@]}"; do run_pairs+=("${key}=${env_map[${key}]}"); done
  run_ops_pw="${env_map[CLOUVE_OPS_PASSWORD]-}"
}

# check_ops_password: fails the case if the ops password (the test's, or the one the run was given) is in an
# argv log, stdout or stderr: no run may show it.
check_ops_password() {
  local secret file
  for secret in "${ops_pw}" "${run_ops_pw}"; do
    [ -n "${secret}" ] || continue
    for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}" "${case_dir}/stdout" "${case_dir}/stderr"; do
      if grep -qF -- "${secret}" "${file}"; then bad "${case_label}: the ops password is in $(basename "${file}")"; fi
    done
  done
}

# run_script [NAME=value | -NAME]... -- <script> [args...]
# Runs a script with the case's environment (see run_env). stdin is the caller's, so redirect it on the call to
# feed a script. Leaves the exit code in $rc, stdout in $out and stderr in $err (byte-exact copies are
# ${case_dir}/stdout and ${case_dir}/stderr). Fails the case if the ops password turns up in an argv log, stdout or
# stderr (check_ops_password). When $FAKE_PIDFILE is set, the script's PID is written there before it starts (exec
# keeps the PID), so a fake can signal it: the fake curl does, for the cases that kill share-as-admin.sh in the
# middle of a run.
run_script() {
  local -a launcher=()
  local script
  run_env "$@" || return 2
  shift "${run_nargs}"
  script="$1"
  shift
  : > "${FAKE_CALLS}"
  : > "${FAKE_OCC_LOG}"
  : > "${FAKE_ARGV_LOG}"
  : > "${FAKE_ARGV_LOG}.env"
  : > "${FAKE_ARGV_LOG}.as"
  rm -f "${FAKE_OCC_LOG}.pass"
  if [ -n "${FAKE_PIDFILE:-}" ]; then launcher=("${BASH}" -c 'echo $$ > "$FAKE_PIDFILE"; exec "$@"' _); fi
  # The script starts with HUP, INT, TERM and PIPE at their defaults. A suite started with nohup has HUP ignored, and one
  # started in the background INT, and a script can't trap a signal that was ignored when it started: the cases that
  # signal a script would test how the suite was started. The group's own 2>/dev/null only hides the "Killed" notice
  # this shell prints for a script that SIGKILL ended.
  { env -i --default-signal=HUP,INT,TERM,PIPE "${run_pairs[@]}" ${launcher[@]+"${launcher[@]}"} "${script}" "$@" > "${case_dir}/stdout" 2> "${case_dir}/stderr"; } 2> /dev/null
  rc=$?
  # Shell variables cannot hold NUL, so these two copies drop it; the files keep every byte.
  out="$(tr -d '\0' < "${case_dir}/stdout")"
  err="$(tr -d '\0' < "${case_dir}/stderr")"
  check_ops_password
}

# start_script <tag> [NAME=value | -NAME]... -- <script> [args...]
# Runs a script in the background, for the cases where two runs overlap. The environment is run_script's. Unlike
# run_script it empties no log, so the runs write to the same ones. Its streams and exit code go to
# ${case_dir}/<tag>.stdout, .stderr and .rc; finish_script <tag> waits for it.
declare -A bg_pids=()
start_script() {
  local tag="$1" script file
  shift
  run_env "$@" || return 2
  shift "${run_nargs}"
  script="$1"
  shift
  for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}" "${FAKE_ARGV_LOG}.env" "${FAKE_ARGV_LOG}.as" "${case_dir}/stdout" "${case_dir}/stderr"; do
    [ -e "${file}" ] || : > "${file}"
  done
  ( { env -i "${run_pairs[@]}" "${script}" "$@" > "${case_dir}/${tag}.stdout" 2> "${case_dir}/${tag}.stderr"; echo $? > "${case_dir}/${tag}.rc"; } 2> /dev/null ) &
  bg_pids[${tag}]=$!
}

# finish_script <tag>: waits for a start_script run. Leaves its exit code in rc and its streams in out and err, adds
# them to ${case_dir}/stdout and stderr (which the checks that sweep the streams read), and runs check_ops_password.
finish_script() {
  wait "${bg_pids[$1]}"
  rc="$(< "${case_dir}/$1.rc")"
  out="$(tr -d '\0' < "${case_dir}/$1.stdout")"
  err="$(tr -d '\0' < "${case_dir}/$1.stderr")"
  cat "${case_dir}/$1.stdout" >> "${case_dir}/stdout"
  cat "${case_dir}/$1.stderr" >> "${case_dir}/stderr"
  check_ops_password
}

# wait_for_file <path>: waits up to 30 seconds for the file to exist. For the cases where one process has to be in a
# known place before the next one starts.
wait_for_file() {
  local i
  for ((i = 0; i < 300; i++)); do
    if [ -e "$1" ]; then return 0; fi
    sleep 0.1
  done
  bad "${case_label}: $1 never appeared"
  return 1
}

# wait_for_call <ERE>: waits up to 30 seconds for a line of $FAKE_CALLS that matches
wait_for_call() {
  local i
  for ((i = 0; i < 300; i++)); do
    if grep -qE -- "$1" "${FAKE_CALLS}" 2> /dev/null; then return 0; fi
    sleep 0.1
  done
  bad "${case_label}: no line matching /$1/ in the calls after 30 seconds"
  return 1
}

# occ_args <args...>: runs occ.sh with these arguments
occ_args() { run_script -- "${occ_sh}" "$@"; }

# Answers for the fake occ. FAKE_OUT and FAKE_ERR write a line to stdout or
# stderr, FAKE_RC sets the exit code, FAKE_HANDLER installs the script on stdin.
FAKE_OUT() { printf '%s\n' "$2" > "${FAKE_OCC}/$1"; }
FAKE_ERR() { printf '%s\n' "$2" > "${FAKE_OCC}/$1.err"; }
FAKE_RC() { printf '%s\n' "$2" > "${FAKE_OCC}/$1.rc"; }
FAKE_HANDLER() { cat > "${FAKE_OCC}/$1.handler"; chmod +x "${FAKE_OCC}/$1.handler"; }

# call_count <name>: how many calls of a fake the last run made
call_count() { grep -cE "^$1( |\$)" "${FAKE_CALLS}" || true; }

# ssh_field <n> opts|target|stdin|stdin_bytes|cmd: one part of the n-th ssh call of the last run
ssh_field() {
  local line
  line="$(grep -E '^ssh ' "${FAKE_CALLS}" | sed -n "${1}p")"
  case "$2" in
    opts)        line="${line#ssh opts=}";        printf '%s' "${line%%' target='*}" ;;
    target)      line="${line#*' target='}";      printf '%s' "${line%%' stdin='*}" ;;
    stdin)       line="${line#*' stdin='}";       printf '%s' "${line%%' stdin_bytes='*}" ;;
    stdin_bytes) line="${line#*' stdin_bytes='}"; printf '%s' "${line%%' cmd='*}" ;;
    cmd)         printf '%s' "${line#*' cmd='}" ;;
  esac
}

dump_case() {
  printf 'exit %s\n--- stdout\n%s\n--- stderr\n%s\n--- calls\n%s\n' "${rc}" "${out}" "${err}" "$(cat "${FAKE_CALLS}" 2>/dev/null)"
}

last_occ_call() { tail -n 1 "${FAKE_OCC_LOG}" 2>/dev/null; }

# no_occ_call_detail: for a failed argv check, what the run printed when occ never ran
no_occ_call_detail() { if [ -z "$(last_occ_call)" ]; then dump_case; fi; }

# The checks. Each prints one ok or FAIL line, headed by the case's label, and
# looks at the last run.

expect_rc() { # expect_rc <exit code>
  if [ "${rc}" -eq "$1" ]; then ok "${case_label}: exit ${1}"
  else bad "${case_label}: wanted exit ${1}, got ${rc}" "$(dump_case)"; fi
}

expect_eq() { # expect_eq <what> <wanted> <got>
  if [ "$2" = "$3" ]; then ok "${case_label}: $1"
  else bad "${case_label}: $1" "wanted: $2
got:    $3"; fi
}

expect_call_count() { # expect_call_count <fake name> <n>
  local got
  got="$(call_count "$1")"
  expect_eq "$1 was called $2 time(s)" "$2" "${got}"
}

expect_stdout_is() { # expect_stdout_is <exact stdout>
  if printf '%s' "$1" | cmp -s - "${case_dir}/stdout"; then ok "${case_label}: stdout is exactly the expected text"
  else bad "${case_label}: stdout differs from the expected text" "$(dump_case)"; fi
}

expect_stdout_file() { # expect_stdout_file <file with the exact stdout>
  if cmp -s "$1" "${case_dir}/stdout"; then ok "${case_label}: stdout is byte for byte what occ printed"
  else bad "${case_label}: stdout differs from what occ printed ($(wc -c < "${case_dir}/stdout") bytes, wanted $(wc -c < "$1"))"; fi
}

expect_stdout_json() { # expect_stdout_json <jq filter that must be true>
  if jq -e "$1" "${case_dir}/stdout" >/dev/null 2>&1; then ok "${case_label}: stdout parses as JSON where $1"
  else bad "${case_label}: stdout is not JSON where $1" "$(dump_case)"; fi
}

expect_occ_calls() { # expect_occ_calls <n>
  expect_eq "occ ran $1 time(s)" "$1" "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
}

expect_occ_argv() { # expect_occ_argv <JSON array>: the last occ call got exactly this argv
  local last
  last="$(last_occ_call)"
  if [ -n "${last}" ] && python3 -I -c 'import json, sys; sys.exit(json.loads(sys.argv[1]) != json.loads(sys.argv[2]))' "$1" "${last}"; then
    ok "${case_label}: occ got exactly the expected argv"
  else
    bad "${case_label}: occ got a different argv" "wanted: $1
got:    ${last:-<no occ call>}
$(no_occ_call_detail)"
  fi
}

expect_occ_args() { # expect_occ_args <arg>...: after php's occ and its two fixed options, occ got exactly these
  local last
  last="$(last_occ_call)"
  if [ -n "${last}" ] && python3 -I -c '
import json, sys
a = json.loads(sys.argv[1])
fixed = ["/var/www/html/occ", "--no-interaction", "--no-warnings"]
sys.exit(not (a[:3] == fixed and a[3:] == sys.argv[2:]))' "${last}" "$@"; then
    ok "${case_label}: each of the $# argument(s) reached occ as one entry, unchanged"
  else
    bad "${case_label}: occ got different arguments" "got: ${last:-<no occ call>}
$(no_occ_call_detail)"
  fi
}

expect_last_arg() { # expect_last_arg <arg>: the last argument reached occ as one entry, unchanged
  local last
  last="$(last_occ_call)"
  if [ -n "${last}" ] && python3 -I -c 'import json, sys; sys.exit(json.loads(sys.argv[1])[-1] != sys.argv[2])' "${last}" "$1"; then
    ok "${case_label}: the last argument reached occ as one entry, unchanged"
  else
    bad "${case_label}: the last argument did not reach occ unchanged" "wanted: $1
got:    ${last:-<no occ call>}
$(no_occ_call_detail)"
  fi
}

# line_bytes <text>: the size of the text and its newline, what a script sends when it sends a line
line_bytes() { printf '%s\n' "$1" | wc -c | tr -d ' '; }

expect_channel_bytes() { # expect_channel_bytes <n> [call]: the ssh call (the first by default) sent n bytes on its stdin
  expect_eq "ssh call ${2:-1} sent $1 byte(s) on the channel" "$1" "$(ssh_field "${2:-1}" stdin_bytes)"
}

expect_pass_sha() { # expect_pass_sha <sha256 hex>: NC_PASS reached occ as exactly this
  expect_eq "NC_PASS reached occ unchanged (SHA-256 compared)" "$1" "$(tail -n 1 "${FAKE_OCC_LOG}.pass" 2>/dev/null || true)"
}

expect_not_in_logs() { # expect_not_in_logs <secret> [file...]: in no argv log, stdout or stderr
  local secret="$1" file leaked=""
  shift
  for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${case_dir}/stdout" "${case_dir}/stderr" "$@"; do
    [ -f "${file}" ] || continue
    if grep -qF -- "${secret}" "${file}"; then leaked+=" $(basename "${file}")"; fi
  done
  if [ -z "${leaked}" ]; then ok "${case_label}: the password is in no argv log, stdout or stderr"
  else bad "${case_label}: the password leaked into:${leaked}"; fi
}

expect_flock() { # expect_flock <lock path>: occ ran under flock on this file, inside sudo
  local s f p
  s="$(grep -nE '^sudo ' "${FAKE_CALLS}" | head -n 1 | cut -d: -f1)"
  f="$(grep -nxF "flock $1" "${FAKE_CALLS}" | head -n 1 | cut -d: -f1)"
  p="$(grep -nE '^php ' "${FAKE_CALLS}" | head -n 1 | cut -d: -f1)"
  if [ -n "${s}" ] && [ -n "${f}" ] && [ -n "${p}" ] && [ "${s}" -lt "${f}" ] && [ "${f}" -lt "${p}" ]; then
    ok "${case_label}: sudo runs flock on $1, which runs php"
  else
    bad "${case_label}: wanted sudo, then flock on $1, then php" "$(dump_case)"
  fi
}

expect_no_flock() {
  if [ "$(call_count flock)" -eq 0 ]; then ok "${case_label}: no flock"
  else bad "${case_label}: flock ran but should not have" "$(dump_case)"; fi
}

# mode_of <path>: the permission bits, e.g. 600
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo unknown; }

# occ_subcommands: the subcommand of each occ call of the last run, in order, on one line
occ_subcommands() { jq -r '.[3]' "${FAKE_OCC_LOG}" | tr '\n' ' ' | sed 's/ $//'; }

# occ_call_args <n>: the arguments of the n-th occ call, after php's occ and its two fixed options, as compact JSON
occ_call_args() { sed -n "${1}p" "${FAKE_OCC_LOG}" | jq -c '.[3:]'; }

expect_occ_sequence() { # expect_occ_sequence <subcommands on one line>: the occ calls of the last run, in order
  expect_eq "occ ran: ${1:-nothing}" "$1" "$(occ_subcommands)"
}

expect_mode() { # expect_mode <path> <mode> <what>
  expect_eq "$3 has mode $2" "$2" "$(mode_of "$1")"
}

# --- fake account store (the temp-password.sh cases) ---

# install_user_fakes: gives the fake occ working user:add, user:info, user:setting, user:resetpassword, and
# app:list and config:app:get (which answer the encryption questions)
install_user_fakes() {
  local sub
  for sub in user:add user:info user:setting user:resetpassword app:list config:app:get; do
    FAKE_HANDLER "${sub}" <<HANDLER
#!/bin/bash
. "${fake_lib}"
. "${users_lib}"
fake_${sub//:/_} "\$@"
HANDLER
  done
}

# seed_user <uid> [display name [email [group...]]]: an account that already exists in the fake Nextcloud
seed_user() {
  local uid="$1" display="${2-}" email="${3-}"
  local -a member_of=("${@:4}")
  # shellcheck source=/dev/null
  ( . "${users_lib}"; nc_fake_create "${uid}" "${display}" "${email}" "${member_of[@]}" )
}

# new_pw_case <label>: new_case, plus what the temp-password.sh cases share: the fake account store,
# the argv shims first on PATH, and the agent's home and password folder as pw_home and pw_dir
new_pw_case() {
  new_case "$1"
  default_env[PATH]="${shim_bin}:${default_env[PATH]}"
  install_user_fakes
  pw_home="${case_dir}/agent-home"
  pw_dir="${pw_home}/nextcloud-passwords"
}

# install_share_fakes: gives the fake occ working group:list and user:auth-tokens:add, :list and :delete
install_share_fakes() {
  local sub
  for sub in group:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete; do
    FAKE_HANDLER "${sub}" <<HANDLER
#!/bin/bash
. "${fake_lib}"
. "${users_lib}"
. "${tokens_lib}"
fake_${sub//[:-]/_} "\$@"
HANDLER
  done
}

# new_share_case <label>: new_pw_case, plus what the share-as-admin.sh cases share: the token table (empty),
# group:list and the token commands, and an enabled account "admin" in the group "admin"
new_share_case() {
  new_pw_case "$1"
  install_share_fakes
  : > "${FAKE_TOKENS}"
  seed_user admin 'Admin' admin@example.com admin
}

# --- the verify-health.sh cases ---

# The database password the health cases give the script. A plain shell variable, not a FAKE_* one, so no run's environment holds it
# (the fake mysql reads the password it wants from a file).
db_pw='Db-Pw-9fXk3Lq7Rt'

# install_health_fakes: gives the fake occ working status, config:app:get, config:system:get and setupchecks (nc-health-lib.sh)
install_health_fakes() {
  local sub
  for sub in status config:app:get config:system:get setupchecks; do
    FAKE_HANDLER "${sub}" <<HANDLER
#!/bin/bash
. "${fake_lib}"
. "${nc_health_lib}"
fake_health_${sub//:/_} "\$@"
HANDLER
  done
}

# set_db_password <password>: the password the script is given (in its environment, and from clv-secret) and the one the fake mysql accepts
set_db_password() {
  default_env[NEXTCLOUD_DB_PASSWORD]="$1"
  FAKE_SECRET_NEXTCLOUD_DB_PASSWORD="$1"
  printf '%s' "$1" > "${case_dir}/db-password"
  FAKE_HEALTH_DB_PW_FILE="${case_dir}/db-password"
  case_db_pw="$1"
}

# new_health_case <label>: new_case, plus what the verify-health.sh cases share: the argv shims first on PATH, the fake occ's answers,
# a healthy fake Nextcloud (the state ok, 42% and 35% of the disks used, the init lock file there and free, a fixed clock), the fake
# curl in probe mode, and the fake timeout logging its calls
new_health_case() {
  new_case "$1"
  default_env[PATH]="${shim_bin}:${default_env[PATH]}"
  set_db_password "${db_pw}"
  FAKE_NOW='@1800000000'
  FAKE_CURL_MODE=probe
  FAKE_HEALTH_TIMEOUT=''
  FAKE_HEALTH_DF_WWW=42
  FAKE_HEALTH_DF_MYSQL=35
  install_health_fakes
  : > "${FAKE_WWW}/nextcloud-init-sync.lock"
  mkdir -p "${FAKE_WWW}/data/clouve-backups"
}

# check_db_password: fails the case if the database password or the ops password is in an argv log, stdout or stderr (run_health does
# this after every run; run_script also sweeps the ops password, this keeps both secrets named in one place)
check_db_password() {
  local file name secret
  for name in database ops; do
    if [ "${name}" = database ]; then secret="${case_db_pw}"; else secret="${ops_pw}"; fi
    [ -n "${secret}" ] || continue
    for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}" "${case_dir}/stdout" "${case_dir}/stderr"; do
      if grep -qF -- "${secret}" "${file}"; then bad "${case_label}: the ${name} password is in $(basename "${file}")"; fi
    done
  done
}

# run_health [NAME=value | -NAME]... [-- <verify-health.sh arguments>]: run_script with verify-health.sh, then check_db_password
run_health() {
  local -a env_args=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do env_args+=("$1"); shift; done
  if [ "$#" -gt 0 ]; then shift; fi
  run_script ${env_args[@]+"${env_args[@]}"} -- "${health_sh}" "$@"
  check_db_password
}

# The labels of the report, in the order verify-health.sh prints them, and the checks that need occ (health_occ) or only ssh to the
# Nextcloud container (health_ssh)
health_labels="ssh_nextcloud occ_status installed maintenance needs_db_upgrade version http_status http_login_page database_tcp ssh_database restore_marker init_lock valkey cron_last_run background_jobs_mode setup_checks disk_nextcloud disk_database url_setting"
health_occ=(installed maintenance needs_db_upgrade version cron_last_run background_jobs_mode setup_checks url_setting)   # skipped when occ can't run
health_ssh=(restore_marker init_lock valkey disk_nextcloud)                                                              # skipped only when ssh to the container fails

# report_labels: the labels of the report lines the last run printed, in order, on one line
report_labels() { grep -E '^[a-z_]+ +(OK|WARN|FAIL) ' "${case_dir}/stdout" | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//'; }

# expect_health <label> <OK|WARN|FAIL> [detail ERE]: the label has one report line, with this status and, if given, a detail that matches
expect_health() {
  local label="$1" want="$2" detail_re="${3:-}" line status rest
  local -a lines=()
  mapfile -t lines < <(grep -E "^${label} +(OK|WARN|FAIL) " "${case_dir}/stdout")
  if [ "${#lines[@]}" -ne 1 ]; then bad "${case_label}: ${label}: wanted one report line, found ${#lines[@]}" "$(dump_case)"; return; fi
  line="${lines[0]}"
  read -r _ status rest <<< "${line}"
  if [ "${status}" != "${want}" ]; then bad "${case_label}: ${label} is ${status}, wanted ${want}" "${line}"; return; fi
  if [ -n "${detail_re}" ] && ! [[ "${rest}" =~ ${detail_re} ]]; then bad "${case_label}: ${label} ${want}: the detail does not match /${detail_re}/" "${line}"; return; fi
  ok "${case_label}: ${label} ${want}${detail_re:+ (${detail_re})}"
}

# expect_no_health <label>...: the report has no line for these checks (they were skipped)
expect_no_health() {
  local label
  for label in "$@"; do
    if grep -qE "^${label} " "${case_dir}/stdout"; then bad "${case_label}: ${label} has a report line but should have been skipped" "$(dump_case)"
    else ok "${case_label}: ${label} was skipped"; fi
  done
}

# expect_overall GREEN|AMBER|RED: the Overall line and the exit code that go together (0, 2, 3)
expect_overall() {
  local last
  last="$(tail -n 1 "${case_dir}/stdout")"
  case "$1" in
    GREEN) expect_eq "the last line" "Overall: GREEN" "${last}"; expect_rc 0 ;;
    AMBER) expect_eq "the last line" "Overall: AMBER (one or more WARN)" "${last}"; expect_rc 2 ;;
    RED) expect_eq "the last line" "Overall: RED (one or more FAIL)" "${last}"; expect_rc 3 ;;
  esac
}

# ssh_summary [host]: "<user@host> <command>" for each ssh call of the last run (only those to this host, if given), one per line
ssh_summary() {
  grep -E '^ssh ' "${FAKE_CALLS}" | sed -E 's/^ssh opts=.* target=([^ ]+) stdin=.* cmd=/\1 /' | { if [ -n "${1:-}" ]; then grep -E "^clouve-ops@${1} "; else cat; fi; }
}

# fake_calls <name>: the logged calls of a fake, one per line (the first word is the fake's name)
fake_calls() { grep -E "^$1( |\$)" "${FAKE_CALLS}" || true; }

# The shape of a generated password: 20 characters of the alphabet with no I, O, l, 0 or 1.
pw_alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
pw_alphabet_re='[A-HJ-NP-Za-km-z2-9]'
pw_line_re='^[A-HJ-NP-Za-km-z2-9]{20}$'

# expect_password_only_in_nc_pass <password>: of every environment the shimmed tools were given, the
# only one that held the password is NC_PASS on the container side, where occ reads it. On the
# agent side no tool ever had it.
expect_password_only_in_nc_pass() {
  local holders
  holders="$(grep -F -- "$1" "${FAKE_ARGV_LOG}.env" | grep -v '^container NC_PASS=' | cut -d= -f1 | sort -u | tr '\n' ' ')"
  expect_eq "no environment holds the password but the container side's NC_PASS" "" "${holders}"
}

# expect_no_password_text: nothing in stdout, stderr or the argv and call logs looks like a generated
# password: a run of 20 or more characters of the alphabet that has an upper-case letter, a
# lower-case letter and a digit, as every generated password does. For the cases where the file,
# and so the password, is gone and cannot be searched for by value. The alphabet itself, which
# is in tr's argument, is blanked out first, and a plain word such as StrictHostKeyChecking is
# 21 letters of the alphabet but has no digit.
expect_no_password_text() {
  local file found=""
  for file in "${case_dir}/stdout" "${case_dir}/stderr" "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}"; do
    [ -f "${file}" ] || continue
    if sed "s/${pw_alphabet}//g" "${file}" | grep -oE "${pw_alphabet_re}{20,}" | grep -E '[A-Z]' | grep -E '[a-z]' | grep -qE '[2-9]'; then found+=" $(basename "${file}")"; fi
  done
  if [ -z "${found}" ]; then ok "${case_label}: nothing in the output or the logs looks like a password"
  else bad "${case_label}: something that looks like a password is in:${found}"; fi
}

# snapshot <path>...: every path under them, and a checksum for each regular file, to compare before and after a run
snapshot() {
  local f
  find "$@" 2>/dev/null | sort | while IFS= read -r f; do
    if [ -f "${f}" ] && [ ! -L "${f}" ]; then printf '%s %s\n' "${f}" "$(cksum < "${f}")"; else printf '%s\n' "${f}"; fi
  done
}

# --- the backup.sh, restore.sh and run-in-nextcloud.sh cases ---

# The database password of the cases' config.php, made to need every escape of the client's options file: an odd double
# quote before a # (unescaped, the # would start a comment), single quotes, \n (unescaped, a newline), \x, \\, a $, a ; and
# spaces at both ends. A plain shell variable, so no run's environment holds it: the fake php answers it from
# $FAKE_CFG/dbpassword, and the fake clients compare with that file.
br_db_pw=' Db "pw #1 '"'"'q'"'"' \n\x\\ $HOME;& '

# install_br_fakes: gives the fake occ what backup.sh and restore.sh call (nc-br-lib.sh)
install_br_fakes() {
  local sub
  for sub in status maintenance:mode maintenance:data-fingerprint maintenance:repair upgrade db:add-missing-indices \
    db:add-missing-columns db:add-missing-primary-keys files:scan groupfolders:scan app:list memcache:redis:command; do
    FAKE_HANDLER "${sub}" <<HANDLER
#!/bin/bash
. "${fake_lib}"
. "${br_lib}"
fake_br_${sub//[:-]/_} "\$@"
HANDLER
  done
}

# br_set <key> <value>: what config.php holds for KEY (the fake php's answer), written as it is, with no newline
br_set() { printf '%s' "$2" > "${FAKE_CFG}/$1"; }
br_unset() { rm -f "${FAKE_CFG}/$1"; }

# new_br_case <label>: new_case, plus what the backup.sh and restore.sh cases share: the clients and the root id switched
# on, the argv shims first on PATH, a clock, plenty of free space, and the case's Nextcloud: www/ with config/ (config.php
# and a fragment), custom_apps/calendar, an empty themes/, the init lock, and data/ with .ncdata, .htaccess, alice's file, a
# preview and the log. config.php's settings are in $FAKE_CFG; datadirectory is the real path of that data/.
new_br_case() {
  new_case "$1"
  default_env[PATH]="${shim_bin}:${default_env[PATH]}"
  FAKE_BR_DB=1
  FAKE_BR_ROOT=1
  FAKE_NOW='@1800000000'
  FAKE_DF_AVAIL=999999999999
  FAKE_CFG="${case_dir}/cfg"
  FAKE_BR_STATE="${case_dir}/nc-state"
  FAKE_SQL_LOG="${case_dir}/sql.log"
  mkdir -p "${FAKE_CFG}" "${FAKE_BR_STATE}"
  : > "${FAKE_SQL_LOG}"
  install_br_fakes
  br_www="${FAKE_WWW}"
  br_data="${FAKE_WWW}/data"
  br_backups="${br_data}/clouve-backups"
  mkdir -p "${br_www}/config" "${br_www}/custom_apps/calendar/appinfo" "${br_www}/themes" \
    "${br_data}/alice/files" "${br_data}/appdata_oc123/preview/1" "${br_data}/appdata_oc123/css"
  printf '<?php\n$CONFIG = array (\n  %s => %s,\n);\n' "'instanceid'" "'oc123abc'" > "${br_www}/config/config.php"
  printf '<?php\n$CONFIG = array (\n  %s => %s,\n);\n' "'upgrade.disable-web'" true > "${br_www}/config/upgrade-disable-web.config.php"
  printf '<?xml version="1.0"?>\n<info><id>calendar</id><version>6.0.1</version></info>\n' > "${br_www}/custom_apps/calendar/appinfo/info.xml"
  printf '# Nextcloud data directory\n' > "${br_data}/.ncdata"
  printf 'deny from all\n' > "${br_data}/.htaccess"
  printf "alice's file\n" > "${br_data}/alice/files/a.txt"
  printf 'PNG' > "${br_data}/appdata_oc123/preview/1/x.png"
  printf 'body{}\n' > "${br_data}/appdata_oc123/css/c.css"
  printf '{"level":2,"message":"log line"}\n' > "${br_data}/nextcloud.log"
  printf '<?php\n$OC_Version = [35, 0, 2, 2];\n' > "${br_www}/version.php"
  : > "${br_www}/nextcloud-init-sync.lock"
  br_set dbtype mysql
  br_set dbhost nextcloud-mariadb
  br_set dbname nextcloud
  br_set dbuser nextcloud
  br_set dbpassword "${br_db_pw}"
  br_set datadirectory "${br_data}"
  br_set version 35.0.2.2
  br_set instanceid oc123abc
  br_set maintenance false
}

# run_in <file|stdin> <script> [NAME=value | -NAME]... [-- args...]: runs backup.sh or restore.sh with NC_ROOT at the case's
# tree, as a file, or the way run-in-nextcloud.sh runs it (`bash -s` with the script on stdin). NC_OCC is the script's own
# default unless the case gives one. The run is then swept for the database password.
run_in() {
  local how="$1" script="$2"
  local -a envs=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  if [ "$#" -gt 0 ]; then shift; fi
  # a missing script runs as a missing file (exit 127), so a case never reads the exit code of the run before
  if [ "${how}" = stdin ] && [ -f "${script}" ]; then
    run_script NC_ROOT="${br_www}" ${envs[@]+"${envs[@]}"} -- "${BASH}" -s -- "$@" < "${script}"
  else
    run_script NC_ROOT="${br_www}" ${envs[@]+"${envs[@]}"} -- "${script}" "$@"
  fi
  check_br_password
}

# check_br_password: fails the case if the database password is in an argv log, an environment, stdout or stderr
check_br_password() {
  local file
  for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}" "${FAKE_ARGV_LOG}.env" "${case_dir}/stdout" "${case_dir}/stderr"; do
    if [ -f "${file}" ] && grep -qF -- "${br_db_pw}" "${file}"; then bad "${case_label}: the database password is in $(basename "${file}")"; fi
  done
}

# br_name <epoch seconds>: the name backup.sh gives a backup made at that time
br_name() { TZ=UTC date -d "@$1" +%Y%m%d-%H%M%S; }

# occ_brief: each occ call of the last run as "<command> <arguments>", one per line
occ_brief() { jq -r '.[3:] | join(" ")' "${FAKE_OCC_LOG}"; }

# expect_occ_brief <lines>: the occ calls of the last run, in order, are exactly these
expect_occ_brief() { expect_eq "occ ran, in order: $(printf '%s' "$1" | tr '\n' '|')" "$1" "$(occ_brief)"; }

# names_in <dir>: the names in a folder, dot-files included, in C-locale order, space-separated
names_in() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' 2> /dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'; }

# br_tmp_left: what the run left in the case's TMPDIR
br_tmp_left() { names_in "${case_dir}/tmp"; }

# br_tree_sum: one checksum of every path, mode and file in the case's Nextcloud, its database log and its maintenance state
br_tree_sum() {
  {
    find "${br_www}" -printf '%P %m %s\n' | sort
    find "${br_www}" -type f -print0 | sort -z | xargs -0 sha256sum
    cat "${FAKE_SQL_LOG}"
    br_now_maint
  } | sha256sum | cut -d' ' -f1
}

# br_now_maint: the fake instance's maintenance mode now (on or off)
br_now_maint() { local m=off; if [ -f "${FAKE_BR_STATE}/maintenance" ]; then read -r m < "${FAKE_BR_STATE}/maintenance"; fi; printf '%s' "${m}"; }

# br_backups_now: the names of the folders in clouve-backups, space-separated
br_backups_now() { local d out=""; for d in "${br_backups}"/*/; do [ -d "${d}" ] && out+="$(basename "${d}") "; done; printf '%s' "${out% }"; }

# br_make_backup [args...]: makes a backup in this case with the real backup.sh (as a file), at the case's clock, and sets
# br_last to its folder. The run's exit code, streams and logs are the last run's, as with any run.
br_make_backup() {
  run_in file "${backup_sh}" -- "$@"
  br_last="${br_backups}/$(br_name "${FAKE_NOW#@}")"
  if [ "${rc}" -ne 0 ] || [ ! -f "${br_last}/SHA256SUMS" ]; then bad "${case_label}: setting up: backup.sh $* did not make a backup" "$(dump_case)"; fi
}

# br_resum <folder>: writes the folder's SHA256SUMS again (after a case changed a file on purpose)
br_resum() {
  ( cd "$1" || exit 1
    names=()
    while IFS= read -r n; do if [ -f "${n}" ]; then names+=("${n}"); fi; done < <(cut -c67- SHA256SUMS)
    sha256sum -- "${names[@]}" > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS )
}

# br_manifest_set <folder> <jq assignment>: changes the manifest, then its checksum, as if backup.sh had written it so
br_manifest_set() { jq "$2" "$1/manifest.json" > "$1/manifest.json.new" && mv "$1/manifest.json.new" "$1/manifest.json" && br_resum "$1"; }

# br_job_cleanup <job>: makes sure no detached job of the case is still running: the fake job ends when its go file is there
br_job_cleanup() {
  local i
  : > "${case_dir}/go"
  for ((i = 0; i < 100; i++)); do
    [ -e "${FAKE_RUN}/jobs/$1.rc" ] && return 0
    sleep 0.1
  done
}

# ---------------------------------------------------------------------------
# 4. Sections
# ---------------------------------------------------------------------------

# ===== occ.sh ===============================================================
occ_cmd='php /var/www/html/occ --no-interaction --no-warnings'
ssh_o='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10'

section "occ.sh: the file"
if [ ! -f "${occ_sh}" ]; then
  bad "occ.sh exists" "${occ_sh}"
else
  mode="$(stat -c %a "${occ_sh}" 2>/dev/null || stat -f %Lp "${occ_sh}" 2>/dev/null || echo unknown)"
  if [ -x "${occ_sh}" ] && [ "${mode}" = 755 ]; then ok "occ.sh is executable, mode 755"
  else bad "occ.sh must be executable with mode 755 (it is ${mode})"; fi
  if [ "$(head -n 1 "${occ_sh}")" = '#!/usr/bin/env bash' ]; then ok "occ.sh starts with #!/usr/bin/env bash"
  else bad "occ.sh does not start with #!/usr/bin/env bash"; fi
  if grep -qE '^[[:space:]]*set[[:space:]]+-[A-Za-z]*x' "${occ_sh}"; then bad "occ.sh turns on set -x, which would print the password"
  else ok "occ.sh never turns on set -x"; fi
  if grep -qE '^[[:space:]]*export[[:space:]]+SSHPASS' "${occ_sh}"; then bad "occ.sh exports SSHPASS; it is set on the sshpass command only"
  else ok "occ.sh never exports SSHPASS"; fi
fi

section "occ.sh: every argument reaches occ as one entry, unexpanded"
# A real occ would refuse --password-from-env without NC_PASS; here only the argv is checked.
new_case "user:add with a quote, double quotes, \$HOME, & and spaces"
occ_args 'user:add' '--display-name=O'"'"'Brien "Bob" $HOME' '-g' 'Sales & Ops' '--password-from-env' '--' 'Mary Ann'
expect_occ_argv '["/var/www/html/occ","--no-interaction","--no-warnings","user:add","--display-name=O'"'"'Brien \"Bob\" $HOME","-g","Sales & Ops","--password-from-env","--","Mary Ann"]'
expect_occ_calls 1

new_case "files:scan path with spaces, a quote, \$5, ; and rm -rf ~"
occ_args 'files:scan' '--path=/Mary Ann/files/It'"'"'s $5; rm -rf ~'
expect_last_arg '--path=/Mary Ann/files/It'"'"'s $5; rm -rf ~'

new_case "a group name with a newline"
occ_args 'group:add' $'two\nlines'
expect_last_arg $'two\nlines'

utf8_locale="$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1 || true)"
new_case "non-ASCII uid in the C locale (printf %q writes octal bytes)"
run_script LC_ALL=C -- "${occ_sh}" 'user:info' 'Дмитрий'
expect_last_arg 'Дмитрий'
if [ -n "${utf8_locale}" ]; then
  new_case "non-ASCII uid in a UTF-8 locale (printf %q keeps the letters)"
  run_script LC_ALL="${utf8_locale}" -- "${occ_sh}" 'user:info' 'Дмитрий'
  expect_last_arg 'Дмитрий'
else
  ok "no UTF-8 locale installed here, so the UTF-8 variant is skipped"
fi

new_case "substitutions, globs, braces, tilde, history, tabs, backslashes and empty arguments"
odd=('x$(touch pwned1)' 'y`touch pwned2`' '*' '?' '[a-z]*' '{a,b}' '~' '~root' '!!' '#hash' $'tab\there' $'cr\rhere'
  'back\slash' $'trailing\\' '' '-n' '--' '-' "' \" ' \"" 'a;b&c|d>e<f')
occ_args 'user:info' "${odd[@]}"
expect_occ_args 'user:info' "${odd[@]}"
if [ ! -e "${FAKE_OPS_HOME}/pwned1" ] && [ ! -e "${FAKE_OPS_HOME}/pwned2" ]; then ok "${case_label}: nothing was executed on the far side"
else bad "${case_label}: a command substitution ran on the far side"; fi

new_case "a byte that is not UTF-8"
occ_args 'files:scan' $'--path=/data/caf\xe9'
expect_last_arg $'--path=/data/caf\xe9'

section "occ.sh: its own options end at the first other argument"
new_case "-- ends occ.sh's options"
occ_args -- --init-lock --password-stdin
expect_occ_args --init-lock --password-stdin
expect_no_flock

new_case "options after the command belong to occ"
occ_args user:add --password-stdin --init-lock
expect_occ_args user:add --password-stdin --init-lock
expect_no_flock

section "occ.sh: the ssh call"
new_case "no password on stdin"
occ_args status --output=json
expect_rc 0
expect_eq "ssh target" "clouve-ops@nc.test" "$(ssh_field 1 target)"
expect_eq "ssh options: -n, then the four -o options" "-n ${ssh_o}" "$(ssh_field 1 opts)"
expect_eq "stdin is closed" "closed" "$(ssh_field 1 stdin)"
expect_eq "the remote command" "sudo -n -u www-data ${occ_cmd} status --output=json" "$(ssh_field 1 cmd)"
expect_call_count ssh 1
expect_call_count clv-secret 0

new_case "no host key is kept: the containers make new ones at every start"
occ_args status
expect_rc 0
if [[ " $(ssh_field 1 opts) " == *' -o UserKnownHostsFile=/dev/null '* && " $(ssh_field 1 opts) " == *' -o StrictHostKeyChecking=accept-new '* ]]; then ok "${case_label}: known_hosts is /dev/null and a new key is accepted"
else bad "${case_label}: the ssh options should be UserKnownHostsFile=/dev/null with StrictHostKeyChecking=accept-new" "$(ssh_field 1 opts)"; fi
if [[ "$(ssh_field 1 opts)" == *'StrictHostKeyChecking=no'* ]]; then bad "${case_label}: StrictHostKeyChecking=no would also accept a changed key without a word"
else ok "${case_label}: StrictHostKeyChecking is not no"; fi

new_case "without --password-stdin, what is on stdin never reaches the container"
occ_args status <<< "some text the caller piped in"
expect_channel_bytes 0

new_case "arguments are quoted with %q in the remote command"
occ_args user:add --display-name='Mary Ann' -- 'a b'
expect_eq "the remote command" "sudo -n -u www-data ${occ_cmd} user:add --display-name=Mary\\ Ann -- a\\ b" "$(ssh_field 1 cmd)"

new_case "--init-lock"
occ_args --init-lock upgrade
expect_rc 0
expect_flock /var/www/html/nextcloud-init-sync.lock
expect_eq "the remote command" "sudo -n -u www-data flock /var/www/html/nextcloud-init-sync.lock ${occ_cmd} upgrade" "$(ssh_field 1 cmd)"

section "occ.sh: a password on stdin never reaches a command line"
tmp_pw='Tmp-pw-AbCdEf234567'
tmp_sha="$(printf %s "${tmp_pw}" | sha256sum | cut -d' ' -f1)"

new_case "--password-stdin"
occ_args --password-stdin user:resetpassword --password-from-env -- alice <<< "${tmp_pw}"
expect_rc 0
expect_pass_sha "${tmp_sha}"
expect_channel_bytes "$(line_bytes "${tmp_pw}")"
expect_not_in_logs "${tmp_pw}"
expect_eq "the fake leaves no copy of the channel (and so of the password) on disk" "" "$(ls -A "${case_dir}/tmp")"
expect_eq "ssh options: no -n, so stdin reaches the container" "${ssh_o}" "$(ssh_field 1 opts)"
expect_eq "stdin is open" "open" "$(ssh_field 1 stdin)"
expect_eq "the remote command" "IFS= read -r NC_PASS && export NC_PASS && exec sudo -n --preserve-env=NC_PASS -u www-data ${occ_cmd} user:resetpassword --password-from-env -- alice" "$(ssh_field 1 cmd)"
expect_occ_args user:resetpassword --password-from-env -- alice
if grep -q '^sudo user=www-data preserve=NC_PASS NC_PASS=set ::' "${FAKE_CALLS}"; then ok "${case_label}: NC_PASS reached sudo, and sudo was told to keep it"
else bad "${case_label}: sudo did not get NC_PASS with --preserve-env=NC_PASS" "$(dump_case)"; fi

new_case "a password with spaces, quotes, a backslash, \$ and edge blanks arrives byte for byte"
odd_pw=' sp\ace "q" '"'"'s'"'"' $HOME;&|<> end '
occ_args --password-stdin user:resetpassword --password-from-env -- alice <<< "${odd_pw}"
expect_pass_sha "$(printf %s "${odd_pw}" | sha256sum | cut -d' ' -f1)"
expect_not_in_logs "${odd_pw}"

new_case "only the first line of stdin is the password"
occ_args --password-stdin user:resetpassword --password-from-env -- alice <<< $'first-line-pw\nsecond-line'
expect_pass_sha "$(printf %s 'first-line-pw' | sha256sum | cut -d' ' -f1)"
expect_channel_bytes "$(line_bytes 'first-line-pw')"

new_case "a password with no newline after it"
occ_args --password-stdin user:resetpassword --password-from-env -- alice < <(printf %s "${tmp_pw}")
expect_pass_sha "${tmp_sha}"

new_case "--init-lock and --password-stdin together, in either order"
occ_args --init-lock --password-stdin upgrade --password-from-env <<< "${tmp_pw}"
expect_eq "the remote command" "IFS= read -r NC_PASS && export NC_PASS && exec sudo -n --preserve-env=NC_PASS -u www-data flock /var/www/html/nextcloud-init-sync.lock ${occ_cmd} upgrade --password-from-env" "$(ssh_field 1 cmd)"
expect_pass_sha "${tmp_sha}"
occ_args --password-stdin --init-lock upgrade --password-from-env <<< "${tmp_pw}"
expect_flock /var/www/html/nextcloud-init-sync.lock
expect_pass_sha "${tmp_sha}"

new_case "--password-stdin with nothing on stdin"
occ_args --password-stdin user:resetpassword --password-from-env -- alice < /dev/null
expect_rc 64
expect_call_count ssh 0
new_case "--password-stdin with an empty first line"
occ_args --password-stdin user:resetpassword --password-from-env -- alice <<< ''
expect_rc 64
expect_call_count ssh 0

section "occ.sh: the exit code and both streams pass through"
new_case "an occ failure"
FAKE_RC user:info 1
FAKE_OUT user:info 'The user "nobody" does not exist.'
occ_args user:info nobody
expect_rc 1
expect_stdout_is $'The user "nobody" does not exist.\n'
expect_call_count ssh 1

new_case "stdout stays JSON that parses"
FAKE_OUT status '{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2"}'
occ_args status --output=json
expect_rc 0
expect_stdout_json '.installed == true and .version == "35.0.2.2"'
expect_eq "nothing on stderr" "" "${err}"

new_case "stdout and stderr stay separate and byte-exact"
printf '  leading\n\ntrailing  \r\nno newline at the end' > "${FAKE_OCC}/config:list"
printf 'a warning for stderr\n' > "${FAKE_OCC}/config:list.err"
occ_args config:list system
expect_stdout_is $'  leading\n\ntrailing  \r\nno newline at the end'
expect_eq "stderr" "a warning for stderr" "${err}"

new_case "all 256 byte values and a large output"
{ python3 -I -c 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 1200)'; } > "${FAKE_OCC}/config:list"
occ_args config:list system
expect_stdout_file "${FAKE_OCC}/config:list"

section "occ.sh: arguments and environment"
new_case "no arguments"
occ_args
expect_rc 64
expect_call_count ssh 0
expect_call_count clv-secret 0
if [[ "${err}" == *'Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>'* ]]; then ok "${case_label}: the usage line is on stderr"
else bad "${case_label}: no usage line on stderr" "$(dump_case)"; fi

new_case "options but no command"
occ_args --init-lock
expect_rc 64
occ_args --
expect_rc 64
expect_call_count ssh 0

new_case "--help"
occ_args --help
expect_rc 0
if [[ "${out}" == 'Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>'* ]]; then ok "${case_label}: the usage is on stdout"
else bad "${case_label}: no usage on stdout" "$(dump_case)"; fi
expect_call_count ssh 0

new_case "occ's own --help is still reachable"
occ_args user:add --help
expect_occ_args user:add --help

new_case "NEXTCLOUD_HOST unset"
run_script -NEXTCLOUD_HOST -- "${occ_sh}" status
expect_rc 1
expect_call_count ssh 0
expect_call_count clv-secret 0
run_script NEXTCLOUD_HOST= -- "${occ_sh}" status
expect_rc 1
expect_call_count ssh 0

section "occ.sh: CLOUVE_OPS_PASSWORD from the environment or from clv-secret"
for mode in environment clv-secret; do
  creds=()
  [ "${mode}" = clv-secret ] && creds=(-CLOUVE_OPS_PASSWORD)
  new_case "password from the ${mode}: quoting"
  run_script "${creds[@]}" -- "${occ_sh}" 'user:add' '--display-name=O'"'"'Brien "Bob" $HOME' '-g' 'Sales & Ops' '--' 'Mary Ann'
  expect_occ_args 'user:add' '--display-name=O'"'"'Brien "Bob" $HOME' '-g' 'Sales & Ops' '--' 'Mary Ann'
  expect_rc 0
  if [ "${mode}" = clv-secret ]; then
    expect_eq "clv-secret was asked for CLOUVE_OPS_PASSWORD once" "clv-secret CLOUVE_OPS_PASSWORD" "$(grep -E '^clv-secret ' "${FAKE_CALLS}")"
  else
    expect_call_count clv-secret 0
  fi
  new_case "password from the ${mode}: password on stdin"
  run_script "${creds[@]}" -- "${occ_sh}" --password-stdin user:resetpassword --password-from-env -- alice <<< "${tmp_pw}"
  expect_pass_sha "${tmp_sha}"
  expect_not_in_logs "${tmp_pw}"
done

new_case "no ops password anywhere"
run_script -CLOUVE_OPS_PASSWORD -FAKE_SECRET_CLOUVE_OPS_PASSWORD -- "${occ_sh}" status
expect_rc 1
expect_call_count ssh 0
if [[ "${err}" == *'clv-secret: CLOUVE_OPS_PASSWORD is not set on this server'* ]]; then ok "${case_label}: clv-secret's own message reaches stderr"
else bad "${case_label}: clv-secret's message was swallowed" "$(dump_case)"; fi
if [[ "${err}" == *'[nextcloud/occ] CLOUVE_OPS_PASSWORD is not set'* ]]; then ok "${case_label}: occ.sh says which password is missing"
else bad "${case_label}: occ.sh does not say which password is missing" "$(dump_case)"; fi

section "occ.sh: when ssh fails, and when occ fails"
cannot_reach='[nextcloud/occ] could not reach clouve-ops@nc.test'

new_case "host unreachable (ssh exits 255)"
FAKE_SSH_FAIL='nc.test=255'
occ_args status
expect_rc 255
expect_eq "stderr ends with the could-not-reach line" "${cannot_reach}" "$(tail -n 1 "${case_dir}/stderr")"
expect_eq "stdout is empty" "" "${out}"
expect_eq "ssh's own message is printed once" "1" "$(grep -c 'Connection refused' "${case_dir}/stderr")"
expect_call_count php 0

new_case "wrong ops password (sshpass exits 5)"
run_script CLOUVE_OPS_PASSWORD=not-the-password -- "${occ_sh}" status
expect_rc 255
expect_eq "stderr ends with the could-not-reach line" "${cannot_reach}" "$(tail -n 1 "${case_dir}/stderr")"
expect_call_count php 0

new_case "host key changed (sshpass exits 7)"
FAKE_SSH_FAIL='nc.test=7'
occ_args status
expect_rc 255
expect_eq "stderr ends with the could-not-reach line" "${cannot_reach}" "$(tail -n 1 "${case_dir}/stderr")"

new_case "occ upgrade fails with 5 (the code sshpass uses for a wrong password)"
FAKE_RC upgrade 5
FAKE_ERR upgrade 'Update failed'
occ_args --init-lock upgrade
expect_rc 5
expect_eq "stderr is occ's own, nothing added" "Update failed" "${err}"
expect_call_count ssh 2
expect_eq "the second ssh call only checks the channel" "true" "$(ssh_field 2 cmd)"
expect_eq "and it has the same options, host-key option included" "-n ${ssh_o}" "$(ssh_field 2 opts)"

new_case "php dies with 255 (a fatal error) while ssh works"
FAKE_RC status 255
FAKE_ERR status 'PHP Fatal error: Allowed memory size exhausted'
occ_args status
expect_rc 255
expect_eq "stderr is php's own, nothing added" "PHP Fatal error: Allowed memory size exhausted" "${err}"

new_case "occ fails with 1: no second ssh call"
FAKE_RC user:info 1
occ_args user:info nobody
expect_call_count ssh 1

section "the harness: answers that depend on the arguments"
new_case "FAKE_HANDLER"
FAKE_HANDLER config:app:get <<'HANDLER'
#!/bin/bash
case "$*" in
  "core lastcron") echo 1700000000 ;;
  *) exit 1 ;;
esac
HANDLER
occ_args config:app:get core lastcron
expect_stdout_is $'1700000000\n'
occ_args config:app:get core other
expect_rc 1

section "the harness: a script sent on stdin runs to the end"
# Task 6 runs backup.sh and restore.sh through `bash -s`. A fake that read the stdin it
# inherits would swallow the rest of the script, and nothing after the occ call would run.
script_text=$'echo before\nphp /var/www/html/occ status\necho after\n'
new_case "bash -s with an occ call in the middle"
run_script -- "${BASH}" -s < <(printf '%s' "${script_text}")
expect_eq "both echo lines ran" $'before\nafter' "${out}"
expect_occ_calls 1

new_case "the same script through the ssh channel (sudo bash -s)"
printf '%s' "${script_text}" > "${case_dir}/job.sh"
cat > "${case_dir}/send.sh" <<'SEND'
#!/bin/bash
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh -o LogLevel=ERROR "clouve-ops@${NEXTCLOUD_HOST}" 'sudo bash -s --' < "$1"
SEND
chmod +x "${case_dir}/send.sh"
run_script -- "${case_dir}/send.sh" "${case_dir}/job.sh"
expect_eq "both echo lines ran" $'before\nafter' "${out}"
expect_occ_calls 1
expect_channel_bytes "$(wc -c < "${case_dir}/job.sh" | tr -d ' ')"

# ===== temp-password.sh and lib/nextcloud-passwords.sh =======================
login_url='https://abc.clouve.app/login'
instruction="Ask them to change it after signing in (Settings > Security). Delete this file once it's handed over."

# pw_files: the names in the agent's password folder, one per line
pw_files() { ls -A "${pw_dir}" 2>/dev/null; }

# password_of <file>: the line of the file that is just a password
password_of() { [ -f "$1" ] || return 0; grep -E "${pw_line_re}" "$1" | head -n 1; }

# expect_password_file <file name> <login>: the file is in place with the right modes and content, the
# password in it is the one that reached occ, and that password is in no argv, environment, log or stream
expect_password_file() {
  local name="$1" login="$2" path="${pw_dir}/$1" value
  if [ ! -f "${path}" ]; then
    bad "${case_label}: there is no password file named '${name}' in the folder" "$(dump_case)"
    return
  fi
  expect_mode "${pw_dir}" 700 "the nextcloud-passwords folder"
  expect_mode "${path}" 600 "the password file"
  expect_eq "the file has one line that is just a password" 1 "$(grep -cE "${pw_line_re}" "${path}")"
  value="$(password_of "${path}")"
  expect_pass_sha "$(printf %s "${value}" | sha256sum | cut -d' ' -f1)"
  expect_not_in_logs "${value}" "${FAKE_ARGV_LOG}"
  expect_password_only_in_nc_pass "${value}"
  expect_eq "the file's login line" "Login: ${login}" "$(grep -m1 '^Login: ' "${path}")"
  expect_eq "the file's sign-in line" "Sign in at: ${login_url}" "$(grep -m1 '^Sign in at: ' "${path}")"
  if grep -qE '^Made: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC$' "${path}"; then ok "${case_label}: the file says when it was made, in UTC"
  else bad "${case_label}: no 'Made: <date> <time> UTC' line" "$(cat "${path}")"; fi
  if grep -qxF "${instruction}" "${path}"; then ok "${case_label}: the file asks them to change it and to delete the file"
  else bad "${case_label}: the instruction line is missing" "$(cat "${path}")"; fi
  expect_stdout_is "Saved the temporary password for ${login} to nextcloud-passwords/${name} in the Files pane."$'\n'
  expect_eq "stderr is empty" "" "${err}"
}

section "temp-password.sh: the files"
for f in "${temp_pw}" "${pw_lib}"; do
  [ -f "${f}" ] || bad "${f#"${scripts}"/} exists" "${f}"
done
# Git keeps only the owner's execute bit, so a checkout under another umask gives 775 or 664. The
# checks below ask for what the modes mean: a script is executable and not writable by others, a
# sourced file has no execute bit at all.
if [ -f "${temp_pw}" ]; then
  tp_mode="$(mode_of "${temp_pw}")"
  if [[ "${tp_mode}" =~ ^[0-7]+$ ]] && (( 8#${tp_mode} & 8#100 )) && ! (( 8#${tp_mode} & 8#002 )); then ok "temp-password.sh is executable and not world-writable (mode ${tp_mode}; 755 is the brief's)"
  else bad "temp-password.sh must be executable and not world-writable (mode ${tp_mode})"; fi
  if [ "$(head -n 1 "${temp_pw}")" = '#!/usr/bin/env bash' ]; then ok "temp-password.sh starts with #!/usr/bin/env bash"
  else bad "temp-password.sh does not start with #!/usr/bin/env bash"; fi
  if grep -qE '^[[:space:]]*(set[[:space:]]+-[A-Za-z]*x|set[[:space:]]+-o[[:space:]]+xtrace)' "${temp_pw}" "${pw_lib}"; then bad "a password script turns on set -x"
  else ok "neither file turns on set -x"; fi
  if grep -qE '^[[:space:]]*export[[:space:]]' "${temp_pw}" "${pw_lib}"; then bad "a password script exports a variable, and the password would go to every child"
  else ok "neither file exports a variable"; fi
fi
if [ -f "${pw_lib}" ]; then
  lib_mode="$(mode_of "${pw_lib}")"
  if [[ "${lib_mode}" =~ ^[0-7]+$ ]] && ! (( 8#${lib_mode} & 8#111 )) && ! (( 8#${lib_mode} & 8#002 )); then ok "lib/nextcloud-passwords.sh has no execute bit and is not world-writable (mode ${lib_mode}; 644 is the brief's)"
  else bad "lib/nextcloud-passwords.sh is sourced: no execute bit, not world-writable (mode ${lib_mode})"; fi
  if [ "$(head -c 2 "${pw_lib}")" != '#!' ]; then ok "lib/nextcloud-passwords.sh is sourced, so it has no shebang"
  else bad "lib/nextcloud-passwords.sh has a shebang"; fi
fi

section "temp-password.sh: --create, the brief's example"
new_pw_case "create"
before_min="$(date -u '+%Y-%m-%d %H:%M')"
run_script TZ=America/Los_Angeles -- "${temp_pw}" --create --display-name 'Mary Ann Lee' --email mary@example.com --group Staff 'Mary Ann' <<< "text on stdin that must be left alone"
after_min="$(date -u '+%Y-%m-%d %H:%M')"
expect_rc 0
mapfile -t pw_found < <(pw_files)
expect_eq "one file in ~/nextcloud-passwords" 1 "${#pw_found[@]}"
name="${pw_found[0]:-none}"
if [[ "${name}" =~ ^Mary_Ann-[0-9]{8}-[0-9]{6}\.txt$ ]]; then ok "${case_label}: the file is named <safe uid>-<UTC date>-<UTC time>.txt"
else bad "${case_label}: unexpected file name '${name}'"; fi
stamp="${name#Mary_Ann-}"
stamp="${stamp%.txt}"
file_min="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
if [ "${file_min}" = "${before_min}" ] || [ "${file_min}" = "${after_min}" ]; then ok "${case_label}: the name's time is UTC, though TZ was America/Los_Angeles"
else bad "${case_label}: the name's time is ${file_min}, UTC is ${before_min}"; fi
made="$(sed -n 's/^Made: \(.*\) UTC$/\1/p' "${pw_dir}/${name}")"
if [ "${made:0:16}" = "${before_min}" ] || [ "${made:0:16}" = "${after_min}" ]; then ok "${case_label}: the Made line is UTC too"
else bad "${case_label}: the Made line is '${made}', UTC is ${before_min}"; fi
expect_password_file "${name}" 'Mary Ann'
pw_value="$(password_of "${pw_dir}/${name}")"
expect_occ_sequence "user:add user:setting user:info"
expect_eq "user:add's arguments (no --email: that would mail a reset link)" \
  '["user:add","--password-from-env","--display-name=Mary Ann Lee","-g","Staff","--","Mary Ann"]' "$(occ_call_args 1)"
expect_eq "user:setting sets the email after the account exists" \
  '["user:setting","--","Mary Ann","settings","email","mary@example.com"]' "$(occ_call_args 2)"
expect_eq "user:info reads the account back" '["user:info","--output=json","--","Mary Ann"]' "$(occ_call_args 3)"
expect_eq "only user:add's ssh call carried the password, as one line" "$(line_bytes "${pw_value}") 0 0" "$(ssh_field 1 stdin_bytes) $(ssh_field 2 stdin_bytes) $(ssh_field 3 stdin_bytes)"
expect_eq "the other two ssh calls had stdin closed" "closed closed" "$(ssh_field 2 stdin) $(ssh_field 3 stdin)"
if grep -qx 'user:add: password file already saved: yes' "${FAKE_CALLS}"; then ok "${case_label}: the file was saved before Nextcloud was changed"
else bad "${case_label}: user:add ran before the password was saved" "$(dump_case)"; fi
if grep -q '^tr ' "${FAKE_ARGV_LOG}" && grep -q '^jq ' "${FAKE_ARGV_LOG}"; then ok "${case_label}: the argv log saw the generator's tr and the read-back's jq"
else bad "${case_label}: the argv shims did not see tr and jq, so the sweeps prove nothing" "$(cat "${FAKE_ARGV_LOG}")"; fi
expect_eq "the agent's home holds only nextcloud-passwords" "nextcloud-passwords" "$(ls -A "${pw_home}")"
expect_eq "no temp files left" "" "$(ls -A "${case_dir}/tmp")"

new_pw_case "create: NEXTCLOUD_URL ends in a slash"
run_script NEXTCLOUD_URL=https://abc.clouve.app/ -- "${temp_pw}" --create 'Mary Ann'
expect_rc 0
mapfile -t pw_found < <(pw_files)
expect_password_file "${pw_found[0]:-none}" 'Mary Ann'

section "temp-password.sh: a reset of an account that exists"
new_pw_case "reset"
seed_user 'Mary Ann' 'Mary Ann Lee' mary@example.com Staff
run_script -- "${temp_pw}" 'Mary Ann' <<< "text on stdin that must be left alone"
expect_rc 0
mapfile -t pw_found < <(pw_files)
expect_eq "one file in ~/nextcloud-passwords" 1 "${#pw_found[@]}"
name="${pw_found[0]:-none}"
if [[ "${name}" =~ ^Mary_Ann-[0-9]{8}-[0-9]{6}\.txt$ ]]; then ok "${case_label}: the file is named <safe uid>-<UTC date>-<UTC time>.txt"
else bad "${case_label}: unexpected file name '${name}'"; fi
expect_password_file "${name}" 'Mary Ann'
pw_value="$(password_of "${pw_dir}/${name}")"
expect_occ_sequence "user:info app:list user:resetpassword"
expect_eq "the account is looked up first" '["user:info","--output=json","--","Mary Ann"]' "$(occ_call_args 1)"
expect_eq "then the encryption app" '["app:list","--output=json"]' "$(occ_call_args 2)"
expect_eq "user:resetpassword's arguments" '["user:resetpassword","--password-from-env","--","Mary Ann"]' "$(occ_call_args 3)"
expect_eq "only the reset's ssh call carried the password, as one line" "0 0 $(line_bytes "${pw_value}")" "$(ssh_field 1 stdin_bytes) $(ssh_field 2 stdin_bytes) $(ssh_field 3 stdin_bytes)"
if grep -qx 'user:resetpassword: password file already saved: yes' "${FAKE_CALLS}"; then ok "${case_label}: the file was saved before the password was reset"
else bad "${case_label}: user:resetpassword ran before the password was saved" "$(dump_case)"; fi

new_pw_case "reset: the uid in another case finds the account, and the reset and the file use its login as Nextcloud spells it"
seed_user 'Mary Ann'
run_script -- "${temp_pw}" 'mary ann'
expect_rc 0
mapfile -t pw_found < <(pw_files)
expect_password_file "${pw_found[0]:-none}" 'Mary Ann'
expect_eq "user:resetpassword's arguments" '["user:resetpassword","--password-from-env","--","Mary Ann"]' "$(occ_call_args 3)"

new_pw_case "reset: user:info gives no user_id: refused, nothing written or changed"
seed_user 'Mary Ann'
FAKE_INFO_NO_UID=1
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 2
expect_occ_sequence "user:info"
expect_eq "nothing was saved" "" "$(pw_files)"
if [[ "${err}" == *'could not read the login of "Mary Ann" (user:info gave no user_id). Nothing was changed.'* ]]; then ok "${case_label}: stderr says why"
else bad "${case_label}: stderr should say user:info gave no user_id" "$(dump_case)"; fi

new_pw_case "reset: an account that does not exist"
run_script -- "${temp_pw}" 'Nobody Here'
expect_rc 2
expect_occ_sequence "user:info"
expect_eq "nothing was saved" "" "$(pw_files)"
expect_eq "stdout is empty" "" "${out}"
if [[ "${err}" == *'Nobody Here'* && "${err}" == *'--create'* ]]; then ok "${case_label}: stderr names the account and says --create makes it"
else bad "${case_label}: the message should name the account and --create" "$(dump_case)"; fi
expect_no_password_text

section "temp-password.sh: resets it will not do"
# The main admin: its password is the one on the Clouve dashboard, and a reset would put the two out of step.
for pair in "admin|admin" "admin|ADMIN" "Admin|admin" "ADMIN|Admin"; do
  admin_user="${pair%%|*}"
  reset_uid="${pair#*|}"
  new_pw_case "reset of ${reset_uid} while NEXTCLOUD_ADMIN_USER is ${admin_user}"
  seed_user "${reset_uid}"
  run_script NEXTCLOUD_ADMIN_USER="${admin_user}" -- "${temp_pw}" "${reset_uid}"
  expect_rc 2
  expect_occ_calls 0
  expect_call_count ssh 0
  expect_eq "stdout is empty" "" "${out}"
  if [[ "${err}" == *'main admin'* && "${err}" == *'Clouve dashboard'* && "${err}" == *'playbooks/regain-admin-access.md'* ]]; then ok "${case_label}: stderr says why and points to the playbook"
  else bad "${case_label}: the message should say it is the main admin, mention the Clouve dashboard and name playbooks/regain-admin-access.md" "$(dump_case)"; fi
  if [ ! -e "${pw_dir}" ]; then ok "${case_label}: nothing was written, not even the folder"
  else bad "${case_label}: something was written under the password folder: $(ls -A "${pw_dir}")"; fi
done

new_pw_case "NEXTCLOUD_ADMIN_USER unset or empty: an account called admin is reset like any other"
seed_user admin
run_script -NEXTCLOUD_ADMIN_USER -- "${temp_pw}" admin
expect_rc 0
run_script NEXTCLOUD_ADMIN_USER= -- "${temp_pw}" admin
expect_rc 0

new_pw_case "creating the main admin is not a reset: occ says the account exists"
seed_user admin
run_script -- "${temp_pw}" --create admin
expect_rc 2
expect_occ_sequence "user:add user:info"
if [[ "${err}" == *'The account "admin" already exists.'* && "${err}" != *'main admin'* ]]; then ok "${case_label}: it is occ that refuses, not the guard"
else bad "${case_label}: expected occ's 'already exists' and no mention of the main admin" "$(dump_case)"; fi

# Nextcloud finds an account by its email address too (Database::userExists), and in any case. The checks go by the
# login that user:info returns, so the main admin's email can't get past the guard, and another account's email is
# never reset by mistake.
new_pw_case "reset by the main admin's email address: refused like the login"
seed_user Jane_Doe 'Jane Doe' jane@acme.com
run_script NEXTCLOUD_ADMIN_USER=Jane_Doe -- "${temp_pw}" jane@acme.com
expect_rc 2
expect_occ_sequence "user:info"
expect_eq "nothing was saved" "" "$(pw_files)"
if [[ "${err}" == *'"jane@acme.com" finds "Jane_Doe", this deployment'"'"'s main admin'* && "${err}" == *'Clouve dashboard'* && "${err}" == *'playbooks/regain-admin-access.md'* ]]; then ok "${case_label}: stderr says whose email it is and points to the playbook"
else bad "${case_label}: the message should say the email finds the main admin and point to the playbook" "$(dump_case)"; fi
expect_no_password_text

new_pw_case "reset by another account's email address: refused, and the message names the login"
seed_user mary 'Mary Ann' mary@acme.com
run_script -- "${temp_pw}" mary@acme.com
expect_rc 2
expect_occ_sequence "user:info"
expect_eq "nothing was saved" "" "$(pw_files)"
if [[ "${err}" == *'"mary@acme.com" is not a login: Nextcloud found the account "mary"'* && "${err}" == *'temp-password.sh -- mary'* ]]; then ok "${case_label}: stderr names the login and the command to run once the user confirms"
else bad "${case_label}: the message should name the login mary and the command" "$(dump_case)"; fi
expect_no_password_text

new_pw_case "reset by the login in another case: done, for the account's own spelling"
seed_user mary 'Mary Ann' mary@acme.com
run_script -- "${temp_pw}" MARY
expect_rc 0
expect_occ_sequence "user:info app:list user:resetpassword"
mapfile -t pw_found < <(pw_files)
expect_password_file "${pw_found[0]:-none}" mary
expect_eq "occ reset the account's own login" "mary" "$(tail -n 1 "${FAKE_OCC_LOG}" | jq -r '.[-1]' 2>/dev/null)"

new_pw_case "--create with an existing account's email address: no advice to reset with that name"
seed_user mary 'Mary Ann' mary@acme.com
run_script -- "${temp_pw}" --create mary@acme.com
expect_rc 2
expect_occ_sequence "user:add user:info"
if [[ "${err}" == *'"mary@acme.com" is not a free login: Nextcloud finds the account "mary"'* && "${err}" != *'run this again without --create'* ]]; then ok "${case_label}: stderr names the account the address belongs to, and doesn't advise a reset with the address"
else bad "${case_label}: the message should name mary and not advise running again without --create" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"

# Per-user encryption keys: a reset regenerates the user's keys and their encrypted files become unreadable.
# <label> <FAKE_ENCRYPTION> <FAKE_MASTER_KEY> <wanted exit> <wanted occ calls>
reset_with_encryption() {
  new_pw_case "reset: $1"
  seed_user alice
  FAKE_ENCRYPTION="$2"
  FAKE_MASTER_KEY="$3"
  run_script -- "${temp_pw}" alice
  expect_rc "$4"
  expect_occ_sequence "$5"
}
reset_with_encryption "the encryption app is disabled" "" "" 0 "user:info app:list user:resetpassword"
reset_with_encryption "the encryption app is disabled, though useMasterKey says 0" "" 0 0 "user:info app:list user:resetpassword"
reset_with_encryption "encryption is on and useMasterKey is not set (the default is the master key)" enabled "" 0 "user:info app:list config:app:get user:resetpassword"

# The stored text is read as Nextcloud's getValueBool reads it: on only for 1, true, yes and on, in any case
# and with nothing around the word. Everything else, an empty string included, means the master key is off.
for value in 1 true TRUE True yes Yes on ON; do
  reset_with_encryption "encryption is on and useMasterKey is stored as '${value}' (master key on)" enabled "${value}" 0 "user:info app:list config:app:get user:resetpassword"
done
for value in 0 false No off OFF maybe ' 1' '1 ' blank; do
  shown="${value}"
  label="'${value}'"
  if [ "${value}" = blank ]; then shown=""; label="an empty string"; fi
  reset_with_encryption "encryption is on and useMasterKey is stored as ${label} (master key off)" enabled "${value}" 2 "user:info app:list config:app:get"
  if [[ "${err}" == *'per-user keys'* && "${err}" == *"stored as \"${shown}\", which Nextcloud reads as off"* && "${err}" == *'unreadable'* && "${err}" == *'nothing was changed'* ]]; then ok "${case_label}: stderr shows the stored value, explains the keys and says nothing was changed"
  else bad "${case_label}: the message should show the stored value, say Nextcloud reads it as off, explain the keys and say nothing was changed" "$(dump_case)"; fi
  expect_eq "stdout is empty" "" "${out}"
  expect_eq "nothing was saved" "" "$(pw_files)"
done
expect_no_password_text

reset_with_encryption "app:list fails, so nobody can tell whether encryption is on" fail "" 2 "user:info app:list"
if [[ "${err}" == *'could not tell whether the encryption app is on'* && "${err}" == *'Could not list the apps.'* ]]; then ok "${case_label}: stderr says it could not tell, and shows occ's text"
else bad "${case_label}: the message should say it could not tell and show occ's text" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"
reset_with_encryption "app:list prints no JSON" nojson "" 2 "user:info app:list"
expect_eq "nothing was saved" "" "$(pw_files)"
reset_with_encryption "app:list prints JSON with no list of enabled apps" odd "" 2 "user:info app:list"
if [[ "${err}" == *'could not read the app list'* ]]; then ok "${case_label}: stderr says it could not read the app list"
else bad "${case_label}: expected 'could not read the app list'" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"
reset_with_encryption "encryption is on and useMasterKey cannot be read" enabled fail 2 "user:info app:list config:app:get"
if [[ "${err}" == *"could not read the encryption app's useMasterKey"* && "${err}" == *'Could not read the setting.'* ]]; then ok "${case_label}: stderr says it could not read the setting, and shows occ's text"
else bad "${case_label}: the message should say it could not read useMasterKey and show occ's text" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"
# An unset key is exit 1 with no output. Exit 1 with text is an error that occ turned into 1 (an exception whose code
# is no number, such as a PDOException's SQLSTATE), so the script can't tell, and refuses.
reset_with_encryption "encryption is on and config:app:get exits 1 with an error, not with silence" enabled exception 2 "user:info app:list config:app:get"
if [[ "${err}" == *"could not read the encryption app's useMasterKey (config:app:get, exit 1)"* && "${err}" == *'SQLSTATE[HY000]'* ]]; then ok "${case_label}: stderr says it could not read the setting, with exit 1, and shows occ's error"
else bad "${case_label}: the message should say it could not read useMasterKey (exit 1) and show occ's error" "$(dump_case)"; fi
expect_eq "stdout is empty" "" "${out}"
expect_eq "nothing was saved" "" "$(pw_files)"

new_pw_case "creating an account is not held up by per-user encryption keys"
FAKE_ENCRYPTION=enabled
FAKE_MASTER_KEY=0
run_script -- "${temp_pw}" --create alice
expect_rc 0
expect_occ_sequence "user:add user:info"

section "temp-password.sh: when Nextcloud refuses, the file goes and occ's message is shown"
policy_msg='Password is among the 1,000,000 most common ones. Please make it unique.'
for stream in stdout stderr; do
  new_pw_case "create: policy failure, message on ${stream}"
  rm -f "${FAKE_OCC}/user:add.handler"
  if [ "${stream}" = stdout ]; then FAKE_OUT user:add "${policy_msg}"; else FAKE_ERR user:add "${policy_msg}"; fi
  FAKE_RC user:add 1
  run_script -- "${temp_pw}" --create --email mary@example.com 'Mary Ann'
  expect_rc 2
  expect_occ_sequence "user:add user:info"   # it looked, and found no account
  if [[ "${err}" == *"${policy_msg}"* ]]; then ok "${case_label}: occ's message is on stderr"
  else bad "${case_label}: occ's message did not reach stderr" "$(dump_case)"; fi
  expect_eq "stdout is empty" "" "${out}"
  expect_eq "no file is left" "" "$(pw_files)"
  if [[ "${err}" == *'finds no account "Mary Ann", so nothing was made'* ]]; then ok "${case_label}: it says no account was made"
  else bad "${case_label}: expected 'finds no account \"Mary Ann\", so nothing was made'" "$(dump_case)"; fi
  expect_call_count shred 1
  expect_eq "the password did reach occ (so it was the policy that said no)" 1 "$(wc -l < "${FAKE_OCC_LOG}.pass" | tr -d ' ')"
  expect_no_password_text
done

new_pw_case "create: occ refuses and the password file cannot be deleted either"
rm -f "${FAKE_OCC}/user:add.handler"
FAKE_OUT user:add "${policy_msg}"
FAKE_RC user:add 1
FAKE_SHRED_FAIL=1
FAKE_RM_FAIL=1
run_script -- "${temp_pw}" --create 'Mary Ann'
expect_rc 2
mapfile -t pw_found < <(pw_files)
expect_eq "the file is still there" 1 "${#pw_found[@]}"
if [[ "${err}" == *"nextcloud-passwords/${pw_found[0]:-none} could not be deleted"* ]]; then ok "${case_label}: stderr names the file it could not delete"
else bad "${case_label}: the message should name the file it could not delete" "$(dump_case)"; fi
if [[ "${err}" != *'so nothing is saved'* ]]; then ok "${case_label}: it does not claim the file was deleted"
else bad "${case_label}: it claims the file was deleted" "$(dump_case)"; fi

new_pw_case "create: the password policy of the fake store itself (10 characters, upper, lower, digit)"
FAKE_PW_POLICY='upper lower digit'
run_script -- "${temp_pw}" --create alice
expect_rc 0
expect_password_file "$(pw_files)" alice

new_pw_case "create: a policy that wants 30 characters refuses the 20 and nothing is left"
FAKE_PW_MINLEN=30
run_script -- "${temp_pw}" --create alice
expect_rc 2
if [[ "${err}" == *'Password needs to be at least 30 characters long.'* ]]; then ok "${case_label}: the policy's message is shown"
else bad "${case_label}: the policy's message is missing" "$(dump_case)"; fi
expect_eq "no file is left" "" "$(pw_files)"

new_pw_case "create: the account already exists"
seed_user 'Mary Ann'
run_script -- "${temp_pw}" --create 'Mary Ann'
expect_rc 2
expect_occ_sequence "user:add user:info"
if [[ "${err}" == *'The account "Mary Ann" already exists.'* ]]; then ok "${case_label}: occ's message is on stderr"
else bad "${case_label}: occ's message is missing" "$(dump_case)"; fi
if [[ "${err}" == *'To give it a new password, run this again without --create'* ]]; then ok "${case_label}: it says how to give the existing account a new password"
else bad "${case_label}: expected the advice to run again without --create" "$(dump_case)"; fi
expect_eq "no file is left" "" "$(pw_files)"

new_pw_case "reset: the policy refuses the password"
seed_user 'Mary Ann'
FAKE_PW_MINLEN=30
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 2
expect_occ_sequence "user:info app:list user:resetpassword"
if [[ "${err}" == *'Password needs to be at least 30 characters long.'* ]]; then ok "${case_label}: the policy's message is shown"
else bad "${case_label}: the policy's message is missing" "$(dump_case)"; fi
expect_eq "no file is left" "" "$(pw_files)"

new_pw_case "occ echoes the password in its refusal: the script hides it"
FAKE_ECHO_PW_FILE="${case_dir}/echoed-password"
run_script -- "${temp_pw}" --create alice
expect_rc 2
echoed="$(cat "${case_dir}/echoed-password" 2>/dev/null)"
if [[ "${echoed}" =~ ${pw_line_re} ]]; then ok "${case_label}: the fake did receive and echo a password"
else bad "${case_label}: the fake saw no password" "$(dump_case)"; fi
expect_not_in_logs "${echoed}" "${FAKE_ARGV_LOG}"
expect_password_only_in_nc_pass "${echoed}"
if [[ "${err}" == *'Rejected the password [password hidden]'* ]]; then ok "${case_label}: the message is shown with the password hidden"
else bad "${case_label}: expected 'Rejected the password [password hidden]'" "$(dump_case)"; fi
expect_eq "no file is left" "" "$(pw_files)"

section "temp-password.sh: the container cannot be reached"
new_pw_case "a reset"
seed_user alice
FAKE_SSH_FAIL='nc.test=255'
run_script -- "${temp_pw}" alice
expect_rc 2
if [[ "${err}" == *'could not look up the account "alice"'* && "${err}" == *'[nextcloud/occ] could not reach clouve-ops@nc.test'* ]]; then ok "${case_label}: stderr says the lookup failed and why"
else bad "${case_label}: the message should say the lookup failed and why" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"

new_pw_case "a create"
FAKE_SSH_FAIL='nc.test=255'
run_script -- "${temp_pw}" --create alice
expect_rc 2
if [[ "${err}" == *'occ could not make the account "alice" (exit 255)'* && "${err}" == *'[nextcloud/occ] could not reach clouve-ops@nc.test'* ]]; then ok "${case_label}: stderr says the account was not made and why"
else bad "${case_label}: the message should say the account was not made and why" "$(dump_case)"; fi
expect_eq "no file is left" "" "$(pw_files)"
expect_call_count ssh 2   # user:add and occ.sh's check of the channel; nothing was made, so it did not look again
if [[ "${err}" == *'If the account was made before the error, run this again without --create to give it a password.'* && "${err}" != *'finds no account'* ]]; then ok "${case_label}: the advice stays conditional, since nothing could be checked"
else bad "${case_label}: expected the conditional advice and no 'finds no account'" "$(dump_case)"; fi
expect_no_password_text

section "temp-password.sh: runs in the same second do not overwrite each other"
new_pw_case "three resets of one account at one fixed second"
seed_user 'Mary Ann'
FAKE_NOW='2026-10-23 10:15:42'
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 0
first_file="Mary_Ann-20261023-101542.txt"
expect_eq "the first run's file name" "${first_file}" "$(pw_files)"
first_sum="$(cksum < "${pw_dir}/${first_file}")"
first_pw="$(password_of "${pw_dir}/${first_file}")"
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 0
expect_stdout_is "Saved the temporary password for Mary Ann to nextcloud-passwords/Mary_Ann-20261023-101542-2.txt in the Files pane."$'\n'
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 0
expect_stdout_is "Saved the temporary password for Mary Ann to nextcloud-passwords/Mary_Ann-20261023-101542-3.txt in the Files pane."$'\n'
expect_eq "the three files" $'Mary_Ann-20261023-101542-2.txt\nMary_Ann-20261023-101542-3.txt\nMary_Ann-20261023-101542.txt' "$(pw_files | LC_ALL=C sort)"
expect_eq "the first file is untouched" "${first_sum}" "$(cksum < "${pw_dir}/${first_file}")"
expect_eq "the three passwords differ" 3 "$(for f in "${pw_dir}"/*; do password_of "${f}"; done | sort -u | wc -l | tr -d ' ')"
expect_mode "${pw_dir}/Mary_Ann-20261023-101542-3.txt" 600 "the third file"
expect_eq "the first password is still in the first file" "${first_pw}" "$(password_of "${pw_dir}/${first_file}")"

new_pw_case "a link that points nowhere is on the first-choice file name"
seed_user 'Mary Ann'
FAKE_NOW='2026-10-23 10:15:42'
mkdir -p "${pw_dir}"
chmod 700 "${pw_dir}"
ln -s "${case_dir}/nowhere" "${pw_dir}/Mary_Ann-20261023-101542.txt"
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 0
expect_stdout_is "Saved the temporary password for Mary Ann to nextcloud-passwords/Mary_Ann-20261023-101542-2.txt in the Files pane."$'\n'
if [ -L "${pw_dir}/Mary_Ann-20261023-101542.txt" ] && [ ! -e "${case_dir}/nowhere" ]; then ok "${case_label}: the link was left alone and nothing was written through it"
else bad "${case_label}: the link was touched, or something was written through it"; fi

section "temp-password.sh: occ said yes, so the account is read back"
new_pw_case "create: user:add exits 0 and creates nothing"
FAKE_ADD_NOOP=1
run_script -- "${temp_pw}" --create alice
expect_rc 2
expect_occ_sequence "user:add user:info"
expect_eq "stdout is empty" "" "${out}"
if [[ "${err}" == *'user:info'* && "${err}" == *'alice'* ]]; then ok "${case_label}: stderr says user:info could not find the account"
else bad "${case_label}: the message should say user:info could not find alice" "$(dump_case)"; fi
mapfile -t pw_found < <(pw_files)
expect_eq "the file stays, since the account may exist" 1 "${#pw_found[@]}"
if [[ "${err}" == *"nextcloud-passwords/${pw_found[0]:-none}"* ]]; then ok "${case_label}: the message names the kept file"
else bad "${case_label}: the message should name the kept file" "$(dump_case)"; fi
kept_pw="$(password_of "${pw_dir}/${pw_found[0]:-none}")"
expect_not_in_logs "${kept_pw}" "${FAKE_ARGV_LOG}"
expect_password_only_in_nc_pass "${kept_pw}"

new_pw_case "create: user:setting exits 0 and stores no email"
FAKE_SETTING_NOOP=1
run_script -- "${temp_pw}" --create --email mary@example.com alice
expect_rc 2
expect_occ_sequence "user:add user:setting user:info"
if [[ "${err}" == *'email'* ]]; then ok "${case_label}: stderr says the email is wrong"
else bad "${case_label}: the message should name the email" "$(dump_case)"; fi
expect_eq "the file stays, since the account exists" 1 "$(pw_files | wc -l | tr -d ' ')"
expect_eq "stdout is empty" "" "${out}"

new_pw_case "create: the group was silently skipped"
FAKE_GROUP_FAIL=Staff
run_script -- "${temp_pw}" --create --group Sales --group Staff alice
expect_rc 2
if [[ "${err}" == *'not in group Staff'* && "${err}" != *'not in group Sales'* ]]; then ok "${case_label}: stderr names the group that is missing, and only that one"
else bad "${case_label}: expected 'not in group Staff' alone" "$(dump_case)"; fi
expect_eq "the file stays" 1 "$(pw_files | wc -l | tr -d ' ')"

new_pw_case "create: user:info shows another account than the one asked for"
FAKE_ADD_LOGIN=somebody-else
run_script -- "${temp_pw}" --create alice
expect_rc 2
if [[ "${err}" == *'login is somebody-else'* ]]; then ok "${case_label}: stderr says whose account user:info showed"
else bad "${case_label}: expected 'login is somebody-else'" "$(dump_case)"; fi
expect_eq "the file stays" 1 "$(pw_files | wc -l | tr -d ' ')"

new_pw_case "create: user:info exits 0 but prints no JSON"
FAKE_INFO_NOJSON=1
run_script -- "${temp_pw}" --create alice
expect_rc 2
if [[ "${err}" == *'could not read it back'* && "${err}" == *'maintenance mode'* ]]; then ok "${case_label}: stderr says it could not read the account back and shows what occ printed"
else bad "${case_label}: the message should say the read-back failed and show occ's text" "$(dump_case)"; fi
expect_eq "the file stays" 1 "$(pw_files | wc -l | tr -d ' ')"

new_pw_case "reset: user:info exits 0 but prints no JSON"
seed_user alice
FAKE_INFO_NOJSON=1
run_script -- "${temp_pw}" alice
expect_rc 2
expect_occ_sequence "user:info"
if [[ "${err}" == *'could not look up the account "alice"'* && "${err}" == *'maintenance mode'* ]]; then ok "${case_label}: stderr says it could not look the account up and shows what occ printed"
else bad "${case_label}: the message should say the lookup failed and show occ's text" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"

new_pw_case "create: a PHP warning comes before user:info's JSON"
FAKE_INFO_NOISE=1
run_script -- "${temp_pw}" --create --group Staff alice
expect_rc 0

new_pw_case "reset: a PHP warning comes before user:info's JSON"
seed_user alice
FAKE_INFO_NOISE=1
run_script -- "${temp_pw}" alice
expect_rc 0

new_pw_case "create: user:setting fails after the account was made"
FAKE_SETTING_FAIL=1
run_script -- "${temp_pw}" --create --email mary@example.com alice
expect_rc 2
expect_occ_sequence "user:add user:setting"
mapfile -t pw_found < <(pw_files)
expect_eq "the file stays, since the password is set" 1 "${#pw_found[@]}"
if [[ "${err}" == *'Could not save the setting.'* && "${err}" == *'alice'* && "${err}" == *"nextcloud-passwords/${pw_found[0]:-none}"* ]]; then
  ok "${case_label}: stderr shows occ's message, says the account exists and names the file"
else bad "${case_label}: the message should show occ's text, the account and the file" "$(dump_case)"; fi
expect_eq "stdout is empty" "" "${out}"

new_pw_case "create: the email comes back lower-cased and the display name trimmed, and that is fine"
run_script -- "${temp_pw}" --create --email 'Mary.Ann@Example.COM' --display-name '  Mary Ann  ' --group Staff 'Mary Ann'
expect_rc 0
expect_eq "user:setting got the address as typed" '["user:setting","--","Mary Ann","settings","email","Mary.Ann@Example.COM"]' "$(occ_call_args 2)"

new_pw_case "create: the account is in a group spelled in another case, which is another group"
FAKE_GROUP_CASE='staff=Staff'
run_script -- "${temp_pw}" --create --group staff alice
expect_rc 2
if [[ "${err}" == *'not in group staff'* ]]; then ok "${case_label}: stderr says the group that was asked for is missing"
else bad "${case_label}: expected 'not in group staff'" "$(dump_case)"; fi

new_pw_case "create: the display name was not set"
FAKE_ADD_NODISPLAY=1
run_script -- "${temp_pw}" --create --display-name 'Mary Ann Lee' 'Mary Ann'
expect_rc 2
if [[ "${err}" == *'display name is "Mary Ann"'* ]]; then ok "${case_label}: stderr says what the display name is"
else bad "${case_label}: expected 'display name is \"Mary Ann\"'" "$(dump_case)"; fi
expect_eq "the file stays" 1 "$(pw_files | wc -l | tr -d ' ')"

section "temp-password.sh: user:add fails after it made the account (the file is then the only copy)"
new_pw_case "the display name step throws: the account has the password and nothing else"
FAKE_ADD_FAIL_AFTER=account
run_script -- "${temp_pw}" --create --display-name 'Mary Ann Lee' --email mary@example.com --group Staff 'Mary Ann'
expect_rc 2
expect_occ_sequence "user:add user:info"   # it looked, and the account was there
mapfile -t pw_found < <(pw_files)
expect_eq "the file is kept" 1 "${#pw_found[@]}"
expect_eq "stdout is empty" "" "${out}"
for want in 'Invalid displayname' 'occ made the account "Mary Ann" before it failed' 'display name is "Mary Ann"' 'email is ""' 'not in group Staff' \
  'user:setting (display name, email) and group:adduser (groups)' "nextcloud-passwords/${pw_found[0]:-none} was kept"; do
  if [[ "${err}" == *"${want}"* ]]; then ok "${case_label}: stderr has '${want}'"
  else bad "${case_label}: stderr should have '${want}'" "$(dump_case)"; fi
done
kept_pw="$(password_of "${pw_dir}/${pw_found[0]:-none}")"
expect_pass_sha "$(printf %s "${kept_pw}" | sha256sum | cut -d' ' -f1)"
expect_not_in_logs "${kept_pw}" "${FAKE_ARGV_LOG}"
expect_password_only_in_nc_pass "${kept_pw}"

new_pw_case "the groups step throws: the display name is there, the groups and the email are not"
FAKE_ADD_FAIL_AFTER=display
run_script -- "${temp_pw}" --create --display-name 'Mary Ann Lee' --email mary@example.com --group Staff 'Mary Ann'
expect_rc 2
expect_eq "the file is kept" 1 "$(pw_files | wc -l | tr -d ' ')"
if [[ "${err}" == *'not in group Staff'* && "${err}" == *'email is ""'* && "${err}" != *'display name is'* ]]; then ok "${case_label}: stderr lists what is missing and not the display name that is there"
else bad "${case_label}: expected the groups and the email missing, and no 'display name is' line" "$(dump_case)"; fi

new_pw_case "user:add throws and nothing but the account was asked for"
FAKE_ADD_FAIL_AFTER=account
run_script -- "${temp_pw}" --create alice
expect_rc 2
expect_eq "the file is kept" 1 "$(pw_files | wc -l | tr -d ' ')"
if [[ "${err}" == *'before it failed'* && "${err}" != *'does not match'* ]]; then ok "${case_label}: stderr says the account exists and lists nothing as missing"
else bad "${case_label}: expected 'before it failed' and no list of what is missing" "$(dump_case)"; fi

section "temp-password.sh: when the file cannot be written, Nextcloud is left alone (exit 3)"
new_pw_case "the nextcloud-passwords folder is a regular file"
printf 'not a folder\n' > "${pw_dir}"
run_script -- "${temp_pw}" --create alice
expect_rc 3
expect_occ_calls 0
expect_call_count ssh 0
if [[ "${err}" == *'could not set up ~/nextcloud-passwords; nothing was changed in Nextcloud'* ]]; then ok "${case_label}: stderr says the folder could not be set up and nothing was changed in Nextcloud"
else bad "${case_label}: the message should say the folder could not be set up and nothing was changed in Nextcloud" "$(dump_case)"; fi
expect_eq "the file that was in the way is untouched" "not a folder" "$(cat "${pw_dir}")"
seed_user 'Mary Ann'
run_script -- "${temp_pw}" 'Mary Ann'
expect_rc 3
expect_occ_sequence "user:info app:list"   # the lookups are read-only; the reset never ran

new_pw_case "create: the password file cannot be written (the disk is full)"
FAKE_CAT_FAIL=1
run_script -- "${temp_pw}" --create alice
expect_rc 3
expect_occ_calls 0
expect_call_count ssh 0
if [[ "${err}" == *'could not save nextcloud-passwords/alice-'* && "${err}" == *'nothing was changed in Nextcloud'* ]]; then ok "${case_label}: stderr names the file and says nothing was changed in Nextcloud"
else bad "${case_label}: the message should name the file and say nothing was changed in Nextcloud" "$(dump_case)"; fi
expect_eq "no half-written file is left" "" "$(pw_files)"
seed_user alice
run_script -- "${temp_pw}" alice
expect_rc 3
expect_occ_sequence "user:info app:list"   # the reset never ran

if [ "$(id -u)" -ne 0 ]; then
  new_pw_case "the home folder is read-only, so the folder cannot be made"
  chmod 500 "${pw_home}"
  run_script -- "${temp_pw}" --create alice
  expect_rc 3
  expect_occ_calls 0
  chmod 700 "${pw_home}"
else
  ok "running as root: a read-only home cannot be tested here, so that case is skipped"
fi

section "temp-password.sh: the environment (exit 1)"
for missing in NEXTCLOUD_URL NEXTCLOUD_HOST HOME; do
  for how in unset empty; do
    new_pw_case "${missing} ${how}"
    if [ "${how}" = unset ]; then run_script "-${missing}" -- "${temp_pw}" --create alice
    else run_script "${missing}=" -- "${temp_pw}" --create alice; fi
    expect_rc 1
    expect_occ_calls 0
    expect_call_count ssh 0
    if [[ "${err}" == *"${missing}"* ]]; then ok "${case_label}: stderr names ${missing}"
    else bad "${case_label}: the message should name ${missing}" "$(dump_case)"; fi
    expect_eq "nothing was saved" "" "$(pw_files)"
  done
done
new_pw_case "jq is not installed"
mkdir -p "${case_dir}/nojq-bin"
for f in /usr/bin/*; do [ "${f##*/}" = jq ] || printf '%s\0' "${f}"; done | xargs -0 ln -sf -t "${case_dir}/nojq-bin"   # everything the script needs, bar jq
run_script PATH="${bin}:${case_dir}/nojq-bin" -- "${temp_pw}" --create alice
expect_rc 1
expect_occ_calls 0
if [[ "${err}" == *'jq is not installed'* ]]; then ok "${case_label}: stderr says jq is missing"; else bad "${case_label}: the message should say jq is missing" "$(dump_case)"; fi
expect_eq "nothing was saved" "" "$(pw_files)"

new_pw_case "HOME is a folder that does not exist"
run_script HOME="${case_dir}/nowhere" -- "${temp_pw}" --create alice
expect_rc 1
expect_occ_calls 0
if [ ! -e "${case_dir}/nowhere" ]; then ok "${case_label}: the missing home was not made"
else bad "${case_label}: the script made the missing home folder"; fi

section "temp-password.sh: usage (exit 64)"
expect_usage_error() { # expect_usage_error <label> <temp-password.sh arguments...>
  new_pw_case "usage: $1"
  shift
  run_script -- "${temp_pw}" "$@"
  expect_rc 64
  if [[ "${err}" == *'Usage: temp-password.sh [--create] [--display-name NAME] [--email ADDR] [--group GROUP]... <uid>'* ]]; then ok "${case_label}: the usage is on stderr"
  else bad "${case_label}: no usage line on stderr" "$(dump_case)"; fi
  expect_call_count ssh 0
  expect_eq "nothing was saved" "" "$(pw_files)"
}
expect_usage_error "no arguments"
expect_usage_error "two accounts" alice bob
expect_usage_error "an empty account name" ''
expect_usage_error "an unknown option" --frobnicate alice
expect_usage_error "a uid that starts with a dash needs --" -weird
expect_usage_error "--email without --create" --email mary@example.com alice
expect_usage_error "--display-name without --create" --display-name 'Mary Ann' alice
expect_usage_error "--group without --create" --group Staff alice
expect_usage_error "an address with no @" --create --email nobody alice
expect_usage_error "an address with a space" --create --email 'mary ann@example.com' alice
expect_usage_error "--display-name without a value" --create alice --display-name
expect_usage_error "an empty display name" --create --display-name '' alice
expect_usage_error "--remove with two files" --remove a.txt b.txt
expect_usage_error "--remove with --create" --remove --create a.txt
expect_usage_error "--remove with no file" --remove

for flag in --help -h; do
  new_pw_case "${flag}"
  run_script -- "${temp_pw}" "${flag}"
  expect_rc 0
  if [[ "${out}" == 'Usage: temp-password.sh [--create]'* && "${out}" == *'temp-password.sh --remove <file>'* ]]; then ok "${case_label}: the usage is on stdout"
  else bad "${case_label}: no usage on stdout" "$(dump_case)"; fi
  expect_call_count ssh 0
done

new_pw_case "create with the --option=value forms"
run_script -- "${temp_pw}" --create --display-name='Mary Ann Lee' --email=mary@example.com --group=Staff 'Mary Ann'
expect_rc 0
expect_eq "user:add's arguments" '["user:add","--password-from-env","--display-name=Mary Ann Lee","-g","Staff","--","Mary Ann"]' "$(occ_call_args 1)"
expect_eq "user:setting's arguments" '["user:setting","--","Mary Ann","settings","email","mary@example.com"]' "$(occ_call_args 2)"

section "temp-password.sh: limits Nextcloud checks only after the account is made (exit 64)"
# repeat_char CHAR N: CHAR written N times
repeat_char() { local text="" i; for ((i = 0; i < $2; i++)); do text+="$1"; done; printf '%s' "${text}"; }

# limit_case <label> <wanted exit> <temp-password.sh arguments...>: on 64 nothing may be touched at all
limit_case() {
  local want="$2"
  new_pw_case "$1"
  shift 2
  run_script -- "${temp_pw}" "$@"
  expect_rc "${want}"
  if [ "${want}" -eq 64 ]; then
    expect_occ_calls 0
    expect_call_count ssh 0
    expect_eq "stdout is empty" "" "${out}"
    if [ ! -e "${pw_dir}" ]; then ok "${case_label}: nothing was written, not even the folder"
    else bad "${case_label}: something was written under the password folder"; fi
  fi
}
limit_case "a display name of 64 characters" 0 --create --display-name "$(repeat_char a 64)" alice
limit_case "a display name of 65 characters" 64 --create --display-name "$(repeat_char a 65)" alice
if [[ "${err}" == *'65 characters'* && "${err}" == *'at most 64'* ]]; then ok "${case_label}: stderr gives the count and the limit"
else bad "${case_label}: expected '65 characters' and 'at most 64'" "$(dump_case)"; fi
limit_case "a display name of 64 multibyte characters (128 bytes)" 0 --create --display-name "$(repeat_char é 64)" alice
limit_case "a display name of 65 multibyte characters" 64 --create --display-name "$(repeat_char é 65)" alice
limit_case "64 characters and blanks around them (Nextcloud trims first)" 0 --create --display-name "  $(repeat_char a 64)   " alice
limit_case "65 characters and blanks around them" 64 --create --display-name "  $(repeat_char a 65)   " alice
limit_case "a group name of 255 characters" 0 --create --group "$(repeat_char g 255)" alice
limit_case "a group name of 256 characters" 64 --create --group "$(repeat_char g 256)" alice
if [[ "${err}" == *'256 characters'* && "${err}" == *'at most 255'* ]]; then ok "${case_label}: stderr gives the count and the limit"
else bad "${case_label}: expected '256 characters' and 'at most 255'" "$(dump_case)"; fi
limit_case "a group name of 255 multibyte characters (510 bytes)" 0 --create --group "$(repeat_char é 255)" alice
limit_case "a group name of 256 multibyte characters" 64 --create --group "$(repeat_char é 256)" alice
limit_case "the second of two groups is too long" 64 --create --group Staff --group "$(repeat_char g 256)" alice

section "temp-password.sh: odd names reach occ as single arguments"
new_pw_case "create with an uid, display name, group and email full of shell syntax"
odd_uid="O'Brien \$(touch pwned); \`touch pwned2\` \"x\" & y"
odd_display=$'Jo "JJ" O\'Brien $HOME; echo hi\nsecond line'
odd_group='Sales & Ops'
run_script -- "${temp_pw}" --create --display-name "${odd_display}" --email 'jo+tag@example.com' --group "${odd_group}" --group 'Ünïcode' -- "${odd_uid}"
expect_rc 0
expect_eq "user:add's arguments" "$(jq -nc --arg d "--display-name=${odd_display}" --arg g "${odd_group}" --arg u "${odd_uid}" \
  '["user:add","--password-from-env",$d,"-g",$g,"-g","Ünïcode","--",$u]')" "$(occ_call_args 1)"
expect_eq "user:setting's arguments" "$(jq -nc --arg u "${odd_uid}" '["user:setting","--",$u,"settings","email","jo+tag@example.com"]')" "$(occ_call_args 2)"
expect_eq "user:info's arguments" "$(jq -nc --arg u "${odd_uid}" '["user:info","--output=json","--",$u]')" "$(occ_call_args 3)"
if [ ! -e "${FAKE_OPS_HOME}/pwned" ] && [ ! -e "${FAKE_OPS_HOME}/pwned2" ] && [ ! -e "${pw_home}/pwned" ] && [ ! -e "${pw_home}/pwned2" ]; then ok "${case_label}: nothing was executed from the names"
else bad "${case_label}: a command substitution ran"; fi
safe_odd="$(printf '%s' "${odd_uid}" | LC_ALL=C sed 's/[^A-Za-z0-9._@-]/_/g')"
mapfile -t pw_found < <(pw_files)
odd_name="${pw_found[0]:-}"
if [[ "${odd_name}" == "${safe_odd}-"* && "${odd_name#"${safe_odd}"-}" =~ ^[0-9]{8}-[0-9]{6}\.txt$ ]]; then ok "${case_label}: the file name is the uid with every other character turned into _"
else bad "${case_label}: expected ${safe_odd}-<date>-<time>.txt, got '${odd_name}'"; fi
expect_eq "the file's login line is the real uid" "Login: ${odd_uid}" "$(grep -m1 '^Login: ' "${pw_dir}/${pw_found[0]:-none}")"
expect_eq "the stdout line names the real uid" "Saved the temporary password for ${odd_uid} to nextcloud-passwords/${pw_found[0]:-none} in the Files pane." "${out}"

new_pw_case "the characters a uid may keep stay in the file name"
FAKE_NOW='2026-10-23 10:15:42'
run_script -- "${temp_pw}" --create 'a.b@c-d_E9'
expect_rc 0
expect_eq "the file name" "a.b@c-d_E9-20261023-101542.txt" "$(pw_files)"
expect_password_file "a.b@c-d_E9-20261023-101542.txt" 'a.b@c-d_E9'

new_pw_case "a uid with slashes cannot put the file outside the folder"
FAKE_NOW='2026-10-23 10:15:42'
run_script -- "${temp_pw}" --create -- '../../evil'
expect_rc 0
expect_eq "the file name has the slashes turned into _" ".._.._evil-20261023-101542.txt" "$(pw_files)"
expect_eq "the login line still has the real uid" "Login: ../../evil" "$(grep -m1 '^Login: ' "${pw_dir}/.._.._evil-20261023-101542.txt")"
expect_eq "nothing was made next to the folder or above it" "" "$(find "${pw_home}" "${case_dir}" -maxdepth 1 -name '*evil*' | sort)"

new_pw_case "a home folder with spaces and glob characters"
odd_home="${case_dir}/home dir [x] *?"
mkdir -p "${odd_home}"
: > "${odd_home}/decoy"
seed_user 'Mary Ann'
FAKE_NOW='2026-10-23 10:15:42'
run_script HOME="${odd_home}" -- "${temp_pw}" 'Mary Ann'
expect_rc 0
run_script HOME="${odd_home}" -- "${temp_pw}" 'Mary Ann'
expect_rc 0
expect_stdout_is "Saved the temporary password for Mary Ann to nextcloud-passwords/Mary_Ann-20261023-101542-2.txt in the Files pane."$'\n'
expect_eq "the two files, the second one numbered" "Mary_Ann-20261023-101542-2.txt Mary_Ann-20261023-101542.txt" "$(cd "${odd_home}/nextcloud-passwords" && echo *)"
expect_mode "${odd_home}/nextcloud-passwords" 700 "the folder"
expect_mode "${odd_home}/nextcloud-passwords/Mary_Ann-20261023-101542-2.txt" 600 "the second file"
run_script HOME="${odd_home}" -- "${temp_pw}" --remove "nextcloud-passwords/Mary_Ann-20261023-101542-2.txt"
expect_rc 0
run_script HOME="${odd_home}" -- "${temp_pw}" --remove "${odd_home}/nextcloud-passwords/Mary_Ann-20261023-101542.txt"
expect_rc 0
expect_eq "both files are gone and the decoy is not" "decoy nextcloud-passwords" "$(cd "${odd_home}" && echo *)"

new_pw_case "a uid that starts with a dash, given after --"
run_script -- "${temp_pw}" --create -- -weird
expect_rc 0
expect_eq "user:add ends its options before the uid" '["user:add","--password-from-env","--","-weird"]' "$(occ_call_args 1)"
expect_eq "user:info ends its options before the uid" '["user:info","--output=json","--","-weird"]' "$(occ_call_args 2)"
mapfile -t pw_found < <(pw_files)
if [[ "${pw_found[0]:-}" == -weird-* ]]; then ok "${case_label}: the file name starts with the uid"; else bad "${case_label}: unexpected file name '${pw_found[0]:-}'"; fi
new_pw_case "a reset of a uid that starts with a dash"
seed_user -weird
run_script -- "${temp_pw}" -- -weird
expect_rc 0
expect_eq "user:resetpassword ends its options before the uid" '["user:resetpassword","--password-from-env","--","-weird"]' "$(occ_call_args 3)"

section "temp-password.sh --remove"
# mk_pw_file <name>: a password file as temp-password.sh leaves it
mk_pw_file() {
  mkdir -p "${pw_dir}"
  chmod 700 "${pw_dir}"
  ( umask 077; printf 'Login: x\n\nTemporary password:\nAbCdEfGhJkMnPqRsTuVw\n' > "${pw_dir}/$1" )
}

new_pw_case "--remove deletes the file the script made, with shred -u"
seed_user 'Mary Ann'
FAKE_NOW='2026-10-23 10:15:42'
run_script -- "${temp_pw}" 'Mary Ann'
made_file="Mary_Ann-20261023-101542.txt"
run_script -- "${temp_pw}" --remove "${made_file}"
expect_rc 0
expect_stdout_is "Deleted nextcloud-passwords/${made_file}."$'\n'
expect_eq "stderr is empty" "" "${err}"
if [ ! -e "${pw_dir}/${made_file}" ]; then ok "${case_label}: the file is gone"; else bad "${case_label}: the file is still there"; fi
expect_eq "it was removed with shred -u" "shred -u -- $(realpath -- "${pw_dir}")/${made_file}" "$(grep '^shred ' "${FAKE_CALLS}")"
expect_occ_calls 0
expect_call_count ssh 0
expect_mode "${pw_dir}" 700 "the folder"

new_pw_case "--remove takes a bare name, nextcloud-passwords/NAME, a path and ~/nextcloud-passwords/NAME"
for f in a.txt b.txt c.txt d.txt keep.txt; do mk_pw_file "${f}"; done
run_script -- "${temp_pw}" --remove a.txt
expect_stdout_is $'Deleted nextcloud-passwords/a.txt.\n'
run_script -- "${temp_pw}" --remove nextcloud-passwords/b.txt
expect_stdout_is $'Deleted nextcloud-passwords/b.txt.\n'
run_script -- "${temp_pw}" --remove "${pw_dir}/c.txt"
expect_stdout_is $'Deleted nextcloud-passwords/c.txt.\n'
# shellcheck disable=SC2088  # a literal ~ reaches the script on purpose
run_script -- "${temp_pw}" --remove '~/nextcloud-passwords/d.txt'
expect_stdout_is $'Deleted nextcloud-passwords/d.txt.\n'
expect_eq "only the file that was not named is left" "keep.txt" "$(pw_files)"

new_pw_case "--remove works when ~/nextcloud-passwords is a link to another folder"
mkdir -p "${case_dir}/vault"
chmod 700 "${case_dir}/vault"
ln -s "${case_dir}/vault" "${pw_dir}"
( umask 077; printf 'x\n' > "${case_dir}/vault/a.txt"; printf 'x\n' > "${case_dir}/vault/b.txt" )
run_script -- "${temp_pw}" --remove a.txt
expect_rc 0
run_script -- "${temp_pw}" --remove "${pw_dir}/b.txt"
expect_rc 0
expect_eq "both files are gone from the folder the link points to" "" "$(ls -A "${case_dir}/vault")"

new_pw_case "--remove -- takes a name that starts with a dash"
mk_pw_file -x.txt
run_script -- "${temp_pw}" --remove -- -x.txt
expect_rc 0
expect_eq "the file is gone" "" "$(pw_files)"

new_pw_case "--remove still deletes the file when shred fails"
mk_pw_file a.txt
FAKE_SHRED_FAIL=1
run_script -- "${temp_pw}" --remove a.txt
expect_rc 0
expect_call_count shred 1
expect_eq "the file is gone (rm -f took over)" "" "$(pw_files)"

new_pw_case "--remove when neither shred nor rm can delete the file"
mk_pw_file a.txt
FAKE_SHRED_FAIL=1
FAKE_RM_FAIL=1
run_script -- "${temp_pw}" --remove a.txt
expect_rc 1
expect_eq "stdout does not claim a deletion" "" "${out}"
if [[ "${err}" == *'could not delete nextcloud-passwords/a.txt'* ]]; then ok "${case_label}: stderr says the file could not be deleted"
else bad "${case_label}: the message should say the file could not be deleted" "$(dump_case)"; fi
expect_eq "the file is still there" "a.txt" "$(pw_files)"

new_pw_case "--remove needs no Nextcloud settings"
mk_pw_file a.txt
run_script -NEXTCLOUD_URL -NEXTCLOUD_HOST -- "${temp_pw}" --remove a.txt
expect_rc 0
expect_eq "the file is gone" "" "$(pw_files)"

new_pw_case "--remove of a file that is not there"
mk_pw_file keep.txt
run_script -- "${temp_pw}" --remove nope.txt
expect_rc 64
expect_eq "stdout is empty" "" "${out}"
if [[ "${err}" == *'nextcloud-passwords/nope.txt'* ]]; then ok "${case_label}: stderr names the file"; else bad "${case_label}: the message should name the file" "$(dump_case)"; fi

new_pw_case "--remove refuses everything that is not a .txt file inside ~/nextcloud-passwords"
mk_pw_file keep.txt
mkdir -p "${case_dir}/outside" "${case_dir}/etc" "${pw_dir}/d.txt"
: > "${case_dir}/outside/x.txt"
: > "${case_dir}/outside/y.txt"
: > "${case_dir}/etc/passwd"
: > "${pw_home}/x.txt"
: > "${pw_dir}/notes.md"
: > "${pw_dir}/.txt"
ln -s "${case_dir}/outside/y.txt" "${pw_dir}/link.txt"
refused_before="$(snapshot "${pw_home}" "${case_dir}/outside" "${case_dir}/etc")"
refused_label="${case_label}"
for arg in '../../etc/passwd' '/tmp/x.txt' "${case_dir}/outside/x.txt" '../x.txt' 'nextcloud-passwords/../x.txt' "${pw_dir}/../x.txt" \
  'link.txt' 'notes.md' 'd.txt' '.txt' '' '.' '..' 'nextcloud-passwords' 'nextcloud-passwords/' 'keep'; do
  run_script -- "${temp_pw}" --remove "${arg}"
  case_label="${refused_label}: '${arg}'"
  expect_rc 64
  expect_eq "stdout is empty" "" "${out}"
done
case_label="${refused_label}"
expect_eq "nothing was touched: not the folder, not the decoys, not the link's target" "${refused_before}" "$(snapshot "${pw_home}" "${case_dir}/outside" "${case_dir}/etc")"
expect_call_count shred 0
expect_occ_calls 0

section "lib/nextcloud-passwords.sh"
new_case "sourcing it defines three functions and changes nothing"
run_script -- "${BASH}" -c 'a="$(set +o; shopt -p; umask; trap -p)"; . "$1" || exit 9; b="$(set +o; shopt -p; umask; trap -p)"
  [ "$a" = "$b" ] && echo "options unchanged"; declare -F | sed "s/^declare -f //" | tr "\n" " "' _ "${pw_lib}"
expect_rc 0
expect_eq "shell options, umask and traps are as they were, and these are the functions" $'options unchanged\nnc_generate_password nc_password_dir nc_write_private_file ' "${out}"
expect_eq "it made nothing in HOME" "" "$(ls -A "${case_dir}/agent-home")"
expect_eq "stderr is empty" "" "${err}"

new_case "nc_generate_password: 300 passwords"
run_script -- "${BASH}" -c '. "$1"; for ((i = 0; i < 300; i++)); do nc_generate_password; done' _ "${pw_lib}"
expect_rc 0
expect_eq "stderr is empty" "" "${err}"
expect_eq "300 lines" 300 "$(wc -l < "${case_dir}/stdout" | tr -d ' ')"
expect_eq "every line is 20 characters of the alphabet (no I, O, l, 0 or 1)" 300 "$(grep -cE "${pw_line_re}" "${case_dir}/stdout")"
expect_eq "every password has an upper-case letter, a lower-case letter and a digit" 300 \
  "$(grep -E '[A-Z]' "${case_dir}/stdout" | grep -E '[a-z]' | grep -cE '[0-9]')"
expect_eq "no two are alike" 300 "$(sort -u "${case_dir}/stdout" | wc -l | tr -d ' ')"
expect_eq "all 57 characters of the alphabet turn up" 57 "$(fold -w1 "${case_dir}/stdout" | sort -u | grep -c .)"

new_case "nc_generate_password under set -euo pipefail (tr dies of SIGPIPE when head stops)"
run_script -- "${BASH}" -c 'set -euo pipefail; . "$1"; for ((i = 0; i < 20; i++)); do pw="$(nc_generate_password)"; [ "${#pw}" -eq 20 ]; done; echo fine' _ "${pw_lib}"
expect_rc 0
expect_stdout_is $'fine\n'
expect_eq "stderr is empty" "" "${err}"

new_case "nc_generate_password called straight in a pipeline under set -e (-e is off inside \$(...), so that never showed it)"
run_script -- "${BASH}" -c 'set -euo pipefail; . "$1"; for ((i = 0; i < 20; i++)); do nc_generate_password | { IFS= read -r line; [ "${#line}" -eq 20 ]; }; done; echo fine' _ "${pw_lib}"
expect_stdout_is $'fine\n'
expect_eq "stderr is empty" "" "${err}"

new_case "nc_generate_password: a draw that comes up short is not used, even with every kind of character"
run_script -- "${BASH}" -c '. "$1"; head() { printf "Ab3"; }; pw="$(nc_generate_password 2>/dev/null)"; echo "rc=$? pw=[${pw}]"' _ "${pw_lib}"
expect_stdout_is $'rc=1 pw=[]\n'

new_case "nc_generate_password: no /dev/urandom to read"
run_script -- "${BASH}" -c '. "$1"; tr() { return 1; }; pw="$(nc_generate_password)"; echo "rc=$? pw=[${pw}]"' _ "${pw_lib}"
expect_stdout_is $'rc=1 pw=[]\n'
if [[ "${err}" == *'could not'* ]]; then ok "${case_label}: it says so on stderr"; else bad "${case_label}: no message on stderr" "$(dump_case)"; fi

new_case "nc_password_dir: makes ~/nextcloud-passwords with mode 700, whatever the caller's umask"
run_script -- "${BASH}" -c '. "$1"; umask 000; nc_password_dir' _ "${pw_lib}"
expect_rc 0
expect_stdout_is "${case_dir}/agent-home/nextcloud-passwords"$'\n'
expect_mode "${case_dir}/agent-home/nextcloud-passwords" 700 "the folder"
chmod 755 "${case_dir}/agent-home/nextcloud-passwords"
run_script -- "${BASH}" -c '. "$1"; nc_password_dir' _ "${pw_lib}"
expect_mode "${case_dir}/agent-home/nextcloud-passwords" 700 "a folder that was made with mode 755, after the next call,"

new_case "nc_password_dir and nc_write_private_file need a home folder and a folder to write in"
run_script -HOME -- "${BASH}" -c '. "$1"; nc_password_dir; echo "rc=$?"' _ "${pw_lib}"
expect_stdout_is $'rc=1\n'
if [[ "${err}" == *'HOME'* ]]; then ok "${case_label}: no HOME is named on stderr"; else bad "${case_label}: the message should name HOME" "$(dump_case)"; fi
: > "${case_dir}/agent-home/nextcloud-passwords"
run_script -- "${BASH}" -c '. "$1"; nc_password_dir; echo "dir rc=$?"; echo data | nc_write_private_file a.txt; echo "write rc=$?"' _ "${pw_lib}"
expect_stdout_is $'dir rc=1\nwrite rc=1\n'
if [[ "${err}" == *'is not a folder'* ]]; then ok "${case_label}: it says ~/nextcloud-passwords is not a folder"; else bad "${case_label}: the message should say it is not a folder" "$(dump_case)"; fi

new_case "nc_write_private_file: mode 600 from the first byte, and it never overwrites"
run_script -- "${BASH}" -c '. "$1"; umask 000
  printf "%s\n" "first" | nc_write_private_file a.txt; echo "first rc=$?"
  printf "%s\n" "second" | nc_write_private_file a.txt; echo "second rc=$?"' _ "${pw_lib}"
expect_stdout_is $'first rc=0\nsecond rc=1\n'
expect_eq "the first content is still there" "first" "$(cat "${case_dir}/agent-home/nextcloud-passwords/a.txt")"
expect_mode "${case_dir}/agent-home/nextcloud-passwords/a.txt" 600 "the file, though the caller's umask was 000,"
expect_mode "${case_dir}/agent-home/nextcloud-passwords" 700 "the folder"
if [[ "${err}" == *'a.txt'* ]]; then ok "${case_label}: it says which file it will not overwrite"; else bad "${case_label}: no message about a.txt" "$(dump_case)"; fi
ln -s "${case_dir}/agent-home/nowhere" "${case_dir}/agent-home/nextcloud-passwords/dangling.txt"
run_script -- "${BASH}" -c '. "$1"; printf "%s\n" "x" | nc_write_private_file dangling.txt; echo "rc=$?"' _ "${pw_lib}"
expect_stdout_is $'rc=1\n'
if [ ! -e "${case_dir}/agent-home/nowhere" ]; then ok "${case_label}: a link that points nowhere is not written through"; else bad "${case_label}: it wrote through a dangling link"; fi
if [[ "${err}" == *'something is already there'* ]]; then ok "${case_label}: the check before the open is what refuses it"
else bad "${case_label}: expected 'something is already there'" "$(dump_case)"; fi

new_case "nc_write_private_file: a write that fails leaves no half-written file"
run_script -- "${BASH}" -c '. "$1"; cat() { return 1; }; printf "%s\n" "x" | nc_write_private_file a.txt; echo "rc=$?"' _ "${pw_lib}"
expect_stdout_is $'rc=1\n'
expect_eq "nothing is left in the folder" "" "$(ls -A "${case_dir}/agent-home/nextcloud-passwords")"

new_case "nc_write_private_file: a link to /dev/null is not opened through"
mkdir -p "${case_dir}/agent-home/nextcloud-passwords"
chmod 700 "${case_dir}/agent-home/nextcloud-passwords"
ln -s /dev/null "${case_dir}/agent-home/nextcloud-passwords/a.txt"
run_script -- "${BASH}" -c '. "$1"; printf "%s\n" secret | nc_write_private_file a.txt; echo "rc=$?"' _ "${pw_lib}"
expect_stdout_is $'rc=1\n'
if [[ "${err}" == *'something is already there'* ]]; then ok "${case_label}: it says something is already there"
else bad "${case_label}: expected 'something is already there'" "$(dump_case)"; fi
expect_eq "the link is left alone" "/dev/null" "$(readlink "${case_dir}/agent-home/nextcloud-passwords/a.txt")"

new_case "nc_write_private_file: a file that appears after the check is not overwritten (noclobber is the second guard)"
mkdir -p "${case_dir}/agent-home/nextcloud-passwords"
chmod 700 "${case_dir}/agent-home/nextcloud-passwords"
# umask is the last thing the write runs before it opens the file, inside the noclobber subshell: plant the file there
run_script -- "${BASH}" -c '. "$1"; umask() { case "$-" in *C*) printf "%s\n" planted > "${HOME}/nextcloud-passwords/a.txt" ;; esac; builtin umask "$@"; }
  printf "%s\n" secret | nc_write_private_file a.txt; echo "rc=$?"; cat "${HOME}/nextcloud-passwords/a.txt"' _ "${pw_lib}"
expect_stdout_is $'rc=1\nplanted\n'

new_case "nc_write_private_file: a FIFO at the path is refused and the call does not hang"
mkdir -p "${case_dir}/agent-home/nextcloud-passwords"
chmod 700 "${case_dir}/agent-home/nextcloud-passwords"
mkfifo "${case_dir}/agent-home/nextcloud-passwords/a.txt"
run_script -- timeout 10 "${BASH}" -c '. "$1"; printf "%s\n" secret | nc_write_private_file a.txt; echo "rc=$?"' _ "${pw_lib}"
expect_rc 0   # 124 would mean the timeout had to kill it
expect_stdout_is $'rc=1\n'
if [ -p "${case_dir}/agent-home/nextcloud-passwords/a.txt" ]; then ok "${case_label}: the FIFO is still there"; else bad "${case_label}: the FIFO was removed or replaced"; fi

new_case "nc_write_private_file: a path swapped for a link to a regular file during the write is reported and left alone"
: > "${case_dir}/agent-home/other.txt"
run_script -- "${BASH}" -c '. "$1"; cat() { rm -f "${HOME}/nextcloud-passwords/a.txt"; ln -s "${HOME}/other.txt" "${HOME}/nextcloud-passwords/a.txt"; }
  printf "%s\n" x | nc_write_private_file a.txt; echo "rc=$?"; [ -L "${HOME}/nextcloud-passwords/a.txt" ] && echo "link kept"' _ "${pw_lib}"
expect_stdout_is $'rc=1\nlink kept\n'
if [[ "${err}" == *'is not a plain file after the write'* ]]; then ok "${case_label}: it says the path is not a plain file after the write"
else bad "${case_label}: expected 'is not a plain file after the write'" "$(dump_case)"; fi
expect_eq "what the link points at was not written to" "" "$(cat "${case_dir}/agent-home/other.txt")"

new_case "nc_write_private_file: the file is already mode 600 when it is made, whatever the caller's umask"
run_script -- "${BASH}" -c '. "$1"; umask 000
  chmod() { if [ "$1" = 600 ]; then stat -c %a -- "${@: -1}" > "${HOME}/mode-at-creation"; fi; command chmod "$@"; }
  printf "%s\n" x | nc_write_private_file a.txt' _ "${pw_lib}"
expect_rc 0
expect_eq "the mode of the new file when chmod got to it" 600 "$(cat "${case_dir}/agent-home/mode-at-creation" 2>/dev/null)"

new_case "nc_write_private_file: only plain file names"
for name in '../x' 'a/b' '' . .. '/etc/x'; do
  run_script -- "${BASH}" -c '. "$1"; printf "%s\n" "x" | nc_write_private_file "$2"; echo "rc=$?"' _ "${pw_lib}" "${name}"
  case_label="nc_write_private_file '${name}'"
  expect_stdout_is $'rc=1\n'
  if [[ "${err}" == *'not a plain file name'* ]]; then ok "${case_label}: it says why"; else bad "${case_label}: the message should say it is not a plain file name" "$(dump_case)"; fi
done
expect_eq "nothing was written anywhere in HOME" "" "$(find "${case_dir}/agent-home" -type f | sort)"

# ===== share-as-admin.sh =====================================================
temp_name=clouve-ai-assistant-temporary
# What the fake user:auth-tokens:add makes, and the 72-character line it prints before it on request
# (nc-tokens-lib.sh). They are shell variables, not FAKE_* ones, so no run's environment holds them.
app_token='JvWiVv3jsB9qKdVHW37ZrPxZT6L7Wgxa9GagUFxUbvRFdbpufkvkKeE2xfskKeR6iIU0C0Fu'
decoy_token='zNycqXMX9DGJWc401hQvJEgeyz2mCyRaq6LUopYL0lb9Qfgh8SlbiS5FNNaQDG1Wk1WIsICV'
ocs_base=/ocs/v2.php/apps/files_sharing/api/v1/shares
share_usage='Usage: share-as-admin.sh --as <uid> create --path <path> --type link|user|group|email'
# the form a real instance returns, which is not the index.php/s/<token> form the script builds itself from a token (for an
# e-mail share), so the cases show that it takes the URL from the response
link_url='https://abc.clouve.app/s/Hj3kLmN0pQrStUv'
refusal='isn'"'"'t an enabled admin; other people share their own files (see playbooks/share-files-and-links.md)'
odd_admin="O'Brien Jr"   # a uid Nextcloud allows (a space and a quote) that a shell has to be told about

# token_rows: id, uid and name of each row of the token table (never the secret), one per line
token_rows() { if [ -s "${FAKE_TOKENS}" ]; then cut -f1-3 "${FAKE_TOKENS}"; fi; }

# temp_tokens_left: how many tokens in the table carry the script's name
temp_tokens_left() {
  if [ -s "${FAKE_TOKENS}" ]; then cut -f3 "${FAKE_TOKENS}" | grep -cxF "${temp_name}" || true; else echo 0; fi
}

# seed_token <id> <uid> <name> [secret]: a token that already exists in the fake Nextcloud
seed_token() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-secret-of-$1}" >> "${FAKE_TOKENS}"; }

# disable_user <uid>: the account exists and is disabled
disable_user() {
  # shellcheck source=/dev/null
  ( . "${users_lib}"; f="$(nc_fake_file "$1")"; jq '.enabled = false' "${f}" > "${f}.new" && mv "${f}.new" "${f}" )
}

# share_response <id> <share_type number> <path> <share_with or ""> <permissions> <expiration or ""> <url or ""> [token]:
# the OCS answer to a create. The token defaults to the last part of the URL, as a real answer has both or, for
# a share by e-mail, only the token.
share_response() {
  jq -nc --arg id "$1" --argjson type "$2" --arg path "$3" --arg with "$4" --argjson perms "$5" --arg exp "$6" --arg url "$7" --arg tok "${8:-}" '
    ($tok | if . != "" then . elif $url != "" then ($url | sub(".*/"; "")) else null end) as $token
    | {ocs: {meta: {status: "ok", statuscode: 200, message: "OK"},
        data: ({id: $id, share_type: $type, uid_owner: "admin", uid_file_owner: "admin", path: $path, item_type: "file",
                permissions: $perms, expiration: (if $exp == "" then null else $exp end),
                share_with: (if $with == "" then null else $with end), token: $token, mail_send: 0, label: "", note: ""}
               + (if $url == "" then {} else {url: $url} end))}}'
}

# ocs_error <statuscode> <message>: an OCS failure answer
ocs_error() { jq -nc --argjson code "$1" --arg msg "$2" '{ocs: {meta: {status: "failure", statuscode: $code, message: $msg}, data: []}}'; }

# cfg_file <n>: the n-th curl config the script sent
cfg_file() { printf '%s.%s' "${FAKE_CURL_CFG}" "$1"; }

# cfg_field <n> <name>: the data-urlencode field of that name in the n-th config, as sent (still escaped), or nothing
cfg_field() { sed -n "s/^data-urlencode = \"$2=\(.*\)\"\$/\1/p" "$(cfg_file "$1")" 2> /dev/null; }

# file_line <file> <prefix>: the first line of the file that starts with the prefix; nothing if there is no such file
file_line() { grep -m1 -- "^$2" "$1" 2> /dev/null; }

expect_cfg_line() { # expect_cfg_line <n> <what> <the exact config line>
  if grep -qxF -- "$3" "$(cfg_file "$1")" 2> /dev/null; then ok "${case_label}: config $1 has $2"
  else bad "${case_label}: config $1 lacks $2" "$(sed "s/${app_token}/<token>/" "$(cfg_file "$1")" 2>&1)"; fi
}

expect_cfg_none() { # expect_cfg_none <n> <what> <ERE>: no line of the n-th config matches
  if ! grep -qE -- "$3" "$(cfg_file "$1")" 2> /dev/null; then ok "${case_label}: config $1 has no $2"
  else bad "${case_label}: config $1 has $2 but should not" "$(sed "s/${app_token}/<token>/" "$(cfg_file "$1")" 2>&1)"; fi
}

expect_cfg_lines() { # expect_cfg_lines <n> <how many>
  expect_eq "config $1 has $2 lines" "$2" "$(wc -l 2> /dev/null < "$(cfg_file "$1")" | tr -d ' ')"
}

# expect_secret_hidden <secret> <what>: in no argv, environment, log or stream of the run
expect_secret_hidden() {
  local file leaked=""
  if [ -z "$1" ]; then bad "${case_label}: there is no value to look for, so '$2 is hidden' would prove nothing"; return; fi
  for file in "${FAKE_CALLS}" "${FAKE_OCC_LOG}" "${FAKE_ARGV_LOG}" "${FAKE_ARGV_LOG}.env" "${case_dir}/stdout" "${case_dir}/stderr"; do
    [ -f "${file}" ] || continue
    if grep -qF -- "$1" "${file}"; then leaked+=" $(basename "${file}")"; fi
  done
  if [ -z "${leaked}" ]; then ok "${case_label}: $2 is in no argv, environment, log or stream"
  else bad "${case_label}: $2 leaked into:${leaked}"; fi
}

# expect_token_hygiene: the run is over. No temporary token is left, the app password is nowhere it should not
# be, and the script left no temporary file but its lock file, which is empty (the app password and the link
# password are never written to disk but in the one private file).
lock_name=clouve-share-as-admin.lock

# tmp_leftovers: the names in the case's temp folder other than the lock file, space-separated
tmp_leftovers() {
  local f out=""
  for f in "${case_dir}/tmp"/* "${case_dir}/tmp"/.[!.]*; do
    if [ -e "${f}" ] && [ "${f##*/}" != "${lock_name}" ]; then out+="${f##*/} "; fi
  done
  printf '%s' "${out}"
}

expect_token_hygiene() {
  expect_eq "no ${temp_name} token is left" 0 "$(temp_tokens_left)"
  expect_secret_hidden "${app_token}" "the app password"
  expect_eq "no temporary file is left but the lock file" "" "$(tmp_leftovers)"
  expect_eq "the lock file is there and holds nothing" 0 "$(wc -c 2> /dev/null < "${case_dir}/tmp/${lock_name}" | tr -d ' ')"
}

# hold_lock: another process takes this case's lock (the real flock, on the file share-as-admin.sh uses) and keeps it
# until release_lock
hold_lock() {
  rm -f "${case_dir}/lock-held" "${case_dir}/lock-release"
  ( exec 8>> "${case_dir}/tmp/${lock_name}"; flock 8; : > "${case_dir}/lock-held"; until [ -e "${case_dir}/lock-release" ]; do sleep 0.1; done ) &
  lock_holder=$!
  wait_for_file "${case_dir}/lock-held"
}
release_lock() {
  : > "${case_dir}/lock-release"
  wait "${lock_holder}"
}

# expect_order <what> <ERE>...: lines of $FAKE_CALLS that match these, each after the one before
expect_order() {
  local what="$1" want prev=0 hit
  shift
  for want in "$@"; do
    hit="$(grep -nE -- "${want}" "${FAKE_CALLS}" | while IFS=: read -r num _; do if [ "${num}" -gt "${prev}" ]; then echo "${num}"; break; fi; done)"
    if [ -z "${hit}" ]; then bad "${case_label}: ${what}: no line matching /${want}/ after line ${prev}" "$(dump_case)"; return; fi
    prev="${hit}"
  done
  ok "${case_label}: ${what}"
}

# expect_refused <wanted reason>: exit 2 with the sentence, the reason, and nothing else done
expect_refused() {
  expect_rc 2
  if [[ "${err}" == *"[nextcloud/share-as-admin] "*"${refusal}"* && "${err}" == *"$1"* ]]; then ok "${case_label}: stderr says the account ${refusal%%;*} and why: $1"
  else bad "${case_label}: expected the refusal sentence and '$1'" "$(dump_case)"; fi
  expect_eq "stdout is empty" "" "${out}"
  expect_call_count curl 0
  expect_eq "no token was listed, made or deleted" 0 "$(grep -c 'user:auth-tokens' "${FAKE_OCC_LOG}" || true)"
  expect_eq "the token table is untouched" "" "$(token_rows)"
  expect_eq "no lock was taken" "no" "$([ -e "${case_dir}/tmp/${lock_name}" ] && echo yes || echo no)"
}

section "share-as-admin.sh: the file"
if [ ! -f "${share_sh}" ]; then
  bad "share-as-admin.sh exists" "${share_sh}"
else
  # Git keeps only the owner's execute bit (see the temp-password.sh checks): ask for what the mode means.
  sa_mode="$(mode_of "${share_sh}")"
  if [[ "${sa_mode}" =~ ^[0-7]+$ ]] && (( 8#${sa_mode} & 8#100 )) && ! (( 8#${sa_mode} & 8#002 )); then ok "share-as-admin.sh is executable and not world-writable (mode ${sa_mode}; 755 is the brief's)"
  else bad "share-as-admin.sh must be executable and not world-writable (mode ${sa_mode})"; fi
  if [ "$(head -n 1 "${share_sh}")" = '#!/usr/bin/env bash' ]; then ok "share-as-admin.sh starts with #!/usr/bin/env bash"
  else bad "share-as-admin.sh does not start with #!/usr/bin/env bash"; fi
  if grep -qE '^[[:space:]]*(set[[:space:]]+-[A-Za-z]*x|set[[:space:]]+-o[[:space:]]+xtrace)' "${share_sh}"; then bad "share-as-admin.sh turns on set -x, which would print the app password"
  else ok "share-as-admin.sh never turns on set -x"; fi
  if grep -qE '^[[:space:]]*export[[:space:]]' "${share_sh}"; then bad "share-as-admin.sh exports a variable, and the app password would go to every child"
  else ok "share-as-admin.sh exports no variable"; fi
  if grep -qF 'lib/nextcloud-passwords.sh' "${share_sh}" && ! grep -qE '^(nc_generate_password|nc_password_dir|nc_write_private_file)\(\)' "${share_sh}"; then ok "share-as-admin.sh sources the password library and does not copy it"
  else bad "share-as-admin.sh must source lib/nextcloud-passwords.sh, not define its functions"; fi
fi

section "share-as-admin.sh: a link with a password and an expiry (the brief's example)"
new_share_case "link create"
FAKE_NOW='2026-10-24 10:15:42'
FAKE_CURL_RESPONSE="$(share_response 42 3 '/Docs/Q3 report.pdf' redacted 17 '2026-12-31 23:59:59' "${link_url}")"
run_script TZ=America/Los_Angeles -- "${share_sh}" --as admin create --path '/Docs/Q3 report.pdf' --type link --expire 2026-12-31 --password <<< "text on stdin that must be left alone"
expect_rc 0
expect_cfg_line 1 "the credentials of the account, with the app password" "user = \"admin:${app_token}\""
expect_cfg_line 1 "the public host from NEXTCLOUD_URL" 'header = "Host: abc.clouve.app"'
expect_cfg_line 1 "the OCS header" 'header = "OCS-APIRequest: true"'
expect_cfg_line 1 "the JSON header" 'header = "Accept: application/json"'
expect_cfg_line 1 "the path, as typed" 'data-urlencode = "path=/Docs/Q3 report.pdf"'
expect_cfg_line 1 "shareType 3" 'data-urlencode = "shareType=3"'
expect_cfg_line 1 "sendMail=false" 'data-urlencode = "sendMail=false"'
expect_cfg_line 1 "the expiry" 'data-urlencode = "expireDate=2026-12-31"'
sent_pw="$(cfg_field 1 password)"
if [[ "${sent_pw}" =~ ${pw_line_re} ]]; then ok "${case_label}: config 1 has a password= of 20 characters from the generator's alphabet"
else bad "${case_label}: config 1 has no 20-character password=" "$(sed "s/${app_token}/<token>/" "$(cfg_file 1)" 2>&1)"; fi
expect_eq "exactly one password= line" 1 "$(grep -c '^data-urlencode = "password=' "$(cfg_file 1)" 2> /dev/null || true)"
expect_cfg_none 1 "shareWith, permissions, note or label (none was given)" '^data-urlencode = "(shareWith|permissions|note|label)='
expect_cfg_lines 1 9
expect_eq "curl's argv: no credentials, the URL and the method" "curl$(printf ' %q' -q -sS -m 30 -K - --noproxy '*' -X POST -w '\n%{http_code}' "http://nc.test${ocs_base}?format=json")" "$(grep '^curl ' "${FAKE_CALLS}")"
expect_eq "the call was authenticated with the app password the fake made" "curl-call n=1 method=POST auth=ok uid=admin" "$(grep '^curl-call ' "${FAKE_CALLS}")"
expect_call_count curl 1
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_eq "user:info reads the account first, for its own spelling of the uid and its enabled flag" '["user:info","--output=json","--","admin"]' "$(occ_call_args 1)"
expect_eq "group:list asks for the admin group" '["group:list","--output=json","admin"]' "$(occ_call_args 2)"
expect_eq "the sweep lists the account's tokens" '["user:auth-tokens:list","--output=json","--","admin"]' "$(occ_call_args 3)"
expect_eq "the token is made with its name and no password" '["user:auth-tokens:add","--name=clouve-ai-assistant-temporary","--","admin"]' "$(occ_call_args 4)"
expect_eq "the token is deleted by id" '["user:auth-tokens:delete","--","admin","1"]' "$(occ_call_args 6)"
expect_eq "and the delete is read back" '["user:auth-tokens:list","--output=json","--","admin"]' "$(occ_call_args 7)"
expect_order "the token is made, then used, then deleted" '^php .* user:auth-tokens:add ' '^curl ' '^php .* user:auth-tokens:delete '
sent_bytes=""
for i in 1 2 3 4 5 6 7; do sent_bytes+="$(ssh_field "${i}" stdin_bytes) "; done
expect_eq "none of the 7 ssh calls carried anything on stdin" "0 0 0 0 0 0 0 " "${sent_bytes}"
expect_token_hygiene
expect_secret_hidden "${sent_pw}" "the link password"
mapfile -t pw_found < <(pw_files)
expect_eq "one file in ~/nextcloud-passwords, named share-<id>-<UTC date>-<UTC time>.txt" "share-42-20261024-101542.txt" "${pw_found[*]:-none}"
sp_file="${pw_dir}/share-42-20261024-101542.txt"
expect_mode "${pw_dir}" 700 "the nextcloud-passwords folder"
expect_mode "${sp_file}" 600 "the password file"
expect_eq "the password file holds the link password" "${sent_pw:-<no password was sent>}" "$(password_of "${sp_file}")"
expect_eq "the password file holds the URL from the response" "Link: ${link_url}" "$(file_line "${sp_file}" 'Link: ')"
expect_eq "and the expiry" "Expires: 2026-12-31 23:59:59" "$(file_line "${sp_file}" 'Expires: ')"
expect_eq "and the time it was made, in UTC" "Made: 2026-10-24 10:15:42 UTC" "$(file_line "${sp_file}" 'Made: ')"
expect_eq "and the share and its path" $'Share: 42\nPath: /Docs/Q3 report.pdf' "$(grep -E '^(Share|Path): ' "${sp_file}" 2> /dev/null)"
if grep -qxF "Send the link and the password by different routes. Delete this file once they're handed over." "${sp_file}" 2> /dev/null; then ok "${case_label}: the file asks to send them by different routes and to delete it"
else bad "${case_label}: the closing instruction is missing" "$(cat "${sp_file}" 2>&1)"; fi
expect_stdout_is "id=42 share_type=link path=\"/Docs/Q3 report.pdf\" share_with=- permissions=17 expiration=\"2026-12-31 23:59:59\" url=\"${link_url}\""$'\npassword saved to nextcloud-passwords/share-42-20261024-101542.txt\n'
expect_eq "stderr is empty" "" "${err}"
expect_eq "the agent's home holds only nextcloud-passwords" "nextcloud-passwords" "$(ls -A "${pw_home}")"
expect_call_count shred 0

new_share_case "link create with a password, the real clock and another time zone"
FAKE_CURL_RESPONSE="$(share_response 43 3 /Docs/a.pdf '' 17 '' "${link_url}")"
before_min="$(date -u '+%Y%m%d-%H%M')"
run_script TZ=America/Los_Angeles -- "${share_sh}" --as admin create --path /Docs/a.pdf --type link --password
after_min="$(date -u '+%Y%m%d-%H%M')"
expect_rc 0
mapfile -t pw_found < <(pw_files)
sp_name="${pw_found[0]:-none}"
if [[ "${sp_name}" =~ ^share-43-([0-9]{8}-[0-9]{4})[0-9]{2}\.txt$ ]] && { [ "${BASH_REMATCH[1]}" = "${before_min}" ] || [ "${BASH_REMATCH[1]}" = "${after_min}" ]; }; then ok "${case_label}: the file name carries the UTC time, though TZ was America/Los_Angeles"
else bad "${case_label}: unexpected file name '${sp_name}' (UTC is ${before_min})"; fi
expect_eq "the file exists and has no Expires line (the response had no expiry)" "1 0" "$([ -f "${pw_dir}/${sp_name}" ] && echo 1 || echo 0) $(grep -c '^Expires: ' "${pw_dir}/${sp_name}" 2> /dev/null || true)"
expect_cfg_none 1 "expireDate (none was asked for)" '^data-urlencode = "expireDate='
expect_stdout_is "id=43 share_type=link path=\"/Docs/a.pdf\" share_with=- permissions=17 expiration=none url=\"${link_url}\""$'\n'"password saved to nextcloud-passwords/${sp_name}"$'\n'
expect_token_hygiene

new_share_case "a link without a password makes no file"
FAKE_CURL_RESPONSE="$(share_response 44 3 /Docs/b.pdf '' 1 '2026-11-30 23:59:59' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs/b.pdf --type link --permissions 1 --expire 2026-11-30 --label 'For Dana' --note 'Read only'
expect_rc 0
expect_cfg_line 1 "permissions" 'data-urlencode = "permissions=1"'
expect_cfg_line 1 "the label" 'data-urlencode = "label=For Dana"'
expect_cfg_line 1 "the note" 'data-urlencode = "note=Read only"'
expect_cfg_none 1 "password" '^data-urlencode = "password='
expect_cfg_none 1 "shareWith" '^data-urlencode = "shareWith='
expect_stdout_is "id=44 share_type=link path=\"/Docs/b.pdf\" share_with=- permissions=1 expiration=\"2026-11-30 23:59:59\" url=\"${link_url}\""$'\n'
expect_eq "no password folder was made" "no" "$([ -e "${pw_dir}" ] && echo yes || echo no)"
expect_eq "no password was drawn (tr -dc is the generator's call)" 0 "$(grep -c '^tr -dc ' "${FAKE_ARGV_LOG}" || true)"
expect_token_hygiene

section "share-as-admin.sh: users, groups and e-mail addresses"
new_share_case "a user share"
seed_user bob 'Bob' bob@example.com
FAKE_CURL_RESPONSE="$(share_response 7 0 /Docs bob 31 '' '')"
run_script -- "${share_sh}" --as admin create --path /Docs --type user --with bob --permissions 31 --note 'Please review'
expect_rc 0
expect_cfg_line 1 "shareType 0" 'data-urlencode = "shareType=0"'
expect_cfg_line 1 "shareWith" 'data-urlencode = "shareWith=bob"'
expect_cfg_line 1 "permissions" 'data-urlencode = "permissions=31"'
expect_cfg_line 1 "the note" 'data-urlencode = "note=Please review"'
expect_cfg_line 1 "sendMail=false, so the recipient is not mailed" 'data-urlencode = "sendMail=false"'
expect_cfg_none 1 "label, password or expireDate" '^data-urlencode = "(label|password|expireDate)='
expect_stdout_is 'id=7 share_type=user path="/Docs" share_with="bob" permissions=31 expiration=none'$'\n'
expect_token_hygiene

# Nextcloud stores a user share's shareWith as given, and an account answers to its login in any case and to its email
# address, but a person sees only the shares stored under their exact login. So --with is looked up first.
new_share_case "a user share named in another case: made for the account's own login"
seed_user bob 'Bob' bob@example.com
FAKE_CURL_RESPONSE="$(share_response 7 0 /Docs bob 31 '' '')"
run_script -- "${share_sh}" --as admin create --path /Docs --type user --with BOB
expect_rc 0
expect_cfg_line 1 "shareWith is the login" 'data-urlencode = "shareWith=bob"'
if [[ "${err}" == *'the login is spelled bob, so the share is made for that'* ]]; then ok "${case_label}: stderr says which spelling was used"
else bad "${case_label}: stderr should say the share is made for bob" "$(dump_case)"; fi
expect_token_hygiene

new_share_case "a user share named by an email address: refused before anything is made, and the login named"
seed_user bob 'Bob' bob@example.com
run_script -- "${share_sh}" --as admin create --path /Docs --type user --with bob@example.com
expect_rc 2
if [[ "${err}" == *'"bob@example.com" is not a login: Nextcloud finds the account "bob"'* && "${err}" == *'--with bob'* && "${err}" == *'Nothing was shared.'* ]]; then ok "${case_label}: stderr names the login and says nothing was shared"
else bad "${case_label}: stderr should name the login bob and say nothing was shared" "$(dump_case)"; fi
expect_call_count curl 0
expect_eq "no app password was made" 0 "$(grep -c 'user:auth-tokens:add' "${FAKE_OCC_LOG}" || true)"

new_share_case "a user share for no account: refused before anything is made"
run_script -- "${share_sh}" --as admin create --path /Docs --type user --with nobody
expect_rc 2
if [[ "${err}" == *'there is no account "nobody" to share with'* ]]; then ok "${case_label}: stderr says there is no such account"
else bad "${case_label}: stderr should say there is no account nobody" "$(dump_case)"; fi
expect_call_count curl 0
expect_eq "no app password was made" 0 "$(grep -c 'user:auth-tokens:add' "${FAKE_OCC_LOG}" || true)"

new_share_case "a group share, no extras"
FAKE_CURL_RESPONSE="$(share_response 8 1 /Docs 'Sales & Ops' 31 '' '')"
run_script -- "${share_sh}" --as admin create --path /Docs --type group --with 'Sales & Ops'
expect_rc 0
expect_cfg_line 1 "shareType 1" 'data-urlencode = "shareType=1"'
expect_cfg_line 1 "the group, as typed" 'data-urlencode = "shareWith=Sales & Ops"'
expect_cfg_none 1 "permissions (none was given, so the server's default applies)" '^data-urlencode = "permissions='
expect_stdout_is 'id=8 share_type=group path="/Docs" share_with="Sales & Ops" permissions=31 expiration=none'$'\n'

new_share_case "an e-mail share, mail asked for, with a password"
FAKE_NOW='2026-10-24 10:15:42'
FAKE_CURL_RESPONSE="$(share_response 9 4 /Docs carol@example.com 17 '2026-11-30 23:59:59' '' 'TokEn1234')"
run_script -- "${share_sh}" --as admin create --path /Docs --type email --with carol@example.com --send-mail --label Finance --password --expire 2026-11-30
expect_rc 0
expect_cfg_line 1 "shareType 4" 'data-urlencode = "shareType=4"'
expect_cfg_line 1 "the address" 'data-urlencode = "shareWith=carol@example.com"'
expect_cfg_line 1 "sendMail=true, as --send-mail asks" 'data-urlencode = "sendMail=true"'
expect_cfg_line 1 "the label" 'data-urlencode = "label=Finance"'
sent_pw="$(cfg_field 1 password)"
if [[ "${sent_pw}" =~ ${pw_line_re} ]]; then ok "${case_label}: a 20-character password was sent"; else bad "${case_label}: no 20-character password in config 1"; fi
expect_stdout_is 'id=9 share_type=email path="/Docs" share_with="carol@example.com" permissions=17 expiration="2026-11-30 23:59:59"'$'\n''password saved to nextcloud-passwords/share-9-20261024-101542.txt'$'\n'
expect_eq "the response has a token but no URL: the file's link is built from NEXTCLOUD_URL with index.php, which works with and without the rewrite" "Link: https://abc.clouve.app/index.php/s/TokEn1234" "$(file_line "${pw_dir}/share-9-20261024-101542.txt" 'Link: ')"
expect_eq "the file holds the password" "${sent_pw:-<no password was sent>}" "$(password_of "${pw_dir}/share-9-20261024-101542.txt")"
expect_secret_hidden "${sent_pw}" "the link password"
expect_token_hygiene

section "share-as-admin.sh: who may use it (exit 2)"
new_share_case "bob is not an admin"
seed_user bob 'Bob' bob@example.com Staff
FAKE_CURL_RESPONSE="$(share_response 1 3 /x '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as bob create --path /Docs --type link
expect_refused 'not in the admin group'
expect_occ_sequence "user:info group:list"

new_share_case "bob is in a group whose name contains admin, and that is not the admin group"
seed_user bob 'Bob' bob@example.com sub-admins Administrators
run_script -- "${share_sh}" --as bob create --path /Docs --type link
expect_refused 'not in the admin group'
group_json="$(FAKE_USERS="${FAKE_USERS}" "${BASH}" -c '. "$1"; . "$2"; . "$3"; fake_group_list --output=json admin' _ "${fake_lib}" "${users_lib}" "${tokens_lib}")"
expect_eq "the search for admin does match those groups too, so the script has to take the exact admin key" yes "$(jq -r 'if has("sub-admins") and has("Administrators") and has("admin") then "yes" else "no" end' <<< "${group_json}")"

new_share_case "the account is disabled"
disable_user admin
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_refused 'the account is disabled'
expect_occ_sequence "user:info group:list"

new_share_case "there is no such account"
run_script -- "${share_sh}" --as ghost create --path /Docs --type link
expect_refused 'there is no account called "ghost"'

new_share_case "nobody is in the admin group at all: group:list prints []"
seed_user admin 'Admin'
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_refused 'not in the admin group'

new_share_case "an admin whose uid is typed in another case is still the admin"
FAKE_CURL_RESPONSE="$(share_response 5 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as ADMIN create --path /Docs --type link
expect_rc 0
expect_cfg_line 1 "the account's own spelling in the credentials" "user = \"admin:${app_token}\""
expect_eq "the token is made for the account's own spelling" '["user:auth-tokens:add","--name=clouve-ai-assistant-temporary","--","admin"]' "$(occ_call_args 4)"
expect_token_hygiene

for how in group-fails group-fails-json group-nojson info-nojson ssh-down; do
  new_share_case "cannot tell whether the account is an admin: ${how}"
  case "${how}" in
    group-fails) FAKE_GROUP_LIST_FAIL=1 ;;
    group-fails-json) FAKE_GROUP_LIST_FAIL=json ;;
    group-nojson) FAKE_GROUP_LIST_NOJSON=1 ;;
    info-nojson) FAKE_INFO_NOJSON=1 ;;
    ssh-down) FAKE_SSH_FAIL='nc.test=255' ;;
  esac
  run_script -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 3
  if [[ "${err}" == *'could not check whether "admin" is an admin'* ]]; then ok "${case_label}: stderr says the check could not be made"
  else bad "${case_label}: the message should say it could not check whether admin is an admin" "$(dump_case)"; fi
  expect_eq "stdout is empty" "" "${out}"
  expect_call_count curl 0
  expect_eq "the token table is untouched" "" "$(token_rows)"
  expect_eq "no lock was taken" "no" "$([ -e "${case_dir}/tmp/${lock_name}" ] && echo yes || echo no)"
  case "${how}" in
    group-fails | group-fails-json) expect_occ_sequence "user:info group:list" ;;
    info-nojson) expect_occ_sequence "user:info" ;;
    ssh-down) if [[ "${err}" == *'could not reach clouve-ops@nc.test'* ]]; then ok "${case_label}: occ.sh's reason is shown"; else bad "${case_label}: occ.sh's could-not-reach line is missing" "$(dump_case)"; fi ;;
  esac
done

section "share-as-admin.sh acts only as the deployment's main admin (exit 2)"
main_admin_msg="share-as-admin.sh acts only as the deployment's main admin (admin); other people, other admins included, share their own files"
new_share_case "a second admin: enabled and in the admin group, but not the main admin"
seed_user eve 'Eve' eve@example.com admin
FAKE_CURL_RESPONSE="$(share_response 1 3 /x '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as eve create --path /Docs --type link
expect_rc 2
if [[ "${err}" == *"[nextcloud/share-as-admin] ${main_admin_msg}"* ]]; then ok "${case_label}: stderr says it acts only as the main admin, names it, and says other admins share their own files"
else bad "${case_label}: expected '${main_admin_msg}'" "$(dump_case)"; fi
expect_eq "stdout is empty" "" "${out}"
expect_call_count curl 0
expect_eq "no token was listed, made or deleted" 0 "$(grep -c 'user:auth-tokens' "${FAKE_OCC_LOG}" || true)"
expect_eq "the token table is untouched" "" "$(token_rows)"
expect_eq "no lock was taken" "no" "$([ -e "${case_dir}/tmp/${lock_name}" ] && echo yes || echo no)"
expect_occ_sequence "user:info group:list"

new_share_case "a second admin is refused for list and for delete, too"
seed_user eve 'Eve' eve@example.com admin
run_script -- "${share_sh}" --as eve list
expect_rc 2
run_script -- "${share_sh}" --as eve delete 42
expect_rc 2
expect_call_count curl 0

new_share_case "the main admin named in another case than NEXTCLOUD_ADMIN_USER spells it"
FAKE_CURL_RESPONSE="$(share_response 1 3 /x '' 17 '' "${link_url}")"
run_script NEXTCLOUD_ADMIN_USER=ADMIN -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_cfg_line 1 "the account's own spelling in the credentials" "user = \"admin:${app_token}\""
expect_token_hygiene

new_share_case "NEXTCLOUD_ADMIN_USER unset or empty: any enabled admin may act"
seed_user eve 'Eve' eve@example.com admin
FAKE_CURL_RESPONSE="$(share_response 1 3 /x '' 17 '' "${link_url}")"
run_script -NEXTCLOUD_ADMIN_USER -- "${share_sh}" --as eve create --path /Docs --type link
expect_rc 0
expect_cfg_line 1 "the second admin's credentials" "user = \"eve:${app_token}\""
run_script NEXTCLOUD_ADMIN_USER= -- "${share_sh}" --as eve create --path /Docs --type link
expect_rc 0

new_share_case "a person who is not an admin still gets the not-an-admin refusal, not the main-admin one"
seed_user bob 'Bob' bob@example.com Staff
run_script -- "${share_sh}" --as bob create --path /Docs --type link
expect_refused 'not in the admin group'
if [[ "${err}" != *'main admin'* ]]; then ok "${case_label}: the main-admin sentence is not used"; else bad "${case_label}: the wrong refusal" "$(dump_case)"; fi

new_share_case "occ.sh cannot load the ops password (clv-secret is not installed): a failure to look, not 'no such account'"
mkdir -p "${case_dir}/bin-no-secret"
for f in "${bin}"/*; do if [ "${f##*/}" != clv-secret ]; then ln -s "${f}" "${case_dir}/bin-no-secret/${f##*/}"; fi; done
if [ -e /usr/bin/clv-secret ] || [ -e /bin/clv-secret ]; then
  ok "${case_label}: skipped, a real clv-secret is installed on this machine"
else
  run_script PATH="${shim_bin}:${case_dir}/bin-no-secret:${BASH%/*}:/usr/bin:/bin" -CLOUVE_OPS_PASSWORD -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 3
  if [[ "${err}" == *'could not check whether "admin" is an admin: user:info failed (exit 1)'* && "${err}" == *'command not found'* ]]; then ok "${case_label}: stderr reports the failure with occ.sh's own words"
  else bad "${case_label}: expected 'user:info failed (exit 1)' and 'command not found'" "$(dump_case)"; fi
  if [[ "${err}" != *'there is no account'* ]]; then ok "${case_label}: it is not reported as a missing account"
  else bad "${case_label}: the failure was taken for a missing account" "$(dump_case)"; fi
  expect_call_count ssh 0
fi

new_share_case "'user not found' after a PHP warning, on its own line, is still a missing account"
FAKE_INFO_NOTFOUND_TEXT=$'PHP Warning:  Undefined array key in /var/www/html/lib/private/x.php on line 1\nuser not found'
run_script -- "${share_sh}" --as ghost create --path /Docs --type link
expect_refused 'there is no account called "ghost"'

new_share_case "'user not found' inside a longer sentence is a failure to look, not a missing account"
FAKE_INFO_NOTFOUND_TEXT='Lookup failed: user not found in backend LDAP'
run_script -- "${share_sh}" --as ghost create --path /Docs --type link
expect_rc 3
if [[ "${err}" == *'could not check whether "ghost" is an admin: user:info failed (exit 1)'* && "${err}" == *'in backend LDAP'* && "${err}" != *'there is no account'* ]]; then ok "${case_label}: stderr reports the failure with occ's words"
else bad "${case_label}: expected a failure to look, with occ's words" "$(dump_case)"; fi

new_share_case "the words 'user not found' with an exit code other than 1 are a failure to look, not a missing account"
FAKE_INFO_NOTFOUND_RC=255
run_script -- "${share_sh}" --as ghost create --path /Docs --type link
expect_rc 3
if [[ "${err}" == *'user:info failed (exit 255)'* && "${err}" != *'there is no account'* ]]; then ok "${case_label}: stderr reports exit 255 as a failure"
else bad "${case_label}: expected 'user:info failed (exit 255)'" "$(dump_case)"; fi

section "share-as-admin.sh: runs take turns (the lock)"
new_share_case "the lock: file descriptor 9, up to 120 seconds, taken after the admin check and before the sweep"
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "flock was asked to wait 120 seconds for file descriptor 9" "flock-fd -w 120 9" "$(grep '^flock-fd ' "${FAKE_CALLS}")"
expect_order "the admin is checked, then the lock is taken, then the sweep starts" '^php .* user:info ' '^php .* group:list ' '^flock-fd ' '^php .* user:auth-tokens:list '
expect_token_hygiene

new_share_case "the lock file is never written or truncated: a link in its place leaves the file it points to alone"
printf 'precious' > "${case_dir}/precious.txt"
ln -s "${case_dir}/precious.txt" "${case_dir}/tmp/${lock_name}"
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "the file the lock path points to is as it was" "precious" "$(cat "${case_dir}/precious.txt")"

new_share_case "the lock file is in TMPDIR"
mkdir -p "${case_dir}/other-tmp"
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script TMPDIR="${case_dir}/other-tmp" -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "there, and empty" "0" "$(wc -c 2> /dev/null < "${case_dir}/other-tmp/${lock_name}" | tr -d ' ')"
expect_eq "and not in the usual temp folder" "no" "$([ -e "${case_dir}/tmp/${lock_name}" ] && echo yes || echo no)"

new_share_case "the lock file can't be opened (a folder is where it goes): exit 1, and nothing was made"
mkdir -p "${case_dir}/tmp/${lock_name}"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 1
if [[ "${err}" == *'could not open the lock file '*"${case_dir}/tmp/${lock_name}"* ]]; then ok "${case_label}: stderr names the lock file"
else bad "${case_label}: the message should name the lock file" "$(dump_case)"; fi
expect_eq "no app password was listed, made or deleted" 0 "$(grep -c 'user:auth-tokens' "${FAKE_OCC_LOG}" || true)"
expect_call_count curl 0

new_share_case "a lock held by another process: the run waits for it and then goes ahead"
hold_lock
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
start_script waiter -- "${share_sh}" --as admin create --path /Docs --type link
wait_for_call '^flock-fd '
expect_eq "while the lock is held the run has not touched an app password" 0 "$(grep -c 'user:auth-tokens' "${FAKE_OCC_LOG}" || true)"
release_lock
finish_script waiter
expect_rc 0
expect_stdout_is "id=42 share_type=link path=\"/Docs\" share_with=- permissions=17 expiration=none url=\"${link_url}\""$'\n'
expect_token_hygiene

new_share_case "a lock that stays held: the run gives up after the wait and has made nothing (exit 3)"
hold_lock
run_script FAKE_FLOCK_WAIT=1 -- "${share_sh}" --as admin create --path /Docs --type link
release_lock
expect_rc 3
if [[ "${err}" == *'not free within 120 seconds'* && "${err}" == *'another share-as-admin.sh run'* ]]; then ok "${case_label}: stderr says the lock was not free and why that may be"
else bad "${case_label}: the message should say the lock was not free within 120 seconds" "$(dump_case)"; fi
expect_eq "no app password was listed, made or deleted" 0 "$(grep -c 'user:auth-tokens' "${FAKE_OCC_LOG}" || true)"
expect_call_count curl 0
expect_eq "stdout is empty" "" "${out}"

new_share_case "two runs at once: neither deletes the other's app password, and both succeed"
# The first run sits in curl with its app password made for 3 seconds, and its own delete takes 2 more. Without the
# lock the second run's sweep deletes that app password and the first run gets a 401; with the lock lifted at the
# start of the first run's clean-up the second run's sweep starts while the first one is still deleting.
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
FAKE_CURL_DELAY_1=3
FAKE_TOKEN_DELETE_DELAY_1=2
start_script first -- "${share_sh}" --as admin create --path /Docs/one --type link
wait_for_file "$(cfg_file 1)"
start_script second -- "${share_sh}" --as admin create --path /Docs/two --type link
finish_script first
first_rc="${rc}"
finish_script second
expect_eq "the first run's exit code" 0 "${first_rc}"
expect_rc 0
expect_eq "both requests were accepted, one after the other" $'curl-call n=1 method=POST auth=ok uid=admin\ncurl-call n=2 method=POST auth=ok uid=admin' "$(grep '^curl-call ' "${FAKE_CALLS}")"
expect_eq "the app password commands ran one run after the other (sweep, make, clean-up delete and read-back)" "list add list delete list list add list delete list" \
  "$(jq -r '.[3]' "${FAKE_OCC_LOG}" | grep '^user:auth-tokens' | sed 's/^user:auth-tokens://' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "each run asked for the lock" 2 "$(grep -c '^flock-fd ' "${FAKE_CALLS}")"
expect_token_hygiene

section "share-as-admin.sh: tokens left by an earlier run are swept first"
new_share_case "two leftovers, a token named cli, near-miss names and another account's token"
seed_user bob 'Bob' bob@example.com Staff
seed_token 3 admin "${temp_name}" left-one
seed_token 4 admin cli
seed_token 5 admin "${temp_name}" left-two
seed_token 6 bob "${temp_name}"
seed_token 7 admin "Clouve-AI-Assistant-Temporary"
seed_token 8 admin "${temp_name}-old"
seed_token 9 admin "my ${temp_name}"
FAKE_CURL_RESPONSE="$(share_response 12 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "only the exact name was swept, for this account only" $'4\tadmin\tcli\n6\tbob\tclouve-ai-assistant-temporary\n7\tadmin\tClouve-AI-Assistant-Temporary\n8\tadmin\tclouve-ai-assistant-temporary-old\n9\tadmin\tmy clouve-ai-assistant-temporary' "$(token_rows)"
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:delete user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_eq "leftover 3 goes first" '["user:auth-tokens:delete","--","admin","3"]' "$(occ_call_args 4)"
expect_eq "then leftover 5" '["user:auth-tokens:delete","--","admin","5"]' "$(occ_call_args 5)"
expect_eq "and the sweep is read back before a new token is made" '["user:auth-tokens:list","--output=json","--","admin"]' "$(occ_call_args 6)"
expect_cfg_line 1 "the new app password, which got the next id" "user = \"admin:${app_token}\""
if [[ "${err}" == *'removed 2 leftover'*"${temp_name}"* ]]; then ok "${case_label}: stderr notes that 2 leftovers were removed"
else bad "${case_label}: expected a note about the 2 removed leftovers" "$(dump_case)"; fi
expect_secret_hidden "${app_token}" "the app password"
expect_secret_hidden "left-one" "a leftover's secret"

new_share_case "a sweep that cannot delete a leftover stops before a new token is made"
seed_token 3 admin "${temp_name}"
FAKE_TOKEN_DELETE_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:delete"
expect_call_count curl 0
if [[ "${err}" == *'could not delete'*'3'* && "${err}" == *'Could not delete the token.'* ]]; then ok "${case_label}: stderr names the token id and shows occ's message"
else bad "${case_label}: the message should name token 3 and show occ's text" "$(dump_case)"; fi
expect_eq "the leftover is still there" $'3\tadmin\tclouve-ai-assistant-temporary' "$(token_rows)"

new_share_case "a delete that exits 0 and removes nothing is caught by the read-back"
seed_token 3 admin "${temp_name}"
FAKE_TOKEN_DELETE_NOOP=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_call_count curl 0
if [[ "${err}" == *'still there'*'3'* ]]; then ok "${case_label}: stderr says token 3 is still there"
else bad "${case_label}: the message should say token 3 is still there" "$(dump_case)"; fi

for how in fail nojson; do
  new_share_case "the sweep cannot list the tokens (${how})"
  if [ "${how}" = fail ]; then FAKE_TOKEN_LIST_FAIL=1; else FAKE_TOKEN_LIST_NOJSON=1; fi
  run_script -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 3
  expect_occ_sequence "user:info group:list user:auth-tokens:list"
  expect_call_count curl 0
  if [[ "${err}" == *'could not list the app passwords of "admin"'* ]]; then ok "${case_label}: stderr says the tokens could not be listed"
  else bad "${case_label}: the message should say the tokens could not be listed" "$(dump_case)"; fi
done

new_share_case "a PHP warning comes before the JSON of user:info and of the token list"
FAKE_TOKEN_LIST_NOISE=1
FAKE_INFO_NOISE=1
seed_token 3 admin "${temp_name}"
FAKE_CURL_RESPONSE="$(share_response 12 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "the leftover was swept and the new token deleted" "" "$(token_rows)"

section "share-as-admin.sh: making the app password"
new_share_case "the token is the last alphanumeric 72-character line (one like it before, a line of punctuation after)"
FAKE_TOKEN_ADD_DECOY=1
FAKE_TOKEN_ADD_TRAILER=1
FAKE_CURL_RESPONSE="$(share_response 12 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_cfg_line 1 "the real token, not the decoy" "user = \"admin:${app_token}\""
expect_secret_hidden "${decoy_token}" "the decoy line"
expect_token_hygiene

new_share_case "user:auth-tokens:add fails"
FAKE_TOKEN_ADD_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
expect_call_count curl 0
if [[ "${err}" == *'could not make the temporary app password'* && "${err}" == *'Could not make the app password.'* ]]; then ok "${case_label}: stderr says so and shows occ's text"
else bad "${case_label}: the message should say the app password could not be made and show occ's text" "$(dump_case)"; fi
expect_eq "stdout is empty" "" "${out}"
expect_token_hygiene

for stream in echo echo-err; do
  new_share_case "user:auth-tokens:add fails and its message holds a token (${stream}): the script blanks it out"
  FAKE_TOKEN_ADD_FAIL="${stream}"
  run_script -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 3
  if [[ "${err}" == *'Could not store the app password [hidden].'* ]]; then ok "${case_label}: stderr has occ's message with the token blanked out"
  else bad "${case_label}: expected 'Could not store the app password [hidden].'" "$(dump_case)"; fi
  expect_token_hygiene
done

new_share_case "add exits 0 but prints no token: the token it made is still deleted"
FAKE_TOKEN_ADD_NOTOKEN=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
expect_call_count curl 0
if [[ "${err}" == *'printed no app password'* ]]; then ok "${case_label}: stderr says occ printed no app password"
else bad "${case_label}: expected 'printed no app password'" "$(dump_case)"; fi
expect_token_hygiene

new_share_case "add prints a 71-character line: not a token"
FAKE_TOKEN_ADD_SHORT=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
expect_call_count curl 0
expect_token_hygiene
expect_secret_hidden "${app_token:1}" "the short token line"

section "share-as-admin.sh: the answer from Nextcloud (exit 3)"
ocs_failure() { # ocs_failure <label> <http> <body> <text stderr must have>...
  local what="$1" http="$2" body="$3" want
  shift 3
  new_share_case "${what}"
  FAKE_CURL_HTTP="${http}"
  FAKE_CURL_RESPONSE="${body}"
  run_script -- "${share_sh}" --as admin create --path /Docs/gone.pdf --type link --password
  expect_rc 3
  for want in "$@"; do
    if [[ "${err}" == *"${want}"* ]]; then ok "${case_label}: stderr has '${want}'"
    else bad "${case_label}: stderr should have '${want}'" "$(dump_case)"; fi
  done
  expect_eq "stdout is empty" "" "${out}"
  expect_eq "no password file" "no" "$([ -e "${pw_dir}" ] && echo yes || echo no)"
  expect_call_count curl 1
  expect_token_hygiene
  expect_secret_hidden "$(cfg_field 1 password)" "the link password"
}
ocs_failure "the path does not exist (the brief's case)" 404 "$(ocs_error 404 'Wrong path, file/folder does not exist')" 'Wrong path, file/folder does not exist' 'HTTP 404'
ocs_failure "a policy refuses" 403 "$(ocs_error 403 'Public upload is not allowed.')" 'Public upload is not allowed.' 'HTTP 403'
ocs_failure "the rate limit (HTTP 429, an empty body)" 429 '' 'HTTP 429' '20 new shares' 'failed logins' 'more than 10 in 30 minutes'
ocs_failure "a proxy answers with a page" 502 '<html><body><h1>502 Bad Gateway</h1></body></html>' 'HTTP 502' 'not OCS JSON' '502 Bad Gateway'
if [[ "${err}" != *'<'* ]]; then ok "${case_label}: the excerpt of the page has no HTML tags"; else bad "${case_label}: the excerpt still has tags" "$(dump_case)"; fi
ocs_failure "maintenance mode" 503 '{"message":"Service unavailable","maintenance":true}' 'HTTP 503' 'not OCS JSON'
ocs_failure "HTTP 200 with an OCS failure inside" 200 "$(ocs_error 403 'Passwords are enforced for link and mail shares')" 'Passwords are enforced for link and mail shares'
ocs_failure "an answer with OCS status 100 (the v1 API's ok), not 200" 200 "$(share_response 42 3 /Docs.pdf '' 17 '' "${link_url}" | jq -c '.ocs.meta.statuscode = 100')" 'HTTP 200'
ocs_failure "JSON without an ocs object" 200 '{"hello":"world"}' 'not OCS JSON'
ocs_failure "success with no share in it" 200 '{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[]}}' 'no share id'

new_share_case "a page that echoes the link password across the 200-character cut: blanked out before it is cut"
pad="$(printf '#%.0s' {1..190})"
FAKE_CURL_HTTP=502
FAKE_CURL_RESPONSE="<html><body>${pad}@PASSWORD@ and more text after it</body></html>"
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 3
sent_pw="$(cfg_field 1 password)"
if [[ -n "${sent_pw}" && "${err}" != *"${sent_pw:0:6}"* && "${err}" != *"${sent_pw: -6}"* ]]; then ok "${case_label}: neither the start nor the end of the password is in stderr"
else bad "${case_label}: a piece of the password reached stderr" "$(dump_case)"; fi
if [[ "${err}" != *'more text after it'* ]]; then ok "${case_label}: the excerpt is cut at 200 characters"; else bad "${case_label}: the excerpt was not cut" "$(dump_case)"; fi
expect_secret_hidden "${sent_pw}" "the link password"
expect_token_hygiene

new_share_case "curl cannot connect"
FAKE_CURL_EXIT=7
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
if [[ "${err}" == *'curl'*'exit 7'* && "${err}" == *'http://nc.test'* ]]; then ok "${case_label}: stderr says curl got no answer from http://nc.test"
else bad "${case_label}: expected curl's exit 7 and the address" "$(dump_case)"; fi
expect_token_hygiene

new_share_case "the app password is refused (something deleted it while the request was on its way)"
FAKE_CURL_REVOKE=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 3
if [[ "${err}" == *'HTTP 401'* && "${err}" == *'brute-force throttle'* && "${err}" == *'do not retry in a loop'* ]]; then ok "${case_label}: stderr says HTTP 401, that failed logins feed the throttle, and not to retry in a loop"
else bad "${case_label}: expected HTTP 401 and the hint about the brute-force throttle" "$(dump_case)"; fi
expect_token_hygiene

new_share_case "Nextcloud echoes the link password and the app password in its refusal: the script blanks them out"
FAKE_CURL_HTTP=400
FAKE_CURL_RESPONSE="$(ocs_error 400 'The password @PASSWORD@ is too weak, and @TOKEN@ is not for sharing')"
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 3
if [[ "${err}" == *'The password [hidden] is too weak, and [hidden] is not for sharing'* ]]; then ok "${case_label}: stderr has the message with both values blanked out"
else bad "${case_label}: expected both values replaced by [hidden]" "$(dump_case)"; fi
expect_secret_hidden "$(cfg_field 1 password)" "the link password"
expect_token_hygiene

section "share-as-admin.sh: the temporary token is deleted however the run ends"
# A fake curl that signals the script while the request is in flight. bash runs a trap when the foreground
# command ends, so the answer arrives and is thrown away: the share exists, the run reports nothing.
# run_script starts the script with these signals at their defaults, however this suite was started.
for pair in TERM:143 HUP:129 INT:130 PIPE:141; do
  sig="${pair%%:*}"
  want_rc="${pair#*:}"
  new_share_case "SIG${sig} arrives while curl is running"
  FAKE_PIDFILE="${case_dir}/script.pid"
  FAKE_CURL_KILL="${sig}"
  if [ "${sig}" != PIPE ]; then FAKE_CURL_LINGER=0.7; fi   # PIPE has no trap: bash ends the script at once
  FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
  # bash ends a script whose child died of SIGINT unless the harness has a trap for it: this one is empty on purpose
  if [ "${sig}" = INT ]; then trap : INT; fi
  run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
  if [ "${sig}" = INT ]; then trap - INT; fi
  expect_rc "${want_rc}"
  expect_eq "the request did go out with the app password" "curl-call n=1 method=POST auth=ok uid=admin" "$(grep '^curl-call ' "${FAKE_CALLS}")"
  expect_eq "stdout is empty: the answer was thrown away" "" "${out}"
  expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
  if [ "${sig}" != PIPE ]; then
    expect_order "the request in flight is waited for (the trap runs when it ends), and only then is the token deleted" '^curl-call ' '^curl-done ' '^php .* user:auth-tokens:delete '
  fi
  expect_token_hygiene
  expect_secret_hidden "$(cfg_field 1 password)" "the link password"
done

new_share_case "SIGTERM arrives while the app password is being made"
FAKE_PIDFILE="${case_dir}/script.pid"
FAKE_TOKEN_ADD_KILL=TERM
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 143
expect_call_count curl 0
expect_eq "the token the fake made is deleted, though the script never took its value" 0 "$(temp_tokens_left)"
expect_secret_hidden "${app_token}" "the app password"

new_share_case "a second SIGTERM arrives while the clean-up is deleting: the clean-up still reads the list back"
FAKE_PIDFILE="${case_dir}/script.pid"
FAKE_CURL_KILL=TERM
FAKE_TOKEN_DELETE_KILL=TERM
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 143
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_token_hygiene

new_share_case "SIGKILL cannot be trapped: the token stays, and the next run sweeps it"
FAKE_PIDFILE="${case_dir}/script.pid"
FAKE_CURL_KILL=KILL
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 137
expect_eq "the token is still there" 1 "$(temp_tokens_left)"
FAKE_PIDFILE=""
FAKE_CURL_KILL=""
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_eq "the next run swept it, and its own is deleted too" 0 "$(temp_tokens_left)"
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_secret_hidden "${app_token}" "the app password"

section "share-as-admin.sh: when the token cannot be deleted at the end"
new_share_case "the create works, then the delete fails"
FAKE_TOKEN_DELETE_FAIL=1
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 5
expect_stdout_is "id=42 share_type=link path=\"/Docs\" share_with=- permissions=17 expiration=none url=\"${link_url}\""$'\n'
if [[ "${err}" == *'WARNING'* && "${err}" == *'The request itself went through; do not repeat it.'* && "${err}" == *'user:auth-tokens:delete -- admin 1'* && "${err}" == *'Could not delete the token.'* ]]; then ok "${case_label}: stderr warns, says the request went through and must not be repeated, and names the token id and the command that deletes it"
else bad "${case_label}: the message should warn, say the request went through and not to repeat it, name token 1 and the delete command" "$(dump_case)"; fi
expect_eq "the token is still in the table" 1 "$(temp_tokens_left)"
expect_secret_hidden "${app_token}" "the app password"

new_share_case "the delete command the clean-up suggests quotes an odd uid"
seed_user "${odd_admin}" 'Brien' '' admin
FAKE_TOKEN_DELETE_FAIL=1
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script NEXTCLOUD_ADMIN_USER="${odd_admin}" -- "${share_sh}" --as "${odd_admin}" create --path /Docs --type link
expect_rc 5
if [[ "${err}" == *"occ.sh user:auth-tokens:delete -- O\\'Brien\\ Jr 1"* ]]; then ok "${case_label}: the uid is quoted for the shell in the suggested command"
else bad "${case_label}: expected -- O\\'Brien\\ Jr 1 in the suggested command" "$(dump_case)"; fi

new_share_case "the create works, then the delete exits 0 and removes nothing"
FAKE_TOKEN_DELETE_NOOP=1
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 5
if [[ "${err}" == *'WARNING'* && "${err}" == *'still there'* && "${err}" == *'do not repeat it'* ]]; then ok "${case_label}: the read-back found the token and stderr says so"
else bad "${case_label}: expected a warning that the token is still there" "$(dump_case)"; fi

new_share_case "the create works, then the token list cannot be read at the end (no id to name)"
FAKE_TOKEN_LIST_FAIL_FROM=2
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 5
expect_stdout_is "id=42 share_type=link path=\"/Docs\" share_with=- permissions=17 expiration=none url=\"${link_url}\""$'\n'
if [[ "${err}" == *'WARNING'* && "${err}" == *'The request itself went through; do not repeat it.'* && "${err}" == *'Find its id with: '*'occ.sh user:auth-tokens:list -- admin'* && "${err}" == *'Could not list the tokens.'* ]]; then ok "${case_label}: stderr warns and says how to find the token's id"
else bad "${case_label}: the message should warn, say the request went through and say how to list the tokens" "$(dump_case)"; fi
expect_eq "the token is still in the table" 1 "$(temp_tokens_left)"
expect_secret_hidden "${app_token}" "the app password"

new_share_case "the create works, the token is deleted, but the read-back of the list fails: not confirmed, so it is reported"
FAKE_TOKEN_LIST_FAIL_FROM=3
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 5
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
if [[ "${err}" == *'WARNING'* && "${err}" == *'Could not list the tokens.'* ]]; then ok "${case_label}: stderr warns that the delete could not be confirmed"
else bad "${case_label}: the message should warn and show occ's text" "$(dump_case)"; fi
expect_eq "the token itself is gone, as the delete said" 0 "$(temp_tokens_left)"

new_share_case "a delete of a share goes through, then the token delete fails: exit 5, and the result is on stdout"
FAKE_TOKEN_DELETE_FAIL=1
run_script -- "${share_sh}" --as admin delete 42
expect_rc 5
expect_stdout_is $'deleted share 42\n'
if [[ "${err}" == *'The request itself went through; do not repeat it.'* && "${err}" == *'user:auth-tokens:delete -- admin 1'* ]]; then ok "${case_label}: stderr says the request went through and how to delete the token"
else bad "${case_label}: expected the warning with the delete command" "$(dump_case)"; fi

new_share_case "a list goes through, then the token delete fails: exit 5, and the list is on stdout"
FAKE_TOKEN_DELETE_FAIL=1
FAKE_CURL_RESPONSE="$(jq -sc '{ocs: {meta: {status: "ok", statuscode: 200, message: "OK"}, data: .}}' <(share_response 42 3 /Docs '' 17 '' "${link_url}" | jq -c .ocs.data))"
run_script -- "${share_sh}" --as admin list
expect_rc 5
expect_stdout_is "id=42 share_type=link path=\"/Docs\" share_with=- permissions=17 expiration=none url=\"${link_url}\""$'\n'

new_share_case "a create whose link password cannot be saved, with a token that cannot be deleted: the exit code stays 4"
FAKE_TOKEN_DELETE_FAIL=1
FAKE_CAT_FAIL=1
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 4
if [[ "${err}" == *'WARNING'* && "${err}" != *'do not repeat it'* ]]; then ok "${case_label}: the warning is there and does not say the request went through"
else bad "${case_label}: expected the warning without 'do not repeat it'" "$(dump_case)"; fi

new_share_case "Nextcloud refuses and the delete fails too: the exit code stays 3 and both are reported"
FAKE_TOKEN_DELETE_FAIL=1
FAKE_CURL_HTTP=404
FAKE_CURL_RESPONSE="$(ocs_error 404 'Wrong path, file/folder does not exist')"
run_script -- "${share_sh}" --as admin create --path /Docs/gone --type link
expect_rc 3
if [[ "${err}" == *'Wrong path, file/folder does not exist'* && "${err}" == *'WARNING'* ]]; then ok "${case_label}: stderr has the refusal and the warning"
else bad "${case_label}: expected both messages" "$(dump_case)"; fi

new_share_case "killed, and the delete fails: the exit code stays that of the signal"
FAKE_PIDFILE="${case_dir}/script.pid"
FAKE_CURL_KILL=TERM
FAKE_TOKEN_DELETE_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 143
if [[ "${err}" == *'WARNING'* ]]; then ok "${case_label}: stderr warns about the token"; else bad "${case_label}: expected a warning" "$(dump_case)"; fi

section "share-as-admin.sh: a link password that cannot be saved (exit 4, the share is deleted again)"
cant_save() { # cant_save <label>: the common checks after a run whose password file could not be written
  expect_rc 4
  expect_eq "stdout is empty" "" "${out}"
  expect_call_count curl 2
  expect_eq "the share was deleted with the same app password, before the token went" $'curl-call n=1 method=POST auth=ok uid=admin\ncurl-call n=2 method=DELETE auth=ok uid=admin' "$(grep '^curl-call ' "${FAKE_CALLS}")"
  expect_eq "the delete is of share 42" "curl$(printf ' %q' -q -sS -m 30 -K - --noproxy '*' -X DELETE -w '\n%{http_code}' "http://nc.test${ocs_base}/42?format=json")" "$(grep '^curl ' "${FAKE_CALLS}" | sed -n 2p)"
  expect_cfg_lines 2 4
  expect_token_hygiene
  expect_secret_hidden "$(cfg_field 1 password)" "the link password"
  expect_eq "nothing is left in the folder" "" "$(pw_files)"
}
if [ "$(id -u)" -ne 0 ]; then
  new_share_case "the home folder is read-only (the brief's case)"
  FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
  chmod 500 "${pw_home}"
  run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
  chmod 700 "${pw_home}"
  cant_save
  if [[ "${err}" == *'could not save the link password'* && "${err}" == *'share 42 was deleted again'* ]]; then ok "${case_label}: stderr says the password could not be saved and the share was deleted again"
  else bad "${case_label}: the message should say the password could not be saved and share 42 was deleted again" "$(dump_case)"; fi
else
  ok "running as root: a read-only home cannot be tested here, so that case is skipped"
fi

new_share_case "the write fails after the file is made (the disk is full)"
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
FAKE_CAT_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
cant_save

new_share_case "the file name is taken"
FAKE_NOW='2026-10-24 10:15:42'
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
mkdir -p "${pw_dir}"
chmod 700 "${pw_dir}"
printf 'earlier\n' > "${pw_dir}/share-42-20261024-101542.txt"
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 4
expect_eq "the earlier file is untouched" "earlier" "$(cat "${pw_dir}/share-42-20261024-101542.txt")"
expect_call_count curl 2

new_share_case "the share cannot be deleted either"
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
FAKE_CURL_HTTP_2=500
FAKE_CURL_RESPONSE_2="$(ocs_error 500 'Could not delete share')"
FAKE_CAT_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 4
if [[ "${err}" == *'could not save the link password'* && "${err}" == *'share 42 could not be deleted'* && "${err}" == *'Could not delete share'* && "${err}" == *'delete 42'* ]]; then ok "${case_label}: stderr says share 42 is still there, why, and how to delete it"
else bad "${case_label}: the message should say share 42 could not be deleted, show the reason and name the delete command" "$(dump_case)"; fi
expect_token_hygiene
expect_secret_hidden "$(cfg_field 1 password)" "the link password"

new_share_case "a link share with a password: HOME does not exist (checked before anything is made)"
run_script HOME="${case_dir}/nowhere" -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 1
expect_occ_calls 0
if [[ "${err}" == *'HOME'* ]]; then ok "${case_label}: stderr names HOME"; else bad "${case_label}: the message should name HOME" "$(dump_case)"; fi

section "share-as-admin.sh: quoting, and no way to add a curl option"
new_share_case "a note with a quote, a backslash, a newline and a fake config line"
FAKE_CURL_RESPONSE="$(share_response 5 3 '/Docs/a "b" \c.pdf' '' 17 '' "${link_url}")"
odd_note=$'He said "hi" \\ and left\nurl = "http://evil.example/"\r\toutput = "/tmp/x"'
odd_label=$'x"y\\'
run_script -- "${share_sh}" --as admin create --path '/Docs/a "b" \c.pdf' --type link --note "${odd_note}" --label "${odd_label}"
expect_rc 0
expect_cfg_line 1 "the note, with the quote and the backslash escaped and the newline, return and tab written as \\n \\r \\t" 'data-urlencode = "note=He said \"hi\" \\ and left\nurl = \"http://evil.example/\"\r\toutput = \"/tmp/x\""'
expect_cfg_line 1 "the label, escaped" 'data-urlencode = "label=x\"y\\"'
expect_cfg_line 1 "the path, escaped" 'data-urlencode = "path=/Docs/a \"b\" \\c.pdf"'
expect_cfg_none 1 "line that is not user, header or data-urlencode" '^(url|output|config|proxy|next|upload-file|write-out|data|form|cookie|request)[ =]'
expect_cfg_lines 1 9
expect_stdout_is 'id=5 share_type=link path="/Docs/a \"b\" \\c.pdf" share_with=- permissions=17 expiration=none url="'"${link_url}"'"'$'\n'

new_share_case "non-ASCII and shell syntax in the path, the group and the uid reach the config as typed"
seed_user "Zoë's \$(touch pwned) \`id\`" 'Zoë' '' admin
FAKE_CURL_RESPONSE="$(share_response 6 1 '/Dokumente/Übersicht $HOME.pdf' 'Équipe; rm -rf ~' 31 '' '')"
run_script NEXTCLOUD_ADMIN_USER="Zoë's \$(touch pwned) \`id\`" -- "${share_sh}" --as "Zoë's \$(touch pwned) \`id\`" create --path '/Dokumente/Übersicht $HOME.pdf' --type group --with 'Équipe; rm -rf ~'
expect_rc 0
expect_cfg_line 1 "the path" 'data-urlencode = "path=/Dokumente/Übersicht $HOME.pdf"'
expect_cfg_line 1 "the group" 'data-urlencode = "shareWith=Équipe; rm -rf ~"'
expect_cfg_line 1 "the credentials" "user = \"Zoë's \$(touch pwned) \`id\`:${app_token}\""
expect_eq "the token is made for the odd uid as one argument" "$(jq -nc --arg u "Zoë's \$(touch pwned) \`id\`" '["user:auth-tokens:add","--name=clouve-ai-assistant-temporary","--",$u]')" "$(occ_call_args 4)"
if [ ! -e "${FAKE_OPS_HOME}/pwned" ] && [ ! -e "${pw_home}/pwned" ] && [ ! -e "${case_dir}/pwned" ]; then ok "${case_label}: nothing was executed from the names"
else bad "${case_label}: a command substitution ran"; fi
expect_token_hygiene

new_share_case "an account whose uid starts with a dash"
seed_user -odd 'Odd' '' admin
FAKE_CURL_RESPONSE="$(share_response 6 3 /Docs '' 17 '' "${link_url}")"
run_script NEXTCLOUD_ADMIN_USER=-odd -- "${share_sh}" --as -odd create --path /Docs --type link
expect_rc 0
expect_eq "the account comes after --, so a uid with a leading dash is not an option" '["user:info","--output=json","--","-odd"]' "$(occ_call_args 1)"
expect_eq "every call ends its options before the uid" '["user:auth-tokens:add","--name=clouve-ai-assistant-temporary","--","-odd"]' "$(occ_call_args 4)"
expect_eq "the delete too" '["user:auth-tokens:delete","--","-odd","1"]' "$(occ_call_args 6)"
expect_cfg_line 1 "the credentials" "user = \"-odd:${app_token}\""
expect_token_hygiene

new_share_case "the command suggested when a create has no share id quotes an odd uid"
seed_user "${odd_admin}" 'Brien' '' admin
FAKE_CURL_RESPONSE='{"ocs":{"meta":{"status":"ok","statuscode":200,"message":"OK"},"data":[]}}'
run_script NEXTCLOUD_ADMIN_USER="${odd_admin}" -- "${share_sh}" --as "${odd_admin}" create --path /Docs --type link
expect_rc 3
if [[ "${err}" == *"share-as-admin.sh --as O\\'Brien\\ Jr list"* ]]; then ok "${case_label}: the uid is quoted for the shell in the suggested command"
else bad "${case_label}: expected --as O\\'Brien\\ Jr in the suggested command" "$(dump_case)"; fi

new_share_case "the delete command suggested after a failed save quotes an odd uid"
seed_user "${odd_admin}" 'Brien' '' admin
FAKE_CURL_RESPONSE="$(share_response 42 3 /Docs '' 17 '' "${link_url}")"
FAKE_CURL_HTTP_2=500
FAKE_CURL_RESPONSE_2="$(ocs_error 500 'Could not delete share')"
FAKE_CAT_FAIL=1
run_script NEXTCLOUD_ADMIN_USER="${odd_admin}" -- "${share_sh}" --as "${odd_admin}" create --path /Docs --type link --password
expect_rc 4
if [[ "${err}" == *"share-as-admin.sh --as O\\'Brien\\ Jr delete 42"* ]]; then ok "${case_label}: the uid is quoted for the shell in the suggested command"
else bad "${case_label}: expected --as O\\'Brien\\ Jr delete 42 in the suggested command" "$(dump_case)"; fi

new_share_case "the delete command suggested after a failed save quotes an odd share id, too"
FAKE_CURL_RESPONSE="$(share_response '7 8' 3 /Docs '' 17 '' "${link_url}")"
FAKE_CURL_HTTP_2=500
FAKE_CURL_RESPONSE_2="$(ocs_error 500 'Could not delete share')"
FAKE_CAT_FAIL=1
run_script -- "${share_sh}" --as admin create --path /Docs --type link --password
expect_rc 4
if [[ "${err}" == *'share-as-admin.sh --as admin delete 7\ 8'* ]]; then ok "${case_label}: the id is quoted for the shell in the suggested command"
else bad "${case_label}: expected 'delete 7\\ 8' in the suggested command" "$(dump_case)"; fi

new_share_case "NEXTCLOUD_URL with a trailing slash, a path and a port: the Host header is the host and the port"
FAKE_CURL_RESPONSE="$(share_response 6 3 /Docs '' 17 '' "${link_url}")"
run_script NEXTCLOUD_URL=https://abc.clouve.app:8443/nextcloud/ -- "${share_sh}" --as admin create --path /Docs --type link
expect_rc 0
expect_cfg_line 1 "Host with the port, no path" 'header = "Host: abc.clouve.app:8443"'
new_share_case "NEXTCLOUD_URL with a trailing slash only"
FAKE_CURL_RESPONSE="$(share_response 6 3 /Docs '' 17 '' "${link_url}")"
run_script NEXTCLOUD_URL=https://abc.clouve.app/ -- "${share_sh}" --as admin create --path /Docs --type link
expect_cfg_line 1 "Host without the slash" 'header = "Host: abc.clouve.app"'

section "share-as-admin.sh list"
new_share_case "list of the account's shares"
FAKE_CURL_RESPONSE="$(jq -sc '{ocs: {meta: {status: "ok", statuscode: 200, message: "OK"}, data: .}}' \
  <(share_response 42 3 '/Docs/Q3 report.pdf' '' 17 '2026-12-31 23:59:59' "${link_url}" | jq -c .ocs.data) \
  <(share_response 7 0 '/Docs/new "line"'$'\n''x' bob 31 '' '' | jq -c .ocs.data) \
  <(share_response 9 4 /Docs carol@example.com 17 '' '' 'TokEn1234' | jq -c .ocs.data) \
  <(share_response 10 6 /Docs 'dana@other.example.org' 1 '' '' | jq -c .ocs.data) \
  <(share_response 11 99 /Docs x 1 '' '' | jq -c .ocs.data))"
run_script -- "${share_sh}" --as admin list
expect_rc 0
expect_stdout_is "id=42 share_type=link path=\"/Docs/Q3 report.pdf\" share_with=- permissions=17 expiration=\"2026-12-31 23:59:59\" url=\"${link_url}\""$'\n'\
'id=7 share_type=user path="/Docs/new \"line\"\nx" share_with="bob" permissions=31 expiration=none'$'\n'\
'id=9 share_type=email path="/Docs" share_with="carol@example.com" permissions=17 expiration=none'$'\n'\
'id=10 share_type=remote path="/Docs" share_with="dana@other.example.org" permissions=1 expiration=none'$'\n'\
'id=11 share_type=99 path="/Docs" share_with="x" permissions=1 expiration=none'$'\n'
expect_eq "curl's argv: a GET, no -G because no field is sent" "curl$(printf ' %q' -q -sS -m 30 -K - --noproxy '*' -X GET -w '\n%{http_code}' "http://nc.test${ocs_base}?format=json")" "$(grep '^curl ' "${FAKE_CALLS}")"
expect_cfg_lines 1 4
expect_cfg_line 1 "the credentials" "user = \"admin:${app_token}\""
expect_occ_sequence "user:info group:list user:auth-tokens:list user:auth-tokens:add user:auth-tokens:list user:auth-tokens:delete user:auth-tokens:list"
expect_token_hygiene

new_share_case "list of one path also asks for reshares"
FAKE_CURL_RESPONSE="$(ocs_error 200 OK | jq -c '.ocs.data = []')"
run_script -- "${share_sh}" --as admin list --path '/Docs/Q3 report.pdf'
expect_rc 0
expect_stdout_is $'no shares\n'
expect_eq "curl's argv: -G, so the fields go in the query" "curl$(printf ' %q' -q -sS -m 30 -K - --noproxy '*' -G -X GET -w '\n%{http_code}' "http://nc.test${ocs_base}?format=json")" "$(grep '^curl ' "${FAKE_CALLS}")"
expect_cfg_line 1 "the path" 'data-urlencode = "path=/Docs/Q3 report.pdf"'
expect_cfg_line 1 "reshares=true" 'data-urlencode = "reshares=true"'
expect_cfg_lines 1 6
expect_token_hygiene

new_share_case "list when Nextcloud refuses"
FAKE_CURL_HTTP=404
FAKE_CURL_RESPONSE="$(ocs_error 404 'Wrong path, file/folder does not exist')"
run_script -- "${share_sh}" --as admin list --path /nope
expect_rc 3
if [[ "${err}" == *'Wrong path, file/folder does not exist'* ]]; then ok "${case_label}: stderr has the message"; else bad "${case_label}: the message is missing" "$(dump_case)"; fi
expect_token_hygiene

new_share_case "list with no HOME at all: only --password needs it"
FAKE_CURL_RESPONSE="$(ocs_error 200 OK | jq -c '.ocs.data = []')"
run_script -HOME -- "${share_sh}" --as admin list
expect_rc 0
expect_stdout_is $'no shares\n'

section "share-as-admin.sh delete"
new_share_case "delete share 42"
run_script -- "${share_sh}" --as admin delete 42
expect_rc 0
expect_stdout_is $'deleted share 42\n'
expect_eq "curl's argv: a DELETE of that share, no data" "curl$(printf ' %q' -q -sS -m 30 -K - --noproxy '*' -X DELETE -w '\n%{http_code}' "http://nc.test${ocs_base}/42?format=json")" "$(grep '^curl ' "${FAKE_CALLS}")"
expect_cfg_lines 1 4
expect_cfg_none 1 "data-urlencode line" '^data-urlencode'
expect_token_hygiene

new_share_case "delete a share that is not there"
FAKE_CURL_HTTP=404
FAKE_CURL_RESPONSE="$(ocs_error 404 'Wrong share ID, share does not exist')"
run_script -- "${share_sh}" --as admin delete 999
expect_rc 3
if [[ "${err}" == *'Wrong share ID, share does not exist'* && "${err}" == *'HTTP 404'* ]]; then ok "${case_label}: stderr has the message and the HTTP code"; else bad "${case_label}: expected the message and the HTTP code" "$(dump_case)"; fi
expect_eq "stdout does not claim a deletion" "" "${out}"

section "share-as-admin.sh: usage (exit 64)"
expect_share_usage_error() { # expect_share_usage_error <label> <arguments...>: refused before anything is touched
  new_case "usage: $1"
  shift
  run_script -- "${share_sh}" "$@"
  expect_rc 64
  if [[ "${err}" == *"${share_usage}"* ]]; then ok "${case_label}: the usage is on stderr"
  else bad "${case_label}: no usage line on stderr" "$(dump_case)"; fi
  expect_eq "stdout is empty" "" "${out}"
  expect_call_count ssh 0
  expect_call_count curl 0
  expect_eq "the token table is untouched" "" "$(token_rows)"
}
expect_share_usage_error "no arguments"
expect_share_usage_error "no --as" create --path /Docs --type link
expect_share_usage_error "--as without a value" --as
expect_share_usage_error "an empty --as" --as '' create --path /Docs --type link
expect_share_usage_error "no action" --as admin
expect_share_usage_error "an unknown action" --as admin remove 42
expect_share_usage_error "an unknown option" --as admin create --path /Docs --type link --frobnicate
expect_share_usage_error "--type user without --with" --as admin create --path /Docs --type user
expect_share_usage_error "--type group without --with" --as admin create --path /Docs --type group
expect_share_usage_error "--type email without --with" --as admin create --path /Docs --type email
expect_share_usage_error "--type link with --with" --as admin create --path /Docs --type link --with x
expect_share_usage_error "--type email with an address that is not one" --as admin create --path /Docs --type email --with carol
expect_share_usage_error "no --type" --as admin create --path /Docs
expect_share_usage_error "an unknown --type" --as admin create --path /Docs --type federated --with x@y
expect_share_usage_error "no --path" --as admin create --type link
expect_share_usage_error "an empty --path" --as admin create --path '' --type link
expect_share_usage_error "--permissions 99" --as admin create --path /Docs --type link --permissions 99
expect_share_usage_error "--permissions 0" --as admin create --path /Docs --type link --permissions 0
expect_share_usage_error "--permissions 32" --as admin create --path /Docs --type link --permissions 32
expect_share_usage_error "--permissions abc" --as admin create --path /Docs --type link --permissions abc
expect_share_usage_error "--permissions 1x" --as admin create --path /Docs --type link --permissions 1x
expect_share_usage_error "--permissions with a huge number" --as admin create --path /Docs --type link --permissions 99999999999999999999
expect_share_usage_error "--permissions with a number that wraps around to 1 in 64 bits" --as admin create --path /Docs --type link --permissions 18446744073709551617
expect_share_usage_error "--expire without zeros" --as admin create --path /Docs --type link --expire 2026-1-1
expect_share_usage_error "--expire in another shape" --as admin create --path /Docs --type link --expire 31/12/2026
expect_share_usage_error "--expire with a trailing newline" --as admin create --path /Docs --type link --expire $'2026-12-31\n'
expect_share_usage_error "--expire with a time" --as admin create --path /Docs --type link --expire '2026-12-31 10:00'
expect_share_usage_error "--password with a user share" --as admin create --path /Docs --type user --with bob --password
expect_share_usage_error "--label with a group share" --as admin create --path /Docs --type group --with Staff --label x
expect_share_usage_error "--send-mail with list" --as admin list --send-mail
expect_share_usage_error "--password with list" --as admin list --password
expect_share_usage_error "--send-mail with delete" --as admin delete 42 --send-mail
expect_share_usage_error "--type with list" --as admin list --type link
expect_share_usage_error "list with a share id" --as admin list 42
expect_share_usage_error "delete without an id" --as admin delete
expect_share_usage_error "delete with a word" --as admin delete abc
expect_share_usage_error "delete with an id and a path after it" --as admin delete 42 /Docs
expect_share_usage_error "delete with a negative id" --as admin delete -1
expect_share_usage_error "delete with an id that has a slash in it" --as admin delete 4/2
expect_share_usage_error "delete with --path" --as admin delete 42 --path /Docs
expect_share_usage_error "create with a stray word" --as admin create extra --path /Docs --type link
expect_share_usage_error "--note without a value" --as admin create --path /Docs --type link --note
expect_share_usage_error "an empty --note" --as admin create --path /Docs --type link --note ''
expect_share_usage_error "an empty --expire" --as admin create --path /Docs --type link --expire ''
expect_share_usage_error "an empty --with" --as admin create --path /Docs --type group --with ''
expect_share_usage_error "an empty --permissions" --as admin create --path /Docs --type link --permissions ''
expect_share_usage_error "an empty --label" --as admin create --path /Docs --type link --label ''
expect_share_usage_error "an empty --type" --as admin create --path /Docs --type ''
expect_share_usage_error "the id of a delete given as an empty word" --as admin delete ''
expect_share_usage_error "--note on delete" --as admin delete 42 --note hi

for flag in --help -h; do
  new_share_case "${flag}"
  run_script -- "${share_sh}" "${flag}"
  expect_rc 0
  flat_usage="${out//$'\n'/ }"
  if [[ "${out}" == "${share_usage}"* && "${out}" == *'share-as-admin.sh --as <uid> delete <share id>'* && "${out}" == *'--note TEXT'* && "${out}" == *'--label TEXT'* && "${flat_usage}" == *' 5 the request went through but the temporary app password could not be deleted'* ]]; then ok "${case_label}: the usage is on stdout, with every option and exit code described"
  else bad "${case_label}: no usage on stdout" "$(dump_case)"; fi
  expect_call_count ssh 0
done

new_share_case "the --option=value forms, and options before the action"
FAKE_CURL_RESPONSE="$(share_response 6 1 /Docs Staff 5 '2026-11-30 23:59:59' '')"
run_script -- "${share_sh}" --as=admin --path=/Docs --type=group --with=Staff --permissions=5 --expire=2026-11-30 --note=Hi create
expect_rc 0
expect_cfg_line 1 "shareType 1" 'data-urlencode = "shareType=1"'
expect_cfg_line 1 "shareWith" 'data-urlencode = "shareWith=Staff"'
expect_cfg_line 1 "permissions" 'data-urlencode = "permissions=5"'
expect_cfg_line 1 "the expiry" 'data-urlencode = "expireDate=2026-11-30"'
expect_cfg_line 1 "the note" 'data-urlencode = "note=Hi"'

new_share_case "a permissions value with a leading zero is sent without it"
run_script -- "${share_sh}" --as admin create --path /Docs --type group --with Staff --permissions 07
expect_cfg_line 1 "permissions 7" 'data-urlencode = "permissions=7"'

section "share-as-admin.sh: the environment (exit 1)"
for missing in NEXTCLOUD_HOST NEXTCLOUD_URL; do
  for how in unset empty; do
    new_case "${missing} ${how}"
    if [ "${how}" = unset ]; then run_script "-${missing}" -- "${share_sh}" --as admin create --path /Docs --type link
    else run_script "${missing}=" -- "${share_sh}" --as admin create --path /Docs --type link; fi
    expect_rc 1
    expect_call_count ssh 0
    expect_call_count curl 0
    if [[ "${err}" == *"${missing} is not set"* ]]; then ok "${case_label}: stderr says ${missing} is not set"; else bad "${case_label}: the message should say ${missing} is not set" "$(dump_case)"; fi
  done
done
for bad_host in 'bad host' 'host/evil' 'a"b' 'host:abc' '-leading' 'host:' 'nc.test, other'; do
  new_case "NEXTCLOUD_HOST is '${bad_host}'"
  run_script NEXTCLOUD_HOST="${bad_host}" -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 1
  expect_call_count ssh 0
  expect_call_count curl 0
done
for bad_url in 'https://' 'abc clouve app' 'https://user:pw@abc.clouve.app' 'https://abc.clouve.app"x' 'https://abc.clouve.app:port'; do
  new_case "NEXTCLOUD_URL is '${bad_url}'"
  run_script NEXTCLOUD_URL="${bad_url}" -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 1
  expect_call_count ssh 0
  expect_call_count curl 0
  if [[ "${bad_url}" == *'pw@'* ]]; then expect_secret_hidden "pw@" "the password in the URL"; fi
done
for missing in jq curl flock; do
  new_case "${missing} is not installed"
  mkdir -p "${case_dir}/no-${missing}-bin"
  for f in /usr/bin/*; do [ "${f##*/}" = "${missing}" ] || printf '%s\0' "${f}"; done | xargs -0 ln -sf -t "${case_dir}/no-${missing}-bin"   # everything the script needs, bar one tool
  run_script PATH="${case_dir}/no-${missing}-bin" -- "${share_sh}" --as admin create --path /Docs --type link
  expect_rc 1
  if [[ "${err}" == *"${missing} is not installed"* ]]; then ok "${case_label}: stderr says ${missing} is missing"; else bad "${case_label}: the message should say ${missing} is missing" "$(dump_case)"; fi
  expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"
done

section "share-as-admin.sh: the harness (deny stubs)"
new_case "a tool nobody fakes exits 99 and does not run"
run_script -- "${BASH}" -c 'mariadb -e "select 1"; echo "mariadb rc=$?"; ssh nowhere true; echo "ssh rc=$?"; docker ps; echo "docker rc=$?"'
expect_eq "each stub says it is a stub and exits 99" $'mariadb rc=99\nssh rc=99\ndocker rc=99' "${out}"
if [[ "${err}" == *'this harness does not fake mariadb'* ]]; then ok "${case_label}: the stub explains itself on stderr"; else bad "${case_label}: no explanation on stderr" "$(dump_case)"; fi
expect_eq "the calls are logged" "denied-mariadb -e select\\ 1 denied-ssh nowhere true denied-docker ps" "$(tr '\n' ' ' < "${FAKE_CALLS}" | sed 's/ $//')"

# ===== lib/nextcloud-ssh.sh ==================================================
section "lib/nextcloud-ssh.sh: the one place the ssh options are written"
if [ ! -f "${ssh_lib}" ]; then
  bad "lib/nextcloud-ssh.sh exists" "${ssh_lib}"
else
  ssh_lib_mode="$(mode_of "${ssh_lib}")"
  if [[ "${ssh_lib_mode}" =~ ^[0-7]+$ ]] && ! (( 8#${ssh_lib_mode} & 8#111 )) && ! (( 8#${ssh_lib_mode} & 8#002 )); then ok "lib/nextcloud-ssh.sh has no execute bit and is not world-writable (mode ${ssh_lib_mode}; 644 is the brief's)"
  else bad "lib/nextcloud-ssh.sh is sourced: no execute bit, not world-writable (mode ${ssh_lib_mode})"; fi
  if [ "$(head -c 2 "${ssh_lib}")" != '#!' ]; then ok "lib/nextcloud-ssh.sh is sourced, so it has no shebang"
  else bad "lib/nextcloud-ssh.sh has a shebang"; fi
  if grep -qE '^[[:space:]]*(export|declare -x|typeset -x)[[:space:]]' "${ssh_lib}"; then bad "lib/nextcloud-ssh.sh exports a variable"
  else ok "lib/nextcloud-ssh.sh exports nothing"; fi
fi
new_case "sourcing it defines the function nc_ssh_options and changes nothing else"
run_script -- "${BASH}" -c '{ set +o; shopt -p; umask; trap -p; pwd; compgen -v | sort; } > "$2/before"; . "$1" || exit 9
  { set +o; shopt -p; umask; trap -p; pwd; compgen -v | sort; } > "$2/after"
  cmp -s "$2/before" "$2/after" && echo "shell unchanged"; declare -F | sed "s/^declare -f //" | tr "\n" " "; echo; nc_ssh_options | tr "\n" " "; echo' _ "${ssh_lib}" "${case_dir}/tmp"
expect_rc 0
expect_eq "options, umask, traps, folder and variables are as they were; one function; it prints the four options" $'shell unchanged\nnc_ssh_options \n'"${ssh_o} " "${out}"
expect_eq "it made nothing in HOME" "" "$(ls -A "${case_dir}/agent-home")"
expect_eq "stderr is empty" "" "${err}"

for f in "${occ_sh}" "${health_sh}"; do
  new_case "$(basename "${f}") takes the options from the lib"
  if grep -vE '^[[:space:]]*#' "${f}" | grep -qE 'StrictHostKeyChecking|UserKnownHostsFile|ConnectTimeout'; then bad "${case_label}: it writes ssh options itself"
  else ok "${case_label}: it writes no ssh option itself"; fi
  if grep -qE '^\. "\$\{script_dir\}/lib/nextcloud-ssh\.sh"' "${f}"; then ok "${case_label}: it sources lib/nextcloud-ssh.sh"
  else bad "${case_label}: it does not source lib/nextcloud-ssh.sh"; fi
  if grep -qE '^mapfile -t ssh_opts < <\(nc_ssh_options\)$' "${f}"; then ok "${case_label}: it reads the options from nc_ssh_options"
  else bad "${case_label}: it does not read the options from nc_ssh_options"; fi
done
new_health_case "a change in the lib reaches occ.sh and verify-health.sh"
mkdir -p "${case_dir}/scripts-copy/lib"
cp "${occ_sh}" "${health_sh}" "${case_dir}/scripts-copy/"
sed 's/ConnectTimeout=10/ConnectTimeout=3/' "${ssh_lib}" > "${case_dir}/scripts-copy/lib/nextcloud-ssh.sh"
run_script -- "${case_dir}/scripts-copy/verify-health.sh"
expect_overall GREEN
expect_eq "every ssh call, those of verify-health.sh and those of the occ.sh next to it, has the changed option and no other" "-n ${ssh_o/ConnectTimeout=10/ConnectTimeout=3}" "$(grep -E '^ssh ' "${FAKE_CALLS}" | sed -E 's/^ssh opts=(.*) target=.*/\1/' | sort -u)"
expect_eq "and there were calls from both" "yes yes" "$([ "$(ssh_summary | grep -c ' sudo -n -u www-data php ')" -gt 0 ] && echo yes || echo no) $([ "$(ssh_summary | grep -c ' df -P ')" -gt 0 ] && echo yes || echo no)"

new_health_case "the lib is missing: both scripts stop before they call anything"
mkdir -p "${case_dir}/no-lib"
cp "${occ_sh}" "${health_sh}" "${case_dir}/no-lib/"
run_script -- "${case_dir}/no-lib/verify-health.sh"
expect_rc 1
expect_eq "verify-health.sh called nothing" "" "$(cat "${FAKE_CALLS}")"
expect_eq "and printed no report" "" "${out}"
run_script -- "${case_dir}/no-lib/occ.sh" status
expect_rc 1
expect_eq "occ.sh called nothing either" "" "$(cat "${FAKE_CALLS}")"

# ===== verify-health.sh ======================================================
occ_remote='sudo -n -u www-data php /var/www/html/occ --no-interaction --no-warnings'
marker_path=/var/www/html/data/clouve-backups/RESTORE-IN-PROGRESS
lock_path=/var/www/html/nextcloud-init-sync.lock
marker_cmd="if sudo -n test -e ${marker_path}; then echo present; elif sudo -n test ! -e ${marker_path}; then echo absent; else echo unknown; fi"
lock_cmd="sudo -n -u www-data bash -c '[ -e \"\$1\" ] || [ -L \"\$1\" ] || exit 10; [ -f \"\$1\" ] && [ ! -L \"\$1\" ] || exit 11; exec flock -n -s -E 99 \"\$1\" true' _ ${lock_path}"
valkey_cmd='sudo -n -u www-data valkey-cli -s /run/clouve/valkey/valkey.sock ping'
playbook_stuck='playbooks/recover-stuck-upgrade-or-maintenance\.md'
# every ssh call of a healthy run: the target and the command, in order
healthy_ssh="clouve-ops@nc.test ${occ_remote} status --output=json
clouve-ops@nc-db.test true
clouve-ops@nc.test ${marker_cmd}
clouve-ops@nc.test ${lock_cmd}
clouve-ops@nc.test ${valkey_cmd}
clouve-ops@nc.test ${occ_remote} config:app:get core lastcron
clouve-ops@nc.test date +%s
clouve-ops@nc.test ${occ_remote} config:app:get core backgroundjobs_mode
clouve-ops@nc.test ${occ_remote} setupchecks --output=json
clouve-ops@nc.test df -P /var/www/html
clouve-ops@nc-db.test df -P /var/lib/mysql
clouve-ops@nc.test ${occ_remote} config:system:get overwrite.cli.url"

section "the harness: the fakes verify-health.sh needs leave the stdin they inherit alone"
# A script sent on stdin to `bash -s` is read by bash as it goes, so a fake that read stdin would swallow the rest of it.
new_health_case "a script on stdin calls mysql, valkey-cli, df, timeout, curl and flock between two echo lines"
vh_script=$'echo before\nmysql --help > /dev/null\nvalkey-cli -s /run/clouve/valkey/valkey.sock ping > /dev/null\ndf -P /var/www/html > /dev/null\ntimeout 5 true\n'
vh_script+=$'curl -q -s -m 5 --noproxy \'*\' -o /dev/null -w \'%{http_code}\' -H \'Host: abc.clouve.app\' http://nc.test/login > /dev/null\n'
vh_script+=$'flock -n -s -E 99 /var/www/html/nextcloud-init-sync.lock true\necho after\n'
run_script -- "${BASH}" -s < <(printf '%s' "${vh_script}")
expect_eq "both echo lines ran" $'before\nafter' "${out}"
expect_eq "every fake was called" "curl df flock mysql timeout valkey-cli " "$(grep -oE '^(mysql|valkey-cli|df|timeout|curl|flock) ' "${FAKE_CALLS}" | tr -d ' ' | sort -u | tr '\n' ' ')"

section "verify-health.sh: the file"
if [ ! -f "${health_sh}" ]; then
  bad "verify-health.sh exists" "${health_sh}"
else
  vh_mode="$(mode_of "${health_sh}")"
  if [[ "${vh_mode}" =~ ^[0-7]+$ ]] && (( 8#${vh_mode} & 8#100 )) && ! (( 8#${vh_mode} & 8#002 )); then ok "verify-health.sh is executable and not world-writable (mode ${vh_mode}; 755 is the brief's)"
  else bad "verify-health.sh must be executable and not world-writable (mode ${vh_mode})"; fi
  if [ "$(head -n 1 "${health_sh}")" = '#!/usr/bin/env bash' ]; then ok "verify-health.sh starts with #!/usr/bin/env bash"
  else bad "verify-health.sh does not start with #!/usr/bin/env bash"; fi
  if grep -qE '^[[:space:]]*(set[[:space:]]+-[A-Za-z]*x|set[[:space:]]+-o[[:space:]]+xtrace)' "${health_sh}"; then bad "verify-health.sh turns on set -x, which would print the passwords"
  else ok "verify-health.sh never turns on set -x"; fi
  if grep -qE '^[[:space:]]*(export|declare -x|typeset -x)[[:space:]]' "${health_sh}"; then bad "verify-health.sh exports a variable; SSHPASS and MYSQL_PWD are set on their commands only"
  else ok "verify-health.sh exports no variable"; fi
  if grep -vE '^[[:space:]]*#' "${health_sh}" | grep -qE '(sshpass[[:space:]]+-p|mysql[^|]*[[:space:]]-p[^[:space:]]|--password=)'; then bad "verify-health.sh puts a password on a command line"
  else ok "verify-health.sh puts no password on a command line"; fi
fi

section "verify-health.sh: a healthy deployment, the brief's first case"
new_health_case "healthy"
before_www="$(snapshot "${FAKE_WWW}")"
run_health
expect_overall GREEN
expect_eq "every label is printed once, in the brief's order, with occ_status after ssh_nextcloud and init_lock after restore_marker" "${health_labels}" "$(report_labels)"
for label in ${health_labels}; do expect_health "${label}" OK; done
expect_health ssh_nextcloud OK '^clouve-ops@nc\.test answers$'
expect_health occ_status OK '^occ answers$'
expect_eq "the title line has the UTC time" "Nextcloud health report, 2027-01-15T08:00:00Z" "$(head -n 1 "${case_dir}/stdout")"
expect_eq "then the host lines" $'host: nc.test\ndb:   nextcloud@nc-db.test\nurl:  https://abc.clouve.app' "$(sed -n 2,4p "${case_dir}/stdout")"
expect_eq "every report line is the label in 26 columns, the status in 4, then the detail" 19 "$(grep -cE '^.{26} (OK  |WARN|FAIL) [^ ]' "${case_dir}/stdout")"
expect_eq "the version is the versionstring" "35.0.2" "$(grep -E '^version ' "${case_dir}/stdout" | sed -E 's/^version +OK +//')"
expect_eq "the disk lines say how much of the volume is used and how much is free (20 GiB at 42%, 10 GiB at 35%)" $'42% used, 11.6 GB free\n35% used, 6.5 GB free' "$(grep -E '^disk_' "${case_dir}/stdout" | sed -E 's/^disk_[a-z]+ +OK +//')"
expect_eq "stderr is empty" "" "${err}"
expect_eq "the ssh calls, in order" "${healthy_ssh}" "$(ssh_summary)"
expect_eq "every ssh call has -n and the same four options occ.sh uses (the containers' host keys change at every start, so none is kept)" "-n ${ssh_o}" "$(grep -E '^ssh ' "${FAKE_CALLS}" | sed -E 's/^ssh opts=(.*) target=.*/\1/' | sort -u)"
expect_eq "none of them sent anything on stdin" "0" "$(grep -E '^ssh ' "${FAKE_CALLS}" | sed -E 's/.* stdin_bytes=([0-9]+) .*/\1/' | sort -u)"
expect_occ_sequence "status config:app:get config:app:get setupchecks config:system:get"
expect_eq "the occ arguments" $'["status","--output=json"]\n["config:app:get","core","lastcron"]\n["config:app:get","core","backgroundjobs_mode"]\n["setupchecks","--output=json"]\n["config:system:get","overwrite.cli.url"]' "$(for n in 1 2 3 4 5; do occ_call_args "${n}"; done)"
expect_eq "the two curl calls: the public host as Host, a temp file for the body of status.php, no body for the login page" \
  "curl$(printf ' %q' -q -s -m 15 --noproxy '*' -o TMPFILE -w '%{http_code}' -H 'Host: abc.clouve.app' http://nc.test/status.php)
curl$(printf ' %q' -q -s -m 15 --noproxy '*' -o /dev/null -w '%{http_code}' -H 'Host: abc.clouve.app' http://nc.test/login)" \
  "$(fake_calls curl | sed -E "s#-o ${case_dir}/tmp/nextcloud-health\.[A-Za-z0-9]+/status\.json#-o TMPFILE#")"
expect_eq "both pages answered 200 for the public host" $'curl-probe page=/status.php host=abc.clouve.app code=200\ncurl-probe page=/login host=abc.clouve.app code=200' "$(fake_calls curl-probe)"
expect_eq "mysql: --help once for the TLS flag, then SELECT 1 with TLS off and the password in MYSQL_PWD only, both without option files" \
  "mysql$(printf ' %q' --no-defaults --help)
mysql$(printf ' %q' --no-defaults -h nc-db.test -u nextcloud nextcloud --ssl-mode=DISABLED --connect-timeout=5 -N -e 'SELECT 1')
mysql-env MYSQL_PWD=set" "$(fake_calls 'mysql(-env)?')"
expect_eq "timeouts: 30 s for mysql, 60 s for every other occ.sh and ssh call, 180 s for setupchecks" "1 30
11 60
1 180" "$(fake_calls timeout | cut -d' ' -f4 | sort | uniq -c | sed -E 's/^ +//' | sort -k2 -n)"
expect_eq "every one of them is timeout -k 5, so a command that ignores TERM is killed 5 seconds later" 0 "$(fake_calls timeout | grep -vc '^timeout -k 5 ' || true)"
expect_eq "setupchecks runs under timeout 180 and nothing else does" "timeout -k 5 180 ${scripts}/occ.sh setupchecks --output=json" "$(fake_calls timeout | grep -E '^timeout -k 5 180 ')"
expect_eq "nothing in /var/www/html changed, so the init lock file was not touched either" "${before_www}" "$(snapshot "${FAKE_WWW}")"
expect_eq "no temporary file is left" "" "$(ls -A "${case_dir}/tmp")"
expect_eq "it asked clv-secret for nothing (both passwords were in the environment)" 0 "$(call_count clv-secret)"

section "verify-health.sh: the Nextcloud container does not answer on ssh, the brief's unreachable case"
new_health_case "ssh to NEXTCLOUD_HOST fails"
FAKE_SSH_FAIL='nc.test=255'
run_health
expect_overall RED
expect_health ssh_nextcloud FAIL 'could not reach clouve-ops@nc\.test: .*Connection refused'
expect_health http_status OK
expect_health http_login_page OK
expect_health database_tcp OK
expect_health ssh_database OK
expect_health disk_database OK
expect_eq "only the checks that do not need the container are printed" "ssh_nextcloud http_status http_login_page database_tcp ssh_database disk_database" "$(report_labels)"
expect_no_health occ_status "${health_occ[@]}" "${health_ssh[@]}"
if [[ "$(grep -E '^ssh_nextcloud ' "${case_dir}/stdout")" == *'skipped'* ]]; then ok "${case_label}: the FAIL line says the checks that need the container were skipped"
else bad "${case_label}: the ssh_nextcloud line should say what was skipped" "$(grep -E '^ssh_nextcloud ' "${case_dir}/stdout")"; fi
expect_eq "the container saw only occ.sh's two attempts, the database host kept working" 2 "$(ssh_summary nc.test | wc -l | tr -d ' ')"
expect_eq "the database host got its two checks" $'clouve-ops@nc-db.test true\nclouve-ops@nc-db.test df -P /var/lib/mysql' "$(ssh_summary nc-db.test)"
expect_call_count curl 2
expect_eq "mysql ran" 1 "$(fake_calls mysql | grep -c ' -N ' || true)"

new_health_case "the ops password is wrong"
run_health CLOUVE_OPS_PASSWORD=not-the-password
expect_overall RED
expect_health ssh_nextcloud FAIL 'could not reach clouve-ops@nc\.test'
expect_health ssh_database WARN 'could not log in to clouve-ops@nc-db\.test'
expect_health disk_database WARN
expect_health http_status OK
expect_health database_tcp OK

new_health_case "the channel is up for the first check and lost for later ones"
FAKE_HEALTH_SSH_FAIL_CMD='valkey-cli'
run_health
expect_health ssh_nextcloud OK
expect_health valkey FAIL '^no PONG: Connection to nc\.test closed by remote host'
expect_health init_lock OK
expect_overall RED

new_health_case "ssh works and occ cannot run, with a restore marker there: the marker is still reported"
FAKE_HEALTH_STATUS_FAIL=1
printf 'backup-2027-01-14\n' > "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS"
run_health
expect_health ssh_nextcloud OK '^clouve-ops@nc\.test answers$'
expect_health occ_status FAIL "^occ can.t run"
expect_health restore_marker FAIL '^a restore is running or was interrupted; see playbooks/restore-from-backup\.md$'
expect_no_health "${health_occ[@]}"
expect_eq "the checks that were printed" "ssh_nextcloud occ_status http_status http_login_page database_tcp ssh_database restore_marker init_lock valkey disk_nextcloud disk_database" "$(report_labels)"
expect_occ_sequence "status"
expect_overall RED

new_health_case "ssh works and occ prints no JSON: the checks that need only ssh still say what they find"
FAKE_HEALTH_STATUS_RAW='Nextcloud is not installed - only a limited number of commands are available'
FAKE_HEALTH_INIT_LOCK=held
FAKE_HEALTH_VALKEY=down
FAKE_HEALTH_DF_WWW=97
run_health
expect_health ssh_nextcloud OK
expect_health occ_status FAIL '^occ status printed no JSON: Nextcloud is not installed - only a limited number of commands are available; the checks that read with occ were skipped$'
expect_health restore_marker OK
expect_health init_lock WARN '^an install, upgrade, recovery, backup or restore holds the lock$'
expect_health valkey FAIL '^no PONG'
expect_health disk_nextcloud FAIL '^97% used'
expect_no_health "${health_occ[@]}"
expect_overall RED

new_health_case "ssh repeats the ops password in a message: the report hides it"
FAKE_HEALTH_SSH_FAIL_CMD='valkey-cli'
FAKE_HEALTH_SSH_ECHO_PW=1
run_health
expect_health valkey FAIL 'closed by remote host\. \[\[hidden\]\]$'

section "verify-health.sh: occ status and the flags it gives"
new_health_case "maintenance mode is on"
FAKE_HEALTH_NC_STATE=maintenance
run_health
expect_health maintenance WARN "users see a maintenance page.*${playbook_stuck}"
expect_health needs_db_upgrade OK
expect_health installed OK
expect_health setup_checks WARN '^skipped'
expect_health http_status OK
expect_health http_login_page WARN '^503 while maintenance mode is on'
expect_health cron_last_run OK
expect_health background_jobs_mode OK
expect_health url_setting OK
expect_overall AMBER
expect_occ_sequence "status config:app:get config:app:get config:system:get"
expect_eq "stderr is empty" "" "${err}"

new_health_case "occ prints its maintenance notices anyway (with --no-warnings it should not) and the lastcron key was never stored"
FAKE_HEALTH_NC_STATE=maintenance
FAKE_HEALTH_LASTCRON_AGE='unset'
run_health
expect_health cron_last_run FAIL 'never ran'

new_health_case "the login page answers 503 but status.php does not say maintenance mode"
FAKE_HEALTH_LOGIN_CODE=503
run_health
expect_health http_login_page FAIL '^503 outside maintenance mode$'
expect_overall RED

new_health_case "an upgrade is pending, the brief's case"
FAKE_HEALTH_NC_STATE=upgrade
run_health
expect_health needs_db_upgrade FAIL "^an upgrade is pending; see ${playbook_stuck}"
expect_health maintenance OK
expect_health setup_checks WARN '^skipped.*upgrade'
expect_overall RED
expect_occ_sequence "status config:app:get config:app:get config:system:get"
expect_eq "stderr is empty" "" "${err}"

new_health_case "an upgrade is running right now: maintenance mode on, the upgrade still pending, and the init lock held"
FAKE_HEALTH_NC_STATE=upgrading
FAKE_HEALTH_INIT_LOCK=held
run_health
expect_health init_lock WARN '^an install, upgrade, recovery, backup or restore holds the lock$'
expect_health maintenance WARN 'maintenance page'
expect_health needs_db_upgrade FAIL "^an upgrade is pending; see ${playbook_stuck}"
expect_health http_status OK
expect_health http_login_page WARN '^503 while maintenance mode is on'
expect_health setup_checks WARN '^skipped'
expect_health cron_last_run OK
expect_eq "every label is printed once, in order" "${health_labels}" "$(report_labels)"
expect_overall RED

new_health_case "the database is down: the pages fail, mysql fails, occ's reads throw, and the rest still reports"
FAKE_HEALTH_NC_STATE=dbdown
FAKE_HEALTH_MYSQL=down
FAKE_HEALTH_LASTCRON_AGE=fail
FAKE_HEALTH_BGMODE=fail
FAKE_HEALTH_SETUPCHECKS=fail
run_health
expect_health http_status FAIL '^500 .*database'
expect_health http_login_page FAIL '^500'
expect_health database_tcp FAIL '^ERROR 2002'
expect_health ssh_nextcloud OK
expect_health cron_last_run WARN '^could not read lastcron.*SQLSTATE'
expect_health background_jobs_mode WARN '^could not read backgroundjobs_mode.*SQLSTATE'
expect_health setup_checks WARN '^could not read the answer \(exit 255\)'
expect_health ssh_database OK
expect_health valkey OK
expect_health disk_nextcloud OK
expect_health url_setting OK
expect_eq "every label is printed once, in order" "${health_labels}" "$(report_labels)"
expect_overall RED

new_health_case "an interrupted restore: the marker, with maintenance mode left on"
FAKE_HEALTH_NC_STATE=maintenance
printf 'backup-2027-01-14\n' > "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS"
run_health
expect_health restore_marker FAIL '^a restore is running or was interrupted; see playbooks/restore-from-backup\.md$'
expect_health maintenance WARN 'maintenance page'
expect_overall RED
expect_eq "the marker is still there" "backup-2027-01-14" "$(< "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS")"

new_health_case "occ status says the instance is not installed"
FAKE_HEALTH_INSTALLED=false
run_health
expect_health installed FAIL 'installed is false'
expect_overall RED

new_health_case "occ status prints a PHP warning before its JSON"
FAKE_HEALTH_STATUS_NOISE=1
run_health
expect_health ssh_nextcloud OK
expect_health version OK '^35\.0\.2$'
expect_overall GREEN

new_health_case "occ status gives JSON with fields missing"
FAKE_HEALTH_STATUS_RAW='{"installed":true}'
run_health
expect_health installed OK
expect_health maintenance WARN 'did not say'
expect_health needs_db_upgrade WARN 'did not say'
expect_health version WARN 'no version'
expect_overall AMBER

new_health_case "occ status fails with a PHP fatal error: ssh works, occ does not"
FAKE_HEALTH_STATUS_FAIL=1
run_health
expect_health ssh_nextcloud OK '^clouve-ops@nc\.test answers$'
expect_health occ_status FAIL '^occ can.t run \(exit 255\): PHP Fatal error:  Allowed memory size of 134217728 bytes exhausted; the checks that read with occ were skipped$'
expect_no_health "${health_occ[@]}"
expect_health restore_marker OK
expect_health init_lock OK
expect_health valkey OK
expect_health disk_nextcloud OK
expect_occ_sequence "status"
expect_overall RED

new_health_case "occ status prints no JSON"
FAKE_HEALTH_STATUS_RAW='Nextcloud is not installed - only a limited number of commands are available'
run_health
expect_health ssh_nextcloud OK
expect_health occ_status FAIL 'occ status printed no JSON: Nextcloud is not installed'
expect_no_health "${health_occ[@]}"

new_health_case "occ status prints a line that starts with { and is not JSON, then the JSON"
FAKE_HEALTH_STATUS_RAW=$'{not json}\n{"installed":true,"maintenance":false,"needsDbUpgrade":false,"versionstring":"35.0.2"}'
run_health
expect_health ssh_nextcloud OK
expect_health occ_status OK
expect_health version OK '^35\.0\.2$'

new_health_case "occ status gives JSON and a failing exit code"
FAKE_HEALTH_STATUS_RAW='{"installed":true,"maintenance":false,"needsDbUpgrade":false,"versionstring":"35.0.2"}'
FAKE_HEALTH_STATUS_RC=3
run_health
expect_health ssh_nextcloud OK
expect_health occ_status FAIL '^occ can.t run \(exit 3\)'
expect_no_health "${health_occ[@]}"

new_health_case "occ status gives JSON that is not a status"
FAKE_HEALTH_STATUS_RAW='{"error":"nothing here"}'
run_health
expect_health occ_status FAIL '^occ status printed no JSON'

new_health_case "occ status has no versionstring, only a version"
FAKE_HEALTH_STATUS_RAW='{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"35.0.2.2"}'
run_health
expect_health version OK '^35\.0\.2\.2$'

new_health_case "occ status says something very long, with control characters in it"
FAKE_HEALTH_STATUS_RAW="$(printf 'x%.0s' {1..300})"$'\tend\x1b[31m\r'
run_health
expect_health occ_status FAIL '^occ status printed no JSON: x{100,117}\.\.\.; the checks that read with occ were skipped$'
expect_eq "no line of the report is longer than 26 + 4 + 2 spaces + 240 characters" 0 "$(awk 'length($0) > 272' "${case_dir}/stdout" | wc -l | tr -d ' ')"
FAKE_HEALTH_STATUS_RAW=$'bad\tstuff\x1b[31m red\r'
run_health
expect_eq "no control character reached the report" 0 "$(LC_ALL=C tr -d '[:print:]\n' < "${case_dir}/stdout" | wc -c | tr -d ' ')"
expect_health occ_status FAIL '^occ status printed no JSON: bad'

section "verify-health.sh: status.php and the login page"
new_health_case "the Host is not in trusted_domains, the brief's case"
FAKE_HEALTH_TRUSTED='other.example'
run_health
expect_health http_status FAIL "^trusted domain error: abc\.clouve\.app isn't in trusted_domains"
expect_health http_login_page FAIL "^400 \(the host is not in trusted_domains: see http_status\)$"
expect_overall RED
expect_health database_tcp OK

new_health_case "the URL has a port: Host carries it, and trusted_domains has the name without it"
run_health NEXTCLOUD_URL=http://t1.test.clv:8080/ FAKE_HEALTH_TRUSTED=t1.test.clv FAKE_HEALTH_URL=http://t1.test.clv:8080/
expect_overall GREEN
expect_eq "Host: t1.test.clv:8080 for both pages" $'curl-probe page=/status.php host=t1.test.clv:8080 code=200\ncurl-probe page=/login host=t1.test.clv:8080 code=200' "$(fake_calls curl-probe)"
expect_eq "the url line shows the URL as given" "url:  http://t1.test.clv:8080/" "$(sed -n 4p "${case_dir}/stdout")"

new_health_case "the URL has a path and a line break in it: the url line is one line"
run_health NEXTCLOUD_URL=$'https://abc.clouve.app/x\nOverall: GREEN\ty' FAKE_HEALTH_URL=unset
expect_eq "one url line, however the URL is spelled" 1 "$(grep -c '^url: ' "${case_dir}/stdout")"
expect_eq "and one Overall line" 1 "$(grep -c '^Overall: ' "${case_dir}/stdout")"

new_health_case "the URL is http://localhost"
run_health NEXTCLOUD_URL=http://localhost FAKE_HEALTH_URL=http://localhost
expect_overall GREEN
expect_eq "Host: localhost" "curl-probe page=/status.php host=localhost code=200" "$(fake_calls curl-probe | head -n 1)"

# Each run gives status.php one fault and the login page another, since the two checks are independent
http_cases=(
  'FAKE_HEALTH_STATUS_CODE=502|^502|FAKE_HEALTH_LOGIN_CODE=500|^500'
  'FAKE_HEALTH_STATUS_CODE=503|^503|FAKE_HEALTH_LOGIN_CODE=302|^302'
  'FAKE_HEALTH_STATUS_CODE=404|^404|FAKE_HEALTH_LOGIN_CODE=404|^404'
  'FAKE_HEALTH_STATUS_BODY={"installed":false,"maintenance":false}|^200 but .*installed|FAKE_HEALTH_CURL_EXIT_LOGIN=7|^no response .*exit 7'
  'FAKE_HEALTH_STATUS_BODY=<html>Welcome</html>|^200 but .*installed|FAKE_HEALTH_LOGIN_CODE=000|^no response'
  'FAKE_HEALTH_STATUS_BODY=|^200 but .*installed|FAKE_HEALTH_LOGIN_CODE=401|^401'
  'FAKE_HEALTH_CURL_EXIT=7|^no response \(curl exit 7: connection refused\)$|FAKE_HEALTH_CURL_EXIT=7|^no response \(curl exit 7: connection refused\)$'
  'FAKE_HEALTH_CURL_EXIT=28|^no response \(curl exit 28: timed out\)$|FAKE_HEALTH_CURL_EXIT=28|^no response \(curl exit 28: timed out\)$'
  'FAKE_HEALTH_CURL_EXIT=6|^no response \(curl exit 6: could not resolve the host\)$|FAKE_HEALTH_CURL_EXIT=6|^no response \(curl exit 6: could not resolve the host\)$'
  'FAKE_HEALTH_NC_STATE=dbdown|^500 .*database|FAKE_HEALTH_NC_STATE=dbdown|^500'
)
for spec in "${http_cases[@]}"; do
  IFS='|' read -r http_status_knob http_status_detail http_login_knob http_login_detail <<< "${spec}"
  new_health_case "status.php: ${http_status_knob}; login page: ${http_login_knob}"
  run_health "${http_status_knob}" "${http_login_knob}"
  expect_health http_status FAIL "${http_status_detail}"
  expect_health http_login_page FAIL "${http_login_detail}"
  expect_overall RED
done
new_health_case "status.php answers but the login page does not: the other probe still runs"
FAKE_HEALTH_LOGIN_CODE=500
run_health
expect_health http_status OK
expect_call_count curl 2

section "verify-health.sh: the database over TCP"
new_health_case "mysql 8 client (the agent's)"
run_health
expect_health database_tcp OK '^nextcloud@nc-db\.test answers'
expect_eq "TLS is switched off with --ssl-mode=DISABLED, which the client's --help lists" "mysql$(printf ' %q' --no-defaults -h nc-db.test -u nextcloud nextcloud --ssl-mode=DISABLED --connect-timeout=5 -N -e 'SELECT 1')" "$(fake_calls mysql | tail -n 1)"

new_health_case "a password= in ~/.my.cnf does not override the database password"
printf '[client]\npassword=from-the-option-file\nuser=someone-else\n' > "${case_dir}/agent-home/.my.cnf"
run_health
expect_health database_tcp OK '^nextcloud@nc-db\.test answers'
expect_overall GREEN
expect_eq "mysql was started with --no-defaults first, so the option file was not read" "mysql$(printf ' %q' --no-defaults -h nc-db.test -u nextcloud nextcloud --ssl-mode=DISABLED --connect-timeout=5 -N -e 'SELECT 1')" "$(fake_calls mysql | tail -n 1)"

new_health_case "the fake mysql lets an option file's password win when --no-defaults is not first (so the case above can fail)"
printf '[client]\npassword=from-the-option-file\n' > "${case_dir}/agent-home/.my.cnf"
run_script -- "${BASH}" -c 'mysql -h nc-db.test -u nextcloud nextcloud --ssl-mode=DISABLED -N -e "SELECT 1"; echo "rc=$?"; mysql --ssl-mode=DISABLED --no-defaults -h x; echo "rc=$?"'
expect_eq "an option file's password is the one used (access denied), and --no-defaults after another option is an error" $'rc=1\nrc=2' "${out}"

new_health_case "mariadb client"
FAKE_HEALTH_MYSQL_FLAVOUR=mariadb
run_health
expect_health database_tcp OK
expect_eq "TLS is switched off with --skip-ssl, since --help does not list --ssl-mode" "mysql$(printf ' %q' --no-defaults -h nc-db.test -u nextcloud nextcloud --skip-ssl --connect-timeout=5 -N -e 'SELECT 1')" "$(fake_calls mysql | tail -n 1)"

new_health_case "mariadb client: its deprecation notice comes first on stderr, and the error is still the one shown"
FAKE_HEALTH_MYSQL_FLAVOUR=mariadb
FAKE_HEALTH_MYSQL=down
run_health
expect_health database_tcp FAIL "^ERROR 2002.*Can.t connect"

db_cases=(
  'the server is down|down|^ERROR 2002.*Can.t connect'
  'the account is refused|denied|^ERROR 1045.*Access denied'
  'the answer is not 1|wrong|^answered "2", wanted 1'
  'no answer at all|empty|^no answer'
  'an error without ERROR in front|nonsql|^mysql: unable to connect: protocol error$'
)
for spec in "${db_cases[@]}"; do
  IFS='|' read -r db_label db_knob db_detail <<< "${spec}"
  new_health_case "database: ${db_label}"
  FAKE_HEALTH_MYSQL="${db_knob}"
  run_health
  expect_health database_tcp FAIL "${db_detail}"
  expect_overall RED
  expect_health ssh_database OK
done
new_health_case "database: the password is wrong"
run_health NEXTCLOUD_DB_PASSWORD=not-the-password
expect_health database_tcp FAIL '^ERROR 1045.*Access denied'

new_health_case "database: a password with spaces, quotes, a dollar sign, a backslash and edge blanks arrives byte for byte"
set_db_password ' sp\ace "q" '"'"'s'"'"' $HOME;&|<> end '
run_health
expect_health database_tcp OK

new_health_case "database: NEXTCLOUD_MARIADB_HOST names the database container, NEXTCLOUD_DB_HOST the address for mysql, and the database and its user have their own names"
run_health NEXTCLOUD_MARIADB_HOST=tkt-7-nextcloud-mariadb NEXTCLOUD_DB_HOST=nextcloud-mariadb NEXTCLOUD_DB_NAME=nc_data NEXTCLOUD_DB_USER=nc_user
expect_overall GREEN
expect_health database_tcp OK '^nc_user@nextcloud-mariadb answers'
expect_eq "mysql goes to NEXTCLOUD_DB_HOST as NEXTCLOUD_DB_USER, to the database NEXTCLOUD_DB_NAME" "mysql$(printf ' %q' --no-defaults -h nextcloud-mariadb -u nc_user nc_data --ssl-mode=DISABLED --connect-timeout=5 -N -e 'SELECT 1')" "$(fake_calls mysql | tail -n 1)"
expect_eq "ssh goes to NEXTCLOUD_MARIADB_HOST" $'clouve-ops@tkt-7-nextcloud-mariadb true\nclouve-ops@tkt-7-nextcloud-mariadb df -P /var/lib/mysql' "$(ssh_summary tkt-7-nextcloud-mariadb)"
expect_eq "the db line shows the database and the address mysql uses" "db:   nc_data@nextcloud-mariadb" "$(sed -n 3p "${case_dir}/stdout")"

new_health_case "database: NEXTCLOUD_MARIADB_HOST is unset or empty, so ssh goes to NEXTCLOUD_DB_HOST"
run_health -NEXTCLOUD_MARIADB_HOST
expect_eq "unset" $'clouve-ops@nc-db.test true\nclouve-ops@nc-db.test df -P /var/lib/mysql' "$(ssh_summary nc-db.test)"
run_health NEXTCLOUD_MARIADB_HOST=
expect_eq "empty" $'clouve-ops@nc-db.test true\nclouve-ops@nc-db.test df -P /var/lib/mysql' "$(ssh_summary nc-db.test)"
expect_overall GREEN

new_health_case "database container: ssh does not answer, which is only a warning"
FAKE_SSH_FAIL='nc-db.test=255'
run_health
expect_health ssh_database WARN 'could not log in to clouve-ops@nc-db\.test \(exit 255\); only the diagnostics need it'
expect_health disk_database WARN 'could not read'
expect_health database_tcp OK
expect_overall AMBER

section "verify-health.sh: the restore marker, the init lock, Valkey"
new_health_case "a restore marker is there"
: > "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS"
run_health
expect_health restore_marker FAIL '^a restore is running or was interrupted; see playbooks/restore-from-backup\.md$'
expect_overall RED
expect_eq "the report did not remove or change the marker" 0 "$(wc -c < "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS" | tr -d ' ')"

new_health_case "the clouve-backups folder is not there"
rmdir "${FAKE_WWW}/data/clouve-backups"
run_health
expect_health restore_marker OK

new_health_case "sudo cannot test for the marker (it exits 1, as it does for a refusal): that is not 'no marker'"
FAKE_HEALTH_SUDO_FAIL='test'
: > "${FAKE_WWW}/data/clouve-backups/RESTORE-IN-PROGRESS"
run_health
expect_health restore_marker WARN '^could not check'
expect_overall AMBER

new_health_case "the connection drops during the marker check"
FAKE_HEALTH_SSH_FAIL_CMD='RESTORE-IN-PROGRESS'
run_health
expect_health restore_marker WARN '^could not check'

new_health_case "the init lock is held by an install, an upgrade, a recovery, a backup or a restore"
FAKE_HEALTH_INIT_LOCK=held
run_health
expect_health init_lock WARN '^an install, upgrade, recovery, backup or restore holds the lock$'
expect_overall AMBER
expect_eq "flock asked without waiting, on the image's lock" "flock ${lock_path}" "$(fake_calls flock)"

new_health_case "the init lock file is missing: nothing is running, and the report does not create it"
rm -f "${FAKE_WWW}/nextcloud-init-sync.lock"
before_www="$(snapshot "${FAKE_WWW}")"
run_health
expect_health init_lock OK 'no lock file'
expect_overall GREEN
expect_call_count flock 0
expect_eq "no lock file was made" "${before_www}" "$(snapshot "${FAKE_WWW}")"

new_health_case "sudo cannot run the lock probe as www-data"
FAKE_HEALTH_SUDO_FAIL=bash
run_health
expect_health init_lock WARN '^could not check \(exit 1\)'

new_health_case "the lock probe runs as www-data, whose file the lock is, never as root"
run_health
expect_health init_lock OK
expect_eq "sudo ran the probe as www-data" 1 "$(grep -c '^sudo user=www-data preserve=- NC_PASS=unset :: bash -c ' "${FAKE_CALLS}")"
expect_eq "no root flock" 0 "$(grep -c '^sudo user=root .* flock' "${FAKE_CALLS}")"

new_health_case "the lock path is a symlink: not opened, WARN, and its target is not made"
rm -f "${FAKE_WWW}/nextcloud-init-sync.lock"
ln -s "${case_dir}/elsewhere" "${FAKE_WWW}/nextcloud-init-sync.lock"
run_health
expect_health init_lock WARN '^the lock path is not a plain file \(a link, a pipe or a folder\), so it was not opened$'
expect_call_count flock 0
expect_eq "the link's target was not made" no "$([ -e "${case_dir}/elsewhere" ] && echo yes || echo no)"

new_health_case "the lock path is a named pipe: not opened, so the report does not wait for it"
rm -f "${FAKE_WWW}/nextcloud-init-sync.lock"
mkfifo "${FAKE_WWW}/nextcloud-init-sync.lock"
SECONDS=0
run_health
expect_health init_lock WARN '^the lock path is not a plain file \(a link, a pipe or a folder\), so it was not opened$'
expect_call_count flock 0
expect_eq "the report did not wait on the pipe" yes "$([ "${SECONDS}" -lt 30 ] && echo yes || echo no)"

new_health_case "the connection drops during the lock check"
FAKE_HEALTH_SSH_FAIL_CMD='flock'
run_health
expect_health init_lock WARN '^could not check \(exit 255\)'

valkey_cases=(
  'Valkey is down|down|^no PONG.*No such file'
  'Valkey is still loading|loading|^no PONG.*LOADING'
  'Valkey answers something else|NOAUTH|^no PONG.*NOAUTH'
)
for spec in "${valkey_cases[@]}"; do
  IFS='|' read -r vk_label vk_knob vk_detail <<< "${spec}"
  new_health_case "${vk_label}"
  FAKE_HEALTH_VALKEY="${vk_knob}"
  run_health
  expect_health valkey FAIL "${vk_detail}"
  expect_overall RED
done
new_health_case "Valkey answers"
run_health
expect_eq "as www-data, with the socket the image makes" "sudo user=www-data preserve=- NC_PASS=unset :: valkey-cli -s /run/clouve/valkey/valkey.sock ping" "$(fake_calls sudo | grep valkey-cli)"

section "verify-health.sh: cron and background jobs"
# cron age, the check's status, backgroundjobs_mode, that check's status and detail: independent checks, so each run gives both a case
cron_cases=(
  '0|OK|cron|OK|^cron$'
  '120|OK|cron|OK|^cron$'
  '900|OK|ajax|WARN|^ajax, expected cron'
  '901|WARN|webcron|WARN|^webcron, expected cron'
  '1200|WARN|unset|WARN|^not set, expected cron'
  '3600|WARN|empty|WARN|^not set, expected cron'
  '3601|FAIL|cron|OK|^cron$'
  '86400|FAIL|cron|OK|^cron$'
)
for spec in "${cron_cases[@]}"; do
  IFS='|' read -r cron_age cron_status mode_knob mode_status mode_detail <<< "${spec}"
  new_health_case "cron ran ${cron_age} seconds ago, backgroundjobs_mode is ${mode_knob}"
  FAKE_HEALTH_LASTCRON_AGE="${cron_age}"
  FAKE_HEALTH_BGMODE="${mode_knob}"
  run_health
  expect_health cron_last_run "${cron_status}" "^${cron_age} s ago"
  expect_health background_jobs_mode "${mode_status}" "${mode_detail}"
  if [ "${cron_status}" = OK ] && [ "${mode_status}" = OK ]; then expect_overall GREEN
  elif [ "${cron_status}" = FAIL ]; then expect_overall RED
  else expect_overall AMBER; fi
done
new_health_case "cron stalled for hours"
FAKE_HEALTH_LASTCRON_AGE=7200
run_health
expect_health cron_last_run FAIL 'cron has stalled'
new_health_case "cron is a little late, the brief's case: 1200 seconds, with everything else fine"
FAKE_HEALTH_LASTCRON_AGE=1200
run_health
expect_health cron_last_run WARN '^1200 s ago \(cron runs every 300 s\)$'
expect_overall AMBER

never_cases=('lastcron was never stored|unset' 'lastcron is an empty string|empty' 'lastcron is 0|zero')
for spec in "${never_cases[@]}"; do
  new_health_case "${spec%%|*}"
  FAKE_HEALTH_LASTCRON_AGE="${spec#*|}"
  run_health
  expect_health cron_last_run FAIL '^never ran \(cron runs every 300 s; the first run comes within 5 minutes of the install\)$'
  expect_overall RED
done
# $(( )) reads 08 and 09 as bad octal numbers; the report must not stop at them
for spec in '08|1799999992' '09|1799999991' '0000000008|1799999992'; do
  new_health_case "lastcron is ${spec%%|*}"
  FAKE_HEALTH_LASTCRON_RAW="${spec%%|*}"
  run_health
  expect_health cron_last_run FAIL "^${spec#*|} s ago \(cron has stalled\)\$"
  expect_eq "stderr is empty" "" "${err}"
  expect_eq "every label is printed once, in order" "${health_labels}" "$(report_labels)"
  expect_overall RED
done
new_health_case "lastcron is 000: that is zero, so cron never ran"
FAKE_HEALTH_LASTCRON_RAW=000
run_health
expect_health cron_last_run FAIL '^never ran'
new_health_case "lastcron is too long a number for the shell's arithmetic"
FAKE_HEALTH_LASTCRON_RAW=99999999999999999999
run_health
expect_health cron_last_run WARN '^unreadable lastcron value'
expect_eq "stderr is empty" "" "${err}"
new_health_case "the container's clock says 09"
FAKE_HEALTH_DATE_RAW=09
run_health
expect_health cron_last_run OK '^0 s ago$'
expect_eq "stderr is empty" "" "${err}"
expect_eq "every label is printed once, in order" "${health_labels}" "$(report_labels)"
new_health_case "the container's clock says a number too long for the shell's arithmetic"
FAKE_HEALTH_DATE_RAW=99999999999999999999
run_health
expect_health cron_last_run WARN "^could not read the container's clock \(it printed: 99999999999999999999\)\$"
expect_eq "stderr is empty" "" "${err}"
new_health_case "the container's clock says something that is not a number"
FAKE_HEALTH_DATE_RAW=yesterday
run_health
expect_health cron_last_run WARN "^could not read the container's clock \(it printed: yesterday\)\$"

# one stray line next to the value of an occ read must not turn the read into a warning: each way PHP writes a diagnostic
for line in 'PHP Warning:  x in /var/www/html/a.php on line 1' 'PHP Notice:  x in /var/www/html/a.php on line 1' \
  'PHP Deprecated:  x in /var/www/html/a.php on line 1' 'Warning: x in /var/www/html/a.php on line 1' \
  'Notice: x in /var/www/html/a.php on line 1' 'Deprecated: x in /var/www/html/a.php on line 1'; do
  new_health_case "the stray line is '${line%% in*}', after the value of each occ read, and the keys are stored"
  FAKE_HEALTH_SCALAR_NOISE=after
  FAKE_HEALTH_SCALAR_NOISE_LINE="${line}"
  run_health
  expect_health cron_last_run OK '^120 s ago$'
  expect_health background_jobs_mode OK '^cron$'
  expect_health url_setting OK '^https://abc\.clouve\.app$'
  new_health_case "the stray line is '${line%% in*}', before the value of each occ read, and the keys are not stored"
  FAKE_HEALTH_SCALAR_NOISE=before
  FAKE_HEALTH_SCALAR_NOISE_LINE="${line}"
  FAKE_HEALTH_LASTCRON_AGE='unset'
  FAKE_HEALTH_BGMODE='unset'
  FAKE_HEALTH_URL='unset'
  run_health
  expect_health cron_last_run FAIL '^never ran'
  expect_health background_jobs_mode WARN '^not set, expected cron'
  expect_health url_setting WARN '^overwrite\.cli\.url is not set'
done
for noise in before after text; do
  new_health_case "a stray line ${noise} the value of each occ read"
  FAKE_HEALTH_SCALAR_NOISE="${noise}"
  run_health
  expect_health cron_last_run OK '^120 s ago$'
  expect_health background_jobs_mode OK '^cron$'
  expect_health url_setting OK '^https://abc\.clouve\.app$'
  expect_overall GREEN
done
new_health_case "a value with blanks around it is read without them"
FAKE_HEALTH_BGMODE='  cron  '
run_health
expect_health background_jobs_mode OK '^cron$'

new_health_case "lastcron is not a number"
FAKE_HEALTH_LASTCRON_AGE=garbage
run_health
expect_health cron_last_run WARN '^unreadable'
new_health_case "reading lastcron throws (the database is down): that is not 'never ran'"
FAKE_HEALTH_LASTCRON_AGE=fail
run_health
expect_health cron_last_run WARN '^could not read lastcron.*SQLSTATE'
new_health_case "reading lastcron fails and says nothing: that is not 'never ran' either"
FAKE_HEALTH_LASTCRON_AGE=silent
run_health
expect_health cron_last_run WARN '^could not read lastcron \(exit 3\)'

new_health_case "the container's clock cannot be read"
FAKE_HEALTH_SSH_FAIL_CMD='date +%s'
run_health
expect_health cron_last_run WARN "^could not read the container's clock"
new_health_case "the connection drops just after the container's clock was read: its answer is not used"
FAKE_HEALTH_SSH_LOST_AFTER='date +%s'
run_health
expect_health cron_last_run WARN "^could not read the container's clock \(exit 255\)"

new_health_case "the clock is behind lastcron"
FAKE_HEALTH_LASTCRON_AGE=-30
run_health
expect_health cron_last_run OK '^0 s ago'

section "verify-health.sh: the setup checks"
new_health_case "occ setupchecks exits 1 with only info results, which is a normal answer"
run_health
expect_health setup_checks OK '^nothing needs attention \(3 info\)'
expect_overall GREEN

new_health_case "one warning and three info results, the brief's case"
FAKE_HEALTH_SETUPCHECKS=warning
run_health
expect_health setup_checks WARN '^PHP memory limit$'
expect_overall AMBER

new_health_case "an error and a warning"
FAKE_HEALTH_SETUPCHECKS=error
run_health
expect_health setup_checks WARN '^Cron last run, Mimetype migrations available$'

new_health_case "twelve warnings: eight are listed, then +4 more"
FAKE_HEALTH_SETUPCHECKS=many
run_health
expect_health setup_checks WARN '^Warning check 01, Warning check 02, Warning check 03, Warning check 04, Warning check 05, Warning check 06, Warning check 07, Warning check 08 \+4 more$'

new_health_case "a warning that has no name is listed by its class"
FAKE_HEALTH_SETUPCHECKS=unnamed
run_health
expect_health setup_checks WARN '^Unnamed$'

new_health_case "the names are long: the detail is cut at 240 characters"
FAKE_HEALTH_SETUPCHECKS=longnames
run_health
expect_health setup_checks WARN '^Long name a x+, Long name b x+.*\.\.\.$'
expect_eq "the detail is 240 characters" 240 "$(grep -E '^setup_checks ' "${case_dir}/stdout" | sed -E 's/^setup_checks +WARN +//' | awk '{print length($0)}')"

new_health_case "no result is anything but success"
FAKE_HEALTH_SETUPCHECKS=success
run_health
expect_health setup_checks OK '\(0 info\)'

new_health_case "the answer has no results at all"
FAKE_HEALTH_SETUPCHECKS=empty
run_health
expect_health setup_checks WARN 'no results'

new_health_case "the answer is not JSON"
FAKE_HEALTH_SETUPCHECKS=nojson
run_health
expect_health setup_checks WARN '^could not read the answer.*Nextcloud is not installed'

new_health_case "setupchecks dies with a fatal error"
FAKE_HEALTH_SETUPCHECKS=fail
run_health
expect_health setup_checks WARN '^could not read the answer \(exit 255\)'

new_health_case "a PHP warning comes before the JSON"
FAKE_HEALTH_SETUPCHECKS=noise
run_health
expect_health setup_checks OK '3 info'

new_health_case "setupchecks times out"
FAKE_HEALTH_TIMEOUT=setupchecks
run_health
expect_health setup_checks WARN '^timed out after 180 s'
expect_overall AMBER

section "verify-health.sh: disk use"
# the use of /var/www/html and of /var/lib/mysql, and the status each gets: under 85 is OK, under 95 WARN, else FAIL
disk_cases=('84|OK|85|WARN' '85|WARN|84|OK' '91|WARN|97|FAIL' '94|WARN|95|FAIL' '95|FAIL|94|WARN' '97|FAIL|91|WARN' '100|FAIL|0|OK')
for spec in "${disk_cases[@]}"; do
  IFS='|' read -r www_use www_status db_use db_status <<< "${spec}"
  new_health_case "/var/www/html is ${www_use}% full, /var/lib/mysql ${db_use}%"
  FAKE_HEALTH_DF_WWW="${www_use}"
  FAKE_HEALTH_DF_MYSQL="${db_use}"
  run_health
  expect_health disk_nextcloud "${www_status}" "^${www_use}% used, [0-9]+\.[0-9] GB free"
  expect_health disk_database "${db_status}" "^${db_use}% used, [0-9]+\.[0-9] GB free"
  if [ "${www_status}" = FAIL ] || [ "${db_status}" = FAIL ]; then expect_overall RED; else expect_overall AMBER; fi
done
new_health_case "both disks are fine"
run_health
expect_health disk_nextcloud OK '^42% used'
expect_health disk_database OK '^35% used'
new_health_case "a full volume says where to look"
FAKE_HEALTH_DF_WWW=97
run_health
expect_health disk_nextcloud FAIL 'playbooks/free-up-space\.md'

new_health_case "df cannot read the path"
FAKE_HEALTH_DF_WWW=error
FAKE_HEALTH_DF_MYSQL=error
run_health
expect_health disk_nextcloud WARN '^could not read df'
expect_health disk_database WARN '^could not read df'
expect_overall AMBER

new_health_case "df prints numbers with leading zeros, which \$(( )) would read as bad octal numbers"
FAKE_HEALTH_DF_WWW=padded
FAKE_HEALTH_DF_MYSQL=padded
run_health
expect_health disk_nextcloud OK '^42% used, 11\.6 GB free$'
expect_health disk_database OK '^42% used, 5\.8 GB free$'
expect_eq "stderr is empty" "" "${err}"
expect_eq "every label is printed once, in order" "${health_labels}" "$(report_labels)"
new_health_case "df prints a number too long for the shell's arithmetic"
FAKE_HEALTH_DF_WWW=huge
FAKE_HEALTH_DF_MYSQL=huge
run_health
expect_health disk_nextcloud WARN '^could not read df'
expect_health disk_database WARN '^could not read df'
expect_eq "stderr is empty" "" "${err}"

new_health_case "df prints no table"
FAKE_HEALTH_DF_WWW=garbage
FAKE_HEALTH_DF_MYSQL=garbage
run_health
expect_health disk_nextcloud WARN '^could not read df'
expect_health disk_database WARN '^could not read df'

new_health_case "the connection drops during the df call"
FAKE_HEALTH_SSH_FAIL_CMD='df -P /var/www/html'
run_health
expect_health disk_nextcloud WARN '^could not read df.*exit 255'
expect_health disk_database OK

section "verify-health.sh: the URL setting"
new_health_case "overwrite.cli.url equals NEXTCLOUD_URL"
run_health
expect_health url_setting OK '^https://abc\.clouve\.app$'

new_health_case "overwrite.cli.url is another address"
FAKE_HEALTH_URL='https://old.clouve.app'
run_health
expect_health url_setting WARN '^overwrite\.cli\.url is https://old\.clouve\.app but NEXTCLOUD_URL is https://abc\.clouve\.app; it changes when the container next starts'
expect_overall AMBER

new_health_case "overwrite.cli.url differs only by a trailing slash"
FAKE_HEALTH_URL='https://abc.clouve.app/'
run_health
expect_health url_setting WARN 'changes when the container next starts'

new_health_case "overwrite.cli.url is not set"
FAKE_HEALTH_URL='unset'
run_health
expect_health url_setting WARN '^overwrite\.cli\.url is not set'

new_health_case "reading overwrite.cli.url throws"
FAKE_HEALTH_URL=fail
run_health
expect_health url_setting WARN '^could not read overwrite\.cli\.url.*SQLSTATE'

section "verify-health.sh: nothing is slower than its timeout"
new_health_case "occ status never answers"
FAKE_HEALTH_TIMEOUT=status
run_health
expect_health ssh_nextcloud FAIL '^occ status gave no answer in 60 s; the checks that need the container were skipped$'
expect_no_health occ_status "${health_occ[@]}" "${health_ssh[@]}"
expect_overall RED
new_health_case "an occ read never answers"
FAKE_HEALTH_TIMEOUT=lastcron
run_health
expect_health cron_last_run WARN '^timed out after 60 s'
expect_health background_jobs_mode OK
new_health_case "the background jobs mode read never answers"
FAKE_HEALTH_TIMEOUT=backgroundjobs_mode
run_health
expect_health background_jobs_mode WARN '^timed out after 60 s'
expect_health cron_last_run OK
new_health_case "the URL setting read never answers"
FAKE_HEALTH_TIMEOUT=overwrite.cli.url
run_health
expect_health url_setting WARN '^timed out after 60 s'
new_health_case "an ssh command never answers"
FAKE_HEALTH_TIMEOUT=ping
run_health
expect_health valkey FAIL '^no PONG.*timed out'
new_health_case "mysql never answers"
FAKE_HEALTH_TIMEOUT=mysql
run_health
expect_health database_tcp FAIL '^timed out after 30 s'

# timeout -k 5 sends KILL 5 seconds after TERM to a command that ignores it, and then exits 137 (128 + 9) instead of 124: also a timeout
kill_cases=(
  'status|ssh_nextcloud|FAIL|^occ status gave no answer in 60 s'
  'setupchecks|setup_checks|WARN|^timed out after 180 s'
  'lastcron|cron_last_run|WARN|^timed out after 60 s'
  'backgroundjobs_mode|background_jobs_mode|WARN|^timed out after 60 s'
  'overwrite.cli.url|url_setting|WARN|^timed out after 60 s'
  'ping|valkey|FAIL|^no PONG: timed out after 60 s'
  'mysql|database_tcp|FAIL|^timed out after 30 s'
)
for spec in "${kill_cases[@]}"; do
  IFS='|' read -r kill_word kill_label kill_status kill_detail <<< "${spec}"
  new_health_case "a command that ignores TERM is killed (${kill_word}, exit 137)"
  FAKE_HEALTH_TIMEOUT="${kill_word}"
  FAKE_HEALTH_TIMEOUT_RC=137
  run_health
  expect_health "${kill_label}" "${kill_status}" "${kill_detail}"
done

section "verify-health.sh: no secret is printed, put on a command line or kept in the environment"
for source in environment clv-secret; do
  creds=()
  [ "${source}" = clv-secret ] && creds=(-NEXTCLOUD_DB_PASSWORD -CLOUVE_OPS_PASSWORD)
  new_health_case "passwords from the ${source}"
  run_health ${creds[@]+"${creds[@]}"}
  expect_overall GREEN
  expect_not_in_logs "${db_pw}" "${FAKE_ARGV_LOG}"
  expect_not_in_logs "${ops_pw}" "${FAKE_ARGV_LOG}"
  expect_eq "the database password reached mysql in MYSQL_PWD (the fake compared it with the one it wants)" 1 "$(fake_calls mysql-env | grep -c 'MYSQL_PWD=set')"
  # jq is the one shimmed tool only the script calls on the agent side (the fake sshpass's helpers are shimmed tools too, and
  # inherit what the real ssh would): so the environments jq got show what the script exported to its own tools.
  holders="$(grep -F -- "${db_pw}" "${FAKE_ARGV_LOG}.env.jq" | grep '^agent ' | cut -d' ' -f2- | cut -d= -f1 | sort -u | tr '\n' ' ')"
  holders_ops="$(grep -F -- "${ops_pw}" "${FAKE_ARGV_LOG}.env.jq" | grep '^agent ' | cut -d' ' -f2- | cut -d= -f1 | sort -u | tr '\n' ' ')"
  expect_eq "jq ran on the agent side" yes "$(if grep -q '^agent ' "${FAKE_ARGV_LOG}.env.jq"; then echo yes; else echo no; fi)"
  if [ "${source}" = environment ]; then
    expect_eq "no tool of the script's got the database password but through the variable the agent set (no export of MYSQL_PWD, no copy)" "FAKE_SECRET_NEXTCLOUD_DB_PASSWORD NEXTCLOUD_DB_PASSWORD " "${holders}"
    expect_eq "and none got the ops password but through its own variable (SSHPASS is set on the sshpass command only)" "CLOUVE_OPS_PASSWORD FAKE_OPS_PASSWORD FAKE_SECRET_CLOUVE_OPS_PASSWORD " "${holders_ops}"
    expect_eq "no clv-secret call" 0 "$(call_count clv-secret)"
  else
    expect_eq "the script's own tools got the database password from nowhere but the harness's stand-in for clv-secret (not exported)" "FAKE_SECRET_NEXTCLOUD_DB_PASSWORD " "${holders}"
    expect_eq "and the ops password from nowhere either (it goes to occ.sh and sshpass on their commands only)" "FAKE_OPS_PASSWORD FAKE_SECRET_CLOUVE_OPS_PASSWORD " "${holders_ops}"
    expect_eq "clv-secret was asked once for each password, and occ.sh did not ask again" $'clv-secret NEXTCLOUD_DB_PASSWORD\nclv-secret CLOUVE_OPS_PASSWORD' "$(fake_calls clv-secret)"
  fi
done

new_health_case "mysql repeats the password in its error message: the report hides it"
FAKE_HEALTH_MYSQL=echo-pw
run_health
expect_health database_tcp FAIL 'Access denied.*\[hidden\]'
expect_not_in_logs "${db_pw}" "${FAKE_ARGV_LOG}"

new_health_case "the database password is on a command line: the fake mysql refuses it"
run_script -- "${BASH}" -c 'mysql -h nc-db.test -u nextcloud "-p$1" nextcloud -e "SELECT 1"; echo "rc=$?"' _ "${db_pw}"
expect_stdout_is $'rc=2\n'

section "verify-health.sh: the environment (exit 1)"
for missing in NEXTCLOUD_HOST NEXTCLOUD_URL NEXTCLOUD_DB_HOST NEXTCLOUD_DB_NAME NEXTCLOUD_DB_USER; do
  for how in unset empty; do
    new_health_case "${missing} ${how}"
    if [ "${how}" = unset ]; then run_health "-${missing}"; else run_health "${missing}="; fi
    expect_rc 1
    expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"
    expect_eq "nothing on stdout" "" "${out}"
    if [[ "${err}" == *"${missing} is not set"* ]]; then ok "${case_label}: stderr says ${missing} is not set"; else bad "${case_label}: the message should say ${missing} is not set" "$(dump_case)"; fi
  done
done
env_cases=(
  'NEXTCLOUD_HOST=bad host|plain host name'
  'NEXTCLOUD_HOST=host/evil|plain host name'
  'NEXTCLOUD_HOST=-leading|plain host name'
  'NEXTCLOUD_HOST=nc.test:8080|plain host name'
  'NEXTCLOUD_DB_HOST=a"b|plain host name'
  'NEXTCLOUD_DB_HOST=db host|plain host name'
  'NEXTCLOUD_MARIADB_HOST=evil host|plain host name'
  'NEXTCLOUD_DB_NAME=--host=evil|NEXTCLOUD_DB_NAME'
  'NEXTCLOUD_DB_NAME=-evil|NEXTCLOUD_DB_NAME'
  'NEXTCLOUD_DB_USER=-u evil|NEXTCLOUD_DB_USER'
  'NEXTCLOUD_DB_USER=ne xt|NEXTCLOUD_DB_USER'
  'NEXTCLOUD_DB_USER=next;cloud|NEXTCLOUD_DB_USER'
  'NEXTCLOUD_URL=https://|NEXTCLOUD_URL'
  'NEXTCLOUD_URL=abc clouve app|NEXTCLOUD_URL'
  'NEXTCLOUD_URL=https://user:pw@abc.clouve.app|NEXTCLOUD_URL'
  'NEXTCLOUD_URL=https://abc.clouve.app:port|NEXTCLOUD_URL'
)
for spec in "${env_cases[@]}"; do
  new_health_case "${spec%%|*}"
  run_health "${spec%%|*}"
  expect_rc 1
  expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"
  if [[ "${err}" == *"${spec#*|}"* ]]; then ok "${case_label}: stderr names ${spec#*|}"; else bad "${case_label}: the message should name ${spec#*|}" "$(dump_case)"; fi
  if [[ "${spec}" == *'pw@'* ]]; then
    if [[ "${err}${out}" == *'pw@'* ]]; then bad "${case_label}: the password in the URL was echoed"; else ok "${case_label}: the password in the URL was not echoed"; fi
  fi
done
for missing in jq curl mysql sshpass ssh timeout mktemp; do
  new_health_case "${missing} is not installed"
  mkdir -p "${case_dir}/no-${missing}-bin"
  for f in "${bin}"/*; do [ "${f##*/}" = "${missing}" ] || ln -sf "${f}" "${case_dir}/no-${missing}-bin/"; done
  for f in /usr/bin/*; do [ "${f##*/}" = "${missing}" ] || [ -e "${case_dir}/no-${missing}-bin/${f##*/}" ] || printf '%s\0' "${f}"; done | xargs -0 ln -sf -t "${case_dir}/no-${missing}-bin"
  run_health PATH="${case_dir}/no-${missing}-bin"
  expect_rc 1
  if [[ "${err}" == *"${missing} is not installed"* ]]; then ok "${case_label}: stderr says ${missing} is missing"; else bad "${case_label}: the message should say ${missing} is missing" "$(dump_case)"; fi
  expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"
done
new_health_case "the temporary folder cannot be made"
run_health TMPDIR="${case_dir}/no/such/folder"
expect_rc 1
if [[ "${err}" == *'could not make a temporary folder'* ]]; then ok "${case_label}: stderr says so"; else bad "${case_label}: the message should say the temporary folder could not be made" "$(dump_case)"; fi
expect_eq "no ssh, curl or mysql call was made" 0 "$(grep -cE '^(ssh|curl|mysql) ' "${FAKE_CALLS}" || true)"
expect_eq "nothing on stdout" "" "${out}"

new_health_case "no database password anywhere"
run_health -NEXTCLOUD_DB_PASSWORD -FAKE_SECRET_NEXTCLOUD_DB_PASSWORD
expect_rc 1
if [[ "${err}" == *'clv-secret: NEXTCLOUD_DB_PASSWORD is not set on this server'* ]]; then ok "${case_label}: clv-secret's own message reaches stderr"; else bad "${case_label}: clv-secret's message was swallowed" "$(dump_case)"; fi
if [[ "${err}" == *'NEXTCLOUD_DB_PASSWORD is not set'* && "${err}" == *'clv-secret --list'* ]]; then ok "${case_label}: the script says which password is missing and where to look"; else bad "${case_label}: the script should name the password and clv-secret --list" "$(dump_case)"; fi
expect_eq "nothing but clv-secret was called" "clv-secret NEXTCLOUD_DB_PASSWORD" "$(cat "${FAKE_CALLS}")"
new_health_case "no ops password anywhere"
run_health -CLOUVE_OPS_PASSWORD -FAKE_SECRET_CLOUVE_OPS_PASSWORD
expect_rc 1
if [[ "${err}" == *'clv-secret: CLOUVE_OPS_PASSWORD is not set on this server'* ]]; then ok "${case_label}: clv-secret's own message reaches stderr"; else bad "${case_label}: clv-secret's message was swallowed" "$(dump_case)"; fi
if [[ "${err}" == *'CLOUVE_OPS_PASSWORD is not set'* && "${err}" == *'clv-secret --list'* ]]; then ok "${case_label}: the script says which password is missing and where to look"; else bad "${case_label}: the script should name the password and clv-secret --list" "$(dump_case)"; fi
expect_eq "no ssh, curl or mysql call" 0 "$(grep -cE '^(ssh|curl|mysql) ' "${FAKE_CALLS}" || true)"

section "verify-health.sh: usage"
for flag in -h --help; do
  new_health_case "${flag}"
  run_health -- "${flag}"
  expect_rc 0
  if [[ "${out}" == 'Usage: verify-health.sh [-h|--help]'* && "${out}" == *'read-only'* && "${out}" == *'GREEN'* && "${out}" == *'64'* ]]; then ok "${case_label}: the usage is on stdout, with the exit codes"
  else bad "${case_label}: no usage on stdout" "$(dump_case)"; fi
  expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"
done
new_health_case "--help does not need the settings"
run_health -NEXTCLOUD_HOST -NEXTCLOUD_URL -- --help
expect_rc 0
new_health_case "an argument it does not know"
run_health -- --json
expect_rc 64
if [[ "${err}" == *'unknown argument: --json'* && "${err}" == *'Usage: verify-health.sh'* ]]; then ok "${case_label}: stderr names the argument and shows the usage"; else bad "${case_label}: stderr should name the argument" "$(dump_case)"; fi
expect_eq "nothing was called" "" "$(cat "${FAKE_CALLS}")"

section "verify-health.sh: a run that is killed leaves nothing behind"
# Bash runs the script's EXIT trap when a signal ends the script. The script is started by a launcher that makes the signals default
# again and writes its PID: a suite started with nohup or in the background has HUP or INT ignored, and the cases would then test
# the way they were started.
kill_launcher='import os, signal, sys
for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, signal.SIG_DFL)
with open(os.environ["FAKE_HEALTH_PIDFILE"], "w") as f:
    f.write(str(os.getpid()))
os.execv(sys.argv[1], sys.argv[1:])'
for sig in TERM:143 INT:130 HUP:129; do
  new_health_case "SIG${sig%%:*} while the HTTP probe runs"
  FAKE_HEALTH_PIDFILE="${case_dir}/pid"
  FAKE_HEALTH_KILL="${sig%%:*}"
  run_script -- "$(command -v python3)" -I -c "${kill_launcher}" "${health_sh}"
  check_db_password
  expect_rc "${sig#*:}"
  expect_eq "no temporary file is left" "" "$(ls -A "${case_dir}/tmp")"
  expect_eq "no report was printed" "" "${out}"
  # bash waits for the command it is running before it acts on SIGINT, whatever the script does; TERM and HUP end the script at once
  if [ "${sig%%:*}" != INT ]; then
    expect_eq "the script did not wait for the command it was running" no "$([ -e "${FAKE_CALLS}.probe-finished" ] && echo yes || echo no)"
  fi
done

# ===== backup.sh, restore.sh and run-in-nextcloud.sh ==========================
# backup.sh and restore.sh run inside the Nextcloud container as root. Here they run against the case's tree (NC_ROOT), as
# root (the fake id), with occ, PHP and MariaDB's clients faked; each important case runs both ways: as a file, and the
# way run-in-nextcloud.sh sends it, through `bash -s` with the script on stdin.
br_t0=1800000000                                   # the case's clock: 2027-01-15T08:00:00Z, backup 20270115-080000
br_n0="$(br_name "${br_t0}")"
br_done_re='^\[nextcloud/backup\] done: .+ \([0-9]+(\.[0-9])? (B|KB|MB|GB)\)\. It is on Nextcloud'"'"'s data volume next to the data it protects; it is never deleted automatically\.$'

# expect_script_file <path> <name>: the checks every script of the plugin passes, plus the in-container header
expect_script_file() {
  local f="$1" n="$2" m
  if [ ! -f "${f}" ]; then bad "${n} exists" "${f}"; return; fi
  m="$(mode_of "${f}")"
  if [ "${m}" = 755 ]; then ok "${n} has mode 755"; else bad "${n} must have mode 755 (it is ${m})"; fi
  if [ "$(head -n 1 "${f}")" = '#!/usr/bin/env bash' ]; then ok "${n} starts with #!/usr/bin/env bash"; else bad "${n} does not start with #!/usr/bin/env bash"; fi
  if grep -qE '^[[:space:]]*(set[[:space:]]+-[A-Za-z]*x|set[[:space:]]+-o[[:space:]]+xtrace)' "${f}"; then bad "${n} turns on set -x"; else ok "${n} never turns on set -x"; fi
  if grep -qE '^[[:space:]]*(export|declare -x|typeset -x)[[:space:]]' "${f}"; then bad "${n} exports a variable"; else ok "${n} exports no variable"; fi
  if grep -vE '^[[:space:]]*#' "${f}" | grep -qE '(sshpass[[:space:]]+-p|mariadb[^|]*[[:space:]]-p[^[:space:]]|mysql[^|]*[[:space:]]-p[^[:space:]]|--password=)'; then bad "${n} puts a password on a command line"
  else ok "${n} puts no password on a command line"; fi
}

# expect_in_container_header <path> <name>: the header says where the script runs and where its credentials come from, and
# the whole script is one function, called on the last line with stdin from /dev/null. Under `bash -s` bash reads the script
# from stdin as it goes, so a command that read stdin would eat the rest of the script; and a script cut off in transit is
# then never run at all, instead of running up to where it was cut.
expect_in_container_header() {
  local f="$1" n="$2" phrase head
  head="$(sed -n 2,14p "${f}" | tr '\n' ' ' | sed 's/#  */ /g; s/  */ /g')"
  for phrase in 'Runs INSIDE the Nextcloud container, as root' 'run-in-nextcloud.sh sends it' "sudo drops the container's environment" 'come from config/config.php'; do
    if [[ "${head}" == *"${phrase}"* ]]; then ok "${n}: the header says: ${phrase}"; else bad "${n}: the header should say: ${phrase}" "${head}"; fi
  done
  if [ "$(grep -vE '^[[:space:]]*(#|$)' "${f}" | tail -n 1)" = 'main "$@" < /dev/null' ]; then ok "${n}: the last line runs main with stdin from /dev/null"
  else bad "${n}: the last line should be: main \"\$@\" < /dev/null" "$(tail -n 3 "${f}")"; fi
  if grep -qE '^[[:space:]]*exec[[:space:]]+(0?<|<)' "${f}"; then bad "${n}: it redirects its own stdin with exec, which under bash -s ends the script"; else ok "${n}: it never redirects its own stdin with exec"; fi
}

# expect_php_as_www_data: every PHP program ran as www-data (config.php is code www-data can change, so root never runs it)
expect_php_as_www_data() {
  local php_calls sudo_php
  php_calls="$(fake_calls php-r | wc -l | tr -d ' ')"
  sudo_php="$(fake_calls sudo | grep -cE '^sudo user=www-data preserve=- NC_PASS=unset :: php -d display_errors=stderr ' || true)"
  if [ "${php_calls}" -gt 0 ] && [ "${php_calls}" = "${sudo_php}" ]; then ok "${case_label}: each of the ${php_calls} PHP program run(s) went through sudo -u www-data, with display_errors=stderr"
  else bad "${case_label}: every php -r should run as www-data with display_errors=stderr (php -r: ${php_calls}, through sudo -u www-data: ${sudo_php})" "$(fake_calls sudo; fake_calls php-r)"; fi
  local others
  others="$(fake_calls sudo | grep -E ':: php ' | grep -vE '^sudo user=www-data ' || true)"
  if [ -n "${others}" ]; then bad "${case_label}: php ran as another user than www-data" "${others}"
  else ok "${case_label}: php never ran as root"; fi
}

# expect_backup <folder> <with_data true|false>: the folder is a whole backup: its files and modes, the checksums, the
# archives, the manifest
expect_backup() {
  local folder="$1" wd="$2" want_files f sizes
  want_files="SHA256SUMS apps.tar.gz config.tar.gz database.sql.gz manifest.json"
  if [ "${wd}" = true ]; then want_files="SHA256SUMS apps.tar.gz config.tar.gz data.tar.gz database.sql.gz manifest.json"; fi
  expect_eq "the backup's files" "${want_files}" "$(names_in "${folder}")"
  expect_mode "${br_backups}" 700 "clouve-backups"
  expect_mode "${folder}" 700 "the backup's folder"
  for f in ${want_files}; do expect_mode "${folder}/${f}" 600 "${f}"; done
  expect_eq "sha256sum -c passes" "ok" "$(cd "${folder}" 2> /dev/null && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1 && echo ok)"
  expect_eq "SHA256SUMS covers the archives and the manifest" "$(echo "${want_files}" | tr ' ' '\n' | grep -v SHA256SUMS | LC_ALL=C sort | tr '\n' ' ')" "$(cut -c67- "${folder}/SHA256SUMS" 2> /dev/null | LC_ALL=C sort | tr '\n' ' ')"
  for f in ${want_files}; do case "${f}" in *.gz) expect_eq "gzip -t ${f}" ok "$(gzip -t "${folder}/${f}" 2> /dev/null && echo ok)" ;; esac; done
  expect_eq "the manifest's fields" "2027-01-15T08:00:00Z|35.0.2.2|35.0.2|oc123abc|nextcloud|${wd}|nextcloud skill backup.sh 0.1.0" \
    "$(jq -r '[.created, .version, .versionstring, .instanceid, .dbname, (.with_data | tostring), .made_by] | join("|")' "${folder}/manifest.json" 2> /dev/null)"
  sizes=""
  for f in ${want_files}; do case "${f}" in *.gz) sizes+="${f}=$(stat -c %s "${folder}/${f}" 2> /dev/null) " ;; esac; done
  expect_eq "the manifest lists each archive with its size in bytes" "${sizes% }" "$(jq -r '.files | sort_by(.name) | map("\(.name)=\(.bytes)") | join(" ")' "${folder}/manifest.json" 2> /dev/null)"
  expect_eq "database.sql.gz holds the dump" "-- dump of nextcloud" "$(gzip -dc "${folder}/database.sql.gz" 2> /dev/null | head -n 1)"
  expect_eq "config.tar.gz holds config/" "config/ config/config.php config/upgrade-disable-web.config.php" "$(tar -tzf "${folder}/config.tar.gz" 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
  expect_eq "apps.tar.gz holds custom_apps/ and themes/" "custom_apps/ custom_apps/calendar/ custom_apps/calendar/appinfo/ custom_apps/calendar/appinfo/info.xml themes/" \
    "$(tar -tzf "${folder}/apps.tar.gz" 2> /dev/null | sort | tr '\n' ' ' | sed 's/ $//')"
}

# expect_nothing_left: no backup folder, no marker, maintenance mode off, no temporary file
expect_nothing_left() {
  expect_eq "no backup folder is left" "" "$(br_backups_now)"
  expect_eq "no BACKUP-IN-PROGRESS marker is left" no "$([ -e "${br_backups}/BACKUP-IN-PROGRESS" ] && echo yes || echo no)"
  expect_eq "maintenance mode is off again" off "$(br_now_maint)"
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
}

section "the harness: the fakes backup.sh and restore.sh need leave the stdin they inherit alone"
new_br_case "a script on stdin calls id, chown, tar, gzip, df, mariadb, mariadb-dump and php -r between two echo lines"
printf '[client]\nuser=nextcloud\n' > "${case_dir}/c.cnf"
chmod 600 "${case_dir}/c.cnf"
br_script=$'echo before\nid -u > /dev/null\nchown www-data:www-data /nowhere\n'
br_script+="tar -czf ${case_dir}/t.tgz -C ${br_www} config"$'\n'"gzip -t ${case_dir}/t.tgz"$'\n'"df -PB1 ${br_data} > /dev/null"$'\n'
br_script+="mariadb --defaults-extra-file=${case_dir}/c.cnf --skip-ssl -N -B -e 'SELECT 1' nextcloud > /dev/null"$'\n'
br_script+="mariadb-dump --defaults-extra-file=${case_dir}/c.cnf --skip-ssl --single-transaction --quick --hex-blob --default-character-set=utf8mb4 --routines --triggers nextcloud > /dev/null"$'\n'
br_script+="php -d display_errors=stderr -r x -- get ${br_www}/config/config.php dbname > /dev/null"$'\n'$'echo after\n'
run_script -- "${BASH}" -s < <(printf '%s' "${br_script}")
expect_eq "both echo lines ran" $'before\nafter' "${out}"
expect_eq "every fake was called" "chown df mariadb mariadb-dump php-r tar " "$(grep -oE '^(chown|tar|df|mariadb|mariadb-dump|php-r) ' "${FAKE_CALLS}" | tr -d ' ' | sort -u | tr '\n' ' ')"
new_case "outside these cases mariadb and mariadb-dump are still deny stubs, and id is the real one"
run_script -- "${BASH}" -c 'mariadb-dump x; echo "rc=$?"; id -u'
expect_eq "mariadb-dump is denied and id is real" "rc=99 $(id -u)" "$(printf '%s' "${out}" | tr '\n' ' ')"

section "backup.sh: the file"
expect_script_file "${backup_sh}" backup.sh
if [ -f "${backup_sh}" ]; then expect_in_container_header "${backup_sh}" backup.sh; fi

section "backup.sh: a config-only backup, the brief's default, run both ways"
for how in file stdin; do
  new_br_case "config-only (${how})"
  run_in "${how}" "${backup_sh}"
  expect_rc 0
  expect_backup "${br_backups}/${br_n0}" false
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:mode --off'
  expect_eq "the marker, naming the backup and locked, was there before maintenance mode went on and still there when it went off" \
    "br-occ maintenance:mode --on maintenance=off backup-marker=locked:${br_n0} restore-marker=absent
br-occ maintenance:mode --off maintenance=on backup-marker=locked:${br_n0} restore-marker=absent" \
    "$(fake_calls br-occ | grep 'maintenance:mode')"
  expect_eq "the database was dumped in maintenance mode, with the locked marker in place" "mariadb-dump-state maintenance=on backup-marker=locked:${br_n0} restore-marker=absent" "$(fake_calls mariadb-dump-state)"
  expect_eq "no marker is left, and maintenance mode is off" "absent off" "$([ -e "${br_backups}/BACKUP-IN-PROGRESS" ] && echo present || echo absent) $(br_now_maint)"
  expect_eq "mariadb-dump read a mode 600 options file in a mode 700 folder, with the host, the user and the password" \
    "mariadb-dump-cnf mode=600 dir=700 host=nextcloud-mariadb port=- socket=- user=nextcloud password=ok" "$(fake_calls mariadb-dump-cnf)"
  expect_eq "and so did the size query" "mariadb-cnf mode=600 dir=700 host=nextcloud-mariadb port=- socket=- user=nextcloud password=ok" "$(fake_calls mariadb-cnf)"
  expect_eq "mariadb-dump's options: the file first, then the brief's, and the database name last" \
    "--skip-ssl --single-transaction --quick --hex-blob --default-character-set=utf8mb4 --routines --triggers nextcloud" \
    "$(fake_calls mariadb-dump | grep -E '^mariadb-dump --' | sed -E 's/^mariadb-dump --defaults-extra-file=[^ ]+ //')"
  expect_eq "the size query asks information_schema for this schema's data and index length" \
    "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = DATABASE()" "$(cat "${FAKE_SQL_LOG}")"
  expect_eq "the image's init lock was taken without waiting (fd 9), then the marker's (fd 8)" $'flock-fd -n 9\nflock-fd -n 8' "$(fake_calls flock-fd)"
  expect_eq "the init lock is on the image's lock file, and the marker's lock on a temporary file beside the marker, which then became it" \
    $'flock-fd-file 9 /var/www/html/nextcloud-init-sync.lock\nflock-fd-file 8 /var/www/html/data/clouve-backups/.BACKUP-IN-PROGRESS.XXXXXX' \
    "$(fake_calls flock-fd-file | sed -E 's/(\.BACKUP-IN-PROGRESS\.)[A-Za-z0-9]{6}$/\1XXXXXX/')"
  expect_php_as_www_data
  expect_eq "each occ call went through sudo -n -u www-data" "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')" "$(fake_calls sudo | grep -c '^sudo user=www-data preserve=- NC_PASS=unset :: php /var/www/html/occ --no-interaction --no-warnings ' || true)"
  expect_eq "config.php was read for the settings the backup needs" "datadirectory dbtype dbhost dbname dbuser dbpassword version instanceid" \
    "$(fake_calls php-r | sed -E 's/^php-r get display_errors=stderr [^ ]+ //' | tr '\n' ' ' | sed 's/ $//')"
  if [[ "$(tail -n 1 "${case_dir}/stdout")" =~ ${br_done_re} ]] && [[ "$(tail -n 1 "${case_dir}/stdout")" == *" done: ${br_backups}/${br_n0} ("* ]]; then ok "${case_label}: the last line is the brief's done line, with the folder and its size"
  else bad "${case_label}: the last line should be the done line" "$(dump_case)"; fi
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
done

section "backup.sh: BACKUP-IN-PROGRESS is never there without its lock"
new_br_case "a sampler opens the marker over and over while a slow backup runs"
FAKE_BR_DUMP_SLEEP=1
# A sample that gets the lock counts only when the name still points to the file it locked: the script removes the
# marker before it lets the lock go, so a sampler that opened the marker just before can lock it once it is gone.
( m="${br_backups}/BACKUP-IN-PROGRESS"
  until [ -e "${case_dir}/watch-stop" ]; do
    if exec 7< "${m}"; then
      if ! flock -n 7; then echo locked
      elif [ "$(stat -c %i "${m}" 2> /dev/null)" = "$(stat -L -c %i "/proc/${BASHPID}/fd/7")" ]; then echo unlocked
      else echo gone; fi
      exec 7<&-
    fi 2> /dev/null
  done > "${case_dir}/watch" ) &
br_watcher=$!
run_in file "${backup_sh}"
: > "${case_dir}/watch-stop"
wait "${br_watcher}"
expect_rc 0
expect_eq "it never found the marker unlocked" 0 "$(grep -c '^unlocked$' "${case_dir}/watch" || true)"
if [ "$(grep -c '^locked$' "${case_dir}/watch" || true)" -gt 0 ]; then ok "${case_label}: it found the marker, locked, $(grep -c '^locked$' "${case_dir}/watch") time(s)"
else bad "${case_label}: the sampler never saw the marker, so it proved nothing"; fi
expect_eq "no temporary marker file is left" "" "$(find "${br_backups}" -maxdepth 1 -name '.BACKUP-IN-PROGRESS.*')"

section "backup.sh --with-data"
# br_disk <path>: the space a path takes on its volume, as backup.sh and restore.sh measure it (du -s -B1)
br_disk() { local n; read -r n _ < <(du -s -B1 -- "$1"); printf '%s' "${n}"; }
for how in file stdin; do
  new_br_case "--with-data (${how})"
  mkdir -p "${br_data}/appdata_oc123/sub/preview" "${br_data}/alice/files/clouve-backups"
  printf 'kept\n' > "${br_data}/appdata_oc123/sub/preview/y"
  printf 'kept\n' > "${br_data}/alice/files/clouve-backups/z"
  head -c 65536 /dev/urandom > "${br_data}/appdata_oc123/preview/1/big.png"     # a preview that takes room on the volume
  want_disk=$(($(br_disk "${br_data}") - $(br_disk "${br_data}/appdata_oc123/preview")))
  run_in "${how}" "${backup_sh}" -- --with-data
  expect_rc 0
  expect_backup "${br_backups}/${br_n0}" true
  expect_eq "the manifest's data_bytes is the space the users' files took (du -s -B1, without the previews)" "${want_disk}" "$(jq -r '.data_bytes' "${br_backups}/${br_n0}/manifest.json" 2> /dev/null)"
  members="$(tar -tzf "${br_backups}/${br_n0}/data.tar.gz" 2> /dev/null | sort)"
  for m in ./alice/files/a.txt ./.ncdata ./.htaccess ./nextcloud.log ./appdata_oc123/css/c.css ./appdata_oc123/sub/preview/y ./alice/files/clouve-backups/z; do
    if grep -qxF -- "${m}" <<< "${members}"; then ok "${case_label}: data.tar.gz has ${m}"; else bad "${case_label}: data.tar.gz lacks ${m}" "${members}"; fi
  done
  if grep -qE '^\./clouve-backups' <<< "${members}"; then bad "${case_label}: data.tar.gz holds ./clouve-backups" "${members}"; else ok "${case_label}: data.tar.gz has no ./clouve-backups"; fi
  if grep -qE '^\./appdata_oc123/preview' <<< "${members}"; then bad "${case_label}: data.tar.gz holds the previews" "${members}"; else ok "${case_label}: data.tar.gz has no ./appdata_oc123/preview"; fi
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:mode --off'
done

section "backup.sh: maintenance mode already on, and --no-maintenance"
new_br_case "maintenance mode already on: it stays on, and no marker is written"
printf 'on\n' > "${FAKE_BR_STATE}/maintenance"
run_in file "${backup_sh}"
expect_rc 0
expect_backup "${br_backups}/${br_n0}" false
expect_eq "a backup without the users' files has no data_bytes" false "$(jq 'has("data_bytes")' "${br_backups}/${br_n0}/manifest.json" 2> /dev/null)"
expect_occ_brief 'status --output=json'
expect_eq "maintenance mode is still on" on "$(br_now_maint)"
expect_eq "the dump saw no marker: this run left the maintenance mode it found alone" "mariadb-dump-state maintenance=on backup-marker=absent restore-marker=absent" "$(fake_calls mariadb-dump-state)"
expect_eq "and no marker is there now" no "$([ -e "${br_backups}/BACKUP-IN-PROGRESS" ] && echo yes || echo no)"
if [[ "${out}" == *'maintenance mode was already on'* ]]; then ok "${case_label}: stdout says it leaves maintenance mode on"; else bad "${case_label}: stdout should say maintenance mode was already on" "$(dump_case)"; fi
new_br_case "--no-maintenance: no maintenance:mode call at all"
run_in stdin "${backup_sh}" -- --no-maintenance
expect_rc 0
expect_backup "${br_backups}/${br_n0}" false
expect_occ_brief 'status --output=json'
expect_eq "the dump ran with maintenance mode off and no marker" "mariadb-dump-state maintenance=off backup-marker=absent restore-marker=absent" "$(fake_calls mariadb-dump-state)"
# A marker of a backup that died is the image's to clear at its next start, which does that without the init lock: so
# backup.sh never takes one over, and never removes one.
for spec in 'on|' 'on|--no-maintenance' 'off|' 'off|--no-maintenance'; do
  br_opt="${spec#*|}"
  new_br_case "a dead backup's unlocked marker, maintenance mode ${spec%%|*}${br_opt:+, ${br_opt}}: it refuses (exit 1) and leaves both alone"
  printf '%s\n' "${spec%%|*}" > "${FAKE_BR_STATE}/maintenance"
  mkdir -m 700 "${br_backups}"
  printf '20270101-000000\n' > "${br_backups}/BACKUP-IN-PROGRESS"
  br_args=()
  if [ -n "${br_opt}" ]; then br_args=("${br_opt}"); fi
  run_in file "${backup_sh}" -- ${br_args[@]+"${br_args[@]}"}
  expect_rc 1
  expect_eq "nothing made; no maintenance:mode call; maintenance mode as it was; the marker still names the dead backup" \
    "|status --output=json|${spec%%|*}|20270101-000000" \
    "$(br_backups_now)|$(occ_brief)|$(br_now_maint)|$(head -n 1 "${br_backups}/BACKUP-IN-PROGRESS" 2> /dev/null)"
  for phrase in 'a backup that stopped (20270101-000000)' "The container's next start turns maintenance mode off and removes the marker" 'occ.sh maintenance:mode --off' \
    "sudo rm -f /var/www/html/data/clouve-backups/BACKUP-IN-PROGRESS"; do
    if [[ "${err}" == *"${phrase/\/var\/www\/html/${br_www}}"* ]]; then ok "${case_label}: stderr says: ${phrase}"; else bad "${case_label}: stderr should say: ${phrase}" "$(dump_case)"; fi
  done
done
new_br_case "a live backup holds its marker locked: no second one takes over"
printf 'on\n' > "${FAKE_BR_STATE}/maintenance"
mkdir -m 700 "${br_backups}"
printf '20270101-000000\n' > "${br_backups}/BACKUP-IN-PROGRESS"
( SECONDS=0; exec 7< "${br_backups}/BACKUP-IN-PROGRESS"; flock 7; : > "${case_dir}/marker-held"; until [ -e "${case_dir}/marker-release" ] || [ "${SECONDS}" -gt 20 ]; do sleep 0.1; done ) &
br_holder=$!
wait_for_file "${case_dir}/marker-held"
run_in file "${backup_sh}"
: > "${case_dir}/marker-release"
wait "${br_holder}"
expect_rc 1
expect_eq "nothing made, maintenance mode and the marker untouched" "|status --output=json|on|20270101-000000" \
  "$(br_backups_now)|$(occ_brief)|$(br_now_maint)|$(head -n 1 "${br_backups}/BACKUP-IN-PROGRESS" 2> /dev/null)"

section "backup.sh: not enough space (exit 3)"
# br_mb <bytes>: the bytes in MB as backup.sh writes them: one decimal, rounded to the nearest tenth (1 MB = 1048576 bytes)
br_mb() { local t=$((($1 * 10 + 524288) / 1048576)); printf '%d.%d MB' "$((t / 10))" "$((t % 10))"; }

# br_need: what backup.sh must find free: 1.2 times the database (FAKE_BR_DB_SIZE) and the folders, rounded up
br_need() {
  local est=$((${FAKE_BR_DB_SIZE:-5242880})) p n
  for p in "${br_www}/config" "${br_www}/custom_apps" "${br_www}/themes"; do read -r n _ < <(du -sb "${p}"); est=$((est + n)); done
  if [ "${1:-}" = data ]; then
    read -r n _ < <(du -sb "${br_data}"); est=$((est + n))
    if [ -d "${br_backups}" ]; then read -r n _ < <(du -sb "${br_backups}"); est=$((est - n)); fi
    for p in "${br_data}"/appdata_*/preview; do if [ -d "${p}" ]; then read -r n _ < <(du -sb "${p}"); est=$((est - n)); fi; done
  fi
  printf '%s' $(((est * 12 + 9) / 10))
}
for kind in config data; do
  new_br_case "free space just under 1.2 times the estimate (${kind})"
  args=()
  if [ "${kind}" = data ]; then
    args=(--with-data)
    mkdir -m 700 "${br_backups}" "${br_backups}/20260101-000000"
    head -c 3000000 /dev/zero > "${br_backups}/20260101-000000/big"     # an old backup, which the estimate leaves out
    head -c 2000000 /dev/zero > "${br_data}/appdata_oc123/preview/1/big.png"
    head -c 1000000 /dev/zero > "${br_data}/alice/files/movie.bin"
  fi
  need="$(br_need "${kind}")"
  FAKE_DF_AVAIL=$((need / 2))
  run_in file "${backup_sh}" -- ${args[@]+"${args[@]}"}
  expect_rc 3
  need_mb="$(br_mb "${need}")"
  free_mb="$(br_mb "$((need / 2))")"
  if [[ "${err}" == *"needs ${need_mb}"* && "${err}" == *"${free_mb} are free"* ]]; then ok "${case_label}: stderr gives both numbers in MB (${need_mb} needed, ${free_mb} free)"
  else bad "${case_label}: stderr should give ${need_mb} needed and ${free_mb} free" "$(dump_case)"; fi
  FAKE_DF_AVAIL=$((need - 1))
  before="$(br_backups_now)"
  run_in file "${backup_sh}" -- ${args[@]+"${args[@]}"}
  expect_rc 3
  expect_eq "no new folder" "${before}" "$(br_backups_now)"
  expect_eq "no occ call but the status" "status --output=json" "$(occ_brief)"
  expect_eq "no dump" 0 "$(call_count mariadb-dump)"
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
  FAKE_DF_AVAIL="${need}"
  run_in file "${backup_sh}" -- ${args[@]+"${args[@]}"}
  expect_rc 0
done
if [ -d "${br_backups}/${br_n0}" ]; then
  members="$(tar -tzf "${br_backups}/${br_n0}/data.tar.gz" 2> /dev/null)"
  if grep -q 'movie.bin' <<< "${members}"; then ok "${case_label}: with exactly enough space the backup has the users' files"; else bad "${case_label}: the backup should hold movie.bin"; fi
fi

section "backup.sh: a step that fails leaves no backup and maintenance mode as it was (exit 2)"
for how in file stdin; do
  new_br_case "the dump fails (${how})"
  FAKE_BR_DUMP_FAIL=1
  run_in "${how}" "${backup_sh}"
  expect_rc 2
  expect_nothing_left
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:mode --off'
  if [[ "${err}" == *'mariadb-dump'* && "${err}" == *"Can't connect to server"* ]]; then ok "${case_label}: stderr has mariadb-dump's error and names the step"; else bad "${case_label}: stderr should name mariadb-dump" "$(dump_case)"; fi
done
new_br_case "the users' files can't be archived"
FAKE_BR_TAR_FAIL=data.tar.gz
run_in file "${backup_sh}" -- --with-data
expect_rc 2
expect_nothing_left
if [[ "${err}" == *'data.tar.gz'* ]]; then ok "${case_label}: stderr names data.tar.gz"; else bad "${case_label}: stderr should name data.tar.gz" "$(dump_case)"; fi
new_br_case "the config archive can't be written, with maintenance mode already on: it stays on"
printf 'on\n' > "${FAKE_BR_STATE}/maintenance"
FAKE_BR_TAR_FAIL=config.tar.gz
run_in file "${backup_sh}"
expect_rc 2
expect_eq "no backup folder, and maintenance mode still on" "|on" "$(br_backups_now)|$(br_now_maint)"
expect_occ_brief 'status --output=json'
new_br_case "maintenance mode can't be turned on: nothing is made"
FAKE_BR_MAINT_FAIL=on
run_in file "${backup_sh}"
expect_rc 2
expect_nothing_left
expect_eq "no dump" 0 "$(call_count mariadb-dump)"
new_br_case "maintenance mode can't be turned off at the end: the backup is kept, the marker stays for the image (exit 5)"
FAKE_BR_MAINT_FAIL=off
run_in file "${backup_sh}"
expect_rc 5
expect_backup "${br_backups}/${br_n0}" false
br_lock_state="$(if ( exec 7< "${br_backups}/BACKUP-IN-PROGRESS" && flock -n 7 ) 2> /dev/null; then echo unlocked; else echo locked-or-missing; fi)"
expect_eq "maintenance mode is still on, and the marker, named for this backup, stays (unlocked, now the run is over)" "on|${br_n0}|unlocked" \
  "$(br_now_maint)|$(head -n 1 "${br_backups}/BACKUP-IN-PROGRESS" 2> /dev/null)|${br_lock_state}"
for phrase in 'maintenance mode is still on' 'occ.sh maintenance:mode --off' "container's next start turns it off"; do
  if [[ "${err}" == *"${phrase}"* ]]; then ok "${case_label}: stderr says: ${phrase}"; else bad "${case_label}: stderr should say: ${phrase}" "$(dump_case)"; fi
done
if [[ "$(tail -n 1 "${case_dir}/stdout")" =~ ${br_done_re} ]]; then ok "${case_label}: the last line is still the done line"; else bad "${case_label}: the last line should be the done line" "$(dump_case)"; fi
new_br_case "tar says a file changed while it read it: a warning, and the backup stands"
FAKE_BR_TAR_CHANGED=data.tar.gz
run_in file "${backup_sh}" -- --with-data
expect_rc 0
expect_backup "${br_backups}/${br_n0}" true
if [[ "${err}" == *'changed'* && "${err}" == *'data.tar.gz'* ]]; then ok "${case_label}: stderr warns about the changed file"; else bad "${case_label}: stderr should warn that a file changed" "$(dump_case)"; fi

section "backup.sh: the check of the new backup fails (exit 4)"
new_br_case "gzip -t fails"
FAKE_BR_GZIP_T_FAIL=1
run_in file "${backup_sh}"
expect_rc 4
expect_nothing_left
if [[ "${err}" == *'gzip -t'* ]]; then ok "${case_label}: stderr says the check failed"; else bad "${case_label}: stderr should say gzip -t failed" "$(dump_case)"; fi

section "backup.sh: a run that is stopped cleans up"
# The dump goes on for a second after the signal. The cleanup waits for it: nothing the backup started runs on after
# the script has removed the folder and turned maintenance mode off.
for sig in TERM:143 INT:130 HUP:129 PIPE:141; do
  new_br_case "SIG${sig%%:*} during the dump"
  FAKE_PIDFILE="${case_dir}/pid"
  FAKE_BR_KILL_AT=dump
  FAKE_BR_KILL_SIG="${sig%%:*}"
  FAKE_BR_DUMP_SLEEP=1
  run_in file "${backup_sh}"
  expect_rc "${sig#*:}"
  expect_nothing_left
  expect_order "the cleanup came after the dump had ended" '^mariadb-dump-finished$' '^br-occ maintenance:mode --off '
done

section "backup.sh: what it refuses (exit 1)"
new_br_case "not root"
run_in file "${backup_sh}" -FAKE_BR_ROOT
expect_rc 1
if [[ "${err}" == *'root'* ]]; then ok "${case_label}: stderr says it needs root"; else bad "${case_label}: stderr should say it needs root" "$(dump_case)"; fi
expect_eq "nothing was called" "" "$(grep -vE '^denied-' "${FAKE_CALLS}")"
new_br_case "no config.php"
rm -f "${br_www}/config/config.php"
run_in file "${backup_sh}"
expect_rc 1
expect_eq "no occ call" 0 "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
new_br_case "occ can't report the status"
FAKE_BR_STATUS_FAIL=1
run_in file "${backup_sh}"
expect_rc 1
if [[ "${err}" == *'An unhandled exception has been thrown'* ]]; then ok "${case_label}: stderr shows occ's first line"; else bad "${case_label}: stderr should show what occ said" "$(dump_case)"; fi
expect_eq "nothing made" "|off" "$(br_backups_now)|$(br_now_maint)"
new_br_case "Nextcloud is not installed"
FAKE_BR_INSTALLED=false
run_in file "${backup_sh}"
expect_rc 1
new_br_case "a restore was cut off"
mkdir -m 700 "${br_backups}"
printf '20261231-235959\n' > "${br_backups}/RESTORE-IN-PROGRESS"
run_in file "${backup_sh}"
expect_rc 1
if [[ "${err}" == *'RESTORE-IN-PROGRESS'* && "${err}" == *'20261231-235959'* ]]; then ok "${case_label}: stderr names the marker and the backup it holds"; else bad "${case_label}: stderr should name the marker and the backup" "$(dump_case)"; fi
expect_eq "nothing made and no maintenance:mode call" "|status --output=json" "$(br_backups_now)|$(occ_brief)"
new_br_case "the init lock is held by an install, an upgrade or another backup"
( SECONDS=0; exec 8< "${br_www}/nextcloud-init-sync.lock"; flock 8; : > "${case_dir}/lock-held"; until [ -e "${case_dir}/lock-release" ] || [ "${SECONDS}" -gt 20 ]; do sleep 0.1; done ) &
br_holder=$!
wait_for_file "${case_dir}/lock-held"
run_in file "${backup_sh}"
: > "${case_dir}/lock-release"
wait "${br_holder}"
expect_rc 1
if [[ "${err}" == *'init lock'* ]]; then ok "${case_label}: stderr says the init lock is held"; else bad "${case_label}: stderr should say the init lock is held" "$(dump_case)"; fi
expect_eq "nothing made and no maintenance:mode call" "|status --output=json" "$(br_backups_now)|$(occ_brief)"
new_br_case "the database is not MySQL or MariaDB"
br_set dbtype sqlite3
run_in file "${backup_sh}"
expect_rc 1
new_br_case "clouve-backups is another user's"
mkdir -m 700 "${br_backups}"
FAKE_BR_FOREIGN=clouve-backups
run_in file "${backup_sh}"
expect_rc 1
if [[ "${err}" == *"${br_backups} is not root's, so something else made it"* ]]; then ok "${case_label}: stderr says it is not root's"; else bad "${case_label}: stderr should say clouve-backups is not root's" "$(dump_case)"; fi
expect_eq "nothing made" "" "$(br_backups_now)"
new_br_case "clouve-backups is a symbolic link"
mkdir -p "${case_dir}/elsewhere"
ln -s "${case_dir}/elsewhere" "${br_backups}"
run_in file "${backup_sh}"
expect_rc 1
expect_eq "nothing was written there" "" "$(ls -A "${case_dir}/elsewhere")"
if [[ "${err}" == *'clouve-backups is not a folder (it is a link or a file)'* ]]; then ok "${case_label}: stderr says it is a link or a file"; else bad "${case_label}: stderr should say clouve-backups is a link or a file" "$(dump_case)"; fi
for spec in '--bogus' '--list --with-data' '--with-data extra'; do
  new_br_case "usage: ${spec}"
  read -ra br_args <<< "${spec}"
  run_in file "${backup_sh}" -- "${br_args[@]}"
  expect_rc 1
  if [[ "${err}" == *'Usage: backup.sh [--with-data] [--no-maintenance]'* ]]; then ok "${case_label}: stderr shows the usage"; else bad "${case_label}: stderr should show the usage" "$(dump_case)"; fi
  expect_eq "nothing was called" 0 "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
done
new_br_case "--help"
run_in file "${backup_sh}" -- --help
expect_rc 0
if [[ "${out}" == 'Usage: backup.sh [--with-data] [--no-maintenance]'* ]]; then ok "${case_label}: the usage is on stdout"; else bad "${case_label}: the usage should be on stdout" "$(dump_case)"; fi

section "backup.sh: the database settings"
br_host_cases=(
  'nextcloud-mariadb:3307|host=nextcloud-mariadb port=3307 socket=-'
  'localhost:/run/mysqld/mysqld.sock|host=localhost port=- socket=/run/mysqld/mysqld.sock'
  '[::1]:3306|host=::1 port=3306 socket=-'
  '10.0.3.4|host=10.0.3.4 port=- socket=-'
)
for spec in "${br_host_cases[@]}"; do
  new_br_case "dbhost ${spec%%|*}"
  br_set dbhost "${spec%%|*}"
  run_in file "${backup_sh}"
  expect_rc 0
  expect_eq "the options file" "mariadb-dump-cnf mode=600 dir=700 ${spec#*|} user=nextcloud password=ok" "$(fake_calls mariadb-dump-cnf)"
done
new_br_case "an upgrade is pending: the backup holds config.php's version, not the code's"
br_set version 34.0.9.1
run_in file "${backup_sh}"
expect_rc 0
expect_eq "the manifest's version and versionstring are the data's" "34.0.9.1 34.0.9" "$(jq -r '"\(.version) \(.versionstring)"' "${br_backups}/${br_n0}/manifest.json" 2> /dev/null)"
new_br_case "an empty database password"
br_set dbpassword ''
run_in file "${backup_sh}"
expect_rc 0
expect_eq "the options file holds the empty password" "mariadb-dump-cnf mode=600 dir=700 host=nextcloud-mariadb port=- socket=- user=nextcloud password=ok" "$(fake_calls mariadb-dump-cnf)"
new_br_case "a database name that would be read as an option"
br_set dbname '-x'
run_in file "${backup_sh}"
expect_rc 1
if [[ "${err}" == *'dbname in config.php'* ]]; then ok "${case_label}: stderr says what is wrong with dbname"; else bad "${case_label}: stderr should name dbname" "$(dump_case)"; fi
expect_eq "no dump" 0 "$(call_count mariadb-dump)"
new_br_case "NC_OCC replaces the occ command"
printf '#!/bin/bash\nexec php "%s/occ" --no-interaction --no-warnings "$@"\n' "${br_www}" > "${case_dir}/my-occ"
chmod +x "${case_dir}/my-occ"
run_in file "${backup_sh}" NC_OCC="${case_dir}/my-occ"
expect_rc 0
expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:mode --off'
expect_eq "occ did not go through the default sudo -u www-data" 0 "$(fake_calls sudo | grep -c '/occ' || true)"

section "backup.sh: datadirectory, the init lock, and folders www-data renames or swaps while it runs"
new_br_case "datadirectory is another folder: it refuses (exit 1) and writes nothing there"
mkdir -p "${case_dir}/elsewhere"
br_set datadirectory "${case_dir}/elsewhere"
run_in file "${backup_sh}"
expect_rc 1
expect_eq "nothing in that folder, no backup, no occ call" "||" "$(ls -A "${case_dir}/elsewhere")|$(br_backups_now)|$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ' | sed 's/^0$//')"
if [[ "${err}" == *"this works only with ${br_data}"* ]]; then ok "${case_label}: stderr says only ${br_data} will do"; else bad "${case_label}: stderr should say it works only with the data folder" "$(dump_case)"; fi
new_br_case "the data folder is a link to another folder: it refuses (exit 1)"
mv "${br_data}" "${case_dir}/realdata"
ln -s "${case_dir}/realdata" "${br_data}"
run_in file "${backup_sh}"
expect_rc 1
expect_eq "nothing was written where the link points" no "$([ -e "${case_dir}/realdata/clouve-backups" ] && echo yes || echo no)"
if [[ "${err}" == *'is not a folder (it is missing, or a link)'* ]]; then ok "${case_label}: stderr says the data folder is a link"; else bad "${case_label}: stderr should say the data folder is a link" "$(dump_case)"; fi
new_br_case "the init lock is a named pipe: it refuses at once (exit 1)"
rm -f "${br_www}/nextcloud-init-sync.lock"
mkfifo "${br_www}/nextcloud-init-sync.lock"
br_t=${EPOCHSECONDS}
# bounded, so a script that waited on the pipe would fail here instead of hanging the suite
run_script NC_ROOT="${br_www}" -- timeout 20 "${backup_sh}"
check_br_password
expect_rc 1
if [ $((EPOCHSECONDS - br_t)) -le 3 ]; then ok "${case_label}: it did not wait on the pipe"; else bad "${case_label}: it took $((EPOCHSECONDS - br_t)) s"; fi
if [[ "${err}" == *'is not a plain file'* ]]; then ok "${case_label}: stderr says the lock is not a plain file"; else bad "${case_label}: stderr should say the lock is not a plain file" "$(dump_case)"; fi
expect_eq "nothing made, and maintenance mode untouched" "|off" "$(br_backups_now)|$(br_now_maint)"
for when in before new; do
  new_br_case "clouve-backups ($([ "${when}" = before ] && echo 'there before the run' || echo 'made by the run')) is swapped for another folder during the dump: the backup goes into the one it checked"
  if [ "${when}" = before ]; then mkdir -m 700 "${br_backups}"; fi
  FAKE_BR_SWAP_AT=dump
  FAKE_BR_SWAP_CMD="mv $(printf %q "${br_backups}") $(printf %q "${br_backups}.moved") && mkdir -m 700 $(printf %q "${br_backups}")"
  run_in file "${backup_sh}"
  expect_rc 0
  expect_eq "the swap happened during the dump" "br-swap at dump" "$(fake_calls br-swap)"
  expect_eq "the folder put in its place got nothing" "" "$(ls -A "${br_backups}" 2> /dev/null)"
  expect_eq "the backup is whole, in the folder it checked" "SHA256SUMS apps.tar.gz config.tar.gz database.sql.gz manifest.json|ok" \
    "$(names_in "${br_backups}.moved/${br_n0}")|$(cd "${br_backups}.moved/${br_n0}" 2> /dev/null && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1 && echo ok)"
  expect_eq "its marker was there, locked, while the dump ran, and is gone; maintenance mode is off" "mariadb-dump-state maintenance=on backup-marker=locked:${br_n0} restore-marker=absent|no|off" \
    "$(fake_calls mariadb-dump-state)|$([ -e "${br_backups}.moved/BACKUP-IN-PROGRESS" ] && echo yes || echo no)|$(br_now_maint)"
done
new_br_case "clouve-backups is swapped for another folder while occ status runs, after it was checked and before anything is written: everything goes into the one it checked"
mkdir -m 700 "${br_backups}"
FAKE_BR_SWAP_AT=occ-status
FAKE_BR_SWAP_CMD="mv $(printf %q "${br_backups}") $(printf %q "${br_backups}.moved") && mkdir -m 700 $(printf %q "${br_backups}")"
run_in file "${backup_sh}" -- --with-data
expect_rc 0
expect_eq "the swap happened while occ status ran" "br-swap at occ-status" "$(fake_calls br-swap)"
expect_eq "the folder put in its place got nothing" "" "$(ls -A "${br_backups}" 2> /dev/null)"
expect_eq "the backup is whole, in the folder it checked, and its marker is gone from there" "SHA256SUMS apps.tar.gz config.tar.gz data.tar.gz database.sql.gz manifest.json|ok|no" \
  "$(names_in "${br_backups}.moved/${br_n0}")|$(cd "${br_backups}.moved/${br_n0}" 2> /dev/null && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1 && echo ok)|$([ -e "${br_backups}.moved/BACKUP-IN-PROGRESS" ] && echo yes || echo no)"
expect_eq "the marker's temporary file was made, opened and locked in the folder it checked, never in the one put in its place" \
  "flock-fd-file 8 /var/www/html/data/clouve-backups.moved/.BACKUP-IN-PROGRESS.XXXXXX" \
  "$(fake_calls flock-fd-file | grep '^flock-fd-file 8 ' | sed -E 's/(\.BACKUP-IN-PROGRESS\.)[A-Za-z0-9]{6}$/\1XXXXXX/')"
new_br_case "the data folder is swapped for a link during the dump: data.tar.gz holds the data folder it checked"
mkdir -p "${case_dir}/outside"
printf 'not the users\n' > "${case_dir}/outside/secret.txt"
FAKE_BR_SWAP_AT=dump
FAKE_BR_SWAP_CMD="mv $(printf %q "${br_data}") $(printf %q "${br_www}/data.moved") && ln -s $(printf %q "${case_dir}/outside") $(printf %q "${br_data}")"
run_in file "${backup_sh}" -- --with-data
expect_rc 0
expect_eq "the swap happened during the dump" "br-swap at dump" "$(fake_calls br-swap)"
members="$(tar -tzf "${br_www}/data.moved/clouve-backups/${br_n0}/data.tar.gz" 2> /dev/null | sort)"
if grep -qxF ./alice/files/a.txt <<< "${members}"; then ok "${case_label}: data.tar.gz has alice's file"; else bad "${case_label}: data.tar.gz lacks alice's file" "${members}"; fi
if grep -q 'secret' <<< "${members}"; then bad "${case_label}: data.tar.gz holds the folder the link points to" "${members}"; else ok "${case_label}: data.tar.gz has nothing from the folder the link points to"; fi
expect_eq "nothing was written where the link points" "secret.txt" "$(ls -A "${case_dir}/outside")"
new_br_case "a link that www-data put in the data folder goes into data.tar.gz as a link, not what it points to"
mkdir -p "${case_dir}/outside"
printf 'not the users\n' > "${case_dir}/outside/secret.txt"
ln -s "${case_dir}/outside" "${br_data}/evil"
run_in file "${backup_sh}" -- --with-data
expect_rc 0
members="$(tar -tvzf "${br_backups}/${br_n0}/data.tar.gz" 2> /dev/null)"
if grep -qE '^l.* \./evil -> ' <<< "${members}"; then ok "${case_label}: ./evil is in data.tar.gz as a link"; else bad "${case_label}: ./evil should be in data.tar.gz as a link" "${members}"; fi
if grep -q 'secret' <<< "${members}"; then bad "${case_label}: data.tar.gz holds what the link points to" "${members}"; else ok "${case_label}: data.tar.gz has nothing from what the link points to"; fi

section "backup.sh: a script cut off in transit runs nothing"
new_br_case "half of backup.sh on stdin"
if [ -f "${backup_sh}" ]; then
  head -c "$(( $(wc -c < "${backup_sh}") / 2 ))" "${backup_sh}" > "${case_dir}/half.sh"
  run_script NC_ROOT="${br_www}" -- "${BASH}" -s < "${case_dir}/half.sh"
  expect_eq "no occ call, no PHP, no dump" "0 0 0" "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ') $(call_count php-r) $(call_count mariadb-dump)"
  expect_eq "no backup and maintenance mode untouched" "|off" "$(br_backups_now)|$(br_now_maint)"
else
  bad "backup.sh exists"
fi

section "backup.sh --list"
new_br_case "--list"
br_make_backup
FAKE_NOW="@$((br_t0 + 60))"
br_make_backup --with-data
mkdir -m 700 "${br_backups}/20270115-090000"                  # cut off before its checksums
printf 'x' > "${br_backups}/20270115-090000/database.sql.gz"
mkdir -m 700 "${br_backups}/.not-a-backup" "${br_backups}/notes"
: > "${br_backups}/RESTORE-IN-PROGRESS.old"
sum_before="$(br_tree_sum)"
run_in file "${backup_sh}" -- --list
expect_rc 0
list_re="^${br_n0}  [0-9.]+ (B|KB|MB|GB)  with_data=false  35\\.0\\.2\$"
mapfile -t br_lines <<< "${out}"
expect_eq "three lines, one per backup" 3 "${#br_lines[@]}"
if [[ "${br_lines[0]:-}" =~ ${list_re} ]]; then ok "${case_label}: the config-only backup: name, size, with_data=false, versionstring"; else bad "${case_label}: line 1" "${out}"; fi
if [[ "${br_lines[1]:-}" =~ ^$(br_name $((br_t0 + 60)))\ \ [0-9.]+\ (B|KB|MB|GB)\ \ with_data=true\ \ 35\.0\.2$ ]]; then ok "${case_label}: the backup with data"; else bad "${case_label}: line 2" "${out}"; fi
if [[ "${br_lines[2]:-}" == '20270115-090000  '*'  INCOMPLETE' ]]; then ok "${case_label}: the folder without SHA256SUMS is INCOMPLETE"; else bad "${case_label}: line 3" "${out}"; fi
expect_eq "it changed nothing" "${sum_before}" "$(br_tree_sum)"
expect_eq "it needed no occ" 0 "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
new_br_case "--list with no backups yet"
run_in stdin "${backup_sh}" -- --list
expect_rc 0
if [[ "${out}" == *'no backups'* ]]; then ok "${case_label}: it says there are none"; else bad "${case_label}: it should say there are no backups" "$(dump_case)"; fi
expect_eq "it made no folder" no "$([ -e "${br_backups}" ] && echo yes || echo no)"

section "restore.sh: the file"
expect_script_file "${restore_sh}" restore.sh
if [ -f "${restore_sh}" ]; then expect_in_container_header "${restore_sh}" restore.sh; fi

# br_change_after_backup: what changes on the case's Nextcloud after its backup was made: alice's file, a new file, a new app,
# a new file in config/ and config.php itself
br_change_after_backup() {
  printf 'changed after the backup\n' > "${br_data}/alice/files/a.txt"
  printf 'new\n' > "${br_data}/alice/files/new.txt"
  mkdir -p "${br_www}/custom_apps/newapp/appinfo"
  printf '<info/>\n' > "${br_www}/custom_apps/newapp/appinfo/info.xml"
  printf '<?php\n' > "${br_www}/config/extra.config.php"
  printf '<?php\n$CONFIG = array (\n  %s => %s,\n);\n// the live one\n' "'instanceid'" "'oc123abc'" > "${br_www}/config/config.php"
}

# br_restore [how] [args...]: restore.sh --backup <the case's first backup> --yes-replace-current-data args... (how: file or stdin)
br_restore() {
  local how="${1:-file}"
  [ "$#" -gt 0 ] && shift
  run_in "${how}" "${restore_sh}" -- --backup "${br_n0}" --yes-replace-current-data "$@"
}

# expect_restore_marker <present|absent> [name]
expect_restore_marker() {
  if [ "$1" = absent ]; then expect_eq "no RESTORE-IN-PROGRESS marker" absent "$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)"
  else expect_eq "the RESTORE-IN-PROGRESS marker is there and names ${2}" "present:${2}" "$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && printf 'present:%s' "$(head -n 1 "${br_backups}/RESTORE-IN-PROGRESS")" || echo absent)"; fi
}

# br_as: the last run's .as log (who ran each shimmed command), with %q's backslashes dropped and the random part of
# config/.config.php.<12 hex> names written HEX
br_as() { sed -E 's/\\//g; s/\.config\.php\.[0-9a-f]{12}/.config.php.HEX/g' "${FAKE_ARGV_LOG}.as"; }

# expect_www_data_only: after a full restore, root ran no command that changes files (rm, find, tar, cp, mv, chmod,
# chown, ln, mkdir, touch, tee, install) on a path in the case's /var/www/html, and no chown ran at all. config.php
# was written by www-data: the backup's copy and the merge each into a new file in config/ (noclobber), the merge
# given the old file's mode and renamed over it, and the copy removed.
expect_www_data_only() {
  local as want
  as="$(br_as)"
  expect_eq "root ran nothing that changes files in config/, custom_apps/, themes/ or the data folder" "" \
    "$(grep -E '^root (rm|find|tar|cp|mv|chmod|chown|ln|mkdir|touch|tee|install) ' <<< "${as}" | grep -F "${br_www}/" || true)"
  expect_eq "no chown ran: www-data made every file it extracted" 0 "$(call_count chown)"
  for want in "www-data chmod --reference=${br_www}/config/config.php -- ${br_www}/config/.config.php.HEX|gave the new config.php the old one's mode" \
    "www-data mv -f -- ${br_www}/config/.config.php.HEX ${br_www}/config/config.php|renamed it over config.php" \
    "www-data rm -f -- ${br_www}/config/.config.php.HEX|removed its copy of the backup's config.php"; do
    if grep -qxF -- "${want%|*}" <<< "${as}"; then ok "${case_label}: www-data ${want#*|}"; else bad "${case_label}: www-data should have ${want#*|}: ${want%|*}" "${as}"; fi
  done
  expect_eq "www-data wrote the backup's config.php and the merge, each into a new file in config/" 2 \
    "$(fake_calls sudo | grep -cE '^sudo user=www-data .* www_write /var/www/html/config/\.config\.php\.[0-9a-f]{12}$' || true)"
}

section "restore.sh: nothing happens without --yes-replace-current-data (exit 1)"
for how in file stdin; do
  new_br_case "not confirmed (${how})"
  br_make_backup --with-data
  br_change_after_backup
  FAKE_NOW="@$((br_t0 + 60))"
  : > "${FAKE_SQL_LOG}"
  sum_before="$(br_tree_sum)"
  run_in "${how}" "${restore_sh}" -- --backup "${br_n0}"
  expect_rc 1
  expect_eq "the tree, the database and maintenance mode are as they were (one checksum over all of them)" "${sum_before}" "$(br_tree_sum)"
  expect_eq "occ was only asked for the status" "status --output=json" "$(occ_brief)"
  expect_eq "no database client ran" "0 0" "$(call_count mariadb) $(call_count mariadb-dump)"
  for phrase in "every table of the database nextcloud" "config/config.php" "custom_apps/ and themes/" "everything in ${br_data} but clouve-backups" \
    "Nothing was changed" "--yes-replace-current-data"; do
    if [[ "${out}" == *"${phrase}"* ]]; then ok "${case_label}: stdout says: ${phrase}"; else bad "${case_label}: stdout should say: ${phrase}" "$(dump_case)"; fi
  done
  expect_restore_marker absent
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
done

section "restore.sh: a backup it can't use (exit 2)"
# br_unusable <label> <setup command> <the message> [restore.sh args...]: restore.sh refuses the backup with that message
# and changes nothing
br_unusable() {
  local label="$1" setup="$2" want="$3" sum
  shift 3
  new_br_case "${label}"
  br_make_backup --with-data
  eval "${setup}"
  FAKE_NOW="@$((br_t0 + 60))"
  : > "${FAKE_SQL_LOG}"
  sum="$(br_tree_sum)"
  if [ "$#" -gt 0 ]; then run_in file "${restore_sh}" -- "$@"; else br_restore file; fi
  expect_rc 2
  if [[ "${err}" == *"${want}"* ]]; then ok "${case_label}: stderr says: ${want}"; else bad "${case_label}: stderr should say: ${want}" "$(dump_case)"; fi
  expect_eq "nothing changed" "${sum}" "$(br_tree_sum)"
  expect_restore_marker absent
}
br_unusable "a damaged archive" 'printf x >> "${br_last}/config.tar.gz"' 'damaged: sha256sum -c says config.tar.gz: FAILED'
br_unusable "no such backup" ':' 'there is no backup 20991231-000000' --backup 20991231-000000 --yes-replace-current-data
br_unusable "a name that is not a backup's" ':' 'is not the name of a backup' --backup ../../etc --yes-replace-current-data
br_unusable "the name .. (a folder that is there)" ':' 'is not the name of a backup' --backup .. --yes-replace-current-data
br_unusable "a backup without SHA256SUMS (cut off while it was made)" 'rm -f "${br_last}/SHA256SUMS"' 'has no SHA256SUMS, so it was cut off'
br_unusable "a backup without manifest.json" 'rm -f "${br_last}/manifest.json"; br_resum "${br_last}"' 'has no manifest.json'
br_unusable "SHA256SUMS names a file outside the backup" 'printf "%s  ../../../etc/hostname\n" "$(printf x | sha256sum | cut -c1-64)" >> "${br_last}/SHA256SUMS"' 'names a file that is no part of a backup'
br_unusable "SHA256SUMS leaves an archive out (it would go in unchecked)" 'grep -v " apps.tar.gz$" "${br_last}/SHA256SUMS" > "${case_dir}/s" && cat "${case_dir}/s" > "${br_last}/SHA256SUMS"' 'does not cover apps.tar.gz'
br_unusable "an archive missing from the folder" 'rm -f "${br_last}/apps.tar.gz"' 'has no file apps.tar.gz'
br_unusable "manifest.json and SHA256SUMS disagree about the users' files" 'br_manifest_set "${br_last}" ".with_data = false"' 'disagree about data.tar.gz'
br_unusable "the backup folder is a symbolic link" 'cp -a "${br_last}" "${case_dir}/copy" && rm -rf "${br_last}" && ln -s "${case_dir}/copy" "${br_last}"' 'is not a folder'
br_unusable "a manifest version that is not a version" 'br_manifest_set "${br_last}" ".version = \"35.0.2.2; rm -rf /\""' 'no version that is a version'
br_unusable "an archive of the backup is another user's" 'FAKE_BR_FOREIGN=config.tar.gz' "config.tar.gz of the backup ${br_n0} is not root's, so restore.sh does not trust it"
br_unusable "SHA256SUMS is another user's" 'FAKE_BR_FOREIGN=SHA256SUMS' "SHA256SUMS of the backup ${br_n0} is not root's, so restore.sh does not trust it"
br_unusable "the backup's folder is another user's" "FAKE_BR_FOREIGN=${br_n0}" "/data/clouve-backups/${br_n0}) is not root's, so restore.sh does not trust it"
br_unusable "clouve-backups is another user's" 'FAKE_BR_FOREIGN=clouve-backups' "/data/clouve-backups is not root's, so something else made it"
new_br_case "a backup without the users' files, and no --skip-data"
br_make_backup
FAKE_NOW="@$((br_t0 + 60))"
sum_before="$(br_tree_sum)"
br_restore file
expect_rc 2
if [[ "${err}" == *"this backup has no users' files; add --skip-data to restore the rest"* ]]; then ok "${case_label}: stderr says the brief's sentence"; else bad "${case_label}: stderr should say the brief's sentence" "$(dump_case)"; fi
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"

section "restore.sh: the versions (exit 3)"
for spec in '36.0.0.1|newer than the code' '33.0.0.1|two majors older' '35.0.3.1|a newer patch'; do
  new_br_case "a backup from ${spec%%|*} (${spec#*|})"
  br_make_backup
  br_manifest_set "${br_last}" ".version = \"${spec%%|*}\""
  FAKE_NOW="@$((br_t0 + 60))"
  sum_before="$(br_tree_sum)"
  br_restore file --skip-data
  expect_rc 3
  expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
  if [[ "${err}" == *"${spec%%|*}"* && "${err}" == *'35.0.2.2'* ]]; then ok "${case_label}: stderr gives both versions"; else bad "${case_label}: stderr should give both versions" "$(dump_case)"; fi
done
new_br_case "versions compare as numbers: a 35.0.9.1 backup is older than 35.0.10.1 code"
br_make_backup
br_manifest_set "${br_last}" '.version = "35.0.9.1"'
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_CODE_VERSION=35.0.10.1
br_restore file --skip-data
expect_rc 0
expect_eq "occ upgrade ran" 1 "$(occ_brief | grep -cx upgrade || true)"
for v in 35.0.1.1 34.0.9.1; do
  new_br_case "a backup from ${v}: occ upgrade runs, with maintenance mode still on"
  br_make_backup
  br_manifest_set "${br_last}" ".version = \"${v}\""
  FAKE_NOW="@$((br_t0 + 60))"
  br_restore file --skip-data
  expect_rc 0
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nupgrade\ndb:add-missing-indices\ndb:add-missing-columns\ndb:add-missing-primary-keys\nmaintenance:repair --include-expensive\nmaintenance:data-fingerprint\nmemcache:redis:command FLUSHDB\nmaintenance:mode --off'
  expect_eq "occ upgrade found maintenance mode on (occ runs a pending upgrade in maintenance mode, and the Updater keeps a maintenance mode it found on)" "br-occ upgrade maintenance=on backup-marker=absent restore-marker=present:${br_n0}" "$(fake_calls 'br-occ upgrade')"
  expect_eq "the steps after it and the fingerprint ran in maintenance mode too" "on on on on on" \
    "$(fake_calls 'br-occ (db:add-missing-[a-z-]+|maintenance:repair|maintenance:data-fingerprint)' | grep -oE 'maintenance=[a-z]+' | cut -d= -f2 | tr '\n' ' ' | sed 's/ $//')"
  expect_restore_marker absent
  expect_eq "maintenance mode is off at the end" off "$(br_now_maint)"
done

section "restore.sh: a full restore, the brief's case, run both ways"
for how in file stdin; do
  new_br_case "a full restore (${how})"
  chmod 640 "${br_www}/config/upgrade-disable-web.config.php" "${br_data}/alice/files/a.txt"
  chmod 750 "${br_www}/custom_apps/calendar" "${br_data}/alice/files"
  br_modes_before="$(for f in config/upgrade-disable-web.config.php custom_apps/calendar custom_apps/calendar/appinfo/info.xml data/alice/files data/alice/files/a.txt; do printf '%s ' "$(mode_of "${br_www}/${f}")"; done)"
  br_make_backup --with-data
  br_change_after_backup
  backups_before="$(snapshot "${br_backups}")"
  chmod 640 "${br_www}/config/config.php"
  FAKE_NOW="@$((br_t0 + 60))"
  : > "${FAKE_SQL_LOG}"
  br_restore "${how}"
  expect_rc 0
  expect_mode "${br_www}/config/config.php" 640 "the new config.php, like the one it replaced,"
  expect_eq "the files and folders www-data extracted have the modes in the archives (tar -p)" "${br_modes_before}" \
    "$(for f in config/upgrade-disable-web.config.php custom_apps/calendar custom_apps/calendar/appinfo/info.xml data/alice/files data/alice/files/a.txt; do printf '%s ' "$(mode_of "${br_www}/${f}")"; done)"
  expect_www_data_only
  expect_eq "the database: every table the schema lists is dropped, then the dump is imported" \
    $'SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()\nSET FOREIGN_KEY_CHECKS=0\nDROP TABLE `oc_appconfig`\nDROP TABLE `oc_filecache`\nDROP TABLE `oc_users`\nIMPORT -- dump of nextcloud' \
    "$(cat "${FAKE_SQL_LOG}")"
  expect_eq "config.php is the merge of the backup's (it ends with // merged)" "// merged" "$(tail -n 1 "${br_www}/config/config.php")"
  expect_eq "and the merge started from the backup's config.php, not the live one" "no" "$(grep -q 'the live one' "${br_www}/config/config.php" && echo yes || echo no)"
  expect_eq "the other files in config/ are the backup's" "config.php upgrade-disable-web.config.php" "$(names_in "${br_www}/config")"
  expect_eq "custom_apps/ is the backup's" "calendar" "$(names_in "${br_www}/custom_apps")"
  expect_eq "alice's file is back" "alice's file" "$(cat "${br_data}/alice/files/a.txt")"
  expect_eq "the file made after the backup is gone" no "$([ -e "${br_data}/alice/files/new.txt" ] && echo yes || echo no)"
  expect_eq ".ncdata, .htaccess and the log are back" "yes yes yes" "$([ -f "${br_data}/.ncdata" ] && echo yes) $([ -f "${br_data}/.htaccess" ] && echo yes) $([ -f "${br_data}/nextcloud.log" ] && echo yes)"
  expect_eq "the previews, which the backup leaves out, are gone (Nextcloud makes them again)" no "$([ -e "${br_data}/appdata_oc123/preview" ] && echo yes || echo no)"
  expect_eq "clouve-backups is untouched" "${backups_before}" "$(snapshot "${br_backups}")"
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:data-fingerprint\nmemcache:redis:command FLUSHDB\nmaintenance:mode --off\napp:list --enabled --output=json\nfiles:scan --all'
  expect_eq "the marker came before maintenance mode, and it named the backup" "br-occ maintenance:mode --on maintenance=off backup-marker=absent restore-marker=present:${br_n0}" "$(fake_calls 'br-occ maintenance:mode --on')"
  expect_eq "the database was replaced in maintenance mode with the marker in place" "maintenance=on backup-marker=absent restore-marker=present:${br_n0}" "$(fake_calls mariadb-import | sed -E 's/.* (maintenance=)/\1/')"
  expect_eq "the fingerprint was set and the cache cleared in maintenance mode, and files:scan ran after maintenance mode was off" "on on off" \
    "$(fake_calls 'br-occ maintenance:data-fingerprint' | grep -oE 'maintenance=[a-z]+' | cut -d= -f2) $(fake_calls 'br-occ memcache:redis:command FLUSHDB' | grep -oE 'maintenance=[a-z]+' | cut -d= -f2) $(fake_calls 'br-occ files:scan' | grep -oE 'maintenance=[a-z]+' | cut -d= -f2)"
  expect_restore_marker absent
  expect_eq "maintenance mode is off" off "$(br_now_maint)"
  expect_eq "the restore is the last line" "[nextcloud/restore] done: ${br_n0}" "$(tail -n 1 "${case_dir}/stdout")"
  expect_eq "the database clients read the options file with this server's settings" "mariadb-cnf mode=600 dir=700 host=nextcloud-mariadb port=- socket=- user=nextcloud password=ok" "$(fake_calls mariadb-cnf | sort -u)"
  expect_eq "the settings the image manages were kept in a mode 600 file" "php-r-managed stdout=file mode=600" "$(fake_calls php-r-managed)"
  managed_bytes="$(printf 'a:2:{s:6:"dbname";s:9:"nextcloud";s:6:"dbhost";s:17:"nextcloud-mariadb";}' | wc -c | tr -d ' ')"
  expect_eq "and the merge read exactly them on stdin, from that mode 600 file" $'php-r-merge stdin=file mode=600\nphp-r-merge stdin_bytes='"${managed_bytes}" "$(fake_calls php-r-merge)"
  expect_php_as_www_data
  expect_eq "each occ call went through sudo -n -u www-data" "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')" "$(fake_calls sudo | grep -c '^sudo user=www-data preserve=- NC_PASS=unset :: php /var/www/html/occ --no-interaction --no-warnings ' || true)"
  expect_eq "www-data cleared config/, custom_apps/, themes/ and the data folder (but clouve-backups)" \
    "www-data find ${br_www}/config -mindepth 1 -maxdepth 1 ! -name config.php -exec rm -rf -- {} +
www-data find ${br_www}/custom_apps -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
www-data find ${br_www}/themes -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
www-data find ${br_data} -mindepth 1 -maxdepth 1 ! -name clouve-backups -exec rm -rf -- {} +" \
    "$(grep -E '^[a-z-]+ find .* -exec rm -rf ' "${FAKE_ARGV_LOG}.as" | sed 's/\\//g')"
  expect_eq "and extracted the archives from its stdin, which root opened" \
    "www-data tar -xzpf - -C ${br_www} --anchored --exclude=config/config.php
www-data tar -xzpf - -C ${br_www}
www-data tar -xzpf - -C ${br_data} --anchored --exclude=./clouve-backups" \
    "$(grep -E '^[a-z-]+ tar -x' "${FAKE_ARGV_LOG}.as" | grep -v ' -xzOf ' | sed 's/\\//g')"
  expect_eq "tar read config.tar.gz twice (root took config.php out; www-data the rest), then apps.tar.gz and data.tar.gz" \
    $'tar-file untar config.tar.gz\ntar-file untar config.tar.gz\ntar-file untar apps.tar.gz\ntar-file untar data.tar.gz' "$(fake_calls tar-file)"
  expect_eq "the image's init lock was taken, without waiting" "flock-fd -n 9" "$(fake_calls flock-fd)"
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
done
new_br_case "Team folders are scanned too when the app is enabled"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_GROUPFOLDERS=enabled
br_restore file
expect_rc 0
expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:data-fingerprint\nmemcache:redis:command FLUSHDB\nmaintenance:mode --off\napp:list --enabled --output=json\nfiles:scan --all\ngroupfolders:scan --all'
new_br_case "app:list fails: the restore finishes, and says Team folders were not scanned"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_GROUPFOLDERS=enabled
FAKE_BR_APPLIST_FAIL=1
br_restore file
expect_rc 0
expect_restore_marker absent
expect_eq "no groupfolders:scan" 0 "$(occ_brief | grep -c groupfolders || true)"
if [[ "${err}" == *'occ.sh groupfolders:scan --all'* ]]; then ok "${case_label}: stderr says what to run"; else bad "${case_label}: stderr should name occ.sh groupfolders:scan --all" "$(dump_case)"; fi
new_br_case "maintenance mode on before the restore: it is off once the restore is done"
br_make_backup --with-data
printf 'on\n' > "${FAKE_BR_STATE}/maintenance"
FAKE_NOW="@$((br_t0 + 60))"
br_restore file
expect_rc 0
expect_occ_brief $'status --output=json\nmaintenance:data-fingerprint\nmemcache:redis:command FLUSHDB\nmaintenance:mode --off\napp:list --enabled --output=json\nfiles:scan --all'
expect_eq "maintenance mode is off and the marker gone" "off absent" "$(br_now_maint) $([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)"
new_br_case "the cache can't be cleared: a warning that says what to run, and the restore finishes"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_CACHE_FAIL=1
br_restore file
expect_rc 0
expect_eq "maintenance mode is off and the marker gone" "off absent" "$(br_now_maint) $([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)"
expect_eq "files:scan still ran" 1 "$(occ_brief | grep -c '^files:scan --all$' || true)"
if [[ "${err}" == *'WARNING: occ memcache:redis:command FLUSHDB failed'*'run occ.sh memcache:distributed:clear'* ]]; then ok "${case_label}: stderr warns and says what to run"; else bad "${case_label}: stderr should warn and name occ.sh memcache:distributed:clear" "$(dump_case)"; fi

section "restore.sh --skip-data"
new_br_case "--skip-data leaves the users' files alone and runs no scan"
br_make_backup --with-data
br_change_after_backup
data_before="$(snapshot "${br_data}" | grep -v '/clouve-backups')"
FAKE_NOW="@$((br_t0 + 60))"
br_restore stdin --skip-data
expect_rc 0
expect_eq "the users' files are untouched" "${data_before}" "$(snapshot "${br_data}" | grep -v '/clouve-backups')"
expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:data-fingerprint\nmemcache:redis:command FLUSHDB\nmaintenance:mode --off'
expect_eq "data.tar.gz was not read, and nothing ran on the data folder" "0 0" "$(fake_calls tar-file | grep -c 'data.tar.gz' || true) $(grep -E '^[a-z-]+ (find|rm|tar) ' "${FAKE_ARGV_LOG}.as" | grep -cF "${br_data}" || true)"
expect_eq "config.php is still the backup's merge" "// merged" "$(tail -n 1 "${br_www}/config/config.php")"
expect_restore_marker absent

section "restore.sh: a step that fails after the changes began (exit 4)"
for how in file stdin; do
  new_br_case "the import fails (${how})"
  br_make_backup --with-data
  br_change_after_backup
  FAKE_NOW="@$((br_t0 + 60))"
  br_make_backup --with-data                       # the backup of the current state, made just before the restore
  br_pre="$(br_name $((br_t0 + 60)))"
  FAKE_NOW="@$((br_t0 + 120))"
  FAKE_BR_IMPORT_FAIL=1
  br_restore "${how}"
  expect_rc 4
  expect_restore_marker present "${br_n0}"
  expect_eq "maintenance mode was never turned off" "on|$(printf 'status --output=json\nmaintenance:mode --on')" "$(br_now_maint)|$(occ_brief)"
  if [[ "${err}" == *'step 4'* && "${err}" == *'database'* ]]; then ok "${case_label}: stderr names the step"; else bad "${case_label}: stderr should name step 4, the database" "$(dump_case)"; fi
  if [[ "${err}" == *"restore.sh --backup ${br_pre} --yes-replace-current-data"* ]]; then ok "${case_label}: stderr gives the command that puts the state from before back"; else bad "${case_label}: stderr should name restore.sh --backup ${br_pre}" "$(dump_case)"; fi
  expect_eq "the users' files were not touched yet" "changed after the backup" "$(cat "${br_data}/alice/files/a.txt")"
  expect_eq "no temporary file is left" "" "$(br_tmp_left)"
done
new_br_case "the tables can't be dropped: it stops at step 4, before the import"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_DROP_FAIL=1
br_restore file
expect_rc 4
expect_restore_marker present "${br_n0}"
expect_eq "no import was tried" 0 "$(grep -c '^IMPORT' "${FAKE_SQL_LOG}" || true)"
if [[ "${err}" == *'step 4'* && "${err}" == *'could not drop the tables'* ]]; then ok "${case_label}: stderr names the step"; else bad "${case_label}: stderr should name step 4" "$(dump_case)"; fi
new_br_case "restoring the newest backup fails: the advice names the older one, not the one that failed"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
br_make_backup --with-data
br_newest="$(br_name $((br_t0 + 60)))"
FAKE_NOW="@$((br_t0 + 120))"
FAKE_BR_IMPORT_FAIL=1
run_in file "${restore_sh}" -- --backup "${br_newest}" --yes-replace-current-data
expect_rc 4
if [[ "${err}" == *"The newest other backup is ${br_n0}"* && "${err}" == *"restore.sh --backup ${br_n0} --yes-replace-current-data"* ]]; then ok "${case_label}: it names ${br_n0}"
else bad "${case_label}: the advice should name ${br_n0}" "$(dump_case)"; fi
new_br_case "the files scan fails after maintenance mode is off: the restore is in place, the marker stays"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_SCAN_FAIL=1
br_restore file
expect_rc 4
expect_restore_marker present "${br_n0}"
expect_eq "maintenance mode is off" off "$(br_now_maint)"
if [[ "${err}" == *'files:scan'* && "${err}" == *'maintenance mode is off'* ]]; then ok "${case_label}: stderr says what failed and that maintenance mode is off"; else bad "${case_label}: stderr should say files:scan failed with maintenance mode off" "$(dump_case)"; fi
new_br_case "occ upgrade fails: the marker stays"
br_make_backup
br_manifest_set "${br_last}" '.version = "35.0.1.1"'
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_UPGRADE_FAIL=1
br_restore file --skip-data
expect_rc 4
expect_restore_marker present "${br_n0}"
expect_eq "maintenance mode was never turned off: it is still on" "on|1" "$(br_now_maint)|$(occ_brief | grep -c '^maintenance:mode' || true)"
if [[ "${err}" == *'occ upgrade'* && "${err}" == *'Nextcloud stays closed to its users'* ]]; then ok "${case_label}: stderr names occ upgrade, and says Nextcloud stays closed"; else bad "${case_label}: stderr should name occ upgrade and say Nextcloud stays closed" "$(dump_case)"; fi
new_br_case "a repair after the upgrade fails: a warning, as in the image's post-upgrade hook, and the restore goes on"
br_make_backup
br_manifest_set "${br_last}" '.version = "35.0.1.1"'
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_REPAIR_FAIL=1
br_restore file --skip-data
expect_rc 0
expect_restore_marker absent
if [[ "${err}" == *'WARNING'*'maintenance:repair'* ]]; then ok "${case_label}: stderr warns about the repair"; else bad "${case_label}: stderr should warn about maintenance:repair" "$(dump_case)"; fi
new_br_case "the merge of config.php fails"
br_make_backup --with-data
br_change_after_backup
cfg_before="$(sha256sum < "${br_www}/config/config.php")"
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_PHP_FAIL=merge
br_restore file
expect_rc 4
expect_restore_marker present "${br_n0}"
expect_eq "config.php is the one from before, whole, and no half-written copy is left in config/" "${cfg_before} 0" \
  "$(sha256sum < "${br_www}/config/config.php") $(find "${br_www}/config" -name '.config.php.*' | wc -l | tr -d ' ')"
if [[ "${err}" == *'step 5'* ]]; then ok "${case_label}: stderr names step 5"; else bad "${case_label}: stderr should name step 5" "$(dump_case)"; fi
expect_eq "maintenance mode stays on" on "$(br_now_maint)"
new_br_case "maintenance mode can't be turned on: the marker goes again and nothing is changed"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
: > "${FAKE_SQL_LOG}"
sum_before="$(br_tree_sum)"
FAKE_BR_MAINT_FAIL=on
br_restore file
expect_rc 2
expect_eq "nothing changed, and no marker" "${sum_before}" "$(br_tree_sum)"
expect_restore_marker absent
if [[ "${err}" == *'Nothing was changed: maintenance mode is as it was, and the marker is gone.'* ]]; then ok "${case_label}: stderr says nothing was changed"; else bad "${case_label}: stderr should say nothing was changed" "$(dump_case)"; fi

section "restore.sh: the backup made before puts the previous state back, even when occ can't start"
new_br_case "after a failed import, restoring the backup made before it"
br_make_backup --with-data
br_change_after_backup
FAKE_NOW="@$((br_t0 + 60))"
br_make_backup --with-data
br_pre="$(br_name $((br_t0 + 60)))"
FAKE_NOW="@$((br_t0 + 120))"
FAKE_BR_IMPORT_FAIL=1
br_restore file
expect_rc 4
unset FAKE_BR_IMPORT_FAIL
FAKE_BR_STATUS_FAIL=1                                # the tables are half gone, so occ can't start
br_set maintenance true                              # what config.php says now: the failed restore turned maintenance mode on
run_in file "${restore_sh}" -- --backup "${br_pre}" --yes-replace-current-data
expect_rc 0
expect_restore_marker absent
expect_eq "the users' files are those of the backup made before" "changed after the backup|new" "$(cat "${br_data}/alice/files/a.txt")|$(cat "${br_data}/alice/files/new.txt" 2> /dev/null)"
expect_eq "the code's version came from version.php" 1 "$(fake_calls php-r | grep -c '^php-r code-version ' || true)"
if [[ "${out}${err}" == *'version.php'* ]]; then ok "${case_label}: the output says where the version came from"; else bad "${case_label}: the output should say the version came from version.php" "$(dump_case)"; fi
expect_eq "maintenance mode is off at the end" off "$(br_now_maint)"
new_br_case "a preview while a cut-off restore's marker is there: no advice to back up first, and the two ways out"
br_make_backup --with-data
br_change_after_backup
FAKE_NOW="@$((br_t0 + 60))"
br_make_backup --with-data
br_pre="$(br_name $((br_t0 + 60)))"
FAKE_NOW="@$((br_t0 + 120))"
FAKE_BR_IMPORT_FAIL=1
br_restore file
expect_rc 4
unset FAKE_BR_IMPORT_FAIL
run_in file "${restore_sh}" -- --backup "${br_pre}"
expect_rc 1
if [[ "${out}${err}" == *'Back up the current state first'* ]]; then bad "${case_label}: the preview of another backup should not say to back up first while backup.sh refuses" "$(dump_case)"; else ok "${case_label}: the preview of another backup: no advice to back up first"; fi
if [[ "${out}${err}" == *"A restore of ${br_n0} was cut off"*'backup.sh refuses to run until a restore finishes'*"can't be backed up first"* ]]; then ok "${case_label}: it names the cut-off restore and says why there is no backing up first"; else bad "${case_label}: the preview should name the cut-off restore and say that backup.sh refuses" "$(dump_case)"; fi
if [[ "${out}${err}" == *"Restoring ${br_pre} puts its state in place of the half-restored one"*"run restore.sh --backup ${br_n0} again, with the options it had"* ]]; then ok "${case_label}: and the two ways out: this backup, or the cut-off restore again"; else bad "${case_label}: the preview should give the two ways out" "$(dump_case)"; fi
if [[ "${out}${err}" == *"The newest other backup here is ${br_n0}"* ]]; then ok "${case_label}: and names the newest other backup"; else bad "${case_label}: the preview should name the newest other backup" "$(dump_case)"; fi
if [[ "${out}${err}" == *'Nothing was changed. To restore, run this again with --yes-replace-current-data.'* ]]; then ok "${case_label}: and says how to go ahead"; else bad "${case_label}: the preview should say how to go ahead" "$(dump_case)"; fi
expect_restore_marker present "${br_n0}"
run_in file "${restore_sh}" -- --backup "${br_n0}"
expect_rc 1
if [[ "${out}${err}" == *'Back up the current state first'* ]]; then bad "${case_label}: the preview of the cut-off restore's backup should not say to back up first" "$(dump_case)"; else ok "${case_label}: the preview of the cut-off restore's backup: no advice to back up first"; fi
if [[ "${out}${err}" == *"A restore of ${br_n0} was cut off"*'Restoring it again finishes that restore. To put back the state from before it instead, restore the backup made just before it, if one was made; '"the newest other backup here is ${br_pre}, made "* ]]; then ok "${case_label}: it says that this finishes the cut-off restore, and which backup may put the state before it back"; else bad "${case_label}: the preview should say that this finishes the cut-off restore, and name the newest other backup" "$(dump_case)"; fi
expect_restore_marker present "${br_n0}"
new_br_case "a preview while a cut-off restore's marker is there, with no other backup: it says so, and no advice to back up first"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_IMPORT_FAIL=1
br_restore file
expect_rc 4
unset FAKE_BR_IMPORT_FAIL
run_in file "${restore_sh}" -- --backup "${br_n0}"
expect_rc 1
if [[ "${out}${err}" == *'Back up the current state first'* ]]; then bad "${case_label}: the preview should not say to back up first" "$(dump_case)"; else ok "${case_label}: no advice to back up first"; fi
if [[ "${out}${err}" == *"A restore of ${br_n0} was cut off"*'Restoring it again finishes that restore. There is no other backup here.'* ]]; then ok "${case_label}: it says that this finishes it, and that there is no other backup"; else bad "${case_label}: the preview should say that this finishes it, and that there is no other backup" "$(dump_case)"; fi
expect_restore_marker present "${br_n0}"
new_br_case "occ can't start and no restore was cut off: restore.sh refuses (exit 2)"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_STATUS_FAIL=1
sum_before="$(br_tree_sum)"
br_restore file
expect_rc 2
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"

section "restore.sh: a run that is stopped, and a session that drops"
new_br_case "SIGTERM while the users' files are extracted: it stops there, with the marker and maintenance mode on"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
FAKE_PIDFILE="${case_dir}/pid"
FAKE_BR_KILL_AT=untar-data.tar.gz
FAKE_BR_KILL_SIG=TERM
br_restore file
expect_rc 4
expect_restore_marker present "${br_n0}"
expect_eq "maintenance mode is on" on "$(br_now_maint)"
if [[ "${err}" == *'TERM'* && "${err}" == *'step 7'* ]]; then ok "${case_label}: stderr says it was stopped, and in which step"; else bad "${case_label}: stderr should say SIGTERM stopped step 7" "$(dump_case)"; fi
expect_eq "no temporary file is left" "" "$(br_tmp_left)"
for sig in HUP PIPE; do
  new_br_case "SIG${sig} (the session is gone) during the extraction: the restore goes on to the end"
  br_make_backup --with-data
  br_change_after_backup
  FAKE_NOW="@$((br_t0 + 60))"
  FAKE_PIDFILE="${case_dir}/pid"
  FAKE_BR_KILL_AT=untar-data.tar.gz
  FAKE_BR_KILL_SIG="${sig}"
  br_restore file
  expect_rc 0
  expect_restore_marker absent
  expect_eq "it finished: alice's file is back and maintenance mode is off" "alice's file|off" "$(cat "${br_data}/alice/files/a.txt")|$(br_now_maint)"
  expect_eq "what it printed after the signal went nowhere" no "$(grep -q 'done:' "${case_dir}/stdout" && echo yes || echo no)"
done

section "restore.sh: datadirectory, the init lock, and folders www-data renames, swaps or links"
for kind in elsewhere link; do
  new_br_case "$([ "${kind}" = elsewhere ] && echo 'datadirectory is another folder' || echo 'the data folder is a link'): it refuses (exit 2), nothing changed"
  br_make_backup --with-data
  FAKE_NOW="@$((br_t0 + 60))"
  if [ "${kind}" = elsewhere ]; then
    mkdir -p "${case_dir}/elsewhere"
    br_set datadirectory "${case_dir}/elsewhere"
    want='this works only with'
  else
    mv "${br_data}" "${case_dir}/realdata"
    ln -s "${case_dir}/realdata" "${br_data}"
    want='is not a folder (it is missing, or a link)'
  fi
  : > "${FAKE_SQL_LOG}"
  sum_before="$(br_tree_sum)"
  data_before="$(snapshot "${case_dir}/realdata" "${case_dir}/elsewhere")"
  br_restore file
  expect_rc 2
  expect_eq "nothing changed" "${sum_before}|${data_before}" "$(br_tree_sum)|$(snapshot "${case_dir}/realdata" "${case_dir}/elsewhere")"
  if [[ "${err}" == *"${want}"* ]]; then ok "${case_label}: stderr says: ${want}"; else bad "${case_label}: stderr should say: ${want}" "$(dump_case)"; fi
  expect_eq "no occ call" 0 "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
done
new_br_case "the init lock is a named pipe: the restore refuses at once (exit 2), nothing changed"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
rm -f "${br_www}/nextcloud-init-sync.lock"
mkfifo "${br_www}/nextcloud-init-sync.lock"
: > "${FAKE_SQL_LOG}"
sum_before="$(br_tree_sum)"
br_t=${EPOCHSECONDS}
run_script NC_ROOT="${br_www}" -- timeout 20 "${restore_sh}" --backup "${br_n0}" --yes-replace-current-data
check_br_password
expect_rc 2
if [ $((EPOCHSECONDS - br_t)) -le 3 ]; then ok "${case_label}: it did not wait on the pipe"; else bad "${case_label}: it took $((EPOCHSECONDS - br_t)) s"; fi
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
if [[ "${err}" == *'is not a plain file'* && "${err}" == *'Nothing was changed'* ]]; then ok "${case_label}: stderr says the lock is not a plain file, and nothing was changed"; else bad "${case_label}: stderr should say the lock is not a plain file" "$(dump_case)"; fi
new_br_case "www-data can't write in config/: the restore refuses before it changes anything (exit 2)"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
chmod 555 "${br_www}/config"
: > "${FAKE_SQL_LOG}"
sum_before="$(br_tree_sum)"
br_restore file
expect_rc 2
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
if [[ "${err}" == *"www-data can't write in ${br_www}/config"* ]]; then ok "${case_label}: stderr names the folder"; else bad "${case_label}: stderr should say www-data can't write in config/" "$(dump_case)"; fi
expect_eq "it asked as www-data" 1 "$(br_as | grep -cxF "www-data test -w ${br_www}/config" || true)"
chmod 755 "${br_www}/config"
new_br_case "clouve-backups is swapped for another folder during the import: the restore reads the backup it checked"
br_make_backup --with-data
br_change_after_backup
# a copy of the backup whose config.php and apps say PLANTED, with checksums that pass
mkdir -p "${case_dir}/plant/x/config" "${case_dir}/plant/x/custom_apps/planted"
cp -a "${br_last}" "${case_dir}/plant/"
printf '<?php\n$CONFIG = array (\n);\n// PLANTED\n' > "${case_dir}/plant/x/config/config.php"
tar -czf "${case_dir}/plant/${br_n0}/config.tar.gz" -C "${case_dir}/plant/x" config
tar -czf "${case_dir}/plant/${br_n0}/apps.tar.gz" -C "${case_dir}/plant/x" custom_apps
br_resum "${case_dir}/plant/${br_n0}"
FAKE_NOW="@$((br_t0 + 60))"
FAKE_BR_SWAP_AT=import
FAKE_BR_SWAP_CMD="mv $(printf %q "${br_backups}") $(printf %q "${br_backups}.moved") && mkdir -m 700 $(printf %q "${br_backups}") && cp -a $(printf %q "${case_dir}/plant/${br_n0}") $(printf %q "${br_backups}/")"
br_restore file --skip-data
expect_rc 0
expect_eq "the swap happened during the import" "br-swap at import" "$(fake_calls br-swap)"
expect_eq "config.php is the merge of the backup it checked, not of the planted one" "no|// merged" "$(grep -q PLANTED "${br_www}/config/config.php" && echo yes || echo no)|$(tail -n 1 "${br_www}/config/config.php")"
expect_eq "custom_apps/ is the backup's, not the planted one" calendar "$(names_in "${br_www}/custom_apps")"
expect_eq "the marker went from the folder it checked, and the planted folder got none" "no|no" \
  "$([ -e "${br_backups}.moved/RESTORE-IN-PROGRESS" ] && echo yes || echo no)|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo yes || echo no)"
new_br_case "clouve-backups is swapped for another folder while occ status runs, after it was checked: the whole restore reads the backup it checked"
br_make_backup --with-data
br_change_after_backup
# a copy of the backup whose dump, config.php, apps and users' files say PLANTED, and whose SHA256SUMS is still the
# backup's: a restore that read the checksums from the planted folder would stop (exit 2), one that read an archive from
# it would restore PLANTED
mkdir -p "${case_dir}/plant/x/config" "${case_dir}/plant/x/custom_apps/planted" "${case_dir}/plant/d/alice/files"
cp -a "${br_last}" "${case_dir}/plant/"
printf '<?php\n$CONFIG = array (\n);\n// PLANTED\n' > "${case_dir}/plant/x/config/config.php"
printf 'PLANTED\n' > "${case_dir}/plant/d/alice/files/a.txt"
printf -- '-- PLANTED dump\n' | gzip > "${case_dir}/plant/${br_n0}/database.sql.gz"
tar -czf "${case_dir}/plant/${br_n0}/config.tar.gz" -C "${case_dir}/plant/x" config
tar -czf "${case_dir}/plant/${br_n0}/apps.tar.gz" -C "${case_dir}/plant/x" custom_apps
tar -czf "${case_dir}/plant/${br_n0}/data.tar.gz" -C "${case_dir}/plant/d" .
FAKE_NOW="@$((br_t0 + 60))"
: > "${FAKE_SQL_LOG}"
FAKE_BR_SWAP_AT=occ-status
# Out of the data folder, so the restore's own clearing of the data folder can't reach it here: this harness runs as one
# user, and in the container www-data can neither move nor clear a folder of root's
FAKE_BR_SWAP_CMD="mv $(printf %q "${br_backups}") $(printf %q "${case_dir}/moved-backups") && mkdir -m 700 $(printf %q "${br_backups}") && cp -a $(printf %q "${case_dir}/plant/${br_n0}") $(printf %q "${br_backups}/")"
br_restore file
expect_rc 0
expect_eq "the swap happened while occ status ran" "br-swap at occ-status" "$(fake_calls br-swap)"
expect_eq "the dump imported is the backup's it checked" "IMPORT -- dump of nextcloud" "$(grep '^IMPORT' "${FAKE_SQL_LOG}")"
expect_eq "config.php, custom_apps/ and alice's file are the backup's it checked, not the planted one's" "no|// merged|calendar|alice's file" \
  "$(grep -q PLANTED "${br_www}/config/config.php" && echo yes || echo no)|$(tail -n 1 "${br_www}/config/config.php")|$(names_in "${br_www}/custom_apps")|$(cat "${br_data}/alice/files/a.txt")"
expect_eq "the marker went from the folder it checked, and the planted folder got none" "no|no" \
  "$([ -e "${case_dir}/moved-backups/RESTORE-IN-PROGRESS" ] && echo yes || echo no)|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo yes || echo no)"
new_br_case "links www-data put in config/, custom_apps/ and the data folder: www-data removes the links, and what they point to is untouched"
br_make_backup --with-data
mkdir -p "${case_dir}/outside/sub"
printf 'keep\n' > "${case_dir}/outside/keep.txt"
printf 'keep\n' > "${case_dir}/outside/sub/deep.txt"
ln -s "${case_dir}/outside" "${br_data}/evil"
ln -s "${case_dir}/outside" "${br_data}/alice/files/evil"
ln -s "${case_dir}/outside/keep.txt" "${br_www}/config/evil.config.php"
ln -s "${case_dir}/outside" "${br_www}/custom_apps/evil"
outside_before="$(snapshot "${case_dir}/outside")"
FAKE_NOW="@$((br_t0 + 60))"
br_restore file
expect_rc 0
expect_eq "what the links point to is untouched" "${outside_before}" "$(snapshot "${case_dir}/outside")"
expect_eq "the links are gone" "no no no no" "$(for l in "${br_data}/evil" "${br_data}/alice/files/evil" "${br_www}/config/evil.config.php" "${br_www}/custom_apps/evil"; do [ -L "${l}" ] && printf 'yes ' || printf 'no '; done | sed 's/ $//')"
expect_www_data_only

section "restore.sh: a folder www-data can't empty stops it before anything changes"
# Steps 5, 6 and 7 empty config/, custom_apps/, themes/ and the data folder as www-data. A folder in them that www-data
# can't read, write in or go into would stop the restore halfway, after the database is the backup's, so step 1 looks
# for one. These folders are the case's: br_lock_dir records each, and br_unlock gives them mode 755 again, so the
# harness can delete its temporary folder.
br_locked=()
# br_lock_dir <mode> <path>: makes the folder with a file in it, then gives it that mode
br_lock_dir() { mkdir -p "$2" && printf 'x\n' > "$2/f.txt" && chmod "$1" "$2"; br_locked+=("$2"); }
br_unlock() { local d; for d in ${br_locked[@]+"${br_locked[@]}"}; do chmod 755 "${d}" 2> /dev/null; done; br_locked=(); }
# expect_not_emptiable <path>: exit 2, the folder named (quoted with %q) and "Nothing was changed.", and the database,
# the marker and maintenance mode as they were
expect_not_emptiable() {
  local want finds
  want="$(printf '%q' "$1")"
  expect_rc 2
  if [[ "${err}" == *"www-data can't empty ${want},"* && "${err}" == *'Nothing was changed.'* ]]; then ok "${case_label}: stderr names ${want} and says nothing was changed"
  else bad "${case_label}: stderr should name ${want} and say nothing was changed" "$(dump_case)"; fi
  expect_eq "no database statement, no marker, maintenance mode off" "|absent|off" \
    "$(cat "${FAKE_SQL_LOG}")|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)|$(br_now_maint)"
  expect_eq "occ was asked for the status only" "status --output=json" "$(occ_brief)"
  finds="$(br_as | grep -E '^[a-z-]+ find ' || true)"
  if grep -qE '^www-data find .* -readable ' <<< "${finds}" && ! grep -qv '^www-data ' <<< "${finds}"; then ok "${case_label}: the check ran as www-data"
  else bad "${case_label}: the check should run find as www-data, and only so" "${finds}"; fi
}
for mode in 555 000; do
  for place in data/alice/files custom_apps/calendar themes/x config/x; do
    new_br_case "a mode ${mode} folder with a file in it, in ${place}/: exit 2, before anything changes"
    br_make_backup --with-data
    FAKE_NOW="@$((br_t0 + 60))"
    br_lock_dir "${mode}" "${br_www}/${place}/locked"
    : > "${FAKE_SQL_LOG}"
    br_restore file
    expect_not_emptiable "${br_www}/${place}/locked"
    br_unlock
  done
done
# mode 300 is a folder www-data can't read (list), and 600 one it can't go into: each fails on its own
for mode in 300 600; do
  new_br_case "a mode ${mode} folder in data/alice/files/: exit 2, before anything changes"
  br_make_backup --with-data
  FAKE_NOW="@$((br_t0 + 60))"
  br_lock_dir "${mode}" "${br_data}/alice/files/locked"
  : > "${FAKE_SQL_LOG}"
  br_restore file
  expect_not_emptiable "${br_data}/alice/files/locked"
  br_unlock
done
new_br_case "a read-only file does not count: removing a file needs only its folder"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
printf 'ro\n' > "${br_data}/alice/files/ro.txt"
chmod 444 "${br_data}/alice/files/ro.txt" "${br_www}/config/upgrade-disable-web.config.php"
br_restore file
expect_rc 0
expect_eq "the read-only file made after the backup is gone" no "$([ -e "${br_data}/alice/files/ro.txt" ] && echo yes || echo no)"
new_br_case "no themes/ folder: there is nothing to check there"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
rmdir "${br_www}/themes"
br_restore file
expect_rc 0
new_br_case "without --yes-replace-current-data the same check runs, so the folder is named before anyone confirms"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
br_lock_dir 555 "${br_data}/alice/files/locked"
: > "${FAKE_SQL_LOG}"
run_in file "${restore_sh}" -- --backup "${br_n0}"
expect_not_emptiable "${br_data}/alice/files/locked"
expect_eq "no preview was printed" no "$(grep -q 'Restoring it replaces' <<< "${out}" && echo yes || echo no)"
br_unlock
for nm in 'has space' $'new\nline'; do
  new_br_case "a folder named $(printf '%q' "${nm}") is named quoted"
  br_make_backup --with-data
  FAKE_NOW="@$((br_t0 + 60))"
  br_lock_dir 555 "${br_data}/alice/files/${nm}"
  : > "${FAKE_SQL_LOG}"
  br_restore file
  expect_not_emptiable "${br_data}/alice/files/${nm}"
  br_unlock
done
new_br_case "--skip-data: such a folder in the data folder does not count, since the data folder is left alone"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
br_lock_dir 555 "${br_data}/alice/files/locked"
br_restore file --skip-data
expect_rc 0
expect_eq "the folder and its file are still there" "x" "$(cat "${br_data}/alice/files/locked/f.txt" 2> /dev/null)"
br_unlock
new_br_case "a folder www-data can't write in, inside clouve-backups: it does not count (clouve-backups is left out at depth 1)"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
br_lock_dir 555 "${br_backups}/locked"
br_restore file
expect_rc 0
expect_restore_marker absent
br_unlock
new_br_case "a folder named clouve-backups deeper in the data folder is checked like any other"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
br_lock_dir 555 "${br_data}/alice/files/clouve-backups/locked"
: > "${FAKE_SQL_LOG}"
br_restore file
expect_not_emptiable "${br_data}/alice/files/clouve-backups/locked"
br_unlock
new_br_case "find can't run as www-data: exit 2, the folder it could not check, nothing changed"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
: > "${FAKE_SQL_LOG}"
FAKE_HEALTH_SUDO_FAIL='find'
br_restore file
expect_rc 2
if [[ "${err}" == *"could not check ${br_www}/config"* && "${err}" == *'Nothing was changed.'* ]]; then ok "${case_label}: stderr names the folder it could not check"
else bad "${case_label}: stderr should say it could not check ${br_www}/config" "$(dump_case)"; fi
expect_eq "no database statement, no marker, maintenance mode off" "|absent|off" \
  "$(cat "${FAKE_SQL_LOG}")|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)|$(br_now_maint)"

section "restore.sh: room for the users' files"
new_br_case "the free space plus the current users' files is under data_bytes plus 5 %: it refuses (exit 2); with exactly enough it restores"
br_make_backup --with-data
br_manifest_set "${br_last}" '.data_bytes = 52428800'
FAKE_NOW="@$((br_t0 + 60))"
br_cur=$(($(br_disk "${br_data}") - $(br_disk "${br_backups}")))
br_need=$(((52428800 * 105 + 99) / 100))
FAKE_DF_AVAIL=$((br_need - br_cur - 1))
: > "${FAKE_SQL_LOG}"
sum_before="$(br_tree_sum)"
br_restore file
expect_rc 2
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
for phrase in "they need $(br_mb "${br_need}")" "the $(br_mb 52428800) they took when the backup was made, plus 5 %" "$(br_mb "${FAKE_DF_AVAIL}") free plus the $(br_mb "${br_cur}") the current users' files take" 'Nothing was changed'; do
  if [[ "${err}" == *"${phrase}"* ]]; then ok "${case_label}: stderr says: ${phrase}"; else bad "${case_label}: stderr should say: ${phrase}" "$(dump_case)"; fi
done
FAKE_DF_AVAIL=$((br_need - br_cur))
br_restore file
expect_rc 0
expect_restore_marker absent
new_br_case "a manifest without data_bytes: a warning, and the restore goes on"
br_make_backup --with-data
br_manifest_set "${br_last}" 'del(.data_bytes)'
FAKE_NOW="@$((br_t0 + 60))"
FAKE_DF_AVAIL=1
br_restore file
expect_rc 0
if [[ "${err}" == *'WARNING'*'data_bytes'*'the free space was not checked'* ]]; then ok "${case_label}: stderr warns that the space was not checked"; else bad "${case_label}: stderr should warn that the space was not checked" "$(dump_case)"; fi
new_br_case "--skip-data needs no room for the users' files"
br_make_backup --with-data
br_manifest_set "${br_last}" '.data_bytes = 999999999999'
FAKE_NOW="@$((br_t0 + 60))"
FAKE_DF_AVAIL=1
br_restore file --skip-data
expect_rc 0
expect_eq "no warning about the space" "" "$(grep 'data_bytes' <<< "${err}")"

section "restore.sh: the start, and a stop before it"
new_br_case "the marker is written under a temporary name and renamed into place, so one from a cut-off restore is never missing"
br_make_backup --with-data
printf '20261231-235959\n' > "${br_backups}/RESTORE-IN-PROGRESS"     # a restore of another backup was cut off
FAKE_NOW="@$((br_t0 + 60))"
br_restore file
expect_rc 0
expect_eq "the marker named this backup by the time maintenance mode went on" "br-occ maintenance:mode --on maintenance=off backup-marker=absent restore-marker=present:${br_n0}" "$(fake_calls 'br-occ maintenance:mode --on')"
expect_eq "the first commands on the marker: a temporary file, renamed over it (no rm before that)" \
  "root mktemp .RESTORE-IN-PROGRESS.XXXXXX|root mv -f -- .RESTORE-IN-PROGRESS.TMP RESTORE-IN-PROGRESS" \
  "$(br_as | grep -F RESTORE-IN-PROGRESS | head -n 2 | sed -E 's/\.RESTORE-IN-PROGRESS\.[A-Za-z0-9]{6} /.RESTORE-IN-PROGRESS.TMP /' | tr '\n' '|' | sed 's/|$//')"
expect_restore_marker absent
expect_eq "no temporary marker file is left" "" "$(find "${br_backups}" -maxdepth 1 -name '.RESTORE-IN-PROGRESS.*')"
new_br_case "SIGTERM before the start (while occ status runs): exit 143, and nothing changed"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
: > "${FAKE_SQL_LOG}"
sum_before="$(br_tree_sum)"
FAKE_PIDFILE="${case_dir}/pid"
FAKE_BR_KILL_AT=occ-status
FAKE_BR_KILL_SIG=TERM
br_restore file
expect_rc 143
expect_eq "nothing changed, and no marker" "${sum_before}|absent" "$(br_tree_sum)|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)"
if [[ "${err}" == *'STOPPED by SIGTERM before the restore began. Nothing was changed.'* ]]; then ok "${case_label}: stderr says it stopped before the restore began, and nothing was changed"; else bad "${case_label}: stderr should say nothing was changed" "$(dump_case)"; fi
expect_eq "no temporary file is left" "" "$(br_tmp_left)"
for sig in INT:130 TERM:143; do
  new_br_case "SIG${sig%%:*} while maintenance mode goes on: exit ${sig#*:}, maintenance mode back off and the marker gone"
  br_make_backup --with-data
  FAKE_NOW="@$((br_t0 + 60))"
  : > "${FAKE_SQL_LOG}"
  sum_before="$(br_tree_sum)"
  FAKE_PIDFILE="${case_dir}/pid"
  FAKE_BR_KILL_AT='occ-maintenance:mode --on'
  FAKE_BR_KILL_SIG="${sig%%:*}"
  br_restore file
  expect_rc "${sig#*:}"
  expect_eq "nothing changed: maintenance mode is off and there is no marker" "${sum_before}" "$(br_tree_sum)"
  expect_restore_marker absent
  expect_occ_brief $'status --output=json\nmaintenance:mode --on\nmaintenance:mode --off'
  if [[ "${err}" == *"STOPPED by SIG${sig%%:*} in step 3 (the start), before the restore began."* && "${err}" == *'Nothing was changed: maintenance mode is as it was, and the marker is gone.'* ]]; then ok "${case_label}: stderr says where it stopped, and that nothing was changed"
  else bad "${case_label}: stderr should say it stopped in step 3 and nothing was changed" "$(dump_case)"; fi
done

new_br_case "SIGTERM while maintenance mode goes on, with a cut-off restore's marker there before: maintenance mode back off, the marker stays"
br_make_backup --with-data
printf '20261231-235959\n' > "${br_backups}/RESTORE-IN-PROGRESS"
FAKE_NOW="@$((br_t0 + 60))"
FAKE_PIDFILE="${case_dir}/pid"
FAKE_BR_KILL_AT='occ-maintenance:mode --on'
FAKE_BR_KILL_SIG=TERM
br_restore file
expect_rc 143
expect_eq "maintenance mode is off again, and a marker is still there" "off|present" "$(br_now_maint)|$([ -e "${br_backups}/RESTORE-IN-PROGRESS" ] && echo present || echo absent)"
if [[ "${err}" == *'Nothing was changed: maintenance mode is as it was, and'*'stays'* ]]; then ok "${case_label}: stderr says nothing was changed and the marker stays"; else bad "${case_label}: stderr should say the marker stays" "$(dump_case)"; fi

section "restore.sh: what it refuses before it changes anything"
new_br_case "not root"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
sum_before="$(br_tree_sum)"
run_in file "${restore_sh}" -FAKE_BR_ROOT -- --backup "${br_n0}" --yes-replace-current-data
expect_rc 2
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
new_br_case "the init lock is held"
br_make_backup --with-data
FAKE_NOW="@$((br_t0 + 60))"
sum_before="$(br_tree_sum)"
( SECONDS=0; exec 8< "${br_www}/nextcloud-init-sync.lock"; flock 8; : > "${case_dir}/lock-held"; until [ -e "${case_dir}/lock-release" ] || [ "${SECONDS}" -gt 20 ]; do sleep 0.1; done ) &
br_holder=$!
wait_for_file "${case_dir}/lock-held"
br_restore file
: > "${case_dir}/lock-release"
wait "${br_holder}"
expect_rc 2
expect_eq "nothing changed" "${sum_before}" "$(br_tree_sum)"
if [[ "${err}" == *'init lock'* ]]; then ok "${case_label}: stderr says the init lock is held"; else bad "${case_label}: stderr should say the init lock is held" "$(dump_case)"; fi
for spec in '|--backup' '--yes-replace-current-data|--backup' "--backup ${br_n0} --bogus|unknown" '--backup|--backup'; do
  new_br_case "usage: restore.sh ${spec%%|*}"
  read -ra br_args <<< "${spec%%|*}"
  run_in file "${restore_sh}" -- ${br_args[@]+"${br_args[@]}"}
  expect_rc 1
  if [[ "${err}" == *'Usage: restore.sh --backup <name> --yes-replace-current-data [--skip-data]'* ]]; then ok "${case_label}: stderr shows the usage"; else bad "${case_label}: stderr should show the usage" "$(dump_case)"; fi
  expect_eq "nothing was called" 0 "$(wc -l < "${FAKE_OCC_LOG}" | tr -d ' ')"
done
if [[ "${err}" == *"--backup needs a backup's name"* ]]; then ok "${case_label}: stderr says --backup needs a name"; else bad "${case_label}: stderr should say --backup needs a backup's name" "$(dump_case)"; fi
new_br_case "--help"
run_in file "${restore_sh}" -- --help
expect_rc 0
if [[ "${out}" == 'Usage: restore.sh --backup <name> --yes-replace-current-data [--skip-data]'* ]]; then ok "${case_label}: the usage is on stdout"; else bad "${case_label}: the usage should be on stdout" "$(dump_case)"; fi

# ----- what backup.sh and restore.sh share -----
# Each of the two is sent into the container on its own, so neither can source a library: the helpers they share are
# written out in both. These cases keep the two copies the same (die's exit code aside: 1 in backup.sh, 2 in
# restore.sh), so a fix to one copy can't miss the other.
br_shared_fns="first_line www php_run setting json_flag json_text split_dbhost cnf_quote write_client_cnf db_query digits du_bytes free_bytes in_mb human marker_name enter_data_dir enter_backups_dir open_init_lock"

# br_fn <file> <name>: shell function NAME in FILE, from its `NAME() {` line to the `}` line that ends it (a function
# on one line is that line)
br_fn() {
  awk -v fn="$2" '
    !found && index($0, fn "() {") == 1 { found = 1; print; if ($0 !~ /[{]$/) exit; next }
    found { print; if ($0 == "}") exit }' "$1"
}

# br_php_reader <file>: the config.php reader in FILE's PHP program, from its first comment line to its last
br_php_reader() { sed -n '/^\/\/ The config\.php reader\./,/^\/\/ The end of the config\.php reader\./p' "$1"; }

# br_compare_shared <backup.sh> <restore.sh>: one line for each shared helper that is missing from one of them, or that
# differs once each "die N " is "die <code> "
br_compare_shared() {
  local fn a b
  for fn in ${br_shared_fns}; do
    a="$(br_fn "$1" "${fn}" | sed -E 's/die [0-9]+ /die <code> /g')"
    b="$(br_fn "$2" "${fn}" | sed -E 's/die [0-9]+ /die <code> /g')"
    if [ -z "${a}" ] || [ -z "${b}" ]; then echo "${fn}: missing"; elif [ "${a}" != "${b}" ]; then echo "${fn}: differs"; fi
  done
  a="$(br_php_reader "$1")"
  b="$(br_php_reader "$2")"
  if [ -z "${a}" ] || [ -z "${b}" ]; then echo "the PHP config.php reader: missing"; elif [ "${a}" != "${b}" ]; then echo "the PHP config.php reader: differs"; fi
}

section "backup.sh and restore.sh: the helpers and the PHP reader they both carry are the same"
new_case "the two copies"
expect_eq "each shared helper and the PHP config.php reader are the same in both, but for die's exit code" "" "$(br_compare_shared "${backup_sh}" "${restore_sh}")"
expect_eq "the reader is a real part of each PHP program (its \$load and \$get are there)" "2 2" \
  "$(br_php_reader "${backup_sh}" | grep -cE '^\$(load|get) = static function' || true) $(br_php_reader "${restore_sh}" | grep -cE '^\$(load|get) = static function' || true)"
# The comparison catches a change, in a helper or in the reader, and a helper that is gone.
python3 -I - "${restore_sh}" "${case_dir}" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src).read()
cases = {
    'helper': ("    text=${text//$'\\b'/\\\\b}\n", ''),
    'reader': ('JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE', 'JSON_UNESCAPED_SLASHES'),
    'gone': ('digits() {\n', 'number_check() {\n'),
}
for name, (old, new) in cases.items():
    assert s.count(old) == 1, name
    open(out + '/restore-' + name + '.sh', 'w').write(s.replace(old, new, 1))
PY
expect_eq "a line gone from one copy of cnf_quote is caught" "cnf_quote: differs" "$(br_compare_shared "${backup_sh}" "${case_dir}/restore-helper.sh")"
expect_eq "a change in one copy of the PHP reader is caught" "the PHP config.php reader: differs" "$(br_compare_shared "${backup_sh}" "${case_dir}/restore-reader.sh")"
expect_eq "a helper gone from one script is caught" "digits: missing" "$(br_compare_shared "${backup_sh}" "${case_dir}/restore-gone.sh")"

section "backup.sh and restore.sh: every cd is cd -P"
# A plain cd goes by the text of $PWD: bash changes to "$PWD/NAME", through the path again, so after a swap it would land in
# the folder put in its place. cd -P changes to NAME in the folder the script is really in.
for f in "${backup_sh}" "${restore_sh}"; do
  new_case "${f##*/}: the cd commands"
  expect_eq "no cd but cd -P and cd /" "" "$(grep -nE '(^|[^[:alnum:]_-])cd( |$)' "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '(^|[^[:alnum:]_-])cd (-P |/ )' || true)"
done

section "backup.sh and restore.sh: the open of the init lock gives up on a named pipe"
# open_init_lock as it is in each script, with its 5 seconds made 1, run on a named pipe, a plain file and a link
for f in "${backup_sh}" "${restore_sh}"; do
  new_case "${f##*/}: open_init_lock"
  { printf 'die() { printf "%%s\\n" "$2" >&2; exit "$1"; }\n'; br_fn "${f}" open_init_lock | sed 's/read -r -t 5 _/read -r -t 1 _/'; } > "${case_dir}/open-lock.sh"
  mkfifo "${case_dir}/pipe"
  : > "${case_dir}/plain"
  ln -s "${case_dir}/plain" "${case_dir}/link"
  if grep -q 'read -r -t 1 _' "${case_dir}/open-lock.sh"; then ok "${case_label}: the function was found, and its wait made 1 second"; else bad "${case_label}: no open_init_lock with read -r -t 5 in ${f##*/}"; fi
  br_t=${EPOCHSECONDS}
  run_script -- timeout 10 "${BASH}" -c '. "$1"; open_init_lock "$2"; echo "returned $?"' _ "${case_dir}/open-lock.sh" "${case_dir}/pipe"
  if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] && [[ "${err}" == *"could not open ${case_dir}/pipe within 5 seconds"* ]] && [ -z "${out}" ]; then ok "${case_label}: on a named pipe it ends the script with a message"
  else bad "${case_label}: on a named pipe it should end the script with a message" "$(dump_case)"; fi
  if [ $((EPOCHSECONDS - br_t)) -le 4 ]; then ok "${case_label}: it gave up in time"; else bad "${case_label}: it took $((EPOCHSECONDS - br_t)) s"; fi
  run_script -- "${BASH}" -c '. "$1"; open_init_lock "$2" && [ -f /proc/self/fd/9 ] && echo "fd 9 open"' _ "${case_dir}/open-lock.sh" "${case_dir}/plain"
  expect_eq "on a plain file it opens fd 9" "fd 9 open" "${out}"
  run_script -- "${BASH}" -c '. "$1"; open_init_lock "$2"; echo "returned $?"; [ -e /proc/self/fd/9 ] && echo "fd 9 still open"' _ "${case_dir}/open-lock.sh" "${case_dir}/link"
  expect_eq "on a link it fails, and closes fd 9 again" "returned 1" "${out}"
done

# ----- run-in-nextcloud.sh -----
section "run-in-nextcloud.sh: the file"
expect_script_file "${run_in_sh}" run-in-nextcloud.sh
if [ -f "${run_in_sh}" ]; then
  expect_eq "it loads the ops password with the repo's loader line, once" 1 "$(grep -cxF ': "${CLOUVE_OPS_PASSWORD:=$(clv-secret CLOUVE_OPS_PASSWORD)}"' "${run_in_sh}")"
  if grep -qE '^\. "\$\{script_dir\}/lib/nextcloud-ssh\.sh" \|\| exit 1$' "${run_in_sh}" && grep -qE '^mapfile -t ssh_opts < <\(nc_ssh_options\)$' "${run_in_sh}"; then ok "run-in-nextcloud.sh takes its ssh options from lib/nextcloud-ssh.sh"
  else bad "run-in-nextcloud.sh should source lib/nextcloud-ssh.sh and read nc_ssh_options"; fi
  if grep -vE '^[[:space:]]*#' "${run_in_sh}" | grep -qE 'StrictHostKeyChecking|UserKnownHostsFile|ConnectTimeout'; then bad "run-in-nextcloud.sh writes ssh options itself"; else ok "run-in-nextcloud.sh writes no ssh option itself"; fi
  if grep -qE '^[[:space:]]*export[[:space:]]+SSHPASS' "${run_in_sh}"; then bad "run-in-nextcloud.sh exports SSHPASS"; else ok "run-in-nextcloud.sh never exports SSHPASS"; fi
fi

# new_rin_case <label>: new_case, plus a copy of run-in-nextcloud.sh and lib/nextcloud-ssh.sh in ${rin_dir}, next to stand-ins
# for backup.sh and restore.sh (run-in-nextcloud.sh sends the scripts next to it). The stand-ins print what they were given.
new_rin_case() {
  new_case "$1"
  default_env[PATH]="${shim_bin}:${default_env[PATH]}"
  FAKE_NOW='@1800000000'
  rin_dir="${case_dir}/scripts"
  mkdir -p "${rin_dir}/lib"
  if [ -f "${run_in_sh}" ]; then cp "${run_in_sh}" "${rin_dir}/"; fi
  cp "${ssh_lib}" "${rin_dir}/lib/"
  rin="${rin_dir}/run-in-nextcloud.sh"
  local s
  for s in backup restore; do
    printf '%s\n' '#!/bin/bash' "echo \"${s} out 1\"" "echo \"${s} err 1\" >&2" 'for a in "$@"; do printf "arg=%s\n" "${a}"; done' \
      'if [ -n "${FAKE_BR_GO:-}" ]; then for i in $(seq 1 300); do [ -e "${FAKE_BR_GO}" ] && break; sleep 0.1; done; fi' \
      "echo \"${s} out 2\"" 'exit "${FAKE_BR_RIN_RC:-0}"' > "${rin_dir}/${s}.sh"
  done
}
rin_job=backup-20270115-080000

section "run-in-nextcloud.sh: a plain run"
new_rin_case "backup.sh: the output streams through and the exit code is the script's"
FAKE_BR_RIN_RC=3
run_script -- "${rin}" backup.sh --with-data 'two words' "it's \$HOME"
expect_rc 3
expect_stdout_is $'backup out 1\narg=--with-data\narg=two words\narg=it\'s $HOME\nbackup out 2\n'
expect_eq "stderr" "backup err 1" "${err}"
expect_call_count ssh 1
expect_eq "ssh target" "clouve-ops@nc.test" "$(ssh_field 1 target)"
expect_eq "ssh options: the four, and no -n (the script travels on stdin)" "${ssh_o}" "$(ssh_field 1 opts)"
printf -v rin_q ' %q' --with-data 'two words' "it's \$HOME"
expect_eq "the remote command, each argument quoted with %q" "sudo -n bash -s --${rin_q}" "$(ssh_field 1 cmd)"
expect_channel_bytes "$(wc -c < "${rin_dir}/backup.sh" | tr -d ' ')"
expect_not_in_logs "${ops_pw}" "${FAKE_ARGV_LOG}"
new_rin_case "restore.sh, with no arguments"
run_script -- "${rin}" restore.sh
expect_rc 0
expect_eq "the remote command" "sudo -n bash -s --" "$(ssh_field 1 cmd)"
new_case "the real backup.sh goes over the channel byte for byte"
run_script -- "${run_in_sh}" backup.sh --list
expect_channel_bytes "$(wc -c < "${backup_sh}" | tr -d ' ')"
if [[ "${err}" == *'root'* ]]; then ok "${case_label}: it ran on the far side (and stopped there, since this harness is not root)"; else bad "${case_label}: backup.sh should have run on the far side" "$(dump_case)"; fi
new_rin_case "the ops password from clv-secret"
run_script -CLOUVE_OPS_PASSWORD -- "${rin}" backup.sh
expect_rc 0
expect_eq "clv-secret was asked once" "clv-secret CLOUVE_OPS_PASSWORD" "$(fake_calls clv-secret)"
new_rin_case "a wrong ops password (sshpass exits 5): 255, like any ssh failure"
run_script CLOUVE_OPS_PASSWORD=not-the-password -- "${rin}" backup.sh
expect_rc 255
if [[ "${err}" == *'ssh to clouve-ops@nc.test failed'* ]]; then ok "${case_label}: stderr says ssh failed"; else bad "${case_label}: stderr should say ssh failed" "$(dump_case)"; fi
expect_call_count ssh 2
expect_eq "the second ssh call only checks the channel" "true" "$(ssh_field 2 cmd)"
expect_eq "and it has -n and the same options" "-n ${ssh_o}" "$(ssh_field 2 opts)"
new_rin_case "a host key sshpass won't accept (exit 7): 255"
FAKE_SSH_FAIL='nc.test=7'
run_script -- "${rin}" restore.sh
expect_rc 255
if [[ "${err}" == *'ssh to clouve-ops@nc.test failed'* ]]; then ok "${case_label}: stderr says ssh failed"; else bad "${case_label}: stderr should say ssh failed" "$(dump_case)"; fi
expect_call_count ssh 2
new_rin_case "backup.sh's own 5 (the backup is kept, maintenance mode is still on): the script's code, once the channel checks out"
FAKE_BR_RIN_RC=5
run_script -- "${rin}" backup.sh
expect_rc 5
expect_stdout_is $'backup out 1\nbackup out 2\n'
expect_eq "stderr is the script's own, nothing added" "backup err 1" "${err}"
expect_call_count ssh 2
expect_eq "the second ssh call only checks the channel" "true" "$(ssh_field 2 cmd)"
expect_eq "and it has -n and the same options" "-n ${ssh_o}" "$(ssh_field 2 opts)"
new_rin_case "a script's 6 or 7 is its own too, once the channel checks out"
FAKE_BR_RIN_RC=7
run_script -- "${rin}" restore.sh
expect_rc 7
expect_eq "stderr is the script's own, nothing added" "restore err 1" "${err}"
new_rin_case "the container can't be reached"
FAKE_SSH_FAIL='nc.test=255'
run_script -- "${rin}" backup.sh
expect_rc 255
if [[ "${err}" == *'clouve-ops@nc.test'* ]]; then ok "${case_label}: stderr names the host"; else bad "${case_label}: stderr should name clouve-ops@nc.test" "$(dump_case)"; fi
expect_eq "255 is ssh's own (neither script ends with it), so there is no second call" "1" "$(call_count ssh)"

section "run-in-nextcloud.sh --detach and --status"
new_rin_case "--detach backup.sh --with-data, then --status while it runs and after it ends"
FAKE_BR_GO="${case_dir}/go"
run_script -- "${rin}" --detach backup.sh --with-data
expect_rc 0
expect_eq "it prints the job" "job: ${rin_job}" "$(head -n 1 "${case_dir}/stdout")"
expect_eq "nothing on stderr: the wait reads a job that has no exit-code file yet" "" "${err}"
if [[ "$(sed -n 2p "${case_dir}/stdout")" == *"run-in-nextcloud.sh --status ${rin_job}" ]]; then ok "${case_label}: then the --status command"; else bad "${case_label}: the second line should be the --status command" "$(dump_case)"; fi
expect_call_count ssh 3
expect_eq "the first call installs the script" \
  "sudo -n install -d -m 700 /run/clouve/jobs || exit 1; if sudo -n test -e /run/clouve/jobs/${rin_job}.sh; then exit 17; fi; sudo -n tee /run/clouve/jobs/${rin_job}.sh > /dev/null && sudo -n chmod 700 /run/clouve/jobs/${rin_job}.sh" \
  "$(ssh_field 1 cmd)"
expect_channel_bytes "$(wc -c < "${rin_dir}/backup.sh" | tr -d ' ')" 1
expect_eq "the second starts it, detached" \
  "sudo -n setsid nohup bash -c 'bash \"\$0.sh\" \"\$@\" > \"\$0.log\" 2>&1; echo \$? > \"\$0.rc\"' /run/clouve/jobs/${rin_job} --with-data < /dev/null > /dev/null 2>&1 &" \
  "$(ssh_field 2 cmd)"
expect_eq "with ssh -n" "-n ${ssh_o}" "$(ssh_field 2 opts)"
expect_eq "the third waits for the job to show it started" "sudo -n bash -s -- /run/clouve/jobs ${rin_job} 5" "$(ssh_field 3 cmd)"
expect_eq "the job file is the script, mode 700, in a mode 700 folder" "$(sha256sum < "${rin_dir}/backup.sh") 700 700" \
  "$(sha256sum < "${FAKE_RUN}/jobs/${rin_job}.sh" 2> /dev/null) $(mode_of "${FAKE_RUN}/jobs/${rin_job}.sh") $(mode_of "${FAKE_RUN}/jobs")"
for ((i = 0; i < 100; i++)); do grep -q 'arg=--with-data' "${FAKE_RUN}/jobs/${rin_job}.log" 2> /dev/null && break; sleep 0.1; done
run_script -- "${rin}" --status "${rin_job}"
expect_rc 3
expect_eq "while it runs: the log so far, then status: running" $'backup out 1\nbackup err 1\narg=--with-data\nstatus: running' "${out}"
expect_eq "while it runs: nothing on stderr (no exit-code file yet)" "" "${err}"
br_job_cleanup "${rin_job}"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 0
expect_eq "once it has ended: the whole log, then the exit code" $'backup out 1\nbackup err 1\narg=--with-data\nbackup out 2\nstatus: finished, exit 0' "${out}"
expect_eq "the --status call sends a script to sudo -n bash -s with the jobs folder and the job's name" "sudo -n bash -s -- /run/clouve/jobs ${rin_job}" "$(ssh_field 1 cmd)"
expect_not_in_logs "${ops_pw}" "${FAKE_ARGV_LOG}"
new_rin_case "--detach restore.sh with arguments that need quoting"
run_script -- "${rin}" --detach restore.sh --backup 20270115-080000 --yes-replace-current-data "it's"
expect_rc 0
expect_eq "it prints the job" "job: restore-20270115-080000" "$(head -n 1 "${case_dir}/stdout")"
printf -v rin_q ' %q' --backup 20270115-080000 --yes-replace-current-data "it's"
if [[ "$(ssh_field 2 cmd)" == *" /run/clouve/jobs/restore-20270115-080000${rin_q} < /dev/null > /dev/null 2>&1 &" ]]; then ok "${case_label}: the arguments are quoted with %q"; else bad "${case_label}: the arguments should be quoted with %q" "$(ssh_field 2 cmd)"; fi
br_job_cleanup restore-20270115-080000
expect_eq "the job got them as they were" $'arg=--backup\narg=20270115-080000\narg=--yes-replace-current-data\narg=it\'s' "$(grep '^arg=' "${FAKE_RUN}/jobs/restore-20270115-080000.log")"
new_rin_case "--detach when a job of that name is there already"
mkdir -p "${FAKE_RUN}/jobs"
printf 'the other job\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
run_script -- "${rin}" --detach backup.sh
expect_rc 1
expect_eq "nothing was started and the other job's file is untouched" "1 the other job" "$(call_count ssh) $(cat "${FAKE_RUN}/jobs/${rin_job}.sh")"
new_rin_case "--status of a job that ended with 4"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/restore-20270115-080000.sh"
printf 'line 1\n[nextcloud/restore] FAILED in step 4\n' > "${FAKE_RUN}/jobs/restore-20270115-080000.log"
printf '4\n' > "${FAKE_RUN}/jobs/restore-20270115-080000.rc"
run_script -- "${rin}" --status restore-20270115-080000
expect_rc 1
expect_eq "the log, then the exit code" $'line 1\n[nextcloud/restore] FAILED in step 4\nstatus: finished, exit 4' "${out}"
new_rin_case "--status of a job with no exit code and no process"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
printf 'started\n' > "${FAKE_RUN}/jobs/${rin_job}.log"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 1
expect_eq "the log, then that it stopped without an exit code" $'started\nstatus: stopped without an exit code' "${out}"
new_rin_case "--status of the last 40 lines only"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
seq 1 100 > "${FAKE_RUN}/jobs/${rin_job}.log"
printf '0\n' > "${FAKE_RUN}/jobs/${rin_job}.rc"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 0
expect_eq "lines 61 to 100, then the status" "$(seq 61 100; echo 'status: finished, exit 0')" "${out}"
new_rin_case "--status of a job whose log does not end with a newline"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
printf 'half a line' > "${FAKE_RUN}/jobs/${rin_job}.log"
printf '0\n' > "${FAKE_RUN}/jobs/${rin_job}.rc"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 0
expect_eq "the status still has a line of its own" $'half a line\nstatus: finished, exit 0' "${out}"
new_rin_case "--status of a job that is not there"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 64
new_rin_case "--detach when sudo refuses to start the job: it waits for it, then says it did not start (exit 1)"
FAKE_HEALTH_SUDO_FAIL=setsid
br_t=${EPOCHSECONDS}
run_script -- "${rin}" --detach backup.sh
expect_rc 1
expect_eq "no job line on stdout" "" "${out}"
if [[ "${err}" == *"the job ${rin_job} did not start"* ]]; then ok "${case_label}: stderr says the job did not start"; else bad "${case_label}: stderr should say the job did not start" "$(dump_case)"; fi
if [ $((EPOCHSECONDS - br_t)) -ge 4 ] && [ $((EPOCHSECONDS - br_t)) -le 15 ]; then ok "${case_label}: it waited about 5 seconds"; else bad "${case_label}: it took $((EPOCHSECONDS - br_t)) s"; fi
new_rin_case "--detach when the container's shell can't run the check: exit 2"
FAKE_BR_GO="${case_dir}/go"
# the third call (the check) fails as sudo does when it refuses: the fake refuses `bash` only once the job is running
mkdir -p "${case_dir}/bin2"
printf '#!/bin/bash\nif [ "${1:-}" = -n ] && [ "${2:-}" = bash ] && [ "${3:-}" = -s ]; then echo "sudo: a password is required" >&2; exit 1; fi\nexec %q "$@"\n' "${bin}/sudo" > "${case_dir}/bin2/sudo"
chmod +x "${case_dir}/bin2/sudo"
run_script PATH="${case_dir}/bin2:${default_env[PATH]}" -- "${rin}" --detach backup.sh
expect_rc 2
if [[ "${err}" == *'whether it runs could not be read'* ]]; then ok "${case_label}: stderr says the state could not be read"; else bad "${case_label}: stderr should say the state could not be read" "$(dump_case)"; fi
br_job_cleanup "${rin_job}"
# rin_holder <job> <tag>: a process with /run/clouve/jobs/<job> (mapped) as an argument, as the job's outer bash has, until
# ${case_dir}/<tag> is there (or 20 seconds have gone by)
rin_holder() {
  bash -c 'SECONDS=0; until [ -e "$1" ] || [ "${SECONDS}" -gt 20 ]; do sleep 0.1; done' "${FAKE_RUN}/jobs/$1" "${case_dir}/$2" &
  rin_holder_pid=$!
}
new_rin_case "--status while only the job's outer bash runs (before its script starts, or while it writes the exit code): running"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
rin_holder "${rin_job}" release
run_script -- "${rin}" --status "${rin_job}"
: > "${case_dir}/release"
wait "${rin_holder_pid}"
expect_rc 3
expect_eq "status: running" "status: running" "${out}"
new_rin_case "--status with an empty exit-code file while the outer bash runs: still running"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
printf 'started\n' > "${FAKE_RUN}/jobs/${rin_job}.log"
: > "${FAKE_RUN}/jobs/${rin_job}.rc"
rin_holder "${rin_job}" release
run_script -- "${rin}" --status "${rin_job}"
: > "${case_dir}/release"
wait "${rin_holder_pid}"
expect_rc 3
expect_eq "the log, then status: running" $'started\nstatus: running' "${out}"
new_rin_case "--status with an empty exit-code file and no process: stopped without an exit code"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
printf 'started\n' > "${FAKE_RUN}/jobs/${rin_job}.log"
: > "${FAKE_RUN}/jobs/${rin_job}.rc"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 1
expect_eq "the log, then that it stopped without an exit code" $'started\nstatus: stopped without an exit code' "${out}"
new_rin_case "--status of a job that never started (no log, no exit code, no process)"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
run_script -- "${rin}" --status "${rin_job}"
expect_rc 1
expect_eq "status: not started" "status: not started" "${out}"
new_rin_case "--status when sudo refuses in the container: exit 2, not a job's exit code"
mkdir -p "${FAKE_RUN}/jobs"
printf 'x\n' > "${FAKE_RUN}/jobs/${rin_job}.sh"
printf '0\n' > "${FAKE_RUN}/jobs/${rin_job}.rc"
FAKE_HEALTH_SUDO_FAIL=bash
run_script -- "${rin}" --status "${rin_job}"
expect_rc 2
if [[ "${err}" == *"could not read the job's status"* ]]; then ok "${case_label}: stderr says the status could not be read"; else bad "${case_label}: stderr should say the status could not be read" "$(dump_case)"; fi

section "run-in-nextcloud.sh: usage and environment"
for spec in 'other.sh' '' '--detach' '--detach other.sh' '--status ../../etc' '--status backup-1' '--status' '--status x y' 'backup' "--status backup-20270115-080000/../x"; do
  new_rin_case "usage: run-in-nextcloud.sh ${spec}"
  read -ra rin_args <<< "${spec}"
  run_script -- "${rin}" ${rin_args[@]+"${rin_args[@]}"}
  expect_rc 64
  expect_eq "nothing was called" "" "$(grep -E '^(ssh|clv-secret) ' "${FAKE_CALLS}")"
done
new_rin_case "--help"
run_script -- "${rin}" --help
expect_rc 0
if [[ "${out}" == 'Usage: run-in-nextcloud.sh [--detach] <backup.sh|restore.sh> [args...]'* ]]; then ok "${case_label}: the usage is on stdout"; else bad "${case_label}: the usage should be on stdout" "$(dump_case)"; fi
for how in unset empty; do
  new_rin_case "NEXTCLOUD_HOST ${how}"
  if [ "${how}" = unset ]; then run_script -NEXTCLOUD_HOST -- "${rin}" backup.sh; else run_script NEXTCLOUD_HOST= -- "${rin}" backup.sh; fi
  expect_rc 1
  if [[ "${err}" == *'NEXTCLOUD_HOST is not set'* ]]; then ok "${case_label}: stderr says so"; else bad "${case_label}: stderr should say NEXTCLOUD_HOST is not set" "$(dump_case)"; fi
  expect_eq "nothing was called" "" "$(grep -E '^(ssh|clv-secret) ' "${FAKE_CALLS}")"
done
new_rin_case "no ops password anywhere"
run_script -CLOUVE_OPS_PASSWORD -FAKE_SECRET_CLOUVE_OPS_PASSWORD -- "${rin}" backup.sh
expect_rc 1
if [[ "${err}" == *'clv-secret: CLOUVE_OPS_PASSWORD is not set on this server'* && "${err}" == *'clv-secret --list'* ]]; then ok "${case_label}: clv-secret's message, then where to look"; else bad "${case_label}: stderr should show clv-secret's message and name clv-secret --list" "$(dump_case)"; fi
expect_call_count ssh 0
new_rin_case "lib/nextcloud-ssh.sh is missing"
rm -f "${rin_dir}/lib/nextcloud-ssh.sh"
run_script -- "${rin}" backup.sh
expect_rc 1
expect_eq "nothing was called" "" "$(grep -E '^(ssh|clv-secret) ' "${FAKE_CALLS}")"
new_rin_case "lib/nextcloud-ssh.sh defines no options"
printf 'nc_ssh_options() { :; }\n' > "${rin_dir}/lib/nextcloud-ssh.sh"
run_script -- "${rin}" backup.sh
expect_rc 1
expect_call_count ssh 0
new_rin_case "the script is missing next to it"
rm -f "${rin_dir}/backup.sh"
run_script -- "${rin}" backup.sh
expect_rc 1
expect_call_count ssh 0
if [[ "${err}" == *'backup.sh is not next to run-in-nextcloud.sh'* ]]; then ok "${case_label}: stderr says which file is missing"; else bad "${case_label}: stderr should say backup.sh is not next to run-in-nextcloud.sh" "$(dump_case)"; fi

# ---- sections for the other scripts go above this line ----

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo
echo "nextcloud-scripts: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
