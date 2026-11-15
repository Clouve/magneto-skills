<?php
/**
 * SuiteCRM skill: remote/users.php (runs inside the SuiteCRM container as www-data; users.sh and
 * temp-password.sh send it)
 *
 * Users, roles and security groups through SuiteCRM's own beans. A password only ever arrives as the first
 * line of stdin, and nothing here prints one or its hash.
 *
 * Usage (users.sh has the full text; MAIN is the login of the deployment's main admin, or "-"):
 *   users.php list
 *   users.php show LOGIN
 *   users.php create LOGIN FIRST LAST EMAIL ADMIN(0|1)          the temporary password on stdin
 *   users.php invite LOGIN FIRST LAST EMAIL ADMIN(0|1)          SuiteCRM makes the password and emails it
 *   users.php set-password LOGIN MAIN                           the temporary password on stdin
 *   users.php restore-admin-password MAIN                       the dashboard's password on stdin
 *   users.php password-rule [first-sign-in]                     when SuiteCRM asks for a new password
 *   users.php deactivate LOGIN MAIN | activate LOGIN | set-admin LOGIN yes|no MAIN
 *   users.php role-list | role-show ROLE | role-create ROLE | role-assign LOGIN ROLE | role-unassign LOGIN ROLE
 *   users.php role-set ROLE MODULE ACTION LEVEL
 *   users.php group-list | group-create GROUP | group-add LOGIN GROUP | group-remove LOGIN GROUP
 *
 * The yes flags (--yes-admin, --yes-reset, --yes-send, --yes-change) are checked by users.sh,
 * temp-password.sh and restore-admin-password.sh before they call this file.
 *
 * A change prints what it replaced: was_status, was_admin, roles_before, groups_before, and before and
 * after for role-set and password-rule.
 *
 * Exit codes: 0 done; 64 usage; 65 bad input; 2 SuiteCRM refused, or this script did (the main admin), or
 * the read-back did not match; 3 no such user, role or group; 4 it exists already; 8 the account was made
 * but the email was not sent.
 */

require __DIR__ . '/boot.php';
require_once 'modules/ACLRoles/ACLRole.php';
require_once 'modules/ACLActions/ACLAction.php';
require_once 'modules/SecurityGroups/SecurityGroup.php';

const SC_LEVELS = ['all' => ACL_ALLOW_ALL, 'group' => ACL_ALLOW_GROUP, 'owner' => ACL_ALLOW_OWNER, 'none' => ACL_ALLOW_NONE,
    'enabled' => ACL_ALLOW_ENABLED, 'disabled' => ACL_ALLOW_DISABLED, 'default' => ACL_ALLOW_DEFAULT];
// How much each level lets through, for the note that says a change widened access. default clears the
// role's setting, and a setting that is not there means allowed.
const SC_LEVEL_WIDTH = ['none' => 0, 'disabled' => 0, 'owner' => 1, 'group' => 2, 'all' => 3, 'enabled' => 3, 'default' => 3];
const SC_PASSWORD_RULE_KEYS = ['systexpiration', 'systexpirationtime', 'systexpirationtype', 'systexpirationlogin'];

function sc_need_user(string $login)
{
    if ($login === '') {
        sc_fail(64, 'no login given');
    }
    $user = sc_find_user($login);
    if ($user === null) {
        sc_fail(3, "there is no user \"$login\". users.sh list shows the logins.");
    }
    return $user;
}

function sc_role(string $name)
{
    global $db;
    $id = $db->getOne('SELECT id FROM acl_roles WHERE deleted = 0 AND name = ' . $db->quoted($name));
    if (empty($id)) {
        return null;
    }
    return BeanFactory::getBean('ACLRoles', $id);
}

function sc_group(string $name)
{
    global $db;
    $id = $db->getOne('SELECT id FROM securitygroups WHERE deleted = 0 AND name = ' . $db->quoted($name));
    if (empty($id)) {
        return null;
    }
    return BeanFactory::getBean('SecurityGroups', $id);
}

