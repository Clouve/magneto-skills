<?php
/**
 * SuiteCRM skill: remote/import.php (runs inside the SuiteCRM container as www-data; import-csv.sh sends it)
 *
 * Imports a CSV file through SuiteCRM's own Import module, the one behind the Import screen, so its checks of
 * dropdown values, email addresses, dates and numbers, its duplicate check and its per-row errors apply.
 *
 * Usage: import.php plan MODULE MODE DUPFIELDS            the CSV on stdin; imports nothing, stores the plan
 *        import.php run MODULE MODE DUPFIELDS PLAN_ID     the CSV on stdin; imports it
 *        import.php last MODULE                           this skill's imports into MODULE, newest first
 *        import.php undo MODULE RECEIPT preview|yes       what an undo of that run would remove; or removes it
 *   MODE is import (new records) or update (the file has an id column). DUPFIELDS is a comma-separated list
 *   of fields for the duplicate check, "default" for the module's usual one, or "none". PLAN_ID is what plan
 *   printed for this file. RECEIPT is what run printed and last lists.
 *
 * What the Import module does that is easy to miss, and what this script does about each:
 *   - It reads every line as a record, the header line too. So the header is taken off before the file
 *     reaches it, and only used to map columns to fields.
 *   - Its CSV reader takes a backslash before a closing quote as part of the cell, so a quoted cell that ends
 *     in a backslash swallows the next row. The plan reads each row the way that reader would and refuses
 *     the file when a row does not come back as it was written.
 *   - It creates an account that is missing when a contact's or an opportunity's account_name names one.
 *     The plan lists those names before anything is imported. Other "by name" columns (campaign, reports
 *     to) are left out of the import.
 *   - A row whose assigned_user_name is no user's login goes to the acting user without a word. The plan
 *     names such rows as a problem, and says who the rows will belong to.
 *   - It stores a cell that starts with =, +, - or @ as it is, and SuiteCRM's CSV export writes it out
 *     unchanged. The plan counts those cells.
 *   - A workflow marked "Run on import" runs for each imported row while the import runs. One that the
 *     scheduler runs takes the imported rows at its next pass, marked or not. The plan lists both kinds and
 *     says which send email. Logic hooks and the audit trail apply to every row.
 *   - It reads numbers and dates through the acting user's own profile. This script fixes those settings for
 *     its own process (sc_fixed_formats), so a cell of 1234.56 is stored as 1234.56 whatever that profile says.
 *   - Its undo deletes rows for good, and it tracks "the last import" per user, in users_last_import. This
 *     script acts as the first admin, as the admin does in the browser. So every run gets a receipt in
 *     tmp/clouve-skill-imports: written before the import starts (state "started") and again when it ends
 *     (state "done", with the counts and exactly the rows SuiteCRM tracked for this run). An undo names its
 *     receipt, removes exactly those rows, once, and marks the receipt "undone". It is refused for an update,
 *     for a run that did not finish, when SuiteCRM no longer tracks the rows (an import the admin starts in
 *     SuiteCRM's own Import screen clears that tracking, and so does restoring a backup from before the
 *     import; an import by this skill never does), and while a newer import still stands.
 *   - Its status and error files in upload/import/ carry the acting user's id, so they are also the files of
 *     an import the admin is doing in the browser. This script sets existing ones aside for the length of
 *     its run and puts them back, uses a file name of its own for the upload, and removes only its own files.
 *
 * A plan is stored next to the receipts, with the file's checksum. run takes the plan's id and refuses a file
 * that is not the one the plan was made for, a plan older than 24 hours, and a plan a run has used already.
 * One import or undo runs at a time (a lock file in the same folder).
 *
 * Exit codes: 0 done; 64 usage, or an undo's preview of a run that can be undone (nothing was removed);
 * 65 the file can't be imported as it is, or it does not fit the plan (nothing was written); 2 SuiteCRM's
 * importer failed, another import or undo is running, or this run can't be undone; 3 there is no such run in
 * this module, it is undone already, or it created nothing.
 */

require __DIR__ . '/boot.php';
require_once 'modules/Import/Importer.php';
require_once 'modules/Import/sources/ImportFile.php';
require_once 'modules/Import/ImportCacheFiles.php';
require_once 'modules/Import/UsersLastImport.php';

/**
 * This process never saves the acting user's preferences, so what sc_fixed_formats() sets stays in memory.
 */
class ScFixedFormatPreferences extends UserPreference
{
    public function savePreferencesToDB($all = false)
    {
        $GLOBALS['savePreferencesToDB'] = false;
    }
}

/**
 * Numbers and dates are read in one fixed form, whatever the main admin's own profile says: a decimal point
 * and no thousands separator, dates as YYYY-MM-DD, times in UTC. SuiteCRM's save reads a number through the
 * acting user's settings (a cell of 1234.56 is stored as 123456 when that profile has a comma as its decimal
 * symbol), so those settings are fixed here, for this process only. The stored profile is not changed.
 * remote/records.php has the same lines; boot.php must not, because users.php saves the main admin's
 * preferences.
 */
function sc_fixed_formats(): void
{
    global $current_user, $timedate;
    $current_user->_userPreferenceFocus = new ScFixedFormatPreferences($current_user);
    foreach (['num_grp_sep' => ',', 'dec_sep' => '.', 'datef' => 'Y-m-d', 'timef' => 'H:i:s', 'timezone' => 'UTC'] as $name => $value) {
        $current_user->setPreference($name, $value, 0, 'global');
    }
    $GLOBALS['savePreferencesToDB'] = false;
    $GLOBALS['savePreferencesToDBCats'] = [];
    // SuiteCRM keeps the separators, the time zone and the date-time format it read first: read them again.
    $separators = get_number_separators(true);
    $timedate->clearCache();
    sugar_cache_clear($timedate->get_date_time_format_cache_key($current_user));
    if ($separators !== [',', '.'] || $timedate->get_date_time_format() !== 'Y-m-d H:i:s' || TimeDate::userTimezone() !== 'UTC') {
        sc_fail(1, 'could not fix the number and date formats for this run, so a number or a date could be stored wrongly. Nothing was changed.');
    }
}
sc_fixed_formats();

const SC_IMPORT_MODULES = ['Accounts', 'Contacts', 'Leads', 'Opportunities'];
const SC_IMPORT_DUPS = ['Accounts' => ['name'], 'Contacts' => ['email1'], 'Leads' => ['email1'], 'Opportunities' => ['name']];
const SC_IMPORT_NEVER = ['deleted', 'date_entered', 'date_modified', 'created_by', 'modified_user_id', 'created_by_name', 'modified_by_name'];
const SC_RECEIPTS = '/var/www/html/tmp/clouve-skill-imports';
const SC_MAX_ROWS = 50000;
const SC_PLAN_HOURS = 24;
const SC_ID_FORM = '/^[pr]\d{8}-\d{6}-\d{6}$/';
// The files SuiteCRM's importer keeps per user in upload/import/: <type>_<user id>.csv
const SC_CACHE_TYPES = ['misc', 'dupes', 'dupesdisplay', 'error', 'errorrecords', 'errorrecordsonly', 'status'];
const SC_NUMBER_TYPES = ['int', 'uint', 'long', 'ulong', 'short', 'tinyint', 'float', 'double', 'decimal', 'currency'];
const SC_UNDO_WARNING = 'An undo deletes these records from the database for good, with every edit people made to them since the import: no undelete brings them back. It does not put back what an --update run changed.';

