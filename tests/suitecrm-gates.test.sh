#!/bin/bash
# ============================================================================
# SuiteCRM skill: the gates table and the playbooks agree, in both directions
# ============================================================================
# Nothing destructive, and nothing that changes who can sign in, may run without the user's clear yes. SKILL.md
# lists those actions in the table "Actions that wait for a yes" under "Safety gates": one row per action, with
# the command in a Command column. The playbooks and the references are where the assistant meets
# the commands. This test fails when the two drift apart. It reads files only: no Docker, no network.
#
# The table. Its Command cell holds one or more commands in backticks, in short: the script, the words that
# make the command this action, and its yes flag (`records.sh delete --yes-delete`, `users.sh role-set`,
# `users.sh set-admin <login> no`, `chown -R`). Nothing else in that cell is in backticks. The first word is the
# script (or the program of a raw ssh command), a word in angle brackets is a value, and every other word is
# fixed. A command of the Markdown "is" that command when it calls that script or program and has every fixed
# word. So the same command without its --yes- flag, which is the preview, is not gated, and a command that
# has no flag at all is gated by its name alone.
#
# A gate, in a playbook or a reference, is a paragraph that starts with "Gate." (a list number may stand in
# front of it) and says "clear yes". A step is the text from one heading to the next.
#
# The checks:
#   1. Flags. Every --yes-... flag that a script of the skill defines (a case label or a comparison in
#      scripts/*.sh) has a row whose command names that script and that flag, and every script and flag in the
#      table is defined by that script. A flag that the scripts mention and no script defines fails too: the
#      test could not see where it is checked.
#   2. No flag. SKILL.md has one paragraph that starts with "No flag." and names, in backticks, every command
#      of the table that has no --yes- flag, and nothing else in backticks. For those commands the gate is the
#      assistant's alone, so SKILL.md has to say which they are.
#   3. Commands have gates. Every command in a shell code block of SKILL.md, a playbook or a reference that is
#      one of the table's commands has a gate above it in its step, with no other code block of gated commands
#      between the gate and it. One gate covers one code block.
#   4. Gates have commands. Every gate is followed, in its step, by a code block with at least one of the
#      table's commands, and every gate says "clear yes".
#   5. Rows are real. Every command of the table is shown in a code block of a playbook or a reference. A
#      command that is only named in running text (a line with the script's name and every fixed word) passes
#      when each such line has the word "yes".
#
# Removing one gate from a playbook fails check 3. Removing one row from the table fails check 1 (a row with a
# flag), check 2 (a row without one) or check 4 (its gate now stands in front of a command the table does not
# list).
#
# Usage: bash tests/suitecrm-gates.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"

command -v python3 > /dev/null || { echo "suitecrm-gates: this test needs python3 on PATH" >&2; exit 1; }

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 60 | sed 's/^/       | /'; fi
}

out="$(python3 -I - "${root}" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
skill = root / "plugins" / "suitecrm" / "skills" / "suitecrm"
SHELL_TAGS = {"", "bash", "sh", "shell", "console", "zsh"}
FLAG = r"--yes-[a-z][a-z-]*"
problems = []
facts = []


def say(rule, where, text):
    problems.append(f"{rule}\t{where}\t{text}")


# ---------------------------------------------------------------------------
# The flags the scripts define
# ---------------------------------------------------------------------------
defined = set()
mentioned = set()
for file in sorted((skill / "scripts").rglob("*")):
    if not file.is_file() or file.suffix not in (".sh", ".php"):
        continue
    for line in file.read_text().splitlines():
        mentioned.update(re.findall(FLAG, line))
        if file.parent != skill / "scripts" or line.lstrip().startswith("#"):
            continue
        # a case label: "--yes-import) yes=1" or "1:--yes-undo) exec ..."
        m = re.match(r"^\s*(?:[\w$\"{}:#-]*:)?(" + FLAG + r")\)", line)
        if m:
            defined.add((file.name, m.group(1)))
        # a comparison: [ "$3" != --yes-remove ]
        for m in re.finditer(r"(?:!=|==|=)\s*\"?(" + FLAG + r")\"?\s*\]", line):
            defined.add((file.name, m.group(1)))
for flag in sorted(mentioned - {f for _, f in defined}):
    say("a flag the scripts mention and none defines", "scripts/", flag)

# ---------------------------------------------------------------------------
# The table in SKILL.md
# ---------------------------------------------------------------------------
skill_md = (skill / "SKILL.md").read_text().splitlines()


def cells(row):
    """The cells of a table row; a | inside backticks does not split."""
    out, cur, tick = [], "", False
    for c in row.strip():
        if c == "`":
            tick = not tick
        if c == "|" and not tick:
            out.append(cur.strip())
            cur = ""
        else:
            cur += c
    out.append(cur.strip())
    return out[1:-1] if len(out) >= 2 else out


