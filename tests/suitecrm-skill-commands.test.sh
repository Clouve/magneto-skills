#!/bin/bash
# ============================================================================
# SuiteCRM skill: the commands in its Markdown run as written
# ============================================================================
# The assistant runs what SKILL.md, the references and the playbooks show it. This test reads every command
# in their fenced code blocks, checks its form, and then runs it against a real SuiteCRM 8.10.2 in Docker
# (the stack of tests/lib/suitecrm-stack/, as tests/suitecrm-scripts.test.sh uses it), in the agent container,
# as the agent's user, in a login shell: the way the assistant would.
#
# The corpus: the fenced blocks tagged bash, sh or shell, or with no tag, of every .md file under
# plugins/suitecrm. In them a comment line and a trailing # comment are not commands; a line that ends with a
# backslash goes on with the next; a command whose quote is still open goes on until it closes (a query over
# several lines); and a heredoc's body belongs to its command. Blocks tagged text, json, csv, sql, php and the
# like are not commands and are not run.
#
# Part 1, the form (static; SC_TEST_STATIC_ONLY=1 stops after it):
#   1. A script of the skill is called by its absolute path, /clouve/skills/suitecrm/plugin/skills/suitecrm/
#      scripts/<name>.sh. backup.sh and restore.sh are the arguments of run-in-suitecrm.sh.
#   2. A value that varies is a <placeholder> from the list below, inside single quotes. A placeholder in
#      double quotes or in no quotes fails: the assistant's shell would expand $ and backticks in the value it
#      puts there. A placeholder that is not on the list fails: the test could not fill it.
#   3. No docker, podman, kubectl, systemctl or service command; no mysql or mariadb client (sql-read.sh is
#      the only way to send SQL); no raw bin/console (console.sh runs the allowed commands).
#   4. No password on a command line: no -p<password> or --password= for a database client, no sshpass -p,
#      no curl -u. An sshpass command sets SSHPASS itself, from ${CLOUVE_OPS_PASSWORD:-$(clv-secret ...)}.
#   5. A query given to sql-read.sh is one statement that starts with SELECT, and it has a "deleted = 0" for
#      every module or link table it reads from.
#   6. A console.sh command is on the allow-list of scripts/lib/suitecrm-console.sh.
#   And on every line of every file of the plugin: no $SKILL_DIR; every /clouve/skills/suitecrm/plugin/<path>
#   exists; every relative Markdown link leads to a file; and the description is the same text in SKILL.md,
#   plugin.json and marketplace.json.
#
# Part 2, the run. The placeholders are filled with fixtures the test makes (a user, a role, a group, one
# record of each module, a CSV file (and one with an id column for commands with --update), an import with its
# receipt, a Module Loader package and its sha256, a backup, a detached job, a kept upgrade backup, a password
# file), and each command runs in file order. Three placeholders follow the commands themselves:
#   <plan id>     import-csv.sh run takes the id of a plan that was made for the same file with the same
#                 options, once. So before a command with <plan id> the test runs that command's own plan (the
#                 same line with plan in place of run, without --plan and --yes-import) and fills in the id
#                 that it prints.
#   <receipt id>  the receipt of the newest import that a command of the Markdown ran (import-csv.sh run prints
#                 it), or of the import the fixtures made.
#   <sha256>      the checksum of the fixture package, which is what packages.sh inspect prints for it.
# A command that calls a script of the skill passes unless it ends with:
#   64 with usage text, an unknown option or a missing argument, or 64 at all when it carries a --yes- flag
#      (64 without one is the preview of an action that waits for the user's yes, which is what the Markdown
#      shows first);
#   2 (SuiteCRM refused, did not keep the change, or the script stopped), 65 (the input the Markdown gives is
#      not valid), 70 (a crash), 75 (refused as busy), 1 (a setting or a tool is missing), 126 or 127 (not
#      found, not executable), 255 (ssh failed), or a timeout.
# After a command that starts a job with --detach, the test waits for the job to end, as the assistant does
# with --status, and <job> stands for that job from then on. Before a command that takes a backup it waits one
# second, because a backup is named after the second it starts in and a second one in that second is refused. Outgoing email is set up against a throwaway
# SMTP server in the stack, so that a test message and an invitation go out.
# Exits that depend on what the commands before it did (3 no such record, 4 it exists already, 76 no recent
# backup, 8) pass: the command was well formed and the script answered. A command that calls no script of the skill (a raw ssh line, compgen, ls) passes unless its shell
# can't find or run it, or ssh fails.
# The test prints every command it could not run, and why. There should be none.
#
# The placeholders: <id> (a record of the module named in the command), <account id>, <contact id>,
# <lead id>, <opportunity id>, <login>, <new login>, <role>, <group>, <new role>, <new group>, <address>,
# <file.csv>, <file.zip>, <sha256>, <plan id>, <receipt id>, <backup>, <job>, <kept backup>, <package id>,
# <password file>, <text>.
#
# Settings: SC_TEST_STATIC_ONLY=1, SC_TEST_REUSE=<stack id>, SC_TEST_KEEP=1, SC_TEST_FILES="<substring>"
# (run only the files whose path holds it), SC_TEST_VERBOSE=1 (print each command's exit code), and the
# SC_STACK_* of tests/lib/suitecrm-stack/stack.sh.
#
# Usage: bash tests/suitecrm-skill-commands.test.sh   (exit 0 = all pass)
# ============================================================================

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
plugin="${root}/plugins/suitecrm"
work="$(mktemp -d "${TMPDIR:-/tmp}/suitecrm-commands-test.XXXXXX")"
S=/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts

