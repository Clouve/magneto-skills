<?php
/**
 * LimeSurvey skill: remote/ls-change.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. survey-activate.sh and
 * delete.sh are its front ends on the agent. It does the two kinds of change that rc.sh refuses: activating a
 * survey, and deleting something. Each request is first answered with what would happen. The change itself runs
 * only on a request that says "confirmed": true, which the front ends set for their yes option and nothing else,
 * and it goes through LimeSurvey's own RemoteControl method.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   activate   sid. Result: the survey's title, counts, whether it is open to anyone or closed to a participant
 *              list, its sender, its links, and "blockers": the reasons it cannot be activated as it is. With
 *              "confirmed": true it activates the survey (LimeSurvey's activate_survey) and reports the state it
 *              reads back.
 *   delete     kind (survey, group, question, language, participant, response or quota) and its ids:
 *                survey       sid
 *                group        sid, gid
 *                question     qid
 *                language     sid, language
 *                participant  sid, ids (a list of participant ids)
 *                response     sid, id
 *                quota        id
 *              Result: "what" (one sentence that names the thing), "goes_with" (what is deleted along with it),
 *              and "blockers". With "confirmed": true it deletes (LimeSurvey's delete_ method) and says so.
 *              No name, address, access code or answer is in any reply.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';
$confirmed = isset($request['confirmed']) && $request['confirmed'] === true;

/** A whole number from the request, or a JSON error that names it. */
function ls_id(array $request, $key, $what)
{
    $value = ls_need($request, $key);
    if (!is_int($value) && !(is_string($value) && ctype_digit($value))) {
        ls_rc_fail("$what has to be a number");
    }
    return (int) $value;
}

/** A survey's title in its base language. */
function ls_title(Survey $survey)
{
    $title = Yii::app()->db->createCommand('SELECT surveyls_title FROM {{surveys_languagesettings}} WHERE surveyls_survey_id = :sid AND surveyls_language = :lang')
        ->queryScalar(array(':sid' => (int) $survey->sid, ':lang' => $survey->language));
    return $title === false ? '(no title)' : (string) $title;
}

/** How many rows a table has, or null when it is not there. */
function ls_rows($table)
{
    if (!tableExists($table)) {
        return null;
    }
    return (int) Yii::app()->db->createCommand("SELECT COUNT(*) FROM $table")->queryScalar();
}

