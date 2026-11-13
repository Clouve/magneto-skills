<?php
/**
 * SuiteCRM skill: remote/boot.php (included by the other remote/*.php scripts; runs inside the SuiteCRM
 * container as www-data, started by remote/entry.sh).
 *
 * Starts SuiteCRM's own code the way its command-line tools do, signs in as the system's first admin, and
 * gives the scripts a few helpers. A script that includes this file runs with that admin's rights: roles and
 * security groups do not apply to it, and SuiteCRM records what it writes as that admin's own work ("created
 * by", "modified by" and the audit trail name the main admin). It refuses to run as root (exit 64).
 *
 * Output rule: a script prints one JSON document on stdout and its messages on stderr. SuiteCRM's legacy code
 * prints notices and HTML of its own, so everything it prints is held back and sent to stderr at the end.
 *
 * Exit codes the scripts share: 0 done; 64 usage; 65 bad input; 1 SuiteCRM could not be started;
 * 2 SuiteCRM refused or the read-back did not match; 3 not found; 4 a likely duplicate, nothing written.
 * Never 5, 6, 7 or 255: those are ssh's and sshpass's.
 */

if (PHP_SAPI !== 'cli') {
    exit(1);
}
// SuiteCRM's files belong to the web user. Started as root, this would leave cache files the web server
// can't replace. remote/entry.sh always starts it as www-data.
if (function_exists('posix_geteuid') && posix_geteuid() === 0) {
    fwrite(STDERR, "[suitecrm] this script runs as www-data, the web server's user, not as root. Use the skill's own scripts (records.sh, users.sh and the others), which start it that way. Nothing was changed.\n");
    exit(64);
}

/** Prints a message on stderr and ends with the code. */
function sc_fail(int $code, string $message): void
{
    sc_flush_noise();
    fwrite(STDERR, '[suitecrm] ' . $message . "\n");
    exit($code);
}

/** Sends what SuiteCRM printed so far to stderr, so that stdout holds only the script's JSON. */
function sc_flush_noise(): void
{
    while (ob_get_level() > 0) {
        $noise = ob_get_clean();
        if (is_string($noise) && trim($noise) !== '') {
            fwrite(STDERR, rtrim($noise) . "\n");
        }
    }
}

/** Prints the result as JSON and ends with 0. */
function sc_done($result): void
{
    sc_flush_noise();
    echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
    exit(0);
}

/** Reads all of stdin as one JSON object. */
function sc_read_json_object(): array
{
    $text = stream_get_contents(STDIN);
    if ($text === false || trim($text) === '') {
        sc_fail(65, 'no JSON on stdin');
    }
    $data = json_decode($text, true);
    if (!is_array($data) || ($data !== [] && array_keys($data) === range(0, count($data) - 1))) {
        sc_fail(65, 'stdin is not a JSON object such as {"name": "Globex"}');
    }
    foreach ($data as $key => $value) {
        if (!is_string($key) || !(is_scalar($value) || $value === null)) {
            sc_fail(65, "the value of \"$key\" is not text, a number, true, false or null");
        }
    }
    return $data;
}

/** Reads the first line of stdin, without its line end: a password. */
function sc_read_secret_line(): string
{
    $line = fgets(STDIN);
    if ($line === false) {
        sc_fail(65, 'no password on stdin');
    }
    $line = rtrim($line, "\r\n");
    if ($line === '') {
        sc_fail(65, 'the password on stdin is empty');
    }
    return $line;
}

ob_start();
error_reporting(E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_WARNING & ~E_STRICT);

if (!is_file('/var/www/html/public/legacy/include/entryPoint.php') || !is_file('/var/www/html/public/legacy/config.php')) {
    sc_fail(1, 'SuiteCRM is not installed in /var/www/html');
}
chdir('/var/www/html/public/legacy');
if (!defined('sugarEntry')) {
    define('sugarEntry', true);
}
require_once 'include/entryPoint.php';

global $current_user, $db, $sugar_config, $app_list_strings, $app_strings, $current_language;
$current_user = BeanFactory::newBean('Users');
$current_user->getSystemUser();
if (empty($current_user->id)) {
    sc_fail(1, 'SuiteCRM has no active admin account to act as');
}
if (empty($current_language)) {
    $current_language = $sugar_config['default_language'] ?? 'en_us';
}
if (empty($app_list_strings)) {
    $app_list_strings = return_app_list_strings_language($current_language);
}
if (empty($app_strings)) {
    $app_strings = return_application_language($current_language);
}

/** The installed SuiteCRM version, from the code. */
function sc_version(): string
{
    return (string) ($GLOBALS['suitecrm_version'] ?? '');
}

/** True when the user is the deployment's main admin: id 1, or the login Clouve created. */
function sc_is_main_admin($user, string $mainLogin): bool
{
    if ((string) $user->id === '1') {
        return true;
    }
    return $mainLogin !== '' && strcasecmp((string) $user->user_name, $mainLogin) === 0;
}

/** Finds a user by login. Returns the bean, or null. */
function sc_find_user(string $login)
{
    global $db;
    $id = $db->getOne('SELECT id FROM users WHERE deleted = 0 AND user_name = ' . $db->quoted($login));
    if (empty($id)) {
        return null;
    }
    $user = BeanFactory::getBean('Users', $id);
    return empty($user->id) ? null : $user;
}