for tool in python3 jq; do
    command -v "${tool}" > /dev/null || { echo "suitecrm-skill-commands: this test needs ${tool} on PATH" >&2; exit 1; }
done

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 40 | sed 's/^/       | /'; fi
}

# ---------------------------------------------------------------------------
# Part 1: the form
# ---------------------------------------------------------------------------
echo "The form of the commands"
python3 -I - "${root}" "${work}/commands.json" > "${work}/static.txt" <<'PY'
import json, os, pathlib, re, subprocess, sys

root = pathlib.Path(sys.argv[1])
plugin = root / "plugins" / "suitecrm"
skill = plugin / "skills" / "suitecrm"
S = "/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts"
VOCAB = {"id", "account id", "contact id", "lead id", "opportunity id", "login", "new login", "role", "group",
         "new role", "new group", "address", "file.csv", "file.zip", "sha256", "plan id", "receipt id", "backup", "job",
         "kept backup", "package id", "password file", "text"}
SHELL_TAGS = {"", "bash", "sh", "shell", "console", "zsh"}
scripts = sorted(p.name for p in (skill / "scripts").glob("*.sh"))
problems = []
commands = []


def say(rule, file, line, text):
    problems.append(f"{rule}\t{file.relative_to(root)}:{line}\t{text}")


def strip_comment(line):
    """Drops a trailing # comment that is outside quotes."""
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
    """The quote that is still open at the end of text, or ''. A backslash escapes inside double quotes."""
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


def fence_commands(file):
    lines = file.read_text().splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r"^(\s*(?:>\s*)?)(```+|~~~+)\s*([A-Za-z0-9_-]*)\s*$", lines[i])
        if not m:
            i += 1
            continue
        indent, mark, tag = m.group(1), m.group(2), m.group(3).lower()
        body = []
        start = i + 2
        i += 1
        while i < len(lines) and not re.match(r"^\s*(?:>\s*)?" + re.escape(mark[:3]) + r"+\s*$", lines[i]):
            text = lines[i]
            body.append(text[len(indent):] if text.startswith(indent) else text.lstrip())
            i += 1
        i += 1
        if tag not in SHELL_TAGS:
            continue
        j = 0
        while j < len(body):
            first = start + j
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
                word = h.group(2)
                while j < len(body):
                    text += "\n" + body[j]
                    j += 1
                    if body[j - 1].strip() == word:
                        break
            out.append((first, text))
    return out


