#!/usr/bin/env bash
# The odoo skill describes the Odoo images Clouve builds from 2026-11-02 on (release 4.5.3, magneto #13 and #14).
#
# Both Odoo images now run tini as PID 1. In the Odoo container, tini runs the entrypoint, which ends by exec'ing
# Odoo, so Odoo is tini's child. tini reaps finished processes (while Odoo was PID 1, every clouve-ops SSH session
# left a zombie behind) and passes signals on to Odoo, SIGHUP included. The skill said "Odoo is PID 1" in five places.
# The restart command stays `grep -q odoo /proc/1/cmdline && sudo kill -HUP 1`: tini's command line has "odoo" in it
# too, and a container on an older image still runs Odoo itself as PID 1.
#
# Neither image holds SSH host keys now. Each container makes its own when it starts, so a key saved from one start
# is wrong after the next. The skill told the assistant to pass `-o StrictHostKeyChecking=accept-new` on its "first
# connection" and to rely on the saved key after that, but ssh refuses a saved key once the container has made a new
# one. Newer agents keep no key for their siblings, older ones do, so every command in the skill also passes
# `-o UserKnownHostsFile=/dev/null`.
#
# Fails when a line under plugins/odoo says Odoo is PID 1, mentions PID 1 without naming tini, or relies on a saved
# host key. Every ssh and scp command in the skill's markdown and scripts, a scp upload or a command in backticks in
# prose included, goes through tests/lib/ssh-host-key-check.py: its -o options, written on the same line, go through
# the real `ssh -G -F /dev/null`. That prints the settings ssh would use on an agent without the sibling SSH settings,
# without connecting, and they must be `userknownhostsfile /dev/null` and `stricthostkeychecking accept-new`. Every
# SIGHUP the skill sends (`kill -HUP`, `kill -s HUP`, `kill -SIGHUP`, `kill -1`) has to be the whole restart command,
# quoted (in single quotes in a code block or script, in backticks in prose):
#   grep -q <name> /proc/1/cmdline && sudo kill -HUP 1
# Its grep then runs against a file standing in for /proc/1/cmdline. It must match when PID 1 is tini running Odoo's
# entrypoint or Odoo itself, and not when PID 1 is tini running PostgreSQL. SKILL.md, reference/stack-and-runtime.md
# and playbooks/install-or-upgrade-module.md each give the command. The test never runs a kill.
#
# Odoo images built before 2026-11-03 put the database password on Odoo's command line (their entrypoint passed
# --db_password), and the assistant can meet one, so the skill never gives a command that prints a process's
# arguments: `ps aux`, `ps -ef`, `pgrep -a`, or a cat of a /proc/*/cmdline file, in a code block, a script, or
# backticks on a prose line that doesn't say never or don't. Since 2026-11-03 Odoo runs as the odoo user, reads that
# password from odoo.conf only, and the clouve-ops sshd's parent is tini, not Odoo: a line that says sshd is Odoo's,
# or that Odoo's command line holds the password with no image date, is stale.
#
# odoo.conf holds db_password and admin_passwd in plain text, so the skill never shows a diff of it, and a setting
# that comes from the container's environment can't be changed from the agent: no line offers an env-driven path, a
# config map or a Clouve control for it (the same rotation pattern as the gibbon and moodle tests).
#
# The database manager: the Odoo image writes list_db = False and a dbfilter for the deployment's database into
# odoo.conf at every start. Nothing reads an ODOO_LIST_DB variable, and a POST with a made-up master password can't
# tell a locked manager from an open one (Odoo checks the password first), so neither appears. The harden playbook
# opens the manager for one task with sed and the restart command, checks it with /web/database/list, and closes it
# the same way; restore-and-clone.md says a clone under another name doesn't answer in a browser. The open step waits
# for the database list to change, not for /web/health, which the old process can still answer.
#
# A copy under another name: Odoo 19's cron thread serves every database the odoo role owns (cron_database_list:
# config['db_name'] or list_dbs(True)), dbfilter or not, and XML-RPC and JSON-RPC reach any database by name. So a
# copy's scheduled jobs (mail, payments) run unless it is neutralized, and its users can sign in to it over the API.
# Every `odoo db load` or `odoo db duplicate` in a playbook neutralizes (-n) or loads into ${ODOO_DB_NAME} itself,
# and restore-and-clone.md says why and to drop a copy when its task is done. A backups folder in the agent holds
# whole databases, so it is made mode 700.
#
# A new master password is never typed into a command (no exp_change_admin_password('...')): the tenant sets it on
# Odoo's own database manager page.
#
# It reads the plugin's files and runs only `grep` and `ssh -G`, which connects to nothing: no network, no Docker.
#
# Run: bash tests/odoo-channel-text.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN="$ROOT/plugins/odoo"
SKILL_DIR="$PLUGIN/skills/odoo"
work="$(mktemp -d "${TMPDIR:-/tmp}/odoo-channel-text.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

