# Playbook: Rotate the admin password (or any user's password)

Use this when the tenant has lost or wants to rotate the WordPress admin password, or wants to force a reset for a specific account. There is a live path for this even with **no shell**: WordPress accepts a password written straight to `wp_users.user_pass` over **[TCP-mysql]** and self-upgrades the hash on next login. The `wp-cli` path is cleaner but needs a shell you probably don't have today.

## The gate (do not skip)

This is the **"reset a user password / rotate admin credentials"** gate from [SKILL.md → Safety gates](../SKILL.md):

- **Confirm the target username** and that the person asking is entitled to it.
- **Confirm the user is contactable out-of-band** — you will hand the new password back by phone / secure message / password manager, never in chat.
- **User ack** on the exact statement you are about to run.
- Know that **platform-injected `WORDPRESS_ADMIN_*` env vars will NOT reflect a manual change** (see the caveat below), so this rotation is the new source of truth — the env var stays stale.

## Preconditions

- [ ] User acknowledged the rotation **logs the affected account out of every active session** (WordPress auth cookies embed a fragment of the stored password hash, so changing `user_pass` invalidates them all).
- [ ] You have an out-of-band channel to deliver the new password. Prefer "set a temporary strong password, tell the user to change it after they log in."
- [ ] If rotating the primary admin: user has confirmed there is no other admin to fall back on, OR has otherwise proven identity.
- [ ] You know the deployment shape and whether a shell exists ([../reference/shell-access.md](../reference/shell-access.md)).

## Step 1 — Confirm the target user — [TCP-mysql]

This doubles as the gate's identity check and as the "one row, then act" confirmation for a targeted write to a crown-jewel table.

```bash
env | grep -iE 'wordpress|mysql|maria|host'   # discover DB creds/host first

MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -e \
  "SELECT ID, user_login, user_email, user_registered, LEFT(user_pass,4) AS hash_prefix
   FROM wp_users WHERE user_login = '<the-login>' OR user_email = '<the-email>';"
```

Expect **exactly one** row. Note the `hash_prefix`: `\$P\$` is phpass, `\$2y\$` (or `\$wp\$`) is bcrypt on 6.8+ — either is a normally-hashed password. The schema does not enforce email uniqueness (duplicates can exist from imports or direct DB writes), so if two rows match on email, stop and disambiguate by `user_login`.

If the account authenticates via SSO / an external identity plugin, `user_pass` is not consulted at login — resetting it does nothing and the reset must happen at the identity provider. Surface that instead of writing a hash.

## Step 2 (preferred) — `wp user update`, when you have a shell — [shell-only — probe first]

Only if the `clouve-ops` probe from [../reference/shell-access.md](../reference/shell-access.md) succeeds. **Generate** the temp password — never prompt for it (`read -rs` captures an empty string in a non-interactive shell, silently setting an empty password):

```bash
NEWPASS=$(openssl rand -hex 16)   # hex is quote-safe and stays out of shell history
[[ -n "$NEWPASS" ]] || { echo "no password captured — aborting, nothing written"; exit 1; }
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new "clouve-ops@${WORDPRESS_HOST}" \
  "wp --path=/var/www/html user update '<the-login>' --user_pass=\"$NEWPASS\" --allow-root"
```

Keep `NEWPASS` set — Step 3's verify probe uses it; unset it only after the out-of-band handoff (Step 4).

`wp user update` writes `user_pass` (correctly hashed) and logs the change. It is a pure database operation — no `wp-content` files are touched, so the `--allow-root` ownership fallout that bites plugin installs does **not** apply here. Note the password is briefly visible in the remote process table for the duration of the call; that is unavoidable over SSH — never also put it in a file or in chat.

## Step 2 (fallback) — MD5 hash straight into the DB — [TCP-mysql]

This is the live path when there is no shell. WordPress recognizes a bare 32-hex-character value (no `\$P\$` / `\$2y\$` prefix) in `user_pass` as a legacy MD5 hash, accepts it at login, and **transparently re-hashes it to the site's current scheme (phpass, or bcrypt on 6.8+) on the next successful login.** It is the documented no-shell reset.

