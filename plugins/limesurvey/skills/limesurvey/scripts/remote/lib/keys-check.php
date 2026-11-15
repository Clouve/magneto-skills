<?php
/**
 * LimeSurvey skill: remote/lib/keys-check.php (run as www-data by restore.sh, as its last check)
 *
 * Starts LimeSurvey on the site as it is, as lib/boot.php does, and says whether its encryption keys
 * (application/config/security.php) can read the stored SMTP password. A reply of any kind proves that LimeSurvey
 * starts on the restored data. It runs only once security.php is in place. lib/keys-probe.php is the wider test
 * of the keys, and needs no start of LimeSurvey.
 *
 * Reply (stdout): {"result": {"keys_ok": true|false|null, "tested": "..."}, "error": null}
 *   true   an encrypted value was found and read
 *   false  an encrypted value was found and the keys cannot read it
 *   null   the database holds nothing encrypted to test with
 */
require __DIR__ . '/boot.php';
ls_rc_run(function (array $ctx) {
    $stored = (string) Yii::app()->getConfig('emailsmtppassword');
    if ($stored !== '') {
        try {
            LSActiveRecord::decryptSingle($stored);
            ls_rc_reply(array('keys_ok' => true, 'tested' => 'the stored SMTP password'));
        } catch (Throwable $e) {
            ls_rc_reply(array('keys_ok' => false, 'tested' => 'the stored SMTP password'));
        }
    }
    ls_rc_reply(array('keys_ok' => null, 'tested' => 'nothing encrypted is stored'));
});
