<?php
/**
 * LimeSurvey skill: remote/lib/keys-probe.php (run as www-data by restore.sh and health.sh)
 *
 * Says whether the encryption keys in one security.php can read values that the database holds encrypted. It does
 * not start LimeSurvey, so it also works on a site that is locked, half restored or without a security.php of its
 * own, and it can test the keys of a backup before they are put in place.
 *
 * Usage: php keys-probe.php <path of a security.php>     the encrypted values on stdin, one per line
 *
 * The values are what LimeSurvey stored: the SMTP password, an encrypted participant field, an encrypted answer,
 * an encrypted setting of a plugin (lib/site.sh, ls_encrypted_samples, picks a few). LimeSurvey stores each as base64 of a sodium secret box, made
 * with the nonce and the key in security.php (application/core/LSSodium.php).
 *
 * It prints one word and nothing else: ok (at least one value was read), wrong (there were values and none could
 * be read), untested (no value to test with), or nokeys (the file is not a security.php with keys). It never
 * prints a key or a value. Exit code: 0.
 */
error_reporting(0);
$file = isset($argv[1]) ? $argv[1] : '';
if ($file === '' || !is_file($file) || is_link($file) || !function_exists('sodium_crypto_secretbox_open')) {
    echo "nokeys\n";
    exit(0);
}
defined('BASEPATH') or define('BASEPATH', '/nonexistent/');
ob_start();
$config = include $file;
ob_end_clean();
if (!is_array($config) || empty($config['encryptionnonce']) || empty($config['encryptionsecretboxkey'])) {
    echo "nokeys\n";
    exit(0);
}
try {
    $nonce = sodium_hex2bin((string) $config['encryptionnonce']);
    $key = sodium_hex2bin((string) $config['encryptionsecretboxkey']);
} catch (Throwable $e) {
    echo "nokeys\n";
    exit(0);
}
$tested = 0;
$read = 0;
while (($line = fgets(STDIN)) !== false) {
    $value = trim($line);
    // A plugin's setting is stored as JSON: the encrypted text in quotes.
    if ($value !== '' && $value[0] === '"') {
        $decoded = json_decode($value);
        $value = is_string($decoded) ? $decoded : '';
    }
    if ($value === '' || $value === 'null') {
        continue;
    }
    $box = base64_decode($value, true);
    // A secret box is its text plus 16 bytes. Anything shorter was never encrypted.
    if ($box === false || strlen($box) < 17) {
        continue;
    }
    $tested++;
    try {
        if (sodium_crypto_secretbox_open($box, $nonce, $key) !== false) {
            $read++;
        }
    } catch (Throwable $e) {
        // not readable with these keys
    }
}
echo $tested === 0 ? 'untested' : ($read > 0 ? 'ok' : 'wrong'), "\n";
