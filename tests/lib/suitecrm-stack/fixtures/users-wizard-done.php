<?php
// Test fixture: the two preferences that finishing SuiteCRM's first-login wizard leaves behind for a user
// (ut and timezone). SuiteCRM looks at them before it sends a new user to the wizard; with them set, the
// next thing it checks at a sign-in is whether the password has expired.
// Usage: users-wizard-done.php LOGIN         sets them, in the person's own name, as the wizard does
//        users-wizard-done.php LOGIN check   prints one line of JSON with what is stored now:
//                                            {"wizard_done": bool, "timezone": "..."}
require __DIR__ . '/boot.php';
$user = sc_find_user($argv[1] ?? '');
if ($user === null) {
    sc_fail(3, 'no such user');
}
if (($argv[2] ?? '') === 'check') {
    $row = $db->fetchOne("SELECT contents FROM user_preferences WHERE deleted = 0 AND category = 'global' AND assigned_user_id = " . $db->quoted($user->id));
    $stored = empty($row['contents']) ? [] : (array) unserialize(base64_decode($row['contents']), ['allowed_classes' => false]);
    sc_flush_noise();
    echo json_encode(['wizard_done' => !empty($stored['ut']) && !empty($stored['timezone']), 'timezone' => (string) ($stored['timezone'] ?? '')]), "\n";
    exit(0);
}
// As the person: SuiteCRM merges into the stored preferences only for the acting user.
$GLOBALS['current_user'] = $user;
$user->setPreference('ut', 1);
$user->setPreference('timezone', 'Europe/Lisbon');
$user->savePreferencesToDB();
sc_done(['wizard_done' => $user->user_name]);
