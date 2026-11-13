# RemoteControl through rc.sh

RemoteControl is LimeSurvey's own API for surveys, groups, questions, participants and responses. `rc.sh` calls its methods inside the container, from the command line, as the site's main admin. No HTTP request is made, no password or session key is used, and the RemoteControl interface in LimeSurvey's Global settings does not have to be on. If the admin has switched it on for their own tools, this skill leaves it alone. The manual page is <https://www.limesurvey.org/manual/RemoteControl_2_API>.

## Calling a method

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --methods
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --whoami
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh list_surveys
printf '%s' '{"iSurveyID": <survey id>}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --stdin get_summary
```

- `--methods` shows three groups: the methods that read, with their parameter names; the ones that change the site and need `--yes`; and the ones `rc.sh` refuses, each with what to use instead. A `?` marks an optional parameter. Use these names: they differ from method to method (`iSurveyID` in most, `surveyId` in `get_fieldmap`, `iSurveyID_org` in `copy_survey`).
- Parameters go on stdin as a JSON object keyed by name, with `--stdin`. Leave the session key out. A JSON array in the method's order works too.
- The reply is one line: `{"result": ..., "error": null}`.

## Reading the reply

| What you see | Meaning | Exit |
|---|---|---|
| `"error": null` and a result | The method ran | 0 |
| `"result": {"status": "...", "error_code": "ERR_..."}` | LimeSurvey refused: no such survey, nothing to list, wrong state | 2 |
| `"result": null, "error": "..."` | The call could not be run: a refused method, a change without `--yes`, wrong parameters, a PHP error | 1 |

Always check both. A method can run and still say `"status": "Error: ..."`.

## What rc.sh runs, and what it refuses

`rc.sh` works from a list. A method that is not on it does not run, so a method that a newer LimeSurvey adds is refused until someone has looked at it.

| Kind | Methods | Here |
|---|---|---|
| Read | `list_surveys`, `list_survey_groups`, `get_survey_properties`, `get_language_properties`, `get_summary`, `get_fieldmap`, `export_timeline`, `list_groups`, `get_group_properties`, `list_questions`, `get_question_properties`, `list_quotas`, `get_quota_properties`, `list_participants`, `get_participant_properties`, `get_response_ids`, `list_users`, `get_site_settings`, `get_available_site_settings` | Run as they are |
| Change | `set_survey_properties`, `set_language_properties`, `set_group_properties`, `set_question_properties`, `set_quota_properties`, `set_participant_properties`, `add_survey`, `copy_survey`, `add_language`, `add_group`, `add_quota`, `import_group`, `import_question` | Run only with `--yes`, which you give once the admin has asked for or agreed to exactly that change |
| Email | `invite_participants`, `remind_participants`, `mail_registered_participants` | Refused. invitations.sh sends, after its checks and the admin's yes |
| Activate | `activate_survey` | Refused. survey-activate.sh |
| Delete | `delete_survey`, `delete_group`, `delete_question`, `delete_language`, `delete_participants`, `delete_response`, `delete_quota` | Refused. delete.sh |
| Participants | `activate_tokens`, `add_participants`, `cpd_importParticipants` | Refused. participants.sh |
| Import | `import_survey` | Refused. survey-import.sh for a draft, survey-archive.sh for an `.lss` or `.lsa` file |
| Export | `export_responses`, `export_responses_by_token`, `export_statistics` | Refused. responses.sh saves these as private files |
| Answers | `add_response`, `update_response`, `upload_file`, `get_uploaded_files` | Refused. This skill never writes an answer, and the admin downloads uploaded files in LimeSurvey |
| Session | `get_session_key`, `release_session_key` | Not needed |

## What no reply holds

Whatever the method, `rc.sh` takes these out of the reply before it prints it:

- the encryption keys of `security.php`, by their names and by their values;
- every field whose name says it is a password, a salt, a hash, a session token, a password-link key or an API key. LimeSurvey's own `list_users` returns each account's session token and password-link key, and its site-settings methods return the encryption keys. Neither reaches you;
- participants' access codes. A field named `token` reads "(hidden)". `--show-codes` leaves the codes in, and is for the one case where the admin asks for one person's link ([playbooks/activate-and-invite.md](../playbooks/activate-and-invite.md#someone-asks-for-their-link-again)).

`get_site_settings` answers only for settings that hold no secret, and says which those are when you ask for another. `set_participant_properties` answers with a count and the fields that were set, not with the person's row. No reply is a file, so no export and no answer is ever printed.

## The methods you will use

| For | Method | Parameters |
|---|---|---|
| The surveys | `list_surveys` | none |
| A survey's settings | `get_survey_properties`, `set_survey_properties` (with `--yes`) | `iSurveyID`, and `aSurveySettings` (a list of names) or `aSurveyData` (an object) |
| A survey's texts | `get_language_properties`, `set_language_properties` (with `--yes`) | `iSurveyID`, `aSurveyLocaleSettings` or `aSurveyLocaleData` |
| Groups | `list_groups`, `add_group`, `set_group_properties` (both with `--yes`) | `iSurveyID`; `iGroupID` |
| Questions | `list_questions`, `get_question_properties`, `set_question_properties` (with `--yes`) | `iSurveyID`; `iQuestionID`, `aQuestionData` |
| A copy of a survey | `copy_survey` (with `--yes`) | `iSurveyID_org`, `sNewname` |
| Counts | `get_summary` | `iSurveyID` |
| The columns of the answers | `get_fieldmap` | `surveyId` |
| Quotas | `list_quotas`, `add_quota` (with `--yes`) | `iSurveyID` |
| One participant | `get_participant_properties`, `set_participant_properties` (with `--yes`) | `iSurveyID`, `aTokenQueryProperties` (such as `{"tid": 3}`), and `aTokenProperties` or `aTokenData` |

There is no method that adds a single question. Questions come from a survey file ([survey-file-format.md](survey-file-format.md)), or the admin adds them in the editor. There is also no method that deactivates a survey: the admin does that in LimeSurvey, and it archives the answers.

Reads:

```bash
printf '%s' '{"iSurveyID": <survey id>, "aSurveySettings": ["active", "expires", "admin", "adminemail", "anonymized"]}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --stdin get_survey_properties
printf '%s' '{"iSurveyID": <survey id>, "aSurveyLocaleSettings": ["surveyls_title", "surveyls_welcometext", "surveyls_endtext"]}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --stdin get_language_properties
```

## Changing a survey that is active

People are answering an active survey, so a change reaches them at once. LimeSurvey draws the line itself:

| On an active survey | |
|---|---|
| Works in place | A question's text and help, whether it is mandatory, its condition (`relevance`); the survey's texts, its sender, its end date and its other settings |
| LimeSurvey refuses (`ERR_SURVEY_ACTIVE`) | Adding or removing a group or a question |
| Can't be changed at all once active | Whether answers are anonymized |

So "fix the typo in question 3 of my live survey" is one call. Without `--yes`, `rc.sh` refuses it and says that the survey is active.

Gate: say what changes and that the people who are answering the survey see it at once. Wait for a yes.

```bash
printf '%s' '{"iQuestionID": <question id>, "aQuestionData": {"question": "How satisfied are you with your visit?"}}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin set_question_properties
```

A change that LimeSurvey refuses on an active survey needs the survey deactivated first. The admin does that in LimeSurvey. It archives the answers given so far into a table of their own and empties the survey, and the survey starts from zero when it is activated again. That is rarely worth a new question: tell the admin what it costs, and offer a second survey for the new question instead. A copy of a survey ([playbooks/copy-or-move-a-survey.md](../playbooks/copy-or-move-a-survey.md)) is a survey of its own, with a new address and no answers. Changes made to a copy never reach the original.

## Dates, and closing a survey

Dates given to LimeSurvey are UTC: the container's clock is UTC, and LimeSurvey stores a date as it is given. `expires` set to a time in the past closes the survey at once. So convert from the admin's time zone first, and say both times before you set one. LimeSurvey's pages show times in the time zone of Global settings, or in each account's own.

To stop a survey from taking answers, set `expires`. Its answers stay. Deactivating it is something else, and archives them ([playbooks/activate-and-invite.md](../playbooks/activate-and-invite.md#close-a-survey) has the command and its gate).

## Traps, each seen on 7.10.0

- LimeSurvey's `invite_participants` sends invitations for an inactive survey without complaint, and `remind_participants` without a gap reminds everyone again on every call. That is why they are refused here.
- `set_survey_properties` and the other `set_` methods answer per field: `{"admin": true, "adminemail": true}`. A `false` means that field was not changed.
- `set_question_properties` works on an active survey, for texts, help, `mandatory` and `relevance`.
- `list_surveys` on a site with no survey answers `ERR_NO_DATA`, which is exit 2 and no fault.
- LimeSurvey's `get_available_site_settings` returns the whole configuration, the keys of `security.php` included, and `list_users` returns session tokens. Through `rc.sh` the first is a list of the settings it shows, and the second has no token.

## What a call leaves behind

Nothing outside LimeSurvey's own `tmp/` folder: no row in the sessions table, no change to the `RPCInterface` setting, no change to the admin's last sign-in. Inside `tmp/` LimeSurvey writes its usual cache files, as `www-data`. The skill's tests check this at every run.

## What the runner depends on in LimeSurvey

`scripts/remote/lib/boot.php` starts LimeSurvey's web application class in the command line and replaces the session with one in memory. It leans on these parts of LimeSurvey, checked on 7.9.1 and 7.10.0. If a LimeSurvey update breaks `rc.sh`, look here first:

- `index.php`: the constants it defines and how it creates `LSYii_Application`.
- `application/helpers/remotecontrol/remotecontrol_handle.php`: the constructor that takes an `AdminController`, and the protected methods `_checkSessionKey()` and `_jumpStartSession()`. The runner stops with a clear message when either is gone.
- `AdminController` and `LSYii_Controller`: the checks made before RemoteControl answers (the maintenance lock, the database version).
- The `User` scopes `active()` and `notexpired()`, and the `permissions` table.

The list of methods is `scripts/remote/lib/rc-policy.php`. `rc.sh --whoami` shows the version the calls run on. On anything but 7.10.x, check a method's result before you trust it.
