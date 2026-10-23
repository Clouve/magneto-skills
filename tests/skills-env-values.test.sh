#!/usr/bin/env bash
# No skill tells the assistant to print its environment's values (B9 follow-through,
# 2026-10-20).
#
# The Magneto Agent's login shell holds each sibling app's settings, database and
# Odoo master passwords included (sidecar-env-fetcher.sh), plus the clouve-ops
# password and the AI Assistant key. A command such as `env | grep -i odoo` prints
# those values into the model's context and onto the customer's screen. Skills ask
# for variable NAMES instead (`compgen -e | grep -i odoo`, and `clv-secret --list` for
# passwords) and pass a value as `${NAME:-$(clv-secret NAME)}` without showing it.
#
# Fails on `env | grep`, `printenv | grep`, `set | grep`, a line that is just `env` or
# `printenv`, or `export -p` anywhere in a skill.
#
# Passwords stay out of the environment (agent secrets, 2026-10-23).
#
# On a new Magneto Agent, no password is an environment variable, so `$(printenv NAME)`
# no longer finds one. `clv-secret NAME` prints it. An older agent still has the
# password in its environment and has no clv-secret. Skills come from git at every
# agent start, so each command has to work on both. That takes two parts:
# `${NAME:-$(clv-secret NAME)}`. An old agent has NAME, so bash never runs the
# clv-secret part. A new agent doesn't, so bash runs it.
#
# A secret name has one of these words in it: PASSWORD, PASSWORDS, PASSWD, PASS, PWD,
# SECRET, SECRETS, KEY, KEYS, TOKEN, TOKENS, CREDENTIAL, CREDENTIALS, PRIVATE, AUTH.
# MAGNETO_AGENT_LLM_KEY, ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN are the exceptions.
# Case doesn't matter, so db_password and Gibbon_Db_Password are secrets too.
# An agent-side secret also starts with CLOUVE_OPS_, GIBBON_, MOODLE_, ODOO_, WORDPRESS_
# or AI_STUDIO_. A name without one of those (DB_PASSWORD, MYSQL_ROOT_PASSWORD,
# MYSQL_PWD) belongs to a sibling or is a script's own copy, so it stays as written.
# is_secret_name and is_agent_side_secret below are that rule. Keep them in step with
# _clv_is_secret_name in magneto-agent's image/installer/secrets/secrets-lib.sh.
#
# It also fails on:
#   - `printenv` of a secret name;
#   - a `$NAME` or `${NAME...}` of an agent-side secret, in a .md file or on a comment
#     line of a .sh file, that isn't exactly the two-part form;
#   - a script that uses an agent-side secret with no top-level line
#     `: "${NAME:=$(clv-secret NAME)}"` above its first other use. Under `set -e` this
#     form is safe. A plain assignment whose $(...) fails would end the script. The line
#     has no `2>/dev/null`: clv-secret's own messages ("waiting for the agent to finish
#     connecting to its apps...", "NAME is not set on this server", the sudo reason)
#     have to reach whoever ran the script. An older agent has no clv-secret, but `:=`
#     only runs it when NAME is unset or empty, so an older agent that has NAME never
#     sees any of this;
#   - a .md line that says an agent-side secret is already in your environment or shell;
#   - a script line that sends the reader to compgen for an agent-side secret's name
#     (the names of passwords come from `clv-secret --list`);
#   - a SKILL.md, in a plugin that uses clv-secret, that never says `clv-secret --list`;
#   - a learnings.md without the "Secrets. Ever." line that names CLOUVE_OPS_PASSWORD
#     bare, not as an expansion;
#   - a CLAUDE.md that doesn't show the two forms above.
# Both forms also run on an agent without clv-secret and on one that has it.
# scripts/tests/ is skipped.
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

# --- The name rule -----------------------------------------------------------

is_secret_name() { # NAME: one of its _-separated words is a secret word, in any case
  local name="${1^^}"
  case "$name" in MAGNETO_AGENT_LLM_KEY | ANTHROPIC_API_KEY | ANTHROPIC_AUTH_TOKEN) return 1 ;; esac
  local -a words=()
  local word
  IFS=_ read -r -a words <<< "$name"
  [ "${#words[@]}" -gt 0 ] || return 1
  for word in "${words[@]}"; do
    case "$word" in
      PASSWORD | PASSWORDS | PASSWD | PASS | PWD | SECRET | SECRETS | KEY | KEYS | TOKEN | TOKENS | CREDENTIAL | CREDENTIALS | PRIVATE | AUTH) return 0 ;;
    esac
  done
  return 1
}

is_agent_side_secret() { # NAME: a secret name with an agent-side prefix
  case "$1" in
    CLOUVE_OPS_* | GIBBON_* | MOODLE_* | ODOO_* | WORDPRESS_* | AI_STUDIO_*) is_secret_name "$1" ;;
    *) return 1 ;;
  esac
}

