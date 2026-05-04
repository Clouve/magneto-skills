#!/bin/bash
# Gibbon plugin — runtime install hook.
#
# Invoked by AI Studio's plugin-stager after the plugin payload is staged
# at /clouve/skills/gibbon/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto/blob/main/apps/ai-studio/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   default-mysql-client (mysql, mysqldump) — scripts/backup.sh and the
#       diagnose / restore playbooks shell out to these to talk to the
#       gibbon-mysql service over TCP.
#   openssh-client + sshpass — the agent ssh's into the gibbon and
#       gibbon-mysql containers as the clouve-ops operator account using
#       `sshpass -e ssh …` with the per-pod password from CLOUVE_OPS_PASSWORD.
#
# These do not belong in the upstream AI Studio image: no other consumer
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
    echo "[gibbon/install] runtime packages already present — skipping apt-get."
    exit 0
fi

echo "[gibbon/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[gibbon/install] apt-get update failed — aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[gibbon/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

# Clean lists to keep /var lean — the dpkg state in /var/lib/dpkg is what
# the gate above relies on, and that survives the cleanup.
rm -rf /var/lib/apt/lists/*

echo "[gibbon/install] runtime packages installed."
