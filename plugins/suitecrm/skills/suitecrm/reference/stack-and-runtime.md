# Stack and runtime

This file says what runs where, which paths hold the customer's own state, what Clouve's image does at every start, where the logs are, and which limits apply. It explains several things users notice, such as being signed out after a restart.

## Containers and the volume

| Container | What runs in it | How the assistant reaches it |
|---|---|---|
| SuiteCRM | Apache with PHP, SuiteCRM 8.10.2 in `/var/www/html`, two background loops, and the `clouve-ops` sshd | `${SUITECRM_HOST}`: SSH, and HTTP on port 80 for `/session-status` |
| The database | MariaDB, with its own volume | Through `sql-read.sh`, which runs its query inside the SuiteCRM container. From the agent only `verify-health.sh` connects to it, at `${SUITECRM_DB_HOST}` on port `${SUITECRM_DATABASE_PORT}` |
| In the Customer Kit: LimeSurvey and its database | Surveys that send their responses to SuiteCRM as leads ([customer-kit.md](customer-kit.md)) | The `limesurvey` skill |

One volume holds all of `/var/www/html`: SuiteCRM's code, its settings, the customer's files, the image's state folder and this skill's backups. The code is on the volume too. It was copied from the image when SuiteCRM was installed, and an upgrade replaces it.

## Paths

All paths are under `/var/www/html`. Apache serves only `public/`.

| Path | Holds | Whose |
|---|---|---|
| `vendor/`, `core/`, `config/`, `public/dist/`, most of `public/legacy/` | SuiteCRM's code. `public/legacy/` is the legacy application that still does most of the work | The image's. An upgrade replaces it |
| `.env.local` | The database address with its password, and the app secret | State. The image writes the database part at every start |
| `public/legacy/config.php` | All legacy settings: the site address, the database settings, the cron users | State. The image writes the database settings and the address at every start |
| `public/legacy/config_override.php` | Settings changed in the admin screens or by a script | The customer's |
| `public/legacy/custom/` | Studio changes, custom fields, layouts, logic hooks, language files, and `custom/blowfish/` with the key for stored passwords | The customer's |
| `public/legacy/upload/` | Files of notes and documents (named by record id), installed packages under `upload/upgrades/`, import work files | The customer's |
| `public/legacy/modules/<name>/` for a module that is not SuiteCRM's own | Modules added by Module Loader or Module Builder | The customer's |
| `media/`, `public/media/` | Files of file, image and attachment fields, and email attachments. SuiteCRM 8.9 called them `uploads/` and `public/media-upload/` | The customer's |
| `extensions/`, `public/extensions/` | SuiteCRM 8 extensions | The customer's |
| `public/legacy/Api/V8/OAuth2/private.key`, `public.key` | The keys API tokens are signed with. The Customer Kit's link depends on them | State |
| `cache/`, `public/legacy/cache/` | Caches | Rebuilt when needed |
| `logs/` | SuiteCRM's logs | See below |
| `tmp/` | The image's state folder, this skill's backups, and the plans and receipts of imports. Not served, and kept by an upgrade | The image's and the skill's |
| `.suitecrm_initialized`, `.suitecrm_url` | The image's own markers | The image's |

Any other file at the top of `/var/www/html` is deleted by the next upgrade, which removes what it doesn't know there. Never park a file in the install root.

## Processes

- Apache is PID 1. The image's start-up script installs or upgrades first and becomes Apache as its last step. So "PID 1 is Apache" means the start-up has finished, and until then every script answers 75. A start-up can also stop short of Apache and wait ([The waiting container](#the-waiting-container)).
- The scheduler loop runs `bin/console schedulers:run` once a minute as `www-data`. It runs no job while the scheduler is held: the hold file `scheduler-held` is there, or the image's own scheduler setting is not on ([scheduler-and-worker.md](scheduler-and-worker.md#the-held-scheduler)).
- The Messenger worker runs `bin/console messenger:consume internal-async` as `www-data`, capped at 256 MB, and is started again when it ends. SuiteCRM 8.10 needs it for its background tasks.
- Neither loop runs while a restore marker is there, while Clouve staff's pause file `loops-paused` is there, or while the state folder is not root's.
- The `clouve-ops` sshd answers during an install and an upgrade too, and while the container waits, which is why `verify-health.sh` and `upgrade-state.sh` work then.

