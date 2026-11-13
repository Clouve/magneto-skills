<?php
/**
 * LimeSurvey skill: remote/ls-mail.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. invitations.sh and
 * mail-settings.sh are its front ends on the agent. Everything here that can send email does so only on a request
 * that says "send": true, which the front ends set for their --send option and nothing else.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   preview    sid, kind (invite or remind), and for remind min_days and optionally max_reminders; optionally
 *              token_ids. Sends nothing. Result: who the mail would come from, how many people would get it, how
 *              it would be sent, and "blockers": the reasons it must not be sent as things are.
 *   send       the same, plus "send": true and "expect": the number of recipients the admin agreed to. It runs the
 *              preview's checks again and refuses when there is a blocker or the number has changed. Then it sends
 *              through LimeSurvey's own invite_participants or remind_participants, batch after batch, until
 *              nobody is left or a batch sends nothing. Afterwards it looks at who is still due: LimeSurvey's
 *              mailer drops an address it does not accept without a word, so the people who were to get mail and
 *              did not are counted and named by their ids ("not_mailed").
 *   settings   LimeSurvey's email settings. The SMTP password is never returned: only whether one is stored, and
 *              whether this site's keys can still read it.
 *   test       to, and "send": true. Sends LimeSurvey's own test message to that address and returns what the mail
 *              server said, with any credential taken out.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 *
 * The blockers, each seen in tests or read in LimeSurvey's source:
 *   - the survey is inactive. LimeSurvey's invite_participants does not check, and mails people a link that
 *     answers "not active";
 *   - the survey has no participant list;
 *   - the survey has ended (its expiry date is past);
 *   - the site has no public address (publicurl), so the links in the mail would point at localhost;
 *   - the email method cannot deliver here: "mail", "sendmail" and "qmail" need a sendmail program, and the image
 *     has none. SMTP is the method that works;
 *   - the sender address is missing or is not an address;
 *   - a reminder without a minimum gap of at least one day. LimeSurvey would remind everyone again on every call.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** LimeSurvey's email settings, without the password. */
function ls_mail_settings()
{
    $app = Yii::app();
    $stored = (string) $app->getConfig('emailsmtppassword');
    $readable = null;
    if ($stored !== '') {
        try {
            LSActiveRecord::decryptSingle($stored);
            $readable = true;
        } catch (Throwable $e) {
            $readable = false;
        }
    }
    $method = (string) $app->getConfig('emailmethod');
    return array(
        'method' => $method,
        'smtp_host' => (string) $app->getConfig('emailsmtphost'),
        'smtp_user' => (string) $app->getConfig('emailsmtpuser'),
        'smtp_encryption' => (string) $app->getConfig('emailsmtpssl'),
        'smtp_password_stored' => $stored !== '',
        'smtp_password_readable' => $readable,
        'site_sender_name' => (string) $app->getConfig('siteadminname'),
        'site_sender_email' => (string) $app->getConfig('siteadminemail'),
        'site_bounce_email' => (string) $app->getConfig('siteadminbounce'),
        'batch_size' => (int) $app->getConfig('maxemails'),
        'can_deliver' => ls_mail_can_deliver($method),
    );
}

/** Whether the email method can deliver in this container, and why not when it cannot. */
function ls_mail_can_deliver($method)
{
    if ($method === 'smtp' || $method === 'plugin') {
        return true;
    }
    foreach (array('/usr/sbin/sendmail', '/usr/lib/sendmail', '/var/qmail/bin/sendmail') as $binary) {
        if (is_executable($binary)) {
            return true;
        }
    }
    return false;
}

/** The ids of the people who are due an invitation or a reminder now. */
function ls_mail_due_ids($sid, $kind, array $tokenIds, $minDays, $maxReminders)
{
    $tokens = TokenDynamic::model($sid);
    if ($kind === 'invite') {
        return $tokens->findParticipantIDs($tokenIds ?: false, 0, true, "emailstatus = 'OK'", '', '', true);
    }
    $delay = '';
    if ($minDays !== null && $minDays >= 1) {
        $compared = gmdate('Y-m-d H:i', time() - 86400 * $minDays);
        $delay = " ((remindersent = 'N' AND sent < '" . $compared . "')  OR  (remindersent < '" . $compared . "'))";
    }
    $count = $maxReminders !== null && $maxReminders >= 1 ? 'remindercount < ' . $maxReminders : '';
    return $tokens->findParticipantIDs($tokenIds ?: false, 0, false, "emailstatus = 'OK'", $count, $delay, true);
}

