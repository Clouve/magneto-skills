# Notable changes in Moodle 5.3

What changed from Moodle 5.2 that you, or the school's admin, need to know. Sources: the [5.3 release notes](https://moodledev.io/general/releases/5.3), the `## 5.3` section of [UPGRADING.md](https://github.com/moodle/moodle/blob/v5.3.0/UPGRADING.md), [public/admin/environment.xml](https://github.com/moodle/moodle/blob/v5.3.0/public/admin/environment.xml), and the code of both releases. What the Clouve image does comes from its installer, [apps/moodle/image/installer/](https://github.com/Clouve/magneto/tree/develop/apps/moodle/image/installer) in Clouve/magneto. The 5.1 to 5.2 changes are in [changes-in-5.2.md](changes-in-5.2.md) and still hold.

Moodle 5.3 is a long-term support release. The Clouve image pins one build: `5.3 (Build: 20261005)`, `$version` `2026100500`, branch `503`, tag `v5.3.0`.

## How a 5.2 site gets to 5.3

A site upgrades once, at the first start of its `moodle` container on the 5.3 image, and nobody runs `upgrade.php` for it. The entrypoint sees that the image's `$version` (2026100500) is higher than the one recorded in `/var/www/html/clouve/installed/version` (2026042000 on a 5.2 site). It then runs the upgrade in maintenance mode, before Apache starts. [upgrade.md → The upgrade on Clouve](upgrade.md#the-upgrade-on-clouve) has the steps. On a big site the start takes as long as Moodle's upgrade does.

