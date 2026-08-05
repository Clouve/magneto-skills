# Playbook: Change the site URL

Use this playbook when the tenant is moving the site to a new domain (custom domain, subdomain change), fixing a scheme mismatch (http ↔ https), or locked out / stuck in redirects after a URL change. Background — `siteurl` vs `home`, the env reconciler, serialized-data hazards — is in [reference/urls-and-migration.md](../reference/urls-and-migration.md). The safety gate "Edit `siteurl` / `home`" in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) applies to every path below.

## Decide the path first

Work through this before touching anything:

1. **Which shape?** Probe per [reference/stack-and-runtime.md](../reference/stack-and-runtime.md). Quick signal: `env | grep -iE 'wordpress|mysql|maria|host'` in the agent — a `WORDPRESS_SITE_URL` in the re-exported sibling env means the Clouve-packaged app (Shape A). Names vary; discover, don't assume.
2. **Is the new URL platform-real?** WordPress can only be told which URL it lives at — making that URL actually route to this pod (DNS, ingress, TLS) is platform work the tenant does in the Clouve console. This playbook handles WordPress's side only. If the new URL doesn't serve *anything* yet, stop and have the tenant finish the platform side first.
3. **Branch:**

| Situation | Path |
|---|---|
| Shape A, domain changed (or changing) through the platform | **Path 1** — the platform env updates the scalars; you handle content |
| Shape A, user wants a URL *different from* `WORDPRESS_SITE_URL` by hand | **Refuse** — the entrypoint reconciler reverts both options at every restart (SKILL.md principle 4). Route the change through the platform, then Path 1 |
| Shape B, any URL change (including lockout recovery) | **Path 2** — TCP scalar update; content pass has no shell path today |

## Preconditions

- [ ] Shape established (above).
- [ ] Full DB dump taken now via [scripts/backup.sh](../scripts/backup.sh) — the content pass is a bulk write; the scalar edit alone still warrants a dump. See [reference/backup-restore.md](../reference/backup-restore.md).
- [ ] Current `siteurl`/`home` values recorded **in chat** (they are your rollback data):
      ```bash
      # [TCP-mysql]
      MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" \
        -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
      ```
