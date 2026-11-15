<?php
/**
 * LimeSurvey skill: remote/ls-users.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. admin-users.sh and
 * temp-password.sh are its front ends on the agent. It manages LimeSurvey's admin accounts and their permissions
 * through LimeSurvey's own User and Permission models. A password arrives in the request on stdin, never as an
 * argument, and no reply ever holds one, or its hash.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   list            every admin account: login, name, email, whether it is active, when it expires, and whether it
 *                   is a superadmin and may create surveys
 *   show            login. The same for one account, with its permissions on each survey.
 *   create          login, full_name, email, password, and optionally can_create_surveys. Makes the account with
 *                   LimeSurvey's own check of the login, the address and the password, and lets it sign in with a
 *                   password. It gets no other permission.
 *   set-password    login, password. Sets the account's password and signs its open sessions out.
 *   grant           login and one of: can_create_surveys (true or false); superadmin (true or false); or sid with
 *                   role (full, editor, results or none). A role replaces what the account had on that survey.
 *   set-active      login, active (true or false). Switches an account on or off. Off never deletes anything.
 *   clear-lockouts  removes LimeSurvey's record of failed sign-ins, which locks an address out for a while after
 *                   too many wrong passwords
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 *
 * It refuses to take the superadmin permission from the site's main admin, or to switch that account off: the
 * skill's own calls run as that account, and a site without a superadmin cannot be managed.
 *
 * The roles on one survey:
 *   full     everything, as the survey's owner has
 *   editor   the questions, groups, texts, quotas and settings. Not the answers, the participants, activation or
 *            who else may work on the survey.
 *   results  reading and exporting the answers and the statistics. Nothing can be changed.
 *   none     no access to that survey
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** The account with that login, or a JSON error. */
function ls_user(array $request)
{
    $login = (string) ls_need($request, 'login');
    $user = User::model()->findByAttributes(array('users_name' => $login));
    if (!$user) {
        ls_rc_fail('there is no admin account "' . $login . '". admin-users.sh list shows the accounts');
    }
    return $user;
}

/** One global permission flag of a user. */
function ls_global_flag($uid, $permission, $flag)
{
    $row = Permission::model()->findByAttributes(array('entity' => 'global', 'entity_id' => 0, 'uid' => (int) $uid, 'permission' => $permission));
    return $row ? (bool) $row->getAttribute($flag) : false;
}

/** Sets one global permission flag of a user, making the row when it is missing. */
function ls_set_global_flag($uid, $permission, $flag, $on)
{
    $row = Permission::model()->findByAttributes(array('entity' => 'global', 'entity_id' => 0, 'uid' => (int) $uid, 'permission' => $permission));
    if (!$row) {
        if (!$on) {
            return;
        }
        $row = new Permission();
        $row->entity = 'global';
        $row->entity_id = 0;
        $row->uid = (int) $uid;
        $row->permission = $permission;
        foreach (array('create_p', 'read_p', 'update_p', 'delete_p', 'import_p', 'export_p') as $f) {
            $row->setAttribute($f, 0);
        }
    }
    $row->setAttribute($flag, $on ? 1 : 0);
    if (!$row->save()) {
        ls_rc_fail('LimeSurvey did not save the permission: ' . json_encode($row->getErrors()));
    }
}

/** What list and show say about one account. Never the password hash. */
function ls_user_row(User $user)
{
    $status = $user->user_status;
    $super = ls_global_flag($user->uid, 'superadmin', 'read_p');
    return array(
        'uid' => (int) $user->uid,
        'login' => $user->users_name,
        'full_name' => $user->full_name,
        'email' => $user->email,
        'active' => !isset($status) || (int) $status !== 0,
        'expires' => $user->expires,
        'created' => $user->created,
        'last_login' => $user->last_login,
        'superadmin' => $super,
        'can_create_surveys' => $super || ls_global_flag($user->uid, 'surveys', 'create_p'),
        // A superadmin has every permission, the one for password sign-in included.
        'can_sign_in_with_password' => $super || ls_global_flag($user->uid, 'auth_db', 'read_p'),
    );
}

