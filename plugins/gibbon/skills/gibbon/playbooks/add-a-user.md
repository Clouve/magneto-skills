# Playbook: Add a user

Use when the admin asks you to add someone to Gibbon: a teacher or other staff member, a student, or a parent.

Gibbon's own form is the way to do it. A new `gibbonPerson` row has about 50 columns with no default ([reference/data-model.md](../reference/data-model.md)), and the form fills them all the way Gibbon expects. It also hashes the password the way Gibbon checks it at sign-in ([reference/security.md](../reference/security.md)). A hand-written insert gets one of those details wrong sooner or later, and then the person can't sign in or a Gibbon page breaks on the row. So the admin adds the person in Gibbon, and you get things ready and check the result.

This playbook has no SQL path: never create a person with SQL. If the form isn't an option, see [When the form isn't an option](#when-the-form-isnt-an-option).

## Preconditions

- [ ] The admin can sign in to Gibbon with an account that may add users (the Administrator role can).
- [ ] You know who the person is: their name, what they are (staff, student or parent), the username they should get and, if they have one, their email address.
- [ ] Passwords stay out of the chat. The admin types the new password into Gibbon's form, or lets Gibbon make one, and gives it to the person directly. Never ask for it, set it, or repeat it.

## Path 1: Gibbon's own form

### 1. Check the username is free (read-only)

```bash
u=$(printf '%s' '<username>' | od -An -tx1 -v | tr -d ' \n')   # the username as hex
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -e \
  "SELECT COUNT(*) AS taken FROM gibbonPerson WHERE username = CONVERT(X'${u}' USING utf8mb3);"
```

`0` means it's free. Gibbon refuses a username that's already taken. The username reaches MySQL as hex, so a quote, a backslash or a `;` in it can't change the query. Only the shell's quoting is left: put the name between the single quotes after `printf '%s'`, and write a single quote in it as `'\''`.

### 2. Pick the role (read-only)

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -e \
  "SELECT gibbonRoleID, name, category FROM gibbonRole ORDER BY category, name;"
```

The primary role decides what the person can see and do. `category` says which kind each role is. Agree the role with the admin. Suggest the Administrator role only when the admin asks for it in so many words.

### 3. Send the admin to the form

Take the link from this install's own tables, so the page and its name match the Gibbon version that's running:

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -sN -e "
  SELECT CONCAT(s.value, '/index.php?q=/modules/', REPLACE(m.name, ' ', '%20'), '/', a.entryURL)
  FROM gibbonAction a
  JOIN gibbonModule m ON m.gibbonModuleID = a.gibbonModuleID
  JOIN gibbonSetting s ON s.scope = 'System' AND s.name = 'absoluteURL'
  WHERE m.name = 'User Admin' AND a.name = 'Manage Users';"
```

If that prints nothing, list the module's pages and pick the user list from them: `SELECT a.name, a.entryURL FROM gibbonAction a JOIN gibbonModule m ON m.gibbonModuleID = a.gibbonModuleID WHERE m.name = 'User Admin';`.

Then tell the admin:

1. Open the link (User Admin → Manage Users) and choose **Add**.
2. Fill in the fields Gibbon marks as required, and choose the primary role from step 2.
3. Type a password or let Gibbon make one, and give it to the person yourself, not in this chat. If the form offers it, have Gibbon ask them for a new password when they first sign in.
4. Set the status to **Full** for someone who starts now (**Expected** for someone who starts later), and allow sign-in if they should sign in now.
5. Save, and tell me the username.

### 4. Check the new user (read-only)

```bash
u=$(printf '%s' '<username>' | od -An -tx1 -v | tr -d ' \n')   # the username as hex, as in step 1
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -e "
  SELECT p.gibbonPersonID, p.username, p.status, p.canLogin, r.name AS primaryRole
  FROM gibbonPerson p
  JOIN gibbonRole r ON r.gibbonRoleID = p.gibbonRoleIDPrimary
  WHERE p.username = CONVERT(X'${u}' USING utf8mb3);"
```

Expect one row with the role you agreed, the status the admin chose and `canLogin` = `Y` for someone who signs in now. Then the person signs in, or the admin tries the new password in a private browser window. Never sign in as them yourself.

### 5. What a new person usually needs next

A user account alone doesn't put someone into the school's year. Depending on the role:

- A student needs a student enrolment in the current school year before they show up in form groups, classes and attendance.
- A parent needs a family that links them to their children before they can see anything about them.
- Staff may need a staff record to show up in staff lists.

Look the pages up on this install rather than going by names from memory:

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -e "
  SELECT m.name AS module, a.name AS page, a.entryURL
  FROM gibbonAction a
  JOIN gibbonModule m ON m.gibbonModuleID = a.gibbonModuleID
  WHERE a.name LIKE '%Enrolment%' OR a.name LIKE '%Famil%' OR a.name LIKE '%Staff%'
  ORDER BY m.name, a.name;"
```

Build each link the way step 3 does, and walk the admin through the page.

## Path 2: many people at once

For a whole class or a new intake, look for Gibbon's import page: run the step 5 query with its `WHERE` changed to `a.name LIKE '%Import%'`. If this install has one, it beats the form one person at a time; if not, use the form. An import writes many rows in one go, so take a backup first ([scripts/backup.sh](../scripts/backup.sh)) and have the admin try a file with two or three people before the full list. Check a few of them with the step 4 query.

## Education Kit: a student or staff member also needs Moodle

In the Education Kit, Moodle's External Database plugin reads Gibbon's `moodleUser` view, and that view holds only the people whose primary role is in the Student or Staff category and whose status is Full. So a parent never gets a Moodle account from the kit, and someone added as Expected gets one only once their status is Full. Check whether this Gibbon feeds a Moodle:

```bash
MYSQL_PWD="${GIBBON_DB_PASSWORD:-$(clv-secret GIBBON_DB_PASSWORD)}" mysql -h "$GIBBON_DB_HOST" -u "$GIBBON_DB_USER" "$GIBBON_DB_NAME" -sN -e \
  "SELECT COUNT(*) FROM information_schema.views WHERE table_schema = DATABASE() AND table_name = 'moodleUser';"
```

`1` means it does. The kit leaves Moodle's user sync switched off, so a new student or staff member has no Moodle account until someone runs it. Tell the admin. With their go-ahead, run the sync with the moodle skill's clouve-ops channel: Moodle's `public/auth/db/cli/sync_users.php`, as `www-data` in the moodle container. It makes a Moodle account for everyone in the view who doesn't have one yet, and it also suspends the synced Moodle accounts of people who are no longer in the view, so say that before you run it.

Never set, ask for or show the new person's Moodle password, here or through the moodle skill. After the sync, Moodle's "Send new user passwords" task makes a password for each new account within a few minutes (Moodle's cron runs every five minutes in the kit), emails it to the address Gibbon holds for the person, and asks them to change it when they first sign in. If they have no email address in Gibbon, or the site can't send mail, the admin sets their password in Moodle's own form instead (Site administration > Users > Browse list of users, the person, Edit profile) and gives it to them directly, not in this chat. Have the admin try it in a private browser window about ten minutes later: until that task has dealt with a new account, it can replace the account's password at a cron run. If it stopped working, tell the admin rather than setting it some other way.

## When the form isn't an option

- If no admin can sign in, that's a lockout, not a new user: see [rotate-admin-credentials.md](rotate-admin-credentials.md).
- If the form shows an error, note the exact text and the URL. A 500 goes through [diagnose-500.md](diagnose-500.md).
- Otherwise, don't write the user into the database yourself, and don't copy another person's row either: that copies their address, phone numbers and emergency contacts into the new account. Say the form is the supported way, and surface what's in the way so the user can file a support ticket.

## Do NOT

- Ask for, set, show or store anyone's password.
- Insert or update `gibbonPerson` rows, or write a password hash, to create an account.
- Give the Administrator role unless the admin asks for it in so many words.
- Sign in as the new user.
