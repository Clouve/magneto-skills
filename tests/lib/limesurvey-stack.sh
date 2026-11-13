# shellcheck shell=bash
# The stand-in stack of the limesurvey skill's tests (sourced by tests/limesurvey-*.test.sh, not run).
#
# It starts a real LimeSurvey 7.10.0 next to a MariaDB 11.8 and a container that stands in for the Magneto Agent,
# on a Docker network of their own, with no published ports and made-up passwords:
#
#   <prefix>app-N    LimeSurvey (limesurvey-standin/app.Dockerfile), with the clouve-ops sshd
#   <prefix>db-N     MariaDB (limesurvey-standin/db.Dockerfile), with the clouve-ops sshd
#   <prefix>agent-N  the assistant's container (limesurvey-standin/agent.Dockerfile): the skill is mounted read-only
#                    at /clouve/skills/limesurvey/plugin, the app's settings are in its login shells as LIMESURVEY_*
#                    variables, and a fake clv-secret serves the passwords. No password is in its environment.
#   <prefix>smtp     a mail sink (limesurvey-standin/smtp-sink.php) that keeps what it is sent
#
# Settings, all optional:
#   LS_TEST_PREFIX      the prefix of every container, network, volume and image this makes (default lss-test-)
#   LS_TEST_ZIP         the path of limesurvey7.10.0+261109.zip. Without it the zip is downloaded once to
#                       ${XDG_CACHE_HOME:-~/.cache}/clouve-skill-tests/ and checked against its SHA-256.
#   LS_TEST_APP_IMAGE   run this app image instead of the stand-in (the real Clouve image, built from magneto)
#   LS_TEST_DB_IMAGE    run this database image instead of the stand-in
#   LS_TEST_AGENT_IMAGE run this agent stand-in image (built from limesurvey-standin/agent.Dockerfile when it is
#                       missing) instead of <prefix>agent:1, so that runs with different prefixes can share one
#   LS_TEST_APP_ENV     more settings for the app container, as NAME=value pairs separated by spaces (the real
#                       image's ENABLE_SUITECRM_INTEGRATION and SUITECRM_* settings, for a look at the Customer Kit)
#   LS_TEST_KEEP=1      leave the containers up when the test ends, to look around
#
# Functions:
#   ls_stack_images            builds the images that are missing
#   ls_stack_up N              starts database, app and agent N and waits until LimeSurvey answers
#   ls_agent_up N              starts agent N alone (ls_stack_up calls it)
#   ls_stack_smtp              starts the mail sink
#   ls_stack_down              removes everything this made, images excepted
#   agent N COMMAND            runs COMMAND in a login shell of agent N, as the assistant's user, with no stdin
#   agent_in N COMMAND         the same, with this shell's stdin passed through
#   app_root N COMMAND         runs COMMAND in app N as root (the test's own back door, not the skill's channel)
#   app_www N COMMAND          the same as www-data, in /var/www/html
#   db_sql N SQL               runs SQL in database N as the app's user, printing rows tab-separated without a header
#   helper N                   sends a JSON request on stdin to the tests' back door in app N (test-helper.php)
#   sink_count                 how many messages the mail sink has
#   ls_ps_snapshot N FILE      appends the process lists (with arguments) of app, db and agent N to FILE
#   ls_exec_log_install N      from now on, records every start of the programs the skill's scripts run in app, db
#                              and agent N, with their arguments (small wrappers ahead of them on the PATH). A
#                              sampled process list misses a program that lives for milliseconds, and this does not.
#   ls_exec_log_collect N FILE appends what was recorded so far to FILE
#   ls_security_values N       prints the values of app N's security.php (the encryption keys), one per line, for
#                              a test to look for in what the scripts print. Never print what this returns.

LS_TEST_PREFIX="${LS_TEST_PREFIX:-lss-test-}"
LS_TEST_VERSION=7.10.0
LS_TEST_BUILD=261109
LS_TEST_SHA256=05b72d1d424a7a6b8ac5ae86f240e14aabe121c3c4e83295d4e64a928786f9db