function sc_receipt_dir(): string
{
    if (!is_dir(SC_RECEIPTS) && !mkdir(SC_RECEIPTS, 0700, true)) {
        sc_fail(2, 'could not make ' . SC_RECEIPTS);
    }
    chmod(SC_RECEIPTS, 0700);
    return SC_RECEIPTS;
}

/** Writes a plan or a receipt in one step, readable by the web user only. */
function sc_store(string $id, array $data): void
{
    $path = sc_receipt_dir() . '/' . $id . '.json';
    $tmp = $path . '.' . getmypid() . '.tmp';
    $json = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($json === false || file_put_contents($tmp, $json) === false || !chmod($tmp, 0600) || !rename($tmp, $path)) {
        @unlink($tmp);
        sc_fail(2, 'could not write ' . $path);
    }
}

/** A stored plan or receipt, or null when there is none of that id. */
function sc_stored(string $id): ?array
{
    if (!preg_match(SC_ID_FORM, $id)) {
        return null;
    }
    $path = sc_receipt_dir() . '/' . $id . '.json';
    $data = is_file($path) ? json_decode((string) file_get_contents($path), true) : null;
    return is_array($data) ? $data : null;
}

/** The ids of the stored plans (p) or receipts (r), oldest first. An id is its UTC time to the microsecond. */
function sc_stored_ids(string $kind): array
{
    $ids = [];
    foreach (glob(sc_receipt_dir() . '/' . $kind . '*.json') ?: [] as $file) {
        $id = basename($file, '.json');
        if (preg_match(SC_ID_FORM, $id)) {
            $ids[] = $id;
        }
    }
    sort($ids, SORT_STRING);
    return $ids;
}

/**
 * A new id that sorts after every stored one of its kind. A plan's file is made here, so that two plans made
 * in the same moment can't take the same id. A receipt's id is made under the lock, and its file is written
 * when the import starts.
 */
function sc_new_id(string $kind): string
{
    $ids = sc_stored_ids($kind);
    $newest = $ids ? end($ids) : '';
    for ($try = 0; $try < 3000; $try++) {
        $now = microtime(true);
        $id = $kind . gmdate('Ymd-His', (int) $now) . '-' . sprintf('%06d', (int) (($now - floor($now)) * 1000000));
        $path = sc_receipt_dir() . '/' . $id . '.json';
        if (strcmp($id, $newest) > 0 && !file_exists($path)) {
            if ($kind !== 'p') {
                return $id;
            }
            $fh = @fopen($path, 'x');
            if ($fh !== false) {
                fclose($fh);
                chmod($path, 0600);
                return $id;
            }
        }
        usleep(1000);
    }
    sc_fail(2, 'could not make a new id: the newest one stored (' . $newest . ') is dated after the container\'s clock. Nothing was written.');
}

/**
 * The lock that lets one import or undo run at a time. It is the kernel's lock on a file, so it ends with the
 * process that holds it, however that process ends. Returns the handle, or null when another run holds it.
 */
function sc_lock()
{
    $fh = fopen(sc_receipt_dir() . '/lock', 'c');
    if ($fh === false) {
        sc_fail(2, 'could not open the lock file in ' . SC_RECEIPTS);
    }
    chmod(sc_receipt_dir() . '/lock', 0600);
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        fclose($fh);
        return null;
    }
    return $fh;
}

/** True while an import or undo of this skill is running. */
function sc_run_in_progress(): bool
{
    $fh = sc_lock();
    if ($fh === null) {
        return true;
    }
    flock($fh, LOCK_UN);
    fclose($fh);
    return false;
}

/** The CSV on stdin: [header cells, data rows, the file's sha256]. Read as the file is written: a quote in a cell is doubled, and a backslash is a backslash. */
function sc_read_csv(): array
{
    $raw = stream_get_contents(STDIN);
    if ($raw === false || $raw === '') {
        sc_fail(65, 'the file is empty. Nothing was written.');
    }
    $sha = hash('sha256', $raw);
    $fh = fopen('php://temp', 'w+');
    fwrite($fh, $raw);
    unset($raw);
    rewind($fh);
    $rows = [];
    $header = null;
    while (($cells = fgetcsv($fh, 0, ',', '"', '')) !== false) {
        if ($cells === [null]) {
            continue;
        }
        if ($header === null) {
            $cells[0] = preg_replace('/^\xEF\xBB\xBF/', '', (string) $cells[0]);
            $header = array_map(fn ($c) => trim((string) $c), $cells);
            continue;
        }
        $rows[] = $cells;
        if (count($rows) > SC_MAX_ROWS) {
            sc_fail(65, 'the file has more than ' . SC_MAX_ROWS . ' rows. Split it. Nothing was written.');
        }
    }
    fclose($fh);
    if ($header === null) {
        sc_fail(65, 'the file is empty. Nothing was written.');
    }
    foreach ($rows as $i => $cells) {
        if (!mb_check_encoding(implode('', array_map('strval', $cells)), 'UTF-8')) {
            sc_fail(65, 'line ' . ($i + 2) . ' is not UTF-8 text. Save the file as "CSV UTF-8" and try again. Nothing was written.');
        }
    }
    return [$header, $rows, $sha];
}

/** Writes one row the way the copy for SuiteCRM's importer is written. */
function sc_put_row($fh, array $cells, int $width): void
{
    fputcsv($fh, array_pad(array_map('strval', $cells), $width, ''), ',', '"', '\\');
}

/**
 * True when SuiteCRM's CSV reader (ImportFile::getNextRow: 8192 bytes a line, a backslash as the escape
 * character, an empty line ends the file) gives the row back as it was written, and nothing else.
 */
function sc_row_survives($scratch, array $cells, int $width): bool
{
    ftruncate($scratch, 0);
    rewind($scratch);
    sc_put_row($scratch, $cells, $width);
    rewind($scratch);
    $back = fgetcsv($scratch, 8192, ',', '"', '\\');
    $more = fgetcsv($scratch, 8192, ',', '"', '\\');
    return $back === array_pad(array_map('strval', $cells), $width, '') && $more === false;
}

