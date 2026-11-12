# Playbook: Rotate the admin password (or any user's password)

Use this when the tenant has lost or wants to rotate the WordPress admin password, or wants to force a reset for a specific account. [scripts/temp-password.sh](../scripts/temp-password.sh) makes the change. It makes a strong temporary password, saves it to a private file in the agent user's home, hands it to WordPress on stdin, checks that WordPress took it, and prints only the file's name. On Shape A it changes the password with wp-cli over the shell (Step 2). With no shell (Shape B, or a failed probe), `--via-db` writes an MD5 value to `wp_users.user_pass` over **[TCP-mysql]**, which WordPress accepts and re-hashes at the next sign-in (Step 2, fallback).

The new password never goes into the chat, onto a command line or into a shell variable. A variable wouldn't last anyway, since each of your Bash calls starts a new shell. And wp-cli prints a password it reads on its standard input back to its standard output, so a `wp user update` you type yourself shows the password in the chat. Use the script.

## The gate (do not skip)

This is the **"reset a user password / rotate admin credentials"** gate from [SKILL.md → Safety gates](../SKILL.md):

- **Confirm the target username** and that the person asking is entitled to it.
- **Confirm the account's owner can be reached outside the chat.** The admin hands the new password over by phone, secure message or a password manager, never in chat.
- **User ack** on the exact command you are about to run.
- Know that **platform-injected `WORDPRESS_ADMIN_*` env vars will NOT reflect a manual change** (see the caveat below). After this rotation `wp_users` is the source of truth, and the env var stays stale.

## Preconditions

- [ ] User acknowledged the rotation **logs the affected account out of every active session** (WordPress auth cookies embed a fragment of the stored password hash, so changing `user_pass` invalidates them all).
- [ ] Someone can pass the new password on outside the chat: the admin reads it from the file the script saves and gives it to the person, who changes it after signing in.
- [ ] If rotating the primary admin: user has confirmed there is no other admin to fall back on, OR has otherwise proven identity.
- [ ] You know the deployment shape and whether a shell exists ([../reference/shell-access.md](../reference/shell-access.md)).

## Step 1: Confirm the target user [TCP-mysql]

This doubles as the gate's identity check and as the "one row, then act" confirmation for a targeted write to a crown-jewel table.

```bash
compgen -e | grep -iE 'wordpress|mysql|maria|host'   # names only: the DB variables and the sibling host
clv-secret --list | grep -iE 'wordpress|mysql|maria|host'   # the passwords' names

MYSQL_PWD="${WORDPRESS_DB_PASSWORD:-$(clv-secret WORDPRESS_DB_PASSWORD)}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -e \
  "SELECT ID, user_login, user_email, user_registered, LEFT(user_pass,4) AS hash_prefix
   FROM wp_users WHERE user_login = '<the-login>' OR user_email = '<the-email>';"
```

Expect **exactly one** row. Note the `hash_prefix`: `\$P\$` is phpass, `\$2y\$` (or `\$wp\$`) is bcrypt on 6.8+, and either is a normally hashed password. The schema does not enforce email uniqueness (duplicates can exist from imports or direct DB writes), so if two rows match on email, stop and settle on the `user_login` with the user. The script goes by `user_login` alone and refuses a login that more than one account has.

If the account authenticates via SSO or an external identity plugin, `user_pass` is not consulted at login. Resetting it does nothing, and the reset has to happen at the identity provider: say so instead of running the script.

## Step 2 (preferred): `wp user update` over the shell [shell-only — probe first]

Only if the `clouve-ops` probe from [../reference/shell-access.md](../reference/shell-access.md) succeeds. Show the user this command and wait for the ack:

```bash
/clouve/skills/wordpress/plugin/skills/wordpress/scripts/temp-password.sh -- '<the-login>'
```

The script looks the account up by its login and changes it by its ID, as `www-data`, with `wp user update <ID>` and WordPress's own database settings, the way [wp.sh](../scripts/wp.sh) runs wp. The password goes on wp's standard input, and wp's output is thrown away inside the WordPress container. WordPress hashes the password its normal way and logs the change, and if the site can send mail it emails the account's owner that the password changed. No `wp-content` files are touched.

It prints one line, for example:

```
Saved the temporary password for user ID 1 to wordpress-passwords/1-20261102-221530.txt in the Files pane. WordPress accepted it at sign-in.
```

The file is `~/wordpress-passwords/<user ID>-<UTC time>.txt`, mode 600. Its name and the line give the account's ID, not the login, which is often an email address; the login is inside the file, for the hand-over. Never open, print or copy it yourself. If the script exits 2, read its message. When nothing changed it has deleted the file again; when the password may be set it keeps the file and says so. If it says the shell or wp-cli failed and nothing changed, use the fallback below.

## Step 2 (fallback): MD5 straight into the DB [TCP-mysql]

This is the live path when there is no shell. WordPress recognizes a bare 32-hex-character value (no `\$P\$` / `\$2y\$` prefix) in `user_pass` as a legacy MD5 hash, accepts it at login, and **re-hashes it to the site's current scheme (phpass, or bcrypt on 6.8+) on the next successful login.** It is the documented no-shell reset. Show the user the command and wait for the ack:

```bash
/clouve/skills/wordpress/plugin/skills/wordpress/scripts/temp-password.sh --via-db -- '<the-login>'
```

The script sends `UPDATE wp_users SET user_pass = MD5('<the password>') WHERE ID = <ID>` to mysql on its standard input, so the password is in no process's arguments, and prints the same one line. Its sign-in check signs in once with the new password. When the line says WordPress accepted it, WordPress replaced the MD5 value with its normal hash at that sign-in.

Notes and honest caveats:

- If the line says "Couldn't confirm the sign-in", the stored value may still be an **unsalted MD5** until the person's first sign-in, which is weaker than the site's normal hashing. That is acceptable for a short while. Have the user sign in and change the password promptly. The script makes a new password on every run, so no temp password is ever shared between accounts.
- This does not set a "must change password" flag (WordPress core has nothing like Moodle's). Tell the user they should change it after signing in.
- The write invalidates the account's existing auth cookies, so that account is logged out everywhere, as intended.

## Step 3: Verify [TCP-mysql] + [HTTP]

The script has already read the account back (it compares a digest of the stored hash from before and after the change) and tried the new password at `wp-login.php`. "WordPress accepted it at sign-in" means WordPress signed the account in with the new password: it set its sign-in cookie and sent the account on to wp-admin, or first to the admin email check it shows an administrator every six months. The script reads that answer without printing it, since the cookie is a live session.

To see the stored value's prefix yourself:

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD:-$(clv-secret WORDPRESS_DB_PASSWORD)}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT user_login, LEFT(user_pass,4) FROM wp_users WHERE user_login='<the-login>';"
```

If the line says "Couldn't confirm the sign-in", that isn't proof of failure. The check signs in at the WordPress container itself, over plain HTTP inside the cluster, so the password never leaves it. When `WORDPRESS_SITE_URL` is https, the request says it came over HTTPS (`X-Forwarded-Proto: https`) and names the site's own host (`Host`), as the site's ingress does with every request, so WordPress checks the password instead of redirecting first. The connection still goes to the container, and the check follows no redirect. An HTTP `200` means the login form came back: WordPress, or a security plugin in front of it, can turn down a sign-in that a script makes. A redirect without a sign-in comes from a plugin that hides `wp-login.php`, or from `FORCE_SSL_ADMIN` when the check couldn't say it came over HTTPS (`WORDPRESS_SITE_URL` isn't https here) or the site's `wp-config.php` ignores that header: both redirect before WordPress checks the password, and the line names the `FORCE_SSL_ADMIN` case that fits. When there was no answer, the line says why: the WordPress host doesn't resolve from the agent, the connection was refused, or it timed out. The line itself means the stored password changed, so have the user try the new one in a private browser window before you conclude it failed.

## Step 4: Hand off outside the chat

In the chat, say only where the password is: "The temporary password for user ID <ID> is in `wordpress-passwords/<file>` in the Files pane." Then the admin, not you:

- passes the password on by voice, secure message or a password manager entry, never by chat or plain email;
- tells the person to change it after they sign in;
- tells them the account's other sessions were ended, so they'll need to sign in again.

Once the admin says it's handed over, delete the file:

```bash
/clouve/skills/wordpress/plugin/skills/wordpress/scripts/temp-password.sh --remove '<file name>'
```

It prints `Deleted wordpress-passwords/<file>.` and deletes only a `.txt` file inside that folder, with `shred -u` where it can.

## The `WORDPRESS_ADMIN_*` env caveat (why this rotation sticks)

On the Clouve-packaged shape the installer consumes `WORDPRESS_ADMIN_USER/EMAIL/PASSWORD` **once**, at the fresh-install boot, and never re-applies them (unlike `siteurl`/`home`, which are re-asserted every boot; see [../reference/architecture.md](../reference/architecture.md)). So:

- Your rotated password **persists** across pod restarts. The entrypoint will not overwrite it.
- `WORDPRESS_ADMIN_PASSWORD` stays frozen at the platform's original generated value and no longer reflects reality. Never read it back to the user as "your password," and never assume it still works. `wp_users` is the source of truth.

## What NOT to do

- Don't write the new password into chat, logs or a command line, and don't keep it in a shell variable. The script makes it, saves it to the private file and feeds it on stdin. Never prompt for it with `read -rs`, which captures an empty string in a non-interactive shell.
- Don't type the `wp user update` command yourself: wp-cli prints the password it reads back to its output, and that output lands in the chat.
- Don't open, `cat` or copy the password file. The admin reads it in the Files pane.
- Don't `UPDATE wp_users SET user_login = …` to "rename" an admin. It desynchronizes `wp_usermeta` and post and comment authorship. Create a new admin in `/wp-admin`, reassign, then delete the old one.
- Don't skip the identity confirmation because the request "sounds" legitimate. The gate is the point.
- Don't touch any other `wp_users` column in the same statement. A password reset is a single-column, single-row write.
