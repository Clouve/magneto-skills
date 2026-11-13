<?php
/**
 * LimeSurvey skill: remote/ls-participants.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. participants.sh is its front
 * end on the agent. It works on one survey's participant list through LimeSurvey's own RemoteControl methods, so
 * access codes are made and encrypted fields are stored the way LimeSurvey does it. It sends no email.
 *
 * Request (stdin): one JSON object with "action", "sid" and what the action needs.
 *   create-list   makes the survey's participant list (LimeSurvey's activate_tokens). On an inactive survey it
 *                 just makes it. On an ACTIVE survey a list closes the survey at once to everyone who has no
 *                 access code, so there it needs "confirmed_closes_open_survey": true, which participants.sh sets
 *                 for its --yes-closes-the-open-survey option and nothing else. Without it the reply says
 *                 "refused": true, with the number of answer sets so far, and nothing is changed.
 *   add           data_base64 and format: json (an array of objects) or csv (a header row, then one person per
 *                 row). Each person needs email; firstname, lastname and language are optional. A row without a
 *                 valid email address, or with an address the list already has, is skipped and counted. Result:
 *                 added, skipped_invalid, skipped_duplicate, total. No access code is returned.
 *   list          start, limit (100 at most per call). Each person's id, name, email, email status, and whether
 *                 they were invited, reminded and have completed. No access code is returned.
 *   count         how many people are on the list, were invited, were reminded and have completed
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** A JSON error unless the survey has a participant list. */
function ls_need_list($sid)
{
    if (!tableExists('{{tokens_' . (int) $sid . '}}')) {
        ls_rc_fail("survey $sid has no participant list yet. participants.sh create-list makes one");
    }
}

