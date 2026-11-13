#!/bin/bash
# ============================================================================
# LimeSurvey skill: the scripts in plugins/limesurvey/skills/limesurvey/scripts/
# ============================================================================
# Runs every script of the plugin against a real LimeSurvey 7.10.0 in Docker, the way the assistant runs them: from
# a container that stands in for the Magneto Agent, over the clouve-ops SSH channel, with the passwords served by a
# (fake) clv-secret and never in the environment. tests/lib/limesurvey-stack.sh builds and starts the containers
# (LimeSurvey, MariaDB 11.8, the agent, a mail sink), on a network of their own with no published ports, and
# removes them at the end.
#
# Sections:
#    0. the files, before any container: every script parses, and the list of RemoteControl methods and the
#       filter for replies (remote/lib/rc-policy.php) do what they say, on made-up replies
#    1. the runner (run-in-limesurvey.sh): the state it reads, its refusals while LimeSurvey is being installed,
#       upgraded or restored, argument quoting, exit codes, nothing left in the container
#    2. console.sh: the allow-list, wipe, demomode, install and resetpassword refused whatever the arguments, a
#       copy imported and the file kept, checkintegrity only with --yes
#    3. rc.sh: RemoteControl methods without HTTP or a password; every method that sends mail, activates, deletes,
#       exports or writes answers refused with the script to use; every method that changes the site only with
#       --yes; no encryption key, session token or password-link key in any reply; nothing left behind
#    4. survey-import.sh: the checker's refusals, the layouts of a survey in two languages, an inactive draft with
#       its links, the file's counts in the survey
#    5. participants.sh: the list, people from CSV and JSON, no access code in any output, and an open survey that
#       is not closed without a yes; survey-activate.sh and delete.sh: a preview first, the change only with a yes
#    6. invitations.sh and mail-settings.sh, against the mail sink: nothing is sent for an inactive survey, without
#       --send, with the wrong --expect, or without a gap for reminders; reminders go to the people who are due
#       and to nobody else; a send larger than one batch; an address the mailer drops is reported
#    7. responses.sh: a summary without what people typed, exports and the statistics report as private files
#    8. temp-password.sh and admin-users.sh: the private file, the password never shown, every refusal, a reply
#       that is lost
#    9. extensions.sh: a compatible plugin and theme go in, incompatible ones are refused
#   10. survey-archive.sh: .lss and .lsa out and in, the .lsa import gated, nothing left in tmp/ when an export
#       fails; crm-link.sh without the Customer Kit's plugin
#   11. upgrade-state.sh: each state of the image's upgrade, a failed and a skipped upgrade with the image's
#       reason, a container that waits for a repair, and the kept backup removed only after a yes
#   12. backup.sh and verify-health.sh: a folder that is not root's own is refused (a planted link, a planted
#       folder, the state folder renamed aside), a full volume, a container that is still starting, a missing or
#       wrong security.php and the keys-only way back
#   13. restore.sh onto another deployment with empty volumes: the keys first, then the data, the tables the
#       backup does not hold removed, a backup with a setuid file and a device file, a restore that fails half
#       way and its marker, a safety backup that is too old
#   14. no secret anywhere: every start of a program in the containers recorded with its arguments, the process
#       lists sampled as well, every output and every container log, searched for each password, for the
#       encryption keys, for session tokens and for participants' access codes
#
# tests/limesurvey-backup-faults.test.sh has the slow cases: a backup that is killed, two at once, a restore of
# a table big enough to outlast the platform's health check, and a restart in the middle of it.
#
# Settings: see tests/lib/limesurvey-stack.sh (LS_TEST_PREFIX, LS_TEST_ZIP, LS_TEST_APP_IMAGE, LS_TEST_DB_IMAGE,
# LS_TEST_KEEP, LS_TEST_OFFLINE=1 to leave out the one check that needs the Ubuntu package archive).
#
# Needs docker. The first run builds three images (a few minutes, and the LimeSurvey release zip, about 120 MB,
# unless LS_TEST_ZIP names a copy). A run takes about six minutes.
#
# Usage: bash tests/limesurvey-scripts.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: the commands handed to the agent are literal text, with $ in single quotes on purpose.
# SC2154: lib/limesurvey-stack.sh, sourced below, sets the ls_* variables.
# shellcheck disable=SC2016,SC2154

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/limesurvey-stack.sh
. "${here}/lib/limesurvey-stack.sh"
command -v docker > /dev/null || { echo "limesurvey-scripts: this test needs docker" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/limesurvey-scripts-test.XXXXXX")"
transcript="${work}/transcript"
ps_log="${work}/ps"
exec_log="${work}/exec"
: > "${transcript}"
: > "${ps_log}"
: > "${exec_log}"
# The stacks whose process lists are sampled. Stack 2 joins when it starts.
echo 1 > "${work}/stacks"
sampler=''
cleanup() {
    if [ -n "${sampler}" ]; then
        rm -f "${work}/sampling"
        wait "${sampler}" 2> /dev/null
    fi
    ls_stack_down
    rm -rf "${work}"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 12 | cut -c1-240 | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }

S=/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts
stack=1
out=''
rc=0
# run COMMAND: runs it in the agent's login shell; leaves its output (stdout and stderr) in out and its code in rc
run() {
    out="$(agent "${stack}" "$1" 2>&1)"
    rc=$?
    printf '$ %s\n%s\n[exit %s]\n' "$1" "${out}" "${rc}" >> "${transcript}"
}
# is LABEL WANT GOT
is() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted: $2
got:    $3"; fi; }
# code LABEL WANT: the last run's exit code
code() { if [ "${rc}" -eq "$2" ]; then ok "$1 (exit $2)"; else bad "$1 (exit ${rc}, wanted $2)" "${out}"; fi; }
# has LABEL TEXT / hasnt LABEL TEXT: the last run's output
has() { if [[ "${out}" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted: $2
in:     ${out}"; fi; }
hasnt() { if [[ "${out}" != *"$2"* ]]; then ok "$1"; else bad "$1" "did not want: $2"; fi; }
surveys() { db_sql "${stack}" 'select count(*) from lime_surveys'; }
remote_leftovers() { app_root "${stack}" 'ls -d /tmp/clouve-ls.* /tmp/clouve-ls-db.* /tmp/clouve-ls-import.* /tmp/clouve-ls-restore.* 2> /dev/null | wc -l'; }
maintenance() { db_sql "${1:-${stack}}" "select coalesce((select stg_value from lime_settings_global where stg_name = 'maintenancemode'), 'off')"; }
# shows LABEL VALUE...: none of the values is in the last run's output. The values are secrets: they are never
# printed, not even when the check fails.
shows() {
    local label="$1" value hit=0
    shift
    for value in "$@"; do
        [ -n "${value}" ] || continue
        if [[ "${out}" == *"${value}"* ]]; then hit=$((hit + 1)); fi
    done
    if [ "${hit}" -eq 0 ]; then ok "${label}"; else bad "${label}" "${hit} of the values that must stay out are in the output"; fi
}
# Secrets and personal data to look for at the end, collected as the run goes. Never printed.
keys_values=()
session_tokens=()
access_codes=()

# ---------------------------------------------------------------------------
section "0. The files, before any container"
# ---------------------------------------------------------------------------
scripts_dir="${ls_repo_root}/plugins/limesurvey/skills/limesurvey/scripts"
syntax=''
while IFS= read -r f; do
    bash -n "${f}" 2>> "${work}/syntax" || syntax+="${f##*/} "
done < <(find "${scripts_dir}" "${ls_repo_root}/plugins/limesurvey/install.sh" -name '*.sh' | sort)
is "every .sh file of the plugin parses (bash -n)" "" "${syntax}"
if command -v shellcheck > /dev/null; then
    lint="$(find "${scripts_dir}" "${ls_repo_root}/plugins/limesurvey/install.sh" -name '*.sh' -print0 | xargs -0 shellcheck -S warning 2>&1 | head -n 20)"
    is "shellcheck finds no warning in them" "" "${lint}"
fi
not_exec="$(find "${scripts_dir}" -maxdepth 1 -name '*.sh' ! -perm -u+x -printf '%f ')"
is "every script the assistant runs is executable" "" "${not_exec}"

echo
echo "Building the images and starting LimeSurvey (this can take a few minutes the first time) ..."
ls_stack_images || { echo "limesurvey-scripts: could not build the images" >&2; exit 1; }
ls_stack_down
ls_stack_up 1 || { echo "limesurvey-scripts: the stack did not start" >&2; exit 1; }
ls_stack_smtp || { echo "limesurvey-scripts: the mail sink did not start" >&2; exit 1; }
smtp_pw='Smtp-Pw-6gF1sD8kZq'
printf '{"op":"set-smtp","host":"%s:2525","user":"mailer@example.test","password":"%s"}' "${ls_smtp}" "${smtp_pw}" | helper 1 > /dev/null

php_lint="$(docker exec -i "$(ls_app 1)" sh -c 'for f in /opt/lss-test/remote/lib/*.php; do php -l "$f"; done' 2>&1 | grep -v '^No syntax errors' || true)"
docker cp -q "${scripts_dir}/remote" "$(ls_app 1):/opt/lss-test/remote-all"
php_lint+="$(docker exec -i "$(ls_app 1)" sh -c 'for f in /opt/lss-test/remote-all/*.php; do php -l "$f"; done' 2>&1 | grep -v '^No syntax errors' || true)"
is "every .php file of the plugin parses (php -l, in LimeSurvey's own PHP)" "" "${php_lint}"

docker cp -q "${ls_standin}/rc-policy-check.php" "$(ls_app 1):/opt/lss-test/rc-policy-check.php"
policy="$(docker exec -i "$(ls_app 1)" php /opt/lss-test/rc-policy-check.php /opt/lss-test/remote-all/lib/rc-policy.php 2>&1)"
is "the list of RemoteControl methods and the reply filter pass their own checks (rc-policy-check.php)" "rc-policy: all checks passed" "$(printf '%s\n' "${policy}" | tail -n 1)"
if [ "$(printf '%s\n' "${policy}" | tail -n 1)" != "rc-policy: all checks passed" ]; then printf '%s\n' "${policy}" | head -n 20 | sed 's/^/       | /'; fi

# Every start of a program in the containers is recorded with its arguments from here on, and every process list
# is sampled as well, until the end of the run.
ls_exec_log_install 1 || { echo "limesurvey-scripts: could not set up the record of program starts" >&2; exit 1; }
: > "${work}/sampling"
(while [ -e "${work}/sampling" ]; do for n in $(cat "${work}/stacks"); do ls_ps_snapshot "${n}" "${ps_log}"; done; sleep 0.15; done) &
sampler=$!
while IFS= read -r value; do keys_values+=("${value}"); done < <(ls_security_values 1)
if [ "${#keys_values[@]}" -ge 2 ]; then ok "the test knows the values of security.php it has to look for (${#keys_values[@]} of them)"; else bad "the test knows the values of security.php it has to look for (${#keys_values[@]} of them)"; fi

if [ "${LS_TEST_OFFLINE:-0}" = 1 ]; then
    echo "  skip install.sh on an agent without the packages (LS_TEST_OFFLINE=1: it needs the Ubuntu package archive)"
else
    # install.sh where the packages are missing: a plain Ubuntu 24.04, as the agent is, with nothing added.
    docker rm -f "${LS_TEST_PREFIX}install" > /dev/null 2>&1
    fresh="$(docker run --rm --name "${LS_TEST_PREFIX}install" --memory 1g -v "${ls_repo_root}/plugins/limesurvey:/clouve/skills/limesurvey/plugin:ro" ubuntu:24.04 \
        bash -c 'cd /clouve/skills/limesurvey/plugin && bash install.sh > /tmp/first 2>&1; echo "first=$?"; grep -c "installing missing packages" /tmp/first; for p in default-mysql-client openssh-client sshpass jq curl; do dpkg-query -W -f "\${Status}\n" "$p" 2> /dev/null | grep -c "^install ok installed$"; done | tr "\n" " "; echo; bash install.sh > /tmp/second 2>&1; echo "second=$?"; grep -c "already present" /tmp/second; command -v ssh sshpass jq curl mysql | wc -l' 2>&1 | tr '\n' ' ')"
    is "install.sh on an agent without the packages installs all five, and a second run finds them" "first=0 1 1 1 1 1 1  second=0 1 5 " "${fresh}"
fi

run 'cd /clouve/skills/limesurvey/plugin && sudo bash install.sh'
code "install.sh runs as root" 0
has "install.sh finds its packages on this agent and does not run apt-get" "already present"

# ---------------------------------------------------------------------------
section "1. run-in-limesurvey.sh"
# ---------------------------------------------------------------------------
run "$S/run-in-limesurvey.sh state.sh"
code "state.sh runs over the channel" 0
has "state.sh says the image's state folder is root's own" "clouve=ok"
has "state.sh says no install is under way" "install=none"
has "state.sh says the web server is Apache" "web_server=apache"
run "$S/run-in-limesurvey.sh"
code "no script is a usage error" 64
run "$S/run-in-limesurvey.sh nope.sh"
code "a name that is not in remote/ is refused" 64
run "$S/run-in-limesurvey.sh ../console.sh"
code "a path is refused" 64
run "$S/run-in-limesurvey.sh 'state.sh;id'"
code "a name with a shell character is refused" 64
run "env -u LIMESURVEY_HOST $S/run-in-limesurvey.sh state.sh"
code "without LIMESURVEY_HOST it stops" 1
has "and says which setting is missing" "LIMESURVEY_HOST is not set"
run "CLOUVE_OPS_PASSWORD=wrong-on-purpose $S/run-in-limesurvey.sh state.sh"
code "a wrong clouve-ops password is an ssh failure" 255
has "and the message names the target" "could not reach clouve-ops@$(ls_app 1)"
run "LIMESURVEY_HOST=no-such-host.invalid $S/run-in-limesurvey.sh state.sh"
code "a host that does not resolve is an ssh failure" 255

app_root 1 'touch /var/www/html/clouve/install-in-progress'
run "$S/rc.sh list_surveys"
code "while the image installs LimeSurvey, rc.sh refuses" 75
has "and says an install is under way" "is being installed"
run "$S/console.sh flushassets"
code "console.sh refuses too" 75
run "$S/run-in-limesurvey.sh backup.sh"
code "backup.sh refuses too" 75
run "$S/run-in-limesurvey.sh state.sh"
code "state.sh still runs" 0
has "and reports the install" "install=in-progress"
run "$S/upgrade-state.sh"
code "upgrade-state.sh says so with exit 2" 2
app_root 1 'rm /var/www/html/clouve/install-in-progress'

for phase in backup upgrade restore; do
    app_root 1 "install -d -m 700 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 && echo phase=${phase} > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state"
    run "$S/rc.sh list_surveys"
    code "while the image's upgrade is in phase ${phase}, rc.sh refuses" 75
    has "and names the phase" "phase ${phase}"
done
run "printf 'sid\n' | $S/participants.sh add --survey 1"
code "participants.sh refuses during an upgrade" 75
run "$S/temp-password.sh --create --email x@example.test busyuser"
code "temp-password.sh refuses during an upgrade" 75
run "ls ~/limesurvey-passwords 2> /dev/null | wc -l"
is "and leaves no password file" "0" "${out}"
app_root 1 'echo phase=failed > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/rc.sh list_surveys"
code "after a failed upgrade (the old version runs) the scripts work" 2
app_root 1 'echo done > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/rc.sh --whoami"
code "after a finished upgrade the scripts work" 0
app_root 1 'echo something-new > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/rc.sh --whoami"
code "a state word the skill does not know does not block a site whose web server is up" 0
app_root 1 'rm -rf /var/www/html/clouve/upgrade-6.16.1-to-7.10.0'

app_root 1 'install -d -m 700 /var/www/html/clouve/backups && echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
run "$S/rc.sh list_surveys"
code "while a restore is unfinished, rc.sh refuses" 75
has "and says a restore was started" "restore from a backup was started"
run "$S/run-in-limesurvey.sh backup.sh"
code "backup.sh refuses too" 75
run "$S/run-in-limesurvey.sh backup.sh --list"
code "backup.sh --list only reads, so it runs" 0
run "$S/run-in-limesurvey.sh restore.sh --last-log"
code "restore.sh --last-log only reads, so it runs" 0
run "$S/verify-health.sh"
code "verify-health.sh reports it as RED" 3
has "with the restore line" "[FAIL] restore"
app_root 1 'rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'

# The busy check, where the web server is not Apache: what the runner's start-up code decides, with the state
# files as they are and the web server's answer given (section 12 has the real thing, a container that waits for
# its database).
busy() { # WEB HOW: clv_busy_reason HOW with the web server reading as WEB; prints "free" or "busy: <sentence>"
    app_root 1 ". /opt/lss-test/remote-all/lib/state.sh; clv_web_server() { printf '%s' '$1'; }; if r=\$(clv_busy_reason '$2'); then echo \"busy: \$r\"; else echo free; fi"
}
is "with Apache up and nothing under way, a script that changes the site may run" "free" "$(busy apache all)"
out="$(busy standin all)"
has "while the image's stand-in page holds the port, a script that changes the site may not" "busy: The LimeSurvey container is still starting"
out="$(busy none restore-ok)"
has "nor may a restore, when no restore was begun" "busy: The LimeSurvey container is still starting"
out="$(busy standin repair)"
has "nor may the keys-only repair, while the container is only starting" "busy: The LimeSurvey container is still starting"
app_root 1 'install -d -m 700 /var/www/html/clouve/backups && echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
is "over the restore's own marker a restore may run, also while the stand-in page is up" "free" "$(busy standin restore-ok)"
out="$(busy standin all)"
has "and everything else is refused because of the restore" "busy: A restore from a backup was started"
app_root 1 'rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
# The image's waiting state: it keeps the stand-in page and the sshd up and waits for a repair.
app_root 1 'printf "reason=the code is 7.10.0 and the database is at version 631, and there is no backup to go back to\nsince=2026-11-12T20:41:07Z\nfrom=6.16.1\nto=7.10.0\nkind=repair\n" > /var/www/html/clouve/needs-attention; install -d -m 700 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 && echo phase=restore > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
out="$(busy standin all)"
has "while the image waits for a repair, a script that changes the site is refused" "busy: The LimeSurvey container is waiting for a repair"
has "with the image's reason" "the database is at version 631"
is "the keys-only repair may run there, although the upgrade's state still names a phase" "free" "$(busy standin repair)"
out="$(busy standin restore-ok)"
has "a new restore may not" "busy: The LimeSurvey container is waiting for a repair"
app_root 1 'echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
is "a restore over its own marker may" "free" "$(busy standin restore-ok)"
app_root 1 'rm -rf /var/www/html/clouve/upgrade-6.16.1-to-7.10.0'
is "with Apache up, an old note of the image's holds nothing back: what is refused is refused for the restore" "busy: A restore from a backup was started" "$(busy apache all | cut -c1-41)"
app_root 1 'rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
is "and once the restore's marker is gone, nothing is refused" "free" "$(busy apache all)"
app_root 1 'rm -f /var/www/html/clouve/needs-attention'
# The image's note as it writes it: reason, since, from, to and kind, one per line (ls_attention_note in the
# image's lib.sh). The state passes all five on.
state_as() { # WEB: clv_state with the web server reading as WEB
    app_root 1 ". /opt/lss-test/remote-all/lib/state.sh; clv_web_server() { printf '%s' '$1'; }; clv_state"
}
app_root 1 'printf "reason=the code is 7.10.0 and the database is at version 631, and there is no backup to go back to\nsince=2026-11-12T20:41:07Z\nfrom=7.10.0\nto=7.10.0\nkind=repair\n" > /var/www/html/clouve/needs-attention'
out="$(state_as standin)"
has "the state has the reason of the image's note" "waiting_reason=the code is 7.10.0 and the database is at version 631"
has "its kind" "waiting_kind=repair"
has "since when the image waits" "waiting_since=2026-11-12T20:41:07Z"
has "and the two versions" $'waiting_from=7.10.0\nwaiting_to=7.10.0'
# While the image waits for this skill's restore, its note has kind=restore.
app_root 1 'printf "reason=a restore from a backup is under way (the AI Assistant'"'"'s skill wrote /var/www/html/clouve/backups/RESTORE-IN-PROGRESS), so nothing is installed, upgraded or started.\nsince=2026-11-12T21:00:00Z\nfrom=7.10.0\nto=7.10.0\nkind=restore\n" > /var/www/html/clouve/needs-attention; echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
out="$(state_as standin)"
has "a note of kind restore over the restore's marker is a wait" "waiting=yes"
has "of kind restore" "waiting_kind=restore"
has "and an apostrophe in the image's reason stays" "the AI Assistant's skill wrote"
is "the restore may run over its marker" "free" "$(busy standin restore-ok)"
out="$(busy standin all)"
has "and everything else is refused because of the restore" "busy: A restore from a backup was started"
# The restore removes its marker when it is done, and the image sees that within seconds and goes on with its
# start. Until then its note is still there, and it no longer means that the container waits.
app_root 1 'rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
out="$(state_as standin)"
has "once the marker is gone, a note of kind restore no longer means that the container waits" "waiting=no"
out="$(busy standin all)"
has "a script is then refused because the container is starting" "busy: The LimeSurvey container is still starting"
hasnt "and not because it waits for a repair" "waiting for a repair"
app_root 1 'rm -f /var/www/html/clouve/needs-attention'
is "nothing is left in the container's /tmp after these runs" "0" "$(remote_leftovers)"

# ---------------------------------------------------------------------------
section "2. console.sh"
# ---------------------------------------------------------------------------
before="$(surveys)"
for cmd in 'wipe' 'wipe no' 'wipe yes' 'WIPE yes' 'demomode' 'demomode yes' 'install a b c d' 'installfromconfig' 'resetpassword admin Some-Pw-1' 'shell' 'updatedb' 'migrate' 'plugin cron' 'flushassets extra' 'setmaintenancemode' 'setmaintenancemode on' 'importsurvey /tmp/x.lsa' 'importsurvey relative.lss' '--failed-upgrade-playbook flushassets'; do
    run "$S/console.sh ${cmd}"
    code "console.sh ${cmd}: refused" 64
done
has "the refusal says why" "refused:"
run "$S/run-in-limesurvey.sh console.sh wipe yes"
code "wipe is refused inside the container too, when console.sh is skipped" 64
run "$S/run-in-limesurvey.sh console.sh install a b c d"
code "install is refused inside the container too" 64
run "$S/run-in-limesurvey.sh console.sh updatedb"
code "updatedb without the playbook's option is refused inside the container too" 64
is "no survey was touched by any of them" "${before}" "$(surveys)"
is "and the admin account is still there" "1" "$(db_sql 1 "select count(*) from lime_users where users_name = '${ls_admin_user}'")"
run "$S/console.sh flushassets"
code "flushassets runs" 0
run "$S/console.sh setmaintenancemode soft"
code "setmaintenancemode soft runs" 0
is "and LimeSurvey has the mode" "soft" "$(db_sql 1 "select stg_value from lime_settings_global where stg_name = 'maintenancemode'")"
run "$S/console.sh setmaintenancemode off"
is "and off puts it back" "off" "$(db_sql 1 "select stg_value from lime_settings_global where stg_name = 'maintenancemode'")"
run "$S/console.sh --failed-upgrade-playbook updatedb"
code "updatedb runs with the playbook's option" 0
has "and says the database is up to date" "up-to-date"
# A survey file in the container: the importer deletes what it reads, so console.sh gives it a copy.
docker cp -q "${ls_standin}/fixtures/draft.txt" "$(ls_app 1):/tmp/draft-in-container.txt"
app_root 1 'chown www-data:www-data /tmp/draft-in-container.txt'
run "$S/console.sh importsurvey /tmp/draft-in-container.txt"
code "importsurvey imports a file in the container" 0
console_sid="$(printf '%s\n' "${out}" | grep -E '^[0-9]+$' | tail -n 1)"
is "and the file is still there (a copy was imported)" "1" "$(app_root 1 'ls /tmp/draft-in-container.txt 2> /dev/null | wc -l')"
is "and the survey is inactive" "N" "$(db_sql 1 "select active from lime_surveys where sid = '${console_sid:-0}'")"
qorder() { db_sql 1 'select coalesce(sum(crc32(concat(qid, ":", question_order))), 0) from lime_questions'; }
order_before="$(qorder)"
run "$S/console.sh checkintegrity"
code "checkintegrity without --yes is refused: it changes data" 64
has "and the refusal says that it applies fixes without asking" "applies its fixes without asking"
run "$S/run-in-limesurvey.sh console.sh checkintegrity"
code "and inside the container too, when console.sh is skipped" 64
is "the order of the questions is as it was" "${order_before}" "$(qorder)"
run "$S/console.sh flushassets --yes"
code "--yes goes with checkintegrity only" 64
run "$S/console.sh checkintegrity --yes"
code "checkintegrity --yes runs" 0

# ---------------------------------------------------------------------------
section "3. rc.sh"
# ---------------------------------------------------------------------------
sessions_before="$(db_sql 1 'select count(*) from lime_sessions' 2> /dev/null || echo 0)"
login_before="$(printf '{"op":"last-login","user":"%s"}' "${ls_admin_user}" | helper 1)"
rpc_before="$(db_sql 1 "select count(*) from lime_settings_global where stg_name = 'RPCInterface'")"
run "$S/rc.sh --whoami"
code "--whoami runs" 0
has "the calls run as the site's main admin" "\"user\":\"${ls_admin_user}\""
has "on LimeSurvey 7.10.0" '"version":"7.10.0"'
has "with a public address for links" '"publicurl_set":true'
has "and RemoteControl stays off" '"rpcinterface":"off"'
run "$S/rc.sh --methods"
has "--methods lists the methods" '"list_surveys":'
run "$S/rc.sh list_surveys"
code "list_surveys runs with no parameters" 0
has "and finds the survey imported above" "\"sid\":${console_sid:-0}"
run "timeout 20 $S/rc.sh list_surveys < <(sleep 60)"
code "without --stdin it does not wait on an open stdin" 0
run "printf '%s' '{\"iSurveyID\": ${console_sid:-0}}' | $S/rc.sh --stdin list_groups"
code "parameters by name, on stdin" 0
has "reach the method" '"group_name":"About you"'
run "printf '%s' '[${console_sid:-0}]' | $S/rc.sh --stdin list_groups"
code "parameters as a list, on stdin" 0
run "printf '%s' '{\"iSurveyID\": 111}' | $S/rc.sh --stdin list_groups"
code "LimeSurvey's own refusal is exit 2" 2
has "with its error code in the reply" '"error_code":"ERR_INVALID_SURVEY"'
run "printf 'not json' | $S/rc.sh --stdin list_surveys"
code "parameters that are not JSON are a usage error" 64
run "$S/rc.sh no_such_method"
code "a method that is not on the skill's list is exit 1" 1
has "and the reply says so" "not on this skill's list"
run "$S/rc.sh --methods"
has "--methods says which methods are refused" '"refused (rc.sh does not run these)":'
has "and which need --yes" '"write (each needs rc.sh --yes'

# Refused whatever the options: each reply names the script that does the job, or says that the skill does not.
refused() { # METHOD PARAMS TEXT
    run "printf '%s' '$2' | $S/rc.sh --stdin $1"
    code "$1 is refused" 1
    has "$1: the reply names \"$3\"" "$3"
    run "printf '%s' '$2' | $S/rc.sh --yes --show-codes --stdin $1"
    code "$1 is refused with --yes too" 1
}
for method in invite_participants remind_participants mail_registered_participants; do
    refused "${method}" "[${console_sid:-0}]" "invitations.sh"
done
run "printf '%s' '{\"method\":\"invite_participants\",\"params\":[${console_sid:-0}],\"confirmed\":true}' | $S/run-in-limesurvey.sh --stdin ls-rc.php"
code "and inside the container, when rc.sh is skipped" 1
refused activate_survey "[${console_sid:-0}]" "survey-activate.sh"
for method in delete_survey delete_group delete_question delete_language delete_participants delete_response delete_quota; do
    refused "${method}" "[${console_sid:-0}, 1]" "delete.sh"
done
run "printf '%s' '{\"method\":\"delete_survey\",\"params\":[${console_sid:-0}],\"confirmed\":true}' | $S/run-in-limesurvey.sh --stdin ls-rc.php"
code "a delete is refused inside the container too, when rc.sh is skipped" 1
for method in export_responses export_responses_by_token export_statistics; do
    refused "${method}" "[${console_sid:-0}, \"csv\"]" "responses.sh"
done
refused get_uploaded_files "[${console_sid:-0}, \"x\"]" "Responses page"
for method in add_response update_response upload_file; do
    refused "${method}" "[${console_sid:-0}, {}]" "never writes"
done
for method in activate_tokens add_participants cpd_importParticipants; do
    refused "${method}" "[${console_sid:-0}, []]" "participants.sh"
done
refused import_survey '["UEsDBA==", "lsa"]' "survey-archive.sh"
refused import_survey '["UEsDBA==", "lss"]' "survey-import.sh"
refused get_session_key '["x", "y"]' "not needed"
run "$S/rc.sh --save-as x.pdf list_surveys"
code "--save-as is gone: rc.sh saves no files" 64
has "and the message names responses.sh" "responses.sh"

# Everything that changes the site needs --yes.
gid="$(db_sql 1 "select gid from lime_groups where sid = '${console_sid:-0}' order by gid limit 1")"
qid="$(db_sql 1 "select qid from lime_questions where sid = '${console_sid:-0}' and parent_qid = 0 order by qid limit 1")"
gated() { # METHOD PARAMS
    run "printf '%s' '$2' | $S/rc.sh --stdin $1"
    code "$1 without --yes is refused" 1
    has "$1: the reply asks for the admin's yes" "does not run without the admin's yes"
}
state_before="$(db_sql 1 "select concat_ws('|', (select count(*) from lime_surveys), (select count(*) from lime_groups), (select count(*) from lime_quota), (select coalesce(expires, 'none') from lime_surveys where sid = '${console_sid:-0}'), (select mandatory from lime_questions where qid = '${qid:-0}'))")"
gated set_survey_properties "[${console_sid:-0}, {\"expires\": \"2020-01-01 00:00:00\"}]"
gated set_language_properties "[${console_sid:-0}, {\"surveyls_endtext\": \"x\"}]"
gated set_group_properties "[${gid:-0}, {\"group_order\": 5}]"
gated set_question_properties "[${qid:-0}, {\"mandatory\": \"N\"}]"
gated add_group "[${console_sid:-0}, \"A new group\"]"
gated add_language "[${console_sid:-0}, \"de\"]"
gated add_quota "[${console_sid:-0}, \"q\", 5]"
gated set_quota_properties "[1, {\"qlimit\": 5}]"
gated add_survey "[555001, \"New\", \"en\"]"
gated copy_survey "[${console_sid:-0}, \"A copy\"]"
gated import_group "[${console_sid:-0}, \"eA==\", \"lsg\"]"
gated import_question "[${console_sid:-0}, ${gid:-0}, \"eA==\", \"lsq\"]"
is "none of them changed anything" "${state_before}" "$(db_sql 1 "select concat_ws('|', (select count(*) from lime_surveys), (select count(*) from lime_groups), (select count(*) from lime_quota), (select coalesce(expires, 'none') from lime_surveys where sid = '${console_sid:-0}'), (select mandatory from lime_questions where qid = '${qid:-0}'))")"
run "printf '%s' '{\"method\":\"set_survey_properties\",\"params\":[${console_sid:-0}, {\"expires\": \"2020-01-01 00:00:00\"}],\"confirmed\":\"yes\"}' | $S/run-in-limesurvey.sh --stdin ls-rc.php"
code "inside the container, \"confirmed\" as a word is not a yes" 1
run "printf '%s' '[${qid:-0}, {\"mandatory\": \"N\"}]' | $S/rc.sh --yes --stdin set_question_properties"
code "with --yes a change runs" 0
is "and LimeSurvey has it" "N" "$(db_sql 1 "select mandatory from lime_questions where qid = '${qid:-0}'")"

# No secret in any reply.
run "$S/rc.sh get_available_site_settings"
code "get_available_site_settings runs" 0
shows "its reply holds none of the values of security.php" "${keys_values[@]}"
hasnt "nor their names" '"encryption'
hasnt "nor the SMTP password's" "emailsmtppassword"
shows "nor the stored SMTP password" "$(db_sql 1 "select stg_value from lime_settings_global where stg_name = 'emailsmtppassword'")"
has "it names the settings rc.sh shows" '"sitename"'
for name in encryptionnonce encryptionsecretboxkey encryptionkeypair encryptionpublickey encryptionsecretkey emailsmtppassword defaultpass; do
    run "printf '%s' '{\"sSetttingName\":\"${name}\"}' | $S/rc.sh --stdin get_site_settings"
    code "get_site_settings ${name} is refused" 1
    shows "get_site_settings ${name}: no value of security.php is printed" "${keys_values[@]}"
done
has "the refusal says which settings rc.sh shows" "is not a setting rc.sh shows"
run "printf '%s' '{\"sSetttingName\":\"sitename\"}' | $S/rc.sh --stdin get_site_settings"
code "get_site_settings of a setting that holds no secret runs" 0
run "$S/rc.sh list_users"
code "list_users runs" 0
has "and lists the main admin" "\"users_name\":\"${ls_admin_user}\""
hasnt "without a session token" "session_token"
hasnt "without a password-link key" "validation_key"
hasnt "without a password hash" '"password"'

is "the survey is still there and inactive" "N" "$(db_sql 1 "select active from lime_surveys where sid = '${console_sid:-0}'")"
is "no session row was made" "${sessions_before}" "$(db_sql 1 'select count(*) from lime_sessions' 2> /dev/null || echo 0)"
is "the admin's last sign-in is unchanged" "${login_before}" "$(printf '{"op":"last-login","user":"%s"}' "${ls_admin_user}" | helper 1)"
is "the RPCInterface setting is unchanged" "${rpc_before}" "$(db_sql 1 "select count(*) from lime_settings_global where stg_name = 'RPCInterface'")"
is "no file under /var/www/html belongs to root" "0" "$(app_root 1 'find /var/www/html -xdev -user root ! -path "/var/www/html/clouve*" | wc -l')"

# delete.sh: a preview first, the delete only with the yes option.
run "$S/delete.sh survey --survey ${console_sid:-0}"
code "delete.sh without --yes-delete is a preview" 0
has "it says what would be deleted" "This would delete: survey ${console_sid:-0}"
has "and what goes with it" "2 groups and 4 questions"
has "and that nothing was deleted" "Nothing was deleted. This was the preview."
is "the survey is still there" "1" "$(db_sql 1 "select count(*) from lime_surveys where sid = '${console_sid:-0}'")"
run "printf '%s' '{\"action\":\"delete\",\"kind\":\"survey\",\"sid\":${console_sid:-0},\"confirmed\":\"true\"}' | $S/run-in-limesurvey.sh --stdin ls-change.php"
is "inside the container, \"confirmed\" as a word deletes nothing" "1" "$(db_sql 1 "select count(*) from lime_surveys where sid = '${console_sid:-0}'")"
run "$S/delete.sh question --question ${qid:-0}"
code "the preview of a question" 0
has "names the question by its code" "(fullname)"
run "$S/delete.sh question --question ${qid:-0} --yes-delete"
code "with --yes-delete, a question of a draft is deleted" 0
is "and it is gone" "0" "$(db_sql 1 "select count(*) from lime_questions where qid = '${qid:-0}'")"
run "$S/delete.sh group --survey ${console_sid:-0} --group ${gid:-0} --yes-delete"
code "and a group" 0
run "$S/delete.sh survey"
code "delete.sh survey without --survey is a usage error" 64
run "$S/delete.sh everything --yes-delete"
code "a kind delete.sh does not know is a usage error" 64
run "$S/delete.sh survey --survey 4242 --yes-delete"
code "a survey that is not there" 1
run "$S/delete.sh survey --survey ${console_sid:-0} --yes-delete"
code "with --yes-delete, the survey is deleted" 0
has "and the output says what went with it" "It took with it:"
is "and the survey is gone" "0" "$(db_sql 1 "select count(*) from lime_surveys where sid = '${console_sid:-0}'")"

# ---------------------------------------------------------------------------
section "4. survey-import.sh"
# ---------------------------------------------------------------------------
docker exec "$(ls_agent 1)" mkdir -p /tmp/files
for f in "${ls_standin}"/fixtures/*.txt; do docker cp -q "${f}" "$(ls_agent 1):/tmp/files/"; done
before="$(surveys)"
run "$S/survey-import.sh --check-only /tmp/files/draft.txt"
code "--check-only passes a good file" 0
has "and counts what it holds" "2 groups, 4 questions, 2 subquestions, 2 answer options"
is "and imports nothing" "${before}" "$(surveys)"
check_bad() { # FILE WHAT TEXT
    run "$S/survey-import.sh /tmp/files/$1"
    code "$2: refused" 2
    has "$2: the message" "$3"
}
check_bad bad-sq-ids.txt "subquestions that share an id" "needs an id that no other Q or SQ row has"
check_bad bad-no-sid.txt "no sid row" "there is no S row for sid"
check_bad bad-no-language.txt "no language row" "there is no S row for language"
check_bad bad-type.txt "an unknown question type" "is not a question type"
check_bad bad-code.txt "a question code with a space" "has to start with a letter"
check_bad bad-dup-code.txt "a question code used twice" "is already used on line"
check_bad bad-quote.txt "a cell that starts with a double quote" "starts with a double quote"
check_bad bad-no-answers.txt "a list question without answer options" "has no answer options"
check_bad bad-a-on-text.txt "answer options under a text question" "takes no answer options"
check_bad bad-header.txt "a header without the needed columns" "the header row lacks"
check_bad bad-extra-tab.txt "a row with more cells than the header" "A tab inside a text splits it"
check_bad bad-lang-type.txt "a translation with another question type" "A translation keeps the question's type"
check_bad bad-lang-dup-answer.txt "an answer code used twice in one language" "the answer code A1 is used twice in question heard"
is "none of the refused files was imported" "${before}" "$(surveys)"
# A survey in two languages: LimeSurvey's importer takes each of these layouts, so the checker has to as well, and
# each has to arrive as the same survey.
lang_sid=987021
for layout in lang-row-by-row lang-question-blocks lang-whole-file; do
    run "$S/survey-import.sh /tmp/files/${layout}.txt"
    code "${layout}: a survey in two languages is imported" 0
    has "${layout}: with the file's counts" "It has 1 groups, 2 questions, 2 subquestions and 2 answer options."
    is "${layout}: each question, subquestion and answer option has its text in both languages" "4 8 2 4" \
        "$(db_sql 1 "select concat_ws(' ', (select count(*) from lime_questions where sid = ${lang_sid}), (select count(*) from lime_question_l10ns l join lime_questions q on q.qid = l.qid where q.sid = ${lang_sid}), (select count(*) from lime_answers a join lime_questions q on q.qid = a.qid where q.sid = ${lang_sid}), (select count(*) from lime_answer_l10ns al join lime_answers a on a.aid = al.aid join lime_questions q on q.qid = a.qid where q.sid = ${lang_sid}))")"
    is "${layout}: the German text of the first question is the file's" "Wie haben Sie von uns erfahren?" \
        "$(db_sql 1 "select l.question from lime_question_l10ns l join lime_questions q on q.qid = l.qid where q.sid = ${lang_sid} and q.title = 'heard' and l.language = 'de'")"
    lang_sid=$((lang_sid + 1))
done
run "$S/survey-import.sh /tmp/files/draft.lsa"
code "an .lsa file is refused as a draft" 64
run "$S/survey-import.sh /tmp/files/draft.txt"
code "a good file is imported" 0
has "the output names the survey's id" "as survey 987002."
has "says it is inactive" "It is inactive (active = N in LimeSurvey)"
has "says a visitor gets 401" "gets HTTP 401"
has "gives the page to review it" "https://surveys.example.test/index.php/surveyAdministration/view?surveyid=987002"
has "gives the preview link" "https://surveys.example.test/index.php/987002?newtest=Y&lang=en"
has "passes the checker's warning on" "there is no end text"
is "LimeSurvey has it as inactive" "N" "$(db_sql 1 "select active from lime_surveys where sid = 987002")"
is "with the file's two subquestions" "2" "$(db_sql 1 "select count(*) from lime_questions where sid = 987002 and parent_qid > 0")"
is "the file on the agent is still there" "1" "$(agent 1 'ls /tmp/files/draft.txt | wc -l')"
run "$S/survey-import.sh /tmp/files/draft.txt"
code "the same file again gets another id" 0
has "and the output says the id was taken" "was taken, so LimeSurvey gave the survey the id"
run "$S/survey-info.sh 987002"
code "survey-info.sh shows the draft" 0
has "as inactive" "State: inactive"
has "with the sender its mails would carry" "Emails are sent as:"
run "$S/survey-info.sh 5"
code "survey-info.sh of a survey that is not there" 1

# ---------------------------------------------------------------------------
section "5. participants.sh"
# ---------------------------------------------------------------------------
run "$S/participants.sh count --survey 987002"
code "without a participant list, count stops" 1
has "and says how to make one" "create-list"
run "$S/participants.sh create-list --survey 987002"
code "create-list makes the list" 0
is "the survey is still inactive" "N" "$(db_sql 1 "select active from lime_surveys where sid = 987002")"
run "$S/participants.sh create-list --survey 987002"
has "a second create-list changes nothing" "already has a participant list"
run "printf 'firstname,lastname,email\nAda,Lovelace,ada@example.test\nAlan,Turing,alan@example.test\nNo,Mail,\nBad,Addr,not-an-address\nAda,Again,ADA@example.test\n' | $S/participants.sh add --survey 987002"
code "people from a CSV are added" 0
has "two are added, two skipped as invalid and one as a duplicate" "Added 2 of the people given. Skipped: 2 without a valid email address, 1 already on the list"
run "printf '%s' '[{\"firstname\":\"Grace\",\"lastname\":\"Hopper\",\"email\":\"grace@example.test\"}]' | $S/participants.sh add --survey 987002"
code "people from JSON are added" 0
has "the list has three people" "The list now has 3 people"
run "printf 'email\nada@example.test\n' | $S/participants.sh add --survey 987002"
code "a file whose people are all on the list adds nobody" 2
run "$S/participants.sh count --survey 987002"
has "count gives the numbers" "3 people on the list, 0 invited"
run "$S/participants.sh list --survey 987002"
code "list shows the people" 0
has "with their addresses" "grace@example.test"
tokens="$(db_sql 1 'select token from lime_tokens_987002')"
leaked=''
for token in ${tokens}; do [[ "${out}" != *"${token}"* ]] || leaked+="${token} "; done
is "and no access code" "" "${leaked}"
run "$S/participants.sh add --survey 987002 < /dev/null"
code "add with nothing on stdin is a usage error" 64
for token in ${tokens}; do access_codes+=("${token}"); done

# rc.sh on the list: access codes are hidden unless --show-codes asks for one, and a change needs --yes.
run "printf '%s' '{\"iSurveyID\": 987002, \"iStart\": 0, \"iLimit\": 10}' | $S/rc.sh --stdin list_participants"
code "rc.sh list_participants runs" 0
has "with each access code hidden" '"token":"(hidden)"'
shows "and none of them in the reply" "${access_codes[@]}"
run "printf '%s' '{\"iSurveyID\": 987002, \"aTokenQueryProperties\": {\"tid\": 1}, \"aTokenProperties\": [\"token\", \"emailstatus\"]}' | $S/rc.sh --stdin get_participant_properties"
has "get_participant_properties hides the code too" '"token":"(hidden)"'
# The one call that shows a code on purpose. Its output stays out of the transcript, and this code out of the
# search at the end.
shown_code="$(db_sql 1 'select token from lime_tokens_987002 where tid = 1')"
shown="$(agent 1 "printf '%s' '{\"iSurveyID\": 987002, \"aTokenQueryProperties\": {\"tid\": 1}, \"aTokenProperties\": [\"token\"]}' | $S/rc.sh --show-codes --stdin get_participant_properties" 2>&1)"
if [[ "${shown}" == *"\"token\":\"${shown_code}\""* ]]; then ok "with --show-codes the one person's code is in the reply"; else bad "with --show-codes the one person's code is in the reply"; fi
kept=()
for token in "${access_codes[@]}"; do [ "${token}" = "${shown_code}" ] || kept+=("${token}"); done
access_codes=("${kept[@]}")
run "printf '%s' '{\"iSurveyID\": 987002, \"aTokenQueryProperties\": {\"tid\": 2}, \"aTokenData\": {\"emailstatus\": \"bounced\"}}' | $S/rc.sh --stdin set_participant_properties"
code "set_participant_properties without --yes is refused" 1
is "and the person is as before" "OK" "$(db_sql 1 'select emailstatus from lime_tokens_987002 where tid = 2')"
run "printf '%s' '{\"iSurveyID\": 987002, \"aTokenQueryProperties\": {\"tid\": 2}, \"aTokenData\": {\"emailstatus\": \"bounced\"}}' | $S/rc.sh --yes --stdin set_participant_properties"
code "with --yes it runs" 0
is "the reply is a count and the field that was set" '{"result":{"changed":1,"tid":2,"fields":{"emailstatus":"bounced"}},"error":null}' "${out}"
shows "with no access code" "${access_codes[@]}" "${shown_code}"
hasnt "and no address" "@example.test"
run "printf '%s' '{\"iSurveyID\": 987002, \"aTokenQueryProperties\": {\"tid\": 2}, \"aTokenData\": {\"emailstatus\": \"OK\"}}' | $S/rc.sh --yes --stdin set_participant_properties"
is "the person's email status is back to OK" "OK" "$(db_sql 1 'select emailstatus from lime_tokens_987002 where tid = 2')"

# A survey that is active and open is not closed without a yes that says so.
open_sid="$(db_sql 1 "select sid from lime_surveys where sid not in (987002, 987021, 987022, 987023) order by sid desc limit 1")"
run "$S/survey-activate.sh ${open_sid}"
code "survey-activate.sh without --yes-activate is a preview" 0
has "it says who could answer" "ANYONE who has its address"
has "and that nothing was changed" "Nothing was changed. This was the preview."
is "the survey is still inactive" "N" "$(db_sql 1 "select active from lime_surveys where sid = ${open_sid}")"
run "printf '%s' '{\"action\":\"activate\",\"sid\":${open_sid},\"confirmed\":1}' | $S/run-in-limesurvey.sh --stdin ls-change.php"
is "inside the container, \"confirmed\" as a number activates nothing" "N" "$(db_sql 1 "select active from lime_surveys where sid = ${open_sid}")"
run "$S/survey-activate.sh ${open_sid} --yes-activate"
code "with --yes-activate the survey is activated" 0
has "and the output says people can answer it" "is ACTIVE now"
is "LimeSurvey has it as active" "Y" "$(db_sql 1 "select active from lime_surveys where sid = ${open_sid}")"
visitor() { docker exec "$(ls_app 1)" curl -s --max-time 15 "http://localhost:8080/index.php/$1?lang=en"; }
if [[ "$(visitor "${open_sid}")" != *"access code"* ]]; then ok "a visitor gets the open survey, with no question for an access code"; else bad "a visitor gets the open survey, with no question for an access code"; fi
run "$S/survey-activate.sh ${open_sid} --yes-activate"
code "activating a survey that is active already is refused" 2
run "$S/participants.sh create-list --survey ${open_sid}"
code "create-list on the active, open survey changes nothing" 2
has "it says the survey is active and open" "is ACTIVE and open"
has "and what a list would do" "closes it at once"
has "and names the option" "--yes-closes-the-open-survey"
is "no participant list was made" "0" "$(db_sql 1 "select count(*) from information_schema.tables where table_schema = database() and table_name = 'lime_tokens_${open_sid}'")"
run "printf '%s' '{\"action\":\"create-list\",\"sid\":${open_sid}}' | $S/run-in-limesurvey.sh --stdin ls-participants.php"
is "nor inside the container, when participants.sh is skipped" "0" "$(db_sql 1 "select count(*) from information_schema.tables where table_schema = database() and table_name = 'lime_tokens_${open_sid}'")"
if [[ "$(visitor "${open_sid}")" != *"access code"* ]]; then ok "the visitor still gets the survey"; else bad "the visitor still gets the survey"; fi
run "$S/participants.sh add --survey 987002 --yes-closes-the-open-survey < /dev/null"
code "the option goes with create-list only" 64
run "$S/participants.sh create-list --survey ${open_sid} --yes-closes-the-open-survey"
code "with --yes-closes-the-open-survey the list is made" 0
has "and the output says the survey is closed now" "CLOSED to everyone who is not on it"
if [[ "$(visitor "${open_sid}")" == *"access code"* ]]; then ok "the visitor is now asked for an access code"; else bad "the visitor is now asked for an access code"; fi
run "$S/delete.sh survey --survey ${open_sid}"
has "the preview of deleting an active survey says that it is active" "ACTIVE: people can answer it now"
run "$S/delete.sh group --survey ${open_sid} --group $(db_sql 1 "select gid from lime_groups where sid = ${open_sid} limit 1") --yes-delete"
code "a group of an active survey is not deleted" 2
has "because LimeSurvey does not take a group out of an active survey" "does not take a group out of an active survey"

# ---------------------------------------------------------------------------
section "6. invitations.sh and mail-settings.sh"
# ---------------------------------------------------------------------------
is "the mail sink starts empty" "0" "$(sink_count)"
run "$S/invitations.sh invite --survey 987002"
code "the preview of an inactive survey says it must not be sent" 2
has "because the survey is inactive" "the survey is inactive"
has "and that nothing was sent" "Nothing was sent."
run "$S/invitations.sh invite --survey 987002 --send --expect 3"
code "--send for an inactive survey is refused" 2
is "the sink is still empty" "0" "$(sink_count)"
run "printf '%s' '{\"action\":\"send\",\"kind\":\"invite\",\"sid\":987002,\"expect\":3}' | $S/run-in-limesurvey.sh --stdin ls-mail.php"
code "inside the container, a send request without \"send\": true is refused" 1
is "the sink is still empty" "0" "$(sink_count)"
run "$S/survey-activate.sh 987002 --yes-activate"
code "the survey is activated (survey-activate.sh --yes-activate)" 0
has "the output says who can answer" "only the 3 people on its participant list"
run "$S/invitations.sh invite --survey 987002"
code "the preview of the active survey" 0
has "shows the number of recipients" "Recipients: 3 people"
has "shows the sender the mail will carry" "From: Test Admin <admin@example.test>"
has "shows how it would be sent" "Sent through: smtp ($(printf '%s' "${ls_smtp}"):2525)"
has "says nothing was sent" "Nothing was sent. This was the preview."
has "and gives the option for the send" "--send --expect 3"
is "the preview sent nothing" "0" "$(sink_count)"
run "$S/invitations.sh invite --survey 987002 --send"
code "--send without --expect is a usage error" 64
run "$S/invitations.sh invite --survey 987002 --send --expect 2"
code "--send with a number the admin did not agree to is refused" 2
has "and says the number changed" "the admin agreed to 2 recipients and the list now gives 3"
is "the sink is still empty" "0" "$(sink_count)"
run "$S/invitations.sh invite --survey 987002 --send --expect 3"
code "--send with the right number sends" 0
has "and says how many went out" "Sent 3 invitations."
is "the sink has three mails" "3" "$(sink_count)"
mail="$(docker exec "${ls_smtp}" tail -n 1 /tmp/sink.jsonl)"
if [[ "${mail}" == *'"from":"Test Admin <admin@example.test>"'* ]]; then ok "each carries the survey's sender"; else bad "each carries the survey's sender" "${mail}"; fi
if [[ "${mail}" == *'https:\/\/surveys.example.test\/index.php\/987002?token='* ]]; then ok "and a link to the public address"; else bad "and a link to the public address" "${mail}"; fi
run "$S/invitations.sh invite --survey 987002"
has "a second preview finds nobody left to invite" "Recipients: 0 people"
run "$S/invitations.sh remind --survey 987002"
code "a reminder without --min-days must not be sent" 2
has "and says why" "needs a minimum gap of at least 1 day"
run "$S/invitations.sh remind --survey 987002 --min-days 0 --send --expect 3"
code "a reminder with a gap of 0 days is refused" 2
run "$S/invitations.sh remind --survey 987002 --min-days 1"
code "a reminder with a gap of a day" 0
has "finds nobody, minutes after the invitation" "Recipients: 0 people"
run "$S/invitations.sh remind --survey 987002 --min-days 1 --send --expect 0"
code "sending to nobody sends nothing" 0
is "the sink still has three mails" "3" "$(sink_count)"

# Reminders that are due. Two of the three were invited three days ago, one a minute ago: a reminder with a gap
# of two days goes to those two and to nobody else.
db_sql 1 "update lime_tokens_987002 set sent = date_format(utc_timestamp() - interval 3 day, '%Y-%m-%d %H:%i') where tid in (1, 2)"
run "$S/invitations.sh remind --survey 987002 --min-days 2"
code "the preview of a reminder with a gap of two days" 0
has "finds the two people who were invited three days ago" "Recipients: 2 people"
is "the preview sent nothing" "3" "$(sink_count)"
run "$S/invitations.sh remind --survey 987002 --min-days 2 --send --expect 2"
code "the reminder is sent" 0
has "to the two" "Sent 2 reminders."
is "the sink has exactly two more mails" "5" "$(sink_count)"
is "and both went to the people who were due" "ada@example.test alan@example.test" "$(docker exec "${ls_smtp}" tail -n 2 /tmp/sink.jsonl | grep -o '"rcpt_to":\["[^"]*"' | sed 's/"$//; s/.*"//; s/[<>]//g' | sort | tr '\n' ' ' | sed 's/ $//')"
is "LimeSurvey recorded one reminder for each of them, and none for the third" "1 1 0" "$(db_sql 1 'select remindercount from lime_tokens_987002 order by tid' | tr '\n' ' ' | sed 's/ $//')"
run "$S/invitations.sh remind --survey 987002 --min-days 2 --send --expect 2"
code "the same reminder a second time is refused: nobody is due any more" 2
is "and the sink has no more mails" "5" "$(sink_count)"
db_sql 1 "update lime_tokens_987002 set remindersent = date_format(utc_timestamp() - interval 3 day, '%Y-%m-%d %H:%i') where tid in (1, 2)"
run "$S/invitations.sh remind --survey 987002 --min-days 2 --max-reminders 2"
has "three days later the two are due again" "Recipients: 2 people"
run "$S/invitations.sh remind --survey 987002 --min-days 2 --max-reminders 1"
has "and --max-reminders 1 leaves them out, since each has had one" "Recipients: 0 people"
is "none of the previews sent anything" "5" "$(sink_count)"

# A send that needs more than one batch: LimeSurvey's batch size is 2, and five people are invited.
printf '{"op":"set-global","name":"maxemails","value":"2"}' | helper 1 > /dev/null
run "printf 'email\nb1@example.test\nb2@example.test\nb3@example.test\nb4@example.test\nb5@example.test\n' | $S/participants.sh add --survey 987002"
code "five more people are added" 0
run "$S/invitations.sh invite --survey 987002"
has "the preview shows the five" "Recipients: 5 people"
has "and the batch size" "2 per batch"
run "$S/invitations.sh invite --survey 987002 --send --expect 5"
code "the five invitations are sent, batch after batch" 0
has "all five" "Sent 5 invitations."
is "the sink has five more mails" "10" "$(sink_count)"
is "and all five are recorded as invited" "0" "$(db_sql 1 "select count(*) from lime_tokens_987002 where sent = 'N'")"
printf '{"op":"set-global","name":"maxemails","value":"50"}' | helper 1 > /dev/null

# An address LimeSurvey's mailer does not take. LimeSurvey drops such a person from the batch without a word, so
# the script has to say that somebody the admin agreed to was not mailed.
run "printf 'email\nc1@example.test\nc2@example.test\n' | $S/participants.sh add --survey 987002"
bad_tid="$(db_sql 1 "select tid from lime_tokens_987002 where email = 'c2@example.test'")"
db_sql 1 "update lime_tokens_987002 set email = 'someone at example' where tid = ${bad_tid:-0}"
run "$S/invitations.sh invite --survey 987002"
has "the preview counts both new people" "Recipients: 2 people"
run "$S/invitations.sh invite --survey 987002 --send --expect 2"
code "a send that leaves somebody out ends with exit 3" 3
has "it says how many went out" "Sent 1 invitations."
has "and that one of the two was not mailed" "1 of the 2 people were not mailed"
has "and names that person by the id on the list" "Their ids on the list: ${bad_tid:-none}."
is "the sink has one more mail" "11" "$(sink_count)"
db_sql 1 "update lime_tokens_987002 set emailstatus = 'bounced' where tid = ${bad_tid:-0}"
while IFS= read -r token; do access_codes+=("${token}"); done < <(db_sql 1 "select token from lime_tokens_987002 where token <> '${shown_code}'")
printf '{"op":"set-global","name":"emailmethod","value":"mail"}' | helper 1 > /dev/null
run "$S/invitations.sh remind --survey 987002 --min-days 1"
code "with LimeSurvey's email method \"mail\" nothing may be sent" 2
has "because the container has no sendmail" "needs a sendmail program"
printf '{"op":"set-global","name":"emailmethod","value":"smtp"}' | helper 1 > /dev/null

run "$S/mail-settings.sh show"
code "mail-settings.sh show" 0
has "shows the server" "SMTP server: ${ls_smtp}:2525"
has "says a password is stored" "SMTP password: stored"
hasnt "and never the password" "${smtp_pw}"
run "$S/mail-settings.sh test --to admin@example.test"
code "a test message without --send is a usage error" 64
is "and sends nothing" "11" "$(sink_count)"
run "$S/mail-settings.sh test --to admin@example.test --send"
code "a test message with --send" 0
has "is handed to the mail server" "was handed to the mail server"
hasnt "and its output holds no password" "${smtp_pw}"
is "the sink has it" "12" "$(sink_count)"

# ---------------------------------------------------------------------------
section "7. responses.sh"
# ---------------------------------------------------------------------------
run "$S/responses.sh summary --survey 987002"
code "a survey without answers has no summary" 1
has "and the message says so" "has no answers yet"
fields="$(agent 1 "printf '%s' '{\"surveyId\": 987002}' | $S/rc.sh --stdin get_fieldmap")"
col() { printf '%s' "${fields}" | docker exec -i "$(ls_agent 1)" jq -r --arg t "$1" --arg a "${2:-}" '.result | to_entries[] | select(.value.title == $t and .value.aid == $a) | .key' | head -n 1; }
q_name="$(col fullname)" q_rating="$(col rating)" q_sq1="$(col channels SQ001)" q_text="$(col comments)"
secret_answer='Secret-Answer-Text-771'
for data in "{\"${q_name}\":\"Ada Lovelace\",\"${q_rating}\":\"A1\",\"${q_sq1}\":\"Y\",\"${q_text}\":\"${secret_answer}\"}" "{\"${q_name}\":\"Alan Turing\",\"${q_rating}\":\"A1\"}" "{\"${q_name}\":\"Grace Hopper\",\"${q_rating}\":\"A2\"}"; do
    printf '{"op":"add-response","sid":987002,"data":%s}' "${data}" | helper 1 > /dev/null
done
run "$S/responses.sh summary --survey 987002"
code "the summary of three answer sets" 0
has "counts them" '"answer_sets": 3'
has "splits a choice question by answer" '"Good": 2'
hasnt "leaves out what people typed" "${secret_answer}"
hasnt "and their names" "Ada Lovelace"
run "$S/responses.sh summary --survey 987002 --with-text"
has "--with-text includes what people typed" "${secret_answer}"
run "$S/responses.sh export --survey 987002"
code "the export" 0
has "names a file in the Files pane" "limesurvey-exports/survey-987002-answers-"
hasnt "and prints no answer" "${secret_answer}"
run 'stat -c "%a" ~/limesurvey-exports ~/limesurvey-exports/*.csv | tr "\n" " "'
is "the folder is mode 700 and the file mode 600" "700 600 " "${out}"
run 'grep -c "Secret-Answer-Text-771" ~/limesurvey-exports/*.csv'
is "the file holds the answers" "1" "${out}"
run "$S/responses.sh export --survey 987002 --format xlsx && head -c 2 ~/limesurvey-exports/*.xlsx"
has "the Excel export is an .xlsx file" "PK"
run "$S/responses.sh export --survey 4242; ls ~/limesurvey-exports | wc -l"
has "an export that fails leaves no file" "2"
run "$S/responses.sh statistics --survey 987002"
code "responses.sh statistics" 0
has "names a file in the Files pane" "limesurvey-exports/survey-987002-statistics-"
run 'stat -c "%a" ~/limesurvey-exports/survey-987002-statistics-*.pdf; head -c 4 ~/limesurvey-exports/survey-987002-statistics-*.pdf'
is "the statistics report is a private PDF file" "600
%PDF" "${out}"
run "$S/responses.sh statistics --survey 987002 --format csv"
code "statistics in a format LimeSurvey has no report for is a usage error" 64
run "printf '%s' '{\"iSurveyID\": 987002, \"sDocumentType\": \"csv\"}' | $S/rc.sh --yes --stdin export_responses"
code "rc.sh does not export answers" 1
hasnt "and prints none" "${secret_answer}"
run "printf '%s' '{\"action\":\"export\",\"sid\":987002,\"save_to\":\"/var/www/html/upload/answers.csv\"}' | $S/run-in-limesurvey.sh --stdin ls-results.php > /dev/null; printf '%s' '{\"method\":\"export_responses\",\"params\":[987002,\"csv\"],\"confirmed\":true,\"save_to\":\"/var/www/html/upload/answers.csv\"}' | $S/run-in-limesurvey.sh --stdin ls-rc.php; printf '%s' '{\"method\":\"export_responses\",\"params\":[987002,\"csv\"],\"confirmed\":true,\"raw\":true}' | $S/run-in-limesurvey.sh --stdin ls-rc.php"
is "no request can have an export written inside the container" "0" "$(app_root 1 'ls /var/www/html/upload/answers.csv 2> /dev/null | wc -l')"
hasnt "and that request prints no answer either" "${secret_answer}"

# A column the summary cannot place, and an equation: what they hold can be anything a person typed, so it is
# shown only with --with-text.
run "$S/survey-import.sh /tmp/files/equation.txt && $S/survey-activate.sh 987030 --yes-activate"
code "a survey with an equation question is imported and activated" 0
eq_fields="$(agent 1 "printf '%s' '{\"surveyId\": 987030}' | $S/rc.sh --stdin get_fieldmap")"
eq_col() { printf '%s' "${eq_fields}" | docker exec -i "$(ls_agent 1)" jq -r --arg t "$1" '.result | to_entries[] | select(.value.title == $t) | .key' | head -n 1; }
typed='Typed-Into-An-Equation-442'
printf '{"op":"add-response","sid":987030,"data":{"%s":"someone","%s":"%s"}}' "$(eq_col nick)" "$(eq_col echoed)" "${typed}" | helper 1 > /dev/null
run "$S/responses.sh summary --survey 987030"
code "its summary" 0
has "counts the answer set" '"answer_sets": 1'
hasnt "and does not show the equation's value" "${typed}"
run "$S/responses.sh summary --survey 987030 --with-text"
has "--with-text shows it" "${typed}"
is "nothing is left in LimeSurvey's tmp folder" "0" "$(app_root 1 'find /var/www/html/tmp -maxdepth 1 -type f ! -name index.html | wc -l')"

# ---------------------------------------------------------------------------
section "8. temp-password.sh and admin-users.sh"
# ---------------------------------------------------------------------------
run "$S/admin-users.sh list"
code "list" 0
has "names the main admin" "The site's main admin is ${ls_admin_user}."
run "$S/temp-password.sh --create --email jane@example.test --full-name 'Jane Doe' jane"
code "a new account gets a temporary password" 0
has "the one line names the file" "Saved the temporary password for jane to limesurvey-passwords/jane-"
run 'stat -c "%a" ~/limesurvey-passwords ~/limesurvey-passwords/jane-*.txt | tr "\n" " "'
is "the folder is mode 700 and the file mode 600" "700 600 " "${out}"
jane_pw="$(agent 1 'sed -n "/^Temporary password:/{n;p}" ~/limesurvey-passwords/jane-*.txt')"
is "the file holds a 20-character password" "20" "${#jane_pw}"
if grep -qF "${jane_pw}" "${transcript}"; then bad "the password is in no output of any script"; else ok "the password is in no output of any script"; fi
is "and it signs the account in" '{"result":true,"error":null}' "$(printf '{"op":"password-ok","user":"jane","password":"%s"}' "${jane_pw}" | helper 1)"
run "$S/temp-password.sh --create --email other@example.test jane"
code "creating an account that exists is refused" 2
run "$S/temp-password.sh --create --email jane@example.test jane2"
code "an email address that another account has is refused" 2
has "with LimeSurvey's reason" "already used by another user"
run "$S/temp-password.sh --create jane3"
code "--create without --email is a usage error" 64
run "$S/temp-password.sh ${ls_admin_user}"
code "the main admin's password is not reset here" 2
has "and the message points to the playbook" "regain-admin-access.md"
run "$S/temp-password.sh nobody"
code "an account that is not there is not reset" 2
run 'ls ~/limesurvey-passwords | wc -l'
is "the refused runs left no file" "1" "${out}"
run "$S/temp-password.sh jane"
code "a reset gives a new password" 0
jane_pw2="$(agent 1 'for f in $(ls -t ~/limesurvey-passwords/jane-*.txt | head -n 1); do sed -n "/^Temporary password:/{n;p}" "$f"; done')"
is "the new one signs in" '{"result":true,"error":null}' "$(printf '{"op":"password-ok","user":"jane","password":"%s"}' "${jane_pw2}" | helper 1)"
is "and the old one no longer does" '{"result":false,"error":null}' "$(printf '{"op":"password-ok","user":"jane","password":"%s"}' "${jane_pw}" | helper 1)"
run "$S/temp-password.sh --remove /etc/passwd"
code "--remove of a file outside the folder is refused" 64
run "$S/temp-password.sh --remove \"\$(ls ~/limesurvey-passwords | head -n 1)\" && ls ~/limesurvey-passwords | wc -l"
has "--remove deletes a password file" "1"

run "$S/admin-users.sh grant jane --survey 987002 --role results"
code "a role on one survey" 0
run "$S/admin-users.sh show jane"
has "show lists it" "On survey 987002: "
has "with reading and exporting answers" "responses (read export)"
hasnt "and not editing questions" "surveycontent"
run "$S/admin-users.sh grant jane --survey 987002 --role none && $S/admin-users.sh show jane"
hasnt "the role none takes the survey away" "On survey 987002"
run "$S/admin-users.sh grant jane --create-surveys"
has "may create surveys" "may create surveys"
run "$S/admin-users.sh grant ${ls_admin_user} --no-superadmin"
code "the main admin keeps the superadmin permission" 1
run "$S/admin-users.sh deactivate ${ls_admin_user}"
code "the main admin cannot be switched off" 1
run "$S/admin-users.sh deactivate jane"
has "an account can be switched off" "switched off"
run "$S/admin-users.sh activate jane"
has "and on again" "active"
run "$S/admin-users.sh set-password jane < /dev/null"
code "set-password with nothing on stdin is a usage error" 64
run 'printf "%s\n" "${LIMESURVEY_ADMIN_PASSWORD:-$(clv-secret LIMESURVEY_ADMIN_PASSWORD)}" | '"$S"'/admin-users.sh set-password "${LIMESURVEY_ADMIN_USER}"'
code "the main admin's password is set from the dashboard's, on stdin" 0
hasnt "without showing it" "${ls_admin_pw}"
is "and it signs the admin in" '{"result":true,"error":null}' "$(printf '{"op":"password-ok","user":"%s","password":"%s"}' "${ls_admin_user}" "${ls_admin_pw}" | helper 1)"
run "$S/admin-users.sh clear-lockouts"
code "clear-lockouts" 0

# A role this does not know must leave the account's permissions as they are, also when admin-users.sh is skipped.
run "$S/admin-users.sh grant jane --survey 987002 --role results"
perms() { db_sql 1 "select count(*) from lime_permissions p join lime_users u on u.uid = p.uid where u.users_name = 'jane' and p.entity = 'survey' and p.entity_id = 987002"; }
perms_before="$(perms)"
run "printf '%s' '{\"action\":\"grant\",\"login\":\"jane\",\"sid\":987002,\"role\":\"viewer\"}' | $S/run-in-limesurvey.sh --stdin ls-users.php"
code "a grant with a role that does not exist is refused" 1
has "and the reply names the roles" "the role is full, editor, results or none"
is "and the account keeps the role it had" "${perms_before}" "$(perms)"
if [ "${perms_before}" -gt 0 ]; then ok "which was a real role (${perms_before} permissions)"; else bad "which was a real role (${perms_before} permissions)"; fi

# The accounts' session tokens, which LimeSurvey's list_users gives out and rc.sh must not.
while IFS= read -r value; do [ -z "${value}" ] || session_tokens+=("${value}"); done < <(db_sql 1 "select session_token from lime_users where session_token is not null and session_token <> ''"; db_sql 1 "select validation_key from lime_users where validation_key is not null and validation_key <> ''")
if [ "${#session_tokens[@]}" -ge 1 ]; then ok "at least one account has a session token to look for (${#session_tokens[@]})"; else bad "at least one account has a session token to look for"; fi
run "$S/rc.sh list_users"
code "rc.sh list_users, now that accounts have session tokens" 0
has "lists jane" '"users_name":"jane"'
shows "and no account's session token or password-link key" "${session_tokens[@]}"

# A reply that is lost. The connection drops after LimeSurvey has made the account and before its answer arrives:
# the password is in force, so the file that holds it has to stay.
docker exec -i -u root "$(ls_agent 1)" sh -c 'cp /usr/local/sbin/ssh /usr/local/sbin/ssh.lss-kept && cat > /usr/local/sbin/ssh && chmod 755 /usr/local/sbin/ssh && rm -f /tmp/lss-ssh-calls' <<'SSH'
#!/bin/sh
# tests only: the second ssh call of a run does its work and then reports a lost connection
echo x >> /tmp/lss-ssh-calls
if [ "$(wc -l < /tmp/lss-ssh-calls)" -eq 2 ]; then
    /usr/bin/ssh "$@" > /dev/null 2>&1
    exit 255
fi
exec /usr/bin/ssh "$@"
SSH
run "$S/temp-password.sh --create --email lost@example.test lostreply"
docker exec -u root "$(ls_agent 1)" sh -c 'mv -f /usr/local/sbin/ssh.lss-kept /usr/local/sbin/ssh; rm -f /tmp/lss-ssh-calls'
code "when the reply is lost, temp-password.sh ends with exit 255" 255
has "it says that the password may or may not be set" "no telling whether the password was set"
has "and that the file was kept" "was KEPT"
is "LimeSurvey did make the account" "1" "$(db_sql 1 "select count(*) from lime_users where users_name = 'lostreply'")"
lost_pw="$(agent 1 'sed -n "/^Temporary password:/{n;p}" ~/limesurvey-passwords/lostreply-*.txt 2> /dev/null')"
is "the kept file holds a password" "20" "${#lost_pw}"
is "and it is the one that signs the account in" '{"result":true,"error":null}' "$(printf '{"op":"password-ok","user":"lostreply","password":"%s"}' "${lost_pw}" | helper 1)"
run "$S/temp-password.sh --create --email nobody@example.test busy2"
has "a run with a working connection is not affected by the test's own change" "Saved the temporary password for busy2"
busy2_pw="$(agent 1 'sed -n "/^Temporary password:/{n;p}" ~/limesurvey-passwords/busy2-*.txt 2> /dev/null')"

# ---------------------------------------------------------------------------
section "9. extensions.sh"
# ---------------------------------------------------------------------------
docker cp -q "${ls_standin}/fixtures/LssGoodPlugin" "$(ls_app 1):/var/www/html/upload/plugins/"
docker cp -q "${ls_standin}/fixtures/LssOldPlugin" "$(ls_app 1):/var/www/html/plugins/"
docker cp -q "${ls_standin}/fixtures/lss_test_theme" "$(ls_app 1):/var/www/html/upload/themes/survey/"
docker cp -q "${ls_standin}/fixtures/lss_old_theme" "$(ls_app 1):/var/www/html/upload/themes/survey/"
app_root 1 'chown -R www-data:www-data /var/www/html/upload /var/www/html/plugins/LssOldPlugin'
run "$S/extensions.sh plugins"
code "plugins lists them" 0
has "with a folder LimeSurvey has not registered" "LssGoodPlugin"
has "and one that is not compatible" "NOT compatible with this LimeSurvey"
run "$S/extensions.sh plugin-activate LssOldPlugin"
code "a plugin that does not list LimeSurvey 7 is refused" 1
has "and the message says why" "does not list this major version"
is "and it is not registered" "0" "$(db_sql 1 "select count(*) from lime_plugins where name = 'LssOldPlugin'")"
run "$S/extensions.sh plugin-activate LssGoodPlugin"
code "a compatible plugin is switched on" 0
is "LimeSurvey has it on" "1" "$(db_sql 1 "select active from lime_plugins where name = 'LssGoodPlugin'")"
run "$S/extensions.sh plugin-activate Nope"
code "a plugin with no folder is refused" 1
run "$S/extensions.sh plugin-activate '../x'"
code "a name that is a path is a usage error" 64
# What an upgrade leaves: every added plugin off, and the image's list of the ones that were on.
db_sql 1 "update lime_plugins set active = 0 where name = 'LssGoodPlugin'"
app_root 1 'install -d -m 700 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 && echo done > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state && printf "LssGoodPlugin\n" > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/active-plugins && chmod 600 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/*'
run "$S/extensions.sh plugins-off-after-upgrade"
code "plugins-off-after-upgrade" 0
has "names the plugin that was on before" "LssGoodPlugin	upload	was on before the upgrade	can be switched on"
run "$S/extensions.sh plugin-deactivate LssGoodPlugin"
has "switching off a plugin that is off changes nothing" "Nothing changed"
run "$S/extensions.sh themes"
has "themes lists a folder that is not registered" "lss_test_theme	in upload/themes/survey, not registered yet"
run "$S/extensions.sh theme-register lss_old_theme"
code "a theme that does not list LimeSurvey 7 is refused" 1
run "$S/extensions.sh theme-register nothere"
code "a theme with no folder is refused" 1
run "$S/extensions.sh theme-register lss_test_theme"
code "a compatible theme is registered" 0
is "LimeSurvey has it" "1" "$(db_sql 1 "select count(*) from lime_templates where name = 'lss_test_theme'")"

# ---------------------------------------------------------------------------
section "10. survey-archive.sh"
# ---------------------------------------------------------------------------
run "$S/survey-archive.sh export --survey 987002 --format lss"
code "an .lss export" 0
run "$S/survey-archive.sh export --survey 987002 --format lsa"
code "an .lsa export" 0
has "warns that it holds answers and participants" "holds the survey's answers and participants"
run 'stat -c "%a" ~/limesurvey-exports/survey-987002-*.lsa; unzip -l ~/limesurvey-exports/survey-987002-*.lsa | grep -c -e "\.lss" -e "\.lsr" -e "\.lst"'
is "the archive is private and holds the structure, the answers and the participants" "600
3" "${out}"
before="$(surveys)"
run "$S/survey-archive.sh import ~/limesurvey-exports/survey-987002-*.lsa"
code "an .lsa import without the option is refused" 64
has "and says the survey would be activated" "activates the survey"
is "and imports nothing" "${before}" "$(surveys)"
run "$S/survey-archive.sh import ~/limesurvey-exports/survey-987002-*.lss"
code "an .lss import" 0
has "arrives inactive" "State: inactive"
run "$S/survey-archive.sh import --yes-activates-the-survey ~/limesurvey-exports/survey-987002-*.lsa"
code "an .lsa import with the option" 0
has "arrives active" "State: ACTIVE"
has "with its participants" "Participants: 10"
has "and its answers" "Answers: 3"
archive_sid="$(printf '%s\n' "${out}" | sed -n 's/^Imported .* as survey \([0-9]*\)\.$/\1/p' | head -n 1)"
# An archive export that fails half way must leave nothing in LimeSurvey's tmp/, which the web server serves: the
# half-written parts can hold answers. The copy's answer table is taken away to make the export fail.
tmp_files() { app_root 1 'find /var/www/html/tmp -maxdepth 1 -type f ! -name index.html | wc -l'; }
tmp_before="$(tmp_files)"
db_sql 1 "drop table lime_responses_${archive_sid:-0}"
run "$S/survey-archive.sh export --survey ${archive_sid:-0} --format lsa"
code "an .lsa export that fails half way ends with exit 1" 1
is "and leaves no file in LimeSurvey's tmp/" "${tmp_before}" "$(tmp_files)"
run "ls ~/limesurvey-exports/survey-${archive_sid:-0}-* 2> /dev/null | wc -l"
is "and none in the Files pane" "0" "${out}"
run "$S/delete.sh survey --survey ${archive_sid:-0} --yes-delete"
run "$S/survey-archive.sh export --survey 4242 --format lss; ls ~/limesurvey-exports/survey-4242-* 2> /dev/null | wc -l"
has "an export of a survey that is not there leaves no file" "0"

run "$S/crm-link.sh status"
code "crm-link.sh on a LimeSurvey without the Customer Kit's SuiteCRM plugin" 1
has "says that the plugin is not there" "the SuiteCRM plugin is not registered"
run "$S/crm-link.sh map --question 1 --field 'Leads first_name'"
code "crm-link.sh map with a field that is not Module:field is a usage error" 64
run "$S/crm-link.sh map --question 1 --field Leads:first_name"
code "crm-link.sh map changes nothing without the plugin" 1
is "and writes no mapping" "0" "$(db_sql 1 "select count(*) from lime_question_attributes where attribute = 'suitecrm_mappings_json'")"

# crm-link.sh map with the plugin there: a module the plugin does not write to and a field SuiteCRM does not have
# are refused before anything is stored. The plugin here is a stand-in with the real one's names and tables and
# no SuiteCRM behind it (fixtures/SuiteCRMIntegration). The real image ships the real plugin, which needs a
# SuiteCRM to name its fields, so there only the module is tried.
mapped() { db_sql 1 "select coalesce((select value from lime_question_attributes a join lime_questions q on q.qid = a.qid where q.sid = 987002 and a.attribute = 'suitecrm_mappings_json' limit 1), 'none')"; }
crm_qid="$(db_sql 1 "select qid from lime_questions where sid = 987002 and title = 'fullname'")"
if app_root 1 'test -e /clouve/limesurvey/package/plugins/SuiteCRMIntegration'; then
    crm=real
    run "$S/extensions.sh plugin-activate SuiteCRMIntegration"
    code "the image's own SuiteCRM plugin is switched on" 0
else
    crm=standin
    docker cp -q "${ls_standin}/fixtures/SuiteCRMIntegration" "$(ls_app 1):/var/www/html/plugins/"
    app_root 1 'chown -R www-data:www-data /var/www/html/plugins/SuiteCRMIntegration'
    run "$S/extensions.sh plugin-activate SuiteCRMIntegration"
    code "a stand-in for the SuiteCRM plugin is switched on" 0
fi
run "$S/crm-link.sh status"
code "crm-link.sh status, with the plugin there" 0
has "says the plugin is on" "SuiteCRM plugin: on"
run "$S/crm-link.sh map --question ${crm_qid} --field Leeds:nope"
code "a module the plugin does not write to is refused" 1
has "the refusal names the modules it writes to" "It writes to: Leads, Cases"
has "and says that nothing was stored" "Nothing was stored"
is "and nothing was" "none" "$(mapped)"
run "$S/crm-link.sh map --question ${crm_qid} --field Leads:first_name --field Accounts:name"
code "one module that is not on the list refuses the whole mapping" 1
is "and nothing was stored" "none" "$(mapped)"
if [ "${crm}" = standin ]; then
    run "$S/crm-link.sh map --question ${crm_qid} --field Leads:nope"
    code "a field SuiteCRM does not have for the module is refused" 1
    has "the refusal names the fields it has" "Its fields: account_name, description, email1, first_name, last_name, phone_work"
    is "and nothing was stored" "none" "$(mapped)"
    run "$S/crm-link.sh map --question ${crm_qid} --field Leads:first_name --field Cases:description"
    code "fields that are there are mapped" 0
    has "the output names them" "now fills: Leads: first_name, Cases: description"
    has "and says the plugin's own table was written" "The plugin's own table: updated."
    is "the mapping is on the question, with the label and the type SuiteCRM gives the field" '[{"module":"Leads","field":"first_name","label":"First Name","type":"varchar","transformRule":""},{"module":"Cases","field":"description","label":"Description","type":"text","transformRule":""}]' "$(mapped)"
    is "and in the plugin's own table" "2" "$(db_sql 1 "select count(*) from lime_survey_crm_mappings where question_id = ${crm_qid}")"
    app_root 1 'touch /var/www/html/plugins/suitecrm-down'
    run "$S/crm-link.sh map --question ${crm_qid} --field Leads:last_name"
    code "while SuiteCRM does not answer, a field cannot be checked, so the mapping is refused" 1
    has "and the message says why" "could not be read from SuiteCRM"
    if [[ "$(mapped)" == *'"field":"first_name"'* ]]; then ok "and the mapping that was there stays"; else bad "and the mapping that was there stays" "$(mapped)"; fi
    app_root 1 'rm -f /var/www/html/plugins/suitecrm-down'
    run "$S/crm-link.sh unmap --question ${crm_qid}"
    code "unmap clears the mapping" 0
    is "on the question" "[]" "$(mapped)"
    is "and in the plugin's own table" "0" "$(db_sql 1 "select count(*) from lime_survey_crm_mappings where question_id = ${crm_qid}")"
else
    run "$S/crm-link.sh map --question ${crm_qid} --field Leads:first_name"
    code "with no SuiteCRM to name the fields, a field cannot be checked, so the mapping is refused" 1
    has "and the message says why" "could not be read from SuiteCRM"
    is "and nothing was stored" "none" "$(mapped)"
fi
# The plugin goes again, so that the rest of this test runs on a LimeSurvey on its own.
run "$S/extensions.sh plugin-deactivate SuiteCRMIntegration"
db_sql 1 "delete from lime_plugin_settings where plugin_id in (select id from lime_plugins where name = 'SuiteCRMIntegration'); delete from lime_plugins where name = 'SuiteCRMIntegration'; delete from lime_question_attributes where attribute = 'suitecrm_mappings_json'; drop table if exists lime_survey_crm_mappings; drop table if exists lime_survey_crm_sync_log"
[ "${crm}" = real ] || app_root 1 'rm -rf /var/www/html/plugins/SuiteCRMIntegration'

# ---------------------------------------------------------------------------
section "11. upgrade-state.sh"
# ---------------------------------------------------------------------------
run "$S/upgrade-state.sh"
code "a finished upgrade with its backup kept" 0
has "names the folder" "clouve/upgrade-6.16.1-to-7.10.0"
has "and the command that removes it" "upgrade-state.sh --remove-kept-backup upgrade-6.16.1-to-7.10.0 --yes"
run "$S/upgrade-state.sh --remove-kept-backup upgrade-6.16.1-to-7.10.0"
code "removing it without --yes is refused" 64
is "and the folder stays" "1" "$(app_root 1 'ls -d /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 | wc -l')"
run "$S/upgrade-state.sh --remove-kept-backup ../backups --yes"
code "a name that is not an upgrade folder is refused" 64
app_root 1 'echo phase=failed > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/upgrade-state.sh"
code "a failed upgrade is exit 3" 3
has "and the output says the old version was put back" "FAILED, and the image put the old version back"
run "$S/upgrade-state.sh --remove-kept-backup upgrade-6.16.1-to-7.10.0 --yes"
code "the folder of a failed upgrade is not removed" 1
run "$S/verify-health.sh"
has "verify-health.sh reports the failed upgrade" "[FAIL] upgrade"
app_root 1 'printf "step=copying\nphase=upgrade\nfrom=6.16.1\nto=7.10.0\n" > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/upgrade-state.sh"
code "an upgrade under way is exit 2" 2
has "and the output names the phase and the image's step" "in phase upgrade, step copying"
app_root 1 'echo done > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state'
run "$S/upgrade-state.sh --remove-kept-backup upgrade-6.16.1-to-7.10.0 --yes"
code "with --yes the kept backup of a finished upgrade is removed" 0
is "and the folder is gone" "0" "$(app_root 1 'ls -d /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 2> /dev/null | wc -l')"
run "$S/upgrade-state.sh"
has "then nothing is kept" "no upgrade backup is kept"

# An upgrade the image gave up on before it had made a folder: only its note is there, with the versions and
# the reason, and the reason is what staff need.
app_root 1 'printf "build=7.10.0+261109-abc123\nfrom=6.16.1\nto=7.10.0\nwhen=2026-11-12T20:41:07Z\nbackup=\nreason=the dump of the database could not be written twice in a row\n" > /var/www/html/clouve/upgrade-failed'
run "$S/upgrade-state.sh"
code "a failed upgrade without a folder is exit 3" 3
has "the output names the versions from the image's note" "The upgrade from LimeSurvey 6.16.1 to 7.10.0 FAILED"
has "and the image's reason" "The image's reason: the dump of the database could not be written twice in a row"
run "$S/verify-health.sh"
has "verify-health.sh names the versions too" "[FAIL] upgrade: the upgrade from 6.16.1 to 7.10.0 failed"
has "and the reason" "the dump of the database could not be written twice in a row"
run "$S/rc.sh --whoami"
code "the scripts work meanwhile: the old version runs" 0
app_root 1 'rm -f /var/www/html/clouve/upgrade-failed'

# An upgrade the image did not try.
app_root 1 'printf "reason=the volume has 212 MB free and the upgrade needs 1100 MB\nfrom=6.16.1\nto=7.10.0\nwhen=2026-11-12T20:41:07Z\n" > /var/www/html/clouve/upgrade-skipped'
run "$S/upgrade-state.sh"
code "an upgrade that was not tried is exit 0: the site runs" 0
has "the output says the image did not try it" "did NOT try the upgrade from LimeSurvey 6.16.1 to 7.10.0"
has "with the image's reason" "The image's reason: the volume has 212 MB free and the upgrade needs 1100 MB"
has "and that the old version runs" "The site runs the old version"
hasnt "and not that nothing is going on" "No install or upgrade is under way"
run "$S/verify-health.sh"
has "verify-health.sh warns about it, with the reason" "[WARN] upgrade: the image did not try the upgrade from 6.16.1 to 7.10.0"
app_root 1 'rm -f /var/www/html/clouve/upgrade-skipped'

# A folder the image moved aside because it stood in the place of its state folder and was not root's.
app_root 1 'install -d -o www-data -g www-data -m 755 /var/www/html/clouve.untrusted-20261112T204107Z'
run "$S/upgrade-state.sh"
has "upgrade-state.sh names a folder the image moved aside" "clouve.untrusted-20261112T204107Z"
has "and says that putting it back is a step for Clouve support" "a step for Clouve support, not for you"
run "$S/verify-health.sh"
has "verify-health.sh names it too" "[WARN] clouve: the image moved aside"
app_root 1 'rmdir /var/www/html/clouve.untrusted-20261112T204107Z'

# ---------------------------------------------------------------------------
section "12. backup.sh and verify-health.sh"
# ---------------------------------------------------------------------------
run "$S/verify-health.sh"
code "before any backup the report is AMBER" 2
has "because there is no backup yet" "[WARN] backups"
hasnt "and nothing fails" "[FAIL]"
app_root 1 'mkdir -p /var/www/html/upload/surveys/987002/files && echo uploaded-by-a-participant > /var/www/html/upload/surveys/987002/files/fu_test && head -c 300000 /dev/urandom > /var/www/html/upload/surveys/987002/files/fu_big && chown -R www-data:www-data /var/www/html/upload/surveys'
run "$S/run-in-limesurvey.sh backup.sh"
code "backup.sh makes a backup" 0
has "under maintenance mode" "maintenance mode on (hard-cli)"
has "and puts the mode back" "maintenance mode back to off"
backup="$(printf '%s\n' "${out}" | sed -n 's/.*done: \([0-9]\{8\}-[0-9]\{6\}\) .*/\1/p')"
if [[ "${backup}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then ok "the last line names the backup"; else bad "the last line names the backup" "${out}"; fi
is "LimeSurvey is out of maintenance mode" "off" "$(db_sql 1 "select stg_value from lime_settings_global where stg_name = 'maintenancemode'")"
is "the backup folder is root's, mode 700, and its files mode 600" "root 700 600 600 600 600 600 600 " "$(app_root 1 "cd /var/www/html/clouve/backups && stat -c '%U %a' ${backup} | tr '\n' ' ' && stat -c '%a' ${backup}/* | tr '\n' ' '")"
is "its checksums match" "0" "$(app_root 1 "cd /var/www/html/clouve/backups/${backup} && sha256sum -c --quiet SHA256SUMS > /dev/null 2>&1; echo \$?")"
is "it holds security.php" "1" "$(app_root 1 "tar -tzf /var/www/html/clouve/backups/${backup}/config.tar.gz | grep -c security.php")"
is "it holds the participant's uploaded file" "1" "$(app_root 1 "tar -tzf /var/www/html/clouve/backups/${backup}/upload.tar.gz | grep -c fu_test")"
is "it holds the plugin that was added by hand, and not the ones LimeSurvey ships" "plugins/LssOldPlugin/" "$(app_root 1 "tar -tzf /var/www/html/clouve/backups/${backup}/plugins.tar.gz | grep -E '^plugins/[^/]+/\$' | tr '\n' ' ' | sed 's/ \$//'")"
is "the image's state folder and the backups folder are root's own, mode 700" "root 700 root 700 " "$(app_root 1 "stat -c '%U %a' /var/www/html/clouve /var/www/html/clouve/backups | tr '\n' ' '")"
is "the web server does not serve the backup" "403" "$(docker exec "$(ls_app 1)" curl -s -o /dev/null -w '%{http_code}' "http://localhost:8080/clouve/backups/${backup}/database.sql.gz")"
# A file anyone may read, in a folder anyone may enter, next to the state folder's name: only the web server's
# own rule for clouve/ can keep that one back, so this check fails when the rule is gone.
app_root 1 'install -d -m 755 /var/www/html/clouve/served-check && echo x > /var/www/html/clouve/served-check/version && chmod 644 /var/www/html/clouve/served-check/version && chmod 755 /var/www/html/clouve'
is "nor a file under clouve/ that everyone could read" "403" "$(docker exec "$(ls_app 1)" curl -s -o /dev/null -w '%{http_code}' "http://localhost:8080/clouve/served-check/version")"
app_root 1 'chmod 700 /var/www/html/clouve && rm -rf /var/www/html/clouve/served-check'
is "the backup recorded how many answer sets the site had" "4" "$(app_root 1 "sed -n 's/.*\"answer_sets\": *\([0-9]*\).*/\1/p' /var/www/html/clouve/backups/${backup}/manifest.json")"
run "$S/run-in-limesurvey.sh backup.sh --list"
has "--list shows it" "${backup}"
run "$S/run-in-limesurvey.sh backup.sh --delete ${backup}"
code "--delete without the yes option is refused" 1
run "$S/run-in-limesurvey.sh backup.sh --delete ../../upload --yes-delete-this-backup"
code "--delete of a name that is no backup is refused" 1
run "$S/verify-health.sh"
code "with a backup the report is GREEN" 0
has "the keys read the encrypted SMTP password" "[OK]   keys: the encryption keys read"
has "the database answers from the agent" "[OK]   database from the agent"

# A folder that is not root's own is never read, listed, restored from or written to, and never "repaired".
# The web server's user owns /var/www/html, so it can plant things there. Each case is put there by the test.
state_all() { db_sql 1 "select concat_ws('|', (select count(*) from lime_surveys), (select count(*) from lime_users), (select count(*) from lime_responses_987002), (select count(*) from information_schema.tables where table_schema = database()))"; }
site_before="$(state_all)"
refuses_untrusted() { # WHAT
    run "$S/run-in-limesurvey.sh backup.sh --list"
    code "$1: backup.sh --list stops" 1
    has "$1: and says the folder is not root's own" "does not belong to root"
    run "$S/run-in-limesurvey.sh backup.sh"
    code "$1: backup.sh makes no backup" 1
    run "$S/run-in-limesurvey.sh restore.sh --backup ${backup}"
    code "$1: restore.sh does not look at the backup" 1
    run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data --skip-safety-backup"
    code "$1: restore.sh restores nothing" 1
    run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup} --yes-replace-the-keys"
    code "$1: nor the keys" 1
    run "$S/backup-copy.sh pull ${backup}"
    code "$1: backup-copy.sh pull copies nothing out" 1
    run "$S/backup-copy.sh push ${pushed}"
    code "$1: backup-copy.sh push puts nothing in" 1
    is "$1: the site is as it was" "${site_before}" "$(state_all)"
    is "$1: and out of maintenance mode" "off" "$(maintenance 1)"
}
# A backup in the Files pane to push: the real one under another name.
run "$S/backup-copy.sh pull ${backup}"
pushed=20200101-000000
run "cp -a ~/limesurvey-backups/${backup} ~/limesurvey-backups/${pushed} && rm -rf ~/limesurvey-backups/${backup}"

# 1. A link in the place of clouve/backups, pointing at a folder off the volume.
app_root 1 'install -d -m 755 /opt/lss-target && mv /var/www/html/clouve/backups /var/www/html/clouve/backups.aside && ln -s /opt/lss-target /var/www/html/clouve/backups'
refuses_untrusted "a link at clouve/backups"
is "a link at clouve/backups: nothing was written where it points, and that folder's mode is as it was" "755 0" "$(app_root 1 'stat -c %a /opt/lss-target | tr "\n" " "; ls -A /opt/lss-target | wc -l')"
run "$S/verify-health.sh"
has "a link at clouve/backups: verify-health.sh reports it" "[FAIL] backups"
app_root 1 'rm /var/www/html/clouve/backups && mv /var/www/html/clouve/backups.aside /var/www/html/clouve/backups && rmdir /opt/lss-target'

# 2. A folder of the web server's user in the place of clouve/backups, holding a copy of a real backup.
app_root 1 "mv /var/www/html/clouve/backups /var/www/html/clouve/backups.aside && cp -a /var/www/html/clouve/backups.aside /var/www/html/clouve/backups && chown -R www-data:www-data /var/www/html/clouve/backups"
refuses_untrusted "a planted folder at clouve/backups"
is "a planted folder at clouve/backups: it was not made root's" "www-data www-data" "$(app_root 1 "stat -c %U /var/www/html/clouve/backups /var/www/html/clouve/backups/${backup} | tr '\n' ' ' | sed 's/ \$//'")"
app_root 1 'rm -rf /var/www/html/clouve/backups && mv /var/www/html/clouve/backups.aside /var/www/html/clouve/backups'

# 3. The state folder itself moved aside, and one of the web server's user in its place, with backups in it.
app_root 1 "mv /var/www/html/clouve /var/www/html/clouve.real && install -d -o www-data -g www-data -m 755 /var/www/html/clouve && cp -a /var/www/html/clouve.real/backups /var/www/html/clouve/backups && chown -R root:root /var/www/html/clouve/backups && touch /var/www/html/clouve/install-in-progress"
refuses_untrusted "the state folder renamed aside and replaced"
run "$S/run-in-limesurvey.sh state.sh"
has "the state folder renamed aside and replaced: state.sh says the folder is not trusted" "clouve=untrusted"
has "and reads no state from it" "install=none"
run "$S/verify-health.sh"
has "verify-health.sh fails on the folder" "[FAIL] clouve"
run "$S/upgrade-state.sh"
code "upgrade-state.sh ends with exit 4" 4
has "and says that nothing in the folder is read" "Nothing in it is read"
run "$S/upgrade-state.sh --remove-kept-backup upgrade-6.16.1-to-7.10.0 --yes"
code "nothing is removed from such a folder" 1
is "the planted folder is still the web server's user's: nothing made it root's" "www-data" "$(app_root 1 'stat -c %U /var/www/html/clouve')"
app_root 1 'rm -rf /var/www/html/clouve && mv /var/www/html/clouve.real /var/www/html/clouve'

# 4. A folder of the web server's user among the backups.
app_root 1 "cp -a /var/www/html/clouve/backups/${backup} /var/www/html/clouve/backups/20200202-020202 && chown -R www-data:www-data /var/www/html/clouve/backups/20200202-020202"
run "$S/run-in-limesurvey.sh backup.sh --list"
has "a backup folder that is not root's is listed as such" "20200202-020202  NOT A FOLDER OF ROOT"
run "$S/run-in-limesurvey.sh restore.sh --backup 20200202-020202 --yes-replace-current-data --skip-safety-backup"
code "and is not restored" 1
has "because it does not belong to root" "does not belong to root"
run "$S/backup-copy.sh pull 20200202-020202"
code "nor copied out" 1
is "the site is as it was" "${site_before}" "$(state_all)"
app_root 1 'rm -rf /var/www/html/clouve/backups/20200202-020202'
run "$S/run-in-limesurvey.sh backup.sh --list"
code "with the real folders back, backup.sh --list works again" 0
has "and shows the backup" "${backup}"

# A volume without room: the space check comes before anything is written or locked. The container's df is
# replaced for this one run by one that reports a full volume.
app_root 1 'cat > /usr/local/sbin/df.lss-full && chmod 755 /usr/local/sbin/df.lss-full && mv /usr/local/sbin/df.lss-full /usr/local/sbin/df' <<'DF'
#!/bin/sh
# tests only: every volume is full
echo "Filesystem 1-blocks Used Available Capacity Mounted on"
echo "/dev/full 1000000000 999990000 10000 100% /var/www/html"
DF
run "$S/run-in-limesurvey.sh backup.sh"
code "with no room on the volume, backup.sh ends with exit 3" 3
has "it gives both numbers" "not enough space for a backup: it needs about"
has "and says that nothing was written" "Nothing was written"
is "no half-made folder is left, and no note" "0" "$(app_root 1 'ls -A /var/www/html/clouve/backups | grep -c -e "^\.making" -e "^\.maintenance"')"
is "and LimeSurvey was not locked" "off" "$(maintenance 1)"
app_root 1 'rm -f /usr/local/sbin/df'

# Only the keys, from a backup. With the right keys in place there is nothing to do, and it says so.
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup}"
code "restore.sh --keys-only, when the keys in place read the data, changes nothing" 2
has "and says that they stay" "already read the data, so they stay"

# A site whose security.php is gone: nothing may start LimeSurvey, or it makes new keys.
app_root 1 'mv /var/www/html/application/config/security.php /root/security.php.kept'
run "$S/rc.sh list_surveys"
code "without security.php, rc.sh does not start LimeSurvey" 1
has "and says the keys are missing" "security.php is missing"
run "$S/console.sh flushassets"
code "nor does console.sh" 1
run "$S/run-in-limesurvey.sh backup.sh"
code "nor does backup.sh" 1
run "$S/verify-health.sh"
code "verify-health.sh is RED" 3
has "with the security.php line" "[FAIL] security.php"
has "and it does not ask the web server, which would make LimeSurvey start" "[WARN] web: not asked"
has "and it points to the keys-only way back" "Only the keys are missing or wrong"
run "$S/run-in-limesurvey.sh backup.sh"
has "backup.sh points to the keys-only way back too, not to a restore that needs a backup first" "restore.sh --keys-only --backup"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "a full restore is still held back by the missing safety backup" 1
has "and it names the keys-only way too" "restore.sh --keys-only --backup"
is "and no new security.php was made by any of them" "0" "$(app_root 1 'ls /var/www/html/application/config/security.php 2> /dev/null | wc -l')"
# The way back: only security.php, from the backup, after its keys were tested against the database.
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup}"
code "restore.sh --keys-only without the yes option is a preview" 0
has "it says that the backup's keys read the data" "its keys read what the database holds encrypted"
has "and that nothing else would change" "no table and no file in upload/ changes"
is "and it puts no file in place" "0" "$(app_root 1 'ls /var/www/html/application/config/security.php 2> /dev/null | wc -l')"
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup} --yes-replace-current-data"
code "the full restore's yes does not go with --keys-only" 1
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup} --yes-replace-the-keys"
code "with --yes-replace-the-keys the keys are put back" 0
is "security.php is the original again, www-data's, mode 600" "$(app_root 1 'sha256sum < /root/security.php.kept') www-data 600" "$(app_root 1 'sha256sum < /var/www/html/application/config/security.php; stat -c "%U %a" /var/www/html/application/config/security.php' | tr '\n' ' ' | sed 's/ $//')"
is "the site's data was not touched" "${site_before}" "$(state_all)"
run "$S/verify-health.sh"
hasnt "verify-health.sh finds nothing failing" "[FAIL]"
has "and the keys read the data" "[OK]   keys: the encryption keys read"

# Other keys in place, as after LimeSurvey made new ones: the keys line fails, and the keys-only way puts the
# original back and keeps the file that was there.
app_root 1 'cd /var/www/html/application/config && sed -E "s/([0-9a-f]{16})([0-9a-f]{16,})/\2\1/" security.php > security.php.other && chown www-data:www-data security.php.other && chmod 600 security.php.other && mv -f security.php.other security.php'
if [ "$(app_root 1 'sha256sum < /var/www/html/application/config/security.php')" != "$(app_root 1 'sha256sum < /root/security.php.kept')" ]; then ok "the site now has other keys than its data was encrypted with"; else bad "the site now has other keys than its data was encrypted with"; fi
while IFS= read -r value; do keys_values+=("${value}"); done < <(ls_security_values 1)
run "$S/verify-health.sh"
code "verify-health.sh is RED" 3
has "with the keys line" "[FAIL] keys"
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup} --yes-replace-the-keys"
code "the keys-only way puts the original keys back" 0
has "and says where the file that was there is kept" "before-restore-"
is "security.php is the original again" "$(app_root 1 'sha256sum < /root/security.php.kept')" "$(app_root 1 'sha256sum < /var/www/html/application/config/security.php')"
is "the file with the other keys is kept, for root only" "600" "$(app_root 1 'stat -c %a /var/www/html/clouve/backups/before-restore-*/security.php | tail -n 1')"
run "$S/verify-health.sh"
has "the keys read the data again" "[OK]   keys: the encryption keys read"
app_root 1 'rm -f /root/security.php.kept'