class Pattern:
    def __init__(self, text, line):
        self.text = text
        self.line = line
        words = re.sub(r"<[^>]*>", " ", text).split()
        self.program = words[0] if words else ""
        self.words = [w for w in words[1:] if w not in ("...", "|")]
        self.flags = [w for w in self.words if re.fullmatch(FLAG, w)]


patterns = []
start = next((i for i, l in enumerate(skill_md) if re.match(r"^##\s+Safety gates", l)), None)
header = None
if start is None:
    say("the gates table", "SKILL.md", 'no heading "## Safety gates"')
else:
    i = start + 1
    while i < len(skill_md) and not re.match(r"^##\s", skill_md[i]):
        row = skill_md[i]
        if row.startswith("|") and header is None and "Command" in cells(row):
            header = cells(row)
            col = header.index("Command")
            i += 2
            while i < len(skill_md) and skill_md[i].startswith("|"):
                got = cells(skill_md[i])
                found = re.findall(r"`([^`]+)`", got[col]) if col < len(got) else []
                if not found:
                    say("the gates table", f"SKILL.md:{i + 1}", "a row without a command in backticks: " + skill_md[i][:80])
                for text in found:
                    patterns.append(Pattern(text, i + 1))
                i += 1
            break
        i += 1
    if header is None:
        say("the gates table", "SKILL.md", 'no table with a "Command" column under "## Safety gates"')

in_table = {(p.program, f) for p in patterns for f in p.flags}
for script, flag in sorted(defined - in_table):
    say("a flag of a script that has no row in the table", f"scripts/{script}", f"{script} {flag}")
for script, flag in sorted(in_table - defined):
    say("a flag in the table that the script does not define", "SKILL.md", f"{script} {flag}")

# The paragraph that names the commands without a flag
flagless = {p.text for p in patterns if not p.flags}
no_flag = [l for l in skill_md if re.match(r"^(?:\d+\.\s+|[-*]\s+)?No flag\. ", l.strip())]
if patterns and len(no_flag) != 1:
    say("the paragraph that names the commands without a flag", "SKILL.md", f'{len(no_flag)} paragraphs start with "No flag." (there must be one)')
elif patterns:
    named = set(re.findall(r"`([^`]+)`", no_flag[0]))
    for text in sorted(flagless - named):
        say("a command without a flag that the \"No flag.\" paragraph does not name", "SKILL.md", text)
    for text in sorted(named - flagless):
        say("a command in the \"No flag.\" paragraph that is not a row without a flag", "SKILL.md", text)

# ---------------------------------------------------------------------------
# The Markdown: headings, gates and the commands of the code blocks, in order
# ---------------------------------------------------------------------------
def strip_comment(line):
    quote = ""
    for i, c in enumerate(line):
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i].rstrip()
    return line


