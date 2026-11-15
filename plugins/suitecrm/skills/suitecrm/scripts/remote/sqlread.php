<?php
/**
 * SuiteCRM skill: remote/sqlread.php (runs inside the SuiteCRM container as www-data; sql-read.sh sends it)
 *
 * Runs one read-only query on SuiteCRM's database and prints its rows. It does not start SuiteCRM: it reads
 * the database settings from SuiteCRM's config.php and connects with mysqli, as SuiteCRM does. The database's
 * own account can write, so the reading is enforced here. sql-read.sh's header says what a user needs to
 * know. This is how it is done.
 *
 * What holds whatever the query's text says, because the server enforces it:
 *   - One statement. mysqli::query and mysqli::prepare send one statement; the server answers a second one
 *     with a syntax error. There is no client program, so \g, \. and \! mean nothing.
 *   - Private copies, made before anything else. A temporary table hides the real table of the same name for
 *     this connection only. Each table that holds only secrets or sessions, each view, and each table whose
 *     name or whose every column is shaped like a secret gets one that cannot be opened (a MERGE table over a
 *     table that is not there: error 1168). Each table that mixes data and secrets (users, outbound_email,
 *     inbound_email, oauth2clients) gets a copy of its rows with the columns on a safe list only, so a hidden
 *     column is an unknown column to the server, in every clause.
 *   - A first pass over empty stand-ins. Any other table with a column whose name is shaped like a secret (a
 *     package's, or a later version's) gets an empty stand-in without those columns, the query is planned
 *     once against the stand-ins, and they are dropped again. A query that the server rejects there and
 *     accepts on the real tables is refused, whatever the error was: it names such a column, or its number
 *     of columns changes with the stand-ins (a * in a UNION, a comparison or a derived table's column list).
 *     A stand-in has no indexes, so an index hint on such a table is refused as well: the server reports the
 *     missing index before the unknown column, and one error must not hide the other. The real tables are
 *     read only after that.
 *   - A read-only transaction, with the session set read-only as well. The server refuses every write to a
 *     real table, every CREATE, DROP and FOR UPDATE (error 1792).
 *   - The statement has to return rows. A prepare says so before it runs, so SELECT ... INTO OUTFILE, INTO a
 *     variable, and every statement that only writes end there. (The server lets a read-only transaction
 *     write to a temporary table, so this is also what keeps a statement from changing the private copies.)
 *   - The plan. A table of the server's own information_schema is the only kind that has no row estimate
 *     in EXPLAIN's rows, and a plan with one is refused. And the script does not run at all when the
 *     database account can read any database besides SuiteCRM's own (mysql, sys, performance_schema, or
 *     another application's).
 *   - The result's metadata. Each column's schema, table and column name are checked before a row is read.
 *   - Time and size. The server stops a statement after 30 seconds, also when this script was killed in the
 *     meantime: the connection then ends, and the private copies go with it. Only a hint in the query
 *     (MAX_EXECUTION_TIME) can lift that limit, and a query that has those words in it is refused (see the
 *     rules that read the query's text, below). As a second line this script stops waiting after 35 seconds
 *     and then ends the statement from a second connection (KILL). At most 5000 rows and 32 MB are printed.
 *   - Nothing is held while the answer is printed. The rows are fetched, the transaction ends and the
 *     connection closes, and only then is anything written: a reader that stalls holds no lock on a table.
 *
 * An extra net, from the server's own text and never from the query's. An EXPLAIN EXTENDED of the query gives
 * two texts: the server's note 1003 (the statement as planned, every table with its schema) and the optimizer
 * trace's "expanded_query" of each SELECT in it (as read before planning: * written out, each column under
 * its real name, also for a row the planner already fetched by its key). Both are split into names and words,
 * and the query is refused when one of them is a server schema, a refused table, a hidden column, a name
 * shaped like a secret, a stored function of this database, a waiting or locking function, or a lock clause.
 * This is what catches a * on a table with a secret-shaped column where the number of columns does not
 * matter (inside a subquery that only sorts or counts), and a stored function that reads such a column. It
 * reads text, and the server writes three things into that text without quoting them: a text value with a
 * character set in front (_utf8mb4'...'), the name of a variable that is set (@x:=...), and the name of a
 * WITH table. The first two are refused on sight. For the third, the query's own text may have a backtick
 * only around a plain name, so that no name can hold a quote. Because it reads text, this part guarantees
 * nothing by itself.
 *
 * Three rules read the query's own text, each for single words and never for SQL, because the server's text
 * cannot show what they look for. They do not care whether the words stand in a text value, so no quoting can
 * hide them, and a query that only mentions them in a value is refused too:
 *   - a backtick stands only around a plain name (above);
 *   - no MAX_EXECUTION_TIME or max_statement_time: the 30 seconds hold for every query;
 *   - no LOCK IN SHARE MODE, and no comment that the server runs as SQL. The server writes the lock clause
 *     of a subquery into neither the note nor the trace, and a read-only transaction allows it: it takes
 *     row locks that a save in SuiteCRM then waits for. The rule looks for SHARE and MODE with nothing but
 *     space and comments between them.
 *
 * The database's message for a rejected query is printed only when it cannot hold data that the checks above
 * would have refused: after the trace was read whole and found clean, or for an error about the query's
 * names and syntax. Otherwise only the error number is printed.
 *
 * Usage: sqlread.php MAX_ROWS table|tsv        the query on stdin
 *
 * Exit codes: 0 answered; 64 usage, or the query was refused; 1 SuiteCRM's settings could not be read, the
 * database could not be reached, or it cannot give what the checks need (private copies, a time limit, the
 * optimizer trace, a read-only transaction); 2 the database rejected the query, or it ran too long;
 * 70 this script stopped on an error of its own.
 */

if (PHP_SAPI !== 'cli') {
    exit(1);
}

const SR_TAG = '[suitecrm/sql-read] ';
const SR_MAX_ROWS = 5000;
const SR_MAX_QUERY = 20000;
const SR_MAX_BYTES = 33554432;
const SR_SECONDS = 30;
const SR_WAIT = 35;
const SR_MARKER = 'clv_name_your_columns';
const SR_SCHEMAS = ['information_schema', 'performance_schema', 'mysql', 'sys'];
const SR_FUNCTIONS = ['sleep', 'benchmark', 'get_lock', 'release_lock', 'release_all_locks', 'is_free_lock', 'is_used_lock',
    'master_pos_wait', 'master_gtid_wait', 'load_file'];