mapfile -t files < <(find "$PLUGIN" -type f \( -name '*.md' -o -name '*.sh' -o -name '*.json' \) | sort)
if [ "${#files[@]}" -lt 20 ]; then
  fail "found the odoo plugin's files (only ${#files[@]}: the scan is broken)"
fi

# stale LABEL REGEX: fails when a line of the plugin matches REGEX (extended, any case).
stale() {
  local hits
  hits="$(grep -nHiE -- "$2" "${files[@]}" || true)"
  if [ -z "$hits" ]; then
    pass "no file says $1"
  else
    fail "no file says $1"
    printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
  fi
}

# report LABEL REPORT: passes when REPORT (lines of "ok ..." and "bad ...") has an ok line and no bad line.
report() {
  local bad ok
  bad="$(grep '^bad ' <<< "$2" || true)"
  ok="$(grep -c '^ok ' <<< "$2" || true)"
  if [ -z "$bad" ] && [ "$ok" -gt 0 ]; then
    pass "$1 ($ok checked)"
  else
    fail "$1"
    printf '%s\n' "${bad:-nothing found, so the scan is broken}" | sed 's/^bad /       /' | cut -c1-220
  fi
}

# --- PID 1 ----------------------------------------------------------------------------

stale 'Odoo is PID 1, or the main process' \
  "odoo is (the container.s )?(main process|pid[[:space:]]*1)|this is pid[[:space:]]*1|main process \(pid[[:space:]]*1|odoo \(pid[[:space:]]*1\)"

hits="$(grep -nHiE -- '\bpid[[:space:]]*1\b' "${files[@]}" | grep -viE 'tini' || true)"
if [ -z "$hits" ]; then
  pass "every line that mentions PID 1 names tini"
else
  fail "every line that mentions PID 1 names tini"
  printf '%s\n' "$hits" | sed "s#^$ROOT/##; s/^/       /" | cut -c1-220
fi

if grep -qiE 'tini[^.]*\bPID[[:space:]]*1\b|\bPID[[:space:]]*1\b[^.]*\btini' "$SKILL_DIR/reference/stack-and-runtime.md"; then
  pass "reference/stack-and-runtime.md names tini as PID 1"
else
  fail "reference/stack-and-runtime.md names tini as PID 1"
fi

# --- The restart command ----------------------------------------------------------------

restarts="$(python3 -I - "$ROOT" "$work" <<'PY'
import pathlib, re, subprocess, sys

root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
skill = root / "plugins" / "odoo" / "skills" / "odoo"
# The command is quoted: in single quotes inside a code block or a script, in backticks in prose.
quoted = {"code": re.compile(r"'([^']*)'"), "prose": re.compile(r"`([^`]*)`")}
shape = re.compile(r"grep -q ([A-Za-z0-9_.][A-Za-z0-9_.-]*) /proc/1/cmdline && sudo kill -HUP 1")
# Any way of sending SIGHUP with kill or pkill: -HUP, -SIGHUP, -s HUP, -s SIGHUP, -1.
hup = re.compile(r"kill\s+(?:-s\s*)?-?(?:SIG)?HUP\b|kill\s+-1\b")

# PID 1's command line in each container, as /proc/1/cmdline holds it (a NUL after each argument), and whether the
# restart command must signal it. The test runs only the command's grep, never a kill.
pid1 = [
    ("tini running Odoo's entrypoint", b"/usr/bin/tini\0--\0/clouve/odoo/installer/entrypoint.sh\0odoo\0", True),
    ("Odoo itself (older images)", b"/usr/bin/python3\0/usr/bin/odoo\0-c\0/etc/odoo/odoo.conf\0", True),
    ("tini running PostgreSQL", b"/usr/bin/tini\0--\0/usr/local/bin/clouve-entrypoint.sh\0postgres\0", False),
]
cmdline = work / "cmdline"

