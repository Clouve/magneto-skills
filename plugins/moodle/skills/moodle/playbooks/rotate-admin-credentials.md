# Playbook: Rotate the admin password (or any user's password)

Use this playbook when the tenant has lost or wants to rotate the primary admin password, or when forcing a password reset for a specific user account.

## Preconditions

- [ ] User has acknowledged that the rotation ends the account's Moodle sessions: the person signs in again.
- [ ] You have a way to communicate the new password back to the user **out-of-band** (not in chat). The user should set the password themselves on the next login. The right pattern is "set a temporary password and force a password change on first login."
- [ ] If rotating the primary admin (uid=2): user has confirmed there's no other admin available, OR they've already proven their identity to you in a way that justifies it.

## Steps

### 1. Confirm the target user

```sql
SELECT id, username, email, auth, deleted, suspended, FROM_UNIXTIME(lastlogin) AS last
FROM mdl_user
WHERE username = '<the username>'
   OR email = '<the email>';
```

There should be exactly one row, `deleted = 0`, `suspended = 0`. If there are two users with the same email, surface to the user — Moodle allows non-unique emails by default but the password reset flow is ambiguous. Note `auth`: `manual`, `email` and the Education Kit's synced `db` accounts get their password here; an SSO account doesn't (see below).

### 2. Set a temporary password with scripts/temp-password.sh

```bash
/clouve/skills/moodle/plugin/skills/moodle/scripts/temp-password.sh -- '<the username>'
```

The script makes a strong password, saves it to a private file, and only then changes Moodle. It asks Moodle for the account first, by its username, then sets the password by the account's id in the moodle container, as `www-data`, with the password on PHP's stdin. The password is never printed and never on a command line, here or in the container. It does what Moodle's own profile page does when an admin types a new password: the account's sign-in plugin sets it (Moodle records `\core\event\user_password_updated`), the External Database sync's `create_password` preference is cleared, so Moodle's "Send new user passwords" task doesn't replace it within five minutes, a new password is required at the next sign-in, and the account's sessions end. Then it checks the password against the stored hash.

It prints one line, for example:

```
Saved the temporary password for Moodle user id 42 to moodle-passwords/42-20261111-181530.txt in the Files pane. Moodle took it (checked against the stored hash) and asks for a new password at the first sign-in.
```

The file is `~/moodle-passwords/<user id>-<UTC time>.txt`, mode 600, in a folder of mode 700. Its name and the line give the account's id, not the username, which is often an email address; the username is inside the file, for the hand-over. Never open, print or copy the file yourself. The line also says when the account is suspended, locked after failed sign-ins, or uses a sign-in method that is turned off.

If the script exits 2, read its message. When Moodle changed nothing (no such account, an SSO account, or the site's password policy refused the password), it has deleted the file again. When the password may be set, it keeps the file and says so.

Why not `admin/cli/reset_password.php`: on Moodle 5.3 it finds only `auth = 'manual'` accounts, and it writes the hash straight into `mdl_user`. It records no event, ends no session, clears no `create_password` and asks for no new password at the next sign-in. Its `--password=` option puts the password on the moodle container's command line, where `ps` shows it.

### 3. Verify the forced change

The script sets the `auth_forcepasswordchange` preference. To see it:

```sql
SELECT u.username, p.name, p.value
FROM mdl_user u
JOIN mdl_user_preferences p ON p.userid = u.id
WHERE u.username = '<the username>'
  AND p.name = 'auth_forcepasswordchange';
```

Should show `value = '1'`. The admin UI shows the same: Site administration → Users → Accounts → Browse list of users → the user → Edit → "Force password change".

### 4. Hand off outside the chat

In the chat, say only where the password is: "The temporary password for Moodle user id <id> is in `moodle-passwords/<file>` in the Files pane." Then the admin, not you:

- passes the password on by voice, secure message or a password manager entry, never by chat or plain email;
- tells the person that Moodle asks for a new password at the first sign-in;
- tells them their other sessions were ended.

Once the admin says it's handed over, delete the file:

```bash
/clouve/skills/moodle/plugin/skills/moodle/scripts/temp-password.sh --remove '<file name>'
```

It prints `Deleted moodle-passwords/<file>.` and deletes only a `.txt` file inside that folder, with `shred -u` where it can.

### 5. Audit log

Moodle records the change in `mdl_logstore_standard_log`, with the account in `relateduserid`:

```sql
SELECT FROM_UNIXTIME(timecreated), action, target, userid, relateduserid, ip
FROM mdl_logstore_standard_log
WHERE eventname = '\\core\\event\\user_password_updated'
  AND relateduserid = (SELECT id FROM mdl_user WHERE username='<the username>')
ORDER BY timecreated DESC LIMIT 5;
```

This is your evidence the rotation happened.

## Special case: the primary admin (uid=2) is the only admin

If the tenant has lost the only admin credential, you can also create a NEW admin via direct SQL (last resort) — but the cleaner path is `scripts/temp-password.sh` for the existing primary admin.

If for some reason the primary admin user is broken (e.g. `deleted = 1` somehow):

1. Surface to the user — this is unusual and worth understanding why.
2. Take a backup before doing anything.
3. To un-delete: `UPDATE mdl_user SET deleted = 0 WHERE id = 2;` — but Moodle's "soft delete" sets `username` to a placeholder; you may also need to reset `username` and `email`. Use Moodle UI's bulk-actions "Restore deleted user" if available.

This is not a fast workflow — accept the time cost and stay cautious.

## Special case: SSO-managed accounts

If the user is authenticated via SSO (`auth_oauth2`, `auth_shibboleth`, LDAP, etc.), `mdl_user.password` is not used. Resetting it does nothing — the user authenticates against the IdP, not Moodle's local DB. `scripts/temp-password.sh` refuses such an account and names its sign-in method.

```sql
SELECT username, auth FROM mdl_user WHERE username = '<the username>';
```

If `auth` is anything other than `manual`, `email` or the Education Kit's `db` (whose passwords Moodle keeps), the password reset has to happen at the IdP, not in Moodle. Surface this to the user.

## What NOT to do

- Don't `UPDATE mdl_user SET password = MD5('newpass')` or any hash you made. Moodle 5.3 stores a salted SHA-512 crypt hash and can add a site pepper; a hand-made hash skips the pepper, the event and the forced change.
- Don't pass a password to `admin/cli/reset_password.php` with `--password=`: it lands on the moodle container's command line, where `ps` shows it.
- Don't type or keep a password in a shell variable (`read -s` and the like): your next Bash call doesn't have it, and the script's file is the hand-over.
- Don't reuse the same temp password across multiple users.
- Don't write the new password to chat. Even ephemeral chat content can be screenshotted and shared.
- Don't bypass the `auth_forcepasswordchange` preference — making the user change immediately is a hard requirement for "you reset their password" flows.