- [ ] New URL confirmed reachable at the ingress (tenant loads it in a browser, or you curl it if the agent has egress to the public hostname — if it doesn't resolve from the pod, ask the tenant to check).
- [ ] User ack obtained per the gate before any write.

## Path 1 — Shape A (Clouve-packaged)

### 1. Do NOT edit the options

On this shape `WORDPRESS_SITE_URL` is authoritative: the installer entrypoint re-asserts `siteurl` and `home` from it (plus `wp rewrite flush --hard`) on every boot. Tell the tenant to make the domain change in the Clouve console; the platform updates the env var, the pod restarts with it, and the entrypoint reconciles both options on the way up. Your job starts after that.

### 2. Confirm the reconcile happened

**[TCP-mysql]** Re-run the `SELECT` from Preconditions. Both rows must equal the new URL exactly (scheme included).

If they still show the old URL: the container hasn't restarted with the new env yet, or the platform change didn't land. A restart re-runs the reconciler — ask the tenant to confirm the change in the console and check again after the pod cycles. Do not "help" with a manual `UPDATE`; it would be overwritten anyway.

### 3. Content pass — embedded URLs still point at the old host

The reconciler touches only the two options. Links, `<img src>` in posts, widget config, and theme mods still carry the old URL (see [reference/urls-and-migration.md](../reference/urls-and-migration.md) for where they live).

**[shell-only — probe first]** The right tool is wp-cli's serialization-aware search-replace, which exists in this image — but only via a shell into the `wordpress` container, and today's WordPress images ship no sshd/`clouve-ops` account. Probe per [reference/shell-access.md](../reference/shell-access.md); expect failure. If a shell does exist:

```bash
wp search-replace 'https://old.example.com' 'https://new.example.com' \
  --path=/var/www/html --skip-columns=guid --report-changed-only --dry-run --allow-root
# show the dry-run output to the user (safety gate), get ack, re-run without --dry-run
wp cache flush --path=/var/www/html --allow-root
```

**Without a shell (the normal case today), the honest options are:**

- **wp-admin route**: install a serialization-aware search-replace plugin (e.g. Better Search Replace) through `/wp-admin`, following the vetting and gates in [install-plugin.md](install-plugin.md). Run its dry-run first, show the tenant the match counts, execute, then delete the plugin.
- **Defer**: leave content as-is. The site works; embedded links/media keep pointing at the old host and break if that host stops serving. Whether the old URL keeps resolving after a domain change is a platform question — assume it will not, and treat the content pass as required, just schedulable.
- **Never** raw SQL `REPLACE()` across content/options — serialized-data corruption, silent and delayed. The gate in [SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow) says refuse; the mechanism is in [reference/urls-and-migration.md](../reference/urls-and-migration.md).

Proceed to Verification.

## Path 2 — Shape B (developer-submitted vanilla compose)

Nothing reconciles URLs on this shape, and a wrong `siteurl` locks everyone out of `/wp-admin` — which is exactly why the fix runs over TCP, not through the admin UI.

### 1. Confirm the table prefix

**[TCP-mysql]** The demo-style compose uses the stock `wp_` prefix, but verify rather than assume:

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" \
  -e "SHOW TABLES LIKE '%options';"
```

Use the prefix you see in every statement below. (If the mysql client fails to authenticate against MySQL 8, see the `caching_sha2_password` note in [reference/stack-and-runtime.md](../reference/stack-and-runtime.md).)

### 2. Update the two scalars — gated

`siteurl` and `home` are plain strings, never serialized — this is one of the few URL edits that is safe over raw SQL. It is still a multi-row `UPDATE`: count first, print the exact statement, get the ack (SKILL.md principle 5).

```bash
# [TCP-mysql] dry-run equivalent:
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" \
  -e "SELECT COUNT(*) FROM wp_options WHERE option_name IN ('siteurl','home');"
# expected: 2
```

Print this to the user and wait for the ack:

```sql
UPDATE wp_options SET option_value = 'https://new.example.com'
 WHERE option_name IN ('siteurl','home');
```

The value must be the exact public URL — scheme included, no trailing slash. After executing, re-`SELECT` and confirm both rows changed.

No rewrite flush is needed for a host/scheme change — rewrite rules are path-based, not host-based. If permalinks 404 afterwards anyway, deleting the `rewrite_rules` row forces WordPress to lazily regenerate it on the next request; that is a single-row `DELETE` — print it and get an ack before running.

### 3. Content pass

Same problem as Path 1 step 3, with one difference worth saying plainly: **the vanilla image has no wp-cli at all**, so even a future shell channel would not provide `wp search-replace` without installing it first. Today the wp-admin plugin route ([install-plugin.md](install-plugin.md), dry-run shown to the user, plugin removed after) is the *only* serialization-safe path for embedded content on this shape — or defer/route to support. Never raw SQL over serialized data.

## Verification

```bash
# [TCP-mysql] both options are the new URL:
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"

# [HTTP] no redirect loop at the container (WORDPRESS_HOST = the wordpress sibling's hostname — discover it):
curl -sI "http://${WORDPRESS_HOST}/" | grep -iE '^(HTTP|Location)'
curl -sI -H 'X-Forwarded-Proto: https' "http://${WORDPRESS_HOST}/" | grep -iE '^(HTTP|Location)'
# expected: with the header, 200 (or one redirect to the NEW url); a repeated Location to the
# same https URL without the header is the TLS-termination scheme loop — see
# reference/urls-and-migration.md § redirect loops.

# [HTTP] login page serves without bouncing off-host:
curl -sI "http://${WORDPRESS_HOST}/wp-login.php" | head -1     # expect HTTP/1.1 200

# [HTTP] feed links carry the new URL:
curl -s -H 'X-Forwarded-Proto: https' "http://${WORDPRESS_HOST}/feed/" | grep -oE '<link>[^<]+' | head -3
```

Then have the tenant verify from outside (the agent can't see the ingress the way a browser does):

- Load `https://<new-url>/wp-admin` and **log in** — a successful login round-trip proves cookies and redirects agree on the new host.
- Open one media-heavy page and confirm images render — that is the canary for whether the content pass is done or still pending.

## Rollback

- **Shape B scalars**: `UPDATE` the two rows back to the values recorded in Preconditions — same gate, print + ack. This is also the recovery move for any lockout caused by a wrong value.
- **Shape A**: revert the domain change in the Clouve console; the next boot's reconciler puts both options back. A wrong value on this shape self-heals at pod restart by design — restart is a valid fix.
- **Content pass gone wrong** (vanished widgets/logo, reset theme mods = serialized corruption): do **not** attempt a reverse replace — restore the DB dump from Preconditions per [rollback-from-backup.md](rollback-from-backup.md).

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| Options revert after a restart (Shape A) | You edited what the reconciler owns | Route through the platform; Path 1 |
| `/wp-admin` unreachable after a manual change (Shape B) | Wrong `siteurl` — admin redirects to a dead host | Path 2 step 2 over TCP; browser can't fix it |
| `ERR_TOO_MANY_REDIRECTS` on https | Scheme loop behind the TLS-terminating ingress | Differential `X-Forwarded-Proto` probe; see [reference/urls-and-migration.md](../reference/urls-and-migration.md) |
| Widgets/logo/menus vanished after a replace | Byte-blind edit corrupted serialized data | Restore the dump; never reverse-replace |
| Images broken on the new domain, site otherwise fine | Content pass not done — literal old URLs in `post_content` | Path step 3 (content pass) |
| mysql client can't authenticate (Shape B) | MySQL 8 `caching_sha2_password` vs the shipped client | See [reference/stack-and-runtime.md](../reference/stack-and-runtime.md) |

## After-action

If you learned something WordPress-specific worth keeping — a plugin that handled the content pass well or badly, an ingress header quirk, a Shape B compose that deviated from the demo layout — capture it per [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill).
