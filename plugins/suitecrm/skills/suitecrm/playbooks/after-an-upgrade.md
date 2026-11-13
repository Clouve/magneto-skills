# After an upgrade

Use this the first time you work on a SuiteCRM that the image has upgraded: upgrade-state.sh lists a kept backup such as `8.9.1-to-8.10.2`, the scheduler is held, or the user says the version changed. When the upgrade failed or is still running, use [failed-upgrade](failed-upgrade.md).

SuiteCRM's version comes from the image. A newer image upgrades the install at its first start, after a backup of its own. The assistant never starts, repeats or undoes an upgrade. What is left afterwards is a short list for the user: look the site over, decide about the scheduled jobs, start the migration tasks, and later let go of the kept backup ([upgrade.md](../reference/upgrade.md)). Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`. A value in angle brackets in a command is yours to fill in. It stays inside its single quotes, and an apostrophe in it is written `'\''`.

## Before you start

Nothing here is urgent, and every step but the first needs the user. Ask whether now is a good time, and whether they are an admin in SuiteCRM: two of the steps happen in SuiteCRM's own admin pages.

## Steps

### 1. Read the state and tell the user the version

Both commands read only, and both work even when the other scripts refuse.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/verify-health.sh
```

upgrade-state.sh prints the version on the volume and the version in the image, whether the start-up has finished, the state of an upgrade, whether the scheduler is held and by what, the backups that upgrades kept with their sizes, and the Manual Migration Tasks by status. After an upgrade from 8.9.1 it looks like this:

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

