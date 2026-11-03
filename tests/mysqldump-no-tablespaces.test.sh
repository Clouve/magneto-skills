#!/usr/bin/env bash
# Every mysqldump the gibbon, moodle and wordpress skills give passes --no-tablespaces,
# and no mysql client command in them puts a password on its command line (#64, release
# 4.5.3, 2026-11-02, widened by the 4.5.3 reviews).
#
# The agent's mysqldump is Oracle MySQL 8.0 (Ubuntu 24.04's default-mysql-client).
# Unless it gets --no-tablespaces, it asks the server for tablespace information,
# which needs the PROCESS privilege, and neither app's database user has it: each
# dump printed "Access denied; you need (at least one of) the PROCESS privilege(s)
# for this operation". Neither app creates general tablespaces, so the flag costs
# the dump nothing. WordPress's own scripts/backup.sh already passed the flag; it is
# checked here too.
#
# A password given as -p"..." or --password=... sits in the process list, where ps
# shows it to anyone on the agent, for as long as the command runs (a whole restore,
# for one moodle command). Every mysql, mysqladmin and mysqldump command gets it in
# MYSQL_PWD instead.
#
# Checks every such command in the three skills: in the markdown's fenced code blocks
# and in the scripts (comment lines skipped, scripts/tests/ skipped), with
# backslash-continued lines joined. A command in backticks on a prose line counts for
# the password rule. A command is a line where the client's name is
# followed by an option. tests/moodle-backup-script.test.sh and gibbon's
# scripts/tests/mysql-tls.test.sh run the two backup scripts against a fake mysqldump.
#
# Run: bash tests/mysqldump-no-tablespaces.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

# commands FILE KIND: prints "LINE<TAB>WHERE<TAB>COMMAND" for each logical command line in FILE.
# KIND md: fenced code blocks (WHERE code), and each `span` on a prose line (WHERE prose, which
# only the password rule reads: a prose mention like `mysqldump --host=...` isn't a whole
# command). KIND sh: every line but comments (WHERE code).
commands() {
  awk -v kind="$2" '
    /^[[:space:]]*```/ { if (kind == "md") { fence = !fence; next } }
    {
      if (kind == "md" && !fence) {
        rest = $0
        while (match(rest, /`[^`]+`/)) {
          print NR "\tprose\t" substr(rest, RSTART + 1, RLENGTH - 2)
          rest = substr(rest, RSTART + RLENGTH)
        }
        next
      }
      if (kind == "sh" && $0 ~ /^[[:space:]]*#/) next
      line = $0
      if (buf == "") start = NR
      if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
      print start "\tcode\t" buf line
      buf = ""
    }
  ' "$1"
}

mapfile -t files < <(
  find "$ROOT/plugins/gibbon/skills" "$ROOT/plugins/moodle/skills" "$ROOT/plugins/wordpress/skills" \
    -type f \( -name '*.md' -o -name '*.sh' \) \
    -not -path '*/scripts/tests/*' | sort
)

seen=0
wp_seen=0
clients=0
no_flag=""
on_argv=""
for f in "${files[@]}"; do
  kind=md
  [[ "$f" == *.sh ]] && kind=sh
  while IFS=$'\t' read -r n where cmd; do
    [[ "$cmd" =~ (^|[[:space:]\;\|\&\(])(mysql|mysqladmin|mysqldump)[[:space:]]+- ]] || continue
    clients=$((clients + 1))
    if [[ "$cmd" =~ [[:space:]]-p[\"\'\$[:alnum:]] || "$cmd" == *--password* ]]; then
      on_argv+="${f#"$ROOT"/}:$n"$'\n'
    fi
    [ "$where" = code ] || continue
    [[ "$cmd" =~ (^|[[:space:]\;\|\&\(])mysqldump[[:space:]]+- ]] || continue
    seen=$((seen + 1))
    if [[ "$f" == "$ROOT/plugins/wordpress/"* ]]; then wp_seen=$((wp_seen + 1)); fi
    [[ "$cmd" =~ (^|[[:space:]])--no-tablespaces([[:space:]]|$) ]] || no_flag+="${f#"$ROOT"/}:$n"$'\n'
  done < <(commands "$f" "$kind")
done

# The scan has to see wordpress's own dumps, not only its files (re-review N4).
if [ "$seen" -lt 10 ] || [ "$wp_seen" -eq 0 ]; then
  fail "every gibbon, moodle and wordpress mysqldump passes --no-tablespaces (found $seen mysqldump commands, $wp_seen of them in wordpress, so the scan is broken)"
elif [ -z "$no_flag" ]; then
  pass "every gibbon, moodle and wordpress mysqldump passes --no-tablespaces ($seen commands)"
else
  fail "every gibbon, moodle and wordpress mysqldump passes --no-tablespaces"
  printf '%s' "$no_flag" | sed 's/^/       /'
fi

if [ "$clients" -gt "$seen" ] && [ -z "$on_argv" ]; then
  pass "no mysql, mysqladmin or mysqldump command puts the password on its command line ($clients commands)"
else
  fail "no mysql, mysqladmin or mysqldump command puts the password on its command line"
  printf '%s' "$on_argv" | sed 's/^/       /'
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All mysqldump flag checks passed."; else exit 1; fi