**Gate reminder:** print the exact statement, get the user's ack, and confirm Step 1 returned exactly one matching row before running it. **Generate** the temp password — never prompt for it (`read -rs` captures an empty string in a non-interactive shell, and the heredoc would then silently execute `MD5('')`, locking the account out). Feed it over stdin (a heredoc), never via `-e "…MD5('…')…"`, so the plaintext stays out of the process arguments:

```bash
NEWPASS=$(openssl rand -hex 16)   # hex contains no quotes, so it is safe inside the SQL literal
[[ -n "$NEWPASS" ]] || { echo "no password captured — aborting, nothing written"; exit 1; }
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" <<SQL
UPDATE wp_users SET user_pass = MD5('${NEWPASS}')
WHERE user_login = '<the-login>';
SQL
```

Keep `NEWPASS` set — Step 3's verify probe uses it; unset it only after the out-of-band handoff (Step 4).

Notes and honest caveats:

- Until the user logs in once, the stored value is an **unsalted MD5** — weaker than the site's normal hashing. It is acceptable transiently; the first login upgrades it. Have the user log in (and ideally change the password) promptly, and never reuse a temp password across accounts.
- This does not set a "must change password" flag (WordPress core has none equivalent to Moodle's). Communicate verbally that they should change it after logging in.
- The write invalidates the account's existing auth cookies — that account is logged out everywhere, as intended.

## Step 3 — Verify — [TCP-mysql] + [HTTP]

**Confirm the write landed** (the hash prefix reflects what you wrote — 32 hex, no prefix, until first login):

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT user_login, LEFT(user_pass,4) FROM wp_users WHERE user_login='<the-login>';"
```

**Login probe** — prove the new password actually authenticates, without leaking it. WordPress rejects logins when the test cookie is absent, so send one:

```bash
[[ -n "$NEWPASS" ]] || { echo "no password captured — aborting, nothing verified"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -b "wordpress_test_cookie=WP Cookie check" \
  --data-urlencode "log=<the-login>" \
  --data-urlencode "pwd=${NEWPASS}" \
  --data-urlencode "wp-submit=Log In" \
  --data-urlencode "testcookie=1" \
  "http://${WORDPRESS_HOST}/wp-login.php")
echo "login status: ${code}"   # 302 ⇒ success (redirect to wp-admin). 200 ⇒ credentials rejected / cookie issue.
```

A `302` (redirect toward `/wp-admin/`) means the credentials were accepted. A `200` means the login form re-rendered — either the password is wrong or, occasionally, the internal host rejected the cookie/Host; if the DB write clearly succeeded, have the user confirm login in a real browser before you conclude failure.

## Step 4 — Hand off out-of-band

Tell the user, **not in chat**:

- The generated temporary password (voice / secure message / password manager entry).
- That they should change it themselves after logging in.
- That the account's other sessions were ended and they'll need to sign in again.

Once the handoff is done, `unset NEWPASS`.

## The `WORDPRESS_ADMIN_*` env caveat (why this rotation sticks)

On the Clouve-packaged shape the installer consumes `WORDPRESS_ADMIN_USER/EMAIL/PASSWORD` **once**, at the fresh-install boot, and never re-applies them (unlike `siteurl`/`home`, which are re-asserted every boot — [../reference/architecture.md](../reference/architecture.md)). So:

- Your rotated password **persists** across pod restarts — the entrypoint will not overwrite it.
- `WORDPRESS_ADMIN_PASSWORD` remains frozen at the platform's original generated value and no longer reflects reality. Never read it back to the user as "your password," and never assume it still works. `wp_users` is the source of truth.

## What NOT to do

- Don't write the new password into chat, logs, a file, or `mysql -e "…"` argv. Generate it (`openssl rand -hex 16`) and feed it via stdin/heredoc every time — never prompt with `read -rs`, which captures an empty string in a non-interactive shell.
- Don't `UPDATE wp_users SET user_login = …` to "rename" an admin — it desynchronizes `wp_usermeta`, post and comment authorship. Create a new admin in `/wp-admin`, reassign, delete the old one.
- Don't skip the identity confirmation because the request "sounds" legitimate. The gate is the point.
- Don't touch any other `wp_users` column in the same statement — a password reset is a single-column, single-row write.
