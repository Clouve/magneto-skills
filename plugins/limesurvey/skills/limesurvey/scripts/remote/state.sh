#!/usr/bin/env bash
# LimeSurvey skill: remote/state.sh
#
# Runs INSIDE the LimeSurvey container, as root, sent by run-in-limesurvey.sh. It only reads.
#
# Usage: state.sh                 prints the install, upgrade and restore state as NAME=value lines
#        state.sh plugins-before  prints the names of the plugins that were on before the last upgrade, one per
#                                 line, from the list the image's upgrade saved in its backup folder (nothing when
#                                 there is no such list)
#
# remote/lib/state.sh says what the names mean and where they are read from.

set -uo pipefail
# shellcheck source=/dev/null
. "${CLV_LS_REMOTE_DIR:?}/lib/state.sh" || exit 1

case "${1:-}" in
    '')
        clv_state
        ;;
    plugins-before)
        folder="$(clv_upgrade_folder)"
        [ -n "${folder}" ] || exit 0
        for f in "${folder}/active-plugins" "${folder}"/*plugins*; do
            [ -f "${f}" ] && [ ! -L "${f}" ] || continue
            # One name per line. Anything else on a line (a version, an id) is dropped.
            sed -E 's/^[[:space:]]*//; s/[[:space:],;|].*$//' "${f}" | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' || :
            break
        done
        ;;
    *)
        echo "[limesurvey/state] unknown request: $1" >&2
        exit 1
        ;;
esac
