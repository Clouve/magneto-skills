#!/usr/bin/env bash
# Each plugin's version is the same in every place that holds it (release 4.5.3,
# 2026-11-02).
#
# A version sits in plugins/<name>/.claude-plugin/plugin.json, in the `version:` line of
# plugins/<name>/skills/<name>/SKILL.md's frontmatter, in the plugin's entry in
# .claude-plugin/marketplace.json, and in README.md's Plugins table. A bump that misses
# one leaves the agent's loader log, the skill and the catalog naming different versions,
# so nobody can tell which skill a tenant's assistant ran.
#
# Fails when they disagree for any plugin, when a SKILL.md with `type: devops` has no
# `version:` line (CLAUDE.md: DevOps skills carry one), when a plugin has no row in
# README.md's table, when a catalog entry has no plugin directory, or when a plugin
# directory has no catalog entry.
#
# The README row has the plugin's name, category, version and a short description (N7,
# 2026-11-03: CLAUDE.md says a plugin added or changed updates its row). Fails, too, when a
# row's category differs from the catalog's, or its description is empty.
#
# Run: bash tests/plugin-versions.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

report="$(python3 - "$ROOT" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
catalog = {p["name"]: p for p in json.load(open(root / ".claude-plugin" / "marketplace.json"))["plugins"]}
# README.md's Plugins table: | `name` | Category | Version | Description |
readme = {}
rows = {}
for row in (root / "README.md").read_text().splitlines():
    m = re.match(r"\|\s*`([a-z0-9-]+)`\s*\|([^|]*)\|\s*([^|\s]+)\s*\|([^|]*)\|", row)
    if m:
        readme[m.group(1)] = m.group(3)
        rows[m.group(1)] = (m.group(2).strip(), m.group(4).strip())
dirs = sorted(d.name for d in (root / "plugins").iterdir() if d.is_dir())
for name in sorted(set(catalog) - set(dirs)):
    print(f"bad {name}: in marketplace.json but has no plugins/{name}/")
for name in dirs:
    if name not in catalog:
        print(f"bad {name}: plugins/{name}/ has no marketplace.json entry")
        continue
    manifest = json.load(open(root / "plugins" / name / ".claude-plugin" / "plugin.json")).get("version")
    skill_md = (root / "plugins" / name / "skills" / name / "SKILL.md").read_text()
    front = re.match(r"---\n(.*?)\n---", skill_md, re.S)
    found = re.search(r"^version:\s*(\S+)\s*$", front.group(1), re.M) if front else None
    skill = found.group(1) if found else None
    devops = bool(front) and re.search(r"^type:\s*devops\s*$", front.group(1), re.M) is not None
    listed = catalog[name].get("version")
    versions = {"plugin.json": manifest, "marketplace.json": listed, "README.md": readme.get(name)}
    if skill is not None or devops:
        versions["SKILL.md"] = skill
    category, description = rows.get(name, (None, None))
    if None in versions.values() or len(set(versions.values())) != 1:
        print(f"bad {name}: " + ", ".join(f"{k} {v}" for k, v in versions.items()))
    elif category != catalog[name].get("category"):
        print(f"bad {name}: README.md's category {category!r}, marketplace.json's {catalog[name].get('category')!r}")
    elif not description:
        print(f"bad {name}: README.md's row has no description")
    else:
        print(f"ok {name} {manifest}")
PY
)"

bad="$(grep '^bad ' <<< "$report" || true)"
ok="$(grep -c '^ok ' <<< "$report" || true)"
if [ -z "$bad" ] && [ "$ok" -gt 0 ]; then
  pass "every plugin has one version in plugin.json, SKILL.md, marketplace.json and README.md, whose row has the catalog's category and a description ($ok plugins)"
else
  fail "every plugin has one version in plugin.json, SKILL.md, marketplace.json and README.md, whose row has the catalog's category and a description"
  printf '%s\n' "${bad:-no plugin found, so the scan is broken}" | sed 's/^bad /       /'
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All plugin version checks passed."; else exit 1; fi
