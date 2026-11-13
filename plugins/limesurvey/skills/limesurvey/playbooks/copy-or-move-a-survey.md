# Copy or move a survey

This playbook takes one survey out of LimeSurvey as a file, or brings one in. Use it to copy a survey, to keep a version of its questions, or to move a survey with its data to another LimeSurvey. It is not a backup of the site ([back-up](back-up.md)).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## The two kinds of file

| File | Holds | Arrives as |
|---|---|---|
| `.lss` | The structure: groups, questions, answer options, texts, settings. No answers, no participants. | An inactive draft. |
| `.lsa` | The structure, plus the survey's answers and participants. Personal data. | An ACTIVE survey: LimeSurvey activates it as it imports it. |

Files that participants uploaded in a file-upload question are in neither. Encrypted answers in an `.lsa` can only be read where the same encryption keys are in place.

## Copy a survey on this site

For a second survey that starts from an existing one, LimeSurvey's own copy is the shortest way. It copies the structure only. The copy is a survey of its own: a new id, a new address, no answers. Changes made to it never reach the original.

Gate: say that this makes a new, inactive survey with the name you give. Wait for a yes.

```bash
printf '%s' '{"iSurveyID_org": <survey id>, "sNewname": "Customer feedback (copy)"}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin copy_survey
```

The reply holds the new survey's id. It is inactive.

## Take a survey out

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-archive.sh export --survey <survey id> --format lss
```

The file lands in `limesurvey-exports` in the Files pane, readable by the admin only.

Gate: with `--format lsa` the file also holds the answers and participants, so exporting an `.lsa` is reading answers. Do it only for the survey the admin named, when they ask ([SKILL.md](../SKILL.md#operating-principles-they-apply-to-every-task-reads-included), principle 1).

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-archive.sh export --survey <survey id> --format lsa
```

## Bring a survey in

The admin uploads the file to the Files pane and tells you its name.

An `.lss` file arrives as an inactive draft:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-archive.sh import <structure file>
```

An `.lsa` file is different.

Gate: tell the admin that LimeSurvey activates the survey as it imports it, so people can answer it at once, and that its answers and participants are loaded too. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-archive.sh import --yes-activates-the-survey <archive file>
```

Without the option the script refuses and changes nothing. If the admin wants the survey's questions only, export an `.lss` from the other site instead.

A tab-separated survey file (`.txt`) goes through survey-import.sh, which checks it first ([draft-a-survey](draft-a-survey.md)).

## Verify

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-info.sh <survey id>
```

## Tell the user

Say what arrived (the id, active or not, how many answers and participants came with it) and where an exported file is. Remind them to delete exported files from the Files pane once they have them.