// Tables that hold only secrets, sessions or settings with secrets in them: refused whole, when they exist.
// tracker has each signed-in user's session id; tracker_sessions, tracker_perf and tracker_queries are its
// siblings in older versions. emails_text has the "new account" email with its generated password.
// sessions and rememberme_token are the names Symfony gives its own session and sign-in tables, should a
// later version keep them in the database. The audit table of each of these, and of the four mixed tables
// below, is refused too (<table>_audit holds the values before and after a change).
const SR_REFUSED_TABLES = ['tracker', 'tracker_sessions', 'tracker_perf', 'tracker_queries', 'oauth2tokens', 'oauth2authcodes',
    'oauth_tokens', 'oauth_consumer', 'oauth_nonce', 'external_oauth_connections', 'external_oauth_providers', 'eapm',
    'calendar_accounts', 'users_password_link', 'config', 'user_preferences', 'outbound_email_audit', 'emails_text',
    'messenger_messages', 'sessions', 'rememberme_token'];

// Tables that mix data and secrets: the columns that can be read. A list of what is allowed, so that a column
// a later version adds stays hidden until someone adds it here. Hidden today: users.user_hash, totp_secret,
// backup_codes and authenticate_id; outbound_email.mail_smtppass; inbound_email.email_password and
// stored_options; oauth2clients.secret.
const SR_MIXED_TABLES = [
    'users' => ['id', 'user_name', 'system_generated_password', 'pwd_last_changed', 'sugar_login', 'first_name', 'last_name',
        'is_admin', 'external_auth_only', 'receive_notifications', 'description', 'date_entered', 'date_modified',
        'modified_user_id', 'created_by', 'title', 'photo', 'department', 'phone_home', 'phone_mobile', 'phone_work',
        'phone_other', 'phone_fax', 'status', 'address_street', 'address_city', 'address_state', 'address_country',
        'address_postalcode', 'deleted', 'portal_only', 'show_on_employees', 'employee_status', 'messenger_id',
        'messenger_type', 'reports_to_id', 'is_group', 'factor_auth', 'factor_auth_interface', 'is_totp_enabled'],
    'outbound_email' => ['id', 'name', 'type', 'user_id', 'is_personal', 'smtp_from_name', 'smtp_from_addr', 'reply_to_name',
        'reply_to_addr', 'signature', 'mail_sendtype', 'mail_smtptype', 'mail_smtpserver', 'mail_smtpport', 'mail_smtpuser',
        'mail_smtpauth_req', 'mail_smtpssl', 'date_entered', 'date_modified', 'modified_user_id', 'created_by', 'deleted',
        'assigned_user_id', 'auth_type', 'external_oauth_connection_id'],
    'inbound_email' => ['id', 'deleted', 'date_entered', 'date_modified', 'last_import_run_datetime',
        'mailbox_last_imported_days', 'email_import_per_run_threshold', 'email_import_timeframe_start',
        'email_import_unread_only', 'modified_user_id', 'created_by', 'name', 'status', 'email_body_filtering', 'server_url',
        'connection_string', 'email_user', 'port', 'service', 'mailbox', 'primary_folder', 'sentFolder', 'trashFolder',
        'delete_seen', 'move_messages_to_trash_after_import', 'mailbox_type', 'template_id', 'group_id', 'is_personal',
        'groupfolder_id', 'type', 'auth_type', 'protocol', 'is_ssl', 'distribution_user_id', 'outbound_email_id',
        'create_case_template_id', 'external_oauth_connection_id'],
    'oauth2clients' => ['id', 'name', 'date_entered', 'date_modified', 'modified_user_id', 'created_by', 'description',
        'deleted', 'redirect_url', 'is_confidential', 'allowed_grant_type', 'duration_value', 'duration_amount',
        'duration_unit', 'assigned_user_id'],
];
// The hidden columns' names, refused wherever the server's text or the result's metadata shows one.
const SR_HIDDEN_COLUMNS = ['user_hash', 'totp_secret', 'backup_codes', 'authenticate_id', 'mail_smtppass', 'email_password',
    'stored_options', 'secret'];

// Errors about the query's names and syntax. Their messages quote the query, never a row.
const SR_PLAIN_ERRORS = [1044, 1046, 1049, 1051, 1052, 1054, 1055, 1056, 1057, 1059, 1060, 1064, 1066, 1102, 1103, 1109, 1111,
    1140, 1142, 1143, 1146, 1166, 1210, 1222, 1235, 1241, 1242, 1247, 1248, 1250, 1267, 1270, 1271, 1305, 1318, 1356, 1370,
    1463, 1582, 1630];

/** Prints a line on stderr. */
function sr_say(string $message): void
{
    fwrite(STDERR, SR_TAG . $message . "\n");
}

/** Prints a line on stderr and ends with the code. */
function sr_end(int $code, string $message): void
{
    sr_say($message);
    exit($code);
}

/** Ends with 64: the query was refused. */
function sr_refuse(string $why, string $tail = 'Nothing was run.'): void
{
    sr_end(64, "refused: $why $tail");
}

// Nothing PHP itself prints may carry a value from the database: a warning or an uncaught error names its
// line and nothing else.
ini_set('zend.exception_ignore_args', '1');
error_reporting(E_ALL);
set_error_handler(static function (int $level, string $text, string $file, int $line): bool {
    if (!(error_reporting() & $level) || ($level & (E_DEPRECATED | E_USER_DEPRECATED))) {
        return true;
    }
    sr_say("sqlread.php: a PHP warning at line $line");
    return true;
});
set_exception_handler(static function (Throwable $e): void {
    sr_end(70, 'sqlread.php stopped on an error of its own (' . get_class($e) . ' at line ' . $e->getLine() . '). Nothing was printed.');
});

// config.php belongs to the web user, so root never includes it.
if (function_exists('posix_geteuid') && posix_geteuid() === 0) {
    sr_end(64, "this script runs as www-data, the web server's user, not as root. Use sql-read.sh, which starts it that way. Nothing was run.");
}

/** A name in lower case, with the letters MariaDB reads as s and i (the long s, the dotless and dotted i). */
function sr_fold(string $name): string
{
    $name = str_replace(["\u{017F}", "\u{0131}", "\u{0130}", "\u{0307}"], ['s', 'i', 'i', ''], $name);
    if (function_exists('mb_strtolower') && mb_check_encoding($name, 'UTF-8')) {
        return mb_strtolower($name, 'UTF-8');
    }
    return strtolower($name);
}

/** True when a name is a hidden column's or is shaped like a secret's. */
function sr_secret_name(string $folded): bool
{
    return in_array($folded, SR_HIDDEN_COLUMNS, true) || sr_secret_shape($folded);
}

/** True when a name is shaped like a secret's: the rule for columns of packages and later versions. */
function sr_secret_shape(string $folded): bool
{
    if ($folded === 'system_generated_password' || $folded === 'pwd_last_changed') {
        return false;
    }
    return (bool) preg_match('/secret|token|password|passwd|_hash$|_key$/', $folded);
}

/** The database's message as a sentence: with a full stop at its end. */
function sr_sentence(string $message): string
{
    $message = rtrim($message);
    return preg_match('/[.!?]$/', $message) ? $message : $message . '.';
}

