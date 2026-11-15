<?php
/**
 * SuiteCRM skill: remote/records.php (runs inside the SuiteCRM container as www-data; records.sh sends it)
 *
 * Creates, reads, updates, links, lists, deletes and brings back accounts, contacts, leads and opportunities
 * through SuiteCRM's own beans, so the module's logic, its audit trail, its logic hooks and its workflows
 * apply, as they do in the browser. Nothing here writes SQL.
 *
 * Numbers and dates go in and come out in one fixed form, whatever the main admin's own profile says: a decimal
 * point and no thousands separator, dates as YYYY-MM-DD, times in UTC as YYYY-MM-DD HH:MM:SS. A field that holds
 * whole numbers (an opportunity's probability) refuses a number with a fraction: SuiteCRM would cut it.
 *
 * What it writes is recorded as the main admin's own work, and a record made without an owner is assigned to the
 * main admin. create says so in its output (assigned_to, assigned_by_default).
 *
 * Usage (records.sh checks the arguments first and has the full text):
 *   records.php create MODULE [allow-duplicate]     fields as a JSON object on stdin
 *   records.php get MODULE ID
 *   records.php update MODULE ID                    fields as a JSON object on stdin
 *   records.php link MODULE ID LINK OTHER_ID [ROLE]
 *   records.php unlink MODULE ID LINK OTHER_ID
 *   records.php list MODULE SEARCH ASSIGNED DELETED LIMIT OFFSET
 *   records.php fields MODULE
 *   records.php delete MODULE ID preview|yes
 *   records.php undelete MODULE ID
 *
 * Exit codes: 0 done; 64 usage; 65 bad input (an unknown field, a value outside a dropdown, a bad date);
 * 2 SuiteCRM did not keep what was sent; 3 no such record; 4 a likely duplicate, nothing written.
 */

require __DIR__ . '/boot.php';

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
 * Numbers and dates go in and out in one fixed form, whatever the main admin's own profile says: a decimal
 * point and no thousands separator, dates as YYYY-MM-DD, times in UTC as YYYY-MM-DD HH:MM:SS. SuiteCRM reads
 * and prints them through the acting user's settings (an amount of "1234.56" is stored as 123456 when that
 * profile has a comma as its decimal symbol), so those settings are fixed here, for this process only. The
 * stored profile is not changed. remote/import.php has the same lines; boot.php must not, because users.php
 * saves the main admin's preferences.
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

const SC_MODULES = ['Accounts', 'Contacts', 'Leads', 'Opportunities'];

// The links this script sets: LINK => [join table, this record's column, the other record's column, other module]
const SC_LINKS = [
    'Accounts' => [
        'contacts' => ['accounts_contacts', 'account_id', 'contact_id', 'Contacts'],
        'opportunities' => ['accounts_opportunities', 'account_id', 'opportunity_id', 'Opportunities'],
    ],
    'Contacts' => [
        'accounts' => ['accounts_contacts', 'contact_id', 'account_id', 'Accounts'],
        'opportunities' => ['opportunities_contacts', 'contact_id', 'opportunity_id', 'Opportunities'],
    ],
    'Leads' => [],
    'Opportunities' => [
        'accounts' => ['accounts_opportunities', 'opportunity_id', 'account_id', 'Accounts'],
        'contacts' => ['opportunities_contacts', 'opportunity_id', 'contact_id', 'Contacts'],
    ],
];

// Fields SuiteCRM fills in itself
const SC_READ_ONLY = ['id', 'deleted', 'date_entered', 'date_modified', 'created_by', 'modified_user_id',
    'created_by_name', 'modified_by_name'];

function sc_module(string $module): string
{
    if (!in_array($module, SC_MODULES, true)) {
        sc_fail(64, "the module must be one of " . implode(', ', SC_MODULES) . ", not \"$module\"");
    }
    return $module;
}

/** The record, or exit 3. With $deleted it finds a deleted one too. */
function sc_load(string $module, string $id, bool $deleted = false)
{
    if (!preg_match('/^[A-Za-z0-9_-]{1,36}$/', $id)) {
        sc_fail(64, 'that is not a record id');
    }
    $bean = BeanFactory::newBean($module);
    $bean->retrieve($id, true, !$deleted ? true : false);
    if (empty($bean->id)) {
        sc_fail(3, "there is no " . ($deleted ? '' : 'undeleted ') . "record $id in $module");
    }
    return $bean;
}