/** The module's active workflows that run for the rows of an import, with their actions. */
function sc_workflows(string $module, string $mode, int $rows): array
{
    global $db;
    // "New records" workflows skip a record that exists already, "modified records" ones skip a new record.
    $fits = $mode === 'update' ? ['All_Records', 'Modified_Records', ''] : ['All_Records', 'New_Records', ''];
    $out = [];
    $res = $db->query('SELECT id, name, run_when, flow_run_on, run_on_import FROM aow_workflow WHERE deleted = 0 AND status = ' . $db->quoted('Active')
        . ' AND flow_module = ' . $db->quoted($module) . ' ORDER BY name');
    while ($row = $db->fetchByAssoc($res)) {
        if (!in_array((string) ($row['flow_run_on'] ?? ''), $fits, true)) {
            continue;
        }
        $when = (string) ($row['run_when'] ?? '');
        $onSave = in_array($when, ['Always', 'On_Save', 'Create'], true);
        $inScheduler = in_array($when, ['Always', 'In_Scheduler', 'Create'], true);
        if ($onSave && (int) $row['run_on_import'] === 1) {
            $runs = 'during the import, for each row';
        } elseif ($inScheduler) {
            $runs = 'at the scheduler\'s next pass after the import, for each row';
        } else {
            // Only on save, and not marked "Run on import": it does not run for imported rows.
            continue;
        }
        $actions = [];
        $ares = $db->query('SELECT action FROM aow_actions WHERE deleted = 0 AND aow_workflow_id = ' . $db->quoted($row['id']) . ' ORDER BY action_order');
        while ($arow = $db->fetchByAssoc($ares)) {
            $actions[] = (string) $arow['action'];
        }
        $conditions = (int) $db->getOne('SELECT COUNT(*) FROM aow_conditions WHERE deleted = 0 AND aow_workflow_id = ' . $db->quoted($row['id']));
        $out[] = [
            'name' => html_entity_decode((string) $row['name'], ENT_QUOTES),
            'runs' => $runs,
            'marked_run_on_import' => (int) $row['run_on_import'] === 1,
            'actions' => $actions,
            'sends_email' => in_array('SendEmail', $actions, true),
            'has_conditions' => $conditions > 0,
            'rows' => $rows,
        ];
    }
    return $out;
}

