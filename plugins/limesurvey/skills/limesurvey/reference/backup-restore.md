# Backup and restore

## What a complete backup is

| Part | Why |
|---|---|
| A dump of the database | Everything LimeSurvey knows: surveys, answers (`lime_responses_<id>`), participants (`lime_tokens_<id>`), archived answers (`lime_old_*`), accounts, permissions, settings, plugin settings |
| `upload/` | Files participants uploaded, survey images, uploaded themes and plugins |
| `application/config/security.php` | The encryption keys |
| `application/config/config.php` and `allowed_hosts.php` | The site's own settings, for reference |
| The plugin folders under `plugins/` that the admin added | Code that is not in the image |
| LimeSurvey's version | A dump fits code of the same database version, or newer code that can update it |

Not needed: `tmp/` (caches) and LimeSurvey's own code (it comes from the image).

backup.sh makes exactly this, in `/var/www/html/clouve/backups/<UTC time>/`: `database.sql.gz`, `upload.tar.gz`, `config.tar.gz`, `plugins.tar.gz`, `manifest.json` and `SHA256SUMS`. The folder is root's, mode 700, and Apache never serves `clouve/`.

backup.sh and restore.sh run inside the LimeSurvey container as root. They are in `scripts/remote/`, and every command calls them through the runner: `run-in-limesurvey.sh backup.sh`, `run-in-limesurvey.sh restore.sh`.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh --list
```

## Why security.php matters

It holds the keys that encrypt answers to questions marked as encrypted, encrypted participant fields, the stored SMTP password, and encrypted plugin settings. Two facts make it dangerous (both tested on 7.10.0):

- LimeSurvey makes a new `security.php`, with new keys, the moment it starts and the file is missing. A web request does it, and so does a console command.
- With other keys, everything that was encrypted is unreadable: "Wrong decryption key!". Putting the original file back makes it readable again.

So a site whose `security.php` is gone must not be started in any way until the file is back, and a restore puts the file in place before anything else. The skill's scripts refuse to start LimeSurvey without the file, and verify-health.sh does not even ask the web server then. It reports `[FAIL] security.php` when the file is missing and `[FAIL] keys` when the file is there and can't read the data. On a live site a visitor's request can still create a new file within seconds, which is why the second check exists.

The keys line comes from a test that does not start LimeSurvey: a few values that the database holds encrypted (the stored SMTP password, encrypted participant fields, encrypted answers, and in the Customer Kit the SuiteCRM plugin's stored passwords) are tried with the keys in the file. "Nothing encrypted is stored yet" means there was nothing to try them on.

A backup without `security.php` is worth nothing for encrypted data, so backup.sh refuses to make one. When the file is missing or wrong, the way back is the keys alone, from a backup that has the right ones: `restore.sh --keys-only`, below.

## Whose folder it is

`/var/www/html` belongs to the web server's user, so code that runs in LimeSurvey could move the real `clouve` folder aside and put one of its own in its place, with a "backup" in it. The image keeps `clouve` as root's own folder, and the scripts hold to one rule: they read, list, restore from and write to `clouve`, `clouve/backups` and a backup's folder only while each is a real folder that belongs to root, with no link on the way. When one is not, they stop and say so, and they never repair it. The image moves such a folder aside as `clouve.untrusted-<time>` at its next start. So the worst that code in LimeSurvey can do is hide the backups. It can't get a planted one restored. Putting a folder back that was moved aside is a step for Clouve support.

A restore also takes nothing on trust from the archives themselves. Files go back as the web server's user, by name, without the archive's owners and without setuid or setgid bits, and a backup that holds a device file is refused.

## backup.sh

```text
run-in-limesurvey.sh backup.sh [--no-maintenance]
run-in-limesurvey.sh backup.sh --list
run-in-limesurvey.sh backup.sh --delete <name> --yes-delete-this-backup
```

- It runs inside the LimeSurvey container as root and reads the database settings from LimeSurvey's own `config.php`. The database password reaches the dump program in a private options file, never on a command line.
- It turns LimeSurvey's maintenance mode to `hard-cli` for the dump, and afterwards back to what it was: off, or the mode an admin had set. Existing installs have MyISAM tables, and a dump of those is consistent only while nothing writes. `hard-cli` keeps participants out and locks the admin pages, RemoteControl and the REST API. While it is on, `rc.sh` answers that the administration is locked. A backup locks the site, so it has a gate.
- A backup that dies (its process is killed, the container is stopped) can't put the mode back. It leaves a note in its folder that says the lock is its own and what the mode was. The next run of backup.sh, restore.sh or verify-health.sh finds the note, puts the mode back and removes the half-made folder, and says so. A lock that no backup set is left alone.
- It checks free space first (1.2 times the database plus `upload/`), and stops before writing anything when there is too little.
- It checks what it wrote: the dump's last line, each archive, the checksums. A backup that fails is removed.
- Exit codes: 0 done, 1 not the place or time (or a folder that is not root's own), 2 a step failed, 3 too little space, 4 the check failed, 5 the backup is kept but maintenance mode could not be put back.

Backups sit on LimeSurvey's own volume. `backup-copy.sh pull <name>` copies one to the Files pane for the admin to download, and `backup-copy.sh push <name>` puts an uploaded one back into the container.

## restore.sh

```text
run-in-limesurvey.sh restore.sh --backup <name>
run-in-limesurvey.sh restore.sh --backup <name> --yes-replace-current-data [--skip-safety-backup]
run-in-limesurvey.sh restore.sh --keys-only --backup <name>
run-in-limesurvey.sh restore.sh --keys-only --backup <name> --yes-replace-the-keys
run-in-limesurvey.sh restore.sh --last-log
```

Without `--yes-replace-current-data` it checks everything and changes nothing. With it, in this order:

1. The marker `clouve/backups/RESTORE-IN-PROGRESS` is written, before the database is touched. The other scripts refuse to run while it is there.
2. Maintenance mode `hard-cli`, when the site is in a state to take it.
3. The backup's `security.php` goes in place, as the web server's user's file with mode 600. The one that was there is kept in `clouve/backups/before-restore-<time>/`.
4. The dump is loaded over the tables that are there. No table is dropped first. A dump replaces each of its own tables in turn, so LimeSurvey's tables exist at every moment of the load. When the load is done, the tables that the dump does not hold are removed: a failed upgrade or a newer site can have left some.
5. `upload/` is emptied and filled from the backup. Added plugins are put back, except those the image ships itself.
6. When the backup's database is older than the code, LimeSurvey's database update runs.
7. Maintenance mode goes to what the backup recorded. The site stays locked until then, also when the dump was taken without the lock.
8. The caches are flushed, LimeSurvey is started once on the restored data, and the keys are tested against the data.
9. The marker is removed.

Why the tables are never dropped first. The platform's health check asks the site for its front page every 15 seconds and restarts the container after five failures. With the tables gone, that page fails for as long as the load runs, and a database with many answers takes longer than that to load. A container restarted in the middle would then find a database without LimeSurvey's settings table and refuse to start at all. Loaded over the old tables, the front page keeps answering (tested with a load of 74 seconds: 71 requests, 71 answers), and a restart in the middle finds a database the image can start on.

When the container does restart in the middle, the image sees the marker and waits: it shows a page that says the site is being restored, keeps its sshd up, and starts no LimeSurvey. The restore is then run again, as often as it takes, and the image starts LimeSurvey once the marker is gone.

What it keeps: this deployment's own `config.php` (the image writes the database settings and the address there at every start) and `allowed_hosts.php`.

What it refuses: a backup that fails its checksums, a backup whose dump has no LimeSurvey settings table, a backup from a newer LimeSurvey than the container runs, a backup or a folder that is not root's own, and a restore with no backup of the current state from the last hour. For an older one it prints the backup's age and how many answer sets the site has gained since, and wants `--skip-safety-backup`, which you add only after the admin has heard both numbers and said that what was added is not worth keeping. A restore that was cut off needs neither.

`--keys-only` puts back `application/config/security.php` from the backup and nothing else. It first tests the backup's keys against what the database holds encrypted, refuses keys that can't read it, and refuses when the keys in place already can. The file that was there is kept in `clouve/backups/before-restore-<time>/`. It is the way back from `[FAIL] security.php` and `[FAIL] keys` ([playbooks/restore-from-backup.md](../playbooks/restore-from-backup.md#only-the-keys-are-missing-or-wrong)).

Exit codes: 0 done (or the checks passed), 1 not the place or time, 2 the backup can't be used, 3 too little space or no database, 4 it failed after it began (the marker stays; run it again).

## Survey files are not backups

| | `.lss` | `.lsa` | A backup |
|---|---|---|---|
| One survey's questions and settings | yes | yes | yes |
| Its answers and participants | no | yes | yes |
| Uploaded files, accounts, permissions, site settings, other surveys | no | no | yes |
| The encryption keys | no | no | yes |

An `.lsa` holds encrypted values as they are stored, so it can only be read on a site with the same keys.

## LimeSurvey's own "Backup entire database"

The admin's Configuration menu has it. It downloads a dump through the browser, with no `upload/` and no keys. It is not a substitute for backup.sh.
