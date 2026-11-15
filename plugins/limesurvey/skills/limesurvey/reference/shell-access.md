# Shell access

How you reach LimeSurvey from the Magneto Agent container: the three channels, what the scripts do on the way, their exit codes, and the raw commands for looking around.

## The three channels

| Channel | For | How |
|---|---|---|
| The skill's scripts over SSH | Everything that reads or changes LimeSurvey | The scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/` |
| HTTP to port 8080 | What a visitor gets | `curl` to `http://${LIMESURVEY_HOST}:8080/` |
| MySQL over TCP | Read-only queries | `mysql` with the password in `MYSQL_PWD` |

The agent has no `docker` and no `kubectl`. It can't restart a container or read a container's stdout log.

## How a script reaches the container

Every script calls run-in-limesurvey.sh, and that is the only script that opens the SSH channel:

1. It packs the skill's in-container files (`scripts/remote/`) into one small archive.
2. It signs in as `clouve-ops` with `sshpass -e`. The password comes from `clv-secret` and is set in the environment of that one command, so it is never on a command line.
3. The channel's stdin carries the archive, then the request (a JSON object, or a file). Requests hold names, addresses and sometimes a new password, which is why they travel on stdin and not as arguments.
4. In the container, start-up code that runs as root unpacks the archive into a folder under `/tmp` that only this run uses, checks the state of the site, runs the script as `www-data` (PHP) or as root (backups, restores, the state reports), and removes the folder.

The state check stops a script with exit 75 while the web server is not up yet (the container is starting, or the image is installing or upgrading LimeSurvey, or waiting for a repair) and while a restore is unfinished. What only reads always runs: the two state reports, `backup.sh --list` and `restore.sh --last-log`. A restore may run again over its own marker, and the keys-only restore may also run while the image waits for a repair.

Nothing is left in the container, and nothing is written to LimeSurvey's volume by the transport. Because the scripts travel with each call, a fix to the skill needs no new image.

The PHP scripts start LimeSurvey's own application from the command line as the site's main admin: the first active account with the superadmin permission. They keep the session in memory, so no session row, no cookie and no sign-in record is made, and LimeSurvey's RemoteControl interface does not have to be switched on ([remotecontrol.md](remotecontrol.md)).

## Exit codes every script shares

| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | The thing is not there, LimeSurvey refused, or a setting or tool is missing. stderr says which. |
| 64 | Usage: a missing or wrong option, or a command the script refuses |
| 70 | The start-up code in the container failed before the script ran |
| 75 | The container is still starting, LimeSurvey is being installed, upgraded or restored, or the image is waiting for a repair. Nothing was run. upgrade-state.sh shows where it stands. |
| 255 | SSH could not reach the container. stderr has `could not reach clouve-ops@<host>`. |

Each script's `--help` lists the codes of its own (2 and 3 mean different things in different scripts).

## Stdin

A script reads stdin only when it says so: `rc.sh --stdin`, `participants.sh add`, `admin-users.sh set-password`, `backup-copy.sh push`. Your shell's stdin can stay open with nothing on it, and a script that waited for it would hang.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh list_surveys
printf '%s' '{"iSurveyID": <survey id>}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --stdin list_groups
```

## Long runs

Most calls take well under a second. A backup or a restore of a site with many uploaded files takes longer. Your Bash calls get 2 minutes unless they pass a longer timeout, 10 minutes at most, and a call that reaches its timeout moves to the background instead of stopping. If the connection drops:

- backup.sh stops, removes the half-made backup and puts maintenance mode back. When it can't (its process was killed outright), the next verify-health.sh, backup or restore does it, and says so.
- restore.sh goes on to the end in the container and writes a log, which `restore.sh --last-log` shows.

So after a dropped call, read the state before you run anything again:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

## Raw SSH

For looking around: free space, file owners, processes. Both containers take the same account.

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${LIMESURVEY_HOST} 'df -h /var/www/html /var/www/html/upload'
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${LIMESURVEY_DB_HOST} 'df -h /var/lib/mysql'
```

- The four `-o` options go on every raw `ssh`. The containers make new host keys at every start. Without `StrictHostKeyChecking=accept-new`, `sshpass` exits 6 and prints nothing.
- An SSH session does not have the container's environment. The database settings are in LimeSurvey's `config.php`, which the scripts read for you.
- `clouve-ops` has passwordless sudo. Anything that runs LimeSurvey's PHP has to run as `www-data`: as root it leaves files in `tmp/` that LimeSurvey can't replace.
- Never print `application/config/config.php` or `application/config/security.php`.
- The container's process list can show the arguments of running commands, so never run a command there with a password as an argument.

## HTTP

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 "http://${LIMESURVEY_HOST}:8080/"
curl -s --max-time 15 "http://${LIMESURVEY_HOST}:8080/index.php/rest/v1/version-info"
```

`/` answers 200 without a sign-in. `version-info` gives the database version and whether a database update is pending, also without a sign-in. The admin pages answer 400 ("The requested hostname is invalid") for a host name that is not the public address or in `allowed_hosts.php`, so they can't be scripted from here by the container's name.

## MySQL

```bash
MYSQL_PWD="${LIMESURVEY_DB_PASSWORD:-$(clv-secret LIMESURVEY_DB_PASSWORD)}" mysql --no-defaults -h ${LIMESURVEY_DB_HOST} -P ${LIMESURVEY_DB_PORT:-3306} -u ${LIMESURVEY_DB_USER} ${LIMESURVEY_DB_NAME} -e 'SELECT stg_value FROM lime_settings_global WHERE stg_name = "DBVersion"'
```

`--no-defaults` has to be the first option: an option file such as `~/.my.cnf` could otherwise override the password or the host. The database account can write, so only the rule against SQL writes keeps this channel read-only ([data-model.md](data-model.md)).
