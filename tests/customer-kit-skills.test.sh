#!/bin/bash
# ============================================================================
# Customer Kit: the limesurvey and suitecrm skills together, on a real pair
# ============================================================================
# The Customer Kit runs LimeSurvey and SuiteCRM in one deployment. Clouve's SuiteCRM plugin in LimeSurvey turns
# a completed survey into a lead or a case in SuiteCRM, and the AI Assistant there has both skills. This test
# starts the kit's four containers from Clouve's own images (the magneto repo builds them), with the settings of
# the kit's manifest, and an assistant stand-in that uses the Magneto Agent's own scripts: the fetchers that read
# each sibling's persona and settings over the clouve-ops channel, clv-secret, and the context composer. Both
# plugins are mounted where the agent stages them. Nothing is faked on the way: a survey response travels from a
# respondent's HTTP request through the plugin and SuiteCRM's API into SuiteCRM's database.
#
# What it checks:
#   agent      the assistant's login shells have the four siblings' settings, no password is in that
#              environment, and clv-secret serves the passwords by name
#   personas   the assistant's context, composed by the agent's own composer from the base template and the two
#              personas the images carry: every host, database name and database user the personas name is
#              filled in, no password's value is in the text, each persona names only its own app's settings,
#              and both say the same about the kit
#   health     verify-health.sh of both skills on the new kit
#   commands   every command in the four Customer Kit texts, run as written, in the order of each text:
#              limesurvey's playbooks/customer-kit-suitecrm-link.md and reference/customer-kit.md, and suitecrm's
#              playbooks/customer-kit-limesurvey-link.md and reference/customer-kit.md
#   mapping    crm-link.sh map for real: a mapping to a Leads field is stored, and the next response a respondent
#              submits over HTTP becomes a lead with that value in that field; a module the plugin does not
#              write to is refused, and so is a field the module does not have, with the names that are there;
#              unmap removes the mapping, and the next lead no longer has the value
#   link       what the two skills say breaks the link, and the fix they name: temp-password.sh refuses the
#              main admin and says why; with the admin's password changed and the account switched off, a
#              response is recorded as failed and makes no lead, users.sh shows the account inactive, and
#              restore-admin-password.sh brings the link back; users.sh refuses to deactivate or demote the
#              main admin; sql-read.sh runs in the kit (SuiteCRM's database account sees one database)
#   client     the plugin's API client deleted in SuiteCRM: crm-link.sh status says that SuiteCRM no longer
#              has it, as the plugin's own status check does, the suitecrm playbook's query finds no client, a
#              response is recorded as failed, and "Initialize OAuth2" on the plugin's settings page (pressed
#              here over HTTP, as the admin) makes a new client and brings the link back
#   waiting    each image's note of a wait (needs-attention): with a restore marker in place and the container
#              restarted, each skill's upgrade-state.sh and verify-health.sh show the image's own reason, and
#              the app comes back when the marker goes
#   sweep      no password of the kit is in anything a script printed
#
# Settings:
#   KIT_LIMESURVEY_IMAGE, KIT_LIMESURVEY_DB_IMAGE, KIT_SUITECRM_IMAGE, KIT_SUITECRM_DB_IMAGE
#                     the four images (Clouve's own, built from the magneto repo). The test is skipped when one
#                     is not given or not on this machine.
#   KIT_AGENT_DIR     the image/ folder of a magneto-agent checkout (default: ../magneto-agent/image next to this
#                     repo). The test is skipped when it is not there.
#   KIT_TEST_PREFIX   the prefix of every container, network, volume and image this makes (default ck-skills-)
#   KIT_TEST_KEEP=1   leave the containers up at the end, for a look around
#
# Needs docker. Publishes no port, pushes nothing, runs on a network with no way out, and removes its containers,
# network and volumes when it ends (the assistant stand-in's image stays, for the next run). Every password is
# made up. A run takes about two minutes.
#
# Usage: KIT_LIMESURVEY_IMAGE=... KIT_LIMESURVEY_DB_IMAGE=... KIT_SUITECRM_IMAGE=... KIT_SUITECRM_DB_IMAGE=... \
#        bash tests/customer-kit-skills.test.sh   (exit 0 = all pass, or skipped)
# ============================================================================

# SC2016: the commands handed to the agent are literal text, with $ in single quotes on purpose.
# shellcheck disable=SC2016

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
lib="${here}/lib/customer-kit"
P="${KIT_TEST_PREFIX:-ck-skills-}"
agent_dir="${KIT_AGENT_DIR:-${repo}/../magneto-agent/image}"

skip() { echo "customer-kit-skills: skipped: $1"; exit 0; }
command -v docker > /dev/null || { echo "customer-kit-skills: this test needs docker" >&2; exit 1; }
declare -A image=(
    [limesurvey]="${KIT_LIMESURVEY_IMAGE:-}"
    [limesurvey-mariadb]="${KIT_LIMESURVEY_DB_IMAGE:-}"
    [suitecrm]="${KIT_SUITECRM_IMAGE:-}"
    [suitecrm-mariadb]="${KIT_SUITECRM_DB_IMAGE:-}"
)
services=(limesurvey-mariadb suitecrm-mariadb suitecrm limesurvey)
for svc in "${services[@]}"; do
    [ -n "${image[${svc}]}" ] || skip "the four images of the Customer Kit are not given. Build them from the magneto repo (apps/limesurvey/image, apps/limesurvey/image/mariadb, apps/suitecrm/image, apps/suitecrm/image/mariadb) and set KIT_LIMESURVEY_IMAGE, KIT_LIMESURVEY_DB_IMAGE, KIT_SUITECRM_IMAGE and KIT_SUITECRM_DB_IMAGE."
    docker image inspect "${image[${svc}]}" > /dev/null 2>&1 || skip "the image ${image[${svc}]} (${svc}) is not on this machine."
done
if [ ! -f "${agent_dir}/installer/chat/marketplace/sidecar-sync.sh" ] || [ ! -f "${agent_dir}/installer/secrets/clv-secret" ] || [ ! -f "${agent_dir}/context/CONTEXT.md.tpl" ]; then
    skip "the Magneto Agent's scripts are not at ${agent_dir} (set KIT_AGENT_DIR to the image/ folder of a magneto-agent checkout)."
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/customer-kit-skills-test.XXXXXX")"
chmod 700 "${work}"
transcript="${work}/transcript"
: > "${transcript}"

c() { printf '%s%s' "${P}" "$1"; }
net="${P}net"
agent_image="${P}agent:1"

