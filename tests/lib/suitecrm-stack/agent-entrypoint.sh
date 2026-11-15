#!/bin/bash
# Stand-in agent start. stack.sh writes the settings to /etc/profile.d/clv-sidecar-env.sh (every login shell
# sources it, as on the Magneto Agent) and the passwords to /run/clouve/secrets.env (root only), which the
# fake clv-secret reads through sudo. Nothing is passed in the container's environment.
set -euo pipefail
install -d -m 700 /run/clouve
: > /run/clouve/secrets.env
chmod 600 /run/clouve/secrets.env
exec sleep infinity
