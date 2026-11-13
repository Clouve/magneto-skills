<?php
// Tests only: a respondent's browser. Completes one all-in-one LimeSurvey page over HTTP, from inside the
// LimeSurvey container, as tests/crm-kit.test.sh in the magneto repo does.
// Usage: php respond.php <survey id> <field>=<answer>...
// Prints "submitted" when LimeSurvey answers with its closing page, "not submitted" otherwise.
$sid = $argv[1];
$base = 'http://127.0.0.1:8080';
$answers = [];
foreach (array_slice($argv, 2) as $kv) {
    [$k, $v] = explode('=', $kv, 2);
    $answers[$k] = $v;
}
$jar = tempnam('/tmp', 'ckr');
function req($url, $jar, $post = null)
{
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_COOKIEJAR => $jar, CURLOPT_COOKIEFILE => $jar,
        CURLOPT_FOLLOWLOCATION => true, CURLOPT_TIMEOUT => 120, CURLOPT_HTTPHEADER => ['Host: localhost']]);
    if ($post !== null) {
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $post);
    }
    return (string) curl_exec($ch);
}
$html = req("$base/index.php/$sid?lang=en&newtest=Y", $jar);
preg_match_all('#<input\b[^>]*type=["\']hidden["\'][^>]*>#', $html, $m);
$pairs = [];
foreach ($m[0] as $tag) {
    if (!preg_match('#name=["\']([^"\']*)["\']#', $tag, $n) || array_key_exists($n[1], $answers)) {
        continue;
    }
    $v = preg_match('#value=["\']([^"\']*)["\']#', $tag, $vv) ? html_entity_decode($vv[1]) : '';
    // The browser's script marks which questions are shown. Without a script every question counts as shown,
    // and LimeSurvey works out for itself which ones apply.
    if (strpos($n[1], 'relevance') === 0) {
        $v = '1';
    }
    $pairs[] = urlencode($n[1]) . '=' . urlencode($v);
}
foreach ($answers as $k => $v) {
    $pairs[] = urlencode($k) . '=' . urlencode($v);
}
$pairs[] = 'move=movesubmit';
$out = req("$base/index.php/$sid", $jar, implode('&', $pairs));
unlink($jar);
echo stripos(strip_tags($out), 'Thank you') !== false ? "submitted\n" : "not submitted\n";