def open_quote(text):
    quote = ""
    i = 0
    while i < len(text):
        c = text[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        i += 1
    return quote


def block_commands(body, first_line):
    """The commands of one code block: (line, the command's own text without a heredoc's body)."""
    out = []
    j = 0
    while j < len(body):
        line = first_line + j
        text = body[j]
        j += 1
        if not text.strip() or text.lstrip().startswith("#"):
            continue
        text = strip_comment(text)
        n = 0
        while (text.endswith("\\") or open_quote(text)) and j < len(body) and n < 80:
            nxt = body[j]
            text = text[:-1].rstrip() + " " + nxt.strip() if text.endswith("\\") else text + "\n" + nxt
            j += 1
            n += 1
        h = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", text)
        if h:
            while j < len(body):
                j += 1
                if body[j - 1].strip() == h.group(2):
                    break
        out.append((line, text))
    return out


def events(file):
    """('heading', line, text) | ('gate', line, text) | ('prose', line, text) | ('block', line, [(line, command)])"""
    lines = file.read_text().splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*(?:>\s*)?)(```+|~~~+)\s*([A-Za-z0-9_-]*)\s*$", lines[i])
        if m:
            indent, mark, tag = m.group(1), m.group(2), m.group(3).lower()
            body = []
            first = i + 2
            i += 1
            while i < len(lines) and not re.match(r"^\s*(?:>\s*)?" + re.escape(mark[:3]) + r"+\s*$", lines[i]):
                text = lines[i]
                body.append(text[len(indent):] if text.startswith(indent) else text.lstrip())
                i += 1
            i += 1
            if tag in SHELL_TAGS:
                out.append(("block", first, block_commands(body, first)))
            continue
        text = lines[i]
        if re.match(r"^#{1,6}\s", text):
            out.append(("heading", i + 1, text))
        elif re.match(r"^\s*(?:\d+\.\s+)?Gate\.(?:\s|$)", text):
            out.append(("gate", i + 1, text))
        elif text.strip():
            out.append(("prose", i + 1, text))
        i += 1
    return out


def words_of(command):
    return re.sub(r"['\"]", " ", command).split()


def which(command):
    """The table's commands that this command is."""
    words = words_of(command)
    names = {w.rsplit("/", 1)[-1] for w in words}
    return [p for p in patterns if p.program in names and all(w in words for w in p.words)]


files = [skill / "SKILL.md"] + sorted((skill / "playbooks").glob("*.md")) + sorted((skill / "reference").glob("*.md"))
shown = set()
gates = 0
gated = 0
prose_lines = []
for file in files:
    rel = file.relative_to(skill)
    gate = None        # (line, used)
    for kind, line, data in events(file) + [("heading", 0, "")]:
        if kind == "heading":
            if gate and not gate[1]:
                say("a gate with no command of the table after it in its step", f"{rel}:{gate[0]}", "")
            gate = None
        elif kind == "gate":
            gates += 1
            if gate and not gate[1]:
                say("a gate with no command of the table after it in its step", f"{rel}:{gate[0]}", "")
            if "clear yes" not in data:
                say('a gate that does not say "clear yes"', f"{rel}:{line}", data.strip()[:100])
            gate = (line, False)
        elif kind == "prose":
            if file != skill / "SKILL.md":
                prose_lines.append((rel, line, data))
        else:
            hits = [(n, c, which(c)) for n, c in data]
            hits = [(n, c, ps) for n, c, ps in hits if ps]
            if not hits:
                continue
            for n, c, ps in hits:
                gated += 1
                if file != skill / "SKILL.md":
                    shown.update(p.text for p in ps)
                if gate is None:
                    say("a gated command with no gate above it in its step", f"{rel}:{n}", c.split("\n")[0].replace("/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/", "")[:110])
            if gate is not None:
                gate = None        # one gate covers one code block

# Rows are real
for p in patterns:
    if p.text in shown:
        continue
    lines = [(rel, n, t) for rel, n, t in prose_lines if p.program in t and all(w in t for w in p.words)]
    if not lines:
        say("a command of the table that no playbook or reference shows", f"SKILL.md:{p.line}", p.text)
        continue
    facts.append(f"named in the text only, each time with a yes: {p.text}")
    for rel, n, t in lines:
        if not re.search(r"\byes\b", re.sub(FLAG, "", t)):
            say("a line that names a gated command and no yes", f"{rel}:{n}", p.text)

print(f"COUNT\t{len(defined)}\t{len(patterns)}\t{len(flagless)}\t{gates}\t{gated}\t{len(files)}")
for f in facts:
    print(f"FACT\t{f}")
for p in problems:
    print(p)
PY
)"
rc=$?
if [ "${rc}" -ne 0 ]; then
    bad "the test's reader ran" "python3 ended with ${rc}"
    echo
    echo "suitecrm-gates: ${pass} passed, ${fail} failed"
    exit 1
fi

count() { printf '%s\n' "${out}" | awk -F'\t' -v n="$1" '$1 == "COUNT" { print $(n + 1) }'; }
n_defined="$(count 1)"
n_rows="$(count 2)"
n_flagless="$(count 3)"
n_gates="$(count 4)"
n_gated="$(count 5)"
n_files="$(count 6)"

echo "The gates table and the playbooks"
if [ "${n_defined:-0}" -ge 10 ]; then ok "found ${n_defined} --yes- flags that the scripts define"; else bad "found the scripts' --yes- flags (${n_defined:-0}; the skill has far more, so the reading is broken)"; fi
if [ "${n_rows:-0}" -ge 20 ]; then ok "found ${n_rows} commands in the gates table, ${n_flagless} of them without a flag"; else bad "found the commands of the gates table (${n_rows:-0}; there must be 20 or more, so the table or the reading is broken)"; fi
if [ "${n_gates:-0}" -ge 20 ] && [ "${n_gated:-0}" -ge 20 ]; then ok "found ${n_gates} gates and ${n_gated} gated commands in ${n_files} Markdown files"; else bad "found the gates and the gated commands (${n_gates:-0} gates, ${n_gated:-0} commands in ${n_files:-0} files; the skill has far more)"; fi

for rule in "the gates table" \
    "a flag the scripts mention and none defines" \
    "a flag of a script that has no row in the table" \
    "a flag in the table that the script does not define" \
    "the paragraph that names the commands without a flag" \
    'a command without a flag that the "No flag." paragraph does not name' \
    'a command in the "No flag." paragraph that is not a row without a flag' \
    "a gated command with no gate above it in its step" \
    "a gate with no command of the table after it in its step" \
    'a gate that does not say "clear yes"' \
    "a command of the table that no playbook or reference shows" \
    "a line that names a gated command and no yes"; do
    hits="$(printf '%s\n' "${out}" | awk -F'\t' -v r="${rule}" '$1 == r { print $2 "  " $3 }')"
    if [ -z "${hits}" ]; then ok "none: ${rule}"; else bad "none: ${rule}" "${hits}"; fi
done
printf '%s\n' "${out}" | awk -F'\t' '$1 == "FACT" { print "  note " $2 }'

echo
echo "suitecrm-gates: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
