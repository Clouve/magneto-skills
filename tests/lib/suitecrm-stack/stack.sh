# shellcheck shell=bash
# tests/lib/suitecrm-stack/stack.sh (sourced by tests/suitecrm-scripts.test.sh and
# tests/suitecrm-skill-commands.test.sh, not run)
#
# Starts a throwaway SuiteCRM 8.10.2 stack in Docker for the suitecrm plugin's tests and takes it down again:
#   <prefix>-db-<id>     MariaDB 12.3
#   <prefix>-app-<id>    SuiteCRM, with the clouve-ops sshd (the stand-in image built from app.Dockerfile,
#                        or the real image named in SC_STACK_APP_IMAGE)
#   <prefix>-agent-<id>  the Magneto Agent's stand-in: the sibling settings in its login shells, a fake
#                        clv-secret, and the plugin mounted read-only at /clouve/skills/suitecrm/plugin
# on the network <prefix>-net-<id>, with one volume for the app and one for the database. No host port is
# published and nothing is pushed. Every name starts with SC_STACK_PREFIX (default lsb-scs), and
# sc_stack_down removes exactly what sc_stack_up made.
#
# Settings (environment):
#   SC_STACK_PREFIX      name prefix (default lsb-scs)
#   SC_STACK_BASE_IMAGE  the plain SuiteCRM 8.10.2 image the stand-in is built on
#                        (default lsres-suitecrm:8.10.2-php8.3)
#   SC_STACK_APP_IMAGE   use this image for the app as it is (Clouve's real SuiteCRM image), and build no stand-in
#   SC_STACK_DB_IMAGE    the database image (default mariadb:12.3)
#
# Functions:
#   sc_stack_build            builds the images that are missing; returns 3 when the base image is not here
#   sc_stack_up ID            starts the stack and waits until SuiteCRM answers and its sshd takes a login
#   sc_stack_down             removes the containers, the network and the volumes
#   sc_agent CMD              runs CMD in the agent container as the non-root user, in a login shell
#   sc_agent_stdin CMD        the same, with this shell's stdin passed on
#   sc_app_root CMD           runs CMD in the app container as root
#   sc_app_www CMD            runs CMD in the app container as www-data, in /var/www/html
#   sc_db_sql SQL             runs SQL in the database as the app's user and prints the rows, tab-separated
# The passwords are made up here and are the same for every run; they are exported as SC_PW_* for the tests'
# sweeps and never printed.

SC_STACK_PREFIX="${SC_STACK_PREFIX:-lsb-scs}"
SC_STACK_BASE_IMAGE="${SC_STACK_BASE_IMAGE:-lsres-suitecrm:8.10.2-php8.3}"
SC_STACK_DB_IMAGE="${SC_STACK_DB_IMAGE:-mariadb:12.3}"
SC_STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC_STACK_PLUGIN="$(cd "${SC_STACK_DIR}/../../.." && pwd)/plugins/suitecrm"

SC_PW_OPS='Ops-Pw-7hQk2Vx9mT'
SC_PW_DB='Db-Pw-4nWz8Rb3yK'
SC_PW_DBROOT='Root-Pw-9cJt5Lm2xQ'
SC_PW_ADMIN='Adm-Pw-6fGs1Hd8vN'
SC_ADMIN_USER='owner@example.test'
SC_SITE_URL='https://crm.example.test'

sc_stack_app_image() {
    if [ -n "${SC_STACK_APP_IMAGE:-}" ]; then printf '%s' "${SC_STACK_APP_IMAGE}"; else printf '%s' "${SC_STACK_PREFIX}-suitecrm-standin:8.10.2"; fi
}

sc_stack_build() {
    if [ -z "${SC_STACK_APP_IMAGE:-}" ]; then
        if ! docker image inspect "${SC_STACK_BASE_IMAGE}" > /dev/null 2>&1; then
            echo "suitecrm-stack: the image ${SC_STACK_BASE_IMAGE} is not on this machine (a plain SuiteCRM 8.10.2 image; set SC_STACK_BASE_IMAGE, or SC_STACK_APP_IMAGE for Clouve's own image)" >&2
            return 3
        fi
        docker build -q --build-arg "BASE=${SC_STACK_BASE_IMAGE}" -t "$(sc_stack_app_image)" \
            -f "${SC_STACK_DIR}/app.Dockerfile" "${SC_STACK_DIR}" > /dev/null || return 1
    fi
    docker build -q -t "${SC_STACK_PREFIX}-agent:1" -f "${SC_STACK_DIR}/agent.Dockerfile" "${SC_STACK_DIR}" > /dev/null || return 1
}

