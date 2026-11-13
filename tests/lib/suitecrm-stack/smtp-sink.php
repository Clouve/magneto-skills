<?php
// Throwaway SMTP server for tests/suitecrm-scripts.test.sh. It listens on 127.0.0.1:2525 inside the SuiteCRM
// container, takes AUTH LOGIN, and writes one line per message to /tmp/smtp-sink.log: whether the client
// authenticated, as whom, the sender, the recipients and the subject. It never stores a password.
$server = stream_socket_server('tcp://127.0.0.1:2525', $errno, $error) or exit("listen failed: $error\n");
while ($conn = @stream_socket_accept($server, -1)) {
    $say = fn ($line) => fwrite($conn, $line . "\r\n");
    $say('220 test-sink ESMTP');
    $inData = false;
    $auth = 'no-auth';
    $envelope = [];
    $subject = '';
    while (($line = fgets($conn)) !== false) {
        $text = rtrim($line, "\r\n");
        if ($inData) {
            if ($text === '.') {
                $inData = false;
                file_put_contents('/tmp/smtp-sink.log', "$auth ; " . implode(' ; ', $envelope) . " ; subject=$subject\n", FILE_APPEND);
                $envelope = [];
                $subject = '';
                $say('250 OK queued');
            } elseif (stripos($text, 'Subject:') === 0 && $subject === '') {
                $subject = trim(substr($text, 8));
            }
            continue;
        }
        $verb = strtoupper(substr($text, 0, 4));
        if ($verb === 'EHLO') {
            $say('250-test-sink');
            $say('250-AUTH LOGIN');
            $say('250 8BITMIME');
        } elseif ($verb === 'HELO') {
            $say('250 test-sink');
        } elseif ($verb === 'AUTH') {
            $say('334 VXNlcm5hbWU6');
            $user = base64_decode(trim((string) fgets($conn)));
            $say('334 UGFzc3dvcmQ6');
            $length = strlen(base64_decode(trim((string) fgets($conn))));
            $auth = "auth user=$user password_length=$length";
            $say('235 Authentication successful');
        } elseif ($verb === 'MAIL' || $verb === 'RCPT') {
            $envelope[] = $text;
            $say('250 OK');
        } elseif ($verb === 'DATA') {
            $inData = true;
            $say('354 End data with <CR><LF>.<CR><LF>');
        } elseif ($verb === 'QUIT') {
            $say('221 Bye');
            break;
        } else {
            $say('250 OK');
        }
    }
    fclose($conn);
}