/** The record's display name. */
function sc_name($bean): string
{
    if (in_array($bean->module_dir, ['Contacts', 'Leads'], true)) {
        return trim(($bean->first_name ?? '') . ' ' . ($bean->last_name ?? ''));
    }
    return (string) ($bean->name ?? '');
}

/** The fields a caller may set, with their type and dropdown. */
function sc_settable($bean): array
{
    $out = [];
    foreach ($bean->field_defs as $name => $def) {
        $type = $def['type'] ?? 'varchar';
        $source = $def['source'] ?? 'db';
        if (in_array($name, SC_READ_ONLY, true) || in_array($type, ['link', 'id'], true) && $name !== 'assigned_user_id'
            && !preg_match('/_id$/', $name)) {
            continue;
        }
        if ($type === 'link' || ($source !== 'db' && $source !== 'custom_fields' && !in_array($name, ['email1', 'account_name', 'account_id', 'assigned_user_name'], true))) {
            continue;
        }
        $out[$name] = ['type' => $type, 'required' => !empty($def['required']), 'options' => $def['options'] ?? null];
    }
    return $out;
}

/** Checks the fields and puts them on the bean. Ends with 65 on the first thing that is wrong. */
function sc_apply($bean, array $fields): void
{
    global $app_list_strings, $db;
    $settable = sc_settable($bean);
    $unknown = array_values(array_diff(array_keys($fields), array_keys($settable)));
    if ($unknown) {
        sc_fail(65, 'not a field of ' . $bean->module_dir . ' that can be set: ' . implode(', ', $unknown)
            . '. records.sh fields ' . $bean->module_dir . ' lists them. Nothing was written.');
    }
    foreach ($fields as $name => $value) {
        $def = $settable[$name];
        $text = is_bool($value) ? ($value ? '1' : '0') : (string) ($value ?? '');
        switch ($def['type']) {
            case 'enum':
            case 'radioenum':
                $list = $app_list_strings[$def['options']] ?? null;
                if (is_array($list) && $text !== '' && !array_key_exists($text, $list)) {
                    sc_fail(65, "\"$text\" is not a value of $name. Its values are: " . implode(', ', array_filter(array_keys($list), 'strlen')) . '. Nothing was written.');
                }
                break;
            case 'date':
                if ($text !== '' && !(preg_match('/^\d{4}-\d{2}-\d{2}$/', $text) && checkdate((int) substr($text, 5, 2), (int) substr($text, 8, 2), (int) substr($text, 0, 4)))) {
                    sc_fail(65, "$name needs a date as YYYY-MM-DD, not \"$text\". Nothing was written.");
                }
                break;
            case 'datetime':
            case 'datetimecombo':
                if ($text !== '' && !preg_match('/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/', $text)) {
                    sc_fail(65, "$name needs a UTC time as YYYY-MM-DD HH:MM:SS, not \"$text\". Nothing was written.");
                }
                break;
            case 'int':
            case 'uint':
            case 'long':
            case 'ulong':
            case 'short':
            case 'tinyint':
                // SuiteCRM's save cuts the fraction off without a word, and its own import refuses such a row.
                if ($text !== '' && !preg_match('/^[+-]?\d+$/', $text)) {
                    sc_fail(65, "$name needs a whole number, not \"$text\". Nothing was written.");
                }
                break;
            case 'currency':
            case 'float':
            case 'double':
            case 'decimal':
                // A decimal point and no thousands separator: 1234.56
                if ($text !== '' && !preg_match('/^[+-]?(\d+(\.\d*)?|\.\d+)$/', $text)) {
                    sc_fail(65, "$name needs a number with a decimal point and no thousands separator, such as 1234.56, not \"$text\". Nothing was written.");
                }
                break;
            case 'bool':
                if (!in_array($text, ['0', '1', ''], true)) {
                    sc_fail(65, "$name needs true or false. Nothing was written.");
                }
                break;
        }
        if ($name === 'email1' && $text !== '' && !filter_var($text, FILTER_VALIDATE_EMAIL)) {
            sc_fail(65, "\"$text\" is not an email address. Nothing was written.");
        }
        if ($name === 'account_name' && $bean->module_dir !== 'Leads') {
            // A name never makes a new account here: it has to match exactly one.
            if ($text === '') {
                continue;
            }
            $rows = [];
            $res = $db->query('SELECT id FROM accounts WHERE deleted = 0 AND name ' . sc_both_forms($text));
            while ($row = $db->fetchByAssoc($res)) {
                $rows[] = $row['id'];
            }
            if (count($rows) !== 1) {
                sc_fail(65, (count($rows) === 0 ? "there is no account named \"$text\"" : count($rows) . " accounts are named \"$text\"")
                    . '. Create the account first, or pass account_id. Nothing was written.');
            }
            $bean->account_id = $rows[0];
            continue;
        }
        if ($name === 'account_id' && $text !== '' && $bean->module_dir !== 'Leads') {
            if (!$db->getOne('SELECT id FROM accounts WHERE deleted = 0 AND id = ' . $db->quoted($text))) {
                sc_fail(65, "there is no account $text. Nothing was written.");
            }
        }
        if ($name === 'assigned_user_name') {
            $user = sc_find_user($text);
            if ($user === null) {
                sc_fail(65, "there is no user \"$text\" to assign to. Nothing was written.");
            }
            $bean->assigned_user_id = $user->id;
            continue;
        }
        if ($name === 'assigned_user_id' && $text !== '' && !$db->getOne('SELECT id FROM users WHERE deleted = 0 AND id = ' . $db->quoted($text))) {
            sc_fail(65, "there is no user $text to assign to. Nothing was written.");
        }
        $bean->$name = $text;
    }
}