docker stop "$(ls_db 1)" > /dev/null
run "$S/verify-health.sh"
code "with the database stopped the report is RED" 3
has "with the database line" "[FAIL] database"

# A container that is still starting: its sshd is up, its web server is not, and it waits for its database. The
# state files say nothing yet, and still nothing may run against the site.
docker restart "$(ls_app 1)" > /dev/null
ls_wait 60 docker exec "$(ls_agent 1)" bash -c "(exec 3<>/dev/tcp/$(ls_app 1)/22) 2>/dev/null"
sleep 3
run "$S/run-in-limesurvey.sh state.sh"
code "in a container that waits for its database, state.sh runs" 0
hasnt "and says the web server is not Apache" "web_server=apache"
for cmd in "rc.sh --whoami" "console.sh flushassets" "run-in-limesurvey.sh backup.sh" "survey-info.sh 987002" "run-in-limesurvey.sh restore.sh --backup ${backup}"; do
    run "$S/${cmd}"
    code "${cmd%% *}: refused while the container is starting" 75
done
has "the refusal says that the container is still starting" "is still starting"
run "$S/run-in-limesurvey.sh backup.sh --list"
code "backup.sh --list still runs" 0
run "$S/upgrade-state.sh"
code "upgrade-state.sh says so with exit 2" 2
has "and explains the stand-in page" "still starting"
run "$S/verify-health.sh"
has "verify-health.sh warns that the container is starting" "[WARN] starting"
has "and shows that the database does not answer" "database"

