<?php
// A mail sink for the limesurvey skill's tests. It accepts every message and appends one JSON line per message to
// /tmp/sink.jsonl: the envelope sender and recipients, the From, To and Subject headers, and the links in the body.
// It also records an AUTH attempt's user name, never the password.
$srv = stream_socket_server('tcp://0.0.0.0:2525', $errno, $errstr) or die("$errstr\n");
echo "sink listening\n";
while ($c = @stream_socket_accept($srv, -1)) {
    fwrite($c, "220 sink ESMTP\r\n");
    $data = false;
    $body = '';
    $from = '';
    $rcpt = array();
    $auth = 0;
    while (($l = fgets($c)) !== false) {
        $t = rtrim($l, "\r\n");
        if ($data) {
            if ($t === '.') {
                $data = false;
                fwrite($c, "250 queued\r\n");
                // Only a message that says it is quoted-printable is decoded: in any other, a "=" followed by two
                // hex digits (an access code in a link can start with them) is text.
                $decoded = stripos($body, 'quoted-printable') !== false ? quoted_printable_decode($body) : $body;
                $headers = array();
                foreach (preg_split('/\r?\n/', $decoded) as $line) {
                    if (preg_match('/^(Subject|From|To|X-surveyid|X-messagetype):\s*(.*)$/i', $line, $m)) {
                        $headers[strtolower($m[1])] = $m[2];
                    }
                }
                preg_match_all('~https?://[^\s"<>]+~', $decoded, $m);
                file_put_contents('/tmp/sink.jsonl', json_encode(array('mail_from' => $from, 'rcpt_to' => $rcpt,
                    'headers' => $headers, 'links' => array_values(array_unique($m[0]))), JSON_INVALID_UTF8_SUBSTITUTE) . "\n", FILE_APPEND);
                $body = '';
                $rcpt = array();
            } else {
                $body .= $t . "\n";
            }
            continue;
        }
        if ($auth > 0) {
            // The lines of an AUTH LOGIN exchange: the user name, then the password. Neither is kept.
            $auth--;
            fwrite($c, $auth > 0 ? "334 UGFzc3dvcmQ6\r\n" : "235 ok\r\n");
            continue;
        }
        $u = strtoupper($t);
        if (strpos($u, 'EHLO') === 0) {
            fwrite($c, "250-sink\r\n250-AUTH LOGIN\r\n250 8BITMIME\r\n");
        } elseif (strpos($u, 'AUTH LOGIN') === 0) {
            $auth = 2;
            fwrite($c, "334 VXNlcm5hbWU6\r\n");
        } elseif (strpos($u, 'DATA') === 0) {
            $data = true;
            fwrite($c, "354 go\r\n");
        } elseif (strpos($u, 'QUIT') === 0) {
            fwrite($c, "221 bye\r\n");
            break;
        } else {
            if (strpos($u, 'MAIL FROM:') === 0) {
                $from = trim(substr($t, 10));
            }
            if (strpos($u, 'RCPT TO:') === 0) {
                $rcpt[] = trim(substr($t, 8));
            }
            fwrite($c, "250 ok\r\n");
        }
    }
    fclose($c);
}
