# Set up email

LimeSurvey sends invitations, reminders and notifications by email. On this deployment only SMTP can deliver: the image has no sendmail program, so LimeSurvey's default method ("PHP mail") sends nothing, and Clouve provides no mail server. The admin brings their own (their mail provider's SMTP account), types its details into LimeSurvey's own form, and you check the result and send a test message. You never see or handle the mail server's password ([SKILL.md](../SKILL.md#operating-principles-they-apply-to-every-task-reads-included), principle 4).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- Before the first invitations. When "the emails don't arrive". When verify-health.sh warns about the email method.

## Steps

### 1. Read the settings

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/mail-settings.sh show
```

It shows the method, the server, the user, the encryption and the site's sender. For the password it says only whether one is stored, and whether this site's keys can still read it.

### 2. The admin fills in the form

Tell the admin where the form is: sign in, then Configuration, Global settings, Email settings. They choose:

- Email method: SMTP.
- SMTP host: the server and its port, as `host:port`, such as `smtp.example.com:587`.
- SMTP username and password: from their mail provider. Many providers want an app password here in place of the mailbox password.
- SMTP encryption: STARTTLS for port 587, SSL/TLS for port 465.
- Default site admin email and name: the sender for the site's own messages, the test message among them. A new install has no address here, so the admin has to fill it in. The mail provider has to accept this address as a sender.

They save the form. Don't offer to type the password for them, and don't ask for it.

### 3. Check what was saved

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/mail-settings.sh show
```

The method has to be `smtp`, with the server they named and "SMTP password: stored". The "Site sender" line has to show an address between the angle brackets. With an empty one, the test message goes out with no sender, and most mail servers refuse or drop it although the script says it was handed over.

### 4. Send a test message

Gate: a test message is an email. Ask the admin which address it should go to (their own), and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/mail-settings.sh test --to '<address>' --send
```

Exit 0 means the mail server took the message. Ask the admin whether it arrived, and to look in the spam folder too. Exit 2 means it was not sent, and the output shows what the mail server answered, with every credential taken out. The usual causes: a wrong port or encryption, a password the provider does not accept, or a sender address the provider refuses.

### 5. Check each survey's sender

Each survey sends its invitations with its own administrator name and address. LimeSurvey takes them from the account that made the survey, not from the site's sender. So a draft you imported carries the main admin's name and address, which is the address the customer signed up with. invitations.sh shows the sender before anything is sent, and [activate-and-invite](activate-and-invite.md) says how to change it.

## What isn't available

Bounce processing. LimeSurvey can read a mailbox for bounced invitations, which needs PHP's `imap` extension, and the image does not have it. Bounces go to the sender's mailbox, where a person reads them.

## Tell the user

Say whether the test message was taken by their mail server, and that only they can confirm it arrived. If it failed, say what the server answered in plain words and what to change in the form.
