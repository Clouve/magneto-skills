# Customer Kit: the LimeSurvey link

Only for the Customer Kit, where LimeSurvey runs next to SuiteCRM and sends survey responses in as leads. Use this when responses have stopped arriving as leads. The last section is a rule that every other playbook follows in a Customer Kit.

How the link works: LimeSurvey's SuiteCRM plugin signs in to SuiteCRM's API as the main admin, with the admin's password as the plugin's settings hold it (at install, the one the Clouve dashboard shows), through an API client named "LimeSurvey Integration" that the plugin itself added to SuiteCRM's database. It then creates the lead as that admin. So the link needs four things on SuiteCRM's side: the main admin account, active, an admin, with the same login and password; the API client; SuiteCRM's key pair for API tokens; and SuiteCRM's database password as LimeSurvey knows it ([customer-kit.md](../reference/customer-kit.md)). Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`.

## Before you start

1. Confirm that LimeSurvey is part of this deployment:

```bash
compgen -e | grep -i limesurvey
```

It prints the names of the assistant's LimeSurvey settings, such as `LIMESURVEY_HOST`. When it prints nothing, this is not a Customer Kit and this playbook does not apply.

2. Ask the user: which survey, when the last response arrived as a lead, and when one was sent in that did not. Ask whether anyone lately changed the main admin's password or account, restored a backup, or changed the plugin's settings in LimeSurvey.

## Steps

Check SuiteCRM's side in this order. Steps 1 to 4 read only.

### 1. SuiteCRM's health

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/verify-health.sh
```

`web` and `database` have to be OK. When SuiteCRM itself is down, LimeSurvey has nowhere to send a response: follow [diagnose-problems](diagnose-problems.md) first.

### 2. The main admin account

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh show "${SUITECRM_ADMIN_USER}"
```

`status` has to be `Active` and `is_admin` `true`. If either is not, step 5 puts it right. Exit 3 means no account has that login any more: someone renamed it. No script here renames an account, so an admin changes the login back on the user's page in SuiteCRM.

A changed password does not show here. Ask the user whether anyone changed the main admin's password, and whether the password on the Clouve dashboard still signs them in.

### 3. The API client

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table \
  'SELECT id, name, allowed_grant_type, is_confidential, date_entered, date_modified FROM oauth2clients WHERE deleted = 0 AND name = "LimeSurvey Integration"'
```

This is the query that sql-read.sh allows on that table: it names its columns and leaves out the client's secret. One row with `allowed_grant_type` `password` is right. No row means the client is gone. Someone deleted it, or a restore brought back a database from before the plugin made it. It is made again from LimeSurvey's side (step 6), never from here: its secret is kept only in LimeSurvey.

### 4. Recent leads

First the count per day for the last two weeks, which shows when leads stopped:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table \
  'SELECT DATE(l.date_entered) AS day_utc, COUNT(*) AS leads FROM leads l WHERE l.deleted = 0 AND l.date_entered >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 14 DAY) GROUP BY DATE(l.date_entered) ORDER BY day_utc DESC'
```

Then, only if you need to match a response the user names, the ten newest leads:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table \
  'SELECT l.first_name, l.last_name, l.status, l.lead_source, l.date_entered FROM leads l WHERE l.deleted = 0 ORDER BY l.date_entered DESC LIMIT 10'
```

The count covers every lead, however it was made. Times are UTC. When leads still arrive, the link works, and the question is about one survey or one response: that is LimeSurvey's side (step 6). A lead that someone deleted shows in `records.sh list Leads --deleted`.

### 5. The fix on SuiteCRM's side

There is one: restore-admin-password.sh. Use it when the main admin's password was changed, or when step 2 found the account inactive or no longer an admin. It sets the password back to the one the Clouve dashboard shows, makes the account active and an admin again, and never prints the password.

A changed password has a second fix, on LimeSurvey's side: the admin types the same new password into the plugin's settings in LimeSurvey (SuiteCRM Admin Password). That keeps the password the user chose, and it is the `limesurvey` skill's step. Ask the user which of the two they want. Either way the password never passes through the chat, and SuiteCRM and the plugin have to hold the same password afterwards. If the plugin was given another password earlier, putting the dashboard's back in SuiteCRM breaks the link until the plugin holds the dashboard's again.

