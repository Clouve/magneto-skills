# Backup and restore

This file says what a complete backup of SuiteCRM is, what [backup.sh](../scripts/backup.sh) saves and leaves out, what [restore.sh](../scripts/restore.sh) replaces and keeps, and where the limits are. Both scripts run inside the SuiteCRM container as root, sent there by [run-in-suitecrm.sh](../scripts/run-in-suitecrm.sh). The steps are in [playbooks/back-up.md](../playbooks/back-up.md) and [playbooks/restore-from-backup.md](../playbooks/restore-from-backup.md).

## What a complete backup is

A complete backup is a dump of the database together with the files that hold the customer's own state, both from the same moment. A dump alone gives records whose attachments are missing and custom fields whose definitions are missing. SuiteCRM's code is not part of it: the code comes from the image.

## What backup.sh saves

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --list
```

A backup is a folder `/var/www/html/tmp/clouve-skill-backups/<UTC time>/`, named like `20261112-101500`. The folder is root's, mode 700, and its files are mode 600.

| File | Holds |
|---|---|
| `db.sql.gz` | One consistent dump of SuiteCRM's database |
| `state.tar.gz` | `.env.local`, `public/legacy/config.php` and `config_override.php`, `public/legacy/custom/` (with the key that decrypts stored passwords), `public/legacy/upload/`, `public/legacy/cache/images/` (the pictures of email templates), the modules that are not SuiteCRM's own, the OAuth2 key pair, `media/` and `public/media/`, `extensions/` and `public/extensions/`, and the image's two markers |
| `manifest.txt` | When it was made, the SuiteCRM version, the site address, the number of tables and files, the sizes |
| `SHA256SUMS` | Checksums of the two files |
| `COMPLETE` | Written last. A folder without it is not a backup, and `restore.sh` refuses it |

What it leaves out, and why:

- SuiteCRM's own code (`vendor/`, `core/`, `public/dist/` and the rest). It comes from the image. This is why a backup restores onto the same SuiteCRM version only.
- `cache/`, `logs/` and `tmp/`. Caches are rebuilt, and `tmp/` holds the backups themselves and the image's state.
- The rest of `public/legacy/cache/`. SuiteCRM rebuilds it. Only `public/legacy/cache/images` is in a backup, because SuiteCRM keeps the pictures of email templates there and nothing makes them again.
- The work files of imports under `public/legacy/upload/import`.
- `config_si.php`, the installer's file of clear-text passwords. It is never in a backup.

How it works, as far as it matters to you:

- The backup is written under a temporary name, `<name>.partial`, checked (the dump's and gzip's exit codes, a test of both archives, the dump's closing line, the archive's listing), renamed, and only then stamped `COMPLETE`. If anything fails or the script is stopped, the unfinished folder is removed. A run that is killed outright can leave its `<name>.partial` behind: `--list` shows it, `--remove` takes its name, and the next backup removes one that is older than a day.
- Before it writes anything, it compares the free space on the volume with its estimate times 1.2. With too little it ends with 2 and says how many MB it needs and how many are free.
- One backup or restore runs at a time. A second backup, restore or `--remove` that starts meanwhile ends with 2 at once and changes nothing. The lock goes when the process ends, however it ends.
- The backups folder has to be a real folder of root's that others can't write in. SuiteCRM's tree is `www-data`'s, `tmp/` included, so code that runs as the web user could move the folder aside and plant its own. A folder that fails the check is refused with 2 and never changed: that is a step for Clouve support. Root includes no file of the web user's: SuiteCRM's settings are read by PHP that runs as `www-data`, and `www-data`'s own `tar` reads the files.
- The database password is read from SuiteCRM's own `config.php` that way and handed to the client in a private file outside the volume. It is never in a command line or in the output.
- Nothing removes old backups by itself. Each backup ends with a line that says how many the skill keeps and how large they are together.
- A backup of a small install takes seconds. For a large one, start it detached and read it back ([shell-access.md](shell-access.md#long-runs)).

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --detach backup.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --status '<job>'
```

Exit codes of `backup.sh`: 0 done, 64 usage or `--remove` without the yes, 1 SuiteCRM's settings or its database can't be read or the database lacks SuiteCRM's tables, 2 not enough free space, another backup or restore is running, or the backups folder is not root's, 3 the dump or the archive failed and nothing was kept, 4 no such backup.

## Sizes and space

The backups sit on the same volume as SuiteCRM, and so does the backup an upgrade keeps. `backup.sh --list` shows each backup with its size and ends with their number and total, and the `disk` line of `verify-health.sh` shows what they take together. On a nearly empty install a backup is under 1 MB. A real one grows with `public/legacy/upload/`, `media/` and the database.

