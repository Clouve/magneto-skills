<?php
/**
 * LimeSurvey skill: remote/ls-results.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. responses.sh is its front end
 * on the agent. It reads the answers of one survey, the one the request names, through LimeSurvey's own export, so
 * encrypted answers come out readable and the columns are LimeSurvey's.
 *
 * Request (stdin): one JSON object with "action", "sid" and what the action needs.
 *   export    format (csv or xlsx), completion (complete, incomplete or all), headings (code, full or abbreviated),
 *             answers (short for answer codes, long for answer texts). Writes the file's bytes to stdout and
 *             nothing else, for the agent to save in the Files pane. On a failure the reply is the usual JSON.
 *   summary   completion, and with_text (true includes what people typed into free-text questions). Result: how
 *             many answer sets there are and, for each question, how many people answered and how the answers
 *             split. Free-text answers are counted, and shown only with with_text. Numbers get their lowest,
 *             highest and average. No participant details, no access codes and no IP addresses are in it.
 *             A column whose question type this does not know, and an equation, count as text: their values are
 *             shown only with with_text.
 *   statistics  format (pdf, xls or html). Writes LimeSurvey's own statistics report as a file's bytes to stdout
 *             and nothing else, for the agent to save in the Files pane. It holds counts and shares per question.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** The request's completion filter. */
function ls_completion(array $request)
{
    $completion = isset($request['completion']) ? $request['completion'] : 'complete';
    if (!in_array($completion, array('complete', 'incomplete', 'all'), true)) {
        ls_rc_fail('completion is complete, incomplete or all');
    }
    return $completion;
}