# The image's waiting state: the start could not go on, the image left its note and waits for a repair, with its
# sshd up and no web server of LimeSurvey's. This container is in the same position, so the note is put there.
app_root 1 'printf "reason=the way back from the failed upgrade failed, and the code and the database do not belong together\nsince=2026-11-12T20:41:07Z\nfrom=6.16.1\nto=7.10.0\nkind=repair\n" > /var/www/html/clouve/needs-attention'
run "$S/upgrade-state.sh"
code "a container that waits for a repair: upgrade-state.sh is exit 4" 4
has "the output says it is waiting" "WAITING FOR A REPAIR"
has "gives the image's reason" "the way back from the failed upgrade failed"
has "since when it waits, from the image's note" "since 2026-11-12T20:41:07Z"
has "and the versions the note names" "LimeSurvey 6.16.1 on the volume, 7.10.0 in the image"
has "says how the Clouve dashboard shows it" "shows as running"
has "and that the way out is Clouve's" "contact Clouve support"
run "$S/verify-health.sh"
has "verify-health.sh fails on it" "[FAIL] waiting"
has "with the image's reason" "the way back from the failed upgrade failed"
has "and since when it waits" "since 2026-11-12T20:41:07Z"
run "$S/rc.sh --whoami"
code "rc.sh is refused there" 75
has "and the refusal says that the container waits for a repair" "is waiting for a repair"
run "$S/run-in-limesurvey.sh backup.sh"
code "and so is a backup" 75
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "and a new restore" 75
run "$S/run-in-limesurvey.sh backup.sh --list"
code "the list of backups still runs" 0
run "$S/run-in-limesurvey.sh restore.sh --last-log"
code "and the restore's log" 0
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${backup}"
if [ "${rc}" -ne 75 ]; then ok "the keys-only repair is let through (here it stops at the database, which is down: exit ${rc})"; else bad "the keys-only repair is let through" "${out}"; fi
# The image can wait with its upgrade's state still at upgrade or restore. Its note is what tells that stop from
# an upgrade that is under way.
app_root 1 'install -d -m 700 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 && printf "phase=restore\nrstep=moving-back\nstep=updating\nmaint=off\nfrom=6.16.1\nto=7.10.0\n" > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state && echo since=2026-11-12T20:40:00Z > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/db-touched'
run "$S/upgrade-state.sh"
code "waiting with the upgrade's state at restore is exit 4, not an upgrade under way" 4
has "the output says where the upgrade stopped" "in phase restore, step moving-back"
has "and that the database has not been put back" "the dump from before it has not been loaded back"
hasnt "and not that an upgrade is under way" "is under way"
run "$S/rc.sh --whoami"
code "rc.sh is refused there" 75
has "as waiting for a repair" "is waiting for a repair"
hasnt "and not as being upgraded" "is being upgraded right now"
app_root 1 'rm -f /var/www/html/clouve/needs-attention'
run "$S/upgrade-state.sh"
code "without the image's note the same state is an upgrade under way: exit 2" 2
has "with its phase and step" "is under way, in phase restore, step moving-back"
run "$S/rc.sh --whoami"
code "and rc.sh is refused" 75
has "because LimeSurvey is being upgraded" "is being upgraded right now"
app_root 1 'rm -rf /var/www/html/clouve/upgrade-6.16.1-to-7.10.0'
app_root 1 'echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS; rm -f /var/www/html/clouve/needs-attention'
run "$S/upgrade-state.sh"
code "a container that waits for an unfinished restore is exit 4 too" 4
has "and the way out is to run the restore again" "Run the same restore again"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
if [ "${rc}" -ne 75 ]; then ok "there the restore is let through, to be finished (here it stops at the database, which is down: exit ${rc})"; else bad "there the restore is let through, to be finished" "${out}"; fi
# The image writes its own note for that wait, with kind=restore. With the marker it is a wait for the restore.
app_root 1 'printf "reason=a restore from a backup is under way (the AI Assistant'"'"'s skill wrote /var/www/html/clouve/backups/RESTORE-IN-PROGRESS), so nothing is installed, upgraded or started.\nsince=2026-11-12T21:00:00Z\nfrom=7.10.0\nto=7.10.0\nkind=restore\n" > /var/www/html/clouve/needs-attention; echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
run "$S/upgrade-state.sh"
code "with the image's note of the wait for a restore, upgrade-state.sh is exit 4" 4
has "the output gives the image's reason" "a restore from a backup is under way"
has "the way out is to run the restore again" "Run the same restore again"
hasnt "and not Clouve support" "contact Clouve support"
# Once the restore has removed its marker, the image goes on within seconds. Its note is still there until then.
app_root 1 'rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
run "$S/upgrade-state.sh"
code "once the restore's marker is gone, that note is no wait: the container is starting" 2
hasnt "it is not reported as waiting for a repair" "WAITING FOR A REPAIR"
hasnt "and nobody is sent to Clouve support" "contact Clouve support"
run "$S/verify-health.sh"
has "verify-health.sh warns that the container is starting" "[WARN] starting"
hasnt "and does not fail on waiting" "[FAIL] waiting"
app_root 1 'rm -f /var/www/html/clouve/needs-attention'
docker start "$(ls_db 1)" > /dev/null
ls_wait 60 docker exec -e MYSQL_PWD="${ls_db_pw}" "$(ls_db 1)" mariadb -u limesurvey limesurvey -e 'select 1'
ls_wait 300 ls_app_answers "$(ls_app 1)" || bad "LimeSurvey came up again once its database was back"
run "$S/rc.sh --whoami"
code "once LimeSurvey is up again, the scripts run" 0

