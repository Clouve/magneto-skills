<?php
// The tests' own back door into LimeSurvey (never part of the skill). It runs as www-data in the app container,
// started the way the skill's scripts start LimeSurvey (the skill's remote/lib/boot.php, copied next to this file),
// and does the set-up and the look-ups that a test needs and no script of the skill offers.
//
// Request (stdin): {"op": "...", ...}. Reply: one line of JSON, as the skill's scripts give it.
//   set-smtp        host, user, password: SMTP as the email method, the password stored encrypted as LimeSurvey does
//   smtp-password   the stored SMTP password, decrypted (to prove that a restore brought the right keys)
//   set-global      name, value: one global setting
//   password-ok     user, password: whether that password signs the account in
//   add-response    sid, data: one answer set, through RemoteControl's add_response
//   encrypt-email   sid: switches on encryption of the participants' email column for a survey
//   last-login      user: the account's last_login value
//   plugin-secret   value: registers Clouve's SuiteCRM plugin's name (switched off) when it is not there, and stores
//                   one of its passwords the way LimeSurvey stores a plugin's encrypted setting
require __DIR__ . '/remote/lib/boot.php';
$request = ls_rc_request();
ls_rc_run(function (array $ctx) use ($request) {
    $op = isset($request['op']) ? $request['op'] : '';
    switch ($op) {
        case 'set-smtp':
            SettingGlobal::setSetting('emailmethod', 'smtp');
            SettingGlobal::setSetting('emailsmtphost', $request['host']);
            SettingGlobal::setSetting('emailsmtpuser', $request['user']);
            SettingGlobal::setSetting('emailsmtpssl', '');
            SettingGlobal::setSetting('emailsmtppassword', LSActiveRecord::encryptSingle($request['password']));
            ls_rc_reply(true);
            break;
        case 'smtp-password':
            ls_rc_reply(LSActiveRecord::decryptSingle(Yii::app()->getConfig('emailsmtppassword')));
            break;
        case 'set-global':
            SettingGlobal::setSetting($request['name'], $request['value']);
            ls_rc_reply(true);
            break;
        case 'password-ok':
            $user = User::model()->findByAttributes(array('users_name' => $request['user']));
            ls_rc_reply($user ? password_verify($request['password'], $user->password) : null);
            break;
        case 'add-response':
            ls_rc_reply($ctx['handle']->add_response('ls-rc-cli', (int) $request['sid'], $request['data']));
            break;
        case 'last-login':
            $user = User::model()->findByAttributes(array('users_name' => $request['user']));
            ls_rc_reply($user ? array('last_login' => $user->last_login, 'modified' => $user->modified) : null);
            break;
        case 'plugin-secret':
            $plugin = Plugin::model()->findByAttributes(array('name' => 'SuiteCRMIntegration'));
            if (!$plugin) {
                $plugin = new Plugin();
                $plugin->name = 'SuiteCRMIntegration';
                $plugin->plugin_type = 'user';
                $plugin->active = 0;
                $plugin->version = '0';
                $plugin->save();
            }
            $row = new PluginSetting();
            $row->plugin_id = $plugin->id;
            $row->model = null;
            $row->model_id = null;
            $row->key = 'suitecrm_admin_password';
            $row->value = json_encode(LSActiveRecord::encryptSingle($request['value']));
            ls_rc_reply($row->save());
            break;
        default:
            ls_rc_fail('unknown op');
    }
});
