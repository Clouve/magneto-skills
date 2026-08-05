# URLs and migration

Two rows in `wp_options` own the canonical site URL. Everything else that looks like a URL — links in posts, `<img>` tags, widget config, theme mods — is embedded content that nothing reconciles for you. Almost every "site redirects somewhere weird", "can't reach wp-admin", or "images broken after the domain change" report resolves to a mismatch between these layers.

## First thing to check

**[TCP-mysql]** Read the two authoritative options:

```bash
MYSQL_PWD="${WORDPRESS_DB_PASSWORD}" mysql -h "$WORDPRESS_DB_HOST" -u "$WORDPRESS_DB_USER" "$WORDPRESS_DB_NAME" \
  -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
```

Compare against the URL users actually hit (scheme included). Any difference — host, scheme, trailing path — is the lead suspect.

## `siteurl` vs `home`

| Option | Settings → General label | What it controls |
|---|---|---|
| `home` | Site Address | The address visitors use. Front-end links, canonical redirects, feed links are built from it. |
| `siteurl` | WordPress Address | Where the core files answer. `/wp-admin`, `/wp-login.php`, `/wp-json`, enqueued core assets are built from it. |

They differ only in subdirectory installs ("WordPress in its own directory"). Neither Clouve shape does that — **on both shapes the two values should be identical**, and a divergence between them is itself a finding, not a configuration style.

Both rows are plain scalar strings (never serialized), which is why they are one of the few URL locations that is safe to edit over raw SQL — see [../playbooks/change-site-url.md](../playbooks/change-site-url.md) for the gated procedure.

`WP_HOME` / `WP_SITEURL` constants in `wp-config.php` override the DB rows entirely (the DB values become dead). Neither shape sets them by default, and checking for them requires a file channel — see [configuration.md](configuration.md) and [shell-access.md](shell-access.md). If the DB values look right but behavior disagrees, hardcoded constants are a hypothesis you currently cannot confirm from the agent — say so rather than guessing.

## Shape A — the env reconciler

