# Participants and email

## Open and closed surveys

A survey without a participant list is open: anyone with its address can answer, as often as they like. A survey with a participant list is closed: each person on the list has an access code, the link in their invitation carries it, and nobody else gets in.

`participants.sh create-list` makes the list. It can be made for a draft, and it does not activate the survey: for a survey that is meant for named people, make the list before you activate. On a survey that is already active and open, a list closes it at once to everyone who has the link and no access code. There the script changes nothing unless it gets `--yes-closes-the-open-survey`, after the admin was told so. Removing a list again is something the admin does in LimeSurvey.

## The list

Each person has an id on the list, a first name, a last name, an email address, a language, an access code, and the state: email status, invited (a date or `N`), reminded, completed.

- `participants.sh add` takes a CSV or JSON on stdin. It skips rows without a valid address and addresses already on the list, and reports the counts. LimeSurvey makes the access codes.
- `participants.sh list` and `count` never show an access code, and `rc.sh` shows "(hidden)" in its place. An access code lets its holder answer as that person, so treat it like a password. The one way to read one is `rc.sh --show-codes`, for one person, when the admin asks for that person's link.
- Names and addresses are personal data. A survey can store them encrypted. The scripts go through LimeSurvey's own code, so they read and write encrypted fields correctly. SQL would not.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh count --survey <survey id>
```

`count` gives numbers only. The list itself is people's names and addresses.

Gate: the admin asks to see who is on the list of this survey.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/participants.sh list --survey <survey id>
```

## Invitations and reminders

invitations.sh is the only way this skill sends them ([playbooks/activate-and-invite.md](../playbooks/activate-and-invite.md)).

- An invitation goes to people on the list who have not been invited, whose email status is OK, and whose validity period includes now.
- A reminder goes to people who were invited and have not completed. `--min-days` is required: only people whose invitation or last reminder is at least that many days old get one.
- LimeSurvey sends in batches of its "maxemails" setting (50 by default). The script sends batch after batch until nobody is left.
- The link in each mail starts with the site's public address (`publicurl` in `config.php`, which the image sets).
- The texts of the invitation and the reminder are the survey's email templates. The admin edits them in the survey's settings (Email templates).

### The sender

The mail's sender is the survey's own administrator name and address. In 7.10.0 a new survey gets them from the account that made it (read in the source: `application/models/Survey.php`), not from the site's settings. A draft this skill imports is made as the main admin, so its invitations go out with the main admin's name and the address the customer signed up with, until someone changes that. A mail provider can refuse to send as an address it does not know. invitations.sh shows the sender in its preview, and `set_survey_properties` with `admin` and `adminemail` changes it ([playbooks/activate-and-invite.md](../playbooks/activate-and-invite.md) has the command and its gate).

### What stops a send

invitations.sh refuses, in the preview and at the send, when the survey is inactive, has no list or has ended, when the site has no public address, when the email method can't deliver, when the sender is not an address, or when a reminder has no gap. LimeSurvey's own method checks none of these: on an inactive survey it reports OK and the mails go out with a link that answers "not active".

LimeSurvey also drops a person whose address its mailer does not accept, without a word. So after a send, invitations.sh looks at who was to get mail and is still waiting, names those people by their ids on the list, and ends with exit 3.

## The email settings

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/mail-settings.sh show
```

They are LimeSurvey's global settings (Configuration, Global settings, Email settings):

| Setting | Meaning |
|---|---|
| Email method | `smtp` is the one that works here. `mail`, `sendmail` and `qmail` need a sendmail program, which the image does not have. |
| SMTP host | `host` or `host:port` |
| SMTP user and password | The password is stored encrypted with the site's keys. No script shows it. |
| SMTP encryption | empty, `ssl` (from the start, port 465) or `tls` (STARTTLS, port 587) |
| Site admin email and name | The sender of the site's own messages, the test message among them. Empty on a new install, until the admin fills it in. It is not the sender of a survey's invitations. |

The admin fills in the form, and `mail-settings.sh test` sends LimeSurvey's own test message ([playbooks/set-up-email.md](../playbooks/set-up-email.md)).

"SMTP password: stored, but this site's keys cannot read it" means `security.php` is not the one the password was saved with. The admin types the password in again. If answers or participants are encrypted too, see [backup-restore.md](backup-restore.md#why-securityphp-matters).

## Bounces

LimeSurvey can read a mailbox for bounced invitations and mark those participants. That needs PHP's `imap` extension, which the image does not have, so the "Bounce settings" in LimeSurvey do nothing here. A bounced invitation lands in the sender's mailbox. When the admin tells you an address bounced, set that person's email status so that they get no more mail. `participants.sh list` shows the ids.

Gate: name the person by their id on the list and say that they get no more invitations or reminders. Wait for a yes.

```bash
printf '%s' '{"iSurveyID": <survey id>, "aTokenQueryProperties": {"tid": <participant id>}, "aTokenData": {"emailstatus": "bounced"}}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin set_participant_properties
```

The reply is a count and the field that was set, such as `{"changed":1,"tid":2,"fields":{"emailstatus":"bounced"}}`. LimeSurvey's own method returns the person's whole row, with their name, address and access code. `rc.sh` prints none of that.

Tested on 7.10.0.