/** A name for a message: itself when it is a plain word, otherwise nothing. */
function sr_plain(string $name): string
{
    return preg_match('/^[A-Za-z0-9_$]{1,64}$/', $name) ? $name : '';
}

/** A name in backticks, for a statement. */
function sr_ident(string $name): string
{
    return '`' . str_replace('`', '``', $name) . '`';
}

/**
 * Splits a statement, as the server wrote it, into its names (in backticks) and its bare words, in order.
 * Text in quotes and comments are skipped. Returns null when a quote, a name or a comment never closes.
 * The server writes a quote inside a name as `` and inside a text as \' (the session's sql_mode is set so).
 *
 * @return array<int, array{0: string, 1: string}>|null each ['name'|'word', text]
 */
function sr_scan(string $sql): ?array
{
    $tokens = [];
    $n = strlen($sql);
    $i = 0;
    while ($i < $n) {
        $c = $sql[$i];
        if ($c === '`') {
            $name = '';
            $i++;
            while (true) {
                if ($i >= $n) {
                    return null;
                }
                if ($sql[$i] === '`') {
                    if ($i + 1 < $n && $sql[$i + 1] === '`') {
                        $name .= '`';
                        $i += 2;
                        continue;
                    }
                    $i++;
                    break;
                }
                $name .= $sql[$i++];
            }
            $tokens[] = ['name', $name];
        } elseif ($c === "'" || $c === '"') {
            $i++;
            while (true) {
                if ($i >= $n) {
                    return null;
                }
                if ($sql[$i] === '\\') {
                    $i += 2;
                    continue;
                }
                if ($sql[$i] === $c) {
                    if ($i + 1 < $n && $sql[$i + 1] === $c) {
                        $i += 2;
                        continue;
                    }
                    $i++;
                    break;
                }
                $i++;
            }
        } elseif ($c === '/' && $i + 1 < $n && $sql[$i + 1] === '*') {
            $end = strpos($sql, '*/', $i + 2);
            if ($end === false) {
                return null;
            }
            $i = $end + 2;
        } elseif (preg_match('/\G[A-Za-z0-9_$\x80-\xff]+/', $sql, $m, 0, $i)) {
            $tokens[] = ['word', $m[0]];
            $i += strlen($m[0]);
        } else {
            $i++;
        }
    }
    return $tokens;
}

/** The database's last error: [number, message, SQLSTATE]. */
function sr_failure(mysqli $db): array
{
    return [(int) $db->errno, (string) $db->error, (string) $db->sqlstate];
}

/** Runs one of this script's own statements. Returns its rows, [] when it returns none, null when it failed. */
function sr_rows(mysqli $db, string $sql): ?array
{
    $result = $db->query($sql);
    if ($result === false) {
        return null;
    }
    if ($result === true) {
        return [];
    }
    $rows = $result->fetch_all(MYSQLI_NUM);
    $result->free();
    return $rows;
}

/** SuiteCRM's database settings, from its own config files. */
function sr_dbconfig(): array
{
    $dir = '/var/www/html/public/legacy';
    if (!is_file("$dir/config.php")) {
        sr_end(1, 'SuiteCRM is not installed in /var/www/html: there is no config.php to take the database settings from.');
    }
    if (!defined('sugarEntry')) {
        define('sugarEntry', true);
    }
    $sugar_config = [];
    ob_start();
    try {
        include "$dir/config.php";
        if (is_file("$dir/config_override.php")) {
            include "$dir/config_override.php";
        }
    } catch (Throwable $e) {
        ob_end_clean();
        sr_end(1, "SuiteCRM's config.php could not be read (" . get_class($e) . ').');
    }
    ob_end_clean();
    $config = is_array($sugar_config) ? ($sugar_config['dbconfig'] ?? null) : null;
    if (!is_array($config) || empty($config['db_host_name']) || empty($config['db_user_name']) || empty($config['db_name'])) {
        sr_end(1, "SuiteCRM's config.php has no database settings (dbconfig).");
    }
    if (($config['db_type'] ?? 'mysql') !== 'mysql') {
        sr_end(1, 'this script reads a MySQL or MariaDB database, and SuiteCRM is set up for another kind.');
    }
    return $config;
}

/** Opens a connection with SuiteCRM's settings, as SuiteCRM does. Returns null when it can't. */
function sr_open(array $config, int $wait): ?mysqli
{
    $host = (string) $config['db_host_name'];
    $port = (int) ($config['db_port'] ?? 0);
    $colon = strpos($host, ':');
    if ($colon !== false) {
        $port = (int) substr($host, $colon + 1);
        $host = substr($host, 0, $colon);
    }
    $db = mysqli_init();
    $db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 10);
    // This script's own time limit: no answer for this long ends the wait (error 2006).
    $db->options(MYSQLI_OPT_READ_TIMEOUT, $wait);
    if (!@$db->real_connect($host, (string) $config['db_user_name'], (string) ($config['db_password'] ?? ''), (string) $config['db_name'], $port ?: 3306)) {
        return null;
    }
    return $db;
}

/**
 * Connects and sets the session up: known quoting rules, a statement time limit, notes on. Returns the
 * connection and the pattern that finds a text value with a character set in front of it.
 */
