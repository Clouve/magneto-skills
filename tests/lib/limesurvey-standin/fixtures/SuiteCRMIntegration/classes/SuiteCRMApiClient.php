<?php
/** The stand-in's API client (tests only): the module list, and a field list that needs no SuiteCRM. */
class SuiteCRMApiClient
{
    public const ALLOWED_MODULES = ['Leads', 'Cases'];

    public function __construct(array $config)
    {
    }

    public static function isAllowedModule($moduleName): bool
    {
        return is_string($moduleName) && in_array($moduleName, self::ALLOWED_MODULES, true);
    }

    public function getModuleFields(string $moduleName): array
    {
        if (!self::isAllowedModule($moduleName)) {
            throw new InvalidArgumentException('The plugin does not read or write this SuiteCRM module');
        }
        if (is_file(dirname(__DIR__, 2) . '/suitecrm-down')) {
            throw new Exception('cURL error: Could not resolve host: suitecrm');
        }
        $fields = array(
            'Leads' => array('first_name' => 'First Name', 'last_name' => 'Last Name', 'email1' => 'Email Address',
                'phone_work' => 'Office Phone', 'account_name' => 'Account Name', 'description' => 'Description'),
            'Cases' => array('name' => 'Subject', 'description' => 'Description', 'priority' => 'Priority'),
        );
        $out = array();
        foreach ($fields[$moduleName] as $name => $label) {
            $out[$name] = array('name' => $name, 'module' => $moduleName, 'type' => $name === 'description' ? 'text' : 'varchar', 'label' => $label);
        }
        return $out;
    }
}
