# Data Model — `wp_options` anatomy, serialized PHP, and the touch lists

A single-site WordPress database is 12 core tables plus whatever plugins add. Default prefix `wp_` (Shape A pins it via `WORDPRESS_TABLE_PREFIX=wp_`); substitute yours if it differs. The engine differs per shape — MariaDB (Shape A) vs MySQL 8 (typical Shape B) — but the schema is identical.

Everything in this file is **[TCP-mysql]** unless labeled otherwise — it is the channel you always have. Canonical invocation (never put the password in the argument list):

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -e "<SQL>"
```

Core tables: `wp_options`, `wp_users`, `wp_usermeta`, `wp_posts`, `wp_postmeta`, `wp_comments`, `wp_commentmeta`, `wp_terms`, `wp_termmeta`, `wp_term_taxonomy`, `wp_term_relationships`, `wp_links`. As an operator you will read many and write to almost none — the lists below draw that line.

## `wp_options` anatomy

Four columns: `option_id`, `option_name` (unique), `option_value` (longtext), `autoload`. Site settings, plugin settings, the active theme and plugin list, the cron schedule, transient caches — all rows in this one table. It is the most useful table in the database and the only one you routinely write to.

Rows worth knowing on sight:

| `option_name` | Holds | Serialized? | Notes |
|---|---|---|---|
| `siteurl`, `home` | The two site URLs | no | Shape A: env-reconciled every boot — see [configuration.md](configuration.md) and [urls-and-migration.md](urls-and-migration.md) |
| `blogname`, `blogdescription`, `admin_email` | Title, tagline, admin contact | no | Safe scalar edits (gated); note a SQL `admin_email` change skips WP's confirmation-mail flow |
| `template`, `stylesheet` | Active theme (parent, child) | no | Plain strings — the theme-fallback lever in WSOD isolation |
| `active_plugins` | Active plugin list | **yes** | Serialized array of `dir/file.php` strings — read freely, write only the known constant `a:0:{}` (see below) |
| `db_version` | Installed **schema** version | no | Compare against the code's expectation — [upgrade.md](upgrade.md). The code version is *not* in the DB: infer over [HTTP] from the meta generator or `/feed/` `<generator>` |
| `wp_user_roles` | Role→capability map (name carries the table prefix) | **yes** | Never hand-edit |
| `cron` | The entire wp-cron schedule | **yes** | Read to see pending jobs ([cron-and-tasks.md](cron-and-tasks.md)); never hand-edit |
| `rewrite_rules` | Compiled permalink rules | **yes** | Safe to `DELETE` — WordPress regenerates on the next request; the closest TCP-only "flush rewrites" |
| `permalink_structure` | Permalink pattern | no | Shape A installs set `/%postname%/` |
| `_transient_*` / `_site_transient_*` | Cached values | often | See transients below |

### `autoload`

Every autoloaded row is read into memory on **every request** (the `alloptions` cache). A few megabytes of autoloaded plugin leftovers is a classic slow-site cause. Since WordPress 6.6 the column vocabulary expanded — expect a mix of `yes`/`no` and `on`/`off`/`auto`/`auto-on`/`auto-off` (general WP knowledge; the `off`-family rows are the not-loaded ones). Heavy-hitter probe:

```sql
SELECT option_name, LENGTH(option_value) AS bytes, autoload
FROM wp_options
WHERE autoload NOT IN ('no','off','auto-off')
ORDER BY bytes DESC LIMIT 20;
```

Report findings; fixing them (deactivating the offending plugin, `wp option update … --autoload=off`) goes through wp-admin or a shell — flipping `autoload` by SQL is technically possible but do it only for rows you can attribute, with the gate.

### Transients

Expiring caches stored as row pairs: `_transient_<key>` (the value) + `_transient_timeout_<key>` (unix expiry); `_site_transient_*` likewise (update checks, etc.). A value row with no timeout twin never expires on its own. Deleting **expired** transients is safe and is — together with the `rewrite_rules` delete — the closest TCP-only analog of "purge caches" ([caching.md](caching.md)):

```sql
-- Count first (SKILL.md gate: multi-row DELETE ⇒ COUNT + user ack)
SELECT COUNT(*) FROM wp_options o
JOIN wp_options t ON t.option_name = CONCAT('_transient_timeout_', SUBSTRING(o.option_name, 12))
WHERE o.option_name LIKE '\_transient\_%'
  AND o.option_name NOT LIKE '\_transient\_timeout\_%'
  AND t.option_value < UNIX_TIMESTAMP();
```

Print the count and the matching `DELETE` (both value and timeout rows), get the ack, then run it. Caveat: if a persistent object cache (Redis/Memcached drop-in) were active, transients would bypass the DB entirely — neither Clouve shape ships one by default, but check for a `wp_options` row mess vs. an `object-cache.php` drop-in before concluding.

## Serialized PHP — the hazard that ruins sites

WordPress stores arrays/objects as PHP-serialized strings whose **string lengths are baked into the data**: `s:13:"..."` means "a 13-byte string follows". `wp_options.option_value`, `wp_postmeta`, widget and theme-mod rows all use it.

Concrete corruption example — a theme-mods row before:

```
a:2:{s:4:"logo";s:29:"http://myshop.old-domain.com/";s:5:"color";s:7:"#0a66c2";}
```

A naive migration runs:

```sql
-- DO NOT DO THIS
UPDATE wp_options SET option_value =
  REPLACE(option_value, 'http://myshop.old-domain.com', 'https://myshop.new-domain.com');