# The rule ignores case, like the agent's: a lowercase or mixed-case name is a secret too, and
# the three exceptions match in any case. A word still has to match whole (keycloak is not key).
bad=""
for nm in db_password Gibbon_Db_Password smtp_pwd; do
  is_secret_name "$nm" || bad+="$nm should be a secret"$'\n'
done
for nm in magneto_agent_llm_key keycloak_url passwordless_mode; do
  ! is_secret_name "$nm" || bad+="$nm should not be a secret"$'\n'
done
if [ -z "$bad" ]; then
  pass "the name rule ignores case"
else
  fail "the name rule ignores case"
  printf '%s' "$bad" | sed 's/^/       /'
fi

mapfile -t md_files < <(find "$ROOT/plugins" -type f -name '*.md' -not -path '*/scripts/tests/*' | sort)
mapfile -t sh_files < <(find "$ROOT/plugins" -type f -name '*.sh' -not -path '*/scripts/tests/*' | sort)
rel() { printf '%s' "${1#"$ROOT"/}"; }

# A candidate is anything with an agent-side prefix after a `$` or `${`. The functions
# above decide which of them are secrets.
prefixes='CLOUVE_OPS|GIBBON|MOODLE|ODOO|WORDPRESS|AI_STUDIO'

# --- No printenv of a secret --------------------------------------------------

bad=""
hits="$(grep -nHE 'printenv[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "${md_files[@]}" "${sh_files[@]}" || true)"
while IFS=: read -r file line text; do
  [ -n "$file" ] || continue
  rest="$text"
  while [[ "$rest" =~ printenv[[:space:]]+([A-Za-z_][A-Za-z0-9_]*) ]]; do
    name="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    if is_secret_name "$name"; then bad+="$(rel "$file"):$line  printenv $name"$'\n'; fi
  done
done <<< "$hits"
if [ -z "$bad" ]; then
  pass "no skill reads a secret with printenv"
else
  fail "no skill reads a secret with printenv"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# --- Markdown uses the two-part form ------------------------------------------

# expansions TEXT: prints "ok NAME" or "bad NAME" for each $NAME or ${NAME...} of an
# agent-side secret in TEXT. ok means it is exactly ${NAME:-$(clv-secret NAME)}.
expansions() {
  local rest="$1" match name before form
  while [[ "$rest" =~ \$\{?([A-Za-z_][A-Za-z0-9_]*) ]]; do
    match="${BASH_REMATCH[0]}"
    name="${BASH_REMATCH[1]}"
    before="${rest%%"$match"*}"
    rest="${rest:${#before}}"
    if is_agent_side_secret "$name"; then
      form='${'"$name"':-$(clv-secret '"$name"')}'
      if [[ "$rest" == "$form"* ]]; then echo "ok $name"; else echo "bad $name"; fi
    fi
    rest="${rest:${#match}}"
  done
}

# A .md file counts on every line. A .sh file counts on its comment lines only: the
# code lines are the loader check's business.
hits="$(
  grep -nHE "\\$\\{?($prefixes)_" "${md_files[@]}" || true
  grep -nHE "^[[:space:]]*#.*\\$\\{?($prefixes)_" "${sh_files[@]}" || true
)"
bad=""
seen=0
while IFS=: read -r file line text; do
  [ -n "$file" ] || continue
  while read -r verdict name; do
    seen=$((seen + 1))
    [ "$verdict" = ok ] || bad+="$(rel "$file"):$line  \$$name is not written as \${$name:-\$(clv-secret $name)}"$'\n'
  done < <(expansions "$text")
done <<< "$hits"
if [ "$seen" -eq 0 ]; then
  fail "every agent-side secret in markdown uses the two-part form (the scan found none to check, so it is broken)"
elif [ -z "$bad" ]; then
  pass "every agent-side secret in markdown uses the two-part form ($seen checked)"
else
  fail "every agent-side secret in markdown uses the two-part form"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# --- Scripts load their secrets first -----------------------------------------

# The loader for NAME is the whole line: no indent, nothing after it.
bad=""
loaders=0
for f in "${sh_files[@]}"; do
  loaded=" "
  reported=" "
  n=0
  while IFS= read -r text || [ -n "$text" ]; do
    n=$((n + 1))
    trimmed="${text#"${text%%[![:space:]]*}"}"
    [[ "$trimmed" == '#'* ]] && continue
    [[ "$text" =~ ($prefixes)_ ]] || continue
    rest="$text"
    while [[ "$rest" =~ ([A-Za-z_][A-Za-z0-9_]*) ]]; do
      tok="${BASH_REMATCH[1]}"
      rest="${rest#*"$tok"}"
      is_agent_side_secret "$tok" || continue
      if [ "$text" = ': "${'"$tok"':=$(clv-secret '"$tok"')}"' ]; then
        loaded+="$tok "
        loaders=$((loaders + 1))
        break
      fi
      if [[ "$loaded" != *" $tok "* && "$reported" != *" $tok "* ]]; then
        bad+="$(rel "$f"):$n  $tok is used above its loader line"$'\n'
        reported+="$tok "
      fi
    done
  done < "$f"