/** Works out the plan: the mapping, the counts and what to warn about. */
function sc_plan(string $module, string $mode, string $dupArg, array $header, array $rows): array
{
    global $db, $current_user;
    $bean = BeanFactory::newBean($module);
    $importable = $bean->get_importable_fields();
    $byLabel = [];
    foreach ($importable as $name => $def) {
        $label = rtrim(trim((string) translate($def['vname'] ?? '', $module)), ':');
        if ($label !== '') {
            $byLabel[strtolower($label)] = $name;
        }
    }
    $byName = array_change_key_case(array_combine(array_keys($importable), array_keys($importable)), CASE_LOWER);
    $columns = [];
    $left = [];
    $map = [];
    foreach ($header as $i => $cell) {
        $field = $byName[strtolower($cell)] ?? $byLabel[strtolower($cell)] ?? null;
        $why = null;
        if ($field === null) {
            $why = 'SuiteCRM has no importable field of that name in ' . $module;
        } elseif (in_array($field, SC_IMPORT_NEVER, true) || ($field === 'id' && $mode !== 'update')) {
            $why = $field === 'id' ? 'ids are only used when updating (--update)' : 'SuiteCRM fills this in itself';
        } elseif (in_array($field, $map, true)) {
            $why = "the field $field is already taken by an earlier column";
        } else {
            $type = $importable[$field]['type'] ?? '';
            if ($type === 'relate' && !in_array($field, ['account_name', 'assigned_user_name'], true)) {
                $why = 'it links to another record by name, which could create records there; link those afterwards';
            }
        }
        if ($why !== null) {
            $left[] = ['column' => $cell, 'why' => $why];
            continue;
        }
        $map[$i] = $field;
        $columns[] = ['column' => $cell, 'field' => $field];
    }
    $required = [];
    foreach ($importable as $name => $def) {
        $need = !empty($def['required']) || (($def['importable'] ?? '') === 'required');
        if ($need && $name !== 'id' && !in_array($name, $map, true) && !in_array($name, ['account_name'], true)) {
            $required[] = $name;
        }
    }
    if ($module === 'Opportunities' && !in_array('account_name', $map, true) && !in_array('account_id', $map, true) && $mode !== 'update') {
        $required[] = 'account_name';
    }
    if ($mode === 'update') {
        $required = in_array('id', $map, true) ? [] : ['id'];
    }
    $dupFields = $dupArg === 'none' ? [] : ($dupArg === 'default' ? SC_IMPORT_DUPS[$module] : array_filter(explode(',', $dupArg), 'strlen'));
    foreach ($dupFields as $field) {
        if (!isset($importable[$field])) {
            sc_fail(65, "\"$field\" is not a field of $module, so it can't be used for the duplicate check. Nothing was written.");
        }
    }
    $dupFields = array_values(array_filter($dupFields, fn ($f) => in_array($f, $map, true)));
    $col = array_flip($map);

    // Likely duplicates: the same value already in SuiteCRM, or twice in the file
    $inCrm = 0;
    $inFile = 0;
    $examples = [];
    if ($mode !== 'update') {
        foreach ($dupFields as $field) {
            $seen = [];
            foreach ($rows as $n => $cells) {
                $value = trim((string) ($cells[$col[$field]] ?? ''));
                if ($value === '') {
                    continue;
                }
                $key = mb_strtolower($value);
                if (isset($seen[$key])) {
                    $inFile++;
                    if (count($examples) < 10) {
                        $examples[] = ['csv_line' => $n + 2, 'field' => $field, 'value' => $value, 'why' => 'also on line ' . $seen[$key]];
                    }
                    continue;
                }
                $seen[$key] = $n + 2;
                if (in_array($field, ['email1', 'email2'], true)) {
                    $hit = $db->getOne("SELECT r.bean_id FROM email_addr_bean_rel r JOIN email_addresses e ON e.id = r.email_address_id AND e.deleted = 0"
                        . " JOIN {$bean->table_name} t ON t.id = r.bean_id AND t.deleted = 0"
                        . " WHERE r.deleted = 0 AND r.bean_module = " . $db->quoted($module) . " AND e.email_address_caps = " . $db->quoted(strtoupper($value)));
                } elseif (isset($bean->field_defs[$field]) && ($bean->field_defs[$field]['source'] ?? 'db') === 'db') {
                    $forms = array_unique([$value, to_html($value)]);
                    $hit = $db->getOne("SELECT id FROM {$bean->table_name} WHERE deleted = 0 AND $field IN (" . implode(', ', array_map(fn ($f) => $db->quoted($f), $forms)) . ')');
                } else {
                    $hit = false;
                }
                if (!empty($hit)) {
                    $inCrm++;
                    if (count($examples) < 10) {
                        $examples[] = ['csv_line' => $n + 2, 'field' => $field, 'value' => $value, 'why' => 'already in SuiteCRM'];
                    }
                }
            }
        }
    }

    // Accounts the Import module would create by name
    $newAccounts = [];
    if (in_array($module, ['Contacts', 'Opportunities'], true) && isset($col['account_name'])) {
        $names = [];
        foreach ($rows as $cells) {
            $value = trim((string) ($cells[$col['account_name']] ?? ''));
            if ($value !== '') {
                $names[$value] = true;
            }
        }
        foreach (array_keys($names) as $name) {
            $forms = array_unique([$name, to_html($name)]);
            if (!$db->getOne('SELECT id FROM accounts WHERE deleted = 0 AND name IN (' . implode(', ', array_map(fn ($f) => $db->quoted($f), $forms)) . ')')) {
                $newAccounts[] = $name;
            }
        }
    }

    // Who the rows will belong to. SuiteCRM takes a login or a full name in assigned_user_name, and gives a
    // row whose value matches no user to the acting user without a word.
    $mainAdmin = (string) $current_user->user_name;
    $owners = [];
    $ownerOf = [];
    $unknownOwner = 0;
    $lookup = function (string $value) use ($db, &$ownerOf) {
        if (!array_key_exists($value, $ownerOf)) {
            $login = $db->getOne('SELECT user_name FROM users WHERE deleted = 0 AND user_name = ' . $db->quoted($value));
            if (empty($login)) {
                $login = $db->getOne("SELECT user_name FROM users WHERE deleted = 0 AND CONCAT(IFNULL(first_name, ''), ' ', IFNULL(last_name, '')) = " . $db->quoted($value));
            }
            $ownerOf[$value] = empty($login) ? null : (string) $login;
        }
        return $ownerOf[$value];
    };

    // Rows SuiteCRM will reject or read wrongly, as far as that can be seen from here
    $problems = [];
    $blocking = 0;
    $missingIds = 0;
    $formulaCount = 0;
    $formulaLines = [];
    $width = count($header);
    $scratch = fopen('php://memory', 'w+');
    foreach ($rows as $n => $cells) {
        foreach (['email1', 'email2'] as $field) {
            $value = isset($col[$field]) ? trim((string) ($cells[$col[$field]] ?? '')) : '';
            if ($value !== '' && !filter_var($value, FILTER_VALIDATE_EMAIL) && count($problems) < 20) {
                $problems[] = ['csv_line' => $n + 2, 'problem' => "not an email address in $field"];
            }
        }
        if ($mode === 'update' && isset($col['id'])) {
            $id = trim((string) ($cells[$col['id']] ?? ''));
            if ($id === '' || !$db->getOne("SELECT id FROM {$bean->table_name} WHERE deleted = 0 AND id = " . $db->quoted($id))) {
                $missingIds++;
                if (count($problems) < 20) {
                    $problems[] = ['csv_line' => $n + 2, 'problem' => 'no record with this id'];
                }
            }
        }
        if (!sc_row_survives($scratch, $cells, $width)) {
            $blocking++;
            if (count($problems) < 20) {
                $ends = array_filter(array_map('strval', $cells), fn ($c) => substr($c, -1) === '\\');
                $problems[] = ['csv_line' => $n + 2, 'problem' => $ends
                    ? 'a cell ends in a backslash: SuiteCRM\'s CSV reader would take the next cell or the next row into it. Take the backslash off the end of the cell.'
                    : 'SuiteCRM\'s CSV reader would not read this line as it is written (a line of more than 8,000 characters, or a line with nothing in it)'];
            }
        }
        if (isset($col['assigned_user_name'])) {
            $value = trim((string) ($cells[$col['assigned_user_name']] ?? ''));
            if ($value === '') {
                if ($mode !== 'update') {
                    $owners[$mainAdmin] = ($owners[$mainAdmin] ?? 0) + 1;
                }
            } elseif (($login = $lookup($value)) !== null) {
                $owners[$login] = ($owners[$login] ?? 0) + 1;
            } else {
                $unknownOwner++;
                $blocking++;
                if (count($problems) < 20) {
                    $problems[] = ['csv_line' => $n + 2, 'problem' => "no user has the login \"$value\" (assigned_user_name): SuiteCRM would give the row to the main admin without saying so"];
                }
            }
        }
        // Cells a spreadsheet would run as a formula. A signed number in a number field and a phone number
        // that starts with + are not formulas.
        $isFormula = false;
        foreach ($map as $i => $field) {
            $value = trim((string) ($cells[$i] ?? ''));
            if ($value === '' || strpos('=+-@', $value[0]) === false) {
                continue;
            }
            $type = (string) ($importable[$field]['type'] ?? '');
            if (($value[0] === '+' || $value[0] === '-') && (in_array($type, SC_NUMBER_TYPES, true) || $type === 'phone')
                && preg_match('/^[+-][0-9 ().,\/-]*$/', $value)) {
                continue;
            }
            $formulaCount++;
            $isFormula = true;
        }
        if ($isFormula && count($formulaLines) < 10) {
            $formulaLines[] = $n + 2;
        }
    }
    fclose($scratch);

    if (isset($col['assigned_user_name'])) {
        $belong = ['by' => 'the assigned_user_name column', 'main_admin' => $mainAdmin, 'rows_by_login' => $owners];
        if ($mode === 'update') {
            $belong['note'] = 'a row with an empty assigned_user_name keeps its owner';
        }
    } elseif ($mode === 'update') {
        $belong = ['by' => 'no change: the file has no assigned_user_name column, so every record keeps its owner', 'main_admin' => $mainAdmin, 'rows_by_login' => []];
    } else {
        $belong = ['by' => 'default: the file has no assigned_user_name column, so every row goes to the main admin', 'main_admin' => $mainAdmin,
            'rows_by_login' => count($rows) ? [$mainAdmin => count($rows)] : []];
    }

    $ready = $required === [] && $columns !== [] && count($rows) > 0 && $missingIds === 0 && $blocking === 0;
    return [
        'plan' => [
            'module' => $module,
            'mode' => $mode,
            'rows' => count($rows),
            'columns' => $columns,
            'columns_not_imported' => $left,
            'required_fields_missing' => $required,
            'duplicate_check_on' => $dupFields,
            'likely_duplicates' => ['already_in_suitecrm' => $inCrm, 'repeated_in_file' => $inFile, 'examples' => $examples],
            'accounts_it_would_create' => $newAccounts,
            'rows_will_belong_to' => $belong,
            'formula_cells' => ['count' => $formulaCount, 'csv_lines' => $formulaLines],
            'workflows_that_run' => sc_workflows($module, $mode, count($rows)),
            'rows_with_problems' => $problems,
            'ready' => $ready,
        ],
        'map' => $map,
        'dup' => $dupFields,
    ];
}

