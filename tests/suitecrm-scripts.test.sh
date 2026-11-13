#!/bin/bash
# ============================================================================
# SuiteCRM skill: the scripts in plugins/suitecrm/skills/suitecrm/scripts/
# ============================================================================
# Runs every script of the plugin against a real SuiteCRM 8.10.2 in Docker: a MariaDB container, a SuiteCRM
# container with the clouve-ops sshd, and a stand-in for the Magneto Agent that has the sibling settings in
# its login shells, a fake clv-secret and the plugin mounted where the agent stages it. The scripts run in
# the agent container as its non-root user, exactly as the assistant runs them, and reach SuiteCRM over SSH.
# Only verify-health.sh also asks the database over TCP. tests/lib/suitecrm-stack/ has the stack.
#
# Sections (SC_TEST_ONLY="name name" runs only those):
#   runner     run-in-suitecrm.sh: --check, every refusal while the image's state says it is installing,
#              upgrading, restoring or waiting (each script of the skill is tried), the notice of its direct
#              forms, the ssh failure code, usage, no files left behind, a bean script that refuses to run as root
#   console    console.sh: the allow-list, each refused command, the held scheduler
#   records    records.sh: create, get, update, link, list, the duplicate stop, bad input, module logic and
#              audit, delete (preview, then yes) and undelete with its links and email address, who a record
#              is assigned to, and amounts and dates under an admin profile with a comma decimal and
#              day-first dates
#   sql        sql-read.sh: a pipeline query, every refusal, and every way round it that a review found: a
#              second statement, the client's backslash commands, a quote in a backticked name, hashes, session
#              ids and tokens read directly, computed, through a subquery or one character at a time
#   users      users.sh, temp-password.sh, restore-admin-password.sh: accounts, roles, groups, the private
#              file, real sign-ins with a temporary password under each password rule, the yes flags, what a
#              change replaced, an owner-only role proven with SuiteCRM's own access checks, the main admin's
#              protection and the way back for a locked-out admin
#   email      email.sh: the system account without its password, the auth_type trap, a test message to a
#              local SMTP sink, and users.sh invite through it
#   import     import-csv.sh: the plan (mapping, rows, duplicates, accounts it would create, owners, formula
#              cells, workflows that run), the plan's id and the file's checksum at the run, the receipts, and
#              an undo that removes one named run once and refuses every other case
#   packages   packages.sh and repair.sh: vetting a package, installing the inspected file and uninstalling it,
#              the repair's dry run and its run
#   scheduler  scheduler.sh: status, what is queued, the held scheduler (the hold file and the image's
#              setting) and its release
#   backup     backup.sh and restore.sh through run-in-suitecrm.sh: a backup's files, modes and checks, the
#              restore's preview and run, the held scheduler and the marker, one at a time, folders and
#              archives root does not trust, --detach and --status, and a restore onto an empty volume
#   health     verify-health.sh and upgrade-state.sh: green, amber and red, the kept upgrade backup, a skipped
#              upgrade, a waiting container, a state folder that is not root's, the Manual Migration Tasks
#   sweep      no password of the stack, and no temporary password, in any process's arguments on the agent
#              or in the SuiteCRM container during the whole run, or in anything a script printed
#
# Settings:
#   SC_TEST_ONLY     sections to run (default: all)
#   SC_TEST_REUSE    the ID of a stack that is already up (sc_stack_up ID); it is used and left running
#   SC_TEST_KEEP=1   leave the stack up at the end, for a look around
#   SC_STACK_*       see tests/lib/suitecrm-stack/stack.sh (SC_STACK_APP_IMAGE runs it on Clouve's own image)
#
# Needs docker, jq and the image named in SC_STACK_BASE_IMAGE (exit 3 when it is not on this machine).
# Publishes no port, pushes nothing, and removes its containers, network and volumes when it ends.
#
# Usage: bash tests/suitecrm-scripts.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: the checks hand literal "$HOME" and the like to the scripts on purpose.
# shellcheck disable=SC2016

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "${here}/lib/suitecrm-stack/stack.sh"
S=/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts
work="$(mktemp -d "${TMPDIR:-/tmp}/suitecrm-scripts-test.XXXXXX")"

for tool in docker jq; do
    command -v "${tool}" > /dev/null || { echo "suitecrm-scripts: this test needs ${tool} on PATH" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 25 | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }
wants() {
    [ -z "${SC_TEST_ONLY:-}" ] && return 0
    case " ${SC_TEST_ONLY} " in *" $1 "*) return 0 ;; esac
    return 1
}

cleanup() {
    if [ -n "${second_id:-}" ]; then (SC_ID="${second_id}"; sc_names; sc_stack_down); fi
    if [ -n "${busy_box:-}" ]; then docker rm -f "${busy_box}" > /dev/null 2>&1; fi
    if [ -z "${SC_TEST_REUSE:-}" ] && [ "${SC_TEST_KEEP:-0}" != 1 ]; then sc_stack_down; fi
    rm -rf "${work}"
}
trap cleanup EXIT

# sc_names: the names sc_stack_up gives the stack SC_ID
sc_names() {
    SC_NET="${SC_STACK_PREFIX}-net-${SC_ID}"
    SC_DB="${SC_STACK_PREFIX}-db-${SC_ID}"
    SC_APP="${SC_STACK_PREFIX}-app-${SC_ID}"
    SC_AGENT="${SC_STACK_PREFIX}-agent-${SC_ID}"
    SC_VOL_APP="${SC_STACK_PREFIX}-appdata-${SC_ID}"
    SC_VOL_DB="${SC_STACK_PREFIX}-dbdata-${SC_ID}"
}

sc_stack_build || exit $?
if [ -n "${SC_TEST_REUSE:-}" ]; then
    SC_ID="${SC_TEST_REUSE}"
    sc_names
else
    echo "Starting the stack..."
    sc_stack_up "t$$" || { echo "suitecrm-scripts: the stack did not start" >&2; exit 1; }
fi
main_id="${SC_ID}"

# Everything a script printed, for the sweep
all_output="${work}/all-output.log"
: > "${all_output}"

# run CMD: runs CMD in the agent as its user; out, err and rc hold the result
run() {
    sc_agent "$1" > "${work}/out" 2> "${work}/err"
    rc=$?
    out="$(cat "${work}/out")"
    err="$(cat "${work}/err")"
    cat "${work}/out" "${work}/err" >> "${all_output}"
}
# run_in TEXT CMD: the same, with TEXT on CMD's stdin
run_in() {
    printf '%s' "$1" | sc_agent_stdin "$2" > "${work}/out" 2> "${work}/err"
    rc=$?
    out="$(cat "${work}/out")"
    err="$(cat "${work}/err")"
    cat "${work}/out" "${work}/err" >> "${all_output}"
}
# is_rc N LABEL
is_rc() {
    if [ "${rc}" -eq "$1" ]; then ok "$2"; else bad "$2 (exit ${rc}, wanted $1)" "${out}"$'\n'"${err}"; fi
}
# has STREAM TEXT LABEL: STREAM is out or err
has() {
    local text
    if [ "$1" = out ]; then text="${out}"; else text="${err}"; fi
    if [[ "${text}" == *"$2"* ]]; then ok "$3"; else bad "$3" "wanted: $2"$'\n'"got: ${text}"; fi
}
hasnt() {
    local text
    if [ "$1" = out ]; then text="${out}"; else text="${err}"; fi
    if [[ "${text}" != *"$2"* ]]; then ok "$3"; else bad "$3" "did not want: $2"; fi
}
# json FILTER WANT LABEL: jq -r FILTER on out equals WANT
json() {
    local got
    got="$(printf '%s' "${out}" | jq -r "$1" 2>&1)"
    if [ "${got}" = "$2" ]; then ok "$3"; else bad "$3" "jq $1 gave: ${got}"$'\n'"wanted: $2"$'\n'"err: ${err}"; fi
}
# val FILTER: prints jq -r FILTER on out
val() { printf '%s' "${out}" | jq -r "$1" 2> /dev/null; }
# sql_is SQL WANT LABEL: the database, read directly
sql_is() {
    local got
    got="$(sc_db_sql "$1" 2>&1)"
    if [ "${got}" = "$2" ]; then ok "$3"; else bad "$3" "the database gave: ${got}"$'\n'"wanted: $2"; fi
}
# login_code USER PASSWORD: the HTTP code of a real sign-in, tried from inside the SuiteCRM container. The
# password goes to curl in a file, so that this test puts none in an argument list either.
login_code() {
    printf '{"username":%s,"password":%s}' "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "$2" '$v')" \
        | docker exec -i "${SC_APP}" bash -c 'j=$(mktemp); b=$(mktemp); cat > "$b"; curl -s -o /dev/null -c "$j" http://localhost/session-status; x=$(awk "\$6==\"XSRF-TOKEN\"{print \$7}" "$j"); curl -s -o /dev/null -w "%{http_code}" -b "$j" -c "$j" -H "Content-Type: application/json" -H "X-XSRF-TOKEN: $x" --data @"$b" http://localhost/login; rm -f "$j" "$b"'
}

# The argv samplers: every process's arguments, in both containers, for the whole run
sampler='echo $$ > /tmp/argv-sample.pid; while :; do cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " " >> /tmp/argv-sample.log; echo >> /tmp/argv-sample.log; sleep 0.05; done'
docker exec -d "${SC_AGENT}" bash -c "rm -f /tmp/argv-sample.log; ${sampler}"
docker exec -d "${SC_APP}" bash -c "rm -f /tmp/argv-sample.log; ${sampler}"

# fixture NAME.php [ARG...]: runs a fixture from tests/lib/suitecrm-stack/fixtures in the SuiteCRM container as www-data,
# with this shell's stdin
docker exec "${SC_APP}" rm -rf /tmp/fixtures
docker cp "${here}/lib/suitecrm-stack/fixtures" "${SC_APP}:/tmp/fixtures" > /dev/null
docker cp "${SC_STACK_PLUGIN}/skills/suitecrm/scripts/remote/boot.php" "${SC_APP}:/tmp/fixtures/boot.php" > /dev/null
fixture() {
    if ! docker exec -i -u www-data "${SC_APP}" php "/tmp/fixtures/$1" "${@:2}" > "${work}/fixture.out" 2>&1; then
        bad "(fixture $1 ran)" "$(cat "${work}/fixture.out")"
    fi
}

# The state folder of the image, and helpers to fake its states
state_dir=/var/www/html/tmp/clouve-backup
# The folder is root's with mode 700: tmp/ has the set-group-ID bit, which a new folder takes over, and the
# leading zeros clear it.
set_state() { sc_app_root "install -d -m 700 ${state_dir} && chown root:root ${state_dir} && chmod 00700 ${state_dir} && $1"; }

# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
if wants runner; then
    section "run-in-suitecrm.sh"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "--check passes on a running SuiteCRM"
    run "$S/run-in-suitecrm.sh"
    is_rc 64 "no arguments is a usage error"
    run "$S/run-in-suitecrm.sh verify-health.sh"
    is_rc 64 "a script that is not backup.sh or restore.sh is refused"
    run "$S/run-in-suitecrm.sh php ../../etc/passwd"
    is_rc 64 "a php name with a path in it is refused"
    run "$S/run-in-suitecrm.sh php nothing.php"
    is_rc 64 "a php script the skill does not have is refused"
    run "$S/run-in-suitecrm.sh --status nonsense"
    is_rc 64 "--status of something that is not a job's name is refused"
    run "SUITECRM_HOST=no-such-host.invalid $S/run-in-suitecrm.sh --check"
    is_rc 255 "an unreachable host is exit 255"
    has err "ssh to clouve-ops@no-such-host.invalid failed" "and says that ssh failed"
    run "CLOUVE_OPS_PASSWORD=wrong-password $S/run-in-suitecrm.sh --check"
    is_rc 255 "a wrong ops password is exit 255"
    run "unset SUITECRM_HOST; $S/run-in-suitecrm.sh --check"
    is_rc 1 "a missing SUITECRM_HOST is exit 1"

    # The runner's direct forms run, but say that the skill's checks are not in them. The skill's own scripts
    # name themselves in SC_SKILL_CALLER and get no such line.
    direct_note="the skill's own checks (the yes flags, the plan, the backup rule) don't apply to it"
    run "$S/run-in-suitecrm.sh php records.php fields Leads"
    is_rc 0 "the runner's php form still runs"
    has err "${direct_note}" "and says on stderr that the skill's checks don't apply to it"
    has err "Use records.sh" "and names the script to use"
    if [ "$(grep -c "don't apply" <<< "${err}")" = 1 ]; then ok "in one line"; else bad "in one line" "${err}"; fi
    json '.module' Leads "its output on stdout is the script's own, unchanged"
    run "$S/run-in-suitecrm.sh console suitecrm:version"
    is_rc 0 "the runner's console form still runs"
    has err "${direct_note}" "and says the same"
    has err "Use console.sh" "and names console.sh"
    run "$S/run-in-suitecrm.sh --allow-busy admin state"
    is_rc 0 "the runner's admin form still runs"
    has err "${direct_note}" "and says the same"
    has err "upgrade-state.sh" "and names the scripts that read the state"
    run "$S/records.sh fields Leads"
    is_rc 0 "records.sh fields runs"
    hasnt err "don't apply" "without that line: the script names itself to the runner"
    run "$S/console.sh suitecrm:version"
    is_rc 0 "console.sh suitecrm:version runs"
    hasnt err "don't apply" "without that line"
    run "$S/email.sh status"
    hasnt err "don't apply" "and email.sh status prints none either"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    hasnt err "don't apply" "backup.sh through the runner is no direct form"
    run "$S/run-in-suitecrm.sh --help"
    is_rc 0 "--help prints the usage"
    has out "don't apply" "which says that the skill's checks don't apply to the direct forms"

    # Every state of the image that means "hands off", and every script of the skill under one of them
    every_script=(
        "$S/run-in-suitecrm.sh --check"
        "$S/run-in-suitecrm.sh backup.sh"
        "$S/run-in-suitecrm.sh backup.sh --list"
        "$S/run-in-suitecrm.sh restore.sh --backup 20260101-000000"
        "$S/console.sh suitecrm:version"
        "$S/records.sh list Accounts"
        "$S/sql-read.sh 'SELECT 1'"
        "$S/users.sh list"
        "$S/temp-password.sh --yes-reset nobody"
        "$S/restore-admin-password.sh --yes-reset"
        "$S/email.sh status"
        "$S/import-csv.sh last Accounts"
        "$S/packages.sh list"
        "$S/repair.sh"
        "$S/scheduler.sh status"
    )
    sc_app_root 'touch /var/www/html/.clouve-install-in-progress'
    for cmd in "${every_script[@]}"; do
        run "${cmd}"
        short="${cmd#"$S"/}"
        if [ "${rc}" -eq 75 ] && [[ "${err}" == *"being installed"* ]]; then ok "refused during an install: ${short}"; else bad "refused during an install: ${short} (exit ${rc})" "${err}"; fi
    done
    run "ls ~/suitecrm-passwords 2>/dev/null | wc -l"
    has out "0" "temp-password.sh left no password file behind when it was refused"
    sc_app_root 'rm -f /var/www/html/.clouve-install-in-progress'

    for phase in backup upgrade restore; do
        set_state "printf 'phase=%s\nfrom=8.9.1\nto=8.10.2\n' ${phase} > ${state_dir}/state"
        run "$S/records.sh list Accounts"
        if [ "${rc}" -eq 75 ] && [[ "${err}" == *"being upgraded by the image (phase: ${phase})"* ]]; then ok "refused while the upgrade's phase is ${phase}"; else bad "refused while the upgrade's phase is ${phase} (exit ${rc})" "${err}"; fi
    done
    run "$S/run-in-suitecrm.sh restore.sh --backup 20260101-000000 --yes-replace-current-data"
    is_rc 75 "a restore is refused while the image upgrades"
    set_state "printf 'phase=as-is\nfrom=unfinished\nto=8.10.2\n' > ${state_dir}/state"
    run "$S/records.sh list Accounts"
    is_rc 75 "refused while the upgrade's phase is as-is"
    has err "(phase: as-is)" "and names the phase"
    has err "staff" "and says that staff are finishing an upgrade by hand"
    set_state "printf 'phase=failed\nbuild=abc\n' > ${state_dir}/state"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "a failed upgrade is not busy: the old version runs and can be worked on"
    set_state "rm -f ${state_dir}/state; touch ${state_dir}/upgrade-in-progress"
    run "$S/users.sh list"
    is_rc 75 "refused while the image's upgrade-in-progress marker is there"
    set_state "rm -f ${state_dir}/upgrade-in-progress"

    # The restore marker, in the image's state folder: a restore is under way, or was cut off
    set_state "echo 'restore of 20200101-000000 started' > ${state_dir}/restore-in-progress"
    run "$S/records.sh list Accounts"
    is_rc 75 "refused while this skill's restore marker is there"
    has err "${state_dir}/restore-in-progress" "and names the marker"
    has err "under way or was cut off" "and says that a restore is under way or was cut off"
    has err "Run the restore again" "and says to run it again"
    run "$S/run-in-suitecrm.sh backup.sh"
    is_rc 75 "a new backup is refused while the marker is there"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    is_rc 0 "the backups can be listed while the marker is there"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 3 "and restore.sh runs (it then finds no such backup)"
    set_state "rm -f ${state_dir}/restore-in-progress"
    # The name an earlier version of this skill gave the marker
    sc_app_root "install -d -m 700 /var/www/html/tmp/clouve-skill-backups && touch /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS"
    run "$S/records.sh list Accounts"
    is_rc 75 "the marker's earlier name, RESTORE-IN-PROGRESS in the backups folder, is still honoured"
    has err "RESTORE-IN-PROGRESS" "and named"
    sc_app_root "rm -f /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "--check passes again once the markers are gone"

    # What makes the state folder trusted is who owns it and who can write in it. A folder of root's with mode
    # 2700 is trusted: a folder made in tmp/ takes over tmp/'s set-group-ID bit. One that its group can write
    # in is not.
    set_state "chmod 2700 ${state_dir} && echo 'cut off' > ${state_dir}/restore-in-progress"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 75 "a state folder of root's with mode 2700 is trusted: the marker in it is read"
    has err "under way or was cut off" "and the refusal is the marker's"
    set_state "rm -f ${state_dir}/restore-in-progress; chmod 2700 ${state_dir}"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "and without the marker --check passes on that folder"
    set_state "chmod 00770 ${state_dir} && echo 'cut off' > ${state_dir}/restore-in-progress"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "a state folder of root's that its group can write in is not trusted: the marker in it is not read"
    run "$S/run-in-suitecrm.sh --allow-busy admin state"
    has out "state_dir=untrusted" "and the state report calls the folder untrusted"
    set_state "rm -f ${state_dir}/restore-in-progress"

    # A state folder that the web user planted: nothing in it is believed, neither a phase nor a marker nor a
    # hold, and nothing in it is changed
    sc_app_root "if [ -e ${state_dir} ]; then mv ${state_dir} ${state_dir}.runner-test-keep; fi"
    sc_app_www "mkdir ${state_dir} && printf 'phase=upgrade\n' > ${state_dir}/state && touch ${state_dir}/restore-in-progress ${state_dir}/upgrade-in-progress"
    run "$S/records.sh list Accounts"
    is_rc 0 "a phase and a marker in a state folder that is not root's are not believed"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "and --check passes"
    run "$S/console.sh schedulers:run"
    is_rc 64 "a scheduler pass by hand is refused there: whether the scheduler is held can't be read"
    has err "is not a folder of root's that others can't write in" "and the refusal says that the folder is not trusted"
    has err "Clouve support" "and whose job that is"
    planted="$(sc_app_root "stat -c '%U' ${state_dir}; ls ${state_dir} | tr '\n' ' '; cat ${state_dir}/state")"
    if [ "${planted}" = "www-data"$'\n'"restore-in-progress state upgrade-in-progress phase=upgrade" ]; then ok "the folder is left as it was found"; else bad "the folder is left as it was found" "${planted}"; fi
    sc_app_root "rm -rf ${state_dir}; if [ -e ${state_dir}.runner-test-keep ]; then mv ${state_dir}.runner-test-keep ${state_dir}; fi"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "--check passes with the image's own folder back"

    # A container whose PID 1 is not Apache: the image's start-up is still running, or it waits
    busy_box="${SC_STACK_PREFIX}-busy-${main_id}"
    docker run -d --name "${busy_box}" --network "${SC_NET}" --memory 512m --entrypoint bash "$(sc_stack_app_image)" \
        -c 'ssh-keygen -A >/dev/null; mkdir -p /run/sshd; /usr/sbin/sshd; exec sleep infinity' > /dev/null
    docker exec -i "${busy_box}" bash -c 'IFS= read -r p; printf "clouve-ops:%s\n" "$p" | chpasswd' <<< "${SC_PW_OPS}"
    sleep 2
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh --check"
    is_rc 75 "refused while PID 1 is not Apache"
    has err "still starting, or waiting" "and says the container is still starting, or waiting"
    has err "upgrade-state.sh says which" "and that upgrade-state.sh says which"
    run "SUITECRM_HOST=${busy_box} $S/records.sh list Accounts"
    is_rc 75 "a script that reads or changes CRM data is refused there"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh backup.sh"
    is_rc 75 "and so is a new backup"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh --allow-busy --check"
    is_rc 0 "a script that passes --allow-busy runs there"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh backup.sh --list"
    is_rc 0 "the backups can be listed there"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 75 "a restore does not start there when none was cut off"
    has err "still starting, or waiting" "and says why"
    # The image marks which wait it is in with a file of root's in /run
    docker exec "${busy_box}" touch /run/clouve-suitecrm-attention
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh --check"
    is_rc 75 "refused while the image waits for a person"
    has err "must not start" "and the refusal says that the image found a site it must not start"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 3 "a restore may start there: the image goes on when its marker appears (here it finds no such backup)"
    docker exec "${busy_box}" bash -c 'rm -f /run/clouve-suitecrm-attention; touch /run/clouve-suitecrm-restoring'
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh --check"
    is_rc 75 "refused while the image shows its restore page and no marker is there"
    has err "after a restore" "and the refusal says that the start goes on after a restore"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 75 "a new restore does not start in that moment"
    docker exec "${busy_box}" rm -f /run/clouve-suitecrm-restoring
    docker exec "${busy_box}" bash -c 'mkdir -p /var/www/html/tmp/clouve-backup && chown root:root /var/www/html/tmp/clouve-backup && chmod 00700 /var/www/html/tmp/clouve-backup && touch /var/www/html/tmp/clouve-backup/restore-in-progress'
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh --check"
    is_rc 75 "with a restore marker there the container counts as waiting for the restore"
    has err "under way or was cut off" "and the refusal says so"
    run "SUITECRM_HOST=${busy_box} $S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 3 "and restore.sh runs although PID 1 is not Apache (it then finds no such backup)"
    docker rm -f "${busy_box}" > /dev/null 2>&1
    busy_box=''

    # The bean scripts run as the web user only: started by hand as root they would leave root-owned cache files
    root_run="$(docker exec "${SC_APP}" php -r 'require "/tmp/fixtures/boot.php"; echo "booted as root";' 2>&1)"
    root_rc=$?
    if [ "${root_rc}" -eq 64 ] && [[ "${root_run}" != *"booted as root"* ]] && [[ "${root_run}" == *"www-data"* ]]; then ok "a bean script started as root refuses to run and names the web user"; else bad "a bean script started as root refuses to run and names the web user (exit ${root_rc})" "${root_run}"; fi

    left="$(sc_app_root 'ls -d /tmp/clv-sc.* 2>/dev/null | wc -l')"
    if [ "${left}" = 0 ]; then ok "no unpacked scripts are left in the container's /tmp"; else bad "no unpacked scripts are left in the container's /tmp" "${left} folders"; fi
fi

# ---------------------------------------------------------------------------
# console
# ---------------------------------------------------------------------------
if wants console; then
    section "console.sh"
    run "$S/console.sh suitecrm:version"
    is_rc 0 "suitecrm:version runs"
    has out "8.10.2" "and prints the version"
    run "$S/console.sh schedulers:show"
    is_rc 0 "schedulers:show runs"
    has out "Process Workflow Tasks" "and lists the scheduled jobs"
    run "$S/console.sh cache:clear"
    is_rc 0 "cache:clear runs"
    owner="$(sc_app_root 'find /var/www/html/cache ! -user www-data | wc -l')"
    if [ "${owner}" = 0 ]; then ok "the cache still belongs to www-data"; else bad "the cache still belongs to www-data" "${owner} files do not"; fi
    for cmd in "dbal:run-sql 'DELETE FROM accounts'" "doctrine:schema:drop --force" "doctrine:database:drop --force" \
        "suitecrm:app:upgrade -t SuiteCRM-8.10.2" "suitecrm:app:install" "secrets:list --reveal" "debug:dotenv" \
        "doctrine:query:sql 'SELECT 1'" "messenger:consume internal-async" "doctrine:migrations:migrate" \
        "cache:clear --env=dev" "nonsense:command" ""; do
        run "$S/console.sh ${cmd}"
        if [ "${rc}" -eq 64 ] && [[ "${err}" == *refused* || "${err}" == *"no console command"* ]]; then ok "refused: ${cmd:-no command}"; else bad "refused: ${cmd:-no command} (exit ${rc})" "${err}"; fi
    done
    run "$S/run-in-suitecrm.sh console doctrine:schema:drop --force"
    is_rc 64 "run-in-suitecrm.sh refuses the same commands when it is called directly"
    sql_is "SELECT COUNT(*) > 100 FROM information_schema.tables WHERE table_schema = 'suitecrm'" 1 "and the tables are all still there"
    set_state "touch ${state_dir}/scheduler-held"
    run "$S/console.sh schedulers:run"
    is_rc 64 "schedulers:run is refused while the scheduler is held"
    has err "held" "and says why"
    set_state "rm -f ${state_dir}/scheduler-held"
fi

# ---------------------------------------------------------------------------
# records
# ---------------------------------------------------------------------------
if wants records; then
    section "records.sh"
    run "$S/records.sh fields Opportunities"
    is_rc 0 "fields lists a module's fields"
    json '.fields.sales_stage.values | index("Closed Won") != null' true "with a dropdown's values"
    json '.fields.amount.required' true "and what is required"

    run_in '{"name": "Globex O'"'"'Hare & Sons \"$HOME\" `id`", "account_type": "Prospect", "email1": "info@globex.example"}' "$S/records.sh create Accounts"
    is_rc 0 "create makes an account"
    acc="$(val .id)"
    json '.name' 'Globex O'"'"'Hare & Sons "$HOME" `id`' "a name with quotes, a \$ and backticks arrives unchanged"
    sql_is "SELECT name FROM accounts WHERE id = '${acc}'" 'Globex O'"'"'Hare & Sons "$HOME" `id`' "and is stored unchanged"
    run_in '{"name": "Globex O'"'"'Hare & Sons \"$HOME\" `id`"}' "$S/records.sh create Accounts"
    is_rc 4 "a second account of the same name is not created"
    json '.likely_duplicates[0].id' "${acc}" "and the existing one is named"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name LIKE 'Globex%'" 1 "nothing was written"
    run_in '{"name": "Globex O'"'"'Hare & Sons \"$HOME\" `id`"}' "$S/records.sh create Accounts --allow-duplicate"
    is_rc 0 "--allow-duplicate creates it after all"
    twin="$(val .id)"

    run_in '{"name": "Initech", "account_type": "Nonsense"}' "$S/records.sh create Accounts"
    is_rc 65 "a value outside a dropdown is refused"
    has err "Its values are" "and the allowed values are listed"
    run_in '{"name": "Initech", "no_such_field": "x"}' "$S/records.sh create Accounts"
    is_rc 65 "a field the module does not have is refused"
    run_in '{"account_type": "Prospect"}' "$S/records.sh create Accounts"
    is_rc 65 "a missing required field is refused"
    run_in 'not json' "$S/records.sh create Accounts"
    is_rc 65 "input that is not JSON is refused"
    run_in '{"name": {"a": 1}}' "$S/records.sh create Accounts"
    is_rc 65 "a nested value is refused"
    sql_is "SELECT COUNT(*) FROM accounts WHERE name = 'Initech'" 0 "none of those wrote anything"
    run "$S/records.sh create Widgets"
    is_rc 64 "a module outside the four is a usage error"

    run_in '{"first_name": "Hank", "last_name": "Scorpio", "email1": "hank@globex.example", "title": "CEO", "account_id": "'"${acc}"'"}' "$S/records.sh create Contacts"
    is_rc 0 "create makes a contact on the account"
    con="$(val .id)"
    json '.links.accounts[0].id' "${acc}" "and it is linked to the account"
    run_in '{"first_name": "Henry", "last_name": "Other", "email1": "HANK@globex.example"}' "$S/records.sh create Contacts"
    is_rc 4 "a contact with the same email address in another case is a likely duplicate"
    run_in '{"last_name": "Solo", "email1": "not-an-address"}' "$S/records.sh create Contacts"
    is_rc 65 "a bad email address is refused"

    run_in '{"name": "Globex reactor", "sales_stage": "Prospecting", "amount": 250000, "date_closed": "2026-12-27"}' "$S/records.sh create Opportunities"
    is_rc 65 "an opportunity without an account is refused"
    run_in '{"name": "Globex reactor", "sales_stage": "Prospecting", "amount": 250000, "date_closed": "2026-12-27", "account_name": "No Such Account"}' "$S/records.sh create Opportunities"
    is_rc 65 "an account name that matches nothing is refused"
    sql_is "SELECT COUNT(*) FROM accounts WHERE name = 'No Such Account'" 0 "and no account is created by name"
    run_in '{"name": "Globex reactor", "sales_stage": "Prospecting", "amount": 250000, "date_closed": "27/12/2026", "account_id": "'"${acc}"'"}' "$S/records.sh create Opportunities"
    is_rc 65 "a date that is not YYYY-MM-DD is refused"
    run_in '{"name": "Globex reactor", "sales_stage": "Prospecting", "amount": 250000, "date_closed": "2026-12-27", "account_id": "'"${acc}"'"}' "$S/records.sh create Opportunities"
    is_rc 0 "create makes an opportunity"
    opp="$(val .id)"
    json '.fields.probability' 10 "SuiteCRM's own logic set the probability from the sales stage"
    json '.fields.date_closed' 2026-12-27 "the closing date reads back as it was sent"
    json '.links.accounts[0].id' "${acc}" "and it is linked to the account"

    run_in '{"sales_stage": "Negotiation/Review", "amount": 300000}' "$S/records.sh update Opportunities ${opp}"
    is_rc 0 "update changes fields"
    json '.changed.sales_stage.before' Prospecting "and reports the value before"
    json '.changed.sales_stage.after' Negotiation/Review "and after"
    json '.changed.probability.after' 80 "the probability follows the new stage, as it does in the browser"
    run_in '{"sales_stage": "Proposal/Price Quote", "probability": 55}' "$S/records.sh update Opportunities ${opp}"
    json '.changed.probability.after' 55 "a probability that is sent with the stage is kept"
    sql_is "SELECT COUNT(*) FROM opportunities_audit WHERE parent_id = '${opp}' AND field_name = 'sales_stage'" 2 "both changes are in SuiteCRM's audit trail"
    run_in '{"sales_stage": "Won it"}' "$S/records.sh update Opportunities ${opp}"
    is_rc 65 "update refuses a value outside the dropdown"
    run_in '{"amount": 1}' "$S/records.sh update Opportunities 00000000-0000-0000-0000-000000000000"
    is_rc 3 "update of a record that is not there is exit 3"

    run "$S/records.sh link Opportunities ${opp} contacts ${con} --role 'Primary Decision Maker'"
    is_rc 0 "link ties the contact to the opportunity with a role"
    sql_is "SELECT contact_role FROM opportunities_contacts WHERE deleted = 0 AND opportunity_id = '${opp}' AND contact_id = '${con}'" "Primary Decision Maker" "the role is stored"
    run "$S/records.sh link Opportunities ${opp} contacts ${con} --role Boss"
    is_rc 65 "a role outside the list is refused"
    run "$S/records.sh link Accounts ${acc} leads ${con}"
    is_rc 64 "a link the script does not set is a usage error"
    run "$S/records.sh get Contacts ${con}"
    is_rc 0 "get reads the contact"
    json '.links.opportunities[0].id' "${opp}" "with its opportunity"
    json '.fields.email1' hank@globex.example "and its email address"

    run "$S/records.sh list Accounts --search \"O'Hare\""
    is_rc 0 "list searches by name"
    json '.total' 2 "and counts the matches"
    run "$S/records.sh list Contacts --search hank@globex"
    json '.records[0].account' 'Globex O'"'"'Hare & Sons "$HOME" `id`' "a contact is found by email address, with its account"
    run "$S/records.sh list Accounts --limit 5000"
    is_rc 64 "a limit of four digits is a usage error"

    run "$S/records.sh delete Contacts ${con}"
    is_rc 0 "delete without --yes-delete is a preview"
    json '.deleted' false "that deletes nothing"
    has err "nothing was deleted" "and says so"
    sql_is "SELECT deleted FROM contacts WHERE id = '${con}'" 0 "the record is untouched"
    run "$S/records.sh delete Contacts ${con} --yes-delete"
    is_rc 0 "delete with --yes-delete marks it deleted"
    has out "records.sh undelete Contacts ${con}" "and prints how to bring it back"
    sql_is "SELECT deleted FROM contacts WHERE id = '${con}'" 1 "the row stays, marked deleted"
    run "$S/records.sh get Contacts ${con}"
    is_rc 3 "a deleted record is no longer found"
    run "$S/records.sh list Contacts --deleted"
    json '.records[0].id' "${con}" "list --deleted shows it"
    run "$S/records.sh undelete Contacts ${con}"
    is_rc 0 "undelete brings it back"
    json '.fields.email1' hank@globex.example "with its email address"
    json '.links.accounts[0].id' "${acc}" "its account"
    json '.links.opportunities[0].id' "${opp}" "and its opportunity"
    sql_is "SELECT contact_role FROM opportunities_contacts WHERE deleted = 0 AND opportunity_id = '${opp}' AND contact_id = '${con}'" "Primary Decision Maker" "the role on the opportunity is back too"
    run "$S/records.sh undelete Contacts ${con}"
    is_rc 2 "undelete of a record that is not deleted is refused"
    run "$S/records.sh unlink Opportunities ${opp} contacts ${con}"
    is_rc 0 "unlink removes the link"
    sql_is "SELECT COUNT(*) FROM opportunities_contacts WHERE deleted = 0 AND opportunity_id = '${opp}'" 0 "and both records stay"
    run "$S/records.sh delete Accounts ${twin} --yes-delete"
    is_rc 0 "the duplicate account is deleted again"
    run "$S/records.sh delete Accounts '${acc}; id' --yes-delete"
    is_rc 64 "an id with shell characters is a usage error"
    # Who owns a new record
    run_in '{"name": "Format Test Ltd"}' "$S/records.sh create Accounts"
    fmt_acc="$(val .id)"
    json '.assigned_to' "${SC_ADMIN_USER}" "create says who the record was assigned to"
    json '.assigned_by_default' true "and that it went to the main admin because no owner was sent"
    has err "assigned to the main admin" "and says so in words"
    run_in '{"last_name": "Owned", "assigned_user_name": "'"${SC_ADMIN_USER}"'"}' "$S/records.sh create Leads"
    json '.assigned_by_default' false "an owner that was sent is not a default"

    # Numbers and dates, with the main admin's profile set to 1.234,56, day-first dates and Europe/Berlin
    fixture records-profile.php european < /dev/null
    profile_before="$(sc_db_sql "SELECT MD5(contents) FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global' AND deleted = 0")"
    run_in '{"name": "Format deal", "sales_stage": "Prospecting", "amount": "1234.56", "date_closed": "2026-12-27", "account_id": "'"${fmt_acc}"'"}' "$S/records.sh create Opportunities"
    is_rc 0 "create works when the main admin's profile has a comma as the decimal symbol and day-first dates"
    fmt_opp="$(val .id)"
    json '.fields.amount' 1234.56 "an amount sent as \"1234.56\" reads back as sent"
    json '.fields.date_closed' 2026-12-27 "and so does the closing date"
    sql_is "SELECT amount, date_closed FROM opportunities WHERE id = '${fmt_opp}'" $'1234.56\t2026-12-27' "both are stored as sent (the amount is not 100 times too large)"
    run_in '{"amount": 2500.75, "probability": 12, "date_closed": "2027-01-31"}' "$S/records.sh update Opportunities ${fmt_opp}"
    is_rc 0 "update works under that profile"
    json '.changed.amount.before' 1234.56 "update reports the amount before as it is stored"
    json '.changed.amount.after' 2500.75 "an amount sent as the number 2500.75 reads back as sent"
    json '.changed.date_closed.after' 2027-01-31 "a date reads back as YYYY-MM-DD"
    sql_is "SELECT amount, probability, date_closed FROM opportunities WHERE id = '${fmt_opp}'" $'2500.75\t12\t2027-01-31' "and all three are stored as sent"
    run_in '{"probability": "12.5"}' "$S/records.sh update Opportunities ${fmt_opp}"
    is_rc 65 "a fraction in a field that holds whole numbers is refused (SuiteCRM would cut it, or read it as 125)"
    has err "whole number" "and the refusal says what the field takes"
    run_in '{"amount": "1.234,56"}' "$S/records.sh update Opportunities ${fmt_opp}"
    is_rc 65 "a number written the profile's way is refused"
    sql_is "SELECT amount, probability FROM opportunities WHERE id = '${fmt_opp}'" $'2500.75\t12' "neither wrote anything"
    run "$S/records.sh get Opportunities ${fmt_opp}"
    json '.fields.amount' 2500.75 "get prints the amount with a decimal point"
    json '.fields.date_closed' 2027-01-31 "the date as YYYY-MM-DD"
    json '.fields.date_entered' "$(sc_db_sql "SELECT date_entered FROM opportunities WHERE id = '${fmt_opp}'")" "and date_entered as the database's UTC value"
    run "$S/records.sh list Opportunities --search 'Format deal'"
    json '.records[0].amount' 2500.75 "list prints the amount with a decimal point"
    json '.records[0].date_closed' 2027-01-31 "and the date as YYYY-MM-DD"
    profile_after="$(sc_db_sql "SELECT MD5(contents) FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global' AND deleted = 0")"
    if [ -n "${profile_before}" ] && [ "${profile_before}" = "${profile_after}" ]; then ok "the main admin's stored profile is unchanged by all of that"; else bad "the main admin's stored profile is unchanged by all of that" "before ${profile_before}, after ${profile_after}"; fi
    fixture records-profile.php restore < /dev/null
fi

# ---------------------------------------------------------------------------
# sql
# ---------------------------------------------------------------------------
if wants sql; then
    section "sql-read.sh"
    sql_from="$(wc -c < "${all_output}")"
    # sql_refused QUERY [LABEL]: the query, sent on stdin, is refused (exit 64, "refused" on stderr) and prints no row
    sql_refused() {
        run_in "$1" "$S/sql-read.sh"
        if [ "${rc}" -eq 64 ] && [[ "${err}" == *refused* ]] && [ -z "${out}" ]; then ok "refused: ${2:-$1}"; else bad "refused: ${2:-$1} (exit ${rc})" "${out}"$'\n'"${err}"; fi
    }
    # sql_unanswered QUERY LABEL TEXT...: the query ends non-zero, and neither stream holds one of the TEXTs
    sql_unanswered() {
        local q="$1" label="$2" t leak=''
        shift 2
        run_in "${q}" "$S/sql-read.sh"
        for t in "$@"; do
            if [[ "${out}${err}" == *"${t}"* ]]; then leak="${t}"; fi
        done
        if [ "${rc}" -ne 0 ] && [ -z "${leak}" ]; then ok "${label}"; else bad "${label} (exit ${rc}${leak:+, printed ${leak}})" "$(printf '%s\n%s' "${out}" "${err}" | cut -c1-200)"; fi
    }

    run_in '{"name": "Pipeline Co"}' "$S/records.sh create Accounts"
    pacc="$(val .id)"
    run_in '{"name": "Müller GmbH"}' "$S/records.sh create Accounts"
    run_in '{"name": "Deal A", "sales_stage": "Qualification", "amount": 18000, "date_closed": "2026-12-02", "account_id": "'"${pacc}"'"}' "$S/records.sh create Opportunities"
    run_in '{"name": "Deal B", "sales_stage": "Closed Lost", "amount": 5000, "date_closed": "2026-10-02", "account_id": "'"${pacc}"'"}' "$S/records.sh create Opportunities"
    # What must never come out: a package's table with tokens in it, a stored function that reads one, a view
    # over the password hashes, an OAuth client's secret, and a signed-in user's session id in tracker. All made
    # up, and removed at the end.
    tok1='tok-Qm7Zp2Xv9Lk4'
    tok2='tok-Hd3Ws8Bn6Yc1'
    sess='5e55a1b2c3d4e5f6a7b8c9d0e1f2a3b4'
    osec='oauth-Secret-Tz4Kq8Wn'
    sc_db_sql "CREATE TABLE clv_test_pkg (id INT PRIMARY KEY, access_token VARCHAR(40), note VARCHAR(40));
        INSERT INTO clv_test_pkg VALUES (1, '${tok1}', 'first'), (2, '${tok2}', 'second');
        CREATE VIEW clv_test_view AS SELECT user_name, user_hash FROM users;
        CREATE FUNCTION clv_test_fn() RETURNS VARCHAR(60) READS SQL DATA RETURN (SELECT access_token FROM clv_test_pkg WHERE id = 1);
        INSERT INTO oauth2clients (id, name, deleted, secret) VALUES ('clv-test-client', 'Clv Test Client', 1, '${osec}');
        INSERT INTO tracker (monitor_id, user_id, module_name, item_id, item_summary, date_modified, action, session_id, visible, deleted)
            VALUES (UUID(), '1', 'Accounts', '${pacc}', 'Pipeline Co', UTC_TIMESTAMP(), 'detailview', '${sess}', 1, 0)"
    sql_is "SELECT COUNT(*) FROM tracker WHERE session_id = '${sess}'" 1 "(a tracker row with a session id is there)"
    sql_is "SELECT LEFT(user_hash, 4) FROM clv_test_view WHERE user_name = '${SC_ADMIN_USER}'" '$2y$' "(and a view that shows a password hash)"

    # Good paths
    run "$S/sql-read.sh \"SELECT sales_stage, COUNT(*) AS deals, ROUND(SUM(amount_usdollar)) AS total FROM opportunities WHERE deleted = 0 AND name LIKE 'Deal %' AND sales_stage NOT IN ('Closed Won', 'Closed Lost') GROUP BY sales_stage\""
    is_rc 0 "a pipeline question is answered"
    has out $'Qualification\t1\t18000' "with the open deals by stage"
    has out $'sales_stage\tdeals\ttotal' "and a header row"
    run_in "SELECT COUNT(*) AS n FROM accounts WHERE deleted = 0 AND name = 'Pipeline Co';" "$S/sql-read.sh"
    is_rc 0 "the query can come on stdin, with a closing semicolon"
    has out $'n\n1' "and is answered"
    run "$S/sql-read.sh 'SELECT 1 AS one'"
    if [ "${rc}" -eq 0 ] && [ "${out}" = $'one\n1' ] && [ -z "${err}" ]; then ok "a query that is answered prints its rows and nothing on stderr"; else bad "a query that is answered prints its rows and nothing on stderr (exit ${rc})" "${out}"$'\n'"${err}"; fi
    run "$S/sql-read.sh 'SELECT name FROM accounts WHERE 1 = 0'"
    if [ "${rc}" -eq 0 ] && [ "${out}" = name ]; then ok "a query that finds no row prints the header row"; else bad "a query that finds no row prints the header row (exit ${rc})" "${out}"$'\n'"${err}"; fi
    run "$S/sql-read.sh --table 'SELECT 1 AS one'"
    has out "| one |" "--table prints a table"
    has out "|   1 |" "with a number on the right, as the mysql client prints it"
    run "$S/sql-read.sh --max-rows 1 'SELECT name FROM opportunities WHERE deleted = 0 ORDER BY name'"
    lines="$(printf '%s\n' "${out}" | wc -l)"
    if [ "${lines}" -eq 2 ]; then ok "--max-rows caps the rows"; else bad "--max-rows caps the rows" "${out}"; fi
    has err "--max-rows" "and says on stderr that the answer may be cut"
    run "$S/sql-read.sh 'SELECT a.relationship_name FROM relationships a JOIN relationships b LIMIT 6000'"
    lines="$(printf '%s\n' "${out}" | wc -l)"
    if [ "${rc}" -eq 0 ] && [ "${lines}" -eq 5001 ]; then ok "a query's own LIMIT gets 5,000 rows at most"; else bad "a query's own LIMIT gets 5,000 rows at most (exit ${rc}, ${lines} lines)" "${err}"; fi
    has err "5,000" "and stderr says where it stopped"
    run 'unset SUITECRM_DB_HOST SUITECRM_DB_NAME SUITECRM_DB_USER SUITECRM_DATABASE_PORT; '"$S/sql-read.sh 'SELECT 1 AS one'"
    is_rc 0 "it needs no database setting on the agent: the query runs inside SuiteCRM's container"
    run_in "SELECT COUNT(*) AS n /* accounts, not contacts */ FROM accounts -- live ones
        WHERE deleted = 0 AND name = 'Pipeline Co'" "$S/sql-read.sh"
    is_rc 0 "a query with comments in it runs"
    has out $'n\n1' "and is answered"
    run_in "SELECT COUNT(*) AS n FROM accounts WHERE deleted = 0 AND name = 'x; DROP TABLE accounts; --'" "$S/sql-read.sh"
    is_rc 0 "a semicolon and a statement inside a text value are text"
    has out $'n\n0' "and the value is compared as it is"
    run_in "SELECT name FROM accounts WHERE deleted = 0 AND name LIKE 'Müller%'" "$S/sql-read.sh"
    is_rc 0 "a name with an accent is found"
    has out 'Müller GmbH' "and printed as it is stored"
    run_in "SELECT COUNT(*) AS n FROM cases WHERE deleted = 0 AND status = 'Open_New'" "$S/sql-read.sh"
    is_rc 0 "a text value with an underscore in it, as SuiteCRM's own status keys have, is fine"
    run_in "SELECT name FROM accounts WHERE deleted = 0 AND name = \"Pipeline Co\"" "$S/sql-read.sh"
    has out 'Pipeline Co' "a text value in double quotes is text, as the references write it"
    run_in "SELECT 'a\\tb' AS t, 'x\\ny' AS n, NULL AS z, 'c\\\\d' AS b" "$S/sql-read.sh"
    has out $'a\\tb\tx\\ny\tNULL\tc\\\\d' "a tab, a line break and a backslash in a value are escaped, and NULL is NULL"
    run "$S/sql-read.sh 'SELECT COUNT(*) FROM users WHERE deleted = 0'"
    is_rc 0 "counting users is fine"
    run "$S/sql-read.sh 'SELECT user_name, status, system_generated_password, pwd_last_changed FROM users WHERE deleted = 0'"
    is_rc 0 "and so are named columns of users that are not secrets"
    has out "${SC_ADMIN_USER}" "with the rows"
    run "$S/sql-read.sh 'SELECT \`name\` FROM \`accounts\` WHERE deleted = 0 LIMIT 1'"
    is_rc 0 "names in backticks are read as names"
    run "$S/sql-read.sh 'SELECT u.user_name, COUNT(*) AS deals, ROUND(SUM(o.amount_usdollar * o.probability / 100)) AS weighted FROM opportunities o JOIN users u ON u.id = o.assigned_user_id AND u.deleted = 0 WHERE o.deleted = 0 GROUP BY u.user_name'"
    is_rc 0 "a multiplication in a query that joins users is not taken for a select-all"
    has out "${SC_ADMIN_USER}"$'\t' "and the join with users is answered"
    run "$S/sql-read.sh 'SELECT id, name, mail_smtpserver, mail_smtpuser FROM outbound_email WHERE deleted = 0'"
    is_rc 0 "the mail account's server and login can be read"
    run "$S/sql-read.sh 'SELECT id, name, deleted, allowed_grant_type FROM oauth2clients WHERE id = \"clv-test-client\"'"
    is_rc 0 "and an OAuth client's name and grant type"
    has out 'Clv Test Client' "with the row"
    run "$S/sql-read.sh 'SELECT COUNT(*) AS n FROM email_addresses WHERE deleted = 0'"
    is_rc 0 "a table that has one secret-shaped column is read through its other columns"
    run "$S/sql-read.sh 'SELECT nonsense FROM accounts'"
    is_rc 2 "a query the database rejects is exit 2"
    has err "nonsense" "with the database's own message"
    run "$S/sql-read.sh 'SELECT id FROM some_table'"
    is_rc 2 "and so is a table that is not there"
    run "$S/sql-read.sh --max-rows 0 'SELECT 1'"
    is_rc 64 "--max-rows 0 is a usage error"
    run "$S/sql-read.sh 'SELECT 1' 'SELECT 2'"
    is_rc 64 "and so are two queries"

    # A save in SuiteCRM that is still open does not hold a read up: the script's own copy of users takes no row locks
    docker exec -e "MYSQL_PWD=${SC_PW_DB}" "${SC_DB}" mariadb -u suitecrm suitecrm -e "BEGIN; UPDATE users SET title = 'clv-held' WHERE id = '1'; SELECT SLEEP(8); ROLLBACK" > /dev/null 2>&1 < /dev/null &
    writer=$!
    for _ in $(seq 1 50); do
        if [ "$(sc_db_sql "SELECT COUNT(*) FROM information_schema.processlist WHERE info LIKE '%SLEEP(8)%' AND id <> CONNECTION_ID()")" = 1 ]; then break; fi
        sleep 0.1
    done
    started="$(date +%s)"
    run "$S/sql-read.sh 'SELECT COUNT(*) AS n FROM users WHERE title = \"clv-held\"'"
    took=$(($(date +%s) - started))
    if [ "${rc}" -eq 0 ] && [ "${out}" = $'n\n0' ] && [ "${took}" -lt 5 ]; then ok "a query on users is answered at once while a save holds a row of it, and sees only what was committed"; else bad "a query on users is answered at once while a save holds a row of it, and sees only what was committed (exit ${rc}, ${took} s)" "${out}"$'\n'"${err}"; fi
    wait "${writer}"

    # Refusals: writes, more than one statement, files, locks, waits, and every table and column with secrets
    while IFS= read -r q; do
        [ -n "${q}" ] || continue
        sql_refused "${q}"
    done <<'QUERIES'
UPDATE accounts SET name = 'x'
DELETE FROM accounts
INSERT INTO accounts (id) VALUES ('x')
INSERT INTO accounts (id) SELECT id FROM contacts
CREATE TABLE clv_test_made AS SELECT 1
DROP TABLE clv_test_pkg
TRUNCATE clv_test_pkg
SELECT 1; DELETE FROM accounts
SELECT 1; SELECT 2
SELECT name FROM accounts INTO OUTFILE '/tmp/x'
SELECT 1 INTO @v
SELECT * FROM users
SELECT user_name, user_hash FROM users
SELECT mail_smtppass FROM outbound_email
SELECT u.* FROM users u
SELECT secret FROM oauth2clients
SELECT * FROM oauth2clients
SELECT id FROM oauth2tokens
SELECT `user_hash` FROM users
SELECT * FROM `users`
SELECT u.`user_hash` FROM `users` u
SELECT totp_secret FROM users
SELECT user_name, backup_codes FROM users
SELECT stored_options FROM inbound_email
SELECT * FROM inbound_email
SELECT * FROM outbound_email
SELECT LOAD_FILE('/etc/passwd')
SELECT SLEEP(100)
SELECT name FROM accounts WHERE SLEEP(100) = 0
SET GLOBAL general_log = 1
CALL something()
SELECT /*!50000 1; DELETE FROM accounts */ 1
WITH x AS (SELECT 1) DELETE FROM accounts
SELECT name FROM accounts FOR UPDATE
SELECT name FROM accounts LOCK IN SHARE MODE
SELECT * FROM eapm
SELECT * FROM calendar_accounts
SELECT * FROM user_preferences
SELECT * FROM config
SELECT * FROM emails_text
SELECT * FROM oauth2tokens
SELECT category, name FROM config
SELECT COUNT(*) FROM suitecrm.config
SELECT info FROM information_schema.processlist
SELECT MAX(info) FROM INFORMATION_SCHEMA.PROCESSLIST p
SELECT table_name FROM information_schema.tables
SELECT (SELECT MAX(info) FROM information_schema.processlist) AS x
SELECT name FROM accounts WHERE name IN (SELECT info FROM information_schema.processlist)
WITH `x'` AS (SELECT 1) SELECT MAX(info) FROM information_schema.processlist WHERE 'a' = 'a'
SELECT email_address FROM email_addresses WHERE confirm_opt_in_token = 'x'
SELECT name FROM meetings WHERE password IS NOT NULL
SELECT 1 AS `a``b`
SELECT a FROM (WITH `c'` AS (SELECT 1 AS a) SELECT a FROM `c'`) d
SELECT name FROM accounts WHERE description = '`'
SHOW GRANTS
QUERIES
    hasnt err "accounts" "a refusal names the rule, not the query"
    # A lock clause the database's own text of a query does not show. In a subquery, LOCK IN SHARE MODE is in
    # neither the plan's note nor the trace, and a read-only transaction lets it through: it would hold row locks,
    # and a save in SuiteCRM would wait for them. The words are found in the query itself, with comments between
    # them or inside a comment the database runs as SQL.
    for q in "SELECT name FROM accounts WHERE id IN (SELECT id FROM accounts LOCK IN SHARE MODE)" \
        "SELECT (SELECT name FROM accounts LIMIT 1 LOCK IN SHARE MODE) AS n" \
        $'SELECT name FROM accounts WHERE id IN (SELECT id FROM accounts LOCK /* a */ IN /* b */ SHARE -- c\n MODE)' \
        $'SELECT name FROM accounts WHERE id IN (SELECT id FROM accounts lock in share # c\n\tmode)' \
        "SELECT name FROM accounts WHERE id IN (SELECT id FROM accounts /*!50000 LOCK IN SHARE MODE */)" \
        "SELECT name FROM accounts WHERE id IN (SELECT id FROM accounts /*M!100000 LOCK IN SHARE MODE */)"; do
        sql_refused "${q}" "a row lock inside a subquery: ${q//$'\n'/ }"
    done
    run "$S/sql-read.sh 'SELECT COUNT(*) AS share FROM accounts WHERE deleted = 0'"
    is_rc 0 "a column labelled share is answered: only the lock clause is refused"
    run "$S/sql-read.sh 'SELECT user_name, * FROM users'"
    is_rc 64 "a select-all after a comma is still refused on users"
    run "$S/sql-read.sh 'SELECT * FROM users'"
    has err "user_name" "a refused select-all on users lists the columns that can be read"
    hasnt err "user_hash" "and not the ones that cannot"

    # The session ids in tracker (a signed-in user's session id is all it takes to be that user)
    for q in "SELECT * FROM tracker ORDER BY id DESC LIMIT 1" "SELECT session_id FROM tracker" "SELECT MAX(t.session_id) FROM tracker t" \
        "SELECT 1 FROM accounts WHERE EXISTS (SELECT 1 FROM tracker WHERE session_id LIKE '5%')" "SELECT item_summary FROM tracker WHERE user_id = '1'"; do
        sql_refused "${q}"
        if [[ "${out}${err}" == *"${sess:0:8}"* ]]; then bad "and prints no part of the session id" "${out}"; else ok "and prints no part of the session id"; fi
    done

    # The password hash, by every way the review found and a few more: none answers, none prints it
    hash_mark='$2y$'
    sql_unanswered 'SELECT 1 AS `a'"'"'`, LENGTH(user_hash) AS hash_len, LEFT(user_hash, 4) AS `b'"'"'` FROM users' "the hash behind a quote in a backticked alias is not read" "${hash_mark}" 60
    sql_unanswered 'SELECT SQL_NO_CACHE * FROM users' "nor by SELECT SQL_NO_CACHE *" "${hash_mark}"
    sql_unanswered 'SELECT HIGH_PRIORITY DISTINCT * FROM users' "nor by another word before the *" "${hash_mark}"
    sql_unanswered 'SELECT LENGTH(user_haſh) FROM users' "nor with a long s in the column's name" "${hash_mark}" 60
    sql_unanswered "SELECT user_name FROM users WHERE user_hash LIKE '\$2y\$%'" "nor one character at a time in a WHERE" "${SC_ADMIN_USER}"
    sql_unanswered 'SELECT user_name FROM users ORDER BY user_hash' "nor by sorting on it" "${SC_ADMIN_USER}"
    sql_unanswered 'SELECT x FROM (SELECT user_hash AS x FROM users) d' "nor through a derived table" "${hash_mark}"
    sql_unanswered "SELECT user_hash FROM users UNION SELECT 'x'" "nor through a UNION" "${hash_mark}"
    sql_unanswered 'SELECT (SELECT user_hash FROM users LIMIT 1)' "nor through a subquery" "${hash_mark}"
    sql_unanswered "SELECT EXTRACTVALUE(1, CONCAT(0x7e, (SELECT user_hash FROM users LIMIT 1)))" "nor inside the database's error message" "${hash_mark}"
    sql_unanswered 'SELECT * FROM clv_test_view' "nor through a view" "${hash_mark}"
    sql_unanswered 'SELECT LENGTH(v.user_hash) FROM clv_test_view v' "nor computed from a view" 60
    sql_unanswered "SELECT 'a', 'b' UNION SELECT * FROM clv_test_view" "nor through a view in a UNION" "${hash_mark}"
    sql_unanswered "SELECT id, name FROM oauth2clients WHERE secret LIKE 'oauth%'" "an OAuth client's secret is not read in a WHERE" 'Clv Test Client'

    # A column of another table that looks like a secret (a package's, or a later version's)
    for q in "SELECT access_token FROM clv_test_pkg" "SELECT LENGTH(access_token) FROM clv_test_pkg" "SELECT note FROM clv_test_pkg WHERE access_token LIKE 'tok-Q%'" \
        "SELECT * FROM clv_test_pkg" "SELECT t.* FROM clv_test_pkg t WHERE t.id = 1" "SELECT LENGTH(access_token) AS x FROM clv_test_pkg WHERE id = 1" \
        "SELECT (SELECT LEFT(t.access_token, 8) FROM clv_test_pkg t WHERE t.id = 1) AS x" "SELECT 'a', 'b', 'c' UNION SELECT * FROM clv_test_pkg WHERE id = 1" \
        "SELECT x FROM (SELECT access_token AS x FROM clv_test_pkg) d" "SELECT note FROM clv_test_pkg ORDER BY access_token" \
        "SELECT x FROM (SELECT 1 AS a, 2 AS x, 3 AS c UNION ALL SELECT * FROM clv_test_pkg) d" "SELECT d.* FROM (SELECT * FROM clv_test_pkg) d" \
        "WITH c AS (SELECT * FROM clv_test_pkg) SELECT * FROM c" "SELECT _binary 'x''', access_token, _binary 'y''' FROM clv_test_pkg" \
        "SELECT @\`a'\` := 1, access_token, 'x' FROM clv_test_pkg" "SELECT acceſſ_token FROM clv_test_pkg"; do
        sql_refused "${q}"
        if [[ "${out}${err}" == *"tok-"* ]] || [[ "${out}" == *16* ]]; then bad "and prints no token" "${out}"$'\n'"${err}"; else ok "and prints no token"; fi
    done
    sql_unanswered "SELECT EXTRACTVALUE(1, CONCAT(0x7e, (SELECT access_token FROM clv_test_pkg LIMIT 1)))" "a token does not come out inside the database's error message" 'tok-'
    sql_unanswered "SELECT EXTRACTVALUE(1, CONCAT(0x7e, (SELECT access_token FROM clv_test_pkg WHERE id = 2)))" "nor when the row is found by its key" 'tok-'
    for q in "SELECT clv_test_fn()" "SELECT note FROM clv_test_pkg WHERE clv_test_fn() LIKE 'tok-Q%'"; do
        sql_refused "${q}"
        if [[ "${out}${err}" == *"tok-"* ]]; then bad "and prints no token" "${out}"$'\n'"${err}"; else ok "and prints no token"; fi
    done
    run "$S/sql-read.sh 'SELECT * FROM clv_test_pkg'"
    has err "these can be read: id, note" "a refused select-all on such a table lists the columns that can be read"
    run "$S/sql-read.sh 'SELECT id, note FROM clv_test_pkg ORDER BY id'"
    is_rc 0 "the other columns of that table are read"
    has out $'1\tfirst' "with the rows"
    # The check against the tables without their secret-shaped columns stands by itself. A query that works only
    # with such a column in the table is refused by that check, whatever error the database met first there: an
    # index hint and a derived table's column list both come before "unknown column".
    run "$S/sql-read.sh \"SELECT note FROM clv_test_pkg USE INDEX (PRIMARY) WHERE access_token LIKE 'tok-Q%'\""
    is_rc 64 "a secret-shaped column behind an index hint is refused"
    has err "without those columns" "by the check against the tables without such columns"
    hasnt out "first" "and no row is printed"
    run "$S/sql-read.sh 'SELECT MIN(t.x) FROM (SELECT * FROM clv_test_pkg) AS t (a, x, c)'"
    is_rc 64 "a * renamed by a derived table's column list is refused"
    has err "number of columns counts" "by the same check"
    hasnt out "tok-" "and no token is printed"
    run "$S/sql-read.sh 'SELECT email_address FROM email_addresses USE INDEX (PRIMARY) WHERE deleted = 0 LIMIT 3'"
    is_rc 64 "an index hint on a table that has a secret-shaped column is refused too"
    has err "index hint" "and the message says to leave the hint out"
    run "$S/sql-read.sh 'SELECT id, name FROM accounts USE INDEX (idx_accnt_name_del) WHERE deleted = 0 LIMIT 3'"
    is_rc 0 "an index hint on a table without such a column is answered"

    # The writes the review got through: each must leave the account as it was
    docker exec -i -u clouve "${SC_AGENT}" bash -c 'cat > /tmp/clv-sql-x.sql' <<< "SET SESSION tx_read_only = 0; UPDATE accounts SET description = 'clv-written-file' WHERE name = 'Pipeline Co';"
    sql_unanswered "SELECT 1 AS one \\g SET SESSION tx_read_only = 0 \\g UPDATE accounts SET description = 'clv-written-g' WHERE name = 'Pipeline Co' \\g SELECT 2 AS two" "the mysql client's \\g does not start a second statement" 'two'
    sql_unanswered "SELECT 1 AS one \\. /tmp/clv-sql-x.sql" "its \\. does not run a file" 'Query OK'
    sql_unanswered "SELECT 1 AS one \\! id > /tmp/clv-sql-proof" "its \\! does not run a shell command" 'uid='
    sql_unanswered 'SELECT 1 AS `a'"'"'`; SET SESSION tx_read_only = 0; UPDATE accounts SET description = '"'clv-written-alias'"' WHERE name = '"'Pipeline Co'"'; SELECT 2 AS `b'"'"'`' "a quote in a backticked alias does not hide a second statement" 'b'"'"
    sql_is "SELECT COUNT(*) FROM accounts WHERE description LIKE 'clv-written%'" 0 "and none of the four wrote to the account"
    proof="$(docker exec "${SC_AGENT}" ls /tmp/clv-sql-proof 2> /dev/null; docker exec "${SC_APP}" ls /tmp/clv-sql-proof 2> /dev/null)"
    if [ -z "${proof}" ]; then ok "and no command ran on the agent or in SuiteCRM's container"; else bad "and no command ran on the agent or in SuiteCRM's container" "${proof}"; fi
    docker exec "${SC_AGENT}" rm -f /tmp/clv-sql-x.sql /tmp/clv-sql-proof
    docker exec "${SC_APP}" rm -f /tmp/clv-sql-proof

    # Read-only does not rest on what the account may not do: with the right to write files, none is written
    docker exec -e "MYSQL_PWD=${SC_PW_DBROOT}" "${SC_DB}" mariadb -uroot -e "GRANT FILE ON *.* TO 'suitecrm'@'%'" < /dev/null
    if [[ "$(sc_db_sql 'SHOW GRANTS')" == *FILE* ]]; then ok "(the database account has the FILE right for the next two)"; else bad "(the database account has the FILE right for the next two)"; fi
    sql_refused "SELECT name FROM accounts INTO OUTFILE '/tmp/clv-sql-outfile'" "INTO OUTFILE, also when the account may write files"
    sql_refused "SELECT 'x' INTO DUMPFILE '/tmp/clv-sql-dumpfile'" "INTO DUMPFILE, also when the account may write files"
    docker exec -e "MYSQL_PWD=${SC_PW_DBROOT}" "${SC_DB}" mariadb -uroot -e "REVOKE FILE ON *.* FROM 'suitecrm'@'%'" < /dev/null
    files="$(docker exec "${SC_DB}" sh -c 'ls /tmp/clv-sql-* 2> /dev/null')"
    if [ -z "${files}" ] && [[ "$(sc_db_sql 'SHOW GRANTS')" != *FILE* ]]; then ok "and no file was written on the database server"; else bad "and no file was written on the database server" "${files}"; fi

    # And it guards one database: with an account that can read another one, it does not run at all
    docker exec -e "MYSQL_PWD=${SC_PW_DBROOT}" "${SC_DB}" mariadb -uroot -e "CREATE DATABASE clv_test_other; CREATE TABLE clv_test_other.t (a VARCHAR(20)); INSERT INTO clv_test_other.t VALUES ('other-Data-7q'); GRANT SELECT ON clv_test_other.* TO 'suitecrm'@'%'" < /dev/null
    sql_is "SELECT a FROM clv_test_other.t" 'other-Data-7q' "(the database account can read a second database for the next two)"
    sql_unanswered "SELECT a FROM clv_test_other.t" "a table of another database is not read" 'other-Data'
    run "$S/sql-read.sh 'SELECT 1 AS one'"
    if [ "${rc}" -eq 1 ] && [ -z "${out}" ] && [[ "${err}" == *clv_test_other* ]]; then ok "and nothing else runs either, until the account is put right (exit 1, naming the database)"; else bad "and nothing else runs either, until the account is put right (exit ${rc})" "${out}"$'\n'"${err}"; fi
    docker exec -e "MYSQL_PWD=${SC_PW_DBROOT}" "${SC_DB}" mariadb -uroot -e "REVOKE SELECT ON clv_test_other.* FROM 'suitecrm'@'%'; DROP DATABASE clv_test_other" < /dev/null
    run "$S/sql-read.sh 'SELECT 1 AS one'"
    is_rc 0 "with the account as the image makes it, queries run again"

    # The time limit is the database's 30 seconds, and a query cannot lift it: a hint that sets a limit of its own
    # is refused. So a run that is killed leaves nothing behind for longer than that. The database ends the
    # statement by itself, and the connection goes with its private copies. Both waits run at once.
    slow='COUNT(*) FROM relationships a, relationships b, relationships c, relationships d, relationships e'
    sql_refused "SELECT /*+ MAX_EXECUTION_TIME(600000) */ ${slow}" "a hint that lifts the database's time limit"
    sql_refused "SELECT /*+ max_execution_time(0) */ 1 AS one" "and the same hint in lower case"
    (printf '%s' "SELECT ${slow}" | sc_agent_stdin "$S/sql-read.sh" > "${work}/slow1.out" 2> "${work}/slow1.err"; echo "$?" > "${work}/slow1.rc") &
    slow1=$!
    (printf '%s' "SELECT COUNT(*) FROM relationships k1, relationships k2, relationships k3, relationships k4, relationships k5" | sc_agent_stdin "$S/sql-read.sh --max-rows 4321" > "${work}/slow2.out" 2> "${work}/slow2.err"; echo "$?" > "${work}/slow2.rc") &
    slow2=$!
    killed_thread=''
    for _ in $(seq 1 100); do
        killed_thread="$(sc_db_sql "SELECT id FROM information_schema.processlist WHERE info LIKE 'SELECT COUNT(*) FROM relationships k1, relationships k2%' LIMIT 1")"
        [ -n "${killed_thread}" ] && break
        sleep 0.2
    done
    docker exec "${SC_APP}" bash -c 'for p in /proc/[0-9]*; do c="$(tr "\0" " " < "$p/cmdline" 2> /dev/null)"; case "$c" in php*sqlread.php\ 4321\ tsv*) kill -9 "${p#/proc/}" ;; esac; done'
    killed_at="$(date +%s)"
    gone=0
    if [ -n "${killed_thread}" ]; then
        for _ in $(seq 1 45); do
            if [ "$(sc_db_sql "SELECT COUNT(*) FROM information_schema.processlist WHERE id = ${killed_thread}")" = 0 ]; then gone=1; break; fi
            sleep 1
        done
    fi
    took=$(($(date +%s) - killed_at))
    wait "${slow1}" "${slow2}"
    cat "${work}"/slow[12].out "${work}"/slow[12].err >> "${all_output}"
    if [ "$(cat "${work}/slow1.rc")" = 2 ] && grep -q '30 seconds' "${work}/slow1.err" && [ ! -s "${work}/slow1.out" ]; then ok "a query that runs too long is stopped after 30 seconds (exit 2)"; else bad "a query that runs too long is stopped after 30 seconds (exit $(cat "${work}/slow1.rc"))" "$(cat "${work}/slow1.err")"; fi
    if [ -n "${killed_thread}" ] && [ "$(cat "${work}/slow2.rc")" != 0 ] && [ ! -s "${work}/slow2.out" ]; then ok "(a second slow query was running, and its reader was killed)"; else bad "(a second slow query was running, and its reader was killed) (thread '${killed_thread}', exit $(cat "${work}/slow2.rc"))" "$(cat "${work}/slow2.err")"; fi
    if [ "${gone}" -eq 1 ]; then ok "after its reader is killed, the database ends the query within its limit and the connection, with its private copies, is gone (${took} s)"; else bad "after its reader is killed, the database ends the query within its limit and the connection, with its private copies, is gone" "still there after ${took} s"; fi
    sql_is "SELECT COUNT(*) FROM information_schema.processlist WHERE (info LIKE '%relationships a, relationships b%' OR info LIKE '%relationships k1, relationships k2%') AND id <> CONNECTION_ID()" 0 "and neither is still running on the database"

    # The read's transaction ends before the answer is printed. A reader that stalls on a large answer holds
    # nothing on the database: a change to the table's layout (a repair makes them) goes through at once.
    sc_db_sql "CREATE TABLE clv_test_big (id INT PRIMARY KEY, pad VARCHAR(6000)); INSERT INTO clv_test_big SELECT seq, REPEAT('x', 6000) FROM seq_1_to_5000"
    (sc_agent "$S/sql-read.sh --max-rows 5000 'SELECT id, pad FROM clv_test_big' | (sleep 14; wc -c)" > "${work}/stall.out" 2> "${work}/stall.err") &
    stall=$!
    sleep 6
    started="$(date +%s)"
    alter="$(sc_db_sql "SET SESSION lock_wait_timeout = 4; ALTER TABLE clv_test_big ADD COLUMN c2 INT" 2>&1)"
    alter_rc=$?
    took=$(($(date +%s) - started))
    wait "${stall}"
    if [ "${alter_rc}" -eq 0 ] && [ "${took}" -lt 4 ]; then ok "while the reader of a large answer stalls, a change to that table's layout is not held up"; else bad "while the reader of a large answer stalls, a change to that table's layout is not held up (exit ${alter_rc}, ${took} s)" "${alter}"; fi
    printed="$(tail -n 1 "${work}/stall.out")"
    if [[ "${printed}" =~ ^[0-9]+$ ]] && [ "${printed}" -gt 30000000 ]; then ok "and the whole answer arrives once the reader goes on (${printed} bytes)"; else bad "and the whole answer arrives once the reader goes on" "$(head -c 300 "${work}/stall.out"; cat "${work}/stall.err")"; fi
    sc_db_sql "DROP TABLE clv_test_big"

    # After all of that, the data is as it was
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'Pipeline Co'" 1 "after all of that the account is still there"
    sql_is "SELECT COUNT(*) FROM clv_test_pkg" 2 "the table a DROP and a TRUNCATE named still has its rows"
    sql_is "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'clv_test_made'" 0 "and no table was made"
    sql_is "SELECT COUNT(*) > 0 FROM users WHERE user_hash LIKE '\$2y\$%'" 1 "the users table still holds its password hash: the query's own copy of it is gone"
    sc_db_sql "DROP FUNCTION clv_test_fn; DROP VIEW clv_test_view; DROP TABLE clv_test_pkg; DELETE FROM oauth2clients WHERE id = 'clv-test-client'; DELETE FROM tracker WHERE session_id = '${sess}'"
    # And nothing sql-read.sh printed in this section, on either stream, holds a hash, a token or the session id
    leaks="$(tail -c "+$((sql_from + 1))" "${all_output}" | grep -cF -e "${hash_mark}" -e "${sess:0:8}" -e 'tok-' -e "${osec}" || true)"
    if [ "${leaks}" = 0 ]; then ok "nothing sql-read.sh printed holds a password hash, a token, a client secret or the session id"; else bad "nothing sql-read.sh printed holds a password hash, a token, a client secret or the session id" "${leaks} lines"; fi
fi

# ---------------------------------------------------------------------------
# users
# ---------------------------------------------------------------------------
if wants users; then
    section "users.sh, temp-password.sh, restore-admin-password.sh"
    # sign_in JAR USER PASSWORD: a real sign-in from inside the SuiteCRM container that keeps its session in
    # /tmp/JAR there (mode 600), and prints the HTTP code. The password reaches curl in a file.
    sign_in() {
        printf '{"username":%s,"password":%s}' "$(printf '%s' "$2" | jq -Rs .)" "$(printf '%s' "$3" | jq -Rs .)" \
            | docker exec -i "${SC_APP}" bash -c 'umask 077; j=/tmp/'"$1"'; b=$(mktemp); cat > "$b"; rm -f "$j"; curl -s -o /dev/null -c "$j" http://localhost/session-status; x=$(awk "\$6==\"XSRF-TOKEN\"{print \$7}" "$j"); curl -s -o /dev/null -w "%{http_code}" -b "$j" -c "$j" -H "Content-Type: application/json" -H "X-XSRF-TOKEN: $x" --data @"$b" http://localhost/login; rm -f "$b"'
    }
    # session_is JAR FILTER WANT LABEL: jq -r FILTER on what SuiteCRM's /session-status says for that session
    session_is() {
        local body got
        body="$(docker exec "${SC_APP}" curl -s -b "/tmp/$1" http://localhost/session-status < /dev/null)"
        got="$(printf '%s' "${body}" | jq -r "$2" 2>&1)"
        if [ "${got}" = "$3" ]; then ok "$4"; else bad "$4" "jq $2 gave: ${got}"$'\n'"wanted: $3"$'\n'"session-status: $(printf '%s' "${body}" | cut -c1-400)"; fi
    }
    # fx_is FILTER WANT LABEL: jq -r FILTER on the last line the last fixture printed
    fx_is() {
        local got
        got="$(tail -n 1 "${work}/fixture.out" | jq -r "$1" 2>&1)"
        if [ "${got}" = "$2" ]; then ok "$3"; else bad "$3" "jq $1 gave: ${got}"$'\n'"wanted: $2"$'\n'"the fixture printed: $(tail -n 3 "${work}/fixture.out" | cut -c1-600)"; fi
    }
    # password_file: the name of the file the last temp-password.sh run saved
    password_file() { printf '%s' "${out}" | sed -n 's/.* to suitecrm-passwords\/\([^ ]*\) in the Files pane\.$/\1/p'; }

    run "$S/users.sh list"
    is_rc 0 "list shows the users"
    json '.users[] | select(.id == "1") | .login' "${SC_ADMIN_USER}" "with the main admin"
    hasnt out "user_hash" "and no password hash"

    # The site's rule for generated passwords, as SuiteCRM ships it
    run "$S/users.sh password-rule"
    is_rc 0 "password-rule reads the site's rule for generated passwords"
    json '.asks_for_new_password' "7 days after the password was set" "which on a new install is 7 days after the password was set"
    rule_was="$(val '.setting | "systexpiration=\(.systexpiration) systexpirationlogin=\(.systexpirationlogin)"')"

    run "$S/temp-password.sh --create --first-name Sally --last-name Sales --email sally@example.test sally"
    is_rc 0 "temp-password.sh --create makes a user"
    pwfile="$(password_file)"
    has out "Saved the temporary password for sally to suitecrm-passwords/" "and prints where the password is"
    has out "SuiteCRM asks for a new password 7 days after the password was set. Until then this password keeps working" "and when SuiteCRM will ask for a new one on this site"
    hasnt out "first sign-in" "without the claim that it is at the first sign-in"
    mode="$(sc_agent "stat -c '%a %U' ~/suitecrm-passwords ~/suitecrm-passwords/${pwfile} | tr '\n' ' '")"
    if [ "${mode}" = "700 clouve 600 clouve " ]; then ok "the folder is 700 and the file 600"; else bad "the folder is 700 and the file 600" "${mode}"; fi
    temp_pw="$(sc_agent "sed -n '/^Temporary password:/{n;p}' ~/suitecrm-passwords/${pwfile}")"
    if [ "${#temp_pw}" -eq 20 ]; then ok "the file holds a 20-character password"; else bad "the file holds a 20-character password" "length ${#temp_pw}"; fi
    printf '%s\n' "${temp_pw}" >> "${work}/temp-passwords"
    hasnt out "${temp_pw}" "which the script did not print"
    file_says="$(sc_agent "tail -n 1 ~/suitecrm-passwords/${pwfile}")"
    if [[ "${file_says}" == "SuiteCRM asks for a new password 7 days after this one was set. Sign in and change it right away under your profile. Delete this file once it is handed over." ]]; then ok "the file says what is true for this site: a new password is asked for after 7 days"; else bad "the file says what is true for this site: a new password is asked for after 7 days" "${file_says}"; fi
    run "$S/users.sh show sally"
    json '.system_generated_password' true "show says the account is on a generated password"
    json '.asks_for_new_password' "7 days after the password was set" "and when SuiteCRM will ask for a new one"
    json 'has("must_change_password")' false "the field that claimed a forced change is gone"
    json '.is_admin' false "the user is not an admin"

    # What SuiteCRM 8.10.2 does at the first sign-in with a temporary password, under the rule it ships with
    code="$(sign_in usr-jar-sally sally "${temp_pw}")"
    if [ "${code}" = 200 ]; then ok "the temporary password signs in"; else bad "the temporary password signs in" "HTTP ${code}"; fi
    session_is usr-jar-sally '.redirect.route' "users/Wizard" "a new user's first sign-in goes to the first-login wizard, which has no password step"
    fixture users-wizard-done.php sally
    code="$(sign_in usr-jar-sally sally "${temp_pw}")"
    session_is usr-jar-sally '.active' true "with the wizard done, the next sign-in with the temporary password is a working session"
    session_is usr-jar-sally '.redirect.route // "none"' none "and SuiteCRM does not send it to the change-password page"
    sc_db_sql "UPDATE users SET pwd_last_changed = DATE_SUB(UTC_TIMESTAMP(), INTERVAL 8 DAY) WHERE user_name = 'sally'"
    code="$(sign_in usr-jar-sally sally "${temp_pw}")"
    session_is usr-jar-sally '.redirect.route' "users/ChangePassword" "it does once the temporary password is more than 7 days old, as the file says"
    sc_db_sql "UPDATE users SET pwd_last_changed = UTC_TIMESTAMP() WHERE user_name = 'sally'"

    # A reset changes who can sign in: it needs its yes
    before="$(sc_agent 'ls ~/suitecrm-passwords | wc -l')"
    run "$S/temp-password.sh sally"
    is_rc 64 "a reset without --yes-reset changes nothing"
    has err "stops working at once" "and says that the current password would stop working at once"
    has err "can't be brought back" "and that the old one can't be brought back"
    after="$(sc_agent 'ls ~/suitecrm-passwords | wc -l')"
    if [ "${before}" = "${after}" ]; then ok "it leaves no password file"; else bad "it leaves no password file" "${before} before, ${after} after"; fi
    code="$(login_code sally "${temp_pw}")"
    if [ "${code}" = 200 ]; then ok "and the password still signs in"; else bad "and the password still signs in" "HTTP ${code}"; fi
    run "$S/temp-password.sh --yes-reset sally"
    is_rc 0 "temp-password.sh --yes-reset resets an existing user"
    pwfile2="$(password_file)"
    temp_pw2="$(sc_agent "sed -n '/^Temporary password:/{n;p}' ~/suitecrm-passwords/${pwfile2}")"
    printf '%s\n' "${temp_pw2}" >> "${work}/temp-passwords"
    code="$(login_code sally "${temp_pw}")"
    if [ "${code}" = 401 ]; then ok "the old password no longer signs in"; else bad "the old password no longer signs in" "HTTP ${code}"; fi
    code="$(login_code sally "${temp_pw2}")"
    if [ "${code}" = 200 ]; then ok "the new one does"; else bad "the new one does" "HTTP ${code}"; fi
    fixture users-wizard-done.php sally check
    fx_is '.wizard_done' true "a reset keeps the person's preferences: no second first-login wizard"
    fx_is '.timezone' "Europe/Lisbon" "and their time zone"

    before="$(sc_agent 'ls ~/suitecrm-passwords | wc -l')"
    run "$S/temp-password.sh --create --last-name Again --email again@example.test sally"
    is_rc 4 "--create of an existing user is refused"
    run "$S/temp-password.sh --yes-reset nobody-here"
    is_rc 4 "a reset of a user who is not there is refused"
    run "$S/temp-password.sh --yes-reset ${SC_ADMIN_USER}"
    is_rc 2 "the main admin's password is not reset here"
    has err "restore-admin-password.sh" "and the message names the way back in"
    run "$S/temp-password.sh ${SC_ADMIN_USER}"
    is_rc 2 "without the yes it is refused too, so that nobody is asked for a yes that would be refused"
    has err "main admin" "and the message says that this is the main admin"
    hasnt err "run it again with --yes-reset" "and does not say to run it again with the yes"
    run "$S/temp-password.sh ${SC_ADMIN_USER^^}"
    is_rc 2 "and so is the same login in capitals"
    run "$S/temp-password.sh --create --email x@example.test nolastname"
    is_rc 64 "--create without a last name is a usage error"
    run "$S/temp-password.sh --create --last-name X --email nonsense x"
    is_rc 64 "--create with a bad email address is a usage error"
    run "$S/temp-password.sh --create --last-name Boss --email boss@example.test --admin boss"
    is_rc 64 "--create --admin without --yes-admin changes nothing"
    has err "full control" "and says what an administrator can do"
    has err "set-admin boss no" "and how it can be taken back"
    sql_is "SELECT COUNT(*) FROM users WHERE user_name = 'boss'" 0 "no account is made"
    after="$(sc_agent 'ls ~/suitecrm-passwords | wc -l')"
    if [ "${before}" = "${after}" ]; then ok "none of the refusals left a password file"; else bad "none of the refusals left a password file" "${before} before, ${after} after"; fi
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "the main admin still signs in with the dashboard's password"; else bad "the main admin still signs in with the dashboard's password" "HTTP ${code}"; fi
    run "$S/temp-password.sh --create --last-name Boss --email boss@example.test --admin --yes-admin boss"
    is_rc 0 "with --yes-admin it makes an administrator"
    sc_agent "sed -n '/^Temporary password:/{n;p}' ~/suitecrm-passwords/$(password_file)" >> "${work}/temp-passwords"
    run "$S/users.sh show boss"
    json '.is_admin' true "who is an admin"
    run "$S/users.sh deactivate boss"
    json '.was_status' Active "(and is switched off again for the rest of the test)"

    run "$S/temp-password.sh --remove /etc/passwd"
    is_rc 64 "--remove of a file outside the folder is refused"
    run "$S/temp-password.sh --remove suitecrm-passwords/${pwfile}"
    is_rc 0 "--remove deletes a password file"
    run "ls ~/suitecrm-passwords/${pwfile}"
    is_rc 2 "and it is gone"

    run "$S/users.sh role-create 'Sales Rep'"
    is_rc 0 "role-create makes a role"
    run "$S/users.sh role-create 'Sales Rep'"
    is_rc 4 "a second role of that name is refused"
    run "$S/users.sh role-set 'Sales Rep' Accounts delete none"
    is_rc 0 "role-set takes delete on Accounts away"
    json '.before + " to " + .after' "default to none" "and prints the level it replaced"
    json '.widens_access' false "a change that narrows access is not marked as widening"
    run "$S/users.sh role-set 'Sales Rep' Opportunities view owner"
    is_rc 0 "role-set limits Opportunities to the owner's"
    run "$S/users.sh role-set 'Sales Rep' Opportunities view all"
    json '.before + " to " + .after' "owner to all" "a second role-set prints the level that was there"
    json '.widens_access' true "and marks a change from owner to all as widening"
    has out "role-set \\\"Sales Rep\\\" Opportunities view owner" "with the command that puts it back"
    run "$S/users.sh role-set 'Sales Rep' Opportunities view owner"
    run "$S/users.sh role-set 'Sales Rep' Opportunities view default"
    json '.widens_access' true "default widens too"
    has out "default means allowed" "and the note says that default means allowed"
    run "$S/users.sh role-set 'Sales Rep' Opportunities view owner"
    json '.before + " to " + .after' "default to owner" "(Opportunities is back at owner)"
    run "$S/users.sh role-set 'Sales Rep' Accounts delete sometimes"
    is_rc 64 "a level that does not exist is a usage error"
    run "$S/users.sh role-set 'Sales Rep' NoSuchModule delete none"
    is_rc 3 "a module SuiteCRM does not have is exit 3"
    run "$S/users.sh role-set 'Sales Rep' Accounts import owner"
    is_rc 64 "owner is refused for import, which SuiteCRM allows or not for the whole module"
    has err "use none to close it" "and the message says to use none"
    run "$S/users.sh role-set 'Sales Rep' Accounts massupdate owner"
    is_rc 64 "and for massupdate"
    run "$S/users.sh role-assign sally 'Sales Rep'"
    is_rc 0 "role-assign gives sally the role"
    json '.roles[0]' "Sales Rep" "and reads it back"
    json '(.roles_before | length | tostring) + " then " + (.roles_after | join(","))' "0 then Sales Rep" "with her roles before and after"
    run "$S/users.sh role-assign sally 'Typo Role'"
    is_rc 3 "a role that is not there is not created by a typo"
    run "$S/users.sh role-show 'Sales Rep'"
    json '.settings.Accounts.delete' none "role-show shows the settings"
    json '.users[0]' sally "and the people in the role"
    run "$S/users.sh group-create 'West Team'"
    is_rc 0 "group-create makes a security group"
    run "$S/users.sh group-add sally 'West Team'"
    json '.groups[0]' "West Team" "group-add puts sally in it"
    json '(.groups_before | length | tostring) + " then " + (.groups_after | join(","))' "0 then West Team" "with her groups before and after"
    run "$S/users.sh group-remove sally 'West Team'"
    json '.groups | length' 0 "group-remove takes her out"
    json '.groups_before[0]' "West Team" "and says which groups she was in"
    run "$S/users.sh role-unassign sally 'Sales Rep'"
    json '.roles | length' 0 "role-unassign takes the role away"
    json '.roles_before[0]' "Sales Rep" "and says which roles she had"

    # "Only her own records": the first user's account is the main admin's, the second user is sally
    run "$S/users.sh role-create 'Own Accounts'"
    for acl_action in list view; do run "$S/users.sh role-set 'Own Accounts' Accounts ${acl_action} owner"; done
    run "$S/users.sh role-assign sally 'Own Accounts'"
    is_rc 0 "(a role with only list and view set to owner, given to sally)"
    fixture users-acl-check.php sally
    fx_is '.list.sees_first' false "with list and view alone, the first user's account is off her list"
    fx_is '.export.has_first' true "but SuiteCRM's own export still hands it to her"
    fx_is '[.first.checkAccess.edit, .first.checkAccess.delete, .first.checkAccess.export, .first.checkAccess.massupdate] | all' true "and she may still edit, delete, export and mass update it"
    closed=0
    for acl_action in edit delete export; do
        run "$S/users.sh role-set 'Own Accounts' Accounts ${acl_action} owner"
        [ "${rc}" -eq 0 ] && closed=$((closed + 1))
    done
    for acl_action in import massupdate; do
        run "$S/users.sh role-set 'Own Accounts' Accounts ${acl_action} none"
        [ "${rc}" -eq 0 ] && closed=$((closed + 1))
    done
    if [ "${closed}" -eq 5 ]; then ok "role-set takes edit, delete and export as owner, and import and massupdate as none"; else bad "role-set takes edit, delete and export as owner, and import and massupdate as none" "${closed} of 5 were taken"; fi
    fixture users-acl-check.php sally
    fx_is '.list.sees_first' false "with all seven set, she does not see the first user's account"
    fx_is '.export.has_first' false "SuiteCRM's export leaves it out"
    fx_is '[.first.checkAccess.view, .first.checkAccess.edit, .first.checkAccess.delete, .first.checkAccess.export, .first.checkAccess.massupdate] | any' false "ACLController::checkAccess refuses view, edit, delete, export and mass update of it"
    fx_is '[.first.ACLAccess.view, .first.ACLAccess.edit, .first.ACLAccess.delete, .first.ACLAccess.export] | any' false "and so does the record's own check"
    fx_is '[.module.import, .module.massupdate] | any' false "the import wizard and the mass update form are closed to her"
    fx_is '[.list.sees_own, .export.has_own, .own.ACLAccess.view, .own.ACLAccess.edit, .own.ACLAccess.delete] | all' true "she still sees, exports, edits and deletes her own account"
    fixture users-acl-check.php sally import-update
    fx_is '.import_changed_first' false "and an import can't change the first user's account"
    # Why import is none: left open, an import that updates by id has no check per record
    run "$S/users.sh role-set 'Own Accounts' Accounts import default"
    json '.widens_access' true "(import opened again: role-set marks it as widening)"
    fixture users-acl-check.php sally import-update
    fx_is '.import_changed_first' true "with import left open, SuiteCRM's importer changes the first user's account for her"
    # A stored owner level on import, as an older version of this script could leave it
    sc_db_sql "UPDATE acl_roles_actions SET access_override = 75 WHERE deleted = 0 AND role_id = (SELECT id FROM acl_roles WHERE name = 'Own Accounts' AND deleted = 0) AND action_id = (SELECT id FROM acl_actions WHERE category = 'Accounts' AND name = 'import' AND deleted = 0)"
    fixture users-acl-check.php sally
    fx_is '.module.import' true "an owner level on import counts as allowed, which is why role-set refuses it"
    run "$S/users.sh role-set 'Own Accounts' Accounts import none"
    json '.before + " to " + .after' "owner to none" "(import is closed again)"
    run "$S/users.sh role-unassign sally 'Own Accounts'"
    sc_db_sql "DELETE FROM accounts WHERE name IN ('ACL probe first', 'ACL probe second')"

    run "$S/users.sh set-admin sally yes"
    is_rc 64 "set-admin yes without --yes-admin changes nothing"
    has err "full control" "and says what an administrator can do"
    has err "set-admin sally no" "and how it can be taken back"
    run "$S/users.sh show sally"
    json '.is_admin' false "sally is still not an admin"
    run "$S/users.sh set-admin sally yes --yes-admin"
    json '.is_admin' true "set-admin yes --yes-admin makes an admin"
    json '.was_admin' false "and says she was not one"
    run "$S/users.sh set-admin sally no"
    json '.is_admin' false "set-admin no takes it back, with no flag"
    json '.was_admin' true "and says she was one"
    run "$S/users.sh set-admin ${SC_ADMIN_USER} no"
    is_rc 2 "the main admin stays an admin"
    run "$S/users.sh invite ann --last-name Admin --email ann@example.test --admin --yes-send"
    is_rc 64 "an invitation that makes an administrator needs --yes-admin too"
    has err "full control" "and says what an administrator can do"
    run "$S/users.sh invite ann --last-name Admin --email ann@example.test --admin --yes-admin"
    is_rc 64 "and still --yes-send"
    sql_is "SELECT COUNT(*) FROM users WHERE user_name = 'ann'" 0 "neither made the account"
    run "$S/users.sh invite ann --last-name Admin --email ann@example.test --admin --yes-admin --yes-send"
    is_rc 2 "with both flags the invitation gets as far as SuiteCRM, which has no outgoing email yet"
    has err "outgoing email is not set up" "and is refused for that reason alone"
    run "$S/users.sh deactivate ${SC_ADMIN_USER}"
    is_rc 2 "the main admin can't be deactivated"
    code="$(sign_in usr-jar-sally sally "${temp_pw2}")"
    session_is usr-jar-sally '.active' true "(sally has a session open)"
    run "$S/users.sh deactivate sally"
    json '.status' Inactive "deactivate makes the account inactive"
    json '.was_status' Active "and says it was active"
    has out "activate \\\"sally\\\" takes this back" "and how to take it back"
    session_is usr-jar-sally '.active' false "her open session has ended, as the output says"
    code="$(login_code sally "${temp_pw2}")"
    if [ "${code}" = 401 ]; then ok "and it can no longer sign in"; else bad "and it can no longer sign in" "HTTP ${code}"; fi
    run "$S/users.sh activate sally"
    json '.status' Active "activate brings it back"
    json '.was_status' Inactive "and says it was inactive"
    fixture users-wizard-done.php sally check
    fx_is '.wizard_done' true "her preferences are still there after all of this"

    # The rule for the whole site: a forced change at the first sign-in, only on a yes
    run "$S/users.sh password-rule first-sign-in"
    is_rc 64 "password-rule first-sign-in without --yes-change changes nothing"
    has err "whole site" "and says that the rule is for the whole site"
    run "$S/users.sh password-rule"
    json '.asks_for_new_password' "7 days after the password was set" "the rule is as it was"
    run "$S/users.sh password-rule first-sign-in --yes-change"
    is_rc 0 "with --yes-change the rule is set"
    json '.before + " -> " + .after' "7 days after the password was set -> at the first sign-in" "and it prints the rule before and after"
    json '.accounts_on_a_generated_password | index("sally") != null' true "and who is on a generated password now"
    run "$S/temp-password.sh --yes-reset sally"
    has out "SuiteCRM asks for a new password at the first sign-in." "a new temporary password now says: at the first sign-in"
    pwfile3="$(password_file)"
    temp_pw3="$(sc_agent "sed -n '/^Temporary password:/{n;p}' ~/suitecrm-passwords/${pwfile3}")"
    printf '%s\n' "${temp_pw3}" >> "${work}/temp-passwords"
    file_says="$(sc_agent "tail -n 1 ~/suitecrm-passwords/${pwfile3}")"
    if [[ "${file_says}" == "SuiteCRM asks for a new password at the first sign-in. Delete this file once it is handed over." ]]; then ok "and so does its file"; else bad "and so does its file" "${file_says}"; fi
    code="$(sign_in usr-jar-sally sally "${temp_pw3}")"
    if [ "${code}" = 200 ]; then ok "the fresh temporary password signs in"; else bad "the fresh temporary password signs in" "HTTP ${code}"; fi
    session_is usr-jar-sally '.redirect.route' "users/ChangePassword" "and SuiteCRM sends that sign-in to its change-password page"
    # shellcheck disable=SC2086  # two KEY=VALUE words
    fixture users-password-rule.php ${rule_was}
    run "$S/users.sh password-rule"
    json '.asks_for_new_password' "7 days after the password was set" "(the rule is back as the test found it)"

    # The sign-in throttle: a new password does not end it
    throttled=''
    for _ in 1 2 3 4 5; do throttled="$(login_code sally 'Wrong-Password-1x')"; done
    code="$(login_code sally "${temp_pw3}")"
    if [ "${throttled}${code}" = 401401 ]; then ok "(after 5 wrong tries SuiteCRM refuses sally's right password too)"; else bad "(after 5 wrong tries SuiteCRM refuses sally's right password too)" "HTTP ${throttled} then ${code}"; fi
    run "$S/temp-password.sh --yes-reset sally"
    temp_pw4="$(sc_agent "sed -n '/^Temporary password:/{n;p}' ~/suitecrm-passwords/$(password_file)")"
    printf '%s\n' "${temp_pw4}" >> "${work}/temp-passwords"
    code="$(login_code sally "${temp_pw4}")"
    if [ "${code}" = 401 ]; then ok "a new password does not end the throttle, as restore-admin-password.sh says of itself"; else bad "a new password does not end the throttle, as restore-admin-password.sh says of itself" "HTTP ${code}"; fi

    # The admin locked out: another password and an inactive account, then the way back
    printf 'Changed-By-Someone-9x\n' | fixture lock-admin.php
    printf '%s\n' "${SC_PW_ADMIN}" | fixture users-admin-state.php
    fx_is '.password_matches' false "(the fixture changed the admin's password: the dashboard's no longer matches what is stored)"
    fx_is '.status' Inactive "(and made the account inactive)"
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 401 ]; then ok "(the admin is locked out for the next check)"; else bad "(the admin is locked out for the next check)" "HTTP ${code}"; fi
    run "$S/restore-admin-password.sh"
    is_rc 64 "restore-admin-password.sh without --yes-reset changes nothing"
    hasnt err "clears" "and no longer claims to clear a lockout"
    has err "does not end SuiteCRM's sign-in throttle" "it says that it does not end the sign-in throttle"
    printf '%s\n' "${SC_PW_ADMIN}" | fixture users-admin-state.php
    fx_is '.password_matches' false "and the admin is still locked out"
    run "$S/restore-admin-password.sh --yes-reset"
    is_rc 0 "with --yes-reset the first run restores the password"
    json '.reactivated' true "and makes the account active again"
    json '.was_status + " " + .status' "Inactive Active" "it says what the account was and is"
    json '.is_admin' true "the account is an admin"
    has out "does not end SuiteCRM's sign-in throttle" "the note says that the sign-in throttle is not ended"
    has out "sign in from another network" "and what helps"
    hasnt out "${SC_PW_ADMIN}" "without printing the password"
    printf '%s\n' "${SC_PW_ADMIN}" | fixture users-admin-state.php
    fx_is '.password_matches' true "the stored password is the dashboard's again"
    fx_is '.status + " " + (.is_admin | tostring)' "Active true" "and the account is active and an admin in the database"
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "the admin signs in with the dashboard's password again"; else bad "the admin signs in with the dashboard's password again" "HTTP ${code}"; fi
    # The same with the admin right taken away as well
    printf 'Changed-By-Someone-9x\n' | fixture lock-admin.php demote
    run "$S/restore-admin-password.sh --yes-reset"
    is_rc 0 "it also restores an admin who lost the admin right"
    json '(.was_admin | tostring) + " " + (.is_admin | tostring)' "false true" "and says so"
    printf '%s\n' "${SC_PW_ADMIN}" | fixture users-admin-state.php
    fx_is '(.password_matches | tostring) + " " + .status + " " + (.is_admin | tostring)' "true Active true" "password, status and admin right are back in the database"
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "and the admin signs in"; else bad "and the admin signs in" "HTTP ${code}"; fi
    docker exec "${SC_APP}" bash -c 'rm -f /tmp/usr-jar-*'