function sr_connect(array $config): array
{
    if (!function_exists('mysqli_init')) {
        sr_end(1, "PHP's mysqli extension is not there.");
    }
    mysqli_report(MYSQLI_REPORT_OFF);
    $db = sr_open($config, SR_WAIT);
    if ($db === null) {
        sr_end(1, "the database could not be reached with SuiteCRM's own settings: " . sr_sentence((string) mysqli_connect_error()));
    }
    $GLOBALS['sr_link'] = [$config, (int) $db->thread_id];
    if (!$db->set_charset('utf8mb4')) {
        sr_end(1, 'the database connection could not be set to utf8mb4.');
    }
    // The scanner knows one set of quoting rules: " starts a text and \ escapes inside one.
    $mode = sr_rows($db, 'SELECT @@SESSION.sql_mode');
    if ($mode === null) {
        sr_end(1, "the database did not give its session's sql_mode.");
    }
    $drop = ['ANSI_QUOTES', 'NO_BACKSLASH_ESCAPES', 'ANSI', 'DB2', 'MAXDB', 'MSSQL', 'ORACLE', 'POSTGRESQL'];
    $modes = array_filter(explode(',', (string) $mode[0][0]), static fn ($m) => $m !== '');
    $kept = array_filter($modes, static fn ($m) => !in_array(strtoupper($m), $drop, true));
    if (count($kept) !== count($modes)) {
        sr_rows($db, "SET SESSION sql_mode = '" . $db->real_escape_string(implode(',', $kept)) . "'");
        $mode = sr_rows($db, 'SELECT @@SESSION.sql_mode');
        if ($mode === null || preg_match('/ANSI_QUOTES|NO_BACKSLASH_ESCAPES/i', (string) $mode[0][0])) {
            sr_end(1, "the session's sql_mode could not be set to the quoting rules this script checks with. Nothing was run.");
        }
    }
    if (sr_rows($db, 'SET SESSION max_statement_time = ' . SR_SECONDS) === null
        && sr_rows($db, 'SET SESSION max_execution_time = ' . (SR_SECONDS * 1000)) === null) {
        sr_end(1, 'this database cannot limit how long a statement runs, and a query is not run without that limit.');
    }
    // The private copies are made with CREATE ... AS SELECT, which locks the rows it reads unless the session
    // reads committed data: a save in SuiteCRM would wait for the copy, and the copy for a save. With this
    // level each statement still sees one consistent state of the data.
    if (sr_rows($db, 'SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED') === null) {
        sr_end(1, 'the database did not take the isolation level this script reads with (READ COMMITTED). Nothing was run.');
    }
    // The note this script reads is a warning of level Note: keep notes on, and room for the ones before it.
    sr_rows($db, 'SET SESSION sql_notes = 1');
    sr_rows($db, 'SET SESSION max_error_count = 1024');
    // The server writes _utf8mb4'it's' for a text value with a character set in front of it, quotes and all.
    // With the character sets' names the pattern finds exactly those; without them, any _word' counts.
    $introducer = "/_[A-Za-z0-9]+'/";
    $sets = sr_rows($db, 'SELECT character_set_name FROM information_schema.character_sets');
    if ($sets !== null && $sets !== []) {
        $names = array_map(static fn ($row) => preg_quote((string) $row[0], '/'), $sets);
        $introducer = '/_(?:' . implode('|', $names) . ")'/i";
    }
    return [$db, $introducer];
}

/** Ends the statement that is still running on the server, from a second connection. */
function sr_kill(): void
{
    [$config, $thread] = $GLOBALS['sr_link'] ?? [null, 0];
    if ($config === null || $thread === 0) {
        return;
    }
    $other = sr_open($config, 10);
    if ($other !== null) {
        $other->query('KILL ' . $thread);
        $other->close();
    }
}

/** Ends the run: the query ran longer than this script waits. */
function sr_too_long(): void
{
    sr_kill();
    sr_end(2, 'the query ran longer than ' . SR_SECONDS . ' seconds, the limit here, and was stopped. Narrow it (fewer rows, a condition on an indexed column) and run it again. Nothing was printed.');
}

/**
 * Makes the private copies. Returns:
 *   refused    [folded name => 'table'|'view']: cannot be opened in this connection
 *   mixed      [table => its readable columns]: a copy of the rows without the secret columns
 *   stand_ins  [table name => its readable columns]: the empty stand-ins for tables with a secret-shaped
 *              column, to drop after the first pass
 *   routines   [folded name => true]: the stored functions and procedures of SuiteCRM's database
 */
function sr_private_copies(mysqli $db): array
{
    $cannot = 'the private copies that hide passwords, tokens and sessions could not be made, and a query is not run without them';
    // The copies guard SuiteCRM's own database. An account that can read another one is not what this
    // script was built for, so it does not run with one.
    $schemas = sr_rows($db, "SELECT schema_name FROM information_schema.schemata WHERE schema_name <> DATABASE() AND LOWER(schema_name) <> 'information_schema'");
    if ($schemas === null) {
        sr_end(1, 'the database did not list the databases its account can read. Nothing was run.');
    }
    if ($schemas !== []) {
        $others = implode(', ', array_map(static fn ($row) => sr_plain((string) $row[0]) ?: '(a name with special characters)', $schemas));
        sr_end(1, "the database account can read more than SuiteCRM's own database (it also sees: $others). This script guards SuiteCRM's own database only, so it does not run. Nothing was run.");
    }
    $tables = sr_rows($db, 'SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = DATABASE()');
    $listed = sr_rows($db, 'SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = DATABASE() ORDER BY table_name, ordinal_position');
    if ($tables === null || $tables === [] || $listed === null) {
        sr_end(1, "the database did not list SuiteCRM's tables and columns. Nothing was run.");
    }
    $columns = [];
    foreach ($listed as [$table, $column]) {
        $columns[sr_fold((string) $table)][] = (string) $column;
    }
    $exists = [];
    $refuse = [];
    foreach ($tables as [$name, $type]) {
        $folded = sr_fold((string) $name);
        $exists[$folded] = (string) $name;
        if (stripos((string) $type, 'VIEW') !== false) {
            $refuse[$folded] = [(string) $name, 'view'];
        }
    }
    $withAudit = array_merge(SR_REFUSED_TABLES, array_map(static fn ($t) => $t . '_audit', SR_REFUSED_TABLES),
        array_map(static fn ($t) => $t . '_audit', array_keys(SR_MIXED_TABLES)));
    foreach ($withAudit as $table) {
        if (isset($exists[$table]) && !isset($refuse[$table])) {
            $refuse[$table] = [$exists[$table], 'table'];
        }
    }
    // The other tables: one whose name is shaped like a secret, or whose every column is, is refused whole.
    // One that has such a column among others gets an empty stand-in without it for the first pass.
    $standIns = [];
    foreach ($exists as $folded => $name) {
        if (isset($refuse[$folded]) || isset(SR_MIXED_TABLES[$folded])) {
            continue;
        }
        $all = $columns[$folded] ?? [];
        $plain = array_values(array_filter($all, static fn ($column) => !sr_secret_name(sr_fold($column))));
        if (sr_secret_shape($folded) || ($all !== [] && $plain === [])) {
            $refuse[$folded] = [$name, 'table'];
        } elseif (count($plain) !== count($all)) {
            $standIns[$name] = $plain;
        }
    }
    foreach ($refuse as [$name, $kind]) {
        $made = sr_rows($db, 'CREATE TEMPORARY TABLE ' . sr_ident($name) . ' (not_readable_here INT) ENGINE=MRG_MyISAM UNION=(clv_no_such_table)');
        // No MERGE engine: a plain empty table hides the real one too, and the checks of the server's text
        // and of the result's metadata refuse a query that names it.
        if ($made === null && sr_rows($db, 'CREATE TEMPORARY TABLE ' . sr_ident($name) . ' (not_readable_here INT)') === null) {
            sr_end(1, "$cannot (error {$db->errno} for " . (sr_plain($name) ?: 'a table') . '). Nothing was run.');
        }
    }
    $mixed = [];
    foreach (SR_MIXED_TABLES as $table => $safe) {
        if (!isset($exists[$table]) || isset($refuse[$table])) {
            continue;
        }
        $name = $exists[$table];
        $readable = array_values(array_filter($columns[$table] ?? [], static fn ($column) => in_array($column, $safe, true)));
        if ($readable === []) {
            sr_end(1, "$cannot ($table has none of the columns this script knows). Nothing was run.");
        }
        $key = in_array('id', $readable, true) ? ' (PRIMARY KEY (`id`))' : '';
        $copy = 'CREATE TEMPORARY TABLE ' . sr_ident($name) . $key . ' AS SELECT ' . implode(', ', array_map('sr_ident', $readable))
            . ', NULL AS ' . sr_ident(SR_MARKER) . ' FROM ' . sr_ident($name);
        if (sr_rows($db, $copy) === null) {
            sr_end(1, "$cannot (error {$db->errno} for $table). Nothing was run.");
        }
        $mixed[$table] = $readable;
    }
    foreach ($standIns as $name => $plain) {
        $standIn = 'CREATE TEMPORARY TABLE ' . sr_ident($name) . ' AS SELECT ' . implode(', ', array_map('sr_ident', $plain))
            . ' FROM ' . sr_ident($name) . ' LIMIT 0';
        if (sr_rows($db, $standIn) === null) {
            sr_end(1, "$cannot (error {$db->errno} for " . (sr_plain($name) ?: 'a table') . '). Nothing was run.');
        }
    }
    $refused = [];
    foreach ($refuse as $folded => [$name, $kind]) {
        $refused[$folded] = $kind;
    }
    // A stored function runs its own statements, which no check here sees. SuiteCRM has none.
    $routines = [];
    foreach (sr_rows($db, 'SELECT routine_name FROM information_schema.routines WHERE routine_schema = DATABASE()') ?? [] as [$routine]) {
        $routines[sr_fold((string) $routine)] = true;
    }
    return ['refused' => $refused, 'mixed' => $mixed, 'stand_ins' => $standIns, 'routines' => $routines];
}