/** A text cut to a length that fits one line, without markup. */
function ls_short($text)
{
    $text = trim(preg_replace('/\s+/', ' ', html_entity_decode(strip_tags((string) $text), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
    return mb_strlen($text) > 80 ? mb_substr($text, 0, 77) . '...' : $text;
}

/** A JSON error when one of LimeSurvey's methods refused. */
function ls_done($reply, $what)
{
    if (is_array($reply) && (isset($reply['error_code']) || (isset($reply['status']) && is_string($reply['status']) && stripos($reply['status'], 'error') === 0))) {
        ls_rc_fail("LimeSurvey refused to $what: " . (isset($reply['status']) && is_string($reply['status']) ? $reply['status'] : json_encode($reply)));
    }
    if ($reply === null || $reply === false) {
        ls_rc_fail("LimeSurvey did not $what");
    }
    return $reply;
}

ls_rc_run(function (array $ctx) use ($request, $action, $confirmed) {
    $handle = $ctx['handle'];
    $db = Yii::app()->db;

    switch ($action) {
        case 'activate':
            $sid = ls_sid($request);
            $survey = ls_survey($sid);
            $counts = ls_survey_counts($sid);
            $participants = ls_rows('{{tokens_' . $sid . '}}');
            $blockers = array();
            if ($survey->active === 'Y') {
                $blockers[] = 'the survey is active already';
            }
            if ($counts['groups'] === 0 || $counts['questions'] === 0) {
                $blockers[] = 'the survey has no questions yet';
            }
            if (!empty($survey->expires) && strtotime($survey->expires . ' UTC') !== false && strtotime($survey->expires . ' UTC') < time()) {
                $blockers[] = 'the survey\'s end date (' . $survey->expires . ' UTC) is past, so nobody could answer it. Change or clear the end date first';
            }
            $report = array(
                'sid' => $sid,
                'title' => ls_title($survey),
                'active' => $survey->active,
                'counts' => $counts,
                'closed' => $participants !== null,
                'participants' => $participants,
                'anonymized' => $survey->anonymized,
                'starts' => $survey->startdate,
                'expires' => $survey->expires,
                'sender_name' => $survey->admin,
                'sender_email' => $survey->adminemail,
                'blockers' => $blockers,
            ) + ls_survey_links($ctx, $sid, $survey->language);
            if (!$confirmed) {
                ls_rc_reply(array('activated' => false) + $report);
            }
            if ($blockers) {
                ls_rc_reply(array('activated' => false, 'refused' => true) + $report);
            }
            ls_done($handle->activate_survey('ls-rc-cli', $sid), 'activate the survey');
            $after = Survey::model()->findByPk($sid);
            if (!$after || $after->active !== 'Y') {
                ls_rc_fail("LimeSurvey answered, and survey $sid still reads as inactive. survey-info.sh $sid shows its state");
            }
            ls_rc_reply(array('activated' => true, 'active' => 'Y') + $report);
            break;

        case 'delete':
            $kind = isset($request['kind']) ? $request['kind'] : '';
            $what = '';
            $goes = array();
            $blockers = array();
            $run = null;
            switch ($kind) {
                case 'survey':
                    $sid = ls_sid($request);
                    $survey = ls_survey($sid);
                    $counts = ls_survey_counts($sid);
                    $answers = $survey->active === 'Y' ? ls_rows('{{responses_' . $sid . '}}') : null;
                    $people = ls_rows('{{tokens_' . $sid . '}}');
                    $what = "survey $sid, \"" . ls_short(ls_title($survey)) . '" (' . ($survey->active === 'Y' ? 'ACTIVE: people can answer it now' : 'inactive') . ')';
                    $goes[] = $counts['groups'] . ' groups and ' . $counts['questions'] . ' questions';
                    $goes[] = $answers === null ? 'no answers (the survey is not active)' : "$answers answer sets";
                    $goes[] = $people === null ? 'no participant list' : "its participant list with $people people";
                    $goes[] = 'the files participants uploaded to it, its quotas and everyone\'s permissions on it';
                    $run = function () use ($handle, $sid) {
                        ls_done($handle->delete_survey('ls-rc-cli', $sid), 'delete the survey');
                        if (Survey::model()->findByPk($sid)) {
                            ls_rc_fail("LimeSurvey answered, and survey $sid is still there");
                        }
                    };
                    break;

                case 'group':
                    $sid = ls_sid($request);
                    $survey = ls_survey($sid);
                    $gid = ls_id($request, 'gid', 'the group id');
                    $group = QuestionGroup::model()->findByAttributes(array('gid' => $gid, 'sid' => $sid));
                    if (!$group) {
                        ls_rc_fail("survey $sid has no group $gid. rc.sh list_groups shows the groups");
                    }
                    $name = $db->createCommand('SELECT group_name FROM {{group_l10ns}} WHERE gid = :gid AND language = :lang')->queryScalar(array(':gid' => $gid, ':lang' => $survey->language));
                    $questions = (int) $db->createCommand('SELECT COUNT(*) FROM {{questions}} WHERE gid = :gid AND parent_qid = 0')->queryScalar(array(':gid' => $gid));
                    $what = "group $gid, \"" . ls_short($name) . "\", of survey $sid";
                    $goes[] = "its $questions questions, with their subquestions and answer options";
                    if ($survey->active === 'Y') {
                        $blockers[] = "survey $sid is active, and LimeSurvey does not take a group out of an active survey";
                    }
                    $run = function () use ($handle, $sid, $gid) {
                        ls_done($handle->delete_group('ls-rc-cli', $sid, $gid), 'delete the group');
                    };
                    break;

                case 'question':
                    $qid = ls_id($request, 'qid', 'the question id');
                    $question = Question::model()->findByPk($qid);
                    if (!$question) {
                        ls_rc_fail("there is no question $qid. rc.sh list_questions shows a survey's questions");
                    }
                    $sid = (int) $question->sid;
                    $survey = ls_survey($sid);
                    $text = $db->createCommand('SELECT question FROM {{question_l10ns}} WHERE qid = :qid AND language = :lang')->queryScalar(array(':qid' => $qid, ':lang' => $survey->language));
                    $subs = (int) $db->createCommand('SELECT COUNT(*) FROM {{questions}} WHERE parent_qid = :qid')->queryScalar(array(':qid' => $qid));
                    $options = (int) $db->createCommand('SELECT COUNT(*) FROM {{answers}} WHERE qid = :qid')->queryScalar(array(':qid' => $qid));
                    $what = ((int) $question->parent_qid === 0 ? 'question' : 'subquestion') . " $qid (" . $question->title . '), "' . ls_short($text) . "\", of survey $sid";
                    $goes[] = "its $subs subquestions and $options answer options";
                    if ($survey->active === 'Y') {
                        $blockers[] = "survey $sid is active, and LimeSurvey does not take a question out of an active survey";
                    }
                    $run = function () use ($handle, $qid) {
                        ls_done($handle->delete_question('ls-rc-cli', $qid), 'delete the question');
                    };
                    break;

                case 'language':
                    $sid = ls_sid($request);
                    $survey = ls_survey($sid);
                    $language = (string) ls_need($request, 'language');
                    if (!preg_match('/^[A-Za-z]{2,3}(-[A-Za-z0-9]+)*$/', $language)) {
                        ls_rc_fail('a language is a code such as de or pt-BR');
                    }
                    $what = "the language $language of survey $sid";
                    $goes[] = 'every text of the survey in that language: titles, questions, answer options, email templates';
                    if ($language === $survey->language) {
                        $blockers[] = "$language is the survey's base language, which cannot be removed";
                    } elseif (!in_array($language, $survey->getAdditionalLanguages(), true)) {
                        $blockers[] = "survey $sid has no language $language";
                    }
                    $run = function () use ($handle, $sid, $language) {
                        ls_done($handle->delete_language('ls-rc-cli', $sid, $language), 'delete the language');
                    };
                    break;

                case 'participant':
                    $sid = ls_sid($request);
                    ls_survey($sid);
                    $table = '{{tokens_' . $sid . '}}';
                    if (!tableExists($table)) {
                        ls_rc_fail("survey $sid has no participant list");
                    }
                    $ids = isset($request['ids']) && is_array($request['ids']) ? $request['ids'] : array();
                    $clean = array();
                    foreach ($ids as $id) {
                        if (!is_int($id) && !(is_string($id) && ctype_digit($id))) {
                            ls_rc_fail('the participant ids have to be numbers (participants.sh list shows them)');
                        }
                        $clean[(int) $id] = true;
                    }
                    $ids = array_keys($clean);
                    if (!$ids) {
                        ls_rc_fail('give at least one participant id');
                    }
                    if (count($ids) > 500) {
                        ls_rc_fail('that is over 500 people in one call. Split the list');
                    }
                    $list = implode(',', $ids);
                    $found = array_map('intval', $db->createCommand("SELECT tid FROM $table WHERE tid IN ($list)")->queryColumn());
                    $done = (int) $db->createCommand("SELECT COUNT(*) FROM $table WHERE tid IN ($list) AND completed NOT IN ('N', '')")->queryScalar();
                    $missing = array_values(array_diff($ids, $found));
                    $what = count($found) . ' of the ' . ((int) $db->createCommand("SELECT COUNT(*) FROM $table")->queryScalar()) . " people on the participant list of survey $sid (ids " . implode(', ', $found) . ')';
                    $goes[] = 'their access codes: the links in their invitations stop working';
                    $goes[] = $done > 0 ? "$done of them have completed the survey. Their answers stay, and can no longer be tied to them" : 'none of them has completed the survey';
                    if ($missing) {
                        $blockers[] = 'the list has no participant with the id ' . implode(', ', $missing);
                    }
                    $run = function () use ($handle, $sid, $found) {
                        $reply = ls_done($handle->delete_participants('ls-rc-cli', $sid, $found), 'delete the participants');
                        foreach ((array) $reply as $tid => $status) {
                            if ($status !== 'Deleted') {
                                ls_rc_fail("participant $tid was not deleted: $status");
                            }
                        }
                    };
                    break;

                case 'response':
                    $sid = ls_sid($request);
                    $survey = ls_survey($sid);
                    $id = ls_id($request, 'id', 'the answer set\'s id');
                    $table = '{{responses_' . $sid . '}}';
                    if ($survey->active !== 'Y' || !tableExists($table)) {
                        ls_rc_fail("survey $sid is not active, so it has no answers to delete");
                    }
                    $row = $db->createCommand("SELECT id, submitdate FROM $table WHERE id = :id")->queryRow(true, array(':id' => $id));
                    if (!$row) {
                        ls_rc_fail("survey $sid has no answer set with the id $id");
                    }
                    $what = "answer set $id of survey $sid (" . (empty($row['submitdate']) ? 'started, not completed' : 'completed') . ')';
                    $goes[] = 'every answer in it, and the files that were uploaded with it';
                    $run = function () use ($handle, $sid, $id) {
                        ls_done($handle->delete_response('ls-rc-cli', $sid, $id), 'delete the answer set');
                    };
                    break;

                case 'quota':
                    $id = ls_id($request, 'id', 'the quota id');
                    $quota = Quota::model()->findByPk($id);
                    if (!$quota) {
                        ls_rc_fail("there is no quota $id. rc.sh list_quotas shows a survey's quotas");
                    }
                    $what = "quota $id, \"" . ls_short($quota->name) . '", of survey ' . (int) $quota->sid;
                    $goes[] = 'its limit and its members. No answer is deleted';
                    $run = function () use ($handle, $id) {
                        ls_done($handle->delete_quota('ls-rc-cli', $id), 'delete the quota');
                    };
                    break;

                default:
                    ls_rc_fail('delete takes a kind: survey, group, question, language, participant, response or quota');
            }
            $report = array('kind' => $kind, 'what' => $what, 'goes_with' => $goes, 'blockers' => $blockers);
            if (!$confirmed) {
                ls_rc_reply(array('deleted' => false) + $report);
            }
            if ($blockers) {
                ls_rc_reply(array('deleted' => false, 'refused' => true) + $report);
            }
            $run();
            ls_rc_reply(array('deleted' => true) + $report);
            break;

        default:
            ls_rc_fail('unknown action. ls-change.php takes activate and delete');
    }
});
