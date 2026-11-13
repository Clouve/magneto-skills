#!/bin/bash
# ============================================================================
# LimeSurvey skill: the safety gates table and the playbooks agree
# ============================================================================
# SKILL.md ends with a table of safety gates: the actions that wait for the admin's yes, and the ones that are
# refused. The playbooks and references mark a step that has a gate with a paragraph that starts with "Gate:". The
# assistant reads a step without that mark as free to run, so the two have to agree, in both directions:
#
#   1. Every command in a playbook or a reference that the table gates stands under a "Gate:" paragraph. The
#      paragraph is in the text between the command's code block and the code block or heading before it.
#   2. Every "Gate:" paragraph is followed by a code block with at least one command that the table gates. A gate
#      for something the table does not have is a gate the table lacks.
#   3. No command anywhere is one the table refuses.
#   4. Every row of the table that names a command is used by at least one command of the playbooks or the
#      references, so that the table names no command the text never gives.
#
# How the table names a command. In the "Action" cell, a piece of code that holds a script's name (something
# that ends in .sh) or begins with "sudo " is a pattern. "..." in it stands for anything, and the rest has to be
# in the command in that order. A pattern that does not end with "..." has to be the end of the command, so that
# `run-in-limesurvey.sh backup.sh` is the backup and not `backup.sh --list`. A row whose "Gate" cell begins with
# "Refuse" refuses its patterns.
#
# The corpus is the fenced code blocks that are shell (tagged bash, sh, shell or console, or not tagged) of every
# .md file of the plugin, one command per line, with a trailing backslash joining lines and comment lines left
# out, as in tests/limesurvey-skill-commands.test.sh.
#
# A self-check first runs the rules on a small made-up skill with one fault per rule: a rule that stops firing
# fails there. No Docker is needed.
#
# Usage: bash tests/limesurvey-gates.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
skill="${root}/plugins/limesurvey/skills/limesurvey"
command -v python3 > /dev/null || { echo "limesurvey-gates: this test needs python3" >&2; exit 1; }
[ -f "${skill}/SKILL.md" ] || { echo "limesurvey-gates: ${skill}/SKILL.md is missing" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/limesurvey-gates.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 25 | cut -c1-260 | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }

# The checker prints one line per finding: "<rule>\t<file>:<line>\t<detail>", and "rows\t<n>", "patterns\t<n>",
# "commands\t<n>", "gated\t<n>", "gates\t<n>" for the counts.
cat > "${work}/gates.py" <<'PY'
import os, re, sys
skill = sys.argv[1]

