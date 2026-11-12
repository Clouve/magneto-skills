# Playbook: Harden the Database Manager

Odoo's database manager (`/web/database/*`) can create, copy, drop, back up and restore databases. Its routes need no sign-in, and the only thing that stops a request is the master password. Clouve's Odoo image locks the manager at every container start. This playbook checks that lock, opens the manager for one task when one really needs the page, and covers the rest of the hardening.

See [reference/security.md](../reference/security.md) for the source-code basis of every item here.

## Preconditions

- [ ] Odoo is running and admin login works.
- [ ] You know the image writes `/etc/odoo/odoo.conf` from its own settings at every container start, so an edit there lasts until the next start. A lasting change to one of those settings is a request to Clouve support.
- [ ] You don't need the ingress: Clouve's ingress doesn't block `/web/database/`, and nothing in this playbook changes it. The lock is in `odoo.conf`.

## Steps

### 1. Check `admin_passwd`

The `admin_passwd` (master password) gates every database manager action. Odoo's default is `'admin'`, and while it is still the default, the first POST that supplies any non-empty password **silently replaces it** (the "auto-change footgun", see [reference/security.md](../reference/security.md#default-password-footgun)).

On Clouve, `admin_passwd` comes from `ODOO_MASTER_PASSWORD`, a random secret Clouve generates for each deployment. The entrypoint writes it into `odoo.conf` in plain text every time the container starts. Check that it is set and isn't the default, without printing it:

```bash
# Prints two counts. "1" then "0": set, and not 'admin'. A second "1": still 'admin'.
# A first "0": missing, so Odoo falls back to 'admin'.
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo grep -c '^admin_passwd' /etc/odoo/odoo.conf; sudo grep -cE '^admin_passwd *= *admin *$' /etc/odoo/odoo.conf || true"
```

Never `cat` or `grep` the `admin_passwd` line itself: on this image it holds the master password in plain text.

Anything other than `1` and `0` is a support request: the deployment's App Configuration is read-only once deployed, and the entrypoint writes `ODOO_MASTER_PASSWORD` back at every start. Odoo's own Set Master Password page is locked with the rest of the manager. A password set there while the manager is open (step 3) lasts only until the container next starts. Never make up a new master password yourself, ask for one, or put one in a command: anything you put in a command shows in this chat, and a remote command also shows in the Odoo container's process list.

### 2. Check the lock: `list_db = False` and `dbfilter`

`list_db = False` makes `check_db_management_enabled()` raise `AccessDenied` on every database manager action, and the database list answers an error. `dbfilter` pins the database a browser reaches. Without a pin, a second database in PostgreSQL breaks the login page: Odoo can't pick one and sends the browser to a database selector that the lock leaves empty.

Clouve's Odoo image writes both at every start:

```ini
list_db = False
dbfilter = ^<ODOO_DB_NAME>\Z
```

It uses `dbfilter`, not `db_name`, on purpose: with `db_name` set, Odoo 19 creates that database at every start if it is missing, with the admin's password `admin`.

Check them (prints a count, then the two lines, neither of which holds a password):

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
  "sudo grep -cE '^list_db *= *False *$' /etc/odoo/odoo.conf; sudo grep -E '^(list_db|dbfilter|db_name) *=' /etc/odoo/odoo.conf"
```

A first `1` means locked. A `0` means the manager is open: either step 3 left it open (close it now), or the deployment runs an Odoo image from before this lock, where `odoo.conf` has no `list_db` line. On an older image the lock comes with the newer image (a new listing version), and an edit to `odoo.conf` there lasts only until the container starts again.

### 3. Open the manager for one task, then close it

`odoo db` does everything the page does (dump, load, duplicate, rename, drop) without the page and without the master password, because it turns the check off for itself. Use it ([playbooks/backup.md](backup.md), [playbooks/restore-and-clone.md](restore-and-clone.md)). Open the page only when the user asks for something only the page does, for exactly that task, with the user's ack:

1. Open it, and restart Odoo so it reads `odoo.conf` again (Odoo re-executes itself with the same config). Then wait
   for the database list to answer: `/web/health` can still answer from the old process before the restart lands.

   ```bash
   SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
     "sudo sed -i 's/^list_db = False$/list_db = True/' /etc/odoo/odoo.conf"
   SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
     'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1'
   for i in $(seq 1 30); do
     sleep 2
     curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
       "http://${ODOO_HOST}:8069/web/database/list" | grep -q '"result"' && break
   done
   ```

2. Check it answers. The database list needs no password, and it answers `"result"` only while the manager is open:

   ```bash
   curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
     "http://${ODOO_HOST}:8069/web/database/list"
   ```

3. Do the task. The page asks for the master password on every action. You can read it with `clv-secret`, and it goes to `curl` on stdin, never on a command line and never into the chat. For example, a backup made the way the page makes it:

   ```bash
   install -d -m 700 "$HOME/backups"   # whole databases: yours alone
   printf '%s' "${ODOO_MASTER_PASSWORD:-$(clv-secret ODOO_MASTER_PASSWORD)}" | \
     curl -sS --data-urlencode master_pwd@- -d "name=${ODOO_DB_NAME}" -d backup_format=zip \
       -o "$HOME/backups/${ODOO_DB_NAME}-manager.zip" -w '%{http_code} %{content_type}\n' \
       "http://${ODOO_HOST}:8069/web/database/backup"
   ```

   `200 application/octet-stream` is the ZIP. A person who already holds the master password can use `https://<their Odoo>/web/database/manager` in the same window. The page works only on `${ODOO_DB_NAME}`: `dbfilter` still applies.

