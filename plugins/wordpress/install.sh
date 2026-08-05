#!/bin/bash
# WordPress plugin — runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/wordpress/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   default-mysql-client (mysql, mysqldump) — scripts/backup.sh,
#       scripts/verify-health.sh, scripts/flush-transients.sh and the
#       diagnose / restore playbooks talk to the WordPress database over TCP
#       with these.
#   openssh-client + sshpass — the conditional shell channel: WordPress
#       playbooks probe for a clouve-ops SSH account on the sibling
#       containers (`sshpass -e ssh …` with the per-pod password from
#       CLOUVE_OPS_PASSWORD). Today's WordPress images do not ship sshd, so
#       the probe is expected to fail — the tools are here so the channel
#       lights up the moment a sibling image adds the account, without a
#       skill re-release.
#
# These do not belong in the upstream Magneto Agent image: no other consumer
# needs them, and shipping sshpass by default expands the platform's attack
# surface for tenants that don't use SSH-based ops at all. They live here
# so the deps travel with the skill that needs them.
#
# Idempotency: dpkg-query gates each package, so re-runs on subsequent
# container starts are a no-op aside from the dpkg lookup itself.

set -u

REQUIRED_PACKAGES=(default-mysql-client openssh-client sshpass)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[wordpress/install] runtime packages already present — skipping apt-get."
    exit 0
fi

echo "[wordpress/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[wordpress/install] apt-get update failed — aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[wordpress/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

# Clean lists to keep /var lean — the dpkg state in /var/lib/dpkg is what
# the gate above relies on, and that survives the cleanup.
rm -rf /var/lib/apt/lists/*

echo "[wordpress/install] runtime packages installed."