fi

# ---------------------------------------------------------------------------
# email
# ---------------------------------------------------------------------------
if wants email; then
    section "email.sh"
    run "$S/email.sh status"
    is_rc 0 "status reads the system account"
    json '.configured' false "which is not set up on a new install"
    run "$S/email.sh test someone@example.test"
    is_rc 64 "a test message needs --yes-send"
    run "$S/email.sh test someone@example.test --yes-send"
    is_rc 2 "and is refused while no server is set"
    run "$S/users.sh invite tom --last-name Tester --email tom@example.test --yes-send"
    is_rc 2 "an invitation is refused while email is not set up"
    sql_is "SELECT COUNT(*) FROM users WHERE user_name = 'tom'" 0 "and no account is made"

    # The admin fills in SuiteCRM's form: here the same bean the form saves, with a made-up SMTP password
    docker cp "${here}/lib/suitecrm-stack/smtp-sink.php" "${SC_APP}:/tmp/smtp-sink.php" > /dev/null
    docker exec -d "${SC_APP}" php /tmp/smtp-sink.php
    smtp_pw='Smtp-Pw-3kLm8Qz5wT'
    printf '%s\n' "${smtp_pw}" | fixture smtp-form.php
    printf '%s\n' "${smtp_pw}" >> "${work}/temp-passwords"
    run "$S/email.sh status"
    json '.configured' true "status sees the account once the form is filled in"
    json '.server' 127.0.0.1 "its server"
    json '.password_stored' true "that a password is stored"
    json '.auth_type' basic "and the sign-in type"
    hasnt out "${smtp_pw}" "but never the password"
    hasnt out "mail_smtppass" "nor the column that holds it"
    run "$S/email.sh test someone@example.test --yes-send"
    is_rc 0 "a test message is sent"
    sink="$(sc_app_root 'cat /tmp/smtp-sink.log')"
    if [[ "${sink}" == *"auth user=mailer@example.test password_length=${#smtp_pw}"*"RCPT TO:<someone@example.test>"* ]]; then ok "the server saw a sign-in and the recipient"; else bad "the server saw a sign-in and the recipient" "${sink}"; fi

    # The trap: a user name with no auth_type, as older tools leave it
    sc_db_sql "UPDATE outbound_email SET auth_type = NULL WHERE type = 'system'"
    run "$S/email.sh status"
    json '.warnings | length > 0' true "status warns when auth_type is not basic"
    has out "auth_type" "and names it"
    run "$S/email.sh set-auth-basic"
    is_rc 64 "set-auth-basic needs --yes-change"
    run "$S/email.sh set-auth-basic --yes-change"
    is_rc 0 "set-auth-basic fixes it"
    sql_is "SELECT auth_type FROM outbound_email WHERE type = 'system'" basic "the account signs in again"
    sc_app_root ': > /tmp/smtp-sink.log'
    run "$S/email.sh test again@example.test --yes-send"
    sink="$(sc_app_root 'cat /tmp/smtp-sink.log')"
    if [[ "${sink}" == *"password_length=${#smtp_pw}"* ]]; then ok "and the stored password still works after the fix"; else bad "and the stored password still works after the fix" "${sink}"; fi

    run "$S/users.sh invite tom --first-name Tom --last-name Tester --email tom@example.test"
    is_rc 64 "an invitation needs --yes-send"
    run "$S/users.sh invite tom --first-name Tom --last-name Tester --email tom@example.test --yes-send"
    is_rc 0 "an invitation makes the account and sends SuiteCRM's email"
    json '.email_sent' true "and says the email went out"
    sink="$(sc_app_root 'cat /tmp/smtp-sink.log')"
    if [[ "${sink}" == *"RCPT TO:<tom@example.test>"* ]]; then ok "the server saw the invitation"; else bad "the server saw the invitation" "${sink}"; fi
    sc_db_sql "UPDATE outbound_email SET mail_smtpport = 2599 WHERE type = 'system'"
    run "$S/email.sh test someone@example.test --yes-send"
    is_rc 2 "a server that does not answer is exit 2"
    has err "Could not connect" "with SuiteCRM's reason"
    sc_db_sql "UPDATE outbound_email SET mail_smtpport = 2525 WHERE type = 'system'"