function sc_user_roles(string $userId): array
{
    global $db;
    $out = [];
    $res = $db->query('SELECT r.name FROM acl_roles_users ru JOIN acl_roles r ON r.id = ru.role_id AND r.deleted = 0'
        . ' WHERE ru.deleted = 0 AND ru.user_id = ' . $db->quoted($userId) . ' ORDER BY r.name');
    while ($row = $db->fetchByAssoc($res)) {
        $out[] = html_entity_decode($row['name'], ENT_QUOTES);
    }
    return $out;
}

function sc_user_groups(string $userId): array
{
    global $db;
    $out = [];
    $res = $db->query('SELECT g.name FROM securitygroups_users gu JOIN securitygroups g ON g.id = gu.securitygroup_id AND g.deleted = 0'
        . ' WHERE gu.deleted = 0 AND gu.user_id = ' . $db->quoted($userId) . ' ORDER BY g.name');
    while ($row = $db->fetchByAssoc($res)) {
        $out[] = html_entity_decode($row['name'], ENT_QUOTES);
    }
    return $out;
}

/** The account's row as the database has it now. A bean can be a cached copy, and setNewPassword() writes past it. */
function sc_user_row(string $userId): array
{
    global $db;
    $row = $db->fetchOne('SELECT status, is_admin, system_generated_password, external_auth_only FROM users WHERE deleted = 0 AND id = ' . $db->quoted($userId));
    return is_array($row) ? $row : [];
}

/**
 * When SuiteCRM asks a person on a generated password for a new one, in words, from the site's own setting
 * (Admin > Password Management, "System-Generated Password Expiration"; hasPasswordExpired() in
 * modules/Users/password_utils.php applies it at each sign-in). $setting is passwordsetting, or null for the
 * one SuiteCRM has loaded.
 */
function sc_password_rule(?array $setting = null): array
{
    global $sugar_config;
    $setting = $setting ?? ($sugar_config['passwordsetting'] ?? []);
    $kept = [];
    foreach (SC_PASSWORD_RULE_KEYS as $key) {
        $kept[$key] = (string) ($setting[$key] ?? '');
    }
    $unclear = 'unclear: the setting is not complete (Admin > Password Management in SuiteCRM shows it)';
    switch ($kept['systexpiration']) {
        case '1':
            // SuiteCRM multiplies the number by the unit: 1 for days, 7 for weeks, 30 for months.
            if (!ctype_digit($kept['systexpirationtime']) || !ctype_digit($kept['systexpirationtype'])) {
                $words = $unclear;
                break;
            }
            $days = (int) $kept['systexpirationtime'] * (int) $kept['systexpirationtype'];
            $words = $days === 0 ? 'at the first sign-in' : ($days === 1 ? '1 day after the password was set' : "$days days after the password was set");
            break;
        case '2':
            if (!ctype_digit($kept['systexpirationlogin'])) {
                $words = $unclear;
                break;
            }
            $logins = (int) $kept['systexpirationlogin'];
            $words = $logins <= 1 ? 'at the first sign-in' : "at sign-in number $logins with that password";
            break;
        case '0':
        case '':
            $words = 'never';
            break;
        default:
            $words = $unclear;
    }
    return ['asks_for_new_password' => $words, 'setting' => $kept];
}

/** The password setting as config.php and config_override.php hold it on disk now, read apart from what is loaded. */
function sc_password_setting_on_disk(): array
{
    $sugar_config = [];
    include 'config.php';
    if (is_file('config_override.php')) {
        include 'config_override.php';
    }
    return is_array($sugar_config['passwordsetting'] ?? null) ? $sugar_config['passwordsetting'] : [];
}

/** The active accounts that are on a generated password now: the people the rule applies to. */
function sc_logins_on_generated_password(): array
{
    global $db;
    $out = [];
    $res = $db->query("SELECT user_name FROM users WHERE deleted = 0 AND status = 'Active' AND system_generated_password = 1"
        . " AND IFNULL(is_group, 0) = 0 AND IFNULL(portal_only, 0) = 0 ORDER BY user_name");
    while ($row = $db->fetchByAssoc($res)) {
        $out[] = html_entity_decode($row['user_name'], ENT_QUOTES);
    }
    return $out;
}

