# Restore from a backup

Use this when the user wants SuiteCRM put back to the state of a backup: after an import, a package or a bulk change that went wrong and can't be undone any other way. Try the smaller fix first: an undelete for one record ([add-and-update-records](add-and-update-records.md), step 7), the undo for an import ([import-a-csv](import-a-csv.md), "Undo the import"), an uninstall for a package ([install-a-module](install-a-module.md), step 7).

A restore replaces every table of SuiteCRM's database and the customer's files with the backup's. Everything entered or changed since the backup is gone: records, users, roles, settings, the audit trail. It keeps this deployment's database settings, its address and `.env.local`. It also brings back what was waiting to run when the backup was made: the campaign email queue, the scheduled workflows and the scheduled reports. Email that went out after the backup would go out a second time. So a restore holds the scheduler and leaves it held, and nothing scheduled runs until the user has seen what is waiting and says to release it (step 5). The only way to undo a restore is to restore another backup, which is why a fresh backup of the current state comes first ([backup-restore.md](../reference/backup-restore.md)). Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`. A value in angle brackets in a command is yours to fill in. It stays inside its single quotes, and an apostrophe in it is written `'\''`. restore.sh runs inside the SuiteCRM container, and run-in-suitecrm.sh sends it there.

## Before you start

1. Ask what went wrong and when. That tells you which backup is the right one, and whether a smaller fix would do.
2. Pick the backup with the user. This reads only.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --list
```

A backup's name is the UTC time it was made (`YYYYmmdd-HHMMSS`). Say the time in the user's own time zone too. Only a backup marked `complete`, of the SuiteCRM version that is installed now, can be restored.

3. Ask who is working in SuiteCRM right now. Someone who saves a record during the restore loses it, so the user asks everyone to stay out until you say it is done.

## Steps

### 1. Run the preview

The preview checks the backup and changes nothing. It ends with exit 64, which is its normal end.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh restore.sh --backup '<backup>'
```

It prints when the backup was made, its SuiteCRM version, the address it came from, and what SuiteCRM holds now: the number of tables, accounts, contacts, leads, opportunities and users. Then it says how many campaign emails were waiting in the queue when the backup was made, that the restore holds the scheduler, and on its `Space:` line how much room the backup's files need and how much is free. Exit 3 means the backup is missing, was never finished or is damaged: pick another. Exit 2 means it is of another SuiteCRM version (see below), or a check refused it: the message says which.

### 2. Show the user what a restore does

Tell the user, with the numbers from the preview:

- When the backup was made. Everything entered or changed since then is gone after the restore: new records, changes to old ones, users added since, settings.
- Studio changes, uploaded files and added modules go back to the backup's state as well.
- What starts again. The backup's database holds the campaign email queue, the workflows and the scheduled reports as they were then. Campaign email that went out since, and scheduled workflows that ran since, would go out and run a second time. So the restore holds the scheduler: afterwards there are no workflows, no reminders, no campaign mail, no scheduled reports and no reading of mailboxes until they have looked at what is waiting and say to release it.
- The address and the sign-in page stay the same. Everyone has to sign in again afterwards.
- Everyone should stay out of SuiteCRM until it is done.
- You take a backup of the current state first, so the restore itself can be undone.

When the user runs campaigns, tell them how much campaign email went out since the backup: that is what would go out again. This reads only. Put the backup's time, in UTC, in place of the date:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh 'SELECT COUNT(*) AS sent_since FROM campaign_log WHERE deleted = 0 AND activity_type = "targeted" AND activity_date > "2026-11-12 10:15:00"'
```

Run it before the restore. Afterwards SuiteCRM's own record of what was sent is the backup's too.

### 3. Take a fresh backup of the current state

It adds a backup to the volume and changes nothing else. restore.sh refuses (exit 2) unless there is a complete backup from the last 24 hours other than the one being restored.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh
```

Note the name it prints. That backup is the way back.

### 4. Restore, as a detached job, after the user's yes

Gate. Show the user step 2: what is lost, what would start again, and that the scheduler stays held afterwards. Wait for a clear yes that names the backup to restore. "Go ahead" from before they saw that is not enough. Then start the restore. Always run it detached, so that a dropped session can't stop it half-way:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --detach restore.sh --backup '<backup>' --yes-replace-current-data
```

