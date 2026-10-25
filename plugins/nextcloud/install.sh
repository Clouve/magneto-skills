#!/bin/bash
# Nextcloud plugin: runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/nextcloud/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   openssh-client + sshpass: every script. They reach the Nextcloud container
#       through the clouve-ops SSH account (`sshpass -e ssh ...`, with the
#       per-pod password from CLOUVE_OPS_PASSWORD), directly or through
#       occ.sh. backup.sh and restore.sh run inside the container, and
#       run-in-nextcloud.sh sends them there.
#   default-mysql-client (mysql): verify-health.sh and the read-only queries
#       in the references and playbooks reach the database over TCP with it.
#       The agent's client only reads. Dumps and restores run inside the
#       Nextcloud container with its own client.
#   jq + curl: share-as-admin.sh and verify-health.sh. curl calls Nextcloud's
#       HTTP endpoints (the files_sharing OCS API, status.php, the login page)
#       and jq reads the JSON that comes back.
#   openssl: the install-or-update-app playbook checks a store release that it
#       reviews against the app store's certificate and signature (openssl
#       x509, openssl dgst), the way Nextcloud checks its own download. The
#       agent's image has it today only because ca-certificates depends on it;
#       listing it here keeps the dependency explicit.
#
# These stay out of the upstream Magneto Agent image on purpose. Tenants who
# don't run a skill that needs them shouldn't get sshpass by default, because
# it widens the platform's attack surface. They live here so the dependencies
# travel with the skill whose scripts use them.
#
# Idempotency: dpkg-query gates each package, so re-runs on later container
# starts do nothing beyond the dpkg lookup.

set -u

REQUIRED_PACKAGES=(default-mysql-client openssh-client sshpass jq curl openssl)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[nextcloud/install] runtime packages already present, skipping apt-get."
    exit 0
fi

echo "[nextcloud/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[nextcloud/install] apt-get update failed, aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[nextcloud/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

# Clean lists to keep /var lean. The dpkg state in /var/lib/dpkg is what
# the gate above relies on, and that survives the cleanup.
rm -rf /var/lib/apt/lists/*

echo "[nextcloud/install] runtime packages installed."