/** A JSON error when a RemoteControl method refused. */
function ls_rc_ok($reply, $what)
{
    if (is_array($reply) && isset($reply['error_code'])) {
        ls_rc_fail("LimeSurvey refused to $what: " . (isset($reply['status']) ? $reply['status'] : $reply['error_code']));
    }
    return $reply;
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $handle = $ctx['handle'];
    $db = Yii::app()->db;
    $sid = ls_sid($request);
    $survey = ls_survey($sid);
    $table = '{{tokens_' . $sid . '}}';

    switch ($action) {
        case 'create-list':
            if (tableExists($table)) {
                ls_rc_reply(array('created' => false, 'note' => "survey $sid already has a participant list"));
            }
            if ($survey->active === 'Y' && (!isset($request['confirmed_closes_open_survey']) || $request['confirmed_closes_open_survey'] !== true)) {
                $answers = tableExists('{{responses_' . $sid . '}}') ? (int) $db->createCommand('SELECT COUNT(*) FROM {{responses_' . $sid . '}}')->queryScalar() : 0;
                ls_rc_reply(array('created' => false, 'refused' => true, 'active' => 'Y', 'answers' => $answers));
            }
            ls_rc_ok($handle->activate_tokens('ls-rc-cli', $sid), 'make the participant list');
            ls_rc_reply(array('created' => true, 'active' => $survey->active));
            break;

        case 'add':
            ls_need_list($sid);
            $bytes = ls_data_bytes($request);
            $format = strtolower((string) ls_need($request, 'format'));
            $people = array();
            if ($format === 'json') {
                $people = json_decode($bytes, true);
                if (!is_array($people) || ($people && array_keys($people) !== range(0, count($people) - 1))) {
                    ls_rc_fail('the JSON has to be an array of people, each an object with email and, if known, firstname and lastname');
                }
            } elseif ($format === 'csv') {
                if (substr($bytes, 0, 3) === "\xEF\xBB\xBF") {
                    $bytes = substr($bytes, 3);
                }
                $lines = preg_split('/\r\n|\n|\r/', trim($bytes));
                $delimiter = substr_count($lines[0], ';') > substr_count($lines[0], ',') ? ';' : ',';
                $header = array_map(function ($h) {
                    return strtolower(trim($h));
                }, str_getcsv(array_shift($lines), $delimiter, '"', '\\'));
                if (!in_array('email', $header, true)) {
                    ls_rc_fail('the first row of the CSV has to name the columns, and one of them has to be email. firstname, lastname and language are the others it reads');
                }
                foreach ($lines as $line) {
                    if (trim($line) === '') {
                        continue;
                    }
                    $cells = str_getcsv($line, $delimiter, '"', '\\');
                    $person = array();
                    foreach ($header as $i => $name) {
                        $person[$name] = isset($cells[$i]) ? trim($cells[$i]) : '';
                    }
                    $people[] = $person;
                }
            } else {
                ls_rc_fail('the format is json or csv');
            }
            if (count($people) > 50000) {
                ls_rc_fail('that is over 50,000 people in one call. Split the list');
            }

            // The addresses the list already has. They can be stored encrypted, so each row is read through the model.
            $have = array();
            foreach (Token::model($sid)->findAll() as $token) {
                $token->decrypt();
                foreach (preg_split('/[;,]/', (string) $token->email) as $address) {
                    $have[strtolower(trim($address))] = true;
                }
            }
            $rows = array();
            $invalid = 0;
            $duplicate = 0;
            $allowed = array('firstname', 'lastname', 'email', 'language', 'validfrom', 'validuntil', 'usesleft');
            foreach ($people as $person) {
                if (!is_array($person)) {
                    $invalid++;
                    continue;
                }
                $person = array_change_key_case($person, CASE_LOWER);
                $email = isset($person['email']) ? trim((string) $person['email']) : '';
                if ($email === '' || !LimeMailer::validateAddress($email)) {
                    $invalid++;
                    continue;
                }
                if (isset($have[strtolower($email)])) {
                    $duplicate++;
                    continue;
                }
                $have[strtolower($email)] = true;
                $row = array();
                foreach ($allowed as $key) {
                    if (isset($person[$key]) && $person[$key] !== '') {
                        $row[$key] = is_string($person[$key]) ? trim($person[$key]) : $person[$key];
                    }
                }
                foreach ($person as $key => $value) {
                    if (preg_match('/^attribute_[0-9]+$/', (string) $key) && $value !== '') {
                        $row[$key] = $value;
                    }
                }
                $row['email'] = $email;
                $row['emailstatus'] = 'OK';
                $rows[] = $row;
            }
            $added = 0;
            if ($rows) {
                $reply = ls_rc_ok($handle->add_participants('ls-rc-cli', $sid, $rows, true), 'add the participants');
                foreach ((array) $reply as $one) {
                    if (is_array($one) && !empty($one['tid'])) {
                        $added++;
                    }
                }
            }
            ls_rc_reply(array('added' => $added, 'not_added' => count($rows) - $added, 'skipped_invalid' => $invalid,
                'skipped_duplicate' => $duplicate, 'total' => (int) $db->createCommand("SELECT COUNT(*) FROM $table")->queryScalar()));
            break;

        case 'list':
            ls_need_list($sid);
            $start = isset($request['start']) ? max(0, (int) $request['start']) : 0;
            $limit = isset($request['limit']) ? min(100, max(1, (int) $request['limit'])) : 50;
            $reply = $handle->list_participants('ls-rc-cli', $sid, $start, $limit, false,
                array('emailstatus', 'language', 'sent', 'remindersent', 'remindercount', 'completed', 'usesleft', 'validfrom', 'validuntil'));
            $people = array();
            if (is_array($reply) && !isset($reply['error_code'])) {
                foreach ($reply as $one) {
                    $info = isset($one['participant_info']) ? $one['participant_info'] : array();
                    $people[] = array(
                        'id' => (int) $one['tid'],
                        'firstname' => isset($info['firstname']) ? $info['firstname'] : '',
                        'lastname' => isset($info['lastname']) ? $info['lastname'] : '',
                        'email' => isset($info['email']) ? $info['email'] : '',
                        'emailstatus' => isset($one['emailstatus']) ? $one['emailstatus'] : '',
                        'language' => isset($one['language']) ? $one['language'] : '',
                        'invited' => isset($one['sent']) ? $one['sent'] : 'N',
                        'reminded' => isset($one['remindersent']) ? $one['remindersent'] : 'N',
                        'reminders' => isset($one['remindercount']) ? (int) $one['remindercount'] : 0,
                        'completed' => isset($one['completed']) ? $one['completed'] : 'N',
                    );
                }
            } elseif (is_array($reply) && $reply['error_code'] !== 'ERR_NO_DATA') {
                ls_rc_ok($reply, 'list the participants');
            }
            ls_rc_reply(array('start' => $start, 'people' => $people,
                'total' => (int) $db->createCommand("SELECT COUNT(*) FROM $table")->queryScalar()));
            break;

        case 'count':
            ls_need_list($sid);
            $one = function ($where) use ($db, $table) {
                return (int) $db->createCommand("SELECT COUNT(*) FROM $table" . ($where ? " WHERE $where" : ''))->queryScalar();
            };
            ls_rc_reply(array(
                'total' => $one(''),
                'invited' => $one("sent NOT IN ('N', '')"),
                'reminded' => $one("remindersent NOT IN ('N', '')"),
                'completed' => $one("completed NOT IN ('N', '')"),
                'email_not_ok' => $one("emailstatus <> 'OK'"),
            ));
            break;

        default:
            ls_rc_fail('unknown action. ls-participants.php takes create-list, add, list and count');
    }
});