It prints `job:` and the job's name, which starts with `restore-`. Follow the job:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --status '<job>'
```

`status: running` (exit 3) means wait and ask again. `status: finished, exit 0` (exit 0) means it is done. The log then has a line that starts with `Restore of`, says `is complete` and gives the number of tables, accounts, contacts, leads, opportunities and users. A line that starts with `As of the backup, this is waiting:` says how many campaign emails, scheduled workflows and scheduled reports the restore brought back, and the next one says that the scheduler is held. `status: finished, exit 2` or `exit 3` means it was refused before anything changed, and the log says why. `status: finished, exit 4` means it failed after it began: go to "A restore that was cut off". While a restore runs, every other script of the skill refuses with exit 75. Only verify-health.sh, upgrade-state.sh and `backup.sh --list` still work.

Only one backup or restore runs at a time. A second one that is started meanwhile ends with exit 2 at once, names the job that is running and changes nothing.

### 5. The scheduler stays held: show what is waiting

After a restore the scheduler is held by the file `tmp/clouve-backup/scheduler-held`, and it stays held until the user says to release it. Until then no scheduled job runs. Read what a release would start. Both read only:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh status
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh queued
```

`status` has `"held": true`, and `held_by` names the hold file. `queued` has the campaign emails that are waiting and due, the active workflows, the scheduled reports and the mailboxes. Those numbers describe SuiteCRM as it was when the backup was made. Part of that queue may have gone out between the backup and the restore: the count from step 2 says how much.

Tell the user what is waiting, and what they can do in SuiteCRM before a release: take queued mail out of a campaign, set a workflow to inactive, or switch one scheduled job off under Admin > Scheduler. The first command below is the preview. It prints what a release would start, changes nothing and exits 64:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release
```

Gate. Show the user those lines with their numbers. Say that every active scheduled job runs from the next minute on, that campaign email in the queue goes out, also to people who got it once already, and that email that has gone out can't be taken back. Wait for a clear yes. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release --yes-release
```

Leaving the scheduler held is a fair choice. Say what does not run until they decide. When the release ends with exit 2, [after-an-upgrade](after-an-upgrade.md) has the table.