/** Runs LimeSurvey's export and returns the path of the file it wrote in tmp/. A JSON error when there is nothing. */
function ls_export_file($handle, $sid, $type, $language, $completion, $headings, $answers)
{
    $reply = $handle->export_responses('ls-rc-cli', $sid, $type, $language, $completion, $headings, $answers);
    if ($reply instanceof BigFile) {
        return $reply->fileName;
    }
    if (is_array($reply) && isset($reply['status'])) {
        $why = $reply['status'];
        if (isset($reply['error_code']) && in_array($reply['error_code'], array('ERR_NO_RESPONSE_TABLE', 'ERR_NO_DATA'), true)) {
            $why = 'the survey has no answers yet';
        }
        ls_rc_fail("nothing to export for survey $sid: $why");
    }
    ls_rc_fail('LimeSurvey gave no export file');
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $handle = $ctx['handle'];
    $sid = ls_sid($request);
    $survey = ls_survey($sid);
    $completion = ls_completion($request);

    switch ($action) {
        case 'statistics':
            $format = isset($request['format']) ? strtolower((string) $request['format']) : 'pdf';
            if (!in_array($format, array('pdf', 'xls', 'html'), true)) {
                ls_rc_fail('format is pdf, xls or html');
            }
            $reply = $handle->export_statistics('ls-rc-cli', $sid, $format, $survey->language, '0');
            if (is_array($reply)) {
                $why = isset($reply['status']) ? $reply['status'] : json_encode($reply);
                if (isset($reply['error_code']) && in_array($reply['error_code'], array('ERR_NO_RESPONSE_TABLE', 'ERR_NO_DATA'), true)) {
                    $why = 'the survey has no answers yet';
                }
                ls_rc_fail("no statistics for survey $sid: $why");
            }
            $bytes = is_string($reply) ? base64_decode($reply, true) : false;
            if ($bytes === false || $bytes === '') {
                ls_rc_fail('LimeSurvey gave no statistics report');
            }
            global $lsRcReplied, $lsRcStdout;
            ls_rc_drop_output();
            $lsRcReplied = true;
            fwrite($lsRcStdout, $bytes);
            fflush($lsRcStdout);
            exit(0);

        case 'export':
            $format = isset($request['format']) ? strtolower((string) $request['format']) : 'csv';
            if (!in_array($format, array('csv', 'xlsx'), true)) {
                ls_rc_fail('format is csv or xlsx');
            }
            $headings = isset($request['headings']) ? $request['headings'] : 'code';
            if (!in_array($headings, array('code', 'full', 'abbreviated'), true)) {
                ls_rc_fail('headings is code, full or abbreviated');
            }
            $answers = isset($request['answers']) ? $request['answers'] : 'long';
            if (!in_array($answers, array('short', 'long'), true)) {
                ls_rc_fail('answers is short or long');
            }
            // LimeSurvey calls its Excel export "xls" and writes an .xlsx file.
            ls_rc_raw_file(ls_export_file($handle, $sid, $format === 'xlsx' ? 'xls' : 'csv', $survey->language, $completion, $headings, $answers));
            break;

        case 'summary':
            $withText = !empty($request['with_text']);
            $file = ls_export_file($handle, $sid, 'json', $survey->language, $completion, 'code', 'long');
            $data = json_decode((string) file_get_contents($file), true);
            @unlink($file);
            if (!is_array($data) || !isset($data['responses']) || !is_array($data['responses'])) {
                ls_rc_fail('LimeSurvey\'s export could not be read');
            }
            $rows = $data['responses'];

            // The questions, by code, with their type and text. Subquestions hang off their parent.
            $questions = array();
            $byId = array();
            $list = $handle->list_questions('ls-rc-cli', $sid, null, $survey->language);
            if (is_array($list) && !isset($list['error_code'])) {
                foreach ($list as $q) {
                    $byId[(int) $q['qid']] = $q;
                }
                foreach ($list as $q) {
                    $text = trim(html_entity_decode(strip_tags((string) $q['question']), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
                    if ((int) $q['parent_qid'] === 0) {
                        $questions[$q['title']] = array('type' => $q['type'], 'text' => $text, 'subs' => array(), 'order' => array((int) $q['group_order'], (int) $q['question_order']));
                    }
                }
                foreach ($list as $q) {
                    if ((int) $q['parent_qid'] !== 0 && isset($byId[(int) $q['parent_qid']])) {
                        $parent = $byId[(int) $q['parent_qid']]['title'];
                        if (isset($questions[$parent])) {
                            $questions[$parent]['subs'][$q['title']] = trim(html_entity_decode(strip_tags((string) $q['question']), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
                        }
                    }
                }
            }
            $meta = array('id', 'submitdate', 'lastpage', 'startlanguage', 'seed', 'token', 'startdate', 'datestamp',
                'ipaddr', 'refurl', 'quota_exit');
            $freeText = array('S', 'T', 'U', 'Q', ';', '|');
            $numeric = array('N', 'K', ':');
            $columns = array();
            foreach ($rows as $row) {
                if (!is_array($row)) {
                    continue;
                }
                foreach ($row as $column => $value) {
                    if (in_array($column, $meta, true) || preg_match('/Time$/', $column) && !isset($questions[$column])) {
                        continue;
                    }
                    if (!isset($columns[$column])) {
                        $code = preg_replace('/\[.*$/', '', $column);
                        $sub = preg_match('/\[([^\]]*)\]/', $column, $m) ? $m[1] : null;
                        $q = isset($questions[$code]) ? $questions[$code] : null;
                        $label = $q ? $q['text'] : '';
                        if ($q && $sub !== null) {
                            $subText = isset($q['subs'][$sub]) ? $q['subs'][$sub] : ($sub === 'other' ? 'Other' : ($sub === 'comment' ? 'Comment' : $sub));
                            $label = trim($label . ' [' . $subText . ']');
                        }
                        $type = $q ? $q['type'] : '?';
                        $kind = 'choice';
                        // A column this cannot place (no such question, or the questions could not be listed) and
                        // an equation can hold anything a person typed, so they count as text.
                        if ($type === '?' || $type === '*' || in_array($type, $freeText, true) || $sub === 'other' || $sub === 'comment' || ($type === 'P' && substr((string) $sub, -7) === 'comment')) {
                            $kind = 'text';
                        } elseif (in_array($type, $numeric, true)) {
                            $kind = 'number';
                        } elseif ($type === 'D') {
                            $kind = 'date';
                        }
                        $columns[$column] = array('code' => $column, 'type' => $type, 'question' => $label, 'kind' => $kind,
                            'answered' => 0, 'values' => array(), 'numbers' => array(), 'texts' => array());
                    }
                    if ($value === null || $value === '') {
                        continue;
                    }
                    $columns[$column]['answered']++;
                    $value = is_scalar($value) ? (string) $value : json_encode($value);
                    switch ($columns[$column]['kind']) {
                        case 'number':
                            if (is_numeric($value)) {
                                $columns[$column]['numbers'][] = (float) $value;
                            }
                            break;
                        case 'text':
                        case 'date':
                            if ($withText && count($columns[$column]['texts']) < 200) {
                                $columns[$column]['texts'][] = mb_substr($value, 0, 500);
                            }
                            break;
                        default:
                            if (!isset($columns[$column]['values'][$value])) {
                                // A choice question with very many different values is free text in disguise.
                                if (count($columns[$column]['values']) >= 40) {
                                    $columns[$column]['kind'] = 'text';
                                    $columns[$column]['values'] = array();
                                    break;
                                }
                                $columns[$column]['values'][$value] = 0;
                            }
                            $columns[$column]['values'][$value]++;
                    }
                }
            }
            $out = array();
            foreach ($columns as $column) {
                $entry = array('code' => $column['code'], 'type' => $column['type'], 'question' => $column['question'], 'answered' => $column['answered']);
                if ($column['kind'] === 'choice') {
                    arsort($column['values']);
                    $entry['counts'] = $column['values'];
                } elseif ($column['kind'] === 'number') {
                    if ($column['numbers']) {
                        $entry['lowest'] = min($column['numbers']);
                        $entry['highest'] = max($column['numbers']);
                        $entry['average'] = round(array_sum($column['numbers']) / count($column['numbers']), 2);
                    }
                } elseif ($withText) {
                    $entry['texts'] = $column['texts'];
                } else {
                    $entry['note'] = 'what people typed is not shown';
                }
                $out[] = $entry;
            }
            $summary = $handle->get_summary('ls-rc-cli', $sid, 'all');
            $title = Yii::app()->db->createCommand('SELECT surveyls_title FROM {{surveys_languagesettings}} WHERE surveyls_survey_id = :sid AND surveyls_language = :lang')
                ->queryScalar(array(':sid' => $sid, ':lang' => $survey->language));
            ls_rc_reply(array(
                'sid' => $sid,
                'title' => $title === false ? null : $title,
                'active' => $survey->active,
                'counted' => $completion,
                'answer_sets' => count($rows),
                'completed' => is_array($summary) && isset($summary['completed_responses']) ? (int) $summary['completed_responses'] : null,
                'incomplete' => is_array($summary) && isset($summary['incomplete_responses']) ? (int) $summary['incomplete_responses'] : null,
                'questions' => $out,
            ));
            break;

        default:
            ls_rc_fail('unknown action. ls-results.php takes export, summary and statistics');
    }
});
