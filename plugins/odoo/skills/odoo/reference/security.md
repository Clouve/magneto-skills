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

**Mitigation:** Set a strong `admin_passwd` in `odoo.conf` before exposing the port, and
use `list_db = False` (see below). Clouve's Odoo image does both at every start.

## list_db=False — the real kill-switch

Setting `list_db = False` (CLI flag `--no-database-list`) causes
`check_db_management_enabled()` (`service/db.py:46-53`) to raise `AccessDenied` on any
call that touches DB management functions. All mutating routes become inaccessible.

**BUT: you must also pin the database.** With one database Odoo picks it by itself, but
once PostgreSQL holds a second one, the login page sends the browser to a database
selector, which the lock leaves empty.

```ini
; odoo.conf, as Clouve's Odoo image writes it at every start
list_db = False
dbfilter = ^odoo\Z       ; the deployment's ODOO_DB_NAME, dots escaped
```

Clouve's image pins the database with `dbfilter`, not `db_name`. Odoo 19 creates every
`db_name` database that is missing when the server starts, at every start and every
SIGHUP restart (`cli/server.py`, `main()`), and a database made that way has the admin
login `admin` with the password `admin` (`base/data/res_users_data.xml`). `dbfilter`
creates nothing. Either one makes a browser reach the pinned database only: Odoo
ignores a session, an `X-Odoo-Database` header or a `?db=` for any other name
(`http.py`, `_get_session_and_dbname`; `web/controllers/utils.py`, `ensure_db`).

`odoo db` (dump, load, duplicate, rename, drop) still works: it sets `list_db = True`
for itself after reading the config (`cli/db.py`). `odoo shell`, `odoo module` and
`odoo neutralize` never touch the lock.

**The GET manager page still returns HTTP 200 with a banner when `list_db = False`,**
and a POST with a made-up master password proves nothing either: the routes check the
master password first (`check_super`), so a locked and an open manager give the same
AccessDenied. Ask for the database list, which needs no password and answers an error
only while the manager is locked:

```bash
curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"call","params":{}}' \
  https://your-odoo/web/database/list
```

On an install you run yourself, also block the entire `/web/database/` prefix at the
ingress. Clouve's ingress doesn't; on Clouve the lock is `list_db = False`:

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
2. Set `list_db = False` with a pinned database (`dbfilter`) for production. Clouve's Odoo image writes both at every start.
3. Block `/web/database/` at the ingress on an install you run yourself (Clouve's ingress doesn't).
4. Enable `proxy_mode = True` and have the proxy strip client `X-Forwarded-*`.
5. Enforce TLS at the proxy and add `Secure; SameSite=Lax` to session cookies.
6. Cap upload size at the ingress (`client_max_body_size`).
7. Verify with the database list (`/web/database/list` answers an error) that DB management is actually blocked, not just hidden.