done
if [ "$loaders" -eq 0 ] && [ -z "$bad" ]; then
  fail "every script loads its agent-side secrets first (no loader line anywhere, so the scan is broken or the scripts lost them)"
elif [ -z "$bad" ]; then
  pass "every script loads its agent-side secrets first ($loaders loader lines)"
else
  fail "every script loads its agent-side secrets first"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# --- The prose agrees with the forms --------------------------------------------

# On a current agent a password is not in the environment. A line that names an
# agent-side secret and calls it "already in your" env, shell or environment is wrong.
bad=""
hits="$(grep -nHE 'already in (your|the agent)' "${md_files[@]}" || true)"
while IFS=: read -r file line text; do
  [ -n "$file" ] || continue
  rest="$text"
  while [[ "$rest" =~ ([A-Za-z_][A-Za-z0-9_]*) ]]; do
    tok="${BASH_REMATCH[1]}"
    rest="${rest#*"$tok"}"
    if is_agent_side_secret "$tok"; then
      bad+="$(rel "$file"):$line  says $tok is already in the environment"$'\n'
      break
    fi
  done
done <<< "$hits"
if [ -z "$bad" ]; then
  pass "no skill says an agent-side secret is already in the environment"
else
  fail "no skill says an agent-side secret is already in the environment"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# A script's message about a missing password sends the reader to `clv-secret --list`.
# `compgen -e` lists the environment, and the passwords are not in it.
bad=""
for f in "${sh_files[@]}"; do
  n=0
  while IFS= read -r text || [ -n "$text" ]; do
    n=$((n + 1))
    [[ "$text" == *compgen* ]] || continue
    rest="$text"
    while [[ "$rest" =~ ([A-Za-z_][A-Za-z0-9_]*) ]]; do
      tok="${BASH_REMATCH[1]}"
      rest="${rest#*"$tok"}"
      if is_agent_side_secret "$tok"; then
        bad+="$(rel "$f"):$n  sends the reader to compgen for $tok (clv-secret --list lists the passwords' names)"$'\n'
        break
      fi
    done
  done < "$f"
done
if [ -z "$bad" ]; then
  pass "no script sends the reader to compgen for a password's name"
else
  fail "no script sends the reader to compgen for a password's name"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# A plugin that uses clv-secret says so in its SKILL.md, and how to list the names.
bad=""
checked=0
for skill in "$ROOT"/plugins/*/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  grep -rqF 'clv-secret' "${skill%/SKILL.md}" --include='*.md' --include='*.sh' || continue
  checked=$((checked + 1))
  grep -qF 'clv-secret --list' "$skill" || bad+="$(rel "$skill")  uses clv-secret but never says clv-secret --list"$'\n'
done
if [ "$checked" -eq 0 ]; then
  fail "every SKILL.md that uses clv-secret says how to list the names (the scan found no such plugin, so it is broken)"
elif [ -z "$bad" ]; then
  pass "every SKILL.md that uses clv-secret says how to list the names ($checked checked)"
else
  fail "every SKILL.md that uses clv-secret says how to list the names"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# learnings.md keeps secrets out, and names the variable without an expansion.
bad=""
checked=0
for f in "$ROOT"/plugins/{gibbon,moodle,odoo,wordpress}/skills/*/learnings.md; do
  checked=$((checked + 1))
  line="$(grep -F 'Secrets. Ever.' "$f" 2>/dev/null || true)"
  if [[ "$line" != *'`CLOUVE_OPS_PASSWORD`'* || "$line" == *'$'* ]]; then
    bad+="$(rel "$f")  has no Secrets. Ever. line that names CLOUVE_OPS_PASSWORD bare"$'\n'
  fi
done
if [ -z "$bad" ]; then
  pass "every learnings.md says secrets never go there, naming CLOUVE_OPS_PASSWORD bare ($checked checked)"
else
  fail "every learnings.md says secrets never go there, naming CLOUVE_OPS_PASSWORD bare"
  printf '%s' "$bad" | sed 's/^/       /'
fi

# CLAUDE.md is where the contract is written down. It shows the forms this test enforces.
if grep -qF '${NAME:-$(clv-secret NAME)}' "$ROOT/CLAUDE.md" && grep -qF ': "${NAME:=$(clv-secret NAME)}"' "$ROOT/CLAUDE.md"; then
  pass "CLAUDE.md shows the markdown form and the script loader line"
