# Regain admin access

This playbook gets the admin back into LimeSurvey when they can't sign in. It checks the usual causes in order, from the harmless one to the reset.

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs. No password is shown or asked for at any step ([SKILL.md](../SKILL.md#operating-principles-they-apply-to-every-task-reads-included), principle 4).

## When to use

- "I can't log in." "It says my password is wrong." "The login page shows an error."
- Not when the site itself is down: do [diagnose-problems](diagnose-problems.md) first.

## Steps

### 1. Check that the site is up and which account it is

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh list
```

The list shows the main admin's login and whether an account is switched off or has expired. Ask the admin which login they type. A common cause is the login itself: it is the one in the list, which is not always their email address.

### 2. "The requested hostname is invalid" (HTTP 400)

That is not a password problem. LimeSurvey answers 400 on its admin pages for an address it does not know. The admin has to use the site's public address, which is the `LIMESURVEY_PUBLIC_URL` setting:

```bash
printf '%s\n' "${LIMESURVEY_PUBLIC_URL}"
```

If they use that address and still get 400, see [reference/troubleshooting.md](../reference/troubleshooting.md).

### 3. Too many wrong passwords

After three wrong passwords LimeSurvey refuses sign-ins from the address the attempts came from, for ten minutes. It counts by the address the request arrives from. Behind Clouve's ingress that can be one address for every visitor, so the lockout may not be the admin's own doing: three wrong passwords by anyone can lock every admin out for those minutes. Clearing the record lets everyone try again at once, and removes nothing else:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh clear-lockouts
```

### 4. An account that is switched off

Look at the account first. An account can be off because someone switched it off on purpose, for a person who left:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh show '<login>'
```

Gate: say that this gives the account's access back, with every right it had, and ask whether it was switched off on purpose. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh activate '<login>'
```

### 5. Reset the main admin's password to the dashboard's

When the main admin has lost their password, put it back to the one the Clouve dashboard shows for this deployment. That is the password the account had at the first install.

Gate: say that the main admin's password will be the one on the Clouve dashboard again, and that their open sessions are signed out. Wait for a yes.

```bash
printf '%s\n' "${LIMESURVEY_ADMIN_PASSWORD:-$(clv-secret LIMESURVEY_ADMIN_PASSWORD)}" | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/admin-users.sh set-password "${LIMESURVEY_ADMIN_USER}"
```

The password goes from the agent's secret store to LimeSurvey on stdin. It is never printed and never on a command line. Tell the admin to sign in with the password from the Clouve dashboard and to change it afterwards.

When `LIMESURVEY_ADMIN_USER` is not the login in the list (the admin renamed the account), use the login from the list in its place.

### 6. Another admin's password

For anyone but the main admin, make a temporary password in a private file. Confirm the account with `admin-users.sh show` first, as in step 4.

Gate: name the account, and say that the person is signed out everywhere and can't sign in until the new password reaches them. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/temp-password.sh '<login>'
```

### 7. A lost second step

When the two-step sign-in is on (LimeSurvey's plugin TwoFactorAdminLogin) and an admin has lost their phone or their codes, another superadmin resets their second step in LimeSurvey's user management. A site with one superadmin has nobody to do that. The way in is then to switch the plugin off, which takes the second step away from every account until an admin switches it on again and each person sets it up anew.

Gate: say exactly that, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugin-deactivate TwoFactorAdminLogin
```

## Verify

Ask the admin to sign in. You can't test their sign-in for them: that would mean handling their password.

## Tell the user

Say what was wrong and what you changed. If you reset the password, say which password is valid now and where to find it, without repeating it.