cleanup() {
    local svc
    if [ "${KIT_TEST_KEEP:-0}" = 1 ]; then
        echo "Kept everything named ${P}* (containers, volumes, the network)."
    else
        docker rm -f "$(c agent)" > /dev/null 2>&1
        for svc in "${services[@]}"; do docker rm -f "$(c "${svc}")" > /dev/null 2>&1; done
        docker volume rm "${P}limesurvey-data" "${P}limesurvey-upload" "${P}limesurvey-db-data" "${P}suitecrm-data" "${P}suitecrm-db-data" > /dev/null 2>&1
        docker network rm "${net}" > /dev/null 2>&1
    fi
    rm -rf "${work}"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 14 | cut -c1-260 | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }
finish() {
    echo
    echo "customer-kit-skills: ${pass} passed, ${fail} failed"
    [ "${fail}" -eq 0 ]
    exit $?
}

# --- the kit's settings, as bundles/crm-kit/clv-docker-compose.yml in the magneto repo has them --------------------
# Every password is made up here, and none is in a command line of this test: the containers get them from env
# files of mode 600, and the test's own database reads use one too.
rnd() { od -An -N8 -tx1 /dev/urandom | tr -d ' \n'; }
pw_ops="Ops-$(rnd)"
pw_admin="Kit-Adm1n-$(rnd)"
pw_other="Other-Adm1n-$(rnd)"
pw_ls_db="lsdb-$(rnd)"
pw_ls_root="lsroot-$(rnd)"
pw_sc_db="scdb-$(rnd)"
pw_sc_root="scroot-$(rnd)"
secrets=("${pw_ops}" "${pw_admin}" "${pw_other}" "${pw_ls_db}" "${pw_ls_root}" "${pw_sc_db}" "${pw_sc_root}")
admin_login='kit.admin@example.test'
SID=123456

envfile() { (umask 077 && cat > "${work}/$1.env"); }
envfile limesurvey <<ENV
DB_TYPE=mysql
DB_HOST=limesurvey-mariadb
DB_PORT=3306
DB_NAME=limesurvey
DB_USERNAME=limesurvey
DB_PASSWORD=${pw_ls_db}
ADMIN_USER=Kit_Admin
ADMIN_NAME=Kit Admin
ADMIN_EMAIL=${admin_login}
ADMIN_PASSWORD=${pw_admin}
PUBLIC_URL=https://limesurvey.kit.example.test
INSTALL_DEMO_DATA=true
ENABLE_SUITECRM_INTEGRATION=true
SUITECRM_URL=suitecrm
SUITECRM_ADMIN_USER=${admin_login}
SUITECRM_ADMIN_PASSWORD=${pw_admin}
SUITECRM_DB_HOST=suitecrm-mariadb
SUITECRM_DB_PORT=3306
SUITECRM_DB_NAME=suitecrm
SUITECRM_DB_USER=suitecrm
SUITECRM_DB_PASSWORD=${pw_sc_db}
CLOUVE_OPS_PASSWORD=${pw_ops}
ENV
envfile limesurvey-mariadb <<ENV
MYSQL_DATABASE=limesurvey
MYSQL_USER=limesurvey
MYSQL_PASSWORD=${pw_ls_db}
MYSQL_ROOT_PASSWORD=${pw_ls_root}
CLOUVE_OPS_PASSWORD=${pw_ops}
ENV
envfile suitecrm <<ENV
DATABASE_HOST=suitecrm-mariadb
DATABASE_PORT=3306
DATABASE_NAME=suitecrm
DATABASE_USER=suitecrm
DATABASE_PASSWORD=${pw_sc_db}
SUITECRM_URL=https://suitecrm.kit.example.test
SUITECRM_ADMIN_USER=${admin_login}
SUITECRM_ADMIN_PASSWORD=${pw_admin}
SUITECRM_INSTALL_DEMO_DATA=no
CLOUVE_OPS_PASSWORD=${pw_ops}
ENV
envfile suitecrm-mariadb <<ENV
MYSQL_DATABASE=suitecrm
MYSQL_USER=suitecrm
MYSQL_PASSWORD=${pw_sc_db}
MYSQL_ROOT_PASSWORD=${pw_sc_root}
CLOUVE_OPS_PASSWORD=${pw_ops}
ENV
printf 'MYSQL_PWD=%s\n' "${pw_ls_db}" | envfile ls-client
printf 'MYSQL_PWD=%s\n' "${pw_sc_db}" | envfile sc-client

# The manifest's capacity (memoryBase, cpuBase) and volumes
declare -A cpus=([limesurvey]=1 [limesurvey-mariadb]=0.5 [suitecrm]=1 [suitecrm-mariadb]=0.5)
declare -A mounts=(
    [limesurvey]="-v ${P}limesurvey-data:/var/www/html -v ${P}limesurvey-upload:/var/www/html/upload"
    [limesurvey-mariadb]="-v ${P}limesurvey-db-data:/var/lib/mysql"
    [suitecrm]="-v ${P}suitecrm-data:/var/www/html"
    [suitecrm-mariadb]="-v ${P}suitecrm-db-data:/var/lib/mysql"
)

