<?php
/**
 * The stand-in's tables (tests only), with the columns the real plugin's DatabaseSchema.php gives them, so that
 * what the skill's text and scripts read and write is tried against the real layout.
 */
class SuiteCRMDatabaseSchema
{
    private $db;

    public function __construct()
    {
        $this->db = Yii::app()->db;
    }

    public function install(): void
    {
        $this->db->createCommand("CREATE TABLE IF NOT EXISTS {{survey_crm_mappings}} (
            id INT AUTO_INCREMENT PRIMARY KEY,
            survey_id INT NOT NULL,
            question_id INT NOT NULL,
            crm_module VARCHAR(100) NOT NULL,
            crm_field_name VARCHAR(100) NOT NULL,
            crm_field_label VARCHAR(255) NULL,
            crm_field_type VARCHAR(50) NULL,
            transform_rule VARCHAR(100) NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            UNIQUE KEY unique_question_field_mapping (question_id, crm_module, crm_field_name)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci")->execute();
        $this->db->createCommand("CREATE TABLE IF NOT EXISTS {{survey_crm_sync_log}} (
            id INT AUTO_INCREMENT PRIMARY KEY,
            response_id INT NOT NULL,
            survey_id INT NOT NULL,
            crm_module VARCHAR(100) NOT NULL,
            crm_record_id VARCHAR(100) NULL,
            sync_status ENUM('success', 'failed', 'partial') NOT NULL,
            request_payload LONGTEXT NULL,
            response_data LONGTEXT NULL,
            error_message TEXT NULL,
            field_mappings_used TEXT NULL,
            synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci")->execute();
    }

    public function saveMappings(int $surveyId, int $questionId, array $mappings): bool
    {
        $this->db->createCommand()->delete('{{survey_crm_mappings}}', 'question_id = :q', array(':q' => $questionId));
        foreach ($mappings as $map) {
            $this->db->createCommand()->insert('{{survey_crm_mappings}}', array(
                'survey_id' => $surveyId, 'question_id' => $questionId, 'crm_module' => $map['module'], 'crm_field_name' => $map['field'],
                'crm_field_label' => isset($map['label']) ? $map['label'] : '', 'crm_field_type' => isset($map['type']) ? $map['type'] : '',
                'transform_rule' => !empty($map['transformRule']) ? $map['transformRule'] : null,
            ));
        }
        return true;
    }
}
