# Back up

Use this before an import, a package install or uninstall, a repair that runs SQL, a restore or any other bulk change, and whenever the user asks for a backup. The other playbooks send you here.

A backup holds one consistent dump of the database and the files that carry the customer's own state: SuiteCRM's settings, `custom/` (Studio changes, custom fields, layouts, hooks, and the key that decrypts stored passwords such as the SMTP one), `upload/` (note and document files, installed packages), the pictures of email templates (`public/legacy/cache/images`), added modules, the media folders, extensions and the OAuth2 keys. SuiteCRM's own code is not in it, because that comes from the image, so a backup restores onto the same SuiteCRM version only. Each backup is a folder that only root can open, on the same volume as SuiteCRM. It protects against a bad change, an import or a package that went wrong. It does not survive the loss of the volume. Nothing removes a backup until someone removes it by name ([backup-restore.md](../reference/backup-restore.md)).

Script names in the text stand for the scripts in `/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/`. A value in angle brackets in a command is yours to fill in. It stays inside its single quotes, and an apostrophe in it is written `'\''`. backup.sh runs inside the SuiteCRM container, and run-in-suitecrm.sh sends it there.

## Before you start

1. List the backups that exist. This reads only.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --list
```

One line per backup: its name (the UTC time it was made, `YYYYmmdd-HHMMSS`), `complete` or `NOT complete`, the SuiteCRM version and the size. A last line says how many backups the skill keeps and how large they are together. With none, it says so. A name that ends in `.partial` is the folder that a stopped backup left behind, and the list gives the command that removes it (step 5).

2. Look at the disk. The `disk` line of the health report shows how full the volume is and how much the backups take.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/verify-health.sh
```

3. Tell the user that people can keep working while the backup runs. Nobody is signed out and no page is blocked. Something saved during those seconds may not be in it.

## Steps

### 1. Take the backup

It writes a new folder on the volume and changes nothing in SuiteCRM. It can be removed again (step 5).

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh
```

It prints a line that starts with `Backing up SuiteCRM` and gives the version, the number of tables and the size of the files. A line that starts with `Backup` names the new backup, says `is complete` and gives the size of the database dump and of the files. The next line gives the free space that is left, and the last one says how many backups the skill now keeps and how large they are together. The exit code is 0. The dump and the archive of the files are checked before the backup is stamped complete. When anything fails, or the command is cut off, the half-made folder is removed, so a folder marked `complete` is always a whole backup. A run that is killed outright can leave a `<name>.partial` folder behind. The list shows it, step 5 removes it, and the next backup removes one that is older than a day.

Only one backup or restore runs at a time. A second one that starts meanwhile ends with exit 2 at once, names the job that is running and writes nothing.

### 2. For a large install, run it detached

A plain run lasts as long as the command and the SSH session. When the first line of step 1 reports many hundreds of MB of files, or a plain run was cut off, start the backup as a job that keeps running in the container:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --detach backup.sh
```

It prints `job:` and the job's name, which starts with `backup-`, and exits 0 once the job has started. Follow it:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh --status '<job>'
```

It prints the end of the job's log and one status line. `status: running` (exit 3) means wait and ask again. `status: finished, exit 0` (exit 0) means the backup is complete. `status: finished, exit` with any other number (exit 1) carries backup.sh's own exit code: look it up under "If it goes wrong".

### 3. Read the result

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --list
```

The new backup is the one with the latest name, and it says `complete`. Note the name: the user gets it, and a later restore or removal needs it. A folder marked `NOT complete` was never finished and is not a backup. restore.sh refuses it.

### 4. Copy a backup off the deployment, when the user asks

A copy somewhere else is what protects against losing the volume. [backup-restore.md](../reference/backup-restore.md) has the command. It puts the copy into the agent's home folder as one file, and the user downloads it from the Files pane.