# --- helpers ---------------------------------------------------------------------------------------------------------
S_LS=/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts
S_SC=/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts
out=''
rc=0
# run COMMAND: runs it in the assistant's login shell, as the assistant's user, with no stdin
run() {
    out="$(docker exec -u assistant -w /home/assistant "$(c agent)" bash -lc "$1" < /dev/null 2>&1)"
    rc=$?
    printf '$ %s\n%s\n[exit %s]\n' "$1" "${out}" "${rc}" >> "${transcript}"
}
code() { if [ "${rc}" -eq "$2" ]; then ok "$1 (exit $2)"; else bad "$1 (exit ${rc}, wanted $2)" "${out}"; fi; }
has() { if [[ "${out}" == *"$2"* ]]; then ok "$1"; else bad "$1" "wanted: $2"$'\n'"in:     ${out}"; fi; }
hasnt() { if [[ "${out}" != *"$2"* ]]; then ok "$1"; else bad "$1" "did not want: $2"$'\n'"in:     ${out}"; fi; }
is() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "wanted: $2"$'\n'"got:    $3"; fi; }
# The test's own back doors: each app's database, read as the app's account
lsql() { docker exec --env-file "${work}/ls-client.env" "$(c limesurvey-mariadb)" mariadb -h 127.0.0.1 -u limesurvey limesurvey -N -B -e "$1" 2>&1 < /dev/null; }
csql() { docker exec --env-file "${work}/sc-client.env" "$(c suitecrm-mariadb)" mariadb -h 127.0.0.1 -u suitecrm suitecrm -N -B -e "$1" 2>&1 < /dev/null; }
# wait_for SECONDS COMMAND...: runs COMMAND once a second until it succeeds
wait_for() {
    local left="$1"
    shift
    while [ "${left}" -gt 0 ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        sleep 1
        left=$((left - 1))
    done
    return 1
}
ls_up() { docker exec "$(c limesurvey)" sh -c '[ "$(cat /proc/1/comm)" = apache2 ] && [ ! -e /var/www/html/clouve/install-in-progress ] && curl -fsS -o /dev/null -H "Host: localhost" http://127.0.0.1:8080/'; }
sc_up() { docker exec "$(c suitecrm)" sh -c '[ "$(cat /proc/1/comm)" = apache2 ] && curl -fsS -m 10 http://localhost/session-status 2> /dev/null | grep -q "\"installed\":true"'; }
ssh_up() { docker exec "$(c agent)" bash -c "(exec 3<>/dev/tcp/$1/22) 2> /dev/null"; }
show_logs() { local svc; for svc in "$@"; do echo "--- the last lines of ${svc}:"; docker logs --tail 25 "$(c "${svc}")" 2>&1 | cut -c1-240; done; }

# doc_commands FILE: the commands in FILE's bash blocks, one per line, in the file's order. A line that ends in a
# backslash is joined to the next one.
doc_commands() {
    awk '
        /^```bash[[:space:]]*$/ { inside = 1; next }
        /^```/ { inside = 0; next }
        inside {
            line = $0
            if (held != "") line = held " " line
            if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
            held = ""
            if (line !~ /^[[:space:]]*$/ && line !~ /^[[:space:]]*#/) print line
        }' "$1"
}
# run_doc FILE: runs every command of FILE as written, with its placeholders filled in. A command is wanted to
# end with exit 0, and the preview of restore-admin-password.sh with 64.
run_doc() {
    local file="$1" cmd want name n=0
    name="${file#"${repo}/plugins/"}"
    while IFS= read -r cmd; do
        n=$((n + 1))
        cmd="${cmd//<survey id>/${SID}}"
        cmd="${cmd//<question id>/${qid_first}}"
        cmd="${cmd//<response id>/${response_first}}"
        if [[ "${cmd}" == *'<'[a-z]*'>'* ]] && [[ "${cmd}" != *'SELECT'* ]]; then
            bad "${name}: a placeholder this test does not know: ${cmd}"
            continue
        fi
        want=0
        [[ "${cmd}" == *"/restore-admin-password.sh" ]] && want=64
        run "${cmd}"
        if [ "${rc}" -eq "${want}" ]; then
            ok "${name}: $(printf '%s' "${cmd}" | sed "s|${S_LS}/||; s|${S_SC}/||" | cut -c1-110) (exit ${want})"
        else
            bad "${name}: $(printf '%s' "${cmd}" | cut -c1-160) (exit ${rc}, wanted ${want})" "${out}"
        fi
    done < <(doc_commands "${file}")
    [ "${n}" -gt 0 ] || bad "${name}: it has commands to run"
}

# qid_of CODE: the id of the demo survey's question with that code, as crm-link.sh mappings shows it
qid_of() { printf '%s\n' "${mappings}" | awk -F'\t' -v code="$1" '$2 == code { gsub(/[^0-9]/, "", $1); print $1; exit }'; }
# respond FIELD=ANSWER...: a respondent completes the demo survey over HTTP. LimeSurvey 7 names a question's
# form field Q<question id>.
respond() { docker exec "$(c limesurvey)" php /tmp/ck-respond.php "${SID}" "$@" 2>&1 < /dev/null; }
# sales_inquiry MARKER [FIELD=ANSWER...]: a respondent's sales inquiry whose answers carry MARKER
sales_inquiry() {
    local m="$1"
    shift
    respond "Q$(qid_of requestType)=SALES" "Q$(qid_of firstName)=Zebulon-${m}" "Q$(qid_of lastName)=Quill-${m}" \
        "Q$(qid_of email)=zeb-${m}@example.invalid" "Q$(qid_of productInterest)=CRM" "$@"
}
# response_of MARKER: the id of the response whose last name carries MARKER, or nothing
response_of() { lsql "SELECT id FROM lime_responses_${SID} WHERE \`Q$(qid_of lastName)\` = 'Quill-$1' ORDER BY id DESC LIMIT 1"; }
# sync_of MARKER: the plugin's log of that response: module and status of each row, in order
sync_of() {
    local id
    id="$(response_of "$1")"
    [[ ${id} =~ ^[0-9]+$ ]] || return 0
    lsql "SELECT CONCAT(crm_module, ':', sync_status) FROM lime_survey_crm_sync_log WHERE survey_id = ${SID} AND response_id = ${id} ORDER BY id" | paste -sd ' ' -
}
# wait_sync MARKER: until the plugin's log has a row for that response, 30 seconds at most
wait_sync() {
    for _ in $(seq 1 30); do
        [ -n "$(sync_of "$1")" ] && return 0
        sleep 1
    done
    return 1
}
leads_of() { csql "SELECT COUNT(*) FROM leads WHERE deleted = 0 AND last_name = 'Quill-$1'"; }
# lead_field MARKER COLUMN: one column of the lead that response made
lead_field() { csql "SELECT IFNULL($2, 'NULL') FROM leads WHERE deleted = 0 AND last_name = 'Quill-$1'"; }
# becomes_lead LABEL MARKER: the response was completed, the plugin logged a success, and SuiteCRM has one lead
becomes_lead() {
    wait_sync "$2" || :
    is "$1: the plugin's log has it as sent" "Leads:success" "$(sync_of "$2")"
    is "$1: SuiteCRM has one lead of it" "1" "$(leads_of "$2")"
}

# admin_web check-status|initialize-oauth2: a LimeSurvey admin presses one of the two buttons on the plugin's
# settings page, over HTTP. The admin's password goes in on stdin.
admin_web() { printf '%s\n' "${pw_admin}" | docker exec -i "$(c limesurvey)" bash /tmp/ck-admin-web.sh Kit_Admin "$1" 2>&1; }

# --- 1. the kit ------------------------------------------------------------------------------------------------------
section "1. The kit's four containers and the assistant stand-in"
build="${work}/agent-build"
mkdir -p "${build}/agent/installer/chat" "${build}/agent/context"
cp "${lib}/agent.Dockerfile" "${build}/Dockerfile"
cp -R "${agent_dir}/installer/secrets" "${build}/agent/installer/secrets"
cp -R "${agent_dir}/installer/chat/marketplace" "${build}/agent/installer/chat/marketplace"
cp "${agent_dir}/context/CONTEXT.md.tpl" "${build}/agent/context/CONTEXT.md.tpl"
if ! docker build -q -t "${agent_image}" "${build}" > "${work}/agent-build.log" 2>&1; then
    echo "customer-kit-skills: the assistant stand-in's image did not build:" >&2
    tail -n 20 "${work}/agent-build.log" >&2
    exit 1
fi
for plugin in limesurvey suitecrm; do
    [ -f "${repo}/plugins/${plugin}/.claude-plugin/plugin.json" ] || { echo "customer-kit-skills: ${repo}/plugins/${plugin} is not the ${plugin} plugin" >&2; exit 1; }
done
docker network create --internal "${net}" > /dev/null || { echo "customer-kit-skills: could not make the network ${net} (is an earlier run still up?)" >&2; exit 1; }
for svc in "${services[@]}"; do
    # shellcheck disable=SC2086  # the mounts are separate words
    docker run -d --pull=never --name "$(c "${svc}")" --hostname "${svc}" --network "${net}" --network-alias "${svc}" \
        --memory 1g --memory-swap 1g --cpus "${cpus[${svc}]}" --env-file "${work}/${svc}.env" ${mounts[${svc}]} \
        "${image[${svc}]}" > /dev/null || { echo "customer-kit-skills: ${svc} did not start" >&2; exit 1; }
done
docker run -d --name "$(c agent)" --hostname magneto-agent --network "${net}" --memory 1g \
    -v "${repo}/plugins/limesurvey:/clouve/skills/limesurvey/plugin:ro" \
    -v "${repo}/plugins/suitecrm:/clouve/skills/suitecrm/plugin:ro" \
    "${agent_image}" > /dev/null || { echo "customer-kit-skills: the assistant stand-in did not start" >&2; exit 1; }
begun="${SECONDS}"
if wait_for 600 sc_up && wait_for 600 ls_up; then
    ok "LimeSurvey and SuiteCRM answer, $((SECONDS - begun)) s after the containers started, at 1 GB each"
else
    bad "LimeSurvey and SuiteCRM answer"
    show_logs limesurvey suitecrm
    finish
fi
is "LimeSurvey's code is 7.x" "7" "$(docker exec "$(c limesurvey)" php -r 'define("BASEPATH", "/x/"); $c = include "/var/www/html/application/config/version.php"; echo explode(".", $c["versionnumber"])[0];' 2>&1)"
is "SuiteCRM's is 8.10.x" "8.10" "$(docker exec "$(c suitecrm)" cut -d. -f1,2 /var/www/html/VERSION 2>&1)"
for svc in "${services[@]}"; do
    wait_for 120 ssh_up "${svc}" || bad "${svc}: its clouve-ops sshd takes connections"
done

# The agent's own start: its secret, then the fetch of each sibling's persona and settings. The ops password
# goes in on stdin.
printf '%s\n' "${pw_ops}" | docker exec -i -u root "$(c agent)" bash -c '
    IFS= read -r CLOUVE_OPS_PASSWORD
    export CLOUVE_OPS_PASSWORD
    export CLV_SIDECAR_HOSTS=limesurvey,limesurvey-mariadb,suitecrm,suitecrm-mariadb
    export CLV_SIDECAR_NAMESPACES=limesurvey,limesurvey-mariadb,suitecrm,suitecrm-mariadb
    export CLV_SIDECAR_APP_PORTS=8080,3306,80,3306
    export CLV_SIDECAR_PULL_TIMEOUT=120
    . /clouve/magneto-agent/installer/secrets/secrets-lib.sh
    part="$(mktemp)"
    _clv_secret_line CLOUVE_OPS_PASSWORD "$CLOUVE_OPS_PASSWORD" > "$part"
    _clv_secrets_install_part agent "$part" || exit 1
    /clouve/magneto-agent/installer/chat/marketplace/sidecar-sync.sh
    install -d -m 755 /clouve/skills
    printf "limesurvey\nsuitecrm\n" > /clouve/skills/.active
    cp /clouve/context/CONTEXT.md.tpl /clouve/skills/CONTEXT.md.tpl
    chmod a+r /clouve/skills/.active /clouve/skills/CONTEXT.md.tpl
    printf "export MAGNETO_AGENT_HOST=%s\nexport MAGNETO_AGENT_USER_FULL_NAME=%s\nexport MAGNETO_AGENT_ORG_NAME=%s\n" https://agent.kit.example.test "Kit\\ Admin" "Kit\\ Org" > /etc/profile.d/clouve-env.sh
' > "${work}/sidecar-sync.log" 2>&1 || bad "the agent's own fetch of the siblings' personas and settings ran" "$(tail -n 15 "${work}/sidecar-sync.log")"
docker cp -q "${lib}/respond.php" "$(c limesurvey):/tmp/ck-respond.php"
docker cp -q "${lib}/admin-web.sh" "$(c limesurvey):/tmp/ck-admin-web.sh"
docker exec "$(c suitecrm)" rm -rf /tmp/ck-fixtures
docker cp -q "${here}/lib/suitecrm-stack/fixtures" "$(c suitecrm):/tmp/ck-fixtures"
docker cp -q "${repo}/plugins/suitecrm/skills/suitecrm/scripts/remote/boot.php" "$(c suitecrm):/tmp/ck-fixtures/boot.php"

# --- 2. what the assistant sees --------------------------------------------------------------------------------------
section "2. The assistant's settings and secrets"
run 'for v in LIMESURVEY_HOST LIMESURVEY_DB_HOST LIMESURVEY_DB_NAME LIMESURVEY_DB_USER LIMESURVEY_ADMIN_USER SUITECRM_HOST SUITECRM_DB_HOST SUITECRM_DB_NAME SUITECRM_DB_USER SUITECRM_ADMIN_USER SUITECRM_URL LIMESURVEY_MARIADB_HOST SUITECRM_MARIADB_HOST; do printf "%s=%s\n" "$v" "${!v:-}"; done'
is "the login shell has each sibling's host, database name and user, and the two admin logins" \
    "LIMESURVEY_HOST=limesurvey LIMESURVEY_DB_HOST=limesurvey-mariadb LIMESURVEY_DB_NAME=limesurvey LIMESURVEY_DB_USER=limesurvey LIMESURVEY_ADMIN_USER=Kit_Admin SUITECRM_HOST=suitecrm SUITECRM_DB_HOST=suitecrm-mariadb SUITECRM_DB_NAME=suitecrm SUITECRM_DB_USER=suitecrm SUITECRM_ADMIN_USER=${admin_login} SUITECRM_URL=https://suitecrm.kit.example.test LIMESURVEY_MARIADB_HOST=limesurvey-mariadb SUITECRM_MARIADB_HOST=suitecrm-mariadb" \
    "$(printf '%s' "${out}" | paste -sd ' ' -)"
run 'env'
leaked=0
for s in "${secrets[@]}"; do [[ "${out}" == *"${s}"* ]] && leaked=$((leaked + 1)); done
is "no password of the kit is in the assistant's environment" "0" "${leaked}"
run 'clv-secret --list | sort | paste -sd " " -'
for name in CLOUVE_OPS_PASSWORD LIMESURVEY_DB_PASSWORD LIMESURVEY_ADMIN_PASSWORD SUITECRM_DB_PASSWORD SUITECRM_ADMIN_PASSWORD; do
    has "clv-secret has ${name}" "${name}"
done
run '[ "$(clv-secret SUITECRM_DB_PASSWORD)" = "$(clv-secret LIMESURVEY_SUITECRM_DB_PASSWORD)" ] && [ "$(clv-secret SUITECRM_ADMIN_PASSWORD)" = "$(clv-secret LIMESURVEY_SUITECRM_ADMIN_PASSWORD)" ] && echo same'
is "LimeSurvey holds the same SuiteCRM admin and database passwords as SuiteCRM (the test compares them and prints neither)" "same" "${out}"

# --- 3. the two personas in one context ------------------------------------------------------------------------------
section "3. Both personas in the assistant's context"
run 'ls /clouve/context/limesurvey/CONTEXT.md.tpl /clouve/context/suitecrm/CONTEXT.md.tpl'
code "the agent's fetch brought each image's persona" 0
run '. /clouve/magneto-agent/installer/chat/marketplace/context-composer.sh && _clv_compose_context /clouve/skills/CONTEXT.md.tpl /clouve/skills/.active "$HOME/CLAUDE.md" && wc -l < "$HOME/CLAUDE.md"'
code "the agent's own composer makes the context from the base template and the two personas" 0
docker exec -u assistant "$(c agent)" cat /home/assistant/CLAUDE.md > "${work}/context.md" 2> /dev/null
for plugin in limesurvey suitecrm; do
    docker exec "$(c agent)" cat "/clouve/context/${plugin}/CONTEXT.md.tpl" > "${work}/${plugin}.tpl" 2> /dev/null
    if grep -q "^## Skill: ${plugin}\$" "${work}/context.md"; then ok "the context has the ${plugin} section"; else bad "the context has the ${plugin} section"; fi
done
# Every variable a persona names that the composer may fill in (a host, a database name, a database user) has
# a value in the login shell, and none of them is left as ${NAME} in the composed text.
unfilled=''
empty=''
for v in $(cat "${work}/limesurvey.tpl" "${work}/suitecrm.tpl" | grep -oE '\$\{[A-Z][A-Z0-9_]*\}' | tr -d '${}' | sort -u); do
    case "${v}" in
        *_HOST | *_DB_NAME | *_DB_USER)
            run "printf '%s' \"\${${v}:-}\""
            [ -n "${out}" ] || empty+=" ${v}"
            grep -qF "\${${v}}" "${work}/context.md" && unfilled+=" ${v}"
            ;;
    esac
done
is "every host, database name and database user the personas name has a value" "" "${empty}"
is "and none of them is left unfilled in the context" "" "${unfilled}"
for want in 'clouve-ops@limesurvey' 'clouve-ops@limesurvey-mariadb' 'clouve-ops@suitecrm' 'clouve-ops@suitecrm-mariadb' '-u limesurvey limesurvey'; do
    if grep -qF -- "${want}" "${work}/context.md"; then ok "the context has: ${want}"; else bad "the context has: ${want}"; fi
done
leaked=0
for s in "${secrets[@]}"; do grep -qF -- "${s}" "${work}/context.md" && leaked=$((leaked + 1)); done
is "no password's value is in the context" "0" "${leaked}"
# A password is named, never filled in: the two-part form stays as the personas write it
for name in CLOUVE_OPS_PASSWORD LIMESURVEY_DB_PASSWORD SUITECRM_DB_PASSWORD; do
    if grep -qF "\${${name}:-\$(clv-secret ${name})}" "${work}/context.md"; then ok "${name} is still read in the two-part form"; else bad "${name} is still read in the two-part form"; fi
done
# Each persona names only its own app's settings, so the two sections can't collide
foreign_ls="$(grep -oE '\$\{[A-Z][A-Z0-9_]*' "${work}/limesurvey.tpl" | tr -d '${' | sort -u | grep -vE '^(LIMESURVEY_|CLOUVE_OPS_PASSWORD$)' | paste -sd ' ' -)"
foreign_sc="$(grep -oE '\$\{[A-Z][A-Z0-9_]*' "${work}/suitecrm.tpl" | tr -d '${' | sort -u | grep -vE '^(SUITECRM_|CLOUVE_OPS_PASSWORD$)' | paste -sd ' ' -)"
is "the LimeSurvey persona names only LimeSurvey's settings and the ops password" "" "${foreign_ls}"
is "the SuiteCRM persona names only SuiteCRM's settings and the ops password" "" "${foreign_sc}"
# What they say about the kit: each names the other app and its skill, LimeSurvey's says that its skill covers
# LimeSurvey's side of the link, and SuiteCRM's that the main admin, its password and the plugin's API client
# are not the assistant's to change. Neither tells the assistant to change them.
kit_ls="$(tr '\n' ' ' < "${work}/limesurvey.tpl" | tr -s ' ')"
kit_sc="$(tr '\n' ' ' < "${work}/suitecrm.tpl" | tr -s ' ')"
if [[ "${kit_ls}" == *"In the Customer Kit, a SuiteCRM container and its database run in the same pod, with a skill and a section of their own"* ]]; then ok "the LimeSurvey persona says that SuiteCRM has a skill and a section of its own in the kit"; else bad "the LimeSurvey persona says that SuiteCRM has a skill and a section of its own in the kit"; fi
if [[ "${kit_ls}" == *"The LimeSurvey skill covers this side of that link"* ]]; then ok "and that its own skill covers LimeSurvey's side of the link"; else bad "and that its own skill covers LimeSurvey's side of the link"; fi
if [[ "${kit_sc}" == *"In the Customer Kit, a LimeSurvey container and its database run in the same deployment, with their own skill"* ]]; then ok "the SuiteCRM persona says that LimeSurvey has its own skill in the kit"; else bad "the SuiteCRM persona says that LimeSurvey has its own skill in the kit"; fi
if [[ "${kit_sc}" == *'so that account, its password and the OAuth2 client named "LimeSurvey Integration" are not yours to change'* ]]; then ok "and that the main admin, its password and the plugin's API client are not the assistant's to change"; else bad "and that the main admin, its password and the plugin's API client are not the assistant's to change"; fi
if ! grep -qiE '(change|reset|set) (the )?(suitecrm|crm) admin.s password' "${work}/limesurvey.tpl"; then ok "the LimeSurvey persona does not tell the assistant to change SuiteCRM's admin password"; else bad "the LimeSurvey persona does not tell the assistant to change SuiteCRM's admin password"; fi

# --- 4. health -------------------------------------------------------------------------------------------------------
section "4. Both skills' health reports on the new kit"
run "${S_LS}/verify-health.sh"
if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ]; then ok "limesurvey verify-health.sh is green or amber on a new kit (exit ${rc})"; else bad "limesurvey verify-health.sh is green or amber on a new kit (exit ${rc})" "${out}"; fi
hasnt "it has no FAIL line" "[FAIL]"
has "its keys line tested the keys against the plugin's stored passwords" "[OK]   keys:"
run "${S_SC}/verify-health.sh"
code "suitecrm verify-health.sh is green" 0
has "and says so" "Overall: GREEN"
run "${S_LS}/upgrade-state.sh"
code "limesurvey upgrade-state.sh: nothing is under way" 0
run "${S_SC}/upgrade-state.sh"
code "suitecrm upgrade-state.sh runs" 0
has "and says that the start-up has finished" "Start-up: finished (PID 1 is Apache)."

