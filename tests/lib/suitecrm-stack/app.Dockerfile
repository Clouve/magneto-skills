# Stand-in for Clouve's SuiteCRM image, for tests/suitecrm-*.test.sh only. Never shipped, never pushed.
#
# It adds what the real image's contract promises on top of a plain SuiteCRM 8.10.2 image (PHP 8.3, the
# release unpacked at /clouve/suitecrm/app, default-mysql-client): the clouve-ops account with passwordless
# sudo, an sshd with password sign-in, and an entrypoint that installs SuiteCRM as www-data, starts the two
# background loops and ends as Apache in PID 1. tests/lib/suitecrm-stack/stack.sh builds it.
ARG BASE=lsres-suitecrm:8.10.2-php8.3
FROM ${BASE}
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server sudo openssl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd \
    && useradd --create-home --shell /bin/bash --comment "Clouve operator (stand-in)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops
COPY app-entrypoint.sh /clouve/standin-entrypoint.sh
RUN chmod 755 /clouve/standin-entrypoint.sh
ENTRYPOINT ["/clouve/standin-entrypoint.sh"]
