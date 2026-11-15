#!/usr/bin/env bash
# SuiteCRM skill: sql-read.sh
#
# Answers a question about the data with one read-only SELECT: pipeline totals, counts, lists. It is the only
# way this skill sends SQL, and it only reads. Changes go through records.sh, users.sh and import-csv.sh, which
# use SuiteCRM's own code.
#
# Usage: sql-read.sh [--table] [--max-rows N] 'SELECT ...'
#        sql-read.sh [--table] [--max-rows N] < query.sql
#
#   --table       print a table with borders. Without it the rows are tab-separated, with a header row.
#   --max-rows N  the most rows a query without its own LIMIT returns (default 200, at most 5000).
#
# Output. The rows on stdout, with a header row first, also when the query finds no row. NULL is printed as
# NULL, and a tab, a line break, a backslash and a NUL byte inside a value as \t, \n, \\ and \0, in both forms.
# At most 5000 rows are printed, whatever LIMIT the query has. When the answer stops at --max-rows or at 5000
# rows, a line on stderr says so: such an answer may be cut, so count and sum in the query itself.
#
# How it runs. This script checks its options and hands the query, on stdin, to remote/sqlread.php, which
# run-in-suitecrm.sh starts inside the SuiteCRM container as the web server's user. That script connects with
# the database settings SuiteCRM itself uses, so the agent needs no database setting, password or client.
#
# The database's own account can write, so the reading is enforced. It is enforced by how the query is run,
# and the server does the refusing, whatever the query's text says:
#   1. One statement. It goes to the server through PHP's mysqli, which sends one statement and has none of
#      the mysql client's commands (\g, \., \!). The server answers a second statement with a syntax error.
#   2. A read-only transaction. The server itself refuses every write, CREATE, DROP and FOR UPDATE.
#   3. Tables that are refused whole. For this one connection each of them is replaced by a table that cannot
#      be opened: tracker (it has session ids), config, user_preferences, emails_text, messenger_messages,
#      eapm, calendar_accounts, users_password_link, the OAuth tables (oauth2tokens, oauth2authcodes,
#      oauth_tokens, oauth_consumer, oauth_nonce, external_oauth_connections, external_oauth_providers), the
#      audit tables of these, every view, and any table whose name is shaped like a secret's (see 5).
#   4. The four tables that mix data and secrets: users, outbound_email, inbound_email, oauth2clients. Each is
#      replaced by a copy of its rows without the secret columns (user_hash, totp_secret, backup_codes,
#      authenticate_id, mail_smtppass, email_password, stored_options, secret). A query cannot name those
#      columns in any place, and a select-all (*) on one of the four is refused with the list of columns that
#      can be read.
#   5. Columns shaped like a secret, in any other table (a package's, or a later version's): a name with
#      secret, token, password or passwd in it, or that ends in _hash or _key. system_generated_password is
#      allowed. The query is first planned against empty stand-ins of those tables that lack such columns, so
#      naming one is an unknown column and is refused. So is a * that takes one in. A query that the database
#      rejects on the stand-ins and accepts on the real tables is refused whatever the error was, so an index
#      hint (USE INDEX, FORCE INDEX) on such a table is refused too: a stand-in has no indexes. In SuiteCRM
#      8.10.2 this covers email_addresses.confirm_opt_in_token and meetings.password, and also the tracker_key
#      and other _key columns of campaigns, campaign_log, campaign_trkrs, prospects and relationships.
#   6. The statement has to return rows, which the server says before it runs. So INTO OUTFILE and INTO a
#      variable are refused.
#   7. Only SuiteCRM's own database. A plan that reads a table of information_schema is refused. The
#      database's account has no right to any other database (mysql, performance_schema, sys, another
#      application's), and if it ever has, this script does not run (exit 1).
#   8. A statement is stopped after 30 seconds by the server, also when this script was killed in the
#      meantime: the connection then ends and the private copies go with it. A query cannot lift that limit:
#      one with MAX_EXECUTION_TIME or max_statement_time in it is refused. As a second line this skill stops
#      waiting after 35 seconds and ends the statement itself. The query is planned twice before it runs,
#      each time under that limit.
#   9. Nothing is held while the answer is printed. The transaction ends and the connection closes first, so
#      a reader that stalls on a large answer keeps no lock on a table.
# On top of that there is an extra net, which reads the server's own account of the query (its plan note and
# its optimizer trace, never the query's text). It refuses the same names again, the label of a column of the
# answer when it is shaped like a secret, LOAD_FILE, SLEEP, BENCHMARK and the lock functions, LOCK IN SHARE
# MODE, a variable that is set (:=) and a text value with a character set in front of it (_utf8mb4'...').
# Three rules read the query itself, each for single words and never for SQL. They do not care whether the
# words stand in a text value, so no quoting can hide them:
#   - a backtick may only stand around a plain name (`name`: letters, digits, _ and $), and nowhere else in
#     the query. The net needs that to hold;
#   - no MAX_EXECUTION_TIME and no max_statement_time (point 8);
#   - no LOCK IN SHARE MODE, and no comment that the database runs as SQL (/*! ... */). The database does
#     not write a subquery's lock clause into its own account of the query, and a read-only transaction
#     allows it, so it would take row locks that a save in SuiteCRM waits for.
# What is guaranteed is points 1 to 9. The net reads text, so it guarantees nothing by itself. It is what
# stands between a secret-shaped column and a * in the few places where the number of columns does not count
# (inside a subquery that only sorts or counts), and between such a column and a stored function, which
# SuiteCRM does not have.
# Comments in a query are fine, except the kind the database runs as SQL. Text inside quotes is fine unless
# it has a backtick, the words of a time limit or "share mode" in it.
# A refusal names the rule that was broken. The database's own message is shown for a query it rejects,
# unless that message could quote a row the rules above would refuse: then only the error number is shown.
#
# Rules for a correct read (reference/data-model.md has more):
#   - every module table has a deleted column: filter deleted = 0, on link tables too;
#   - custom fields are in <table>_cstm, joined on id_c;
#   - opportunities.amount_usdollar is the amount in the base currency, and probability is a percentage;
#   - dates are stored in UTC.
#
# Env vars read: SUITECRM_HOST (through run-in-suitecrm.sh, which also loads the ops password).
#
# Exit codes: 0 answered; 64 usage, or the query was refused; 1 a setting or the ops password is missing,
# SuiteCRM's own database settings could not be read, the database could not be reached, it cannot give what
# the checks need, or its account can read more than SuiteCRM's database; 2 the database rejected the query,
# or the query ran too long and was stopped; 70 the script could not start in the container, or stopped on an
# error of its own; 75 SuiteCRM is being installed or upgraded; 255 ssh failed.

