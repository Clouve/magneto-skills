# Users and roles

Three scripts cover the people who sign in. [users.sh](../scripts/users.sh) lists users and changes their state, roles and security groups. [temp-password.sh](../scripts/temp-password.sh) gives an account a temporary password in a private file. [restore-admin-password.sh](../scripts/restore-admin-password.sh) puts the main admin's password back. None of them takes, prints or logs a password.

The scripts act with full admin rights, whatever the role of the person asking. They can't tell who is typing. Treat every change here as an admin's decision. Each one waits behind a gate: say what it gives or takes away, and wait for a clear yes. Making an administrator, a password reset, an invitation and the site's password rule need a yes flag. The other changes have none and run at once: `deactivate`, `activate`, `set-admin <login> no`, `role-set`, `role-assign`, `role-unassign`, `group-add`, `group-remove` and a plain `temp-password.sh --create`. For those the gate is all there is.

## Users

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh list
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh show '<login>'
```

Each user comes back with `login`, `name`, `email`, `status` (Active or Inactive), `is_admin`, `system_generated_password`, `asks_for_new_password`, `roles` and `groups`. The main admin's login is in `SUITECRM_ADMIN_USER` and is usually an email address.

- `system_generated_password` is `true` while the account is still on a password that SuiteCRM or this skill made. It does not say whether the person has signed in.
- `asks_for_new_password` says when SuiteCRM will ask that person for a new password, by the site's rule: `at the first sign-in`, `7 days after the password was set` (or another number of days), `at sign-in number N with that password`, `never`, `never (the person chose this password)` or `never (this account signs in through LDAP or SAML)`.

## A first password, two ways

Both ways make an account that can sign in, so both wait for a yes.

The first way needs no email. It makes the account and a 20-character password, and saves the password to `~/suitecrm-passwords/<login>-<UTC time>.txt` on the agent, mode 600 in a folder of mode 700. The Files pane shows the file. The script prints two lines: the file's name, and when SuiteCRM asks for a new password on this site.

Gate. This command has no yes flag. Show the user the login, the name and the email address of the new account, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --create --last-name 'Scorpio' --first-name 'Hank' --email '<address>' '<new login>'
```

Tell the user to open the file in the Files pane and pass the password on by a channel they trust. When they say it is handed over, remove the file:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --remove '<password file>'
```

The second way has SuiteCRM make the password and send it in its own "New account information" email, so nobody else ever sees it. It needs working outgoing email ([email.md](email.md)). Without `--yes-send` the command changes nothing and exits 64.

Gate. This makes an account and sends a message. Show the user the login and the address the password goes to, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh invite '<new login>' --last-name 'Scorpio' --first-name 'Hank' --email '<address>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh invite '<new login>' --last-name 'Scorpio' --first-name 'Hank' --email '<address>' --yes-send
```