def placeholders(file, line, head):
    """Checks each <placeholder> of the command's own text (a heredoc's body is data, not checked)."""
    quote = ""
    i = 0
    found = []
    while i < len(head):
        c = head[i]
        if quote == '"' and c == "\\":
            i += 2
            continue
        if quote:
            if c == quote:
                quote = ""
        elif c in "'\"":
            quote = c
        if c == "<":
            m = re.match(r"<([a-z][a-z0-9 ._-]*)>", head[i:])
            if m:
                name = m.group(1)
                found.append(name)
                if name not in VOCAB:
                    say("placeholder not on the list", file, line, f"<{name}>")
                elif quote != "'":
                    say("placeholder outside single quotes", file, line, f"<{name}> in {head.strip()[:120]}")
                i += len(m.group(0))
                continue
        i += 1
    return found


def check_sql(file, line, text):
    m = re.search(r"sql-read\.sh((?:\s+--table|\s+--max-rows\s+\d+)*)\s+(['\"])(.*)\2\s*$", text, re.S)
    if not m:
        if "<<" not in text and "<" not in text.split("sql-read.sh", 1)[1]:
            say("sql-read.sh without a quoted query", file, line, text.strip()[:120])
        return
    sql = m.group(3).strip().rstrip(";").strip()
    if not re.match(r"(?is)^select\b", sql):
        say("a query that does not start with SELECT", file, line, sql[:100])
    if ";" in re.sub(r"'[^']*'", "''", sql):
        say("a query with more than one statement", file, line, sql[:100])
    tables = len(re.findall(r"(?i)\b(?:FROM|JOIN)\s+(?:accounts_contacts|accounts_opportunities|opportunities_contacts|accounts|contacts|leads|opportunities|email_addr_bean_rel)\b", sql))
    flags = len(re.findall(r"(?i)\bdeleted\s*=\s*0\b", sql))
    if flags < tables:
        say("a query without deleted = 0 for each module or link table", file, line, f"{tables} tables, {flags} filters: {sql[:100]}")


md_files = sorted(skill.rglob("*.md"), key=lambda p: (p.name != "SKILL.md", str(p)))
for file in md_files:
    for line, text in fence_commands(file):
        head = text.split("\n", 1)[0] if "<<" in text.split("\n", 1)[0] else text
        names = placeholders(file, line, head)
        words = re.findall(r"[^\s'\"|;&()]+", head)
        uses_skill = S in text
        for w in words:
            base = w.rsplit("/", 1)[-1]
            if base in scripts and w != f"{S}/{base}":
                if base in ("backup.sh", "restore.sh") and "run-in-suitecrm.sh" in head:
                    continue
                say("a script not called by its absolute path", file, line, w)
        for cmd in ("docker", "podman", "kubectl", "systemctl", "service", "mysql", "mariadb", "mysqldump", "mariadb-dump", "mysqladmin"):
            if re.search(r"(?:^|[|;&(]\s*|\bsudo\s+(?:-\S+\s+)*|['\"])" + re.escape(cmd) + r"\s", head):
                say(f"a {cmd} command", file, line, head.strip()[:120])
        if re.search(r"bin/console", head) and "console.sh" not in head:
            say("a raw bin/console command", file, line, head.strip()[:120])
        if re.search(r"sshpass\s+-p|curl\s[^|;]*\s(?:-u|--user)\s|--password=|\s-p['\"]?[A-Za-z0-9$]", head) and "mkdir -p" not in head:
            say("a password on a command line", file, line, head.strip()[:120])
        if "sshpass" in head and 'SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e' not in head:
            say("an sshpass command that does not set SSHPASS in the two-part form", file, line, head.strip()[:120])
        if f"{S}/sql-read.sh" in head:
            check_sql(file, line, text if "<<" not in head else head)
        m = re.search(re.escape(f"{S}/console.sh") + r"\s+(.*)$", head)
        if m:
            lib = skill / "scripts" / "lib" / "suitecrm-console.sh"
            got = subprocess.run(["bash", "-c", f'. "{lib}"; sc_console_refusal {m.group(1)}'], capture_output=True, text=True).stdout.strip()
            if got:
                say("a console.sh command that is refused", file, line, got[:120])
        module = next((w for w in re.findall(r"\b(Accounts|Contacts|Leads|Opportunities)\b", head)), "")
        commands.append({"file": str(file.relative_to(skill)), "line": line, "text": text, "skill": uses_skill,
                         "placeholders": names, "module": module, "yes": bool(re.search(r"--yes-[a-z-]+", head))})