## Check the result

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/verify-health.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/repair.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/records.sh list Accounts --search '<text>'
```

- verify-health.sh: `restore` says no restore is under way, and `web`, `database` and `version` are OK. `scheduler` warns that it is held until step 5 has released it, so the report ends with `Overall: AMBER`.
- repair.sh without options is a dry run. `"database_in_sync": true` means the database and the files match. When it lists SQL they don't: show it to the user and follow the second part of [install-a-module](install-a-module.md).
- Ask the user for a record that should be there again, and one that was added after the backup and should be gone. Look both up.

In the Customer Kit, check the LimeSurvey link afterwards ([customer-kit-limesurvey-link](customer-kit-limesurvey-link.md)): the restore also put the main admin's password and SuiteCRM's API clients back to the backup's state.

An import that the skill made after the backup can no longer be undone, and its records are gone with the restore anyway.

## Undo a restore

Restore the backup from step 3, by the same steps: the preview, the user's yes, the detached job. restore.sh again wants a complete backup from the last 24 hours other than the one being restored. The backup you restored first counts when it is that recent. Otherwise take a new one.

## A restore that was cut off

The signs: `--status` shows `finished, exit 4` or `stopped without an exit code`, verify-health.sh fails on `restore` and names the marker `tmp/clouve-backup/restore-in-progress`, and the other scripts refuse with exit 75 and name the restore. SuiteCRM may be half restored. Don't repair it by hand, and never remove the marker yourself.

1. Make sure no restore is still running: `--status` with the job's name must not say `running`.
2. Run the restore again with the command of step 4: of the same backup, or of the backup from step 3 when the user would rather be back where they started. Running it again is always safe. The log of the failed job names the step that failed.

No fresh backup is asked for this time, and none can be taken: backup.sh refuses while the marker is there. A backup of a half-restored SuiteCRM would be worth nothing, and the backup from step 3 already is the way back. The scheduler was held before the first table was dropped, and it stays held.

When the container restarted in the middle, it does not start SuiteCRM on a half-restored site. It keeps a page up that says "SuiteCRM is being restored", and waits for the marker to go. upgrade-state.sh then says `Start-up: the container is waiting: a restore was cut off (run the restore again)`, and PID 1 is not Apache. Under that line it shows the image's own reason and the time the wait began, from the note the image leaves for you in `tmp/clouve-backup/needs-attention`. verify-health.sh shows the same. A container that restarted has no jobs, so `--status` knows no job any more. The steps are the same: run the restore again with the command of step 4. restore.sh runs in that state, and when it is complete the container finishes its start by itself. Wait a minute, then check the result.

When the second run fails at the same step, stop, and write up a support request for Clouve with what the job's log printed ([diagnose-problems](diagnose-problems.md), step 6). The heading in Clouve's staff runbook is "The page says "SuiteCRM is being restored"".

## A backup of another version

The preview and the restore both refuse with exit 2, and the message starts with `refused: the backup` and names the backup's SuiteCRM version and the installed one. A backup holds no code, and a database of one version under the code of another breaks SuiteCRM. This happens with backups taken before the image upgraded SuiteCRM. Tell the user that this backup can't be restored here. The assistant can't go back to the version before an upgrade. That is a request to Clouve support ([after-an-upgrade](after-an-upgrade.md)).

## Restoring onto a new deployment

A backup of one deployment can be restored onto another of the same SuiteCRM version, because the restore keeps the new deployment's database settings and address. The backup's folder first has to be in the new deployment's backups folder, and this skill has no command that puts it there. That step needs Clouve support. Don't make up a command for it. Once `backup.sh --list` on the new deployment shows the backup as `complete`, the steps above apply.

After such a restore, the users and their passwords are the old deployment's. When the main admin can't sign in with the password on the Clouve dashboard, follow [regain-admin-access](regain-admin-access.md). The pictures of email templates, which SuiteCRM keeps in `public/legacy/cache/images`, are in the backup and come onto the new deployment with it.

## Tell the user

- That SuiteCRM is back to the state of the backup, with the backup's time and the numbers of accounts, contacts, leads and opportunities it has now.
- Everyone has to sign in again, and can work again from now.
- What was entered after that time is gone, as agreed.
- That the scheduler is held: what is waiting, what does not run meanwhile, and that it starts when they say so.
- The name of the backup you took just before the restore: "If you change your mind, I can restore that one. Tell me before anyone enters much new data."

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Exit 64 with a preview | The normal end of the preview | Go on with step 2 |
| Exit 3 | No such backup, or it was never finished, is damaged, or holds something a backup never holds. Nothing was changed | Pick another backup from the list |
| Exit 2 | Another SuiteCRM version, no fresh backup of the current state, not enough free space for the backup's files, another backup or restore is running, or a folder that is not root's. Nothing was changed. The message says which | Step 3, "A backup of another version", or wait for the job the message names. Free space: [back-up](back-up.md), step 6. A folder that is not root's is Clouve support's step |
| Exit 1 | SuiteCRM's settings or its database can't be read. Nothing was changed | verify-health.sh, then [diagnose-problems](diagnose-problems.md) |
| Exit 4, or the marker `tmp/clouve-backup/restore-in-progress` | The restore failed after it began | "A restore that was cut off" |
| Exit 75 from restore.sh | The image is installing or upgrading, or the container is still starting. A new restore does not start then | Wait, and read upgrade-state.sh |
| `--detach` exit 1 | The job was not started | Run it again. Check `--status` first when the message names a job |
| `--detach` exit 2 | The job was started, but whether it runs could not be read | `--status` with the job's name |
| `--status` exit 64 | No job of that name. A container that restarted has no jobs | verify-health.sh: its `restore` and `start-up` lines say whether a restore was cut off |
| Exit 75 from another script | A restore is running or was cut off | Wait for the job, or "A restore that was cut off" |
| Exit 255 | The SSH channel failed. A detached job keeps running | `--status`, then verify-health.sh |
