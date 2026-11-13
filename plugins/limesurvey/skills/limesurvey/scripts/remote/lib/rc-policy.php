<?php
/**
 * LimeSurvey skill: remote/lib/rc-policy.php (included by ls-rc.php)
 *
 * What rc.sh may do with each of LimeSurvey's RemoteControl methods, and what it may show of a reply. This file
 * needs nothing of LimeSurvey: it is plain functions over arrays, so the skill's tests run it on its own.
 *
 * The list. Every method is one of:
 *   read     runs as it is
 *   write    changes the site, so it runs only when the request says "confirmed": true (rc.sh --yes), which the
 *            assistant gives once the admin has asked for or agreed to exactly that change
 *   refuse   never runs through rc.sh. The reason names the script that does the job, with its checks, or says
 *            that this skill does not do it.
 * A method that is not on the list is refused: a newer LimeSurvey can bring methods nobody here has looked at.
 *
 * The filter. Whatever the method, a reply passes ls_rc_filter() before it is printed:
 *   - a field whose name says it is a secret is taken out: the encryption keys, any password, salt or hash, a
 *     session token, a validation or password-link key, an API key;
 *   - the values of security.php themselves are taken out wherever they appear, under any name;
 *   - a participant's access code (a field named "token") is replaced by "(hidden)", unless the request says
 *     "show_codes": true (rc.sh --show-codes), which is for the one case where the admin asks for someone's link;
 *   - set_participant_properties answers with how many people were changed and the fields that were set, not with
 *     the person's whole row.
 * The site-settings methods answer only for the settings on ls_rc_safe_settings().
 *
 * ls_rc_policy()                     array(method => array(kind, reason))
 * ls_rc_method_policy($method)       array(kind, reason); an unknown method is array('refuse', ...)
 * ls_rc_safe_settings()              the names get_site_settings may be asked for
 * ls_rc_secret_name($name)           whether a field's name says it holds a secret
 * ls_rc_filter($method, $result, $showCodes, array $secretValues, array $params = array())   the reply to print
 */

function ls_rc_policy()
{
    $mail = 'it sends email. invitations.sh shows who would get mail and from which address, and sends only with the admin\'s yes';
    $delete = 'it deletes. delete.sh shows what would go, and what goes with it, and deletes only with the admin\'s yes';
    $answers = 'it returns people\'s answers. responses.sh saves an export as a private file in the Files pane, and its summary counts answers without printing what people typed';
    $noAnswers = 'this skill never writes or changes an answer set. People answer through the survey, and an admin edits an answer in LimeSurvey (the survey\'s Responses page)';
    $session = 'it is not needed here: every call already runs as the site\'s main admin, with no session key';
    return array(
        // Surveys
        'list_surveys' => array('read', ''),
        'list_survey_groups' => array('read', ''),
        'get_survey_properties' => array('read', ''),
        'get_language_properties' => array('read', ''),
        'get_summary' => array('read', ''),
        'get_fieldmap' => array('read', ''),
        'export_timeline' => array('read', ''),
        'add_survey' => array('write', ''),
        'copy_survey' => array('write', ''),
        'set_survey_properties' => array('write', ''),
        'add_language' => array('write', ''),
        'set_language_properties' => array('write', ''),
        'activate_survey' => array('refuse', 'it opens the survey to the people who answer it. survey-activate.sh shows what would go live and activates only with the admin\'s yes'),
        'import_survey' => array('refuse', 'survey-import.sh checks a survey file and imports it as an inactive draft, and survey-archive.sh import brings in an .lss or .lsa file (an .lsa arrives active, after the admin\'s yes)'),
        'delete_survey' => array('refuse', $delete),
        'delete_language' => array('refuse', $delete),
        // Groups and questions
        'list_groups' => array('read', ''),
        'get_group_properties' => array('read', ''),
        'list_questions' => array('read', ''),
        'get_question_properties' => array('read', ''),
        'add_group' => array('write', ''),
        'set_group_properties' => array('write', ''),
        'import_group' => array('write', ''),
        'import_question' => array('write', ''),
        'set_question_properties' => array('write', ''),
        'delete_group' => array('refuse', $delete),
        'delete_question' => array('refuse', $delete),
        // Quotas
        'list_quotas' => array('read', ''),
        'get_quota_properties' => array('read', ''),
        'add_quota' => array('write', ''),
        'set_quota_properties' => array('write', ''),
        'delete_quota' => array('refuse', $delete),
        // Participants
        'list_participants' => array('read', ''),
        'get_participant_properties' => array('read', ''),
        'set_participant_properties' => array('write', ''),
        'activate_tokens' => array('refuse', 'it makes a participant list, which closes an open survey to everyone without an access code. participants.sh create-list does it, and asks first when the survey is active'),
        'add_participants' => array('refuse', 'participants.sh add takes the people on stdin, skips addresses that are not valid or already on the list, and prints no access code'),
        'cpd_importParticipants' => array('refuse', 'it writes to the site-wide participant database. participants.sh add puts people on one survey\'s list; the central database is the admin\'s to manage in LimeSurvey'),
        'delete_participants' => array('refuse', $delete),
        'invite_participants' => array('refuse', $mail),
        'remind_participants' => array('refuse', $mail),
        'mail_registered_participants' => array('refuse', $mail),
        // Answers
        'get_response_ids' => array('read', ''),
        'export_responses' => array('refuse', $answers),
        'export_responses_by_token' => array('refuse', $answers),
        'get_uploaded_files' => array('refuse', 'it returns files that participants uploaded. The admin downloads those in LimeSurvey (the survey\'s Responses page); a full backup holds them too'),
        'export_statistics' => array('refuse', 'it returns a file. responses.sh statistics saves LimeSurvey\'s statistics report as a private file in the Files pane'),
        'add_response' => array('refuse', $noAnswers),
        'update_response' => array('refuse', $noAnswers),
        'upload_file' => array('refuse', $noAnswers),
        'delete_response' => array('refuse', $delete),
        // The site
        'list_users' => array('read', ''),
        'get_site_settings' => array('read', ''),
        'get_available_site_settings' => array('read', ''),
        'get_session_key' => array('refuse', $session),
        'release_session_key' => array('refuse', $session),
    );
}

