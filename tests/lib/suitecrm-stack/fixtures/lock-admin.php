<?php
// Test fixture: what a locked-out admin looks like. Sets the main admin's password to the line on stdin and
// makes the account inactive, in one SQL UPDATE, so that the stored hash really is another password's.
// (setNewPassword() followed by save() would write the old hash back, and the lockout would be a fake one.)
// Usage: lock-admin.php [demote]     the other password on stdin; demote also takes the admin right away
require __DIR__ . '/boot.php';
$hash = User::getPasswordHash(sc_read_secret_line());
$demote = ($argv[1] ?? '') === 'demote';
$db->query("UPDATE users SET user_hash = " . $db->quoted($hash) . ", status = 'Inactive'" . ($demote ? ', is_admin = 0' : '') . " WHERE id = '1'", true);
sc_done(['locked' => true, 'demoted' => $demote]);
