# Recover from a failed upgrade

When the image's upgrade of LimeSurvey fails, the image undoes it: it puts the database back from the dump it took first, moves the old code back and starts the old version. The site then runs as before the upgrade, and the image does not try again until a newer image arrives. This playbook is for reading that state and the ones next to it, for telling the user, and for the rare case where the database update itself is left unfinished.

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- upgrade-state.sh exits 3 or 4, or says that the image did not try the upgrade.
- verify-health.sh shows `[FAIL] upgrade`, `[FAIL] waiting`, or `[FAIL] database` with a version mismatch.
- "The update did not happen: it still looks like the old version."
- LimeSurvey's admin page shows "Database upgrade", or says that a previous database update failed.
- Not while an upgrade is still running (upgrade-state.sh exits 2 and names a phase): wait for it.

## Steps

### 1. Read the state

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/upgrade-state.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

Both always run, whatever state the container is in. They change nothing in the upgrade's state.

### 2. The upgrade failed and the old version is back

upgrade-state.sh says "FAILED, and the image put the old version back", with the image's reason, and verify-health.sh shows the old version with the database answering. The site works, on the old version.

- Don't remove anything in `/var/www/html/clouve/`. The folder there records the failure, and removing it makes the image try the upgrade again at its next start.
- Don't run the database update by hand to "finish" the upgrade. The code on the volume is the old version's.
- Tell the user that the update did not go through, that their site and data are as they were, and that Clouve has to look at why. Give them what you see: the reason and the versions from upgrade-state.sh, the output of verify-health.sh, and the time. Clouve's staff can also read the container's log, where the image writes a line that starts with `[clouve-upgrade] FAILED`.

### 3. The upgrade was not tried

upgrade-state.sh says "The image did NOT try the upgrade", with the image's reason: too little free space on the volume, too few free inodes, or its own backup could not be made. Nothing was changed. The site runs the old version, and the image tries again at its next start.

- When the reason is space, look at what takes it: old backups of this skill (`run-in-limesurvey.sh backup.sh --list`) and the kept backup of an earlier upgrade (upgrade-state.sh names it). [back-up](back-up.md) and [after-an-upgrade](after-an-upgrade.md) say how each is removed, after the admin's yes. More space than that is a change of the Clouve plan.
- You can't restart the app, and the upgrade runs only at a start. Tell the user what was in the way and what you freed, and that the update happens at the app's next start, which Clouve support can trigger. In the container's log, which Clouve's staff can read, the line starts with `[clouve-upgrade] skipped:`.

### 4. On the old version, keep to the reports

After a failed upgrade and after one that was not tried, the site keeps the version it had: LimeSurvey 6, for the move to 7. This skill's scripts were written for LimeSurvey 7 and tested on it. verify-health.sh warns about the version, and it and upgrade-state.sh are fine to run. Leave the rest alone until the site is on version 7: an `rc.sh` call or an import can behave differently on the old version. If the admin needs something done meanwhile, they do it in LimeSurvey's own pages.

### 5. The container is waiting for a repair

upgrade-state.sh exits 4 and says "WAITING FOR A REPAIR", and verify-health.sh shows `[FAIL] waiting`. The image has stopped at a state it can't leave by itself. It keeps its stand-in page and its sshd up, so that someone can get in, serves no LimeSurvey, and does not restart. On the Clouve dashboard the deployment shows as running, although nobody can use the site. The image's reason is in the output of both scripts, with the time the wait began. Both come from the note the image leaves for you in `clouve/needs-attention`, because you can't read the container's log. The note holds no password. There are three kinds.

- A restore of this skill was cut off, and its marker is still there. The way out is yours: run the same restore again ([restore-from-backup](restore-from-backup.md), "When a restore was cut off"). The image starts LimeSurvey once the restore is done.
- The image stopped in the middle of an upgrade or of its way back from one: a step failed, or it could not record where it was, as on a full volume. upgrade-state.sh then also says where the upgrade stopped (the phase and the step) and whether the database is still as the upgrade left it. The phase can read `upgrade` or `restore` although no work is going on.
- The code and the database don't belong together (the versions differ, or a database update was cut off), and the image has no backup it trusts. That is also the state after the image moved its state folder aside as `clouve.untrusted-<time>`, because something had replaced it.

For the last two, change nothing. The scripts that change survey data, send mail or run LimeSurvey's code refuse in this state, because the code and the database may not fit together. Putting a `clouve.untrusted-*` folder back, freeing space on the volume by hand, or loading a dump by hand, is a step for Clouve support. Tell the user that the site is down, that their data is still on the volume, and that Clouve support has to repair it. Give them every line of upgrade-state.sh. For Clouve's staff: the container's log has a line that starts with `[clouve-upgrade] FAILED` and says the same, and the repair for each case is under "When a start waits for repair" in the image's README (`apps/limesurvey/README.md` in the magneto repo).

After such a repair the site can come back with LimeSurvey's maintenance page still showing. Nothing lifts that mode by itself. [diagnose-problems](diagnose-problems.md) has the step that switches it off, after a yes.

What still runs there, because it changes no survey data and runs none of LimeSurvey's code: the two reports, `run-in-limesurvey.sh backup.sh --list`, `run-in-limesurvey.sh restore.sh --last-log`, a restore over its own marker, and the keys-only restore.

### 6. The code is new and the database is old, and the site is up

verify-health.sh shows `[FAIL] database: is at version ... and the code needs ...`, with Apache running. LimeSurvey's admin page then offers a "Database upgrade" to anyone who opens it, without a sign-in. The image runs that update before the web server starts, so this state means a start went wrong. Check first that nothing is running:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/upgrade-state.sh
```

Only when that says no upgrade is under way: back up, then run LimeSurvey's own database update.

Gate: say that the backup locks the site while it runs, that the update then brings the database to the version the code needs, and that the backup is the way back. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/console.sh --failed-upgrade-playbook updatedb
```

If backup.sh stops with "could not turn the maintenance mode on", LimeSurvey's own lock does not work on this database as it is. Nobody can use the admin pages in this state anyway, so the backup can be taken without the lock.

Gate: say that this backup runs without the lock on the site, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --no-maintenance
```

Exit 0 of the update with "successfully upgraded" is the good end. Then flush the caches and check:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/console.sh flushassets
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

### 7. A database update that was cut off

verify-health.sh shows `[FAIL] database: a database update was cut off`. LimeSurvey refuses to update again and says to restore the backup made before the update. The database is half changed, and no command repairs it in place.

- If the image kept its upgrade backup (upgrade-state.sh names it), this is Clouve's to fix: the image restores from it at a restart. Tell the user to contact Clouve support, with what you see.
- If a backup made by backup.sh from before the update exists, [restore-from-backup](restore-from-backup.md) puts it back, and the database update then runs as part of the restore.

### 8. The database is newer than the code

verify-health.sh shows the database at a newer version than the code. LimeSurvey does not notice this and would write to tables that no longer exist. Don't change anything. Tell the user to contact Clouve support.

## Tell the user

Say plainly whether their site works right now and on which version, that no data was lost (when the old version is back), and what happens next. Don't promise a date for the update.
