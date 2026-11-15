# Add an admin account

This playbook gives a colleague of the admin their own sign-in to LimeSurvey, with a temporary password that is never shown in the chat, and a role on the surveys they should work on. An account, a role and the right to create surveys each change who can see what, so each needs the admin's yes ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow)).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- "Give Maria access so she can see the results." "Add an account for our intern to edit the questions."
- Not for the people who answer surveys. They need no account: they are participants ([activate-and-invite](activate-and-invite.md)).

## Before you start

Ask the admin for the person's name and email address, and what they should be able to do. Offer the roles in plain words:

| Role | What the person can do on that survey |
|---|---|
| `results` | See and export the answers and the statistics. Change nothing. |
| `editor` | Change the questions, texts, quotas and settings. Not see answers or participants, and not activate the survey. |
| `full` | Everything, as the survey's owner can. |

Recommend the smallest role that does the job. Someone who should make their own surveys needs the right to create surveys, and has every right on the ones they make.

## Steps

### 1. See who is there

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh list
```

### 2. Make the account

Gate: say who gets an account and with which address; wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/temp-password.sh --create --email '<address>' --full-name '<full name>' '<login>'
```

The script makes a 20-character password, saves it to a private file in `limesurvey-passwords` in the Files pane, makes the account and prints only the file's name. It never prints the password. Add `--can-create-surveys` when the person should make their own surveys.

A login is letters, digits, dots, dashes, underscores or `@`. LimeSurvey refuses an address that another account has, and the script then deletes the file again.

### 3. Give the role

Gate: say which role on which survey; wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh grant '<login>' --survey <survey id> --role results
```

A role replaces what the account had on that survey, and `--role none` takes the survey away.

Gate: for the right to create surveys, say that the person can then make surveys of their own, with every right on those. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh grant '<login>' --create-surveys
```

Gate: the superadmin permission gives full control of the whole site, every survey and every answer. Give it only when the admin asks for exactly that. Say what it means, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh grant '<login>' --superadmin
```

### 4. Hand over the password

Tell the admin that the file is in the Files pane, in the folder `limesurvey-passwords`, and holds the login, the temporary password and the sign-in page. They pass it on in a way they trust, and the person changes the password after signing in (their name at the top right, then "Account"). When that is done, delete the file:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/temp-password.sh --remove '<password file>'
```

## Verify

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh show '<login>'
```

It shows the account and its permissions on each survey.

## Later changes

Each of these starts with a look at the account, so that the change lands on the right person:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh show '<login>'
```

A new temporary password for someone who forgot theirs. It is not for the main admin, whose way back in is [regain-admin-access](regain-admin-access.md).

Gate: name the account, and say that the person is signed out everywhere and can't sign in until the new password reaches them. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/temp-password.sh '<login>'
```

If the script ends with exit 255 and says that the connection was lost, the password may or may not be set. It keeps the file for that reason. Run the command again, which settles it, and remove the file that is then out of date.

Someone who left: switch the account off. Nothing they made is deleted, and `activate` turns it back on.

Gate: name the account, and say that the person can no longer sign in. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh deactivate '<login>'
```

## Tell the user

Say what the account can do, in plain words, and where the password file is. Never repeat the password, even if you could read the file.