/**
 * The first pass: plans the query against the stand-ins, where a secret-shaped column does not exist, and
 * drops them. Ends the run when the query names such a column. Returns the number of the error the server
 * met there, or 0. When the same query is then accepted on the real tables, that error can only come from
 * what the stand-ins lack: a secret-shaped column (named, or taken in by a *), or an index.
 */
function sr_first_pass(mysqli $db, string $query, array $rules): int
{
    if ($rules['stand_ins'] === []) {
        return 0;
    }
    if (sr_rows($db, 'START TRANSACTION READ ONLY') === null) {
        sr_end(1, 'the database did not start a read-only transaction, and a query is not run outside one. Nothing was run.');
    }
    $plan = $db->query('EXPLAIN ' . $query);
    $failure = $plan === false ? sr_failure($db) : [0, '', ''];
    if ($plan instanceof mysqli_result) {
        $plan->free();
    }
    if (in_array($failure[0], [2006, 2013], true)) {
        sr_too_long();
    }
    $dropped = sr_rows($db, 'ROLLBACK') !== null;
    foreach (array_keys($rules['stand_ins']) as $name) {
        $dropped = $dropped && sr_rows($db, 'DROP TEMPORARY TABLE ' . sr_ident($name)) !== null;
    }
    if (!$dropped) {
        sr_end(1, 'the stand-in tables of the first check could not be removed again, so the query was not run.');
    }
    if ($failure[0] === 1054 || $failure[0] === 1168) {
        // Ends the run when the unknown column is a secret's, or a refused table was named.
        sr_refuse_if_secret($failure, $rules);
    }
    if ($failure[0] === 1969 || $failure[0] === 3024) {
        sr_end(2, 'the database stopped the query after ' . SR_SECONDS . ' seconds, the limit here, while it was still being planned. Narrow it and run it again. Nothing was printed.');
    }
    return $failure[0];
}

/**
 * Why a query is refused that the server rejected on the stand-ins (with this error) and accepts on the real
 * tables. 1222: the SELECTs of a UNION differ in columns. 1241: an operand has the wrong number of columns.
 * 4002 and 4201: the column list of a WITH table or of a derived table does not fit its SELECT.
 */
function sr_first_pass_refusal(int $errno): string
{
    if (in_array($errno, [1222, 1241, 4002, 4201], true)) {
        return sr_star_refusal();
    }
    return 'the query works only with a column that is shaped like a secret (secret, token, password or passwd in its name, or _hash or _key '
        . "at its end): without those columns the database rejects it (error $errno). Name the columns you need, and use no index hint "
        . '(USE INDEX, FORCE INDEX) on a table that has such a column.';
}

/** Ends the run with a refusal when the failure is about a refused table (1168) or a secret's column (1054). */
function sr_refuse_if_secret(array $failure, array $rules): void
{
    [$errno, $error] = $failure;
    if ($errno === 1168) {
        $names = array_keys(array_filter($rules['refused'], static fn ($kind) => $kind === 'table'));
        sort($names);
        sr_refuse('the query reads a table or a view that is not read here. The tables that hold sign-in sessions, tokens, stored passwords '
            . 'or settings with secrets in them are refused whole (' . implode(', ', $names) . '), and so is every view.');
    }
    if ($errno === 1054 && preg_match("/^Unknown column '(.*)' in /s", $error, $m)) {
        $dot = strrpos($m[1], '.');
        $raw = $dot === false ? $m[1] : substr($m[1], $dot + 1);
        $name = sr_fold($raw);
        if (in_array($name, SR_HIDDEN_COLUMNS, true)) {
            sr_refuse(sr_column_refusal());
        }
        if (sr_secret_shape($name)) {
            sr_refuse(sr_shape_refusal($raw));
        }
    }
}

/**
 * The optimizer trace of the EXPLAIN that just ran: the "expanded_query" of every SELECT in the statement.
 * Returns ['whole' => true when the trace is this statement's and nothing is missing from it, 'queries' =>
 * the texts].
 */
function sr_trace(mysqli $db, string $statement): array
{
    $none = ['whole' => false, 'queries' => []];
    $rows = sr_rows($db, 'SELECT QUERY, TRACE, MISSING_BYTES_BEYOND_MAX_MEM_SIZE, INSUFFICIENT_PRIVILEGES FROM information_schema.OPTIMIZER_TRACE');
    if ($rows === null) {
        return $none;
    }
    foreach ($rows as [$query, $trace, $missing, $denied]) {
        if ((string) $query !== $statement) {
            continue;
        }
        if ((int) $missing !== 0 || (int) $denied !== 0) {
            return $none;
        }
        // Each "expanded_query" is a JSON text. Inside a JSON text a quote is always \", so the key can't
        // be found inside one.
        $trace = (string) $trace;
        $n = strlen($trace);
        $key = '"expanded_query":';
        $queries = [];
        $at = 0;
        while (($at = strpos($trace, $key, $at)) !== false) {
            $start = $at + strlen($key);
            $start += strspn($trace, " \t\r\n", $start);
            if ($start >= $n || $trace[$start] !== '"') {
                return $none;
            }
            $end = $start + 1;
            while ($end < $n && $trace[$end] !== '"') {
                $end += $trace[$end] === '\\' ? 2 : 1;
                $end += strcspn($trace, '"\\', $end);
            }
            if ($end >= $n) {
                return $none;
            }
            $text = json_decode(substr($trace, $start, $end - $start + 1));
            if (!is_string($text)) {
                return $none;
            }
            $queries[] = $text;
            $at = $end + 1;
        }
        return ['whole' => $queries !== [], 'queries' => $queries];
    }
    return $none;
}

