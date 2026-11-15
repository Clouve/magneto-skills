<?php
/**
 * LimeSurvey skill: remote/lib/tsv-check.php (included by ls-survey.php)
 *
 * Checks a tab-separated survey file before LimeSurvey imports it. LimeSurvey's importer takes almost anything
 * and says little: it drops subquestions that share an id, reads a cell that starts with a double quote as quoted
 * text that can swallow the rest of the row, and ignores rows it does not know. This checker refuses what the
 * importer would get wrong, so that the survey the admin reviews is the survey that was written.
 *
 * ls_tsv_check(string $bytes): array('errors' => [...], 'warnings' => [...], 'summary' => [...])
 *   An error stops the import. A warning does not. Each message starts with the line number it is about.
 *   summary: sid, language, languages, title, groups, questions, subquestions, answers (counted in the base
 *   language), and codes (question code => type).
 *
 * The rules (reference/survey-file-format.md explains each one):
 *   1. UTF-8 text, one row per line, cells separated by tabs. No cell starts with a double quote.
 *   2. The first row is the header, with at least: id, class, type/scale, name, relevance, text, language,
 *      mandatory, other. No row has more cells than the header.
 *   3. class is S, SL, G, Q, SQ, A, C, AS, QTA, QTAM or QTALS.
 *   4. S rows: sid (six digits) and language are there; format, if given, is G, S or A.
 *   5. SL rows: surveyls_title in the base language is there; a language is the base language or one of
 *      additional_languages. A missing welcome text or end text is a warning.
 *   6. At least one G row with a name, and one Q row. A Q row comes after a G row.
 *   7. Q rows: a known type; a code that starts with a letter and holds only letters and digits, 20 at most, and
 *      is used once per language; an id of digits; mandatory is Y, N, S or empty; other is Y, N or empty.
 *   8. SQ rows: after a question whose type takes subquestions; an id of digits that no other Q or SQ row uses;
 *      a code of letters and digits, used once per language in its question and scale; scale 0, or 1 for the
 *      columns of an array of numbers or texts.
 *   9. A rows: after a question whose type takes answer options; a code of 1 to 5 letters and digits, used once
 *      per language in its question and scale; scale 0, or 1 for the second scale of a dual-scale array.
 *  10. A question whose type needs answer options or subquestions has at least one of each it needs.
 *  11. A relevance expression names only question codes that exist and come earlier in the file (a warning).
 *
 * More than one language. LimeSurvey's importer ties the rows of the languages together like this, and so does
 * this checker, so every layout the importer takes passes here: a group is the same group as the group at the
 * same position in the base language (the first G row of each language, the second, and so on); a Q row whose
 * code is already a question of that group is that question's text in another language, not a new question; and
 * the SQ and A rows below a Q row belong to that question, each code once per language. So a row may be followed
 * by its translation, a question's block may be repeated per language, or the whole file may be repeated per
 * language. A translation has the type of the question it translates (an error if not), and a language whose
 * question has another number of subquestions or answer options than the base language gets a warning.
 */