def out(*cols):
    print("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in cols))

# --- The table ----------------------------------------------------------------------------------------------
lines = open(os.path.join(skill, "SKILL.md"), encoding="utf-8").read().splitlines()
start = next((i for i, l in enumerate(lines) if l.strip().startswith("| Action | Gate |")), None)
if start is None:
    out("table", "SKILL.md:0", "there is no table that starts with | Action | Gate |")
    sys.exit(0)
rows = []
for i in range(start + 2, len(lines)):
    line = lines[i].strip()
    if not line.startswith("|"):
        break
    cells = [c.strip() for c in line.strip("|").split("|")]
    if len(cells) < 2:
        continue
    action, gate = cells[0], cells[-1]
    patterns = [p for p in re.findall(r"`([^`]+)`", action) if re.search(r"[a-z][a-z0-9-]*\.sh\b", p) or p.startswith("sudo ")]
    rows.append({"line": i + 1, "action": action, "refuse": gate.lower().startswith("refuse"), "patterns": patterns})
out("rows", len(rows))

def compile_pattern(pattern):
    open_end = pattern.rstrip().endswith("...")
    pieces = [p.strip() for p in pattern.split("...")]
    pieces = [p for p in pieces if p]
    return pieces, open_end

def matches(pattern, command):
    pieces, open_end = compile_pattern(pattern)
    if not pieces:
        return False
    at = 0
    for n, piece in enumerate(pieces):
        found = command.find(piece, at)
        if found < 0:
            return False
        # A script's name has to be a whole name: "backup.sh" is not "other-backup.sh".
        if found > 0 and re.match(r"[A-Za-z0-9_-]", command[found - 1]) and re.match(r"[a-z]", piece):
            return False
        at = found + len(piece)
        # And a word of the pattern has to be a whole word: "map" is not "mappings".
        if at < len(command) and re.match(r"[A-Za-z0-9_]", piece[-1]) and re.match(r"[A-Za-z0-9_-]", command[at]):
            return False
    if not open_end:
        return command.rstrip().rstrip("'\"").rstrip().endswith(pieces[-1]) or command.rstrip().endswith(pieces[-1])
    return True

gated = [(r, p) for r in rows if not r["refuse"] for p in r["patterns"]]
refused = [(r, p) for r in rows if r["refuse"] for p in r["patterns"]]
out("patterns", len(gated))
used = set()

# --- The text -----------------------------------------------------------------------------------------------
shell_tags = {"", "bash", "sh", "shell", "console"}
files = []
for d, _, names in os.walk(skill):
    for n in sorted(names):
        if n.endswith(".md"):
            files.append(os.path.join(d, n))
commands = gated_commands = gates = 0
for path in sorted(files):
    rel = os.path.relpath(path, skill)
    text = open(path, encoding="utf-8").read().splitlines()
    fence, tag, buf, start_line = False, "", "", 0
    prose = []            # the text since the last code block or heading: (line number, text)
    block = None          # the code block being read: its commands, and the prose above it
    pending_gate = None   # a "Gate:" paragraph that still waits for its code block
    for i, line in enumerate(text, 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            if not fence:
                fence, tag = True, stripped[3:].strip().lower()
                block = {"commands": [], "prose": prose, "shell": tag in shell_tags, "line": i}
            else:
                fence = False
                if block["shell"]:
                    has_gate = any(re.match(r"(?:[-*]\s+)?Gate:", t) for _, t in block["prose"])
                    hit = False
                    for at, cmd in block["commands"]:
                        commands += 1
                        for row, pattern in refused:
                            if matches(pattern, cmd):
                                out("3", "%s:%d" % (rel, at), "the table refuses this (row %d: %s): %s" % (row["line"], pattern, cmd[:120]))
                        first = None
                        for row, pattern in gated:
                            if matches(pattern, cmd):
                                used.add(pattern)
                                if first is None:
                                    first = (row, pattern)
                        if first is not None:
                            hit = True
                            gated_commands += 1
                            if not has_gate and rel != "SKILL.md":
                                out("1", "%s:%d" % (rel, at), "no \"Gate:\" above a command the table gates (row %d: %s): %s" % (first[0]["line"], first[1], cmd[:120]))
                    if has_gate:
                        gates += 1
                        if not hit:
                            where = next(n for n, t in block["prose"] if re.match(r"(?:[-*]\s+)?Gate:", t))
                            out("2", "%s:%d" % (rel, where), "a \"Gate:\" for a command the table does not gate: %s" % "; ".join(c[:90] for _, c in block["commands"]))
                        pending_gate = None
                    prose = []
                block = None
            buf = ""
            continue
        if fence:
            if not block["shell"]:
                continue
            if not buf and (not stripped or stripped.startswith("#")):
                continue
            if not buf:
                start_line = i
            if stripped.endswith("\\"):
                buf += stripped[:-1] + " "
                continue
            block["commands"].append((start_line, buf + stripped))
            buf = ""
            continue
        if stripped.startswith("#"):
            if pending_gate is not None:
                out("2", "%s:%d" % (rel, pending_gate), "a \"Gate:\" with no command under it before the next heading")
                pending_gate = None
            prose = []
            continue
        if stripped:
            prose.append((i, stripped))
            if re.match(r"(?:[-*]\s+)?Gate:", stripped):
                pending_gate = i
    if pending_gate is not None:
        out("2", "%s:%d" % (rel, pending_gate), "a \"Gate:\" with no command under it")
for row, pattern in gated:
    if pattern not in used:
        out("4", "SKILL.md:%d" % row["line"], "no command in the text is this one: %s" % pattern)
out("commands", commands)
out("gated", gated_commands)
out("gates", gates)
PY

count() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$2"; }
findings() { awk -F'\t' -v r="$1" '$1 == r { print $2 ": " $3 }' "$2"; }

# ---------------------------------------------------------------------------
section "1. The checker checks itself"
# ---------------------------------------------------------------------------
fx="${work}/fixture"
mkdir -p "${fx}/playbooks"
S=/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts
cat > "${fx}/SKILL.md" <<MD
# Fixture

| Action | Gate |
|---|---|
| Sending (\`invitations.sh ... --send ...\`) | Ack |
| A backup (\`run-in-limesurvey.sh backup.sh\`) | Ack |
| Wiping (\`console.sh wipe ...\`) | Refuse |
| Never given (\`never-used.sh ...\`) | Ack |
| A thing with no command | Ack |

After the table.
MD
cat > "${fx}/playbooks/one.md" <<MD
# One

A preview, which the table does not gate:

\`\`\`bash
${S}/invitations.sh invite --survey 1
${S}/run-in-limesurvey.sh backup.sh --list
\`\`\`

Gate: wait for a yes.

\`\`\`bash
${S}/invitations.sh invite --survey 1 --send --expect 2
\`\`\`

No gate here, and the table has one:

\`\`\`bash
${S}/run-in-limesurvey.sh backup.sh
\`\`\`

Gate: for something the table does not have.

\`\`\`bash
${S}/survey-info.sh 1
\`\`\`

## A heading

Gate: for nothing at all.

## Another heading

\`\`\`bash
${S}/console.sh wipe yes
\`\`\`

\`\`\`text
${S}/run-in-limesurvey.sh backup.sh
\`\`\`
MD
python3 -I "${work}/gates.py" "${fx}" > "${work}/fixture.out"
want() { # RULE COUNT WHAT
    local got
    got="$(awk -F'\t' -v r="$1" '$1 == r' "${work}/fixture.out" | wc -l | tr -d ' ')"
    if [ "${got}" = "$2" ]; then ok "the fixture has $2 finding(s) of rule $1: $3"; else bad "the fixture has ${got} finding(s) of rule $1, wanted $2: $3" "$(cat "${work}/fixture.out")"; fi
}
want 1 1 "a gated command without a Gate: above it"
want 2 2 "a Gate: for a command the table does not gate, and a Gate: with no command"
want 3 1 "a command the table refuses"
want 4 1 "a row whose command the text never gives"
if [ "$(count rows "${work}/fixture.out")" = 5 ] && [ "$(count patterns "${work}/fixture.out")" = 3 ] && [ "$(count commands "${work}/fixture.out")" = 6 ]; then
    ok "the fixture's table has 5 rows and 3 gated patterns, and its text 6 commands (the text block is left out)"
else
    bad "the fixture's table has 5 rows and 3 gated patterns, and its text 6 commands" "$(cat "${work}/fixture.out")"
fi
if [ "$(findings 1 "${work}/fixture.out" | grep -c 'backup.sh --list' || true)" = 0 ]; then ok "a pattern that does not end with ... is the end of the command: backup.sh --list is not the backup"; else bad "a pattern that does not end with ... is the end of the command"; fi

# ---------------------------------------------------------------------------
section "2. The skill's table and its playbooks"
# ---------------------------------------------------------------------------
python3 -I "${work}/gates.py" "${skill}" > "${work}/skill.out"
rows="$(count rows "${work}/skill.out")"
patterns="$(count patterns "${work}/skill.out")"
commands="$(count commands "${work}/skill.out")"
gated="$(count gated "${work}/skill.out")"
gates="$(count gates "${work}/skill.out")"
if [ "${rows:-0}" -ge 25 ] && [ "${patterns:-0}" -ge 30 ]; then ok "the safety gates table has ${rows} rows, and ${patterns} commands it gates"; else bad "the safety gates table has ${rows:-0} rows and ${patterns:-0} gated commands, fewer than this test expects to find"; fi
if [ "${commands:-0}" -ge 100 ] && [ "${gated:-0}" -ge 40 ] && [ "${gates:-0}" -ge 40 ]; then
    ok "the text gives ${commands} commands, ${gated} of them gated, under ${gates} \"Gate:\" paragraphs"
else
    bad "the text gives ${commands:-0} commands, ${gated:-0} gated, under ${gates:-0} \"Gate:\" paragraphs, fewer than this test expects to find"
fi
for rule in 1 2 3 4 table; do
    case "${rule}" in
        1) label="every command the table gates stands under a \"Gate:\" paragraph" ;;
        2) label="every \"Gate:\" paragraph is for a command the table gates" ;;
        3) label="no command in the text is one the table refuses" ;;
        4) label="every command the table names is given somewhere in the text" ;;
        table) label="SKILL.md has the safety gates table" ;;
    esac
    hits="$(findings "${rule}" "${work}/skill.out")"
    if [ -z "${hits}" ]; then ok "${label}"; else bad "${label}" "${hits}"; fi
done

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