/** A value as SQL, in both forms SuiteCRM stores text: as typed, and with quotes and angle brackets as HTML entities. */
function sc_both_forms(string $text): string
{
    global $db;
    $forms = array_unique([$text, to_html($text)]);
    return 'IN (' . implode(', ', array_map(fn ($f) => $db->quoted($f), $forms)) . ')';
}

/** Records that look like the one about to be made: [id, name, why] */
function sc_duplicates($bean): array
{
    global $db;
    $found = [];
    $add = function (string $sql, string $why) use (&$found, $db) {
        $res = $db->limitQuery($sql, 0, 10);
        while ($row = $db->fetchByAssoc($res)) {
            $found[$row['id']] = ['id' => $row['id'], 'name' => trim(html_entity_decode((string) $row['name'], ENT_QUOTES)), 'why' => $why];
        }
    };
    $table = $bean->table_name;
    switch ($bean->module_dir) {
        case 'Accounts':
            $add("SELECT id, name FROM accounts WHERE deleted = 0 AND name " . sc_both_forms((string) $bean->name), 'same name');
            break;
        case 'Contacts':
        case 'Leads':
            if (!empty($bean->email1)) {
                $add("SELECT t.id, CONCAT(IFNULL(t.first_name, ''), ' ', IFNULL(t.last_name, '')) AS name FROM $table t"
                    . " JOIN email_addr_bean_rel r ON r.bean_id = t.id AND r.bean_module = " . $db->quoted($bean->module_dir) . " AND r.deleted = 0"
                    . " JOIN email_addresses e ON e.id = r.email_address_id AND e.deleted = 0"
                    . " WHERE t.deleted = 0 AND e.email_address_caps = " . $db->quoted(strtoupper((string) $bean->email1)), 'same email address');
            }
            if (!empty($bean->last_name)) {
                $add("SELECT id, CONCAT(IFNULL(first_name, ''), ' ', IFNULL(last_name, '')) AS name FROM $table WHERE deleted = 0"
                    . " AND last_name " . sc_both_forms((string) $bean->last_name)
                    . " AND IFNULL(first_name, '') " . sc_both_forms((string) ($bean->first_name ?? '')), 'same first and last name');
            }
            break;
        case 'Opportunities':
            if (!empty($bean->account_id)) {
                $add("SELECT o.id, o.name FROM opportunities o JOIN accounts_opportunities ao ON ao.opportunity_id = o.id AND ao.deleted = 0"
                    . " WHERE o.deleted = 0 AND o.name " . sc_both_forms((string) $bean->name) . " AND ao.account_id = " . $db->quoted((string) $bean->account_id), 'same name on the same account');
            }
            break;
    }
    return array_values($found);
}

