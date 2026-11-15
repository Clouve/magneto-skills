# Accounts and permissions

LimeSurvey's admin accounts are the people who make and run surveys. The people who answer surveys have no account: they are participants ([participants-and-email.md](participants-and-email.md)).

## The main admin

The image makes one account at the first install, with the name, address and password the customer gave on the Clouve dashboard: `LIMESURVEY_ADMIN_USER`, `LIMESURVEY_ADMIN_EMAIL`, and the password named `LIMESURVEY_ADMIN_PASSWORD`. It has the superadmin permission. This skill's calls run as the site's main admin, which is the first active account with that permission, so:

- the scripts never take the superadmin permission from it and never switch it off;
- temp-password.sh does not reset its password. The way back in is the dashboard's password ([playbooks/regain-admin-access.md](../playbooks/regain-admin-access.md)).

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh list
```

## Site-wide permissions

| Permission | What it gives | Script |
|---|---|---|
| Superadmin | Everything: every survey, every answer, every setting, every account | `admin-users.sh grant <login> --superadmin` |
| Create surveys | Making one's own surveys, with every right on those | `admin-users.sh grant <login> --create-surveys` |
| Password sign-in | Signing in with a password. temp-password.sh gives it to every account it makes. | |

LimeSurvey has more site-wide permissions (user management, themes, label sets, global settings, the central participant database). The admin sets those in LimeSurvey's user management when they need them.

## Roles on one survey

An account without the superadmin permission sees only the surveys it owns or was given rights on. `admin-users.sh grant <login> --survey <id> --role <role>` sets these, replacing what the account had on that survey:

| Role | LimeSurvey's permissions |
|---|---|
| `results` | Responses: read, export. Statistics: read. |
| `editor` | Survey content: all. Survey texts and settings: read, update. Translations: read, update. Quotas and assessments: create, read, update, delete. |
| `full` | Every survey permission, as the owner has. That includes activation, the participant list, the answers, and who else may work on the survey. |
| `none` | Nothing: the survey disappears from the account's list. |

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh show '<login>'
```

It lists the account's permissions on each survey and the surveys it owns.

## Passwords

- temp-password.sh makes a 20-character password, saves it in a private file in the Files pane and never prints it. LimeSurvey stores only a hash.
- LimeSurvey's own rules for passwords (the PasswordRequirement plugin, on by default) apply to passwords people set themselves. A generated one passes them.
- `console.php resetpassword` takes the new password as an argument, where the container's process list shows it, and applies no rules. This skill does not run it.
- Setting a password signs the account's open sessions out, so a reset locks the person out until the new password reaches them.
- The person changes their password under their name at the top right, then "Account".

## Lockouts

After three wrong passwords LimeSurvey refuses sign-ins from that address for ten minutes. It counts by the address a request arrives from (read in the source: `application/helpers/common_helper.php`). Behind Clouve's ingress that can be the same address for every visitor, so a lockout may hit every admin at once, and may not be the doing of the person who reports it. This was not tested behind an ingress. `admin-users.sh clear-lockouts` removes the record.

## Switching an account off

`admin-users.sh deactivate <login>` stops the account from signing in and deletes nothing. Its surveys stay, owned by it. Deleting an account is the admin's to do in LimeSurvey's user management, where LimeSurvey asks who takes over the surveys.

## Two-step sign-in

LimeSurvey ships a core plugin for it (TwoFactorAdminLogin), off by default. The admin switches it on in the plugin manager, and each person then sets it up for themselves. An admin who has lost their second step needs it reset in LimeSurvey by another superadmin. A site with one superadmin has nobody for that: [playbooks/regain-admin-access.md](../playbooks/regain-admin-access.md) switches the plugin off then, after a yes, which takes the second step away from every account.

Tested on 7.10.0.