# sc_stack_up ID [app volume to reuse]
sc_stack_up() {
    SC_ID="$1"
    SC_NET="${SC_STACK_PREFIX}-net-${SC_ID}"
    SC_DB="${SC_STACK_PREFIX}-db-${SC_ID}"
    SC_APP="${SC_STACK_PREFIX}-app-${SC_ID}"
    SC_AGENT="${SC_STACK_PREFIX}-agent-${SC_ID}"
    SC_VOL_APP="${SC_STACK_PREFIX}-appdata-${SC_ID}"
    SC_VOL_DB="${SC_STACK_PREFIX}-dbdata-${SC_ID}"
    # Docker makes a missing bind-mount source as a folder owned by root, so the plugin has to be there first.
    if [ ! -f "${SC_STACK_PLUGIN}/.claude-plugin/plugin.json" ]; then
        echo "suitecrm-stack: ${SC_STACK_PLUGIN} is not the suitecrm plugin" >&2
        return 1
    fi
    docker network create "${SC_NET}" > /dev/null || return 1
    docker volume create "${SC_VOL_APP}" > /dev/null || return 1
    docker volume create "${SC_VOL_DB}" > /dev/null || return 1
    docker run -d --name "${SC_DB}" --network "${SC_NET}" --network-alias suitecrm-mariadb --memory 1g \
        -e MYSQL_DATABASE=suitecrm -e MYSQL_USER=suitecrm -e "MYSQL_PASSWORD=${SC_PW_DB}" \
        -e "MYSQL_ROOT_PASSWORD=${SC_PW_DBROOT}" -e "CLOUVE_OPS_PASSWORD=${SC_PW_OPS}" \
        -v "${SC_VOL_DB}:/var/lib/mysql" "${SC_STACK_DB_IMAGE}" > /dev/null || return 1
    docker run -d --name "${SC_APP}" --network "${SC_NET}" --network-alias suitecrm --memory 3g \
        -e DATABASE_HOST="${SC_DB}" -e DATABASE_PORT=3306 -e DATABASE_NAME=suitecrm -e DATABASE_USER=suitecrm \
        -e "DATABASE_PASSWORD=${SC_PW_DB}" -e "SUITECRM_URL=${SC_SITE_URL}" \
        -e "SUITECRM_ADMIN_USER=${SC_ADMIN_USER}" -e "SUITECRM_ADMIN_PASSWORD=${SC_PW_ADMIN}" \
        -e SUITECRM_INSTALL_DEMO_DATA=no -e "CLOUVE_OPS_PASSWORD=${SC_PW_OPS}" \
        -v "${SC_VOL_APP}:/var/www/html" "$(sc_stack_app_image)" > /dev/null || return 1
    docker run -d --name "${SC_AGENT}" --network "${SC_NET}" --memory 1g \
        -v "${SC_STACK_PLUGIN}:/clouve/skills/suitecrm/plugin:ro" "${SC_STACK_PREFIX}-agent:1" > /dev/null || return 1
    # The agent's settings and secrets, as its sidecar-env-fetcher would leave them.
    docker exec -i "${SC_AGENT}" bash -c 'cat > /etc/profile.d/clv-sidecar-env.sh' <<EOS || return 1
export SUITECRM_HOST=${SC_APP}
export SUITECRM_URL=${SC_SITE_URL}
export SUITECRM_ADMIN_USER=${SC_ADMIN_USER}
export SUITECRM_DB_HOST=${SC_DB}
export SUITECRM_DB_NAME=suitecrm
export SUITECRM_DB_USER=suitecrm
export SUITECRM_DATABASE_HOST=${SC_DB}
export SUITECRM_DATABASE_PORT=3306
export SUITECRM_DATABASE_NAME=suitecrm
export SUITECRM_DATABASE_USER=suitecrm
export SUITECRM_MARIADB_HOST=${SC_DB}
EOS
    docker exec -i "${SC_AGENT}" bash -c 'for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f /run/clouve/secrets.env ] && break; sleep 0.5; done; cat > /run/clouve/secrets.env && chmod 600 /run/clouve/secrets.env' <<EOS || return 1
CLOUVE_OPS_PASSWORD=${SC_PW_OPS}
SUITECRM_DB_PASSWORD=${SC_PW_DB}
SUITECRM_DATABASE_PASSWORD=${SC_PW_DB}
SUITECRM_ADMIN_PASSWORD=${SC_PW_ADMIN}
SUITECRM_MARIADB_MYSQL_PASSWORD=${SC_PW_DB}
SUITECRM_MARIADB_MYSQL_ROOT_PASSWORD=${SC_PW_DBROOT}
EOS
    sc_stack_wait
}

# sc_stack_wait: SuiteCRM answers /session-status with "installed":true and the sshd takes the agent's login
sc_stack_wait() {
    local i
    for i in $(seq 1 180); do
        if docker exec "${SC_APP}" sh -c 'curl -fsS -m 5 http://localhost/session-status 2>/dev/null' 2> /dev/null | grep -q '"installed":true'; then
            if sc_agent 'SSHPASS="$(clv-secret CLOUVE_OPS_PASSWORD)" sshpass -e ssh -n -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 clouve-ops@${SUITECRM_HOST} true' > /dev/null 2>&1; then
                return 0
            fi
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "${SC_APP}" 2> /dev/null)" != true ]; then
            echo "suitecrm-stack: the app container stopped:" >&2
            docker logs --tail 30 "${SC_APP}" >&2
            return 1
        fi
        sleep 1
    done
    echo "suitecrm-stack: SuiteCRM did not come up in 180 seconds:" >&2
    docker logs --tail 30 "${SC_APP}" >&2
    return 1
}

sc_stack_down() {
    [ -n "${SC_ID:-}" ] || return 0
    docker rm -f "${SC_AGENT}" "${SC_APP}" "${SC_DB}" > /dev/null 2>&1
    docker volume rm "${SC_VOL_APP}" "${SC_VOL_DB}" > /dev/null 2>&1
    docker network rm "${SC_NET}" > /dev/null 2>&1
    SC_ID=''
}

sc_agent() { docker exec -u clouve -w /home/clouve "${SC_AGENT}" bash -lc "$1" < /dev/null; }
sc_agent_stdin() { docker exec -i -u clouve -w /home/clouve "${SC_AGENT}" bash -lc "$1"; }
sc_app_root() { docker exec "${SC_APP}" bash -c "$1" < /dev/null; }
sc_app_www() { docker exec -u www-data -w /var/www/html "${SC_APP}" bash -c "$1" < /dev/null; }
sc_db_sql() { docker exec -e "MYSQL_PWD=${SC_PW_DB}" "${SC_DB}" mariadb -N -B -u suitecrm suitecrm -e "$1" < /dev/null; }