/** The ids on the other side of a link. */
function sc_linked($bean, string $link): array
{
    global $db;
    [$table, $mine, $theirs, $module] = SC_LINKS[$bean->module_dir][$link];
    $other = BeanFactory::newBean($module);
    $name = in_array($module, ['Contacts'], true) ? "CONCAT(IFNULL(o.first_name, ''), ' ', IFNULL(o.last_name, ''))" : 'o.name';
    $res = $db->limitQuery("SELECT o.id, $name AS name FROM $table j JOIN {$other->table_name} o ON o.id = j.$theirs AND o.deleted = 0"
        . " WHERE j.deleted = 0 AND j.$mine = " . $db->quoted($bean->id) . " ORDER BY name", 0, 50);
    $out = [];
    while ($row = $db->fetchByAssoc($res)) {
        $out[] = ['id' => $row['id'], 'name' => trim(html_entity_decode((string) $row['name'], ENT_QUOTES))];
    }
    return $out;
}

/** A date or a time of the record as the database holds it: YYYY-MM-DD, or YYYY-MM-DD HH:MM:SS in UTC. */
function sc_stored_date($bean, string $name, string $type): string
{
    $value = (string) $bean->$name;
    $stored = is_array($bean->fetched_row ?? null) ? (string) ($bean->fetched_row[$name] ?? '') : '';
    if (preg_match('/^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}:\d{2})?$/', $stored)) {
        return $stored;
    }
    if ($type === 'date') {
        return $GLOBALS['timedate']->to_db_date($value, false) ?: $value;
    }
    return $GLOBALS['timedate']->to_db($value) ?: $value;
}

/** The login a record is assigned to, or '' when it has no owner. */
function sc_owner_login($bean): string
{
    global $db;
    if (empty($bean->assigned_user_id)) {
        return '';
    }
    return (string) $db->getOne('SELECT user_name FROM users WHERE id = ' . $db->quoted((string) $bean->assigned_user_id));
}

/** What `get` prints: every field that holds something, and the links. */
function sc_view($bean): array
{
    $fields = [];
    foreach ($bean->field_defs as $name => $def) {
        $type = $def['type'] ?? 'varchar';
        if ($type === 'link' || !isset($bean->$name) || is_array($bean->$name) || is_object($bean->$name)) {
            continue;
        }
        $value = (string) $bean->$name;
        if ($value === '') {
            continue;
        }
        // Dates and times are printed as the database holds them (times in UTC), the way create and update take them.
        if (in_array($type, ['date', 'datetime', 'datetimecombo'], true)) {
            $value = sc_stored_date($bean, $name, $type);
        }
        $fields[$name] = html_entity_decode($value, ENT_QUOTES);
    }
    $links = [];
    foreach (array_keys(SC_LINKS[$bean->module_dir]) as $link) {
        $links[$link] = sc_linked($bean, $link);
    }
    return ['module' => $bean->module_dir, 'id' => $bean->id, 'name' => html_entity_decode(sc_name($bean), ENT_QUOTES), 'deleted' => (int) $bean->deleted === 1,
        'fields' => $fields, 'links' => $links];
}

$action = $argv[1] ?? '';
$module = sc_module($argv[2] ?? '');