# ---------------------------------------------------------------------------
section "13. restore.sh, onto another deployment with empty volumes"
# ---------------------------------------------------------------------------
ls_stack_up 2 || { echo "limesurvey-scripts: the second stack did not start" >&2; exit 1; }
ls_exec_log_install 2 || { echo "limesurvey-scripts: could not set up the record of program starts in the second stack" >&2; exit 1; }
echo "1 2" > "${work}/stacks"
while IFS= read -r value; do keys_values+=("${value}"); done < <(ls_security_values 2)
# The keys line of the health report. A new site has nothing encrypted to try the keys on. In the Customer Kit
# the SuiteCRM plugin stores its passwords encrypted, and those count.
stack=2
run "$S/verify-health.sh"
has "on a new site, verify-health.sh says that nothing encrypted is stored yet" "[OK]   keys: nothing encrypted is stored yet"
printf '{"op":"plugin-secret","value":"Crm-Pw-3fH7kQ2xLm"}' | helper 2 > /dev/null
run "$S/verify-health.sh"
has "with a password of the SuiteCRM plugin stored, it tests the keys against that" "[OK]   keys: the encryption keys read what the database holds encrypted"
docker exec -u www-data "$(ls_app 2)" sh -c 'cd /var/www/html/application/config && cp -p security.php /tmp/lss-security.kept && sed -E "s/([0-9a-f]{16})([0-9a-f]{16,})/\2\1/" /tmp/lss-security.kept > security.php'
while IFS= read -r value; do keys_values+=("${value}"); done < <(ls_security_values 2)
run "$S/verify-health.sh"
has "and with other keys in place it says that they do not read it" "[FAIL] keys"
docker exec -u www-data "$(ls_app 2)" sh -c 'cd /var/www/html/application/config && cat /tmp/lss-security.kept > security.php && rm -f /tmp/lss-security.kept'
db_sql 2 "delete from lime_plugin_settings where plugin_id in (select id from lime_plugins where name = 'SuiteCRMIntegration'); delete from lime_plugins where name = 'SuiteCRMIntegration' and active = 0"
stack=1
keys_1="$(app_root 1 'sha256sum < /var/www/html/application/config/security.php')"
keys_2="$(docker exec -u root "$(ls_app 2)" sh -c 'sha256sum < /var/www/html/application/config/security.php')"
if [ "${keys_1}" != "${keys_2}" ]; then ok "the new deployment has encryption keys of its own"; else bad "the new deployment has encryption keys of its own"; fi
run "$S/backup-copy.sh pull ${backup}"
code "backup-copy.sh pull brings the backup to the Files pane" 0
run "stat -c '%a' ~/limesurvey-backups ~/limesurvey-backups/${backup}/database.sql.gz | tr '\n' ' '"
is "as a private folder and files" "700 600 " "${out}"
run "$S/backup-copy.sh pull ${backup}"
code "a second pull of the same name is refused" 1
# What the admin does by hand: download the folder from one deployment's Files pane, upload it to the other's.
docker exec "$(ls_agent 2)" sh -c 'umask 077 && mkdir -p ~/limesurvey-backups'
docker exec "$(ls_agent 1)" sh -c 'tar -cf - -C ~/limesurvey-backups .' | docker exec -i "$(ls_agent 2)" sh -c 'tar -xf - -C ~/limesurvey-backups'
stack=2
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup}"
code "restore.sh of a backup that is not in the container" 1
run "$S/backup-copy.sh push ${backup}"
code "backup-copy.sh push puts it into the new deployment's container" 0
run "$S/backup-copy.sh push ${backup}"
code "a second push of the same name is refused" 1
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup}"
code "without a backup of the current state, restore.sh stops" 1
has "and asks for one" "Take one first"
has "and names the option for a site with nothing worth keeping" "--skip-safety-backup"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "also with the yes option" 1
is "and has changed nothing" "0" "$(db_sql 2 'select count(*) from lime_surveys')"
run "$S/run-in-limesurvey.sh backup.sh"
code "a backup of the new deployment's current state" 0
own_backup="$(printf '%s\n' "${out}" | sed -n 's/.*done: \([0-9]\{8\}-[0-9]\{6\}\) .*/\1/p')"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup}"
code "the preview passes its checks" 0
has "says what a restore replaces" "a restore replaces: every table of the database"
has "names the backup that is the way back, with its age" "the newest backup of the current state, ${own_backup}, is"
# A table the backup does not hold, as a failed upgrade or a newer site can leave: a restore has to remove it.
db_sql 2 'create table lime_left_by_something_else (id int primary key)'
# With no room for the backup's files in upload/, nothing is changed.
docker exec -i -u root "$(ls_app 2)" sh -c 'cat > /usr/local/sbin/df && chmod 755 /usr/local/sbin/df' <<'DF'
#!/bin/sh
# tests only: every volume is full
echo "Filesystem 1-blocks Used Available Capacity Mounted on"
echo "/dev/full 1000000000 999999990 10 100% /var/www/html"
DF
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "with no room in upload/ for the backup's files, restore.sh ends with exit 3" 3
has "and says so" "upload/ has no room for the backup's files"
docker exec -u root "$(ls_app 2)" rm -f /usr/local/sbin/df
is "no marker was written" "0" "$(docker exec -u root "$(ls_app 2)" sh -c 'ls /var/www/html/clouve/backups/RESTORE-IN-PROGRESS 2> /dev/null | wc -l')"
has "and that nothing was changed" "Nothing was changed"
is "and has changed nothing" "0" "$(db_sql 2 'select count(*) from lime_surveys')"
run "$S/run-in-limesurvey.sh restore.sh --backup 20200101-000000 --yes-replace-current-data"
code "a backup that is not there is refused" 1
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "the restore runs" 0
has "it ends with the done line" "done: ${backup} is restored"
keys_line="$(printf '%s\n' "${out}" | grep -n 'security.php is the backup' | cut -d: -f1)"
load_line="$(printf '%s\n' "${out}" | grep -n 'loading the dump' | cut -d: -f1)"
if [ -n "${keys_line}" ] && [ -n "${load_line}" ] && [ "${keys_line}" -lt "${load_line}" ]; then ok "the keys went in before the database was touched"; else bad "the keys went in before the database was touched" "${out}"; fi
has "no table was dropped before the dump was loaded" "no table is dropped first"
has "the table the backup does not hold was removed afterwards" "1 that the backup does not hold were removed"
is "and it is gone" "0" "$(db_sql 2 "select count(*) from information_schema.tables where table_schema = database() and table_name = 'lime_left_by_something_else'")"
is "the database has exactly the tables of the first deployment" "$(db_sql 1 "select group_concat(table_name order by table_name) from information_schema.tables where table_schema = database()" | sha256sum)" "$(db_sql 2 "select group_concat(table_name order by table_name) from information_schema.tables where table_schema = database()" | sha256sum)"
is "security.php is www-data's, mode 600, as the image keeps it" "www-data 600" "$(docker exec -u root "$(ls_app 2)" stat -c '%U %a' /var/www/html/application/config/security.php)"
is "the encryption keys are the first deployment's" "${keys_1}" "$(docker exec -u root "$(ls_app 2)" sh -c 'sha256sum < /var/www/html/application/config/security.php')"
is "the surveys are there" "$(db_sql 1 'select count(*) from lime_surveys')" "$(db_sql 2 'select count(*) from lime_surveys')"
is "the answers are there" "3" "$(db_sql 2 'select count(*) from lime_responses_987002')"
is "nothing under /var/www/html but the state folder belongs to root" "0" "$(docker exec -u root "$(ls_app 2)" sh -c 'find /var/www/html -xdev -user root ! -path "/var/www/html/clouve*" | wc -l')"
is "the encrypted SMTP password reads as the original" "{\"result\":\"${smtp_pw}\",\"error\":null}" "$(printf '{"op":"smtp-password"}' | helper 2)"
is "the participant's uploaded file is there, as www-data's" "www-data uploaded-by-a-participant" "$(docker exec -u root "$(ls_app 2)" sh -c 'stat -c %U /var/www/html/upload/surveys/987002/files/fu_test | tr "\n" " "; cat /var/www/html/upload/surveys/987002/files/fu_test')"
is "the hand-added plugin is there" "1" "$(docker exec "$(ls_app 2)" sh -c 'ls /var/www/html/plugins/LssOldPlugin/config.xml | wc -l')"
is "config.php still points at the new deployment's own database" "1" "$(docker exec "$(ls_app 2)" grep -c "host=$(ls_db 2);" /var/www/html/application/config/config.php)"
is "maintenance mode is off" "off" "$(db_sql 2 "select stg_value from lime_settings_global where stg_name = 'maintenancemode'")"
is "the marker is gone" "0" "$(docker exec -u root "$(ls_app 2)" sh -c 'ls /var/www/html/clouve/backups/RESTORE-IN-PROGRESS 2> /dev/null | wc -l')"
is "the old keys were kept aside, for root only" "600" "$(docker exec -u root "$(ls_app 2)" sh -c 'stat -c %a /var/www/html/clouve/backups/before-restore-*/security.php')"
run "$S/rc.sh list_surveys"
code "LimeSurvey works on the restored data" 0
has "and lists the restored survey" '"sid":987002'
run "$S/verify-health.sh"
hasnt "verify-health.sh finds nothing failing" "[FAIL]"
has "and the keys read the restored data" "[OK]   keys: the encryption keys read"
run "$S/run-in-limesurvey.sh restore.sh --last-log"
has "--last-log shows the restore's log" "restore of ${backup} started"

