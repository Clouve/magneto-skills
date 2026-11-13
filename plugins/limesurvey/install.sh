#!/bin/bash
# LimeSurvey plugin: runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/limesurvey/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   openssh-client + sshpass: every script. They reach the LimeSurvey container
#       through the clouve-ops SSH account (`sshpass -e ssh ...`, with the
#       per-pod password from CLOUVE_OPS_PASSWORD), all through
#       run-in-limesurvey.sh, which sends the skill's in-container scripts
#       (scripts/remote/) there and runs them.
#   default-mysql-client (mysql): verify-health.sh checks the database over
#       TCP with it, and the read-only queries in the references use it. The
#       agent's client only reads. Dumps and restores run inside the LimeSurvey
#       container with its own client.
#   jq: every script builds its request and reads the reply as JSON with it.
#   curl: survey-import.sh and verify-health.sh ask LimeSurvey's own port
#       what a visitor would get.
#
# tar, gzip, base64 and sha256sum are part of the agent's base system.
#
# These stay out of the upstream Magneto Agent image on purpose. Tenants who
# don't run a skill that needs them shouldn't get sshpass by default, because
# it widens the platform's attack surface. They live here so the dependencies
# travel with the skill whose scripts use them.
#
# Idempotency: dpkg-query gates each package, so re-runs on later container
# starts do nothing beyond the dpkg lookup.

set -u

REQUIRED_PACKAGES=(default-mysql-client openssh-client sshpass jq curl)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[limesurvey/install] runtime packages already present, skipping apt-get."
    exit 0
fi

echo "[limesurvey/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[limesurvey/install] apt-get update failed, aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[limesurvey/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

# Clean lists to keep /var lean. The dpkg state in /var/lib/dpkg is what
# the gate above relies on, and that survives the cleanup.
rm -rf /var/lib/apt/lists/*

echo "[limesurvey/install] runtime packages installed."
