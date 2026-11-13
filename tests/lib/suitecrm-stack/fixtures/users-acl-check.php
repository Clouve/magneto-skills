<?php
// Test fixture: what a role really lets a person do in Accounts, asked of SuiteCRM's own checks while acting
// as that person. The first run makes two accounts: one that belongs to the main admin ("ACL probe first")
// and one that belongs to the person ("ACL probe second").
// Usage: users-acl-check.php LOGIN
//        users-acl-check.php LOGIN import-update
// The first form prints one line of JSON:
//   list        the list query SuiteCRM builds for her (create_new_list_query): rows, sees_first, sees_own
//   export      SuiteCRM's own export() from include/export_utils.php: refused, has_first, has_own
//   first       ACLController::checkAccess for view, list, edit, delete, export and massupdate on the main
//               admin's account (she is not its owner), and the bean's own ACLAccess for the same record
//   own         the same for her own account
//   module      the two checks SuiteCRM makes once for the whole module: import (the import wizard's
//               controller) and massupdate (the mass update form), both asked with "is the owner"
// import-update asks the import wizard's own question first (may she import into Accounts at all) and, when
// the answer is yes, runs SuiteCRM's Importer as her on one row that names the main admin's account by its
// id, with "update existing records", and a new phone number. It prints {"import_open": bool,
// "import_changed_first": bool} and puts the phone number back.
require __DIR__ . '/boot.php';
require_once 'modules/ACLActions/ACLAction.php';
require_once 'include/export_utils.php';
require_once 'modules/Import/Importer.php';
require_once 'modules/Import/sources/ImportFile.php';

$her = sc_find_user($argv[1] ?? '');
if ($her === null) {
    sc_fail(3, 'no such user');
}
$ids = [];
foreach (['first' => '1', 'second' => $her->id] as $which => $ownerId) {
    $name = "ACL probe $which";
    $id = $db->getOne('SELECT id FROM accounts WHERE deleted = 0 AND name = ' . $db->quoted($name));
    if (empty($id)) {
        $account = BeanFactory::newBean('Accounts');
        $account->name = $name;
        $account->assigned_user_id = $ownerId;
        $account->phone_office = '555-0100';
        $account->save();
        $id = $account->id;
    }
    $ids[$which] = $id;
}

// From here on, as her: no admin rights, her roles, nothing cached from the admin.
$GLOBALS['current_user'] = $her;
unset($_SESSION['ACL']);
ACLAction::getUserActions($her->id, true);

if (($argv[2] ?? '') === 'import-update') {
    $phoneSql = 'SELECT phone_office FROM accounts WHERE id = ' . $db->quoted($ids['first']);
    $before = (string) $db->getOne($phoneSql);
    // modules/Import/controller.php asks exactly this before it shows the wizard.
    $open = (bool) ACLController::checkAccess('Accounts', 'import', true);
    if ($open) {
        $file = 'upload/users_acl_check_' . $her->id;
        file_put_contents($file, '"' . $ids['first'] . '","555-9999"' . "\n");
        $_REQUEST = ['module' => 'Import', 'import_module' => 'Accounts', 'source' => 'csv', 'has_header' => 'off', 'import_type' => 'update',
            'custom_delimiter' => ',', 'custom_enclosure' => '"', 'columncount' => 2, 'colnum_0' => 'id', 'colnum_1' => 'phone_office',
            'importlocale_charset' => 'UTF-8', 'importlocale_dateformat' => 'Y-m-d', 'importlocale_timeformat' => 'H:i',
            'importlocale_timezone' => 'UTC', 'importlocale_currency' => '-99', 'importlocale_default_currency_significant_digits' => 2,
            'importlocale_num_grp_sep' => ',', 'importlocale_dec_sep' => '.', 'importlocale_default_locale_name_format' => 's f l'];
        $importer = new Importer(new ImportFile($file, ',', '"', false), BeanFactory::newBean('Accounts'));
        $importer->import();
        @unlink($file);
    }
    $after = (string) $db->getOne($phoneSql);
    $db->query('UPDATE accounts SET phone_office = ' . $db->quoted($before) . ' WHERE id = ' . $db->quoted($ids['first']), true);
    sc_flush_noise();
    echo json_encode(['import_open' => $open, 'import_changed_first' => $after !== $before]), "\n";
    exit(0);
}

$seed = BeanFactory::newBean('Accounts');
$listed = [];
$res = $db->query($seed->create_new_list_query('', "accounts.name LIKE 'ACL probe %'"));
while ($row = $db->fetchByAssoc($res)) {
    $listed[] = $row['id'];
}

$export = ['refused' => true, 'has_first' => false, 'has_own' => false];
// export() ends the process when the module's export right is missing, so the same check comes first.
if (ACLController::checkAccess('Accounts', 'export', true)) {
    $csv = (string) export('Accounts');
    $export = ['refused' => false, 'has_first' => strpos($csv, 'ACL probe first') !== false, 'has_own' => strpos($csv, 'ACL probe second') !== false];
}

$records = [];
foreach ($ids as $which => $id) {
    $account = BeanFactory::newBean('Accounts');
    $account->retrieve($id);
    $owner = $account->isOwner($her->id);
    foreach (['view', 'list', 'edit', 'delete', 'export', 'massupdate'] as $action) {
        $records[$which]['checkAccess'][$action] = (bool) ACLController::checkAccess('Accounts', $action, $owner);
    }
    foreach (['view', 'list', 'edit', 'delete', 'export'] as $action) {
        $records[$which]['ACLAccess'][$action] = (bool) $account->ACLAccess($action);
    }
}

sc_flush_noise();
echo json_encode([
    'list' => ['rows' => count($listed), 'sees_first' => in_array($ids['first'], $listed, true), 'sees_own' => in_array($ids['second'], $listed, true)],
    'export' => $export,
    'first' => $records['first'],
    'own' => $records['second'],
    'module' => [
        'import' => (bool) ACLController::checkAccess('Accounts', 'import', true),
        'massupdate' => (bool) ACLController::checkAccess('Accounts', 'massupdate', true),
    ],
]), "\n";