fi

# take_backup: a complete backup by this skill, which the bulk actions want to see first
take_backup() {
    run "$S/run-in-suitecrm.sh backup.sh"
    if [ "${rc}" -ne 0 ]; then bad "(a backup for the next checks)" "${out}"$'\n'"${err}"; fi
}

# ---------------------------------------------------------------------------
# import
# ---------------------------------------------------------------------------
if wants import; then
    section "import-csv.sh"
    sc_app_root 'rm -rf /var/www/html/tmp/clouve-skill-backups/2*'
    imports_dir=/var/www/html/tmp/clouve-skill-imports
    upload_dir=/var/www/html/public/legacy/upload/import
    # plan_run MODULE FILE [OPTIONS]: a plan of the file (in the agent user's home), then the run of that plan; out,
    # err and rc are the run's
    plan_run() {
        run "$S/import-csv.sh plan $1 $2 ${3:-}"
        run "$S/import-csv.sh run $1 $2 --plan $(val .plan_id) ${3:-} --yes-import"
    }
    # count_is TABLE NAMES WANT LABEL: how many rows of TABLE have one of the last names
    count_is() { sql_is "SELECT COUNT(*) FROM $1 WHERE last_name IN ($2)" "$3" "$4"; }
    run_in '{"name": "Acme Existing"}' "$S/records.sh create Accounts --allow-duplicate"
    run_in '{"first_name": "Erin", "last_name": "Existing", "email1": "erin@acme.example"}' "$S/records.sh create Contacts --allow-duplicate"
    erin="$(val .id)"
    sc_agent_stdin 'cat > ~/contacts.csv' <<'CSV'
First Name,last_name,email1,title,account_name,nonsense_column
Ann,Archer,ann@acme.example,Buyer,Acme Existing,x
Bob,Baker,bob@soylent.example,CTO,Soylent Corp,x
Erin,Existing,ERIN@acme.example,Dup,Acme Existing,x
Cat,Cook,not-an-email,Chef,Acme Existing,x
"Dee ""D"" O'Neil",Dunn,dee@acme.example,"Lead, Sales",Acme Existing,x
CSV
    fixture workflow.php import-off < /dev/null
    run_in '{"first_name": "Wanda", "last_name": "Workflow", "email1": "wanda@example.test"}' "$S/records.sh create Contacts"
    json '.fields.description' "stamped by workflow" "a workflow runs on a contact that records.sh creates, as it does in the browser"
    run "$S/import-csv.sh plan Contacts '~/contacts.csv'"
    is_rc 0 "a path that starts with ~/ works inside quotes too"
    run "$S/import-csv.sh plan Contacts ~/contacts.csv"
    is_rc 0 "plan reads the file and changes nothing"
    json '.rows' 5 "it counts the data rows, without the header"
    json '[.columns[] | .field] | join(",")' "first_name,last_name,email1,title,account_name" "it maps columns by field name and by label"
    json '.columns_not_imported[0].column' nonsense_column "it names the column it can't map"
    json '.likely_duplicates.already_in_suitecrm' 1 "it finds the contact that is already there"
    json '.accounts_it_would_create | join(",")' "Soylent Corp" "it names the account the import would create"
    json '.rows_with_problems[0].csv_line' 5 "it points at the row with a bad email address"
    json '.ready' true "and says the file can be imported"
    has out "creates 1 new account" "the plan says in words that an account would be created"
    plan1="$(val .plan_id)"
    json '.plan_id | test("^p[0-9]{8}-[0-9]{6}-[0-9]{6}$")' true "the plan has an id"
    json '.file_sha256' "$(sc_agent 'sha256sum ~/contacts.csv' | cut -d' ' -f1)" "and the file's checksum"
    json '.rows_will_belong_to.rows_by_login["'"${SC_ADMIN_USER}"'"]' 5 "it says that the rows will belong to the main admin"
    has out "will belong to the main admin (${SC_ADMIN_USER}), because the file has no assigned_user_name column" "in words too"
    json '.formula_cells.count' 0 "it counts no formula cells in a file that has none"
    json '.workflows_that_run[0].name' "Test stamp" "it lists the active workflow of the module"
    json '.workflows_that_run[0].runs | test("scheduler")' true "one that is not marked to run on import takes the rows at the scheduler's next pass"
    json '.workflows_that_run[0].actions | join(",")' ModifyRecord "with its actions"
    json '.workflows_that_run[0].sends_email' false "and whether it sends email"
    count_is contacts "'Archer', 'Baker', 'Cook', 'Dunn'" 0 "the plan wrote nothing"

    run "$S/import-csv.sh run Contacts ~/contacts.csv"
    is_rc 64 "run needs --yes-import"
    run "$S/import-csv.sh run Contacts ~/contacts.csv --yes-import"
    is_rc 64 "and the id of the plan the user saw"
    has err "--plan" "the refusal names --plan"
    run "$S/import-csv.sh run Contacts ~/contacts.csv --plan ${plan1} --yes-import"
    is_rc 76 "and a backup from the last 24 hours"
    has err "backup" "the refusal says so"
    count_is contacts "'Archer', 'Baker', 'Cook', 'Dunn'" 0 "nothing was imported"
    take_backup
    run "$S/import-csv.sh run Contacts ~/contacts.csv --plan p20000101-000000-000000 --yes-import"
    is_rc 65 "a plan id that does not exist is refused"
    run "$S/import-csv.sh run Leads ~/contacts.csv --plan ${plan1} --yes-import"
    is_rc 65 "a plan of another module is refused"
    run "$S/import-csv.sh run Contacts ~/contacts.csv --plan ${plan1} --dup-fields none --yes-import"
    is_rc 65 "and so is a run with other duplicate fields than the plan's"
    count_is contacts "'Archer', 'Baker', 'Cook', 'Dunn'" 0 "none of those imported anything"

    # An import the admin is doing in the browser has files of its own in upload/import: the upload
    # (IMPORT_<module>_<user id>) and the status file (status_<user id>.csv). Another user's are there too.
    sc_app_www "mkdir -p ${upload_dir} && printf 'the admin, in the browser\n' > ${upload_dir}/IMPORT_Contacts_1 && printf '7,0,0,7,0,browser\n' > ${upload_dir}/status_1.csv && printf '3,1,0,2,0,someone else\n' > ${upload_dir}/status_another-user-id.csv"
    browser_files_before="$(sc_app_root "cd ${upload_dir} && md5sum IMPORT_Contacts_1 status_1.csv status_another-user-id.csv")"
    run "$S/import-csv.sh run Contacts ~/contacts.csv --plan ${plan1} --yes-import"
    is_rc 0 "run imports the file after a backup"
    receipt1="$(val .receipt)"
    json '.receipt | test("^r[0-9]{8}-[0-9]{6}-[0-9]{6}$")' true "and prints the run's receipt id"
    json '.created' 3 "three contacts are created"
    json '.skipped_as_duplicates' 1 "the duplicate is skipped"
    json '.rows_with_errors' 1 "the bad row is reported"
    json '.errors[0].csv_line' 5 "with its line in the file"
    json '.records_made_by_module.Accounts' 1 "and the account it made by name is counted"
    sql_is "SELECT COUNT(*) FROM contacts WHERE deleted = 0 AND first_name = 'First Name'" 0 "the header row did not become a contact"
    sql_is "SELECT first_name FROM contacts WHERE deleted = 0 AND last_name = 'Dunn'" 'Dee "D" O'"'"'Neil' "quotes and commas in a cell arrive unchanged"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'Soylent Corp'" 1 "the account exists now"
    sql_is "SELECT COUNT(*) FROM contacts WHERE deleted = 0 AND last_name IN ('Archer', 'Baker', 'Dunn') AND description = 'stamped by workflow'" 0 "a workflow that is not marked to run on import leaves imported rows alone while the import runs, as in the browser"
    left="$(sc_app_root "ls ${upload_dir}/ 2>/dev/null | grep -c clouve-skill || true")"
    if [ "${left}" = 0 ]; then ok "the uploaded copy of the file is gone from SuiteCRM's upload folder"; else bad "the uploaded copy of the file is gone from SuiteCRM's upload folder" "${left} left"; fi
    browser_files_after="$(sc_app_root "cd ${upload_dir} && md5sum IMPORT_Contacts_1 status_1.csv status_another-user-id.csv" 2>&1)"
    if [ "${browser_files_before}" = "${browser_files_after}" ]; then ok "the admin's own browser upload and status file, and another user's status file, are still in upload/import, unchanged"; else bad "the admin's own browser upload and status file, and another user's status file, are still in upload/import, unchanged" "before:"$'\n'"${browser_files_before}"$'\n'"after:"$'\n'"${browser_files_after}"; fi
    left="$(sc_app_root "ls -d ${imports_dir}/aside-* 2>/dev/null | wc -l")"
    if [ "${left}" = 0 ]; then ok "and nothing that was set aside for the run is left behind"; else bad "and nothing that was set aside for the run is left behind" "${left} left"; fi
    sc_app_root "rm -f ${upload_dir}/IMPORT_Contacts_1 ${upload_dir}/status_1.csv ${upload_dir}/status_another-user-id.csv"
    modes="$(sc_app_root "stat -c '%U %a' ${imports_dir} ${imports_dir}/${receipt1}.json ${imports_dir}/${plan1}.json | sort -u | tr '\n' ';'")"
    if [ "${modes}" = "www-data 600;www-data 700;" ]; then ok "the receipts folder is the web user's alone (700), and so are the plan and the receipt (600)"; else bad "the receipts folder is the web user's alone (700), and so are the plan and the receipt (600)" "${modes}"; fi

    run "$S/import-csv.sh run Contacts ~/contacts.csv --plan ${plan1} --yes-import"
    is_rc 65 "the same plan can't be run twice (a repeated command does not import again)"
    has err "${receipt1}" "the refusal names the run that used the plan"
    count_is contacts "'Archer', 'Baker', 'Dunn'" 3 "and nothing was imported a second time"

    run "$S/import-csv.sh last Contacts"
    json '.imports[0].can_undo' true "last shows the import and that it can be undone"
    json '.imports[0].receipt' "${receipt1}" "with its receipt id"
    json '.imports[0] | "\(.mode) \(.state) \(.created) \(.skipped_as_duplicates) \(.rows_with_errors)"' "import done 3 1 1" "its mode, its state and its counts"
    run "$S/import-csv.sh undo Contacts"
    is_rc 64 "undo without a receipt id is a usage error"
    run "$S/import-csv.sh undo Contacts --yes-undo"
    is_rc 64 "and so is undo with the yes and no receipt id"
    has err "receipt id" "it asks for the receipt id"
    count_is contacts "'Archer', 'Baker', 'Dunn'" 3 "neither removed anything"
    run "$S/import-csv.sh undo Contacts ${receipt1}"
    is_rc 64 "undo needs --yes-undo"
    json '.undone' false "without it, it is a preview that removes nothing"
    json '.can_undo' true "which says that this run can be undone"
    json '"\(.would_remove_by_module.Contacts) \(.would_remove_by_module.Accounts)"' "3 1" "how many records of which module an undo would remove"
    json '.accounts_it_made_by_name | join(",")' "Soylent Corp" "and the account the import made by name"
    has err "nothing was removed" "it says that nothing was removed"
    has err "from the database for good" "that an undo deletes for good"
    has err "does not put back what an --update run changed" "and that an update's changes are not put back"
    count_is contacts "'Archer', 'Baker', 'Dunn'" 3 "the preview removed nothing"
    run "$S/import-csv.sh undo Leads ${receipt1} --yes-undo"
    is_rc 3 "a receipt of another module is refused"
    run "$S/import-csv.sh undo Contacts r20000101-000000-000000 --yes-undo"
    is_rc 3 "and so is a receipt id that does not exist"
    count_is contacts "'Archer', 'Baker', 'Dunn'" 3 "neither removed anything"
    run "$S/import-csv.sh undo Contacts ${receipt1} --yes-undo"
    is_rc 0 "undo removes what the import made"
    json '.records_removed_by_module.Contacts' 3 "the three contacts"
    json '.records_removed_by_module.Accounts' 1 "and the account"
    sql_is "SELECT COUNT(*) FROM contacts WHERE last_name IN ('Archer', 'Baker', 'Dunn')" 0 "they are gone from the database, not just hidden"
    sql_is "SELECT COUNT(*) FROM contacts WHERE deleted = 0 AND last_name = 'Existing'" 1 "the contact that was there before is untouched"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'Acme Existing'" 1 "and so is the account that was there before"
    run "$S/import-csv.sh undo Contacts ${receipt1} --yes-undo"
    is_rc 3 "a second undo has nothing to undo"
    run "$S/import-csv.sh last Contacts"
    json '.imports[0] | "\(.state) \(.can_undo)"' "undone false" "last shows the run as undone"

    # Two imports into one module, and one that creates nothing in between. An undo removes the run it
    # names, once, and never an older one.
    sc_agent_stdin 'cat > ~/older.csv' <<'CSV'
last_name,email1
Older One,older1@leads.example
Older Two,older2@leads.example
CSV
    sc_agent_stdin 'cat > ~/newer.csv' <<'CSV'
