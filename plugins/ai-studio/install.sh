#!/bin/bash
# AI Studio plugin — runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is
# staged at /clouve/skills/ai-studio/plugin/. The contract for hooks
# lives at the plugin-stager source in the magneto-agent repo.
#
# Installs:
#   openssh-client + sshpass — the only way the agent reaches a sibling
#     workspace. Same pattern moodle and gibbon use (their hooks add
#     mysql-client too; ai-studio doesn't need that).
#
# Lives here, not in the upstream Magneto Agent image, so the deps travel
# with the skill that needs them — tenants without ai-studio don't
# pay for sshpass-shaped attack surface.
#
# Idempotency: dpkg-query gates each package; re-runs on subsequent
# container starts are a no-op aside from the dpkg lookup. Required
# because the plugin-stager invokes this on every container start.

set -u

REQUIRED_PACKAGES=(openssh-client sshpass)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ ${#missing[@]} -eq 0 ]; then
    echo "[ai-studio/install] runtime packages already present."
    exit 0
fi

echo "[ai-studio/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[ai-studio/install] apt-get update failed — aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[ai-studio/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

rm -rf /var/lib/apt/lists/*

echo "[ai-studio/install] runtime packages installed."