# Every line of every file
for file in sorted(p for p in plugin.rglob("*") if p.is_file() and p.suffix in (".md", ".sh", ".php", ".json")):
    for n, text in enumerate(file.read_text().splitlines(), 1):
        if re.search(r"\$\{?SKILL_DIR\b", text):
            say("$SKILL_DIR", file, n, text.strip()[:100])
        for m in re.finditer(r"/clouve/skills/suitecrm/plugin/([A-Za-z0-9_./-]+)", text):
            path = m.group(1).rstrip("./")
            if path and not (plugin / path).exists():
                say("a path that is not in the plugin", file, n, m.group(0))
        if file.suffix == ".md":
            for m in re.finditer(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", text):
                target = m.group(1)
                if re.match(r"[a-z]+:", target):
                    continue
                if not (file.parent / target).exists():
                    say("a link to a file that is not there", file, n, target)

desc = {}
m = re.search(r"^description: (.*)$", (skill / "SKILL.md").read_text(), re.M)
desc["SKILL.md"] = m.group(1).strip() if m else ""
desc["plugin.json"] = json.loads((plugin / ".claude-plugin" / "plugin.json").read_text()).get("description", "")
catalog = json.loads((root / ".claude-plugin" / "marketplace.json").read_text())
desc["marketplace.json"] = next((p.get("description", "") for p in catalog["plugins"] if p["name"] == "suitecrm"), "")
if len(set(desc.values())) != 1 or not desc["SKILL.md"]:
    problems.append("the description differs\tSKILL.md, plugin.json, marketplace.json\t" + " / ".join(f"{k}: {len(v)} chars" for k, v in desc.items()))

json.dump(commands, open(sys.argv[2], "w"))
print(f"COUNT\t{len(commands)}\t{len(md_files)}")
for p in problems:
    print(p)
PY
count="$(sed -n 's/^COUNT\t\([0-9]*\)\t.*/\1/p' "${work}/static.txt")"
files="$(sed -n 's/^COUNT\t[0-9]*\t\([0-9]*\)$/\1/p' "${work}/static.txt")"
if [ "${count:-0}" -ge 60 ]; then ok "found ${count} commands in ${files} Markdown files"; else bad "found the commands (${count:-0} in ${files:-0} files; the skill has far more, so the reading is broken)"; fi
for rule in "a script not called by its absolute path" "placeholder not on the list" "placeholder outside single quotes" \
    "a docker command" "a podman command" "a kubectl command" "a systemctl command" "a service command" \
    "a mysql command" "a mariadb command" "a mysqldump command" "a mariadb-dump command" "a mysqladmin command" \
    "a raw bin/console command" "a password on a command line" "an sshpass command that does not set SSHPASS in the two-part form" \
    "sql-read.sh without a quoted query" "a query that does not start with SELECT" "a query with more than one statement" \
    "a query without deleted = 0 for each module or link table" "a console.sh command that is refused" \
    '$SKILL_DIR' "a path that is not in the plugin" "a link to a file that is not there" "the description differs"; do
    hits="$(awk -F'\t' -v r="${rule}" '$1 == r { print $2 "  " $3 }' "${work}/static.txt")"
    if [ -z "${hits}" ]; then ok "none: ${rule}"; else bad "none: ${rule}" "${hits}"; fi
done

if [ "${SC_TEST_STATIC_ONLY:-0}" = 1 ]; then
    rm -rf "${work}"
    echo
    echo "suitecrm-skill-commands (static only): ${pass} passed, ${fail} failed"
    [ "${fail}" -eq 0 ]
    exit $?
fi

# ---------------------------------------------------------------------------
# Part 2: the run
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
. "${here}/lib/suitecrm-stack/stack.sh"
command -v docker > /dev/null || { echo "suitecrm-skill-commands: the run needs docker" >&2; exit 1; }

sc_names() {
    SC_NET="${SC_STACK_PREFIX}-net-${SC_ID}"
    SC_DB="${SC_STACK_PREFIX}-db-${SC_ID}"
    SC_APP="${SC_STACK_PREFIX}-app-${SC_ID}"
    SC_AGENT="${SC_STACK_PREFIX}-agent-${SC_ID}"
    SC_VOL_APP="${SC_STACK_PREFIX}-appdata-${SC_ID}"
    SC_VOL_DB="${SC_STACK_PREFIX}-dbdata-${SC_ID}"
}
cleanup() {
    if [ -z "${SC_TEST_REUSE:-}" ] && [ "${SC_TEST_KEEP:-0}" != 1 ]; then sc_stack_down; fi
    rm -rf "${work}"
}
trap cleanup EXIT

sc_stack_build || exit $?
if [ -n "${SC_TEST_REUSE:-}" ]; then
    SC_ID="${SC_TEST_REUSE}"
    sc_names
else
    echo
    echo "Starting the stack..."
    sc_stack_up "c$$" || { echo "suitecrm-skill-commands: the stack did not start" >&2; exit 1; }
fi

# agent CMD: runs CMD as the agent's user; prints stdout
agent() { sc_agent "$1" 2> "${work}/seed.err"; }
agent_in() { sc_agent_stdin "$1" 2> "${work}/seed.err"; }

# A Module Loader package for <file.zip> and <package id>
mkdir -p "${work}/pkg/files"
cat > "${work}/pkg/manifest.php" <<'PHP'
<?php
$manifest = ['name' => 'Test Hello', 'description' => 'A test package', 'version' => '1.0.0', 'author' => 'Test',
    'acceptable_sugar_versions' => ['regex_matches' => ['6\.5\.[0-9]+']], 'acceptable_suitecrm_versions' => ['regex_matches' => ['8\..*']],
    'type' => 'module', 'is_uninstallable' => true, 'published_date' => '2026-11-12'];
$installdefs = ['id' => 'test_hello', 'copy' => [['from' => '<basepath>/files/TestHello.php', 'to' => 'custom/include/TestHello.php']]];
PHP
printf '<?php\n// test package file\n' > "${work}/pkg/files/TestHello.php"
(cd "${work}/pkg" && python3 -I -c "
import zipfile
z = zipfile.ZipFile('../test_hello.zip', 'w')
z.write('manifest.php'); z.write('files/TestHello.php')
z.close()")
docker cp "${work}/test_hello.zip" "${SC_AGENT}:/home/clouve/test_hello.zip" > /dev/null
docker exec "${SC_AGENT}" chown clouve:clouve /home/clouve/test_hello.zip
# <sha256>: what packages.sh inspect prints for that file, and what install takes
f_sha="$(sha256sum "${work}/test_hello.zip" | cut -d' ' -f1)"

# Outgoing email, so that a test message and an invitation have somewhere to go: a throwaway SMTP server in
# the SuiteCRM container, and the account an admin would save in SuiteCRM's own form (the scripts test's fixtures)
docker exec "${SC_APP}" rm -rf /tmp/fixtures
docker cp "${here}/lib/suitecrm-stack/fixtures" "${SC_APP}:/tmp/fixtures" > /dev/null
docker cp "${SC_STACK_PLUGIN}/skills/suitecrm/scripts/remote/boot.php" "${SC_APP}:/tmp/fixtures/boot.php" > /dev/null
docker cp "${here}/lib/suitecrm-stack/smtp-sink.php" "${SC_APP}:/tmp/smtp-sink.php" > /dev/null
docker exec -d "${SC_APP}" php /tmp/smtp-sink.php

seq_no=0
# seed: makes, or makes again, everything the placeholders stand for
seed() {
    seq_no=$((seq_no + 1))
    # What a restore of the file before left: its hold on the scheduler, and a marker if it was cut off
    sc_app_root 'rm -f /var/www/html/tmp/clouve-backup/restore-in-progress /var/www/html/tmp/clouve-skill-backups/RESTORE-IN-PROGRESS /var/www/html/tmp/clouve-backup/scheduler-held'
    printf 'Smtp-Pw-3kLm8Qz5wT\n' | docker exec -i -u www-data "${SC_APP}" php /tmp/fixtures/smtp-form.php > /dev/null 2>&1
    if ! agent "$S/users.sh show pat" > /dev/null; then
        agent "$S/temp-password.sh --create --first-name Pat --last-name Probe --email pat@example.test pat" > /dev/null
    fi
    agent "$S/users.sh activate pat" > /dev/null
    agent "$S/users.sh set-admin pat no" > /dev/null
    agent "$S/users.sh role-create 'Sales Rep'" > /dev/null
    agent "$S/users.sh group-create 'West Team'" > /dev/null
    f_account="$(printf '{"name": "Globex Fixture %s"}' "${seq_no}" | agent_in "$S/records.sh create Accounts" | jq -r '.id // empty')"
    f_contact="$(printf '{"first_name": "Hank", "last_name": "Fixture%s", "email1": "hank%s@globex.example", "account_id": "%s"}' "${seq_no}" "${seq_no}" "${f_account}" | agent_in "$S/records.sh create Contacts" | jq -r '.id // empty')"
    f_lead="$(printf '{"first_name": "Lisa", "last_name": "Fixture%s", "email1": "lisa%s@example.test"}' "${seq_no}" "${seq_no}" | agent_in "$S/records.sh create Leads" | jq -r '.id // empty')"
    f_opp="$(printf '{"name": "Globex deal %s", "sales_stage": "Prospecting", "amount": 1000, "date_closed": "2027-01-15", "account_id": "%s"}' "${seq_no}" "${f_account}" | agent_in "$S/records.sh create Opportunities" | jq -r '.id // empty')"
    printf 'first_name,last_name,email1,title\nIda,Import%s,ida%s@example.test,Buyer\n' "${seq_no}" "${seq_no}" | agent_in 'cat > ~/contacts.csv'
    printf 'id,title\n%s,Buyer\n' "${f_contact}" | agent_in 'cat > ~/contacts-update.csv'
    f_backup="$(agent "$S/run-in-suitecrm.sh backup.sh" | sed -n 's/^Backup \([0-9]\{8\}-[0-9]\{6\}\) is complete.*/\1/p')"
    # An import of the skill's own, so that <receipt id> stands for a run whatever the commands before it did
    printf 'first_name,last_name,email1\nSam,Seed%s,sam%s@example.test\n' "${seq_no}" "${seq_no}" | agent_in 'cat > ~/contacts-seed.csv'
    f_plan="$(agent "$S/import-csv.sh plan Contacts ~/contacts-seed.csv" | jq -r '.plan_id // empty')"
    f_receipt="$(agent "$S/import-csv.sh run Contacts ~/contacts-seed.csv --plan ${f_plan:-none} --yes-import" | jq -r '.receipt // empty')"
    agent "$S/packages.sh install ~/test_hello.zip --sha256 ${f_sha} --yes-install" > /dev/null
    sc_app_root 'install -d -m 700 /var/www/html/tmp/clouve-backup/8.9.1-to-8.10.2 && echo x > /var/www/html/tmp/clouve-backup/8.9.1-to-8.10.2/db.sql.gz'
    f_job="$(agent "$S/run-in-suitecrm.sh --detach backup.sh" | sed -n 's/^job: //p')"
    for _ in $(seq 1 30); do
        agent "$S/run-in-suitecrm.sh --status ${f_job}" > /dev/null
        [ $? -eq 3 ] || break
        sleep 1
    done
    f_pwfile="$(agent "$S/temp-password.sh --yes-reset pat" | sed -n 's/.* to \(suitecrm-passwords\/[^ ]*\) in the Files pane\.$/\1/p')"
    if [ -z "${f_account}" ] || [ -z "${f_contact}" ] || [ -z "${f_lead}" ] || [ -z "${f_opp}" ] || [ -z "${f_backup}" ] || [ -z "${f_job}" ] || [ -z "${f_pwfile}" ] || [ -z "${f_receipt}" ]; then
        bad "(the fixtures were made)" "account=${f_account} contact=${f_contact} lead=${f_lead} opp=${f_opp} backup=${f_backup} job=${f_job} pwfile=${f_pwfile} receipt=${f_receipt}"$'\n'"$(cat "${work}/seed.err")"
    fi
}

new_no=0
# fill TEXT MODULE: TEXT with every placeholder filled in
fill() {
    local text="$1" id
    case "$2" in
        Contacts) id="${f_contact}" ;;
        Leads) id="${f_lead}" ;;
        Opportunities) id="${f_opp}" ;;
        *) id="${f_account}" ;;
    esac
    new_no=$((new_no + 1))
    text="${text//<id>/${id}}"
    text="${text//<account id>/${f_account}}"
    text="${text//<contact id>/${f_contact}}"
    text="${text//<lead id>/${f_lead}}"
    text="${text//<opportunity id>/${f_opp}}"
    text="${text//<login>/pat}"
    text="${text//<new login>/newperson${new_no}}"
    text="${text//<role>/Sales Rep}"
    text="${text//<group>/West Team}"
    text="${text//<new role>/New Role ${new_no}}"
    text="${text//<new group>/New Group ${new_no}}"
    text="${text//<address>/someone@example.test}"
    # An import with --update needs a file with an id column: the fixture for that names the fixture contact.
    if [[ "${text}" == *--update* ]]; then
        text="${text//<file.csv>//home/clouve/contacts-update.csv}"
    fi
    text="${text//<file.csv>//home/clouve/contacts.csv}"
    text="${text//<file.zip>//home/clouve/test_hello.zip}"
    text="${text//<sha256>/${f_sha}}"
    text="${text//<plan id>/${f_plan:-no-plan}}"
    text="${text//<receipt id>/${f_receipt:-no-receipt}}"
    text="${text//<backup>/${f_backup}}"
    text="${text//<job>/${f_job}}"
    text="${text//<kept backup>/8.9.1-to-8.10.2}"
    text="${text//<package id>/test_hello}"
    text="${text//<password file>/${f_pwfile}}"
    text="${text//<text>/Globex}"
    printf '%s' "${text}"
}