last_name,email1
Newer One,newer1@leads.example
Newer Two,newer2@leads.example
CSV
    # A file of the admin's that a run set aside and, cut off, never put back
    sc_app_www "mkdir -p ${imports_dir}/aside-r20000101-000000-000000 && printf '9,0,0,9,0,left by a run that was cut off\n' > ${imports_dir}/aside-r20000101-000000-000000/status_1.csv"
    plan_run Leads older.csv
    is_rc 0 "a first import into Leads"
    older="$(val .receipt)"
    back="$(sc_app_root "cat ${upload_dir}/status_1.csv 2>&1; ls -d ${imports_dir}/aside-* 2> /dev/null | wc -l")"
    if [ "${back}" = '9,0,0,9,0,left by a run that was cut off'$'\n''0' ]; then ok "a file that a cut-off run had set aside is back in upload/import after the next run"; else bad "a file that a cut-off run had set aside is back in upload/import after the next run" "${back}"; fi
    sc_app_root "rm -f ${upload_dir}/status_1.csv"
    plan_run Leads older.csv
    is_rc 0 "the same file again imports"
    json '.created' 0 "and creates nothing: both rows are duplicates"
    nothing="$(val .receipt)"
    json '.receipt | test("^r[0-9]")' true "a run that created nothing has a receipt too"
    json '.undo' null "and offers no undo"
    run "$S/import-csv.sh undo Leads ${nothing} --yes-undo"
    is_rc 3 "undo of the run that created nothing is refused"
    has err "created nothing" "and says why"
    count_is leads "'Older One', 'Older Two'" 2 "the first import's rows are all still there"
    plan_run Leads newer.csv
    is_rc 0 "a second import into Leads"
    newer="$(val .receipt)"
    run "$S/import-csv.sh last Leads"
    json '[.imports[:3][] | .receipt] | join(" ")' "${newer} ${nothing} ${older}" "last lists the three runs, newest first"
    json '[.imports[:3][] | .can_undo] | join(" ")' "true false false" "only the newest can be undone now"
    json '.imports[2].why_not | test("'"${newer}"'")' true "and the older one's reason names the newer run"
    run "$S/import-csv.sh undo Leads ${older} --yes-undo"
    is_rc 2 "undo of the older import while the newer one stands is refused"
    has err "${newer}" "the refusal names the newer run"
    has err "Newer imports are undone first, each with its own yes" "and says that newer imports go first"
    count_is leads "'Older One', 'Older Two', 'Newer One', 'Newer Two'" 4 "nothing was removed"
    run "$S/import-csv.sh undo Leads ${older}"
    is_rc 2 "the preview of an undo that is not possible ends with the refusal's code"
    json '.can_undo' false "and says that it can't be undone"
    # A run that was cut off leaves a receipt in the state "started": its records can't be told apart.
    sc_app_www "printf '%s' '{\"receipt\":\"r20991231-235959-000000\",\"state\":\"started\",\"module\":\"Leads\",\"mode\":\"import\",\"made_utc\":\"2099-12-31 23:59:59\",\"rows\":[]}' > ${imports_dir}/r20991231-235959-000000.json"
    run "$S/import-csv.sh undo Leads r20991231-235959-000000 --yes-undo"
    is_rc 2 "undo of a run that did not finish is refused"
    has err "did not finish" "and says why"
    run "$S/import-csv.sh undo Leads ${newer} --yes-undo"
    is_rc 2 "and it blocks the undo of the imports before it"
    count_is leads "'Older One', 'Older Two', 'Newer One', 'Newer Two'" 4 "nothing was removed"
    sc_app_root "rm -f ${imports_dir}/r20991231-235959-000000.json"
    run "$S/import-csv.sh undo Leads ${newer} --yes-undo"
    is_rc 0 "undo of the newer import, by its receipt id"
    count_is leads "'Newer One', 'Newer Two'" 0 "removes the newer import's rows"
    run "$S/import-csv.sh undo Leads ${newer} --yes-undo"
    is_rc 3 "the same command again is refused: that run is undone already"
    has err "undone already" "and says so"
    count_is leads "'Older One', 'Older Two'" 2 "and the first import's rows are all still there"
    run "$S/import-csv.sh undo Leads ${older} --yes-undo"
    is_rc 0 "after the newer one is undone, the older import can be undone by its id"
    count_is leads "'Older One', 'Older Two'" 0 "and its rows are gone"

    # An update gets a receipt, and has no undo
    printf 'id,title\n%s,Changed by an update\n' "${erin}" | sc_agent_stdin 'cat > ~/retitle.csv'
    plan_run Contacts retitle.csv --update
    is_rc 0 "an update of an existing contact runs"
    json '.updated' 1 "and changes it"
    update_receipt="$(val .receipt)"
    json '.undo' null "it offers no undo"
    run "$S/import-csv.sh last Contacts"
    json '.imports[0] | "\(.receipt) \(.mode) \(.can_undo)"' "${update_receipt} update false" "last shows the update with its receipt, and that it can't be undone"
    run "$S/import-csv.sh undo Contacts ${update_receipt} --yes-undo"
    is_rc 2 "undo of an update is refused"
    has err "an update has no undo" "and says that the backup is the way back"
    sql_is "SELECT title FROM contacts WHERE id = '${erin}'" "Changed by an update" "the change stays"

    # One import or undo at a time
    docker exec -d -u www-data "${SC_APP}" php -r "file_put_contents('/tmp/import-lock.pid', getmypid()); \$f = fopen('${imports_dir}/lock', 'c'); flock(\$f, LOCK_EX); sleep(120);"
    sc_app_root 'for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/import-lock.pid ] && break; sleep 0.3; done; sleep 0.3'
    run "$S/import-csv.sh plan Leads ~/newer.csv"
    run "$S/import-csv.sh run Leads ~/newer.csv --plan $(val .plan_id) --yes-import"
    is_rc 2 "a run is refused while another import or undo of the skill is running"
    has err "another import or undo" "and says why"
    count_is leads "'Newer One', 'Newer Two'" 0 "nothing was imported"
    sc_app_root 'kill "$(cat /tmp/import-lock.pid)" 2> /dev/null; rm -f /tmp/import-lock.pid'

    # The plan says what a workflow that is marked "Run on import" does, and how many emails that is
    fixture workflow.php import-on < /dev/null
    fixture workflow.php email-on < /dev/null
    run "$S/import-csv.sh plan Contacts ~/contacts.csv"
    json '.workflows_that_run[0].runs | test("during the import")' true "the plan says that a workflow marked to run on import runs during the import"
    json '.workflows_that_run[0].actions | join(",")' "ModifyRecord,SendEmail" "with its actions"
    json '.workflows_that_run[0].sends_email' true "and that it sends email"
    has out "This workflow sends an email for each imported row: 5 rows" "and says in words how many emails that is"
    fixture workflow.php email-off < /dev/null

    # The admin imports in the browser after ours: SuiteCRM forgets our rows, and the undo must refuse
    plan_run Contacts contacts.csv
    receipt2="$(val .receipt)"
    sql_is "SELECT COUNT(*) FROM contacts WHERE deleted = 0 AND last_name IN ('Archer', 'Baker', 'Dunn') AND description = 'stamped by workflow'" 3 "and one that is marked to run on import runs for them"
    fixture workflow.php inactive < /dev/null
    sc_db_sql "DELETE FROM users_last_import WHERE assigned_user_id = '1'"
    run "$S/import-csv.sh undo Contacts ${receipt2} --yes-undo"
    is_rc 2 "undo refuses once SuiteCRM no longer tracks the import"
    has err "SuiteCRM's own Import screen" "and says what clears that tracking: an import the admin starts in the browser"
    hasnt err "or here" "not an import by this skill"
    count_is contacts "'Archer', 'Baker', 'Dunn'" 3 "and removes nothing"
    run "$S/import-csv.sh last Contacts"
    json '.imports[] | select(.receipt == "'"${receipt2}"'") | .can_undo' false "last says so too"

    # The file changed after the plan
    printf 'last_name,email1\nPlanned,planned@leads.example\n' | sc_agent_stdin 'cat > ~/changed.csv'
    run "$S/import-csv.sh plan Leads ~/changed.csv"
    json '.rows' 1 "a plan of a file with one row"
    changed_plan="$(val .plan_id)"
    printf 'last_name,email1\nSwapped One,swapped1@leads.example\nSwapped Two,swapped2@leads.example\nSwapped Three,swapped3@leads.example\nSwapped Four,swapped4@leads.example\n' | sc_agent_stdin 'cat > ~/changed.csv'
    run "$S/import-csv.sh run Leads ~/changed.csv --plan ${changed_plan} --yes-import"
    is_rc 65 "run refuses a file that changed after the plan"
    has err "the file has changed since the plan was made" "and says so"
    sql_is "SELECT COUNT(*) FROM leads WHERE last_name LIKE 'Swapped%' OR last_name = 'Planned'" 0 "nothing was imported"
    run "$S/import-csv.sh plan Leads ~/changed.csv"
    old_plan="$(val .plan_id)"
    sc_app_www "sed -i 's/\"made_at\":[0-9]*/\"made_at\":1000000000/' ${imports_dir}/${old_plan}.json"
    run "$S/import-csv.sh run Leads ~/changed.csv --plan ${old_plan} --yes-import"
    is_rc 65 "run refuses a plan that is older than 24 hours"
    has err "older than 24 hours" "and says so"
    sql_is "SELECT COUNT(*) FROM leads WHERE last_name LIKE 'Swapped%'" 0 "nothing was imported"

    # A quoted cell that ends in a backslash: SuiteCRM's CSV reader takes the next row into it
    sc_agent_stdin 'cat > ~/backslash.csv' <<'CSV'
last_name,email1,description
Slash,slash@leads.example,"ends with a backslash \"
After,after@leads.example,the next person in the file
CSV
    run "$S/import-csv.sh plan Leads ~/backslash.csv"
    json '.rows' 2 "the plan reads a cell that ends in a backslash as the file has it: two rows"
    json '.ready' false "and says the file is not ready"
    json '.rows_with_problems[0].csv_line' 2 "it names the line"
    json '.rows_with_problems[0].problem | test("backslash")' true "and the reason"
    run "$S/import-csv.sh run Leads ~/backslash.csv --plan $(val .plan_id) --yes-import"
    is_rc 65 "run refuses that file"
    count_is leads "'Slash', 'After'" 0 "and imports nothing"

    # Cells a spreadsheet would run as a formula are counted; a signed number and a phone number are not
    sc_agent_stdin 'cat > ~/formulas.csv' <<'CSV'
last_name,email1,phone_work,description
Formula One,formula1@leads.example,+1 555 0100,"=HYPERLINK(""http://evil.example"",""click"")"
Plain,plain@leads.example,+44 (20) 7946-0958,nothing special
Formula Two,formula2@leads.example,555-0101,@SUM(1+1)
CSV
    run "$S/import-csv.sh plan Leads ~/formulas.csv"
    json '.formula_cells.count' 2 "the plan counts the cells that start with =, +, - or @, and not a phone number that starts with +"
    json '.formula_cells.csv_lines | join(",")' "2,4" "with their lines"
    json '.ready' true "the file can still be imported: the cells are stored as given"
    has out "SuiteCRM's own CSV export writes them out unchanged" "and the plan says in words what a spreadsheet may do with them"
    printf 'name,account_name,amount,date_closed,sales_stage,next_step\nRefund,Acme Existing,-250.50,2026-12-31,Prospecting,-2+3\n' | sc_agent_stdin 'cat > ~/negative.csv'
    run "$S/import-csv.sh plan Opportunities ~/negative.csv"
    json '.formula_cells.count' 1 "a negative number in a number field is not counted, the same sign in a text field is"

    # Who the rows will belong to
    printf 'last_name,email1,assigned_user_name\nMine,mine@leads.example,%s\nNobodys,nobodys@leads.example,no-such-login\nDefault,default@leads.example,\n' "${SC_ADMIN_USER}" | sc_agent_stdin 'cat > ~/owners.csv'
    run "$S/import-csv.sh plan Leads ~/owners.csv"
    json '.rows_will_belong_to.by' "the assigned_user_name column" "with an assigned_user_name column, the plan says that the column decides who owns the rows"
    json '.rows_will_belong_to.rows_by_login["'"${SC_ADMIN_USER}"'"]' 2 "it counts the rows of each login, a row with no owner going to the main admin"
    json '[.rows_with_problems[] | select(.problem | test("no user has the login")) | .csv_line] | join(",")' 3 "it names the row whose assigned_user_name is no user's login"
    json '.ready' false "and says the file is not ready"

    # Numbers and dates in a file, with the main admin's profile set to 1.234,56 and day-first dates
    fixture records-profile.php european < /dev/null
    profile_before="$(sc_db_sql "SELECT MD5(contents) FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global' AND deleted = 0")"
    printf 'name,account_name,amount,date_closed,sales_stage\nImported deal,Acme Existing,1234.56,2026-12-31,Prospecting\n' | sc_agent_stdin 'cat > ~/deal.csv'
    plan_run Opportunities deal.csv
    is_rc 0 "an import runs when the main admin's profile has a comma as the decimal symbol and day-first dates"
    json '.created' 1 "it creates the opportunity"
    sql_is "SELECT amount, date_closed FROM opportunities WHERE deleted = 0 AND name = 'Imported deal'" $'1234.56\t2026-12-31' "a cell of 1234.56 and a date are stored as the file has them (the amount is not 100 times too large)"
    profile_after="$(sc_db_sql "SELECT MD5(contents) FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global' AND deleted = 0")"
    if [ -n "${profile_before}" ] && [ "${profile_before}" = "${profile_after}" ]; then ok "and the main admin's stored profile is unchanged by the import"; else bad "and the main admin's stored profile is unchanged by the import" "before ${profile_before}, after ${profile_after}"; fi
    fixture records-profile.php restore < /dev/null

    sc_agent_stdin 'cat > ~/bad.csv' <<'CSV'
first_name,title
No,Lastname
CSV
    run "$S/import-csv.sh plan Contacts ~/bad.csv"
    json '.required_fields_missing | join(",")' last_name "plan names a required field the file lacks"
    json '.ready' false "and says the file is not ready"
    run "$S/import-csv.sh run Contacts ~/bad.csv --plan $(val .plan_id) --yes-import"
    is_rc 65 "run refuses a file that is not ready"
    run "$S/import-csv.sh plan Contacts ~/no-such-file.csv"
    is_rc 64 "a file that is not there is a usage error"
    run "$S/import-csv.sh plan Widgets ~/contacts.csv"
    is_rc 64 "and so is a module outside the four"
    sc_agent_stdin 'cat > ~/update.csv' <<'CSV'
id,title
no-such-id,Boss
CSV
    run "$S/import-csv.sh plan Contacts ~/update.csv --update"
    json '.ready' false "an update whose ids match nothing is not ready"
fi

# ---------------------------------------------------------------------------
# packages
# ---------------------------------------------------------------------------
if wants packages; then
    section "packages.sh and repair.sh"
    sc_app_root 'rm -rf /var/www/html/tmp/clouve-skill-backups/2*'
    # A small Module Loader package: one file, one language string
    pkg="${work}/pkg"
    mkdir -p "${pkg}/files" "${pkg}/language"
    cat > "${pkg}/manifest.php" <<'PHP'
<?php
$manifest = ['name' => 'Test Hello', 'description' => 'A test package', 'version' => '1.0.0', 'author' => 'Test',
    'acceptable_sugar_versions' => ['regex_matches' => ['6\.5\.[0-9]+']], 'acceptable_suitecrm_versions' => ['regex_matches' => ['8\..*']],
    'type' => 'module', 'is_uninstallable' => true, 'published_date' => '2026-11-12'];
$installdefs = ['id' => 'test_hello', 'copy' => [['from' => '<basepath>/files/TestHello.php', 'to' => 'custom/include/TestHello.php']],
    'language' => [['from' => '<basepath>/language/en_us.lang.php', 'to_module' => 'application', 'language' => 'en_us']]];
