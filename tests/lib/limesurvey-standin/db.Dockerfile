# A stand-in for Clouve's limesurvey-mariadb image, for the limesurvey skill's tests only. Never pushed.
# MariaDB 11.8 with the clouve-ops account, passwordless sudo and an sshd that takes its password.
FROM mariadb:11.8

RUN apt-get update && apt-get install -y --no-install-recommends openssh-server sudo \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (test stand-in)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

COPY sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY db-entrypoint.sh /clouve/standin/entrypoint.sh
RUN chmod +x /clouve/standin/entrypoint.sh

ENTRYPOINT ["/clouve/standin/entrypoint.sh"]
CMD ["mariadbd"]
