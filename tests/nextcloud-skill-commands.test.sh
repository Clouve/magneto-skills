#!/bin/bash
# ============================================================================
# Nextcloud skill: the commands its files contain
# ============================================================================
# A static test of plugins/nextcloud. It reads the plugin's files and nothing else: no Docker, no
# network, no Nextcloud. It runs from any working folder and writes only inside its own mktemp -d
# folder, which a trap removes.
#
# The corpus
#   - the fenced code blocks of every .md file (``` and ~~~ fences, indented or in a blockquote, any language);
#   - every non-comment line of every .sh file, heredoc bodies and usage text included.
#   A trailing # comment is not part of a line. In shell (a .sh file, or a fence tagged bash, sh, shell,
#   console, zsh, ksh, dash, shellscript or shell-session, or with no tag) a command continued with a
#   trailing backslash is one line. So is a command whose quote is still open at the end of a line (an -e
#   string with the SQL on the lines after it) or that ends in | && || (the next line goes on with it), up to
#   60 lines. A quote that does not close within that, or before the block ends, leaves its first line to be
#   read alone. A line that opens a heredoc is always read alone; its body is one line per line. Every hit is
#   reported as file:line, the line it is on, not the line its command starts on.
#   A fence with any other tag (text, json, yaml, php, diff, sql ...) is not shell: each of its lines is read
#   alone, so an apostrophe in a tree diagram chains nothing, and every line is still checked. Rule 7 still
#   reads a sql fence. Tag a diagram or a block of prose text. A line that starts and ends with | is a row of
#   a table: a quote or a trailing | never joins it to the line before it or after it. (A pipe at the front of
#   a continuation line, as in a long jq program, does not make a row.) A trailing backslash still continues
#   a line onto one that starts with |.
#   Not read, so a command there is not checked: inline code and tables in prose, and indented code with no
#   fence. Rule 12 is the one exception: it also reads the inline code of prose, tables included.
#
# Rules on the corpus (Markdown that passes uses these forms)
#   1. The occ form. Call occ as /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh
#      (in Markdown by that absolute path; in a script as "${script_dir}/occ.sh"), or as
#      sudo [-n|-E|--preserve-env=NC_PASS] -u www-data [flock /var/www/html/nextcloud-init-sync.lock]
#      php /var/www/html/occ, or through a script's "${NC_OCC[@]}" or "${occ[@]}". Fails: php occ, ./occ,
#      a bare occ, sudo php, php /var/www/html/occ without that sudo, a docker, podman or kubectl command
#      (the agent has none), and in Markdown an occ.sh that is not written by its absolute path.
#   2. Secret reads. Fails: config:list ... --private; config:system:get of dbpassword, secret,
#      passwordsalt, mail_smtppassword (or proxyuserpwd), or of redis followed by password;
#      config:app:get of a key containing password, secret, token or private.
#   3. Unscoped cleanups. versions:cleanup and trashbin:cleanup need a user. versions:cleanup also takes
#      --path=/<uid>/files/..., but the path has to be there (a value starting with /, a <placeholder> or a
#      $variable): an empty --path is every user. --all-users fails.
#   4. Passwords on a command line. Fails: --value on a config key containing pass, secret or pwd;
#      user:resetpassword without --password-from-env; user:add without --password-from-env or
#      --generate-password; mysql, mariadb or another MySQL or MariaDB client (mariadb-dump, mysqladmin ...)
#      with -p<password>, --password= or an abbreviation of it (--pass=); sshpass -p; curl -u or -U
#      user:password (alone or bundled: -su, -sSu); a URL with user:password@ in it. A curl login goes in the
#      -K - config on stdin.
#   5. Prompts that -n declines. groupfolders:delete, files:delete and sharing:delete-orphan-shares need
#      --force or -f: they ask [y/N], and under -n occ takes no and still exits 0.
#   6. Never run: encryption:enable, encrypt-all, enable-master-key, disable-master-key, decrypt-all;
#      maintenance:install; the experimental sharing:* share store (create-share, delete-share,
#      get-share, get-shares, add-share-*, remove-share-*, update-share-*, select-share-permission-preset).
#      The files_sharing repair commands (sharing:fix-share-owners, and sharing:delete-orphan-shares with
#      --force ...) stay.
#   7. No SQL writes. SQL handed to mysql or mariadb (the -e or --execute value, a heredoc, a here-string,
#      or text piped in) and the body of a sql fence may not start a statement with INSERT, UPDATE, DELETE,
#      ALTER, DROP, TRUNCATE, CREATE, REPLACE (the brief's eight), RENAME, LOAD DATA, LOAD XML, GRANT,
#      REVOKE, CALL, OPTIMIZE, REPAIR, SET GLOBAL or SET PERSIST, and INTO OUTFILE and INTO DUMPFILE fail
#      wherever they stand. A statement starts at the start of the SQL or after a ;. scripts/restore.sh is
#      exempt.
#   8. No feeding redacted config back. config:list and config:import in one command line, or
#      config:import of a file that config:list wrote earlier in the same block or script.
#   9. Quotas. A line that sets a quota writes the size as "5 GB": the number, one space, GB or MB. GiB
#      and MiB, or no space, fail; %20 and + in a URL read as the space they stand for. Prose outside a
#      code block may explain the GiB trap.
#
# Rules on every line of every file (prose, comments and JSON too)
#  10. $SKILL_DIR and ${SKILL_DIR} fail: the agent does not define them.
#  11. Every /clouve/skills/nextcloud/plugin/<path> named has to exist as plugins/nextcloud/<path>.
#
# Rule on the commands of Markdown, in shell fences and in inline code
#  12. Values in single quotes. A <placeholder> inside double quotes fails. The agent's bash expands $( ), backticks
#      and $ inside double quotes before occ.sh or ssh quotes anything, so a value put in the placeholder's place
#      there would run on the agent. A placeholder inside single quotes passes, and so does one inside double quotes
#      within single quotes (a jq program), which that bash does not expand. $( ) and backticks are read as command
#      lines of their own, inside double quotes too. Inline code counts as a command when its first word, after any
#      VAR=value, is an occ command name (files:scan), occ with one, a path or a name ending in .sh, an option (a
#      fragment such as -N -e "..."), or a tool the skill runs (sudo, ssh, mysql, curl, jq, find and the others in
#      INLINE_TOOLS). Other inline code is a name, a value, or what a command prints, such as
#      `The account "<uid>" already exists.`, and is not checked.
#
# How a command is read
#   A small lexer splits each line into commands and words: quotes, $(...), `...`, pipes, ; && ||, and
#   redirects are understood. Text inside quotes is read again as a command line, so a command given to ssh
#   or bash -c is seen, and so is an occ.sh named in a script's message. In that text, and inside $( ) and
#   backticks, a newline ends a command as a ; does (after | && || the command goes on), so a quoted script
#   of several lines is several commands: a flag on one line is no flag of the command above it, a docker on
#   the second line is a docker run, and each hit lands on the line of its own word.
#   Rules 2 to 6 and 8 look at an occ call: a command name that comes after an occ launcher in the same
#   command (occ.sh, php .../occ, ${NC_OCC[@]}, $OCC, ${occ[@]}, occ_run ...), or, in Markdown, a command
#   name that starts a line, because the assistant would run it. occ.sh's own options (--password-stdin,
#   --init-lock, --) sit between the launcher and the command name and are skipped. A command name in a
#   script's message ("user:add makes the account") is not a call. Rules 3 to 6 also leave out a request for
#   help (--help, -h, or help before the name): it runs nothing. <uid> and <user id> are placeholders, not
#   redirects.
#   docker, podman and kubectl, and a bare occ in Markdown, count when they are the command a line runs:
#   first in it, or behind sudo, exec, env, timeout, xargs, ssh <host> and the like. `which docker`,
#   `grep -q docker /proc/1/cgroup` and a string given to echo or a message function, even one that starts
#   with the word, are not runs; a string given to ssh, bash -c, sudo or eval is.
#
# Where a rule is narrower or wider than its one-line wording, and why
#   - Rule 1 asks for occ.sh by its absolute path in Markdown only. In scripts the call form is
#     "${script_dir}/occ.sh", and a bare occ.sh in a message or in occ.sh's usage text is text for the reader.
#   - Rule 1 exempts one line, by file and exact text: skills/nextcloud/scripts/occ.sh builds its remote
#     command in pieces, and the sudo -n -u www-data part and the optional flock are on earlier lines, so
#     the line that adds " php /var/www/html/occ ..." reads as a bare php occ. The same text anywhere else
#     still fires (the self-check proves it).
#   - Rule 1 lets php take its own options (php -d memory_limit=512M /var/www/html/occ): they change
#     neither who runs occ nor where it is.
#   - Rule 3 counts versions:cleanup --path (or -p) as a scope: 35.0.2 takes the user from the path
#     (apps/files_versions/lib/Command/CleanUp.php), and the spec's gate says "named users or paths". An
#     empty --path is not one: the same file treats it as every user.
#   - Rules 2 and 4 skip keys that have password or token in the name and hold a flag, a number, a list of
#     groups or a URL, the settings the sharing and hardening playbooks read and set: the password_policy
#     app (enforceNonCommonPassword ...), core's shareapi_* keys (shareapi_enforce_links_password,
#     shareapi_token_length ...), the system keys sharing.* and auth.storeCryptedPassword, and
#     lost_password_link. A secret next to them still fires (shareapi_* of another app, api_token, my_secret).
#   - Rule 2 matches config:app:get keys without regard to case (clientSecret, privateKey).
#   - Rule 4's -p<something> counts only as an argument of a MySQL or MariaDB client (mkdir -p and tar -p do
#     not count, -P is the port, and a lone -p asks for the password), and sshpass's own options only (the -p
#     of the ssh it runs is a port).
#   - Rule 7 reads SQL statement by statement, by the first word of each, so SHOW CREATE TABLE, SHOW GRANTS,
#     EXPLAIN SELECT ..., SELECT TRUNCATE(...), SELECT REPLACE(...) and a quoted 'delete' (all reads) pass,
#     and an HTTP method (curl -X DELETE) is not SQL. The brief's eight verbs are a floor.
#   - Rule 7 sees SQL in an -e string, a here-string and a pipe (also inside a quoted script), and in a
#     heredoc that follows a command line. It does not see a heredoc that sits inside a quoted string or
#     inside the body of another heredoc (ssh host "mysql db <<'SQL' ... SQL", or a mysql heredoc in the body
#     of bash <<'EOF'): every other rule reads those lines, rule 7 does not yet.
#   - Lines are joined in shell only, so an -e string that runs over lines in a fence tagged text, yaml or the
#     like is read a line at a time and its SQL is not seen. Tag a command bash.
#   - Rule 9 also fails a size with no space ("5GB"), because the skill writes quotas one way.
#   - Wider than the wording: proxyuserpwd, the other MySQL and MariaDB clients (mysqldump, mysqladmin ...),
#     curl -u and -U, passwords in URLs, any docker or podman command, fences tagged sql, here-strings and
#     pipes into mysql, and a bare occ behind ssh.
#   - Rule 12 reads Markdown only: a script's message may name a placeholder for its reader. It reads shell fences,
#     so a placeholder in double quotes in a text fence (what a command prints) passes. It skips <uninstall>, a
#     literal tag that a sed address in a playbook matches. It does not follow a value into a remote command: the
#     container's shell reads a single-quoted ssh command, so that quoting is the playbook's job (the playbooks
#     check a value against a pattern first, or quote it with printf %q). Inline code that runs over two lines,
#     and a heredoc body read as a command line, are its known gaps.
#
# The self-check
#   Before it reads the plugin, the test builds a fixture plugin in its temp folder: one Markdown file and
#   some scripts holding bad lines (each tagged with the rules that have to report it, and no others) and
#   good lines (which no rule may report), then runs every rule on it. A rule that stops firing, or starts
#   firing on a good line, fails here first, and a test that cannot fail cannot be trusted.
#
# How to add a rule
#   1. Add its entry to RULES in the checker below: the number, a short title, and the hint authors see
#      when it fires (what to write instead).
#   2. Write rN(u). It takes a unit (one command line, with .text, .cmds and .origin) and returns
#      [(offset in u.text, detail)]. Give the offset of the word that offends (word.pos), not of its
#      command: scan() turns it into the physical line, so a hit in the fifth line of a quoted script is
#      reported on the fifth line. occ_calls(u, real=True) gives the occ commands with help requests left out.
#   3. List it in UNIT_RULES. Three kinds are wired elsewhere: rule 7 (SQL) in scan(), because it also reads
#      heredoc bodies and sql fences; rules 10 and 11 (every line of every file) in raw_rules(); and rule 12's
#      reading of inline code in inline_rules(), which scan() calls for each Markdown file (its fence half, r12, is
#      in UNIT_RULES).
#   4. Add its bad lines (bad_line N ...) and its good lines (ok_line ...) to the fixture above. The
#      self-check fails with "the fixture has no entry for it" while a rule has none.
#   5. Describe it in this header.
#
# Usage: bash tests/nextcloud-skill-commands.test.sh   (exit 0 = all pass)
# ============================================================================

# SC2016: the fixture lines are literal text, with $ and ${...} in single quotes on purpose.
# shellcheck disable=SC2016

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin="$(cd "${here}/.." && pwd)/plugins/nextcloud"
work="$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-skill-commands-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

command -v python3 > /dev/null || { echo "nextcloud-skill-commands: this test needs python3 on PATH" >&2; exit 1; }
[ -d "${plugin}" ] || { echo "nextcloud-skill-commands: ${plugin} is missing" >&2; exit 1; }

pass=0
fail=0
bad() {
  fail=$((fail + 1))
  printf '  FAIL %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/       | /'; fi
}
section() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. The fixture
# ---------------------------------------------------------------------------
# The fixture is a small plugin built in the temp folder: one Markdown file and some scripts, laid out like
# the real plugin. Each call below adds one entry and records, in a manifest, which lines it occupies and
# which rules have to report it:
#
#   bad_line RULES TEXT      a line in a fenced block of the Markdown file. RULES is the rule numbers that
#                            must report it and no others ("1" or "2,8"). TEXT may hold several lines.
#   ok_line TEXT             a line no rule may report
#   bad_block RULES / ok_block    the same, with the text read from stdin (a heredoc)
#   bad_fence MODE RULES TEXT / ok_fence MODE TEXT    the same in another kind of fence: fence:LANG,
#                            tilde:LANG, indent:LANG (a fence inside a list item) or quote:LANG (in a blockquote)
#   bad_prose RULES TEXT / ok_prose TEXT   a line of prose, outside any fence
#   bad_script RULES FILE TEXT / ok_script FILE TEXT   a line of scripts/FILE (and *_script_block, from stdin)
#
# @OCC@ in a text stands for the absolute path of occ.sh. The checker reports "scaffolding" when a rule fires
# on a line that belongs to no entry, so a stray hit cannot hide.
fx_plugin="${work}/fixture/plugins/nextcloud"
fx_manifest="${work}/manifest.tsv"
: > "${fx_manifest}"
declare -A fx_lines=()

occ_path=/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh
fx_md=skills/nextcloud/reference/selfcheck.md
fx_scripts=skills/nextcloud/scripts