PHP
    printf '<?php\n// test package file\n' > "${pkg}/files/TestHello.php"
    printf '<?php\n$app_strings["LBL_TEST_HELLO"] = "Hello";\n' > "${pkg}/language/en_us.lang.php"
    (cd "${pkg}" && python3 -c "
import zipfile, os
z = zipfile.ZipFile('../test_hello.zip', 'w')
for root, dirs, files in os.walk('.'):
    for f in files:
        z.write(os.path.join(root, f))
z.close()")
    cp "${pkg}/manifest.php" "${pkg}/keep-manifest.php"
    printf '<?php\n$manifest = ["name" => "Risky", "version" => "1", "type" => "module", "acceptable_sugar_versions" => ["regex_matches" => [".*"]]];\n$installdefs = ["id" => "risky", "post_install" => ["<basepath>/scripts/post.php"]];\n' > "${pkg}/manifest.php"
    mkdir -p "${pkg}/scripts"
    printf '<?php\nshell_exec("id");\n' > "${pkg}/scripts/post.php"
    (cd "${pkg}" && python3 -c "
import zipfile
z = zipfile.ZipFile('../risky.zip', 'w')
z.write('manifest.php'); z.write('scripts/post.php')
z.close()")
    docker cp "${work}/test_hello.zip" "${SC_AGENT}:/home/clouve/test_hello.zip" > /dev/null
    docker cp "${work}/risky.zip" "${SC_AGENT}:/home/clouve/risky.zip" > /dev/null
    sc_agent_stdin 'cat > ~/not-a-package.zip' <<< "this is not a zip"
    docker exec "${SC_AGENT}" chown clouve:clouve /home/clouve/test_hello.zip /home/clouve/risky.zip

    run "$S/packages.sh list"
    is_rc 0 "list reads the installed packages"
    json '.packages | length' 0 "of which a new install has none"
    run "$S/packages.sh inspect '~/test_hello.zip'"
    is_rc 0 "a path that starts with ~/ works inside quotes too"
    run "$S/packages.sh inspect ~/test_hello.zip"
    is_rc 0 "inspect reads a package without running it"
    has out "test_hello" "it shows the package's id"
    has out "custom/include/TestHello.php" "and the files it copies"
    has out "No install scripts" "and says it runs no scripts of its own"
    pkg_sum="$(printf '%s\n' "${out}" | sed -n 's/^sha256: //p')"
    if [ -n "${pkg_sum}" ] && [ "${pkg_sum}" = "$(sha256sum "${work}/test_hello.zip" | cut -d ' ' -f 1)" ]; then ok "and prints the file's sha256 checksum"; else bad "and prints the file's sha256 checksum" "inspect printed: ${pkg_sum:-nothing}"; fi
    has out "--sha256 ${pkg_sum} --yes-install" "with the install command for this very file"
    run "$S/packages.sh inspect ~/risky.zip"
    is_rc 0 "inspect reads a risky package too"
    has out "post_install" "it flags an install script"
    has out "shell_exec" "and code that runs commands"
    run "$S/packages.sh inspect ~/not-a-package.zip"
    is_rc 65 "a file that is not a zip with a manifest.php is refused"
    run "$S/packages.sh install ~/test_hello.zip --yes-install"
    is_rc 64 "install needs --sha256, the checksum of the file that was inspected"
    has err "--sha256" "and says so"
    run "$S/packages.sh install ~/test_hello.zip --sha256 nonsense --yes-install"
    is_rc 64 "a --sha256 that is not a checksum is a usage error"
    run "$S/packages.sh install ~/test_hello.zip --sha256 ${pkg_sum}"
    is_rc 64 "install needs --yes-install"
    run "$S/packages.sh install ~/test_hello.zip --sha256 ${pkg_sum} --yes-install"
    is_rc 76 "and a backup from the last 24 hours"
    take_backup
    # Another file under the checksum of the one that was inspected
    run "$S/packages.sh install ~/risky.zip --sha256 ${pkg_sum} --yes-install"
    is_rc 65 "a file that is not the one that was inspected is refused"
    has err "not the file that was inspected" "and the message says why"
    run "SC_SKILL_CALLER=packages.sh $S/run-in-suitecrm.sh --stdin php packages.php install test_hello.zip ${pkg_sum} < ~/risky.zip"
    is_rc 65 "the SuiteCRM side checks the bytes that arrive as well"
    run "$S/packages.sh list"
    json '.packages | length' 0 "and nothing was installed"
    present="$(sc_app_root 'ls /var/www/html/public/legacy/upload/risky.zip /var/www/html/public/legacy/upload/test_hello.zip 2>/dev/null | wc -l')"
    if [ "${present}" = 0 ]; then ok "nor left in SuiteCRM's upload folder"; else bad "nor left in SuiteCRM's upload folder" "${present} files"; fi
    run "$S/packages.sh install ~/test_hello.zip --sha256 ${pkg_sum} --yes-install"
    is_rc 0 "install puts the inspected package in through Module Loader"
    json '.package.id_name' test_hello "and reads it back from SuiteCRM's list"
    present="$(sc_app_root 'test -f /var/www/html/public/legacy/custom/include/TestHello.php && stat -c %U /var/www/html/public/legacy/custom/include/TestHello.php')"
    if [ "${present}" = www-data ]; then ok "the package's file is in place and belongs to www-data"; else bad "the package's file is in place and belongs to www-data" "${present}"; fi
    run "$S/packages.sh list"
    json '.packages[0].id_name' test_hello "list shows it"
    run "$S/packages.sh uninstall test_hello"
    is_rc 64 "uninstall needs --yes-uninstall"
    # SuiteCRM's stored copy of the zip is gone: an uninstall would only take the package off the list
    stored=/var/www/html/public/legacy/upload/upgrades/module/test_hello.zip
    sc_app_root "mv ${stored} /tmp/usr-test_hello.zip"
    run "$S/packages.sh uninstall test_hello --yes-uninstall"
    is_rc 2 "an uninstall is refused when SuiteCRM's stored copy of the zip is gone"
    has err "Nothing was changed" "and says that nothing was changed"
    hasnt out "uninstalled" "it does not report an uninstall"
    run "$S/packages.sh list"
    json '.packages[0].id_name + " " + .packages[0].status' "test_hello installed" "the package is still listed as installed"
    present="$(sc_app_root 'test -f /var/www/html/public/legacy/custom/include/TestHello.php && echo yes || echo no')"
    if [ "${present}" = yes ]; then ok "and its file is still in place"; else bad "and its file is still in place"; fi
    sc_app_root "mv /tmp/usr-test_hello.zip ${stored}"
    run "$S/packages.sh uninstall test_hello --yes-uninstall"
    is_rc 0 "with the stored zip back, uninstall takes it out again"
    json '.tables_and_custom_fields' kept "and keeps the tables and custom fields a package made, unless told otherwise"
    present="$(sc_app_root 'test -f /var/www/html/public/legacy/custom/include/TestHello.php && echo yes || echo no')"
    if [ "${present}" = no ]; then ok "and its file is gone"; else bad "and its file is gone"; fi
    run "$S/packages.sh uninstall never_installed --yes-uninstall"
    is_rc 3 "uninstall of a package that is not installed is exit 3"
    run "$S/packages.sh install ~/test_hello.zip --sha256 ${pkg_sum} --yes-install"
    run "$S/packages.sh uninstall test_hello --remove-tables --yes-uninstall"
    is_rc 0 "uninstall --remove-tables is taken"
    json '.tables_and_custom_fields' removed "and says that the package's tables and custom fields went too"

    run "$S/repair.sh"
    is_rc 0 "repair.sh without --execute is a dry run"
    json '.executed' false "that runs no SQL"
    json '.database_in_sync' true "and finds a new install in sync"
    sc_db_sql "ALTER TABLE accounts DROP COLUMN sic_code"
    run "$S/repair.sh"
    json '.database_in_sync' false "it sees a column that went missing"
    has out "sic_code" "and shows the SQL that would put it back"
    run "$S/repair.sh --execute"
    is_rc 64 "--execute needs --yes-repair"
    run "$S/repair.sh --execute --yes-repair"
    is_rc 0 "with it the repair runs"
    json '.database_in_sync' true "and finds the database in sync when it looks again"
    json '.sql_still_needed | length' 0 "with no SQL left to run"
    sql_is "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'suitecrm' AND table_name = 'accounts' AND column_name = 'sic_code'" 1 "and the column is back"
    run "$S/repair.sh"
    json '.database_in_sync' true "the next dry run is in sync again"
    # A field whose column the database can't make as asked: the SQL runs without an error, and the database
    # is still not in sync afterwards
    fixture users-repair-probe.php add
    run "$S/repair.sh --execute --yes-repair"
    json '.executed' true "an execute whose SQL does not bring the database in line still runs"
    json '.database_in_sync' false "and reports what it finds afterwards: not in sync"
    has out "usr_repair_probe" "with the SQL that is still needed"
    is_rc 2 "and exit 2"
    left="$(val '.sql_still_needed | join(" ")')"
    run "$S/repair.sh"
    json '.database_in_sync' false "which is what the next dry run says"
    if [ -n "${left}" ] && [ "${left}" = "$(val '.sql_it_would_run | join(" ")')" ]; then ok "and both name the same SQL"; else bad "and both name the same SQL" "after the execute: ${left}"$'\n'"the dry run: $(val '.sql_it_would_run | join(" ")')"; fi
    fixture users-repair-probe.php remove
    sc_db_sql "ALTER TABLE bugs DROP COLUMN usr_repair_probe"
    run "$S/repair.sh"
    json '.database_in_sync' true "(the test field is gone and the database is in sync again)"
    run "$S/repair.sh --module Accounts"
    is_rc 0 "a repair of one module runs"
    json '.modules' Accounts "and names the module"
    run "$S/repair.sh --module NoSuchModule"
    is_rc 3 "a module SuiteCRM does not have is exit 3"
    owner="$(sc_app_root 'find /var/www/html/cache /var/www/html/public/legacy/cache /var/www/html/public/legacy/custom ! -user www-data 2>/dev/null | wc -l')"
    if [ "${owner}" = 0 ]; then ok "nothing in the caches or custom/ belongs to another user afterwards"; else bad "nothing in the caches or custom/ belongs to another user afterwards" "${owner} files"; fi
fi

# ---------------------------------------------------------------------------
# scheduler
# ---------------------------------------------------------------------------
if wants scheduler; then
    section "scheduler.sh"
    # ops_state CMD: like set_state, with the state folder as the image and the skill trust it: root's, mode 700,
    # without the set-group-ID bit a folder made in tmp/ takes over
    ops_state() { sc_app_root "install -d -m 700 ${state_dir} && chown root:root ${state_dir} && chmod 00700 ${state_dir} && $1"; }
    sc_app_root "if [ -d ${state_dir} ] && [ ! -L ${state_dir} ]; then chown root:root ${state_dir} && chmod 00700 ${state_dir}; fi"
    run "$S/scheduler.sh status"
    is_rc 0 "status reads the scheduler"
    json '.held' false "which is not held on a new install"
    json '.cron_user_allowed' true "www-data is an allowed cron user"
    json '.schedulers | length > 5' true "it lists the scheduled jobs"
    json '.messenger_worker_running' true "and sees the Messenger worker"

    # A new install has no state folder: the image makes it at its first upgrade, and a restore makes it
    sc_app_root "if [ -d ${state_dir} ]; then mv ${state_dir} ${state_dir}.ops-test-keep; fi"
    run "$S/scheduler.sh status"
    is_rc 0 "status works when the image's state folder is not there"
    json '.held' false "a missing state folder means not held"
    json '.hold_file' no "and it says there is no hold file"
    if [[ "${err}" != *"cannot access"* && "${err}" != *"No such file"* ]]; then ok "without noise about the missing folder"; else bad "without noise about the missing folder" "${err}"; fi
    sc_app_root "if [ -d ${state_dir}.ops-test-keep ]; then mv ${state_dir}.ops-test-keep ${state_dir}; fi"

    ops_state "touch ${state_dir}/scheduler-held"
    run "$S/scheduler.sh status"
    json '.held' true "status sees a held scheduler"
    json '.hold_file' yes "and names the hold file as the reason"
    json '.held_by | length' 1 "with one reason listed"
    run "$S/scheduler.sh queued"
    is_rc 0 "queued says what a release would start"
    json 'has("campaign_emails_waiting") and has("active_workflows") and has("inbound_mailboxes")' true "campaign mail, workflows and mailboxes are counted"
    run "$S/scheduler.sh run-once"
    is_rc 64 "run-once is refused while the scheduler is held"

    # A release shows what would start before it asks for the yes. Three campaign emails wait, two of them due.
    # No email marketing record owns them, so no scheduled job ever picks them up.
    sc_db_sql "INSERT INTO emailman (date_entered, send_date_time, deleted, in_queue, related_type, related_id) VALUES (UTC_TIMESTAMP(), UTC_TIMESTAMP() - INTERVAL 1 HOUR, 0, 0, 'Contacts', 'ops-test-queue-1'), (UTC_TIMESTAMP(), UTC_TIMESTAMP() - INTERVAL 2 HOUR, 0, 0, 'Contacts', 'ops-test-queue-2'), (UTC_TIMESTAMP(), '2099-01-01 00:00:00', 0, 0, 'Contacts', 'ops-test-queue-3')"
    waiting="$(sc_db_sql 'SELECT COUNT(*) FROM emailman WHERE deleted = 0')"
    due="$(sc_db_sql 'SELECT COUNT(*) FROM emailman WHERE deleted = 0 AND (send_date_time IS NULL OR send_date_time <= UTC_TIMESTAMP())')"
    if [ "${waiting}" -ge 3 ] && [ "${due}" -ge 2 ]; then ok "three campaign emails wait in the queue (${waiting} in all, ${due} due)"; else bad "three campaign emails wait in the queue" "waiting ${waiting}, due ${due}"; fi
    run "$S/scheduler.sh release"
    is_rc 64 "release needs --yes-release"
    has out "Campaign emails waiting: ${waiting} (${due} due now)" "the refusal shows the campaign emails that wait and are due"
    has out "Active workflows:" "and the active workflows"
    has out "Scheduled reports:" "the scheduled reports"
    has out "Inbound mailboxes:" "the inbound mailboxes"
    has out "Jobs waiting:" "and the jobs that wait"
    has err "nothing was changed" "then it says that nothing was changed"
    held="$(sc_app_root "test -e ${state_dir}/scheduler-held && echo yes || echo no")"
    if [ "${held}" = yes ]; then ok "and the scheduler is still held"; else bad "and the scheduler is still held"; fi
    run "$S/scheduler.sh release --yes"
    is_rc 64 "a yes that is not --yes-release is refused the same way"

    # The web user moved root's state folder aside and put its own there: nothing in it is trusted
    sc_app_root "mv ${state_dir} ${state_dir}.ops-test-keep"
    sc_app_www "mkdir ${state_dir} && touch ${state_dir}/scheduler-held"
    run "$S/scheduler.sh status"
    json '.hold_file' unknown "status does not read a hold file from a state folder that is not root's"
    if sc_app_root "grep -q untrusted /clouve/suitecrm/installer/loops.sh 2>/dev/null"; then
        json '.held' true "and says that this image holds the scheduler while such a folder is there"
    else
        json '.held' null "and says that it does not know whether the scheduler is held"
    fi
    run "$S/scheduler.sh release --yes-release"
    if [ "${rc}" -ne 0 ] && [[ "${err}" == *"not a folder of root's"* ]]; then ok "a release is refused when the state folder is not root's, and says why"; else bad "a release is refused when the state folder is not root's, and says why (exit ${rc})" "${out}"$'\n'"${err}"; fi
    planted="$(sc_app_root "test -e ${state_dir}/scheduler-held && test -e ${state_dir}.ops-test-keep/scheduler-held && stat -c %U ${state_dir}")"
    if [ "${planted}" = www-data ]; then ok "and nothing was changed: the planted folder and the real one are as they were"; else bad "and nothing was changed: the planted folder and the real one are as they were" "${planted}"; fi
    sc_app_root "rm -rf ${state_dir} && mv ${state_dir}.ops-test-keep ${state_dir}"

    run "$S/scheduler.sh release --yes-release"
    is_rc 0 "release with the yes lets it go"
    has out "What starts now" "and says what starts now"
    has out "Campaign emails waiting: ${waiting} (${due} due now)" "with the same numbers"
    held="$(sc_app_root "test -e ${state_dir}/scheduler-held && echo yes || echo no")"
    if [ "${held}" = no ]; then ok "the hold is gone"; else bad "the hold is gone"; fi
    sc_db_sql "DELETE FROM emailman WHERE related_id LIKE 'ops-test-queue-%'"
    run "$S/scheduler.sh release --yes-release"
    is_rc 0 "releasing a scheduler that is not held is fine"
    has out "was not held" "and says so"
    run "$S/scheduler.sh run-once"
    is_rc 0 "run-once runs one scheduler pass"
    run "$S/scheduler.sh status"
    json '.last_run != null' true "and status shows that jobs have run"
    json '.held_by | length' 0 "and gives no reason for a hold"

    # The image's scheduler setting. A newer image records in SuiteCRM's own settings whether its scheduler loop
    # runs ($sugar_config['clouve']['scheduler'] = 'on': set by a new install and by a release, not set on an
    # install that existed before the image), and ships the tools that read it (settings.php scheduler, as
    # www-data: on or off) and release the scheduler (release-scheduler.sh). The skill calls those tools.
    installer=/clouve/suitecrm/installer
    as_www="setpriv --reuid=www-data --regid=www-data --init-groups --"
    setting_now() { sc_app_root "cd /var/www/html && ${as_www} php ${installer}/settings.php scheduler 2>/dev/null" 2> /dev/null || true; }
    # setting_checks: what holds whichever way the setting is made to read on and off. It starts with the setting
    # off and no hold file, and ends with the setting on.
    setting_checks() {
        run "$S/scheduler.sh status"
        json '.image_setting' off "status reads the image's scheduler setting through the image's own tool"
        json '.held' true "a setting that is off means held"
        json '.hold_file' no "although there is no hold file"
        json '.held_by | length' 1 "and it says which of the two holds it"
        run "$S/scheduler.sh run-once"
        is_rc 64 "run-once is refused while the setting is off"
        run "$S/upgrade-state.sh"
        has out "Scheduler: held (the image's scheduler setting is off" "upgrade-state.sh says that the setting holds the scheduler"
        run "$S/verify-health.sh"
        if printf '%s\n' "${out}" | grep -Eq '^  WARN +scheduler +held \(the image.s scheduler setting is off'; then ok "and so does verify-health.sh"; else bad "and so does verify-health.sh" "${out}"; fi
        run "$S/scheduler.sh release"
        is_rc 64 "release still needs --yes-release"
        if [ "$(setting_now)" = off ]; then ok "and the setting is still off"; else bad "and the setting is still off"; fi
        ops_state "touch ${state_dir}/scheduler-held"
        run "$S/scheduler.sh status"
        json '.held_by | length' 2 "with the hold file there too, status names both"
    }
    # released_checks: after a release with the yes
    released_checks() {
        is_rc 0 "release with the yes removes the hold file and has the image switch the setting on"
        has out "the hold file is gone and the image's scheduler setting is on" "and says both"
        has out "What starts now" "and what starts now"
        if [ "$(setting_now)" = on ] && ! sc_app_root "test -e ${state_dir}/scheduler-held"; then ok "the hold file is gone and the image reads the setting as on"; else bad "the hold file is gone and the image reads the setting as on" "$(setting_now)"; fi
        run "$S/scheduler.sh status"
        json '.held' false "status says not held afterwards"
        json '.image_setting' on "with the setting on"
        run "$S/scheduler.sh release --yes-release"
        has out "was not held" "a second release finds nothing to release"
    }
    # also_checks: the image's loop runs no job either while staff's pause file is there, or while a state folder
    # it moved aside is on the volume. Neither is a hold that a release removes.
    also_checks() {
        ops_state "rm -f ${state_dir}/scheduler-held; touch ${state_dir}/loops-paused"
        run "$S/scheduler.sh status"
        json '.held' true "staff's pause file means that no scheduled job runs"
        json '.held_by | join(" ") | contains("loops-paused")' true "and status names it"
        run "$S/scheduler.sh release --yes-release"
        is_rc 2 "a release does not remove staff's pause"
        has err "Clouve support" "and says that it is a request to Clouve support"
        if sc_app_root "test -e ${state_dir}/loops-paused"; then ok "the pause file is still there"; else bad "the pause file is still there"; fi
        ops_state "rm -f ${state_dir}/loops-paused"
        sc_app_root "install -d -m 700 ${state_dir}.untrusted-20261112T201500Z"
        run "$S/scheduler.sh status"
        json '.held' true "a state folder the image moved aside means that no scheduled job runs"
        json '.held_by | join(" ") | contains("moved aside")' true "and status names that too"
        run "$S/scheduler.sh run-once"
        is_rc 64 "run-once is refused then"
        run "$S/upgrade-state.sh"
        has out "Scheduler: the image runs no scheduled job for now" "upgrade-state.sh says that no job runs, and that a release does not change it"
    }
    real_setting="$(setting_now)"
    if [ "${real_setting}" = on ] || [ "${real_setting}" = off ]; then
        # This image has the setting and the tools
        run "$S/scheduler.sh status"
        json '.image_setting' "${real_setting}" "status reports the image's own scheduler setting (${real_setting})"
        ops_state "rm -f ${state_dir}/scheduler-held"
        sc_app_root "cd /var/www/html && ${as_www} php ${installer}/scheduler-setting.php off"
        setting_checks
        run "$S/scheduler.sh release --yes-release"
        released_checks
        if sc_app_www "grep -q \"sugar_config\\['clouve'\\]\\['scheduler'\\] = 'on'\" /var/www/html/public/legacy/config_override.php"; then ok "the setting is in SuiteCRM's own config_override.php"; else bad "the setting is in SuiteCRM's own config_override.php"; fi
        also_checks
        # The image's own release refuses while a folder it moved aside is on the volume
        ops_state "touch ${state_dir}/scheduler-held"
        run "$S/scheduler.sh release --yes-release"
        is_rc 2 "with a hold file and a moved-aside folder, the image's own release refuses"
        if sc_app_root "test -e ${state_dir}/scheduler-held"; then ok "and the hold file is still there"; else bad "and the hold file is still there"; fi
        sc_app_root "rmdir ${state_dir}.untrusted-20261112T201500Z"
        run "$S/scheduler.sh release --yes-release"
        is_rc 0 "once the folder is gone the release works"
        run "$S/scheduler.sh status"
        json '.held' false "and the scheduler is not held at the end"
    else
        # This image has no such setting, so stand-ins for the image's tools are put where the image has them:
        # the setting is on when a flag file is there, and loops.sh names the other reasons.
        run "$S/scheduler.sh status"
        json '.image_setting' none "status says that this image has no scheduler setting of its own"
        flag=/var/www/html/tmp/ops-test-scheduler-on
        sc_app_root "mkdir -p ${installer} && for f in settings.php loops.sh; do if [ -f ${installer}/\$f ]; then mv ${installer}/\$f ${installer}/\$f.ops-test-keep; fi; done; rm -f ${flag}"
        docker exec -i "${SC_APP}" bash -c "cat > ${installer}/settings.php && chmod 644 ${installer}/settings.php" <<'EOS'
<?php
// Test stand-in for the image's settings.php: "scheduler" prints on when the flag file is there, off when not.
if (($argv[1] ?? '') === 'scheduler') {
    echo is_file('/var/www/html/tmp/ops-test-scheduler-on') ? "on\n" : "off\n";
    exit(0);
}
if (is_file(__DIR__ . '/settings.php.ops-test-keep')) {
    require __DIR__ . '/settings.php.ops-test-keep';
}
EOS
        printf '%s\n' '# Test stand-in for the image'"'"'s loops.sh. It names the two things the skill looks for: untrusted, loops-paused.' \
            | docker exec -i "${SC_APP}" bash -c "cat > ${installer}/loops.sh"
        release_double() { docker exec -i "${SC_APP}" bash -c "cat > ${installer}/release-scheduler.sh && chmod 755 ${installer}/release-scheduler.sh"; }
        printf '%s\n' '#!/bin/bash' '# Test stand-in for the image'"'"'s release-scheduler.sh' "touch ${flag}" "rm -f ${state_dir}/scheduler-held" | release_double
        ops_state "rm -f ${state_dir}/scheduler-held"
        setting_checks
        # A release tool that does not switch the setting on
        printf '%s\n' '#!/bin/bash' 'exit 0' | release_double
        run "$S/scheduler.sh release --yes-release"
        is_rc 2 "a release that leaves the setting off is reported as failed"
        if sc_app_root "test -e ${state_dir}/scheduler-held"; then ok "and the hold file is still there"; else bad "and the hold file is still there"; fi
        # A release tool that refuses, as the image's does while a restore is under way
        printf '%s\n' '#!/bin/bash' 'echo "[suitecrm] ERROR: a restore is under way, so the scheduler is not released now" >&2' 'exit 1' | release_double
        run "$S/scheduler.sh release --yes-release"
        is_rc 2 "a release that the image's own tool refuses is refused"
        has err "a restore is under way" "with the image's reason"
        sc_app_root "rm -f ${installer}/release-scheduler.sh"
        run "$S/scheduler.sh release --yes-release"
        is_rc 2 "without the image's release tool the setting can't be switched on, and the release is refused"
        has err "Clouve support" "which is then a request to Clouve support"
        printf '%s\n' '#!/bin/bash' '# Test stand-in for the image'"'"'s release-scheduler.sh' "touch ${flag}" "rm -f ${state_dir}/scheduler-held" | release_double
        run "$S/scheduler.sh release --yes-release"
        released_checks
        also_checks
        sc_app_root "rmdir ${state_dir}.untrusted-20261112T201500Z"
        sc_app_root "rm -f ${installer}/settings.php ${installer}/loops.sh ${installer}/release-scheduler.sh ${flag}; for f in settings.php loops.sh; do if [ -f ${installer}/\$f.ops-test-keep ]; then mv ${installer}/\$f.ops-test-keep ${installer}/\$f; fi; done"
        run "$S/scheduler.sh status"
        json '.image_setting' none "without the stand-ins the image has no setting again"
        json '.held' false "and the scheduler is not held at the end"
    fi
fi

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
bdir=/var/www/html/tmp/clouve-skill-backups
# wait_job JOB: waits for a detached job to end; rc is --status's
wait_job() {
    local i
    for i in $(seq 1 120); do
        run "$S/run-in-suitecrm.sh --status $1"
        [ "${rc}" -eq 3 ] || return 0
        sleep 1
    done
}
if wants backup; then
    section "backup.sh and restore.sh"
    run_dir=/run/clouve/suitecrm-skill
    hold="${state_dir}/scheduler-held"
    rmarker="${state_dir}/restore-in-progress"
    # backup_name: the name in "Backup <name> is complete", from what the last run printed
    backup_name() { printf '%s\n' "${out}" | sed -n 's/^Backup \([0-9]\{8\}-[0-9]\{6\}\) is complete.*/\1/p'; }
    # wait_up: SuiteCRM answers as an installed app again (after a start that waited)
    wait_up() {
        for _ in $(seq 1 120); do
            if docker exec "${SC_APP}" sh -c 'curl -fsS -m 5 http://localhost/session-status 2>/dev/null' 2> /dev/null | grep -q '"installed":true'; then return 0; fi
            sleep 1
        done
        return 1
    }
    # kill_job JOB: ends every process of the detached job JOB in the SuiteCRM container with SIGKILL. The job has
    # a session of its own, and the pattern is written so that this command's own arguments don't match it.
    kill_job() {
        sc_app_root "found=0; for sid in \$(ps -eo sid=,args= | awk -v pat='/run/clouve/jobs/[${1:0:1}]${1:1}' '\$0 ~ pat && \$1 > 1 { print \$1 }' | sort -u); do for pid in \$(ps -eo pid=,sid= | awk -v sid=\"\$sid\" '\$2 == sid { print \$1 }'); do kill -KILL \"\$pid\" 2> /dev/null && found=1; done; done; [ \"\$found\" = 1 ]"
    }
    # lock_free: waits until nothing holds the skill's lock
    lock_free() {
        sc_app_root "for _ in \$(seq 1 30); do if [ ! -e ${run_dir}/lock ] || flock -n ${run_dir}/lock true; then exit 0; fi; sleep 1; done; exit 1"
    }
    sc_app_root "rm -rf ${bdir} ${bdir}.aside; rm -f ${rmarker} ${hold}"
    sc_db_sql "DELETE FROM emailman WHERE related_id LIKE 'bak-test-queue-%'; UPDATE accounts SET deleted = 1 WHERE name IN ('Before Backup Co', 'Before Backup Co renamed', 'After Backup Co')"
    run_in '{"name": "Before Backup Co", "email1": "info@before.example"}' "$S/records.sh create Accounts --allow-duplicate"
    keep_acc="$(val .id)"
    sc_app_www 'mkdir -p public/legacy/custom/test && echo kept > public/legacy/custom/test/marker.txt && echo upload-one > public/legacy/upload/test-upload-one'
    # A picture of an email template (SuiteCRM keeps them in cache/images), and a cache file that is not one
    sc_app_www 'mkdir -p public/legacy/cache/images && echo picture-one > public/legacy/cache/images/bak-test-picture.png && echo not-a-picture > public/legacy/cache/bak-test-other.txt'
    sc_app_root 'echo "<?php // old passwords" > /var/www/html/public/legacy/config_si.php'
    # Three campaign emails wait in the queue when the first backup is made, two of them due. No email marketing
    # record owns them, so no scheduled job ever picks them up.
    sc_db_sql "INSERT INTO emailman (date_entered, send_date_time, deleted, in_queue, related_type, related_id) VALUES (UTC_TIMESTAMP(), UTC_TIMESTAMP() - INTERVAL 1 HOUR, 0, 0, 'Contacts', 'bak-test-queue-1'), (UTC_TIMESTAMP(), UTC_TIMESTAMP() - INTERVAL 2 HOUR, 0, 0, 'Contacts', 'bak-test-queue-2'), (UTC_TIMESTAMP(), '2099-01-01 00:00:00', 0, 0, 'Contacts', 'bak-test-queue-3')"
    q_rows="$(sc_db_sql 'SELECT COUNT(*) FROM emailman')"
    q_waiting="$(sc_db_sql 'SELECT COUNT(*) FROM emailman WHERE deleted = 0')"
    q_due="$(sc_db_sql 'SELECT COUNT(*) FROM emailman WHERE deleted = 0 AND (send_date_time IS NULL OR send_date_time <= UTC_TIMESTAMP())')"

    run "$S/run-in-suitecrm.sh backup.sh"
    is_rc 0 "backup.sh takes a backup"
    b1="$(backup_name)"
    if [[ "${b1}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then ok "and prints its name"; else bad "and prints its name" "${out}"; fi
    has out "This skill now keeps 1 backup" "and how many backups the skill now keeps, with their size"
    modes="$(sc_app_root "stat -c '%a %U' ${bdir} ${bdir}/${b1} ${bdir}/${b1}/db.sql.gz ${bdir}/${b1}/state.tar.gz ${bdir}/${b1}/manifest.txt ${bdir}/${b1}/COMPLETE | tr '\n' ' '")"
    if [ "${modes}" = "700 root 700 root 600 root 600 root 600 root 600 root " ]; then ok "the folders are 700 and the files 600, all root's"; else bad "the folders are 700 and the files 600, all root's" "${modes}"; fi
    if ! docker exec -u www-data "${SC_APP}" ls "${bdir}" > /dev/null 2>&1; then ok "the web user can't read the backups"; else bad "the web user can't read the backups"; fi
    if sc_app_root "gzip -t ${bdir}/${b1}/db.sql.gz && zcat ${bdir}/${b1}/db.sql.gz | grep -q 'CREATE TABLE \`accounts\`' && zcat ${bdir}/${b1}/db.sql.gz | tail -n 3 | grep -q 'Dump completed'"; then ok "the dump is whole and holds the tables"; else bad "the dump is whole and holds the tables"; fi
    listing="$(sc_app_root "tar -tzf ${bdir}/${b1}/state.tar.gz")"
    for want in .env.local public/legacy/config.php public/legacy/custom/test/marker.txt public/legacy/upload/test-upload-one public/legacy/Api/V8/OAuth2/private.key \
        public/legacy/cache/images/bak-test-picture.png; do
        if grep -qxF "${want}" <<< "${listing}"; then ok "the archive holds ${want}"; else bad "the archive holds ${want}" "$(head -n 20 <<< "${listing}")"; fi
    done
    if ! grep -q 'config_si.php' <<< "${listing}"; then ok "and not config_si.php, the installer's file of clear-text passwords"; else bad "and not config_si.php"; fi
    if ! grep -qE '^(vendor|core|cache|public/dist)/' <<< "${listing}"; then ok "and none of SuiteCRM's own code"; else bad "and none of SuiteCRM's own code"; fi
    if ! grep -E '^public/legacy/cache/' <<< "${listing}" | grep -qvE '^public/legacy/cache/images(/|$)'; then ok "of public/legacy/cache it holds the pictures of email templates and nothing else"; else bad "of public/legacy/cache it holds the pictures of email templates and nothing else" "$(grep -E '^public/legacy/cache/' <<< "${listing}" | head -n 10)"; fi
    if sc_app_root "grep -q '^suitecrm_version: 8.10.2$' ${bdir}/${b1}/manifest.txt && cd ${bdir}/${b1} && sha256sum -c --quiet SHA256SUMS"; then ok "the manifest names the version and the checksums hold"; else bad "the manifest names the version and the checksums hold" "$(sc_app_root "cat ${bdir}/${b1}/manifest.txt")"; fi
    hasnt out "${SC_PW_DB}" "the database password is in nothing it printed"
    stray="$(sc_app_root "find /tmp /run/clouve /var/www/html/tmp -name '*.cnf' 2>/dev/null | wc -l")"
    if [ "${stray}" = 0 ]; then ok "no database options file is left behind"; else bad "no database options file is left behind" "${stray}"; fi
    left="$(sc_app_root "ls -d ${run_dir}/run.* 2>/dev/null | wc -l")"
    if [ "${left}" = 0 ]; then ok "and no folder of the run's own in ${run_dir}"; else bad "and no folder of the run's own in ${run_dir}" "$(sc_app_root "ls -la ${run_dir}")"; fi
    run "$S/run-in-suitecrm.sh backup.sh --list"
    is_rc 0 "--list lists the backups"
    has out "${b1}  complete" "with the new one marked complete"

    # A backup that can't finish leaves nothing half-made
    docker stop "${SC_DB}" > /dev/null
    run "$S/run-in-suitecrm.sh backup.sh"
    if [ "${rc}" -ne 0 ]; then ok "a backup fails when the database is down (exit ${rc})"; else bad "a backup fails when the database is down"; fi
    half="$(sc_app_root "ls ${bdir} | grep -vc '^${b1}\$' || true")"
    if [ "${half}" = 0 ]; then ok "and leaves no half-made backup"; else bad "and leaves no half-made backup" "$(sc_app_root "ls -la ${bdir}")"; fi
    docker start "${SC_DB}" > /dev/null
    for _ in $(seq 1 60); do sc_db_sql 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done

    # What a killed backup leaves: a <name>.partial folder. It is listed with the way to remove it, it can be
    # removed by name, and the next backup clears one that is older than a day.
    sc_app_root "cd ${bdir} && mkdir 20200101-010101.partial 20200102-010101.partial && chown root:root ./*.partial && chmod 00700 ./*.partial && echo half > 20200101-010101.partial/db.sql.gz && echo half > 20200102-010101.partial/db.sql.gz && touch -d '2 days ago' 20200101-010101.partial"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    has out "20200102-010101.partial  NOT complete" "--list shows a leftover of a backup that was stopped"
    has out "backup.sh --remove 20200102-010101.partial --yes-remove" "with the command that removes it"
    run "$S/run-in-suitecrm.sh backup.sh --remove 20200102-010101.partial"
    is_rc 64 "--remove of a leftover needs --yes-remove too"
    has err "deletes" "and says what it would delete"
    run "$S/run-in-suitecrm.sh backup.sh --remove 20200102-010101.partial --yes-remove"
    is_rc 0 "--remove takes a <name>.partial leftover"
    if ! sc_app_root "test -e ${bdir}/20200102-010101.partial"; then ok "and the leftover is gone"; else bad "and the leftover is gone"; fi
    run "$S/run-in-suitecrm.sh backup.sh --remove '../x.partial' --yes-remove"
    is_rc 64 "--remove takes no path"

    # Changes after the backup, which a restore must undo. The campaign went out: its queue is empty now.
    run_in '{"name": "After Backup Co"}' "$S/records.sh create Accounts --allow-duplicate"
    run_in '{"name": "Before Backup Co renamed"}' "$S/records.sh update Accounts ${keep_acc}"
    sc_app_www 'echo changed > public/legacy/custom/test/marker.txt && echo upload-two > public/legacy/upload/test-upload-two'
    sc_app_www 'echo changed-picture > public/legacy/cache/images/bak-test-picture.png && echo picture-two > public/legacy/cache/images/bak-test-picture-two.png'
    sc_db_sql "DELETE FROM emailman WHERE related_id LIKE 'bak-test-queue-%'"

    run "$S/run-in-suitecrm.sh restore.sh --backup ${b1}"
    is_rc 64 "restore.sh without the yes is a preview"
    has out "pictures of email templates" "the preview says that the pictures of email templates are replaced too"
    has out "Nothing was changed" "that says nothing was changed"
    has out "${q_rows} campaign email" "the preview says how many campaign emails the backup's queue holds"
    has out "holds the scheduler" "and that the restore holds the scheduler"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "and changes nothing"
    if ! sc_app_root "test -e ${hold} || test -e ${rmarker}"; then ok "a preview writes no hold and no marker"; else bad "a preview writes no hold and no marker"; fi
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b1} --yes-replace-current-data"
    is_rc 2 "a restore is refused without a fresh backup of the current state"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
    is_rc 3 "a backup that is not there is exit 3"
    run "$S/run-in-suitecrm.sh restore.sh --backup '../../etc' --yes-replace-current-data"
    is_rc 64 "a name that is not a backup's is a usage error"
    sleep 1
    take_backup
    b2="$(backup_name)"
    has out "20200101-010101.partial" "a backup's start removes a leftover that is older than a day, and says so"
    if ! sc_app_root "test -e ${bdir}/20200101-010101.partial"; then ok "and that leftover is gone"; else bad "and that leftover is gone"; fi
    has out "This skill now keeps 2 backups" "and the backup counts the backups the skill keeps"
    sc_app_root "cp -a ${bdir}/${b1} ${bdir}/20200202-020202 && rm ${bdir}/20200202-020202/COMPLETE"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200202-020202 --yes-replace-current-data"
    is_rc 3 "a backup without its COMPLETE stamp is refused"
    sc_app_root "touch ${bdir}/20200202-020202/COMPLETE && echo x >> ${bdir}/20200202-020202/db.sql.gz"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200202-020202 --yes-replace-current-data"
    is_rc 3 "a backup whose checksum does not hold is refused"
    sc_app_root "cp -a ${bdir}/${b1}/db.sql.gz ${bdir}/20200202-020202/db.sql.gz && sed -i 's/^suitecrm_version: .*/suitecrm_version: 8.9.1/' ${bdir}/20200202-020202/manifest.txt"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200202-020202 --yes-replace-current-data"
    is_rc 2 "a backup of another SuiteCRM version is refused"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "none of the refused restores changed anything"
    if ! sc_app_root "test -e ${hold} || test -e ${rmarker}"; then ok "and none wrote a hold or a marker"; else bad "and none wrote a hold or a marker"; fi
    run "$S/run-in-suitecrm.sh backup.sh --remove 20200202-020202"
    is_rc 64 "--remove needs --yes-remove"
    run "$S/run-in-suitecrm.sh backup.sh --remove 20200202-020202 --yes-remove"
    is_rc 0 "--remove deletes one backup by name"

    # A backup whose files would not fit on the volume is refused before a table is dropped. The archive holds
    # one sparse file that is larger than the free space.
    # craft NAME PREPARE [TAR_OPTIONS [EXTRA_MEMBER]]: a copy of the first backup named NAME whose archive holds the
    # first backup's files and what PREPARE adds to /root/bak-craft/tree in the SuiteCRM container
    craft() {
        sc_app_root "set -e; cd /root/bak-craft && rm -rf ${bdir}/$1 && cp -a ${bdir}/${b1} ${bdir}/$1 && $2 && { find tree -mindepth 1 -maxdepth 1 -printf '%P\\n'; printf '%s\\n' '${4:-}'; } | grep -v '^\$' | tar -C tree ${3:-} -czf ${bdir}/$1/state.tar.gz -T - && cd ${bdir}/$1 && sha256sum db.sql.gz state.tar.gz > SHA256SUMS && chmod 600 ./*"
    }
    sc_app_root "rm -rf /root/bak-craft && mkdir -p /root/bak-craft/tree && tar -xzpf ${bdir}/${b1}/state.tar.gz -C /root/bak-craft/tree"
    craft 20200303-030303 "truncate -s \$((\$(df -PB1 /var/www/html | awk 'NR == 2 { print \$4 }') * 2 + 1073741824)) tree/public/legacy/upload/bak-test-sparse" -S
    sc_app_root "rm -f /root/bak-craft/tree/public/legacy/upload/bak-test-sparse"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200303-030303 --yes-replace-current-data"
    is_rc 2 "a restore whose files would not fit on the volume is refused"
    has err "not enough free space" "and says that the space is not enough"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "before a table is dropped"
    if ! sc_app_root "test -e ${hold} || test -e ${rmarker} || test -e /var/www/html/public/legacy/upload/bak-test-sparse"; then ok "and before a file, a hold or a marker is written"; else bad "and before a file, a hold or a marker is written"; fi
    sc_app_root "rm -rf ${bdir}/20200303-030303"

    # An archive never brings a device, a FIFO, a path outside the tree or a link that points outside it
    for kind in device fifo absolute dotdot link-absolute link-up; do
        case "${kind}" in
            device) craft 20200404-040404 "mknod tree/public/legacy/upload/bak-test-bad c 1 3" ;;
            fifo) craft 20200404-040404 "mkfifo tree/public/legacy/upload/bak-test-bad" ;;
            absolute) craft 20200404-040404 "echo bad > /root/bak-craft/bak-test-bad" -P /root/bak-craft/bak-test-bad ;;
            dotdot) craft 20200404-040404 "echo bad > tree/bak-test-bad" "--transform=s,^bak-test-bad\$,public/../../bak-test-bad," ;;
            link-absolute) craft 20200404-040404 "ln -s /etc/shadow tree/public/legacy/upload/bak-test-bad" ;;
            link-up) craft 20200404-040404 "ln -s ../../../../../etc/passwd tree/public/legacy/upload/bak-test-bad" ;;
        esac
        sc_app_root "rm -f /root/bak-craft/tree/public/legacy/upload/bak-test-bad /root/bak-craft/tree/bak-test-bad /root/bak-craft/bak-test-bad"
        run "$S/run-in-suitecrm.sh restore.sh --backup 20200404-040404 --yes-replace-current-data"
        if [ "${rc}" -eq 3 ] && [[ "${err}" == *"never holds"* ]]; then ok "an archive with a ${kind} member is refused"; else bad "an archive with a ${kind} member is refused (exit ${rc})" "${out}"$'\n'"${err}"; fi
        planted="$(sc_app_root "ls -d /var/www/html/public/legacy/upload/bak-test-bad /var/www/html/bak-test-bad /var/www/bak-test-bad /var/www/html/root 2>/dev/null | wc -l; test -e ${rmarker} && echo marker")"
        if [ "${planted}" = 0 ]; then ok "and nothing of it is on the volume, and no marker"; else bad "and nothing of it is on the volume, and no marker" "${planted}"; fi
    done
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "none of those restores changed the database"
    sc_app_root "rm -rf ${bdir}/20200404-040404"

    # Two restores started one second apart: one runs, the other is refused by the lock and changes nothing
    run "$S/run-in-suitecrm.sh --detach restore.sh --backup ${b1} --yes-replace-current-data"
    is_rc 0 "--detach starts the restore as a job"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    sleep 1
    run "$S/run-in-suitecrm.sh --detach restore.sh --backup ${b1} --yes-replace-current-data"
    job2="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    if [[ "${job2}" =~ ^restore-[0-9]{8}-[0-9]{6}$ ]] && [ "${job2}" != "${job}" ]; then ok "a second restore is started a second later"; else bad "a second restore is started a second later" "${out}"$'\n'"${err}"; fi
    wait_job "${job}"
    is_rc 0 "the job finishes with exit 0"
    has out "Restore of ${b1} is complete" "and its log says the restore is complete"
    has out "${q_waiting} campaign email" "its closing lines say how many campaign emails wait as of the backup"
    has out "${q_due} due now" "and how many of them are due"
    has out "The scheduler is held" "and that the scheduler is held"
    has out "scheduler.sh release --yes-release" "until the user says to release it"
    wait_job "${job2}"
    has out "status: finished, exit 2" "the second restore ended with exit 2"
    has out "only one runs at a time" "because one backup or restore runs at a time"
    has out "${run_dir}/lock" "and it names the lock"
    hasnt out "Restoring the backup" "without starting on the database or the files"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 0 "the account made after the backup is gone"
    sql_is "SELECT name FROM accounts WHERE id = '${keep_acc}'" "Before Backup Co" "the renamed account has its old name"
    marker="$(sc_app_root 'cat /var/www/html/public/legacy/custom/test/marker.txt; ls /var/www/html/public/legacy/upload/ | grep -c test-upload')"
    if [ "${marker}" = $'kept\n1' ]; then ok "custom/ and upload/ are as they were at the backup"; else bad "custom/ and upload/ are as they were at the backup" "${marker}"; fi
    pictures="$(sc_app_root 'cat /var/www/html/public/legacy/cache/images/bak-test-picture.png; ls /var/www/html/public/legacy/cache/images | grep -c bak-test-picture; stat -c "%U %a" /var/www/html/public/legacy/cache/images/bak-test-picture.png' 2>&1)"
    if [ "${pictures}" = $'picture-one\n1\nwww-data 644' ]; then ok "the pictures of email templates are as they were at the backup, and www-data's"; else bad "the pictures of email templates are as they were at the backup, and www-data's" "${pictures}"; fi
    if ! sc_app_root 'test -e /var/www/html/public/legacy/cache/bak-test-other.txt'; then ok "the rest of SuiteCRM's cache was cleared, as before"; else bad "the rest of SuiteCRM's cache was cleared, as before"; fi
    owner="$(sc_app_root 'find /var/www/html/public/legacy/custom /var/www/html/public/legacy/upload /var/www/html/cache /var/www/html/public/legacy/config.php /var/www/html/.env.local ! -user www-data | wc -l')"
    if [ "${owner}" = 0 ]; then ok "everything restored belongs to www-data"; else bad "everything restored belongs to www-data" "${owner} files"; fi
    keymode="$(sc_app_root 'stat -c %a /var/www/html/public/legacy/Api/V8/OAuth2/private.key')"
    if [ "${keymode}" = 600 ]; then ok "the OAuth2 private key is mode 600"; else bad "the OAuth2 private key is mode 600" "${keymode}"; fi
    dirmodes="$(sc_app_root 'stat -c %a /var/www/html/public/legacy /var/www/html/public/legacy/custom /var/www/html/public/legacy/custom/test /var/www/html/public/legacy/upload | sort -u | tr "\n" " "')"
    if [ "${dirmodes}" = "2755 " ]; then ok "the restored folders have the tree's mode, set-group-ID included"; else bad "the restored folders have the tree's mode, set-group-ID included" "${dirmodes}"; fi
    if ! sc_app_root "test -e ${rmarker} || test -e ${bdir}/RESTORE-IN-PROGRESS"; then ok "the restore marker is gone"; else bad "the restore marker is gone"; fi
    sql_is "SELECT COUNT(*) FROM emailman WHERE related_id LIKE 'bak-test-queue-%'" 3 "the restore brought the campaign queue back as it was"
    holdmode="$(sc_app_root "stat -c '%U %a' ${hold} 2>&1")"
    if [ "${holdmode}" = "root 600" ]; then ok "and it holds the scheduler: scheduler-held is there, root's, mode 600"; else bad "and it holds the scheduler: scheduler-held is there, root's, mode 600" "${holdmode}"; fi
    run "$S/scheduler.sh status"
    json '.held' true "scheduler.sh status says held"
    stray="$(sc_app_root "find /tmp /run/clouve /var/www/html/tmp -name '*.cnf' -o -name '*.err' 2>/dev/null | grep -v '/jobs/' | wc -l; ls -d ${run_dir}/run.* ${bdir}/.restore* 2>/dev/null | wc -l")"
    if [ "${stray}" = $'0\n0' ]; then ok "neither restore left an options file, an error file or a folder of its own"; else bad "neither restore left an options file, an error file or a folder of its own" "${stray}"; fi
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "the admin signs in after the restore"; else bad "the admin signs in after the restore" "HTTP ${code}"; fi
    run "$S/repair.sh"
    json '.database_in_sync' true "and the repair's dry run finds the database in sync with the files"
    run "$S/run-in-suitecrm.sh --status backup-20200101-000000"
    is_rc 64 "--status of a job that never was is exit 64"

    # A restore that is run again while the hold is there leaves the hold as it is
    sc_app_root "rm -f ${hold}"

    # Two backups started one second apart: the same. A large file makes the first one last long enough.
    sc_app_www 'head -c 314572800 /dev/urandom > public/legacy/upload/bak-test-large'
    run "$S/run-in-suitecrm.sh --detach backup.sh"
    is_rc 0 "--detach starts a backup as a job"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    sleep 1
    run "$S/run-in-suitecrm.sh --detach backup.sh"
    job2="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    wait_job "${job}"
    is_rc 0 "the first backup finishes with exit 0"
    b3="$(backup_name)"
    wait_job "${job2}"
    has out "status: finished, exit 2" "a second backup started a second later ended with exit 2"
    has out "${run_dir}/lock" "and names the lock"
    hasnt out "Backing up SuiteCRM" "without writing anything"
    count="$(sc_app_root "ls ${bdir} | grep -c '^[0-9]' || true")"
    if [ "${count}" = 3 ]; then ok "there is one new backup, and no leftover"; else bad "there is one new backup, and no leftover" "$(sc_app_root "ls -la ${bdir}")"; fi
    # A backup that is killed outright leaves its <name>.partial, without the database options file, and no lock
    sleep 1
    run "$S/run-in-suitecrm.sh --detach backup.sh"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    for _ in $(seq 1 40); do
        run "$S/run-in-suitecrm.sh --status ${job}"
        if [[ "${out}" == *"Backing up SuiteCRM"* ]]; then break; fi
    done
    if kill_job "${job}"; then ok "a running backup is killed with SIGKILL"; else bad "a running backup is killed with SIGKILL" "$(sc_app_root 'ps -eo pid,sid,args')"; fi
    run "$S/run-in-suitecrm.sh --status ${job}"
    is_rc 1 "--status says the job stopped"
    has out "stopped without an exit code" "without an exit code"
    if lock_free; then ok "the lock is free again: it went with the process"; else bad "the lock is free again: it went with the process"; fi
    left="$(sc_app_root "ls ${bdir} | grep -c '\.partial\$' || true; find ${bdir} /var/www/html/tmp -name '*.cnf' 2>/dev/null | wc -l")"
    if [ "${left}" = $'1\n0' ]; then ok "it left its .partial folder, and no database options file on the volume"; else bad "it left its .partial folder, and no database options file on the volume" "${left}"; fi
    partial="$(sc_app_root "ls ${bdir} | grep '\.partial\$'")"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    has out "${partial}  NOT complete" "--list shows it"
    run "$S/run-in-suitecrm.sh backup.sh --remove ${partial} --yes-remove"
    is_rc 0 "and --remove takes it away"
    sc_app_www 'rm -f public/legacy/upload/bak-test-large'
    sleep 1
    take_backup
    b5="$(backup_name)"
    left="$(sc_app_root "ls -d ${run_dir}/run.* 2>/dev/null | wc -l; find /run/clouve -name '*.cnf' 2>/dev/null | wc -l")"
    if [ "${left}" = $'0\n0' ]; then ok "the next backup cleared the work folder and the options file the killed one left in ${run_dir}"; else bad "the next backup cleared the work folder and the options file the killed one left in ${run_dir}" "${left}"; fi
    run "$S/run-in-suitecrm.sh backup.sh --remove ${b5} --yes-remove"
    run "$S/run-in-suitecrm.sh backup.sh --remove ${b3} --yes-remove"
    is_rc 0 "(the large backup is removed again)"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "SuiteCRM can be worked on after the refused jobs"

    # Root includes nothing the web user can write. A line in config.php that would write a file as root must
    # write none, at a backup and at a restore.
    sc_app_root 'rm -f /etc/bak-test-root-proof'
    sc_app_www 'printf "\n%s\n" "if (function_exists(\"posix_geteuid\") && posix_geteuid() === 0) { file_put_contents(\"/etc/bak-test-root-proof\", \"written as uid 0\"); }" >> public/legacy/config.php'
    sleep 1
    take_backup
    b4="$(backup_name)"
    if ! sc_app_root 'test -e /etc/bak-test-root-proof'; then ok "a backup does not run config.php as root"; else bad "a backup does not run config.php as root" "$(sc_app_root 'ls -la /etc/bak-test-root-proof')"; fi
    sc_app_root 'rm -f /etc/bak-test-root-proof'
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b2}"
    if ! sc_app_root 'test -e /etc/bak-test-root-proof'; then ok "a restore's preview does not run config.php as root"; else bad "a restore's preview does not run config.php as root"; fi
    sc_app_root 'rm -f /etc/bak-test-root-proof'
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b4} --yes-replace-current-data"
    is_rc 0 "a restore of a backup whose config.php holds that line finishes"
    if ! sc_app_root 'test -e /etc/bak-test-root-proof'; then ok "and does not run config.php as root, the current one or the backup's"; else bad "and does not run config.php as root, the current one or the backup's"; fi
    if ! sc_app_root 'grep -q bak-test-root-proof /var/www/html/public/legacy/config.php'; then ok "the rewritten config.php holds settings only"; else bad "the rewritten config.php holds settings only"; fi
    cfg="$(sc_app_root "stat -c '%U %a' /var/www/html/public/legacy/config.php; ls /var/www/html/public/legacy | grep -c 'config.*restore' || true")"
    if [[ "${cfg}" == "www-data "*$'\n'"0" ]]; then ok "it is www-data's, and no temporary copy of it is left"; else bad "it is www-data's, and no temporary copy of it is left" "${cfg}"; fi
    sc_app_root 'rm -f /etc/bak-test-root-proof'
    sc_app_www "sed -i '/bak-test-root-proof/d' public/legacy/config.php"
    run "$S/run-in-suitecrm.sh backup.sh --remove ${b4} --yes-remove"

    # A backup made before the pictures of email templates were part of one: its restore leaves the pictures alone
    sc_app_www 'echo later-picture > public/legacy/cache/images/bak-test-later.png'
    craft 20200505-050505 "rm -rf tree/public/legacy/cache"
    if ! sc_app_root "tar -tzf ${bdir}/20200505-050505/state.tar.gz | grep -q '^public/legacy/cache/'"; then ok "(a backup without cache/images in its archive)"; else bad "(a backup without cache/images in its archive)"; fi
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200505-050505 --yes-replace-current-data"
    is_rc 0 "a backup that holds no pictures restores"
    pictures="$(sc_app_root 'cat /var/www/html/public/legacy/cache/images/bak-test-later.png /var/www/html/public/legacy/cache/images/bak-test-picture.png' 2>&1)"
    if [ "${pictures}" = $'later-picture\npicture-one' ]; then ok "and leaves the pictures that are there"; else bad "and leaves the pictures that are there" "${pictures}"; fi
    sc_app_root "rm -rf ${bdir}/20200505-050505 /var/www/html/public/legacy/cache/images/bak-test-later.png; rm -f ${hold}"

    # A set-user-ID file of root's in an archive: it comes back as a plain file of www-data's
    craft 20200404-040404 "echo '#!/bin/sh' > tree/public/legacy/upload/bak-test-suid && chown root:root tree/public/legacy/upload/bak-test-suid && chmod 6755 tree/public/legacy/upload/bak-test-suid && echo '#!/bin/sh' > tree/bak-test-suid && chown root:root tree/bak-test-suid && chmod 4755 tree/bak-test-suid"
    sc_app_root "rm -f /root/bak-craft/tree/public/legacy/upload/bak-test-suid /root/bak-craft/tree/bak-test-suid"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20200404-040404 --yes-replace-current-data"
    is_rc 0 "a backup whose archive holds set-user-ID files of root's restores"
    suid="$(sc_app_root "stat -c '%U %a' /var/www/html/public/legacy/upload/bak-test-suid /var/www/html/bak-test-suid 2>&1 | tr '\n' ' '; find /var/www/html -xdev -type f -perm /6000 2>/dev/null | wc -l")"
    if [ "${suid}" = "www-data 755 www-data 755 0" ]; then ok "the files come back as www-data's, without the set-user-ID and set-group-ID bits"; else bad "the files come back as www-data's, without the set-user-ID and set-group-ID bits" "${suid}"; fi
    sc_app_root "rm -rf ${bdir}/20200404-040404 /root/bak-craft /var/www/html/public/legacy/upload/bak-test-suid /var/www/html/bak-test-suid; rm -f ${hold}"

    # The web user owns tmp/, so it can move the backups folder aside and plant one of its own. Root trusts
    # nothing in a folder that is not root's.
    sc_app_www "mv ${bdir} ${bdir}.aside && mkdir -p ${bdir}/20300101-000000 && cd ${bdir}/20300101-000000 && printf -- '-- Dump completed\n' | gzip > db.sql.gz && mkdir -p t/public/legacy && echo planted > t/public/legacy/bak-test-planted && tar -C t -czf state.tar.gz . && rm -rf t && sha256sum db.sql.gz state.tar.gz > SHA256SUMS && printf 'suitecrm_version: 8.10.2\ntables: 1\n' > manifest.txt && touch COMPLETE && cp -a ${bdir}/20300101-000000 ${bdir}/20300102-000000"
    run "$S/run-in-suitecrm.sh --need-backup --check"
    is_rc 76 "--need-backup is not satisfied by a backup in a folder the web user planted"
    has err "is not a folder of root's" "and says that the backups folder is not trusted"
    run "$S/repair.sh --execute --yes-repair"
    is_rc 76 "so a bulk action that asks for a backup is refused"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    is_rc 2 "backup.sh --list refuses the planted folder"
    has err "is not a folder of root's" "with the plain message"
    hasnt out "20300101-000000" "and lists nothing from it"
    run "$S/run-in-suitecrm.sh backup.sh"
    is_rc 2 "backup.sh refuses it too"
    has err "is not a folder of root's" "with the plain message"
    run "$S/run-in-suitecrm.sh backup.sh --remove 20300101-000000 --yes-remove"
    is_rc 2 "and so does --remove"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20300101-000000"
    is_rc 2 "restore.sh refuses the planted folder at the preview"
    has err "is not a folder of root's" "with the plain message"
    run "$S/run-in-suitecrm.sh restore.sh --backup 20300101-000000 --yes-replace-current-data"
    is_rc 2 "and at the restore"
    planted="$(sc_app_root "stat -c '%U' ${bdir} ${bdir}/20300101-000000 | sort -u | tr '\n' ' '; ls ${bdir} | tr '\n' ' '; stat -c '%U %a' ${bdir}.aside; ls ${bdir}.aside | grep -c '^${b1}\$'; ls -d /var/www/html/public/legacy/bak-test-planted ${rmarker} 2>/dev/null | wc -l")"
    if [ "${planted}" = "www-data 20300101-000000 20300102-000000 root 700"$'\n'"1"$'\n'"0" ]; then ok "nothing was changed: the planted folder is as it was, and the real one is where the web user moved it"; else bad "nothing was changed: the planted folder is as it was, and the real one is where the web user moved it" "${planted}"; fi
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 0 "and the database is as it was"
    sc_app_root "rm -rf ${bdir} && mv ${bdir}.aside ${bdir}"
    run "$S/run-in-suitecrm.sh --need-backup --check"
    is_rc 0 "with the real folder back, --need-backup is satisfied again"
    # The same for the image's state folder, where the restore writes its marker and the hold
    sc_app_root "if [ -e ${state_dir} ]; then mv ${state_dir} ${state_dir}.bak-test-keep; fi"
    sc_app_www "mkdir ${state_dir}"
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b1} --yes-replace-current-data"
    is_rc 2 "a restore is refused while the image's state folder is not root's"
    has err "is not a folder of root's" "with the plain message"
    planted="$(sc_app_root "stat -c '%U' ${state_dir}; ls -A ${state_dir} | wc -l")"
    if [ "${planted}" = "www-data"$'\n'"0" ]; then ok "and nothing is written into it"; else bad "and nothing is written into it" "${planted}"; fi
    sc_app_root "rmdir ${state_dir}; if [ -e ${state_dir}.bak-test-keep ]; then mv ${state_dir}.bak-test-keep ${state_dir}; fi"

    # Something else makes tables while the restore runs. The Messenger worker does: it makes its table again
    # whenever it finds it gone. The restore must not stop half-way over that.
    docker exec -d "${SC_DB}" bash -c 'echo $$ > /tmp/recreate.pid; while :; do MYSQL_PWD="$MYSQL_PASSWORD" mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "CREATE TABLE IF NOT EXISTS messenger_messages (id INT); CREATE TABLE IF NOT EXISTS stray_from_elsewhere (id INT)" 2>/dev/null; sleep 0.3; done'
    sleep 1
    take_backup
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b2} --yes-replace-current-data"
    is_rc 0 "a restore finishes although something else makes tables while it runs"
    has out "stray_from_elsewhere" "and names the table that is not the backup's"
    docker exec "${SC_DB}" bash -c 'kill "$(cat /tmp/recreate.pid)"' > /dev/null 2>&1
    sql_is "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = 'suitecrm' AND table_name = 'messenger_messages' AND column_name = 'body'" 1 "the worker's table is the backup's, not the stand-in that was made meanwhile"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "and the records are the backup's"
    sc_db_sql "DROP TABLE IF EXISTS stray_from_elsewhere"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "SuiteCRM can be worked on afterwards"
    sleep 1
    take_backup
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b1} --yes-replace-current-data"
    is_rc 0 "(back to the first backup for the next checks)"

    # A database without SuiteCRM's tables is not backed up: such a backup would be worth nothing
    sc_db_sql "RENAME TABLE config TO config_moved_for_test"
    run "$S/run-in-suitecrm.sh backup.sh"
    is_rc 1 "a backup is refused when the database lacks SuiteCRM's tables"
    sc_db_sql "RENAME TABLE config_moved_for_test TO config"

    # A restore that was cut off: the marker stays, only restore.sh runs, and it needs no fresh backup
    set_state "echo 'cut off' > ${rmarker}; touch ${bdir}/RESTORE-IN-PROGRESS"
    run "$S/records.sh list Accounts"
    is_rc 75 "after a restore that was cut off, the other scripts refuse"
    run "$S/run-in-suitecrm.sh backup.sh"
    is_rc 75 "and so does a new backup"
    run "$S/run-in-suitecrm.sh backup.sh --list"
    is_rc 0 "but the backups can still be listed, to pick the one to restore"
    has out "${b2}  complete" "and the list shows them"
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b2} --yes-replace-current-data"
    is_rc 0 "but a restore runs, without a fresh backup"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 1 "and brings the later state back"
    if ! sc_app_root "test -e ${rmarker} || test -e ${bdir}/RESTORE-IN-PROGRESS"; then ok "it removes the marker, and the marker's earlier name too"; else bad "it removes the marker, and the marker's earlier name too"; fi
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "after which SuiteCRM can be worked on again"

    # A restore that is killed outright. Another session holds a lock on one table, so the restore stops in the
    # middle of dropping the tables, and there it is killed. The kernel frees its lock, the marker and the hold
    # stay, and the next restore clears what the killed one left and finishes.
    all_tables="$(sc_db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'suitecrm'")"
    docker exec -d "${SC_DB}" bash -c 'echo $$ > /tmp/hold-table.pid; MYSQL_PWD="$MYSQL_PASSWORD" exec mariadb -u "$MYSQL_USER" "$MYSQL_DATABASE" -e "LOCK TABLES users READ; SELECT SLEEP(300)"'
    sleep 1
    run "$S/run-in-suitecrm.sh --detach restore.sh --backup ${b1} --yes-replace-current-data"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    stuck=0
    for _ in $(seq 1 60); do
        stuck="$(sc_db_sql "SELECT COUNT(*) FROM information_schema.processlist WHERE state LIKE 'Waiting for table metadata lock%'")"
        if [ "${stuck}" -ge 1 ]; then break; fi
        sleep 0.5
    done
    if [ "${stuck}" -ge 1 ] && kill_job "${job}"; then ok "a restore is killed with SIGKILL in the middle of dropping the tables"; else bad "a restore is killed with SIGKILL in the middle of dropping the tables" "$(sc_app_root 'ps -eo pid,sid,args')"; fi
    docker exec "${SC_DB}" bash -c 'kill "$(cat /tmp/hold-table.pid)"' > /dev/null 2>&1
    run "$S/run-in-suitecrm.sh --status ${job}"
    has out "stopped without an exit code" "--status says the job stopped without an exit code"
    if lock_free; then ok "the lock is free again: it went with the process"; else bad "the lock is free again: it went with the process"; fi
    tables="$(sc_db_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'suitecrm'")"
    if [ "${tables}" -lt "${all_tables}" ]; then ok "SuiteCRM is half restored (${tables} of ${all_tables} tables are left)"; else bad "SuiteCRM is half restored" "${tables} tables"; fi
    left="$(sc_app_root "test -e ${rmarker} && echo marker; test -e ${hold} && echo hold; ls -d ${run_dir}/run.* 2>/dev/null | wc -l")"
    if [ "${left}" = $'marker\nhold\n1' ]; then ok "the marker and the hold are there, and the work folder the killed run left"; else bad "the marker and the hold are there, and the work folder the killed run left" "${left}"; fi
    run "$S/run-in-suitecrm.sh --check"
    is_rc 75 "--check refuses"
    has err "no restore is running now" "and says that no restore is running now"
    has err "Run the restore again" "and to run it again"
    run "$S/run-in-suitecrm.sh restore.sh --backup ${b1} --yes-replace-current-data"
    is_rc 0 "the restore, run again, finishes"
    left="$(sc_app_root "test -e ${rmarker} && echo marker; ls -d ${run_dir}/run.* 2>/dev/null | wc -l; find /run/clouve /var/www/html/tmp -name '*.cnf' 2>/dev/null | wc -l")"
    if [ "${left}" = $'0\n0' ]; then ok "the marker is gone, and so is what the killed run left: its work folder and the database options file"; else bad "the marker is gone, and so is what the killed run left: its work folder and the database options file" "${left}"; fi
    sql_is "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'suitecrm'" "${all_tables}" "all tables are back"
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "and SuiteCRM can be worked on again"

    # A restore that was cut off, and then the container restarts. The image's contract: a start that finds
    # the marker keeps only its stand-in page and the sshd up and waits for the marker to go, so PID 1 is not
    # Apache. An image that does not wait yet starts as usual. The restore has to finish either way.
    sc_app_root "rm -f ${hold}"
    set_state "echo 'cut off' > ${rmarker}"
    restarted="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    docker restart "${SC_APP}" > /dev/null
    waits=''
    for _ in $(seq 1 60); do
        if sc_agent 'SSHPASS="$(clv-secret CLOUVE_OPS_PASSWORD)" sshpass -e ssh -n -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 clouve-ops@${SUITECRM_HOST} true' > /dev/null 2>&1; then
            pid1="$(docker exec "${SC_APP}" cat /proc/1/comm 2> /dev/null)"
            if [ "${pid1}" = apache2 ]; then waits=no; break; fi
            if docker logs --since "${restarted}" "${SC_APP}" 2>&1 | grep -q 'restore-in-progress'; then waits=yes; break; fi
        fi
        sleep 1
    done
    if [ -z "${waits}" ]; then waits=yes; fi
    docker exec -d "${SC_APP}" bash -c "${sampler}"
    if [ "${waits}" = yes ]; then
        echo "  ...this image waits for the restore marker to go"
        run "$S/run-in-suitecrm.sh --check"
        is_rc 75 "a container that started with the marker in place waits, and --check says so"
        has err "under way or was cut off" "naming the restore, not a start-up"
        run "$S/records.sh list Accounts"
        is_rc 75 "the scripts that touch CRM data refuse there"
        run "$S/run-in-suitecrm.sh backup.sh"
        is_rc 75 "and a new backup"
        run "$S/run-in-suitecrm.sh --allow-busy admin state"
        is_rc 0 "the state can still be read"
        run "$S/run-in-suitecrm.sh backup.sh --list"
        is_rc 0 "and the backups listed"
        workers="$(sc_app_root "ps -eo args | grep -c '[p]hp bin/console' || true")"
        if [ "${workers}" = 0 ]; then ok "no scheduler pass and no Messenger worker runs while it waits"; else bad "no scheduler pass and no Messenger worker runs while it waits" "$(sc_app_root 'ps -eo pid,args')"; fi
    else
        echo "  ...this image does not wait for the restore marker yet: it started as usual"
        run "$S/run-in-suitecrm.sh --check"
        is_rc 75 "after a restart with the marker in place, --check still refuses"
    fi
    run "$S/run-in-suitecrm.sh --detach restore.sh --backup ${b1} --yes-replace-current-data"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    wait_job "${job}"
    is_rc 0 "the restore, run again after the restart, finishes"
    if [ "${waits}" = yes ]; then
        has out "finishes its start by itself" "and says that the container finishes its start by itself"
    else
        has out "Restore of ${b1} is complete" "and says so"
    fi
    if ! sc_app_root "test -e ${rmarker}"; then ok "the marker is gone"; else bad "the marker is gone"; fi
    if wait_up; then ok "SuiteCRM answers again"; else bad "SuiteCRM answers again" "$(docker logs --tail 20 "${SC_APP}" 2>&1)"; fi
    run "$S/run-in-suitecrm.sh --check"
    is_rc 0 "and can be worked on"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'After Backup Co'" 0 "with the first backup's records"
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "and the admin signs in"; else bad "and the admin signs in" "HTTP ${code}"; fi

    # A restore onto an empty volume: a second, new stack gets the first one's backup
    echo "  ...starting a second stack with an empty volume"
    second_id="${main_id}b"
    (
        SC_ID="${second_id}"
        sc_stack_up "${second_id}" > /dev/null
    ) || bad "(the second stack started)"
    SC_ID="${second_id}"
    sc_names
    docker exec "${SC_STACK_PREFIX}-app-${main_id}" tar -C "${bdir}" -cf - "${b1}" | docker exec -i "${SC_APP}" bash -c "install -d -m 700 ${bdir} && tar -C ${bdir} -xpf -"
    sql_is "SELECT COUNT(*) FROM accounts WHERE name = 'Before Backup Co'" 0 "(the new install does not have the first one's account)"
    take_backup
    run "$S/run-in-suitecrm.sh --detach restore.sh --backup ${b1} --yes-replace-current-data"
    job="$(printf '%s\n' "${out}" | sed -n 's/^job: //p')"
    wait_job "${job}"
    is_rc 0 "the backup restores onto the new install"
    sql_is "SELECT COUNT(*) FROM accounts WHERE deleted = 0 AND name = 'Before Backup Co'" 1 "its records are there"
    marker="$(sc_app_root 'cat /var/www/html/public/legacy/custom/test/marker.txt')"
    if [ "${marker}" = kept ]; then ok "and its files"; else bad "and its files" "${marker}"; fi
    picture="$(sc_app_root 'cat /var/www/html/public/legacy/cache/images/bak-test-picture.png; stat -c %U /var/www/html/public/legacy/cache/images/bak-test-picture.png' 2>&1)"
    if [ "${picture}" = $'picture-one\nwww-data' ]; then ok "and the picture of an email template, which the new install did not have"; else bad "and the picture of an email template, which the new install did not have" "${picture}"; fi
    dbhost="$(docker exec -u www-data "${SC_APP}" php -r 'include "/var/www/html/public/legacy/config.php"; echo $sugar_config["dbconfig"]["db_host_name"];')"
    if [ "${dbhost}" = "${SC_DB}" ]; then ok "config.php still names this deployment's database, not the one the backup came from"; else bad "config.php still names this deployment's database" "${dbhost}"; fi
    run "$S/records.sh list Accounts --search 'Before Backup'"
    json '.total' 1 "SuiteCRM's own code reads the restored records"
    code="$(login_code "${SC_ADMIN_USER}" "${SC_PW_ADMIN}")"
    if [ "${code}" = 200 ]; then ok "and the admin signs in"; else bad "and the admin signs in" "HTTP ${code}"; fi
    sc_stack_down
    second_id=''
    SC_ID="${main_id}"
    sc_names

    # The stack as the next sections expect it: no test rows in the campaign queue, and the scheduler not held
    sc_db_sql "DELETE FROM emailman WHERE related_id LIKE 'bak-test-queue-%'"
    sc_app_root 'rm -f /var/www/html/public/legacy/cache/images/bak-test-picture*.png /var/www/html/public/legacy/cache/bak-test-other.txt'
    sc_app_root "rm -f ${hold}"
