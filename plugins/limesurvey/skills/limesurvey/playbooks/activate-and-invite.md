# Activate a survey and invite people

This playbook takes a reviewed draft live. When the survey is for named people, it also sets up the participant list and sends the invitations and reminders. Activating, sending and closing each need the admin's yes ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow)).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs. Names and addresses are personal data: they go to the scripts on stdin, never on a command line, and stay out of the chat beyond what the task needs.

## When to use

- The admin has reviewed a draft and wants people to answer it.
- The admin wants to invite a list of people, or remind the ones who have not answered.
- The admin wants a survey to stop taking answers.

## Open or closed: decide first

Ask the admin who should be able to answer.

- Anyone with the link (an open survey). It needs no participant list: skip to step 3, and the admin shares the public address.
- Only named people (a closed survey). Make the participant list and add the people before you activate, in the order below. A survey that is activated first is open to anyone with its address until the list exists.

## Before you start

1. Read the survey's state, and check that email works if invitations are wanted:

   ```bash
   /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-info.sh <survey id>
   /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/mail-settings.sh show
   ```

   When the email method is not `smtp`, or no test message has arrived yet, do [set-up-email](set-up-email.md) first. Invitations go out through the customer's own mail server.

2. Check the sender. Invitations carry the survey's own administrator name and address (the "Emails are sent as" line), not the site's. A survey gets them from the account that made it, so a draft you imported carries the main admin's name and address. A mail server can refuse a sender it does not know.

   Gate: ask the admin which name and address the invitations should come from, say that this changes the survey's sender, and wait for a yes.

   ```bash
   printf '%s' '{"iSurveyID": <survey id>, "aSurveyData": {"admin": "Survey Team", "adminemail": "<address>"}}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin set_survey_properties
   ```

## Steps

### 1. Make the participant list

For a closed survey only. On a draft this changes nothing for anyone yet:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh create-list --survey <survey id>
```

If the survey is already active and open, the script changes nothing and says so (exit 2): a list would close the survey at once to everyone who has the link and no access code.

Gate: tell the admin exactly that, with the number of answers so far that the script printed, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh create-list --survey <survey id> --yes-closes-the-open-survey
```

### 2. Add the people

The admin gives you the people as a file in the Files pane: a CSV with a header row that has `email`, and `firstname`, `lastname` and `language` when they have them. When they paste the people into the chat instead, write them to a file with your file tool (never with a command that has them as arguments), feed that file to the script, and delete it afterwards.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh add --survey <survey id> < <people file>
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh count --survey <survey id>
```

The script skips rows without a valid address and addresses that are already on the list, and says how many of each. Tell the admin those numbers.

### 3. Activate the survey

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-activate.sh <survey id>
```

Nothing is changed. The output shows the title, the number of questions, who can answer (anyone, or only the people on the list), the sender and the public address. Exit 2 means it can't be activated as things are, and says why.

Gate: show the admin those lines. Say that people can answer the survey from then on, and that its groups and questions can then no longer be added or removed. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/survey-activate.sh <survey id> --yes-activate
```

For an open survey, that is all: give the admin the public address.

### 4. Preview the invitations

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/invitations.sh invite --survey <survey id>
```

Nothing is sent. The output shows the number of recipients, the sender, the subject, how the mail is sent, and what the link in each mail looks like. Exit 2 means it must not be sent as things are, and the output says why: the survey is inactive, email can't deliver, the site has no public address, or the sender is missing. Fix that first.

The preview shows the subject, not the mail's text. Read the text too, so that the admin agrees to what people will get:

```bash
printf '%s' '{"iSurveyID": <survey id>, "aSurveyLocaleSettings": ["surveyls_email_invite_subj", "surveyls_email_invite", "surveyls_email_remind_subj", "surveyls_email_remind"]}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --stdin get_language_properties
```

The admin changes these texts in the survey's settings (Email templates). The words in curly brackets, such as `{FIRSTNAME}` and `{SURVEYURL}`, are filled in for each person: leave them as they are.

### 5. Send them

Gate: show the admin the preview's lines, word for word, and the mail's subject and text. Wait for a clear yes that covers the number of recipients.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/invitations.sh invite --survey <survey id> --send --expect <number of recipients>
```

`--expect` is the number the admin agreed to. When the list now gives another number, nothing is sent and the script says so: show the new preview and ask again. The script sends in LimeSurvey's own batches until nobody is left. Exit 3 means some mails were not sent. The output gives LimeSurvey's reason for each where there is one, and the ids of the people it left out without a reason, which is what LimeSurvey does with an address its mailer does not accept. Tell the admin which people to check.

### 6. Remind the ones who have not answered

A reminder needs a gap: `--min-days` is how many days must have passed since the invitation or the last reminder, and it is at least 1. `--max-reminders 2` leaves out people who have already had two.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/invitations.sh remind --survey <survey id> --min-days 7 --max-reminders 2
```

Gate: as for invitations, show the admin the preview's lines and the reminder's text, and wait for a yes that covers the number.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/invitations.sh remind --survey <survey id> --min-days 7 --max-reminders 2 --send --expect <number of recipients>
```

## Verify

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh count --survey <survey id>
```

The count of invited people has to be the number sent.

## Someone asks for their link again

The admin may ask for one person's link, to pass it on themselves. An access code lets its holder answer as that person, so read it for that one person only, and give it to the admin alone.

Gate: the admin names the person and asks for their link or code.

```bash
printf '%s' '{"iSurveyID": <survey id>, "aTokenQueryProperties": {"tid": <participant id>}, "aTokenProperties": ["token"]}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --show-codes --stdin get_participant_properties
```

The person's link is the survey's public address with `&token=` and the code at its end. Without `--show-codes`, every reply shows "(hidden)" in place of a code.

## Close a survey

To stop a survey from taking answers, give it an end date. Its answers stay where they are. Deactivating a survey is something else. It archives the answers and empties the survey. The admin does it in LimeSurvey, and it is rarely what they mean.

Dates in LimeSurvey are UTC. Convert from the admin's time zone before you set one: "Friday at 5 pm" in California is 01:00 UTC on Saturday in winter. A date in the past closes the survey at once.

Gate: say when the survey will stop taking answers, in the admin's time and in UTC, and wait for a yes.

```bash
printf '%s' '{"iSurveyID": <survey id>, "aSurveyData": {"expires": "2027-01-31 23:59:59"}}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin set_survey_properties
```

## Tell the user

Say how many invitations went out and from which address, and how many were skipped or failed and why. Bounced mail is not processed on this deployment, so a wrong address shows up only in the sender's own mailbox.