ls_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ls_repo_root="$(cd "${ls_lib_dir}/../.." && pwd)"
ls_standin="${ls_lib_dir}/limesurvey-standin"

ls_app_image="${LS_TEST_APP_IMAGE:-${LS_TEST_PREFIX}ls:${LS_TEST_VERSION}}"
ls_db_image="${LS_TEST_DB_IMAGE:-${LS_TEST_PREFIX}db:11.8}"
ls_agent_image="${LS_TEST_AGENT_IMAGE:-${LS_TEST_PREFIX}agent:1}"
ls_net="${LS_TEST_PREFIX}net"

# Made-up passwords. The tests look for each of them in process lists, logs and output.
ls_ops_pw='Ops-Pw-7hQk2Vx9mT'
ls_db_pw='Db-Pw-4tZ8nQ1rLs'
ls_db_root_pw='Root-Pw-2mC5vJ7pGf'
ls_admin_pw='Adm-Pw-9xK3wB6yHd'
ls_admin_user='Test_Admin'
ls_admin_email='admin@example.test'
ls_public_url='https://surveys.example.test'

ls_app() { printf '%sapp-%s' "${LS_TEST_PREFIX}" "$1"; }
ls_db() { printf '%sdb-%s' "${LS_TEST_PREFIX}" "$1"; }
ls_agent() { printf '%sagent-%s' "${LS_TEST_PREFIX}" "$1"; }
ls_smtp="${LS_TEST_PREFIX}smtp"

ls_stack_zip() {
    local zip="${LS_TEST_ZIP:-}" cache
    if [ -z "${zip}" ]; then
        cache="${XDG_CACHE_HOME:-${HOME}/.cache}/clouve-skill-tests"
        zip="${cache}/limesurvey${LS_TEST_VERSION}+${LS_TEST_BUILD}.zip"
        if [ ! -f "${zip}" ]; then
            mkdir -p "${cache}"
            curl -fsSL --retry 3 -o "${zip}.part" \
                "https://download.limesurvey.org/latest-master/limesurvey${LS_TEST_VERSION}+${LS_TEST_BUILD}.zip" || return 1
            mv "${zip}.part" "${zip}"
        fi
    fi
    echo "${LS_TEST_SHA256}  ${zip}" | sha256sum -c - > /dev/null 2>&1 || {
        echo "limesurvey-stack: ${zip} is not LimeSurvey ${LS_TEST_VERSION} build ${LS_TEST_BUILD} (checksum)" >&2
        return 1
    }
    printf '%s\n' "${zip}"
}

ls_have_image() { [ -n "$(docker images -q "$1" 2> /dev/null)" ]; }

ls_stack_images() {
    local ctx zip
    if [ -z "${LS_TEST_APP_IMAGE:-}" ] && ! ls_have_image "${ls_app_image}"; then
        zip="$(ls_stack_zip)" || return 1
        ctx="$(mktemp -d "${TMPDIR:-/tmp}/limesurvey-standin.XXXXXX")"
        cp "${ls_standin}"/sshd.conf "${ls_standin}"/apache-clouve.conf "${ls_standin}"/app-entrypoint.sh "${ls_standin}"/restoring.php "${ctx}/"
        cp "${zip}" "${ctx}/limesurvey.zip"
        docker build -q -t "${ls_app_image}" -f "${ls_standin}/app.Dockerfile" "${ctx}" > /dev/null || { rm -rf "${ctx}"; return 1; }
        rm -rf "${ctx}"
    fi
    if [ -z "${LS_TEST_DB_IMAGE:-}" ] && ! ls_have_image "${ls_db_image}"; then
        docker build -q -t "${ls_db_image}" -f "${ls_standin}/db.Dockerfile" "${ls_standin}" > /dev/null || return 1
    fi
    if ! ls_have_image "${ls_agent_image}"; then
        docker build -q -t "${ls_agent_image}" -f "${ls_standin}/agent.Dockerfile" "${ls_standin}" > /dev/null || return 1
    fi
}

