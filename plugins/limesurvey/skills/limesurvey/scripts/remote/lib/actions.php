<?php
/**
 * LimeSurvey skill: remote/lib/actions.php (included by the ls-*.php scripts in remote/ after lib/boot.php)
 *
 * Small helpers the action scripts share.
 *   ls_need($request, $key)        the value of $key, or a JSON error that names it
 *   ls_sid($request)               the request's survey id as an int; a JSON error when it is not a number
 *   ls_survey($sid)                the Survey model; a JSON error when there is no such survey
 *   ls_survey_counts($sid)         groups, questions, subquestions and answer options of a survey
 *   ls_survey_links($ctx, $sid, $language)   the admin page, the preview and the public address of a survey
 *   ls_data_bytes($request)        the bytes of the request's data_base64
 */

function ls_need(array $request, $key)
{
    if (!array_key_exists($key, $request) || $request[$key] === '' || $request[$key] === null) {
        ls_rc_fail("the request lacks \"$key\"");
    }
    return $request[$key];
}

function ls_sid(array $request)
{
    $sid = ls_need($request, 'sid');
    if (!is_int($sid) && !(is_string($sid) && ctype_digit($sid))) {
        ls_rc_fail('the survey id has to be a number');
    }
    return (int) $sid;
}

function ls_survey($sid)
{
    $survey = Survey::model()->findByPk((int) $sid);
    if (!$survey) {
        ls_rc_fail("there is no survey $sid on this site. rc.sh list_surveys shows the surveys");
    }
    return $survey;
}

function ls_survey_counts($sid)
{
    $db = Yii::app()->db;
    $one = function ($sql) use ($db, $sid) {
        return (int) $db->createCommand($sql)->queryScalar(array(':sid' => (int) $sid));
    };
    return array(
        'groups' => $one('SELECT COUNT(*) FROM {{groups}} WHERE sid = :sid'),
        'questions' => $one('SELECT COUNT(*) FROM {{questions}} WHERE sid = :sid AND parent_qid = 0'),
        'subquestions' => $one('SELECT COUNT(*) FROM {{questions}} WHERE sid = :sid AND parent_qid > 0'),
        'answers' => $one('SELECT COUNT(*) FROM {{answers}} a JOIN {{questions}} q ON q.qid = a.qid WHERE q.sid = :sid'),
    );
}

function ls_survey_links(array $ctx, $sid, $language)
{
    $app = $ctx['app'];
    return array(
        // Where the admin reviews and edits the survey, after signing in.
        'admin_url' => $app->createAbsoluteUrl('surveyAdministration/view', array('surveyid' => (int) $sid)),
        // What a signed-in admin sees as a participant, also while the survey is inactive.
        'preview_url' => $app->createPublicUrl('survey/index', array('sid' => (int) $sid, 'newtest' => 'Y', 'lang' => $language)),
        // What participants open once the survey is active.
        'public_url' => $app->createPublicUrl('survey/index', array('sid' => (int) $sid, 'lang' => $language)),
    );
}

function ls_data_bytes(array $request)
{
    $data = base64_decode((string) ls_need($request, 'data_base64'), true);
    if ($data === false || $data === '') {
        ls_rc_fail('the file did not arrive (data_base64 is empty or is not base64)');
    }
    return $data;
}