# --- 5. a first response, then every command of the four texts -----------------------------------------------------
section "5. A first response, through the limesurvey skill's own activation"
run "${S_LS}/crm-link.sh mappings --survey ${SID}"
code "crm-link.sh mappings lists the demo survey's questions" 0
mappings="${out}"
qid_first="$(qid_of firstName)"
qid_phone="$(qid_of phone)"
if [[ "${qid_first}" =~ ^[0-9]+$ ]] && [[ "${qid_phone}" =~ ^[0-9]+$ ]]; then ok "with the ids of its questions (firstName ${qid_first}, phone ${qid_phone})"; else bad "with the ids of its questions" "${mappings}"; fi
has "firstName fills Leads: first_name" $'firstName\tLeads: first_name'
has "phone fills Leads: phone_work" $'phone\tLeads: phone_work'
# One page for the whole survey, so that one request completes it (the admin's choice in the survey's settings)
lsql "UPDATE lime_surveys SET format = 'A' WHERE sid = ${SID}" > /dev/null
run "${S_LS}/survey-activate.sh ${SID}"
code "survey-activate.sh shows what would go live" 0
run "${S_LS}/survey-activate.sh ${SID} --yes-activate"
code "and activates the demo survey after the yes" 0
m1="a$(rnd | cut -c1-6)"
is "a respondent completes a sales inquiry over HTTP" "submitted" "$(sales_inquiry "${m1}" "Q${qid_phone}=555-0100-${m1}")"
becomes_lead "the first response" "${m1}"
is "with the phone number in the field the demo mapping names" "555-0100-${m1}" "$(lead_field "${m1}" phone_work)"
response_first="$(response_of "${m1}")"

