# Playbook: Harden the Database Manager

Run this before exposing an Odoo instance to the internet. The default configuration leaves the database manager reachable by any HTTP client with no authentication beyond a password that defaults to `'admin'`.

See [reference/security.md](../reference/security.md) for the source-code basis of every item here.

## Preconditions

- [ ] Odoo is running and admin login works.
- [ ] You can edit `odoo.conf` on the Odoo container (the entrypoint regenerates it on each pod start — coordinate with Clouve ops to persist changes through a config map or environment variable override).
- [ ] You have access to the ingress/nginx configuration for this deployment.

## Steps

### 1. Set a strong `admin_passwd`

The `admin_passwd` (master password) is the only protection for all mutating database manager routes. The default is `'admin'` — and the first POST body that supplies any non-empty password **silently replaces it** with no confirmation step (the "auto-change footgun", see [reference/security.md](../reference/security.md#default-password-footgun)).

Set a strong value before the instance is reachable:

```bash
# In the Clouve deployment, ODOO_MASTER_PASSWORD env var is templated into odoo.conf:
# admin_passwd = <ODOO_MASTER_PASSWORD>
# Set it to a random 32-char string — never leave it as 'admin'.

# Verify the current value (shows the PBKDF2 hash, not plaintext — 'admin' has a known hash):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo grep admin_passwd /etc/odoo/odoo.conf"
```

If the value is the default `'admin'` hash, change it immediately:

```bash
# From odoo shell — change via the DB manager's own API (avoids the auto-change footgun):
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo odoo shell -d <db> --no-http <<'EOF'
import odoo.service.db as db_svc
db_svc.change_db_admin_password('admin', 'NEW_STRONG_PASSWORD_HERE')
env.cr.commit()
EOF"
```

Or set the `ODOO_MASTER_PASSWORD` environment variable to the desired value and restart the pod (the entrypoint will template it into `odoo.conf`).

### 2. Set `list_db=False` and pin `db_name`

`list_db=False` causes `check_db_management_enabled()` to raise `AccessDenied` on any call to DB management functions. All mutating routes become inaccessible.

**BUT: you must also pin `db_name` or `dbfilter`.** Without a pinned database, the login page breaks (empty DB selector).

```ini
; In odoo.conf (or via the ODOO_LIST_DB / db_name env vars):
list_db = False
db_name = myproductiondb
; Alternatively:
; dbfilter = ^myproductiondb$
```

Verify the config is active:

```bash
SSHPASS="$CLOUVE_OPS_PASSWORD" sshpass -e ssh clouve-ops@${ODOO_HOST} \
  "sudo grep -E 'list_db|db_name|dbfilter' /etc/odoo/odoo.conf"
```

### 3. Enable `proxy_mode=True`

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

### 4. Enforce TLS and add Secure cookie flags

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

### 5. Block `/web/database/` at the ingress

For production instances, block the entire database manager prefix at the ingress — this is defense in depth on top of `list_db=False`:

```nginx
location /web/database/ {
    return 403;
}
```

Also cap upload size (the restore route has no server-side size limit):

```nginx
client_max_body_size 500m;   # adjust to your largest legitimate backup
```

### 6. Verify lockdown

**A GET to `/web/database/manager` returning HTTP 200 is NOT proof the kill-switch is active.** The manager page renders with a banner even when `list_db=False`. You must verify with a POST:

```bash
# This should return an AccessDenied error (rendered HTML with error), not succeed.
# If list_db=False is working, the create/drop/backup routes are blocked:
curl -s -X POST https://<your-odoo>/web/database/backup \
  -F master_pwd=test -F name=<db> -F backup_format=zip | head -20
```

Expected: response contains `AccessDenied` or an error message — not a ZIP file download.

If the ingress is blocking `/web/database/` with `return 403`:

```bash
curl -o /dev/null -w "%{http_code}" -s -X POST https://<your-odoo>/web/database/create \
  -F master_pwd=test -F db_name=test
# Expected: 403
```

## Hardening checklist summary

- [ ] `admin_passwd` set to a strong random value (not `'admin'`).
- [ ] `list_db = False` in `odoo.conf`.
- [ ] `db_name` or `dbfilter` pinned (login page depends on it).
- [ ] `proxy_mode = True` in `odoo.conf`.
- [ ] Proxy strips client `X-Forwarded-*` and sets its own.
- [ ] TLS enforced at ingress; plain HTTP redirected to HTTPS.
- [ ] `Secure; SameSite=Lax` added to session cookie at proxy.
- [ ] `/web/database/` prefix blocked at ingress with `return 403`.
- [ ] `client_max_body_size` capped at ingress.
- [ ] POST probe to `/web/database/backup` confirmed AccessDenied.

## Do NOT

- Leave `admin_passwd = admin` — the first POST from anyone adopts their submitted password.
- Set `list_db=False` without pinning `db_name` — the login page will break.
- Trust a GET 200 on `/web/database/manager` as proof of lockdown — always verify with a POST.
- Rely on the password alone without blocking the route at the ingress for production instances.
