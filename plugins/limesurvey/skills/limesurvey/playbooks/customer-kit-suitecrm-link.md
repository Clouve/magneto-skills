# The Customer Kit's link to SuiteCRM

In the Customer Kit, LimeSurvey and SuiteCRM run in one pod, and LimeSurvey has Clouve's SuiteCRM plugin switched on. When someone completes a survey whose link is on, the plugin makes a lead or a case in SuiteCRM from the questions that are mapped to CRM fields. This playbook checks LimeSurvey's side of that link, maps questions, and says what breaks it. SuiteCRM's side belongs to the `suitecrm` skill. [reference/customer-kit.md](../reference/customer-kit.md) has the background.

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs. In a LimeSurvey on its own, crm-link.sh says that the plugin is not there.

## When to use

- "Survey answers stopped showing up in the CRM." "Make this form create leads." "Which question fills which CRM field?"

## Steps

### 1. Read the state

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh status
```

It shows whether the plugin is on, where it connects, which surveys have the link on, and how many answer sets were sent and how many failed. It shows no password and no answer.

| What you see | What it means | What to do |
|---|---|---|
| `SuiteCRM plugin: OFF` | An admin switched it off, or an upgrade did. The image switches it back on after an upgrade when it was on before. | Step 2 switches it on, after the admin's yes. |
| `load error: ...` | LimeSurvey marked the plugin as broken, because it threw an error while it loaded, and has stopped loading it. The image clears that mark at every start, so it normally never shows. | Tell the user the error's text. The mark goes at the next start of the app: ask Clouve support to restart it. If it comes back, the plugin itself is broken, and that is Clouve's to fix. |
| `Link switched on for the whole site: no` | The plugin's own "Enable" setting is off. | The admin switches it on in the plugin's settings (Configuration, Plugins, SuiteCRM Integration). |
| `password NOT stored`, or an empty address | The connection settings are missing. The image writes them at every start from the deployment's settings. | You can't restart the app. Ask the user to have Clouve support restart it. |
| `Sign-in to SuiteCRM ... not set up yet`, with an error | The plugin could not reach SuiteCRM or sign in. | Check SuiteCRM with the `suitecrm` skill. See "What breaks the link". |
| `Sign-in to SuiteCRM ...: the plugin holds a client, but SuiteCRM no longer has it` | The plugin's API client was deleted in SuiteCRM, or a restore there brought back a database from before the plugin made it. Nothing is sent. | An admin opens the plugin's settings (Configuration, Plugins, SuiteCRM Integration) and presses "Initialize OAuth2", which makes a new client. Then run the status again. |
| A survey with `link off` | Answers to that survey are not sent. | Step 3. |
| `DUPLICATE setting rows` | A known fault: the plugin reads the first row, which can say off. | Step 3 repairs it. |
| Answer sets that failed | The CRM refused them or was not reachable. | Step 5. |

### 2. Switch the plugin on

Only when the status says `SuiteCRM plugin: OFF`.

Gate: say that the plugin is Clouve's own, that it sends completed answers of the surveys whose link is on to SuiteCRM, and that it was off. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugin-activate SuiteCRMIntegration
```

### 3. Switch the link on for a survey

Gate: say that every completed answer set of that survey is sent to SuiteCRM from then on. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh enable-survey --survey <survey id>
```

Gate: switching it off again stops that. Say so, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh disable-survey --survey <survey id>
```

### 4. Map questions to CRM fields

A question is mapped to one or more CRM fields. Read what is mapped:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh mappings --survey <survey id>
```

The admin can do the mapping themselves in LimeSurvey's classic question editor: edit a question and open its "SuiteCRM Integration" section. LimeSurvey 7 opens its new editor by default, and that one does not show the section. The menu under their name at the top right has the entry "Editor version", which switches to the classic editor.

Or you do it for them. A field is the module and the field's name as SuiteCRM's API has them. The plugin writes to two modules, Leads and Cases, and to no other. For a lead, the usual fields are `Leads:first_name`, `Leads:last_name`, `Leads:email1`, `Leads:phone_work`, `Leads:account_name` and `Leads:description`.

Gate: ask the admin which answer goes where, show them the list, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh map --question <question id> --field Leads:first_name
```