- `invite` is refused with 2 while no mail server is set. Exit 8 means the account exists and the email failed: nobody has the password, so give the account one with `temp-password.sh --yes-reset`, behind its gate.
- `--email` with `--create` only stores the address. No mail goes out.
- Exit 4: the login exists already. Nothing was changed.
- `--admin` on either command makes an administrator. It needs `--yes-admin` as well ([Admin rights](#admin-rights)).

## When SuiteCRM asks for a new password

A temporary or emailed password is not changed at the first sign-in by itself. SuiteCRM sends a person to its change-password page only when the site's rule for generated passwords says so. The rule is SuiteCRM's own setting: Admin > Password Management, "System-Generated Password Expiration". This prints it and reads only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule
```

- `asks_for_new_password` is the rule in words, `accounts_on_a_generated_password` lists the accounts it applies to now, and `setting` holds SuiteCRM's own values.
- A stock install says `7 days after the password was set`. In a test with that rule, the first sign-in with a temporary password went to SuiteCRM's welcome wizard, which has no password step, and SuiteCRM asked for nothing more. The temporary password stayed the person's working password until it was 7 days old. Then SuiteCRM asked for a new one.
- So a generated password is as good as the person's own for that week. Whoever saw the file or the email can sign in as them. Ask the person to change it under their profile right after they sign in, and remove the password file once it is handed over.
- `temp-password.sh` reads the rule and writes what is true for this site into its second output line and into the password file.
- A person who chose their own password is never asked, and neither is an account that signs in through LDAP or SAML.

The skill never changes the site's password rules by itself. `password-rule first-sign-in` sets the rule to the first sign-in. In a test, SuiteCRM then sent a person with a temporary password to the change-password page at their first sign-in. The change is for the whole site: everyone who is on a generated password now is asked at their next sign-in, and everyone who gets one later at their first. An admin changes it back under Admin > Password Management. Without `--yes-change` the command changes nothing and exits 64.

Gate. Say that this is one rule for the whole site, and name the accounts that `users.sh password-rule` lists. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule first-sign-in
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh password-rule first-sign-in --yes-change
```

The second form prints `changed`, the rule `before` and `after`, and SuiteCRM's values before and now (`setting_before`, `setting`).

## A forgotten password

A reset replaces the password of an existing user with a new temporary one, in a new file. The old password stops working at once and can't be brought back. Without `--yes-reset` the command changes nothing, says what it would do and exits 64.

Gate. Confirm the account with `users.sh show`, so that the reset reaches the right person, and check that someone can hand them the new password. Say that their current password stops working at once. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh '<login>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --yes-reset '<login>'
```

- The new password follows the site's rule like any generated one ([When SuiteCRM asks for a new password](#when-suitecrm-asks-for-a-new-password)).
- The file is written first and SuiteCRM is changed second, so no password is ever set that nobody saved. If SuiteCRM changes nothing, the script deletes the file again.
- If the outcome is unknown (the script crashed, the session dropped, or SuiteCRM did not confirm the password), the file is kept, because it may hold the only copy. The message says so. Run the reset again and remove the older file.
- It refuses two kinds of account with exit 2: the main admin, and an account that signs in through LDAP or SAML, for which SuiteCRM keeps no password.
- A reset does not end the sign-in throttle ([When someone can't sign in](#when-someone-cant-sign-in)).
- Never take a password from the chat and never suggest one. If a user types a password into the chat, don't use it and don't repeat it, and suggest they change it.

## How SuiteCRM keeps passwords

SuiteCRM stores a bcrypt hash of the lower-case md5 of the password, in `users.user_hash`. Only SuiteCRM's own code produces it. A hash from another tool, such as Symfony's `security:hash-password`, never matches, and a value written by hand locks the person out. SuiteCRM's own call also clears its older lockout counters for the account, marks a temporary password from temp-password.sh as a generated one (restore-admin-password.sh sets one the admin chose, which is not) and notes when it was set, which is what the site's rule counts from. It does not end the sign-in throttle, which SuiteCRM 8 keeps somewhere else ([When someone can't sign in](#when-someone-cant-sign-in)). So passwords change only through the two scripts, and `sql-read.sh` refuses to read the column.

## Deactivate, never delete

`deactivate` and `activate` have no yes flag. Each prints `was_status` and the account as it is now.

Gate. Confirm the person by name. For `deactivate`, say that they are signed out at once and can't sign in again. For `activate`, say that they get their access back as it was, with the password they had. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh deactivate '<login>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh activate '<login>'
```

- A deactivated account can't sign in, and a session it had open ends. Everything else stays: its records are still assigned to it, and the history still shows who created and changed what. `activate` undoes it completely.
- The skill never deletes a user. Records, assignments and the audit trail all point at the account, and a deleted account leaves them pointing at nobody.
- When someone leaves, their open work usually moves to a colleague. `records.sh list Opportunities --assigned '<login>'` shows what they hold, and `records.sh update` with `assigned_user_name` moves one record. For many records, the admin can change "Assigned to" with a mass update from the module's list in SuiteCRM.

## Admin rights

An admin sees and changes everything, settings and other users included, and can install code through Module Loader. Roles don't limit an admin. `set-admin <login> yes` needs `--yes-admin`: without it the command changes nothing and exits 64. `set-admin <login> no` has no flag. Both print `was_admin`.

Gate. For `yes`, say what an admin can do, and wait for a clear yes that names the person. For `no`, say who loses the admin pages and that their roles apply to them again, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' yes
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' yes --yes-admin
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh set-admin '<login>' no
```

A new account can start as an administrator. `--admin` needs `--yes-admin` on both commands, and `invite` needs `--yes-send` as well. Use it only when the admin asked for exactly that.

Gate. Say that the new account is an administrator from the start, with full control of SuiteCRM, and name the person. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/temp-password.sh --create --admin --yes-admin --last-name 'Scorpio' --first-name 'Hank' --email '<address>' '<new login>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh invite '<new login>' --last-name 'Scorpio' --first-name 'Hank' --email '<address>' --admin --yes-admin --yes-send
```

## The main admin

The main admin is the account made when SuiteCRM was installed: the login in `SUITECRM_ADMIN_USER`, or the user with id 1. Its password is the one the Clouve dashboard shows. The scripts protect it: it can't be deactivated, it can't lose its admin rights, and `temp-password.sh` won't reset it. There are three reasons.

- The dashboard's password is the customer's known way back in.
- The skill's own scripts act as this account. So "created by", "modified by" and the audit trail name the main admin for everything the assistant writes, and a record made without an owner belongs to it ([records.md](records.md)).
- In the Customer Kit, LimeSurvey signs in to SuiteCRM as this account with that password. A change stops survey responses from arriving, with no error anyone sees ([customer-kit.md](customer-kit.md)).

When the main admin is locked out, or someone changed its password, put the dashboard's password back. Without the flag the script changes nothing and says what it would do.

Gate. Say that the password goes back to the one on the Clouve dashboard, and that whoever knows the current one loses it. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh --yes-reset
```

It also makes the account active and an admin again, and the output says what it was (`was_status`, `was_admin`). It works when the admin was deactivated and the password was changed as well. It does not end the sign-in throttle ([When someone can't sign in](#when-someone-cant-sign-in)), and its `note` says so. SuiteCRM asks for no new password afterwards. The user signs in with the password from the Clouve dashboard.

## Roles

A role limits what its members may do, module by module. Someone without a role may do everything a regular user can, and a role's unset entries stay allowed. These read, or make a role that nobody is in yet:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-list
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-show '<role>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-create '<new role>'
```

`role-set` takes the role, the module as in its address (`Accounts`, `Contacts`, `Leads`, `Opportunities`, `Cases`), an action and a level. The actions are `access` (is the module there at all), `view` (open a record), `list` (see the list), `edit` (create and change), `delete`, `import`, `export` and `massupdate` (change many records from the list).

| Level | Goes with | What it means for a person in the role |
|---|---|---|
| `all` | Every action but `access` | They may do it on every record of the module |
| `group` | `view`, `list`, `edit`, `delete`, `export` | They may do it on records assigned to them, and on records in a security group they belong to |
| `owner` | `view`, `list`, `edit`, `delete`, `export` | They may do it only on records assigned to them |
| `none` | Every action but `access` | They may not do it at all |
| `enabled` | `access` | The module is open to them |
| `disabled` | `access` | The module is closed and hidden for them, whatever the other actions say |
| `default` | Any action | Clears the role's setting. The action falls back to SuiteCRM's default, which allows it |

SuiteCRM has no `owner` or `group` level for `import` and `massupdate`: they are allowed or closed for the whole module. `role-set` refuses such a level with exit 64.

Gate. `role-set` has no yes flag, and it changes the role for everyone in it. Show the user who is in the role (`role-show`) and the lines you are about to run, say what each takes away or opens, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts list owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts view owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts edit owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts delete owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts export owner
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts import none
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-set '<role>' Accounts massupdate none
```

Those seven lines are "she works only with her own accounts". All seven are needed:

- `list` and `view` alone hide records on screen but leave export and changes open. In a test with only those two, a person who owned no account saw an empty list, and SuiteCRM's own export still gave her every account. She could also edit or delete an account whose id she had.
- With `edit`, `delete` and `export` at `owner` as well, the export returned none of the other person's accounts.
- `import` has to be `none`. With import left open, SuiteCRM's importer in update mode, run as her, changed another person's account by its id.
- `massupdate none` closes bulk edits from the list. It also closes them for her own records, and `import none` stops her own imports. Say that to the user.

What `role-set` prints: `before` and `after` (the level it replaced and the new one), `users` (the people in the role) and `widens_access`. When the new level lets more through than the old one, `widens_access` is `true` and the `note` gives the command that puts it back. `default` opens, because an unset action is allowed.

Gate. `role-assign` and `role-unassign` have no yes flag. Say what the person gains or loses with the role, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-assign '<login>' '<role>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh role-unassign '<login>' '<role>'
```

- Both print the person's roles before and after (`roles_before`, `roles_after`).
- `role-show` lists only what the role sets. A module or action that is not listed is allowed.
- People in the role see a change after they sign in again.
- With several roles, SuiteCRM's stock setting takes the more generous level for each action ("Additive Rights", read in SuiteCRM's code). An admin can change that under Admin > Security Suite Settings.
- Exit 3: no such role, or SuiteCRM has no such action for that module. Exit 4: the role exists already.

## Security groups

A security group is a set of people, and a record can belong to groups. Groups matter only together with the `group` level: a role that sets Opportunities `view` to `group` lets its members open the opportunities assigned to them and those in a group they are in. Listing the groups reads only, and a new group has nobody in it:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-list
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-create '<new group>'
```

Gate. `group-add` and `group-remove` have no yes flag. Say which group it is and which records the person gains or loses with it, and wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-add '<login>' '<group>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh group-remove '<login>' '<group>'
```

- Both print the person's groups before and after (`groups_before`, `groups_after`).
- With SuiteCRM's stock settings a new record joins the groups of the person who creates it and of the person it is assigned to (read in SuiteCRM's code, not tested through the scripts). Existing records join no group by themselves.
- The skill has no command that puts a record into a group or ties a role to a group. The admin does both in SuiteCRM: a record's Security Groups panel, and Admin > Security Suite Group Management.
- A group changes nothing for people whose role says `all`, and nothing for admins.

