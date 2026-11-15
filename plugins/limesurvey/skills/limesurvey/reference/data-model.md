# Data model

The tables worth knowing for read-only diagnosis. The table prefix is `lime_`.

## The rule

No SQL writes. Never `INSERT`, `UPDATE`, `DELETE`, `ALTER`, `DROP` or `TRUNCATE`. Encrypted fields, access codes and answer tables have rules that only LimeSurvey's code keeps, and a write that looks right can leave a survey unusable. The database account can write, so nothing but this rule stops you. Use the scripts and RemoteControl for changes.

Reading is fine, with care: a query on `lime_responses_<id>` or `lime_tokens_<id>` returns people's answers and details, so query those only when the admin asks about that survey, and prefer counts.

## Connecting

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT sid, active, language, datecreated FROM lime_surveys ORDER BY sid'
```

## The tables

| Table | Holds |
|---|---|
| `lime_surveys` | One row per survey: `sid`, `active` (`Y` or `N`), `language`, `owner_id`, `admin` and `adminemail` (the sender of its mails), `expires`, `anonymized`, `template` |
| `lime_surveys_languagesettings` | A survey's texts per language: title, welcome and end text, email templates |
| `lime_groups`, `lime_group_l10ns` | Groups and their texts |
| `lime_questions`, `lime_question_l10ns` | Questions and subquestions (`parent_qid` above 0) and their texts |
| `lime_answers`, `lime_answer_l10ns` | Answer options |
| `lime_question_attributes` | Extra settings per question |
| `lime_responses_<sid>` | The answers of an active survey: one row per answer set, columns `Q<qid>` |
| `lime_tokens_<sid>` | A survey's participant list, with access codes |
| `lime_old_responses_<sid>_<time>`, `lime_old_tokens_<sid>_<time>` | What a deactivated survey left |
| `lime_users` | Admin accounts. `password` is a hash. |
| `lime_permissions` | Who may do what: `entity` is `global` or `survey`, `entity_id` the survey |
| `lime_settings_global` | Site settings as name and value: `DBVersion`, `maintenancemode`, `emailmethod`, `RPCInterface`. `emailsmtppassword` is stored encrypted: leave it out of queries. |
| `lime_plugins`, `lime_plugin_settings` | Plugins (`active`, `plugin_type`, `load_error`) and their settings |
| `lime_templates`, `lime_template_configuration` | Installed themes and their options |
| `lime_failed_login_attempts` | Wrong passwords by address |
| `lime_sessions` | Sessions, when the site keeps them in the database |

## Queries that help

How many surveys, and how many are active:

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT active, COUNT(*) FROM lime_surveys GROUP BY active'
```

The biggest tables (answer tables grow, and so do archived ones):

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT table_name, engine, table_rows, ROUND((data_length + index_length) / 1048576, 1) AS mb FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY data_length + index_length DESC LIMIT 15'
```

The database version, a cut-off update and the maintenance mode:

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT stg_name, stg_value FROM lime_settings_global WHERE stg_name IN ("DBVersion", "DBUpdateIncomplete", "maintenancemode", "emailmethod", "RPCInterface")'
```

`DBVersion` is 718 for LimeSurvey 7.10.0. A row named `DBUpdateIncomplete` means a database update was cut off ([playbooks/recover-from-a-failed-upgrade.md](../playbooks/recover-from-a-failed-upgrade.md)).

Plugins and their state:

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT name, plugin_type, active, load_error FROM lime_plugins ORDER BY plugin_type, name'
```

## Encrypted columns

Participant fields and answers of questions marked as encrypted are stored as encrypted text, and so are the SMTP password and some plugin settings. A query shows that text, which is of no use and should stay out of the chat. Read such data through the scripts.
