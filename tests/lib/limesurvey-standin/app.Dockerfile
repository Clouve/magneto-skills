# A stand-in for Clouve's LimeSurvey image, for the limesurvey skill's tests only. Never pushed.
#
# It has what the skill's scripts rely on, and nothing else of the real image:
#   - LimeSurvey 7.10.0 (upstream's release zip) on upstream's 7.9.1 runtime image, with Apache on 8080;
#   - the clouve-ops account with passwordless sudo and an sshd that takes its password;
#   - default-mysql-client (mariadb, mariadb-dump);
#   - the Apache rule that denies /clouve/, /node_modules/ and /installer/ over the web;
#   - /var/www/html/clouve as root's own folder, mode 700, and the "being restored" page while the skill's restore
#     marker is there;
#   - /clouve/limesurvey/package/plugins, the list of plugins the release ships, and /clouve/limesurvey/image-build.
# The real image is magneto's apps/limesurvey/image. Its entrypoint installs and upgrades the site itself. This one
# hands the install to upstream's entrypoint.
FROM martialblog/limesurvey:7.9.1-261102-apache

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        default-mysql-client openssh-server sudo unzip \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_*

# The 7.10.0 code replaces the base image's copy. The in-app updater is off, as in the real image.
COPY limesurvey.zip /tmp/limesurvey.zip
RUN find /var/www/html -mindepth 1 -maxdepth 1 -exec rm -rf {} + \
    && unzip -q /tmp/limesurvey.zip -d /tmp/unpacked \
    && cp -a /tmp/unpacked/limesurvey/. /var/www/html/ \
    && rm -rf /tmp/limesurvey.zip /tmp/unpacked \
    && sed -i "s/^\\(\\\$config\\['updatable'\\] = \\)true;/\\1false;/" /var/www/html/application/config/version.php \
    && chown -R www-data:www-data /var/www/html \
    && install -d /clouve/limesurvey/package/application/config \
    && cp -a /var/www/html/plugins /clouve/limesurvey/package/plugins \
    && cp /var/www/html/application/config/version.php /clouve/limesurvey/package/application/config/version.php \
    && echo '7.10.0+261109-standin' > /clouve/limesurvey/image-build

RUN useradd --create-home --shell /bin/bash --comment "Clouve operator (test stand-in)" clouve-ops \
    && echo "clouve-ops ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/clouve-ops \
    && chmod 0440 /etc/sudoers.d/clouve-ops

COPY sshd.conf /etc/ssh/sshd_config.d/clouve-ops.conf
COPY apache-clouve.conf /etc/apache2/conf-available/zz-clouve.conf
COPY app-entrypoint.sh /clouve/standin/entrypoint.sh
COPY restoring.php /clouve/standin/restoring.php
RUN a2enconf zz-clouve > /dev/null && chmod +x /clouve/standin/entrypoint.sh && chmod 644 /clouve/standin/restoring.php

ENTRYPOINT ["/clouve/standin/entrypoint.sh"]
CMD ["apache2-foreground"]
