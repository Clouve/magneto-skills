# Upgrades

SuiteCRM's version comes from Clouve's image. This file says what an upgrade does when a container starts on a newer image, what [upgrade-state.sh](../scripts/upgrade-state.sh) shows, what to do after an upgrade, after a failed one and after one the image did not start, and what survives.

## Versions come from the image

- A newer image upgrades the SuiteCRM on the volume at its first start, before Apache answers. Nobody starts it by hand.
- SuiteCRM 8 has no upgrade of its own in the browser. The Module Loader in its admin screens installs add-ons only. So a customer can't move SuiteCRM ahead of the image.
- The assistant's part is to read the state, explain it, and do the follow-up work after an upgrade. The last section lists what it never does.

## What an upgrade does at a start

1. The image compares the version on the volume with its own. It also reads the version SuiteCRM records in its database as the last step of an install or an upgrade, because the `VERSION` file changes early in an upgrade and proves nothing.
2. While it works, a stand-in answers on port 80. People see a short page that says "SuiteCRM is starting", and every other address answers 503. The skill's scripts answer 75, apart from `verify-health.sh`, `upgrade-state.sh` and `backup.sh --list`.
3. It checks that the volume has room. With too little, when files in the install are not `www-data`'s, or when the backup of the next step can't be made, it does not start the upgrade at all ([An upgrade the image did not start](#an-upgrade-the-image-did-not-start)).
4. Phase `backup`: it saves the old code and settings as an archive and the database as a dump, in `tmp/clouve-backup/<from>-to-<to>/`. The customer's files stay where they are and are not in that backup.
5. Phase `upgrade`: it runs SuiteCRM's own two commands as `www-data`. `suitecrm:app:upgrade` copies the new code over the old. `suitecrm:app:upgrade-finalize` repairs the database, runs the migrations and records the new version.
6. The upgrade counts as done only when both commands ended well, the database records the new version and SuiteCRM's own version command prints it.
7. On success it removes its work files, keeps the backup, and starts Apache and the two loops.
8. On failure it goes back (phase `restore`): the old code is put back, the tables are dropped and the dump is loaded. When the upgrade fails for good, the phase becomes `failed` and the old version runs.

A container that stops in the middle is safe: the next start reads the phase and does the one thing that is safe there. When the image finds a site between two versions with no backup it trusts, it starts nothing and waits for a person ([stack-and-runtime.md](stack-and-runtime.md#the-waiting-container)). In a test on a fast machine the two commands took about 11 seconds, and about 20 with the backup. A cluster disk is slower.

## What upgrade-state.sh shows

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh
```

It works at any time, during an upgrade and in a container that waits too, and only reads. This is what it printed on a new install:

```text
SuiteCRM version on the volume: 8.10.2
SuiteCRM version in the image: 8.10.2
Start-up: finished (PID 1 is Apache).
Upgrade: No upgrade is under way.
Scheduler: not held.
Backups kept by upgrades: none.
Manual Migration Tasks: none.
```

And this is what it printed in a test with the state an upgrade from 8.9.1 leaves: a kept backup, the scheduler held by the image's setting, and seven tasks nobody has started:

```text
SuiteCRM version on the volume: 8.10.2
SuiteCRM version in the image: 8.10.2
Start-up: finished (PID 1 is Apache).
Upgrade: No upgrade is under way.
Scheduler: held (the image's scheduler setting is off, as on an install that existed before this image). No scheduled job runs until it is released: scheduler.sh release shows what would start, and lets it go with --yes-release after the user's yes.
Backups kept by upgrades:
  8.9.1-to-8.10.2  95 MB  last changed 2026-11-12 10:15 UTC
  Remove one with upgrade-state.sh --remove-kept-backup <name> --yes-remove, once the user has checked the upgraded site.
Manual Migration Tasks: 7 initial.
  An admin starts them in SuiteCRM under Admin > Migrations (playbooks/after-an-upgrade.md).
```

A line appears only when it has something to say. The whole set:

| Line | What to do with it |
|---|---|
| `SuiteCRM version on the volume`, `SuiteCRM version in the image` | The version that runs, and the version the image brings. When the image's is newer and the start-up has finished, the image did not start the upgrade, and the `Upgrade:` line says why |
| `Start-up: finished (PID 1 is Apache).` | The start-up is done |
| `Start-up: still running` | The image is installing or upgrading. Wait, and run it again |
| `Start-up: the container is waiting: a restore was cut off (run the restore again)` | PID 1 is not Apache and the stand-in page answers. Run the restore again ([playbooks/restore-from-backup.md](../playbooks/restore-from-backup.md)) |
| `Start-up: the container is waiting: the image found a site that it must not start as it is` | The way out is Clouve support. Pass on this report and the one of `verify-health.sh`, and leave the state folder and every backup as they are |
| `Start-up: waiting or still starting` | A start takes a few minutes: the image waits up to five minutes for the database. If the line stays, tell the user and Clouve support |
| `State folder: ...` | `tmp/clouve-backup` is not a folder of root's, so nothing in it was read, or the image moved such a folder aside to `tmp/clouve-backup.untrusted-<UTC time>`. Putting either right is a step for Clouve support. Change nothing in it |
| `Backups folder: ...` | This skill's backups folder is not a folder of root's. `backup.sh` and `restore.sh` refuse then. Clouve support |
| `Files in the image's state folder (tmp/clouve-backup): ...` | The image's files that are there now, such as `scheduler-held` or `upgrade-skipped` |
| `Install: a new install is under way or was cut off` | Wait. The next start cleans up and installs again |
| `Upgrade: No upgrade is under way.` | The volume and the image hold the same version, and the start-up has finished |
| `Upgrade: under way, phase: ...` | Leave SuiteCRM alone until it finishes |
| `Upgrade: the last upgrade failed` | See "A failed upgrade" below. The lines under it are the image's own reason |
| `Upgrade: the image has <x>, the volume runs <y>: the image did not start the upgrade` | See "An upgrade the image did not start" below |
| `Restore: ...` | A restore by this skill is running or was cut off |
| `Scheduler: held (...)` | By the hold file, by the image's scheduler setting, or by both ([scheduler-and-worker.md](scheduler-and-worker.md#the-held-scheduler)) |
| `Backups kept by upgrades` | Each kept backup with its size. The line under them says whether one can be removed now. See the next section |
| `Upgrade work files: ... in tmp/package/upgrade` | The image removes them after an upgrade. Tell Clouve support if they stay |
| `The skill's other scripts refuse for now: ...` | Why the other scripts answer 75 |
| `Manual Migration Tasks` | Counts by status, or `none`. `initial` means an admin has not started them, and a second line then says where they start. A new install has none and gets no such line |

## After an upgrade

- Run `verify-health.sh`. Its `version` line confirms that the code and the database agree.
- Everyone was signed out, because sessions don't survive a restart of the container.
- Seven Manual Migration Tasks wait under Admin > Migrations. An admin starts them, and they need the Messenger worker ([scheduler-and-worker.md](scheduler-and-worker.md#the-manual-migration-tasks)).
- On an install that existed before this image, the scheduler is held. Look at what is queued and release it after the user's yes.
- SuiteCRM 8.10 renamed its media folders: `uploads/` is now `media/` and `public/media-upload/` is now `public/media/`. The upgrade moves the files by itself. Nothing changes for people in the browser.
- No Quick Repair is needed. The upgrade runs its own, and a dry run right after one reported the database in sync.
- Take a new backup with `backup.sh`. Backups made on the old version no longer restore ([backup-restore.md](backup-restore.md#the-same-version-rule)).
- A SuiteCRM 8 extension with a browser part may be switched off by the upgrade until it is rebuilt, which this image can't do.

The kept backup stays on the volume until someone removes it. It holds the old code, the settings with the database password and every record as it was before the upgrade, and it is the only way back to the old version. Have the user check the upgraded SuiteCRM first: records and attachments open, custom fields are there, a test email goes out.

Gate. Show the user which kept backup goes and the size it frees, and say that there is then no way back to the old version from this volume. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh --remove-kept-backup '<kept backup>'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh --remove-kept-backup '<kept backup>' --yes-remove
```

The first form removes nothing and ends with 64. The name is the one the report shows, such as `8.9.1-to-8.10.2`. The removal is refused with 2 while an upgrade is under way or has failed, while the container is starting or waiting, and when the state folder is not root's, because the backup may still be needed. The report itself offers the removal only when nothing can need the backup any more.

## A failed upgrade

When an upgrade fails, the image puts the old version back and starts it. `upgrade-state.sh` then says that the last upgrade failed, with the image's reason, and `verify-health.sh` reports RED on its `upgrade` line although SuiteCRM works. The skill's scripts are not refused in this state.

- The image doesn't try again until a newer image arrives or Clouve clears the state.
- The data is as it was before the upgrade. Nobody could enter anything while it ran.
- The old version lacks the newer one's security fixes, so this needs Clouve support soon. Give them the reason lines from `upgrade-state.sh` and the last lines of `logs/upgrade.log`, SuiteCRM's own upgrade log, which stays on the volume ([playbooks/failed-upgrade.md](../playbooks/failed-upgrade.md), step 3).
- The assistant doesn't clear the state, doesn't run the upgrade commands and doesn't remove the kept backup.

## An upgrade the image did not start

The signs: the version on the volume is older than the image's, the start-up has finished, and no failure is on record. The image then skipped the upgrade at this start without trying it. It does that when the volume has too little room for the new code and a backup of the old, when files in the install are not www-data's, or when it could not make that backup. Nothing was changed, the old version keeps running, and the image tries again at its next start.

- The image leaves the note `tmp/clouve-backup/upgrade-skipped`, with the versions, the time and the reason. `upgrade-state.sh` then prints `the image has <x>, the volume runs <y>: the image did not start the upgrade, because <reason> (at <time>)`, and `verify-health.sh` warns on its `upgrade` line.
- An image that leaves no note still writes the reason to the container's log, in a line that starts with `[clouve-upgrade]`. Only Clouve support can read that log, and `upgrade-state.sh` says so in that case. What you can read is the `disk` line of `verify-health.sh`: an upgrade needs room for the new code and for a backup of the old code and the database.
- So an old version does not prove that no newer image has arrived. Compare the two version lines before you say that.
- Room comes from a backup of this skill that the user picks by name ([playbooks/back-up.md](../playbooks/back-up.md), step 5), or from a larger plan. Never tell anyone to remove a folder that holds a backup, and never touch the state folder.
- The old version lacks the newer one's security fixes, so tell the user and write up a request for Clouve support ([playbooks/failed-upgrade.md](../playbooks/failed-upgrade.md)).

## An upgrade that did not finish

A different case is an upgrade that did not finish and was not put back: `verify-health.sh` fails on `version` because the code and the database disagree, or pages answer 500. The next start of the container picks the upgrade up from its phase. The assistant can't restart it, so tell the user and Clouve support at once ([playbooks/failed-upgrade.md](../playbooks/failed-upgrade.md)).

## What survives an upgrade

These came through an upgrade from 8.9.1 to 8.10.2 in a test:

| Survives | Detail |
|---|---|
| Records and their links | Accounts, contacts, leads, opportunities, notes, with the same counts |
| Users, roles and security groups | Sign-in with the same passwords |
| Custom fields and their values | And logic hooks and other files under `public/legacy/custom/` |
| Files | Attachments in `public/legacy/upload/`, and the media folders under their new names |
| Settings | `config_override.php` and `.env.local` unchanged. `config.php` is kept and gains new entries |
| Outgoing email | The system account and its stored password, since the key file is under `custom/` |
| The Customer Kit's link | The OAuth2 client and the key pair. The password sign-in still returned a token |
| Add-ons | `extensions/`, and module folders that are not SuiteCRM's own |

What does not survive:

- A file at the top of `/var/www/html` that SuiteCRM doesn't know. The upgrade deletes it.
- Edits to `.env`. The upgrade replaces the file with the package's copy.
- Changes made inside SuiteCRM's own code, such as a core module's folder. The upgrade replaces those folders. Customisations belong under `custom/`.
- The built browser part of an extension, as said above.

## What the assistant never does

- Start, repeat or undo an upgrade, or run `suitecrm:app:upgrade`, `suitecrm:app:upgrade-finalize` or a migration command. `console.sh` refuses them.
- Restart the container or Apache. A restart is a request to Clouve support.
- Change or remove anything in `tmp/clouve-backup` by hand. `upgrade-state.sh` and `scheduler.sh` are the only ways in.
- Put back, rename or remove a state folder that is not root's, or one the image moved aside. It may hold the backup an upgrade kept, and Clouve support looks at it first.
- Put the kept backup back, or copy old code over new.
- Promise a date for a newer version.

## Exit codes of upgrade-state.sh

| Code | Meaning |
|---|---|
| 0 | Done |
| 64 | Usage, or `--remove-kept-backup` without `--yes-remove` |
| 2 | Refused: an upgrade is under way or has failed, the container is starting or waiting, or the state folder is not root's |
| 3 | No kept backup of that name |
| 255 | ssh failed |
