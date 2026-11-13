#!/bin/bash
# ============================================================================
# LimeSurvey skill: the commands its Markdown gives
# ============================================================================
# The assistant runs the commands of SKILL.md, the playbooks and the references as they are written. This test
# reads them and runs them.
#
# Part 1 reads the plugin's files and nothing else (no Docker). The corpus is the fenced code blocks of every .md
# file that are shell (tagged bash, sh, shell or console, or not tagged), one command per line, with a trailing
# backslash joining lines and comment lines left out. A fence with any other tag (text, yaml, json) is what a
# command prints or a file's content, and is not run. The rules:
#   1. A script of the skill is called by its absolute path,
#      /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/<name>, and that file is there and executable.
#   2. Every /clouve/skills/limesurvey/plugin/<path> named anywhere in the plugin exists as plugins/limesurvey/<path>.
#   3. No docker, podman or kubectl command: the agent has none.
#   4. No password on a command line: mysql or mariadb with -p<password> or --password=, sshpass -p, curl -u, or
#      LimeSurvey's console command resetpassword.
#   5. console.php is never called directly, only through console.sh, and never with wipe, demomode or install.
#   6. SQL handed to mysql with -e starts no statement with INSERT, UPDATE, DELETE, ALTER, DROP, TRUNCATE, CREATE,
#      REPLACE, RENAME, GRANT or REVOKE.
#   7. invitations.sh with --send also has --expect; rc.sh with a method that changes the site has --yes; and
#      rc.sh is never given a method it refuses (the ones that send mail, activate, delete, export or write
#      answers: each has a script of its own).
#   8. Every relative link in a .md file leads to a file that exists, and its #anchor to a heading of that file.
#   9. A <placeholder> in a command is one the live part has a value for (PLACEHOLDERS below), so that no command
#      is left out of part 2 without anyone noticing.
# A self-check first runs the rules on a small made-up plugin with one bad line per rule: a rule that stops
# firing fails there.
#
# Part 2 runs every one of those commands in the stand-in stack of tests/lib/limesurvey-stack.sh (a real
# LimeSurvey 7.10.0, MariaDB 11.8, a stand-in for the agent, a mail sink), from the agent's login shell, the way
# the assistant would. Before each file's commands the site is put back to one fixture state: a survey (987002)
# that is active, with three participants, three answer sets, an admin account, an uploaded plugin and theme, a
# stand-in for the Customer Kit's SuiteCRM plugin, two backups and the kept backup of a finished upgrade. Each
# placeholder gets that fixture's value: <people file> is one more person, so the invitations of the playbook go
# to four people (<number of recipients>). A command passes when it ends with exit 0, or with the exit code
# EXPECTED below gives for it, with the reason it is right. It fails on any other code, and on output that shows
# the command was not understood (a usage error, an unknown option or method, a method rc.sh refuses, a change
# without its yes, a wrong parameter name, a missing file or program).
#
# A command that ends well can still print what it must not. So what each command prints is searched for the
# values that have to stay out of the chat: every participant's access code, the values of security.php, the
# passwords of the stack, the admin accounts' session tokens, and what a participant typed into a text question.
# MAY_PRINT lists the commands that show one of these on purpose, each with its reason.
#
# BEFORE lists what the test does to the site just before a command, so that the command has something to do: a
# reminder is due only days after the invitation. CHECK lists what has to be true after a command.
#
# NOT_RUN lists the commands part 2 leaves out, each with its reason. The test prints them.
#
# Settings: see tests/lib/limesurvey-stack.sh. LS_COMMANDS_STATIC_ONLY=1 runs part 1 alone.
#
# Usage: bash tests/limesurvey-skill-commands.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: commands and patterns are literal text, with $ in single quotes on purpose.
# SC2154: lib/limesurvey-stack.sh, sourced below, sets the ls_* variables.
# shellcheck disable=SC2016,SC2154