When space runs short, the choices are an old backup the user names ([Removing a backup](#removing-a-backup)), the upgrade's kept backup once the user has checked the upgraded site ([upgrade.md](upgrade.md)), or a larger plan. Never remove customer files to make room.

A complete backup counts as recent for 24 hours. That is the backup `import-csv.sh`, `packages.sh` and `repair.sh --execute` ask for before they change many things at once (exit 76 without one).

## The same-version rule

A backup holds no code, and a database of one SuiteCRM version on the code of another breaks SuiteCRM. So `restore.sh` compares the version in the backup's `manifest.txt` with the installed one and refuses with exit 2 when they differ. Two things follow:

- A backup made before an image upgrade can't be restored after it. Take a new backup after every upgrade, and tell the user that the older ones no longer restore.
- The way back to an older version is the backup the image's upgrade keeps, and only the image uses it ([upgrade.md](upgrade.md)).

## What restore.sh replaces and keeps

The preview changes nothing and ends with 64. It prints when the backup was made, its version, and what SuiteCRM holds now: the number of tables, accounts, contacts, leads, opportunities and users that a restore would replace. It also says how many campaign emails were waiting in the queue when the backup was made, that the restore holds the scheduler, and on a `Space:` line how much room the backup's files need.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh restore.sh --backup '<backup>'
```

| A restore replaces | A restore keeps from this deployment |
|---|---|
| Every table of SuiteCRM's database: records, users and their passwords, roles, settings, the audit trail. Whatever was entered since the backup is gone | The database's address, name, user and password in `config.php` |
| `public/legacy/custom/`, `public/legacy/upload/`, the added modules, `media/`, `public/media/`, `extensions/`, `public/extensions/` | The site address (`site_url` and `host_name`) |
| `config_override.php`, the OAuth2 key pair, and the pictures of email templates in `public/legacy/cache/images` | `.env.local` |

When SuiteCRM had no `public/legacy/cache/images` folder at the time of the backup, the archive holds none, and the restore leaves the pictures that are there. The preview says which it is.

Because it keeps the deployment's own settings, a restored SuiteCRM still answers at this deployment's address and reaches this deployment's database.

Before it changes anything, `restore.sh` checks these things and refuses when one fails:

- No other backup or restore of this skill is running. Exit 2 if one is.
- The backups folder, the backup and the image's state folder are real folders of root's that others can't write in. Exit 2 if not: that is a step for Clouve support.
- The backup has its `COMPLETE` stamp, its checksums hold and both archives are whole. Exit 3 if not.
- The archive holds only files, folders and links that stay inside SuiteCRM's tree: no device file, no absolute path, no path with `..`, no link that points outside. Exit 3 if not.
- The backup's SuiteCRM version is the installed one. Exit 2 if not.
- A complete backup of the current state from the last 24 hours exists, other than the one being restored, so that the restore itself can be undone. Exit 2 if not.
- The backup's files fit on the volume. Exit 2 if not, before any table is dropped.

A restore always runs detached, after a fresh backup and the user's clear yes. Ask the user to have everyone stay out of SuiteCRM until it is done: what people save during those seconds can be lost.

Gate. Show the user the preview: what is replaced, what would start again, and that the scheduler stays held afterwards. Wait for a clear yes that names the backup.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --detach restore.sh --backup '<backup>' --yes-replace-current-data
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --status '<job>'
```

Once it starts, it holds the scheduler and writes its marker. Then it drops every table and loads the dump, replaces the folders, writes this deployment's settings back into `config.php`, clears the caches, and checks that the tables are back, that SuiteCRM reports the right version and that the app answers. The file work in SuiteCRM's tree is done as `www-data`. A restore never keeps an owner, a set-user-ID or set-group-ID bit or a device file from an archive: everything it brings is `www-data`'s. It removes the marker last and leaves the scheduler held. Afterwards everyone has to sign in again. Run `verify-health.sh`, and `repair.sh` as a dry run: if it reports SQL, the files and the database don't match.

Exit codes of `restore.sh`: 0 restored, 64 usage or the preview, 1 SuiteCRM's settings or database can't be read, 2 a check refused it (another version, no fresh backup, not enough free space, another backup or restore is running, a folder that is not root's), 3 the backup is missing, incomplete, damaged or holds something a backup never holds, 4 the restore failed after it began, 75 the image is installing or upgrading, or the container is still starting and no restore was cut off.

## What a restore starts again

The dump holds more than records. It brings back the campaign email queue, the workflows and the scheduled reports as they were when the backup was made. SuiteCRM takes a campaign message out of its queue when it has sent it, and it notes which records a scheduled workflow has dealt with. A backup from before a send has the messages still in the queue and none of those notes. So with a running scheduler, email that went out after the backup would go out a second time within a minute of the restore, and scheduled workflows would run again over records they had dealt with.

That is why a restore holds the scheduler. Before it changes anything it writes the hold file `tmp/clouve-backup/scheduler-held`, and it leaves the file when it ends. Its last lines say what is waiting as of the backup (campaign emails in the queue and due, scheduled workflows, scheduled reports) and that the scheduler is held. Nothing scheduled runs until the user has seen what is waiting and says to release it: `scheduler.sh queued` shows it, and `scheduler.sh release --yes-release` lets it go ([scheduler-and-worker.md](scheduler-and-worker.md#the-held-scheduler)). Say this to the user before the restore, and again when it is done.

## The marker of a restore that was cut off

A restore writes the file `tmp/clouve-backup/restore-in-progress` before it changes anything and removes it when the restore is complete. The file is root's, and it sits in the image's state folder because the image reads it too. An earlier version of the skill wrote `tmp/clouve-skill-backups/RESTORE-IN-PROGRESS`, and that name is still read as a restore that was cut off. While a marker exists, SuiteCRM may be half restored:

- Every other script of the skill answers 75, a new backup and `backup.sh --remove` included. `backup.sh --list` still works, so you can see the names of both backups: the one being restored and the fresh one taken before it.
- The image runs neither the scheduler nor the Messenger worker.
- `verify-health.sh` reports RED on its `restore` line and names the marker.
- A marker with a job that `--status` shows as running is a restore still at work. Wait for it.
- A restore that failed ends with 4 and keeps the marker and the hold, and its output names the step. Run the restore again, of the same backup or of the one taken just before it. Running it again is always safe. No new backup is asked for then, because a backup of a half-restored state is worth nothing.
- A container that restarts while the marker is there does not start SuiteCRM. It keeps a stand-in page up that says "SuiteCRM is being restored", with the SSH channel, and waits for the marker to go. PID 1 is then not Apache, and `upgrade-state.sh` says `the container is waiting: a restore was cut off (run the restore again)`. `restore.sh` still runs in that state. When it is complete, the container finishes its start by itself.
- Never remove the marker by hand. If the restore keeps failing at the same step, that is a request to Clouve support.

## A backup on the same volume is not disaster recovery

The backups protect against a bad change, an import or a package that went wrong. They are on the same volume as SuiteCRM, so they are lost with the volume or the deployment. Say that when a user asks whether their data is safe.

The skill has no script that copies a backup off the deployment. What works is this: stream one backup folder as a tar file into the agent user's home, where the Files pane shows it, and have the admin download it from there. Check the backup's size with `--list` first, because the agent's home needs room for it, and give the call a longer timeout for a large one.

Gate. The copy holds the whole database: every customer record, every user's password hash, and the settings with the database password. Say that to the user, make the copy only when they asked for it, and wait for a clear yes.

```bash
install -m 600 /dev/null ~/suitecrm-backup-'<backup>'.tar
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${SUITECRM_HOST} 'sudo -n tar -C /var/www/html/tmp/clouve-skill-backups -cf - "$(cat)"' <<< '<backup>' > ~/suitecrm-backup-'<backup>'.tar
tar -tf ~/suitecrm-backup-'<backup>'.tar
```

The first line makes an empty file that only the agent user can read, and the second fills it. The backup's name goes in on stdin, so it is never part of the remote command. The listing should show the backup's folder with the five files of the table above.

The tar file holds the whole database, every customer record, and the settings with the database password. Tell the admin to keep their copy somewhere safe, and remove the file from the agent as soon as they have it:

```bash
rm -f ~/suitecrm-backup-'<backup>'.tar
```

The skill can't put such a copy back into a deployment. That is a request to Clouve support.

## Removing a backup

Removing a backup is final. The first form removes nothing and ends with 64. A restore that was cut off blocks a removal, because finishing it may need that backup. `--remove` also takes the name of a leftover, such as `20261112-101500.partial`, the folder that a stopped backup left behind.

Gate. The user picks the backup by its name. Say when it was made and that it can't be brought back, and wait for a clear yes that names it.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --remove '<backup>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --remove '<backup>' --yes-remove
```

## The backup an upgrade keeps is a different thing

| | This skill's backup | The upgrade's kept backup |
|---|---|---|
| Made | When someone asks, by `backup.sh` | By the image, before it upgrades SuiteCRM |
| Where | `tmp/clouve-skill-backups/<UTC time>/` | `tmp/clouve-backup/<from>-to-<to>/` |
| Holds | The database and the customer's files and settings, no code | The old code and settings and a dump of the database, without the customer's files, which an upgrade leaves in place |
| Good for | Going back on a change, on the same version | Going back to the old version when an upgrade fails |
| Restored by | `restore.sh` | The image, at a start. Never the assistant |
| Removed by | `backup.sh --remove` | `upgrade-state.sh --remove-kept-backup` |
| Counts for the 24-hour rule | Yes | No |