fi

# ---------------------------------------------------------------------------
# health
# ---------------------------------------------------------------------------
if wants health; then
    section "verify-health.sh and upgrade-state.sh"
    # ops_state CMD: like set_state, with the state folder as the image and the skill trust it: root's, mode 700,
    # without the set-group-ID bit a folder made in tmp/ takes over
    ops_state() { sc_app_root "install -d -m 700 ${state_dir} && chown root:root ${state_dir} && chmod 00700 ${state_dir} && $1"; }
    # line_is LEVEL CHECK TEXT LABEL: verify-health.sh's line for CHECK has LEVEL and holds TEXT
    line_is() {
        local line
        line="$(printf '%s\n' "${out}" | grep -E "^  [A-Z]+ +$2 " | head -n 1)"
        if [[ "${line}" =~ ^\ \ $1\ +$2\  ]] && [[ "${line}" == *"$3"* ]]; then ok "$4"; else bad "$4" "wanted a $1 line for $2 with: $3"$'\n'"got: ${line:-no such line}"; fi
    }
    shadow_first="$(sc_app_root 'head -n 1 /etc/shadow')"
    sc_app_root "if [ -d ${state_dir} ] && [ ! -L ${state_dir} ]; then chown root:root ${state_dir} && chmod 00700 ${state_dir}; fi"
    sc_app_root 'rm -f /var/www/html/public/legacy/config_si.php'
    # Whatever an earlier section left: no restore marker, the scheduler not held (a restore leaves it held),
    # and a scheduler pass that has just run
    sc_app_root "rm -f ${state_dir}/scheduler-held ${state_dir}/restore-in-progress /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS"
    run "$S/scheduler.sh run-once"
    run "$S/verify-health.sh"
    is_rc 0 "verify-health.sh is green on a healthy stack"
    has out "Overall: GREEN" "and says so"
    has out "8.10.2" "it reports the version"
    hasnt out "${SC_PW_DB}" "and prints no password"
    if [ -z "${err}" ]; then ok "and nothing on stderr"; else bad "and nothing on stderr" "${err}"; fi

    # A new install: no Manual Migration Tasks, the image's version next to the volume's, and no state folder
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh runs on a new install"
    has out "Manual Migration Tasks: none." "which has no Manual Migration Tasks"
    hasnt out "An admin starts them" "so it gives no hint to start them"
    if ! printf '%s\n%s\n' "${out}" "${err}" | grep -q '^jq:'; then ok "and no line of jq's on stdout or stderr"; else bad "and no line of jq's on stdout or stderr" "${out}"$'\n'"${err}"; fi
    if [ -z "${err}" ]; then ok "and nothing at all on stderr"; else bad "and nothing at all on stderr" "${err}"; fi
    # An upgraded install: the upgrade leaves seven Manual Migration Tasks that wait for an admin. Two more here
    # are done already.
    task_rows=''
    for n in 1 2 3 4 5 6 7; do task_rows+="('ops-test-task-${n}', 'ops test task ${n}', UTC_TIMESTAMP(), UTC_TIMESTAMP(), 0, 'ops-test', 'initial'), "; done
    task_rows+="('ops-test-task-8', 'ops test task 8', UTC_TIMESTAMP(), UTC_TIMESTAMP(), 0, 'ops-test', 'completed'), ('ops-test-task-9', 'ops test task 9', UTC_TIMESTAMP(), UTC_TIMESTAMP(), 0, 'ops-test', 'completed')"
    sc_db_sql "INSERT INTO manual_migration_tasks (id, name, date_entered, date_modified, deleted, type, status) VALUES ${task_rows}"
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh runs on an upgraded install"
    if [[ "${out}" == *"Manual Migration Tasks:"*"7 initial"* && "${out}" == *"Manual Migration Tasks:"*"2 completed"* ]]; then ok "and counts the Manual Migration Tasks by status"; else bad "and counts the Manual Migration Tasks by status" "${out}"; fi
    has out "An admin starts them in SuiteCRM under Admin > Migrations" "with the hint that an admin starts them"
    if ! printf '%s\n%s\n' "${out}" "${err}" | grep -q '^jq:'; then ok "and again no line of jq's"; else bad "and again no line of jq's" "${out}"$'\n'"${err}"; fi
    run "$S/verify-health.sh"
    is_rc 2 "the waiting tasks make verify-health.sh amber"
    line_is WARN migrations "7 Manual Migration Task(s) wait" "and it warns about the seven that wait"
    sc_db_sql "DELETE FROM manual_migration_tasks WHERE id LIKE 'ops-test-task-%'"
    run "$S/upgrade-state.sh"
    has out "Manual Migration Tasks: none." "with the rows gone it is a new install again"
    has out "SuiteCRM version in the image: 8.10.2" "it prints the image's own version next to the volume's"
    sc_app_root "if [ -d ${state_dir} ]; then mv ${state_dir} ${state_dir}.ops-test-keep; fi"
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh works when the image's state folder is not there"
    has out "Scheduler: not held" "a missing state folder means the scheduler is not held"
    has out "No upgrade is under way" "and no upgrade under way"
    if [ -z "${err}" ]; then ok "without noise about the missing folder"; else bad "without noise about the missing folder" "${err}"; fi
    run "$S/verify-health.sh"
    is_rc 0 "and verify-health.sh is green without a state folder"
    sc_app_root "if [ -d ${state_dir}.ops-test-keep ]; then mv ${state_dir}.ops-test-keep ${state_dir}; fi"

    ops_state "touch ${state_dir}/scheduler-held"
    sc_app_root 'echo "<?php" > /var/www/html/public/legacy/config_si.php'
    run "$S/verify-health.sh"
    is_rc 2 "a held scheduler and a leftover config_si.php make it amber"
    has out "scheduler-held" "it names the hold"
    has out "config_si.php" "and the file"
    has out "scheduler.sh release --yes-release" "and the release with its yes flag"
    ops_state "rm -f ${state_dir}/scheduler-held"
    sc_app_root 'rm -f /var/www/html/public/legacy/config_si.php'
    ops_state "printf 'phase=failed\nfrom=8.9.1\nto=8.10.2\nreason=finalize exited 1\n' > ${state_dir}/state"
    run "$S/verify-health.sh"
    is_rc 3 "a failed upgrade makes it red"
    has out "failed" "and it says the upgrade failed"
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh reads the state"
    has out "failed" "and reports the failed upgrade"
    has out "finalize exited 1" "with the image's reason"
    ops_state "install -d -m 700 ${state_dir}/8.9.1-to-8.10.2 && head -c 100000 /dev/urandom > ${state_dir}/8.9.1-to-8.10.2/code.tar.gz"
    run "$S/upgrade-state.sh"
    has out "8.9.1-to-8.10.2" "after a failed upgrade it lists the backup the upgrade kept"
    hasnt out "--yes-remove" "and does not say how to remove a backup the way back may need"
    ops_state "rm -f ${state_dir}/state"
    run "$S/upgrade-state.sh"
    has out "8.9.1-to-8.10.2" "it lists the backup the upgrade kept"
    has out "No upgrade is under way" "and says no upgrade is under way"
    has out "--remove-kept-backup <name> --yes-remove" "after a finished upgrade it says how to remove the kept backup"
    run "$S/upgrade-state.sh --remove-kept-backup 8.9.1-to-8.10.2"
    is_rc 64 "removing the kept backup needs --yes-remove"
    ops_state "printf 'phase=upgrade\n' > ${state_dir}/state"
    run "$S/upgrade-state.sh --remove-kept-backup 8.9.1-to-8.10.2 --yes-remove"
    is_rc 2 "it is refused while an upgrade is under way"
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh still reads the state during an upgrade"
    has out "phase: upgrade" "and shows the phase"
    run "$S/verify-health.sh"
    is_rc 3 "verify-health.sh is red during an upgrade, and still runs"
    ops_state "rm -f ${state_dir}/state"

    # The web user moved root's state folder aside and put its own there, with files that are links to /etc/shadow
    ops_state "touch ${state_dir}/scheduler-held"
    sc_app_root "mv ${state_dir} ${state_dir}.ops-test-keep"
    sc_app_www "mkdir ${state_dir} ${state_dir}/8.9.1-to-8.10.2 && ln -s /etc/shadow ${state_dir}/upgrade-failed && ln -s /etc/shadow ${state_dir}/state && ln -s /etc/shadow ${state_dir}/upgrade-skipped && ln -s /etc/shadow ${state_dir}/scheduler-held"
    run "SC_SKILL_CALLER=test $S/run-in-suitecrm.sh --allow-busy admin state"
    is_rc 0 "admin.sh state runs on a state folder that is not root's"
    has out "state_dir=untrusted" "and says that the folder is not trusted"
    if [[ "${out}${err}" != *"${shadow_first}"* && "${out}${err}" != *"daemon:"* ]]; then ok "it prints nothing of the file the planted links point at"; else bad "it prints nothing of the file the planted links point at" "${out}"; fi
    hasnt out "kept_backup=" "and lists nothing from the planted folder"
    run "$S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh runs on a state folder that is not root's"
    has out "tmp/clouve-backup is not a folder of root's" "it names the folder that is not trusted"
    has out "Clouve support" "and says that putting it right is a step for Clouve support"
    hasnt out "No upgrade is under way" "it does not claim that no upgrade is under way"
    if [[ "${out}${err}" != *"${shadow_first}"* && "${out}${err}" != *"daemon:"* ]]; then ok "and prints nothing of the file the planted links point at"; else bad "and prints nothing of the file the planted links point at" "${out}"; fi
    run "$S/verify-health.sh"
    line_is WARN state-dir "tmp/clouve-backup is not a folder of root's" "verify-health.sh warns about the state folder"
    sched_line="$(printf '%s\n' "${out}" | grep -E '^  WARN +scheduler ' | head -n 1)"
    if [[ "${sched_line}" == *"not known"* || "${sched_line}" == *"runs no scheduled job"* ]]; then ok "and does not say that the scheduler is fine"; else bad "and does not say that the scheduler is fine" "${sched_line:-no WARN line for the scheduler}"; fi
    if [[ "${out}${err}" != *"${shadow_first}"* && "${out}${err}" != *"daemon:"* ]]; then ok "and prints nothing of that file either"; else bad "and prints nothing of that file either" "${out}"; fi
    run "$S/upgrade-state.sh --remove-kept-backup 8.9.1-to-8.10.2 --yes-remove"
    if [ "${rc}" -eq 2 ] && [[ "${err}" == *"not a folder of root's"* ]]; then ok "removing a kept backup is refused when the state folder is not root's"; else bad "removing a kept backup is refused when the state folder is not root's (exit ${rc})" "${err}"; fi
    planted="$(sc_app_root "test -d ${state_dir}/8.9.1-to-8.10.2 && test -L ${state_dir}/upgrade-failed && test -e ${state_dir}.ops-test-keep/scheduler-held && stat -c %U ${state_dir}")"
    if [ "${planted}" = www-data ]; then ok "and nothing was changed: the planted folder and the real one are as they were"; else bad "and nothing was changed: the planted folder and the real one are as they were" "${planted}"; fi
    # The same with a link in place of the folder
    sc_app_root "mv ${state_dir} ${state_dir}.ops-test-planted"
    sc_app_www "ln -s ${state_dir}.ops-test-planted ${state_dir}"
    run "SC_SKILL_CALLER=test $S/run-in-suitecrm.sh --allow-busy admin state"
    has out "state_dir=untrusted" "a link in place of the state folder is not trusted either"
    if [[ "${out}${err}" != *"${shadow_first}"* && "${out}${err}" != *"daemon:"* ]]; then ok "and nothing is read through it"; else bad "and nothing is read through it" "${out}"; fi
    sc_app_root "rm -f ${state_dir}; rm -rf ${state_dir}.ops-test-planted; mv ${state_dir}.ops-test-keep ${state_dir}"
    # In a folder of root's, a file that is a link is not printed either
    ops_state "rm -f ${state_dir}/scheduler-held; ln -s /etc/shadow ${state_dir}/upgrade-failed; ln -s /etc/shadow ${state_dir}/upgrade-skipped"
    run "$S/upgrade-state.sh"
    if [[ "${out}${err}" != *"${shadow_first}"* && "${out}${err}" != *"daemon:"* ]]; then ok "a link inside the state folder is not printed"; else bad "a link inside the state folder is not printed" "${out}"; fi
    ops_state "rm -f ${state_dir}/upgrade-failed ${state_dir}/upgrade-skipped"
    # A folder the image moved aside because it did not trust it
    sc_app_root "install -d -m 700 ${state_dir}.untrusted-20261112T201500Z"
    run "$S/upgrade-state.sh"
    has out "clouve-backup.untrusted-20261112T201500Z" "upgrade-state.sh lists a state folder the image moved aside"
    has out "Clouve support" "and says that putting it back is a step for Clouve support"
    run "$S/verify-health.sh"
    line_is WARN state-dir "clouve-backup.untrusted-20261112T201500Z" "and verify-health.sh warns about it"
    sc_app_root "rmdir ${state_dir}.untrusted-20261112T201500Z"

    run "$S/upgrade-state.sh --remove-kept-backup ../clouve-skill-backups --yes-remove"
    is_rc 64 "a name that is not a kept backup's is refused"
    run "$S/upgrade-state.sh --remove-kept-backup 8.9.1-to-8.10.2 --yes-remove"
    is_rc 0 "with the yes, and no upgrade under way, the kept backup is removed"
    if ! sc_app_root "test -e ${state_dir}/8.9.1-to-8.10.2"; then ok "and it is gone"; else bad "and it is gone"; fi

    # The restore marker, under its name in the image's state folder and under the earlier one
    ops_state "touch ${state_dir}/restore-in-progress"
    run "$S/verify-health.sh"
    is_rc 3 "a restore marker makes verify-health.sh red"
    line_is FAIL restore "restore-in-progress" "and it names the marker"
    ops_state "rm -f ${state_dir}/restore-in-progress"
    sc_app_root "install -d -m 700 /var/www/html/tmp/clouve-skill-backups && chown root:root /var/www/html/tmp/clouve-skill-backups && chmod 00700 /var/www/html/tmp/clouve-skill-backups && touch /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS"
    run "$S/verify-health.sh"
    line_is FAIL restore "RESTORE-IN-PROGRESS" "the earlier marker name is still read"
    sc_app_root "rm -f /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS"

    # An older version on the volume than in the image, and no upgrade under way: the image skipped the upgrade
    sc_app_root 'cp -p /var/www/html/VERSION /var/www/html/VERSION.test-keep && echo 8.9.1 > /var/www/html/VERSION'
    run "$S/verify-health.sh"
    has out "8.9.1 has no Messenger worker" "on 8.9 code (after a failed upgrade) the missing worker is not a warning"
    line_is WARN upgrade "the image has 8.10.2, the volume runs 8.9.1: the image did not start the upgrade" "verify-health.sh warns that the image did not start the upgrade"
    run "$S/upgrade-state.sh"
    has out "the image has 8.10.2, the volume runs 8.9.1: the image did not start the upgrade" "upgrade-state.sh says that the image did not start the upgrade"
    has out "[clouve-upgrade]" "that the reason is in the container's log line"
    has out "Clouve support" "which Clouve support reads"
    has out "disk line of verify-health.sh" "and points at the disk check"
    hasnt out "No upgrade is under way" "it does not say that no upgrade is under way"
    # The image's note: name=value lines (from, to, reason, time), a file of root's with mode 600
    ops_state "printf 'from=8.9.1\nto=8.10.2\nreason=not enough free space on the volume: 120 MB free, about 900 MB needed\ntime=2026-11-12T20:15:00Z\n' > ${state_dir}/upgrade-skipped && chmod 600 ${state_dir}/upgrade-skipped"
    run "$S/upgrade-state.sh"
    has out "the image has 8.10.2, the volume runs 8.9.1: the image did not start the upgrade, because not enough free space on the volume: 120 MB free, about 900 MB needed (at 2026-11-12T20:15:00Z)" "with the image's note it gives the reason and the time"
    hasnt out "No upgrade is under way" "and still does not say that no upgrade is under way"
    run "$S/verify-health.sh"
    line_is WARN upgrade "because not enough free space on the volume" "verify-health.sh gives the reason too"
    ops_state "rm -f ${state_dir}/upgrade-skipped"
    sc_app_root 'cat /var/www/html/VERSION.test-keep > /var/www/html/VERSION && rm -f /var/www/html/VERSION.test-keep'

    # A container that waits: PID 1 is not Apache, the sshd answers. First with a restore marker, then without.
    busy_box="${SC_STACK_PREFIX}-wait-${main_id}"
    docker run -d --name "${busy_box}" --network "${SC_NET}" --memory 512m --entrypoint bash "$(sc_stack_app_image)" \
        -c 'ssh-keygen -A >/dev/null; mkdir -p /run/sshd; /usr/sbin/sshd; exec sleep infinity' > /dev/null
    docker exec -i "${busy_box}" bash -c 'IFS= read -r p; printf "clouve-ops:%s\n" "$p" | chpasswd' <<< "${SC_PW_OPS}"
    docker exec "${busy_box}" bash -c "mkdir -p /var/www/html/tmp && install -d -m 700 ${state_dir} && chmod 00700 ${state_dir} && touch ${state_dir}/restore-in-progress && echo 8.10.2 > /var/www/html/VERSION"
    sleep 2
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    is_rc 0 "upgrade-state.sh runs in a container that waits"
    has out "the container is waiting: a restore was cut off (run the restore again" "it says that the container waits for a restore that was cut off"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    is_rc 3 "verify-health.sh is red there, and still runs"
    has out "the container is waiting: a restore was cut off (run the restore again" "and says the same"
    # The image leaves a note for the assistant while it waits, because the assistant can't read the container's
    # log: tmp/clouve-backup/needs-attention, root's, mode 600, with reason, since, from, to and kind, one per
    # line (sc_attention_write in the image's lib.sh). Both reports show what it says.
    # write_note OWNER KIND REASON: the note as the image writes it
    write_note() {
        docker exec -i "${busy_box}" bash -c "umask 077; cat > ${state_dir}/needs-attention; chown $1 ${state_dir}/needs-attention" <<NOTE
reason=$3
since=2026-11-12T21:00:00Z
from=8.9.1
to=8.10.2
kind=$2
NOTE
    }
    write_note root:root restore "a restore is under way (${state_dir}/restore-in-progress is there), so this start waits: nothing is installed, upgraded or started until the restore has finished and removed its marker."
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    has out "the container is waiting: a restore was cut off (run the restore again" "with the image's note of a wait for a restore, upgrade-state.sh still says to run the restore again"
    has out "nothing is installed, upgraded or started until the restore has finished" "and gives the image's own reason"
    has out "since 2026-11-12T21:00:00Z" "and since when it waits"
    has out "Files in the image's state folder (tmp/clouve-backup): restore-in-progress, needs-attention." "the note is in its list of the state folder's files"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    line_is FAIL start-up "nothing is installed, upgraded or started until the restore has finished" "verify-health.sh gives the image's reason too"
    docker exec "${busy_box}" rm -f "${state_dir}/restore-in-progress" "${state_dir}/needs-attention"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    has out "waiting or still starting" "without a marker it says that the container is waiting or still starting"
    has out "Clouve support" "and that the way out is Clouve support"
    hasnt out "emove" "and tells nobody to remove anything"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    line_is FAIL start-up "waiting or still starting" "verify-health.sh says the same"
    # The image marks a start that waits for a person with a file of root's in /run (its stand-in page then
    # says that SuiteCRM needs attention)
    docker exec "${busy_box}" touch /run/clouve-suitecrm-attention
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    has out "the container is waiting: the image found a site that it must not start as it is" "with the image's mark it says that the container waits for a repair"
    has out "Clouve support" "that the way out is Clouve support"
    has out "[clouve-upgrade] FAILED" "and which line of the container's log says what was found"
    hasnt out "emove" "and again tells nobody to remove anything"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    line_is FAIL start-up "the container is waiting: the image found a site that it must not start as it is" "verify-health.sh says the same"
    # With the image's note, both reports say what it found, in the image's words
    found="the code on the volume is 8.10.2 and the database says 8.9.1, and no upgrade backup is there to go back to"
    write_note root:root repair "${found}"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    has out "the container is waiting: the image found a site that it must not start as it is" "with the image's note, upgrade-state.sh says that the container waits for a repair"
    has out "${found}" "and what the image found, from its note"
    has out "since 2026-11-12T21:00:00Z" "since when it waits"
    has out "SuiteCRM 8.9.1 on the volume and 8.10.2 in the image" "and the two versions the note names"
    hasnt out "which only Clouve support can read" "and does not say that only Clouve support can read the reason"
    has out "Clouve support" "the way out is still Clouve support"
    hasnt out "emove" "and it tells nobody to remove anything"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    line_is FAIL start-up "${found}" "verify-health.sh gives what the image found too"
    # A note that is not a plain file of root's is not read: the web user owns tmp/ and could plant one
    write_note www-data:www-data repair "planted-by-the-web-user"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    hasnt out "planted-by-the-web-user" "a note that belongs to the web user is not read"
    has out "[clouve-upgrade] FAILED" "and the report names the log line instead"
    docker exec "${busy_box}" bash -c "rm -f ${state_dir}/needs-attention; ln -s /etc/hostname ${state_dir}/needs-attention"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    hasnt out "$(docker exec "${busy_box}" cat /etc/hostname)" "and neither is a note that is a link"
    docker exec "${busy_box}" rm -f "${state_dir}/needs-attention"
    # Control characters in a note never reach the terminal
    docker exec "${busy_box}" bash -c "umask 077; printf 'reason=line one\\033[31m red\\rover\nsince=2026-11-12T21:00:00Z\nfrom=8.9.1\nto=8.10.2\nkind=repair\n' > ${state_dir}/needs-attention"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    if [[ "${out}" == *"line one[31m redover"* ]] && [[ "${out}" != *$'\033'* ]] && [[ "${out}" != *$'\r'* ]]; then ok "control characters in a note are taken out"; else bad "control characters in a note are taken out" "$(printf '%s' "${out}" | grep -a 'line one' | cat -v)"; fi
    # One wait has no note: the image moved a state folder aside as untrusted and makes no new one, so that
    # staff can put the old one back. The folder's name is the sign, and the reports say that, with no reason line.
    docker exec "${busy_box}" bash -c "rm -rf ${state_dir}; mkdir -p ${state_dir}.untrusted-20261112T201500Z"
    run "SUITECRM_HOST=${busy_box} $S/upgrade-state.sh"
    has out "the container is waiting: the image set its state folder aside as untrusted (tmp/clouve-backup.untrusted-20261112T201500Z)" "a wait behind a state folder that was moved aside: upgrade-state.sh says that the image set it aside as untrusted"
    has out "Clouve support has to check it and put it back" "and that Clouve support has to check it and put it back"
    hasnt out "Why it waits" "with no reason line"
    hasnt out "emove" "and it tells nobody to remove anything"
    run "SUITECRM_HOST=${busy_box} $S/verify-health.sh"
    line_is FAIL start-up "the image set its state folder aside as untrusted (tmp/clouve-backup.untrusted-20261112T201500Z)" "verify-health.sh says the same"
    line_is FAIL start-up "Clouve support has to check it and put it back" "with the way out"
    docker rm -f "${busy_box}" > /dev/null 2>&1
    busy_box=''

    docker stop "${SC_DB}" > /dev/null
    run "$S/verify-health.sh"
    is_rc 3 "a database that is down makes verify-health.sh red"
    docker start "${SC_DB}" > /dev/null
    for _ in $(seq 1 60); do sc_db_sql 'SELECT 1' > /dev/null 2>&1 && break; sleep 1; done
    run "SUITECRM_HOST=no-such-host.invalid $S/verify-health.sh"
    is_rc 3 "and so does a SuiteCRM container that can't be reached"
