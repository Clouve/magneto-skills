#!/bin/bash
# SuiteCRM plugin: runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/suitecrm/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   openssh-client + sshpass: every script. They reach the SuiteCRM container
#       through the clouve-ops SSH account (`sshpass -e ssh ...`, with the
#       per-pod password from CLOUVE_OPS_PASSWORD), all through
#       run-in-suitecrm.sh, which sends the skill's own scripts there.
#   default-mysql-client (mysql): verify-health.sh asks the database a few
#       fixed questions over TCP with it. The agent's client only reads.
#       sql-read.sh does not use it: its query runs inside the SuiteCRM
#       container. Dumps and restores run there too, with its own client.
#   jq: temp-password.sh and upgrade-state.sh read the JSON the scripts print,
#       and the playbooks use it to pick a field out of a result.
#   curl: verify-health.sh asks SuiteCRM's /session-status whether the app
#       answers.
#   unzip: packages.sh inspect unpacks a Module Loader package on the agent to
#       read it before anything is installed.
#
# These stay out of the upstream Magneto Agent image on purpose. Tenants who
# don't run a skill that needs them shouldn't get sshpass by default, because
# it widens the platform's attack surface. They live here so the dependencies
# travel with the skill whose scripts use them.
#
# Idempotency: dpkg-query gates each package, so re-runs on later container
# starts do nothing beyond the dpkg lookup.

set -u

REQUIRED_PACKAGES=(default-mysql-client openssh-client sshpass jq curl unzip)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[suitecrm/install] runtime packages already present, skipping apt-get."
    exit 0
fi

echo "[suitecrm/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[suitecrm/install] apt-get update failed, aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[suitecrm/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

# Clean lists to keep /var lean. The dpkg state in /var/lib/dpkg is what
# the gate above relies on, and that survives the cleanup.
rm -rf /var/lib/apt/lists/*

echo "[suitecrm/install] runtime packages installed."