function sc_user_view($user): array
{
    global $db;
    $email = $db->getOne("SELECT e.email_address FROM email_addr_bean_rel r JOIN email_addresses e ON e.id = r.email_address_id AND e.deleted = 0"
        . " WHERE r.bean_module = 'Users' AND r.deleted = 0 AND r.bean_id = " . $db->quoted($user->id) . ' ORDER BY r.primary_address DESC');
    $row = sc_user_row($user->id);
    $generated = (int) ($row['system_generated_password'] ?? 0) === 1;
    if (!empty($row['external_auth_only'])) {
        $asks = 'never (this account signs in through LDAP or SAML)';
    } elseif (!$generated) {
        $asks = 'never (the person chose this password)';
    } else {
        $asks = sc_password_rule()['asks_for_new_password'];
    }
    return [
        'login' => $user->user_name,
        'id' => $user->id,
        'name' => trim(html_entity_decode(($user->first_name ?? '') . ' ' . ($user->last_name ?? ''), ENT_QUOTES)),
        'email' => $email ?: null,
        'status' => (string) ($row['status'] ?? $user->status),
        'is_admin' => (int) ($row['is_admin'] ?? $user->is_admin) === 1,
        // True while the account is on a password that SuiteCRM or this skill made. It says nothing about
        // whether the person has signed in.
        'system_generated_password' => $generated,
        'asks_for_new_password' => $asks,
        'roles' => sc_user_roles($user->id),
        'groups' => sc_user_groups($user->id),
    ];
}

/** True when the stored hash of the user is the hash of this password. Read from the database: a bean can be a cached copy. */
function sc_password_kept(string $userId, string $password): bool
{
    global $db;
    $hash = (string) $db->getOne('SELECT user_hash FROM users WHERE deleted = 0 AND id = ' . $db->quoted($userId));
    return $hash !== '' && User::checkPassword($password, $hash);
}

/**
 * Call before setNewPassword() on an account. setNewPassword() resets three sign-in counters in the
 * person's preferences and saves them. For an account other than the acting one, SuiteCRM 8.10.2 saves
 * those three alone and drops the rest: the time zone, the date and number formats, and the mark that the
 * first-login wizard is done. Loading what is stored into the place SuiteCRM saves from keeps them.
 */
function sc_keep_preferences($user): void
{
    if (empty($user->id) || empty($user->user_name)) {
        return;
    }
    $key = $user->user_name . '_PREFERENCES';
    if (isset($_SESSION[$key]['global'])) {
        return;
    }
    $user->reloadPreferences('global');
    if (!isset($_SESSION[$key]['global']) && is_array($user->user_preferences['global'] ?? null)) {
        $_SESSION[$key]['global'] = $user->user_preferences['global'];
    }
}

function sc_check_new_user(array $argv): array
{
    [$login, $first, $last, $email, $admin] = [$argv[2] ?? '', $argv[3] ?? '', $argv[4] ?? '', $argv[5] ?? '', $argv[6] ?? '0'];
    if ($login === '' || $last === '') {
        sc_fail(64, 'a new user needs a login and a last name');
    }
    if (strlen($login) > 60 || preg_match('/[\x00-\x1f]/', $login)) {
        sc_fail(65, 'the login has to be at most 60 characters of text');
    }
    if ($email === '' || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
        sc_fail(65, "a new user needs an email address, and \"$email\" is not one");
    }
    if (sc_find_user($login) !== null) {
        sc_fail(4, "the user \"$login\" exists already. Nothing was changed.");
    }
    return [$login, $first, $last, $email, $admin === '1' ? 1 : 0];
}

function sc_make_user(string $login, string $first, string $last, string $email, int $admin, string $password)
{
    $user = BeanFactory::newBean('Users');
    $user->user_name = $login;
    $user->first_name = $first;
    $user->last_name = $last;
    $user->email1 = $email;
    $user->status = 'Active';
    $user->employee_status = 'Active';
    $user->is_admin = $admin;
    $user->user_hash = User::getPasswordHash($password);
    $user->save();
    // '1' marks the password as system generated. When SuiteCRM asks for a new one follows the site's rule
    // (sc_password_rule), which on a stock install is 7 days after the password was set.
    sc_keep_preferences($user);
    $user->setNewPassword($password, '1');
    $made = sc_find_user($login);
    if ($made === null || !sc_password_kept($made->id, $password)) {
        sc_fail(2, "SuiteCRM did not keep the user \"$login\" as sent; check users.sh show");
    }
    return $made;
}

