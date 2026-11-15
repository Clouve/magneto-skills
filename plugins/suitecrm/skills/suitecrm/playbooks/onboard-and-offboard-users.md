# Onboard and offboard users

Use this when someone needs a SuiteCRM account, forgot their password, should be allowed more or less, or is leaving. When the main admin can't sign in, use [regain-admin-access](regain-admin-access.md).

users.sh handles accounts, roles and security groups, and never takes or prints a password. A first password comes one of two ways: SuiteCRM emails its own (`users.sh invite`), or temp-password.sh saves one to a private file that the user opens in the Files pane. Never ask for a password and never put one in the chat ([users-and-roles.md](../reference/users-and-roles.md)). The scripts act with full admin rights and can't tell who is asking. So every change to who can sign in, or to what someone may do, waits behind a gate, and several of these commands have no yes flag: nothing but the gate stops them. Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`. A value in angle brackets in a command is yours to fill in. It stays inside its single quotes, and an apostrophe in it is written `'\''`.

## Before you start

1. For a new person, ask: their first and last name, their email address, the login they should have (many teams use the email address), what they should be allowed to do ("only her own deals", "everything except deleting"), and whether they should be an admin. Unless the user says so, they are not.
2. See who is there. This reads only.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh list
```

Each user has `login`, `name`, `email`, `status` (Active or Inactive), `is_admin`, `system_generated_password`, `asks_for_new_password`, `roles` and `groups`. `system_generated_password` is `true` while the account is on a password that SuiteCRM or this skill made. It says nothing about whether the person has signed in. `asks_for_new_password` says when SuiteCRM will ask that person for a new one.

3. For a new person, check whether SuiteCRM can send email. That decides how they get their first password.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh status
```

Use the invitation (step 1, way A) only when `configured` is `true`, `warnings` is empty and a test message has arrived ([configure-email](configure-email.md)). Otherwise use the private file (way B).

In the commands, put the person's own names in place of `Sally` and `Sales`, inside the single quotes.

## Steps

### 1. Create the account

A new account can sign in as soon as the person has its password. Until it has a role, it may do everything in every module except the admin pages (step 2). So both ways wait for a yes.

Way A, by email. SuiteCRM makes the account, generates a password and emails it. Nobody else sees it. The first command is the preview: it changes nothing and exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh invite '<new login>' --first-name 'Sally' --last-name 'Sales' --email '<address>'
```

Gate. This makes an account and sends email. Show the user the login, the name and the address the password goes to, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh invite '<new login>' --first-name 'Sally' --last-name 'Sales' --email '<address>' --yes-send
```

Exit 0 prints `"created": true` and `"email_sent": true`. Exit 8 means the account was made and the email was not sent: nobody has the password, so give the account one with step 4, and fix email afterwards.

Way B, a private file. This makes the account with a temporary password that is never printed. No email is sent. The command has no yes flag and runs at once.

Gate. Show the user the login, the name and the email address of the account you are about to make, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --create --first-name 'Sally' --last-name 'Sales' --email '<address>' '<new login>'
```

It prints two lines. The first starts with `Saved the temporary password for` and names the login and the file in `suitecrm-passwords/`, a folder the Files pane shows. The second says when SuiteCRM asks for a new password on this site. Don't open the file. Ask the user to open it in the Files pane, pass the login and the password on in private (in person, by phone, in a password manager), and tell you when that is done. Then delete the file:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --remove '<password file>'
```

Neither password is good for one sign-in only. Step 7 says how long it keeps working and what the user can do about it. Both ways take `--admin`, which makes the new account an administrator. It needs `--yes-admin` as well, after the gate of step 5.

### 2. Set what the person may do, with a role

Without a role, a regular user may do everything in every module except the admin pages. A role takes rights away. Look at the roles that exist:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-list
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-show '<role>'
```