section "6. Every command of the four Customer Kit texts, as written"
run_doc "${repo}/plugins/limesurvey/skills/limesurvey/playbooks/customer-kit-suitecrm-link.md"
# The playbook's steps switch the link off and clear a mapping, each after its own gate. Put both back.
run "${S_LS}/crm-link.sh enable-survey --survey ${SID}"
code "the link is switched on again for the demo survey" 0
run "${S_LS}/crm-link.sh map --question ${qid_first} --field Leads:first_name"
code "and firstName is mapped again" 0
run_doc "${repo}/plugins/limesurvey/skills/limesurvey/reference/customer-kit.md"
run_doc "${repo}/plugins/suitecrm/skills/suitecrm/playbooks/customer-kit-limesurvey-link.md"
run_doc "${repo}/plugins/suitecrm/skills/suitecrm/reference/customer-kit.md"
# What some of them printed
run "${S_LS}/crm-link.sh status"
has "crm-link.sh status: the plugin is on" "SuiteCRM plugin: on"
has "it connects to the kit's SuiteCRM as the main admin, and shows no password" "SuiteCRM admin: ${admin_login}, password stored"
has "the demo survey's link is on and the survey is active" "${SID}: link on, survey active"
has "one answer set was sent" "1 worked, 0 failed"
run "${S_SC}/sql-read.sh --table 'SELECT id, name, deleted, allowed_grant_type FROM oauth2clients WHERE name = \"LimeSurvey Integration\"'"
has "suitecrm sql-read.sh shows the plugin's API client, with the password grant" "| LimeSurvey Integration |       0 | password"
run "${S_SC}/users.sh show \"\${SUITECRM_ADMIN_USER}\""
has "users.sh show: the main admin is active" '"status": "Active"'
has "and an admin" '"is_admin": true'
m2="b$(rnd | cut -c1-6)"
is "after restore-admin-password.sh --yes-reset (run twice above, with nothing wrong), a response is completed" "submitted" "$(sales_inquiry "${m2}")"
becomes_lead "the response after the password was put back" "${m2}"

