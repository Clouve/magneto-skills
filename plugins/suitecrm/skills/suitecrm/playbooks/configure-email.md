# Configure email

Use this when the user wants SuiteCRM to send email (invitations, notifications, reminders, campaigns), or when mail that used to go out has stopped. It covers outgoing mail only. Mailboxes that SuiteCRM reads are in [email.md](../reference/email.md).

The admin sets outgoing mail up in SuiteCRM's own form and types the SMTP password there. The password never passes through the chat, a command line or a file of yours. email.sh then reads the result without the password, sends a test message, and fixes the one setting that older tools leave wrong. Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`. A value in angle brackets in a command is yours to fill in. It stays inside its single quotes, and an apostrophe in it is written `'\''`.

## Before you start

1. Read what is set now. This reads only, and it never shows the password.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh status
```

It prints `configured`, `server`, `port`, `security` (none, SSL or TLS), `user`, `password_stored` (`true` or `false`), `auth_type`, `from_name`, `from_address` and `warnings`. A new SuiteCRM has no server and port 25.

2. Ask the user what their email provider gave them: the SMTP server's name, the port, the user name, and the address and name that mail should come from. Ask whether they have the password at hand, and tell them they will type it into SuiteCRM themselves. Some providers want a separate "app password" for this, and the provider's help pages say so.
3. When a user pastes a password into the chat anyway, don't use it and don't repeat it. Ask them to type it into the form, and suggest they change it at the provider, since it has now been in a chat.

## Steps

### 1. Walk the admin through SuiteCRM's form

An admin signs in to SuiteCRM and opens the Admin page, then Outbound Email in the Email group. They open the account named "system" and edit it. The labels below are the ones in SuiteCRM 8.10.2's form:

| Field | What to enter |
|---|---|
| Auth Type | Basic Auth, when the server wants a user name and a password, as nearly all do |
| Server | The SMTP server's name from the provider |
| Mail SMTP/SSL | TLS with port 587. SSL with port 465 |
| Port | 587 for most providers |
| Username | The user name from the provider, often the full email address |
| Password | The admin types it here. Nobody sends it to you |
| "From" name, "From" address | The name and address people see as the sender. Use an address the provider lets this account send from |

Then they save. Wait until the user says it is saved.

### 2. Read the result

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh status
```

A good result has `"configured": true`, the server and port the user named, `"password_stored": true`, `"auth_type": "basic"` and no warnings. Each warning has one meaning:

| The warning starts with | What it means | What to do |
|---|---|---|
| `No SMTP server is set` | The form was not saved, or the server is empty. SuiteCRM can't send | Step 1 again |
| `A user name is set but auth_type is not "basic"` | SuiteCRM 8.10 signs in to the server only when the account's sign-in type is "basic". Without it, a server that needs a sign-in refuses the mail | Step 3 |
| `A user name is set but no password is stored` | The password field was left empty | The admin types it into the form and saves |
| `Port 25 is blocked` | Many hosts and mail services block port 25 | The admin changes the port to 587 with TLS |
| `The From address is empty or still the example one` | Mail services reject a sender they don't know | The admin sets the "From" address |

### 3. Fix the sign-in type, when the warning says so

This sets the account's sign-in type to "basic" and leaves the stored password as it is. It is needed when the account was saved by an older tool or script. The admin can change the type again in the form at any time. The first command is the preview: it changes nothing and exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh set-auth-basic
```

Gate. Tell the user that this changes one setting of the outgoing-mail account, the sign-in type, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh set-auth-basic --yes-change
```

It prints `"changed": true` and `"stored_password_untouched": true`, or `"changed": false` when the type was "basic" already.

### 4. Send a test message

Ask which address the test should go to. The user's own is best, because they can say whether it arrived. The first command is the preview: nothing is sent, and it exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh test '<address>'
```

Gate. This sends one email. Tell the user: "I'll send one short test message from SuiteCRM to that address", and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh test '<address>' --yes-send
```

Exit 0 prints `"sent": true`. That means the mail server took the message. Ask the person whether it arrived, and to look in the spam folder.

Exit 2 prints `"sent": false` and `error`, the mail server's or SuiteCRM's own reason. Read it this way:

- It could not connect, the connection was refused, or it timed out: the server's name or the port is wrong, or the provider does not accept connections from outside. The admin checks both in the form.
- It names the sign-in (authentication): the user name or the password was refused, or the provider wants an app password. The admin types it again in the form. You never handle it.
- It names the sender: the "From" address is not one the provider allows for this account.
- It names TLS, SSL or a certificate: the "Mail SMTP/SSL" choice does not fit the port. 587 goes with TLS and 465 with SSL.

After a change in the form, run step 2 and this step again.

### 5. After it works

A new person can now get their first password by email ([onboard-and-offboard-users](onboard-and-offboard-users.md), step 1, way A).

Mail that SuiteCRM sends on a schedule (campaigns, reminders, workflow emails, scheduled reports) also needs the scheduler to run. This reads only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh status
```

`"held": true` means that no scheduled job runs until someone releases the scheduler ([after-an-upgrade](after-an-upgrade.md), step 3). `last_run` should be a few minutes old at most. [scheduler-and-worker.md](../reference/scheduler-and-worker.md) has the rest.

## Check the result

`email.sh status` shows no warnings (step 2), and the person who got the test message says it arrived. A `"sent": true` alone is not enough.

## Tell the user

- That outgoing email works, which address it comes from, and that the test message arrived.
- That their SMTP password is stored in SuiteCRM, encrypted, and that you never saw it.
- What still needs them: an app password from the provider, a "From" address the provider accepts, or releasing the scheduler for scheduled mail.
- That SuiteCRM can now email a new person their first password.

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Exit 64 | The yes flag is missing (the preview), or the address is not written as an address | Run the second command after the yes, or ask for the address again |
| Exit 65 | That is not an email address | Ask for the address again |
| Exit 2 from `status` | SuiteCRM has no system outgoing-mail account | [diagnose-problems](diagnose-problems.md), and tell the user |
| Exit 2 from `test` | No server is set, or the message was not sent | Step 1, or read `error` as in step 4 |
| Exit 2 from `set-auth-basic` | No SMTP user name is set, so there is nothing to sign in with, or SuiteCRM did not keep the change | The admin fills in the form (step 1). Then `status` again |
| `"sent": true`, and nothing arrives | The server took the message and dropped or delayed it | Spam folder first. Then the provider's side: whether the "From" address belongs to the account, and the provider's own sending log |
| The test arrives, but one person's own emails from SuiteCRM don't send | They send through their own outgoing account. email.sh reads the system account only | The person checks their account under Outbound Email Accounts, reached from their profile page, and types its password there ([email.md](../reference/email.md)) |
| Exit 70 or 255 | The script crashed, or SSH failed | `status` again, then [diagnose-problems](diagnose-problems.md) |
| Exit 75 | The image is installing or upgrading SuiteCRM, a restore was cut off, or the container waits. Nothing was changed | `upgrade-state.sh` says which. Wait ([failed-upgrade](failed-upgrade.md)), or finish the restore ([restore-from-backup](restore-from-backup.md)) |