/** What the plan says in words, for the user to read before the yes. */
function sc_plan_in_words(array $plan): string
{
    $module = $plan['module'];
    $rows = $plan['rows'];
    $belong = $plan['rows_will_belong_to'];
    if ($plan['mode'] === 'update') {
        $text = "Changes the $rows records named by the id column. There is no undo for an update: the backup is the way back.";
        if ($belong['rows_by_login']) {
            $text .= ' It changes the owner of the rows that name one in assigned_user_name.';
        }
    } else {
        $text = "Adds up to $rows records to $module. Rows SuiteCRM finds to be duplicates (" . (implode(', ', $plan['duplicate_check_on']) ?: 'no check') . ') or invalid are skipped and reported.'
            . ($plan['accounts_it_would_create'] ? ' It also creates ' . count($plan['accounts_it_would_create']) . ' new account(s) by name.' : '');
        $logins = array_keys($belong['rows_by_login']);
        if ($logins === [$belong['main_admin']] || $logins === []) {
            $text .= ' The new records will belong to the main admin (' . $belong['main_admin'] . ')'
                . ($belong['by'] === 'the assigned_user_name column' ? '.' : ', because the file has no assigned_user_name column.');
        } else {
            $text .= ' The new records will belong to the users named in the assigned_user_name column (' . implode(', ', array_map(fn ($l) => $l . ': ' . $belong['rows_by_login'][$l], $logins)) . ').';
        }
    }
    $text .= $plan['mode'] === 'update'
        ? ' The changes are recorded as the main admin\'s own work: "modified by" and the audit trail name the main admin.'
        : ' They are recorded as the main admin\'s own work: "created by" names the main admin.';
    if ($plan['formula_cells']['count'] > 0) {
        $text .= ' ' . $plan['formula_cells']['count'] . ' cell(s) start with =, +, - or @. They are stored as they are, and SuiteCRM\'s own CSV export writes them out unchanged, so a spreadsheet that opens an export may run them as formulas.';
    }
    foreach ($plan['workflows_that_run'] as $flow) {
        $text .= ' The workflow "' . $flow['name'] . '" runs ' . $flow['runs'] . ($flow['has_conditions'] ? ' that meets its conditions' : '') . '.';
        if ($flow['sends_email']) {
            $text .= ' This workflow sends an email for each imported row' . ($flow['has_conditions'] ? ' that meets its conditions' : '') . ": $rows rows. An undo does not take mail back.";
        }
    }
    if ($plan['mode'] !== 'update') {
        $text .= " import-csv.sh undo $module <receipt id> removes what the run added, for good; run prints the receipt id.";
    }
    return $text;
}

/** The rows SuiteCRM tracks as the acting user's imports: users_last_import id => row. */
function sc_tracked(string $userId): array
{
    global $db;
    $rows = [];
    $res = $db->query('SELECT id, bean_type, bean_id, import_module FROM users_last_import WHERE deleted = 0 AND assigned_user_id = ' . $db->quoted($userId));
    while ($row = $db->fetchByAssoc($res)) {
        $rows[$row['id']] = $row;
    }
    return $rows;
}

/** The module's name for a tracked row: SuiteCRM stores the bean's class (Contact), people say the module (Contacts). */
function sc_module_of(string $beanType): string
{
    $module = array_search($beanType, $GLOBALS['beanList'] ?? [], true);
    return is_string($module) ? $module : $beanType;
}

/** The receipt's rows whose record is still in the database, by module, and the names of the accounts among them that the import made by name. */
function sc_still_there(array $receipt): array
{
    global $db;
    $byType = [];
    foreach ($receipt['rows'] ?? [] as $row) {
        $byType[(string) $row['bean_type']][] = (string) $row['bean_id'];
    }
    $there = [];
    $accounts = [];
    foreach ($byType as $type => $ids) {
        $bean = isset($GLOBALS['beanFiles'][$type]) ? BeanFactory::newBean(sc_module_of($type)) : null;
        if (!$bean || empty($bean->table_name)) {
            continue;
        }
        $count = 0;
        foreach (array_chunk($ids, 500) as $chunk) {
            $in = implode(', ', array_map(fn ($id) => $db->quoted($id), $chunk));
            if ($type === 'Account' && $receipt['module'] !== 'Accounts') {
                $res = $db->query("SELECT name FROM accounts WHERE id IN ($in) ORDER BY name");
                while ($row = $db->fetchByAssoc($res)) {
                    $count++;
                    if (count($accounts) < 200) {
                        $accounts[] = html_entity_decode((string) $row['name'], ENT_QUOTES);
                    }
                }
            } else {
                $count += (int) $db->getOne("SELECT COUNT(*) FROM {$bean->table_name} WHERE id IN ($in)");
            }
        }
        if ($count > 0) {
            $there[sc_module_of($type)] = $count;
        }
    }
    return [$there, $accounts];
}

/**
 * The newest import that still stands, of any module: a run that did not finish, or an import of new records
 * of which SuiteCRM still tracks at least one row. An undone run, an update and a run that created nothing do
 * not stand. Returns its receipt id, state, module and time, or null when no import stands. It looks once
 * per process, and again when $again is set (after the lock is taken).
 */
function sc_newest_standing(array $tracked, bool $again = false): ?array
{
    static $found = false;
    if ($found !== false && !$again) {
        return $found;
    }
    $found = null;
    foreach (array_reverse(sc_stored_ids('r')) as $id) {
        // A receipt that can't be read says nothing about what its run made: it counts as one that did not finish.
        $receipt = sc_stored($id) ?? ['state' => 'started'];
        $state = $receipt['state'] ?? '';
        if ($state === 'undone' || ($receipt['mode'] ?? '') === 'update') {
            continue;
        }
        $stands = $state !== 'done';
        foreach ($state === 'done' ? ($receipt['rows'] ?? []) : [] as $row) {
            if (isset($tracked[$row['id'] ?? ''])) {
                $stands = true;
                break;
            }
        }
        if ($stands) {
            $found = ['receipt' => $id, 'state' => $state === 'done' ? 'done' : 'started', 'module' => (string) ($receipt['module'] ?? 'a module its receipt does not name'),
                'made_utc' => (string) ($receipt['made_utc'] ?? 'an unknown date')];
            break;
        }
    }
    return $found;
}

/**
 * Whether the run of this receipt can be undone now: [true, 0, null] or [false, exit code, why not].
 * $tracked is sc_tracked() of the acting user, $running is sc_run_in_progress(), and $again makes it look at
 * the other receipts afresh.
 */