/** The message that lists a mixed table's readable columns. */
function sr_select_all_refusal(array $tables, array $mixed): string
{
    $lists = '';
    foreach ($tables as $table) {
        if (isset($mixed[$table])) {
            $lists .= " Of $table these can be read: " . implode(', ', $mixed[$table]) . '.';
        }
    }
    $named = $tables !== [] ? implode(' and ', $tables) : 'one of ' . implode(', ', array_keys($mixed));
    return "the query selects all columns (*) of $named, and that table also holds stored passwords, hashes or secrets. Name the columns you need."
        . $lists;
}

/**
 * Why the statement is refused, from the server's own texts of it, or '' when nothing in them is. $texts are
 * the note 1003 and the trace's expanded queries.
 */
function sr_text_refusal(array $texts, array $rules): string
{
    $markerSeen = false;
    $mixedSeen = [];
    foreach ($texts as $text) {
        // The two things the server writes into these texts without quoting them. Either would let a
        // quote of the user's choosing hide what follows it, so both are refused wherever they show.
        if (strpos($text, ':=') !== false) {
            return 'the query has := in it. A query here does not set a variable, and a text value with := in it cannot be checked.';
        }
        if (preg_match($rules['introducer'], $text)) {
            return "a text value with a character set in front of it (such as _utf8mb4'...') cannot be checked here. Write the value without it.";
        }
        $tokens = sr_scan($text);
        if ($tokens === null) {
            return 'the database\'s own text of this query could not be read to its end, so what it reads could not be checked.';
        }
        $words = [];
        foreach ($tokens as [$kind, $raw]) {
            $name = sr_fold($raw);
            $words[] = $kind === 'word' ? $name : '';
            if ($kind === 'word' && in_array($name, SR_FUNCTIONS, true)) {
                return strtoupper($name) . '() is not allowed in a read here.';
            }
            if (in_array($name, SR_SCHEMAS, true)) {
                return sr_schema_refusal();
            }
            if (isset($rules['refused'][$name])) {
                return sr_table_refusal($name, $rules['refused'][$name]);
            }
            if (isset($rules['routines'][$name])) {
                return (sr_plain($raw) ?: 'a name in the query') . ' is a stored function of this database, and a query here calls none: what a function reads cannot be checked.';
            }
            if (in_array($name, SR_HIDDEN_COLUMNS, true)) {
                return sr_column_refusal();
            }
            if ($name === SR_MARKER) {
                $markerSeen = true;
            } elseif (isset($rules['mixed'][$name])) {
                $mixedSeen[$name] = true;
            } elseif (sr_secret_shape($name)) {
                return sr_shape_refusal($raw);
            }
        }
        $line = ' ' . implode(' ', $words) . ' ';
        if (preg_match('/ for (update|share) | lock in share mode /', $line)) {
            return 'a read here takes no locks (FOR UPDATE, LOCK IN SHARE MODE).';
        }
    }
    if ($markerSeen) {
        return sr_select_all_refusal(array_keys($mixedSeen), $rules['mixed']);
    }
    return '';
}

/**
 * Why the plan is refused, or ''. $rows are EXPLAIN's, by column name. A table of the server's own
 * information_schema is the only kind of row that names a table and has no row estimate (the result of a
 * UNION has none either, and no id).
 */
function sr_plan_refusal(array $rows): string
{
    foreach ($rows as $row) {
        if (($row['id'] ?? null) !== null && ($row['table'] ?? null) !== null && ($row['rows'] ?? null) === null) {
            return sr_schema_refusal();
        }
    }
    return '';
}

function sr_schema_refusal(): string
{
    return "the server's own tables (information_schema, performance_schema, mysql and sys) are not read here.";
}

function sr_table_refusal(string $name, string $kind): string
{
    $shown = sr_plain($name) ?: 'a table in the query';
    if ($kind === 'view') {
        return "$shown is a view, and a view is not read here: it can show what a table's hidden columns hold. Query the tables it reads.";
    }
    return "$shown is not read here: it holds sign-in sessions, tokens, stored passwords or settings with secrets in them.";
}

function sr_column_refusal(): string
{
    return 'the query names a column that holds a password, a password hash, a sign-in code, a token or a client secret. '
        . 'Such a column is not read here, in a WHERE, an ORDER BY or a function either.';
}

function sr_shape_refusal(string $name): string
{
    $shown = sr_plain($name) !== '' ? '"' . sr_plain($name) . '"' : 'a name in the query';
    return "$shown looks like the name of something secret: it has secret, token, password or passwd in it, or ends in _hash or _key. "
        . 'Such columns and tables are not read here. If it is only the label of a column of the answer, give that column another label with AS.';
}

function sr_star_refusal(): string
{
    return 'the query takes all columns (*) of a table that has a column shaped like a secret (secret, token, password or passwd in its name, '
        . 'or _hash or _key at its end), in a place where the number of columns counts. Name the columns you need.';
}

/** Why a result is refused, from its metadata (each column's schema, table and column), or ''. */
function sr_fields_refusal(array $fields, array $rules): string
{
    foreach ($fields as $field) {
        $schema = sr_fold((string) $field->db);
        $table = sr_fold((string) $field->orgtable);
        if (in_array($schema, SR_SCHEMAS, true)) {
            return sr_schema_refusal();
        }
        if (isset($rules['refused'][$table])) {
            return sr_table_refusal($table, $rules['refused'][$table]);
        }
        foreach ([(string) $field->orgname, (string) $field->name] as $raw) {
            $name = sr_fold($raw);
            if ($name === SR_MARKER) {
                return sr_select_all_refusal(isset($rules['mixed'][$table]) ? [$table] : [], $rules['mixed']);
            }
            if (in_array($name, SR_HIDDEN_COLUMNS, true)) {
                return sr_column_refusal();
            }
            if (sr_secret_shape($name)) {
                foreach ($rules['stand_ins'] as $standIn => $readable) {
                    if (sr_fold($standIn) === $table && sr_plain($standIn) !== '' && sr_plain($raw) !== '') {
                        return "the answer would have the column \"$raw\" of $standIn, and a column whose name has secret, token, password or passwd in it, "
                            . "or ends in _hash or _key, is not read here. Name the columns you need. Of $standIn these can be read: " . implode(', ', $readable) . '.';
                    }
                }
                return sr_shape_refusal($raw);
            }
        }
    }
    return '';
}