set -uo pipefail
set +x

usage() {
    cat <<'USAGE'
Usage: sql-read.sh [--table] [--max-rows N] 'SELECT ...'
       sql-read.sh [--table] [--max-rows N] < query.sql

Runs one read-only SELECT on SuiteCRM's database and prints the rows, tab-separated with a header row
(--table: with borders). At most 200 rows unless the query has its own LIMIT or --max-rows says otherwise,
and never more than 5000. A line on stderr says when the answer stops at a limit.

It runs one statement, inside a read-only transaction, for 30 seconds at most. Refused: anything that is not
one SELECT that returns rows; the tables that hold sessions, tokens, stored passwords or settings with
secrets (tracker, config, user_preferences, emails_text, the OAuth tables and others) and every view; the
password, hash, token and secret columns of users, outbound_email, inbound_email and oauth2clients, and * on
those four; any column or table whose name has secret, token, password or passwd in it or ends in _hash or
_key, and an index hint on a table that has such a column; information_schema; SLEEP, LOAD_FILE and locks
(LOCK IN SHARE MODE and the words "share mode" anywhere); a time limit of its own (MAX_EXECUTION_TIME); a
/*! ... */ comment. Filter deleted = 0 on every module and link table.

Exit codes: 0 answered; 64 usage or refused; 1 a missing setting, or the database could not be reached;
2 the database rejected the query; 70 the script could not start or stopped; 75 SuiteCRM is being installed
or upgraded; 255 ssh failed.
USAGE
}

msg() { printf '[suitecrm/sql-read] %s\n' "$*" >&2; }

format=tsv
max_rows=200
sql=''
have_sql=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        --table) format=table; shift ;;
        --max-rows)
            [[ ${2:-} =~ ^[0123456789]{1,4}$ ]] && [ "$((10#$2))" -ge 1 ] && [ "$((10#$2))" -le 5000 ] || { msg "--max-rows needs a number from 1 to 5000"; exit 64; }
            max_rows="$((10#$2))"
            shift 2
            ;;
        --) shift; [ "$#" -le 1 ] || { msg "give the query as one argument"; exit 64; }; if [ "$#" -eq 1 ]; then sql="$1"; have_sql=1; shift; fi ;;
        -*) msg "unknown option: $1"; usage >&2; exit 64 ;;
        *)
            [ "${have_sql}" -eq 0 ] || { msg "give the query as one argument, in quotes"; exit 64; }
            sql="$1"
            have_sql=1
            shift
            ;;
    esac
done
if [ "${have_sql}" -eq 0 ]; then
    if [ -t 0 ]; then msg "no query given"; usage >&2; exit 64; fi
    sql="$(cat)"
fi

# Trim, and drop one closing semicolon. Nothing else about the query is decided here.
sql="${sql#"${sql%%[![:space:]]*}"}"
sql="${sql%"${sql##*[![:space:]]}"}"
sql="${sql%;}"
sql="${sql%"${sql##*[![:space:]]}"}"
[ -n "${sql}" ] || { msg "no query given"; exit 64; }
if [ "${#sql}" -gt 20000 ]; then
    msg "refused: the query is longer than 20,000 characters. Nothing was run."
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The runner says so when its php form is used by hand; this tells it who is calling.
export SC_SKILL_CALLER=sql-read.sh
# The query goes in on stdin: printf is a builtin, so it is in no command line on either side.
printf '%s' "${sql}" | "${script_dir}/run-in-suitecrm.sh" --stdin php sqlread.php "${max_rows}" "${format}"
exit "${PIPESTATUS[1]}"