else
  fail "CLAUDE.md shows the markdown form and the script loader line"
fi

# --- Both forms work on old and new agents ------------------------------------

tmp="$(mktemp -d "${TMPDIR:-/tmp}/skills-env-values.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# agent_run PATH SNIPPET [NAME=value ...]: runs SNIPPET in an empty environment the way
# a skill command runs on an agent. Sets out, err and rc.
agent_run() {
  local path="$1" snippet="$2"
  shift 2
  out="$(env -i PATH="$path" "$@" "$BASH" -c "$snippet" 2>"$tmp/err")"
  rc=$?
  err="$(cat "$tmp/err")"
}
# prints_only LABEL WANT: the last run exited 0, printed WANT and nothing on stderr.
# A failure names the case and never shows a value.
prints_only() {
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ] && [ -z "$err" ]; then pass "$1"; else fail "$1"; fi
}
# prints_nothing LABEL: the last run exited 0 and printed nothing on stdout. Stderr is
# left alone: bash says "clv-secret: command not found" when there is no clv-secret.
prints_nothing() {
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "$1"; else fail "$1"; fi
}

two_part='printf %s "${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}"'
loader='set -euo pipefail; : "${MOODLE_DB_PASSWORD:=$(clv-secret MOODLE_DB_PASSWORD)}"; printf %s "$MOODLE_DB_PASSWORD"'

# An old agent: the password is in the environment and there is no clv-secret.
bare=/usr/bin:/bin
agent_run "$bare" "$two_part" MOODLE_DB_PASSWORD=fake-x
prints_only "works on an agent without clv-secret: the two-part form prints the environment's value" fake-x
agent_run "$bare" "$loader" MOODLE_DB_PASSWORD=fake-x
prints_only "works on an agent without clv-secret: the loader line keeps the environment's value, with nothing on stderr" fake-x
agent_run "$bare" "$loader"
prints_nothing "works on an agent without clv-secret: with no value either, the loader line exits 0 and prints nothing"

# A new agent: clv-secret is there and the password is not in the environment. The
# stand-in knows one fake value, answers like the real one for any other name, and
# leaves a mark when it runs.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/clv-secret" <<'STUB'
#!/bin/bash
[ -n "${CLV_STUB_MARK:-}" ] && : > "$CLV_STUB_MARK"
if [ "${1:-}" = MOODLE_DB_PASSWORD ]; then printf %s fake-y; exit 0; fi
echo "clv-secret: ${1:-} is not set on this server" >&2
exit 2
STUB
chmod +x "$tmp/bin/clv-secret"
withstub="$tmp/bin:/usr/bin:/bin"
agent_run "$withstub" "$two_part" CLV_STUB_MARK="$tmp/ran"
prints_only "works on an agent with clv-secret: the two-part form fetches the value" fake-y
agent_run "$withstub" "$loader" CLV_STUB_MARK="$tmp/ran"
prints_only "works on an agent with clv-secret: the loader line fetches the value" fake-y
# A name clv-secret does not know: the line still exits 0 and prints nothing on stdout, so
# the script goes on, and clv-secret's own message reaches stderr.
agent_run "$withstub" 'set -euo pipefail; : "${OTHER_DB_PASSWORD:=$(clv-secret OTHER_DB_PASSWORD)}"; printf %s "$OTHER_DB_PASSWORD"' CLV_STUB_MARK="$tmp/ran"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$err" = "clv-secret: OTHER_DB_PASSWORD is not set on this server" ]; then
  pass "works on an agent with clv-secret: a name it does not know leaves the script running and its message on stderr"
else
  fail "works on an agent with clv-secret: a name it does not know leaves the script running and its message on stderr"
fi

# Both: the environment wins and clv-secret never runs.
rm -f "$tmp/ran"
agent_run "$withstub" "$two_part" MOODLE_DB_PASSWORD=fake-x CLV_STUB_MARK="$tmp/ran"
prints_only "an agent with both uses the environment's value in the two-part form" fake-x
agent_run "$withstub" "$loader" MOODLE_DB_PASSWORD=fake-x CLV_STUB_MARK="$tmp/ran"
prints_only "an agent with both uses the environment's value in the loader line" fake-x
if [ ! -e "$tmp/ran" ]; then pass "an agent with both never runs clv-secret"; else fail "an agent with both never runs clv-secret"; fi

echo
if [ "$FAILED" -eq 0 ]; then printf '\033[32mAll env-value checks passed.\033[0m\n'; else
  printf '\033[31menv-value checks FAILED.\033[0m\n'; fi
exit "$FAILED"