/** Everything invitations.sh shows before a send, and the reasons not to send. */
function ls_mail_preview(array $request)
{
    $app = Yii::app();
    $sid = ls_sid($request);
    $survey = ls_survey($sid);
    $kind = isset($request['kind']) ? $request['kind'] : '';
    if ($kind !== 'invite' && $kind !== 'remind') {
        ls_rc_fail('kind is invite or remind');
    }
    $tokenIds = array();
    if (!empty($request['token_ids'])) {
        if (!is_array($request['token_ids'])) {
            ls_rc_fail('token_ids has to be a list of participant ids');
        }
        foreach ($request['token_ids'] as $id) {
            if (!is_int($id) && !(is_string($id) && ctype_digit($id))) {
                ls_rc_fail('token_ids has to be a list of participant ids (numbers)');
            }
            $tokenIds[] = (int) $id;
        }
    }
    $minDays = isset($request['min_days']) && $request['min_days'] !== '' ? (int) $request['min_days'] : null;
    $maxReminders = isset($request['max_reminders']) && $request['max_reminders'] !== '' ? (int) $request['max_reminders'] : null;

    $blockers = array();
    $settings = ls_mail_settings();
    $title = $app->db->createCommand('SELECT surveyls_title FROM {{surveys_languagesettings}} WHERE surveyls_survey_id = :sid AND surveyls_language = :lang')
        ->queryScalar(array(':sid' => $sid, ':lang' => $survey->language));

    if ($survey->active !== 'Y') {
        $blockers[] = 'the survey is inactive, so the link in the mail would not work. The admin activates the survey first';
    }
    if (!empty($survey->expires) && strtotime($survey->expires . ' UTC') !== false && strtotime($survey->expires . ' UTC') < time()) {
        $blockers[] = 'the survey ended on ' . $survey->expires . ' UTC, so nobody could answer it';
    }
    $hasList = tableExists('{{tokens_' . $sid . '}}');
    if (!$hasList) {
        $blockers[] = 'the survey has no participant list';
    }
    if (empty($GLOBALS['lsPublicUrl']['host'])) {
        $blockers[] = 'the site has no public address (publicurl), so the links in the mail would point at localhost';
    }
    if (!$settings['can_deliver']) {
        $blockers[] = 'the email method is "' . $settings['method'] . '", which needs a sendmail program, and this container has none. The admin sets up SMTP in LimeSurvey first (playbooks/set-up-email.md)';
    }
    if ($settings['method'] === 'smtp' && $settings['smtp_password_readable'] === false) {
        $blockers[] = 'the stored SMTP password cannot be read with this site\'s keys. The admin types it into LimeSurvey\'s email settings again';
    }
    if ($kind === 'remind' && ($minDays === null || $minDays < 1)) {
        $blockers[] = 'a reminder needs a minimum gap of at least 1 day since the invitation or the last reminder (--min-days). Without one LimeSurvey reminds everyone again on every call';
    }
    if ($maxReminders !== null && $maxReminders < 1) {
        $blockers[] = '--max-reminders has to be 1 or more';
    }

    // The sender the mail will carry: what LimeSurvey's mailer sets for this survey.
    $mailer = \LimeMailer::getInstance(\LimeMailer::ResetComplete);
    $mailer->setSurvey($sid);
    $from = (string) $mailer->From;
    $fromName = (string) $mailer->FromName;
    $returnPath = (string) $mailer->Sender;
    if ($from === '' || !\LimeMailer::validateAddress($from)) {
        $blockers[] = 'the sender address ("' . $from . '") is missing or is not an email address. Set the survey\'s administrator email first';
    }

    $recipients = 0;
    $counts = null;
    if ($hasList) {
        $recipients = count(ls_mail_due_ids($sid, $kind, $tokenIds, $minDays, $maxReminders));
        $table = '{{tokens_' . $sid . '}}';
        $one = function ($where) use ($app, $table) {
            return (int) $app->db->createCommand("SELECT COUNT(*) FROM $table" . ($where ? " WHERE $where" : ''))->queryScalar();
        };
        $counts = array('total' => $one(''), 'invited' => $one("sent NOT IN ('N', '')"),
            'completed' => $one("completed NOT IN ('N', '')"), 'email_not_ok' => $one("emailstatus <> 'OK'"));
    }
    $subjectField = $kind === 'invite' ? 'surveyls_email_invite_subj' : 'surveyls_email_remind_subj';
    $subject = $app->db->createCommand("SELECT $subjectField FROM {{surveys_languagesettings}} WHERE surveyls_survey_id = :sid AND surveyls_language = :lang")
        ->queryScalar(array(':sid' => $sid, ':lang' => $survey->language));

    return array(
        'sid' => $sid,
        'title' => $title === false ? null : $title,
        'active' => $survey->active,
        'kind' => $kind,
        'recipients' => $recipients,
        'participants' => $counts,
        'sender_name' => $fromName,
        'sender_email' => $from,
        'return_path' => $returnPath,
        'subject' => $subject === false ? null : $subject,
        'method' => $settings['method'],
        'smtp_host' => $settings['smtp_host'],
        'batch_size' => $settings['batch_size'],
        'min_days' => $minDays,
        'max_reminders' => $maxReminders,
        'token_ids' => $tokenIds,
        'link_example' => $app->createPublicUrl('survey/index', array('sid' => $sid, 'token' => 'ACCESS-CODE', 'lang' => $survey->language)),
        'blockers' => $blockers,
    );
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $handle = $ctx['handle'];
    $GLOBALS['lsPublicUrl'] = $ctx['public_url'];

    switch ($action) {
        case 'settings':
            ls_rc_reply(ls_mail_settings());
            break;

        case 'preview':
            ls_rc_reply(ls_mail_preview($request));
            break;

        case 'send':
            if (empty($request['send']) || $request['send'] !== true) {
                ls_rc_fail('nothing was sent: the request does not say "send": true');
            }
            if (!isset($request['expect']) || !is_int($request['expect'])) {
                ls_rc_fail('nothing was sent: the request has to say how many recipients the admin agreed to ("expect")');
            }
            $preview = ls_mail_preview($request);
            if ($preview['blockers']) {
                ls_rc_reply(array('sent' => 0, 'refused' => true, 'blockers' => $preview['blockers']) + $preview);
            }
            if ($preview['recipients'] !== $request['expect']) {
                ls_rc_reply(array('sent' => 0, 'refused' => true, 'blockers' => array('the admin agreed to ' . $request['expect'] . ' recipients and the list now gives ' . $preview['recipients'] . '. Show the new number and ask again')) + $preview);
            }
            if ($preview['recipients'] === 0) {
                ls_rc_reply(array('sent' => 0, 'refused' => false, 'failed' => array(), 'left' => 0, 'not_mailed' => 0, 'not_mailed_ids' => array()) + $preview);
            }
            $sid = $preview['sid'];
            $ids = $preview['token_ids'] ?: null;
            $sent = 0;
            $failed = array();
            $left = 0;
            // One batch is LimeSurvey's "maxemails" setting. More batches than the list can need means something loops.
            $rounds = (int) ceil($preview['recipients'] / max(1, $preview['batch_size'])) + 2;
            while ($rounds-- > 0) {
                if ($preview['kind'] === 'invite') {
                    $reply = $handle->invite_participants('ls-rc-cli', $sid, $ids, true, true);
                } else {
                    $reply = $handle->remind_participants('ls-rc-cli', $sid, $preview['min_days'], $preview['max_reminders'], $ids ?: false, true);
                }
                if (!is_array($reply)) {
                    break;
                }
                if (isset($reply['error_code'])) {
                    if ($reply['error_code'] !== 'ERR_NO_DATA') {
                        ls_rc_reply(array('sent' => $sent, 'refused' => false, 'failed' => array_values($failed), 'left' => $left,
                            'not_mailed' => 0, 'not_mailed_ids' => array(), 'stopped' => 'LimeSurvey stopped: ' . $reply['status']) + $preview);
                    }
                    $left = 0;
                    break;
                }
                $batch = 0;
                foreach ($reply as $tid => $one) {
                    if (!is_array($one)) {
                        continue;
                    }
                    if (isset($one['status']) && $one['status'] === 'OK') {
                        $batch++;
                        unset($failed[$tid]);
                    } else {
                        $failed[$tid] = array('id' => (int) $tid, 'error' => isset($one['error']) ? (string) $one['error'] : 'not sent');
                    }
                }
                $sent += $batch;
                $left = isset($reply['status']) ? (int) $reply['status'] : 0;
                if ($batch === 0 || $left === 0) {
                    break;
                }
            }
            // Who was to get mail and is still due. LimeSurvey takes an address its mailer does not accept out of
            // the batch without a word, so those people show up here and nowhere else.
            $due = array_map('intval', (array) ls_mail_due_ids($sid, $preview['kind'], $preview['token_ids'], $preview['min_days'], $preview['max_reminders']));
            $silent = array_values(array_diff($due, array_map('intval', array_keys($failed))));
            ls_rc_reply(array('sent' => $sent, 'refused' => false, 'failed' => array_values($failed), 'left' => max($left, count($due)),
                'not_mailed' => count($silent), 'not_mailed_ids' => array_slice($silent, 0, 50)) + $preview);
            break;

        case 'test':
            if (empty($request['send']) || $request['send'] !== true) {
                ls_rc_fail('nothing was sent: the request does not say "send": true');
            }
            $to = trim((string) ls_need($request, 'to'));
            if (!\LimeMailer::validateAddress($to)) {
                ls_rc_fail('"' . $to . '" is not an email address');
            }
            $settings = ls_mail_settings();
            if (!$settings['can_deliver']) {
                ls_rc_reply(array('sent' => false, 'error' => 'the email method is "' . $settings['method'] . '", which needs a sendmail program, and this container has none. The admin sets up SMTP in LimeSurvey first') + $settings);
            }
            // LimeSurvey's own test message (Global settings, Email settings, "Send test email").
            $mailer = new \LimeMailer();
            $mailer->emailType = 'settings_test';
            $mailer->rawSubject = 'Test email from ' . Yii::app()->getConfig('sitename');
            $mailer->rawBody = 'This is a test email from your LimeSurvey. If you can read it, outgoing email works.';
            $mailer->SMTPDebug = 2;
            $mailer->setTo($to);
            $mailer->setFrom(Yii::app()->getConfig('siteadminemail'), Yii::app()->getConfig('siteadminname'));
            $ok = (bool) $mailer->sendMessage();
            // What the mail server said, without the lines that carry a credential.
            $secrets = array();
            try {
                $password = (string) LSActiveRecord::decryptSingle(Yii::app()->getConfig('emailsmtppassword'));
            } catch (Throwable $e) {
                $password = '';
            }
            foreach (array($password, (string) $settings['smtp_user']) as $secret) {
                if ($secret !== '') {
                    $secrets[] = $secret;
                    $secrets[] = base64_encode($secret);
                }
            }
            if ($password !== '') {
                $secrets[] = base64_encode("\0" . $settings['smtp_user'] . "\0" . $password);
            }
            $dialogue = array();
            foreach ((array) $mailer->getDebug() as $line) {
                $line = trim(preg_replace('/\s+/', ' ', (string) $line));
                if ($line === '') {
                    continue;
                }
                foreach ($secrets as $secret) {
                    $line = str_replace($secret, '[hidden]', $line);
                }
                if (preg_match('/^(.*CLIENT -> SERVER: )(AUTH \S+)\s+\S+/', $line, $m)) {
                    $line = $m[1] . $m[2] . ' [hidden]';
                }
                $dialogue[] = substr($line, 0, 300);
            }
            ls_rc_reply(array('sent' => $ok, 'to' => $to, 'error' => $ok ? null : (string) $mailer->getError(),
                'dialogue' => array_slice($dialogue, -40)) + $settings);
            break;

        default:
            ls_rc_fail('unknown action. ls-mail.php takes preview, send, settings and test');
    }
});