# A backup of the current state that is hours old is not good enough without a word: the preview gives its age
# and how many answer sets the site has gained since, and the restore wants --skip-safety-backup.
run "$S/run-in-limesurvey.sh backup.sh"
recent="$(printf '%s\n' "${out}" | sed -n 's/.*done: \([0-9]\{8\}-[0-9]\{6\}\) .*/\1/p')"
older="$(date -u -d '3 hours ago' '+%Y%m%d-%H%M%S')"
oldest="$(date -u -d '30 hours ago' '+%Y%m%d-%H%M%S')"
docker exec -u root "$(ls_app 2)" sh -c "cd /var/www/html/clouve/backups && mv ${recent} ${older} && mv ${own_backup} ${oldest}"
fields2="$(agent 2 "printf '%s' '{\"surveyId\": 987002}' | $S/rc.sh --stdin get_fieldmap")"
printf '{"op":"add-response","sid":987002,"data":{"%s":"A later answer"}}' "$(printf '%s' "${fields2}" | docker exec -i "$(ls_agent 2)" jq -r '.result | to_entries[] | select(.value.title == "fullname") | .key' | head -n 1)" | helper 2 > /dev/null
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "with a backup of the current state that is three hours old, restore.sh stops" 1
has "it gives the backup's age" "${older}, is 3 hours old"
has "and how many answer sets the site has gained since" "the site has 1 more answer sets than it holds"
has "and asks for a new backup or the option" "Take a new one first"
is "nothing was changed" "4" "$(db_sql 2 'select count(*) from lime_responses_987002')"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --skip-safety-backup"
code "with --skip-safety-backup the preview passes" 0
has "and says what is lost" "What was added since is lost with this restore"
run "$S/verify-health.sh"
has "verify-health.sh gives the newest backup's age" "the newest is ${backup}, made "

