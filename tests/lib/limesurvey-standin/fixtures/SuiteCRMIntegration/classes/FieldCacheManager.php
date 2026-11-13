<?php
/** The stand-in's field cache (tests only): asks the API client, and keeps nothing. */
class FieldCacheManager
{
    private $apiClient;
    private $plugin;

    public function __construct(SuiteCRMApiClient $apiClient, $plugin, int $cacheTtlHours = 24)
    {
        $this->apiClient = $apiClient;
        $this->plugin = $plugin;
    }

    public function getFields(string $moduleName, bool $forceRefresh = false): array
    {
        return $this->apiClient->getModuleFields($moduleName);
    }

    public static function getCachedFields($plugin, string $moduleName): array
    {
        $cached = $plugin->getSetting('scf_' . strtolower($moduleName));
        return is_array($cached) ? $cached : array();
    }
}
