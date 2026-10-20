#!/bin/bash
# ============================================================================
# Odoo skill: commands that can't work on Clouve's Odoo 19 image
# ============================================================================
# The AI Assistant runs the skill's commands as written, from the Magneto
# Agent container, over the clouve-ops SSH channel. Each rule below is a
# command shape the skill once gave it that fails on the real image (checked
# against a running Odoo 19 container built from magneto/apps/odoo, Odoo
# nightly 19.0-20261015, on 2026-10-20):
#
#   1. /var/lib/odoo/scripts/...  No such folder in the Odoo container. The
#      skill's scripts live in the agent, staged at
#      /clouve/skills/odoo/plugin/skills/odoo/scripts/.
#   2. `-c` given to `odoo db`. Where `-c` may go differs per subcommand:
#      `odoo db dump -c ...` fails ("unrecognized arguments: -c") and
#      `odoo -c ... db dump` starts the server parser ("unrecognized
#      parameters"). ODOO_RC=/etc/odoo/odoo.conf works for every subcommand.
#   3. Recycling the pod, or asking the customer to restart. The agent has no
#      kubectl and the customer's dashboard has no restart button. Odoo is
#      PID 1 in its container and re-executes itself on SIGHUP.
#   4. `sudo odoo shell` without the config. sudo over SSH has no ODOO_RC, so
#      Odoo looks for PostgreSQL on a local socket and fails. The same holds
#      for every odoo command given -d: `odoo neutralize -d <db>` with no
#      config ends "THE DATABASE IS NOT NEUTRALIZED!" (checked on the rig's
#      Odoo 19 pod, 2026-10-20).
#   5. `sudo -u postgres psql/pg_dump` without -U. This stack has no
#      `postgres` role (POSTGRES_USER=odoo): "role "postgres" does not exist".
#   6. scp straight out of /var/lib/odoo. scp runs as clouve-ops without sudo,
#      and /var/lib/odoo is odoo-only (drwxr-x--- odoo:odoo), so it reports
#      "No such file or directory". Stream it with `sudo cat` over ssh instead.
#
# Plus one positive check: every /clouve/skills/odoo/plugin/<path> the skill
# names exists in plugins/odoo/<path>, so a command that pipes or runs one of
# the skill's own files points at a file that ships.
#
# Reads the plugin's files only. Nothing runs, no network, no Docker.
#
# Usage: bash tests/odoo-skill-commands.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "${here}/../plugins/odoo" && pwd)"

pass=0
fail=0

# Every text file in the plugin (Markdown, scripts, manifests).
mapfile -t files < <(find "${plugin}" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' \) | sort)

# hits <ere> [<exclude-ere>] — prints file:line:text for lines that match <ere>
# (case-insensitive) and, when given, do not match <exclude-ere> (case-sensitive:
# `-U` must not be mistaken for the `-u` in `sudo -u`).
hits() {
  local ere="$1" exclude="${2:-}"
  if [ -n "${exclude}" ]; then
    grep -n -i -E -H -- "${ere}" "${files[@]}" | grep -v -E -- "${exclude}"
  else
    grep -n -i -E -H -- "${ere}" "${files[@]}"
  fi
}

# rule <label> <ere> [<exclude-ere>] — passes when no line matches.
rule() {
  local label="$1" found
  found="$(hits "${@:2}" || true)"
  if [ -z "${found}" ]; then
    printf '  ✓ %s\n' "${label}"
    pass=$((pass + 1))
  else
    printf '  ✗ %s\n' "${label}"
    printf '%s\n' "${found}" | sed -e "s|^${plugin}/||" -e 's/^/      | /' | cut -c1-200
    fail=$((fail + 1))
  fi
}

echo "Odoo skill: command shapes that fail on the Odoo 19 image"

rule "no step runs a script from /var/lib/odoo/scripts/ (there is no such folder)" \
  '/var/lib/odoo/scripts/'

odoo='odoo(-bin)?'
cfg='(-c|--config)([[:space:]=]|$)'
rule "no 'odoo db' command takes -c (use ODOO_RC=/etc/odoo/odoo.conf)" \
  "${odoo}[[:space:]]+db[[:space:]]+${cfg}|${odoo}[[:space:]]+(-c|--config)[[:space:]=][^[:space:]]+[[:space:]]+db([[:space:]]|$)|${odoo}[[:space:]]+db[[:space:]]+(init|load|dump|duplicate|rename|drop)([[:space:]][^|;&]*)?[[:space:]]${cfg}"

rule "no step recycles the pod or asks the customer to restart" \
  'kubectl[[:space:]]+(rollout|delete[[:space:]]+pod)|recycle[[:space:]]+(the|your|its)[[:space:]]+pod|pod[[:space:]/-]+(container[[:space:]]+)?recycle|restart(ing)?[[:space:]]+(the|your)[[:space:]]+deployment|ask[[:space:]]+the[[:space:]]+(customer|user|tenant)[[:space:]]+to[[:space:]]+restart'

rule "every 'sudo odoo shell' passes the config (-c or ODOO_RC)" \
  "sudo([[:space:]]+[A-Za-z_]+=[^[:space:]]+)*[[:space:]]+${odoo}[[:space:]]+shell" \
  "[[:space:]]${cfg}|ODOO_RC="

rule "every odoo command given -d (shell, module, neutralize, -i/-u) passes the config" \
  "${odoo}[[:space:]]+(shell|module[[:space:]]+[a-z]+|neutralize)[^\`]*[[:space:]]-d[[:space:]]|${odoo}[[:space:]]+-d[[:space:]]" \
  "[[:space:]]${cfg}|ODOO_RC=|psql"

rule "every 'sudo -u postgres psql/pg_dump' names the role with -U (there is no postgres role)" \
  'sudo[[:space:]]+-u[[:space:]]+postgres[[:space:]]+(psql|pg_dump|pg_dumpall|pg_restore)([^[:alnum:]_]|$)' \
  '[[:space:]](-U|--username)[[:space:]=]'

rule "nothing scp's straight out of /var/lib/odoo (clouve-ops can't read it; use sudo cat over ssh)" \
  'clouve-ops@[^[:space:]:]+:/var/lib/odoo'

# Every staged path the skill names must ship in the plugin.
missing=""
while IFS= read -r ref; do
  rel="${ref#/clouve/skills/odoo/plugin/}"
  rel="${rel%.}"
  [ -e "${plugin}/${rel}" ] || missing+="${ref}"$'\n'
done < <(grep -h -o -E '/clouve/skills/odoo/plugin/[A-Za-z0-9_./-]*' "${files[@]}" | sort -u)
if [ -z "${missing}" ]; then
  printf '  ✓ %s\n' "every /clouve/skills/odoo/plugin/... path the skill names exists in plugins/odoo/"
  pass=$((pass + 1))
else
  printf '  ✗ %s\n' "every /clouve/skills/odoo/plugin/... path the skill names exists in plugins/odoo/"
  printf '%s' "${missing}" | sed 's/^/      | missing: /'
  fail=$((fail + 1))
fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