/**
 * Ends the run after the database refused or rejected the statement. $failure is sr_failure()'s. $trusted: the
 * trace was read whole and found clean, so the database's message can hold nothing the checks would have refused.
 */
function sr_rejected(array $failure, bool $trusted, bool $atExplain, array $rules): void
{
    [$errno, $error, $state] = $failure;
    sr_refuse_if_secret($failure, $rules);
    switch ($errno) {
        case 1792:
            sr_refuse('only reads run here, and this statement writes, makes or drops something, or takes a lock. Changes go through records.sh, users.sh and import-csv.sh.');
            // no break: sr_refuse ends the run
        case 1045:
        case 1227:
            sr_refuse("the database's account may not do that: it reads SuiteCRM's tables and nothing else (no files on the database server).");
            // no break
        case 1064:
            if ($atExplain) {
                sr_refuse('only one SELECT statement runs here, and the database could not read this as one. Its message: ' . sr_sentence($error));
            }
            break;
        case 1969:
        case 3024:
            sr_end(2, 'the database stopped the query after ' . SR_SECONDS . ' seconds, the limit here. Narrow it (fewer rows, a condition on an indexed column) and run it again. Nothing was printed.');
            // no break
        case 2006:
        case 2013:
            sr_too_long();
    }
    if ($trusted || in_array($errno, SR_PLAIN_ERRORS, true)) {
        sr_end(2, 'the database rejected the query (error ' . $errno . '): ' . sr_sentence($error) . ' Nothing was printed.');
    }
    sr_end(2, "the database rejected the query (error $errno, SQLSTATE $state). Its message is not shown here, because it can quote a row. Nothing was printed.");
}

/** One value as the mysql client's batch mode prints it. */
function sr_escape(?string $value): string
{
    if ($value === null) {
        return 'NULL';
    }
    return strtr($value, ["\\" => '\\\\', "\t" => '\\t', "\n" => '\\n', "\0" => '\\0']);
}

function sr_width(string $text): int
{
    if (function_exists('mb_strwidth') && mb_check_encoding($text, 'UTF-8')) {
        return mb_strwidth($text, 'UTF-8');
    }
    return strlen($text);
}

/** Prints the rows: tab-separated with a header row, or as a table with borders, numbers on the right. */
function sr_print(array $fields, array $rows, bool $asTable): void
{
    $header = array_map(static fn ($f) => sr_escape((string) $f->name), $fields);
    $lines = [];
    foreach ($rows as $row) {
        $lines[] = array_map('sr_escape', $row);
    }
    if (!$asTable) {
        $out = implode("\t", $header) . "\n";
        foreach ($lines as $line) {
            $out .= implode("\t", $line) . "\n";
        }
        fwrite(STDOUT, $out);
        return;
    }
    $numeric = [MYSQLI_TYPE_DECIMAL, MYSQLI_TYPE_NEWDECIMAL, MYSQLI_TYPE_TINY, MYSQLI_TYPE_SHORT, MYSQLI_TYPE_LONG, MYSQLI_TYPE_FLOAT,
        MYSQLI_TYPE_DOUBLE, MYSQLI_TYPE_LONGLONG, MYSQLI_TYPE_INT24, MYSQLI_TYPE_YEAR];
    $widths = array_map('sr_width', $header);
    foreach ($lines as $line) {
        foreach ($line as $i => $cell) {
            $widths[$i] = max($widths[$i], sr_width($cell));
        }
    }
    $rule = '+';
    foreach ($widths as $width) {
        $rule .= str_repeat('-', $width + 2) . '+';
    }
    $format = static function (array $cells, bool $isHeader) use ($widths, $fields, $numeric): string {
        $text = '|';
        foreach ($cells as $i => $cell) {
            $pad = str_repeat(' ', $widths[$i] - sr_width($cell));
            $right = !$isHeader && in_array($fields[$i]->type, $numeric, true);
            $text .= ' ' . ($right ? $pad . $cell : $cell . $pad) . ' |';
        }
        return $text;
    };
    $out = $rule . "\n" . $format($header, true) . "\n" . $rule . "\n";
    foreach ($lines as $line) {
        $out .= $format($line, false) . "\n";
    }
    if ($lines !== []) {
        $out .= $rule . "\n";
    }
    fwrite(STDOUT, $out);
}

// ---------------------------------------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------------------------------------
$maxRows = $argv[1] ?? '';
$format = $argv[2] ?? '';
if ($argc !== 3 || !preg_match('/^[1-9][0-9]{0,3}$/', $maxRows) || (int) $maxRows > SR_MAX_ROWS || !in_array($format, ['table', 'tsv'], true)) {
    sr_end(64, 'usage: sqlread.php MAX_ROWS(1 to ' . SR_MAX_ROWS . ') table|tsv, with the query on stdin. Use sql-read.sh.');
}
$maxRows = (int) $maxRows;
$query = stream_get_contents(STDIN);
// Closing semicolons and the space around the query are not part of it.
$query = rtrim(trim($query === false ? '' : $query), "; \t\r\n");
if ($query === '') {
    sr_end(64, 'no query on stdin');
}
$length = function_exists('mb_strlen') && mb_check_encoding($query, 'UTF-8') ? mb_strlen($query, 'UTF-8') : strlen($query);
if ($length > SR_MAX_QUERY) {
    sr_refuse('the query is longer than 20,000 characters.');
}
// The one rule that reads the query's own text, and it reads single characters, not SQL. The server writes
// the name of a WITH table back without quoting it, so a name with a quote in it would hide what follows it
// from the net below. A name can hold a quote only inside backticks. So every backtick in the text, wherever
// it stands, has to be half of a pair around a plain name.
$withoutNames = preg_replace('/`[A-Za-z0-9_$]+`/', '', $query);
if ($withoutNames === null || strpos($withoutNames, '`') !== false || strpos($query, '``') !== false) {
    sr_refuse('a name in backticks may hold only letters, digits, _ and $ here (`name`), and a backtick may stand nowhere else in the query, in a text value or a comment either.');
}
// The time limit is the server's, for every query. Only these words can lift it, and SQL has no other way
// to spell them.
if (stripos($query, 'max_execution_time') !== false || stripos($query, 'max_statement_time') !== false) {
    sr_refuse('a query here does not set a time limit of its own (MAX_EXECUTION_TIME, max_statement_time): every query has ' . SR_SECONDS . ' seconds. Write it without those words, in a text value too.');
}
// A comment that the server runs as SQL can hold any clause, so there is none.
if (strpos($query, '/*!') !== false || stripos($query, '/*M!') !== false) {
    sr_refuse('a comment that the database runs as SQL (/*! ... */) is not allowed here. Write the query without it.');
}
// LOCK IN SHARE MODE: the server's text of a subquery does not show it. Between SHARE and MODE the server
// allows space and comments, and nothing else, so the match never goes back over them (*+). A failed match
// (false) is refused like a found one.
if (preg_match('/\bshare(?:\s|\/\*.*?\*\/|--[^\n]*(?:\n|$)|#[^\n]*(?:\n|$))*+mode\b/is', $query) !== 0) {
    sr_refuse('a read here takes no locks (FOR UPDATE, LOCK IN SHARE MODE). If the words "share mode" only stand in a text value, search for them another way.');
}

