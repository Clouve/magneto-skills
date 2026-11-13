# The Customer Kit: LimeSurvey and SuiteCRM

The Customer Kit runs LimeSurvey and SuiteCRM in one pod. LimeSurvey has Clouve's plugin `SuiteCRMIntegration` switched on, and a completed survey can become a lead or a case in the CRM. This file is LimeSurvey's side. SuiteCRM's side is in the `suitecrm` skill. A LimeSurvey deployed on its own has the plugin's folder and no link: the plugin is not registered there.

## How the link works

1. The admin switches the link on for a survey (the plugin's tab in the survey's settings, or `crm-link.sh enable-survey`).
2. Questions are mapped to CRM fields: this question fills `Leads: first_name`, that one `Leads: email1`. The plugin writes to two SuiteCRM modules, Leads and Cases, and to no other: the list is in its code, and no setting or mapping adds to it.
3. When someone completes the survey, the plugin reads the answers, builds a record for each CRM module that has mapped fields, signs in to SuiteCRM's API and creates the record.
4. It writes what it sent, and whether it worked, to its own log table.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh status
```

## The plugin's settings

The image writes the connection settings from the deployment at every start, so they follow a changed password. They are in LimeSurvey under Configuration, Plugins, SuiteCRM Integration.

| Setting | Meaning |
|---|---|
| Enable SuiteCRM Integration | The switch for the whole site |
| SuiteCRM URL, admin username, admin password | Where the plugin signs in. The password is stored encrypted. |
| SuiteCRM database host, port, name, user, password | Used for one thing: to make the plugin's OAuth2 client in SuiteCRM. The plugin reads nothing else from that database. |
| OAuth2 client id and secret, OAuth2 status | The API client the plugin made for itself in SuiteCRM, named "LimeSurvey Integration" |
| Debug mode | Extra logging. Leave it off. |
| Field cache TTL | How long the list of CRM fields is kept |

`crm-link.sh status` shows them without any password or secret. The three passwords and secrets are stored encrypted with the site's keys, so verify-health.sh's keys line also tests the keys against them.

The list of CRM fields comes from SuiteCRM's API: the plugin asks SuiteCRM for the fields of a module, and keeps the answer for as long as the cache setting says.

## The field mapping

Each question can fill one or more CRM fields. A field is a module and a field name as SuiteCRM's API has them:

| Usual lead fields | |
|---|---|
| `Leads:first_name`, `Leads:last_name` | A lead needs a last name. |
| `Leads:email1` | Email |
| `Leads:phone_work`, `Leads:phone_mobile` | Phone |
| `Leads:account_name` | Company |
| `Leads:description` | A longer text |

For a case: `Cases:name` (the subject) and `Cases:description`.

Two ways to map:

- The admin does it in LimeSurvey's classic question editor: edit the question and open "SuiteCRM Integration". LimeSurvey 7 opens its new editor by default, which does not show that section. The menu under the admin's name at the top right has the entry "Editor version", which switches to the classic editor.
- You do it with `crm-link.sh map`, after the admin told you which answer goes where. The script checks the module against the plugin's list and the field against the fields SuiteCRM names for that module, and stores nothing when either is not there. Its refusal lists the names that are.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh mappings --survey <survey id>
```

The mapping that counts is the one on the question (its attribute `suitecrm_mappings_json`): the plugin reads it when an answer set is completed. The script also writes it to the plugin's own table `lime_survey_crm_mappings`, which the plugin's pages show, and says `The plugin's own table: updated`. If that line ever reads `not updated`, the mapping on the question is stored and answers still reach the CRM. The plugin's pages are then out of step, which Clouve should hear about.

## The log

The table `lime_survey_crm_sync_log` has one row per attempt: the answer set (`response_id`), the survey, the CRM module, the id of the record that SuiteCRM made (`crm_record_id`), the status (success, failed, partial), an error message and the time (`synced_at`). A row of a send that worked holds none of the answers, so find it by the answer set's id or by the SuiteCRM record's id, never by what someone answered. Only a row of a failed send also holds what was sent. That is people's answers, so it is personal data: read counts and error messages, and a failed row's content only when the admin asks about that answer set. A mapping the plugin refuses (a module or a field that is not on its list) is left out and logged as a failed row with the module `Refused`, and the rest of the answer set still goes to SuiteCRM. The plugin removes rows that are older than 90 days.

## What breaks the link

| Change | Effect | Way back |
|---|---|---|
| The SuiteCRM admin's password is changed in SuiteCRM | The plugin's sign-in fails. `crm-link.sh status` still reads "set up": it checks that the client is there and does not try the sign-in | Set it back to the deployment's password in SuiteCRM (the `suitecrm` skill) |
| The OAuth2 client "LimeSurvey Integration" is deleted or changed, or SuiteCRM's OAuth2 keys are replaced | The plugin's API calls are refused. When the client is gone, `crm-link.sh status` says that SuiteCRM no longer has it, and so does the status check on the plugin's settings page. A changed client or replaced keys don't show there, only as failed sends | The plugin's settings page has "Initialize OAuth2", which makes the client again |
| The plugin is switched off in LimeSurvey | Nothing is sent | `extensions.sh plugin-activate SuiteCRMIntegration`, after a yes |
| LimeSurvey marked the plugin as broken (`load error` in `crm-link.sh status`) | The plugin is not loaded, and nothing is sent | The image clears the mark at every start. Ask Clouve support to restart the app; if the mark comes back, the plugin is broken |
| The link is off for the survey, or its setting has duplicate rows | That survey sends nothing | `crm-link.sh enable-survey --survey <id>` |
| A LimeSurvey upgrade | Added plugins are switched off. The image switches this one back on when it was on. | Check with `crm-link.sh status` |
| A mapped question is deleted, or the survey is not active | The record is incomplete, or nothing is sent | Map again; activate |
| SuiteCRM is down | Sends fail and are logged as failed. They are not sent again later. | Fix SuiteCRM. The answers stay in LimeSurvey. |

## What the plugin does not do

- It does not send answers that were given while the link was off or SuiteCRM was down.
- It does not update a CRM record when an answer is edited.
- It does not copy anything from SuiteCRM into LimeSurvey.