`role-show` lists the people in the role and its `settings`. A module or an action that is not listed is at its default, which is allowed. Make a new role when none fits. A role with nobody in it changes nothing for anyone:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-create '<new role>'
```

`role-set` sets one action in one module: the role, the module as in its address (Accounts, Contacts, Leads, Opportunities, Cases), the action (`access`, `view`, `list`, `edit`, `delete`, `import`, `export`, `massupdate`) and the level. For `access` the level is `enabled` or `disabled`. For `view`, `list`, `edit`, `delete` and `export` it is `all`, `group` (records of the person's security groups), `owner` (records assigned to the person) or `none`. `import` and `massupdate` take only `all` or `none`, because SuiteCRM has no owner level for those two. `default` clears the setting, and a cleared setting means allowed.

Gate. `role-set` has no yes flag, and it changes the role for everyone in it. Read `role-show` first. Show the user who is in the role and the lines you are about to run, say what each line takes away or opens, and wait for a clear yes. Then run them:

```bash
# "She works only with her own opportunities": all seven lines
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities list owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities view owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities edit owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities delete owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities export owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities import none
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Opportunities massupdate none
# "He can't delete accounts"
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts delete none
```

"Only her own records" takes all seven lines. `list` and `view` alone hide records on screen but leave export and changes open: she could still export every opportunity, and edit or delete one whose id she has. `import` and `massupdate` are set to `none` because SuiteCRM has no owner level there, and an import in update mode can change a record she does not own. The price is that she can't import or mass-update her own records either. Say that to the user before the yes.

Each `role-set` prints the level it replaced (`before` and `after`), the people in the role (`users`) and `widens_access`. When `widens_access` is `true` the line opened something, and the `note` gives the command that puts it back. Keep the `before` values in the conversation: they are the way back. In the same way, `Contacts export none` stops exports of contacts, and `Cases access disabled` hides a module.

Gate. Giving someone a role changes what they may see and do, and `role-assign` has no yes flag. Say what the person gains or loses with this role, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-assign '<login>' '<role>'
```

It prints `roles_before` and `roles_after`. People see a changed role after they sign in again. A role never limits an admin. `role-unassign` takes a role away from a person. It waits for a yes in the same way.

### 3. Security groups

A security group is a set of people. It matters when a role uses the level `group`: the person then works with the records that belong to their groups. Which records belong to a group is set in SuiteCRM's own screens ([users-and-roles.md](../reference/users-and-roles.md)). Listing the groups reads only, and a new group with nobody in it changes nothing for anyone:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-list
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-create '<new group>'
```

Gate. Putting someone in a group changes which records they work with, and `group-add` has no yes flag. Say which group it is and what the person gains, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-add '<login>' '<group>'
```

It prints `groups_before` and `groups_after`. `group-remove` takes a person out of a group. It waits for a yes in the same way.

### 4. Someone forgot their password

Before a reset, find out why the sign-in fails. A new password helps only when the password is the problem. Read `status` with `users.sh show` (under "Check the result"), and ask what the sign-in page says:

- `status` is `Inactive`: the account was deactivated, and a new password would not let the person in. Whether they are let back in is the user's decision (`users.sh activate`, step 6).
- The page says "Too many failed login attempts", or the person tried five times or more in the last half hour: that is the sign-in throttle. It refuses the right password too, and a new password does not end it. The person waits thirty minutes, or signs in from another network ([regain-admin-access](regain-admin-access.md), step 1).

The first command is the preview. It changes nothing and exits 64:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh '<login>'
```

Gate. Confirm the account with `users.sh show` and show the user its login and name, so that the reset reaches the right person. Say that the person's current password stops working at once and can't be brought back, and check that someone can hand them the new one. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --yes-reset '<login>'
```

It saves a new temporary password to a private file, as in step 1, way B. Hand it over the same way and remove the file afterwards. Step 7 applies to this password too. The script refuses the main admin (exit 2: that is [regain-admin-access](regain-admin-access.md)) and an account that signs in through LDAP or SAML, for which SuiteCRM keeps no password.

### 5. Make someone an admin

The first command is the preview. It changes nothing and exits 64:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' yes
```

Gate. Say what it gives: an admin sees and changes every record, manages users and roles, changes the settings and the layouts, and can install code through Module Loader. Roles no longer limit them. Wait for a clear yes that names the person. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' yes --yes-admin
```

It prints `was_admin` and the account as it is now. The same gate stands in front of a new account that starts as an admin: `--admin` on a command of step 1 needs `--yes-admin` too.

Taking the right away has no yes flag.

Gate. Say who loses the admin pages, and that their roles and security groups apply to them again. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' no
```

The main admin always stays an admin (exit 2).

### 6. Someone leaves

Deactivate the account. Never delete it: SuiteCRM's records point at their owner, and this skill has no command that deletes a user. A deactivated person is signed out at once and can no longer sign in. Their records stay, still assigned to them, and `activate` reverses it.

First see what they own, module by module. `total` is the number:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/records.sh list Opportunities --assigned '<login>'
```

Gate. `deactivate` has no yes flag. Tell the user the numbers, confirm the person by name, and say that the person is signed out at once. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh deactivate '<login>'
```

It prints `"deactivated": true`, `"status": "Inactive"` and `was_status`.

Gate. Letting someone back in gives them their access as it was, with the password they had, and `activate` has no yes flag. Confirm the person by name with the user, and wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh activate '<login>'
```

