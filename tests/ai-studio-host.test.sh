#!/usr/bin/env bash
# The ai-studio and mern skills reach the AI Studio workspace by ${AI_STUDIO_HOST}
# (B8, 2026-10-20).
#
# The ai-studio skill said the workspace was "reachable at the pod-internal hostname
# `ai-studio`" and gave `clouve-ops@ai-studio` in its SSH examples. That name only
# exists under docker-compose. On Kubernetes the sibling is tkt-<id>-ai-studio
# (`getent hosts ai-studio` fails in the agent), and the Magneto Agent exports the
# name that does resolve as AI_STUDIO_HOST (magneto-agent sidecar-env-fetcher.sh),
# like GIBBON_HOST, MOODLE_HOST and ODOO_HOST for the other skills.
#
# Fails on any SSH target or hostname claim that names the bare `ai-studio` host in
# either plugin, and checks the skill gives the ${AI_STUDIO_HOST} form and a way to
# confirm the variable's name that prints no values.
#
# Run: bash tests/ai-studio-host.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SKILL="$ROOT/plugins/ai-studio/skills/ai-studio/SKILL.md"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

bare="$(grep -rnE 'clouve-ops@ai-studio\b|@ai-studio[[:space:]:'"'"'"]|hostname `ai-studio`|host `ai-studio`' \
  "$ROOT/plugins/ai-studio" "$ROOT/plugins/mern" || true)"
if [ -z "$bare" ]; then
  pass "no SSH target or hostname names the bare ai-studio host"
else
  fail "no SSH target or hostname names the bare ai-studio host"
  printf '       %s\n' "$bare"
fi

n="$(grep -c 'clouve-ops@${AI_STUDIO_HOST}' "$SKILL")"
if [ "$n" -ge 2 ]; then pass "both SSH examples use \${AI_STUDIO_HOST} ($n)"; else
  fail "both SSH examples use \${AI_STUDIO_HOST} (found $n)"; fi

if grep -qF 'compgen -e | grep -i studio' "$SKILL"; then
  pass "says how to confirm the variable's name, names only"
else
  fail "says how to confirm the variable's name, names only (compgen -e | grep -i studio)"
fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[32mAll ai-studio host checks passed.\033[0m\n'; else
  printf '\033[31mai-studio host checks FAILED.\033[0m\n'; fi
exit "$FAILED"