The copy waits for a yes like any other gated action, and the gate is written out next to the command in the reference. Before you make a copy, say what it holds: the whole database, so every customer record and every user's password hash, plus SuiteCRM's settings with the database password, the key for stored passwords and the OAuth2 keys. It has to be kept as private as SuiteCRM itself. Make the copy only when the user asks for it and has said yes to that, and delete the file from the Files pane once they have downloaded it.

### 5. Remove an old backup

A removed backup is gone for good. The user picks the backup by its name from the list of step 3. Keep the newest one, and keep any backup that was taken just before a restore, an import or an install the user may still want to undo. The first command is the preview: nothing is removed, and it exits 64.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --remove '<backup>'
```

Gate. Say which backup goes, when it was made, and that it can't be brought back. Wait for a clear yes that names it. Then:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/run-in-suitecrm.sh backup.sh --remove '<backup>' --yes-remove
```

It prints `Removed the backup` and the name. While a restore is cut off, a removal is refused (exit 75): finishing that restore may need the backup. The same two commands remove a leftover, with its name as the list shows it, such as `20261112-101500.partial`. A leftover is no backup, so nothing is lost with it.

### 6. When there is not enough space (exit 2)

backup.sh stops before it writes anything when the volume has less free space than 1.2 times its estimate. The message gives both numbers: about how many MB it needs and how many are free. Tell the user those numbers and the two ways out:

- remove old backups that they name (step 5), or the backup an upgrade kept, once they have checked the upgraded site ([after-an-upgrade](after-an-upgrade.md), step 5);
- move to a plan with a larger disk.

The disk's size is part of the customer's plan. Never change it, and never delete anything else to make room.

## Check the result

The list (step 3) shows the new backup as `complete`, and the `disk` line of verify-health.sh shows what the backups take now.

## Tell the user

- That you made a backup, with its name, the time it was made (UTC and their own time), its size, and what is in it: the database, their files and their settings.
- It is on the same disk as SuiteCRM. It protects against a change that goes wrong, and it is lost if the disk is lost.
- It stays until someone removes it by name, and it takes disk space meanwhile.
- It can be restored onto this SuiteCRM version. After an upgrade, older backups can't be restored any more.
- If they want a copy somewhere else, you can put one in the Files pane for them to download.

## If it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| backup.sh exit 1 | SuiteCRM's settings or its database can't be read, the database lacks SuiteCRM's tables, or two backups started in the same second | Run it again. If it fails again, verify-health.sh and [diagnose-problems](diagnose-problems.md) |
| backup.sh exit 2 | Not enough free space, another backup or restore is running, or the backups folder is not a folder of root's. Nothing was written, and the message says which | Free space: step 6. A job that is running: wait for it (`--status`). A folder that is not root's: change nothing in it, and tell Clouve support |
| backup.sh exit 3 | The dump or the archive failed, or the run was cut off. Nothing was kept | Read the message, check the `database` line of verify-health.sh, and try once more, detached. Then tell the user |
| backup.sh exit 4 | `--remove`: there is no backup of that name | Read the list again |
| Exit 64 | The preview of a removal, or a name that is not a backup's name | A backup's name looks like `20261112-101500`, and a leftover's like `20261112-101500.partial` |
| `--detach` exit 1 | The job was not started. Two jobs in the same second give this too | Run it again |
| `--detach` exit 2 | The job was started, but whether it runs could not be read | `--status` with the job's name |
| `--status` exit 64 | No job of that name. A container that restarted has no jobs | Read the list: the backup is there and complete, or it is not there |
| `--status` prints `stopped without an exit code` (exit 1) | The job was killed | Read the list, then run the backup again |
| Exit 75 | The image is installing or upgrading SuiteCRM, a restore is under way or was cut off, or the container waits. Nothing was written. `backup.sh --list` still works | upgrade-state.sh says which. Wait ([failed-upgrade](failed-upgrade.md)), or finish the restore ([restore-from-backup](restore-from-backup.md)) |
| Exit 255 | The SSH channel failed or dropped. A plain backup stops with it | Read the list, then [diagnose-problems](diagnose-problems.md) |
