<?php
// Test fixture: the main admin's own number, date and time settings, set the way SuiteCRM's profile screen sets
// them (User::setPreference for each, then savePreferencesToDB).
// Usage: records-profile.php european | restore | show
//   european  1000s separator ".", decimal symbol ",", dates as d/m/Y, times as H:i, time zone Europe/Berlin.
//             The stored profile as it was is kept in a file first, once.
//   restore   puts the stored profile back exactly as it was before "european", and removes that file
//   show      prints the stored values, read from the database
require __DIR__ . '/boot.php';
const SC_PROFILE_KEPT = '/tmp/records-profile.kept';
$mode = $argv[1] ?? '';
$stored = function () use ($db) {
    return $db->fetchOne("SELECT id, contents FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global' AND deleted = 0");
};
$values = function () use ($stored) {
    $row = $stored();
    $all = $row ? unserialize(base64_decode($row['contents']), ['allowed_classes' => false]) : [];
    return array_intersect_key($all, array_flip(['num_grp_sep', 'dec_sep', 'datef', 'timef', 'timezone']));
};
switch ($mode) {
    case 'european':
        if (!is_file(SC_PROFILE_KEPT)) {
            $row = $stored();
            file_put_contents(SC_PROFILE_KEPT, json_encode($row ?: null));
        }
        $admin = BeanFactory::getBean('Users', '1');
        foreach (['num_grp_sep' => '.', 'dec_sep' => ',', 'datef' => 'd/m/Y', 'timef' => 'H:i', 'timezone' => 'Europe/Berlin'] as $name => $value) {
            $admin->setPreference($name, $value, 0, 'global');
        }
        $admin->savePreferencesToDB();
        sc_done(['profile' => 'european', 'stored' => $values()]);
        // no break: sc_done exits

    case 'restore':
        if (!is_file(SC_PROFILE_KEPT)) {
            sc_done(['profile' => 'as it was', 'stored' => $values()]);
        }
        $kept = json_decode((string) file_get_contents(SC_PROFILE_KEPT), true);
        if (is_array($kept)) {
            $db->query('UPDATE user_preferences SET contents = ' . $db->quoted($kept['contents']) . ' WHERE id = ' . $db->quoted($kept['id']));
        } else {
            $db->query("DELETE FROM user_preferences WHERE assigned_user_id = '1' AND category = 'global'");
        }
        unlink(SC_PROFILE_KEPT);
        // This process still holds the european values: keep SuiteCRM's shutdown from writing them back.
        $GLOBALS['savePreferencesToDB'] = false;
        sc_done(['profile' => 'restored', 'stored' => $values()]);
        // no break: sc_done exits

    case 'show':
        sc_done(['stored' => $values()]);
        // no break: sc_done exits

    default:
        sc_fail(64, 'usage: records-profile.php european | restore | show');
}
