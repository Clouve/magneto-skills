#!/usr/bin/env bash
# No skill tells the assistant to print its environment's values (B9 follow-through,
# 2026-10-20).
#
# The Magneto Agent's login shell holds each sibling app's settings, database and
# Odoo master passwords included (sidecar-env-fetcher.sh), plus the clouve-ops
# password and the AI Assistant key. A command such as `env | grep -i odoo` prints
# those values into the model's context and onto the customer's screen. Skills ask
# for variable NAMES instead (`compgen -e | grep -i odoo`) and pass a value as
# `$(printenv NAME)` without showing it.
#
# Fails on `env | grep`, `printenv | grep`, `set | grep`, a line that is just `env` or
# `printenv`, or `export -p` anywhere in a skill.
#
# Run: bash tests/skills-env-values.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# (A bare `env` in backticks is left alone: Odoo's shell has an `env` object.)
hits="$(grep -rnE '(^|[`$(;|&[:space:]])(env|printenv|set)[[:space:]]*\|[[:space:]]*(grep|egrep|sort|less|cat|head|tail)\b|^[[:space:]]*(env|printenv)[[:space:]]*(#.*)?$|export -p' \
  "$ROOT/plugins" --include='*.md' --include='*.sh' || true)"
if [ -z "$hits" ]; then
  pass "no skill prints the environment's values"
else
  fail "no skill prints the environment's values"
  printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /"
fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[32mAll env-value checks passed.\033[0m\n'; else
  printf '\033[31menv-value checks FAILED.\033[0m\n'; fi
exit "$FAILED"
