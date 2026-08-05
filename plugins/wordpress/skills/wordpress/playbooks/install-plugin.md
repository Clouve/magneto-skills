# Playbook: Install a plugin

Use this whenever the user wants to add a WordPress plugin that is not already present. The honest headline: **installing a plugin means running the installer, and the agent has no way to run a WordPress installer without a shell — which today it does not have.** So the realistic flow is *the user installs from `/wp-admin` while you vet, guide, and verify over the channels you do have* ([TCP-mysql] + [HTTP]). The `wp-cli` path is documented for the day a shell exists.

## Read first — a plugin is arbitrary PHP

A plugin executes arbitrary PHP inside the WordPress container with **full database access and filesystem write**. Treat installing one like standing up a new server-side service, not like a UI tweak. This is SKILL.md principle 9 and the **"install / update / delete a plugin or theme"** gate: *trusted source verified + backup + user ack; never via SQL.* You never write a plugin into the site through the database — activation records in `active_plugins` are the *result* of an install, not a way to perform one.

Unlike the Moodle packaging, on **Shape A** WordPress `wp-content/` sits on the **persistent `wordpressdata` volume**, so a plugin the user installs from `/wp-admin` **survives pod restarts** — this is a durable change, not an experiment that evaporates. That cuts both ways: a bad plugin also persists until it is removed, which is why the backup precondition is not optional. On **Shape B**, persistence depends on the developer's compose declaring a volume for `/var/www/html` — verify (ask the developer / check the compose) before promising an install survives a restart; without a volume, plugins, themes, and uploads are lost on every pod restart.

## Preconditions

- [ ] **Backup taken** ([../scripts/backup.sh](../scripts/backup.sh)). A plugin's activation hook can extend the schema and write options; the backup is your restore point.
- [ ] User has named the **exact plugin** (the wordpress.org slug, e.g. `wordfence`, or a specific vendor zip) **and** its source.
- [ ] **Source vetted** as trusted (below).
- [ ] Deployment shape known and shell status probed ([../reference/shell-access.md](../reference/shell-access.md)) — it decides which path you take.
- [ ] **Shape B only: persistence verified.** Confirm the developer's compose declares a volume for `/var/www/html` (ask the developer / check the compose) before promising the install survives a restart — without one, plugins, themes, and uploads are lost on every pod restart. This changes what you tell the user at the end.
- [ ] User ack on doing the install.

## Vetting the source

Before anything is installed:

1. **Prefer the canonical registry.** [wordpress.org/plugins](https://wordpress.org/plugins/) listings have passed baseline review, publish an active-install count, a "tested up to" version, and a last-updated date. A plugin not updated in 2+ years, or with no "tested up to" near the running core version, is a risk even if popular.
2. **Reject unvetted zips.** A zip from a random link, a nulled/"premium-for-free" site, or an unknown GitHub fork is untrusted by default. Nulled plugins are a classic backdoor vector — refuse them and say why.
3. **Match it to the site.** Confirm the plugin's minimum PHP/WordPress version is satisfied by the running core (fingerprint it over **[HTTP]**: `curl -s "http://${WORDPRESS_HOST}/" | grep -i '<meta name="generator"'`). Installing a plugin that requires a newer core than the image ships will fatal on activation.
4. **If the user insists on a third-party source**, surface the risk explicitly and get an unambiguous ack that they accept it. You cannot statically audit the PHP without a shell to unpack it — say so; don't imply a review you didn't do.

If vetting raises a concern, name it and ask the user to pick a different plugin.

## Path A (the real one today) — user installs via `/wp-admin`, you verify

Use this whenever the shell probe fails (the normal case).

### A1. Capture the "before" state — [TCP-mysql]

Record what is active now, so you can diff after and so you have the value to restore if activation white-screens:

```bash
env | grep -iE 'wordpress|mysql|maria|host'   # discover DB creds/host

MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT option_value FROM wp_options WHERE option_name='active_plugins';"
```

Save that serialized value verbatim (this is also the recorded-state the WSOD gate wants). Confirm the site is healthy first: `curl -sI "http://${WORDPRESS_HOST}/"` → 200.

### A2. Guide the install

Tell the user, in order:

1. `/wp-admin` → **Plugins → Add New Plugin**.
2. Search for the vetted slug (or **Upload Plugin** for a vetted zip).
3. **Install Now**, then **Activate**.

Snag to warn them about up front: on the Clouve-packaged shape the entrypoint only re-chowns `wp-content/uploads/`, so the `plugins/` directory may be **root-owned and not writable by `www-data`**. If so, `/wp-admin` will prompt for **FTP credentials** instead of installing directly (WordPress falling back from the `direct` filesystem method). That is a permissions/file-channel problem the agent cannot fix from here — route it: the user (or the platform/image) needs the `plugins/` dir writable by the web user, or `define( 'FS_METHOD', 'direct' );` plus correct ownership in `wp-config.php`. *(General WordPress behavior — confirm against the specific image if it bites; the exact ownership the official image leaves can vary.)*

### A3. Verify — [TCP-mysql] + [HTTP]

```bash
# 1. The plugin now appears in active_plugins as "<slug>/<slug>.php":
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "${WORDPRESS_DB_HOST}" \
  -u "${WORDPRESS_DB_USER}" "${WORDPRESS_DB_NAME}" -N -e \
  "SELECT option_value FROM wp_options WHERE option_name='active_plugins';"

# 2. The site still returns 200 (a fatal-on-activation plugin white-screens it):
curl -sI "http://${WORDPRESS_HOST}/" | head -1
curl -sI "http://${WORDPRESS_HOST}/wp-login.php" | head -1
```

Also confirm, over the user's browser or HTTP, that the plugin's own settings page loads and that the expected new option rows exist (many plugins write `<slug>_*` options on activation — a quick `SELECT option_name FROM wp_options WHERE option_name LIKE '<slug>%';` shows them). If the homepage or `/wp-admin` now 500s, you're in [diagnose-500.md](diagnose-500.md) — go there and roll back.

## Path B (when a shell exists) — `wp plugin install` — [shell-only — probe first]

Only if the `clouve-ops` probe succeeds:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new "clouve-ops@${WORDPRESS_HOST}" \
  "wp --path=/var/www/html plugin install '<slug>' --activate --allow-root"
```

**Post-install ownership caveat (Shape A).** `--allow-root` writes the new plugin files as **root**, but the entrypoint only re-chowns `wp-content/uploads/` on boot — so these root-owned files persist and will later block `www-data`-driven updates or auto-updates of that plugin. Re-chown after installing:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD}" sshpass -e ssh \
  -o StrictHostKeyChecking=accept-new "clouve-ops@${WORDPRESS_HOST}" \
  "chown -R www-data:www-data /var/www/html/wp-content/plugins/<slug>"
```

Then run the same **A3** verification (active_plugins + site 200).

## Rollback — deactivate

Activation broke the site, or the plugin isn't wanted:

- **Preferred — `/wp-admin` (Path A) or `wp plugin deactivate <slug> --allow-root` (Path B):** deactivates just that plugin, cleanly.
- **[TCP-mysql] fallback — deactivate *all* plugins only.** You can safely blank `active_plugins` to the empty-array constant `a:0:{}`, but you must **not** hand-edit the serialized array to remove a single entry — a byte-count mismatch silently corrupts it (SKILL.md principle 6). Deactivating everything is the WSOD-isolation move and it has its own gate (**record the current `active_plugins` first + ack** — you captured it in A1). The full procedure, including restoring the saved value, lives in [diagnose-500.md](diagnose-500.md); use it rather than free-handing the SQL here.

After any rollback, re-verify the site returns 200 and tell the user exactly what state the plugin set is in now.

## Tell the user

- Whether the plugin is installed and active, with the evidence (its entry in `active_plugins`, site still 200, settings page loads).
- On **Shape A**: that the change **persists** across restarts (it's on the `wordpressdata` volume) — this is durable, for better and worse. On **Shape B**: only promise persistence if you verified a volume covers `/var/www/html` (precondition above); otherwise warn that the plugin is lost on the next pod restart.
- Any snag you routed to them (FTP-credentials prompt, a permissions fix, a source you couldn't audit).
- If you rolled back: what failed and what the current plugin set is.