Repeat `--field` for a question that fills more than one field. `map` replaces the question's mapping. Before it stores anything, the script checks the module against the plugin's own list and the field against the field list SuiteCRM gives for that module. A module or a field that is not there is refused, with the names that are, and nothing is stored. When SuiteCRM does not answer and the plugin has no list of its fields yet, the script can't check and stores nothing.

The mapping that counts is the one stored on the question: the plugin reads it when an answer set is completed. The script also writes it to the plugin's own table, which the plugin's pages show. The script's last sentence says `The plugin's own table: updated`. If it ever says `not updated`, the mapping on the question is stored all the same and answers still reach the CRM: tell the user what the line says, so that Clouve can look at the plugin's table.

Read the result back with `mappings`, and test it with one answer set before the admin relies on it.

Gate: `unmap` clears a question's mapping, and its answers no longer reach the CRM. Say so, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/crm-link.sh unmap --question <question id>
```

A survey needs at least what SuiteCRM needs to make the record: for a lead, a last name.

### 5. When answers don't arrive

1. `crm-link.sh status`: is the plugin on, is the link on for that survey, did sends fail?
2. Is the survey active? Only a completed answer set of an active survey is sent.
3. Are the questions mapped (`crm-link.sh mappings`)?
4. Does SuiteCRM answer? Use the `suitecrm` skill's health check.

The plugin keeps a log of its sends in the table `lime_survey_crm_sync_log`, and removes rows that are older than 90 days. A row of a send that worked holds the answer set's id and the id of the record SuiteCRM made, and none of the answers. Only a row of a failed send also holds what was sent, which is personal data: read counts and error messages, and a failed row's content only when the admin asks about that answer set. Start with the counts:

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT survey_id, sync_status, COUNT(*) AS n, MAX(synced_at) AS last FROM lime_survey_crm_sync_log GROUP BY survey_id, sync_status'
```

To see what became of one answer set, look it up by its id (the Responses page shows it), not by what the person answered. The row names the record in SuiteCRM, which the `suitecrm` skill can open:

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT response_id, crm_module, crm_record_id, sync_status, error_message, synced_at FROM lime_survey_crm_sync_log WHERE survey_id = <survey id> AND response_id = <response id> ORDER BY id'
```

A failed row with the module `Refused` means that the plugin left one mapping out, because its module or field is not on the plugin's list. The rest of that answer set still went to SuiteCRM. Map the question again (step 4).

## What breaks the link

- Changing the SuiteCRM admin's password in SuiteCRM. The plugin signs in as that admin, with the password the deployment set. The image writes the deployment's password into the plugin at every start, so a password changed by hand in SuiteCRM no longer matches. The status still reads `set up` then, because it checks that the client is there and does not try the sign-in. Failed sends are the sign.
- Deleting or changing the OAuth2 client named "LimeSurvey Integration" in SuiteCRM, or replacing SuiteCRM's OAuth2 keys. When the client is gone, `crm-link.sh status` says that SuiteCRM no longer has it, and so does the status check on the plugin's settings page. That page has "Initialize OAuth2", which makes the client again. A client that was changed, or keys that were replaced, don't show in the status. Failed sends are the sign.
- Switching the plugin off in LimeSurvey, or its "Enable" setting, or the link of one survey.
- A LimeSurvey upgrade, for added plugins in general. The image switches this one back on.
- Deleting a mapped question, or changing its type so that it no longer gives the value the CRM field wants.

## Tell the user

Say whether new answers reach the CRM now, what was wrong, and what they should not change in SuiteCRM (the admin's password, the "LimeSurvey Integration" client).
