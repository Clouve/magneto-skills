#!/bin/bash
# Odoo plugin — runtime install hook.
#
# Invoked by Magneto Agent's plugin-stager after the plugin payload is staged
# at /clouve/skills/odoo/plugin/. The contract for hooks is documented in
# https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh
#
# What this installs and why:
#   postgresql-client (psql, pg_dump, pg_restore) — scripts/backup.sh and the
#       diagnose / restore playbooks shell out to these to talk to the
#       odoo-postgres service over TCP.
#   openssh-client + sshpass — the agent ssh's into the odoo and odoo-postgres
#       containers as the clouve-ops operator account using `sshpass -e ssh …`
#       with the per-pod password from CLOUVE_OPS_PASSWORD (the filestore-aware
#       `odoo-bin db dump/load` and `odoo shell` run inside the odoo container).
#
# These do not belong in the upstream Magneto Agent image: no other consumer
# needs them, and shipping sshpass by default expands the platform's attack
# surface for tenants that don't use SSH-based ops at all. They live here so the
# deps travel with the skill that needs them.
#
# Idempotency: dpkg-query gates each package, so re-runs on subsequent container
# starts are a no-op aside from the dpkg lookup itself.

set -u

REQUIRED_PACKAGES=(postgresql-client openssh-client sshpass)

missing=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing+=("$pkg")
    fi
done

if [ "${#missing[@]}" -eq 0 ]; then
    echo "[odoo/install] runtime packages already present — skipping apt-get."
    exit 0
fi

echo "[odoo/install] installing missing packages: ${missing[*]}"

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update -qq; then
    echo "[odoo/install] apt-get update failed — aborting" >&2
    exit 1
fi

if ! apt-get install -y --no-install-recommends "${missing[@]}"; then
    echo "[odoo/install] apt-get install failed for: ${missing[*]}" >&2
    exit 1
fi

rm -rf /var/lib/apt/lists/*

echo "[odoo/install] runtime packages installed."
