# Troubleshooting

Symptom, cause, first check and fix. Start every diagnosis with the health report:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

| Symptom | Likely cause | First check | Fix |
|---|---|---|---|
| The site shows "LimeSurvey is starting" or "being restored" | The image's stand-in page: an install or upgrade runs, the start waits for the database, or the image waits for a repair | `upgrade-state.sh`, then `verify-health.sh` | For an install or upgrade: wait. For a start that waits: the database line says whether it answers. For a repair: the output says the way out. |
| The site is down and the Clouve dashboard says it runs | The image waits for a repair and serves no LimeSurvey | `upgrade-state.sh` (exit 4) | Finish the unfinished restore, or tell the user to contact Clouve support ([recover-from-a-failed-upgrade](../playbooks/recover-from-a-failed-upgrade.md)) |
| Every script exits 75 | The container is starting, an install, an upgrade, an unfinished restore, or the image waits for a repair | `upgrade-state.sh` | Wait, or finish the restore ([restore-from-backup](../playbooks/restore-from-backup.md)) |
| "It still looks like the old version" after an update | The image did not try the upgrade (too little space), or it failed and the old version is back | `upgrade-state.sh` | [recover-from-a-failed-upgrade](../playbooks/recover-from-a-failed-upgrade.md) |
| Every script exits 255 | The SSH channel is down: the pod is hidden because its health check fails, or the container is restarting | The database from the agent ([shell-access.md](shell-access.md#mysql)) | Tell the user what you see. You can't restart a container. |
| "Internal Server Error" on a page, nothing more | `debug` is 0, so LimeSurvey hides and logs nothing | Reproduce through the console or `rc.sh` ([diagnose-problems](../playbooks/diagnose-problems.md)) | Depends on the error |
| HTTP 400 "The requested hostname is invalid" on the admin pages | The address is not the public address and not in `allowed_hosts.php` | Which address the admin uses | They use the site's public address. A custom domain is set on the Clouve dashboard. |
| The admin page shows "Database upgrade" | The code is newer than the database | `verify-health.sh` | [recover-from-a-failed-upgrade](../playbooks/recover-from-a-failed-upgrade.md) |
| "A previous database update ... failed or was interrupted" | A database update was cut off | `verify-health.sh` | The same playbook. The database has to be restored. |
| Broken styling, old scripts, odd template errors | Stale caches, often after an upgrade or theme change | | `console.sh flushassets` |
| "Wrong decryption key!", encrypted answers unreadable, SMTP password "cannot be read" | `security.php` is not the one the data was encrypted with | `verify-health.sh` (the keys line) | Put the original keys back alone from a backup ([restore-from-backup](../playbooks/restore-from-backup.md#only-the-keys-are-missing-or-wrong)) |
| Emails don't go out | The email method is not SMTP, or the mail server refuses | `mail-settings.sh show` | [set-up-email](../playbooks/set-up-email.md) |
| Invitations go out but the links don't work | The survey is inactive, or expired | `survey-info.sh <id>` | Activate it, after a yes |
| Invitations are refused by the mail server | The survey's sender address is one the provider does not accept | The preview of `invitations.sh` | Set the survey's `admin` and `adminemail` ([participants-and-email.md](participants-and-email.md#the-sender)) |
| A participant "can't get in" | Their access code is used up, the survey has ended, or they are not on the list. After three wrong codes from one address LimeSurvey also locks that address out for ten minutes, and behind the ingress that can be everyone's address | `participants.sh list`, when the admin asks | The admin decides: a new invitation, or more uses. `admin-users.sh clear-lockouts` lifts a lockout |
| The admin "is locked out" without having typed a wrong password | LimeSurvey counts wrong passwords by the address a request arrives from, which can be one address for every visitor | `admin-users.sh list` | `admin-users.sh clear-lockouts` ([regain-admin-access](../playbooks/regain-admin-access.md)) |
| A plugin stopped working after an update | The upgrade switched it off, or it is not compatible | `extensions.sh plugins-off-after-upgrade` | [after-an-upgrade](../playbooks/after-an-upgrade.md) |
| A survey fell back to the default theme | Its theme lists only an old LimeSurvey version and was uninstalled | `extensions.sh themes` | A new version of the theme from its author |
| The new editor is empty or logs the admin out | The REST API it uses is not reached, or caches are stale | `curl` of `/index.php/rest/v1/version-info` ([shell-access.md](shell-access.md#http)) | `console.sh flushassets`. The classic editor still works. |
| "Could not write" errors, uploads fail | Files under `tmp/` or `upload/` belong to root | `verify-health.sh` (the tmp files line) | The fix below, after a yes |
| The admin can't sign in | Wrong login, a lockout, an account switched off, a lost password | `admin-users.sh list` | [regain-admin-access](../playbooks/regain-admin-access.md) |
| The site is locked: admins and participants see a maintenance page | A backup or restore is running, or maintenance mode was left on: by an admin, or by an upgrade that was cut off and repaired by hand | `verify-health.sh`: `[WARN] jobs` means one is running. It also lifts the lock that a dead backup left, and says so | Wait for a running one. Otherwise, when no upgrade is under way either: `console.sh setmaintenancemode off`, after a yes ([diagnose-problems](../playbooks/diagnose-problems.md)) |
| `rc.sh` says the administration is locked | Maintenance mode is `hard-cli`: a backup or restore is running, or one died | `verify-health.sh` | As the row above. |
| `verify-health.sh` shows `[FAIL] clouve` or `[FAIL] backups` | The image's state folder or the backups folder is a link or not root's: something replaced it | | Change nothing. Tell the user to contact Clouve support. |
| The disk is nearly full | Old backups, a kept upgrade backup, uploaded files, a large database | `verify-health.sh`, `backup.sh --list`, `upgrade-state.sh` | Delete old backups or the kept upgrade backup after a yes. More space is a plan change. |
| Data oddities after a crash or an import | Orphaned rows | | `console.sh checkintegrity --yes`, after a backup and a yes. It changes data without asking ([diagnose-problems](../playbooks/diagnose-problems.md)) |
| `[WARN] debug` in the health report | `debug` is above 0 in `config.php`: every visitor sees error details | | The one command in [diagnose-problems](../playbooks/diagnose-problems.md), after a yes |

## Files that belong to root

A command that ran LimeSurvey's PHP as root leaves cache files under `tmp/` that the web server can't replace. The skill's scripts run as `www-data`, so this comes from a command someone ran by hand.

Gate: say that this gives LimeSurvey's own `tmp/` and `upload/` folders back to the web server's user and touches nothing else. Wait for a yes.

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${LIMESURVEY_HOST} 'sudo chown -R www-data:www-data /var/www/html/tmp /var/www/html/upload'
```

## Maintenance mode

| Mode | Participants | Admins, RemoteControl, REST API |
|---|---|---|
| `off` | answer surveys | work |
| `soft` | can finish a survey they started; nobody new starts | work |
| `hard` | see a maintenance page | work |
| `hard-cli` | see a maintenance page | locked. Only `console.sh setmaintenancemode` lifts it. |

## When nothing fits

Give the user what a support ticket needs: what you ran, what it printed, and when. Clouve's staff can read the container's log, which you can't.
