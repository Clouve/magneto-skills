<?php
// Moodle DevOps Skill: lib/set-temp-password.php, run by scripts/temp-password.sh in the moodle container as
// www-data, through php -r (this file without its first line):
//
//   php -r <code> -- lookup <username>   finds the account and says whether Moodle keeps its password; reads nothing
//   php -r <code> -- set <user id>       sets the password it reads on stdin
//
// It prints STEP and RESULT lines and nothing else, never the password. The set half does what Moodle's own profile
// page does when an admin types a new password (user/editadvanced.php): the account's sign-in plugin sets it
// (password::update() adds the site's pepper, records user_password_updated and removes web service tokens when the
// site asks for that), the External Database sync's create_password preference is cleared so that Moodle's "Send new
// user passwords" task doesn't replace the password, a new one is required at the next sign-in, and the account's
// sessions end. Then it checks the password against the stored hash. Like Moodle's own password pages, it records no
// user_updated event: no profile field changes.

define('CLI_SCRIPT', true);
require '/var/www/html/config.php';
require_once($CFG->libdir . '/authlib.php');

// Prints one RESULT line and stops.
function clv_result(string $line, int $code = 0): void {
    echo "RESULT {$line}\n";
    exit($code);
}

$mode = $argv[1] ?? '';
$arg = trim($argv[2] ?? '');
if ($mode === 'lookup' && $arg !== '') {
    $user = $DB->get_record('user',
        ['username' => core_text::strtolower($arg), 'mnethostid' => $CFG->mnet_localhost_id, 'deleted' => 0]);
} else if ($mode === 'set' && ctype_digit($arg)) {
    $user = $DB->get_record('user', ['id' => (int) $arg, 'mnethostid' => $CFG->mnet_localhost_id, 'deleted' => 0]);
} else {
    clv_result('unchanged usage', 64);
}
if (!$user) {
    clv_result('unchanged no-account');
}
if (isguestuser($user)) {
    clv_result('unchanged guest');
}
$auth = get_auth_plugin($user->auth);
if (!$auth->can_change_password() || $auth->prevent_local_passwords()) {
    clv_result("unchanged not-local auth={$user->auth}");
}
if ($mode === 'lookup') {
    clv_result("found id={$user->id} auth={$user->auth}");
}

$password = preg_replace('/\r?\n\z/', '', (string) stream_get_contents(STDIN));
if ($password === '' || preg_match('/[\r\n]/', $password)) {
    clv_result('unchanged no-password');
}
$errmsg = '';
if (!check_password_policy($password, $errmsg, $user)) {
    clv_result('unchanged policy ' . trim(preg_replace('/\s+/', ' ', html_to_text($errmsg, 0))));
}

echo "STEP change id={$user->id}\n";
if (!$auth->user_update_password($user, $password)) {
    clv_result("failed id={$user->id}", 3);
}
unset_user_preference('create_password', $user);
set_user_preference('auth_forcepasswordchange', 1, $user);
\core\session\manager::destroy_user_sessions($user->id);

$user = $DB->get_record('user', ['id' => $user->id], '*', MUST_EXIST);
$notes = [validate_internal_user_password($user, $password) ? 'verified' : 'not-verified'];
if (!empty($user->suspended)) {
    $notes[] = 'suspended';
}
if (!is_enabled_auth($user->auth)) {
    $notes[] = 'auth-disabled';
}
if (login_is_lockedout($user)) {
    $notes[] = 'locked';
}
clv_result("changed id={$user->id} auth={$user->auth} " . implode(' ', $notes));
