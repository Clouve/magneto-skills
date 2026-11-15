<?php
/**
 * LimeSurvey skill: remote/lib/boot.php (included by the .php scripts in remote/, inside the LimeSurvey container)
 *
 * Starts LimeSurvey's own code from the command line, as the site's main admin, without HTTP, a password, a
 * session row or a changed setting. It starts LimeSurvey's web application class (the console application
 * refuses every permission check), keeps the session in memory, and hands back the application, the admin and a
 * RemoteControl handler whose calls all run as that admin.
 *
 * Run it as the web server's user, never as root: run-in-limesurvey.sh does. It refuses root, because files in
 * tmp/ would end up owned by root, and any user that does not own tmp/.
 *
 * What a script gets from this file:
 *   ls_rc_request()               the JSON object on stdin, as an array
 *   ls_boot()                     array('app', 'admin', 'controller', 'handle', 'root', 'public_url')
 *   ls_rc_reply($result)          one line on stdout, {"result": ..., "error": null}, exit 0
 *   ls_rc_fail($message)          one line on stdout, {"result": null, "error": "..."}, exit 1
 *   ls_rc_reply_file($path)       a file as base64 in the reply, streamed, then removed
 *   ls_rc_raw_file($path)         a file's bytes alone on stdout, streamed, then removed, exit 0
 * Notices and warnings go to stderr. LS_RC_DEBUG=1 shows all of them. LS_ROOT names the LimeSurvey folder
 * (default: the current folder, then /var/www/html).
 *
 * What it leans on in LimeSurvey, checked on 7.9.1 and 7.10.0 (reference/remotecontrol.md lists the files): the
 * constants and the start in index.php, remotecontrol_handle's constructor and its protected _checkSessionKey() and
 * _jumpStartSession(), AdminController, the User scopes active() and notexpired(), and the permissions table.
 */

$lsRcReplied = false;
$lsRcStdout = fopen('php://stdout', 'w');
$lsRcQuiet = E_ERROR | E_PARSE | E_CORE_ERROR | E_COMPILE_ERROR | E_USER_ERROR | E_RECOVERABLE_ERROR;

/** Throws away anything LimeSurvey printed, so that stdout stays one reply. What it printed goes to stderr. */
function ls_rc_drop_output()
{
    while (ob_get_level() > 0) {
        $stray = ob_get_clean();
        if ($stray !== '' && $stray !== false) {
            fwrite(STDERR, "ls-rc: output kept out of the reply:\n" . substr($stray, 0, 4000) . "\n");
        }
    }
}

function ls_rc_reply($result, $error = null, $exitCode = 0)
{
    global $lsRcReplied, $lsRcStdout;
    ls_rc_drop_output();
    $flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE;
    $json = json_encode(array('result' => $result, 'error' => $error), $flags);
    if ($json === false) {
        $json = json_encode(array('result' => null, 'error' => 'reply could not be encoded as JSON: ' . json_last_error_msg()));
        $exitCode = 1;
    }
    $lsRcReplied = true;
    fwrite($lsRcStdout, $json . "\n");
    fflush($lsRcStdout);
    exit($exitCode);
}

function ls_rc_fail($message)
{
    ls_rc_reply(null, $message, 1);
}

/** Reply with a file as base64, streamed so that a large export never sits in memory. Removes the file. */
function ls_rc_reply_file($path)
{
    global $lsRcReplied, $lsRcStdout;
    $in = @fopen($path, 'r');
    if (!$in) {
        ls_rc_fail("the export file $path could not be read");
    }
    ls_rc_drop_output();
    stream_filter_append($in, 'convert.base64-encode', STREAM_FILTER_READ);
    $lsRcReplied = true;
    fwrite($lsRcStdout, '{"result":"');
    stream_copy_to_stream($in, $lsRcStdout);
    fclose($in);
    @unlink($path);
    fwrite($lsRcStdout, '","error":null}' . "\n");
    fflush($lsRcStdout);
    exit(0);
}

/** Write a file's bytes to stdout and nothing else, then remove it. For exports that the agent saves as a file. */
function ls_rc_raw_file($path)
{
    global $lsRcReplied, $lsRcStdout;
    $in = @fopen($path, 'r');
    if (!$in) {
        fwrite(STDERR, "ls-rc: the export file could not be read\n");
        $lsRcReplied = true;
        exit(1);
    }
    ls_rc_drop_output();
    $lsRcReplied = true;
    stream_copy_to_stream($in, $lsRcStdout);
    fclose($in);
    @unlink($path);
    fflush($lsRcStdout);
    exit(0);
}

// A fatal error, or LimeSurvey calling exit, must still give a JSON reply.
register_shutdown_function(function () {
    global $lsRcReplied;
    if ($lsRcReplied) {
        return;
    }
    $last = error_get_last();
    $message = 'LimeSurvey stopped without a reply';
    if ($last && in_array($last['type'], array(E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR, E_RECOVERABLE_ERROR))) {
        $message = 'PHP fatal error: ' . $last['message'] . ' in ' . $last['file'] . ':' . $last['line'];
    }
    ls_rc_reply(null, $message, 1);
});