For the fix on this side, the first command is the preview: it changes nothing and exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh
```

Gate. Tell the user that the main admin's password goes back to the one on the Clouve dashboard, that whoever signs in to that account with another password loses it, and that the account is made active again. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh --yes-reset
```

Exit 0 prints `"password_restored": true` and whether the account was reactivated. Then ask the user to send in one test response, and run step 4 again a minute later.

### 6. What belongs elsewhere

To the `limesurvey` skill, on LimeSurvey's side:

- the plugin's settings: whether it is on, SuiteCRM's address, the admin's login and password stored there, whether the survey is linked and how its questions map to fields;
- running "Initialize OAuth2" in the plugin's settings when step 3 found no client. That makes the client again. Until it is done, the plugin's own status check says that SuiteCRM no longer has the client, and so does the `limesurvey` skill's `crm-link.sh status`;
- the survey's sync log, which has a row for each response the plugin sent, marked `success` or `failed`. A failed row there is the sign of a broken link. Go by that log, never by the status line alone: the status checks that the client is there and does not try the sign-in, so a changed admin password does not show in it.

To Clouve support:

- SuiteCRM's key pair for API tokens, when it is missing or was replaced;
- a database password that changed. LimeSurvey holds SuiteCRM's database password, and the settings on both sides are written at a start of the containers, which the assistant can't trigger.

Go to Clouve support when steps 1 to 5 are fine on this side, the `limesurvey` skill finds its side in order, and a test response still makes no lead. Write up what you ran, what it printed and when ([diagnose-problems](diagnose-problems.md), step 6).

## Check the result

A test response that the user sends in shows up as a lead: the count for today in step 4 goes up by one, and the newest lead is theirs. That lead proves the link, together with a row without an error in the survey's sync log on LimeSurvey's side. The plugin's status line does not prove it.

## Tell the user

- What had stopped the link, and what you did. After a password restore: that the main admin's password is again the one on the Clouve dashboard.
- That responses sent in while the link was down did not become leads. Whether they can be sent again is a question for LimeSurvey's side.
- The rule below, in their words: leave the main admin account and its password alone, and give people their own accounts. If that password ever has to change, the plugin in LimeSurvey needs the same new one straight away.

## The rule for every other playbook

In a Customer Kit, never do any of these, whatever the task:

- change the main admin's password. temp-password.sh refuses that account, and restore-admin-password.sh is the only script that sets it, to the dashboard's value;
- deactivate or rename the main admin account, or take away its admin rights. users.sh refuses the first and the last;
- change or delete the API client named "LimeSurvey Integration", or SuiteCRM's key pair.

When a user asks for one of them, say what it would stop, and offer what does the job without it: a second admin account for the person ([onboard-and-offboard-users](onboard-and-offboard-users.md), steps 1 and 5). After a restore from a backup, run steps 2 to 4 here, because a restore brings back the old state of the account and of the client.

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `compgen` prints nothing | LimeSurvey is not in this deployment | This playbook does not apply |
| sql-read.sh exits 64 on step 3 | The query was changed: it names the secret, or uses `*` | Run it as written |
| restore-admin-password.sh exits 1, 2 or 3 | The agent has no admin password, SuiteCRM did not keep it, or the account was not found | The table in [regain-admin-access](regain-admin-access.md) |
| Leads still don't arrive after step 5 | The cause is not the admin account | Step 6: the `limesurvey` skill first, then Clouve support |
| The plugin's status check in LimeSurvey reads "ready", and leads still don't arrive | The status check asks SuiteCRM whether the client is there, and no more. It does not try the sign-in, so a changed admin password or a switched-off admin account does not show in it | Step 2 here, with the question about the password, and the survey's sync log on LimeSurvey's side (step 6) |
| Exit 75 | The image is installing or upgrading SuiteCRM, a restore was cut off, or the container waits | `upgrade-state.sh` says which. Wait ([failed-upgrade](failed-upgrade.md)), or finish the restore ([restore-from-backup](restore-from-backup.md)) |
