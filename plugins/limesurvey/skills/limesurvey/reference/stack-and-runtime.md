# Stack and runtime

What runs where, what is on which volume, and what the Clouve image does at every start.

## Containers

| Container | What it runs | Port |
|---|---|---|
| `limesurvey` (`${LIMESURVEY_HOST}`) | Apache with PHP 8.4 and LimeSurvey 7.10.0, and the clouve-ops sshd | 8080 |
| `limesurvey-mariadb` (`${LIMESURVEY_DB_HOST}`) | MariaDB 11.8, and the clouve-ops sshd | 3306 |
| the Magneto Agent | you | |

On Kubernetes the containers are named `tkt-<id>-limesurvey` and so on. Always use the variables.

## Volumes and paths

| Path in the LimeSurvey container | Volume | Holds |
|---|---|---|
| `/var/www/html` | `limesurvey-data` | LimeSurvey's code, `application/config/`, `plugins/`, `tmp/`, and `clouve/` |
| `/var/www/html/upload` | `limesurvey-upload` | Files participants uploaded (`upload/surveys/<id>/files`), survey images, uploaded themes (`upload/themes/survey/`) and plugins (`upload/plugins/`) |
| `/var/lib/mysql` in the database container | `limesurvey-db-data` | The database |

Files worth knowing:

- `application/config/config.php`: the database settings, the public address (`publicurl`), `debug`. It holds the database password. Never print it.
- `application/config/security.php`: the encryption keys. Never print, move, edit or delete it ([backup-restore.md](backup-restore.md#why-securityphp-matters)).
- `application/config/allowed_hosts.php`: the host names LimeSurvey answers its admin pages for.
- `application/config/version.php`: LimeSurvey's version, build and the database version the code needs.
- `clouve/`: the image's state files, the backup an upgrade keeps (`clouve/upgrade-<from>-to-<to>/`) and this skill's backups (`clouve/backups/`). It belongs to root, mode 700, and Apache never serves it. A `clouve.untrusted-<time>` folder next to it is something the image moved aside because it stood in that place and was not root's: leave it to Clouve support.
- `/clouve/limesurvey/package` (in the image, not on a volume): the LimeSurvey release the image ships.

Everything in `upload/` is served as a static file to anyone who knows its name. Never put a dump, an export or a backup there.

## What the image does at every start

Before Apache starts, the image's entrypoint:

1. starts the clouve-ops sshd, and takes the SSH password out of the environment that Apache and PHP see;
2. waits for the database;
3. looks at the code on the volume and the database's version, and installs LimeSurvey on an empty volume, upgrades an older install ([upgrade.md](upgrade.md)), or refuses to start when the volume's code or the database is newer than the image;
4. writes the database settings and `publicurl` into `config.php` from the deployment's settings;
5. keeps `localhost` and the public address's host in `allowed_hosts.php`;
6. in the Customer Kit, writes the SuiteCRM plugin's connection settings ([customer-kit.md](customer-kit.md));
7. starts Apache as PID 1.

Until Apache starts, a stand-in answers on port 8080: `GET /` gets a short page with status 200 ("LimeSurvey is starting. This site is being set up or upgraded."), and every other address gets 503. The skill's scripts refuse with exit 75 during that time. The page shows in three situations, and the reports tell them apart:

- An install or an upgrade runs. upgrade-state.sh names it.
- The start is waiting for the database, before any state is written. upgrade-state.sh says the container is still starting, and verify-health.sh shows `[WARN] starting` and whether the database answers. The image waits up to five minutes, then the container stops and starts again. The health check passes all the while, so a database that is down does not hide the pod during those minutes, and SSH stays up.
- The image is waiting for a repair: a restore of this skill is unfinished (the page then says the site is being restored), it stopped in the middle of an upgrade or of its way back from one, or the code and the database don't belong together and it has no backup it trusts. It waits without a time limit, and the Clouve dashboard shows the deployment as running. upgrade-state.sh exits 4 and says the way out.

## Don't fight these

- `config.php`'s database settings and `publicurl`: set from the deployment at every start. A custom domain comes from the Clouve dashboard.
- `allowed_hosts.php`: the image's two entries come back at every start. Extra entries stay.
- LimeSurvey's version: the image's. The in-app updater (ComfortUpdate) is off in `version.php`.
- `clouve/`: only through the scripts.
- Apache: PID 1. Never stop or restart it: the container ends with it, and a restart signals every process in the container.
- CPU, memory and disk: the customer's plan.

## Logs and debug

- Apache's access and error logs go to the container's stdout, which you can't read. Clouve's staff can.
- With `debug` at 0 in `config.php` (the default), LimeSurvey switches error reporting off: a broken page shows "Internal Server Error" and nothing is logged anywhere.
- LimeSurvey's console always prints the full error and stack trace, to you only. That is the way to see an error ([playbooks/diagnose-problems.md](../playbooks/diagnose-problems.md)).
- `debug` at 1 or 2 shows error details, with file paths and queries, to every visitor, and switches caches off. Leave it at 0.
- Console commands leave a small PHP session file in the container's `/tmp`. It is not on a volume and goes at the next restart.

## What isn't here

- No sendmail program, so LimeSurvey's email methods "PHP mail", "sendmail" and "qmail" send nothing. SMTP works.
- No PHP `imap` extension, so bounce processing does not work.
- No cron. LimeSurvey needs none for surveys, invitations or exports. A plugin that wants a scheduled job does not get one.

## Things LimeSurvey 7 does that surprise people

- The first admin sign-in writes `allowed_hosts.php` with whatever host name that request used, when the file is missing. The image seeds it first for that reason.
- The REST API at `/rest/v1` is always on. The new survey editor uses it. It signs in with an admin's password.
- RemoteControl is off by default (Global settings, Interfaces). Once an admin switches it on, it is reachable from the internet with any admin's password. This skill does not need it and does not switch it.
- The new editor opens by default. The classic editor is still there: the menu under the admin's name at the top right has the entry "Editor version", which switches between the two.

Tested on 7.10.0 unless a line says otherwise.