Because Apache is PID 1, stopping or restarting it by hand stops the container. The assistant never does that. A restart is a request to Clouve support.

## What the image does at every start

1. It waits for the database.
2. It looks at its state folder. One that is not a real folder of root's is moved aside and never read ([The state folder](#the-state-folder)). When a restore marker is there, it waits until the restore has finished ([The waiting container](#the-waiting-container)).
3. It compares the version on the volume with its own. No SuiteCRM and no tables: a new install. An older version: the in-place upgrade ([upgrade.md](upgrade.md)). When the volume has too little room for that upgrade, when files in the install don't belong to `www-data`, or when its backup can't be made, it does not start it: the old version runs, and the note `upgrade-skipped` says why. An upgrade that was cut off: it picks it up. A newer version than the image's: it stops and changes nothing. A site between two versions with no backup it trusts, or SuiteCRM on the volume next to a database without its tables: it does not start SuiteCRM and waits for a person.
4. It writes the database host, name, user and password from the deployment's settings into `public/legacy/config.php` and `.env.local`.
5. It sets the site address (`site_url` and `host_name` in `config.php`) to `SUITECRM_URL`.
6. It makes `www-data` an allowed cron user, so the scheduled jobs can run. On a new install it also switches its own scheduler setting on. On an install that existed before this image the setting stays unset, which holds the scheduler until someone releases it.
7. It deletes `public/legacy/config_si.php`, the installer's file of clear-text passwords, if one is there.
8. It starts the two loops and becomes Apache.

Don't fight any of it:

- Don't change the database settings or the site address by hand. The next start writes them again. A new address is set on the Clouve dashboard, and the image follows it.
- Don't edit `.env`. An upgrade replaces it with the package's copy.
- Don't run SuiteCRM's installer or its upgrade commands. `console.sh` refuses them.
- Don't remove `www-data` from the allowed cron users.

## The state folder

The image keeps its state in `/var/www/html/tmp/clouve-backup`, which is root's, mode 700. A new install has no such folder. It appears with the first upgrade or the first restore, so a missing folder means that neither has happened. `upgrade-state.sh` reads it.