4. Close it in the same session, wait for the list to answer `"error"` again, and check that the count from section 2
   ("Check the lock") is `1`:

   ```bash
   SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
     "sudo sed -i 's/^list_db = True$/list_db = False/' /etc/odoo/odoo.conf"
   SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${ODOO_HOST} \
     'grep -q odoo /proc/1/cmdline && sudo kill -HUP 1'
   for i in $(seq 1 30); do
     sleep 2
     curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
       "http://${ODOO_HOST}:8069/web/database/list" | grep -q '"error"' && break
   done
   ```

   Setting a master password on the page makes Odoo rewrite `odoo.conf`. It writes `list_db = True` in the same form, so the `sed` still matches, but check the count anyway.

A new container writes `odoo.conf` again and locks the manager, so it never stays open past a restart of the container. Don't leave it open past the task either.

### 4. `proxy_mode=True`

Without `proxy_mode=True`, Odoo ignores `X-Forwarded-For` and `X-Forwarded-Proto`, which breaks correct IP logging and HTTPS detection.

```ini
; In odoo.conf:
proxy_mode = True
```

The proxy **must** strip any client-supplied `X-Forwarded-*` headers before appending its own — otherwise an attacker can spoof their IP or claim HTTPS on a plain-HTTP connection.

Nginx configuration:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Host $host;
# Do NOT forward X-Forwarded-Host from the client.
```

### 5. Enforce TLS and add Secure cookie flags

Odoo's session cookie is `httponly` but not `Secure` or `SameSite` by default. Without TLS enforcement, the session cookie travels in plaintext.

```nginx
# Force HTTPS at the ingress:
server {
    listen 80;
    return 301 https://$host$request_uri;
}

# Add Secure + SameSite to the session cookie as it passes through:
proxy_cookie_flags ~ httponly secure samesite=lax;
```

Also set in `odoo.conf` if your Odoo version supports it:

```ini
session_cookie_samesite = Lax
```

### 6. Outside Clouve: block `/web/database/` at the ingress

On an Odoo install you run yourself, block the whole database manager prefix at the ingress, on top of `list_db = False`, and cap the upload size (the restore route has no server-side limit). Clouve's ingress does neither; on Clouve the lock is `list_db = False` alone.

```nginx
location /web/database/ {
    return 403;
}
client_max_body_size 500m;   # adjust to your largest legitimate backup
```

### 7. Verify the lock

**A GET to `/web/database/manager` returning HTTP 200 is NOT proof of anything.** The manager page renders with a banner when the manager is locked. A POST with a made-up master password doesn't tell you either: Odoo checks the password before the lock, so a locked and an open manager give the same AccessDenied page. Ask for the database list, which needs no password:

```bash
curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
  "http://${ODOO_HOST}:8069/web/database/list"
```

Expected: an `"error"` with `AccessDenied` in it. A `"result"` with a list of databases means the manager is open.

## Hardening checklist summary

- [ ] `admin_passwd` set and not `'admin'` (step 1).
- [ ] `list_db = False` and `dbfilter` in `odoo.conf` (step 2; the image writes both).
- [ ] The manager opened only for one task, and closed again (step 3).
- [ ] `proxy_mode = True` in `odoo.conf`, and the proxy strips client `X-Forwarded-*`.
- [ ] TLS enforced and `Secure; SameSite=Lax` on the session cookie.
- [ ] The database list answers `"error"` (step 7).

## Do NOT

- Leave `admin_passwd = admin`: the first POST from anyone adopts their submitted password.
- Set `list_db = False` without pinning the database (`dbfilter`, or `db_name` on an install you run yourself): the login page breaks once there is a second database.
- Trust a GET 200 on `/web/database/manager`, or an AccessDenied for a made-up master password, as proof of the lock: use the database list.
- Leave the manager open after the task, or put the master password on a command line or in the chat.