# Only the keys, with a backup whose keys are not this database's: refused before anything is put in place.
docker exec -u root "$(ls_app 2)" sh -c 'mv /var/www/html/application/config/security.php /root/security.php.kept'
run "$S/run-in-limesurvey.sh restore.sh --keys-only --backup ${oldest} --yes-replace-the-keys"
code "keys that cannot read this database are not put in place" 2
has "and the message says so" "are not the ones this database was encrypted with"
is "no security.php was put in place" "0" "$(docker exec -u root "$(ls_app 2)" sh -c 'ls /var/www/html/application/config/security.php 2> /dev/null | wc -l')"
docker exec -u root "$(ls_app 2)" sh -c 'mv /root/security.php.kept /var/www/html/application/config/security.php'

# A backup that someone built: its upload archive holds a setuid file, a file outside upload/, a device file and
# a FIFO, all as root's. It arrives the way a backup from another deployment does. The restore must leave no
# file of root's, no setuid bit and no device file, and nothing outside upload/.
command -v python3 > /dev/null || { echo "limesurvey-scripts: the crafted backups need python3" >&2; exit 1; }
craft() { # KIND NAME: makes ~/limesurvey-backups/NAME in agent 2 from the real backup, changed as KIND says
    local dir="${work}/craft-$2"
    rm -rf "${dir}" && mkdir -p "${dir}"
    docker exec "$(ls_agent 2)" sh -c "tar -cf - -C ~/limesurvey-backups/${backup} ." | tar -xf - -C "${dir}" || return 1
    with_device=()
    [ "$1" = "${1%+device}" ] || with_device=(device)
    python3 -I - "${1%+device}" "${dir}" ${with_device[@]+"${with_device[@]}"} <<'PY2' || return 1
import gzip, hashlib, io, sys, tarfile
kind, d = sys.argv[1], sys.argv[2]
if kind == "setuid":
    src = tarfile.open(d + "/upload.tar.gz", "r:gz")
    out = tarfile.open(d + "/upload.new", "w:gz", format=tarfile.GNU_FORMAT)
    for m in src.getmembers():
        out.addfile(m, src.extractfile(m) if m.isfile() else None)
    def add(name, mode, kind=tarfile.REGTYPE, data=b"#!/bin/sh\nid\n", link=""):
        m = tarfile.TarInfo(name)
        m.mode, m.uid, m.gid, m.uname, m.gname, m.type, m.linkname = mode, 0, 0, "root", "root", kind, link
        if kind == tarfile.REGTYPE:
            m.size = len(data)
            out.addfile(m, io.BytesIO(data))
        else:
            if kind == tarfile.CHRTYPE:
                m.devmajor, m.devminor = 1, 3
            out.addfile(m)
    add("upload/planted-suid", 0o4755)
    add("upload/planted-sgid-dir", 0o2777, tarfile.DIRTYPE)
    add("upload/planted-fifo", 0o666, tarfile.FIFOTYPE)
    if len(sys.argv) > 3:
        add("upload/planted-dev", 0o666, tarfile.CHRTYPE)
    add("tmp/planted-outside", 0o4755)
    add("application/config/planted.php", 0o644, data=b"<?php // planted\n")
    out.close()
    import os
    os.replace(d + "/upload.new", d + "/upload.tar.gz")
elif kind == "broken-dump":
    lines = gzip.open(d + "/database.sql.gz", "rb").read().split(b"\n")
    at = next(i for i, l in enumerate(lines) if l.startswith(b"-- Table structure for table `lime_surveys`"))
    lines.insert(at, b"THIS IS NOT SQL, AND THE LOAD STOPS HERE;")
    # As a dump taken without the lock on the site: the maintenance mode it holds is off.
    lines = [l.replace(b"('maintenancemode','hard-cli')", b"('maintenancemode','off')") for l in lines]
    assert any(b"('maintenancemode','off')" in l for l in lines)
    with gzip.open(d + "/database.sql.gz", "wb") as f:
        f.write(b"\n".join(lines))
names = ["database.sql.gz", "upload.tar.gz", "config.tar.gz", "plugins.tar.gz", "manifest.json"]
with open(d + "/SHA256SUMS", "w") as f:
    for n in names:
        f.write("%s  %s\n" % (hashlib.sha256(open(d + "/" + n, "rb").read()).hexdigest(), n))
PY2
    docker exec "$(ls_agent 2)" sh -c "umask 077 && rm -rf ~/limesurvey-backups/$2 && mkdir -p ~/limesurvey-backups/$2" || return 1
    tar -cf - -C "${dir}" . | docker exec -i "$(ls_agent 2)" sh -c "tar -xf - -C ~/limesurvey-backups/$2 --no-same-owner"
}
craft setuid 20200303-030303 || bad "the crafted backup with a setuid file could be built"
run "$S/backup-copy.sh push 20200303-030303"
code "the built backup is pushed like any backup from another deployment" 0
run "$S/run-in-limesurvey.sh backup.sh"
code "a fresh backup of the current state" 0
run "$S/run-in-limesurvey.sh restore.sh --backup 20200303-030303 --yes-replace-current-data"
code "it is restored" 0
suid() { docker exec -u root "$(ls_app 2)" sh -c "$1"; }
is "its setuid file arrives as a plain file of www-data's" "www-data 755" "$(suid 'stat -c "%U %a" /var/www/html/upload/planted-suid')"
is "its setgid folder arrives without the bit, and closed to group and others for writing" "www-data 755" "$(suid 'stat -c "%U %a" /var/www/html/upload/planted-sgid-dir')"
is "its FIFO does not arrive" "0" "$(suid 'ls /var/www/html/upload/planted-fifo 2> /dev/null | wc -l')"
is "its file outside upload/ does not arrive" "0" "$(suid 'ls /var/www/html/tmp/planted-outside /var/www/html/application/config/planted.php 2> /dev/null | wc -l')"
is "no file under /var/www/html but the state folder belongs to root" "0" "$(suid 'find /var/www/html -xdev -user root ! -path "/var/www/html/clouve*" | wc -l')"
is "no file there has a setuid or setgid bit" "0" "$(suid 'find /var/www/html -xdev \( -type f -o -type d \) -perm /6000 ! -path "/var/www/html/clouve*" | wc -l')"
is "and nothing there is a device, a FIFO or a socket" "0" "$(suid 'find /var/www/html -xdev \( -type b -o -type c -o -type p -o -type s \) | wc -l')"
is "the participant's uploaded file is there all the same" "uploaded-by-a-participant" "$(suid 'cat /var/www/html/upload/surveys/987002/files/fu_test')"