/** The flags of each role, by survey permission. */
function ls_role_map($role)
{
    $all = array('create', 'read', 'update', 'delete', 'import', 'export');
    switch ($role) {
        case 'editor':
            return array(
                'survey' => array('read'),
                'surveycontent' => $all,
                'surveylocale' => array('read', 'update'),
                'surveysettings' => array('read', 'update'),
                'translations' => array('read', 'update'),
                'quotas' => array('create', 'read', 'update', 'delete'),
                'assessments' => array('create', 'read', 'update', 'delete'),
            );
        case 'results':
            return array(
                'survey' => array('read'),
                'responses' => array('read', 'export'),
                'statistics' => array('read'),
            );
        case 'none':
            return array();
    }
    return null;
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $mainAdmin = $ctx['admin'];
    $db = Yii::app()->db;

    switch ($action) {
        case 'list':
            $rows = array();
            foreach (User::model()->findAll(array('order' => 'uid')) as $user) {
                $rows[] = ls_user_row($user);
            }
            ls_rc_reply(array('main_admin' => $mainAdmin->users_name, 'accounts' => $rows));
            break;

        case 'show':
            $user = ls_user($request);
            $row = ls_user_row($user);
            $surveys = array();
            $found = Permission::model()->findAllByAttributes(array('entity' => 'survey', 'uid' => (int) $user->uid));
            foreach ($found as $p) {
                $flags = array();
                foreach (array('create', 'read', 'update', 'delete', 'import', 'export') as $crud) {
                    if ($p->getAttribute($crud . '_p')) {
                        $flags[] = $crud;
                    }
                }
                if ($flags) {
                    $surveys[(int) $p->entity_id][$p->permission] = $flags;
                }
            }
            $row['survey_permissions'] = $surveys;
            $row['owns_surveys'] = array_map('intval', $db->createCommand('SELECT sid FROM {{surveys}} WHERE owner_id = :uid ORDER BY sid')->queryColumn(array(':uid' => (int) $user->uid)));
            $row['is_main_admin'] = (int) $user->uid === (int) $mainAdmin->uid;
            ls_rc_reply($row);
            break;

        case 'create':
            $login = trim((string) ls_need($request, 'login'));
            $password = (string) ls_need($request, 'password');
            $email = trim((string) ls_need($request, 'email'));
            $fullName = isset($request['full_name']) && trim((string) $request['full_name']) !== '' ? trim((string) $request['full_name']) : $login;
            if (!preg_match('/^[A-Za-z0-9._@-]{1,64}$/', $login)) {
                ls_rc_fail('a login is 1 to 64 letters, digits, dots, dashes, underscores or @ signs');
            }
            if (User::model()->findByAttributes(array('users_name' => $login))) {
                ls_rc_fail('the admin account "' . $login . '" already exists');
            }
            $probe = new User();
            $weak = $probe->checkPasswordStrength($password);
            if ($weak !== '') {
                ls_rc_fail('LimeSurvey does not take that password: ' . $weak);
            }
            $new = User::insertUser($login, $password, $fullName, (int) $mainAdmin->uid, $email);
            if (!is_numeric($new)) {
                $why = array();
                foreach ((array) $new->getErrors() as $field => $messages) {
                    $why[] = $field . ': ' . implode(' ', (array) $messages);
                }
                ls_rc_fail('LimeSurvey did not make the account. ' . implode('; ', $why));
            }
            // Without this permission an account cannot sign in with a password.
            ls_set_global_flag($new, 'auth_db', 'read_p', true);
            if (!empty($request['can_create_surveys'])) {
                ls_set_global_flag($new, 'surveys', 'create_p', true);
            }
            ls_rc_reply(ls_user_row(User::model()->findByPk($new)));
            break;

        case 'set-password':
            $user = ls_user($request);
            $password = (string) ls_need($request, 'password');
            if (strlen($password) < 8) {
                ls_rc_fail('the password has fewer than 8 characters, so it was not set');
            }
            // setPassword() also gives the account a new session token, which signs its open sessions out.
            if (!$user->setPassword($password, true)) {
                ls_rc_fail('LimeSurvey did not save the password: ' . json_encode($user->getErrors()));
            }
            ls_set_global_flag($user->uid, 'auth_db', 'read_p', true);
            ls_rc_reply(array('login' => $user->users_name, 'password_set' => true));
            break;

        case 'grant':
            $user = ls_user($request);
            $isMain = (int) $user->uid === (int) $mainAdmin->uid;
            if (array_key_exists('superadmin', $request)) {
                if (!$request['superadmin'] && $isMain) {
                    ls_rc_fail('"' . $user->users_name . '" is the site\'s main admin. Its superadmin permission stays: the site needs one, and this skill works as that account');
                }
                ls_set_global_flag($user->uid, 'superadmin', 'read_p', (bool) $request['superadmin']);
            } elseif (array_key_exists('can_create_surveys', $request)) {
                ls_set_global_flag($user->uid, 'surveys', 'create_p', (bool) $request['can_create_surveys']);
            } elseif (isset($request['sid'])) {
                $sid = ls_sid($request);
                ls_survey($sid);
                $role = isset($request['role']) ? $request['role'] : '';
                // The role is checked before anything is taken away: a role this does not know must leave the
                // account's permissions as they are.
                $map = $role === 'full' ? array() : ls_role_map($role);
                if ($map === null) {
                    ls_rc_fail('the role is full, editor, results or none. Nothing was changed');
                }
                Permission::model()->deleteAllByAttributes(array('entity' => 'survey', 'entity_id' => $sid, 'uid' => (int) $user->uid));
                if ($role === 'full') {
                    Permission::model()->giveAllSurveyPermissions((int) $user->uid, $sid);
                } else {
                    $base = Survey::getPermissionData();
                    foreach ($map as $permission => $flags) {
                        if (!isset($base[$permission])) {
                            continue;
                        }
                        $row = new Permission();
                        $row->entity = 'survey';
                        $row->entity_id = $sid;
                        $row->uid = (int) $user->uid;
                        $row->permission = $permission;
                        foreach (array('create', 'read', 'update', 'delete', 'import', 'export') as $crud) {
                            $allowed = !isset($base[$permission][$crud]) || $base[$permission][$crud];
                            $row->setAttribute($crud . '_p', in_array($crud, $flags, true) && $allowed ? 1 : 0);
                        }
                        if (!$row->save()) {
                            ls_rc_fail('LimeSurvey did not save the permission: ' . json_encode($row->getErrors()));
                        }
                    }
                }
            } else {
                ls_rc_fail('grant needs one of can_create_surveys, superadmin, or sid with role');
            }
            ls_rc_reply(ls_user_row(User::model()->findByPk($user->uid)));
            break;

        case 'set-active':
            $user = ls_user($request);
            $on = !empty($request['active']);
            if (!$on && (int) $user->uid === (int) $mainAdmin->uid) {
                ls_rc_fail('"' . $user->users_name . '" is the site\'s main admin, and that account stays on');
            }
            $user->user_status = $on ? 1 : 0;
            if ($on && !empty($user->expires) && strtotime($user->expires . ' UTC') < time()) {
                $user->expires = null;
            }
            if (!$user->save(true, array('user_status', 'expires'))) {
                ls_rc_fail('LimeSurvey did not save the account: ' . json_encode($user->getErrors()));
            }
            ls_rc_reply(ls_user_row(User::model()->findByPk($user->uid)));
            break;

        case 'clear-lockouts':
            $removed = (int) $db->createCommand('SELECT COUNT(*) FROM {{failed_login_attempts}}')->queryScalar();
            FailedLoginAttempt::model()->deleteAll();
            ls_rc_reply(array('removed' => $removed));
            break;

        default:
            ls_rc_fail('unknown action. ls-users.php takes list, show, create, set-password, grant, set-active and clear-lockouts');
    }
});
