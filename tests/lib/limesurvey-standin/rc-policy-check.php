<?php
// Checks the limesurvey skill's list of RemoteControl methods and its filter for replies
// (scripts/remote/lib/rc-policy.php) on made-up replies. tests/limesurvey-scripts.test.sh runs it in the app
// container, with LimeSurvey's own PHP: php rc-policy-check.php <path of rc-policy.php> [<path of LimeSurvey>]
// It prints one line per failed check, and "rc-policy: all checks passed" as its last line when none failed.
// The secrets in it are made up.
error_reporting(E_ALL);
require $argv[1];
$root = isset($argv[2]) ? $argv[2] : '/var/www/html';
$failed = 0;
function check($label, $ok)
{
    global $failed;
    if (!$ok) {
        $failed++;
        echo "FAILED: $label\n";
    }
}
function flat($value)
{
    return json_encode($value);
}

// --- The list ---------------------------------------------------------------------------------------------------
$policy = ls_rc_policy();
foreach ($policy as $name => $entry) {
    check("$name has a kind of read, write or refuse", is_array($entry) && in_array($entry[0], array('read', 'write', 'refuse'), true));
    check("$name, which is refused, says what to use instead", $entry[0] !== 'refuse' || strlen($entry[1]) > 20);
}
$refused = array(
    'invite_participants' => 'invitations.sh', 'remind_participants' => 'invitations.sh', 'mail_registered_participants' => 'invitations.sh',
    'activate_survey' => 'survey-activate.sh',
    'delete_survey' => 'delete.sh', 'delete_group' => 'delete.sh', 'delete_question' => 'delete.sh', 'delete_language' => 'delete.sh',
    'delete_participants' => 'delete.sh', 'delete_response' => 'delete.sh', 'delete_quota' => 'delete.sh',
    'export_responses' => 'responses.sh', 'export_responses_by_token' => 'responses.sh', 'export_statistics' => 'responses.sh',
    'activate_tokens' => 'participants.sh', 'add_participants' => 'participants.sh', 'cpd_importParticipants' => 'participants.sh',
    'import_survey' => 'survey-import.sh',
    'add_response' => 'never writes', 'update_response' => 'never writes', 'upload_file' => 'never writes',
    'get_uploaded_files' => 'Responses page', 'get_session_key' => 'not needed', 'release_session_key' => 'not needed',
);
foreach ($refused as $name => $names) {
    list($kind, $reason) = ls_rc_method_policy($name);
    check("$name is refused", $kind === 'refuse');
    check("the refusal of $name names \"$names\"", strpos($reason, $names) !== false);
}
foreach (array('set_survey_properties', 'set_language_properties', 'set_group_properties', 'set_question_properties', 'set_quota_properties',
    'set_participant_properties', 'add_survey', 'copy_survey', 'add_group', 'add_language', 'add_quota', 'import_group', 'import_question') as $name) {
    list($kind) = ls_rc_method_policy($name);
    check("$name changes the site, so it is a write", $kind === 'write');
}
foreach (array('list_surveys', 'get_summary', 'list_questions', 'get_fieldmap', 'list_participants', 'list_users', 'get_site_settings') as $name) {
    list($kind) = ls_rc_method_policy($name);
    check("$name is a read", $kind === 'read');
}
list($kind, $reason) = ls_rc_method_policy('a_method_a_newer_limesurvey_added');
check('a method that is not on the list is refused', $kind === 'refuse' && strpos($reason, 'not on this skill') !== false);

// Every method this LimeSurvey has is on the list, so that none is refused only for being forgotten, and a new
// one shows up here.
$source = "$root/application/helpers/remotecontrol/remotecontrol_handle.php";
if (is_file($source)) {
    preg_match_all('/^\s*public function ([a-z][A-Za-z0-9_]*)\(/m', (string) file_get_contents($source), $m);
    $methods = array_diff($m[1], array('__construct'));
    check('LimeSurvey\'s RemoteControl class was read (' . count($methods) . ' methods)', count($methods) >= 50);
    foreach ($methods as $name) {
        if ($name[0] === '_') {
            continue;
        }
        check("LimeSurvey's method $name is on the list", isset($policy[$name]));
    }
    foreach (array_keys($policy) as $name) {
        check("the list's method $name is one LimeSurvey has", in_array($name, $methods, true));
    }
}

// --- The settings rc.sh shows -----------------------------------------------------------------------------------
$safe = ls_rc_safe_settings();
foreach ($safe as $name) {
    check("the setting $name on the safe list is no secret by its name", !ls_rc_secret_name($name));
}
foreach (array('encryptionkeypair', 'encryptionpublickey', 'encryptionsecretkey', 'encryptionnonce', 'encryptionsecretboxkey',
    'emailsmtppassword', 'defaultpass', 'googleMapsAPIKey', 'ipInfoDbAPIKey') as $name) {
    check("the setting $name is not on the safe list", !in_array($name, $safe, true));
    check("the name $name reads as a secret", ls_rc_secret_name($name));
}

// --- The filter -------------------------------------------------------------------------------------------------
$nonce = 'aabbccddeeff00112233445566778899aabbccddeeff0011';
$boxKey = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
$secrets = array($nonce, $boxKey);

