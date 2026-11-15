# Back up

This playbook makes a backup of the whole site, checks it, and gives the admin a copy to download. The script is `backup.sh`. It runs inside the LimeSurvey container as root, so it is always called as `run-in-limesurvey.sh backup.sh`. A backup is a folder in `/var/www/html/clouve/backups/`, on LimeSurvey's own volume, that only root can open and the web server never serves. Nothing deletes it automatically. It holds the database, `upload/`, the config files with the encryption keys, and the plugins the admin added ([reference/backup-restore.md](../reference/backup-restore.md)).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- Before a restore, a delete, a bulk change, or a theme or plugin install. Other playbooks send you here.
- The admin asks for a backup, or for a copy to keep somewhere else.
- Not for one survey's questions or answers: that is [copy-or-move-a-survey](copy-or-move-a-survey.md) or [export-and-summarize-responses](export-and-summarize-responses.md).

## Before you start

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --list
```

The health report shows the free space and the state of the site. The list shows the backups that are there, by name (the UTC time each was made).

## Steps

### 1. Make the backup

Gate: a backup locks the site while it runs. Participants and admins see a maintenance page until it is done. For a small site that is a few seconds, and for a site with a large database or many uploaded files it is minutes. Say so, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh
```

The script turns maintenance mode on (`hard-cli`), dumps the database, archives `upload/`, the config files and the added plugins, checks every file, and puts maintenance mode back to what it was before: off, or the mode the admin had set. The last line names the backup: `done: <name> (<size>)`.

- Exit 3: not enough free space. Nothing was written. The message gives both numbers.
- Exit 2 or 4: a step or the check failed. The half-made backup is removed and maintenance mode is back as it was.
- Exit 5, or a message that the maintenance mode could not be put back: the site is still locked. The next run of verify-health.sh, of a backup or of a restore lifts that lock by itself, so run the health report:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

A backup can also die without a word, when the connection is fine and the container is stopped or runs out of memory. It then leaves the site locked and a half-made folder. The same health report cleans that up and says so in a `[WARN] backup` line. Such a run made no backup: take a new one.

`--no-maintenance` skips the lock. People can keep answering, and an answer that arrives during the dump may be in the backup only in part.

Gate: use it only when the admin can't take the interruption. Say that the backup may then miss part of an answer that arrives while it runs, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --no-maintenance
```

### 2. Check it

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --list
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

The new backup is in the list without `INCOMPLETE`, and the health report shows maintenance mode off.

### 3. Give the admin a copy

The backup sits on the volume it protects, so a lost volume takes it along. For a copy elsewhere, pull it to the Files pane:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/backup-copy.sh pull <backup name>
```

It lands in `limesurvey-backups/<backup name>/` in the Files pane, as six files. Tell the admin to download the whole folder, to keep it somewhere safe (it holds every answer, every participant and the encryption keys), and then to delete it from the Files pane.

## Delete an old backup

Gate: the admin picks the backup by name; deleting it can't be undone. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --delete <backup name> --yes-delete-this-backup
```

## When the scripts say a folder is not root's own

The backups folder belongs to root, and so does the folder it is in. If something replaced either one, by a link or by a folder of another owner, the scripts read and write nothing there and say so, and verify-health.sh shows `[FAIL] clouve` or `[FAIL] backups`. Don't try to repair it. Tell the user to contact Clouve support, with the lines you see.

## Tell the user

Say that the backup is made, what it is called, how big it is, and that it stays on the site's own disk until someone deletes it. Offer the copy for download.