ini_set('display_errors', '0');
ini_set('log_errors', '1');
ini_set('error_log', '');
ini_set('html_errors', '0');
error_reporting(getenv('LS_RC_DEBUG') ? E_ALL : $lsRcQuiet);
ob_start();

if (PHP_SAPI !== 'cli') {
    ls_rc_fail('this script runs from the command line only');
}

/** The request: one JSON object on stdin. */
function ls_rc_request()
{
    $raw = stream_get_contents(STDIN);
    $request = json_decode((string) $raw, true);
    if (!is_array($request)) {
        ls_rc_fail('send one JSON object on stdin');
    }
    return $request;
}

/** Where LimeSurvey is. Stops with a clear message when the folder is not a LimeSurvey install or the user is wrong. */
function ls_rc_root()
{
    $root = getenv('LS_ROOT');
    if (!$root) {
        $root = is_file(getcwd() . '/application/config/version.php') ? getcwd() : '/var/www/html';
    }
    $root = rtrim(realpath($root) ?: $root, '/');
    foreach (array('index.php', 'application/config/internal.php', 'application/core/LSYii_Application.php',
        'application/helpers/remotecontrol/remotecontrol_handle.php', 'vendor/autoload.php') as $needed) {
        if (!is_file("$root/$needed")) {
            ls_rc_fail("$root does not look like LimeSurvey: $needed is missing");
        }
    }
    if (!is_file("$root/application/config/config.php")) {
        ls_rc_fail('LimeSurvey is not installed yet: application/config/config.php is missing');
    }
    // LimeSurvey makes a new security.php, with new keys, the moment it starts without one. With data in the
    // database that would leave every encrypted value unreadable, so this never starts it in that state.
    if (!is_file("$root/application/config/security.php")) {
        ls_rc_fail('application/config/security.php is missing. It holds the keys that encrypted answers and the SMTP password need, and LimeSurvey would make new ones if it started now. Put the file back from a backup first (playbooks/restore-from-backup.md)');
    }
    if (!function_exists('posix_geteuid')) {
        ls_rc_fail('the PHP posix extension is missing, so this cannot check which user runs it');
    }
    $euid = posix_geteuid();
    if ($euid === 0) {
        ls_rc_fail('refusing to run as root: files in tmp/ would end up owned by root. Run it as the web server user (run-in-limesurvey.sh does)');
    }
    $webUid = @fileowner("$root/tmp");
    if ($webUid !== false && $webUid !== 0 && $webUid !== $euid) {
        $pw = posix_getpwuid($webUid);
        ls_rc_fail('refusing to run as uid ' . $euid . ': tmp/ belongs to ' . ($pw ? $pw['name'] : "uid $webUid") . '. Run it as that user');
    }
    return $root;
}

/**
 * Starts LimeSurvey's web application the way index.php does, without running a request, and returns
 * array('app', 'admin', 'controller', 'handle', 'root', 'public_url').
 */