fi

# ---------------------------------------------------------------------------
# sweep
# ---------------------------------------------------------------------------
if wants sweep; then
    section "No password in any process's arguments, or in anything a script printed"
    docker exec "${SC_AGENT}" bash -c 'kill "$(cat /tmp/argv-sample.pid)"' > /dev/null 2>&1 || true
    docker exec "${SC_APP}" bash -c 'kill "$(cat /tmp/argv-sample.pid)"' > /dev/null 2>&1 || true
    docker exec "${SC_AGENT}" sort -u /tmp/argv-sample.log > "${work}/argv-agent.log" 2> /dev/null
    docker exec "${SC_APP}" sort -u /tmp/argv-sample.log > "${work}/argv-app.log" 2> /dev/null
    lines_agent="$(wc -l < "${work}/argv-agent.log")"
    lines_app="$(wc -l < "${work}/argv-app.log")"
    if [ "${lines_agent}" -gt 20 ] && [ "${lines_app}" -gt 20 ] && grep -q 'run-in-suitecrm.sh' "${work}/argv-agent.log" && grep -q 'remote/entry.sh' "${work}/argv-app.log"; then
        ok "the samplers saw the scripts run (${lines_agent} distinct command lines on the agent, ${lines_app} in SuiteCRM's container)"
    else
        bad "the samplers saw the scripts run" "agent ${lines_agent}, app ${lines_app}"
    fi
    {
        printf '%s\n' "${SC_PW_OPS}" "${SC_PW_DB}" "${SC_PW_DBROOT}" "${SC_PW_ADMIN}"
        cat "${work}/temp-passwords" 2> /dev/null
    } | sort -u > "${work}/passwords"
    n="$(wc -l < "${work}/passwords")"
    for where in agent app; do
        if hits="$(grep -cFf "${work}/passwords" "${work}/argv-${where}.log")" && [ "${hits}" -gt 0 ]; then
            bad "none of the ${n} passwords is in an argument list in the ${where} container" "$(grep -Ff "${work}/passwords" "${work}/argv-${where}.log" | cut -c1-160 | sed -E 's/[A-Za-z]+-Pw-[A-Za-z0-9]+/[password]/g' | head -n 5)"
        else
            ok "none of the ${n} passwords is in an argument list in the ${where} container"
        fi
    done
    if grep -qFf "${work}/passwords" "${all_output}"; then
        bad "none of them is in anything a script printed" "$(grep -Ff "${work}/passwords" "${all_output}" | cut -c1-120 | sed -E 's/[A-Za-z]+-Pw-[A-Za-z0-9]+/[password]/g' | head -n 5)"
    else
        ok "none of them is in anything a script printed"
    fi
    # A password hash is a secret too: SuiteCRM's are bcrypt, and they start with $2y$.
    hashes="$(grep -cF '$2y$' "${all_output}" || true)"
    if [ "${hashes}" = 0 ]; then ok "and nothing a script printed holds a password hash"; else bad "and nothing a script printed holds a password hash" "${hashes} lines with a bcrypt hash"; fi
    logs="$(docker exec "${SC_APP}" bash -c 'cat /var/www/html/logs/legacy/suitecrm.log /var/www/html/logs/prod/*.log /var/www/html/tmp/clouve-skill-backups/*/manifest.txt /run/clouve/jobs/*.log 2>/dev/null' | grep -cFf "${work}/passwords" || true)"
    if [ "${logs}" = 0 ]; then ok "or in SuiteCRM's logs, a backup's manifest or a job's log"; else bad "or in SuiteCRM's logs, a backup's manifest or a job's log" "${logs} lines"; fi
    world="$(docker exec "${SC_AGENT}" bash -c 'find /home/clouve /tmp -type f -perm /044 2>/dev/null | xargs -r grep -lFf /dev/stdin 2>/dev/null | wc -l' < "${work}/passwords")"
    if [ "${world}" = 0 ]; then ok "and no file on the agent that others can read holds one"; else bad "and no file on the agent that others can read holds one" "${world} files"; fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "suitecrm-scripts: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
