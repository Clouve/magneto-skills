<?php
// Test fixture: the main admin's account as the database has it now, and whether the password on stdin is
// the one stored. The comparison happens here, so that no hash ever leaves the container.
// Usage: users-admin-state.php     the password to compare on stdin
// Prints one line of JSON: {"password_matches": bool, "status": "...", "is_admin": bool}
require __DIR__ . '/boot.php';
$password = sc_read_secret_line();
$row = $db->fetchOne("SELECT user_hash, status, is_admin FROM users WHERE id = '1' AND deleted = 0");
sc_flush_noise();
echo json_encode([
    'password_matches' => !empty($row['user_hash']) && User::checkPassword($password, (string) $row['user_hash']),
    'status' => (string) ($row['status'] ?? ''),
    'is_admin' => (int) ($row['is_admin'] ?? 0) === 1,
]), "\n";