# The same with a device file in the archive: no backup of this skill has one, so it is refused before anything
# is changed.
craft setuid+device 20200505-050505 || bad "the crafted backup with a device file could be built"
run "$S/backup-copy.sh push 20200505-050505"
answers_before="$(db_sql 2 'select count(*) from lime_responses_987002')"
run "$S/run-in-limesurvey.sh restore.sh --backup 20200505-050505 --yes-replace-current-data"
code "a backup whose upload archive holds a device file is refused" 2
has "and the message says why" "holds a device file"
is "no marker was written, and nothing was changed" "0 ${answers_before}" "$(suid 'ls /var/www/html/clouve/backups/RESTORE-IN-PROGRESS 2> /dev/null | wc -l') $(db_sql 2 'select count(*) from lime_responses_987002')"

# A restore that fails half way: the dump of this built backup stops in the middle. The restore ends with exit 4,
# its marker stays, the other scripts refuse, and a second restore, of a good backup, runs over the marker.
craft broken-dump 20200404-040404 || bad "the crafted backup with a dump that stops could be built"
run "$S/backup-copy.sh push 20200404-040404"
run "$S/run-in-limesurvey.sh backup.sh"
run "$S/run-in-limesurvey.sh restore.sh --backup 20200404-040404 --yes-replace-current-data"
code "a restore whose dump stops half way ends with exit 4" 4
has "the output names the step" "FAILED at step: loading the dump"
has "and says that the marker stays" "RESTORE-IN-PROGRESS stays"
is "the marker is there, and names the backup" "20200404-040404" "$(suid 'head -n 1 /var/www/html/clouve/backups/RESTORE-IN-PROGRESS')"
is "LimeSurvey's settings table is there: the site can start" "1" "$(db_sql 2 "select count(*) from lime_settings_global where stg_name = 'DBVersion'")"
is "and it is locked, although the dump was taken with the maintenance mode off" "hard-cli" "$(maintenance 2)"
run "$S/rc.sh list_surveys"
code "rc.sh refuses while the restore is unfinished" 75
run "$S/run-in-limesurvey.sh backup.sh"
code "and so does backup.sh" 75
run "$S/verify-health.sh"
has "verify-health.sh reports the unfinished restore" "[FAIL] restore"
run "$S/run-in-limesurvey.sh restore.sh --last-log"
has "the log has the failure" "FAILED at step: loading the dump"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "the restore of a good backup runs over the marker, with no new safety backup" 0
has "and says why it needs none" "a restore was cut off here before"
is "the marker is gone" "0" "$(suid 'ls /var/www/html/clouve/backups/RESTORE-IN-PROGRESS 2> /dev/null | wc -l')"
is "the answers are the backup's" "3" "$(db_sql 2 'select count(*) from lime_responses_987002')"
is "and the site is open again" "off" "$(maintenance 2)"

