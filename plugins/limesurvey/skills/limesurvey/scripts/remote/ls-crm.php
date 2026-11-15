<?php
/**
 * LimeSurvey skill: remote/ls-crm.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. crm-link.sh is its front end on
 * the agent. It is for the Customer Kit only, where LimeSurvey has Clouve's SuiteCRM plugin (SuiteCRMIntegration):
 * a completed answer set becomes a lead or a case in SuiteCRM, built from the questions that are mapped to CRM
 * fields. Everywhere else it says that the plugin is not there.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   status           whether the plugin is registered and on, its connection settings without any password (only
 *                    whether one is stored), which surveys have the link switched on, and how many answer sets
 *                    were sent to SuiteCRM and how many failed. No answer is returned.
 *   mappings         sid. Each question of the survey with the CRM fields it fills.
 *   set-mapping      qid and mappings: a list of {"module": "Leads", "field": "first_name"} (label, type and
 *                    transformRule are optional). It replaces the question's mappings; an empty list clears them.
 *                    Before anything is stored, each module is checked against the plugin's own list of modules
 *                    (SuiteCRMApiClient::ALLOWED_MODULES), and each field against the field list SuiteCRM gives
 *                    for that module, through the plugin's own call. A module or a field that is not there is
 *                    refused with the names that are, and so is every mapping when the field list cannot be had
 *                    (SuiteCRM does not answer and the plugin's cache is empty). Then the mapping is stored where
 *                    the plugin reads it when an answer set is completed (the question attribute
 *                    suitecrm_mappings_json), and in the plugin's own table through the plugin's own class.
 *   set-survey-link  sid, enabled (true or false). Switches the link on or off for one survey. Duplicate rows of
 *                    that setting, which make the plugin read the wrong one, are removed.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** The plugin's row, or a JSON error that says this is not a Customer Kit. */
function ls_crm_plugin()
{
    $plugin = Plugin::model()->findByAttributes(array('name' => 'SuiteCRMIntegration'));
    if (!$plugin) {
        ls_rc_fail('the SuiteCRM plugin is not registered in this LimeSurvey. It comes with the Customer Kit, where LimeSurvey and SuiteCRM run together; a LimeSurvey on its own has no link to a CRM');
    }
    return $plugin;
}

/** The modules the plugin writes to, from the plugin's own code. A JSON error when the plugin has no such list. */
function ls_crm_modules($root)
{
    $class = "$root/plugins/SuiteCRMIntegration/classes/SuiteCRMApiClient.php";
    if (is_file($class)) {
        require_once $class;
    }
    if (!class_exists('SuiteCRMApiClient', false) || !defined('SuiteCRMApiClient::ALLOWED_MODULES') || !is_array(SuiteCRMApiClient::ALLOWED_MODULES)) {
        ls_rc_fail('this version of the SuiteCRM plugin has no list of the modules it writes to (SuiteCRMApiClient::ALLOWED_MODULES), so a mapping cannot be checked, and nothing was stored. Tell the user: the skill and the plugin are out of step');
    }
    return array_values(SuiteCRMApiClient::ALLOWED_MODULES);
}

/**
 * The fields SuiteCRM has for a module, keyed by name, through the plugin's own field-list call. When SuiteCRM does
 * not answer, what the plugin's cache holds. Returns array(fields, note): no fields and a reason when there is no
 * list to be had.
 */
function ls_crm_fields($pluginId, $module)
{
    try {
        $plugin = Yii::app()->getPluginManager()->loadPlugin('SuiteCRMIntegration', (int) $pluginId);
    } catch (Throwable $e) {
        $plugin = null;
    }
    if (!is_object($plugin)) {
        return array(array(), 'the plugin could not be loaded');
    }
    $why = '';
    if (method_exists($plugin, 'getCacheManager')) {
        try {
            // The call is the plugin's own, and protected: it runs here as the plugin itself.
            $ask = Closure::bind(function ($module) {
                return $this->getCacheManager()->getFields($module, false);
            }, $plugin, get_class($plugin));
            $fields = $ask($module);
            if (is_array($fields) && $fields) {
                return array($fields, '');
            }
            $why = 'SuiteCRM named no fields for it';
        } catch (Throwable $e) {
            $why = 'SuiteCRM did not answer (' . get_class($e) . ')';
        }
    } else {
        $why = 'this version of the plugin has no field-list call';
    }
    if (class_exists('FieldCacheManager', false) && method_exists('FieldCacheManager', 'getCachedFields')) {
        try {
            $cached = FieldCacheManager::getCachedFields($plugin, $module);
            if (is_array($cached) && $cached) {
                return array($cached, '');
            }
        } catch (Throwable $e) {
            // no cache to fall back on
        }
    }
    return array(array(), $why);
}