found = set()
for path in sorted(p for p in skill.rglob("*") if p.is_file() and p.suffix in (".md", ".sh")):
    rel = path.relative_to(skill)
    fence = False
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if path.suffix == ".md" and line.lstrip().startswith("```"):
            fence = not fence
            continue
        if not hup.search(line):
            continue
        context = "code" if fence or path.suffix == ".sh" else "prose"
        spans = [s for s in quoted[context].findall(line) if hup.search(s)]
        if not spans:
            print(f"bad {rel}:{n}: a SIGHUP outside a quoted restart command")
        for cmd in spans:
            found.add(str(rel))
            m = shape.fullmatch(cmd.strip())
            if not m:
                print(f"bad {rel}:{n}: {cmd.strip()}: not grep -q <name> /proc/1/cmdline && sudo kill -HUP 1")
                continue
            wrong = []
            for label, content, sends in pid1:
                cmdline.write_bytes(content)
                signals = subprocess.run(["grep", "-q", m.group(1), str(cmdline)], timeout=10).returncode == 0
                if signals != sends:
                    wrong.append(f"PID 1 is {label}: it {'signals' if signals else 'skips'} it")
            if wrong:
                print(f"bad {rel}:{n}: {cmd.strip()}: " + "; ".join(wrong))
            else:
                print(f"ok {rel}:{n}")
for rel in ("SKILL.md", "reference/stack-and-runtime.md", "playbooks/install-or-upgrade-module.md"):
    if rel not in found:
        print(f"bad {rel}: gives no restart command")
PY
)"
report "every restart command checks PID 1 first: it signals Odoo on the tini image and the older one, never PostgreSQL" \
  "$restarts"

# --- SSH host keys ----------------------------------------------------------------------

stale 'that a saved host key gets reused (first connection, known-hosts entry)' \
  'first connection|known[-_ ]?hosts?[[:space:]]+entry|reuses?[[:space:]]+the[[:space:]]+known|fingerprint once'

if ! command -v ssh >/dev/null 2>&1; then
  fail "ssh is installed, to check each command's options with ssh -G"
else
  commands="$(python3 -I "$ROOT/tests/lib/ssh-host-key-check.py" "$ROOT" odoo)"
  n_cmds="$(grep -c '' <<< "$commands" || true)"
  if [ "$n_cmds" -lt 20 ]; then
    fail "found the skill's ssh and scp commands (only $n_cmds: the scan is broken)"
  fi
  report "every ssh and scp command keeps no host key, even on an agent without the sibling SSH settings" "$commands"
fi

# --- Odoo's command line holds the database password -------------------------------------

printers="$(python3 -I - "$ROOT" <<'PY'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
plugin = root / "plugins" / "odoo"
# A command that prints a process's arguments, or reads a /proc/<pid>/cmdline file.
shows_args = re.compile(r"\bps\s+(?:-\w*e\w*f\b|aux\w*|-aux\w*|-o\s*\S*args)|\bpgrep\s+-\w*a|\bcat\s+/proc/\S*cmdline")
negated = re.compile(r"\b(?:never|don't|do not)\b", re.I)
for path in sorted(p for p in plugin.rglob("*") if p.is_file() and p.suffix in (".md", ".sh")):
    rel = path.relative_to(root)
    fence = False
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if path.suffix == ".md" and line.lstrip().startswith("```"):
            fence = not fence
            continue
        if path.suffix == ".sh":
            text = "" if line.lstrip().startswith("#") else line
        elif fence:
            text = line
        else:
            text = "" if negated.search(line) else " ".join(re.findall(r"`([^`]*)`", line))
        if shows_args.search(text):
            print(f"bad {rel}:{n}: {line.strip()[:150]}")
PY
)"
if [ -z "$printers" ]; then
  pass "no command in the skill prints Odoo's arguments (ps aux, ps -ef, pgrep -a, /proc/*/cmdline)"
else
  fail "no command in the skill prints Odoo's arguments (ps aux, ps -ef, pgrep -a, /proc/*/cmdline)"
  printf '%s\n' "$printers" | sed 's/^bad /       /'
fi

# --- The master password never goes into a command --------------------------------------

