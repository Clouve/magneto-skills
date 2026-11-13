<?php
// The stand-in's "being restored" page (tests only): what the real image answers on Apache's port while the
// skill's restore marker is there. GET / is 200, so the platform's health check passes, and everything else is 503.
$path = parse_url(isset($_SERVER['REQUEST_URI']) ? $_SERVER['REQUEST_URI'] : '/', PHP_URL_PATH);
if ($path === '/' || $path === '') {
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><title>LimeSurvey</title><p>LimeSurvey is being restored. Please try again in a few minutes.</p>';
    return true;
}
http_response_code(503);
header('Retry-After: 60');
echo 'LimeSurvey is being restored.';
return true;
