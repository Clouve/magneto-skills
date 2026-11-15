<?php
// A plugin that does nothing, for the limesurvey skill's tests.
class LssOldPlugin extends PluginBase
{
    protected $storage = 'DbStorage';
    protected static $description = 'limesurvey skill test fixture';
    protected static $name = 'LssOldPlugin';
    public function init()
    {
        $this->subscribe('beforeSurveyPage');
    }
    public function beforeSurveyPage()
    {
    }
}