```

The URL is now 30 bytes but the prefix still says `s:29:` — `unserialize()` returns `false`, and WordPress silently falls back to defaults: logo gone, menu assignments gone, every Customizer setting reset. The `UPDATE` "succeeded", the site "works", and the damage surfaces as mysteriously vanished configuration — often days later, blamed on something else.

Rules ([SKILL.md](../SKILL.md) principle 6):

- A value starting `a:`, `s:`, `O:`, `i:`, or `b:` followed by a number/colon is serialized — **never** string-`REPLACE` across it.
- Length-aware search-replace is `wp search-replace --dry-run` — **[shell-only — probe first]**, unreachable today. Without a shell there is no safe bulk rewrite of serialized data over TCP; say so and scope the work to plain scalar rows, or route.
- The one safe serialized *write* is a **known constant**: `a:0:{}` (the empty array) into `active_plugins` for WSOD isolation — after `SELECT`ing and saving the current value so it can be restored (gated).

## NEVER touch (no direct `UPDATE` / `DELETE` / `INSERT`)

These hold the tenant's content, identity, and money. Mutating them outside WordPress's APIs desyncs denormalized counts, meta chains, and caches in ways that surface later and silently. **Refuse**, and route through `/wp-admin` (or wp-cli when a shell exists).

| Table(s) | What it holds |
|---|---|
| `wp_posts` | *Everything*: posts, pages, media attachments, revisions, nav-menu items, block templates, WooCommerce products — one table, discriminated by `post_type` |
| `wp_postmeta` | Attachment paths, page-builder blobs (serialized), custom fields, SEO data |
| `wp_users` | Accounts. Single gated exception: the `user_pass` reset below |
| `wp_usermeta` | Capabilities (`wp_capabilities`, serialized), session tokens, per-user settings |
| `wp_comments`, `wp_commentmeta` | Comments — and WooCommerce order notes live here as comment type `order_note` |
| `wp_terms`, `wp_termmeta`, `wp_term_taxonomy`, `wp_term_relationships` | Categories, tags, menus, product attributes — the relationships *are* the categorization |
| `wp_wc_*` (e.g. `wp_wc_orders`, `wp_wc_orders_meta`) and `wp_woocommerce_*` (e.g. `wp_woocommerce_order_items`, `_order_itemmeta`, `_sessions`) | WooCommerce orders and money. HPOS-era stores keep orders in `wp_wc_orders`, legacy stores in `wp_posts` — either way: never |

Rule of thumb: if a table holds something a human typed, uploaded, or paid for — read-only. `SELECT` is always fine and often the fastest diagnosis.

## Safe to touch (each with its gate)

| Operation | Gate ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow)) |
|---|---|
| Scalar `wp_options` rows: `blogname`, `blogdescription`, `admin_email`, `permalink_structure`, … | Single-row `UPDATE`; print the SQL + user ack. Prefer pointing the user at `/wp-admin` Settings when they can click it themselves |
| `siteurl` / `home` | Shape check first (env reconciler wins on Shape A) + [playbooks/change-site-url.md](../playbooks/change-site-url.md) |
| `active_plugins` → `'a:0:{}'` (WSOD isolation) | `SELECT` and record the current value first + user ack |
| `template` / `stylesheet` → a known theme | [HTTP] probe the theme exists first: `curl -sfI "http://${WORDPRESS_HOST}/wp-content/themes/twentytwentyfive/style.css"` |
| Expired-transient `DELETE`, `rewrite_rules` `DELETE` | `SELECT COUNT(*)` first + user ack |
| `wp_users.user_pass` MD5 reset | The gate below |

## The `user_pass` MD5-upgrade fallback

Standard, documented WordPress behavior: `wp_users.user_pass` normally holds a modern hash (bcrypt since WP 6.8; phpass before), but WordPress **accepts a plain MD5 value and transparently re-hashes it to the modern scheme on the user's next successful login**. That makes a TCP-only password reset possible — the fallback for "lost admin access" when no shell exists:

```sql
-- 1. Verify exactly one target row (also confirms the username with the user):
SELECT ID, user_login, user_email FROM wp_users WHERE user_login = 'the_admin';

-- 2. Print this, get the ack, then run:
UPDATE wp_users SET user_pass = MD5('a-strong-temp-pass') WHERE user_login = 'the_admin';
```

**Gate** (per [SKILL.md](../SKILL.md)): confirm the username, confirm the requester actually controls that account (contactable at `user_email`), print the exact `UPDATE`, and wait for the ack. Then:

- The value sits as weak MD5 until the next login — do this just-in-time, use a strong temp password, and have the user log in immediately and change it in their profile.
- Existing login cookies for that user die with the change — auth cookies embed a fragment of the stored hash (general WP knowledge) — which is usually a feature when you're resetting a possibly-compromised account.
- On Shape A the platform-injected `WORDPRESS_ADMIN_PASSWORD` env will **not** reflect this change — note that to the user (see [playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md)).
- With a shell instead: **[shell-only — probe first]** `wp user update the_admin --user_pass='…' --path=/var/www/html --allow-root` — same gate.

## Quick diagnostic reads

Install state (this is literally Shape A's own boot-time detection):

```sql
SELECT option_value FROM wp_options WHERE option_name IN ('siteurl','home','db_version','template','stylesheet','active_plugins');
```

Content canary (useful before/after a backup or restore — [backup-restore.md](backup-restore.md)):

```sql
SELECT post_type, post_status, COUNT(*) FROM wp_posts GROUP BY post_type, post_status;
SELECT COUNT(*) AS users FROM wp_users;
SELECT COUNT(*) AS comments FROM wp_comments;
```

Who can log in as admin:

```sql
SELECT u.ID, u.user_login, u.user_email
FROM wp_users u JOIN wp_usermeta m ON m.user_id = u.ID
WHERE m.meta_key = 'wp_capabilities' AND m.meta_value LIKE '%administrator%';
```

(Reading the serialized `wp_capabilities` with `LIKE` is fine — it's the *writes* that are forbidden.)
