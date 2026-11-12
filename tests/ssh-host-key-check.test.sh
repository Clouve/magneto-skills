#!/usr/bin/env bash
# Every plugin's ssh and scp commands keep and check no saved host key, and the checker that says so reads commands,
# not prose (release 4.5.5, M7).
#
# tests/lib/ssh-host-key-check.py puts each ssh or scp command to clouve-ops@ through the real `ssh -G -F /dev/null`
# and wants `StrictHostKeyChecking=accept-new` and `UserKnownHostsFile=/dev/null`. gibbon's, odoo's, moodle's and
# wordpress's channel-text tests run it for their plugin. This test runs it for every plugin, so a new one or one
# without such a test (ai-studio, nextcloud) can't fall behind, and checks the checker itself on made-up plugins:
#   - a command without the options fails, and one with them on its line passes;
#   - an error message quoted in prose ("ssh to clouve-ops@<host> failed") is not a command: an ordinary word between
#     ssh and clouve-ops@ means prose, but only outside code (Markdown outside a fenced block, a script's comment
#     lines), and the value after an option (`-o LogLevel ERROR`, `-p 22`) or scp's source is no ordinary word;
#   - an array of options counts only when the same file fills it with `mapfile -t NAME < <(FUNC)` and FUNC is defined
#     in the plugin's own scripts/lib/*.sh, as nextcloud's lib/nextcloud-ssh.sh does. The checker runs FUNC and puts
#     what it prints through ssh -G. Any other array, and a FUNC that prints too little, still fails.
#
# Needs ssh and bash; connects to nothing.
#
# Run: bash tests/ssh-host-key-check.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECK="$ROOT/tests/lib/ssh-host-key-check.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/ssh-host-key-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }

if ! command -v ssh > /dev/null 2>&1; then
  fail "ssh is installed, to check each command's options with ssh -G"
  exit 1
fi

echo "Every plugin"
for dir in "$ROOT"/plugins/*/; do
  plugin="$(basename "$dir")"
  out="$(python3 -I "$CHECK" "$ROOT" "$plugin")"
  ok="$(grep -c '^ok ' <<< "$out" || true)"
  bad="$(grep '^bad ' <<< "$out" || true)"
  if [ -z "$bad" ]; then
    pass "$plugin: every ssh and scp command keeps no host key ($ok checked)"
  else
    fail "$plugin: every ssh and scp command keeps no host key ($(grep -c '' <<< "$bad") fail)"
    printf '%s\n' "$bad" | sed 's/^bad /       /' | head -10 | cut -c1-200
  fi
done

echo
echo "The checker, on made-up plugins"
# case NAME FILE CONTENT [LIB]: a plugin "t-NAME" whose only file is FILE (under skills/t-NAME/) with CONTENT, and
# with LIB, scripts/lib/opts.sh holding LIB. Prints the checker's output.
case_run() {
  local name="$1" file="$2" content="$3" lib="${4:-}" base="$work/$1"
  mkdir -p "$base/plugins/t-$name/skills/t-$name/$(dirname "$file")"
  printf '%s\n' "$content" > "$base/plugins/t-$name/skills/t-$name/$file"
  if [ -n "$lib" ]; then
    mkdir -p "$base/plugins/t-$name/skills/t-$name/scripts/lib"
    printf '%s\n' "$lib" > "$base/plugins/t-$name/skills/t-$name/scripts/lib/opts.sh"
  fi
  python3 -I "$CHECK" "$base" "t-$name"
}
expect() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then pass "$label"; else fail "$label"; printf '       want: %s\n       got:  %s\n' "$want" "${got//$'\n'/ | }"; fi
}
opts='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null'
lib_ok="opts() { printf '%s\\n' -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10; }"
lib_short="opts() { printf '%s\\n' -o StrictHostKeyChecking=accept-new; }"

out="$(case_run bare a.md 'sshpass -e ssh clouve-ops@${HOST}')"
expect "a command without the options fails" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run inline a.md "SSHPASS=x sshpass -e ssh $opts clouve-ops@\${HOST} true")"
expect "a command with both options on its line passes" "ok" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run port a.md 'sshpass -e ssh -p 22 clouve-ops@${HOST} true')"
expect "a port between ssh and the target doesn't make a command prose" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run prose a.md '| Exit 255 and `ssh to clouve-ops@<host> failed` (run.sh), or ssh could not reach clouve-ops@<host> |')"
expect "an error message quoted in prose isn't a command" "" "$out"
# Prose is an ordinary word between ssh and the target, outside code only: in Markdown outside a fenced block, in a
# script on a comment line. The value after `-o NAME` or `-p` is no ordinary word, and scp's source never is.
out="$(case_run spaced a.md 'Run `sshpass -e ssh -o LogLevel ERROR clouve-ops@${HOST} true` to check.')"
expect "a spaced option value (-o LogLevel ERROR) doesn't make a command prose" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run fenced a.md '```bash
sshpass -e ssh to clouve-ops@${HOST} true
```')"
expect "inside a fenced code block, an ordinary word doesn't make a command prose" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run scpword a.md 'Copy it with `scp backup clouve-ops@${HOST}:/tmp/`.')"
expect "scp's source file name is no prose" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run shcode scripts/a.sh 'msg "ssh to clouve-ops@${h} failed"')"
expect "a script line that isn't a comment is never prose" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run shcomment scripts/a.sh '#   255  ssh could not reach or log in to clouve-ops@<host>; stderr says so')"
expect "a script comment can be prose" "" "$out"
out="$(case_run mapfile scripts/a.sh 'mapfile -t ssh_opts < <(opts)
ssh -n "${ssh_opts[@]}" "clouve-ops@$1" true' "$lib_ok")"
expect "an array filled from a function in the plugin's scripts/lib counts, through ssh -G" "ok" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run mapshort scripts/a.sh 'mapfile -t ssh_opts < <(opts)
ssh -n "${ssh_opts[@]}" "clouve-ops@$1" true' "$lib_short")"
expect "  and fails when the function leaves an option out" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run nolib scripts/a.sh 'mapfile -t ssh_opts < <(opts)
ssh -n "${ssh_opts[@]}" "clouve-ops@$1" true')"
expect "  and fails when the function isn't in the plugin's scripts/lib" "bad" "$(cut -d' ' -f1 <<< "$out")"
out="$(case_run array scripts/a.sh "ssh_opts=($opts)
ssh -n \"\${ssh_opts[@]}\" \"clouve-ops@\$1\" true")"
expect "an array set any other way doesn't count" "bad" "$(cut -d' ' -f1 <<< "$out")"

echo
if [ "$FAILED" -eq 0 ]; then echo "All ssh host-key checker checks passed."; else exit 1; fi