function ls_rc_method_policy($method)
{
    $policy = ls_rc_policy();
    if (isset($policy[$method])) {
        return $policy[$method];
    }
    return array('refuse', 'it is not on this skill\'s list of RemoteControl methods, so nobody has checked what it changes or returns. rc.sh --methods shows the list');
}

function ls_rc_safe_settings()
{
    return array(
        'sitename', 'siteadminname', 'siteadminemail', 'siteadminbounce', 'defaultlang', 'restrictToLanguages',
        'versionnumber', 'buildnumber', 'dbversionnumber', 'DBVersion', 'updatable',
        'emailmethod', 'emailsmtphost', 'emailsmtpuser', 'emailsmtpssl', 'emailsmtpdebug', 'emailcharset', 'maxemails',
        'sendingrate', 'bounceaccounttype', 'bounceaccounthost', 'bounceencryption',
        'RPCInterface', 'maintenancemode', 'debug', 'debugsql', 'publicurl', 'force_ssl', 'x_frame_options',
        'defaulttheme', 'admintheme', 'displayTimezone', 'iSessionExpirationTime',
        'maxLoginAttempt', 'timeOutTime', 'maxLoginAttemptParticipants', 'timeOutParticipants',
        'reverseProxyIpAddresses', 'reverseProxyIpHeader', 'allowedHosts',
        'surveyPreview_require_Auth', 'filterxsshtml', 'usePluginWhitelist', 'disablePluginUpload',
        'mysqlEngine', 'iFileUploadTotalSpaceMB', 'memory_limit', 'max_execution_time', 'show_survey_list',
    );
}

function ls_rc_secret_name($name)
{
    if (!is_string($name)) {
        return false;
    }
    return (bool) preg_match('/pass(word|wd)?$|password|passwd|(^|_)pwd($|_)|secret|salt|hash|nonce|keypair|secretbox'
        . '|^encryption(public|secret)?key$|session_?token|session_?key|validation_?key|one_time_pw|api_?key|private_?key|credential/i', $name);
}

/** The reply as it may be printed. */
function ls_rc_filter($method, $result, $showCodes, array $secretValues, array $params = array())
{
    $secretValues = array_values(array_filter($secretValues, function ($v) {
        return is_string($v) && strlen($v) >= 16;
    }));
    $clean = function ($value) use (&$clean, $showCodes, $secretValues) {
        if (is_array($value)) {
            $out = array();
            foreach ($value as $key => $item) {
                if (ls_rc_secret_name($key)) {
                    continue;
                }
                if ($key === 'token' && !$showCodes && (is_string($item) || is_int($item)) && $item !== '') {
                    $out[$key] = '(hidden)';
                    continue;
                }
                $out[$key] = $clean($item);
            }
            return $out;
        }
        if (is_string($value)) {
            foreach ($secretValues as $secret) {
                if (strpos($value, $secret) !== false) {
                    return '(hidden)';
                }
            }
        }
        return $value;
    };

    // A refusal of LimeSurvey's own passes as it is: it holds a status and an error code.
    $refused = is_array($result) && (isset($result['error_code']) || (isset($result['status']) && count($result) === 1));

    if ($method === 'get_available_site_settings' && is_array($result) && !$refused) {
        $names = array_keys($result) === range(0, count($result) - 1) ? $result : array_keys($result);
        return array_values(array_intersect(ls_rc_safe_settings(), $names));
    }
    if ($method === 'set_participant_properties' && is_array($result) && !$refused) {
        // LimeSurvey answers with the person's whole row. What matters is that one person was changed, and how.
        $shown = array('emailstatus', 'language', 'sent', 'remindersent', 'remindercount', 'completed', 'usesleft', 'validfrom', 'validuntil', 'blacklisted');
        $sent = isset($params['aTokenData']) && is_array($params['aTokenData']) ? $params['aTokenData'] : (isset($params[2]) && is_array($params[2]) ? $params[2] : array());
        $fields = array();
        foreach ($sent as $key => $unused) {
            if (!is_string($key) || $key === 'tid' || !array_key_exists($key, $result)) {
                continue;
            }
            $fields[$key] = in_array($key, $shown, true) ? $result[$key] : '(set)';
        }
        return $clean(array('changed' => 1, 'tid' => isset($result['tid']) ? (int) $result['tid'] : null, 'fields' => $fields));
    }
    return $clean($result);
}