// What list_users gives, per account.
$users = array(array(
    'uid' => 2, 'users_name' => 'jane', 'email' => 'jane@example.test', 'password' => '$2y$10$abcdefghijklmnopqrstuv',
    'one_time_pw' => 'otp-123', 'session_token' => 'sess-0123456789abcdef0123456789abcdef', 'validation_key' => 'vk-0123456789abcdef',
    'validation_key_expiration' => '2026-11-14 10:00:00', 'last_forgot_email_password' => null,
    'permissions' => array(array('permission' => 'auth_db', 'read_p' => 1)),
));
$shown = flat(ls_rc_filter('list_users', $users, false, $secrets));
foreach (array('$2y$10$', 'otp-123', 'sess-0123456789', 'vk-0123456789', 'session_token', 'validation_key', 'one_time_pw', '"password"') as $needle) {
    check("list_users: \"$needle\" is not in the reply", strpos($shown, $needle) === false);
}
check('list_users: the login and the permissions are still in the reply', strpos($shown, '"users_name":"jane"') !== false && strpos($shown, 'auth_db') !== false);

// What get_available_site_settings gives: every setting with its value, the keys of security.php among them.
$settings = array('sitename' => 'A site', 'emailmethod' => 'smtp', 'emailsmtppassword' => 'c2VjcmV0', 'encryptionnonce' => $nonce,
    'encryptionsecretboxkey' => $boxKey, 'encryptionkeypair' => 'kp', 'defaultpass' => 'password', 'somethingnew' => $boxKey);
$shown = flat(ls_rc_filter('get_available_site_settings', $settings, false, $secrets));
check('get_available_site_settings: the reply is a list of names from the safe list', $shown === '["sitename","emailmethod"]');
// The same reply through another method's path: the names go, and so does a key's value under any name.
$shown = flat(ls_rc_filter('some_read', $settings, false, $secrets));
foreach (array($nonce, $boxKey, 'c2VjcmV0', 'encryptionnonce', 'encryptionsecretboxkey', 'encryptionkeypair', 'emailsmtppassword', 'defaultpass') as $needle) {
    check("any method: \"" . substr($needle, 0, 12) . "...\" is not in the reply", strpos($shown, $needle) === false);
}
check('any method: a key\'s value under a name that says nothing is hidden', strpos($shown, '"somethingnew":"(hidden)"') !== false);
check('any method: what is no secret stays', strpos($shown, '"sitename":"A site"') !== false);
check('get_site_settings: a key\'s value as the whole reply is hidden', ls_rc_filter('get_site_settings', $boxKey, false, $secrets) === '(hidden)');
check('a secret value inside a longer text is hidden', ls_rc_filter('x', "key=$nonce;", false, $secrets) === '(hidden)');
$nested = array('a' => array('b' => array('salt' => 's', 'hash' => 'h', 'secret' => 'x', 'apikey' => 'k', 'bounceaccountpass' => 'p', 'keep' => 1)));
check('secret names are taken out at any depth', flat(ls_rc_filter('x', $nested, false, array())) === '{"a":{"b":{"keep":1}}}');
check('names that only look alike stay (tokenlength, usetokens, nokeyboard, tokenencryptionoptions)',
    flat(ls_rc_filter('get_survey_properties', array('tokenlength' => 15, 'usetokens' => 'Y', 'nokeyboard' => 'N', 'tokenencryptionoptions' => '{}'), false, array()))
    === '{"tokenlength":15,"usetokens":"Y","nokeyboard":"N","tokenencryptionoptions":"{}"}');

// Access codes.
$people = array(array('tid' => 1, 'token' => 'AbCdEfGhIjKlMnO', 'participant_info' => array('firstname' => 'Ada', 'email' => 'ada@example.test')));
$shown = flat(ls_rc_filter('list_participants', $people, false, $secrets));
check('list_participants: the access code is hidden', strpos($shown, 'AbCdEfGhIjKlMnO') === false && strpos($shown, '"token":"(hidden)"') !== false);
check('list_participants: with show_codes it is there', strpos(flat(ls_rc_filter('list_participants', $people, true, $secrets)), 'AbCdEfGhIjKlMnO') !== false);
check('an empty access code stays empty', flat(ls_rc_filter('x', array('token' => ''), false, array())) === '{"token":""}');

// What set_participant_properties gives: the person's whole row.
$row = array('tid' => 2, 'participant_id' => null, 'firstname' => 'Bob', 'lastname' => 'Roe', 'email' => 'bob@example.test',
    'emailstatus' => 'bounced', 'token' => '9oJT71FSjf1PbMy', 'language' => 'en', 'usesleft' => 1, 'completed' => 'N');
$shown = flat(ls_rc_filter('set_participant_properties', $row, false, $secrets,
    array('iSurveyID' => 1, 'aTokenQueryProperties' => array('tid' => 2), 'aTokenData' => array('emailstatus' => 'bounced', 'firstname' => 'Bobby'))));
check('set_participant_properties: a count and the fields that were set', $shown === '{"changed":1,"tid":2,"fields":{"emailstatus":"bounced","firstname":"(set)"}}');
$shown = flat(ls_rc_filter('set_participant_properties', $row, true, $secrets, array(1, array('tid' => 2), array('emailstatus' => 'bounced'))));
foreach (array('Bob', 'Roe', 'bob@example.test', '9oJT71FSjf1PbMy') as $needle) {
    check("set_participant_properties: \"$needle\" is not in the reply, also with show_codes", strpos($shown, $needle) === false);
}
check('set_participant_properties: parameters given as a list work too', $shown === '{"changed":1,"tid":2,"fields":{"emailstatus":"bounced"}}');
$no = array('status' => 'Error: Invalid tokenid', 'error_code' => 'ERR_INVALID_TOKEN');
check('a refusal of LimeSurvey passes as it is', ls_rc_filter('set_participant_properties', $no, false, $secrets, array()) === $no);

echo $failed === 0 ? "rc-policy: all checks passed\n" : "rc-policy: $failed checks failed\n";
exit($failed === 0 ? 0 : 1);
