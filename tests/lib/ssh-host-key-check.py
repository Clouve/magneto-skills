"""Checks that every ssh and scp command in a plugin keeps and checks no saved host key.

Used by tests/odoo-channel-text.test.sh and tests/gibbon-channel-text.test.sh.

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
command in backticks in prose. The command's `-o` options, given as `-o NAME=VALUE` or
`-oNAME=VALUE` anywhere between the word and the target, go through the real
`ssh -G -F /dev/null`, which prints the settings ssh would use with no config file and connects
to nothing. They must include `userknownhostsfile /dev/null` and
`stricthostkeychecking accept-new`. Options passed any other way (in a variable, an array or a
config file) don't count, so such a command fails: write the two options on the line.

Prints one line per command: "ok <file>:<line>" or "bad <file>:<line>: <why>".
"""

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
for path in files:
    rel = path.relative_to(root)
    for n, line in logical_lines(path.read_text()):
        for m in word.finditer(line):
            rest = line[m.end():]
            at = rest.find("clouve-ops@")
            if at < 0 or ends_command.search(rest[:at]):
                continue
            opts = [o.replace(" ", "=", 1) for o in option.findall(rest[:at])]
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