function ls_tsv_check($bytes)
{
    $errors = array();
    $warnings = array();
    $summary = array('sid' => null, 'language' => null, 'languages' => array(), 'title' => null, 'groups' => 0,
        'questions' => 0, 'subquestions' => 0, 'answers' => 0, 'codes' => array());
    $done = function () use (&$errors, &$warnings, &$summary) {
        return array('errors' => $errors, 'warnings' => $warnings, 'summary' => $summary);
    };

    // Rule 1.
    if (substr($bytes, 0, 3) === "\xEF\xBB\xBF") {
        $bytes = substr($bytes, 3);
    }
    if (trim($bytes) === '') {
        $errors[] = 'the file is empty';
        return $done();
    }
    if (!mb_check_encoding($bytes, 'UTF-8')) {
        $errors[] = 'the file is not UTF-8 text';
        return $done();
    }
    if (strpos($bytes, "\0") !== false) {
        $errors[] = 'the file holds NUL bytes, so it is not a text file';
        return $done();
    }
    $lines = preg_split('/\r\n|\n|\r/', $bytes);
    while ($lines && trim(end($lines)) === '') {
        array_pop($lines);
    }

    // Rule 2: the header.
    $header = array_map('trim', explode("\t", $lines[0]));
    $required = array('id', 'class', 'type/scale', 'name', 'relevance', 'text', 'language', 'mandatory', 'other');
    $missing = array_diff($required, $header);
    if ($missing) {
        $errors[] = 'line 1: the header row lacks ' . implode(', ', $missing) . '. It needs at least: ' . implode(', ', $required) . ', separated by tabs';
        return $done();
    }
    $seen = array();
    foreach ($header as $h) {
        if ($h !== '' && isset($seen[$h])) {
            $errors[] = "line 1: the header names the column $h twice";
        }
        $seen[$h] = true;
    }
    $columns = count($header);

    $classes = array('S', 'SL', 'G', 'Q', 'SQ', 'A', 'C', 'AS', 'QTA', 'QTAM', 'QTALS');
    // What each question type takes: 'a' answer options, 's' subquestions, 'x' subquestions on scale 1 too,
    // 'd' answer options on scale 1 too.
    $types = array(
        '1' => 'asd', '5' => '', 'A' => 's', 'B' => 's', 'C' => 's', 'D' => '', 'E' => 's', 'F' => 'as', 'G' => '',
        'H' => 'as', 'I' => '', 'K' => 's', 'L' => 'a', 'M' => 's', 'N' => '', 'O' => 'a', 'P' => 's', 'Q' => 's',
        'R' => 's', 'S' => '', 'T' => '', 'U' => '', 'X' => '', 'Y' => '', '!' => 'a', '|' => '', '*' => '',
        ':' => 'sx', ';' => 'sx',
    );

    // First pass: the rows, the survey settings and the languages.
    $rows = array();
    foreach ($lines as $i => $line) {
        $n = $i + 1;
        if ($i === 0 || trim($line) === '') {
            continue;
        }
        $cells = explode("\t", $line);
        foreach ($cells as $c => $cell) {
            if ($cell !== '' && $cell[0] === '"') {
                $name = isset($header[$c]) ? $header[$c] : 'column ' . ($c + 1);
                $errors[] = "line $n: the $name cell starts with a double quote. LimeSurvey reads such a cell as quoted text and can lose the rest of the row. Start the text with another character, or use &quot;";
            }
        }
        if (count($cells) > $columns) {
            $errors[] = "line $n: the row has " . count($cells) . " cells and the header has $columns. A tab inside a text splits it: take the tab out";
            continue;
        }
        $row = array('_line' => $n);
        foreach ($header as $c => $h) {
            $row[$h] = isset($cells[$c]) ? $cells[$c] : '';
        }
        $row['class'] = trim($row['class']);
        if ($row['class'] === '') {
            $errors[] = "line $n: the row has no class. Every row is S, SL, G, Q, SQ or A";
            continue;
        }
        if (!in_array($row['class'], $classes, true)) {
            $errors[] = "line $n: unknown class \"" . $row['class'] . '". Use S, SL, G, Q, SQ or A';
            continue;
        }
        $rows[] = $row;
    }

    $settings = array();
    foreach ($rows as $row) {
        if ($row['class'] === 'S') {
            if (trim($row['name']) === '') {
                $errors[] = 'line ' . $row['_line'] . ': an S row needs the setting in name and its value in text';
                continue;
            }
            $settings[trim($row['name'])] = array(trim($row['text']), $row['_line']);
        }
    }
    // Rule 4.
    if (!isset($settings['sid'])) {
        $errors[] = 'there is no S row for sid. Add one with a six-digit number of your choosing in text; LimeSurvey takes another number if that one is in use';
    } elseif (!preg_match('/^[1-9][0-9]{5}$/', $settings['sid'][0])) {
        $errors[] = 'line ' . $settings['sid'][1] . ': sid has to be a six-digit number that does not start with 0, not "' . $settings['sid'][0] . '"';
    } else {
        $summary['sid'] = (int) $settings['sid'][0];
    }
    $base = null;
    if (!isset($settings['language'])) {
        $errors[] = 'there is no S row for language. Add one with the survey\'s language code in text, such as en';
    } elseif (!preg_match('/^[a-z]{2,3}(-[A-Za-z0-9]+)*$/', $settings['language'][0])) {
        $errors[] = 'line ' . $settings['language'][1] . ': language has to be a language code such as en, de or pt-BR, not "' . $settings['language'][0] . '"';
    } else {
        $base = $settings['language'][0];
        $summary['language'] = $base;
    }
    if (isset($settings['format']) && !in_array($settings['format'][0], array('G', 'S', 'A'), true)) {
        $errors[] = 'line ' . $settings['format'][1] . ': format is G (a page per group), S (a page per question) or A (all on one page), not "' . $settings['format'][0] . '"';
    }
    $languages = $base === null ? array() : array($base);
    if (isset($settings['additional_languages']) && $settings['additional_languages'][0] !== '') {
        foreach (preg_split('/\s+/', $settings['additional_languages'][0]) as $extra) {
            if ($extra !== '' && !in_array($extra, $languages, true)) {
                $languages[] = $extra;
            }
        }
        $warnings[] = 'line ' . $settings['additional_languages'][1] . ': the survey has more than one language (' . implode(', ', $languages) . '). Every SL, G, Q, SQ and A row then needs a copy in each language. Write one language unless the admin asked for more';
    }
    $summary['languages'] = $languages;
    if (isset($settings['active']) && strtoupper($settings['active'][0]) === 'Y') {
        $warnings[] = 'line ' . $settings['active'][1] . ': the S row for active is ignored. An imported survey is always inactive, and the admin activates it';
    }
    if ($base === null) {
        return $done();
    }
    // lang ROW: the row's language, the base language when the cell is empty
    $lang = function (array $row) use ($base) {
        $l = trim($row['language']);
        return $l === '' ? $base : $l;
    };

    // Second pass: the structure.
    $titles = array();
    $welcome = false;
    $end = false;
    $groupSeq = array();       // language => how many G rows it has had: a group is known by its position
    $groupKey = null;          // the position of the group the rows below belong to
    $questions = array();      // "<group position>/<code>" => what is known about the question
    $current = null;           // the key of the question the SQ and A rows below belong to
    $ids = array();            // id => array(class, name, language => true, line)
    $codes = array();          // language => code => line
    $order = array();          // codes in file order, base language
    $relevance = array();      // array(line, expression, number of codes known before it)
    foreach ($rows as $row) {
        $n = $row['_line'];
        $name = trim($row['name']);
        $l = $lang($row);
        if (in_array($row['class'], array('SL', 'G', 'Q', 'SQ', 'A'), true) && !in_array($l, $languages, true)) {
            $errors[] = "line $n: the language \"$l\" is not the survey's language" . (count($languages) > 1 ? 's (' . implode(', ', $languages) . ')' : " ($base)");
            continue;
        }
        switch ($row['class']) {
            case 'SL':
                if ($name === '') {
                    $errors[] = "line $n: an SL row needs the text's name in name, such as surveyls_title";
                    break;
                }
                if (trim($row['language']) === '') {
                    $errors[] = "line $n: an SL row needs its language in the language column";
                    break;
                }
                if ($name === 'surveyls_title' && trim($row['text']) !== '') {
                    $titles[$l] = trim($row['text']);
                }
                if ($l === $base && $name === 'surveyls_welcometext' && trim($row['text']) !== '') {
                    $welcome = true;
                }
                if ($l === $base && $name === 'surveyls_endtext' && trim($row['text']) !== '') {
                    $end = true;
                }
                break;
            case 'G':
                $current = null;
                $groupKey = isset($groupSeq[$l]) ? $groupSeq[$l] : 0;
                $groupSeq[$l] = $groupKey + 1;
                if ($name === '') {
                    $errors[] = "line $n: the group has no name";
                }
                if ($l === $base) {
                    $summary['groups']++;
                }
                if (trim($row['relevance']) !== '' && $l === $base) {
                    $relevance[] = array($n, $row['relevance'], count($order));
                }
                break;
            case 'Q':
                $current = null;
                if ($groupKey === null) {
                    $errors[] = "line $n: the question comes before any group. Put a G row above it";
                    break;
                }
                $type = trim($row['type/scale']);
                if (!isset($types[$type])) {
                    $errors[] = "line $n: \"$type\" is not a question type. reference/survey-file-format.md lists them (S short text, T long text, L list, M multiple choice, N number, Y yes or no, ...)";
                    break;
                }
                if (!preg_match('/^[A-Za-z][A-Za-z0-9]{0,19}$/', $name)) {
                    $errors[] = "line $n: the question code \"$name\" has to start with a letter and hold only letters and digits, 20 at most";
                } elseif (isset($codes[$l][strtolower($name)])) {
                    $errors[] = "line $n: the question code $name is already used on line " . $codes[$l][strtolower($name)] . '. Each question needs its own code';
                } else {
                    $codes[$l][strtolower($name)] = $n;
                }
                $id = trim($row['id']);
                if (!ctype_digit($id) || (int) $id === 0) {
                    $errors[] = "line $n: question $name needs a number in the id column";
                } elseif (isset($ids[$id]) && !($ids[$id][0] === 'Q' && $ids[$id][1] === $name && !isset($ids[$id][2][$l]))) {
                    $errors[] = "line $n: the id $id is already used on line " . $ids[$id][3] . '. Every Q and SQ row needs an id of its own';
                } else {
                    if (!isset($ids[$id])) {
                        $ids[$id] = array('Q', $name, array(), $n);
                    }
                    $ids[$id][2][$l] = true;
                }
                $mandatory = trim($row['mandatory']);
                if (!in_array($mandatory, array('', 'Y', 'N', 'S'), true)) {
                    $errors[] = "line $n: mandatory is Y, N or S (asked for, can be skipped), not \"$mandatory\"";
                }
                $other = trim($row['other']);
                if (!in_array($other, array('', 'Y', 'N'), true)) {
                    $errors[] = "line $n: other is Y or N, not \"$other\"";
                } elseif ($other === 'Y' && !in_array($type, array('L', '!', 'M', 'P'), true)) {
                    $warnings[] = "line $n: other is Y, and only list and multiple choice questions (L, !, M, P) have an \"Other\" option";
                }
                if (trim($row['text']) === '' && $type !== '*') {
                    $warnings[] = "line $n: question $name has no text";
                }
                if (trim($row['relevance']) !== '' && $l === $base) {
                    $relevance[] = array($n, $row['relevance'], count($order));
                }
                // The same code in the same group is the same question, in another language.
                $key = $groupKey . '/' . strtolower($name);
                if (isset($questions[$key])) {
                    if ($questions[$key]['type'] !== $type) {
                        $errors[] = "line $n: question $name has the type $type here and the type " . $questions[$key]['type'] . ' on line ' . $questions[$key]['line'] . '. A translation keeps the question\'s type';
                    }
                } else {
                    $questions[$key] = array('line' => $n, 'code' => $name, 'type' => $type,
                        'answers' => array(), 'subs' => array(), 'acodes' => array(), 'scodes' => array());
                }
                $current = $key;
                if ($l === $base) {
                    $summary['questions']++;
                    $summary['codes'][$name] = $type;
                    $order[] = $name;
                }
                break;
            case 'SQ':
                if ($current === null) {
                    $errors[] = "line $n: the subquestion has no question above it";
                    break;
                }
                $question = &$questions[$current];
                $takes = $types[$question['type']];
                if (strpos($takes, 's') === false) {
                    // The "other" row of a list question and the comment row of a list with comment are not real rows.
                    if ($name === 'other' || in_array($question['type'], array('O', '|'), true)) {
                        unset($question);
                        break;
                    }
                    $errors[] = "line $n: question " . $question['code'] . ' (type ' . $question['type'] . ') takes no subquestions' . (strpos($takes, 'a') !== false ? '. Its choices are A rows' : '');
                    unset($question);
                    break;
                }
                $scale = trim($row['type/scale']);
                if (!in_array($scale, array('', '0', '1'), true)) {
                    $errors[] = "line $n: a subquestion's type/scale is empty or 0, or 1 for a column of an array of numbers or texts, not \"$scale\"";
                    unset($question);
                    break;
                }
                $scale = (int) $scale;
                if ($scale === 1 && strpos($takes, 'x') === false) {
                    $errors[] = "line $n: only the columns of an array of numbers (:) or texts (;) have 1 in type/scale";
                    unset($question);
                    break;
                }
                if (!preg_match('/^[A-Za-z0-9]{1,20}$/', $name)) {
                    $errors[] = "line $n: the subquestion code \"$name\" has to hold only letters and digits, 20 at most";
                } elseif (isset($question['scodes'][$l][$scale][strtolower($name)])) {
                    $errors[] = "line $n: the subquestion code $name is used twice in question " . $question['code'] . ($l === $base ? '' : " in the language $l");
                } else {
                    $question['scodes'][$l][$scale][strtolower($name)] = true;
                }
                $id = trim($row['id']);
                if (!ctype_digit($id) || (int) $id === 0) {
                    $errors[] = "line $n: subquestion $name needs a number of its own in the id column. Without one LimeSurvey can drop the subquestion without a word";
                } elseif (isset($ids[$id]) && !($ids[$id][0] === 'SQ' && $ids[$id][1] === $question['code'] . '/' . $scale . '/' . $name && !isset($ids[$id][2][$l]))) {
                    $errors[] = "line $n: the id $id is already used on line " . $ids[$id][3] . '. A subquestion needs an id that no other Q or SQ row has, or LimeSurvey drops it without a word';
                } else {
                    if (!isset($ids[$id])) {
                        $ids[$id] = array('SQ', $question['code'] . '/' . $scale . '/' . $name, array(), $n);
                    }
                    $ids[$id][2][$l] = true;
                }
                if (trim($row['text']) === '') {
                    $warnings[] = "line $n: subquestion $name has no text";
                }
                $question['subs'][$l][$scale] = (isset($question['subs'][$l][$scale]) ? $question['subs'][$l][$scale] : 0) + 1;
                unset($question);
                if ($l === $base) {
                    $summary['subquestions']++;
                }
                break;
            case 'A':
                if ($current === null) {
                    $errors[] = "line $n: the answer option has no question above it";
                    break;
                }
                $question = &$questions[$current];
                $takes = $types[$question['type']];
                if (strpos($takes, 'a') === false) {
                    $errors[] = "line $n: question " . $question['code'] . ' (type ' . $question['type'] . ') takes no answer options' . (strpos($takes, 's') !== false ? '. Its items are SQ rows' : '');
                    unset($question);
                    break;
                }
                $scale = trim($row['type/scale']);
                if (!in_array($scale, array('', '0', '1'), true)) {
                    $errors[] = "line $n: an answer option's type/scale is empty or 0, or 1 for the second scale of a dual-scale array, not \"$scale\"";
                    unset($question);
                    break;
                }
                $scale = (int) $scale;
                if ($scale === 1 && strpos($takes, 'd') === false) {
                    $errors[] = "line $n: only a dual-scale array (type 1) has answer options with 1 in type/scale";
                    unset($question);
                    break;
                }
                if (!preg_match('/^[A-Za-z0-9]{1,5}$/', $name)) {
                    $errors[] = "line $n: the answer code \"$name\" has to be 1 to 5 letters and digits";
                } elseif (isset($question['acodes'][$l][$scale][strtolower($name)])) {
                    $errors[] = "line $n: the answer code $name is used twice in question " . $question['code'] . ($l === $base ? '' : " in the language $l");
                } else {
                    $question['acodes'][$l][$scale][strtolower($name)] = true;
                }
                if (trim($row['text']) === '') {
                    $warnings[] = "line $n: answer option $name has no text";
                }
                $question['answers'][$l][$scale] = (isset($question['answers'][$l][$scale]) ? $question['answers'][$l][$scale] : 0) + 1;
                unset($question);
                if ($l === $base) {
                    $summary['answers']++;
                }
                break;
        }
    }
    // Rule 10, once every row is read: what a question needs has to be there in the base language, and the
    // other languages should have as many rows as the base language.
    foreach ($questions as $question) {
        $takes = $types[$question['type']];
        $count = function ($what, $language, $scale) use ($question) {
            return isset($question[$what][$language][$scale]) ? $question[$what][$language][$scale] : 0;
        };
        if (strpos($takes, 'a') !== false && $count('answers', $base, 0) === 0) {
            $errors[] = 'line ' . $question['line'] . ': question ' . $question['code'] . ' (type ' . $question['type'] . ') has no answer options. Add A rows under it';
        }
        if (strpos($takes, 'd') !== false && $count('answers', $base, 1) === 0) {
            $errors[] = 'line ' . $question['line'] . ': question ' . $question['code'] . ' (a dual-scale array) has no answer options for its second scale. Add A rows with 1 in type/scale';
        }
        if (strpos($takes, 's') !== false && $count('subs', $base, 0) === 0) {
            $errors[] = 'line ' . $question['line'] . ': question ' . $question['code'] . ' (type ' . $question['type'] . ') has no subquestions. Add SQ rows under it';
        }
        if (strpos($takes, 'x') !== false && $count('subs', $base, 1) === 0) {
            $errors[] = 'line ' . $question['line'] . ': question ' . $question['code'] . ' (an array of numbers or texts) has no columns. Add SQ rows with 1 in type/scale';
        }
        foreach ($languages as $other) {
            if ($other === $base) {
                continue;
            }
            foreach (array('answers' => 'answer options', 'subs' => 'subquestions') as $what => $words) {
                foreach (array(0, 1) as $scale) {
                    if ($count($what, $other, $scale) !== $count($what, $base, $scale)) {
                        $warnings[] = 'line ' . $question['line'] . ': question ' . $question['code'] . ' has ' . $count($what, $base, $scale) . " $words in $base and " . $count($what, $other, $scale) . " in $other. Each one needs a row in every language";
                    }
                }
            }
        }
    }
    foreach ($languages as $other) {
        if ($other !== $base && (isset($groupSeq[$other]) ? $groupSeq[$other] : 0) !== (isset($groupSeq[$base]) ? $groupSeq[$base] : 0)) {
            $warnings[] = "the survey has " . (isset($groupSeq[$base]) ? $groupSeq[$base] : 0) . " groups in $base and " . (isset($groupSeq[$other]) ? $groupSeq[$other] : 0) . " in $other. LimeSurvey matches the groups of the languages by their position, so each language needs the same groups in the same order";
        }
    }

    // Rules 5 and 6.
    if (!isset($titles[$base])) {
        $errors[] = "there is no SL row for surveyls_title in the language $base. The survey needs a title";
    } else {
        $summary['title'] = $titles[$base];
    }
    if ($summary['groups'] === 0) {
        $errors[] = 'there is no G row. A survey needs at least one group of questions';
    }
    if ($summary['questions'] === 0) {
        $errors[] = 'there is no Q row. A survey needs at least one question';
    }
    if (!$welcome) {
        $warnings[] = 'there is no welcome text (an SL row for surveyls_welcometext). People see it before the first question';
    }
    if (!$end) {
        $warnings[] = 'there is no end text (an SL row for surveyls_endtext). People see it after they submit';
    }

    // Rule 11.
    $known = array();
    foreach ($order as $i => $code) {
        $known[strtolower($code)] = $i;
    }
    $words = array('and', 'or', 'not', 'true', 'false', 'eq', 'ne', 'lt', 'le', 'gt', 'ge', 'naok', 'shown', 'value',
        'code', 'relevancestatus', 'self', 'that', 'token', 'sq', 'qid', 'gid', 'sgqa', 'nok', 'question', 'type', 'jsname',
        'rowdivid', 'mandatory', 'grelevance', 'gseq', 'qseq', 'valuenaok', 'onlynum', 'readwrite', 'sid', 'lang');
    foreach ($relevance as $entry) {
        list($n, $expression, $before) = $entry;
        $bare = preg_replace('/"[^"]*"|\'[^\']*\'/', ' ', $expression);
        if (substr_count($bare, '(') !== substr_count($bare, ')')) {
            $warnings[] = "line $n: the relevance \"$expression\" has unbalanced brackets";
        }
        if (preg_match_all('/(?<![A-Za-z0-9_.:])([A-Za-z][A-Za-z0-9]*)(?:_[A-Za-z0-9]+)?(?![A-Za-z0-9_]*\s*\()/', $bare, $m)) {
            foreach (array_unique($m[1]) as $word) {
                $w = strtolower($word);
                if (in_array($w, $words, true) || strtoupper($word) === 'INSERTANS') {
                    continue;
                }
                if (!isset($known[$w])) {
                    $warnings[] = "line $n: the relevance \"$expression\" names $word, which is not a question code in this file";
                } elseif ($known[$w] >= $before) {
                    $warnings[] = "line $n: the relevance \"$expression\" names $word, which comes later in the survey. A condition can only look at earlier questions";
                }
            }
        }
    }

    return $done();
}