# The same restore onto a site whose security.php is gone, as after a lost config folder: LimeSurvey must not
# start before the backup's keys are in place. A restore that was cut off left its marker.
docker exec -u root "$(ls_app 2)" sh -c "rm /var/www/html/application/config/security.php && echo ${backup} > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS"
run "$S/rc.sh list_surveys"
code "with the marker of a cut-off restore, rc.sh refuses" 75
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "the restore runs again over its own marker, without security.php" 0
is "and the keys are the backup's, not new ones" "${keys_1}" "$(docker exec -u root "$(ls_app 2)" sh -c 'sha256sum < /var/www/html/application/config/security.php')"
is "the encrypted SMTP password still reads as the original" "{\"result\":\"${smtp_pw}\",\"error\":null}" "$(printf '{"op":"smtp-password"}' | helper 2)"
docker exec -u root "$(ls_app 2)" sh -c "printf x >> /var/www/html/clouve/backups/${backup}/database.sql.gz"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup} --yes-replace-current-data"
code "a backup whose files do not match its checksums is refused" 2
is "and the restored data stays" "3" "$(db_sql 2 'select count(*) from lime_responses_987002')"
is "nothing is left in the second container's /tmp" "0" "$(remote_leftovers)"
ls_ps_snapshot 2 "${ps_log}"
stack=1

# ---------------------------------------------------------------------------
section "14. No secret anywhere"
# ---------------------------------------------------------------------------
rm -f "${work}/sampling"
wait "${sampler}" 2> /dev/null
sampler=''
samples="$(wc -l < "${ps_log}")"
if [ "${samples}" -gt 2000 ]; then ok "the process lists of both deployments' containers were sampled throughout (${samples} lines)"; else bad "the process lists of both deployments' containers were sampled throughout (${samples} lines)"; fi
ls_exec_log_collect 1 "${exec_log}"
ls_exec_log_collect 2 "${exec_log}"
starts="$(wc -l < "${exec_log}")"
if [ "${starts}" -gt 2000 ]; then ok "every start of a program in them was recorded with its arguments (${starts} lines)"; else bad "every start of a program in them was recorded with its arguments (${starts} lines)"; fi
for wanted in 'mariadb-dump --defaults-extra-file=' 'sshpass -e ssh' 'tar -xzf - -C /var/www/html' 'php /tmp/clouve-ls.'; do
    if grep -qF -- "${wanted}" "${exec_log}"; then ok "the record has the scripts' own commands (${wanted})"; else bad "the record has the scripts' own commands (${wanted})"; fi
done
for c in "$(ls_app 1)" "$(ls_db 1)" "$(ls_agent 1)" "$(ls_app 2)" "$(ls_db 2)" "$(ls_agent 2)"; do docker logs "${c}" >> "${work}/logs" 2>&1; done
# found VALUE: where a value shows up, as words; nothing when it shows up nowhere. The value is never printed.
found() {
    local where=''
    [ -n "$1" ] || return 0
    grep -qF -- "$1" "${exec_log}" && where+="the arguments of a program, "
    grep -qF -- "$1" "${ps_log}" && where+="a process list, "
    grep -qF -- "$1" "${transcript}" && where+="a script's output, "
    grep -qF -- "$1" "${work}/logs" && where+="a container log, "
    printf '%s' "${where}"
}
sweep() { # NAME VALUE
    is "$1 is in no program's arguments, no process list, no output and no container log" "" "$(found "$2")"
}
sweep_all() { # NAME VALUE...
    local name="$1" value where='' n=0
    shift
    for value in "$@"; do
        [ -n "${value}" ] || continue
        n=$((n + 1))
        where+="$(found "${value}")"
    done
    is "${name} (${n} values): none is in a program's arguments, a process list, an output or a container log" "" "${where}"
}
sweep "the clouve-ops password" "${ls_ops_pw}"
sweep "the database password" "${ls_db_pw}"
sweep "the database root password" "${ls_db_root_pw}"
sweep "the admin's password" "${ls_admin_pw}"
sweep "the SMTP password" "${smtp_pw}"
sweep "the first temporary password" "${jane_pw}"
sweep "the second temporary password" "${jane_pw2}"
sweep "the password of the account whose reply was lost" "${lost_pw}"
sweep "the password of the last account made" "${busy2_pw}"
sweep "the SuiteCRM plugin's stored password" "Crm-Pw-3fH7kQ2xLm"
sweep_all "the values of security.php, of both deployments" "${keys_values[@]}"
sweep_all "the admin accounts' session tokens and password-link keys" "${session_tokens[@]}"
# Access codes are looked for in what the scripts printed and in the arguments of the programs they started.
codes_where=''
codes_n=0
for value in "${access_codes[@]}"; do
    [ -n "${value}" ] || continue
    codes_n=$((codes_n + 1))
    grep -qF -- "${value}" "${transcript}" && codes_where+="a script's output, "
    grep -qF -- "${value}" "${exec_log}" && codes_where+="the arguments of a program, "
done
is "the participants' access codes (${codes_n} values, all but the one shown on purpose): none is in an output or in a program's arguments" "" "${codes_where}"
if [ "${codes_n}" -ge 8 ]; then ok "and there were access codes to look for"; else bad "and there were access codes to look for (${codes_n})"; fi
is "no password is in the agent's environment" "0" "$(agent 1 'env | grep -c -e Pw- || true')"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
