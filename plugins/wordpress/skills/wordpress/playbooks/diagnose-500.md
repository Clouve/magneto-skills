# Playbook: Diagnose a 500

Use this playbook when the user reports the WordPress site is erroring — an HTTP 500, the "There has been a critical error on this website" page, or a white screen. Don't run more than one diagnostic step at a time; stop when the answer is clear and tell the user before changing anything.

**The channel reality shapes this whole ladder** ([reference/shell-access.md](../reference/shell-access.md)): there is no shell into the WordPress container today, so you cannot read the fatal. The ladder therefore leans on HTTP differentials and DB-side evidence, with the gated no-shell isolation moves where they exist.

## Preconditions

- [ ] Discovered env: `env | grep -iE 'wordpress|mysql|maria|host'` — you have `${WORDPRESS_HOST}` and the `${WORDPRESS_DB_*}` set.
- [ ] Confirmed the table prefix: `SHOW TABLES LIKE '%options'` (commands below assume `wp_`).
- [ ] Know your shape (Clouve-packaged vs developer compose — [reference/stack-and-runtime.md](../reference/stack-and-runtime.md)); two steps below branch on it.

## Step 0: Confirm the symptom **[HTTP]**

```bash
curl -sI "http://${WORDPRESS_HOST}/"
# HTTP/1.1 500 Internal Server Error  ← the symptom (blank body OR the "critical error" page)
# HTTP/1.1 503 Service Unavailable    ← likely maintenance mode — different problem; see Step 0.5
# HTTP/1.1 200 OK                     ← site is up. The user may be wrong, or the problem is partial.
```

Body matters as much as status:

```bash
curl -s "http://${WORDPRESS_HOST}/" | head -c 400
```

- `There has been a critical error on this website` → a PHP fatal caught by WordPress's handler (5.2+). WordPress also tries to email the admin a recovery-mode link — worth asking the user to check that inbox, though mail from these pods isn't guaranteed.
- `Error establishing a database connection` → jump to Step 5 (DB health).
- Truly blank → fatal before output, or output killed; same ladder.

If `200 OK`, ask the user for the exact URL, a screenshot/copy of the error, and the approximate time. One URL erroring with the rest of the site fine is a different fact pattern from "every page is down."

## Step 0.5: Maintenance mode? **[HTTP]**

A 503 with *"Briefly unavailable for scheduled maintenance"* is a stuck `.maintenance` file from an interrupted update, not a 500. Core timestamps the file and ignores it after roughly 10 minutes, so re-probe after 10 minutes; if it persists, removing the file needs a file channel that doesn't exist today — see [reference/troubleshooting.md](../reference/troubleshooting.md#stuck-in-maintenance-mode) for the honest routing, and find out which update was interrupted before anyone retries it.

## Step 1: The log reality check (read this before hunting for logs)

On the moodle skill, Step 1 is "tail the Apache error log over SSH." Here that rung is missing, and you should not pretend otherwise:

- Apache's error stream goes to **container stderr** in official-image derivatives. The agent has no `docker logs` / `kubectl logs` — that stream is invisible from here on every channel.
- `wp-content/debug.log` only exists if `WP_DEBUG` + `WP_DEBUG_LOG` are on. *Enabling* that (a `wp-config.php` edit) needs a **[shell-only — probe first]** channel — probe if you like (`sshpass -e ssh -o ConnectTimeout=3 ... true` — expected to fail today; see [reference/shell-access.md](../reference/shell-access.md)). *Reading* an existing log, though, is **[HTTP]** — it sits in the docroot, so probe opportunistically:

  ```bash
  curl -sf "http://${WORDPRESS_HOST}/wp-content/debug.log" | tail -50
  # 404 = no log or blocked, not "no errors"
  ```
- Shape A forces `WP_DEBUG_DISPLAY` off on every boot, so fatals will not appear in HTTP bodies either.

Conclusion: you will usually **not** get the fatal's file/line. The rest of the ladder builds the diagnosis from HTTP differentials (Step 2), DB evidence (Step 3), and gated isolation (Steps 4–5). If the user can view the pod logs in their Clouve dashboard or has cluster access, the first fatal in the burst short-circuits all of this — ask.

## Step 2: HTTP differential — scope the failure **[HTTP]**

```bash
for path in / /wp-login.php /wp-admin/ /wp-json/ /wp-includes/js/jquery/jquery.min.js /wp-content/index.php; do
  printf '%-45s %s\n' "$path" "$(curl -s -o /dev/null -w '%{http_code}' "http://${WORDPRESS_HOST}${path}")"
done
```

Read the pattern:

| Pattern | Meaning | Next |
|---|---|---|
| Static asset 200, all PHP 500 | PHP-level fatal on every request — plugin/theme code loaded on each page, or `wp-config.php` | Step 3, then 4 |
| Static asset 404 | Broken/incomplete file tree (Shape A: the entrypoint's 5s extraction race) | [reference/troubleshooting.md](../reference/troubleshooting.md#pod-is-running-but-the-site-is-broken-shape-a-boot-half-failures) |
| Front 500, `/wp-login.php` 200 | Theme or a front-end-only plugin — login uses neither theme | Step 5 first, then 4 |
| `/wp-admin/` 500, front 200 | Admin-only plugin code | Step 4, reactivation via UI won't work — note it |
| Everything refused / timeout | Web container down — not a 500 | Escalate (platform) |

## Step 3: DB-side evidence **[TCP-mysql]**

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" -e "SELECT 1"
```

If that fails, Step 5. If it works, gather the read-only picture:

```sql
-- Install state + versions (code version is NOT in the DB — infer over HTTP via /feed/ <generator>):
SELECT option_value FROM wp_options WHERE option_name='db_version';
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');

-- What's active (SAVE THIS OUTPUT — you will need it verbatim in Step 4):
SELECT option_value FROM wp_options WHERE option_name='active_plugins';
SELECT option_name, option_value FROM wp_options WHERE option_name IN ('template','stylesheet');
```

Evidence this can surface: a `siteurl`/`home` mismatch (redirect trouble masquerading as "down" — [reference/troubleshooting.md](../reference/troubleshooting.md#redirect-loop)), a recently-grown `active_plugins` list matching "it broke right after I installed X," or a theme name you can disprove over HTTP in Step 5.

## Step 4: Plugin isolation — the gated no-shell fallback **[TCP-mysql]**

With a shell this would be `wp plugin deactivate --all`. Without one, the documented fallback is writing the empty serialized array — one of the few serialized writes that is safe, because the value is a known constant. This is **gated** ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow): "Deactivate all plugins"): **record the current value first**, print the exact SQL, and wait for the user's ack.

1. **Record the current value** (Step 3 already did — confirm you have the exact string saved somewhere durable in the conversation):
   ```sql
   SELECT option_value FROM wp_options WHERE option_name='active_plugins';
   ```
2. Print this to the user and get an explicit ack:
   ```sql
   UPDATE wp_options SET option_value='a:0:{}' WHERE option_name='active_plugins';
   ```
3. Re-probe **[HTTP]**: `curl -sI "http://${WORDPRESS_HOST}/"`.
   - **Site recovers** → a plugin is the cause. Do **not** rebuild the serialized array by hand to bisect ([SKILL.md](../SKILL.md) principle 6) — either restore the exact saved string in one gated `UPDATE` (known value, safe) once the user accepts the broken state back, or (better) have the user log into `/wp-admin` now and reactivate plugins **one at a time via the UI** until the culprit reveals itself.
   - **Still 500** → restore the saved value (gated, exact bytes) and move to Step 5.

## Step 5: Theme fallback / DB health

**Theme** — if the differential pointed at the theme (front 500, login 200), fall back to a default theme. **Verify the target theme exists over HTTP first** — pointing `template`/`stylesheet` at a directory that isn't there replaces one broken site with another:

```bash
# [HTTP] — 200 required before proceeding (twentytwentyfive ships with current WP; verify, don't assume):
curl -sI "http://${WORDPRESS_HOST}/wp-content/themes/twentytwentyfive/style.css"
```

Then, gated ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow): "Theme fallback"): record current values from Step 3, print the exact SQL, and wait for the user's ack:

```sql
UPDATE wp_options SET option_value='twentytwentyfive' WHERE option_name IN ('template','stylesheet');
```

Re-probe. Recovers → the old theme's code is at fault; the user chooses fix-or-replace from `/wp-admin`. Restore the recorded values only once the theme is fixed.

**DB health** — if Step 3's `SELECT 1` failed or WordPress shows the DB-error page:

- Refused/timeout → DB container down; platform action, escalate.
- Auth-plugin error on Shape B (MySQL 8 `caching_sha2_password`) → likely *your client's* limitation, not the site's — see [reference/troubleshooting.md](../reference/troubleshooting.md#mysql-client-cant-authenticate-shape-b--mysql-8) before blaming the DB.
- You connect but WordPress can't → env/config divergence between the web container and reality; escalate with both facts.
- Connected but suspicious → `CHECK TABLE wp_options, wp_posts, wp_postmeta;` (read-only) for corruption evidence.

## Step 6: When to conclude "needs a file channel / support"

Stop and route — with your evidence attached — when the ladder lands on any of:

- Plugins ruled out (Step 4), theme ruled out (Step 5), DB healthy → the fatal is in `wp-config.php`, a must-use plugin, a drop-in (`db.php`, `object-cache.php`), or a damaged core file. All file-channel territory.
- Broken file tree (Step 2, asset 404s) that one platform-side restart didn't heal.
- Stuck `.maintenance` past the ~10-minute self-expiry.
- Any fix that needs the pod's env, resources, or a restart — platform-managed, and capacity is paid ([SKILL.md](../SKILL.md) principle 11).

Routing, in order: things the user can do from `/wp-admin` (if reachable — the differential tells you); the user's Clouve dashboard (pod logs, restart); a support ticket carrying the evidence pack below.

## Step 7: Tell the user

After fixing — or concluding you can't from here:

- The cause (one sentence) and the evidence for it.
- What you changed, with the before-value you recorded, and what you restored.
- What remains open (e.g. "plugins are all deactivated; reactivate one at a time in /wp-admin", "needs a support ticket for the file-side fix").
- The evidence pack for any escalation: shape, HTTP-inferred code version + `db_version`, the Step 2 status table, the Step 3 SELECT outputs, timeline. No secrets, no dump contents.

Don't say "fixed" if you only stopped the symptom — surface root cause and remediation distinctly.