# --- 7. crm-link.sh map, for real ------------------------------------------------------------------------------------
section "7. crm-link.sh map: a mapping to a Leads field, a response, a lead with that value"
run "${S_LS}/crm-link.sh map --question ${qid_phone} --field Leads:phone_mobile"
code "a mapping to a real field of Leads is stored" 0
has "and the plugin's own table is updated" "The plugin's own table: updated"
run "${S_LS}/crm-link.sh mappings --survey ${SID}"
has "mappings shows it" $'phone\tLeads: phone_mobile'
m3="c$(rnd | cut -c1-6)"
is "a respondent completes the next response" "submitted" "$(sales_inquiry "${m3}" "Q${qid_phone}=555-0199-${m3}")"
becomes_lead "the response after the mapping" "${m3}"
is "the lead has the answer in the mapped field" "555-0199-${m3}" "$(lead_field "${m3}" phone_mobile)"
is "and not in the field the question filled before" "NULL" "$(lead_field "${m3}" phone_work)"
run "${S_SC}/sql-read.sh 'SELECT phone_mobile FROM leads WHERE deleted = 0 AND last_name = \"Quill-${m3}\"'"
has "the suitecrm skill reads the same value" "555-0199-${m3}"
run "${S_LS}/crm-link.sh map --question ${qid_phone} --field Accounts:name"
if [ "${rc}" -ne 0 ]; then ok "a module that is not Leads or Cases is refused (exit ${rc})"; else bad "a module that is not Leads or Cases is refused" "${out}"; fi
has "with the modules the plugin writes to" "Leads"
has "both of them" "Cases"
run "${S_LS}/crm-link.sh map --question ${qid_phone} --field Leads:no_such_field_here"
if [ "${rc}" -ne 0 ]; then ok "a field that Leads does not have is refused (exit ${rc})"; else bad "a field that Leads does not have is refused" "${out}"; fi
has "with the names SuiteCRM gives for the module" "phone_mobile"
has "the usual ones among them" "first_name"
run "${S_LS}/crm-link.sh mappings --survey ${SID}"
has "after the two refusals the mapping is as it was" $'phone\tLeads: phone_mobile'
run "${S_LS}/crm-link.sh unmap --question ${qid_phone}"
code "unmap clears the question's mapping" 0
run "${S_LS}/crm-link.sh mappings --survey ${SID}"
has "mappings shows it as not mapped" $'phone\t(not mapped)'
m4="d$(rnd | cut -c1-6)"
is "a respondent completes a response after the unmap" "submitted" "$(sales_inquiry "${m4}" "Q${qid_phone}=555-0142-${m4}")"
becomes_lead "the response after the unmap" "${m4}"
is "its lead has no phone number: the answer no longer reaches the CRM" "NULL NULL" "$(lead_field "${m4}" "CONCAT(IFNULL(phone_mobile, 'NULL'), ' ', IFNULL(phone_work, 'NULL'))")"
run "${S_LS}/crm-link.sh map --question ${qid_phone} --field Leads:phone_work"
code "the demo mapping of phone is put back" 0