# ls_wait SECONDS COMMAND...: runs COMMAND once a second until it succeeds
ls_wait() {
    local left="$1"
    shift
    while [ "${left}" -gt 0 ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        sleep 1
        left=$((left - 1))
    done
    return 1
}

# ls_agent_up N: starts agent N, with the skill mounted and the settings of app N and database N in its login shells
ls_agent_up() {
    local n="$1" app db agent
    app="$(ls_app "${n}")" db="$(ls_db "${n}")" agent="$(ls_agent "${n}")"
    docker run -d --init --name "${agent}" --hostname "${agent}" --network "${ls_net}" --memory 1g \
        -v "${ls_repo_root}/plugins/limesurvey:/clouve/skills/limesurvey/plugin:ro" \
        "${ls_agent_image}" > /dev/null || return 1
    # What the Magneto Agent puts in every login shell: the siblings' settings, never a password.
    docker exec -i -u root "${agent}" sh -c 'cat > /etc/profile.d/clv-sidecar-env.sh' <<ENV
export LIMESURVEY_HOST='${app}'
export LIMESURVEY_PUBLIC_URL='${ls_public_url}'
export LIMESURVEY_ADMIN_USER='${ls_admin_user}'
export LIMESURVEY_ADMIN_NAME='Test Admin'
export LIMESURVEY_ADMIN_EMAIL='${ls_admin_email}'
export LIMESURVEY_DB_TYPE='mysql'
export LIMESURVEY_DB_HOST='${db}'
export LIMESURVEY_DB_PORT='3306'
export LIMESURVEY_DB_NAME='limesurvey'
export LIMESURVEY_DB_USER='limesurvey'
export LIMESURVEY_DB_USERNAME='limesurvey'
export LIMESURVEY_MARIADB_HOST='${db}'
ENV
    # What clv-secret serves. Root's, mode 0600, as on the agent.
    docker exec -i -u root "${agent}" sh -c 'install -d -m 755 /run/clouve && umask 077 && cat > /run/clouve/secrets.env' <<SECRETS
CLOUVE_OPS_PASSWORD=${ls_ops_pw}
LIMESURVEY_DB_PASSWORD=${ls_db_pw}
LIMESURVEY_ADMIN_PASSWORD=${ls_admin_pw}
LIMESURVEY_MARIADB_MYSQL_PASSWORD=${ls_db_pw}
LIMESURVEY_MARIADB_MYSQL_ROOT_PASSWORD=${ls_db_root_pw}
SECRETS
}

ls_stack_up() {
    local n="$1" app db agent pair extra=()
    app="$(ls_app "${n}")" db="$(ls_db "${n}")" agent="$(ls_agent "${n}")"
    for pair in ${LS_TEST_APP_ENV:-}; do extra+=(-e "${pair}"); done
    # Docker makes a missing bind-mount source itself, as root. Stop before it can.
    [ -d "${ls_repo_root}/plugins/limesurvey/skills/limesurvey/scripts" ] || {
        echo "limesurvey-stack: ${ls_repo_root}/plugins/limesurvey has no skill to mount" >&2
        return 1
    }
    docker network inspect "${ls_net}" > /dev/null 2>&1 || docker network create "${ls_net}" > /dev/null || return 1
    docker run -d --name "${db}" --hostname "${db}" --network "${ls_net}" --memory 2g \
        -v "${LS_TEST_PREFIX}dbdata-${n}:/var/lib/mysql" \
        -e MYSQL_DATABASE=limesurvey -e MYSQL_USER=limesurvey -e MYSQL_PASSWORD="${ls_db_pw}" \
        -e MYSQL_ROOT_PASSWORD="${ls_db_root_pw}" -e CLOUVE_OPS_PASSWORD="${ls_ops_pw}" \
        "${ls_db_image}" > /dev/null || return 1
    docker run -d --name "${app}" --hostname "${app}" --network "${ls_net}" --memory 2g \
        -v "${LS_TEST_PREFIX}html-${n}:/var/www/html" -v "${LS_TEST_PREFIX}upload-${n}:/var/www/html/upload" \
        -e DB_TYPE=mysql -e DB_HOST="${db}" -e DB_PORT=3306 -e DB_NAME=limesurvey -e DB_USERNAME=limesurvey \
        -e DB_PASSWORD="${ls_db_pw}" -e ADMIN_USER="${ls_admin_user}" -e ADMIN_NAME='Test Admin' \
        -e ADMIN_EMAIL="${ls_admin_email}" -e ADMIN_PASSWORD="${ls_admin_pw}" -e PUBLIC_URL="${ls_public_url}" \
        -e INSTALL_DEMO_DATA=false -e CLOUVE_OPS_PASSWORD="${ls_ops_pw}" \
        ${extra[@]+"${extra[@]}"} "${ls_app_image}" > /dev/null || return 1
    ls_agent_up "${n}" || return 1
    # LimeSurvey answers, its tables are there, and both sshds take connections.
    ls_wait 240 ls_app_answers "${app}" || {
        echo "limesurvey-stack: ${app} did not answer on 8080; its last lines:" >&2
        docker logs --tail 20 "${app}" >&2 2>&1
        return 1
    }
    ls_wait 60 docker exec "${app}" sh -c 'cd /var/www/html && test -f application/config/config.php && test -f application/config/security.php' || return 1
    ls_wait 60 docker exec "${agent}" bash -c "(exec 3<>/dev/tcp/${app}/22) 2>/dev/null" || return 1
    ls_helper_install "${n}"
}

# ls_helper_install N: puts the tests' back door (limesurvey-standin/test-helper.php) and the skill's remote/lib,
# which it starts LimeSurvey with, into app N, outside the volumes
ls_helper_install() {
    local app
    app="$(ls_app "$1")"
    docker exec -u root "${app}" sh -c 'rm -rf /opt/lss-test && mkdir -p /opt/lss-test/remote' || return 1
    docker cp -q "${ls_repo_root}/plugins/limesurvey/skills/limesurvey/scripts/remote/lib" "${app}:/opt/lss-test/remote/lib" || return 1
    docker cp -q "${ls_standin}/test-helper.php" "${app}:/opt/lss-test/helper.php" || return 1
    docker exec -u root "${app}" chmod -R a+rX /opt/lss-test
}

# helper N: sends the JSON request on stdin to the tests' back door in app N, and prints its one-line reply
helper() {
    docker exec -i -u www-data -w /var/www/html "$(ls_app "$1")" php /opt/lss-test/helper.php
}

# ls_app_answers CONTAINER: the install is over and LimeSurvey itself answers on 8080: Apache is PID 1 (the real
# image answers with a stand-in page while it installs), and no install stamp is left. A container that has stopped
# ends the wait at once.
ls_app_answers() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2> /dev/null)" = true ] || { sleep 3; return 1; }
    docker exec "$1" sh -c '[ "$(cat /proc/1/comm)" = apache2 ] && [ ! -e /var/www/html/clouve/install-in-progress ] && curl -fsS -o /dev/null http://localhost:8080/'
}

