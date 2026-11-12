"""Checks that every ssh and scp command in a plugin keeps and checks no saved host key.

Used by tests/ssh-host-key-check.test.sh (every plugin) and the gibbon, moodle, odoo and wordpress
channel-text tests.

Run: python3 -I tests/lib/ssh-host-key-check.py <repo root> <plugin name>

The app containers make new SSH host keys when their images are rebuilt, and the Odoo images
make new ones at every start. A key the agent saved is then wrong, and ssh refuses it. On an
agent without the Magneto Agent's sibling SSH settings (#14), a key that is new to it stops at
a yes/no prompt that sshpass can't answer: sshpass exits 6 and prints nothing. So every command
passes `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null`.

It reads every .md and .sh file under plugins/<plugin name> (a plugin's scripts/tests/ folder
skipped), with backslash-continued lines joined. A command is an `ssh` or `scp` word (at the
start, or after a space, a quote, a backtick or one of `(|;&`) with `clouve-ops@` later on the
same line and nothing between them that ends a command or a quoted span: a `|`, `;`, `&`, `(`,
`)` or a backtick. So a scp upload counts (its source comes before the target), and so does a
command in backticks in prose. Outside code, that is in Markdown outside a fenced block or on a
script's comment line, an ordinary word between `ssh` and the target makes it prose instead, such as
an error message quoted in a table: "ssh to clouve-ops@<host> failed". An ordinary word is letters
only and isn't an option's value (`-p 22`, `-o LogLevel ERROR`); an scp line is never prose, since
its sources come before the target. The command's `-o` options, given as `-o NAME=VALUE` or
`-oNAME=VALUE` anywhere between the word and the target, go through the real
`ssh -G -F /dev/null`, which prints the settings ssh would use with no config file and connects
to nothing. They must include `userknownhostsfile /dev/null` and
`stricthostkeychecking accept-new`. One array counts too: `"${NAME[@]}"` on the command, when the
same file fills NAME with `mapfile -t NAME < <(FUNC)` and FUNC is defined in the plugin's own
scripts/lib/*.sh (nextcloud's lib/nextcloud-ssh.sh). The checker runs FUNC in a bash with an
empty environment and puts what it prints through ssh -G with the rest. Options passed any other
way (another variable or array, a config file) don't count, so such a command fails: write the
two options on the line.

Prints one line per command: "ok <file>:<line>" or "bad <file>:<line>: <why>".
"""

import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
plugin = sys.argv[2]
base = root / "plugins" / plugin
word = re.compile(r"""(?:^|(?<=[\s"'(|;&`]))(ssh|scp)(?=\s)""")
ends_command = re.compile(r"[|;&()`]")
option = re.compile(r"""(?:^|\s)-o\s*["']?([A-Za-z]+[=\s][^\s"']+)""")
want = ("userknownhostsfile /dev/null", "stricthostkeychecking accept-new")
# ssh and scp options that take a value: the word after one is that value, not prose.
takes_value = {"-b", "-B", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-P",
               "-p", "-Q", "-R", "-S", "-W", "-w"}
filled = re.compile(r"mapfile\s+-t\s+([A-Za-z_][A-Za-z0-9_]*)\s+<\s*<\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")


def is_prose(between):
    """True when an ordinary word, not an option or an option's value, sits between the ssh word and the target."""
    words = between.split()
    i = 0
    while i < len(words):
        w = words[i]
        if w == "-o":
            # -o NAME=VALUE is one word after the flag, -o NAME VALUE two.
            i += 3 if i + 1 < len(words) and "=" not in words[i + 1] else 2
        elif w in takes_value:
            i += 2
        elif re.fullmatch(r"[A-Za-z]+", w):
            return True
        else:
            i += 1
    return False


def fenced_lines(text):
    """The numbers of the Markdown lines inside a fenced code block, the fences included."""
    inside, fence, lines = False, "", set()
    for n, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip(" >")
        mark = stripped[:3]
        if mark in ("```", "~~~") and (not inside or mark == fence):
            inside, fence = not inside, mark
            lines.add(n)
        elif inside:
            lines.add(n)
    return lines


def lib_functions(plugin_dir):
    """Maps each function defined in the plugin's scripts/lib/*.sh to its file."""
    found = {}
    for lib in sorted(plugin_dir.rglob("scripts/lib/*.sh")):
        for m in re.finditer(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{", lib.read_text()):
            found.setdefault(m.group(1), lib)
    return found


def function_options(lib, func):
    """The -o values FUNC prints, one argument per line, run in a bash with an empty environment."""
    r = subprocess.run(["bash", "--noprofile", "--norc", "-c", '. "$1" && "$2"', "_", str(lib), func],
                       capture_output=True, text=True, timeout=10, env={"PATH": os.defpath})
    args = r.stdout.splitlines() if r.returncode == 0 else []
    return [args[i + 1] for i, a in enumerate(args[:-1]) if a == "-o"]


def logical_lines(text):
    """Yields (first line number, text) with backslash-continued lines joined."""
    buf, start = "", None
    for n, line in enumerate(text.splitlines(), 1):
        if start is None:
            start = n
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        yield start, buf + line
        buf, start = "", None
    if start is not None:
        yield start, buf


files = sorted(
    p
    for p in base.rglob("*")
    if p.is_file() and p.suffix in (".md", ".sh") and "scripts/tests" not in p.as_posix()
)
functions = lib_functions(base)
for path in files:
    rel = path.relative_to(root)
    text = path.read_text()
    arrays = {}
    in_code = fenced_lines(text) if path.suffix == ".md" else set()
    if path.suffix == ".sh":
        for name, func in filled.findall(text):
            if func in functions:
                arrays[name] = function_options(functions[func], func)
    for n, line in logical_lines(text):
        # Prose can only be outside code: Markdown outside a fenced block, or a script's comment line.
        outside_code = n not in in_code if path.suffix == ".md" else line.lstrip().startswith("#")
        for m in word.finditer(line):
            rest = line[m.end():]
            at = rest.find("clouve-ops@")
            if at < 0 or ends_command.search(rest[:at]):
                continue
            if outside_code and m.group(1) == "ssh" and is_prose(rest[:at]):
                continue
            opts = [o.replace(" ", "=", 1) for o in option.findall(rest[:at])]
            for name, values in arrays.items():
                if '"${' + name + '[@]}"' in rest[:at]:
                    opts += values
            args = ["ssh", "-G", "-F", "/dev/null"]
            for o in opts:
                args += ["-o", o]
            r = subprocess.run(args + [f"clouve-ops@tkt-7-{plugin}"], capture_output=True, text=True, timeout=10)
            settings = r.stdout.splitlines()
            if r.returncode != 0:
                err = (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1]
                print(f"bad {rel}:{n}: ssh -G refuses its options: {err}")
            elif not all(w in settings for w in want):
                got = [s for s in settings if s.split(" ", 1)[0] in ("userknownhostsfile", "stricthostkeychecking")]
                print(f"bad {rel}:{n}: {m.group(1)} would use {', '.join(got)}")
            else:
                print(f"ok {rel}:{n}")