# --- 8. what breaks the link, and the fix ----------------------------------------------------------------------------
section "8. The main admin's password: what the skills say breaks the link, and their fix"
run "${S_SC}/temp-password.sh \"\${SUITECRM_ADMIN_USER}\""
code "suitecrm temp-password.sh refuses the main admin" 2
has "and says that LimeSurvey signs in with that password in the Customer Kit" "in the Customer Kit LimeSurvey signs in to SuiteCRM with it"
has "and names the script that gets the admin back in" "restore-admin-password.sh"
run "${S_SC}/users.sh deactivate \"\${SUITECRM_ADMIN_USER}\""
code "users.sh refuses to deactivate the main admin" 2
run "${S_SC}/users.sh set-admin \"\${SUITECRM_ADMIN_USER}\" no"
code "and to take its admin right away" 2
m5="e$(rnd | cut -c1-6)"
is "after the three refusals a response is completed" "submitted" "$(sales_inquiry "${m5}")"
becomes_lead "the response after the refusals" "${m5}"
# Someone changes the main admin's password in SuiteCRM and the account ends up inactive. This is the
# suitecrm tests' fixture for a locked-out admin: SuiteCRM's own hash of another password, written in one UPDATE.
printf '%s\n' "${pw_other}" | docker exec -i -u www-data "$(c suitecrm)" php /tmp/ck-fixtures/lock-admin.php > /dev/null 2>&1 || bad "(the admin's password was changed and the account switched off)"
run "${S_SC}/users.sh show \"\${SUITECRM_ADMIN_USER}\""
has "users.sh show, step 2 of the suitecrm playbook, shows the account inactive" '"status": "Inactive"'
m6="f$(rnd | cut -c1-6)"
is "a respondent still completes the survey: the answers stay in LimeSurvey" "submitted" "$(sales_inquiry "${m6}")"
wait_sync "${m6}" || :
is "the plugin's log has that response as failed, as the limesurvey skill says" "Leads:failed" "$(sync_of "${m6}")"
is "and SuiteCRM has no lead of it, as the suitecrm skill says" "0" "$(leads_of "${m6}")"
run "${S_LS}/crm-link.sh status | tail -n 1"
has "crm-link.sh status counts the failed answer set" "1 failed"
run "${S_SC}/restore-admin-password.sh"
code "restore-admin-password.sh without the yes changes nothing" 64
run "${S_SC}/restore-admin-password.sh --yes-reset"
code "with the yes it puts the dashboard's password back" 0
has "says that the password is restored" '"password_restored": true'
has "and that the account was made active again" '"reactivated": true'
leaked=0
for s in "${secrets[@]}"; do [[ "${out}" == *"${s}"* ]] && leaked=$((leaked + 1)); done
is "and prints no password" "0" "${leaked}"
m7="g$(rnd | cut -c1-6)"
is "a respondent completes the next response" "submitted" "$(sales_inquiry "${m7}")"
becomes_lead "the response after the fix: the link is back" "${m7}"
is "the response that failed meanwhile was not sent again, as both skills say" "0" "$(leads_of "${m6}")"

# --- 9. the plugin's API client ---------------------------------------------------------------------------------------
section "9. The plugin's API client deleted in SuiteCRM, and \"Initialize OAuth2\""
client_query="${S_SC}/sql-read.sh --table 'SELECT id, name, allowed_grant_type, is_confidential, date_entered, date_modified FROM oauth2clients WHERE deleted = 0 AND name = \"LimeSurvey Integration\"'"
run "${client_query}"
has "(the client is there before)" "LimeSurvey Integration"
client_before="$(csql "SELECT id FROM oauth2clients WHERE deleted = 0 AND name = 'LimeSurvey Integration'")"
# An admin deletes the client in SuiteCRM (Admin, OAuth2 Clients and Tokens): the row is marked deleted
csql "UPDATE oauth2clients SET deleted = 1 WHERE name = 'LimeSurvey Integration'" > /dev/null
run "${client_query}"
code "the suitecrm playbook's query for the client still runs" 0
hasnt "and finds no client" "LimeSurvey Integration"
run "${S_LS}/crm-link.sh status"
code "crm-link.sh status runs" 0
has "it says that SuiteCRM no longer has the client the plugin holds" "SuiteCRM no longer has it"
has "and names the fix" "Initialize OAuth2"
hasnt "and does not call the sign-in set up" "(OAuth2 client): set up"
out="$(admin_web check-status)"
has "the plugin's own status check on its settings page says the same" "SuiteCRM no longer has the OAuth2 client that LimeSurvey holds"
has "and its overall state is an error" '"overall":"error"'
m9="i$(rnd | cut -c1-6)"
is "a respondent completes a response meanwhile" "submitted" "$(sales_inquiry "${m9}")"
wait_sync "${m9}" || :
is "the plugin's log has it as failed" "Leads:failed" "$(sync_of "${m9}")"
is "and SuiteCRM has no lead of it" "0" "$(leads_of "${m9}")"
out="$(admin_web initialize-oauth2)"
has "the admin presses \"Initialize OAuth2\" on the plugin's settings page, and the plugin makes a new client" '"success":true'
client_after="$(csql "SELECT id FROM oauth2clients WHERE deleted = 0 AND name = 'LimeSurvey Integration'")"
if [ -n "${client_after}" ] && [ "${client_after}" != "${client_before}" ]; then ok "SuiteCRM has a new client"; else bad "SuiteCRM has a new client" "before: ${client_before}, after: ${client_after}"; fi
run "${S_LS}/crm-link.sh status"
has "crm-link.sh status says that the sign-in is set up again" "(OAuth2 client): set up"
run "${client_query}"
has "the suitecrm playbook's query finds the client again" "LimeSurvey Integration"
m10="j$(rnd | cut -c1-6)"
is "a respondent completes the next response" "submitted" "$(sales_inquiry "${m10}")"
becomes_lead "the response after \"Initialize OAuth2\": the link is back" "${m10}"

