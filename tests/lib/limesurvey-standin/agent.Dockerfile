# A stand-in for the Magneto Agent container, for the limesurvey skill's tests only. Never pushed.
# Ubuntu 24.04, as the agent is, with the packages the plugin's install.sh adds, a non-root user, and a fake
# clv-secret that serves the test's made-up passwords. The passwords are not in any process's environment.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
        default-mysql-client openssh-client sshpass jq curl ca-certificates sudo procps file unzip \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash assistant \
    && echo "assistant ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/assistant \
    && chmod 0440 /etc/sudoers.d/assistant

COPY clv-secret /usr/local/bin/clv-secret
RUN chmod 755 /usr/local/bin/clv-secret

USER assistant
WORKDIR /home/assistant
CMD ["sleep", "infinity"]
