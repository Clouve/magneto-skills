#!/bin/bash
# ============================================================================
# LimeSurvey skill: backups and restores that are cut off, and a restore that outlasts the health check
# ============================================================================
# tests/limesurvey-scripts.test.sh runs backup.sh and restore.sh on a small site, where each takes a second. This
# test gives the site a table of several hundred megabytes and then does what goes wrong on a real one:
#
#   1. the fixture: a survey with answers, and the big table
#   2. a backup whose processes are killed (kill -9, as a stopped container, an eviction or the OOM killer does):
#      it leaves the site locked in maintenance mode and a half-made folder. The next verify-health.sh, backup.sh
#      or restore.sh cleans up: the maintenance mode goes back to what the dead backup had found (off, or soft:
#      never simply to off), and only when that backup had set it, and the half-made folder goes
#   3. two backups at once: the second one stops, and so does a restore
#   4. a backup whose database goes away in the middle: exit 2, no half-made folder, and the lock on the site
#      lifted by the next run
#   5. a restore whose load of the dump takes over a minute, with the database held to a fraction of a CPU. The
#      platform's health check is GET / on the app's port every 15 seconds, and five failures in a row restart
#      the container. So GET / is asked every second through the whole restore, and it must never go 15 seconds
#      without a 200. The restore's marker is there all along, and the other scripts refuse meanwhile
#   6. the database stopped in the middle of the load: exit 4, the marker stays
#   7. the app container restarted in the middle of the load: it comes up waiting for the restore, with its sshd
#      and a page that keeps the health check happy, the other scripts still refuse, a second run of the same
#      restore finishes, and LimeSurvey then starts on the restored data
#
# Settings: see tests/lib/limesurvey-stack.sh, and:
#   LS_FAULTS_BIG_MB   the size of the big table in megabytes (default 700)
#   LS_FAULTS_DB_CPUS  the CPU limit of the database container during the restores (default 0.25)
# The load has to take over 60 seconds for part 5 to prove anything, and the test fails when it does not: raise
# the first setting or lower the second on a faster machine.
#
# Needs docker and about 3 GB of disk. A run takes about ten minutes.
#
# Usage: bash tests/limesurvey-backup-faults.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: the commands handed to the agent are literal text, with $ in single quotes on purpose.
# SC2154: lib/limesurvey-stack.sh, sourced below, sets the ls_* variables.
# shellcheck disable=SC2016,SC2154

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/limesurvey-stack.sh
. "${here}/lib/limesurvey-stack.sh"
command -v docker > /dev/null || { echo "limesurvey-backup-faults: this test needs docker" >&2; exit 1; }
big_mb="${LS_FAULTS_BIG_MB:-700}"
db_cpus="${LS_FAULTS_DB_CPUS:-0.25}"
[[ "${big_mb}" =~ ^[0-9]+$ ]] || { echo "limesurvey-backup-faults: LS_FAULTS_BIG_MB is a number of megabytes" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/limesurvey-backup-faults.XXXXXX")"
poller=''
cleanup() {
    if [ -n "${poller}" ]; then
        rm -f "${work}/polling"
        wait "${poller}" 2> /dev/null
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
out=''
rc=0
run() {
    out="$(agent 1 "$1" 2>&1)"
    rc=$?
}
is() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted: $2
got:    $3"; fi; }
code() { if [ "${rc}" -eq "$2" ]; then ok "$1 (exit $2)"; else bad "$1 (exit ${rc}, wanted $2)" "${out}"; fi; }
has() { if [[ "${out}" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted: $2
in:     ${out}"; fi; }
hasnt() { if [[ "${out}" != *"$2"* ]]; then ok "$1"; else bad "$1" "did not want: $2"; fi; }
maintenance() { db_sql 1 "select coalesce((select stg_value from lime_settings_global where stg_name = 'maintenancemode'), 'off')"; }
backups_dir=/var/www/html/clouve/backups
# left: the half-made folders and the note a dead backup leaves, as a count
left() { app_root 1 "ls -A ${backups_dir} 2> /dev/null | grep -c -e '^\.making-' -e '^\.maintenance-by-backup\$' || true"; }
# start_bg FILE COMMAND: runs COMMAND in the agent in the background, its output to FILE; its PID in bg
bg=''
start_bg() {
    local file="$1"
    shift
    (agent 1 "$*" > "${file}" 2>&1; echo "$?" > "${file}.rc") &
    bg=$!
}
# kill_backup: kill -9 for every process of a running backup.sh in the app container, the way a stopped
# container or the OOM killer ends them: no trap runs. The list of processes is read on stdin, so that this
# command's own text is not in any command line it looks at.
kill_backup() {
    docker exec -i -u root "$(ls_app 1)" sh -s <<'KILL'
for p in /proc/[0-9]*; do
    c="$(tr '\0' ' ' < "$p/cmdline" 2> /dev/null)"
    case "$c" in
        *clouve-ls.*backup.sh* | *limesurvey-run*backup.sh* | *mariadb-dump* | *mysqldump* | 'gzip '* | *'tar -czf'*) kill -9 "${p#/proc/}" 2> /dev/null ;;
    esac
done
KILL
}
# wait_making: until a backup that is running has made its folder and locked the site
wait_making() {
    ls_wait 90 app_root 1 "ls -d ${backups_dir}/.making-* > /dev/null 2>&1 && test -e ${backups_dir}/.maintenance-by-backup"
}
# wait_lock: until a backup or restore holds the lock
wait_lock() {
    ls_wait 60 sh -c "docker exec -u assistant '$(ls_agent 1)' bash -lc '$S/run-in-limesurvey.sh state.sh' < /dev/null 2> /dev/null | grep -q '^job_lock=held'"
}

# ---------------------------------------------------------------------------
section "1. The fixture"
# ---------------------------------------------------------------------------
echo "Building the images and starting LimeSurvey (this can take a few minutes the first time) ..."
ls_stack_images || { echo "limesurvey-backup-faults: could not build the images" >&2; exit 1; }
ls_stack_down
ls_stack_up 1 || { echo "limesurvey-backup-faults: the stack did not start" >&2; exit 1; }
printf '{"op":"set-smtp","host":"mail.example.test:25","user":"mailer@example.test","password":"Smtp-Pw-6gF1sD8kZq"}' | helper 1 > /dev/null
docker exec "$(ls_agent 1)" mkdir -p /tmp/files
docker cp -q "${ls_standin}/fixtures/draft.txt" "$(ls_agent 1):/tmp/files/draft.txt"
run "$S/survey-import.sh /tmp/files/draft.txt && $S/survey-activate.sh 987002 --yes-activate"
code "a survey is imported and activated" 0
fields="$(agent 1 "printf '%s' '{\"surveyId\": 987002}' | $S/rc.sh --stdin get_fieldmap")"
name_col="$(printf '%s' "${fields}" | docker exec -i "$(ls_agent 1)" jq -r '.result | to_entries[] | select(.value.title == "fullname") | .key' | head -n 1)"
for who in One Two Three; do
    printf '{"op":"add-response","sid":987002,"data":{"%s":"Person %s"}}' "${name_col}" "${who}" | helper 1 > /dev/null
done
is "it has three answer sets" "3" "$(db_sql 1 'select count(*) from lime_responses_987002')"

echo "  making a table of about ${big_mb} MB ..."
db_sql 1 'create table lime_old_responses_big (id int unsigned not null auto_increment primary key, filler varchar(1024) not null) engine=InnoDB'
chunks=$(((big_mb + 47) / 48))
for _ in $(seq 1 "${chunks}"); do
    db_sql 1 'insert into lime_old_responses_big (filler) select repeat(md5(rand()), 30) from seq_1_to_50000' || { echo "limesurvey-backup-faults: could not fill the big table" >&2; exit 1; }
done
big_rows="$(db_sql 1 'select count(*) from lime_old_responses_big')"
is "the big table has its rows" "$((chunks * 50000))" "${big_rows}"
is "nothing is under way" "0" "$(left)"

# ---------------------------------------------------------------------------
section "2. A backup that is killed"
# ---------------------------------------------------------------------------
start_bg "${work}/killed-1" "$S/run-in-limesurvey.sh backup.sh"
wait_making || bad "the backup got as far as locking the site and making its folder"
kill_backup
wait "${bg}" 2> /dev/null
if [ "$(cat "${work}/killed-1.rc" 2> /dev/null)" != 0 ]; then ok "the killed backup did not end well"; else bad "the killed backup did not end well" "$(cat "${work}/killed-1")"; fi
is "it left LimeSurvey locked" "hard-cli" "$(maintenance)"
is "and its half-made folder and its note" "2" "$(left)"
run "$S/run-in-limesurvey.sh state.sh"
has "state.sh says that a backup died" "backup_died=yes"
has "and that no backup is running" "job_lock=free"
run "$S/run-in-limesurvey.sh backup.sh --list"
hasnt "backup.sh --list does not show the half-made folder as a backup" ".making"
run "$S/verify-health.sh"
has "verify-health.sh says that it cleaned up after the backup" "[WARN] backup: a backup was cut off earlier"
has "that it put the maintenance mode back" "put the maintenance mode back to off"
has "and that it removed the half-made folder" "removed the half-made folder .making-"
is "LimeSurvey is open again" "off" "$(maintenance)"
is "and nothing of the dead backup is left" "0" "$(left)"
run "$S/verify-health.sh"
hasnt "a second verify-health.sh has nothing to clean up" "a backup was cut off earlier"

# The mode goes back to what it was, not to off. And the next backup does the cleaning as well as verify-health.sh.
run "$S/console.sh setmaintenancemode soft"
start_bg "${work}/killed-2" "$S/run-in-limesurvey.sh backup.sh"
wait_making || bad "the second backup got as far as locking the site"
kill_backup
wait "${bg}" 2> /dev/null
is "a backup killed on a site in soft maintenance mode left it locked" "hard-cli" "$(maintenance)"
run "$S/run-in-limesurvey.sh backup.sh"
code "the next backup runs to its end" 0
has "it says what the dead backup left" "a backup that was cut off earlier left its traces"
has "and that the mode went back to soft, which that backup had found" "put the maintenance mode back to soft"
has "and it ends by putting the mode back to soft itself" "maintenance mode back to soft"
is "LimeSurvey is in soft maintenance mode, as before both backups" "soft" "$(maintenance)"
is "nothing half-made is left" "0" "$(left)"
backup_1="$(printf '%s\n' "${out}" | sed -n 's/.*done: \([0-9]\{8\}-[0-9]\{6\}\) .*/\1/p')"
if [[ "${backup_1}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then ok "the backup is ${backup_1}"; else bad "the backup has a name" "${out}"; fi
run "$S/console.sh setmaintenancemode off"

# restore.sh cleans up too, before it looks at anything else.
start_bg "${work}/killed-3" "$S/run-in-limesurvey.sh backup.sh"
wait_making || bad "the third backup got as far as locking the site"
kill_backup
wait "${bg}" 2> /dev/null
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup_1} --skip-safety-backup"
code "a restore's preview after a dead backup" 0
has "says what the dead backup left" "a backup that was cut off earlier left its traces"
is "and LimeSurvey is open again" "off" "$(maintenance)"
is "with nothing half-made left" "0" "$(left)"

# A lock on the site that no backup set stays: only the half-made folder goes.
run "$S/console.sh setmaintenancemode hard-cli"
app_root 1 "install -d -m 700 ${backups_dir}/.making-20200101-000000"
run "$S/verify-health.sh"
has "a half-made folder without a note is removed" "removed the half-made folder .making-20200101-000000"
is "and a maintenance mode that no backup set is left alone" "hard-cli" "$(maintenance)"
run "$S/console.sh setmaintenancemode off"

# ---------------------------------------------------------------------------
section "3. Two at once"
# ---------------------------------------------------------------------------
start_bg "${work}/first" "$S/run-in-limesurvey.sh backup.sh"
wait_lock || bad "the first backup holds the lock"
run "$S/run-in-limesurvey.sh backup.sh"
code "a second backup stops while the first one runs" 1
has "and says why" "another backup or a restore is running"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup_1} --yes-replace-current-data --skip-safety-backup"
code "a restore stops too" 1
has "for the same reason" "another backup or a restore is running"
run "$S/verify-health.sh"
has "verify-health.sh says that a backup is running" "[WARN] jobs"
hasnt "and cleans nothing up under it" "a backup was cut off earlier"
wait "${bg}" 2> /dev/null
is "the first backup ran to its end, untouched by the others" "0" "$(cat "${work}/first.rc" 2> /dev/null)"
backup_2="$(sed -n 's/.*done: \([0-9]\{8\}-[0-9]\{6\}\) .*/\1/p' "${work}/first")"
if [[ "${backup_2}" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [ "${backup_2}" != "${backup_1}" ]; then ok "it is ${backup_2}"; else bad "the first backup has a name" "$(cat "${work}/first")"; fi
is "LimeSurvey is open" "off" "$(maintenance)"

# ---------------------------------------------------------------------------
section "4. The database goes away during a backup"
# ---------------------------------------------------------------------------
start_bg "${work}/nodb" "$S/run-in-limesurvey.sh backup.sh"
wait_making || bad "the backup got as far as locking the site"
docker stop "$(ls_db 1)" > /dev/null
wait "${bg}" 2> /dev/null
is "the backup ends with exit 2" "2" "$(cat "${work}/nodb.rc" 2> /dev/null)"
out="$(cat "${work}/nodb")"
has "it says that the dump failed" "the database dump failed"
has "and that the maintenance mode could not be put back" "could not put the maintenance mode back"
is "its half-made folder is gone, and its note stays for the next run" "1" "$(left)"
docker start "$(ls_db 1)" > /dev/null
ls_wait 120 docker exec -e MYSQL_PWD="${ls_db_pw}" "$(ls_db 1)" mariadb -u limesurvey limesurvey -e 'select 1' || bad "the database came back"
is "with the database back, LimeSurvey is still locked" "hard-cli" "$(maintenance)"
run "$S/verify-health.sh"
has "verify-health.sh lifts the lock" "put the maintenance mode back to off"
is "LimeSurvey is open again" "off" "$(maintenance)"
is "and nothing is left" "0" "$(left)"
is "the big table is whole" "${big_rows}" "$(db_sql 1 'select count(*) from lime_old_responses_big')"

# ---------------------------------------------------------------------------
section "5. A restore that takes longer than the health check waits"
# ---------------------------------------------------------------------------
# The poll: once a second, what a visitor (and the platform's health check) gets at /, and whether the restore's
# marker is there. One line per poll: <seconds since 1970> <HTTP status> <M or ->.
poll_start() {
    : > "${work}/polls"
    : > "${work}/polling"
    (
        while [ -e "${work}/polling" ]; do
            status="$(docker exec "$(ls_agent 1)" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$(ls_app 1):8080/" 2> /dev/null)"
            mark="$(docker exec -u root "$(ls_app 1)" sh -c "test -e ${backups_dir}/RESTORE-IN-PROGRESS && echo M || echo -" 2> /dev/null)"
            echo "$(date +%s) ${status:-000} ${mark:--}" >> "${work}/polls"
            sleep 1
        done
    ) &
    poller=$!
}
poll_stop() {
    rm -f "${work}/polling"
    wait "${poller}" 2> /dev/null
    poller=''
}
# longest_gap FROM TO: the longest stretch, in seconds, without a 200 between two times
longest_gap() {
    awk -v from="$1" -v to="$2" '
        $1 >= from && $1 <= to { if (last == "") last = from; if ($2 == 200) { if ($1 - last > gap) gap = $1 - last; last = $1 } }
        END { if (last == "") last = from; if (to - last > gap) gap = to - last; print gap + 0 }' "${work}/polls"
}
log_seconds() { # TEXT: when the restore's log has its first line with TEXT, as seconds of the day
    printf '%s\n' "$1" | awk -v text="$2" 'index($0, text) { split($1, t, ":"); print t[1] * 3600 + t[2] * 60 + t[3]; exit }'
}

docker update --cpus "${db_cpus}" "$(ls_db 1)" > /dev/null || bad "the database container could be held to ${db_cpus} CPU"
tables_before="$(db_sql 1 "select count(*) from information_schema.tables where table_schema = database()")"
db_sql 1 'create table lime_made_after_the_backup (id int primary key)'
poll_start
sleep 5
began="$(date +%s)"
start_bg "${work}/restore-a" "$S/run-in-limesurvey.sh restore.sh --backup ${backup_2} --yes-replace-current-data"
ls_wait 60 app_root 1 "test -e ${backups_dir}/RESTORE-IN-PROGRESS" || bad "the restore wrote its marker"
sleep 20
run "$S/rc.sh list_surveys"
code "while the restore runs, rc.sh refuses" 75
has "because a restore has not finished" "restore from a backup was started"
run "$S/run-in-limesurvey.sh backup.sh"
code "and backup.sh refuses" 75
is "the table that was made after the backup is still there: nothing was dropped before the load" "1" "$(db_sql 1 "select count(*) from information_schema.tables where table_schema = database() and table_name = 'lime_made_after_the_backup'")"
wait "${bg}" 2> /dev/null
ended="$(date +%s)"
sleep 3
poll_stop
is "the restore ran to its end" "0" "$(cat "${work}/restore-a.rc" 2> /dev/null)"
out="$(cat "${work}/restore-a")"
has "with its done line" "done: ${backup_2} is restored"
log="$(agent 1 "$S/run-in-limesurvey.sh restore.sh --last-log" 2>&1)"
load_from="$(log_seconds "${log}" 'loading the dump')"
load_to="$(log_seconds "${log}" "the database is the backup's")"
load_took=$(((${load_to:-0} - ${load_from:-0} + 86400) % 86400))
if [ "${load_took}" -gt 60 ]; then
    ok "loading the dump took ${load_took} s, longer than the health check waits before it restarts a container"
else
    bad "loading the dump took ${load_took} s, which proves nothing: it has to take over 60 s (raise LS_FAULTS_BIG_MB or lower LS_FAULTS_DB_CPUS)"
fi
polls="$(awk -v from="${began}" -v to="${ended}" '$1 >= from && $1 <= to' "${work}/polls" | wc -l)"
good="$(awk -v from="${began}" -v to="${ended}" '$1 >= from && $1 <= to && $2 == 200' "${work}/polls" | wc -l)"
if [ "${polls}" -ge 40 ]; then ok "the site was asked for / ${polls} times during the restore, and answered 200 to ${good} of them"; else bad "the site was asked for / at least 40 times during the restore (${polls})"; fi
gap="$(longest_gap "${began}" "${ended}")"
if [ "${gap}" -lt 15 ]; then
    ok "the longest stretch without a 200 was ${gap} s: the health check, which asks every 15 s and needs 5 failures in a row, never saw one failure follow another"
else
    bad "the longest stretch without a 200 was ${gap} s. The health check asks every 15 s and restarts the container after 5 failures in a row" "$(awk -v from="${began}" -v to="${ended}" '$1 >= from && $1 <= to { print $2 }' "${work}/polls" | sort | uniq -c | tr '\n' ' ')"
fi
marker_at="$(awk -v from="${began}" '$1 >= from && $3 == "M" { print $1; exit }' "${work}/polls")"
marked="$(awk -v from="${marker_at:-0}" -v to="$((ended - 3))" '$1 >= from && $1 <= to { n++; if ($3 == "M") m++ } END { print (n >= 40 && m == n) ? "yes" : "no (" m + 0 " of " n + 0 " looks)" }' "${work}/polls")"
is "the restore's marker was there at every look, from before the load to the end" "yes" "${marked}"
is "the big table is whole" "${big_rows}" "$(db_sql 1 'select count(*) from lime_old_responses_big')"
is "the answers are there" "3" "$(db_sql 1 'select count(*) from lime_responses_987002')"
is "the table that was made after the backup is gone now, and the database has the backup's tables" "${tables_before}" "$(db_sql 1 "select count(*) from information_schema.tables where table_schema = database()")"
is "the marker is gone" "0" "$(app_root 1 "ls ${backups_dir}/RESTORE-IN-PROGRESS 2> /dev/null | wc -l")"
is "LimeSurvey is open" "off" "$(maintenance)"

# ---------------------------------------------------------------------------
section "6. The database stops in the middle of the load"
# ---------------------------------------------------------------------------
start_bg "${work}/restore-b" "$S/run-in-limesurvey.sh restore.sh --backup ${backup_2} --yes-replace-current-data"
ls_wait 60 app_root 1 "test -e ${backups_dir}/RESTORE-IN-PROGRESS" || bad "the restore wrote its marker"
sleep 15
docker stop "$(ls_db 1)" > /dev/null
wait "${bg}" 2> /dev/null
is "the restore ends with exit 4" "4" "$(cat "${work}/restore-b.rc" 2> /dev/null)"
out="$(cat "${work}/restore-b")"
has "it names the step that failed" "FAILED at step: loading the dump"
has "and says to run it again" "Run the same restore again"
is "the marker stays" "1" "$(app_root 1 "ls ${backups_dir}/RESTORE-IN-PROGRESS 2> /dev/null | wc -l")"
docker start "$(ls_db 1)" > /dev/null
ls_wait 120 docker exec -e MYSQL_PWD="${ls_db_pw}" "$(ls_db 1)" mariadb -u limesurvey limesurvey -e 'select 1' || bad "the database came back"
is "LimeSurvey's settings table is there, so the site can start" "1" "$(db_sql 1 "select count(*) from lime_settings_global where stg_name = 'DBVersion'")"
run "$S/rc.sh list_surveys"
code "rc.sh refuses until the restore is finished" 75

# ---------------------------------------------------------------------------
section "7. The container restarts in the middle of the load"
# ---------------------------------------------------------------------------
start_bg "${work}/restore-c" "$S/run-in-limesurvey.sh restore.sh --backup ${backup_2} --yes-replace-current-data"
ls_wait 60 sh -c "grep -q 'loading the dump' '${work}/restore-c'" || bad "the second run of the restore got to the load"
sleep 15
docker restart "$(ls_app 1)" > /dev/null
wait "${bg}" 2> /dev/null
if [ "$(cat "${work}/restore-c.rc" 2> /dev/null)" != 0 ]; then ok "the restore was cut off by the restart"; else bad "the restore was cut off by the restart"; fi
if ls_wait 120 docker exec "$(ls_agent 1)" bash -c "(exec 3<>/dev/tcp/$(ls_app 1)/22) 2>/dev/null"; then
    ok "the container is up again, with its sshd"
else
    bad "the container is up again, with its sshd" "$(docker logs --tail 15 "$(ls_app 1)" 2>&1)"
fi
sleep 5
is "the container is running, not stopped" "true" "$(docker inspect -f '{{.State.Running}}' "$(ls_app 1)")"
run "$S/run-in-limesurvey.sh state.sh"
code "state.sh runs" 0
has "it says a restore is unfinished" "restore=in-progress"
hasnt "and that LimeSurvey is not being served" "web_server=apache"
answers=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    answers+="$(docker exec "$(ls_agent 1)" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$(ls_app 1):8080/" 2> /dev/null) "
    sleep 1
done
is "the health check's request gets 200 all the while, so the platform leaves the container alone" "200 200 200 200 200 200 200 200 200 200 " "${answers}"
is "and what answers is a page about the restore, not LimeSurvey on a half-loaded database" "1" "$(docker exec "$(ls_agent 1)" curl -s --max-time 5 "http://$(ls_app 1):8080/" 2> /dev/null | grep -ci 'restored' | sed 's/^[1-9][0-9]*$/1/')"
run "$S/rc.sh list_surveys"
code "rc.sh refuses" 75
run "$S/run-in-limesurvey.sh backup.sh"
code "backup.sh refuses" 75
run "$S/verify-health.sh"
has "verify-health.sh reports the unfinished restore" "[FAIL] restore"
has "and that the container waits" "[FAIL] waiting"
run "$S/upgrade-state.sh"
code "upgrade-state.sh says the container waits for a repair" 4
has "in so many words" "WAITING FOR A REPAIR"
has "and that the way out is to run the restore again" "Run the same restore again"
has "and how the Clouve dashboard shows the deployment meanwhile" "shows as running"
run "$S/run-in-limesurvey.sh restore.sh --last-log"
has "the log of the run that was cut off is kept" "loading the dump"
run "$S/run-in-limesurvey.sh restore.sh --backup ${backup_2} --yes-replace-current-data"
code "the same restore, run again, finishes" 0
has "it needed no new backup of the current state" "a restore was cut off here before"
has "and ends with its done line" "done: ${backup_2} is restored"
if ls_wait 300 ls_app_answers "$(ls_app 1)"; then
    ok "LimeSurvey then starts by itself"
else
    bad "LimeSurvey then starts by itself" "$(docker logs --tail 20 "$(ls_app 1)" 2>&1)"
fi
run "$S/rc.sh list_surveys"
code "and the scripts work again" 0
has "with the restored survey" '"sid":987002'
is "the big table is whole" "${big_rows}" "$(db_sql 1 'select count(*) from lime_old_responses_big')"
is "the answers are there" "3" "$(db_sql 1 'select count(*) from lime_responses_987002')"
is "the marker is gone" "0" "$(app_root 1 "ls ${backups_dir}/RESTORE-IN-PROGRESS 2> /dev/null | wc -l")"
is "LimeSurvey is open" "off" "$(maintenance)"
run "$S/verify-health.sh"
hasnt "verify-health.sh finds nothing failing" "[FAIL]"
has "and the keys read the restored data" "[OK]   keys: the encryption keys read"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