ls_stack_smtp() {
    docker run -d --name "${ls_smtp}" --hostname "${ls_smtp}" --network "${ls_net}" --memory 512m \
        --entrypoint php -v "${ls_standin}/smtp-sink.php:/sink.php:ro" "${ls_app_image}" /sink.php > /dev/null
}

ls_stack_down() {
    local names
    [ "${LS_TEST_KEEP:-0}" = 1 ] && return 0
    names="$(docker ps -aq --filter "name=^${LS_TEST_PREFIX}(app|db|agent)-[0-9]+$" --filter "name=^${ls_smtp}$" --filter "name=^${LS_TEST_PREFIX}install$")"
    # shellcheck disable=SC2086  # one id per word
    [ -z "${names}" ] || docker rm -f -v ${names} > /dev/null 2>&1
    names="$(docker volume ls -q --filter "name=^${LS_TEST_PREFIX}(dbdata|html|upload)-[0-9]+$")"
    # shellcheck disable=SC2086
    [ -z "${names}" ] || docker volume rm ${names} > /dev/null 2>&1
    docker network rm "${ls_net}" > /dev/null 2>&1 || true
}

agent() {
    local n="$1"
    shift
    docker exec -u assistant "$(ls_agent "${n}")" bash -lc "$*" < /dev/null
}
agent_in() {
    local n="$1"
    shift
    docker exec -i -u assistant "$(ls_agent "${n}")" bash -lc "$*"
}
app_root() {
    local n="$1"
    shift
    docker exec -i -u root "$(ls_app "${n}")" bash -c "$*"
}
app_www() {
    local n="$1"
    shift
    docker exec -i -u www-data -w /var/www/html "$(ls_app "${n}")" bash -c "$*"
}
db_sql() {
    local n="$1"
    shift
    docker exec -i -e MYSQL_PWD="${ls_db_pw}" "$(ls_db "${n}")" mariadb -N -B -u limesurvey limesurvey -e "$*"
}
sink_count() {
    docker exec "${ls_smtp}" sh -c 'test -f /tmp/sink.jsonl && wc -l < /tmp/sink.jsonl || echo 0' | tr -d ' '
}
ls_ps_snapshot() {
    local n="$1" file="$2" c
    for c in "$(ls_app "${n}")" "$(ls_db "${n}")" "$(ls_agent "${n}")"; do
        docker exec -u root "${c}" sh -c 'for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null; echo; done' >> "${file}" 2> /dev/null || true
    done
}

