<?php
// Test fixture: what an admin's save of Admin > Password Management does to the rule for generated passwords:
// the values go through SuiteCRM's Configurator into config_override.php. The test uses it to put the rule
// back as it found it.
// Usage: users-password-rule.php KEY=VALUE [KEY=VALUE...]   KEY is systexpiration, systexpirationtime,
//                                                           systexpirationtype or systexpirationlogin
require __DIR__ . '/boot.php';
require_once 'modules/Configurator/Configurator.php';
$configurator = new Configurator();
foreach (array_slice($argv, 1) as $pair) {
    [$key, $value] = array_pad(explode('=', $pair, 2), 2, '');
    if (!in_array($key, ['systexpiration', 'systexpirationtime', 'systexpirationtype', 'systexpirationlogin'], true)) {
        sc_fail(64, "not a key of the rule: $key");
    }
    $configurator->config['passwordsetting'][$key] = $value;
}
$configurator->handleOverride();
sc_done(['saved' => true]);