The Clouve-packaged installer entrypoint ([entrypoint.sh](https://github.com/Clouve/magneto/blob/develop/apps/wordpress/image/installer/entrypoint.sh)) re-asserts the URL **on every boot**: if the site is installed and `WORDPRESS_SITE_URL` is set, it compares `wp option get siteurl` / `home` against the env var and, on mismatch, runs `wp option update` on both followed by `wp rewrite flush --hard`.

Operational consequences:

- **The env var is authoritative.** A hand edit to `siteurl`/`home` — via SQL, via Settings → General, via anything — silently reverts at the next pod restart. Never fight the reconciler; domain changes go through the platform (SKILL.md principle 4).
- **It is also a safety net.** A botched URL edit on Shape A self-heals: restart the pod and the entrypoint puts both options back to the deployment URL. Lockouts here are temporary by construction.
- **Only those two options.** The reconciler touches nothing else — every embedded URL in content (next section) still points wherever it pointed before. A platform domain change without a follow-up content pass leaves a mixed-host site.

## Shape B — nothing reconciles

The vanilla image runs the stock entrypoint: no `WORDPRESS_SITE_URL`, no reconciliation, no wp-cli. Whatever lands in `siteurl`/`home` — from the browser installer's first-boot guess, or from a later edit — stays until something changes it.

The failure mode that matters: **a wrong `siteurl` locks everyone out of `/wp-admin`.** Login and admin requests redirect to the `siteurl` host; if that host doesn't resolve, doesn't route to this pod, or bounces at the ingress, the admin UI is unreachable — so the usual "fix it in Settings → General" advice is circular. The live recovery path is the TCP-only scalar update in [../playbooks/change-site-url.md](../playbooks/change-site-url.md); it works precisely because these two rows are plain strings.

## Where URLs are embedded in content

Changing `siteurl`/`home` does **not** touch any of these. Attachment URLs are computed from `siteurl` at render time, but the moment an image is inserted into a post the literal absolute URL is baked into `post_content` — that is why media "breaks" after a domain move even though the media files never moved.

| Location | What lives there | Serialized? | Safe edit channel |
|---|---|---|---|
| `wp_posts.post_content` | links, `<img src>`, gallery/shortcode markup, block markup | plain text | serialization-aware search-replace only (consistency with the rest) |
| `wp_posts.guid` | post/attachment *identity*, not location | plain text | leave alone — feed readers treat GUIDs as identity; pass `--skip-columns=guid` |
| `wp_postmeta.meta_value` | custom fields, page-builder blobs (often serialized PHP or slashed JSON) | frequently | serialization-aware tools only |
| `wp_options` → `widget_*`, `sidebars_widgets`, `theme_mods_<theme>` | widget config, custom logo/header image URLs, menu assignments | **yes** | serialization-aware tools only |
| `wp_comments.comment_content` | commenter links | plain text | search-replace |
| Plugin tables (`wp_woocommerce_*`, etc.) | plugin-specific URL storage | varies | serialization-aware tools; check prefix coverage |

## Serialization-aware search-replace vs raw SQL `REPLACE()`

PHP-serialized strings are length-prefixed byte counts:

```
s:27:"https://old.example.com/img";
```

A raw SQL `REPLACE(option_value, 'old.example.com', 'new-and-longer.example.com')` changes the string but **not** the `s:27:` prefix. On the next read, `unserialize()` fails — and WordPress fails *silently*, falling back to defaults. The damage pattern: widgets vanish, the custom logo and theme mods reset, menu assignments drop, WooCommerce settings revert — with no error in any log. It looks like "settings randomly reset", days later, long after the SQL that caused it.

This is SKILL.md principle 6 and a hard gate: **refuse raw SQL string replacement across `option_value` / `meta_value` / any column that can hold serialized data.** The same trap applies to the tempting TCP-only workaround of `mysqldump` → `sed` → reimport — editing the dump with a byte-blind tool corrupts serialized data identically.

The only safe scalar exceptions are (a) `siteurl`/`home` themselves, and (b) writing an **exact serialized literal you computed yourself** (e.g. `a:0:{}` for an empty array) — nothing is string-substituted, so no length can go stale.

### The tool that does it right

**[shell-only — probe first]** wp-cli's `search-replace` unserializes each value, replaces inside the data structure, and reserializes with correct lengths:

```bash
wp search-replace 'https://old.example.com' 'https://new.example.com' \
  --path=/var/www/html --skip-columns=guid --report-changed-only --dry-run --allow-root
# review with the user (safety gate), then re-run without --dry-run
```

wp-cli exists only inside the Shape A `wordpress` container, so this needs a shell channel — which today's WordPress images do not provide (no sshd, no `clouve-ops` account; probe per [shell-access.md](shell-access.md), expect failure). On Shape B the image never ships wp-cli at all, so even a future shell would not help without installing it.

### Live alternatives today (no shell)

1. **wp-admin route**: a serialization-aware search-replace plugin (e.g. Better Search Replace — widely used, has a dry-run mode) installed and driven through `/wp-admin`, then removed. Follow the vetting and gates in [../playbooks/install-plugin.md](../playbooks/install-plugin.md); show the user the dry-run count before the real run.
2. **Defer the content pass**: change only the scalars and accept a mixed-host site for now — pages render, but embedded media/links keep pointing at the old host and break if/when it stops serving. State this trade-off explicitly.
3. **Route to support** when neither is acceptable. Do not improvise a raw-SQL substitute.

## Redirect loops from scheme mismatch behind TLS-terminating ingress

On Clouve, TLS terminates at the platform ingress; the WordPress container speaks plain HTTP on :80. WordPress decides "am I on HTTPS?" per request via `is_ssl()`, which looks at the connection it sees — plain HTTP — unless something maps the `X-Forwarded-Proto` header to `$_SERVER['HTTPS']`.

The loop: `siteurl`/`home` are `https://…`, a request arrives, WordPress sees plain HTTP, issues a canonical 301 to the `https://` URL, the ingress delivers the "new" request over plain HTTP again — `ERR_TOO_MANY_REDIRECTS`.

The official `wordpress` Docker image's generated `wp-config.php` has shipped an `X-Forwarded-Proto` shim for some time (sets `$_SERVER['HTTPS'] = 'on'` when the header says https), and both shapes derive their `wp-config.php` from that generator — so the shim is *probably* present, but confirming it in the file needs a channel you likely don't have. Test behavior instead:

**[HTTP]** differential probe from the agent (set `WORDPRESS_HOST` to the WordPress sibling's hostname — discover via `env | grep -iE 'wordpress|mysql|maria|host'`):

```bash
curl -sI "http://${WORDPRESS_HOST}/" | grep -iE '^(HTTP|Location)'
curl -sI -H 'X-Forwarded-Proto: https' "http://${WORDPRESS_HOST}/" | grep -iE '^(HTTP|Location)'
```

| Without header | With header | Reading |
|---|---|---|
| 301 → same https URL | 200 (or expected page) | Shim works; WordPress is fine — the question is whether the ingress sends the header (platform side; surface it) |
| 301 → same https URL | 301 → same https URL | Shim absent or overridden; needs a `wp-config.php` fix (file channel — route to support) |
| 200 | 200 | No scheme loop here; look elsewhere |

The **opposite** mismatch — `siteurl`/`home` still `http://` while users arrive over `https://` — doesn't usually loop but breaks differently: absolute `http://` asset links (mixed-content blocking) and login redirects that bounce to `http://` and back. Fix is the same in both directions: make both options exactly the public URL, scheme included, via [../playbooks/change-site-url.md](../playbooks/change-site-url.md).

## Related

- [../playbooks/change-site-url.md](../playbooks/change-site-url.md) — the gated procedure, per shape, with verification and rollback.
- [data-model.md](data-model.md) — serialized-PHP hazards in full; never-touch tables.
- [configuration.md](configuration.md) — `WP_HOME`/`WP_SITEURL` and the other `wp-config.php` constants.
- [stack-and-runtime.md](stack-and-runtime.md) — telling the two shapes apart.
- [shell-access.md](shell-access.md) — the channel matrix and the shell probe.
