# Security Reference

## Database manager routes

All 9 `/web/database/*` routes are declared `auth='none'` — they require no session,
no user, no API key. They are reachable by any HTTP client that can reach the Odoo port
(`addons/web/controllers/database.py:59-186`):

| Route | Method | csrf | Purpose |
|---|---|---|---|
| `/web/database/selector` | GET | n/a | DB selector widget |
| `/web/database/manager` | GET | n/a | Manager page (read-only) |
| `/web/database/create` | POST | False | Create DB |
| `/web/database/duplicate` | POST | False | Duplicate DB |
| `/web/database/drop` | POST | False | Drop DB |
| `/web/database/backup` | POST | False | Download backup |
| `/web/database/restore` | POST | False | Restore from upload |
| `/web/database/change_password` | POST | False | Change master password |
| `/web/database/list` | JSON-RPC | n/a | List DBs |

All mutating routes set `csrf=False`. The **only** protection is the `admin_passwd`
(master password) that must be submitted in each POST body — checked by
`odoo.service.db.check_super()` (`service/db.py:60-63`).

### Default password footgun

The default `admin_passwd` is `'admin'` (`tools/config.py`). When the value is still
`'admin'`, the HTTP `create`, `duplicate`, `drop`, `backup`, `restore`, and
`change_password` controllers check:

```python
insecure = odoo.tools.config.verify_admin_password('admin')
if insecure and master_pwd:
    dispatch_rpc('db', 'change_admin_password', ["admin", master_pwd])
```

This means: **the first POST body that supplies any non-empty `master_pwd` silently
becomes the new master password.** There is no confirmation step. An attacker who
reaches the `/web/database/create` endpoint before the operator sets a real password
can adopt any password they choose on the first request.

**Mitigation:** Set a strong `admin_passwd` in `odoo.conf` before exposing the port, or
use `list_db=False` (see below).

## list_db=False — the real kill-switch

Setting `list_db = False` (CLI flag `--no-database-list`) causes
`check_db_management_enabled()` (`service/db.py:46-53`) to raise `AccessDenied` on any
call that touches DB management functions. All mutating routes become inaccessible.

**BUT: you must also pin `db_name` or `dbfilter`.**
Without a pinned database, the DB selector widget returns an empty list and the Odoo
login page breaks (it cannot determine which DB to connect to).

```ini
; odoo.conf
list_db = False
db_name = myproductiondb       ; or use dbfilter = ^myproductiondb$
```

**The GET manager page still returns HTTP 200 with a banner when `list_db=False`.**
Do not rely on a 200/non-200 check to confirm the kill-switch is active. Verify by
attempting a POST:

```bash
# Should return a rendered error (AccessDenied), not succeed:
curl -s -X POST https://your-odoo/web/database/backup \
  -F master_pwd=test -F name=mydb -F backup_format=zip | head -20
```

Block the entire `/web/database/` prefix at the ingress for any instance where DB
management should be completely unreachable:

```nginx
location /web/database/ {
    return 403;
}
```

## Proxy and TLS hardening

### proxy_mode and X-Forwarded headers

Enable `proxy_mode = True` in `odoo.conf` whenever Odoo sits behind a reverse proxy.
This activates Werkzeug's `ProxyFix`, which trusts **one hop** of `X-Forwarded-For`,
`X-Forwarded-Proto`, and `X-Forwarded-Host`.

The proxy **must** strip any client-supplied `X-Forwarded-*` headers before appending
its own. If the proxy blindly forwards client headers, an attacker can spoof their
source IP or the protocol (e.g. claim `X-Forwarded-Proto: https` on a plain-HTTP
request), bypassing any `https`-only checks inside Odoo.

```nginx
# nginx: remove any client X-Forwarded-* before passing to Odoo
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
# Do not forward X-Forwarded-Host from the client — let nginx set it:
proxy_set_header Host $host;
```

### Session cookie

Odoo's session cookie is `httponly` but **not** `Secure` or `SameSite` by default.
Without TLS enforcement at the proxy, the session cookie travels over plain HTTP and
is trivially stolen. Enforce at the proxy:

```nginx
# Add Secure + SameSite to the session cookie as it passes through:
proxy_cookie_flags ~ httponly secure samesite=lax;
```

Also set `session_cookie_samesite = Lax` in `odoo.conf` if your Odoo version supports it.

### Restore route upload size

`/web/database/restore` is declared `max_content_length=None`
(`addons/web/controllers/database.py:150`), meaning Odoo itself imposes no upload size
limit. A malicious actor with the master password can upload an arbitrarily large file.
Cap this at the ingress:

```nginx
client_max_body_size 500m;   # adjust to your largest legitimate backup
```

## Hardening checklist

1. Set a strong `admin_passwd` in `odoo.conf` before first boot.
2. Set `list_db = False` with a pinned `db_name` or `dbfilter` for production.
3. Block `/web/database/` at the ingress for production instances.
4. Enable `proxy_mode = True` and have the proxy strip client `X-Forwarded-*`.
5. Enforce TLS at the proxy and add `Secure; SameSite=Lax` to session cookies.
6. Cap upload size at the ingress (`client_max_body_size`).
7. Verify with a POST probe that DB management is actually blocked, not just hidden.