# The programs whose starts are recorded, per container. The wrappers sit in /usr/local/sbin, which comes first on
# the PATH of a login shell, of an ssh session and of sudo, and each one starts the real program it finds further
# down the PATH.
ls_exec_log_names_app='bash sh php mariadb mariadb-dump mysql mysqldump sudo tar gzip zcat sed sha256sum curl find chmod chown cp mv rm install timeout cat'
ls_exec_log_names_db='bash sh mariadb mysql sudo'
ls_exec_log_names_agent='bash sh ssh sshpass jq mysql mariadb curl tar base64 sha256sum sudo cat'
ls_exec_log_install() {
    local n="$1" kind c names
    for kind in app db agent; do
        case "${kind}" in
            app) c="$(ls_app "${n}")" names="${ls_exec_log_names_app}" ;;
            db) c="$(ls_db "${n}")" names="${ls_exec_log_names_db}" ;;
            agent) c="$(ls_agent "${n}")" names="${ls_exec_log_names_agent}" ;;
        esac
        docker exec -i -u root "${c}" sh -s -- ${names} <<'WRAP' || return 1
: > /var/log/lss-exec.log
chmod 666 /var/log/lss-exec.log
mkdir -p /usr/local/sbin
for name in "$@"; do
    real=''
    for d in /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
        if [ -x "$d/$name" ]; then real="$d/$name"; break; fi
    done
    [ -n "$real" ] || continue
    printf '#!/bin/sh\n# tests only: records each start of %s with its arguments, then becomes it\nprintf "%%s %%s\\n" "%s" "$*" >> /var/log/lss-exec.log 2> /dev/null\nexec %s "$@"\n' "$name" "$name" "$real" > "/usr/local/sbin/$name"
    chmod 755 "/usr/local/sbin/$name"
done
WRAP
    done
}
ls_exec_log_collect() {
    local n="$1" file="$2" c
    for c in "$(ls_app "${n}")" "$(ls_db "${n}")" "$(ls_agent "${n}")"; do
        docker exec -u root "${c}" cat /var/log/lss-exec.log >> "${file}" 2> /dev/null || true
    done
}
ls_security_values() {
    docker exec -i -u www-data "$(ls_app "$1")" php -r '
        define("BASEPATH", "/nonexistent/");
        $c = include "/var/www/html/application/config/security.php";
        foreach ((array) $c as $v) { if (is_string($v) && strlen($v) >= 16) { echo $v, "\n"; } }' 2> /dev/null
}
