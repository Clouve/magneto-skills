<?php
// Test fixture: what the admin's own save of SuiteCRM's outgoing-email form does. It saves the system account
// through the same bean the form uses, pointed at the test's SMTP sink, with the password from stdin.
require __DIR__ . '/boot.php';
$id = $db->getOne("SELECT id FROM outbound_email WHERE type = 'system' AND deleted = 0");
$account = BeanFactory::getBean('OutboundEmailAccounts', $id);
$account->mail_sendtype = 'SMTP';
$account->mail_smtptype = 'other';
$account->mail_smtpserver = '127.0.0.1';
$account->mail_smtpport = 2525;
$account->mail_smtpssl = 0;
$account->mail_smtpauth_req = 1;
$account->auth_type = 'basic';
$account->mail_smtpuser = 'mailer@example.test';
$account->mail_smtppass = sc_read_secret_line();
$account->smtp_from_name = 'Test CRM';
$account->smtp_from_addr = 'crm@example.test';
$account->save();
sc_done(['saved' => true]);