$action = $argv[1] ?? '';
switch ($action) {
    case 'list':
        $out = [];
        $res = $db->query("SELECT id FROM users WHERE deleted = 0 AND IFNULL(is_group, 0) = 0 AND IFNULL(portal_only, 0) = 0 ORDER BY user_name");
        while ($row = $db->fetchByAssoc($res)) {
            $user = BeanFactory::getBean('Users', $row['id']);
            if (!empty($user->id)) {
                $out[] = sc_user_view($user);
            }
        }
        sc_done(['users' => $out]);

    case 'show':
        sc_done(sc_user_view(sc_need_user($argv[2] ?? '')));

    case 'create':
        [$login, $first, $last, $email, $admin] = sc_check_new_user($argv);
        $password = sc_read_secret_line();
        $user = sc_make_user($login, $first, $last, $email, $admin, $password);
        sc_done(['created' => true] + sc_user_view($user));

    case 'invite':
        [$login, $first, $last, $email, $admin] = sc_check_new_user($argv);
        $system = $db->fetchOne("SELECT mail_smtpserver FROM outbound_email WHERE type = 'system' AND deleted = 0");
        if (empty($system['mail_smtpserver'])) {
            sc_fail(2, 'outgoing email is not set up, so SuiteCRM cannot send the invitation. Nothing was changed. Use temp-password.sh --create, or set up email first (playbooks/configure-email.md).');
        }
        $password = User::generatePassword();
        $user = sc_make_user($login, $first, $last, $email, $admin, $password);
        $template = $sugar_config['passwordsetting']['generatepasswordtmpl'] ?? '';
        $result = $user->sendEmailForPassword($template, ['password' => $password]);
        $view = sc_user_view($user);
        if (empty($result['status'])) {
            sc_flush_noise();
            echo json_encode(['created' => true, 'email_sent' => false] + $view, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), "\n";
            fwrite(STDERR, "[suitecrm] the user \"$login\" was made, but SuiteCRM could not send the email" . (!empty($result['message']) ? ' (' . strip_tags((string) $result['message']) . ')' : '') . ". Nobody has the password. Give the account one with temp-password.sh --yes-reset, and fix email with playbooks/configure-email.md.\n");
            exit(8);
        }
        sc_done(['created' => true, 'email_sent' => true] + $view);

    case 'set-password':
        $user = sc_need_user($argv[2] ?? '');
        if (sc_is_main_admin($user, ($argv[3] ?? '-') === '-' ? '' : $argv[3])) {
            sc_fail(2, "\"{$user->user_name}\" is this deployment's main admin. Its password is the one on the Clouve dashboard, and in the Customer Kit LimeSurvey signs in to SuiteCRM with it. Follow playbooks/regain-admin-access.md. Nothing was changed.");
        }
        if (!empty($user->external_auth_only)) {
            sc_fail(2, "\"{$user->user_name}\" signs in through an outside service (LDAP or SAML), so SuiteCRM keeps no password for it. Nothing was changed.");
        }
        $password = sc_read_secret_line();
        sc_keep_preferences($user);
        $user->setNewPassword($password, '1');
        $after = sc_find_user($user->user_name);
        if ($after === null || !sc_password_kept($after->id, $password)) {
            sc_fail(2, 'SuiteCRM did not keep the new password; check the account');
        }
        sc_done(['password_set' => true] + sc_user_view($after));

    case 'restore-admin-password':
        $main = ($argv[2] ?? '-') === '-' ? '' : $argv[2];
        $user = $main !== '' ? sc_find_user($main) : null;
        if ($user === null) {
            $user = BeanFactory::getBean('Users', '1');
        }
        if (empty($user->id) || !sc_is_main_admin($user, $main)) {
            sc_fail(3, 'could not find the main admin account');
        }
        $password = sc_read_secret_line();
        $was = sc_user_row($user->id);
        $wasStatus = (string) ($was['status'] ?? '');
        $wasAdmin = (int) ($was['is_admin'] ?? 0) === 1;
        $changed = false;
        // The account first, the password second. setNewPassword() writes the hash with its own UPDATE and
        // leaves the bean's copy as it was read, so a save() after it would write the old hash back.
        if ($wasStatus !== 'Active' || !$wasAdmin) {
            $user->status = 'Active';
            $user->employee_status = 'Active';
            $user->is_admin = 1;
            $user->save();
            $now = sc_user_row($user->id);
            if (($now['status'] ?? '') !== 'Active' || (int) ($now['is_admin'] ?? 0) !== 1) {
                // SuiteCRM's save lets only an admin change these fields, and this script acts as the main
                // admin: with that account demoted, the save keeps the old values. This is the way back in,
                // so the three columns are set directly.
                $db->query("UPDATE users SET status = 'Active', employee_status = 'Active', is_admin = 1 WHERE deleted = 0 AND id = " . $db->quoted($user->id), true);
            }
            $changed = true;
        }
        // '0': the admin chose this password themselves at install, so SuiteCRM never asks for a new one.
        sc_keep_preferences($user);
        $user->setNewPassword($password, '0');
        // Read back from the database: a bean can be a stale copy.
        $now = sc_user_row($user->id);
        if (!sc_password_kept($user->id, $password)) {
            sc_fail(2, 'SuiteCRM did not keep the password. The account is ' . ($now['status'] ?? 'unknown') . '; check it with users.sh show before you run this again.');
        }
        if (($now['status'] ?? '') !== 'Active' || (int) ($now['is_admin'] ?? 0) !== 1) {
            sc_fail(2, 'the password is back, but SuiteCRM did not keep the account active and an admin; check it with users.sh show');
        }
        sc_done(['password_restored' => true, 'reactivated' => $changed, 'was_status' => $wasStatus, 'was_admin' => $wasAdmin]
            + sc_user_view($user)
            + ['note' => 'This does not end SuiteCRM\'s sign-in throttle. After 5 wrong tries SuiteCRM refuses that login from that network address for up to 30 minutes, the right password included, and says "Too many failed login attempts". Then wait 30 minutes, or sign in from another network, such as a phone off the Wi-Fi.']);

    case 'password-rule':
        $want = $argv[2] ?? '';
        if ($want !== '' && $want !== 'first-sign-in') {
            sc_fail(64, 'password-rule takes nothing, or first-sign-in');
        }
        $applies = 'accounts on a generated password: a temporary one from temp-password.sh, or one SuiteCRM emailed (users.sh invite). A person who chose their own password is never asked.';
        $before = sc_password_rule(sc_password_setting_on_disk());
        if ($want === '') {
            sc_done(['asks_for_new_password' => $before['asks_for_new_password'], 'applies_to' => $applies,
                'accounts_on_a_generated_password' => sc_logins_on_generated_password(), 'setting' => $before['setting'],
                'note' => 'This is one setting for the whole site: Admin > Password Management in SuiteCRM, "System-Generated Password Expiration". users.sh password-rule first-sign-in --yes-change sets it to the first sign-in.']);
        }
        $changed = false;
        if ($before['setting']['systexpiration'] !== '2' || $before['setting']['systexpirationlogin'] !== '1') {
            // What the Password Management page does when "Password Expires upon 1 logins" is saved: the two
            // values go through SuiteCRM's Configurator into config_override.php.
            require_once 'modules/Configurator/Configurator.php';
            $configurator = new Configurator();
            $configurator->config['passwordsetting']['systexpiration'] = '2';
            $configurator->config['passwordsetting']['systexpirationlogin'] = '1';
            $configurator->handleOverride();
            $configurator->clearCache();
            require_once 'include/portability/Services/Cache/CacheManager.php';
            (new CacheManager())->markAsNeedsUpdate('rebuild_all');
            $changed = true;
        }
        $after = sc_password_rule(sc_password_setting_on_disk());
        if ($after['setting']['systexpiration'] !== '2' || $after['setting']['systexpirationlogin'] !== '1') {
            sc_fail(2, 'SuiteCRM did not keep the setting (config_override.php may not be writable). The rule is still: ' . $after['asks_for_new_password'] . '.');
        }
        sc_done(['changed' => $changed, 'before' => $before['asks_for_new_password'], 'after' => $after['asks_for_new_password'],
            'applies_to' => $applies, 'accounts_on_a_generated_password' => sc_logins_on_generated_password(),
            'setting_before' => $before['setting'], 'setting' => $after['setting'],
            'note' => 'Everyone listed in accounts_on_a_generated_password is asked for a new password at their next sign-in, and so is everyone who gets a generated password from now on. To change the rule back, use Admin > Password Management in SuiteCRM ("System-Generated Password Expiration"); "before" and "setting_before" say what it was.']);

    case 'deactivate':
    case 'activate':
        $user = sc_need_user($argv[2] ?? '');
        if ($action === 'deactivate' && sc_is_main_admin($user, ($argv[3] ?? '-') === '-' ? '' : $argv[3])) {
            sc_fail(2, "\"{$user->user_name}\" is this deployment's main admin and stays active. Nothing was changed.");
        }
        $wasStatus = (string) (sc_user_row($user->id)['status'] ?? '');
        $user->status = $action === 'activate' ? 'Active' : 'Inactive';
        $user->employee_status = $action === 'activate' ? 'Active' : 'Terminated';
        $user->save();
        $view = sc_user_view($user);
        if ($view['status'] !== $user->status) {
            sc_fail(2, 'SuiteCRM did not keep the change; check users.sh show');
        }
        sc_done([$action === 'activate' ? 'activated' : 'deactivated' => true, 'was_status' => $wasStatus] + $view
            + ['note' => $action === 'activate'
                ? "The account can sign in again, with the password it had. users.sh deactivate \"{$user->user_name}\" takes this back."
                : "The account can't sign in, and a session it had open has ended. Its records stay assigned to it. users.sh activate \"{$user->user_name}\" takes this back."]);

    case 'set-admin':
        $user = sc_need_user($argv[2] ?? '');
        $want = $argv[3] ?? '';
        if (!in_array($want, ['yes', 'no'], true)) {
            sc_fail(64, 'set-admin takes yes or no');
        }
        if ($want === 'no' && sc_is_main_admin($user, ($argv[4] ?? '-') === '-' ? '' : $argv[4])) {
            sc_fail(2, "\"{$user->user_name}\" is this deployment's main admin and stays an admin. Nothing was changed.");
        }
        $wasAdmin = (int) (sc_user_row($user->id)['is_admin'] ?? 0) === 1;
        $user->is_admin = $want === 'yes' ? 1 : 0;
        $user->save();
        $view = sc_user_view($user);
        if ($view['is_admin'] !== ($want === 'yes')) {
            sc_fail(2, 'SuiteCRM did not keep the change; check users.sh show');
        }
        sc_done(['is_admin_set' => true, 'was_admin' => $wasAdmin] + $view
            + ['note' => $want === 'yes'
                ? "The account has full control of SuiteCRM now: every record whatever its roles, exports, other users' accounts and Module Loader. users.sh set-admin \"{$user->user_name}\" no takes the right away again; what the account read or exported in between stays read."
                : "The account's roles and security groups apply to it again. users.sh set-admin \"{$user->user_name}\" yes --yes-admin gives the right back."]);

    case 'role-list':
        $out = [];
        $res = $db->query("SELECT r.name, r.description, (SELECT COUNT(*) FROM acl_roles_users ru JOIN users u ON u.id = ru.user_id AND u.deleted = 0 WHERE ru.role_id = r.id AND ru.deleted = 0) AS users FROM acl_roles r WHERE r.deleted = 0 ORDER BY r.name");
        while ($row = $db->fetchByAssoc($res)) {
            $out[] = ['role' => html_entity_decode($row['name'], ENT_QUOTES), 'description' => html_entity_decode((string) $row['description'], ENT_QUOTES), 'users' => (int) $row['users']];
        }
        sc_done(['roles' => $out]);

    case 'role-show':
        $role = sc_role($argv[2] ?? '');
        if ($role === null) {
            sc_fail(3, 'there is no role "' . ($argv[2] ?? '') . '"');
        }
        $names = array_flip(SC_LEVELS);
        $set = [];
        $res = $db->query("SELECT a.category, a.name, ra.access_override FROM acl_roles_actions ra JOIN acl_actions a ON a.id = ra.action_id AND a.deleted = 0"
            . " WHERE ra.deleted = 0 AND ra.role_id = " . $db->quoted($role->id) . " AND ra.access_override <> 0 ORDER BY a.category, a.name");
        while ($row = $db->fetchByAssoc($res)) {
            $set[$row['category']][$row['name']] = $names[(int) $row['access_override']] ?? (string) $row['access_override'];
        }
        $users = [];
        $res = $db->query("SELECT u.user_name FROM acl_roles_users ru JOIN users u ON u.id = ru.user_id AND u.deleted = 0 WHERE ru.deleted = 0 AND ru.role_id = " . $db->quoted($role->id) . " ORDER BY u.user_name");
        while ($row = $db->fetchByAssoc($res)) {
            $users[] = $row['user_name'];
        }
        sc_done(['role' => $role->name, 'users' => $users, 'settings' => $set, 'note' => 'a module or action that is not listed is at its default: allowed']);

    case 'role-create':
        $name = trim($argv[2] ?? '');
        if ($name === '') {
            sc_fail(64, 'a role needs a name');
        }
        if (sc_role($name) !== null) {
            sc_fail(4, "the role \"$name\" exists already");
        }
        $role = BeanFactory::newBean('ACLRoles');
        $role->name = $name;
        $role->description = 'Made by the AI Assistant';
        $role->save();
        sc_done(['role_created' => true, 'role' => $name]);

    case 'role-assign':
    case 'role-unassign':
        $user = sc_need_user($argv[2] ?? '');
        $role = sc_role($argv[3] ?? '');
        if ($role === null) {
            sc_fail(3, 'there is no role "' . ($argv[3] ?? '') . '". users.sh role-list shows the roles, and role-create makes one.');
        }
        $rolesBefore = sc_user_roles($user->id);
        $role->load_relationship('users');
        if ($action === 'role-assign') {
            $role->users->add($user->id);
        } else {
            $role->users->delete($role->id, $user->id);
        }
        $rolesAfter = sc_user_roles($user->id);
        $has = in_array(html_entity_decode((string) $role->name, ENT_QUOTES), $rolesAfter, true);
        if ($has !== ($action === 'role-assign')) {
            sc_fail(2, 'SuiteCRM did not keep the change; check users.sh show');
        }
        sc_done(['done' => $action, 'roles_before' => $rolesBefore, 'roles_after' => $rolesAfter] + sc_user_view($user)
            + ['note' => 'the person sees the change after they sign in again']);

    case 'role-set':
        $role = sc_role($argv[2] ?? '');
        if ($role === null) {
            sc_fail(3, 'there is no role "' . ($argv[2] ?? '') . '"');
        }
        [$module, $act, $level] = [$argv[3] ?? '', $argv[4] ?? '', $argv[5] ?? ''];
        if (!isset(SC_LEVELS[$level])) {
            sc_fail(64, 'the level must be one of ' . implode(', ', array_keys(SC_LEVELS)));
        }
        if (($act === 'access') !== in_array($level, ['enabled', 'disabled', 'default'], true) && $level !== 'default') {
            sc_fail(64, 'the action "access" takes enabled, disabled or default; the other actions take all, group, owner, none or default');
        }
        // SuiteCRM's own list of the levels each action has. import and massupdate have no owner or group
        // level: SuiteCRM asks "may this person import at all", so a stored "owner" there counts as allowed.
        $known = $GLOBALS['ACLActions']['module']['actions'][$act]['aclaccess'] ?? null;
        if (is_array($known) && !in_array(SC_LEVELS[$level], $known, true)) {
            $names = array_flip(SC_LEVELS);
            $takes = implode(', ', array_map(fn ($value) => $names[$value] ?? (string) $value, $known));
            sc_fail(64, "SuiteCRM has no level \"$level\" for the action \"$act\". It takes: $takes. default means allowed"
                . (in_array($act, ['import', 'massupdate'], true) ? ", and $act is allowed or not for the whole module: use none to close it" : '') . '. Nothing was changed.');
        }
        $actionId = $db->getOne("SELECT id FROM acl_actions WHERE deleted = 0 AND category = " . $db->quoted($module) . " AND name = " . $db->quoted($act));
        if (empty($actionId)) {
            sc_fail(3, "SuiteCRM has no action \"$act\" for the module \"$module\". The actions are access, view, list, edit, delete, import, export and massupdate, and the module is named as in its address, such as Accounts or Opportunities.");
        }
        $overrideSql = "SELECT access_override FROM acl_roles_actions WHERE deleted = 0 AND role_id = " . $db->quoted($role->id) . " AND action_id = " . $db->quoted($actionId);
        $names = array_flip(SC_LEVELS);
        // The level this replaces, read before the change, so that a wrong word can be put right.
        $old = $db->getOne($overrideSql);
        $before = ($old === false || $old === null || $old === '') ? 'default' : ($names[(int) $old] ?? (string) $old);
        $role->setAction($role->id, $actionId, SC_LEVELS[$level]);
        $now = (int) $db->getOne($overrideSql);
        if ($now !== SC_LEVELS[$level]) {
            sc_fail(2, 'SuiteCRM did not keep the setting; check users.sh role-show');
        }
        $users = [];
        $res = $db->query("SELECT u.user_name FROM acl_roles_users ru JOIN users u ON u.id = ru.user_id AND u.deleted = 0 WHERE ru.deleted = 0 AND ru.role_id = " . $db->quoted($role->id) . " ORDER BY u.user_name");
        while ($row = $db->fetchByAssoc($res)) {
            $users[] = $row['user_name'];
        }
        $widens = (SC_LEVEL_WIDTH[$level] ?? 3) > (SC_LEVEL_WIDTH[$before] ?? 3);
        $note = 'people in the role see the change after they sign in again';
        if ($widens) {
            $note = "This widens what the role allows: $act on $module went from $before to $level"
                . ($level === 'default' ? ', and default means allowed' : '') . ". To put it back: users.sh role-set \"" . html_entity_decode((string) $role->name, ENT_QUOTES) . "\" $module $act $before. " . ucfirst($note) . '.';
        }
        sc_done(['role_set' => true, 'role' => $role->name, 'module' => $module, 'action' => $act, 'level' => $level,
            'before' => $before, 'after' => $level, 'widens_access' => $widens, 'users' => $users, 'note' => $note]);

    case 'group-list':
        $out = [];
        $res = $db->query("SELECT g.name, (SELECT COUNT(*) FROM securitygroups_users gu JOIN users u ON u.id = gu.user_id AND u.deleted = 0 WHERE gu.securitygroup_id = g.id AND gu.deleted = 0) AS users FROM securitygroups g WHERE g.deleted = 0 ORDER BY g.name");
        while ($row = $db->fetchByAssoc($res)) {
            $out[] = ['group' => html_entity_decode($row['name'], ENT_QUOTES), 'users' => (int) $row['users']];
        }
        sc_done(['groups' => $out]);

    case 'group-create':
        $name = trim($argv[2] ?? '');
        if ($name === '') {
            sc_fail(64, 'a group needs a name');
        }
        if (sc_group($name) !== null) {
            sc_fail(4, "the security group \"$name\" exists already");
        }
        $group = BeanFactory::newBean('SecurityGroups');
        $group->name = $name;
        $group->save();
        sc_done(['group_created' => true, 'group' => $name]);

    case 'group-add':
    case 'group-remove':
        $user = sc_need_user($argv[2] ?? '');
        $group = sc_group($argv[3] ?? '');
        if ($group === null) {
            sc_fail(3, 'there is no security group "' . ($argv[3] ?? '') . '". users.sh group-list shows them, and group-create makes one.');
        }
        $groupsBefore = sc_user_groups($user->id);
        $group->load_relationship('users');
        if ($action === 'group-add') {
            $group->users->add($user->id);
        } else {
            $group->users->delete($group->id, $user->id);
        }
        $groupsAfter = sc_user_groups($user->id);
        $has = in_array(html_entity_decode((string) $group->name, ENT_QUOTES), $groupsAfter, true);
        if ($has !== ($action === 'group-add')) {
            sc_fail(2, 'SuiteCRM did not keep the change; check users.sh show');
        }
        sc_done(['done' => $action, 'groups_before' => $groupsBefore, 'groups_after' => $groupsAfter] + sc_user_view($user)
            + ['note' => 'the person sees the change after they sign in again']);

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