/**
 * Whether SuiteCRM no longer has the OAuth2 client the plugin made for itself: true when it was deleted there, or
 * when a restore brought back a database from before it was made. The plugin's own check, which asks SuiteCRM's
 * database and is what its settings page's status check uses. False when the client is there, and when SuiteCRM's
 * database can't be asked. Null when this version of the plugin has no such check, or the plugin can't be loaded.
 */
function ls_crm_client_gone($pluginId, $clientId)
{
    try {
        $plugin = Yii::app()->getPluginManager()->loadPlugin('SuiteCRMIntegration', (int) $pluginId);
        if (!is_object($plugin) || !method_exists($plugin, 'oauth2ClientIsGone')) {
            return null;
        }
        // The call is the plugin's own, and protected: it runs here as the plugin itself.
        $ask = Closure::bind(function ($clientId) {
            return $this->oauth2ClientIsGone($clientId);
        }, $plugin, get_class($plugin));
        return (bool) $ask((string) $clientId);
    } catch (Throwable $e) {
        return null;
    }
}

/** A setting of the plugin, decoded from the JSON it is stored as. Null when there is none. */
function ls_crm_setting($pluginId, $key, $model = null, $modelId = null)
{
    $row = PluginSetting::model()->findByAttributes(array('plugin_id' => (int) $pluginId, 'model' => $model, 'model_id' => $modelId, 'key' => $key));
    if (!$row) {
        return null;
    }
    $value = json_decode((string) $row->value, true);
    return $value === null ? $row->value : $value;
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $db = Yii::app()->db;
    $root = $ctx['root'];
    $plugin = ls_crm_plugin();
    $pid = (int) $plugin->id;

    switch ($action) {
        case 'status':
            $settings = array();
            foreach (array('enabled', 'suitecrm_url', 'suitecrm_admin_user', 'suitecrm_db_host', 'suitecrm_db_port', 'suitecrm_db_name',
                'suitecrm_db_user', 'oauth_client_id', 'oauth_initialized', 'oauth_init_error', 'debug_mode') as $key) {
                $value = ls_crm_setting($pid, $key);
                $settings[$key] = is_scalar($value) ? (string) $value : null;
            }
            foreach (array('suitecrm_admin_password', 'suitecrm_db_password', 'oauth_client_secret') as $key) {
                $settings[$key . '_stored'] = ls_crm_setting($pid, $key) !== null && ls_crm_setting($pid, $key) !== '';
            }
            // The settings say that a client was made. The plugin's own check asks SuiteCRM whether it still has it.
            $clientGone = null;
            if ($settings['oauth_initialized'] === '1' && (string) $settings['oauth_client_id'] !== '' && (int) $plugin->active === 1) {
                $clientGone = ls_crm_client_gone($pid, $settings['oauth_client_id']);
            }
            $surveys = array();
            $rows = PluginSetting::model()->findAllByAttributes(array('plugin_id' => $pid, 'model' => 'Survey', 'key' => 'survey_enabled'));
            foreach ($rows as $row) {
                $sid = (int) $row->model_id;
                $value = json_decode((string) $row->value, true);
                $surveys[$sid]['sid'] = $sid;
                $surveys[$sid]['values'][] = is_scalar($value) ? (string) $value : (string) $row->value;
            }
            foreach ($surveys as $sid => $one) {
                // The plugin reads the first row. More than one row is the known fault that switches a survey off.
                $surveys[$sid]['link_on'] = $one['values'][0] === '1';
                $surveys[$sid]['duplicate_rows'] = count($one['values']) > 1;
                $survey = Survey::model()->findByPk($sid);
                $surveys[$sid]['active'] = $survey ? $survey->active : null;
                unset($surveys[$sid]['values']);
            }
            $log = array();
            if (tableExists('{{survey_crm_sync_log}}')) {
                foreach ($db->createCommand('SELECT sync_status, COUNT(*) AS n FROM {{survey_crm_sync_log}} GROUP BY sync_status')->queryAll() as $row) {
                    $log[$row['sync_status']] = (int) $row['n'];
                }
            }
            $config = "$root/plugins/SuiteCRMIntegration/config.xml";
            $compatible = null;
            if (is_file($config) && ($xml = @simplexml_load_file($config))) {
                $extension = new ExtensionConfig($xml);
                $compatible = (bool) $extension->isCompatible();
            }
            ls_rc_reply(array(
                'registered' => true,
                'on' => (int) $plugin->active === 1,
                'version' => $plugin->version,
                'folder_there' => is_dir("$root/plugins/SuiteCRMIntegration"),
                'compatible' => $compatible,
                'load_error' => (int) $plugin->load_error === 1 ? (string) $plugin->load_error_message : null,
                'settings' => $settings,
                'client_gone' => $clientGone,
                'surveys' => array_values($surveys),
                'sent_to_suitecrm' => (object) $log,
            ));
            break;

        case 'mappings':
            $sid = ls_sid($request);
            $survey = ls_survey($sid);
            $rows = $db->createCommand(
                "SELECT q.qid, q.title, q.type, l.question, a.value FROM {{questions}} q
                 LEFT JOIN {{question_l10ns}} l ON l.qid = q.qid AND l.language = :lang
                 LEFT JOIN {{question_attributes}} a ON a.qid = q.qid AND a.attribute = 'suitecrm_mappings_json'
                 WHERE q.sid = :sid AND q.parent_qid = 0 ORDER BY q.gid, q.question_order"
            )->queryAll(true, array(':sid' => $sid, ':lang' => $survey->language));
            $out = array();
            foreach ($rows as $row) {
                $maps = json_decode((string) $row['value'], true);
                $fields = array();
                foreach (is_array($maps) ? $maps : array() as $map) {
                    if (isset($map['module'], $map['field'])) {
                        $fields[] = $map['module'] . ': ' . $map['field'];
                    }
                }
                $out[] = array('qid' => (int) $row['qid'], 'code' => $row['title'], 'type' => $row['type'],
                    'question' => mb_substr(trim(strip_tags((string) $row['question'])), 0, 80), 'crm_fields' => $fields);
            }
            ls_rc_reply(array('sid' => $sid, 'link_on' => ls_crm_setting($pid, 'survey_enabled', 'Survey', $sid) === '1', 'questions' => $out));
            break;

        case 'set-mapping':
            $qid = isset($request['qid']) ? (int) $request['qid'] : 0;
            $question = Question::model()->findByAttributes(array('qid' => $qid, 'parent_qid' => 0));
            if (!$question) {
                ls_rc_fail("there is no question with the id $qid (crm-link.sh mappings shows the ids)");
            }
            $maps = isset($request['mappings']) && is_array($request['mappings']) ? $request['mappings'] : null;
            if ($maps === null) {
                ls_rc_fail('set-mapping needs "mappings": a list, which may be empty');
            }
            $clean = array();
            $modules = $maps ? ls_crm_modules($root) : array();
            $fieldLists = array();
            foreach ($maps as $map) {
                if (!is_array($map) || empty($map['module']) || empty($map['field'])
                    || !preg_match('/^[A-Za-z][A-Za-z0-9_]*$/', (string) $map['module']) || !preg_match('/^[A-Za-z][A-Za-z0-9_]*$/', (string) $map['field'])) {
                    ls_rc_fail('each mapping needs a module and a field, as SuiteCRM names them, such as Leads and first_name. Nothing was stored');
                }
                $module = (string) $map['module'];
                $field = (string) $map['field'];
                // The module, against the plugin's own list. The plugin writes to no other, whatever a mapping says.
                if (!in_array($module, $modules, true)) {
                    ls_rc_fail('"' . $module . '" is not a SuiteCRM module the plugin writes to. It writes to: ' . implode(', ', $modules) . '. Nothing was stored');
                }
                // The field, against the fields SuiteCRM names for that module.
                if (!isset($fieldLists[$module])) {
                    $fieldLists[$module] = ls_crm_fields($pid, $module);
                }
                list($fields, $why) = $fieldLists[$module];
                if (!$fields) {
                    ls_rc_fail("the fields of $module could not be read from SuiteCRM, so \"$field\" could not be checked: $why. Nothing was stored. Check SuiteCRM with the suitecrm skill, then run this again");
                }
                if (!isset($fields[$field])) {
                    $names = array_keys($fields);
                    sort($names);
                    ls_rc_fail("SuiteCRM's $module has no field \"$field\". Nothing was stored. Its fields: " . implode(', ', array_slice($names, 0, 80)) . (count($names) > 80 ? ', and ' . (count($names) - 80) . ' more' : ''));
                }
                $known = is_array($fields[$field]) ? $fields[$field] : array();
                $clean[] = array(
                    'module' => $module,
                    'field' => $field,
                    'label' => isset($map['label']) ? (string) $map['label'] : (isset($known['label']) && is_string($known['label']) && $known['label'] !== '' ? $known['label'] : ucwords(str_replace('_', ' ', $field))),
                    'type' => isset($map['type']) ? (string) $map['type'] : (isset($known['type']) && is_string($known['type']) && $known['type'] !== '' ? $known['type'] : 'varchar'),
                    'transformRule' => isset($map['transformRule']) ? (string) $map['transformRule'] : '',
                );
            }
            // Where the plugin reads the mapping when an answer set is completed.
            $attribute = QuestionAttribute::model()->findByAttributes(array('qid' => $qid, 'attribute' => 'suitecrm_mappings_json'));
            if (!$attribute) {
                $attribute = new QuestionAttribute();
                $attribute->qid = $qid;
                $attribute->attribute = 'suitecrm_mappings_json';
                $attribute->language = null;
            }
            $attribute->value = json_encode($clean, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            if (!$attribute->save()) {
                ls_rc_fail('LimeSurvey did not save the mapping: ' . json_encode($attribute->getErrors()));
            }
            // The plugin's own table, through the plugin's own class, so that its pages show the same.
            $table = 'not updated: the plugin\'s class was not found';
            $class = "$root/plugins/SuiteCRMIntegration/classes/DatabaseSchema.php";
            if (is_file($class)) {
                // The attribute above is what counts when an answer set is completed. The table is what the
                // plugin's own pages show, so a failure here is reported and does not undo the mapping.
                try {
                    require_once $class;
                    if (class_exists('SuiteCRMDatabaseSchema')) {
                        $schema = new SuiteCRMDatabaseSchema();
                        $table = $schema->saveMappings((int) $question->sid, $qid, $clean) ? 'updated' : 'not updated: the plugin could not save it';
                    }
                } catch (Throwable $e) {
                    $table = 'not updated: ' . mb_substr($e->getMessage(), 0, 200);
                }
            }
            ls_rc_reply(array('qid' => $qid, 'code' => $question->title, 'sid' => (int) $question->sid, 'mappings' => $clean, 'plugin_table' => $table));
            break;

        case 'set-survey-link':
            $sid = ls_sid($request);
            ls_survey($sid);
            $on = !empty($request['enabled']);
            $rows = PluginSetting::model()->findAllByAttributes(array('plugin_id' => $pid, 'model' => 'Survey', 'model_id' => $sid, 'key' => 'survey_enabled'));
            $keep = array_shift($rows);
            $removed = 0;
            foreach ($rows as $extra) {
                $extra->delete();
                $removed++;
            }
            if (!$keep) {
                $keep = new PluginSetting();
                $keep->plugin_id = $pid;
                $keep->model = 'Survey';
                $keep->model_id = $sid;
                $keep->key = 'survey_enabled';
            }
            $keep->value = json_encode($on ? '1' : '0');
            if (!$keep->save()) {
                ls_rc_fail('LimeSurvey did not save the setting: ' . json_encode($keep->getErrors()));
            }
            ls_rc_reply(array('sid' => $sid, 'link_on' => $on, 'duplicate_rows_removed' => $removed));
            break;

        default:
            ls_rc_fail('unknown action. ls-crm.php takes status, mappings, set-mapping and set-survey-link');
    }
});