switch ($action) {
    case 'fields':
        $bean = BeanFactory::newBean($module);
        $out = [];
        foreach (sc_settable($bean) as $name => $def) {
            $entry = ['type' => $def['type']];
            if ($def['required']) {
                $entry['required'] = true;
            }
            if ($def['options'] && isset($app_list_strings[$def['options']]) && is_array($app_list_strings[$def['options']])) {
                $entry['values'] = array_values(array_filter(array_keys($app_list_strings[$def['options']]), 'strlen'));
            }
            $out[$name] = $entry;
        }
        sc_done(['module' => $module, 'fields' => $out, 'links' => array_keys(SC_LINKS[$module])]);
        // no break: sc_done exits

    case 'create':
        $fields = sc_read_json_object();
        $bean = BeanFactory::newBean($module);
        sc_apply($bean, $fields);
        foreach (sc_settable($bean) as $name => $def) {
            if ($def['required'] && $name !== 'account_name' && (!isset($bean->$name) || (string) $bean->$name === '')) {
                sc_fail(65, "$module needs $name. Nothing was written.");
            }
        }
        if ($module === 'Opportunities' && empty($bean->account_id)) {
            sc_fail(65, 'an opportunity needs its account: pass account_id, or account_name when exactly one account has that name. Nothing was written.');
        }
        if (($argv[3] ?? '') !== 'allow-duplicate') {
            $dups = sc_duplicates($bean);
            if ($dups) {
                sc_flush_noise();
                echo json_encode(['created' => false, 'likely_duplicates' => $dups], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), "\n";
                fwrite(STDERR, "[suitecrm] not created: " . count($dups) . " record(s) in $module look like this one. Show them to the user. Update one of them, or run this again with --allow-duplicate when they say it is a different one.\n");
                exit(4);
            }
        }
        // A record made without an owner belongs to the main admin, whom this script acts as.
        $byDefault = empty($bean->assigned_user_id);
        if ($byDefault) {
            $bean->assigned_user_id = $current_user->id;
        }
        $bean->save();
        $saved = sc_load($module, $bean->id);
        $owner = sc_owner_login($saved);
        if ($byDefault) {
            fwrite(STDERR, "[suitecrm] no owner was sent, so the record is assigned to the main admin ($owner). Send assigned_user_name with a login to give it to someone else.\n");
        }
        sc_done(['created' => true, 'assigned_to' => $owner, 'assigned_by_default' => $byDefault] + sc_view($saved));

    case 'get':
        sc_done(sc_view(sc_load($module, $argv[3] ?? '')));

    case 'update':
        $bean = sc_load($module, $argv[3] ?? '');
        $fields = sc_read_json_object();
        if ($fields === []) {
            sc_fail(65, 'no fields to change');
        }
        $shown = function ($record, string $name): string {
            if (!isset($record->$name) || !is_scalar($record->$name) || (string) $record->$name === '') {
                return '';
            }
            $type = $record->field_defs[$name]['type'] ?? '';
            if (in_array($type, ['date', 'datetime', 'datetimecombo'], true)) {
                return sc_stored_date($record, $name, $type);
            }
            return html_entity_decode((string) $record->$name, ENT_QUOTES);
        };
        $before = [];
        foreach (array_keys($fields) as $name) {
            $before[$name] = $shown($bean, $name);
        }
        sc_apply($bean, $fields);
        // In the browser, picking a new sales stage sets the probability that goes with it. SuiteCRM's save
        // only does that for an empty probability, so a stage sent without one gets the stage's own here.
        if ($module === 'Opportunities' && isset($fields['sales_stage']) && !array_key_exists('probability', $fields)) {
            $byStage = $app_list_strings['sales_probability_dom'] ?? [];
            if (isset($byStage[$bean->sales_stage]) && $byStage[$bean->sales_stage] !== '') {
                $before['probability'] = isset($bean->probability) ? (string) $bean->probability : '';
                $bean->probability = $byStage[$bean->sales_stage];
                $fields['probability'] = $bean->probability;
            }
        }
        $bean->save();
        $saved = sc_load($module, $bean->id);
        $changed = [];
        foreach (array_keys($fields) as $name) {
            $changed[$name] = ['before' => $before[$name], 'after' => $shown($saved, $name)];
        }
        sc_done(['updated' => true, 'module' => $module, 'id' => $saved->id, 'name' => html_entity_decode(sc_name($saved), ENT_QUOTES), 'changed' => $changed]);

    case 'link':
    case 'unlink':
        $bean = sc_load($module, $argv[3] ?? '');
        $link = $argv[4] ?? '';
        if (!isset(SC_LINKS[$module][$link])) {
            sc_fail(64, "$module has these links here: " . (implode(', ', array_keys(SC_LINKS[$module])) ?: 'none') . ". \"$link\" is not one of them.");
        }
        $other = sc_load(SC_LINKS[$module][$link][3], $argv[5] ?? '');
        if (!$bean->load_relationship($link)) {
            sc_fail(2, "SuiteCRM could not load the link $link of $module");
        }
        if ($action === 'link') {
            $extra = [];
            $role = $argv[6] ?? '';
            if ($role !== '') {
                if (SC_LINKS[$module][$link][0] !== 'opportunities_contacts') {
                    sc_fail(64, 'only the link between an opportunity and a contact has a role');
                }
                $roles = $app_list_strings['opportunity_relationship_type_dom'] ?? [];
                if (!array_key_exists($role, $roles)) {
                    sc_fail(65, "\"$role\" is not a contact role. The roles are: " . implode(', ', array_filter(array_keys($roles), 'strlen')));
                }
                $extra = ['contact_role' => $role];
            }
            $bean->$link->add($other->id, $extra);
        } else {
            $bean->$link->delete($bean->id, $other->id);
        }
        $ids = array_column(sc_linked($bean, $link), 'id');
        $has = in_array($other->id, $ids, true);
        if ($has !== ($action === 'link')) {
            sc_fail(2, "SuiteCRM did not " . ($action === 'link' ? 'keep' : 'remove') . " the link; read both records back");
        }
        sc_done([$action === 'link' ? 'linked' : 'unlinked' => true, 'module' => $module, 'id' => $bean->id, 'link' => $link,
            'other' => ['module' => $other->module_dir, 'id' => $other->id, 'name' => html_entity_decode(sc_name($other), ENT_QUOTES)]]);

    case 'list':
        $search = (string) ($argv[3] ?? '');
        $assigned = (string) ($argv[4] ?? '');
        $deleted = ($argv[5] ?? '0') === '1' ? 1 : 0;
        $limit = max(1, min(200, (int) ($argv[6] ?? 20)));
        $offset = max(0, (int) ($argv[7] ?? 0));
        $bean = BeanFactory::newBean($module);
        $t = $bean->table_name;
        $email = "(SELECT e.email_address FROM email_addr_bean_rel r JOIN email_addresses e ON e.id = r.email_address_id AND e.deleted = 0"
            . " WHERE r.bean_id = t.id AND r.bean_module = " . $db->quoted($module) . " AND r.deleted = 0 ORDER BY r.primary_address DESC LIMIT 1)";
        $columns = [
            'Accounts' => "t.id, t.name, t.account_type, t.industry, t.phone_office, t.billing_address_city AS city, $email AS email",
            'Contacts' => "t.id, t.first_name, t.last_name, t.title, t.phone_work, $email AS email, (SELECT a.name FROM accounts_contacts j JOIN accounts a ON a.id = j.account_id AND a.deleted = 0 WHERE j.contact_id = t.id AND j.deleted = 0 LIMIT 1) AS account",
            'Leads' => "t.id, t.first_name, t.last_name, t.status, t.lead_source, t.account_name AS company, $email AS email",
            'Opportunities' => "t.id, t.name, t.sales_stage, t.amount, t.probability, t.date_closed, (SELECT a.name FROM accounts_opportunities j JOIN accounts a ON a.id = j.account_id AND a.deleted = 0 WHERE j.opportunity_id = t.id AND j.deleted = 0 LIMIT 1) AS account",
        ][$module];
        $where = ["t.deleted = $deleted"];
        if ($search !== '') {
            $likes = [];
            foreach (array_unique([$search, to_html($search)]) as $form) {
                $like = $db->quoted('%' . str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $form) . '%');
                $likes[] = in_array($module, ['Contacts', 'Leads'], true)
                    ? "CONCAT(IFNULL(t.first_name, ''), ' ', IFNULL(t.last_name, '')) LIKE $like OR $email LIKE $like"
                    : "t.name LIKE $like";
            }
            $where[] = '(' . implode(' OR ', $likes) . ')';
        }
        if ($assigned !== '') {
            $user = sc_find_user($assigned);
            if ($user === null) {
                sc_fail(3, "there is no user \"$assigned\"");
            }
            $where[] = 't.assigned_user_id = ' . $db->quoted($user->id);
        }
        $cond = implode(' AND ', $where);
        $total = (int) $db->getOne("SELECT COUNT(*) FROM $t t WHERE $cond");
        $res = $db->limitQuery("SELECT $columns, u.user_name AS assigned_to, t.date_modified FROM $t t LEFT JOIN users u ON u.id = t.assigned_user_id WHERE $cond ORDER BY t.date_modified DESC, t.id", $offset, $limit);
        $rows = [];
        while ($row = $db->fetchByAssoc($res)) {
            $rows[] = array_map(fn ($v) => $v === null ? null : html_entity_decode((string) $v, ENT_QUOTES), $row);
        }
        sc_done(['module' => $module, 'deleted' => $deleted === 1, 'total' => $total, 'offset' => $offset, 'count' => count($rows), 'records' => $rows]);

    case 'delete':
        $bean = sc_load($module, $argv[3] ?? '');
        $bean->load_relationships();
        $related = [];
        foreach ($bean->get_linked_fields() as $link => $def) {
            if (in_array($link, ['created_by_link', 'modified_user_link', 'assigned_user_link', 'email_addresses', 'email_addresses_primary'], true) || !isset($bean->$link) || !is_object($bean->$link)) {
                continue;
            }
            try {
                $n = count((array) $bean->$link->get());
            } catch (Throwable $e) {
                continue;
            }
            if ($n > 0) {
                $related[$link] = $n;
            }
        }
        $view = sc_view($bean);
        $summary = ['module' => $module, 'id' => $bean->id, 'name' => $view['name'], 'linked_records' => $related,
            'restorable_links' => $view['links']];
        if (($argv[4] ?? '') !== 'yes') {
            sc_flush_noise();
            echo json_encode(['deleted' => false, 'preview' => $summary], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), "\n";
            fwrite(STDERR, "[suitecrm] nothing was deleted. This is what a delete would take out of view. SuiteCRM keeps the row, marked deleted, so records.sh undelete $module {$bean->id} brings it back with its email addresses and its account, contact and opportunity links. Its other links (the linked_records above: calls, meetings, notes, cases and the like) are cut for good. Show this to the user, and run it again with --yes-delete after a clear yes.\n");
            exit(0);
        }
        $bean->mark_deleted($bean->id);
        $still = $db->getOne("SELECT deleted FROM {$bean->table_name} WHERE id = " . $db->quoted($bean->id));
        if ((string) $still !== '1') {
            sc_fail(2, 'SuiteCRM did not mark the record deleted; read it back');
        }
        sc_done(['deleted' => true] + $summary + ['bring_it_back' => "records.sh undelete $module {$bean->id}"]);

    case 'undelete':
        $bean = sc_load($module, $argv[3] ?? '', true);
        if ((int) $bean->deleted !== 1) {
            sc_fail(2, "the record {$bean->id} is not deleted");
        }
        // mark_deleted stamps the record and the link rows it cuts within the same second or two.
        $stamp = (string) $db->getOne("SELECT date_modified FROM {$bean->table_name} WHERE id = " . $db->quoted($bean->id));
        $near = "BETWEEN DATE_SUB(" . $db->quoted($stamp) . ", INTERVAL 10 SECOND) AND DATE_ADD(" . $db->quoted($stamp) . ", INTERVAL 10 SECOND)";
        $bean->mark_undeleted($bean->id);
        $bean = sc_load($module, $bean->id);
        $restored = ['emails' => [], 'links' => []];
        $res = $db->query("SELECT e.email_address, r.primary_address FROM email_addr_bean_rel r JOIN email_addresses e ON e.id = r.email_address_id AND e.deleted = 0"
            . " WHERE r.bean_id = " . $db->quoted($bean->id) . " AND r.bean_module = " . $db->quoted($module) . " AND r.deleted = 1 AND r.date_modified $near ORDER BY r.primary_address DESC");
        $addresses = [];
        while ($row = $db->fetchByAssoc($res)) {
            $addresses[$row['email_address']] = (int) $row['primary_address'] === 1;
        }
        if ($addresses) {
            foreach ($addresses as $address => $primary) {
                $bean->emailAddress->addAddress($address, $primary);
                $restored['emails'][] = $address;
            }
            $bean->emailAddress->save($bean->id, $module);
        }
        foreach (SC_LINKS[$module] as $link => [$table, $mine, $theirs, $otherModule]) {
            $other = BeanFactory::newBean($otherModule);
            $extraColumn = $table === 'opportunities_contacts' ? ', j.contact_role' : '';
            $res = $db->query("SELECT j.$theirs AS other_id$extraColumn FROM $table j JOIN {$other->table_name} o ON o.id = j.$theirs AND o.deleted = 0"
                . " WHERE j.$mine = " . $db->quoted($bean->id) . " AND j.deleted = 1 AND j.date_modified $near");
            $ids = [];
            while ($row = $db->fetchByAssoc($res)) {
                $ids[$row['other_id']] = $row['contact_role'] ?? '';
            }
            if ($ids && $bean->load_relationship($link)) {
                foreach ($ids as $otherId => $role) {
                    $bean->$link->add($otherId, $role !== '' ? ['contact_role' => $role] : []);
                    $restored['links'][] = ['link' => $link, 'id' => $otherId];
                }
            }
        }
        $saved = sc_load($module, $bean->id);
        sc_done(['undeleted' => true, 'restored' => $restored] + sc_view($saved));

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
