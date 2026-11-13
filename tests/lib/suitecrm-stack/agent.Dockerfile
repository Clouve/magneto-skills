# Stand-in for the Magneto Agent container, for tests/suitecrm-*.test.sh only. Never shipped, never pushed.
#
# Ubuntu 24.04, as the agent's image is, with the packages the suitecrm plugin's install.sh adds, a non-root
# user with passwordless sudo, and a fake clv-secret that serves the passwords from a root-only file, so that
# no password is in the user's environment. The skill is mounted read-only at /clouve/skills/suitecrm/plugin.
FROM ubuntu:24.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-client sshpass default-mysql-client jq curl unzip sudo ca-certificates procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash clouve \
    && echo "clouve ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve \
    && chmod 0440 /etc/sudoers.d/clouve
COPY agent-entrypoint.sh /usr/local/bin/agent-entrypoint.sh
COPY clv-secret /usr/local/bin/clv-secret
RUN chmod 755 /usr/local/bin/agent-entrypoint.sh /usr/local/bin/clv-secret
ENTRYPOINT ["/usr/local/bin/agent-entrypoint.sh"]