## When someone can't sign in

SuiteCRM answers a wrong password and a deactivated account in the same words: the page says "Login credentials incorrect, please try again." Its sign-in page stops accepting tries after 5 failures within 30 minutes for one login from one network address, or 50 from one network address whatever the login. The page then says "Too many failed login attempts, please try again later.", and it refuses the right password too.

Start with `users.sh show`, and ask what the page says. An Inactive account needs `activate`. For an Active account whose owner is unsure of the password, use `temp-password.sh --yes-reset`. Both wait behind their gate. If the page names too many attempts, or the person is sure of the password and was refused several times, it is the throttle. It ends by itself after 30 minutes, and from another network, such as a phone off the Wi-Fi, the same login signs in at once. Neither a new password nor `restore-admin-password.sh` ends it (both tested).

No script ends the throttle for one login. The counters are in SuiteCRM's cache. So `repair.sh`, its dry run included, and `console.sh cache:clear` wipe them as a side effect, for every login and every address at once. In a test on Clouve's image, a login that was refused signed in a few seconds after either one. Someone who was guessing passwords gets a fresh count as well. Don't run them to end a throttle. Waiting and the other network are the way out, and say this side effect when you run a repair for another reason while someone is locked out.

## Exit codes

| Code | users.sh | temp-password.sh | restore-admin-password.sh |
|---|---|---|---|
| 0 | Done | Done | Done |
| 64 | Usage, a yes flag is missing (`--yes-send`, `--yes-admin`, `--yes-change`), or a level that does not go with the action | Usage, `--yes-reset` or `--yes-admin` is missing, or `--remove` of something that is not a password file | Usage, or no `--yes-reset` |
| 65 | Bad input | | |
| 1 | | A setting or tool is missing | A setting or the password is missing |
| 2 | Refused (the main admin, an outside sign-in, no email set up), or SuiteCRM did not keep the change | SuiteCRM refused or did not confirm, or the reset was refused | SuiteCRM did not keep the password, or did not keep the account active and an admin |
| 3 | No such user, role, group or action | The file could not be written. Nothing was changed | The main admin could not be found |
| 4 | It exists already | The user exists already (`--create`), or doesn't exist | |
| 8 | Invited, but the email was not sent | | |
| 70, 75, 255 | See [shell-access.md](shell-access.md#exit-codes-the-scripts-share) | The same | The same |