[$db, $introducer] = sr_connect(sr_dbconfig());
$rules = sr_private_copies($db);
$rules['introducer'] = $introducer;

// The first pass, against the stand-ins. From here on the real tables are back, behind the private copies.
$firstPassError = sr_first_pass($db, $query, $rules);

// What the net reads: the trace of the EXPLAIN below. Asked for before the transaction starts.
if (sr_rows($db, "SET SESSION optimizer_trace = 'enabled=on'") === null) {
    sr_end(1, 'this database has no optimizer trace (MariaDB has it from 10.4 on), and this script needs it to check what a query reads. Nothing was run.');
}
sr_rows($db, 'SET SESSION optimizer_trace_max_mem_size = 33554432');
if (sr_rows($db, 'SET SESSION TRANSACTION READ ONLY') === null || sr_rows($db, 'START TRANSACTION READ ONLY') === null) {
    sr_end(1, 'the database did not start a read-only transaction, and a query is not run outside one. Nothing was run.');
}

// The plan, and the server's own texts of the statement: note 1003 and the trace. EXPLAIN runs none of the
// query, apart from what the planner looks up to plan (a row by its key, a small subquery): that is why its
// error message is trusted only after the trace was found clean.
$statement = 'EXPLAIN EXTENDED ' . $query;
$explain = $db->query($statement);
$explainFailure = sr_failure($db);
$notes = [];
$plan = null;
if ($explain instanceof mysqli_result) {
    $names = array_map(static fn ($field) => $field->name, $explain->fetch_fields());
    if (in_array('select_type', $names, true) && in_array('table', $names, true) && in_array('rows', $names, true)) {
        $plan = $explain->fetch_all(MYSQLI_ASSOC);
    }
    $explain->free();
    foreach (sr_rows($db, 'SHOW WARNINGS') ?? [] as $warning) {
        if ((int) ($warning[1] ?? 0) === 1003) {
            $notes[] = (string) $warning[2];
        }
    }
}
$trace = sr_trace($db, $statement);
sr_rows($db, "SET SESSION optimizer_trace = 'enabled=off'");

$netWhy = sr_text_refusal(array_merge($trace['queries'], $notes), $rules);
$trusted = $netWhy === '' && $trace['whole'];
if ($explain === false) {
    if ($netWhy !== '') {
        sr_refuse($netWhy);
    }
    sr_rejected($explainFailure, $trusted, true, $rules);
}

// Does it return rows? A prepare says so, and gives the result's columns, before anything runs.
$prepared = $db->prepare($query);
if ($prepared === false) {
    $failure = sr_failure($db);
    if ($netWhy !== '') {
        sr_refuse($netWhy);
    }
    sr_rejected($failure, $trusted, false, $rules);
}
$returnsRows = $prepared->field_count > 0;
$metadata = $returnsRows ? $prepared->result_metadata() : false;
$fieldsWhy = $metadata instanceof mysqli_result ? sr_fields_refusal($metadata->fetch_fields(), $rules) : 'the database did not say which columns the answer has.';
if ($metadata instanceof mysqli_result) {
    $metadata->free();
}
$prepared->close();
if (!$returnsRows) {
    sr_refuse('this statement returns no rows. Only a SELECT that prints its rows runs here: no write, and no INTO a file or a variable.');
}
// The refusals, the server's own answers first: the answer's columns, the plan, the first pass. Then the net.
// Here the server has accepted the query on the real tables, so an error of the first pass is a refusal.
foreach ([$fieldsWhy, $plan !== null ? sr_plan_refusal($plan) : '', $firstPassError !== 0 ? sr_first_pass_refusal($firstPassError) : '', $netWhy] as $why) {
    if ($why !== '') {
        sr_refuse($why);
    }
}
if ($plan === null || $notes === [] || !$trusted) {
    sr_refuse('what this query reads could not be checked (the database gave no plan, no note or no complete trace for it). Make it one plain SELECT, or a simpler one.');
}

// The query itself.
if (sr_rows($db, 'SET SESSION sql_select_limit = ' . $maxRows) === null) {
    sr_end(1, 'the database did not take the row limit. Nothing was run.');
}
$started = microtime(true);
$result = $db->query($query, MYSQLI_USE_RESULT);
if ($result === false) {
    sr_rejected(sr_failure($db), true, false, $rules);
}
if ($result === true) {
    sr_refuse('this statement returns no rows. Only a SELECT that prints its rows runs here.', 'Nothing was printed.');
}
$fields = $result->fetch_fields();
$why = sr_fields_refusal($fields, $rules);
if ($why !== '') {
    $db->close();
    sr_refuse($why, 'No row was printed.');
}
$rows = [];
$bytes = 0;
$more = false;
while (($row = $result->fetch_row()) !== null && $row !== false) {
    if (count($rows) === SR_MAX_ROWS) {
        $more = true;
        break;
    }
    foreach ($row as $value) {
        $bytes += $value === null ? 4 : strlen($value);
    }
    if ($bytes > SR_MAX_BYTES) {
        $db->close();
        sr_end(2, 'the answer is larger than 32 MB. Select fewer columns or fewer rows. Nothing was printed.');
    }
    if (microtime(true) - $started > SR_WAIT) {
        // Rows that come slowly never trip the wait for one answer; the whole statement has the same limit.
        $db->close();
        sr_too_long();
    }
    $rows[] = $row;
}
if (!$more && (int) $db->errno !== 0) {
    sr_rejected(sr_failure($db), true, false, $rules);
}
// The transaction ends and the connection closes before a byte is printed: a reader that stalls must not
// keep a transaction open, because a change to a table's layout waits for it, and every query on that table
// then waits behind the change. When rows are left, closing ends the statement on the server, and they are
// never fetched.
if (!$more) {
    $result->free();
    $db->query('ROLLBACK');
}
$db->close();
sr_print($fields, $rows, $format === 'table');
if ($more) {
    sr_say('stopped at 5,000 rows, the most this script prints. The query has more: narrow it, or count and sum in the query itself.');
    exit(0);
}
if (count($rows) === $maxRows) {
    sr_say("$maxRows rows, which is the --max-rows limit: a query without its own LIMIT is cut there, so there may be more. Raise --max-rows (5000 at most), or count and sum in the query itself.");
}
exit(0);
