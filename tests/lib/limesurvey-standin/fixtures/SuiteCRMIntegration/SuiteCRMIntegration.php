<?php
/**
 * A stand-in for Clouve's SuiteCRM plugin (magneto: apps/limesurvey/image/installer/SuiteCRMIntegration), for the
 * limesurvey skill's tests only. It has the parts of the real plugin that the skill's crm-link.sh leans on, with
 * the same names, and talks to no SuiteCRM:
 *   - the class SuiteCRMApiClient with the list of modules the plugin writes to (ALLOWED_MODULES);
 *   - the plugin's protected getCacheManager(), whose getFields($module) gives a module's fields, keyed by the
 *     field's name, and FieldCacheManager::getCachedFields() for what the cache holds;
 *   - the class SuiteCRMDatabaseSchema with saveMappings(), which writes the plugin's own mappings table;
 *   - the tables lime_survey_crm_mappings and lime_survey_crm_sync_log, made on activation with the columns the
 *     real plugin gives them.
 * When the file fixtures/suitecrm-down exists next to the plugin's folder, getFields() throws, as the real one
 * does when SuiteCRM does not answer.
 */
require_once __DIR__ . '/classes/SuiteCRMApiClient.php';
require_once __DIR__ . '/classes/FieldCacheManager.php';
require_once __DIR__ . '/classes/DatabaseSchema.php';

class SuiteCRMIntegration extends PluginBase
{
    protected $storage = 'DbStorage';
    protected static $name = 'SuiteCRMIntegration';
    protected static $description = 'A stand-in for Clouve\'s SuiteCRM plugin (tests only)';
    protected $encryptedSettings = array('suitecrm_admin_password', 'suitecrm_db_password', 'oauth_client_secret');
    protected $settings = array(
        'enabled' => array('type' => 'checkbox', 'label' => 'Enable SuiteCRM Integration', 'default' => '0'),
        'suitecrm_url' => array('type' => 'string', 'label' => 'SuiteCRM URL'),
    );
    private $cacheManager = null;

    public function init()
    {
        $this->subscribe('beforeActivate');
    }

    public function beforeActivate()
    {
        $schema = new SuiteCRMDatabaseSchema();
        $schema->install();
    }

    public function getSetting(string $key, ?string $lang = null, ?int $surveyId = null, $default = null)
    {
        return $this->get($key, null, null, $default);
    }

    protected function getCacheManager(): FieldCacheManager
    {
        if ($this->cacheManager === null) {
            $this->cacheManager = new FieldCacheManager(new SuiteCRMApiClient(array()), $this, 24);
        }
        return $this->cacheManager;
    }
}