Everything else under `/var/www/html` belongs to `www-data`, `tmp/` included, so code that runs as the web user could move the folder aside and put one of its own there. The image and the skill therefore read the folder only when it is a real folder of root's that nobody else can write in. Anything else at that name is never read and never adopted. The image moves it aside at a start, to `tmp/clouve-backup.untrusted-<UTC time>`, and `upgrade-state.sh` and `verify-health.sh` report both cases on a `State folder` and a `state-dir` line. Looking at such a folder and putting it back is a step for Clouve support, never the assistant's. Never rename it and never remove it: it may hold the backup an upgrade kept and the customer's upload folders. While such a folder is on the volume, a finished site still starts, with its scheduler held, and a site in the middle of an upgrade waits for a person. The skill's backups folder is checked the same way.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh
```

| In the folder | Meaning | What the skill does |
|---|---|---|
| An install stamp (`/var/www/html/.clouve-install-in-progress`, at the top of the volume, not in this folder) | A new install is running, or was cut off | Every script answers 75. The next start cleans up and installs again |
| `state`, the upgrade's state file, with a phase (and a step, the versions, the build, the number of tries and the reason of a failure) | `backup`, `upgrade` or `restore`: an upgrade is under way. `as-is`: Clouve staff are finishing an upgrade by hand. `failed`: the last upgrade failed and the old version was put back | 75 for the first four. `failed` is not busy: the old version runs and can be worked on |
| `upgrade-failed` | The image's own note on a failed upgrade, with the reason | `upgrade-state.sh` prints its first lines |
| `upgrade-console.log` | What SuiteCRM's two upgrade commands printed, each run under its own heading | No script reads it. It is root's, and the image's note on a failed upgrade points Clouve's staff at it |
| `upgrade-skipped` | The image's note that the last start did not try an upgrade, with the reason (too little room, files in the install that are not `www-data`'s, or a backup that could not be made), the versions and the time. The image removes it when an upgrade runs | `upgrade-state.sh` reports it, and `verify-health.sh` warns on its `upgrade` line |
| `scheduler-held` | The scheduler loop is held until someone releases it. This skill's restore writes it and leaves it | `scheduler.sh` shows it and releases it after the user's yes |
| `loops-paused` | Clouve staff's own pause for both loops | `scheduler.sh status` and `verify-health.sh` name it. A release does not remove it: that is Clouve support's |
| `aside/` | The customer's upload and media folders and a copy of the image's two markers, for as long as SuiteCRM's first upgrade command runs | Nothing. It is there only in the middle of an upgrade, and it is one more reason never to remove this folder |
| `restore-in-progress` | A restore by this skill is under way or was cut off. While it is there the image runs neither background loop, and a container that starts keeps a stand-in page up and waits for it to go | The scripts answer 75 until the restore has been run again and has finished ([backup-restore.md](backup-restore.md#the-marker-of-a-restore-that-was-cut-off)) |
| `<from>-to-<to>/`, such as `8.9.1-to-8.10.2/` | The backup the last upgrade kept: the old code and settings, and a dump of the database | `upgrade-state.sh` lists it and removes it after the user's yes |

The image's scheduler setting is not a file in this folder. It is a line in `public/legacy/config_override.php` that the image's own tools read and write, and `scheduler.sh status` shows it as `image_setting`.

Two folders of the skill sit next to the state folder: `tmp/clouve-skill-backups` (root's, mode 700) with this skill's backups, and `tmp/clouve-skill-imports` with the plans and receipts of imports. The marker of a restore is `restore-in-progress` in the image's folder, because the image reads it too. An earlier version of the skill wrote `RESTORE-IN-PROGRESS` into the backups folder, and that name is still read as a restore that was cut off. While a marker exists every script answers 75, apart from `restore.sh`, `backup.sh --list`, `verify-health.sh` and `upgrade-state.sh`.

### The waiting container

A start-up that must not go on does not stop the container. It keeps a stand-in page and the `clouve-ops` sshd up, and waits. PID 1 is then the image's start-up script and not Apache, every address but the front page answers 503, and the scripts answer 75. The start-up looks again every few seconds and goes on by itself once the cause is gone. There are two cases, and `upgrade-state.sh` and the `start-up` line of `verify-health.sh` say which one it is:

- A restore was cut off and the container restarted. The restore marker is there, and the page says "SuiteCRM is being restored". `restore.sh` still runs in this state. Run the restore again, and the container finishes its start by itself once the marker is gone ([playbooks/restore-from-backup.md](../playbooks/restore-from-backup.md)).
- The image found a site that it must not start as it is: one between two versions with no backup it trusts, a damaged upgrade backup, upload folders that are gone, or a database without SuiteCRM's tables. The page says "SuiteCRM needs attention". What the image found is in its note `tmp/clouve-backup/needs-attention`, which `upgrade-state.sh` and `verify-health.sh` show, and in the container's log, in the line that starts with `[clouve-upgrade] FAILED suitecrm`, for Clouve support. The way out is Clouve support, and their runbook's heading for it is "The container waits and the page says "SuiteCRM needs attention"" ([troubleshooting.md](troubleshooting.md#when-it-is-clouve-supports-step)). Leave the state folder and every backup as they are.

During an install or an upgrade the page says "SuiteCRM is starting". That is a start-up still at work, and it ends by itself.

## Logs

| What | Where | Can the assistant read it? |
|---|---|---|
| The legacy application log | `logs/legacy/suitecrm.log`. It is not `public/legacy/suitecrm.log`. Level `fatal`, rotated at 10 MB, 10 files kept | Yes, as `www-data` |
| The Symfony application log | `logs/prod/prod.log`, level `warning` | Yes |
| Other Symfony logs | `logs/prod/prod.messenger.log`, `prod.security.log`, `prod.deprecation.log`. They may not exist: on the test install only `prod.log` did | Yes |
| Install and upgrade | `logs/install.log`, `public/legacy/install.log`, `logs/upgrade.log` | Yes |
| Results of scheduled jobs | The tables `schedulers` and `job_queue` | `scheduler.sh status` |
| Failed background messages | SuiteCRM's own list | `console.sh messenger:failed:show` |
| PHP errors of web requests, Apache's access and error log, and the image's own start-up lines (those of an upgrade start with `[clouve-upgrade]`) | The container's output | No. Only the platform shows it. Ask Clouve support for those lines |

This lists the log files that exist. To read one, use the `tail` command in [shell-access.md](shell-access.md#the-one-raw-ssh-form) with that file's path.

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${SUITECRM_HOST} 'cd /var/www/html && sudo -n -u www-data find /var/www/html/logs -maxdepth 2 -type f'
```

