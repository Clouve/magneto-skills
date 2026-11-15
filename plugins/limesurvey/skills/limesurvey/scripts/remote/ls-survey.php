<?php
/**
 * LimeSurvey skill: remote/ls-survey.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. survey-import.sh and
 * survey-archive.sh are its front ends on the agent. lib/boot.php says how LimeSurvey is started.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   check           data_base64 (a tab-separated survey file). Checks the file and changes nothing. LimeSurvey is
 *                   not started. Result: errors, warnings, summary (lib/tsv-check.php).
 *   import          data_base64, format (txt or lss). Checks a txt file first and stops on an error. Then LimeSurvey
 *                   imports its own copy of the file (its importer deletes the file it reads). Result: imported,
 *                   sid, title, active, the counts it finds in the database next to the counts of the file, the
 *                   links, and what does not match.
 *   info            sid. Title, state, counts and links of one survey. No answer and no participant is read, only
 *                   how many there are.
 *   archive-export  sid, format (lss or lsa). Writes the file's bytes to stdout and nothing else. An .lss is the
 *                   questions and settings. An .lsa also holds the answers and the participants.
 *   archive-import  data_base64, format (lss or lsa), and for lsa "confirmed": true, because LimeSurvey activates
 *                   a survey it imports from an .lsa archive and loads its answers and participants.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';
require __DIR__ . '/lib/tsv-check.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

if ($action === 'check') {
    ls_rc_reply(ls_tsv_check(ls_data_bytes($request)));
}

/** What a survey looks like after an import, for the reply. */
function ls_survey_report(array $ctx, $sid)
{
    $survey = ls_survey($sid);
    $db = Yii::app()->db;
    $title = $db->createCommand('SELECT surveyls_title FROM {{surveys_languagesettings}} WHERE surveyls_survey_id = :sid AND surveyls_language = :lang')
        ->queryScalar(array(':sid' => (int) $sid, ':lang' => $survey->language));
    $report = array(
        'sid' => (int) $sid,
        'title' => $title === false ? null : $title,
        'active' => $survey->active,
        'language' => $survey->language,
        'additional_languages' => trim((string) $survey->additional_languages),
        'counts' => ls_survey_counts($sid),
        'sender_name' => $survey->admin,
        'sender_email' => $survey->adminemail,
        'has_participant_list' => (bool) tableExists('{{tokens_' . (int) $sid . '}}'),
        'participants' => null,
        'responses' => null,
    );
    if ($report['has_participant_list']) {
        $report['participants'] = (int) $db->createCommand('SELECT COUNT(*) FROM {{tokens_' . (int) $sid . '}}')->queryScalar();
    }
    if ($survey->active === 'Y' && tableExists('{{responses_' . (int) $sid . '}}')) {
        $report['responses'] = (int) $db->createCommand('SELECT COUNT(*) FROM {{responses_' . (int) $sid . '}}')->queryScalar();
    }
    return $report + ls_survey_links($ctx, $sid, $survey->language);
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $handle = $ctx['handle'];
    switch ($action) {
        case 'import':
            $format = strtolower((string) ls_need($request, 'format'));
            if (!in_array($format, array('txt', 'lss'), true)) {
                ls_rc_fail('import takes a txt (tab-separated) or lss file. An .lsa archive goes through archive-import, because it activates the survey');
            }
            $bytes = ls_data_bytes($request);
            $check = null;
            if ($format === 'txt') {
                $check = ls_tsv_check($bytes);
                if ($check['errors']) {
                    ls_rc_reply(array('imported' => false) + $check);
                }
            }
            // LimeSurvey writes the data to a file of its own in tmp/, imports that, and deletes it.
            $new = $handle->import_survey('ls-rc-cli', base64_encode($bytes), $format);
            if (!is_int($new) || $new <= 0) {
                ls_rc_reply(array('imported' => false, 'errors' => array('LimeSurvey did not import the file: ' . (is_array($new) && isset($new['status']) ? $new['status'] : json_encode($new))),
                    'warnings' => $check ? $check['warnings'] : array(), 'summary' => $check ? $check['summary'] : null));
            }
            $report = ls_survey_report($ctx, $new);
            $mismatches = array();
            if ($check) {
                // The file's counts are those of its base language. The database keeps one row per group,
                // question and answer option, with the texts of each language beside it.
                foreach (array('groups', 'questions', 'subquestions', 'answers') as $what) {
                    $want = $check['summary'][$what];
                    $have = $report['counts'][$what];
                    if ($have !== $want) {
                        $mismatches[] = "the file has $want $what and the survey has $have";
                    }
                }
                if ((int) $check['summary']['sid'] !== (int) $new) {
                    $report['sid_note'] = 'the id ' . $check['summary']['sid'] . ' of the file was taken, so LimeSurvey gave the survey the id ' . $new;
                }
            }
            if ($report['active'] !== 'N') {
                $mismatches[] = 'the survey is active after the import, which should not happen for this kind of file';
            }
            ls_rc_reply(array('imported' => true, 'mismatches' => $mismatches, 'warnings' => $check ? $check['warnings'] : array()) + $report);
            break;

        case 'info':
            ls_rc_reply(ls_survey_report($ctx, ls_sid($request)));
            break;

        case 'archive-export':
            $sid = ls_sid($request);
            $survey = ls_survey($sid);
            $format = strtolower((string) ls_need($request, 'format'));
            Yii::app()->loadHelper('export');
            $tmp = Yii::app()->getConfig('tempdir');
            if ($format === 'lss') {
                $file = $tmp . DIRECTORY_SEPARATOR . randomChars(30);
                if (file_put_contents($file, surveyGetXMLData($sid)) === false) {
                    ls_rc_fail('could not write the export in tmp/');
                }
                ls_rc_raw_file($file);
            }
            if ($format !== 'lsa') {
                ls_rc_fail('the format is lss (questions and settings) or lsa (with the answers and participants)');
            }
            // The steps of LimeSurvey's own "Survey archive" export (admin/Export.php, exportarchive).
            $zipName = $tmp . DIRECTORY_SEPARATOR . randomChars(30);
            $part = $tmp . DIRECTORY_SEPARATOR . randomChars(30);
            // Both files are in LimeSurvey's tmp/ and can hold answers, so whatever goes wrong, neither stays.
            $whole = false;
            try {
                $zip = new ZipArchive();
                if ($zip->open($zipName, ZipArchive::CREATE) !== true) {
                    throw new RuntimeException('could not start the archive in tmp/');
                }
                $zip->addFromString('survey_' . $sid . '.lss', surveyGetXMLData($sid));
                if ($survey->isActive) {
                    getXMLDataSingleTable($sid, 'responses_' . $sid, 'Responses', 'responses', $part, false);
                    $zip->addFromString('survey_' . $sid . '_responses.lsr', file_get_contents($part));
                    @unlink($part);
                }
                if ($survey->hasTokensTable) {
                    getXMLDataSingleTable($sid, 'tokens_' . $sid, 'Tokens', 'tokens', $part);
                    $zip->addFromString('survey_' . $sid . '_tokens.lst', file_get_contents($part));
                    @unlink($part);
                }
                if (isset($survey->hasTimingsTable) && $survey->hasTimingsTable == 'Y') {
                    getXMLDataSingleTable($sid, 'timings_' . $sid, 'Timings', 'timings', $part);
                    $zip->addFromString('survey_' . $sid . '_timings.lsi', file_get_contents($part));
                    @unlink($part);
                }
                if (!$zip->close()) {
                    throw new RuntimeException('could not write the archive in tmp/');
                }
                $whole = true;
            } finally {
                @unlink($part);
                if (!$whole) {
                    // An archive that was never closed is written when PHP ends, so it is emptied and closed
                    // here, and then removed.
                    if (isset($zip) && $zip instanceof ZipArchive) {
                        try {
                            @$zip->unchangeAll();
                            @$zip->close();
                        } catch (Throwable $e) {
                            // nothing was written
                        }
                    }
                    @unlink($zipName);
                }
            }
            ls_rc_raw_file($zipName);
            break;

        case 'archive-import':
            $format = strtolower((string) ls_need($request, 'format'));
            if (!in_array($format, array('lss', 'lsa'), true)) {
                ls_rc_fail('archive-import takes an lss or lsa file');
            }
            if ($format === 'lsa' && empty($request['confirmed'])) {
                ls_rc_fail('an .lsa archive brings a survey with its answers and participants, and LimeSurvey activates that survey as it imports it. That needs the admin\'s yes first');
            }
            $new = $handle->import_survey('ls-rc-cli', base64_encode(ls_data_bytes($request)), $format);
            if (!is_int($new) || $new <= 0) {
                ls_rc_fail('LimeSurvey did not import the file: ' . (is_array($new) && isset($new['status']) ? $new['status'] : json_encode($new)));
            }
            ls_rc_reply(array('imported' => true) + ls_survey_report($ctx, $new));
            break;

        default:
            ls_rc_fail('unknown action. ls-survey.php takes check, import, info, archive-export and archive-import');
    }
});
