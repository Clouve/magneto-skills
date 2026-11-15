# Restore from a backup

This playbook puts a backup made by backup.sh back, over this site or onto a new deployment. A restore replaces every survey, every answer, every participant and every admin account with what the backup holds. It keeps this deployment's own database settings and address. The playbook also has the small repair for a site whose encryption keys are missing or wrong, which touches nothing but the keys.

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs. The script is `restore.sh`. It runs inside the LimeSurvey container as root, so it is always called as `run-in-limesurvey.sh restore.sh`.

## When to use

- Something was deleted or broken and the admin wants yesterday's state back.
- The admin moves their LimeSurvey to a new Clouve deployment and has a backup of the old one.
- A restore was cut off (verify-health.sh shows `[FAIL] restore`).
- verify-health.sh shows `[FAIL] security.php` or `[FAIL] keys`: go straight to "Only the keys are missing or wrong".
- Not for bringing back one survey: if an `.lss` or `.lsa` file of it exists, [copy-or-move-a-survey](copy-or-move-a-survey.md) does that without touching the rest.

## What to know first

- The encryption keys travel with the backup. restore.sh puts the backup's `security.php` in place before anything else, and before any LimeSurvey code runs, because LimeSurvey makes new keys the moment it starts without that file. The keys that were there are kept in `clouve/backups/before-restore-<time>/`.
- A backup from an older LimeSurvey can be restored: restore.sh runs LimeSurvey's database update afterwards. A backup from a newer LimeSurvey than this container runs is refused.
- restore.sh wants a backup of the current state that is less than an hour old, so that the restore can be undone. An older one is named with its age and with how many answer sets the site has gained since.
- The site is locked while a restore runs, and LimeSurvey's tables are never dropped first: the dump is loaded over them. So the platform's health check keeps passing through a long load, and the container is not restarted in the middle.
- A dropped connection does not stop a restore. It goes on to the end in the container and writes a log.
- Only a backup in root's own folder is restored. If the scripts say that `clouve`, `clouve/backups` or a backup's folder is a link or does not belong to root, something replaced it: restore nothing, and tell the user to contact Clouve support.

## Steps

### 1. Pick the backup

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --list
```

Ask the admin which one, by its name (the UTC time it was made).

For a backup from another deployment, the admin uploads its folder (six files) to `limesurvey-backups/<backup name>/` in the Files pane. Then put it into the container:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/backup-copy.sh list
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/backup-copy.sh push <backup name>
```

The script checks the folder against the backup's own checksums before and after the copy.

### 2. Back up what is there now

Gate: a backup locks the site while it runs: participants and admins see a maintenance page for that time. Say so, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh
```

On a brand-new deployment this is a backup of an empty site, and it takes a second. It is still what makes the restore undoable.

If backup.sh says that `security.php` is missing, no backup can be taken, and a full restore is not what the site needs: see "Only the keys are missing or wrong".

### 3. Look at what the restore would do

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --backup <backup name>
```

Nothing is changed. The output says what the backup holds, what is on the site now, what a restore replaces and what it keeps, and which backup is the way back, with its age. Exit 2 means the backup can't be used (damaged, incomplete, or from a newer LimeSurvey). Exit 1 with "Take a new one first" or "Take one first" means step 2 is missing or is more than an hour old.

### 4. Restore

Gate: show the admin the lines from step 3. Say that every survey, answer, participant and account on the site now is replaced by the backup's, that the site is closed while it runs, and that the backup from step 2 is the way back. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --backup <backup name> --yes-replace-current-data
```

The last line is `done: <name> is restored`. Exit 4 means a step failed after the restore began: the message names the step, and the marker `RESTORE-IN-PROGRESS` stays. See "When a restore was cut off" below.

`--skip-safety-backup` restores without a fresh backup of the current state. Everything that was added to the site since its newest backup is then lost for good, and with no backup at all, everything.

Gate: tell the admin the age of the newest backup and the number of answer sets it lacks, which the preview printed, and that those are lost. Offer step 2 once more. Only when the admin says that what was added is not worth keeping:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --backup <backup name> --yes-replace-current-data --skip-safety-backup
```

### 5. Check the result

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh list_surveys
```

The health report must show no `[FAIL]`, with the keys line saying that the encryption keys read what the database holds. Ask the admin to sign in and look at a survey. Their password is the one from the backup's site.

## Only the keys are missing or wrong

verify-health.sh shows `[FAIL] security.php` (the file is gone) or `[FAIL] keys` (the file holds other keys than the data was encrypted with, as after LimeSurvey made a new one). The surveys and answers are all there. Only `application/config/security.php` has to come back, from a backup that holds the right keys. A full restore would throw away everything since that backup to repair one file, and with the file missing it can't even take its safety backup. So this is the one case where the file is changed, and one script action does it. Don't copy the file by hand.

Start nothing else in LimeSurvey meanwhile: a page or a console command would make new keys.

Look first. This changes nothing:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --list
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --keys-only --backup <backup name>
```

The script takes `security.php` out of the backup and tests its keys against values the database holds encrypted: the stored SMTP password, encrypted participant fields, encrypted answers. It says one of these:

- "its keys read what the database holds encrypted": this backup is the one. Go on.
- "its keys cannot read what the database holds encrypted" (exit 2): these are not the keys. Try the next backup in the list, the newest first.
- "the database holds nothing encrypted to test its keys with": no key is needed to read the data. With the file missing, the backup's file fills the gap, so that LimeSurvey makes no new one. With a file in place, nothing is changed.
- "the keys in place already read the data" (exit 2): there is nothing to repair.

Gate: say that only `security.php` is replaced, by the one from that backup, that no survey, answer or file changes, and that the file in place now is kept in `clouve/backups/before-restore-<time>/`. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --keys-only --backup <backup name> --yes-replace-the-keys
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

The keys line of the health report has to read `[OK]`. If no backup holds keys that read the data, the encrypted values are lost with the keys. Tell the user which data that is (answers to questions marked as encrypted, encrypted participant fields, the stored SMTP password, which the admin can type in again), and that Clouve support can look for an older copy.

## When a restore was cut off

verify-health.sh shows `[FAIL] restore`, and the other scripts refuse with exit 75. Read what happened:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --last-log
```

Then run the same restore again. It starts over from the keys and is safe to repeat, and it needs no fresh backup while the marker is there.

Gate: the admin said yes to this restore before. Tell them that it was cut off and that you run it again, and wait for their yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh restore.sh --backup <backup name> --yes-replace-current-data
```

If it fails at the same step again, restore the backup from step 2 the same way, and tell the user what the log says.

If the container restarted while the restore was running, it comes up waiting: it shows a page that says the site is being restored, its sshd answers, and LimeSurvey does not start on the half-loaded database. upgrade-state.sh says "WAITING FOR A REPAIR" and names the restore, with the image's own reason and the time the wait began, from its note `clouve/needs-attention`. The Clouve dashboard shows the deployment as running all the while. The way out is the same: run the restore again. When it is done, the image starts LimeSurvey by itself, within a minute.

## Tell the user

Say which backup was restored, that the site is open again, and that everything made after that backup is gone from the site (and is in the backup from step 2, if they need it). After a move to a new deployment, remind them that the admin password is the old site's.