set -uo pipefail
exec < /dev/null

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${here}/.." && pwd)"
plugin="${root}/plugins/limesurvey"
command -v python3 > /dev/null || { echo "limesurvey-skill-commands: this test needs python3" >&2; exit 1; }
[ -d "${plugin}" ] || { echo "limesurvey-skill-commands: ${plugin} is missing" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/limesurvey-skill-commands.XXXXXX")"
stack_up=no
cleanup() {
    if [ "${stack_up}" = yes ]; then ls_stack_down; fi
    rm -rf "${work}"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() {
    fail=$((fail + 1))
    printf '  FAIL %s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2" | head -n 12 | cut -c1-260 | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }

# The placeholders of the Markdown, and the fixture's value for each. backup, question and the two exported files
# are filled in once the fixture exists.
declare -A PLACEHOLDERS=(
    ['<survey id>']=987002
    ['<participant id>']=1
    ['<response id>']=1
    ['<address>']=admin@example.test
    ['<login>']=jane
    ['<full name>']='Jane Doe'
    ['<password file>']=jane-20260101-000000.txt
    ['<upgrade folder>']=upgrade-6.16.1-to-7.10.0
    ['<people file>']=/tmp/files/more-people.csv
    ['<survey file>']=/tmp/files/second-draft.txt
    ['<structure file>']=/tmp/files/survey-987002.lss
    ['<archive file>']=/tmp/files/survey-987002.lsa
    ['<plugin name>']=LssGoodPlugin
    ['<theme name>']=lss_test_theme
    ['<number of recipients>']=4
    ['<backup name>']=''
    ['<question id>']=''
)

# ---------------------------------------------------------------------------
# The checker: prints "cmd<TAB>file<TAB>line<TAB>command" for each command of the corpus, and
# "bad<TAB>rule<TAB>file:line<TAB>detail" for each finding
# ---------------------------------------------------------------------------
cat > "${work}/check.py" <<'PY'
import os, re, sys
base = sys.argv[1]                      # .../plugins/<name>
name = os.path.basename(base)
known = set(sys.argv[2].split("|")) if len(sys.argv) > 2 and sys.argv[2] else set()
prefix = "/clouve/skills/%s/plugin/" % name
scripts = prefix + "skills/%s/scripts/" % name
shell_tags = {"", "bash", "sh", "shell", "console"}
own = set()
sdir = os.path.join(base, "skills", name, "scripts")
if os.path.isdir(sdir):
    own = {f for f in os.listdir(sdir) if f.endswith(".sh")}

def out(*cols):
    print("\t".join(str(c).replace("\t", " ").replace("\n", " ") for c in cols))

def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")

def headings(path):
    found, fence = set(), False
    for line in open(path, encoding="utf-8"):
        if line.lstrip().startswith("```"):
            fence = not fence
        elif not fence and line.startswith("#"):
            found.add(slug(line.lstrip("#")))
    return found

files = []
for d, _, names in os.walk(base):
    for n in sorted(names):
        if n.endswith((".md", ".sh", ".php", ".json")):
            files.append(os.path.join(d, n))
for path in sorted(files):
    rel = os.path.relpath(path, base)
    text = open(path, encoding="utf-8").read()
    lines = text.splitlines()
    # Rule 2: every path under the plugin's staged folder exists.
    for i, line in enumerate(lines, 1):
        for m in re.finditer(re.escape(prefix) + r"([A-Za-z0-9_./-]*[A-Za-z0-9_/-])", line):
            target = m.group(1).rstrip("/")
            if not os.path.exists(os.path.join(base, target)):
                out("bad", 2, "%s:%d" % (rel, i), prefix + target + " does not exist in the plugin")
    if not path.endswith(".md"):
        continue
    # Rule 8: links.
    fence = False
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        for m in re.finditer(r"\]\(([^)\s]+)\)", line):
            link = m.group(1)
            if re.match(r"[a-z]+:", link):
                continue
            target, _, anchor = link.partition("#")
            dest = os.path.normpath(os.path.join(os.path.dirname(path), target)) if target else path
            if not os.path.exists(dest):
                out("bad", 8, "%s:%d" % (rel, i), "the link %s leads nowhere" % link)
            elif anchor and dest.endswith(".md") and anchor not in headings(dest):
                out("bad", 8, "%s:%d" % (rel, i), "%s has no heading for #%s" % (os.path.relpath(dest, base), anchor))
    # The shell fences, one command per line.
    fence, tag, buf, start = False, "", "", 0
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("```"):
            if not fence:
                fence, tag = True, stripped[3:].strip().lower()
            else:
                fence = False
            buf = ""
            continue
        if not fence or tag not in shell_tags:
            continue
        if not buf and (not stripped or stripped.startswith("#")):
            continue
        if not buf:
            start = i
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        cmd = buf + stripped
        buf = ""
        where = "%s:%d" % (rel, start)
        out("cmd", rel, start, cmd)
        words = cmd.split()
        # Rule 1: the skill's scripts by absolute path.
        for m in re.finditer(r"(?:^|[\s|;&(])([A-Za-z0-9_./${}-]*?)([a-z][a-z0-9-]*\.sh)(?=\s|$)", cmd):
            lead, script = m.group(1), m.group(2)
            if script not in own:
                continue
            if lead != scripts:
                # An in-container script named as an argument of run-in-limesurvey.sh is fine.
                before = cmd[:m.start(2)].rstrip().split()
                if lead == "" and before and before[-1].endswith("run-in-limesurvey.sh") or (lead == "" and "--stdin" in before[-2:] and any(b.endswith("run-in-limesurvey.sh") for b in before)):
                    continue
                out("bad", 1, where, "%s is not called as %s%s" % (script, scripts, script))
            elif not os.access(os.path.join(sdir, script), os.X_OK):
                out("bad", 1, where, "%s is not executable" % script)
        # Rule 3.
        first = re.sub(r"^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+)?", "", cmd).split(" ")[0]
        if first in ("docker", "podman", "kubectl") or re.search(r"[|;&]\s*(docker|podman|kubectl)\s", cmd):
            out("bad", 3, where, "the agent has no " + first)
        # Rule 4.
        if re.search(r"\b(mysql|mariadb|mysqldump|mariadb-dump|mysqladmin)\b[^|;]*\s(-p\S+|--password(=|\s))", cmd):
            out("bad", 4, where, "a database password on the command line")
        if re.search(r"\bsshpass\s+-p", cmd) or re.search(r"\bcurl\b[^|;]*\s-u\b", cmd) or re.search(r"\bresetpassword\b", cmd):
            out("bad", 4, where, "a password on the command line")
        # Rule 5.
        if "console.php" in cmd:
            out("bad", 5, where, "console.php is called directly; use console.sh")
        if re.search(r"console\.sh\s+(--\S+\s+)*(wipe|demomode|install)\b", cmd):
            out("bad", 5, where, "a console command that is never run")
        # Rule 6.
        for m in re.finditer(r"""\s-e\s+(['"])(.*?)\1""", cmd):
            if re.search(r"\b(mysql|mariadb)\b", cmd[:m.start()]):
                for statement in m.group(2).split(";"):
                    if re.match(r"\s*(INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE|CREATE|REPLACE|RENAME|GRANT|REVOKE)\b", statement, re.I):
                        out("bad", 6, where, "SQL that writes: " + statement.strip()[:40])
        # Rule 7.
        if "invitations.sh" in cmd and "--send" in words and "--expect" not in words:
            out("bad", 7, where, "invitations.sh --send without --expect")
        if "rc.sh" in cmd and re.search(r"\s(set_[a-z_]+|add_survey|copy_survey|add_group|add_language|add_quota|import_group|import_question)\s*$", cmd) and "--yes" not in words:
            out("bad", 7, where, "rc.sh runs a method that changes the site without --yes")
        if "rc.sh" in cmd and re.search(r"\s(activate_survey|delete_[a-z_]+|invite_participants|remind_participants|mail_registered_participants|export_responses(_by_token)?|export_statistics|add_response|update_response|upload_file|get_uploaded_files|activate_tokens|add_participants|cpd_importParticipants|import_survey|get_session_key|release_session_key)\s*$", cmd):
            out("bad", 7, where, "rc.sh is given a method it refuses: use the script for it")
        # Rule 9.
        for m in re.finditer(r"<[a-z][a-z ]*>", cmd):
            if m.group(0) not in known:
                out("bad", 9, where, "the placeholder %s has no fixture value in this test" % m.group(0))
PY

known="$(printf '%s|' "${!PLACEHOLDERS[@]}")"

# ---------------------------------------------------------------------------
section "1. The checker checks itself"
# ---------------------------------------------------------------------------
fx="${work}/fixture/plugins/limesurvey"
mkdir -p "${fx}/skills/limesurvey/scripts" "${fx}/skills/limesurvey/reference"
printf '#!/bin/bash\n' > "${fx}/skills/limesurvey/scripts/rc.sh"
printf '#!/bin/bash\n' > "${fx}/skills/limesurvey/scripts/console.sh"
printf '#!/bin/bash\n' > "${fx}/skills/limesurvey/scripts/invitations.sh"
chmod +x "${fx}/skills/limesurvey/scripts/"*.sh
printf '# Other\n\n## A heading\n' > "${fx}/skills/limesurvey/reference/other.md"
S=/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts
cat > "${fx}/skills/limesurvey/SKILL.md" <<MD
# Fixture

See [other](reference/other.md#a-heading), [gone](reference/gone.md) and [no anchor](reference/other.md#nope).

\`\`\`bash
${S}/rc.sh list_surveys
rc.sh list_surveys
${S}/missing.sh
docker ps
MYSQL_PWD=x mysql -h db -pSecret db -e 'SELECT 1'
sshpass -p secret ssh host
php application/commands/console.php flushassets
${S}/console.sh wipe yes
mysql -h db -e 'DELETE FROM lime_surveys'
mysql -h db -e 'SELECT 1; SELECT "delete"'
${S}/invitations.sh invite --survey 1 --send
${S}/invitations.sh invite --survey 1 --send --expect 2
printf x | ${S}/rc.sh --stdin set_survey_properties
printf x | ${S}/rc.sh --yes --stdin set_survey_properties
printf x | ${S}/rc.sh --yes --stdin delete_survey
${S}/rc.sh <mystery thing>
\`\`\`

\`\`\`text
docker ps
\`\`\`
MD
python3 -I "${work}/check.py" "${fx}" '<survey id>|' > "${work}/fixture.out"
want_rules() { # LINE RULES...: the fixture's SKILL.md line has findings of exactly these rules
    local line="$1" got
    shift
    got="$(awk -F'\t' -v at="skills/limesurvey/SKILL.md:${line}" '$1 == "bad" && $3 == at { print $2 }' "${work}/fixture.out" | sort -u | tr '\n' ' ')"
    if [ "${got}" = "$*" ]; then ok "fixture line ${line}: rules [${*}]"; else bad "fixture line ${line}: wanted rules [${*}], got [${got}]"; fi
}
want_rules 3 '8 '          # the two bad links
want_rules 6 ''            # a good command
want_rules 7 '1 '          # a bare rc.sh
want_rules 8 '2 '          # a script that is not there
want_rules 9 '3 '          # docker
want_rules 10 '4 '         # mysql -p
want_rules 11 '4 '         # sshpass -p
want_rules 12 '5 '         # console.php
want_rules 13 '5 '         # console.sh wipe
want_rules 14 '6 '         # SQL write
want_rules 15 ''           # SQL reads
want_rules 16 '7 '         # --send without --expect
want_rules 17 ''
want_rules 18 '7 '         # a change without --yes
want_rules 19 ''
want_rules 20 '7 '         # a method rc.sh refuses, with --yes or without
want_rules 21 '9 '         # an unknown placeholder
is_count="$(grep -c '^cmd' "${work}/fixture.out")"
if [ "${is_count}" -eq 16 ]; then ok "the corpus is the 16 commands of the bash fence, and the text fence is left out"; else bad "the corpus is the 16 commands of the bash fence (got ${is_count})"; fi

# ---------------------------------------------------------------------------
section "2. The plugin's Markdown, read"
# ---------------------------------------------------------------------------
python3 -I "${work}/check.py" "${plugin}" "${known}" > "${work}/plugin.out"
grep '^cmd' "${work}/plugin.out" > "${work}/commands.tsv" || true
total="$(wc -l < "${work}/commands.tsv")"
if [ "${total}" -ge 80 ]; then ok "the Markdown gives ${total} commands"; else bad "the Markdown gives ${total} commands, fewer than this test expects to find"; fi
for rule in 1 2 3 4 5 6 7 8 9; do
    hits="$(awk -F'\t' -v r="${rule}" '$1 == "bad" && $2 == r { print $3 ": " $4 }' "${work}/plugin.out")"
    case "${rule}" in
        1) label="every script of the skill is called by its absolute path, and is there and executable" ;;
        2) label="every /clouve/skills/limesurvey/plugin/ path named in the plugin exists" ;;
        3) label="no docker, podman or kubectl command" ;;
        4) label="no password on a command line" ;;
        5) label="console.php only through console.sh, and never wipe, demomode or install" ;;
        6) label="no SQL that writes" ;;
        7) label="--send has --expect, a method that changes the site has --yes, and rc.sh is given no method it refuses" ;;
        8) label="every relative link and anchor leads somewhere" ;;
        9) label="every placeholder in a command has a fixture value" ;;
    esac
    if [ -z "${hits}" ]; then ok "${label}"; else bad "${label}" "${hits}"; fi
done

if [ "${LS_COMMANDS_STATIC_ONLY:-0}" = 1 ]; then
    echo
    echo "${pass} passed, ${fail} failed (part 2 was not run: LS_COMMANDS_STATIC_ONLY=1)"
    [ "${fail}" -eq 0 ]
    exit $?
fi

# ---------------------------------------------------------------------------
section "3. The fixture"
# ---------------------------------------------------------------------------
# shellcheck source=lib/limesurvey-stack.sh
. "${here}/lib/limesurvey-stack.sh"
command -v docker > /dev/null || { echo "limesurvey-skill-commands: part 2 needs docker" >&2; exit 1; }
echo "Building the images and starting LimeSurvey (this can take a few minutes the first time) ..."
ls_stack_images || { echo "limesurvey-skill-commands: could not build the images" >&2; exit 1; }
ls_stack_down
stack_up=yes
ls_stack_up 1 || { echo "limesurvey-skill-commands: the stack did not start" >&2; exit 1; }
ls_stack_smtp || exit 1
app="$(ls_app 1)"
agentc="$(ls_agent 1)"
fixtures="${ls_standin}/fixtures"
printf '{"op":"set-smtp","host":"%s:2525","user":"mailer@example.test","password":"Smtp-Pw-6gF1sD8kZq"}' "${ls_smtp}" | helper 1 > /dev/null

docker exec "${agentc}" mkdir -p /tmp/files
docker cp -q "${fixtures}/draft.txt" "${agentc}:/tmp/files/draft.txt"
docker exec "${agentc}" sh -c "sed 's/987002/987010/' /tmp/files/draft.txt > /tmp/files/second-draft.txt; printf 'firstname,lastname,email\nAda,Lovelace,ada@example.test\nAlan,Turing,alan@example.test\nGrace,Hopper,grace@example.test\n' > /tmp/files/people.csv; printf 'firstname,lastname,email\nEdsger,Dijkstra,edsger@example.test\n' > /tmp/files/more-people.csv"
docker cp -q "${fixtures}/LssGoodPlugin" "${app}:/var/www/html/upload/plugins/"
docker cp -q "${fixtures}/lss_test_theme" "${app}:/var/www/html/upload/themes/survey/"
app_root 1 'chown -R www-data:www-data /var/www/html/upload'

setup() { # COMMAND: a fixture step, run in the agent; it has to work
    local out
    if ! out="$(agent 1 "$1" 2>&1)"; then
        echo "limesurvey-skill-commands: a fixture step failed: $1" >&2
        printf '%s\n' "${out}" | head -n 8 >&2
        exit 1
    fi
}
setup "${S}/survey-import.sh /tmp/files/draft.txt"
setup "${S}/participants.sh create-list --survey 987002"
setup "${S}/participants.sh add --survey 987002 < /tmp/files/people.csv"
setup "${S}/survey-activate.sh 987002 --yes-activate"
fields="$(agent 1 "printf '%s' '{\"surveyId\": 987002}' | ${S}/rc.sh --stdin get_fieldmap")"
col() { printf '%s' "${fields}" | docker exec -i "${agentc}" jq -r --arg t "$1" '.result | to_entries[] | select(.value.title == $t and .value.aid == "") | .key' | head -n 1; }
typed='Typed-By-A-Participant-618'
for data in "{\"$(col fullname)\":\"Ada Lovelace\",\"$(col rating)\":\"A1\",\"$(col comments)\":\"${typed}\"}" "{\"$(col fullname)\":\"Alan Turing\",\"$(col rating)\":\"A1\"}" "{\"$(col fullname)\":\"Grace Hopper\",\"$(col rating)\":\"A2\"}"; do
    printf '{"op":"add-response","sid":987002,"data":%s}' "${data}" | helper 1 > /dev/null
done
PLACEHOLDERS['<question id>']="$(col fullname | tr -dc '0-9')"
setup "${S}/temp-password.sh --create --email jane@example.test --full-name 'Jane Doe' jane"
setup "${S}/extensions.sh plugin-activate LssGoodPlugin && ${S}/extensions.sh theme-register lss_test_theme"
# The Customer Kit's SuiteCRM plugin. The stand-in app has none, so a stand-in for the plugin goes in: the parts
# of the real one that crm-link.sh leans on, with the real plugin's tables, and no SuiteCRM behind it
# (fixtures/SuiteCRMIntegration). The real image ships the real plugin, which needs a SuiteCRM to answer, so there
# the crm-link.sh commands are left to the Customer Kit's own test.
if app_root 1 'test -e /clouve/limesurvey/package/plugins/SuiteCRMIntegration' < /dev/null; then
    crm=real
else
    crm=standin
    docker cp -q "${fixtures}/SuiteCRMIntegration" "${app}:/var/www/html/plugins/"
    app_root 1 'chown -R www-data:www-data /var/www/html/plugins/SuiteCRMIntegration' < /dev/null
    setup "${S}/extensions.sh plugin-activate SuiteCRMIntegration"
    db_sql 1 "insert into lime_survey_crm_sync_log (response_id, survey_id, crm_module, crm_record_id, sync_status) values (1, 987002, 'Leads', 'abc', 'success'), (2, 987002, 'Leads', null, 'failed')"
fi
setup "${S}/survey-archive.sh export --survey 987002 --format lss && ${S}/survey-archive.sh export --survey 987002 --format lsa && cp ~/limesurvey-exports/survey-987002-*.lss /tmp/files/survey-987002.lss && cp ~/limesurvey-exports/survey-987002-*.lsa /tmp/files/survey-987002.lsa"
# Two backups: the one the commands name, and the one this test puts the site back to before each file.
setup "${S}/run-in-limesurvey.sh backup.sh"
named="$(agent 1 "${S}/run-in-limesurvey.sh backup.sh --list" | awk '{ print $1 }' | tail -n 1)"
sleep 1
setup "${S}/run-in-limesurvey.sh backup.sh"
reset_to="$(agent 1 "${S}/run-in-limesurvey.sh backup.sh --list" | awk '{ print $1 }' | tail -n 1)"
PLACEHOLDERS['<backup name>']="${named}"
setup "${S}/backup-copy.sh pull ${named} && tar -cf /tmp/files/backup-copy.tar -C ~/limesurvey-backups ${named}"
app_root 1 'rm -rf /root/fixture-backups && cp -a /var/www/html/clouve/backups /root/fixture-backups'
# What must not show up in what a command prints. Never printed here either.
secrets=("${ls_ops_pw}" "${ls_db_pw}" "${ls_db_root_pw}" "${ls_admin_pw}" 'Smtp-Pw-6gF1sD8kZq')
while IFS= read -r value; do secrets+=("${value}"); done < <(ls_security_values 1)
while IFS= read -r value; do [ -z "${value}" ] || secrets+=("${value}"); done < <(db_sql 1 "select session_token from lime_users where session_token is not null and session_token <> ''")
if [[ "${named}" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "${reset_to}" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [ "${named}" != "${reset_to}" ] && [ -n "${PLACEHOLDERS['<question id>']}" ] && [ "${#secrets[@]}" -ge 8 ]; then
    ok "the fixture is in place: survey 987002 with participants and answers, an account, a plugin, a theme, the SuiteCRM plugin (${crm}), and the backups ${named} and ${reset_to}"
else
    bad "the fixture is in place" "named=${named} reset_to=${reset_to} question=${PLACEHOLDERS['<question id>']}"
fi

# reset_fixture: the site, the image's state folder and the agent's own files, as they were when the fixture was made
reset_fixture() {
    app_root 1 "rm -rf /var/www/html/clouve/backups /var/www/html/clouve/upgrade-* /var/www/html/clouve/install-in-progress && cp -a /root/fixture-backups /var/www/html/clouve/backups && install -d -m 700 /var/www/html/clouve/upgrade-6.16.1-to-7.10.0 && echo phase=done > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/state && printf 'LssGoodPlugin\n' > /var/www/html/clouve/upgrade-6.16.1-to-7.10.0/active-plugins" < /dev/null || return 1
    agent 1 "${S}/run-in-limesurvey.sh restore.sh --backup ${reset_to} --yes-replace-current-data --skip-safety-backup" > "${work}/reset.out" 2>&1 || return 1
    agent 1 'rm -rf ~/limesurvey-backups ~/limesurvey-exports ~/limesurvey-passwords ~/survey-drafts && (umask 077 && mkdir ~/limesurvey-backups ~/limesurvey-passwords) && tar -xf /tmp/files/backup-copy.tar -C ~/limesurvey-backups && (umask 077 && echo placeholder > ~/limesurvey-passwords/jane-20260101-000000.txt)' || return 1
}

# ---------------------------------------------------------------------------
section "4. The commands, run"
# ---------------------------------------------------------------------------
# NOT_RUN: commands part 2 leaves out, as "pattern<TAB>reason". The pattern is an extended regular expression on
# the command as written.
NOT_RUN=''
if [ "${crm}" = real ]; then
    NOT_RUN="$(cat <<'LIST'
crm-link\.sh	this image ships Clouve's real SuiteCRM plugin, which needs a SuiteCRM to answer, and this stack has none: the Customer Kit's own test runs these against the real pair, and the stand-in run of this test runs them against a stand-in for the plugin
plugin-activate SuiteCRMIntegration	the same: without a SuiteCRM the real plugin is not switched on here
lime_survey_crm_sync_log	the same: the table is made when the real plugin is switched on
LIST
)"
fi
# EXPECTED: commands that are right to end with another exit code than 0 on this fixture, as
# "pattern<TAB>code<TAB>reason".
EXPECTED="$(cat <<'LIST'
survey-activate\.sh	2	the fixture's survey is active already, which the script says, and it changes nothing
--keys-only	2	the fixture's keys read its data, so the script says that they stay and changes nothing
backup-copy\.sh pull	1	the fixture already holds that backup in the Files pane, and a copy is never overwritten
backup-copy\.sh push	1	the container already holds that backup, and one is never overwritten
temp-password\.sh --create	2	the fixture's account jane exists, so making it again is refused
plugin-activate '?LssGoodPlugin	0	the plugin is on already, which the script reports and leaves
index\.php/987002"$	0	curl prints the status and ends with 0 whatever the status is
LIST
)"
# BEFORE: what the test does to the site just before a command, as "pattern<TAB>what<TAB>SQL". A reminder is due
# only days after the invitation, so the invitations the playbook has just sent are dated eight days back.
BEFORE="$(cat <<'LIST'
invitations\.sh remind	the invitations are dated eight days back, so that the four people are due a reminder	update lime_tokens_987002 set sent = date_format(utc_timestamp() - interval 8 day, '%Y-%m-%d %H:%i') where sent not in ('N', '')
LIST
)"
# CHECK: what has to be true after a command, as "pattern<TAB>what<TAB>a command in the app container, as
# root<TAB>what it has to print".
CHECK="$(cat <<'LIST'
invitations\.sh remind .* --send --expect	the mail sink has the four invitations and the four reminders	SINK	8
sed -i -E	config.php has debug at 0 again	grep -c "'debug'=>0" /var/www/html/application/config/config.php	1
checkintegrity --yes	LimeSurvey is still out of maintenance mode	true	
LIST
)"
# MAY_PRINT: commands that show something on purpose that no other command may print, as
# "pattern<TAB>what<TAB>reason".
MAY_PRINT="$(cat <<'LIST'
rc\.sh --show-codes	codes	the admin asked for one person's link, and this is the one command that reads an access code
responses\.sh summary .* --with-text	typed	the admin asked what people wrote
LIST
)"

subst() { # COMMAND: the command with each placeholder replaced by the fixture's value
    local cmd="$1" key
    for key in "${!PLACEHOLDERS[@]}"; do
        cmd="${cmd//"${key}"/"${PLACEHOLDERS[${key}]}"}"
    done
    printf '%s' "${cmd}"
}
not_understood='command not found|No such file or directory|syntax error|unknown option|unknown action|unknown method|has no parameter named|needs the parameter|parameters, got|is not one of the scripts|Usage: |"error":"rc\.sh does not run|does not run without the admin|is not a setting rc\.sh shows|refused: '
ran=0
skipped=0
current=''
: > "${work}/not-run"
# The list is read on descriptor 3: the commands and the fixture steps must not get it as their stdin.
while IFS=$'\t' read -r -u 3 _ file line cmd; do
    reason="$(awk -F'\t' -v c="${cmd}" 'c ~ $1 { print $2; exit }' <<< "${NOT_RUN}")"
    if [ -n "${reason}" ]; then
        skipped=$((skipped + 1))
        printf '%s:%s  %s\n      not run: %s\n' "${file}" "${line}" "${cmd}" "${reason}" >> "${work}/not-run"
        continue
    fi
    if [ "${file}" != "${current}" ]; then
        current="${file}"
        if ! reset_fixture; then
            bad "${file}: the fixture could be put back before its commands" "$(cat "${work}/reset.out" 2> /dev/null)"
            continue
        fi
    fi
    if [ "${file}" = playbooks/diagnose-problems.md ] && [ "${debug_set:-}" != "${file}" ]; then
        # The playbook has the command that sets debug back to 0. It finds debug at 2.
        debug_set="${file}"
        docker exec -u www-data "${app}" sed -i -E "s/^([[:space:]]*'debug'[[:space:]]*=>[[:space:]]*)[0-9]+/\12/" /var/www/html/application/config/config.php < /dev/null
    fi
    while IFS=$'\t' read -r pattern what sql; do
        [ -n "${pattern}" ] || continue
        if [[ "${cmd}" =~ ${pattern} ]]; then db_sql 1 "${sql}" < /dev/null || bad "${file}:${line}: before the command, ${what}"; fi
    done <<< "${BEFORE}"
    real="$(subst "${cmd}")"
    out="$(timeout 300 docker exec -u assistant "${agentc}" bash -lc "${real}" < /dev/null 2>&1)"
    rc=$?
    ran=$((ran + 1))
    want=0
    why=''
    while IFS=$'\t' read -r pattern code text; do
        [ -n "${pattern}" ] || continue
        if [[ "${cmd}" =~ ${pattern} ]]; then want="${code}"; why="${text}"; break; fi
    done <<< "${EXPECTED}"
    label="${file}:${line}  ${cmd:0:150}"
    # What the command printed, searched for what must stay out of the chat.
    may=''
    while IFS=$'\t' read -r pattern kind text; do
        [ -n "${pattern}" ] || continue
        if [[ "${cmd}" =~ ${pattern} ]]; then may+=" ${kind}"; fi
    done <<< "${MAY_PRINT}"
    leaked=''
    for value in "${secrets[@]}"; do
        if [ -n "${value}" ] && [[ "${out}" == *"${value}"* ]]; then leaked="a password, a value of security.php or a session token"; fi
    done
    if [[ "${may}" != *codes* ]]; then
        while IFS= read -r value; do
            if [ -n "${value}" ] && [[ "${out}" == *"${value}"* ]]; then leaked="${leaked:+${leaked}, and }a participant's access code"; break; fi
        done < <(db_sql 1 "select token from lime_tokens_987002" 2> /dev/null < /dev/null)
    fi
    if [[ "${may}" != *typed* ]] && [[ "${out}" == *"${typed}"* ]]; then leaked="${leaked:+${leaked}, and }what a participant typed"; fi
    checked=''
    while IFS=$'\t' read -r pattern what check wanted; do
        [ -n "${pattern}" ] || continue
        if [[ "${cmd}" =~ ${pattern} ]]; then
            if [ "${check}" = SINK ]; then got="$(sink_count)"; elif [ "${check}" = true ]; then got="$(db_sql 1 "select coalesce((select stg_value from lime_settings_global where stg_name = 'maintenancemode'), 'off')" < /dev/null)"; wanted=off; else got="$(app_root 1 "${check}" < /dev/null 2>&1)"; fi
            if [ "${got}" != "${wanted}" ]; then checked="${what} (wanted ${wanted}, got ${got})"; fi
        fi
    done <<< "${CHECK}"
    if [ "${rc}" -ne "${want}" ]; then
        bad "${label} (exit ${rc}, wanted ${want})" "${out}"
    elif grep -qE "${not_understood}" <<< "${out}"; then
        bad "${label} (exit ${rc}, but its output says it was not understood)" "${out}"
    elif [ -n "${leaked}" ]; then
        bad "${label} (exit ${rc}, but it printed ${leaked})"
    elif [ -n "${checked}" ]; then
        bad "${label} (exit ${rc}, but afterwards it is not so that ${checked})" "${out}"
    elif [ "${want}" -ne 0 ]; then
        ok "${label}  [exit ${rc}: ${why}]"
    else
        ok "${label}"
    fi
done 3< "${work}/commands.tsv"

section "5. What was run"
if [ "$((ran + skipped))" -eq "${total}" ]; then ok "every one of the ${total} commands was run (${ran}) or is listed as not run (${skipped})"; else bad "every command was run or listed: ${ran} run, ${skipped} not run, ${total} in the Markdown"; fi
if [ "${crm}" = standin ]; then
    crm_ran="$(grep -c 'crm-link\.sh' "${work}/commands.tsv" || true)"
    if [ "${crm_ran}" -ge 8 ] && [ "${skipped}" -eq 0 ]; then ok "the ${crm_ran} crm-link.sh commands ran too, against the stand-in for the SuiteCRM plugin, and nothing was left out"; else bad "the crm-link.sh commands ran against the stand-in for the SuiteCRM plugin (${crm_ran} commands, ${skipped} not run)"; fi
fi
if [ "${skipped}" -gt 0 ]; then
    echo
    echo "Not run, and why:"
    sed 's/^/  /' "${work}/not-run"
fi

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