echo
echo "The commands, run"
seed
total="$(jq 'length' "${work}/commands.json")"
ran=0
last_file=''
file_bad=''
reseed=0
i=0
while [ "${i}" -lt "${total}" ]; do
    entry="$(jq -c ".[${i}]" "${work}/commands.json")"
    i=$((i + 1))
    file="$(jq -r '.file' <<< "${entry}")"
    if [ -n "${SC_TEST_FILES:-}" ] && [[ "${file}" != *"${SC_TEST_FILES}"* ]]; then continue; fi
    if [ "${file}" != "${last_file}" ]; then
        if [ -n "${last_file}" ]; then
            if [ -z "${file_bad}" ]; then ok "${last_file}: ${file_ran} commands ran"; else bad "${last_file}: ${file_ran} commands ran, these did not run as written" "${file_bad}"; fi
        fi
        if [ "${reseed}" -eq 1 ]; then seed; fi
        last_file="${file}"
        file_bad=''
        file_ran=0
        reseed=0
    fi
    line="$(jq -r '.line' <<< "${entry}")"
    raw="$(jq -r '.text' <<< "${entry}")"
    # A run takes the id of a plan made for this file with these options, and a plan is good for one run: make
    # that plan first, as the playbook does, with the command's own words.
    if [[ "${raw}" == *"import-csv.sh run "*"<plan id>"* ]]; then
        plan_raw="${raw/import-csv.sh run /import-csv.sh plan }"
        plan_raw="${plan_raw/ --plan \'<plan id>\'/}"
        plan_raw="${plan_raw/ --yes-import/}"
        f_plan="$(agent "$(fill "${plan_raw}" "$(jq -r '.module' <<< "${entry}")")" | jq -r '.plan_id // empty')"
    fi
    text="$(fill "${raw}" "$(jq -r '.module' <<< "${entry}")")"
    if [[ "${text%%$'\n'*}" =~ \<[a-z][a-z0-9\ ._-]*\> ]]; then
        file_bad+="line ${line}: could not run, a placeholder is not on the list: ${text%%$'\n'*}"$'\n'
        continue
    fi
    # backup.sh names a backup after the second it starts in, and refuses a second one in that same second ("run
    # this again in a second"). The Markdown shows one backup after the other, and the stand-in takes less than
    # a second for one, so each backup gets a second of its own here.
    if [[ "${text%%$'\n'*}" == *backup.sh* && "${text%%$'\n'*}" != *--list* && "${text%%$'\n'*}" != *--remove* ]]; then sleep 1; fi
    printf '%s\n' "${text}" | docker exec -i -u clouve "${SC_AGENT}" bash -c 'cat > /tmp/doc-command.sh'
    timeout 180 docker exec -u clouve -w /home/clouve "${SC_AGENT}" bash -lc 'bash /tmp/doc-command.sh' > "${work}/cmd.out" 2> "${work}/cmd.err" < /dev/null
    rc=$?
    ran=$((ran + 1))
    file_ran=$((file_ran + 1))
    err="$(cat "${work}/cmd.err")"
    # A job the Markdown started with --detach: the assistant follows it with --status before it goes on, so
    # the test waits for it too, and <job> stands for it from here on.
    started="$(sed -n 's/^job: \(\(backup\|restore\)-[0-9]\{8\}-[0-9]\{6\}\)$/\1/p' "${work}/cmd.out" | head -n 1)"
    if [ -n "${started}" ]; then
        f_job="${started}"
        for _ in $(seq 1 120); do
            agent "$S/run-in-suitecrm.sh --status ${f_job}" > /dev/null
            [ $? -eq 3 ] || break
            sleep 1
        done
    fi
    # The receipt of an import that a command made: <receipt id> stands for it from here on. An update has no
    # undo, so its receipt is not taken.
    made="$(jq -r 'select(.imported == true and .mode == "import") | .receipt // empty' "${work}/cmd.out" 2> /dev/null)"
    if [ -n "${made}" ]; then f_receipt="${made}"; fi
    why=''
    if [ "$(jq -r '.skill' <<< "${entry}")" = true ]; then
        case "${rc}" in
            64)
                if [ "$(jq -r '.yes' <<< "${entry}")" = true ]; then
                    why="exit 64 although it carries a --yes- flag"
                elif [[ "${err}" == *"Usage:"* || "${err}" == *"unknown"* || "${err}" == *"takes"* || "${err}" == *"needs"* ]]; then
                    why="exit 64, a usage error"
                fi
                ;;
            2 | 65 | 70 | 75 | 1 | 126 | 127 | 255 | 124 | 137) why="exit ${rc}" ;;
        esac
        if [ "$(jq -r '.yes' <<< "${entry}")" = true ]; then reseed=1; fi
    else
        case "${rc}" in
            126 | 127 | 255 | 124 | 137) why="exit ${rc}" ;;
        esac
        if [[ "${err}" == *"command not found"* || "${err}" == *"No such file or directory"* ]]; then why="${why:-exit ${rc}}, the shell could not find something"; fi
    fi
    if [ "${SC_TEST_VERBOSE:-0}" = 1 ]; then printf '       . %s:%s exit %s: %s\n' "${file}" "${line}" "${rc}" "$(printf '%s' "${text%%$'\n'*}" | cut -c1-150)"; fi
    if [ -n "${why}" ]; then
        file_bad+="line ${line}: ${why}: ${text%%$'\n'*}"$'\n'"    $(printf '%s' "${err}" | grep -v '^Usage\|^$' | head -n 2 | cut -c1-200 | tr '\n' ' ')"$'\n'
    fi
done
if [ -n "${last_file}" ]; then
    if [ -z "${file_bad}" ]; then ok "${last_file}: ${file_ran} commands ran"; else bad "${last_file}: ${file_ran} commands ran, these did not run as written" "${file_bad}"; fi
fi
if [ "${ran}" -gt 0 ]; then ok "${ran} commands were run in all"; else bad "no command was run"; fi

echo
echo "suitecrm-skill-commands: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