# --- 10. the image's note of a wait ----------------------------------------------------------------------------------
section "10. A container that waits: each image's own reason reaches the assistant"
# The skill's restore writes its marker before it changes anything. A container that starts while the marker is
# there waits, and leaves a note for the assistant with its reason (needs-attention). Here the marker is put
# there by hand, and the containers are restarted.
docker exec "$(c suitecrm)" bash -c 'install -d -m 700 -o root -g root /var/www/html/tmp/clouve-backup && chmod 00700 /var/www/html/tmp/clouve-backup && echo "restore of ck-test started" > /var/www/html/tmp/clouve-backup/restore-in-progress && chmod 600 /var/www/html/tmp/clouve-backup/restore-in-progress'
docker exec "$(c limesurvey)" bash -c 'install -d -m 700 -o root -g root /var/www/html/clouve/backups && echo 20260101-000000 > /var/www/html/clouve/backups/RESTORE-IN-PROGRESS'
docker restart "$(c suitecrm)" "$(c limesurvey)" > /dev/null
wait_for 120 ssh_up suitecrm || bad "suitecrm's sshd is up again"
wait_for 120 ssh_up limesurvey || bad "limesurvey's sshd is up again"
wait_for 90 docker exec "$(c suitecrm)" test -e /var/www/html/tmp/clouve-backup/needs-attention || bad "the SuiteCRM image left its note of the wait (tmp/clouve-backup/needs-attention)" "$(docker logs --tail 8 "$(c suitecrm)" 2>&1)"
wait_for 90 docker exec "$(c limesurvey)" test -e /var/www/html/clouve/needs-attention || bad "the LimeSurvey image left its note of the wait (clouve/needs-attention)" "$(docker logs --tail 8 "$(c limesurvey)" 2>&1)"
note_keys() { docker exec "$1" sh -c "sed 's/=.*//' '$2' | paste -sd ' ' -; stat -c '%U %a' '$2'" 2>&1 | paste -sd ' ' -; }
is "the SuiteCRM image's note has the five keys, and is root's with mode 600" "reason since from to kind root 600" "$(note_keys "$(c suitecrm)" /var/www/html/tmp/clouve-backup/needs-attention)"
is "and so has the LimeSurvey image's" "reason since from to kind root 600" "$(note_keys "$(c limesurvey)" /var/www/html/clouve/needs-attention)"
run "${S_SC}/upgrade-state.sh"
code "suitecrm upgrade-state.sh runs while the container waits" 0
has "it says that a restore was cut off" "the container is waiting: a restore was cut off (run the restore again)"
has "and gives the image's own reason, from the note" "a restore is under way"
has "with the time since when it waits" "needs-attention, since 20"
run "${S_SC}/verify-health.sh"
code "suitecrm verify-health.sh is red there" 3
has "with the image's reason in its start-up line" "The image's note says, since 20"
run "${S_LS}/upgrade-state.sh"
code "limesurvey upgrade-state.sh says that the container waits" 4
has "it gives the image's own reason, from the note" "The image's reason: a restore from a backup is under way"
has "the time since when it waits" "It has waited since 20"
has "and the way out" "Run the same restore again"
run "${S_LS}/verify-health.sh"
has "limesurvey verify-health.sh fails on waiting, with the reason" "[FAIL] waiting: the container is waiting for a repair and serves no LimeSurvey (a restore from a backup is under way"
has "and the time" "), since 20"
run "${S_LS}/crm-link.sh status"
code "a limesurvey script that changes or reads the site is refused meanwhile" 75
run "${S_SC}/records.sh list Leads"
code "and so is a suitecrm one" 75
docker exec "$(c suitecrm)" rm -f /var/www/html/tmp/clouve-backup/restore-in-progress
docker exec "$(c limesurvey)" rm -f /var/www/html/clouve/backups/RESTORE-IN-PROGRESS
if wait_for 300 sc_up && wait_for 300 ls_up; then ok "with the markers gone, both apps finish their start by themselves"; else bad "with the markers gone, both apps finish their start by themselves"; show_logs limesurvey suitecrm; fi
if ! docker exec "$(c suitecrm)" test -e /var/www/html/tmp/clouve-backup/needs-attention && ! docker exec "$(c limesurvey)" test -e /var/www/html/clouve/needs-attention; then ok "and both images removed their notes"; else bad "and both images removed their notes"; fi
run "${S_LS}/upgrade-state.sh"
code "limesurvey upgrade-state.sh: nothing is under way again" 0
run "${S_SC}/upgrade-state.sh"
has "suitecrm upgrade-state.sh: the start-up has finished again" "Start-up: finished (PID 1 is Apache)."
run "${S_LS}/crm-link.sh status"
has "after the restart the plugin is on, as the image leaves it" "SuiteCRM plugin: on"
m8="h$(rnd | cut -c1-6)"
is "a respondent completes a response after both restarts" "submitted" "$(sales_inquiry "${m8}")"
becomes_lead "the response after both restarts" "${m8}"

# --- 11. nothing printed holds a password ----------------------------------------------------------------------------
section "11. No password in anything a script printed"
leaked=0
for s in "${secrets[@]}"; do grep -qF -- "${s}" "${transcript}" && leaked=$((leaked + 1)); done
is "none of the kit's seven passwords is in the output of the $(grep -c '^\$ ' "${transcript}") commands this test ran" "0" "${leaked}"
finish