# fx_add MODE FILE RULES TEXT
fx_add() {
  local mode="$1" file="$2" rules="$3" text="$4"
  local path="${fx_plugin}/${file}" at="${fx_lines[${file}]:-0}"
  local open='' close='' pad='' out='' line first last label
  local -a body
  mkdir -p "$(dirname "${path}")"
  mapfile -t body <<< "${text}"
  case "${mode}" in
    fence:*) open='```'"${mode#fence:}"; close='```' ;;
    tilde:*) open='~~~'"${mode#tilde:}"; close='~~~' ;;
    indent:*) pad='    '; open="${pad}"'```'"${mode#indent:}"; close="${pad}"'```' ;;
    quote:*) pad='> '; open="${pad}"'```'"${mode#quote:}"; close="${pad}"'```' ;;
    prose | script | raw | filler) ;;
    *) echo "fx_add: unknown mode ${mode}" >&2; exit 1 ;;
  esac
  if [ -n "${open}" ]; then out+="${open}"$'\n'; first=$((at + 2)); else first=$((at + 1)); fi
  for line in "${body[@]}"; do out+="${pad}${line}"$'\n'; done
  last=$((first + ${#body[@]} - 1))
  if [ -n "${close}" ]; then out+="${close}"$'\n'; fi
  if [ "${mode}" != raw ] && [ "${mode}" != filler ]; then out+=$'\n'; fi
  printf '%s' "${out}" >> "${path}"
  fx_lines[${file}]=$((at + $(printf '%s' "${out}" | wc -l)))
  label="${body[0]//$'\t'/ }"
  if [ "${mode}" != filler ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "${file}" "${first}" "${last}" "${rules}" "${label:0:100}" >> "${fx_manifest}"
  fi
}

sub() { printf '%s' "${1//@OCC@/${occ_path}}"; }
bad_line() { fx_add fence:bash "${fx_md}" "$1" "$(sub "$2")"; }
ok_line() { fx_add fence:bash "${fx_md}" - "$(sub "$1")"; }
bad_block() { fx_add fence:bash "${fx_md}" "$1" "$(sub "$(cat)")"; }
ok_block() { fx_add fence:bash "${fx_md}" - "$(sub "$(cat)")"; }
bad_fence() { fx_add "$1" "${fx_md}" "$2" "$(sub "$3")"; }
ok_fence() { fx_add "$1" "${fx_md}" - "$(sub "$2")"; }
bad_prose() { fx_add prose "${fx_md}" "$1" "$2"; }
ok_prose() { fx_add prose "${fx_md}" - "$1"; }
bad_script() { fx_add script "${fx_scripts}/$2" "$1" "$(sub "$3")"; }
ok_script() { fx_add script "${fx_scripts}/$1" - "$(sub "$2")"; }
bad_script_block() { fx_add script "${fx_scripts}/$2" "$1" "$(sub "$(cat)")"; }
ok_script_block() { fx_add script "${fx_scripts}/$1" - "$(sub "$(cat)")"; }
# block_open [LANG] ... block_close: one fence (bash unless LANG is given; '' is untagged) that several entries
# share, for checks that need lines next to each other. block_bad and block_ok add an entry inside it;
# block_filler adds lines that belong to no entry.
block_open() { printf '%s\n' '```'"${1-bash}" >> "${fx_plugin}/${fx_md}"; fx_lines[${fx_md}]=$(( ${fx_lines[${fx_md}]:-0} + 1 )); }
block_close() { printf '%s\n\n' '```' >> "${fx_plugin}/${fx_md}"; fx_lines[${fx_md}]=$(( ${fx_lines[${fx_md}]:-0} + 2 )); }
block_bad() { fx_add raw "${fx_md}" "$1" "$(sub "$2")"; }
block_ok() { fx_add raw "${fx_md}" - "$(sub "$1")"; }
block_filler() { fx_add filler "${fx_md}" - "$1"; }

# ---- rule 1: the occ form
bad_line 1 'php occ status'
bad_line 1 'cd /var/www/html && ./occ status'
bad_line 1 'sudo php /var/www/html/occ status'
bad_line 1 'sudo -n -E php /var/www/html/occ status'
bad_line 1 'php /var/www/html/occ status'
bad_line 1 'sudo -u root php /var/www/html/occ status'
bad_line 1 'sudo -u www-data php occ status'
bad_line 1 'sudo -u www-data ./occ status'
bad_line 1 'su www-data -c "php /var/www/html/occ status"'
bad_line 1 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "php /var/www/html/occ status"'
bad_line 1 'docker exec nextcloud-app ls /var/www/html'
bad_line 1 'docker compose exec app ls /var/www/html'
bad_line 1 'kubectl get pods'
bad_line 1 'occ status'
bad_line 1 'sudo -u www-data occ status'
bad_line 1 'occ.sh status'
bad_line 1 './occ.sh status'
bad_line 1 'bash scripts/occ.sh status'
bad_line 1 '"${script_dir}/occ.sh" status'
bad_line 1,11 '/clouve/skills/nextcloud/plugin/scripts/occ.sh status'
bad_line 1 'docker ps'
bad_line 1 'podman exec nextcloud-app ls'
bad_line 1 'OCC=occ.sh'
ok_block <<'END'
OCC=@OCC@
$OCC user:disable -- alice
END
ok_line 'sudo --user=www-data php /var/www/html/occ status'
ok_line 'sudo --user www-data php /var/www/html/occ status'
ok_line 'printf "%s\n" "${NEXTCLOUD_ADMIN_PASSWORD:-$(clv-secret NEXTCLOUD_ADMIN_PASSWORD)}" | /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh --password-stdin user:resetpassword --password-from-env -- "${NEXTCLOUD_ADMIN_USER}"'
ok_line 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -u www-data php /var/www/html/occ status --output=json -n"'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh groupfolders:delete 3 --force'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh versions:cleanup alice'
ok_line '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh user:setting alice files quota "5 GB"'
ok_line '@OCC@ status --output=json'
ok_line 'sudo -n -u www-data php /var/www/html/occ status --output=json'
ok_line 'sudo -n --preserve-env=NC_PASS -u www-data php /var/www/html/occ user:resetpassword --password-from-env alice'
ok_line 'sudo -E -u www-data php /var/www/html/occ status'
ok_line 'sudo --preserve-env=NC_PASS -u www-data php /var/www/html/occ status'
ok_line 'exec sudo -n --preserve-env=NC_PASS -u www-data php /var/www/html/occ upgrade'
ok_line 'sudo -n -u www-data flock /var/www/html/nextcloud-init-sync.lock php /var/www/html/occ upgrade'
ok_line 'sudo -u www-data php -d memory_limit=512M /var/www/html/occ files:scan --all'
ok_line '"${NC_OCC[@]}" status'
ok_line '"${occ[@]}" status'
ok_line '${NC_OCC} status'
ok_line 'php -v'
ok_line "php -r 'echo 1;'"
ok_line 'ls -l /var/www/html/occ'
ok_line 'cat @OCC@'
ok_line '# docker exec nextcloud-app php occ status   (a comment, not a command)'
ok_line '@OCC@ status   # not php occ, not docker exec, not kubectl'
bad_script 1 other.sh "remote+=' php /var/www/html/occ --no-interaction --no-warnings'"
ok_script occ.sh "remote+=' php /var/www/html/occ --no-interaction --no-warnings'"
bad_script 1 other.sh 'NC_OCC=(php "${nc_root}/occ" --no-interaction)'
bad_script 1 other.sh 'ssh_run "${host}" "docker exec nextcloud-app ls"'
bad_script_block 1 other.sh <<'END'
cat <<'EOF' | sshpass -e ssh "${target}" bash -s
php /var/www/html/occ status
EOF
END
ok_script other.sh '"${script_dir}/occ.sh" user:info --output=json -- "${uid}" 2>&1'
ok_script other.sh 'text="$("${script_dir}/occ.sh" user:info --output=json -- "${uid}" 2>&1)"'
ok_script other.sh 'msg "Run occ.sh maintenance:mode --off to turn it off"'
ok_script other.sh 'NC_OCC=(sudo -n -u www-data php "${nc_root}/occ" --no-interaction --no-warnings)'
ok_script other.sh 'occ_run "${NC_OCC[@]}" maintenance:mode --off'
ok_script other.sh 'www() { (cd / && exec sudo -n -u www-data "$@"); }'
ok_script other.sh 'php_run() { www php -d display_errors=stderr -d log_errors=0 -r "${php_code}" -- "$@"; }'
ok_script other.sh '# php occ status, docker exec and kubectl in a comment'
ok_script_block other.sh <<'END'
usage() {
    cat <<'EOF'
Usage: occ.sh [--password-stdin] [--init-lock] [--] <occ arguments...>
  occ.sh status --output=json
  printf '%s\n' "$pw" | occ.sh --password-stdin user:resetpassword --password-from-env -- alice
EOF
}
END

# docker, podman and kubectl are commands the agent can't run; naming one in text is fine
bad_line 1 'docker compose logs app'
bad_line 1 'sudo docker ps'
bad_line 1 'sudo -n -u root docker ps'
bad_line 1 'timeout 5 kubectl get pods'
bad_line 1 'env FOO=1 podman ps'
bad_line 1 'exec docker run --rm alpine true'
bad_line 1 'echo hi | docker exec nextcloud-app ls'
bad_line 1 'ls /tmp && docker ps'
bad_line 1 'x=$(docker ps)'
bad_line 1 'echo hi; docker ps'
bad_line 1 'true || docker ps'
bad_block 1 <<'END'
echo `kubectl get pods`
END
bad_block 1 <<'END'
sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "bash -c 'docker ps'"
END
bad_line 1 'xargs -n1 docker rm'
bad_line 1 'ssh clouve-ops@${NEXTCLOUD_HOST} docker ps'
bad_line 1 'sshpass -e ssh -o LogLevel=ERROR clouve-ops@${NEXTCLOUD_HOST} "sudo docker ps"'
bad_line 1 'bash -c "kubectl get pods"'
bad_line 1 'for c in a b; do docker rm "$c"; done'
bad_line 1 'if kubectl get pods; then echo yes; fi'
bad_line 1 '(cd /tmp && podman ps)'
bad_line 1 'ssh clouve-ops@${NEXTCLOUD_HOST} occ status'
bad_script 1 other.sh 'docker ps'
bad_script 1 other.sh 'sudo -n kubectl get pods'
ok_line 'which docker'
ok_line 'type docker kubectl'
ok_line 'command -v docker kubectl || echo "neither is installed"'
ok_line 'grep -q docker /proc/1/cgroup && echo "in a container"'
ok_line 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "grep -c docker /proc/1/cgroup"'
ok_line 'ssh clouve-ops@${NEXTCLOUD_HOST} which docker'
ok_line "jq '.docker' package.json"
ok_line 'echo "this is not run with docker"'
ok_line 'echo "docker compose pull is what the customer runs"'
ok_line 'printf "%s\n" "kubectl get pods"'
ok_line 'echo "occ is slow here"'
ok_block <<'END'
sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "echo 'docker ps is not available'"
END
ok_line 'apt-get install -y kubectl'
ok_line 'helm get values kubectl-proxy'
ok_fence fence:text 'tini -> docker-entrypoint.sh -> apache2-foreground'
ok_fence fence:text 'docker-entrypoint.sh starts Apache and the cron loop'
ok_script other.sh 'msg "docker is not installed here"'
ok_script other.sh 'echo "kubectl is not available: use the dashboard"'

# ---- rule 2: secret reads
bad_line 2 '@OCC@ config:list --private'
bad_line 2 '@OCC@ config:list system --private'
bad_line 2 '@OCC@ config:list --output=json --private system'
bad_line 2 '@OCC@ config:system:get dbpassword'
bad_line 2 '@OCC@ config:system:get secret'
bad_line 2 '@OCC@ config:system:get passwordsalt'
bad_line 2 '@OCC@ config:system:get mail_smtppassword'
bad_line 2 '@OCC@ config:system:get proxyuserpwd'
bad_line 2 '@OCC@ config:system:get redis password'
bad_line 2 '@OCC@ config:system:get --output=json dbpassword'
bad_line 2 '@OCC@ config:system:get "dbpassword"'
bad_line 2 '@OCC@ config:app:get spreed signaling_secret'
bad_line 2 '@OCC@ config:app:get example user_password'
bad_line 2 '@OCC@ config:app:get example api_token'
bad_line 2 '@OCC@ config:app:get example private_key'
bad_line 2 '@OCC@ config:app:get example clientSecret'
bad_line 2 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -u www-data php /var/www/html/occ config:system:get dbpassword"'
bad_line 2 'config:list --private'
bad_script 2 other.sh 'occ_run 60 config:system:get dbpassword'
ok_line '@OCC@ config:list system'
ok_line '@OCC@ config:list system --output=json'
ok_line '@OCC@ config:system:get overwrite.cli.url'
ok_line '@OCC@ config:system:get redis host'
ok_line '@OCC@ config:system:get lost_password_link'
ok_line '@OCC@ config:app:get core lastcron'
ok_line '@OCC@ config:app:get encryption useMasterKey'
ok_line '@OCC@ config:app:get password_policy minLength'
ok_line '@OCC@ config:app:get password_policy enforceNonCommonPassword'
ok_script other.sh 'msg "config:system:get dbpassword would print the database password"'

# sharing policy keys have password or token in the name and hold a flag, a number or a list of groups
ok_line '@OCC@ config:app:get core shareapi_enforce_links_password'
ok_line '@OCC@ config:app:set core shareapi_enforce_links_password --value=yes'
ok_line '@OCC@ config:app:set core shareapi_enable_link_password_by_default --value=yes'
ok_block <<'END'
@OCC@ config:app:set core shareapi_enforce_links_password_excluded_groups --value='["admins"]'
END
ok_line '@OCC@ config:app:get core shareapi_token_length'
ok_line '@OCC@ config:app:set core shareapi_allow_custom_tokens --value=no'
ok_line '@OCC@ config:system:get sharing.enable_mail_link_password_expiration'
ok_line '@OCC@ config:system:set sharing.enable_mail_link_password_expiration --type=boolean --value=true'
ok_line '@OCC@ config:system:set auth.storeCryptedPassword --type=boolean --value=false'
# ... and a secret is still a secret next to them
bad_line 2 '@OCC@ config:app:get core api_token'
bad_line 2 '@OCC@ config:app:get example shareapi_token_length'
bad_line 4 '@OCC@ config:app:set core my_secret --value=x'
bad_line 4 '@OCC@ config:app:set example shareapi_enforce_links_password --value=yes'
bad_line 4 '@OCC@ config:app:set example admin_password --value=x'
bad_line 4 '@OCC@ config:system:set shareapi_enforce_links_password --value=yes'
bad_line 4 '@OCC@ config:system:set sharingpassword --value=x'

# ---- rule 3: unscoped cleanups
bad_line 3 '@OCC@ versions:cleanup'
bad_line 3 '@OCC@ versions:cleanup --all-users'
bad_line 3 '@OCC@ versions:cleanup alice --all-users'
bad_line 3 '@OCC@ trashbin:cleanup'
bad_line 3 '@OCC@ trashbin:cleanup --all-users'
bad_line 3 '@OCC@ trashbin:cleanup --output=json'
bad_line 3 '@OCC@ trashbin:cleanup -v'
bad_line 3 'versions:cleanup'
bad_line 3 '@OCC@ trashbin:cleanup < /dev/null'
ok_line '@OCC@ trashbin:cleanup <user id>'
ok_line '@OCC@ versions:cleanup <user id>'
ok_line '@OCC@ versions:cleanup alice bob'
ok_line '@OCC@ versions:cleanup --path="/alice/files/Music"'
ok_line '@OCC@ versions:cleanup -p /alice/files/Music'
ok_line '@OCC@ trashbin:cleanup alice'
ok_line '@OCC@ trashbin:cleanup <uid>'
ok_line '@OCC@ trashbin:cleanup "${uid}"'
ok_line '@OCC@ trashbin:cleanup --output=json alice'
ok_line '@OCC@ trashbin:cleanup --output json alice'
ok_line '@OCC@ trashbin:cleanup -- alice'
ok_script other.sh 'trap cleanup EXIT'
ok_script other.sh 'cleanup() { rm -rf "${work}"; }'

# versions:cleanup --path needs a value: 35.0.2 takes an empty path to mean every user
bad_line 3 '@OCC@ versions:cleanup --path='
bad_line 3 '@OCC@ versions:cleanup --path=""'
bad_line 3 '@OCC@ versions:cleanup --path ""'
bad_line 3 "@OCC@ versions:cleanup -p ''"
bad_line 3 '@OCC@ versions:cleanup --path'
bad_line 3 '@OCC@ versions:cleanup --path=alice/files/Music'
bad_line 3 '@OCC@ trashbin:cleanup ""'
ok_line '@OCC@ versions:cleanup --path=/alice/files/Music'
ok_line '@OCC@ versions:cleanup --path "/alice/files/Old reports"'
ok_line '@OCC@ versions:cleanup --path="${folder}"'
ok_line '@OCC@ versions:cleanup --path=$folder'
ok_line '@OCC@ versions:cleanup --path=<path>'
ok_line '@OCC@ versions:cleanup -p"/alice/files/Music"'
# xargs takes the user from stdin, but nothing on the line names one: a real unscoped run
bad_block 3 <<'END'
@OCC@ user:list --output=json | jq -r 'keys[]' | xargs -n1 @OCC@ trashbin:cleanup
END
ok_block <<'END'
@OCC@ user:list --output=json | jq -r 'keys[]' | xargs -I{} @OCC@ trashbin:cleanup {}
END

# ---- rule 4: passwords on a command line
bad_line 4 '@OCC@ config:system:set mail_smtppassword --value=hunter2'
bad_line 4 '@OCC@ config:system:set redis password --value=x'
bad_line 4 '@OCC@ config:app:set spreed signaling_secret --value="${secret}"'
bad_line 4 '@OCC@ config:system:set mail_smtppassword --value "$pw"'
bad_line 4 '@OCC@ user:resetpassword alice'
bad_line 4 '@OCC@ user:resetpassword --no-password alice'
bad_line 4 '@OCC@ --password-stdin --init-lock user:resetpassword alice'
bad_line 4 '@OCC@ user:add alice'
bad_line 4 '@OCC@ user:add --display-name="Alice A" -g staff alice'
bad_line 4 'mysql -h db -u nextcloud -pSECRET nextcloud'
bad_line 4 "mysql -u nextcloud -p'secret' nextcloud"
bad_line 4 'mariadb --password=secret nextcloud'
bad_line 4 'mariadb-dump -h db -u nextcloud -pSECRET nextcloud'
bad_line 4 'mysqldump --password=secret nextcloud'
bad_line 4 'sshpass -p secret ssh clouve-ops@${NEXTCLOUD_HOST} true'
bad_line 4 'sshpass -psecret ssh clouve-ops@${NEXTCLOUD_HOST} true'
bad_line 4 'ssh clouve-ops@${NEXTCLOUD_HOST} "mysql -u nextcloud -pSECRET nextcloud"'
bad_script 4 other.sh '"${script_dir}/occ.sh" --password-stdin user:add -- "${uid}"'
ok_line 'printf "%s\n" "$pw" | @OCC@ --password-stdin user:add --password-from-env -- alice'
ok_line '@OCC@ user:add --generate-password --email=alice@example.com --display-name="Alice A" -g staff alice'
ok_line 'MYSQL_PWD="${NEXTCLOUD_DB_PASSWORD:-$(clv-secret NEXTCLOUD_DB_PASSWORD)}" mysql -h ${NEXTCLOUD_DB_HOST} -u ${NEXTCLOUD_DB_USER} ${NEXTCLOUD_DB_NAME}'
ok_line 'mkdir -p /tmp/x && mysql -N -e "SELECT 1"'
ok_line 'tar -cpf /tmp/x.tar /tmp/y && mysql -N -e "SELECT 1"'
ok_line 'mysql -P 3306 -h db -u nextcloud nextcloud'
ok_line 'mysql -h db -u nextcloud -p nextcloud'
ok_line 'sshpass -e ssh -p 2222 clouve-ops@${NEXTCLOUD_HOST} true'
bad_line 4 'curl -s -u alice:secret "https://cloud.example.com/ocs/v2.php/cloud/users/alice?format=json"'
bad_line 4 'curl -s --user "alice:${APP_PASSWORD}" https://cloud.example.com/remote.php/dav/'
bad_line 4 'curl -s -ualice:secret https://cloud.example.com/remote.php/dav/'
bad_line 4 'curl -s --user=alice:<app-password> https://cloud.example.com/remote.php/dav/'
ok_line 'curl -s -u alice https://cloud.example.com/remote.php/dav/'
ok_line 'curl -s -K - -H "OCS-APIRequest: true" "https://cloud.example.com/ocs/v2.php/cloud/users/alice?format=json" < "${config_file}"'
ok_line 'curl -s --user-agent "skill/1" https://cloud.example.com/status.php'
ok_line 'SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} true'
ok_line '@OCC@ config:app:set core backgroundjobs_mode --value=cron'
ok_line '@OCC@ config:system:set trusted_domains 1 --value=cloud.example.com'
ok_line '@OCC@ config:app:set password_policy minLength --value=12'
ok_line '@OCC@ config:app:set password_policy enforceNonCommonPassword --value=1'
ok_line '@OCC@ config:system:set lost_password_link --value=disabled'
ok_script other.sh 'msg "user:add makes the account, then sets the display name and groups"'

# curl: u bundled with other short options, the proxy login, and a URL that carries the password
bad_line 4 'curl -su alice:secret https://cloud.example.com/'
bad_line 4 'curl -sSu alice:secret https://cloud.example.com/'
bad_line 4 'curl -Lu alice:secret https://cloud.example.com/'
bad_line 4 'curl -x http://proxy:3128 -U bob:secret https://cloud.example.com/'
bad_line 4 'curl --proxy-user bob:secret https://cloud.example.com/'
bad_line 4 'curl -s "https://alice:secret@cloud.example.com/remote.php/dav/"'
bad_line 4 'curl -s "https://alice:${APP_PASSWORD}@cloud.example.com/remote.php/dav/files/alice/"'
bad_line 4 'curl -s https://alice:<app-password>@cloud.example.com/remote.php/dav/'
bad_line 4 'git clone https://bob:secret@git.example.com/x.git'
ok_line 'curl -su alice https://cloud.example.com/'
ok_line 'curl -sSL -K - https://cloud.example.com/status.php < "${config_file}"'
ok_line 'curl -s -H "X-Note: u:v" -d "username=alice" https://cloud.example.com/status.php'
ok_line 'curl -s -dusername=alice:x https://cloud.example.com/status.php'
ok_line 'curl -s https://alice@cloud.example.com/remote.php/dav/'
ok_line 'curl -s https://cloud.example.com:8443/status.php'
ok_line 'curl -s "https://cloud.example.com/index.php/login?user=alice:bob"'
# the proxy password is a password; mysqladmin and mariadb-admin and the --pass abbreviation take one too
bad_line 4 '@OCC@ config:system:set proxyuserpwd --value=x'
bad_line 4 'mysqladmin -h db -u nextcloud -pSECRET status'
bad_line 4 'mariadb-admin -pSECRET status'
bad_line 4 'mysqlcheck -pSECRET nextcloud'
bad_line 4 'mariabackup --backup --password=secret --target-dir=/tmp/b'
bad_line 4 'mysql --pass=secret nextcloud'
bad_line 4 'mysql --passw=secret nextcloud'
bad_line 4 'mariadb-dump --passwor="secret" nextcloud'
ok_line '@OCC@ config:system:set proxy --value=proxy.example.com:3128'
ok_line 'mysqladmin -h db -u nextcloud status'
ok_line 'mysqlcheck --check --databases nextcloud'
ok_line 'mysql --password nextcloud'
ok_line 'mysql --pager=less --port=3306 nextcloud'
ok_line 'mariadb-admin --protocol=tcp status'

# ---- rule 5: prompts that -n declines
bad_line 5 '@OCC@ groupfolders:delete 3'
bad_line 5 '@OCC@ files:delete /alice/files/old.txt'
bad_line 5 '@OCC@ files:delete --skip-trash 123'
bad_line 5 'groupfolders:delete 3'
bad_script 5 other.sh 'occ_run "${NC_OCC[@]}" groupfolders:delete 3'
ok_line '@OCC@ groupfolders:delete -f 3'
ok_line '@OCC@ groupfolders:delete --force 3'
ok_line '@OCC@ groupfolders:delete <id> --force'
ok_line '@OCC@ files:delete --force /alice/files/old.txt'
ok_line '@OCC@ files:delete -f --skip-trash 123'

# sharing:delete-orphan-shares asks [y/N] and exits 0 either way
bad_line 5 '@OCC@ sharing:delete-orphan-shares'
bad_line 5 '@OCC@ sharing:delete-orphan-shares --owner alice'
bad_script 5 other.sh 'occ_run "${NC_OCC[@]}" sharing:delete-orphan-shares'
ok_line '@OCC@ sharing:delete-orphan-shares --force'
ok_line '@OCC@ sharing:delete-orphan-shares -f --owner alice'
# reading a command's help runs nothing
ok_line '@OCC@ groupfolders:delete --help'
ok_line '@OCC@ help groupfolders:delete'
ok_line '@OCC@ files:delete -h'
ok_line '@OCC@ help files:delete'
ok_line '@OCC@ sharing:delete-orphan-shares --help'
ok_line '@OCC@ trashbin:cleanup --help'
ok_line '@OCC@ versions:cleanup --help'
ok_line '@OCC@ help versions:cleanup'
ok_line '@OCC@ user:add --help'
ok_line '@OCC@ user:resetpassword -h'
ok_line '@OCC@ help user:resetpassword'
ok_line '@OCC@ encryption:enable --help'
ok_line '@OCC@ help encryption:enable'
ok_line '@OCC@ help sharing:create-share'
ok_line '@OCC@ list encryption'
bad_line 3 '@OCC@ help trashbin:cleanup && @OCC@ trashbin:cleanup'
bad_line 5 '@OCC@ groupfolders:delete --help; @OCC@ groupfolders:delete 3'

# ---- rule 6: never run
for cmd in encryption:enable encryption:encrypt-all encryption:enable-master-key encryption:disable-master-key \
  encryption:decrypt-all maintenance:install sharing:create-share sharing:delete-share sharing:get-share \
  sharing:get-shares sharing:add-share-recipient sharing:add-share-source sharing:remove-share-recipient \
  sharing:remove-share-source sharing:update-share-permission sharing:update-share-property \
  sharing:update-share-recipient-permission sharing:update-share-recipient-secret sharing:update-share-state \
  sharing:update-share-user-status sharing:select-share-permission-preset; do
  bad_line 6 "@OCC@ ${cmd} 1"
done
bad_line 6 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -u www-data php /var/www/html/occ encryption:enable"'
bad_line 6 'encryption:encrypt-all'
for cmd in sharing:fix-share-owners sharing:cleanup-remote-storages \
  sharing:expiration-notification sharing:fix-owncloud-group-shares encryption:status encryption:list-modules \
  encryption:disable encryption:set-default-module; do
  ok_line "@OCC@ ${cmd}"
done

# ---- rule 7: no SQL writes
bad_line 7 'mysql -h db -u nextcloud nextcloud -e "DELETE FROM oc_share WHERE id = 1"'
bad_line 7 "mariadb -e 'UPDATE oc_jobs SET reserved_at = 0' nextcloud"
bad_line 7 'mysql -e "insert into oc_share (id) values (1)" nextcloud'
bad_line 7 'mysql nextcloud -e "ALTER TABLE oc_share ADD COLUMN x int"'
bad_line 7 'mysql nextcloud -e "DROP TABLE oc_share"'
bad_line 7 'mysql nextcloud -e "TRUNCATE TABLE oc_jobs"'
bad_line 7 'mysql nextcloud -e "CREATE TABLE t (id int)"'
bad_line 7 'mysql nextcloud -e "REPLACE INTO oc_x VALUES (1)"'
bad_line 7 'mysql nextcloud -e "SELECT 1; DELETE FROM oc_jobs"'
bad_line 7 'mysql nextcloud --execute="UPDATE oc_jobs SET x = 1"'
bad_line 7 'mysql -NBe "DELETE FROM oc_jobs" nextcloud'
bad_line 7 'echo "TRUNCATE oc_jobs" | mysql nextcloud'
bad_line 7 'mysql nextcloud <<< "DELETE FROM oc_jobs"'
bad_block 7 <<'END'
mysql nextcloud <<'SQL'
SELECT 1;
UPDATE oc_jobs SET reserved_at = 0;
SQL
END
bad_block 7 <<'END'
sshpass -e ssh clouve-ops@${NEXTCLOUD_DB_HOST} "mysql nextcloud" <<EOF
insert into oc_x values (1);
EOF
END
bad_fence fence:sql 7 'UPDATE oc_jobs SET reserved_at = 0;'
bad_script 7 other.sh 'mariadb -e "DROP DATABASE nextcloud"'
ok_script restore.sh 'mariadb -e "DROP DATABASE nextcloud"'
ok_line 'mysql -N -e "SELECT COUNT(*) FROM oc_share" nextcloud'
ok_line 'mysql -e "SHOW CREATE TABLE oc_share" nextcloud'
ok_line 'mysql -e "SELECT TRUNCATE(size / 1048576, 2) FROM oc_filecache LIMIT 5" nextcloud'
ok_line 'mysql -e "SELECT REPLACE(path, '"'files/'"', '"''"') FROM oc_filecache LIMIT 5" nextcloud'
ok_line 'mysql -e "SELECT id FROM oc_jobs WHERE class LIKE '"'%delete%'"'" nextcloud'
ok_line 'mysql -e "SELECT * FROM oc_jobs FOR UPDATE" nextcloud'
ok_line 'mysql nextcloud <<<"SELECT 1"'
ok_line 'mysql -e "SELECT 1" nextcloud 2>&1 | grep "DELETE failed"'
ok_line 'echo "DELETE FROM oc_share" > /tmp/note.txt'
ok_line 'curl -s -X DELETE -H "OCS-APIRequest: true" https://cloud.example.com/ocs/v2.php/apps/files_sharing/api/v1/shares/12'
ok_block <<'END'
mysql nextcloud <<'SQL'
SELECT id, share_type FROM oc_share WHERE uid_owner = 'alice';
SHOW CREATE TABLE oc_share;
SQL
END
ok_fence fence:sql 'SELECT COUNT(*) FROM oc_share;'
ok_script other.sh 'ocs DELETE "/ocs/v2.php/apps/files_sharing/api/v1/shares/${id}"'

# an -e string that runs over several lines, the house style of the Moodle playbooks
bad_block 7 <<'END'
mysql -h db -u nextcloud nextcloud -e "
DELETE FROM oc_jobs WHERE reserved_at > 0;
"
END
bad_block 7 <<'END'
mysql nextcloud --execute='
  SELECT 1;
  UPDATE oc_jobs SET reserved_at = 0;
'
END
bad_block 7 <<'END'
sshpass -e ssh clouve-ops@${NEXTCLOUD_DB_HOST} "mysql nextcloud -e '
  DELETE FROM oc_jobs;
'"
END
bad_block 7 <<'END'
printf 'DELETE FROM oc_x;
' | mysql nextcloud
END
ok_block <<'END'
mysql -h db -u nextcloud nextcloud -e "
SELECT id, class
  FROM oc_jobs
 WHERE reserved_at > 0;
"
END
ok_block <<'END'
mysql nextcloud -e "
-- who owns what
SELECT uid_owner, COUNT(*) FROM oc_share GROUP BY uid_owner;
SHOW CREATE TABLE oc_share;
"
END
# <<- strips leading tabs from the body and from the closing line
bad_line 7 $'mysql nextcloud <<-\'SQL\'\n\tdelete from oc_x;\n\tSQL'
ok_line $'mysql nextcloud <<-\'SQL\'\n\tselect 1;\n\tSQL'
# the verbs beyond the brief's eight, at the start of the SQL or after a ;
for sql in "RENAME TABLE oc_a TO oc_b" "LOAD DATA INFILE '/tmp/x' INTO TABLE oc_x" \
  "LOAD XML LOCAL INFILE '/tmp/x.xml' INTO TABLE oc_x" "GRANT ALL ON *.* TO 'x'@'%'" \
  "REVOKE ALL ON *.* FROM 'x'@'%'" "CALL cleanup()" "OPTIMIZE TABLE oc_filecache" "REPAIR TABLE oc_filecache" \
  "SET GLOBAL max_connections = 10" "SET PERSIST max_connections = 10" "SET @@GLOBAL.max_connections = 10" \
  "SELECT * FROM oc_share INTO OUTFILE '/tmp/shares.txt'" "SELECT 1 INTO DUMPFILE '/tmp/x'" \
  "SELECT 1; GRANT ALL ON *.* TO 'x'@'%'"; do
  bad_line 7 "mysql nextcloud -e \"${sql}\""
done
# ... and the reads that look like them
for sql in "SHOW CREATE TABLE oc_share" "SHOW GRANTS FOR 'nextcloud'@'%'" "SHOW GRANTS" "EXPLAIN SELECT * FROM oc_share" \
  "EXPLAIN DELETE FROM oc_share" "SELECT * FROM oc_jobs WHERE class = 'DELETE'" \
  "SELECT 'INTO OUTFILE', 'GRANT ALL', 'SET GLOBAL x'" "SET @x = 1; SELECT @x" "SET NAMES utf8mb4" \
  "SET SESSION sql_mode = ''" "SELECT id INTO @first FROM oc_jobs LIMIT 1" "SHOW VARIABLES LIKE 'max_connections'" \
  "SELECT table_name, CREATE_TIME FROM information_schema.tables"; do
  ok_line "mysql nextcloud -e \"${sql}\""
done

# ---- rule 8: no feeding redacted config back
bad_line 2,8 '@OCC@ config:list system --private | @OCC@ config:import'
bad_line 8 '@OCC@ config:list system | @OCC@ config:import'
bad_line 8 '@OCC@ config:import < <(@OCC@ config:list system)'
bad_line 8 '@OCC@ config:import <<< "$(@OCC@ config:list system)"'
bad_block 8 <<'END'
@OCC@ config:list system > /tmp/config.json
@OCC@ config:import /tmp/config.json
END
bad_block 8 <<'END'
@OCC@ config:list system >> /tmp/config.json
@OCC@ config:import < /tmp/config.json
END
ok_line '@OCC@ config:import /tmp/fresh-settings.json'
ok_line '@OCC@ config:list system > /tmp/config.json'
ok_line '@OCC@ config:list system --output=json | jq .system.version'

bad_block 8 <<'END'
@OCC@ config:list system |
  @OCC@ config:import
END
bad_block 8 <<'END'
@OCC@ config:list system > /tmp/c.json &&
  @OCC@ config:import /tmp/c.json
END
bad_block 8 <<'END'
@OCC@ config:list system > /tmp/c.json ||
  @OCC@ config:import /tmp/c.json
END
ok_block <<'END'
@OCC@ config:list system |
  jq .system.version
END
ok_block <<'END'
@OCC@ config:list system --output=json ||
  echo "could not list the settings"
END

# ---- rule 9: quotas
bad_line 9 '@OCC@ user:setting alice files quota "5 GiB"'
bad_line 9 '@OCC@ user:setting alice files quota 5GiB'
bad_line 9 '@OCC@ user:setting alice files quota "500 MiB"'
bad_line 9 '@OCC@ config:app:set files default_quota --value="10 GiB"'
bad_line 9 '@OCC@ groupfolders:quota 3 10GiB'
bad_line 9 'curl -s -K - -H "OCS-APIRequest: true" -d quota=5GiB "https://cloud.example.com/ocs/v1.php/cloud/users/alice"'
bad_line 9 '@OCC@ user:setting alice files quota 5GB'
bad_line 9 '@OCC@ groupfolders:quota 3 10MB'
ok_line '@OCC@ user:setting alice files quota "500 MB"'
ok_line '@OCC@ user:setting alice files quota "2 TB"'
ok_line '@OCC@ user:setting alice files quota unlimited'
ok_line '@OCC@ user:setting alice files quota none'
ok_line '@OCC@ user:setting alice files quota 5368709120'
ok_line '@OCC@ groupfolders:quota 3 "10 GB"'
ok_line '@OCC@ config:app:set files default_quota --value="10 GB"'
ok_line '# the GiB trap: a quota of "5 GiB" is read as 5 bytes'
ok_line '@OCC@ user:setting alice files quota "5 GB"   # not "5 GiB"'

ok_line 'curl -s -K - -X PUT "https://cloud.example.com/ocs/v2.php/cloud/users/alice?key=quota&value=5%20GB"'
ok_line 'curl -s -K - -X PUT "https://cloud.example.com/ocs/v2.php/cloud/users/alice?key=quota&value=5+GB"'
bad_line 9 'curl -s -K - -X PUT "https://cloud.example.com/ocs/v2.php/cloud/users/alice?key=quota&value=5%20GiB"'
bad_line 9 'curl -s -K - -X PUT "https://cloud.example.com/ocs/v2.php/cloud/users/alice?key=quota&value=5+MiB"'
bad_line 9 'curl -s -K - -X PUT "https://cloud.example.com/ocs/v2.php/cloud/users/alice?key=quota&value=5GB"'

# ---- rule 10: no undefined $SKILL_DIR
bad_prose 10 'Run $SKILL_DIR/scripts/occ.sh status from the agent.'
bad_prose 10 'The folder is ${SKILL_DIR}.'
bad_line 1,10 '$SKILL_DIR/scripts/occ.sh status'
bad_script 10 other.sh '# see $SKILL_DIR/scripts'
bad_script 10 other.sh 'echo "${SKILL_DIR}"'
ok_prose 'Mention SKILL_DIR without a dollar sign, or $SKILL_DIRECTORY, which is a different name.'

# ---- rule 11: named files exist
bad_prose 11 'Read `/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/missing.sh` first.'
bad_prose 11 'See /clouve/skills/nextcloud/plugin/skills/nextcloud/reference/nope.md.'
bad_prose 11 'The folder /clouve/skills/nextcloud/plugins/oops holds it.'
bad_line 11 'bash /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/missing.sh --help'
bad_script 11 other.sh '# helper at /clouve/skills/nextcloud/plugin/lib/gone.sh'
ok_prose 'The script is `/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh`.'
ok_prose 'It is (/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh), or "/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh", or occ.sh at /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh: next.'
ok_prose 'The scripts sit in /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/ and every one is /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/*.sh or /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/<name>.sh.'
ok_prose 'The payload is staged at /clouve/skills/nextcloud/plugin/.'
ok_script other.sh '# the plugin root is /clouve/skills/nextcloud/plugin/. and occ.sh is /clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh'

# ---- rule 12: values in single quotes
bad_line 12 '@OCC@ files:scan --path="/<uid>/files/<folder>"'
bad_line 12 '@OCC@ user:info --output=json -- "<uid>"'
bad_line 12 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -n -u www-data ls /var/www/html/data/<uid>/files"'
bad_line 12 'name="<Full name>"'
bad_line 12 '@OCC@ user:info -- "$(printf %s "<uid>")"'
bad_line 12 '@OCC@ group:adduser -- "${GROUP:-<gid>}" alice'
bad_line 12 $'sshpass -e ssh h "sed -n \'/<pattern>/p\' -- f"'
bad_fence fence:sh 12 '@OCC@ user:info -- "<uid>"'
bad_block 12 <<'END'
@OCC@ files:scan \
  --path="/<uid>/files/<folder>"
END
ok_line "@OCC@ files:scan --path='/<uid>/files/<folder>'"
ok_line "@OCC@ user:info --output=json -- '<uid>'"
ok_line $'@OCC@ user:setting -- \'<uid>\' settings display_name \'Ann O\'\\\'\'Brien\''
ok_line '@OCC@ user:info -- "${NEXTCLOUD_ADMIN_USER}"'
ok_line "jq -r '.[] | select(.name == \"<name>\")' list.json"
ok_line "p=\"\$(printf %q '/var/www/html/data/<uid>/files')\""
ok_line $'sshpass -e ssh h "sed -n \'/<uninstall>/,/<\\/uninstall>/p\' -- f"'
ok_line '@OCC@ groupfolders:scan -- <id>'
ok_line '# a comment may say "<uid>" in double quotes'
ok_fence fence:text 'The account "<uid>" already exists.'
bad_prose 12 'Scan it with `files:scan --path="/<uid>/files/<folder>"` first.'
bad_prose 12 'Check it with `occ.sh user:info -- "<uid>"` first.'
bad_prose 12 'Then add `-N -e "<query>"` to the line.'
bad_prose 12 'Read it with `sudo -n -u www-data cat "/var/www/html/data/<uid>/files/<file>"`.'
bad_prose 12 '| `files:scan --path="/<uid>/files/<folder>"` | a row of a table is prose too |'
bad_prose 12 'With a variable first: `MYSQL_PWD=x mysql -e "SELECT 1 FROM oc_users WHERE uid = <uid>"`.'
ok_prose $'Scan it with `files:scan --path=\'/<uid>/files/<folder>\'` first.'
ok_prose 'It prints `The account "<uid>" already exists.` and exits 1.'
ok_prose 'A list is `{"<gid>":["<uid>"]}` in JSON, and `"<text>" is not a valid IP address` is a message.'
ok_prose 'Write the quota as `"5 GB"`, and the login as `"${NEXTCLOUD_ADMIN_USER}"`.'
bad_prose 12 'A span of two backticks, ``echo "`date` <uid>"``, is read as well.'
ok_prose 'A lone ` before "<uid>" is plain text, since nothing closes it.'

# ---- how the corpus is read
bad_fence tilde:bash 5 '@OCC@ groupfolders:delete 3'
bad_fence indent:bash 5 '@OCC@ groupfolders:delete 3'
bad_fence quote:bash 5 '@OCC@ groupfolders:delete 3'
ok_fence quote:bash '@OCC@ groupfolders:delete 3 --force'
bad_block 5 <<'END'
@OCC@ \
  groupfolders:delete 3
END
ok_block <<'END'
@OCC@ \
  groupfolders:delete 3 \
  --force
END
ok_prose 'Never run `php occ` as root, never `docker exec`, never `config:list --private`, and a quota of 5 GiB is 5 bytes.'
ok_prose 'DELETE FROM oc_share is what the skill never runs, and groupfolders:delete 3 needs --force.'
# an apostrophe in a # comment must not swallow the lines after it (the entries share one fence, so each hit
# has to land on its own line)
block_open
block_ok "echo hi   # it's fine"
block_bad 5 '@OCC@ groupfolders:delete 3'
block_ok "echo done  # don't"
block_close
# a quote that never closes is read as its own line, not joined to the lines after it ...
block_open
block_ok 'echo "this quote never closes'
block_bad 5 '@OCC@ groupfolders:delete 3'
block_close
# ... and the line after it is a command of its own, not text of the string that echo prints
block_open
block_ok 'echo "this quote never closes'
block_bad 1 'docker ps'
block_close
# a string that ends a line with \\ hands the shell it goes to a backslash and a newline: its next line goes on
block_open
block_ok $'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "\\\\'
block_bad 1 '  docker ps"'
block_close
# a comment line that ends in a backslash does not continue onto the next line
block_open
block_ok $'# a comment that ends in a backslash \\'
block_bad 5 '@OCC@ groupfolders:delete 3'
block_close
# ... and so is one that closes only after more than 60 lines (read as one string, its config:list and
# config:import would be one command line to rule 8)
block_open
block_ok 'echo "the quote opens here'
block_bad 5 '@OCC@ groupfolders:delete 3'
block_ok '@OCC@ config:list system'
block_filler "$(printf 'echo filler %s\n' {1..60})"
block_ok '@OCC@ config:import /tmp/c.json'
block_ok 'and closes here"'
block_close
# a line that opens a heredoc is read alone even when a quote is open on it: the body follows it, and the lines
# after the heredoc are lines of their own again (a backslash still continues a command)
block_open
block_ok $'text="$(cat <<\'EOF\''
block_bad 1 'php /var/www/html/occ status'
block_ok 'EOF'
block_ok ')"'
block_bad 5 '@OCC@ groupfolders:delete 3'
block_ok $'@OCC@ groupfolders:delete 3 \\'
block_ok '  --force'
block_close
# ---- a quoted script that runs over several lines. Inside it a newline ends a command, as a ; does, and every
# hit lands on its own line (each line below is an entry of one shared fence, so the line a hit is on is checked).
# A flag on a later line does not satisfy an earlier command
block_open
block_bad 4 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "@OCC@ user:add alice'
block_ok '  @OCC@ user:resetpassword --password-from-env bob"'
block_close
block_open
block_bad 5 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "@OCC@ groupfolders:delete 3'
block_ok '  @OCC@ files:delete --force /alice/files/old.txt"'
block_close
block_open
block_bad 3 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "@OCC@ trashbin:cleanup'
block_ok '  @OCC@ trashbin:cleanup alice"'
block_close
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "@OCC@ trashbin:cleanup alice'
block_bad 3 '  @OCC@ versions:cleanup"'
block_close
# a command on the second or a later line is the command it runs
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "cd /tmp'
block_bad 1 '  docker ps'
block_bad 1 '  kubectl get pods'
block_bad 1 '  occ status"'
block_close
# the odoo style: a heredoc inside a quoted ssh command, with the problem on its fifth line
block_open
block_ok $'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} \\'
block_ok $'  "sudo bash -s <<\'EOF\''
block_ok 'cd /var/www/html'
block_ok $'# it\'s a comment with an apostrophe'
block_bad 5 '@OCC@ groupfolders:delete 3'
block_ok 'EOF"'
block_close
# the same inside $( ) with a newline between the commands
block_open
block_ok 'text="$('
block_bad 4 '  @OCC@ user:add alice'
block_ok '  @OCC@ user:resetpassword --password-from-env bob'
block_ok ')"'
block_close
# ... and when the $( ) or the backticks open on a later line of the string than the string itself
block_open
block_ok 'echo "first line'
block_ok '  second line $('
block_bad 4 '  @OCC@ user:add alice'
block_ok ')"'
block_close
block_open
block_ok 'echo "first line'
block_ok '  second line `'
block_bad 4 '  @OCC@ user:add alice'
block_ok '`"'
block_close
# a pipe that ends a line goes on in the next one, also inside a quoted script
block_open
block_bad 7 $'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "printf \'DELETE FROM oc_x;\' |'
block_ok '  mysql nextcloud"'
block_close
# a quoted script with several correct occ calls is clean, line by line
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "'
block_ok '  sudo -n -u www-data php /var/www/html/occ status --output=json -n'
block_ok '  # a comment, and an apostrophe in it: it'"'"'s fine'
block_ok '  sudo -n -u www-data php /var/www/html/occ user:resetpassword --password-from-env alice'
block_ok '  @OCC@ groupfolders:delete 3 --force'
block_ok '  @OCC@ trashbin:cleanup alice'
block_ok '  @OCC@ versions:cleanup --path=/alice/files/Music'
block_ok "  @OCC@ user:setting alice files quota '5 GB'"
block_ok '  df --block-size=1GiB /var/www/html/data'
block_ok '  which docker'
block_ok '"'
block_close
# every rule reads a later line of a quoted script as a command of its own, and reports it on that line
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "'
block_bad 1 '  php /var/www/html/occ status'
block_bad 2 '  @OCC@ config:list system --private'
block_bad 3 '  @OCC@ versions:cleanup'
block_bad 4 '  @OCC@ user:resetpassword alice'
block_bad 5 '  @OCC@ files:delete /alice/files/old.txt'
block_bad 6 '  @OCC@ encryption:enable'
block_bad 7 "  mysql nextcloud -e 'TRUNCATE oc_jobs'"
block_bad 9 '  @OCC@ user:setting alice files quota 5GiB'
block_ok '"'
block_close
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "'
block_ok '  @OCC@ config:list system > /tmp/c.json'
block_bad 8 '  @OCC@ config:import /tmp/c.json'
block_ok '"'
block_close
# an unfinished redirect at the end of a line takes nothing from the next line
block_open
block_ok 'sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "echo done >'
block_bad 1 '  docker ps"'
block_close
# the offsets are those of the whole command line: a $( ) or backticks that open at the end of a long first
# line, a string that starts on a later line than the first (after a pipe that ends a line, or after another
# string that ran over lines), and a $( ) or backticks in the later line of such a string
block_open
block_ok 'sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${NEXTCLOUD_HOST} "echo $('
block_bad 4 '  @OCC@ user:add alice'
block_ok ')"'
block_close
block_open
block_ok 'sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${NEXTCLOUD_HOST} "echo `'
block_bad 4 '  @OCC@ user:add alice'
block_ok '`"'
block_close
block_open
block_ok 'printf %s "${pw}" |'
block_ok '  sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "echo start'
block_ok '  echo $('
block_bad 4 '    @OCC@ user:add alice'
block_ok '  )"'
block_close
block_open
block_ok 'printf %s "${pw}" |'
block_ok '  sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "echo start'
block_ok '  echo `'
block_bad 4 '    @OCC@ user:add alice'
block_ok '  `"'
block_close
block_open
block_ok 'echo "first'
block_ok '  line" && sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "'
block_bad 1 '  docker ps'
block_ok '"'
block_close
# a script is joined the same way: an -e string over lines, and a command that goes on after a pipe
bad_script_block 7 other.sh <<'END'
mysql nextcloud -e "
DELETE FROM oc_jobs;
"
END
bad_script_block 8 other.sh <<'END'
"${script_dir}/occ.sh" config:list system |
  "${script_dir}/occ.sh" config:import
END
bad_script_block 4 other.sh <<'END'
ssh_run "${host}" "
  sudo -n -u www-data php /var/www/html/occ user:add alice
  sudo -n -u www-data php /var/www/html/occ user:resetpassword --password-from-env bob
"
END
ok_script_block other.sh <<'END'
ssh_run "${host}" "
  sudo -n -u www-data php /var/www/html/occ user:resetpassword --password-from-env alice
  sudo -n -u www-data php /var/www/html/occ trashbin:cleanup alice
"
END

# ---- only shell is joined into one command: bash, sh, shell, console, zsh and untagged fences, and .sh files
# an apostrophe in a diagram must not chain the lines after it
block_open text
block_ok "Gibbon's stack"
block_ok '├── nginx/                 ← the web server'
block_bad 1 'docker ps'
block_ok "└── Gibbon's own data"
block_close
# the shell fences join a -e string that runs over lines; so does one with no language, and a tag may carry more
# than the language (a case, {.bash}, bash{1,3}, sh:install.sh, bash,linenos)
for lang in bash sh shell console zsh ksh dash shellscript shell-session shellsession Bash '{.bash}' 'bash{1,3}' \
  'sh:install.sh' 'bash,linenos' ''; do
  bad_fence "fence:${lang}" 7 $'mysql nextcloud -e "\nDELETE FROM oc_jobs;\n"'
done
# other fences are read a line at a time, and every line is still checked: the apostrophe opens nothing
for lang in text json yaml php diff sql python ini nginx '{.text}'; do
  bad_fence "fence:${lang}" 1 $'Gibbon\'s stack\ndocker ps\nGibbon\'s end'
done
bad_fence fence:yaml 1 'docker ps'
bad_fence fence:json 1 'kubectl get pods'
# a table row ends in | but is no pipeline: its lines are not chained
block_open ''
block_ok '| Setting | Value |'
block_ok '| default_quota | 10 GB |'
block_ok '| trash | 500MB |'
block_ok '| config:list system | prints the settings |'
block_ok '| config:import file.json | loads a file |'
block_close
# a line that starts with | is not joined onto the line before it, whatever that line opens
block_open ''
block_ok "Alice's results:"
block_ok '| a | b |'
block_bad 1 'docker ps'
block_ok "Bob's results"
block_close
# the rule holds in both directions: a row is not joined onto the line before it, even when that line leaves a
# quote open and the row closes it; and a row that ends in | does not carry on into the line after it
block_open ''
block_ok "@OCC@ config:list system | echo it's"
block_ok "| @OCC@ config:import /tmp/c.json it's |"
block_close
block_open ''
block_ok '| @OCC@ config:list system |'
block_ok '@OCC@ config:import /tmp/c.json'
block_close
# ... but a backslash still continues a command onto a line that starts with |, also onto one that starts and
# ends with it, or holds only a |
bad_block 8 <<'END'
@OCC@ config:list system --output=json \
  | @OCC@ config:import
END
bad_block 8 <<'END'
@OCC@ config:list system --output=json \
  | @OCC@ config:import |
END
bad_block 8 <<'END'
@OCC@ config:list system --output=json \
  |
  @OCC@ config:import
END
# a line that starts with | and does not end with it is the front of a pipeline (a long jq program), no table
# row: the quote it closes is joined, and the line after it is a command of its own
block_open
block_ok "jq -r '"
block_ok '  .system'
block_ok $'  | .version\' <<< "${json}"'
block_bad 1 'docker ps'
block_ok "echo 'done'"
block_close
# ... so it is joined into the string it sits in: what echo prints is no command
block_open
block_ok 'echo "usage:'
block_ok '  | docker ps'
block_ok '  done"'
block_close
ok_block <<'END'
@OCC@ config:list system --output=json \
  | jq .system.version
END

# commands as a playbook writes them. The scripts they name have to exist in the fixture too (rule 11).
ok_script run-in-nextcloud.sh '# stands in for the real script'
ok_script temp-password.sh '# stands in for the real script'
ok_block <<'END'
for uid in alice bob; do
  @OCC@ trashbin:cleanup "${uid}"
  @OCC@ versions:cleanup "${uid}"
done
@OCC@ versions:cleanup --path="/alice/files/Old reports"
@OCC@ files:transfer-ownership <from-uid> <to-uid> --path="Reports"
@OCC@ user:setting alice files quota "5 GB"   # prints the quota when the value is left out
END
ok_block <<'END'
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${NEXTCLOUD_HOST} "sudo tail -n 200 /var/www/html/data/nextcloud.log" | jq -r 'select(.level <= 2) | "\(.time) \(.message)"'
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${NEXTCLOUD_HOST} "sudo -n -u www-data valkey-cli -s /run/clouve/valkey/valkey.sock ping"
MYSQL_PWD="${NEXTCLOUD_DB_PASSWORD:-$(clv-secret NEXTCLOUD_DB_PASSWORD)}" mysql -h ${NEXTCLOUD_DB_HOST} -u ${NEXTCLOUD_DB_USER} ${NEXTCLOUD_DB_NAME} <<'SQL'
SELECT storage, COUNT(*) AS files FROM oc_filecache GROUP BY storage;
SELECT TRUNCATE(SUM(size) / 1048576, 1) AS mb FROM oc_filecache;
SQL
END
ok_block <<'END'
@OCC@ --init-lock upgrade
/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/run-in-nextcloud.sh --detach backup.sh --with-data
/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/temp-password.sh --create --display-name "Alice A" --group staff alice
@OCC@ user:add --generate-password --email=alice@example.com --display-name="Alice A" -g staff,sales alice
@OCC@ app:list --output=json | jq -r '.enabled | keys[]'
curl -s -K - "https://${NEXTCLOUD_HOST}/ocs/v2.php/cloud/users/alice?format=json" <<'CURL'
header = "OCS-APIRequest: true"
CURL
END
ok_fence fence:text "$(
  cat <<'END'
+----------------+---------+
| Setting        | Value   |
+----------------+---------+
| quota          | 5 GB    |
+----------------+---------+
You may use your browser or the occ upgrade command to do the upgrade
{"installed":true,"version":"35.0.2.1","maintenance":false,"needsDbUpgrade":false}
END
)"

# ---------------------------------------------------------------------------
# 2. The checker
# ---------------------------------------------------------------------------
cat > "${work}/checker.py" <<'PY'
import bisect
import os
import re
import sys
import textwrap

OCC_SH = '/clouve/skills/nextcloud/plugin/skills/nextcloud/scripts/occ.sh'
OCC_PHP = '/var/www/html/occ'
LOCK = '/var/www/html/nextcloud-init-sync.lock'
STAGED = '/clouve/skills/nextcloud/plugin/'
RESTORE_SH = 'skills/nextcloud/scripts/restore.sh'

# The one line of occ.sh that builds the remote command in pieces: the sudo -n -u www-data part and the
# optional flock part are on earlier lines (127 to 134), so this line alone reads as a bare php occ. It is
# exempt from the php part of rule 1 by file and exact text. The same text in any other file still fires.
R1_EXEMPT = {('skills/nextcloud/scripts/occ.sh', "remote+=' php /var/www/html/occ --no-interaction --no-warnings'")}

RULES = {
    1: ('occ form',
        'Call occ as %s <command>. Over SSH it is sudo -u www-data php %s <command> -n (sudo may also take -n, -E or '
        '--preserve-env=NC_PASS, and flock %s). In a script: "${script_dir}/occ.sh", "${NC_OCC[@]}" or "${occ[@]}". '
        'Never php occ, ./occ, sudo php, a bare php %s, or a docker, podman or kubectl command (the agent has none '
        'of them; naming one in text is fine).'
        % (OCC_SH, OCC_PHP, LOCK, OCC_PHP)),
    2: ('secret reads',
        'Read settings with config:list system, which hides the secrets. Never config:list --private, and never '
        'config:system:get or config:app:get on a password, secret or token key. (Sharing policy keys such as '
        'shareapi_enforce_links_password hold no secret and are fine.)'),
    3: ('unscoped cleanups',
        'Name the user: versions:cleanup <uid> or versions:cleanup --path=/<uid>/files/<folder>, and '
        'trashbin:cleanup <uid>. With no user, with an empty --path, or with --all-users they clean every user.'),
    4: ('passwords on a command line',
        'Send a password on stdin: printf \'%s\\n\' "$pw" | occ.sh --password-stdin user:resetpassword '
        '--password-from-env -- <uid>. user:add takes --password-from-env or --generate-password. A database '
        'password goes in MYSQL_PWD, the clouve-ops password in SSHPASS with sshpass -e, and a curl login in '
        'the -K - config on stdin (not -u user:password, and not user:password@host in a URL).'),
    5: ('prompts that -n declines',
        'Add --force (or -f) to groupfolders:delete, files:delete and sharing:delete-orphan-shares. They ask '
        '[y/N]; with -n, occ takes the default, which is no, and still exits 0, so nothing is deleted and '
        'nothing says so.'),
    6: ('never run',
        'This skill never runs server-side encryption, maintenance:install or the experimental sharing:* share '
        'store. If a file has to mention one, put it in prose, outside a code block.'),
    7: ('no SQL writes',
        'Read with SELECT or SHOW. Change data with occ or Nextcloud\'s own API. GRANT, SET GLOBAL, OPTIMIZE, '
        'INTO OUTFILE and the like are off limits too. Only scripts/restore.sh replaces the database.'),
    8: ('redacted config fed back',
        'config:list hides secrets, so importing its output would overwrite the real values with placeholders. '
        'Import a file you wrote.'),
    9: ('quotas',
        'Write a quota as "5 GB": the number, one space, then GB or MB. GiB and MiB are read as bytes (the '
        'provisioning API\'s 5 GiB means 5 bytes).'),
    10: ('undefined SKILL_DIR',
         'The agent defines no $SKILL_DIR. Write the literal path under %s.' % STAGED),
    11: ('named files exist',
         'Every %s<path> has to exist as plugins/nextcloud/<path>.' % STAGED),
    12: ('values in single quotes',
         "Put a value that comes from Nextcloud or from a person in single quotes, with '\\'' for an apostrophe in "
         "it: --path='/<uid>/files/<folder>'. In double quotes the agent's shell expands $( ), backticks and $ in it "
         "before occ.sh or ssh quotes anything. Only the skill's own variables, such as \"${NEXTCLOUD_ADMIN_USER}\", "
         "go in double quotes."),
}

# ---------------------------------------------------------------------------
# A small shell lexer. It splits one line of shell text into commands (lists of words) and reads quotes the
# way a shell does, but never fails: an unbalanced quote runs to the end of the line. Text inside quotes is
# lexed again as a command line, so a command handed to ssh or bash -c is seen, and so is an occ.sh
# mentioned in a message. $(...) and `...` are lexed too.
# ---------------------------------------------------------------------------
MAX_DEPTH = 4
PLACEHOLDER = re.compile(r'<[A-Za-z][A-Za-z0-9_.:/ -]*>')
OPS = ('<<<', '<<-', '&&', '||', '|&', ';;', '<<', '>>', '>&', '<&', '&>', '>|', '|', '&', ';', '(', ')', '<', '>')
REDIRS = ('<<<', '<<-', '<<', '>>', '>&', '<&', '&>', '>|', '<', '>')


class Word:
    __slots__ = ('v', 'pos', 'quoted')

    def __init__(self, v, pos, quoted):
        self.v, self.pos, self.quoted = v, pos, quoted


class Cmd:
    # emb: lexed out of a quoted string. via: the words of the command that held that string (None otherwise).
    __slots__ = ('words', 'redirs', 'subs', 'sep', 'emb', 'prev', 'via')

    def __init__(self, sep, emb, prev, via):
        self.words, self.redirs, self.subs = [], [], []
        self.sep, self.emb, self.prev, self.via = sep, emb, prev, via

    def values(self):
        return [w.v for w in self.words]

    def walk(self):
        yield self
        for s in self.subs:
            for c in s.walk():
                yield c


def skip_dq(s, i):
    """s[i] is a double quote. Returns the index just after the closing one (len(s) when there is none)."""
    n = len(s)
    i += 1
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
        elif c == '"':
            return i + 1
        elif c == '$' and s[i + 1:i + 2] == '(':
            i = match_paren(s, i + 2)[0]
        elif c == '$' and s[i + 1:i + 2] == '{':
            i = match_brace(s, i + 2)
        elif c == '`':
            i = min(end_backtick(s, i + 1) + 1, n)
        else:
            i += 1
    return n


def end_backtick(s, i):
    """i is just after an opening backtick. Returns the index of the closing one (len(s) when there is none)."""
    n = len(s)
    while i < n:
        if s[i] == '\\':
            i += 2
        elif s[i] == '`':
            return i
        else:
            i += 1
    return n


def match_paren(s, i):
    """i is just after '$('. Returns (index after the matching ')', the text inside)."""
    n = len(s)
    start = i
    depth = 1
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i = skip_dq(s, i)
            continue
        if c == '`':
            i = min(end_backtick(s, i + 1) + 1, n)
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1, s[start:i]
        i += 1
    return n, s[start:]


def match_brace(s, i):
    """i is just after '${'. Returns the index after the matching '}'."""
    n = len(s)
    depth = 1
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i = skip_dq(s, i)
            continue
        if c == '$' and s[i + 1:i + 2] == '(':
            i = match_paren(s, i + 2)[0]
            continue
        if c == '$' and s[i + 1:i + 2] == '{':
            depth += 1
            i += 2
            continue
        if c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def nth_line_start(text, pos, k):
    """The offset where the k-th line after the one holding pos starts (pos itself when k is 0)."""
    for _ in range(k):
        j = text.find('\n', pos)
        if j < 0:
            break
        pos = j + 1
    return pos


class Lexer:
    def __init__(self, text, depth=0, emb=False, via=None, root=None, base=0):
        # root and base are for text lexed out of a quoted string or a $( ): root is the text of the whole command
        # line and base the offset in it where this text starts, so that each word can be put on the line it is on.
        self.t, self.depth, self.emb, self.via = text, depth, emb, via
        self.root, self.base = root, base
        self.whole = text if root is None else root
        self.cmds = []
        self.cur = Cmd('', emb, None, via)
        self.buf, self.wstart, self.wq, self.pend = [], None, False, None
        self.comments = []        # (start, end) of each # comment; a comment ends at the newline
        self.open_quote = False   # a ' or " (or $') was never closed
        self.dangling = False     # the text ends with | && || or |&, so the command goes on in the next line

    def at(self, k):
        """The offset in the whole command line that stands for offset k of this text: k itself at the top. In
        text lexed out of a string it is the start of the line that holds k, counting from where the text starts
        (a newline in the string is a newline in the command line)."""
        if self.root is None:
            return k
        return nth_line_start(self.root, self.base, self.t.count('\n', 0, k))

    def sub(self, inner, start):
        """Lex text found inside this text (a $( ), a backtick, or a quoted string) that starts at offset start."""
        return lex(inner, self.depth + 1, self.emb, self.via, self.whole, self.at(start))[0]

    def begin(self, i):
        if self.wstart is None:
            self.wstart = i

    def flush(self):
        if self.wstart is None:
            return
        w = Word(''.join(self.buf), self.at(self.wstart), self.wq)
        self.dangling = False
        was_redirect = self.pend is not None
        if self.pend is not None:
            self.cur.redirs.append((self.pend, w))
            self.pend = None
        else:
            self.cur.words.append(w)
        if self.wq and re.search(r'\s', w.v):
            words = self.cur.values()
            via = tuple(words if was_redirect else words[:-1])
            self.cur.subs.extend(lex(w.v, self.depth + 1, True, via, self.whole, w.pos)[0])
        self.buf, self.wstart, self.wq = [], None, False

    def end_cmd(self, sep):
        if self.cur.words or self.cur.redirs or self.cur.subs:
            self.cmds.append(self.cur)
        self.cur = Cmd(sep, self.emb, self.cmds[-1] if self.cmds else None, self.via)
        self.dangling = sep in ('|', '&&', '||', '|&')

    def dq(self, i):
        """self.t[i] is a double quote. Returns the index after the closing one. Appends the string, with its
        escapes resolved, to the word, and lexes the substitutions inside it."""
        t, n = self.t, len(self.t)
        k = i + 1
        out = []
        while k < n:
            c = t[k]
            if c == '"':
                self.buf.append(''.join(out))
                return k + 1
            if c == '\\' and k + 1 < n:
                d = t[k + 1]
                if d in '"\\$`':
                    out.append(d)
                    k += 2
                elif d == '\n':
                    k += 2
                else:
                    out.append(c)
                    k += 1
                continue
            if c == '$' and t[k + 1:k + 2] == '(':
                j, inner = match_paren(t, k + 2)
                self.cur.subs.extend(self.sub(inner, k + 2))
                out.append(t[k:j])
                k = j
                continue
            if c == '$' and t[k + 1:k + 2] == '{':
                j = match_brace(t, k + 2)
                out.append(t[k:j])
                k = j
                continue
            if c == '`':
                j = end_backtick(t, k + 1)
                self.cur.subs.extend(self.sub(t[k + 1:j], k + 1))
                out.append(t[k:j + 1])
                k = min(j + 1, n)
                continue
            out.append(c)
            k += 1
        self.buf.append(''.join(out))
        self.open_quote = True
        return n

    def run(self):
        t, n = self.t, len(self.t)
        i = 0
        while i < n:
            c = t[i]
            if c in ' \t\r\n':
                self.flush()
                if c == '\n' and (self.cur.words or self.cur.redirs or self.cur.subs):
                    # a newline ends a command, as a ; does (after | && || or ; the command is still empty, so
                    # a newline there goes on)
                    self.pend = None
                    self.end_cmd('\n')
                i += 1
            elif c == '#' and self.wstart is None:
                j = t.find('\n', i)
                j = n if j < 0 else j
                self.comments.append((i, j))
                i = j
            elif c == '\\':
                if i + 1 < n and t[i + 1] == '\n':
                    i += 2                    # a backslash and a newline join the lines: nothing is left. A string
                    continue                  # that ends a line with \\ gets here: dq() reads it as one backslash
                self.begin(i)
                if i + 1 < n:
                    self.buf.append(t[i + 1])
                    self.wq = True
                i += 2
            elif c == "'":
                self.begin(i)
                j = t.find("'", i + 1)
                if j < 0:
                    j = n
                    self.open_quote = True
                self.buf.append(t[i + 1:j])
                self.wq = True
                i = j + 1
            elif c == '"':
                self.begin(i)
                self.wq = True
                i = self.dq(i)
            elif c == '$':
                self.begin(i)
                nx = t[i + 1:i + 2]
                if nx == '(':
                    j, inner = match_paren(t, i + 2)
                    self.cur.subs.extend(self.sub(inner, i + 2))
                    self.buf.append(t[i:j])
                    i = j
                elif nx == '{':
                    j = match_brace(t, i + 2)
                    self.buf.append(t[i:j])
                    i = j
                elif nx == "'":
                    j = i + 2
                    while j < n and t[j] != "'":
                        j += 2 if t[j] == '\\' else 1
                    if j >= n:
                        self.open_quote = True
                    self.buf.append(t[i + 2:j])
                    self.wq = True
                    i = min(j + 1, n)
                else:
                    self.buf.append('$')
                    i += 1
            elif c == '`':
                self.begin(i)
                j = end_backtick(t, i + 1)
                self.cur.subs.extend(self.sub(t[i + 1:j], i + 1))
                self.buf.append(t[i:j + 1])
                i = min(j + 1, n)
            elif c in '|&;()<>':
                m = PLACEHOLDER.match(t, i) if c == '<' else None
                # <name> is a placeholder when a boundary follows it, or when it sits inside a word with no
                # space in it (https://alice:<app-password>@host/), where it can't be a redirect.
                if m and (m.end() >= n or t[m.end()] in ' \t\'")],;|&@'
                          or (self.wstart is not None and ' ' not in m.group(0))):
                    self.begin(i)
                    self.buf.append(m.group(0))
                    i = m.end()
                    continue
                op = c
                for cand in OPS:
                    if t.startswith(cand, i):
                        op = cand
                        break
                if op in REDIRS and self.wstart is not None and not self.wq and ''.join(self.buf).isdigit():
                    self.buf, self.wstart = [], None  # the 2 of 2>&1 belongs to the operator
                else:
                    self.flush()
                i += len(op)
                if op in REDIRS:
                    self.pend = op
                else:
                    if op == '(':
                        self.pend = None  # <( ) and >( ): the redirect has no target word
                    self.end_cmd(op)
            else:
                self.begin(i)
                self.buf.append(c)
                i += 1
        self.flush()
        dangling = self.dangling
        self.end_cmd('')
        self.dangling = dangling


def lex(text, depth=0, emb=False, via=None, root=None, base=0):
    """Returns (commands, comments): the commands of some shell text, and the (start, end) of each comment."""
    if depth > MAX_DEPTH:
        return [], []
    lx = Lexer(text, depth, emb, via, root, base)
    lx.run()
    return lx.cmds, lx.comments


# ---------------------------------------------------------------------------
# The corpus: the fenced blocks of every .md file and the non-comment lines of every .sh file, as units.
# A unit is one command line: in shell, lines joined by a trailing backslash, by a quote left open or by a
# trailing | && || make one unit, and a heredoc body is one unit per line.
# ---------------------------------------------------------------------------
FENCE = re.compile(r'^(\s*(?:>\s?)*)(`{3,}|~{3,})\s*([^`\s]*)')
QUOTE = re.compile(r'^\s*(?:>\s?)+')
SQL_LANGS = ('sql', 'mysql', 'mariadb')
# Only shell is joined into one command. A fence is shell when it is tagged with one of these, or with nothing;
# text, json, yaml, php, diff, sql and the rest are read a line at a time (a diagram with an apostrophe, a block
# of prose or a table is no command). Authors tag such a fence text.
SHELL_FENCES = ('', 'bash', 'sh', 'shell', 'console', 'zsh', 'ksh', 'dash', 'shellscript', 'shell-session',
                'shellsession')


def is_shell_fence(lang):
    return re.split(r'[\s{},:]', lang.lstrip('{.'), maxsplit=1)[0] in SHELL_FENCES


def is_table_row(text):
    """A line that starts and ends with | is a row of a table (the | at its end closes a cell), not a pipeline
    that goes on below. It is never joined to the line after it, nor that line to it. A line of a jq program
    that only starts with | (a pipe at the front of a continuation line) is not a row."""
    t = text.strip()
    return len(t) > 1 and t[0] == '|' and t[-1] == '|'


def is_comment(text):
    return text.lstrip().startswith('#')


def continues(text):
    return (len(text) - len(text.rstrip('\\'))) % 2 == 1


MAX_JOIN = 60   # most physical lines read as one command line


def joined(parts):
    """parts is [(lineno, text, join)]. join says how a line meets the next one: 'bs' (a trailing backslash,
    dropped) or 'nl' (a newline, kept: the line ends inside a quote or after | && ||), None for the last.
    Returns (the text, [(offset where each line starts, lineno)])."""
    texts, starts, off = [], [], 0
    for ln, t, join in parts:
        if join == 'bs':
            t = t[:-1]
        elif join == 'nl':
            t += '\n'
        starts.append((off, ln))
        texts.append(t)
        off += len(t)
    return ''.join(texts), starts


def text_state(text):
    """(a quote is left open, the text ends in | && ||, the text starts a heredoc)"""
    try:
        lx = Lexer(text)
        lx.run()
    except RecursionError:
        return False, False, False    # Unit says so, with the line
    heredoc = any(op in ('<<', '<<-') for c in lx.cmds for d in c.walk() if not d.emb for op, _w in d.redirs)
    return lx.open_quote, lx.dangling, heredoc


def logical_line(numbered, i, join=True):
    """The physical lines that make one command line, starting at numbered[i]. A trailing backslash joins the
    next line. So does a quote left open (an -e string that holds the SQL on the lines after it) and a line that
    ends in | && || (the command goes on); but a table row (a line that starts and ends with |) neither joins
    nor is joined by quote or operator. A line that starts a heredoc is read alone: its body follows. A quote
    that is still open after MAX_JOIN lines, or at the end of the block, means the first line was read wrongly,
    so the first line stands alone. With join=False (the fence is no shell) every line stands alone.
    Returns (parts, index of the last line used)."""
    n = len(numbered)
    parts = [[numbered[i][0], numbered[i][1], None]]
    j = i
    if not join:
        return [tuple(parts[0])], i
    while j + 1 < n and len(parts) < MAX_JOIN:
        last = parts[-1][1]
        if not is_comment(last) and continues(last):
            how = 'bs'
        elif is_table_row(last) or is_table_row(numbered[j + 1][1]):
            break
        else:
            quote, dangling, heredoc = text_state(joined(parts)[0])
            if heredoc or not (quote or dangling):
                break
            how = 'nl'
        parts[-1][2] = how
        j += 1
        parts.append([numbered[j][0], numbered[j][1], None])
    if any(p[2] == 'nl' for p in parts) and text_state(joined(parts)[0])[0]:
        parts = [[numbered[i][0], numbered[i][1], None]]
        j = i
        while j + 1 < n and not is_comment(parts[-1][1]) and continues(parts[-1][1]):
            parts[-1][2] = 'bs'
            j += 1
            parts.append([numbered[j][0], numbered[j][1], None])
    return [tuple(p) for p in parts], j


class Unit:
    def __init__(self, rel, origin, parts, block):
        self.rel, self.origin, self.block = rel, origin, block
        self.text, self.starts = joined(parts)
        self.offs = [s[0] for s in self.starts]
        try:
            lx = Lexer(self.text)
            lx.run()
        except RecursionError:
            sys.exit('%s:%d: this line nests quotes and substitutions too deeply to read' % (rel, parts[0][0]))
        self.cmds, self.comments = lx.cmds, lx.comments

    def line_at(self, pos):
        k = bisect.bisect_right(self.offs, pos) - 1
        return self.starts[max(k, 0)][1]

    def all_cmds(self):
        for c in self.cmds:
            for d in c.walk():
                yield d

    def code(self):
        """The text with each comment blanked out, so offsets stay the same."""
        out = self.text
        for a, b in self.comments:
            out = out[:a] + ' ' * (b - a) + out[b:]
        return out


def tool_is(v, names):
    base = v.rsplit('/', 1)[-1]
    return base in names and ('/' not in v or v.rsplit('/', 2)[-2] in ('bin', 'sbin'))


def is_sql_client(v):
    return tool_is(v, ('mysql', 'mariadb'))


def build_units(rel, origin, numbered, skip_comments, join=True):
    """numbered is [(lineno, text)] for one fenced block or one script. Returns (units, heredocs)."""
    block = {'listed': set(), 'shell': join}
    units, heredocs, open_hd = [], [], []
    i, n = 0, len(numbered)
    while i < n:
        ln, text = numbered[i]
        if open_hd:
            hd = open_hd[0]
            if (text.lstrip('\t') if hd['dash'] else text) == hd['delim']:
                open_hd.pop(0)
            else:
                hd['lines'].append((ln, text))
                if not (skip_comments and is_comment(text)):
                    units.append(Unit(rel, origin, [(ln, text, None)], block))
            i += 1
            continue
        if skip_comments and is_comment(text):
            i += 1
            continue
        parts, i = logical_line(numbered, i, join)
        u = Unit(rel, origin, parts, block)
        units.append(u)
        sql = any(is_sql_client(v) for c in u.all_cmds() for v in c.values())
        for c in u.all_cmds():
            if c.emb:
                continue
            for op, w in c.redirs:
                if op in ('<<', '<<-'):
                    hd = {'delim': w.v, 'dash': op == '<<-', 'sql': sql, 'lines': []}
                    open_hd.append(hd)
                    heredocs.append(hd)
        i += 1
    return units, heredocs


def md_blocks(lines):
    """Yields (language, [(lineno, text)]) for each fenced block. A block inside a blockquote loses its > marks."""
    block = None
    for ln, text in enumerate(lines, 1):
        if block is not None and block['quoted']:
            text = QUOTE.sub('', text, count=1)
        m = FENCE.match(text)
        if block is None:
            if m:
                block = {'mark': m.group(2), 'lang': m.group(3).lower(), 'lines': [], 'quoted': '>' in m.group(1)}
        elif m and m.group(2)[0] == block['mark'][0] and len(m.group(2)) >= len(block['mark']) and text.strip() == m.group(2):
            yield block['lang'], block['lines']
            block = None
        else:
            block['lines'].append((ln, text))
    if block is not None:
        yield block['lang'], block['lines']


# ---------------------------------------------------------------------------
# Reading a command
# ---------------------------------------------------------------------------
NEVER_RUN = re.compile(
    r'encryption:(?:enable|encrypt-all|enable-master-key|disable-master-key|decrypt-all)'
    r'|maintenance:install'
    r'|sharing:(?:create-share|delete-share|get-shares?|add-share-[a-z-]+|remove-share-[a-z-]+'
    r'|update-share-[a-z-]+|select-share-permission-preset)')
RULE_COMMANDS = {'config:list', 'config:import', 'config:system:get', 'config:app:get', 'config:system:set',
                 'config:app:set', 'versions:cleanup', 'trashbin:cleanup', 'user:resetpassword', 'user:add',
                 'groupfolders:delete', 'files:delete', 'sharing:delete-orphan-shares'}
# These ask [y/N]. Under -n occ takes the answer no and still exits 0: nothing is deleted and nothing says so.
FORCE_COMMANDS = ('groupfolders:delete', 'files:delete', 'sharing:delete-orphan-shares')
VALUE_OPTS = {'--output', '--default-value', '--path', '-p', '--type', '--value', '--display-name', '--email',
              '--group', '-g'}


def is_php(v):
    return re.fullmatch(r'(?:.*/)?php\d*(?:\.\d+)?', v) is not None


def is_launcher(vals, j, origin):
    """Does vals[j] start an occ call? occ.sh, php .../occ, ${NC_OCC[@]}, $OCC, ${occ[@]}, occ_run ..."""
    v = vals[j]
    if v.rsplit('/', 1)[-1] == 'occ.sh' or v.endswith('/occ'):
        return True
    if v == 'occ':
        return origin == 'md' or any(is_php(x) for x in vals[:j])
    return ('NC_OCC' in v or re.fullmatch(r'\$\{?OCC\}?', v) is not None
            or re.fullmatch(r'\$\{?occ(\[[@*]\])?\}?', v) is not None
            or re.fullmatch(r'occ_[A-Za-z0-9_]+', v) is not None)


SHELL_KEYWORDS = ('if', 'then', 'else', 'elif', 'while', 'until', 'do', '!', '{')
# Commands that run the command after them, with the options of each that take a value.
WRAPPERS = {
    'sudo': ('-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-T', '-U', '--user', '--group'),
    'doas': ('-u', '-C'),
    'env': ('-u', '-C', '-S'),
    'timeout': ('-k', '-s', '--kill-after', '--signal'),
    'xargs': ('-n', '-I', '-L', '-P', '-d', '-E', '-s', '-a'),
    'nice': ('-n',),
    'watch': ('-n',),
    'exec': (), 'nohup': (), 'time': (), 'setsid': (),
    'sshpass': ('-f', '-d', '-p'),
    'ssh': ('-o', '-p', '-i', '-l', '-F', '-J', '-L', '-R', '-D', '-b', '-c', '-e', '-E', '-I', '-m', '-O', '-S',
            '-W', '-w', '-B', '-Q'),
}
RUNNERS = ('bash', 'sh', 'dash', 'zsh', 'ksh', 'su', 'runuser', 'eval') + tuple(WRAPPERS)


def command_start(vals):
    """The index of the command a line runs: after VAR=value words, shell keywords (if, then, do) and wrappers
    such as sudo, exec, env, timeout, xargs and ssh <host>, which run what follows. len(vals) when none follows."""
    k, n = 0, len(vals)
    while k < n:
        w = vals[k]
        base = w.rsplit('/', 1)[-1]
        if re.match(r'[A-Za-z_]\w*=', w) or w in SHELL_KEYWORDS:
            k += 1
        elif base in WRAPPERS:
            takes = WRAPPERS[base]
            k += 1
            while k < n and vals[k].startswith('-') and vals[k] != '-':
                k += 2 if vals[k] in takes else 1
            if base == 'ssh' and k < n:
                k += 1                      # the host: what follows runs there
            elif base == 'timeout' and k < n and re.fullmatch(r'[0-9.]+[smhd]?', vals[k]):
                k += 1                      # the duration
        else:
            return k
    return n


def runs_a_command(cmd):
    """Quoted text is lexed again, so that a command given to ssh or bash -c is seen. What comes out of it is a
    command only when what stands in front of the string runs it (ssh, bash -c, sudo, eval ...). A string given
    to echo, printf or a message function is text, even when it starts with the word docker."""
    if not cmd.emb:
        return True
    via = cmd.via or ()
    for x in via[:command_start(via) + 1]:
        base = x.rsplit('/', 1)[-1]
        if base in RUNNERS or 'ssh' in base:
            return True
    return False


def asks_for_help(vals, launcher, j):
    """occ.sh user:add --help, occ.sh -h user:add and occ.sh help user:add read a command's help and run nothing."""
    before = vals[(launcher + 1 if launcher is not None else 0):j]
    after = vals[j + 1:]
    return '--help' in after or '-h' in after or 'help' in before or '--help' in before or '-h' in before


def occ_calls(u, real=False):
    """Yields (name, args, word, cmd) for each occ command the rules look at. A command name counts after an
    occ launcher. In Markdown it also counts at the start of a line: the assistant would run it. With real=True
    a request for help (--help, -h, help <name>) is left out: it runs nothing."""
    for cmd in u.all_cmds():
        vals = cmd.values()
        launcher = None
        for j, v in enumerate(vals):
            if v in RULE_COMMANDS or NEVER_RUN.fullmatch(v):
                start = u.origin == 'md' and all(re.match(r'[A-Za-z_]\w*=', x) or x == '$' for x in vals[:j])
                if launcher is not None or start:
                    if real and asks_for_help(vals, launcher, j):
                        continue
                    yield v, vals[j + 1:], cmd.words[j], cmd
            elif launcher is None and is_launcher(vals, j, u.origin):
                launcher = j


def positionals(args):
    """The arguments that are not options, nor values of options that take one."""
    pos, i, literal = [], 0, False
    while i < len(args):
        a = args[i]
        if literal:
            pos.append(a)
        elif a == '--':
            literal = True
        elif a.startswith('-') and a != '-':
            if a in VALUE_OPTS and i + 1 < len(args) and not args[i + 1].startswith('-'):
                i += 1
        else:
            pos.append(a)
        i += 1
    return pos


SUDO_VALUE_OPTS = ('-u', '-g', '-C', '-D', '-h', '-p', '-r', '-t', '-T', '-U', '--user', '--group')


def sudo_prefix(vals, i):
    """What stands in front of vals[i] (a php): ('none', '') when no sudo does, ('ok', '') for sudo -u www-data
    with only the options the skill uses (and the init-lock flock), else ('bad', why)."""
    j = i
    if j >= 2 and vals[j - 2] == 'flock':
        if vals[j - 1] != LOCK:
            return 'bad', 'flock has to lock %s' % LOCK
        j -= 2
    k = j - 1
    while True:
        if k < 0:
            return 'none', ''
        if vals[k].rsplit('/', 1)[-1] == 'sudo':
            break
        if vals[k].startswith('-') or (k >= 1 and vals[k - 1] in SUDO_VALUE_OPTS):
            k -= 1
            continue
        return 'none', ''
    opts = vals[k + 1:j]
    user, extra, m = None, [], 0
    while m < len(opts):
        o = opts[m]
        if o in ('-u', '--user') and m + 1 < len(opts):
            user = opts[m + 1]
            m += 2
            continue
        if o.startswith('--user='):
            user = o[7:]
        elif o.startswith('-u') and len(o) > 2 and not o.startswith('--'):
            user = o[2:]
        elif o not in ('-n', '--non-interactive', '-E', '--preserve-env=NC_PASS'):
            extra.append(o)
        m += 1
    if user != 'www-data':
        return 'bad', 'sudo runs it as %s; it has to be sudo -u www-data' % (user or 'root')
    if extra:
        return 'bad', 'sudo takes only -n, -E and --preserve-env=NC_PASS here, not %s' % extra[0]
    return 'ok', ''


def php_script(vals, i):
    """The index of the script php runs (skipping php's own options), or None when it runs code instead."""
    j = i + 1
    while j < len(vals):
        a = vals[j]
        if a in ('-d', '-c'):
            j += 2
        elif a == '-f':
            return j + 1 if j + 1 < len(vals) else None
        elif a in ('-r', '-R', '-B', '-E', '-F'):
            return None
        elif a.startswith('-'):
            j += 1
        else:
            return j
    return None


# ---------------------------------------------------------------------------
# The rules on the corpus. Each takes a unit and returns [(offset in the unit's text, detail)].
# ---------------------------------------------------------------------------
CONTAINER_TOOLS = ('docker', 'docker-compose', 'podman', 'kubectl')


def r1(u):
    out = []
    exempt = (u.rel, u.text.strip()) in R1_EXEMPT
    for cmd in u.all_cmds():
        ws = cmd.words
        vals = cmd.values()
        start = command_start(vals)
        # docker, podman and kubectl fail when they are run: first in a command, or behind sudo, exec, env,
        # timeout, xargs, ssh <host>. `which docker`, `grep -q docker /proc/1/cgroup` and a message that says the
        # word are not runs.
        if start < len(vals) and tool_is(vals[start], CONTAINER_TOOLS) and runs_a_command(cmd):
            out.append((ws[start].pos, '%s: the agent has no %s; it reaches the containers over SSH'
                        % (vals[start], vals[start])))
        for i, v in enumerate(vals):
            pos = ws[i].pos
            if is_php(v):
                kind, why = sudo_prefix(vals, i)
                j = php_script(vals, i)
                if j is not None and vals[j].rsplit('/', 1)[-1] == 'occ':
                    if exempt:
                        continue
                    path = vals[j]
                    if not (path == OCC_PHP or (u.origin == 'sh' and re.fullmatch(r'\$\{?\w+\}?/occ', path))):
                        out.append((pos, 'php %s: the path to occ is %s' % (path, OCC_PHP)))
                    if kind == 'none':
                        out.append((pos, 'php occ is not run as www-data: put sudo -u www-data in front of php'))
                    elif kind == 'bad':
                        out.append((pos, 'php occ: ' + why))
                elif kind == 'bad':
                    out.append((pos, 'sudo php: ' + why))
            elif v == './occ' and not any(is_php(x) for x in vals[max(0, i - 3):i]):
                out.append((pos, './occ: the path to occ is %s, and it runs as sudo -u www-data php' % OCC_PHP))
            elif u.origin == 'md' and v == 'occ' and i == start and runs_a_command(cmd):
                out.append((pos, 'a bare occ command: there is no occ on the PATH'))
            target = re.sub(r'^[A-Za-z_]\w*=', '', v)  # OCC=/path/occ.sh names the script too
            if u.origin == 'md' and target.rsplit('/', 1)[-1] == 'occ.sh' and target != OCC_SH:
                out.append((pos, '%s: in Markdown, occ.sh is written by its absolute path, %s' % (target, OCC_SH)))
    return out


# The four keys the persona names, plus proxyuserpwd, which holds the proxy's password.
SECRET_SYSTEM_KEYS = {'dbpassword', 'secret', 'passwordsalt', 'mail_smtppassword', 'proxyuserpwd'}
SECRET_APP_KEY = re.compile(r'password|secret|token|private', re.I)


def policy_key(app, key):
    """Keys with password or token in the name whose value holds no secret: a yes/no flag, a number, a list of
    groups or a URL. app is None for a system key. They are the settings the sharing and hardening playbooks
    read and set: the password_policy app (enforceNonCommonPassword ...), core's shareapi_* keys
    (shareapi_enforce_links_password, shareapi_token_length ...), the system keys sharing.* and
    auth.storeCryptedPassword, and lost_password_link."""
    if app is None:
        return key in ('lost_password_link', 'auth.storeCryptedPassword') or key.startswith('sharing.')
    return app == 'password_policy' or (app == 'core' and key.startswith('shareapi_'))


def r2(u):
    out = []
    for name, args, word, _cmd in occ_calls(u):
        if name == 'config:list' and '--private' in args:
            out.append((word.pos, 'config:list --private prints every secret'))
        elif name == 'config:system:get':
            pos = positionals(args)
            for k, a in enumerate(pos):
                if a.lower() in SECRET_SYSTEM_KEYS or (a == 'redis' and pos[k + 1:k + 2] == ['password']):
                    out.append((word.pos, 'config:system:get %s prints a secret' % a))
        elif name == 'config:app:get':
            pos = positionals(args)
            if len(pos) >= 2 and not policy_key(pos[0], pos[1]) and SECRET_APP_KEY.search(pos[1]):
                out.append((word.pos, 'config:app:get %s %s reads a secret' % (pos[0], pos[1])))
    return out


def path_scope(args):
    """True for versions:cleanup --path=VALUE (or -p) when VALUE starts with / (a path), < (a placeholder) or $
    (a variable). 35.0.2 takes the user from the path (apps/files_versions/lib/Command/CleanUp.php) and treats an
    empty or missing path as every user."""
    for k, a in enumerate(args):
        if a in ('--path', '-p'):
            val = args[k + 1] if k + 1 < len(args) else ''
        elif a.startswith('--path='):
            val = a[7:]
        elif a.startswith('-p') and not a.startswith('--'):
            val = a[2:]
        else:
            continue
        if val[:1] in ('/', '<', '$'):
            return True
    return False


def r3(u):
    out = []
    for name, args, word, _cmd in occ_calls(u, real=True):
        if name not in ('versions:cleanup', 'trashbin:cleanup'):
            continue
        if '--all-users' in args:
            out.append((word.pos, '%s --all-users cleans every user' % name))
            continue
        scoped = any(positionals(args))     # an empty '' is no user
        if name == 'versions:cleanup':
            # --path is a scope too (see path_scope), and the spec's gate says "named users or paths".
            scoped = scoped or path_scope(args)
        if not scoped:
            out.append((word.pos, '%s without a user cleans every user' % name))
    return out


SECRETISH = re.compile(r'pass|secret|pwd', re.I)
# The MySQL and MariaDB client programs all take -p<password> and --password=<password>.
DB_CLIENTS = ('mysql', 'mariadb', 'mysqldump', 'mariadb-dump', 'mysqladmin', 'mariadb-admin', 'mysqlcheck',
              'mariadb-check', 'mysqlshow', 'mariadb-show', 'mysqlimport', 'mariadb-import', 'mysqlbinlog',
              'mariadb-binlog', 'mariabackup', 'mariadb-backup')
# mysql takes any prefix of --password that is not ambiguous, so --pass=secret works.
DB_PASSWORD = re.compile(r'-p.+|--pas(?:s(?:w(?:o(?:r(?:d)?)?)?)?)?=.*')
URL_PASSWORD = re.compile(r'://[^/\s:@]*:[^/\s@]+@')
CURL_ARG_SHORT = 'AbcCdDeEFHKmoPQrtTuUwxXyYz'   # the short options of curl that take a value


def curl_login(vals, i):
    """True when the curl command at vals[i] gives user:password in its own words: -u, --user, -U or
    --proxy-user, alone or bundled with other short options (-su, -sSu, -Lu)."""
    k = i + 1
    while k < len(vals):
        a = vals[k]
        cred = None
        if a in ('--user', '--proxy-user'):
            cred = vals[k + 1] if k + 1 < len(vals) else ''
        elif a.startswith('--user=') or a.startswith('--proxy-user='):
            cred = a.split('=', 1)[1]
        elif a.startswith('-') and not a.startswith('--'):
            for m, c in enumerate(a[1:], 2):         # a[m:] is what follows c
                if c in 'uU':
                    cred = a[m:] or (vals[k + 1] if k + 1 < len(vals) else '')
                    break
                if c in CURL_ARG_SHORT:
                    break                            # the rest of the word is that option's value
        if cred is not None and ':' in cred:
            return True
        k += 1
    return False


def r4(u):
    out = []
    for name, args, word, _cmd in occ_calls(u, real=True):
        if name in ('config:system:set', 'config:app:set'):
            keys = positionals(args)
            # Not secrets: policy_key lists them (password_policy, shareapi_*, sharing.* ...).
            if name == 'config:app:set':
                app, keys = (keys[0] if keys else ''), keys[1:2]
                benign = bool(keys) and policy_key(app, keys[0])
            else:
                benign = bool(keys) and all(policy_key(None, k) for k in keys)
            if (not benign and any(SECRETISH.search(k) for k in keys)
                    and any(a == '--value' or a.startswith('--value=') for a in args)):
                out.append((word.pos, '%s %s --value= puts the secret in a command line' % (name, ' '.join(keys))))
        elif name == 'user:resetpassword' and '--password-from-env' not in args:
            out.append((word.pos, 'user:resetpassword without --password-from-env'))
        elif name == 'user:add' and '--password-from-env' not in args and '--generate-password' not in args:
            out.append((word.pos, 'user:add without --password-from-env or --generate-password'))
    for cmd in u.all_cmds():
        vals = cmd.values()
        for w in cmd.words:
            if URL_PASSWORD.search(w.v):
                out.append((w.pos, 'a URL with the password in it (user:password@host)'))
        for i, v in enumerate(vals):
            if tool_is(v, DB_CLIENTS):
                for a in vals[i + 1:]:
                    if DB_PASSWORD.fullmatch(a):
                        out.append((cmd.words[i].pos, '%s with the password in the command line' % v.rsplit('/', 1)[-1]))
                        break
            elif tool_is(v, ('curl',)):
                if curl_login(vals, i):
                    out.append((cmd.words[i].pos, 'curl -u with the password in the command line'))
            elif tool_is(v, ('sshpass',)):
                j = i + 1
                while j < len(vals) and vals[j].startswith('-'):
                    a = vals[j]
                    if a == '-p' or (a.startswith('-p') and not a.startswith('--')):
                        out.append((cmd.words[i].pos, 'sshpass -p puts the password in the command line'))
                        break
                    j += 2 if a in ('-f', '-d') else 1
    return out


def r5(u):
    out = []
    for name, args, word, _cmd in occ_calls(u, real=True):
        if name in FORCE_COMMANDS and not any(a == '--force' or re.fullmatch(r'-[A-Za-z]*f[A-Za-z]*', a) for a in args):
            out.append((word.pos, '%s without --force or -f' % name))
    return out


def r6(u):
    return [(word.pos, '%s is never run by this skill' % name)
            for name, _args, word, _cmd in occ_calls(u, real=True) if NEVER_RUN.fullmatch(name)]


def r8(u):
    out = []
    calls = list(occ_calls(u))
    names = [c[0] for c in calls]
    for name, args, word, cmd in calls:
        if name == 'config:list':
            for op, target in cmd.redirs:
                if op in ('>', '>>', '>|', '&>'):
                    u.block['listed'].add(target.v)
        elif name == 'config:import':
            if 'config:list' in names:
                out.append((word.pos, 'config:list and config:import in one command line'))
                continue
            files = positionals(args) + [t.v for op, t in cmd.redirs if op == '<']
            if any(f in u.block['listed'] for f in files):
                out.append((word.pos, 'config:import reads a file that config:list wrote'))
    return out


SIZE = re.compile(r'(?<![\w.])(\d+(?:[.,]\d+)?)(\s*)([KMGTP])(i?)B\b', re.I)


def decode_spaces(s):
    """s with %20 and + read as spaces (a query string: value=5%20GB), and for each character of the result its
    offset in s."""
    out, offs, i = [], [], 0
    while i < len(s):
        if s.startswith('%20', i):
            out.append(' ')
            offs.append(i)
            i += 3
        else:
            out.append(' ' if s[i] == '+' else s[i])
            offs.append(i)
            i += 1
    return ''.join(out), offs


def r9(u):
    code, offs = decode_spaces(u.code())
    out = []
    start = 0
    for line in code.split('\n'):          # "a line that sets a quota": a script that runs over lines is several
        if 'quota' in line.lower():
            for m in SIZE.finditer(line):
                at = offs[start + m.start()]
                if m.group(4):
                    out.append((at, '%s: GiB and MiB are read as bytes' % m.group(0)))
                elif m.group(2) != ' ':
                    # The brief says quotas are written "5 GB", with the space, so 5GB fails too (Nextcloud reads
                    # both).
                    out.append((at, '%s: write the number, one space, then the unit ("5 GB")' % m.group(0)))
        start += len(line) + 1
    return out


# Rule 12: a <placeholder> inside double quotes. The agent's bash expands $( ), backticks and $ inside double quotes
# before occ.sh or ssh quotes anything, so a value written in a placeholder's place there could run on the agent.
# A placeholder inside single quotes passes, and so does one inside double quotes within single quotes (a jq program,
# a remote command), which the agent's shell does not expand. $( ) and backticks are read as command lines of their
# own, inside double quotes too. <uninstall> is a literal tag that a sed address matches, not a placeholder.
R12_LITERAL = frozenset(('<uninstall>',))


def dq_placeholders(s, base=0, depth=0):
    """[(offset, placeholder)] for each <placeholder> that stands inside double quotes in the shell text s."""
    out = []
    if depth > MAX_DEPTH:
        return out
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '\\':
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            i = n if j < 0 else j + 1
        elif c == '$' and s[i + 1:i + 2] == "'":
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == '\\' else 1
            i = min(j + 1, n)
        elif c == '$' and s[i + 1:i + 2] == '(':
            j, inner = match_paren(s, i + 2)
            out.extend(dq_placeholders(inner, base + i + 2, depth + 1))
            i = j
        elif c == '`':
            j = end_backtick(s, i + 1)
            out.extend(dq_placeholders(s[i + 1:j], base + i + 1, depth + 1))
            i = min(j + 1, n)
        elif c == '"':
            i = dq_scan(s, i, base, depth, out)
        else:
            i += 1
    return out


def dq_scan(s, i, base, depth, out):
    """s[i] is a double quote. Adds the placeholders inside the string to out, and returns the index after it."""
    n = len(s)
    k = i + 1
    while k < n:
        c = s[k]
        if c == '\\':
            k += 2
        elif c == '"':
            return k + 1
        elif c == '$' and s[k + 1:k + 2] == '(':
            j, inner = match_paren(s, k + 2)
            out.extend(dq_placeholders(inner, base + k + 2, depth + 1))
            k = j
        elif c == '`':
            j = end_backtick(s, k + 1)
            out.extend(dq_placeholders(s[k + 1:j], base + k + 1, depth + 1))
            k = min(j + 1, n)
        else:
            m = PLACEHOLDER.match(s, k) if c == '<' else None
            if m and m.group(0) not in R12_LITERAL:
                out.append((base + k, m.group(0)))
                k = m.end()
            else:
                k += 1
    return n


def r12(u):
    """In a shell fence of a Markdown file; inline code is read by inline_rules()."""
    if u.origin != 'md' or not u.block.get('shell'):
        return []
    return [(pos, '%s in double quotes' % ph) for pos, ph in dq_placeholders(u.code())]


UNIT_RULES = ((1, r1), (2, r2), (3, r3), (4, r4), (5, r5), (6, r6), (8, r8), (9, r9), (12, r12))


# Rule 7: SQL that mysql or mariadb is handed. SQL is read statement by statement: a statement is a write when
# its first word (the start of the SQL, or the word after a ;) is a write verb. That keeps SHOW CREATE TABLE,
# SHOW GRANTS, EXPLAIN SELECT ..., SELECT TRUNCATE(...), SELECT REPLACE(...) and a quoted 'delete' (all reads)
# from firing. The brief's eight verbs are the floor; RENAME, LOAD DATA, LOAD XML, GRANT, REVOKE, CALL, OPTIMIZE,
# REPAIR and SET GLOBAL / SET PERSIST change the server or its data just as much. INTO OUTFILE and INTO DUMPFILE
# write a file on the database server wherever they stand.
SQL_WRITE = re.compile(r'[\s(]*(INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE|CREATE|REPLACE|RENAME|GRANT|REVOKE|CALL'
                       r'|OPTIMIZE|REPAIR|LOAD\s+(?:DATA|XML)|SET\s+(?:@@)?(?:GLOBAL|PERSIST(?:_ONLY)?))\b', re.I)
SQL_FILE_OUT = re.compile(r'\bINTO\s+(?:OUTFILE|DUMPFILE)\b', re.I)


def sql_blank(s):
    """s with comments, string literals and quoted names blanked out, same length."""
    out = list(s)
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if s.startswith('--', i) and (i + 2 >= n or s[i + 2] in ' \t\r\n'):
            j = s.find('\n', i)
            j = n if j < 0 else j
        elif c == '#':
            j = s.find('\n', i)
            j = n if j < 0 else j
        elif s.startswith('/*', i) and not s.startswith('/*!', i):
            j = s.find('*/', i + 2)
            j = n if j < 0 else j + 2
        elif c in '\'"`':
            j = i + 1
            while j < n:
                if s[j] == '\\' and c != '`':
                    j += 2
                elif s[j] == c and s[j + 1:j + 2] == c:
                    j += 2
                elif s[j] == c:
                    break
                else:
                    j += 1
            j = min(j + 1, n)
        else:
            i += 1
            continue
        for k in range(i, j):
            if out[k] != '\n':
                out[k] = ' '
        i = j
    return ''.join(out)


def sql_writes(text):
    """[(offset, what)] for each statement of text that writes, and each INTO OUTFILE or INTO DUMPFILE. A
    WITH ... DELETE is a write too."""
    blank = sql_blank(text)
    hits, start = [], 0
    for part in blank.split(';'):
        m = SQL_WRITE.match(part)
        if m:
            hits.append((start + m.start(1), re.sub(r'\s+', ' ', m.group(1)).upper()))
        elif re.match(r'[\s(]*WITH\b', part, re.I):
            m2 = re.search(r'\)\s*(INSERT|UPDATE|DELETE|REPLACE)\b', part, re.I)
            if m2:
                hits.append((start + m2.start(1), m2.group(1).upper()))
        start += len(part) + 1
    for m in SQL_FILE_OUT.finditer(blank):
        hits.append((m.start(), re.sub(r'\s+', ' ', m.group(0)).upper()))
    hits.sort()
    return hits


def sql_candidates(u):
    """Yields (position, SQL text) for the SQL a unit hands to mysql or mariadb: the -e or --execute value, a
    here-string, and the quoted words of the command piped into it."""
    for cmd in u.all_cmds():
        vals = cmd.values()
        if not any(is_sql_client(v) for v in vals):
            continue
        for j, v in enumerate(vals):
            if (v in ('-e', '--execute') or re.fullmatch(r'-[A-Za-z]+e', v)) and j + 1 < len(vals):
                yield cmd.words[j + 1].pos, vals[j + 1]
            elif v.startswith('--execute='):
                yield cmd.words[j].pos, v.split('=', 1)[1]
        for op, w in cmd.redirs:
            if op == '<<<':
                yield w.pos, w.v
        if cmd.sep in ('|', '|&') and cmd.prev is not None:
            for w in cmd.prev.words[1:]:
                if w.quoted:
                    yield w.pos, w.v


def r7_unit(u):
    if u.rel == RESTORE_SH:
        return []
    out = []
    for pos, sql in sql_candidates(u):
        for off, what in sql_writes(sql):
            # a string that runs over several lines: report the line the statement is on
            out.append((nth_line_start(u.text, pos, sql.count('\n', 0, off)), 'SQL %s handed to mysql or mariadb' % what))
    return out


# ---------------------------------------------------------------------------
# Rules on every line of every file
# ---------------------------------------------------------------------------
SKILL_DIR = re.compile(r'\$\{?SKILL_DIR\b')
STAGED_PATH = re.compile(r'/clouve/skills/nextcloud/plugin((?:/[A-Za-z0-9_.-]+)*/?)')


def raw_rules(rel, lines, root, add):
    for ln, text in enumerate(lines, 1):
        if SKILL_DIR.search(text):
            add(10, rel, ln, '$SKILL_DIR is not defined for the agent')
        for m in STAGED_PATH.finditer(text):
            rest = m.group(1)
            nxt = text[m.end():m.end() + 1]
            if not rest and re.match(r'[A-Za-z0-9_-]', nxt):
                add(11, rel, ln, 'a path that is not under %s' % STAGED)
                continue
            sub = rest.rstrip('.').strip('/')
            target = os.path.join(root, sub) if sub else root
            if not os.path.exists(target):
                add(11, rel, ln, 'plugins/nextcloud/%s does not exist' % sub)


# ---------------------------------------------------------------------------
# Rule 12 in the prose of a Markdown file: inline code that reads as a command
# ---------------------------------------------------------------------------
OCC_NAME = re.compile(r'[a-z][a-z0-9_-]*(?::[a-z0-9_-]+)+$')
ASSIGNMENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*=')
INLINE_TOOLS = frozenset((
    'awk', 'base64', 'bash', 'cat', 'cd', 'chmod', 'chown', 'clv-secret', 'compgen', 'cp', 'curl', 'cut', 'df',
    'du', 'echo', 'env', 'exec', 'export', 'find', 'flock', 'grep', 'head', 'jq', 'kill', 'ls', 'mariadb',
    'mariadb-dump', 'md5sum', 'mkdir', 'mv', 'mysql', 'mysqldump', 'nohup', 'occ', 'openssl', 'php', 'printf',
    'rm', 'sed', 'setsid', 'sh', 'sha256sum', 'shred', 'sort', 'ssh', 'sshpass', 'sudo', 'tail', 'tar', 'tee',
    'timeout', 'valkey-cli', 'wc', 'xargs'))


def prose_lines(lines):
    """Yields (lineno, text) for each line of Markdown outside the fenced blocks; the fence lines belong to them."""
    block = None
    for ln, text in enumerate(lines, 1):
        t = QUOTE.sub('', text, count=1) if block is not None and block['quoted'] else text
        m = FENCE.match(t)
        if block is None:
            if m:
                block = {'mark': m.group(2), 'quoted': '>' in m.group(1)}
            else:
                yield ln, text
        elif m and m.group(2)[0] == block['mark'][0] and len(m.group(2)) >= len(block['mark']) and t.strip() == m.group(2):
            block = None


def inline_spans(text):
    """Yields the code of each inline code span in one line of prose: a run of backticks up to the next run of the
    same length. A run that nothing closes is plain text."""
    i, n = 0, len(text)
    while i < n:
        if text[i] != '`':
            i += 1
            continue
        j = i
        while j < n and text[j] == '`':
            j += 1
        k = j
        close = -1
        while k < n:
            if text[k] != '`':
                k += 1
                continue
            e = k
            while e < n and text[e] == '`':
                e += 1
            if e - k == j - i:
                close = k
                break
            k = e
        if close < 0:
            i = j
            continue
        yield text[j:close]
        i = close + (j - i)


def inline_is_command(code):
    """Inline code reads as a command when its first word, after any VAR=value, is an occ command name (files:scan),
    occ with one, a path or a name ending in .sh, an option (a fragment such as -N -e "..."), or a tool in
    INLINE_TOOLS. Anything else is a name, a value, or what a command prints."""
    try:
        cmds, _comments = lex(code)
    except RecursionError:
        return False
    if not cmds:
        return False
    words = [v for v in cmds[0].values()]
    while words and ASSIGNMENT.match(words[0]):
        words = words[1:]
    if not words:
        return False
    first = words[0]
    base = first.rsplit('/', 1)[-1]
    if first.startswith('-') or OCC_NAME.match(first) or base.endswith('.sh') or first.startswith(('/', './', '~/')):
        return True
    if base == 'occ':
        return len(words) > 1 and bool(OCC_NAME.match(words[1]) or words[1].startswith('-'))
    return base in INLINE_TOOLS


def inline_rules(rel, lines, add):
    for ln, text in prose_lines(lines):
        for code in inline_spans(text):
            if inline_is_command(code):
                for _pos, ph in dq_placeholders(code):
                    add(12, rel, ln, '%s in double quotes, in inline code' % ph)


# ---------------------------------------------------------------------------
# Scanning a plugin folder
# ---------------------------------------------------------------------------
def read_lines(path):
    with open(path, encoding='utf-8', errors='replace', newline='') as f:
        lines = f.read().split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return [x.rstrip('\r') for x in lines]


def scan(root):
    """Returns (hits, stats); a hit is (rule, rel path, line, detail, the line's text)."""
    hits, seen = [], set()
    stats = {'files': 0, 'fenced': 0, 'script': 0}
    cache = {}

    def add(rule, rel, ln, detail):
        key = (rule, rel, ln, detail)
        if key not in seen:
            seen.add(key)
            lines = cache[rel]
            hits.append((rule, rel, ln, detail, lines[ln - 1] if 0 < ln <= len(lines) else ''))

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            lines = cache[rel] = read_lines(full)
            stats['files'] += 1
            raw_rules(rel, lines, root, add)
            if rel.endswith('.md'):
                inline_rules(rel, lines, add)
                blocks = [(lang, numbered, False) for lang, numbered in md_blocks(lines)]
                origin = 'md'
            elif rel.endswith('.sh'):
                blocks = [('', list(enumerate(lines, 1)), True)]    # no tag: a script is shell
                origin = 'sh'
            else:
                continue
            for lang, numbered, skip in blocks:
                units, heredocs = build_units(rel, origin, numbered, skip, is_shell_fence(lang))
                stats['fenced' if origin == 'md' else 'script'] += len(units)
                for u in units:
                    for rid, fn in UNIT_RULES:
                        for pos, detail in fn(u):
                            add(rid, rel, u.line_at(pos), detail)
                    for pos, detail in r7_unit(u):
                        add(7, rel, u.line_at(pos), detail)
                if rel != RESTORE_SH:
                    bodies = [hd['lines'] for hd in heredocs if hd['sql']]
                    if lang in SQL_LANGS:
                        bodies.append(numbered)
                    for body in bodies:
                        text = '\n'.join(t for _ln, t in body)
                        for off, verb in sql_writes(text):
                            add(7, rel, body[text.count('\n', 0, off)][0], 'SQL %s in SQL handed to mysql or mariadb' % verb)
    hits.sort(key=lambda h: (h[0], h[1], h[2]))
    return hits, stats


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------
def clip(text, width=150):
    text = text.strip()
    return text if len(text) <= width else text[:width - 3] + '...'


def report_scan(root, shown):
    hits, stats = scan(root)
    passed = failed = 0
    print('  corpus: %d files, %d fenced lines, %d script lines' % (stats['files'], stats['fenced'], stats['script']))
    if stats['script'] == 0:
        print('  FAIL the scan found no script lines in %s, so it is broken' % shown)
        failed += 1
    for rid in sorted(RULES):
        title, fix = RULES[rid]
        mine = [h for h in hits if h[0] == rid]
        if not mine:
            print('  ok   rule %d (%s): no hits' % (rid, title))
            passed += 1
            continue
        print('  FAIL rule %d (%s): %d hit(s)' % (rid, title, len(mine)))
        failed += 1
        last = None
        for _r, rel, ln, detail, text in mine:
            if last is not None and last != (rel, ln):
                print('       |     %s' % clip(last_text))
            print('       | %s/%s:%d: %s' % (shown, rel, ln, detail))
            last, last_text = (rel, ln), text
        print('       |     %s' % clip(last_text))
        for row in textwrap.wrap(fix, 100, initial_indent='How to fix: ', subsequent_indent='    '):
            print('       | %s' % row)
    print('#counts %d %d' % (passed, failed))


def verify(root, manifest, shown):
    hits, _stats = scan(root)
    rows = []
    with open(manifest, encoding='utf-8') as f:
        for line in f:
            file, first, last, rules, label = line.rstrip('\n').split('\t')
            rows.append((file, int(first), int(last), set() if rules == '-' else set(int(r) for r in rules.split(',')), label))
    groups = dict((rid, []) for rid in RULES)
    groups['good'] = []
    for file, first, last, expect, label in rows:
        inside = [h for h in hits if h[1] == file and first <= h[2] <= last]
        got = set(h[0] for h in inside)
        for rid in (sorted(expect) if expect else ['good']):
            groups[rid].append((file, first, expect, got, label, inside))
    passed = failed = 0
    for key in list(sorted(RULES)) + ['good']:
        entries = groups[key]
        title = 'good lines' if key == 'good' else 'rule %d (%s)' % (key, RULES[key][0])
        wrong = [e for e in entries if e[2] != e[3]]
        if not entries:
            print('  FAIL self-check, %s: the fixture has no entry for it' % title)
            failed += 1
        elif wrong:
            print('  FAIL self-check, %s: %d of %d entries came out wrong' % (title, len(wrong), len(entries)))
            for file, first, expect, got, label, inside in wrong:
                print('       | %s/%s:%d: expected %s, got %s' % (shown, file, first, sorted(expect) or 'no rule', sorted(got) or 'no rule'))
                print('       |     %s' % clip(label))
                for rule, _rel, ln, detail, _text in inside:
                    print('       |     rule %d at line %d: %s' % (rule, ln, detail))
            failed += 1
        else:
            what = 'lines that no rule may report' if key == 'good' else 'bad lines, each reported by exactly the rules it names'
            print('  ok   self-check, %s: %d %s' % (title, len(entries), what))
            passed += 1
    # a hit outside every entry would be a hit on the fixture's own scaffolding
    covered = set()
    for file, first, last, _e, _l in rows:
        for ln in range(first, last + 1):
            covered.add((file, ln))
    stray = [h for h in hits if (h[1], h[2]) not in covered]
    if stray:
        print('  FAIL self-check, scaffolding: %d hit(s) outside every fixture entry' % len(stray))
        for rule, rel, ln, detail, _text in stray:
            print('       | %s/%s:%d: rule %d, %s' % (shown, rel, ln, rule, detail))
        failed += 1
    else:
        print('  ok   self-check, scaffolding: no hit outside the fixture entries')
        passed += 1
    print('#counts %d %d' % (passed, failed))


def main(argv):
    if len(argv) == 5 and argv[1] == 'verify':
        verify(argv[2], argv[3], argv[4])
    elif len(argv) == 4 and argv[1] == 'scan':
        report_scan(argv[2], argv[3])
    else:
        print('usage: checker.py verify ROOT MANIFEST SHOWN | scan ROOT SHOWN', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
PY

# ---------------------------------------------------------------------------
# 3. Run
# ---------------------------------------------------------------------------
# run_checker MODE ARGS...: runs the checker, prints its lines and adds its counts
run_checker() {
  local out rc counts p f
  out="$(python3 -I -B "${work}/checker.py" "$@" 2> "${work}/checker.err")"
  rc=$?
  if [ "${rc}" -ne 0 ] || [ -s "${work}/checker.err" ]; then
    bad "the checker (${1}) failed to run (exit ${rc})" "$(cat "${work}/checker.err")"
  fi
  printf '%s\n' "${out}" | grep -v '^#counts '
  counts="$(printf '%s\n' "${out}" | sed -n 's/^#counts //p')"
  if [ -n "${counts}" ]; then
    read -r p f <<< "${counts}"
    pass=$((pass + p))
    fail=$((fail + f))
  fi
}

section "Self-check: the rules against a fixture of known bad and good lines"
run_checker verify "${fx_plugin}" "${fx_manifest}" fixture

section "The plugin: the same rules against plugins/nextcloud"
run_checker scan "${plugin}" plugins/nextcloud

echo
echo "nextcloud-skill-commands: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
