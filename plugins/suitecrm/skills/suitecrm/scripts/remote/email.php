<?php
/**
 * SuiteCRM skill: remote/email.php (runs inside the SuiteCRM container as www-data; email.sh sends it)
 *
 * Reads SuiteCRM's system outgoing-mail account without its password, sends a test message through it, and
 * fixes the one setting older tools leave wrong (auth_type). The admin types the SMTP password into
 * SuiteCRM's own form (Admin > Email > Outbound Email); nothing here takes or prints one.
 *
 * Usage: email.php status | test ADDRESS | set-auth-basic
 *
 * Exit codes: 0 done; 64 usage; 65 bad input; 2 no server is set, the message was not sent, or SuiteCRM did
 * not keep the change.
 */

require __DIR__ . '/boot.php';

function sc_system_account(): array
{
    global $db;
    $row = $db->fetchOne("SELECT id, mail_sendtype, mail_smtptype, mail_smtpserver, mail_smtpport, mail_smtpuser, mail_smtpauth_req,"
        . " mail_smtpssl, smtp_from_name, smtp_from_addr, auth_type, (mail_smtppass IS NOT NULL AND mail_smtppass <> '') AS has_password"
        . " FROM outbound_email WHERE type = 'system' AND deleted = 0");
    if (empty($row)) {
        sc_fail(2, 'SuiteCRM has no system outgoing-mail account');
    }
    return $row;
}

function sc_email_status(): array
{
    $row = sc_system_account();
    $admin = BeanFactory::newBean('Administration');
    $admin->retrieveSettings('notify');
    $ssl = [0 => 'none', 1 => 'SSL', 2 => 'TLS'][(int) $row['mail_smtpssl']] ?? (string) $row['mail_smtpssl'];
    $warnings = [];
    $configured = trim((string) $row['mail_smtpserver']) !== '';
    if (!$configured) {
        $warnings[] = 'No SMTP server is set, so SuiteCRM cannot send email. The admin fills in Admin > Email > Outbound Email.';
    } else {
        if (trim((string) $row['mail_smtpuser']) !== '' && (string) $row['auth_type'] !== 'basic') {
            $warnings[] = 'A user name is set but auth_type is not "basic", so SuiteCRM 8.10 signs in to the server without it. Servers that need a sign-in will refuse the mail. email.sh set-auth-basic fixes it.';
        }
        if (trim((string) $row['mail_smtpuser']) !== '' && empty($row['has_password'])) {
            $warnings[] = 'A user name is set but no password is stored. The admin enters it in SuiteCRM\'s form.';
        }
        if ((int) $row['mail_smtpport'] === 25) {
            $warnings[] = 'Port 25 is blocked by many hosts and mail services. 587 with TLS is the usual choice.';
        }
        if (trim((string) ($admin->settings['notify_fromaddress'] ?? '')) === '' || stripos((string) $admin->settings['notify_fromaddress'], 'example.com') !== false) {
            $warnings[] = 'The From address is empty or still the example one. Mail services reject a sender they do not know.';
        }
    }
    return [
        'configured' => $configured,
        'server' => $row['mail_smtpserver'] ?: null,
        'port' => (int) $row['mail_smtpport'],
        'security' => $ssl,
        'user' => $row['mail_smtpuser'] ?: null,
        'password_stored' => !empty($row['has_password']),
        'auth_type' => $row['auth_type'] ?: null,
        'from_name' => $admin->settings['notify_fromname'] ?? null,
        'from_address' => $admin->settings['notify_fromaddress'] ?? null,
        'warnings' => $warnings,
    ];
}

$action = $argv[1] ?? '';
switch ($action) {
    case 'status':
        sc_done(sc_email_status());

    case 'test':
        $to = $argv[2] ?? '';
        if (!filter_var($to, FILTER_VALIDATE_EMAIL)) {
            sc_fail(65, "\"$to\" is not an email address");
        }
        $status = sc_email_status();
        if (!$status['configured']) {
            sc_fail(2, 'no SMTP server is set, so nothing was sent. The admin fills in Admin > Email > Outbound Email first (playbooks/configure-email.md).');
        }
        require_once 'include/SugarPHPMailer.php';
        $mail = new SugarPHPMailer();
        $mail->setMailerForSystem();
        $mail->From = (string) $status['from_address'];
        $mail->FromName = (string) $status['from_name'];
        $mail->addAddress($to);
        $mail->Subject = 'SuiteCRM test message';
        $mail->Body = "This is a test message from your SuiteCRM. If you can read it, outgoing email works.\n";
        $mail->Timeout = 20;
        $sent = false;
        $error = '';
        try {
            $sent = (bool) $mail->send();
            $error = (string) $mail->ErrorInfo;
        } catch (Throwable $e) {
            $error = $e->getMessage();
        }
        if (!$sent) {
            sc_flush_noise();
            echo json_encode(['sent' => false, 'to' => $to, 'error' => $error, 'account' => $status], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n";
            fwrite(STDERR, "[suitecrm] the test message was not sent: $error\n");
            exit(2);
        }
        sc_done(['sent' => true, 'to' => $to, 'account' => $status,
            'note' => 'sent means the server took the message; ask the person whether it arrived, and to check the spam folder']);

    case 'set-auth-basic':
        $row = sc_system_account();
        if (trim((string) $row['mail_smtpuser']) === '') {
            sc_fail(2, 'no SMTP user name is set, so there is nothing to sign in with. Nothing was changed.');
        }
        if ((string) $row['auth_type'] === 'basic') {
            sc_done(['changed' => false, 'auth_type' => 'basic']);
        }
        $before = (string) $db->getOne("SELECT mail_smtppass FROM outbound_email WHERE id = " . $db->quoted($row['id']));
        $account = BeanFactory::getBean('OutboundEmailAccounts', $row['id']);
        if (empty($account->id)) {
            sc_fail(2, 'SuiteCRM could not load the system account');
        }
        $account->auth_type = 'basic';
        $account->mail_smtpauth_req = 1;
        // The password field is left alone: an unset password keeps the stored one.
        unset($account->mail_smtppass);
        $account->save();
        $after = sc_system_account();
        $afterPass = (string) $db->getOne("SELECT mail_smtppass FROM outbound_email WHERE id = " . $db->quoted($row['id']));
        if ((string) $after['auth_type'] !== 'basic') {
            sc_fail(2, 'SuiteCRM did not keep auth_type; check email.sh status');
        }
        if ($before !== $afterPass) {
            // Put the stored value back exactly as it was: the change was to one flag, never to the password.
            $db->query("UPDATE outbound_email SET mail_smtppass = " . $db->quoted($before) . " WHERE id = " . $db->quoted($row['id']));
        }
        sc_done(['changed' => true, 'auth_type' => 'basic', 'stored_password_untouched' => true]);

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
