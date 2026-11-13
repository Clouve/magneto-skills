# Outgoing email

SuiteCRM sends its own mail (invitations, notifications, reminders, campaigns) through one system account. The admin sets that account up in SuiteCRM's own form, where the SMTP password is typed and never passes through the chat. [email.sh](../scripts/email.sh) then reads the result without the password, sends a test message, and fixes the one setting that older tools leave wrong.

Never ask for an SMTP password, and never offer to type one in. If a user pastes one into the chat, don't use it and don't repeat it, and suggest they change it at their mail provider.

## The system account

- It is one row of the table `outbound_email`, the one of type `system`. A new install has it with an empty server and port 25, so a new SuiteCRM can't send anything yet.
- The admin fills it in under Admin > Email > Outbound Email.
- What to enter: the provider's SMTP server, the port (587 with TLS is the usual pair, 465 goes with SSL), the user name and password of the mailbox with the sign-in type "basic", and a From name and address.
- No script of the skill writes these settings. The assistant says what to enter and checks the result.
- `email.sh` reads and tests this account only. SuiteCRM 8.10.2 has three other kinds of outgoing account: System Override, Group and Personal. An email that a person writes in SuiteCRM can go out through their own Personal account, which they set up under Outbound Email Accounts, reached from their profile page (read in SuiteCRM's code, not tested). No script of the skill reads those accounts. So when the test message arrives and one person's own emails don't send, that account is the place to look.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh status
```

| Key | Meaning |
|---|---|
| `configured` | Whether a server is set at all |
| `server`, `port`, `security` | Where SuiteCRM sends, and with `none`, `SSL` or `TLS` |
| `user`, `password_stored` | The SMTP user name, and whether a password is stored. The password itself is never read |
| `auth_type` | The sign-in type. It must be `basic` when a user name is set |
| `from_name`, `from_address` | What recipients see as the sender |
| `warnings` | What the script found wrong, in words: no server, a user name without `basic`, a user name without a stored password, port 25, an empty or example From address |

## The auth_type trap

SuiteCRM 8.10 signs in to the SMTP server only when the account's `auth_type` is `basic`. An account saved by an older tool or script has a user name and a password but no `auth_type`. SuiteCRM then sends without signing in. A server that needs a sign-in refuses the mail, and a server that needs none still takes it, so a test against such a server proves nothing. SuiteCRM's own form sets the type correctly. For an account that lacks it, `set-auth-basic` sets it. Without `--yes-change` the command changes nothing and says what it would do.

Gate. Tell the user that this changes one setting of the outgoing-mail account, the sign-in type, and leaves the stored password as it is. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh set-auth-basic
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh set-auth-basic --yes-change
```

The change sets the sign-in type to `basic` and leaves the stored password as it is. It is refused with 2 when no user name is set.

## The test message

A test sends real email. Without `--yes-send` the command sends nothing and exits 64.

Gate. Show the user the address the test message goes to, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh test '<address>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh test '<address>' --yes-send
```

- It sends one short message with the subject "SuiteCRM test message" through the system account.
- `"sent": true` means the mail server took the message. It doesn't mean it arrived. Ask the person to look, in the spam folder too.
- Exit 2 means SuiteCRM could not hand the message over, or no server is set. `error` holds SuiteCRM's reason.

## SMTP errors in plain words

| The error says | What it means | What to tell the admin |
|---|---|---|
| `Could not connect to SMTP host`, `Connection refused`, `SMTP code: 111` | Nothing answers at that server and port | Check the server name and the port. Many hosts block port 25: use 587 with TLS |
| `Connection timed out` | The port is blocked on the way, or the server name is wrong | The same |
| `Could not authenticate`, a `535` code | The server refused the user name or the password | Type them again in SuiteCRM's form. Many providers want an app password, or SMTP switched on for the mailbox |
| `530`, `Authentication required`, `Must issue a STARTTLS command first` | The server wants a sign-in or TLS that SuiteCRM did not offer | Check `auth_type` and `security` in `email.sh status` |
| `550`, `553` or `554` with words about the sender | The server won't send mail from that From address | Use a From address the mailbox is allowed to send as |
| Words about a certificate or SSL | The security setting doesn't fit the port, or the server's certificate doesn't fit its name | 465 goes with SSL, 587 with TLS, and the server name must be the one the provider gives |
| No error, but the mail never arrives | The receiving side dropped it or filed it as spam | The From address's domain has to allow this mail server. That is set with the domain's provider |

Only the first row was seen in a test here. The other rows are the usual words of mail servers, and each server phrases them a little differently, so read the whole `error` text.

## The From address

The From name and address are part of the system account, and SuiteCRM also keeps them among its notification settings, which is where `email.sh` reads them. Mail services reject a sender they don't know. So the From address should be the mailbox the SMTP user belongs to, or an address that mailbox may send as. `email.sh status` warns when it is empty or still an example address.

## The key file that decrypts the stored password

SuiteCRM stores the SMTP password encrypted. The key is a file under `public/legacy/custom/blowfish/`, which SuiteCRM makes on first use.

- A copy of the database without that folder can't decrypt the stored password. This skill's backups include `public/legacy/custom/`, and so the key. A restore brought the password back in working order in a test.
- If the key file is ever lost, nothing recovers the stored password. The admin types it again in the form.
- Never print the key file, and never copy it anywhere. `sql-read.sh` refuses the column that holds the encrypted password.

## What depends on the scheduler

A test message and an invitation go out at once. Other mail waits for a scheduled job:

- Campaign email goes out through the jobs "Queue Campaign Emails" and "Send Campaign Emails".
- Reminders for calls and meetings go out through "Run Email Reminder Notifications".
- Scheduled reports and workflow actions that run from the scheduler go out through their own jobs.

So when the test arrives but campaign mail and reminders never go out, look at the scheduler first: `scheduler.sh status` shows whether it is held or has stopped ([scheduler-and-worker.md](scheduler-and-worker.md)). SuiteCRM 8.10 pauses a campaign when the mail server returns errors, according to its release notes.

## Inbound mailboxes

SuiteCRM can also read mailboxes, for example to file incoming mail or to open cases from it. The admin sets them up under Admin > Email > Inbound Email, with the mailbox's own password. The scheduled job "Check Inbound Mailboxes" reads them, so they too stand still while the scheduler is held.

The skill has no script that creates or changes a mailbox. `scheduler.sh queued` lists the active ones by name, which matters before a held scheduler is released: from then on SuiteCRM reads those mailboxes.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done |
| 64 | Usage, or the yes is missing |
| 65 | Not an email address |
| 2 | No server is set, the message was not sent, or the change was not kept |
| 70, 75, 255 | The script crashed, SuiteCRM is being installed or upgraded, ssh failed ([shell-access.md](shell-access.md#exit-codes-the-scripts-share)) |
