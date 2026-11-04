# shellcheck shell=bash
# WordPress DevOps Skill: lib/wp-remote.sh, sourced by wp.sh and temp-password.sh.
#
# wp_remote_command ARGS...: prints the command that runs `wp --path=/var/www/html ARGS` in the
# WordPress container as www-data. The clouve-ops login shell there (bash) runs it over SSH.
#
# Why it isn't just `sudo -u www-data wp ...`: the official image's wp-config.php reads the
# database settings from the environment (getenv_docker), and an SSH session doesn't inherit the
# container's environment. A plain wp over SSH stops with "Error establishing a database
# connection" on any command that loads the database. So the command first takes WordPress's
# settings from the environment of the container's first process, where Docker and Kubernetes put
# them. It reads /proc/1/environ as that process's owner, as the Magneto Agent's
# sidecar-env-fetcher.sh does. The read is a shell builtin, so the values go from that file into
# the shell's environment and on to wp through sudo --preserve-env, and never onto a command
# line. Only the names the official image's wp-config.php reads are kept (the database settings,
# the table prefix, WORDPRESS_DEBUG, WORDPRESS_CONFIG_EXTRA and the eight keys and salts, each
# also as NAME_FILE), so the deployment's admin password and the rest stay out of wp's reach.
# When the file can't be read, wp runs without them, and both errors come back on stderr.
#
# Each of ARGS is quoted with printf %q, which the remote bash decodes, so an argument with
# spaces, quotes, $, ;, &, a newline or a * reaches wp as one argument, unexpanded. The command
# reads nothing from stdin before wp starts, so wp gets the channel's stdin whole.
wp_remote_command() {
    local remote arg quoted
    # shellcheck disable=SC2016  # expanded by the shell in the WordPress container
    remote='names=""
while IFS= read -r -d "" kv; do
    name="${kv%%=*}"
    case "${name}" in WORDPRESS_?*) ;; *) continue ;; esac
    setting="${name#WORDPRESS_}"
    case "${setting%_FILE}" in
        DB_HOST | DB_USER | DB_PASSWORD | DB_NAME | DB_CHARSET | DB_COLLATE | TABLE_PREFIX | DEBUG | CONFIG_EXTRA \
            | AUTH_KEY | SECURE_AUTH_KEY | LOGGED_IN_KEY | NONCE_KEY \
            | AUTH_SALT | SECURE_AUTH_SALT | LOGGED_IN_SALT | NONCE_SALT) ;;
        *) continue ;;
    esac
    export "${kv}"
    names="${names:+${names},}${name}"
done < <(sudo -n -u "$(stat -c %U /proc/1)" cat /proc/1/environ < /dev/null)
sudo -n ${names:+--preserve-env="${names}"} -u www-data wp --path=/var/www/html'
    for arg in "$@"; do
        printf -v quoted ' %q' "${arg}"
        remote+="${quoted}"
    done
    printf '%s' "${remote}"
}
