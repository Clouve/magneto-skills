# A stand-in for the Magneto Agent container, for tests/customer-kit-skills.test.sh only. Never shipped, never pushed.
#
# Ubuntu 24.04, as the agent is, with the packages both plugins' install.sh hooks add, gettext-base for the agent's
# context composer (envsubst), and a non-root user with passwordless sudo. The agent's own scripts are copied in
# from a magneto-agent checkout (the test puts them into the build context as agent/): clv-secret and its library,
# the fetchers that read each sibling's persona and settings over the clouve-ops channel, and the composer that
# makes the assistant's context from them. So the settings and secrets the skills see here are the ones the real
# agent derives from the four siblings. Nothing is in the container's environment.
FROM ubuntu:24.04
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        default-mysql-client openssh-client sshpass jq curl ca-certificates sudo procps file unzip util-linux gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash assistant \
    && echo "assistant ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/assistant \
    && chmod 0440 /etc/sudoers.d/assistant
COPY agent/installer /clouve/magneto-agent/installer
COPY agent/context/CONTEXT.md.tpl /clouve/context/CONTEXT.md.tpl
RUN install -m 0755 -o root -g root /clouve/magneto-agent/installer/secrets/clv-secret /usr/local/bin/clv-secret \
    && chmod 755 /clouve/magneto-agent/installer/chat/marketplace/*.sh \
    && chmod a+r /clouve/context/CONTEXT.md.tpl
CMD ["sleep", "infinity"]