To see where a site stands:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo grep -m1 -F "\$version" /var/www/html/public/version.php; sudo cat /var/www/html/clouve/installed/version; sudo ls /var/www/html/clouve/installed/ /var/www/html/clouve/upgrade-stash/'
```

An upgraded site shows `$version  = 2026100500.00;`, then `2026100500`, and a `5.3` file next to the `5.2` one. `upgrade-stash/` exists only once an upgrade has held a plugin back. The image's own copy of Moodle is in `/clouve/moodle/moodle-5.3/`.

The upgrade's lines go to the container log, which you can't read from the pod; Clouve support can. Moodle's own record of it is in `mdl_upgrade_log` (see [data-model.md](data-model.md)).

## Before the upgrade

When the user asks ahead of time what 5.3 will change, check three things and tell them:

1. **Who uses the Classic theme.** The site theme (`SELECT value FROM mdl_config WHERE name = 'theme'`), and categories, courses, cohorts and users: `SELECT COUNT(*) FROM mdl_course WHERE theme = 'classic'`, and the same for `mdl_course_categories`, `mdl_cohort` and `mdl_user`. Also look for `$CFG->theme` in `config.php` (`sudo grep -n 'CFG->theme' /var/www/html/config.php`, which shows that line only). The next section says what happens to each.
2. **Which added plugins 5.3 will hold back.** For each plugin an admin added, read `$plugin->supported` and `$plugin->incompatible` in its `version.php`. A `supported` range that ends at `502`, or an `incompatible` of `503` or lower, means the upgrade holds it back.
3. **Whether the site has its own `report_aiusage` or `aiprovider_anthropic`.** Both are part of 5.3. Look for `public/report/aiusage/` and `public/ai/provider/anthropic/` in the code tree. If either is there, see [A site the image doesn't upgrade](#a-site-the-image-doesnt-upgrade).

Then take the backup as [playbooks/upgrade-moodle.md](../playbooks/upgrade-moodle.md) says.

## The Classic theme is gone

5.3 no longer has the Classic theme (MDL-88351). A single upgrade step handles that, and it runs only when Classic's code is missing. On Clouve it always is: Classic was part of 5.2, so the image never copies it into the new code.

- If the site theme is Classic (in the database, or forced in `config.php`), Moodle copies the Classic settings the admin changed to Boost, then switches the site to Boost. Those settings are the brand colour, the raw initial and raw SCSS, the background and login background images, and the unaddable blocks. Boost settings that Classic left at their default stay as they were, so a site that had customised both themes ends up with a mix: check it.
- Lost on the way: theme presets and uploaded preset files (make an equivalent Boost preset), the Classic-only dark navbar, and block positions. Classic had two block columns, Boost has one, so blocks from Classic's right-hand column are shown at the end of Boost's block region, in a new order. Raw SCSS that used Classic variables or partials may need fixing.
- Then Moodle uninstalls Classic. That deletes its settings and blanks the theme of every category, course, cohort and user that had picked Classic, so they follow the theme above them again (the category's, then the site's).
- Moodle's upgrade can't change a value forced in `config.php`, and a forced `'classic'` would make Moodle ask for the missing theme on every page and fall back to the default with a warning. So the image turns a line that only says `$CFG->theme = 'classic';` into a comment that says why. Any other line that sets Classic is left alone and named in the log as one to change by hand.
- A theme based on Classic (an added theme whose `parents` include `classic`) is kept, but it can't load without Classic: Moodle shows its default theme instead until that theme has a release for 5.3.

Tell the admin to look over the front page, a course and the block layout after the upgrade, and the Boost settings (Site administration → Appearance → Themes → Boost) if Classic was customised.

A school that wants Classic back can install it as an added plugin from [moodlehq/moodle-theme_classic](https://github.com/moodlehq/moodle-theme_classic) (follow [playbooks/install-plugin.md](../playbooks/install-plugin.md), and check that its `version.php` supports `503`). After the upgrade it starts clean: its old settings went to Boost, and courses and users have to pick it again. Moodle's way to keep Classic with its settings is to install it before the upgrade, which doesn't fit Clouve, where the upgrade runs at the first start of the new image. Later upgrades carry an added Classic over like any other added plugin.

## Plugins the admin added

The upgrade copies them into the new code, as it did before 5.3, and holds one back in `/var/www/html/clouve/upgrade-stash/<UTC time>/` when:

- 5.3 ships it itself;
- its `version.php` marks it incompatible with 5.3, or it needs a plugin the new site won't have;
- (new in 5.3) its `$plugin->supported` range covered 5.2 (`502`) and stops before 5.3 (`503`). Moodle itself would only warn, but the author hasn't said the plugin works on 5.3. A plugin that was already outside its range on 5.2 is kept, with a warning;
- Moodle's upgrade fails twice on it: the image then holds back that plugin alone and runs the upgrade again. When the failure doesn't name an added plugin, it holds back all of them and runs the upgrade once more.

A held-back plugin's data stays in the database. To bring it back, install a release that supports 5.3: [playbooks/install-plugin.md → Putting back a held-back plugin](../playbooks/install-plugin.md#putting-back-a-held-back-plugin).

### A site the image doesn't upgrade

5.3 includes two new plugins: `aiprovider_anthropic` (Anthropic Claude API provider) and `report_aiusage` (AI usage, a course report). A site whose admin had added either one gets 5.3's own copy. If the added copy has a higher version than 5.3's, though, Moodle can't go back to the older one. The image then upgrades nothing: the site keeps running its 5.2 code (Apache, cron and the clouve-ops shell start as usual), no new version is recorded, and every start checks again. The container log says `NOT UPGRADED` and names the plugin.

You see it as `public/version.php` and `/var/www/html/clouve/installed/version` both still at 2026042000 on the 5.3 image. There are two ways out, and the user picks:

- **Wait** for an image whose Moodle has a newer copy of the plugin. The site stays on 5.2 until then.
- **Uninstall the added plugin in Moodle, and make sure its folder is gone.** This deletes the plugin's data, so take the backup first and get the user's ack. Uninstall it while the site still runs 5.2: Site administration → Plugins → Plugins overview → Uninstall, or `admin/cli/uninstall_plugins.php --plugins=report_aiusage --run` (see [playbooks/install-plugin.md → Uninstalling](../playbooks/install-plugin.md#uninstalling)). Removing only the folder isn't enough: the database still records the newer version, and Moodle's upgrade then stops with "Cannot downgrade". The upgrade to 5.3 runs at the container's next start; ask Clouve support if it should happen sooner.

## Requirements

From `environment.xml`; only two floors moved:

| | 5.2 | 5.3 |
|---|---|---|
| Upgrade from | 4.4 or later | 4.4 or later |
| PHP | 8.3.0 | 8.3.0 |
| MySQL | 8.4 | 8.4 |
| MariaDB | 10.11.0 | **11.4.0** |
| PostgreSQL | 16 | **17** |
| SQL Server | 15.0 | 15.0 |
| PHP extensions and settings | | the same as 5.2 |

The Clouve image runs PHP 8.3 and MySQL 8.4, so it needed no change. The code layout is the same as 5.2: `config.php` and `admin/cli/` at the root, the webroot in `public/`.

## New for the site's admin

- New-login notifications are forced on for new sites (MDL-89465). The Security report has a new check, "Security message notifications" (`core_securitymessages`). It warns until the "New login" notification is enabled and locked for every enabled output (web, email, mobile). A new 5.3 site passes; a site upgraded from 5.2 keeps its old notification settings, so it warns. The fix is in Site administration → Messaging → Notification settings. Users then get a notification, by email too, when they sign in from a device Moodle hasn't seen before, so let the admin decide.
- AI: the Anthropic provider and the AI usage report above. The upgrade turns neither on.
- Personal access tokens: 5.3 has an OAuth 2 server, and users can create tokens for the REST API at `/user/personalaccesstokens.php`. `login/token.php` checks requests more strictly and no longer takes `appsitecheck`.
- Boost: Noto Sans is the default font, the primary and secondary navigation are React components, the login form template moved from Boost to core, the course index has one collapse/expand-all button, and there is an experimental dark mode (Boost setting `enablecolourmodes`). Check any theme based on Boost that overrides the navigation or login templates.
- `config.php`: `$CFG->showcampaigncontent` is no longer read (the campaign banner is gone). The admin Notifications page shows "From Moodle" cards instead, which the new `$CFG->disablenotificationctas` hides (config.php only). `define('USER_DESCRIPTION_MAX_LENGTH', …)` is new too.
- TeX and Algebra filter images move from `<dataroot>/filter/tex` and `filter/algebra` into Moodle's file storage during the upgrade.

## CLI and cron

- The scripts this skill uses are where they were, with the same options: `upgrade.php`, `cron.php`, `maintenance.php`, `purge_caches.php`, `install_database.php`, `kill_all_sessions.php`, `cfg.php`, `backup.php`, `restore_backup.php`, `check_database_schema.php`.
- `scheduled_task.php` takes `-e` for `--execute`, and `--execute` without a task runs every task that is due. In the web UI, "Run now" can run a task in the background.
- `reset_password.php` still only finds `auth = 'manual'` users, and the Education Kit's user sync is still `public/auth/db/cli/sync_users.php`, setting `create_password` on each user it creates. See [playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md).
- New at the root: `bin/moodle`, a Symfony Console command line. Keep using `admin/cli/*.php`, which this skill documents.

## For plugin code

When you vet a plugin ([playbooks/install-plugin.md](../playbooks/install-plugin.md)), these show up as debugging notices on 5.3. They still work:

- the `user/lib.php` functions such as `user_create_user()`, `user_update_user()` and `user_delete_user()`, replaced by `\core\user::create_user()` and friends;
- the old `\external_*` classes;
- `FEATURE_GROUPMEMBERSONLY`.

`hash_internal_user_password()`, `update_internal_user_password()`, `validate_internal_user_password()`, `get_auth_plugin()` and `is_enabled_auth()` now wrap new core classes but are not deprecated. A password set for a user synced from Gibbon still needs `unset_user_preference('create_password', $user)` right after it, as [playbooks/rotate-admin-credentials.md](../playbooks/rotate-admin-credentials.md) says.

## Checks that fail on every Clouve site

These aren't new in 5.3; a 5.2 site has them too. Tell the user what they are rather than trying to fix them from inside the site:

| Check | Result | Why |
|---|---|---|
| `core_router` (status) | ERROR | "The router is not configured": the image doesn't set `$CFG->routerconfigured` or route requests to `r.php`. Because of it, `checks.php` (the status set) exits 2 on every Clouve site. |
| `core_publicpaths` (security) | ERROR | Apache serves files under `public/` that Moodle wants hidden (`admin/environment.xml`, `lib/db/install.xml`, READMEs, `upgrade.txt`, `tests/fixtures/`, `tests/behat/`). |
| `core_configrw`, `core_preventexecpath`, `core_riskbackup` (security) | WARNING | Image and site settings; see [security.md](security.md). |
| `core_cookiesecure` (security) | WARNING | Only on a site reached over plain HTTP. |
| `tool_task_cronrunning` (status) | CRITICAL | Only until cron has run once. |

The first two need a change in the image, so they belong in a Clouve support ticket.

Also on both releases:

- `checks.php --type=security` can stop with `Class "curl" not found`: the public-paths check uses Moodle's `curl` class without loading `lib/filelib.php`. Read the Security checks report in the web UI instead.
- `GET /` answers 303 to `/login/index.php`, because a new Clouve site has `forcelogin` on. Probe `/login/index.php`, which answers 200.
- `cron.php` stays alive for about three minutes after its tasks (`cron_keepalive`), and the image starts one every minute, so `ps` shows several at once and "Moodle Cron Completed Successfully" turns up in `/var/log/moodle-cron.log` minutes late. That is normal: "Scheduled task complete:" lines show the tasks ran.