On a new install the last three lines are `Scheduler: not held.`, `Backups kept by upgrades: none.` and `Manual Migration Tasks: none.`, with no hint under them ([upgrade.md](../reference/upgrade.md#what-upgrade-statesh-shows)).

After an upgrade of an install that existed before, verify-health.sh ends with `Overall: AMBER` and two warnings: `scheduler` is held, and `migrations` has tasks waiting. That is the expected state, and steps 3 and 4 clear it. A `FAIL` on `upgrade`, `version`, `web` or `start-up` is not expected, and neither is a version in the image that is newer than the one on the volume: go to [failed-upgrade](failed-upgrade.md).

Tell the user which version SuiteCRM is on now. Step 2 checks with them that their records, settings and custom fields came through.

### 2. Check the site with the user

Ask the user to do these and to tell you what they see:

- sign in;
- open a record they know, and look at a custom field on it;
- open a record with an attachment, such as a note with a file, and open the file;
- send themselves a message from SuiteCRM, if they use its email.

For the last one, read the outgoing-mail account first. This reads only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/email.sh status
```

A warning there, or a test message, is [configure-email](configure-email.md). When something else is wrong, follow [diagnose-problems](diagnose-problems.md) before the next steps.

### 3. The held scheduler

An install that existed before this image never ran a scheduled job. Starting them all at once could send campaign email that has waited for months and run workflows over old records. So on such an install the image holds the scheduler, through its own scheduler setting, until someone has looked at what would start. While it is held there are no workflows, no reminders, no reading of mailboxes, no campaign mail and no scheduled reports. A new install is not held. A restore by this skill holds the scheduler too, with a hold file, and the steps here release that one as well ([restore-from-backup](restore-from-backup.md)).

See whether it is held, and what a release would start. Both read only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh status
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh queued
```

`status` has `"held": true` or `false`, and says what holds it under `held_by`, `hold_file` and `image_setting`. `queued` prints what is waiting:

| Key | What to tell the user |
|---|---|
| `campaign_emails_waiting`, `campaign_emails_due_now` | How many campaign emails are queued, and how many would go out straight away |
| `active_workflows`, `workflows_that_run_on_all_records` | Which workflows are on. Those that run on all records also go over old records |
| `scheduled_reports` | Reports that would be emailed on their schedule |
| `inbound_mailboxes` | Mailboxes SuiteCRM would start reading |
| `jobs_waiting`, `scheduled_jobs_that_never_ran` | Jobs that are queued, and scheduled jobs that have never run |

When something on that list should not start, an admin turns it off in SuiteCRM first: the workflow, the campaign, or the scheduled job itself (Admin > Scheduler). This skill has no command for that. Then the release. The first command is the preview: it prints what a release would start, as plain lines with the same numbers, changes nothing and exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release
```

Gate. Show the user the list above with its numbers, and say: from the next minute on every active scheduled job runs, waiting campaign emails go out, and an email that was sent can't be taken back. The hold can't be put back from here. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release --yes-release
```

It prints a line that starts with `Released:`, and the queue once more under "What starts now". A few minutes later, `scheduler.sh status` shows a fresh `last_run`, the day's results under `jobs_last_24_hours` and any failures under `last_failed_jobs`. Leaving the scheduler held is a fair choice too. Say what does not run until they decide.

### 4. The Manual Migration Tasks

An upgrade from 8.9 leaves seven tasks waiting: Migrate Notes Attachments, Migrate Document Revision Files, Migrate Contact Photos, Migrate Lead Photos, Migrate Prospect Photos, Migrate Google Calendar Sync Data and Migrate Google Calendar Sync Users. They move old files and calendar-sync data into the form that SuiteCRM 8.10 uses. Until they have run, SuiteCRM's documentation says that old attachments still display.

- An admin starts them in SuiteCRM under Admin > Migrations, one at a time. The assistant can't start them: there is no command for it.
- They need the Messenger worker. `scheduler.sh status` (step 3) shows `"messenger_worker_running": true`, what is waiting for it, and the tasks by status under `manual_migration_tasks`.
- Running one was not tested for this skill. So take a backup first ([back-up](back-up.md)): the tasks move the customer's files, and the backup that the upgrade kept does not hold those files. Then ask the admin to start one task, wait until the number under `initial` goes down, look at a record with an attachment, and only then start the next.

SuiteCRM 8.10 also renamed two media folders on the volume: `uploads/` became `media/` and `public/media-upload/` became `public/media/`. The upgrade moved the files, and nothing needs doing. It only matters when someone looks for a file by its old path.

### 5. The kept backup

The upgrade kept one backup, named like `8.9.1-to-8.10.2`: the old code and the database as they were just before it. upgrade-state.sh (step 1) lists it with its size. It is the only way back to the old version, and it takes disk space. Leave it until the user has worked with the upgraded site for some days and is satisfied. The first command is the preview: nothing is removed, and it exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh --remove-kept-backup '<kept backup>'
```

Gate. Say which backup goes and how much space it frees, and that there is then no way back to the old version from this volume. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/upgrade-state.sh --remove-kept-backup '<kept backup>' --yes-remove
```

It prints a line that starts with `Removed the kept upgrade backup`. Backups that this skill made before the upgrade are of the old version and can't be restored any more. Offer to remove those as well, by name ([back-up](back-up.md), step 5).

## Check the result

Run step 1 again. With the scheduler released and the tasks done, verify-health.sh says `Overall: GREEN`: `scheduler` shows that jobs ran minutes ago, `migrations` shows no task waiting, and `worker` is running. upgrade-state.sh says `Scheduler: not held.` and, once the kept backup is removed, `Backups kept by upgrades: none.`

## Tell the user

- Which version SuiteCRM is on now, and what you and they checked.
- What still waits for them, and where: the decision about the scheduler, the seven tasks under Admin > Migrations, the kept backup.
- What does not run while the scheduler is held.
- That you can't start the migration tasks or an upgrade, and can't go back to the old version. Going back is a request to Clouve support, and only as long as the kept backup exists.

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| verify-health.sh fails on `upgrade` or `version` | The upgrade failed or did not finish | [failed-upgrade](failed-upgrade.md) |
| Exit 75 from any script | An install, an upgrade or a restore is still under way, or the container waits | upgrade-state.sh says which. [failed-upgrade](failed-upgrade.md) has each case |
| `scheduler.sh release` exit 2 | The hold could not be removed, the image's scheduler setting could not be read or switched on, or the state folder is not root's. Nothing was released | Run `status` again and read `held_by`. Write up a support request for Clouve, with the runbook's heading "Release the held scheduler" ([troubleshooting.md](../reference/troubleshooting.md#when-it-is-clouve-supports-step)) |
| `worker` warns that the Messenger worker is not running | Background tasks wait, the migration tasks included. The image restarts the worker | Check again after some minutes. Tell Clouve support if it stays down |
| A migration task does not move | The worker is down, or the task failed | `scheduler.sh status` for the worker and the failed messages, then [diagnose-problems](diagnose-problems.md) |
| `--remove-kept-backup` exit 2 | An upgrade is under way or failed, the container is still starting or waits, or the state folder is not root's. Nothing was removed | Leave the backup. [failed-upgrade](failed-upgrade.md) |
| `--remove-kept-backup` exit 3 | No kept backup of that name | Read the name from upgrade-state.sh |
| upgrade-state.sh lists `Upgrade work files` | The upgrade left its unpacked package behind | Tell Clouve support if the line is still there at the next look. Don't delete the files yourself |
| A screen of an add-on looks broken after the upgrade | The add-on may not fit the new version | [diagnose-problems](diagnose-problems.md). A repair is not needed after an upgrade: the upgrade ran its own |