function ls_boot()
{
    global $lsRcQuiet;
    $root = ls_rc_root();
    $GLOBALS['root'] = $root;
    chdir($root);

    $publicUrl = array();
    $userConfig = (function ($file) use ($root) {
        defined('BASEPATH') or define('BASEPATH', $root . '/vendor/yiisoft/yii/framework/');
        return require $file;
    })("$root/application/config/config.php");
    if (is_array($userConfig) && !empty($userConfig['config']['publicurl'])) {
        $publicUrl = parse_url($userConfig['config']['publicurl']) ?: array();
    }
    $https = isset($publicUrl['scheme']) && $publicUrl['scheme'] === 'https';
    $host = isset($publicUrl['host']) ? $publicUrl['host'] : 'localhost';
    $port = isset($publicUrl['port']) ? (int) $publicUrl['port'] : ($https ? 443 : 80);
    $_SERVER['SCRIPT_FILENAME'] = "$root/index.php";
    $_SERVER['SCRIPT_NAME'] = '/index.php';
    $_SERVER['PHP_SELF'] = '/index.php';
    $_SERVER['DOCUMENT_ROOT'] = $root;
    $_SERVER['REQUEST_URI'] = '/index.php/admin/remotecontrol';
    $_SERVER['REQUEST_METHOD'] = 'POST';
    $_SERVER['CONTENT_TYPE'] = 'application/json';
    $_SERVER['SERVER_PROTOCOL'] = 'HTTP/1.1';
    $_SERVER['SERVER_NAME'] = $host;
    $_SERVER['SERVER_PORT'] = $port;
    $_SERVER['HTTP_HOST'] = $host . (($https && $port === 443) || (!$https && $port === 80) ? '' : ":$port");
    $_SERVER['REMOTE_ADDR'] = '127.0.0.1';
    $_SERVER['HTTP_USER_AGENT'] = 'ls-rc-cli';
    if ($https) {
        $_SERVER['HTTPS'] = 'on';
    }
    $_SESSION = array();

    define('SELF', 'index.php');
    define('ROOT', $root);
    define('EXT', '.php');
    defined('BASEPATH') or define('BASEPATH', "$root/vendor/yiisoft/yii/framework/");
    define('FCPATH', "$root/");
    define('SYSDIR', 'framework');
    define('APPPATH', "$root/application/");
    define('YII_DEBUG', false);
    define('YII_ENABLE_ERROR_HANDLER', false);
    define('YII_ENABLE_EXCEPTION_HANDLER', false);

    require_once "$root/vendor/autoload.php";
    require_once BASEPATH . 'yii.php';
    require_once APPPATH . 'core/LSYii_Application.php';
    $config = require APPPATH . 'config/internal.php';
    Yii::$enableIncludePath = false;

    // The session class extends Yii's own, so it is declared once Yii is loaded.
    require __DIR__ . '/boot-session.php';
    $config['components']['session'] = array('class' => 'LsRcSession');

    $app = Yii::createApplication('LSYii_Application', $config);
    error_reporting(getenv('LS_RC_DEBUG') ? E_ALL : $lsRcQuiet);

    // The checks AdminController::run() makes before RemoteControl answers.
    if (method_exists('SettingGlobal', 'isAdministrationLocked') && SettingGlobal::isAdministrationLocked()) {
        ls_rc_fail('the administration is locked for maintenance (setmaintenancemode hard-cli). A backup, a restore or an upgrade holds that lock while it runs. Try again when it is unlocked; verify-health.sh shows the mode');
    }
    if ((int) $app->getConfig('DBVersion') !== (int) $app->getConfig('dbversionnumber')) {
        ls_rc_fail('the database is at version ' . $app->getConfig('DBVersion') . ' and the code needs ' . $app->getConfig('dbversionnumber') . '. The database update has to run first (playbooks/recover-from-a-failed-upgrade.md)');
    }

    // What LSYii_Controller sets up for every admin request.
    $app->loadHelper('expressions.em_manager');
    $app->loadHelper('replacements');
    Yii::import('application.helpers.globalsettings');
    Yii::import('application.helpers.remotecontrol.*');
    Yii::import('application.libraries.BigData', true); // BigFile, which the export methods return
    $wanted = (int) $app->getConfig('memory_limit');
    if (ini_get('memory_limit') != -1 && convertPHPSizeToBytes(ini_get('memory_limit')) < convertPHPSizeToBytes($wanted . 'M')) {
        @ini_set('memory_limit', $wanted . 'M');
    }
    $tz = $app->getConfig('displayTimezone');
    if (empty($tz) || !in_array($tz, timezone_identifiers_list())) {
        $app->setConfig('displayTimezone', 'UTC');
    }
    $app->setLanguage($app->getConfig('defaultlang'));

    // The two protected methods this leans on. If LimeSurvey renames them, stop here with a clear message.
    foreach (array('_checkSessionKey', '_jumpStartSession') as $internal) {
        if (!method_exists('remotecontrol_handle', $internal)) {
            ls_rc_fail("this LimeSurvey version has no remotecontrol_handle::$internal, so the skill's scripts need an update");
        }
    }

    // The controller and the RemoteControl handler extend LimeSurvey's own classes, which can be loaded now.
    require __DIR__ . '/boot-classes.php';

    // The site's main admin: the first active user with the global superadmin permission.
    $uids = $app->db->createCommand(
        "SELECT p.uid FROM {{permissions}} p WHERE p.entity = 'global' AND p.permission = 'superadmin' AND p.read_p = 1 ORDER BY p.uid"
    )->queryColumn();
    $admin = null;
    foreach ($uids as $uid) {
        $admin = User::model()->notexpired()->active()->findByPk($uid);
        if ($admin) {
            break;
        }
    }
    if (!$admin) {
        ls_rc_fail('no active user has the global superadmin permission');
    }

    $controller = new LsRcController('admin');
    $app->setController($controller);
    $handle = new LsRcHandle($controller, $admin->users_name);

    return array('app' => $app, 'admin' => $admin, 'controller' => $controller, 'handle' => $handle,
        'root' => $root, 'public_url' => $publicUrl);
}

/** Runs $work (a function of the booted context) and turns anything it throws into a JSON error. */
function ls_rc_run(callable $work)
{
    try {
        $ctx = ls_boot();
        $work($ctx);
        ls_rc_fail('the script ended without a reply');
    } catch (Throwable $e) {
        $file = $e->getFile();
        if (!empty($GLOBALS['root']) && strpos($file, $GLOBALS['root'] . '/') === 0) {
            $file = substr($file, strlen($GLOBALS['root']) + 1);
        }
        ls_rc_fail(get_class($e) . ': ' . $e->getMessage() . ' (' . $file . ':' . $e->getLine() . ')');
    }
}