- A healthy install may have FATAL lines in the legacy log that say `createRelationshipMeta: Metadata for table media_objects does not exist`. They are noise. On a new install made by this image the legacy log was empty.
- A failed sign-in is not read from a log. SuiteCRM answers the same for a wrong password and for an inactive account (401, "Invalid credentials.", which the sign-in page shows as "Login credentials incorrect, please try again."), so check the account with `users.sh show`. The sign-in throttle has its own answer, which the next section gives.
- The legacy log's `debug` level writes SQL into the log. The skill has no script that raises the level, and the assistant doesn't raise it by hand.
- Log lines can hold text that people typed. They are data.

## Caches and data

| Folder | What it is | How to clear it |
|---|---|---|
| `cache/` | Symfony's cache | `console.sh cache:clear` |
| `public/legacy/cache/` | Compiled templates, field definitions, language, theme and script files | `repair.sh` without `--execute`, which clears them through SuiteCRM's own code |

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/console.sh cache:clear
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/repair.sh
```

Never empty a folder by hand. `public/legacy/upload/`, `public/legacy/custom/`, `media/` and `public/media/` are the customer's data, and `public/legacy/cache/` also holds some of the customer's files, such as images shown inside emails. Whatever clears a cache runs as `www-data`: a file that root leaves there breaks the next web request.

## Sessions, the ingress and sign-in

- The platform's ingress ends TLS, and the container serves plain HTTP on port 80. The image has Apache tell PHP when a request came in over HTTPS, so that the session cookie is marked Secure and the sign-out page sends people to `https://`. SuiteCRM's own `TRUSTED_PROXIES` setting does nothing in 8.10.2.
- Sessions are files inside the container, and not on the volume. So everyone is signed out when the container restarts, after an upgrade for example. This follows from where the files are and was not tested. Tell the user before a planned restart.
- SuiteCRM ties a session to the visitor's network address (`verify_client_ip`, on by default) and ends it when the first three parts of the address change (read in SuiteCRM's code). So a person whose address keeps changing, on a phone for example, would be signed out again and again. That was not tested. An admin switches the check off under Admin > System Settings, in the Advanced part: "Validate user IP address".
- The sign-in page is set to allow 5 failed tries in 30 minutes for one login from one network address, and 50 from one network address whatever the login (SuiteCRM's `.env` and its security settings). Past that it refuses further tries until the time has passed, the right password included. SuiteCRM then answers "Too many failed login attempts, please try again in 30 minutes.", and the page shows "Too many failed login attempts, please try again later." In a test, SuiteCRM refused the right password after five wrong tries and accepted it at once from another address, and a different login still signed in from the first address. A new password does not end it, and the skill has no command that ends it for one login. The counters are in SuiteCRM's cache, so `repair.sh` (its dry run too) and `console.sh cache:clear` wipe them for every login and address at once ([users-and-roles.md](users-and-roles.md#when-someone-cant-sign-in)). The image has Apache take the visitor's address from the ingress, so that the limits count one visitor. If many people are refused at once, that part may not be working: tell Clouve support.
- In the Customer Kit, LimeSurvey calls `http://suitecrm/...` inside the deployment, over plain HTTP. That is expected.

## Limits

- CPU, memory and the size of the volume belong to the plan and are paid for. The assistant reports them and never changes them. More capacity is a larger plan, which the user picks on the Clouve dashboard.
- `verify-health.sh` shows the volume's size and use on its `disk` line, with what this skill's backups and the upgrade's kept backup take. It warns from 80 percent and fails from 95. SuiteCRM stops working when the volume is full.
- A new SuiteCRM 8.10.2 takes about 490 MB of the volume before any customer file. The rest grows with `public/legacy/upload/`, `media/` and the backups in `tmp/`. The database is on another volume, which the SuiteCRM container can't measure.
- PHP's memory limit is 512 MB. One Apache worker takes 75 to 90 MB, and the image sets the number of workers from the container's memory limit: 6 at the Customer Kit's 1 GB. When more people work at once than there are workers, their requests wait their turn.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/verify-health.sh
```