Giving the records to someone else is the user's call. For a few records, change `assigned_user_name` one by one ([add-and-update-records](add-and-update-records.md), step 5). For more than about ten, an admin does it in SuiteCRM's own mass update: open the module's list, filter on "Assigned to" with the person who left, select the records, choose Bulk Action, then Mass Update, set "Assigned to" to the new owner and save. That is a bulk change, so offer a backup first ([back-up](back-up.md)).

### 7. When SuiteCRM asks for a new password

An emailed or temporary password is not changed at the first sign-in by itself. SuiteCRM asks for a new one by the site's own rule for generated passwords. This prints the rule and reads only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule
```

`asks_for_new_password` is the rule in words, and `accounts_on_a_generated_password` lists who is on such a password now. On a stock install the rule is `7 days after the password was set`. The first sign-in then goes to SuiteCRM's welcome wizard, which has no password step, and the generated password stays the person's working password for a week. Whoever saw the email or the file can sign in as that person until it is changed. So do two things whatever the rule says: ask the user to have the person change the password under their profile right after they sign in, and remove the password file as soon as it is handed over.

The skill never changes the site's password rules by itself. When the user wants SuiteCRM to ask at the first sign-in, offer the change. It is one setting for the whole site (Admin > Password Management, "System-Generated Password Expiration"). After it, SuiteCRM sends everyone who is on a generated password to its change-password page at their next sign-in, and everyone who gets one later at their first. The first command is the preview: it changes nothing and exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule first-sign-in
```

Gate. Say that this is a rule for the whole site, name the accounts it reaches now, and say that an admin can change it back under Admin > Password Management. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule first-sign-in --yes-change
```

It prints `"changed": true` and the rule `before` and `after`.

## Check the result

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh show '<login>'
```

Check `status`, `is_admin`, `roles` and `groups` against what the user asked for. `system_generated_password` is `true` while the person is still on a generated password, whether or not they have signed in. `asks_for_new_password` says when SuiteCRM will ask them for a new one. Never test a sign-in yourself: ask the person to try.

## Tell the user

- For a new account: the login, how the password reaches the person (SuiteCRM's email, or the file in the Files pane that they hand over), and when SuiteCRM asks for a new password, in the words of `asks_for_new_password`. Ask them to have the person change it right after the first sign-in.
- For a role: what the person can and can't do now, in their words, and that it applies after they sign in again.
- For a new admin: that the person now has full control.
- For someone who left: that they can't sign in any more, how many records are still in their name, and where the mass update is.
- That a password file stays in the Files pane until it is removed, and that you remove it once they say it is handed over.

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Exit 64 with "nothing was changed" or "nothing was done" | The yes flag is missing: `--yes-send`, `--yes-reset`, `--yes-admin` or `--yes-change`. That is the preview | Go through the gate of that step, then run the command with its flag |
| users.sh exit 64 from `role-set` | The level does not go with the action. `import` and `massupdate` take only `all`, `none` or `default`. Nothing was changed | Use `none` to close the action |
| users.sh exit 2 | Refused: the main admin can't be deactivated or lose its admin rights, `invite` without email set up, or SuiteCRM did not keep the change | The message says which. For email, [configure-email](configure-email.md) or way B |
| users.sh exit 3 | No such user, role, group, or no such action for that module | Check the spelling against `list`, `role-list` or `group-list`. A module is named as in its address |
| users.sh exit 4, or temp-password.sh exit 4 with `--create` | The login, role or group exists already. Nothing was changed | Ask the user: another login, or a reset of the existing account (step 4) |
| temp-password.sh exit 4 without `--create` | There is no such user to reset | `users.sh list` shows the logins |
| users.sh exit 8 | The account was made, the invitation was not sent | Step 4 for a password, then [configure-email](configure-email.md) |
| Exit 65 | The login is longer than 60 characters, or the email address is not one | Ask the user for the right value |
| temp-password.sh exit 2 | SuiteCRM refused or did not confirm the password. The message says whether the file was kept | When the file was kept, check the account with `users.sh show`, then remove the file if it is not needed |
| temp-password.sh exit 3 | The private file could not be written. Nothing was changed in SuiteCRM | Tell the user. The agent's disk may be full |
| temp-password.sh exit 255 | SSH failed part of the way. The file was kept, because the password may be set | `users.sh show` first. Run it again only when the account is not there or the user agrees to a second reset, and remove the file that is not needed |
| Exit 75 | The image is installing or upgrading SuiteCRM, a restore was cut off, or the container waits. Nothing was changed | `upgrade-state.sh` says which. Wait ([failed-upgrade](failed-upgrade.md)), or finish the restore ([restore-from-backup](restore-from-backup.md)) |