function sc_undo_check(array $receipt, array $tracked, bool $running, bool $again = false): array
{
    $id = $receipt['receipt'];
    $state = $receipt['state'] ?? '';
    $rows = $receipt['rows'] ?? [];
    if ($state === 'undone') {
        return [false, 3, "the import $id is undone already (on " . ($receipt['undone_utc'] ?? 'an unknown date') . ' UTC)'];
    }
    if (($receipt['mode'] ?? '') === 'update') {
        return [false, 2, "the run $id was an update (--update), and an update has no undo: the backup taken before it is the way back"];
    }
    if ($state !== 'done') {
        return [false, 2, $running
            ? "the import $id is still running"
            : "the import $id did not finish, so the records it made can't be told apart from others: restore the backup taken before it, or delete the records one by one"];
    }
    if (!$rows) {
        return [false, 3, "the import $id created nothing, so there is nothing to undo"];
    }
    if (!empty($receipt['tracking_differs'])) {
        return [false, 2, "SuiteCRM's own tracking changed while the import $id ran (an import in the browser at the same time), so the records it made can't be told apart safely: restore the backup taken before it, or delete the records one by one"];
    }
    foreach ($rows as $row) {
        if (!preg_match('/^[A-Za-z0-9_-]{1,36}$/', (string) ($row['id'] ?? '')) || !preg_match('/^[A-Za-z0-9_-]{1,36}$/', (string) ($row['bean_id'] ?? ''))
            || !isset($GLOBALS['beanFiles'][(string) ($row['bean_type'] ?? '')])) {
            return [false, 2, "the receipt $id is damaged, so the records of that import can't be told apart safely: restore the backup taken before it, or delete the records one by one"];
        }
        if (!isset($tracked[$row['id']]) || $tracked[$row['id']]['bean_id'] !== $row['bean_id']) {
            return [false, 2, "SuiteCRM no longer tracks the records of the import $id (an import the admin starts in SuiteCRM's own Import screen clears that tracking, and so does restoring a backup from before the import), so they can't be told apart safely: restore the backup taken before it, or delete the records one by one"];
        }
    }
    // Newer imports go first: their records may hang on what this one made (a contact on an account it created).
    $newest = sc_newest_standing($tracked, $again);
    if ($newest !== null && strcmp($newest['receipt'], $id) > 0) {
        $other = $newest['receipt'];
        if ($newest['state'] === 'done') {
            return [false, 2, "a newer import still stands: $other, into " . $newest['module'] . ' on ' . $newest['made_utc']
                . " UTC. Newer imports are undone first, each with its own yes: import-csv.sh undo " . $newest['module'] . " $other"];
        }
        return [false, 2, "a newer import, $other into " . $newest['module'] . ', ' . ($running ? 'is still running' : 'did not finish')
            . '. Newer imports are undone first, and one that did not finish can\'t be undone: restore the backup taken before it'];
    }
    return [true, 0, null];
}

/** What last and the undo's preview show of a receipt. */
function sc_receipt_summary(array $receipt): array
{
    return [
        'receipt' => $receipt['receipt'],
        'module' => $receipt['module'] ?? null,
        'made_utc' => $receipt['made_utc'] ?? null,
        'mode' => $receipt['mode'] ?? null,
        'state' => $receipt['state'] ?? null,
        'undone_utc' => $receipt['undone_utc'] ?? null,
        'rows_read' => $receipt['rows_read'] ?? null,
        'created' => $receipt['created'] ?? null,
        'updated' => $receipt['updated'] ?? null,
        'skipped_as_duplicates' => $receipt['skipped_as_duplicates'] ?? null,
        'rows_with_errors' => $receipt['rows_with_errors'] ?? null,
        'records_made_by_module' => (object) ($receipt['records_made_by_module'] ?? []),
    ];
}

/** The full path of a file in SuiteCRM's upload/import/ folder, or '' when the name is not one. */
function sc_upload_path(string $name): string
{
    $path = (string) UploadStream::path(ImportCacheFiles::getImportDir() . '/' . $name);
    if ($path === '' || basename($name) !== $name) {
        return '';
    }
    return $path[0] === '/' ? $path : '/var/www/html/public/legacy/' . $path;
}

/** The full path of one of SuiteCRM's per-user import files in upload/import/. */
function sc_cache_file(string $type): string
{
    global $current_user;
    return sc_upload_path($type . '_' . $current_user->id . '.csv');
}

/** Puts files that a run of this skill set aside back where SuiteCRM keeps them, unless newer ones are there. */
function sc_put_back_aside(): void
{
    foreach (glob(sc_receipt_dir() . '/aside-*', GLOB_ONLYDIR) ?: [] as $dir) {
        foreach (glob($dir . '/*') ?: [] as $file) {
            $home = sc_upload_path(basename($file));
            if ($home !== '' && !file_exists($home) && is_dir(dirname($home))) {
                rename($file, $home);
            } else {
                unlink($file);
            }
        }
        rmdir($dir);
    }
}

$action = $argv[1] ?? '';
$module = $argv[2] ?? '';
if (!in_array($module, SC_IMPORT_MODULES, true)) {
    sc_fail(64, 'the module must be one of ' . implode(', ', SC_IMPORT_MODULES));
}