# Typed into the ssh command string, a new master password shows in the chat (the tool call itself), on the agent's
# process list and in the Odoo container's. The tenant sets it on Odoo's own database manager page instead.
typed="$(grep -nHE "exp_change_admin_password\([[:space:]]*['\"]" "${files[@]}" || true)"
if [ -z "$typed" ] && grep -qF 'Set Master Password' "$SKILL_DIR/playbooks/harden-db-manager.md"; then
  pass "no command types a new master password; harden-db-manager.md sends the tenant to Odoo's own Set Master Password"
else
  fail "no command types a new master password; harden-db-manager.md sends the tenant to Odoo's own Set Master Password"
  printf '%s\n' "$typed" | sed "s#^$ROOT/##; /^$/d; s/^/       /" | cut -c1-220
fi

# --- The non-root image (2026-11-03) ---------------------------------------------------------

stale "that sshd is Odoo's child" "sshd.{0,3} is odoo.s\\b|odoo.s child[^.]*sshd"
stale "that Odoo's command line holds the database password, with no image date" \
  "odoo.s command line holds the database password|entrypoint passes .?--db_password"

# --- odoo.conf's passwords and settings that come from the environment ---------------------------

stale 'a diff of odoo.conf (it holds both passwords)' 'show(ing)? (a |the )?diff'
stale 'an env-driven path, a config map or a Clouve control for a setting' \
  'prefer (the |that )?env[- ]|env(-var)?-driven (sync |config )?(path|pattern)|via env vars|env injection on pod restart|rotate the secret|rotated clouve secret|via a kubernetes secret|clouve platform ui|config ?map|environment variable override'

# --- The database manager ----------------------------------------------------------------------

stale 'ODOO_LIST_DB (nothing reads it)' 'ODOO_LIST_DB'
stale 'a lockdown probe with a made-up master password' 'master_pwd=test'

harden="$SKILL_DIR/playbooks/harden-db-manager.md"
missing=""
for want in "sudo sed -i 's/^list_db = False\$/list_db = True/' /etc/odoo/odoo.conf" \
            "sudo sed -i 's/^list_db = True\$/list_db = False/' /etc/odoo/odoo.conf" \
            "grep -q odoo /proc/1/cmdline && sudo kill -HUP 1" \
            "/web/database/list" \
            "--data-urlencode master_pwd@-"; do
  grep -qF -- "$want" "$harden" || missing="${missing}       ${want}"$'\n'
done
if [ -z "$missing" ]; then
  pass "harden-db-manager.md opens the manager for one task, checks it with /web/database/list and closes it"
else
  fail "harden-db-manager.md opens the manager for one task, checks it with /web/database/list and closes it"
  printf 'missing:\n%s' "$missing"
fi

if grep -qF 'answers in a browser' "$SKILL_DIR/playbooks/restore-and-clone.md"; then
  pass "restore-and-clone.md says which database answers in a browser"
else
  fail "restore-and-clone.md says which database answers in a browser"
fi

# --- Copies under another name, and the open step's wait ---------------------------------------

copies="$(python3 -I - "$SKILL_DIR" <<'PY2'
import pathlib, re, sys
skill = pathlib.Path(sys.argv[1])
load = re.compile(r"\bodoo db (load|duplicate)\b")
for path in sorted((skill / "playbooks").glob("*.md")):
    fence = False
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if not fence or not load.search(line):
            continue
        ok = re.search(r"\s(-n|--neutralize)\b", line) or "${ODOO_DB_NAME}" in line
        print(("ok " if ok else "bad ") + "playbooks/%s:%d: %s" % (path.name, n, line.strip()[:140]))
PY2
)"
report "every odoo db load or duplicate in a playbook neutralizes (-n) or loads into \${ODOO_DB_NAME}" "$copies"

rc="$SKILL_DIR/playbooks/restore-and-clone.md"
missing=""
for want in 'scheduled jobs' 'XML-RPC' 'odoo db drop'; do grep -qF -- "$want" "$rc" || missing="$missing '$want'"; done
if [ -z "$missing" ]; then
  pass "restore-and-clone.md says a copy's scheduled jobs and API stay live, and to drop it when done"
else
  fail "restore-and-clone.md says a copy's scheduled jobs and API stay live, and to drop it when done"
  echo "       missing:$missing"
fi

# shellcheck disable=SC2016  # a literal: the text no file may hold
stale 'a backups folder in the agent made with the default mode' 'mkdir -p "\$HOME/backups"'
if grep -qE 'curl[^#]*web/health' "$SKILL_DIR/playbooks/harden-db-manager.md"; then
  fail "the open step waits for the database list to change, not for /web/health"
else
  pass "the open step waits for the database list to change, not for /web/health"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All odoo channel-text checks passed."; else exit 1; fi
