# Responses and privacy

## Answers are personal data

What people answer, together with who they are, is personal data that the organization holds in trust. Three rules follow, and they apply to every task:

- Read, export or summarize the answers of a survey only when the admin asks for that survey.
- Keep answers out of the chat beyond what the admin asked for. An export goes to a private file, never into the chat.
- Never copy answers, names or addresses into this skill's files.

Counts are not answers. survey-info.sh and `get_summary` say how many answer sets a survey has without reading one.

## Where answers live

Each active survey has its own table, `lime_responses_<survey id>`, with one row per answer set and one column per question (`Q<question id>`, and `Q<question id>_S<subquestion id>` for a subquestion). Deactivating a survey renames the table to `lime_old_responses_<survey id>_<time>`: the answers are kept, and the survey starts with an empty table when it is activated again. That is why changing an active survey is a decision for the admin.

A complete answer set has a submit date. An incomplete one was started and not finished.

## The summary

Gate: the admin asked about this survey's answers.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/responses.sh summary --survey <survey id>
```

The summary is JSON for you to read: the number of answer sets, and per question the number of people who answered and the split of their answers. For numbers it gives the lowest, the highest and the average. What people typed is counted and left out, unless `--with-text` asks for it. The same goes for an equation question and for a column the script can't tie to a question: their values can be anything a person typed. It holds no access code, no IP address and no participant details.

A question's code in the summary is its code in the survey. A subquestion shows as `code[subquestion code]`, and the "Other" box of a list as `code[other]`.

A multiple choice question has one entry per box. In such an entry, "Yes" is the number of people who ticked the box. "N/A" is everyone else: people who did not tick it and people who were never shown the question. "answered" counts both, so it is the number of answer sets, not the number of people who ticked anything.

## The export

Gate: the admin asked for this survey's answers as a file.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/responses.sh export --survey <survey id> --format csv
```

The file lands in `limesurvey-exports` in the Files pane, mode 600 in a folder of mode 700. It is LimeSurvey's own export:

- `--format`: `csv` (semicolon-separated, UTF-8) or `xlsx`.
- `--completion`: `complete` (the default), `incomplete` or `all`.
- `--headings`: `code` (the question codes), `full` (the question texts) or `abbreviated`.
- `--answers`: `long` (the answer texts, the default) or `short` (the answer codes).

The first columns are LimeSurvey's own: the answer set's id, the submit date, the last page, the language, and for a closed survey that is not anonymized the access code. Tell the admin the file holds personal data and should be deleted from the Files pane once they have it.

An export is saved on the assistant's side only, as a private file in the Files pane. Nothing writes one inside the LimeSurvey container, where `upload/` and `tmp/` are served to the web. `rc.sh` refuses LimeSurvey's export methods for that reason, and prints no answers.

## The statistics report

Gate: the admin asked for a report on this survey.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/responses.sh statistics --survey <survey id>
```

LimeSurvey's own statistics report: counts and shares per question, as a PDF, or with `--format xls` or `--format html`. It is saved like an export.

## Encryption

A survey can mark questions, and participant fields, as encrypted. LimeSurvey then stores them encrypted in the database, with the keys in `application/config/security.php`.

- The scripts read through LimeSurvey's own code, so the summary and the export show encrypted answers readable. Say so when you hand over an export.
- SQL shows the stored, encrypted text. Never try to read or write encrypted fields with SQL.
- Without the right `security.php` nobody can read them, the admin included ([backup-restore.md](backup-restore.md#why-securityphp-matters)).

## Anonymized surveys

With "anonymized responses" on, LimeSurvey does not store which participant gave which answer set, and the export has no access code column. It can't be switched once the survey is active. Dates and IP addresses are separate survey settings.

## Deleting answers

delete.sh deletes one answer set, and that can't be undone except from a backup of the whole site. The first command below is the preview: it deletes nothing, and says whether the answer set was completed.

Gate: back up first. Show the admin the preview's lines, and wait for a yes for that one answer set.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/delete.sh response --survey <survey id> --response <response id>
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/delete.sh response --survey <survey id> --response <response id> --yes-delete
```

Tested on 7.10.0.