switch ($action) {
    case 'plan':
    case 'run':
        $mode = ($argv[3] ?? 'import') === 'update' ? 'update' : 'import';
        $dupArg = $argv[4] ?? 'default';
        [$header, $rows, $sha] = sc_read_csv();
        $result = sc_plan($module, $mode, $dupArg, $header, $rows);
        $plan = $result['plan'];
        if ($action === 'plan') {
            // Plans nobody can run any more go, so the folder stays small.
            foreach (sc_stored_ids('p') as $old) {
                $file = sc_receipt_dir() . '/' . $old . '.json';
                $written = @filemtime($file);
                if ($written !== false && $written < time() - 2 * SC_PLAN_HOURS * 3600) {
                    @unlink($file);
                }
            }
            $planId = sc_new_id('p');
            sc_store($planId, ['plan_id' => $planId, 'module' => $module, 'mode' => $mode, 'duplicate_check_on' => $plan['duplicate_check_on'],
                'file_sha256' => $sha, 'rows' => $plan['rows'], 'ready' => $plan['ready'], 'made_utc' => gmdate('Y-m-d H:i:s'), 'made_at' => time(), 'used_by' => null]);
            $plan = ['plan_id' => $planId, 'file_sha256' => $sha] + $plan;
            $plan['what_the_import_does'] = sc_plan_in_words($plan);
            $plan['run_it_with'] = $plan['ready']
                ? "import-csv.sh run $module <the same file> --plan $planId" . ($mode === 'update' ? ' --update' : '') . ($dupArg !== 'default' ? " --dup-fields $dupArg" : '') . ' --yes-import (after the user\'s yes, within ' . SC_PLAN_HOURS . ' hours, and only while the file is unchanged)'
                : null;
            sc_done($plan);
        }
        $planId = (string) ($argv[5] ?? '');
        $stored = sc_stored($planId);
        if ($stored === null || $planId[0] !== 'p') {
            sc_fail(65, "there is no plan \"$planId\". Run import-csv.sh plan $module <file> first, show it to the user, and pass the plan_id it prints as --plan. Nothing was written.");
        }
        $differs = [];
        if (($stored['module'] ?? '') !== $module) {
            $differs[] = 'the plan is for ' . ($stored['module'] ?? '?') . ", not $module";
        }
        if (($stored['mode'] ?? '') !== $mode) {
            $differs[] = 'the plan is for ' . (($stored['mode'] ?? '') === 'update' ? 'an update (--update)' : 'an import of new records') . ', and this run is not';
        }
        $planDups = $stored['duplicate_check_on'] ?? [];
        $runDups = $plan['duplicate_check_on'];
        sort($planDups);
        sort($runDups);
        if ($planDups !== $runDups) {
            $differs[] = 'the plan checks duplicates on ' . (implode(', ', $planDups) ?: 'nothing') . ', this run on ' . (implode(', ', $runDups) ?: 'nothing');
        }
        if (($stored['file_sha256'] ?? '') !== $sha) {
            $differs[] = 'the file has changed since the plan was made (the plan saw ' . ($stored['rows'] ?? '?') . ' rows, the file now has ' . $plan['rows'] . ')';
        }
        if ($differs) {
            sc_fail(65, "not imported: this is not what the plan $planId showed: " . implode('; ', $differs) . ". Make a new plan, show it to the user, and run with its plan_id after a new yes. Nothing was written.");
        }
        if ((int) ($stored['made_at'] ?? 0) < time() - SC_PLAN_HOURS * 3600) {
            sc_fail(65, "not imported: the plan $planId is older than " . SC_PLAN_HOURS . ' hours (made ' . ($stored['made_utc'] ?? '?') . ' UTC), and SuiteCRM may have changed since. Make a new plan, show it to the user, and run with its plan_id after a new yes. Nothing was written.');
        }
        $usedMessage = fn (array $p) => "not imported: the plan $planId was used already, by the run " . $p['used_by'] . ". Nothing was imported a second time. import-csv.sh last $module shows what that run did. To import the file again, make a new plan.";
        if (!empty($stored['used_by'])) {
            sc_fail(65, $usedMessage($stored));
        }
        if (!$plan['ready']) {
            sc_flush_noise();
            echo json_encode(['imported' => false] + $plan, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), "\n";
            fwrite(STDERR, "[suitecrm] not imported: the file is not ready (required_fields_missing, rows_with_problems or no rows above). Nothing was written.\n");
            exit(65);
        }
        $lock = sc_lock();
        if ($lock === null) {
            sc_fail(2, "not imported: another import or undo of this skill is running. Wait for it to end (import-csv.sh last $module shows the runs), then run this again. Nothing was written.");
        }
        // Under the lock: the plan again, in case two runs of it started together.
        $stored = sc_stored($planId) ?? $stored;
        if (!empty($stored['used_by'])) {
            sc_fail(65, $usedMessage($stored));
        }
        if (!ImportCacheFiles::ensureWritable()) {
            sc_fail(2, "not imported: SuiteCRM's upload/import folder can't be written. Nothing was written.");
        }
        sc_put_back_aside();
        $receiptId = sc_new_id('r');
        // Until the import itself starts there is no receipt: nothing ran.
        $notStarted = function (string $message) {
            sc_fail(2, 'not imported: ' . $message . ' Nothing was written.');
        };

        global $mod_strings;
        $mod_strings = return_module_language('en_us', 'Import');
        $bean = BeanFactory::newBean($module);
        // SuiteCRM's status and error files carry the acting user's id, so an import the admin is doing in
        // the browser uses the same ones: set those aside, and put them back when this run ends, however it ends.
        $aside = sc_receipt_dir() . '/aside-' . $receiptId;
        $dest = ImportCacheFiles::getImportDir() . '/clouve-skill-' . $receiptId;
        // True once every file of the admin's is out of the way: only then are the status and error files
        // in upload/import this run's own, to be removed when it ends.
        $ours = false;
        $tidy = function () use ($dest, &$ours) {
            static $done = false;
            if ($done) {
                return;
            }
            $done = true;
            $real = sc_upload_path(basename($dest));
            if ($real !== '' && is_file($real)) {
                unlink($real);
            }
            foreach ($ours ? SC_CACHE_TYPES : [] as $type) {
                $file = sc_cache_file($type);
                if ($file !== '' && is_file($file)) {
                    unlink($file);
                }
            }
            sc_put_back_aside();
        };
        register_shutdown_function($tidy);
        foreach (SC_CACHE_TYPES as $type) {
            $file = sc_cache_file($type);
            if ($file !== '' && is_file($file)) {
                if (!is_dir($aside) && !mkdir($aside, 0700)) {
                    $notStarted("could not make $aside.");
                }
                if (!rename($file, $aside . '/' . basename($file))) {
                    $notStarted('could not set SuiteCRM\'s own import file ' . basename($file) . ' aside.');
                }
            }
        }
        $ours = true;
        $out = fopen($dest, 'w');
        if ($out === false) {
            $notStarted('could not write the import file in SuiteCRM\'s upload folder.');
        }
        foreach ($rows as $cells) {
            sc_put_row($out, $cells, count($header));
        }
        fclose($out);
        // 'module' => 'Import' is what the Import screen's own requests carry. Workflows look at it: with it, only
        // a workflow marked "Run on import" runs for the imported rows, as in the browser.
        $_REQUEST = ['module' => 'Import', 'import_module' => $module, 'source' => 'csv', 'has_header' => 'off', 'import_type' => $mode,
            'custom_delimiter' => ',', 'custom_enclosure' => '"', 'columncount' => count($header),
            'importlocale_charset' => 'UTF-8', 'importlocale_dateformat' => 'Y-m-d', 'importlocale_timeformat' => 'H:i',
            'importlocale_timezone' => 'UTC', 'importlocale_currency' => '-99', 'importlocale_default_currency_significant_digits' => 2,
            'importlocale_num_grp_sep' => ',', 'importlocale_dec_sep' => '.', 'importlocale_default_locale_name_format' => 's f l'];
        foreach ($result['map'] as $i => $field) {
            $_REQUEST['colnum_' . $i] = $field;
        }
        if ($result['dup'] && $mode !== 'update') {
            $_REQUEST['enabled_dup_fields'] = json_encode(array_values($result['dup']));
        }
        // The receipt, before the first row: from here on the run counts as started, and the plan as used.
        $receipt = ['receipt' => $receiptId, 'state' => 'started', 'module' => $module, 'mode' => $mode, 'plan_id' => $planId, 'file_sha256' => $sha,
            'user_id' => $current_user->id, 'made_utc' => gmdate('Y-m-d H:i:s'), 'rows' => []];
        sc_store($receiptId, $receipt);
        sc_store($planId, ['used_by' => $receiptId] + $stored);
        $before = sc_tracked($current_user->id);
        $importer = new Importer(new ImportFile($dest, ',', '"', false), $bean);
        $importer->import();
        $after = sc_tracked($current_user->id);
        // What SuiteCRM tracked for this run: the rows that are new, and that it filed under this module.
        $mine = [];
        foreach (array_diff_key($after, $before) as $row) {
            if ($row['import_module'] === $module) {
                $mine[] = ['id' => $row['id'], 'bean_type' => $row['bean_type'], 'bean_id' => $row['bean_id']];
            }
        }

        $status = [];
        $statusFile = sc_cache_file('status');
        if (is_readable($statusFile) && ($fh = fopen($statusFile, 'r'))) {
            $status = fgetcsv($fh, 0, ',', '"', '\\') ?: [];
            fclose($fh);
        }
        $errors = [];
        $errorFile = sc_cache_file('error');
        if (is_readable($errorFile) && ($fh = fopen($errorFile, 'r'))) {
            while (($cells = fgetcsv($fh, 0, ',', '"', '\\')) !== false && count($errors) < 50) {
                if (count($cells) >= 4) {
                    $errors[] = ['csv_line' => (int) $cells[3] + 1, 'error' => strip_tags((string) $cells[0]), 'field' => (string) $cells[1]];
                }
            }
            fclose($fh);
        }
        $tidy();
        // An account made by name for a row that then turned out to be a duplicate is taken out again by
        // SuiteCRM, so what counts is what is there now.
        [$made] = sc_still_there(['module' => $module, 'rows' => $mine]);
        $mainRows = count(array_filter($mine, fn ($r) => $r['bean_type'] === $bean->object_name));
        $known = count($status) >= 5;
        $receipt = ['state' => 'done', 'ended_utc' => gmdate('Y-m-d H:i:s'),
            'rows_read' => $known ? (int) $status[0] : null, 'created' => $known ? (int) $status[3] : $mainRows, 'updated' => $known ? (int) $status[4] : null,
            'skipped_as_duplicates' => $known ? (int) $status[2] : null, 'rows_with_errors' => $known ? (int) $status[1] : null,
            'records_made_by_module' => $made, 'rows' => $mine] + $receipt;
        // The rows SuiteCRM tracked must be the rows it says it created. They are not when an import in the
        // browser ran at the same moment: then nobody can tell whose rows are whose, and the undo says so.
        if ($known && $mainRows !== (int) $status[3]) {
            $receipt['tracking_differs'] = true;
        }
        sc_store($receiptId, $receipt);
        flock($lock, LOCK_UN);
        fclose($lock);
        if (!$known) {
            sc_fail(2, "SuiteCRM's importer gave no result line, so the counts are not known. The import ran: the receipt $receiptId holds the " . count($mine) . " records it made. Check them with import-csv.sh last $module and records.sh list $module.");
        }
        [$canUndo, , $whyNot] = sc_undo_check($receipt, $after, false, true);
        sc_done([
            'imported' => true,
            'module' => $module,
            'mode' => $mode,
            'receipt' => $receiptId,
            'plan_id' => $planId,
            'rows_read' => (int) $status[0],
            'created' => (int) $status[3],
            'updated' => (int) $status[4],
            'skipped_as_duplicates' => (int) $status[2],
            'rows_with_errors' => (int) $status[1],
            'errors' => $errors,
            'records_made_by_module' => (object) $made,
            'undo' => $canUndo ? "import-csv.sh undo $module $receiptId" : null,
            'undo_note' => $canUndo
                ? "import-csv.sh undo $module $receiptId shows what an undo would remove; with --yes-undo it removes exactly these records. " . SC_UNDO_WARNING
                : 'no undo: ' . $whyNot,
        ]);
        // no break: sc_done exits

    case 'last':
        $tracked = sc_tracked($current_user->id);
        $running = sc_run_in_progress();
        $list = [];
        $total = 0;
        foreach (array_reverse(sc_stored_ids('r')) as $id) {
            $receipt = sc_stored($id);
            if ($receipt === null || ($receipt['module'] ?? '') !== $module) {
                continue;
            }
            $total++;
            if (count($list) >= 10) {
                continue;
            }
            [$can, , $why] = sc_undo_check($receipt, $tracked, $running);
            $list[] = sc_receipt_summary($receipt) + ['can_undo' => $can, 'why_not' => $why];
        }
        sc_done(['module' => $module, 'total' => $total, 'imports' => $list]);
        // no break: sc_done exits

    case 'undo':
        $id = (string) ($argv[3] ?? '');
        $confirm = (string) ($argv[4] ?? 'preview');
        $receipt = $id !== '' && $id[0] === 'r' ? sc_stored($id) : null;
        if ($receipt === null) {
            sc_fail(3, "there is no import \"$id\". import-csv.sh last $module lists this skill's imports into $module with their receipt ids. Nothing was removed.");
        }
        if (($receipt['module'] ?? '') !== $module) {
            sc_fail(3, "the import $id went into " . ($receipt['module'] ?? 'another module') . ", not $module. Nothing was removed.");
        }
        $tracked = sc_tracked($current_user->id);
        [$can, $code, $why] = sc_undo_check($receipt, $tracked, sc_run_in_progress());
        if ($confirm !== 'yes') {
            [$there, $accounts] = sc_still_there($receipt);
            sc_flush_noise();
            echo json_encode(['undone' => false] + sc_receipt_summary($receipt) + [
                'would_remove_by_module' => (object) ($can ? $there : []),
                'accounts_it_made_by_name' => $accounts,
                'can_undo' => $can,
                'why_not' => $why,
                'what_an_undo_does' => SC_UNDO_WARNING,
            ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), "\n";
            if ($can) {
                fwrite(STDERR, "[suitecrm] nothing was removed. This is what an undo of the import $id would remove. " . SC_UNDO_WARNING
                    . " Show this to the user, and run it again with --yes-undo after a clear yes.\n");
                exit(64);
            }
            fwrite(STDERR, "[suitecrm] nothing was removed, and this import can't be undone: $why. " . SC_UNDO_WARNING . "\n");
            exit($code);
        }
        if (!$can) {
            sc_fail($code, "not undone: $why. Nothing was removed.");
        }
        $lock = sc_lock();
        if ($lock === null) {
            sc_fail(2, 'not undone: another import or undo of this skill is running. Wait for it to end, then run this again. Nothing was removed.');
        }
        // Under the lock: the receipt again, in case two undos of it started together.
        $receipt = sc_stored($id) ?? $receipt;
        $tracked = sc_tracked($current_user->id);
        [$can, $code, $why] = sc_undo_check($receipt, $tracked, false, true);
        if (!$can) {
            sc_fail($code, "not undone: $why. Nothing was removed.");
        }
        $rows = $receipt['rows'];
        [$there] = sc_still_there($receipt);
        $undo = new UsersLastImport();
        foreach ($rows as $row) {
            $undo->undoById($row['id']);
        }
        [$left] = sc_still_there($receipt);
        if ($left) {
            sc_fail(2, 'SuiteCRM did not remove every record of the import ' . $id . ': ' . array_sum($left) . ' are still there. The receipt stays as it is. Run this again, or restore the backup.');
        }
        foreach (array_chunk(array_column($rows, 'id'), 500) as $chunk) {
            $db->query('DELETE FROM users_last_import WHERE id IN (' . implode(', ', array_map(fn ($i) => $db->quoted($i), $chunk)) . ')');
        }
        $receipt = ['state' => 'undone', 'undone_utc' => gmdate('Y-m-d H:i:s'), 'rows' => [], 'rows_removed' => count($rows)] + $receipt;
        sc_store($id, $receipt);
        flock($lock, LOCK_UN);
        fclose($lock);
        sc_done(['undone' => true, 'module' => $module, 'receipt' => $id, 'made_utc' => $receipt['made_utc'] ?? null, 'undone_utc' => $receipt['undone_utc'],
            'records_removed_by_module' => (object) $there,
            'note' => 'the records are gone for good; only a backup brings them back']);
        // no break: sc_done exits

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
