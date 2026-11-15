<?php
/**
 * LimeSurvey skill: remote/ls-rc.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh (rc.sh is its front end on the
 * agent). It calls one of LimeSurvey's RemoteControl methods from the command line: no HTTP, no password, no
 * session row, no setting changed. RemoteControl does not have to be switched on, and the customer's own use of
 * it is left alone. lib/boot.php says how LimeSurvey is started.
 *
 * Request (stdin): {"method": "<name>", "params": [...]}
 *   params are the method's arguments after the session key. Leave the key out.
 *   params may also be an object keyed by parameter name: {"iSurveyID": 123456}.
 *   {"method": "_methods"} lists the methods this runs, with their parameters, and the ones it refuses, with what
 *   to use instead.
 *   {"method": "_whoami"} says which admin and which LimeSurvey version the calls run as.
 *   "confirmed": true is needed for every method that changes the site (rc.sh --yes). The assistant gives it only
 *   once the admin has asked for or agreed to exactly that change.
 *   "show_codes": true leaves participants' access codes in the reply (rc.sh --show-codes). Without it each one
 *   reads "(hidden)".
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}.
 * Exit code: 0 when the method ran, 1 when it could not be run. LimeSurvey's own refusals come back in result, as
 * {"status": "...", "error_code": "ERR_..."}, with exit 0.
 *
 * Which method is read, write or refused, and what is taken out of every reply, is in lib/rc-policy.php. In short:
 * a method that is not on the list there does not run; the methods that send email, delete, activate, export
 * answers or write answers are refused, each with the name of the script that does that job; no reply holds an
 * encryption key, a password, a session token or a password-link key; and no reply is a file, so nothing here
 * can print an export or write one inside the container.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/rc-policy.php';

$request = ls_rc_request();
if (!isset($request['method']) || !is_string($request['method'])) {
    ls_rc_fail('send one JSON object on stdin: {"method": "...", "params": [...]}');
}
$method = $request['method'];
$params = isset($request['params']) ? $request['params'] : array();
if (!is_array($params)) {
    ls_rc_fail('"params" must be a JSON array or object');
}
$confirmed = isset($request['confirmed']) && $request['confirmed'] === true;
$showCodes = isset($request['show_codes']) && $request['show_codes'] === true;

// The refusals come first, before LimeSurvey is even started.
if ($method !== '_methods' && $method !== '_whoami') {
    list($kind, $reason) = ls_rc_method_policy($method);
    if ($kind === 'refuse') {
        ls_rc_fail("rc.sh does not run $method: $reason");
    }
}

ls_rc_run(function (array $ctx) use ($method, $params, $confirmed, $showCodes) {
    $app = $ctx['app'];
    $admin = $ctx['admin'];
    $handle = $ctx['handle'];

    $reflection = new ReflectionClass('remotecontrol_handle');
    $callable = array();
    foreach ($reflection->getMethods(ReflectionMethod::IS_PUBLIC) as $m) {
        $name = $m->getName();
        if ($name[0] === '_' || $m->isStatic()) {
            continue;
        }
        $callable[$name] = $m;
    }
    $describe = function (ReflectionMethod $m) {
        $out = array();
        foreach ($m->getParameters() as $i => $p) {
            if ($i === 0 && stripos($p->getName(), 'sessionkey') !== false) {
                continue;
            }
            $out[] = $p->getName() . ($p->isOptional() ? '?' : '');
        }
        return $out;
    };
    if ($method === '_methods') {
        ksort($callable);
        $list = array('read' => array(), 'write' => array(), 'refused' => array());
        foreach ($callable as $name => $m) {
            list($kind, $reason) = ls_rc_method_policy($name);
            if ($kind === 'refuse') {
                $list['refused'][$name] = $reason;
            } else {
                $list[$kind][$name] = $describe($m);
            }
        }
        ls_rc_reply(array(
            'read' => $list['read'],
            'write (each needs rc.sh --yes, after the admin asked for or agreed to that change)' => $list['write'],
            'refused (rc.sh does not run these)' => $list['refused'],
        ));
    }
    if ($method === '_whoami') {
        ls_rc_reply(array(
            'uid' => (int) $admin->uid,
            'user' => $admin->users_name,
            'version' => $app->getConfig('versionnumber'),
            'build' => $app->getConfig('buildnumber'),
            'dbversion' => (int) $app->getConfig('DBVersion'),
            'rpcinterface' => $app->getConfig('RPCInterface'),
            // Links in invitation mails start with this. When publicurl is not set they point at localhost.
            'publicurl_set' => !empty($ctx['public_url']['host']),
            'survey_url_example' => $app->createPublicUrl('survey/index', array('sid' => 123456)),
            'php_session_id' => session_id(),
        ));
    }
    if (!isset($callable[$method])) {
        ls_rc_fail("this LimeSurvey has no RemoteControl method '$method'. rc.sh --methods shows the list");
    }
    list($kind) = ls_rc_method_policy($method);

    $m = $callable[$method];
    $declared = $m->getParameters();
    $takesKey = isset($declared[0]) && stripos($declared[0]->getName(), 'sessionkey') !== false;
    $named = $params !== array() && array_keys($params) !== range(0, count($params) - 1);
    $args = array();
    if ($named) {
        $known = array();
        foreach ($declared as $i => $p) {
            if ($i === 0 && $takesKey) {
                continue;
            }
            $known[$p->getName()] = $p;
        }
        $unknown = array_diff(array_keys($params), array_keys($known));
        if ($unknown) {
            ls_rc_fail("$method has no parameter named " . implode(', ', $unknown) . '. It takes: ' . implode(', ', $describe($m)));
        }
        $pending = array();
        foreach ($known as $name => $p) {
            if (array_key_exists($name, $params)) {
                $args = array_merge($args, $pending, array($params[$name]));
                $pending = array();
            } elseif ($p->isOptional()) {
                $pending[] = $p->isDefaultValueAvailable() ? $p->getDefaultValue() : null;
            } else {
                ls_rc_fail("$method needs the parameter $name. It takes: " . implode(', ', $describe($m)));
            }
        }
    } else {
        $args = array_values($params);
        $required = $m->getNumberOfRequiredParameters() - ($takesKey ? 1 : 0);
        $most = $m->getNumberOfParameters() - ($takesKey ? 1 : 0);
        if (count($args) < $required || count($args) > $most) {
            ls_rc_fail("$method takes " . ($required === $most ? $most : "$required to $most") . ' parameters, got ' . count($args) . ': ' . implode(', ', $describe($m)));
        }
    }

    // The gate for everything that changes the site. The survey a change lands in is named when it is active:
    // people are answering it, and the change reaches them at once.
    if ($kind === 'write' && !$confirmed) {
        $live = '';
        $sid = ls_rc_target_survey($method, $args);
        if ($sid) {
            $survey = Survey::model()->findByPk($sid);
            if ($survey && $survey->active === 'Y') {
                $live = " Survey $sid is ACTIVE: people are answering it now, and this changes it for them at once.";
            }
        }
        ls_rc_fail("$method changes the site, so it does not run without the admin's yes.$live Show the admin what this call changes, and once they have asked for or agreed to exactly that, run it again with rc.sh --yes");
    }

    if ($method === 'get_site_settings') {
        $name = isset($args[0]) ? (string) $args[0] : '';
        if (!in_array($name, ls_rc_safe_settings(), true)) {
            ls_rc_fail('"' . $name . '" is not a setting rc.sh shows. It shows: ' . implode(', ', ls_rc_safe_settings()) . '. mail-settings.sh show has the email settings, and nothing shows a password or a key');
        }
    }

    if ($takesKey) {
        array_unshift($args, 'ls-rc-cli');
    }
    $result = $m->invokeArgs($handle, $args);
    if ($result === false) {
        ls_rc_fail('unknown method or incorrect parameters');
    }
    if ($result instanceof BigFile) {
        // No method on the list returns a file. If a LimeSurvey update makes one do so, the file goes and nothing
        // of it is printed.
        @unlink($result->fileName);
        ls_rc_fail("$method returned a file, which rc.sh never prints. responses.sh saves exports in the Files pane");
    }

    // What security.php holds, to take out of the reply wherever it shows up.
    $secrets = array();
    foreach (array('encryptionkeypair', 'encryptionpublickey', 'encryptionsecretkey', 'encryptionnonce', 'encryptionsecretboxkey') as $name) {
        $value = $app->getConfig($name);
        if (is_string($value) && $value !== '') {
            $secrets[] = $value;
        }
    }
    if ($takesKey) {
        array_shift($args);
    }
    $given = $named ? $params : $args;
    ls_rc_reply(ls_rc_filter($method, $result, $showCodes, $secrets, $given));
});

/** The survey a writing method changes, when its arguments name one. 0 when they do not. */
function ls_rc_target_survey($method, array $args)
{
    $first = isset($args[0]) && (is_int($args[0]) || (is_string($args[0]) && ctype_digit($args[0]))) ? (int) $args[0] : 0;
    if (!$first) {
        return 0;
    }
    try {
        switch ($method) {
            case 'set_group_properties':
                $group = QuestionGroup::model()->findByPk($first);
                return $group ? (int) $group->sid : 0;
            case 'set_question_properties':
                $question = Question::model()->findByPk($first);
                return $question ? (int) $question->sid : 0;
            case 'set_quota_properties':
                $quota = Quota::model()->findByPk($first);
                return $quota ? (int) $quota->sid : 0;
            case 'add_survey':
            case 'copy_survey':
                return 0;
        }
    } catch (Throwable $e) {
        return 0;
    }
    return $first;
}
