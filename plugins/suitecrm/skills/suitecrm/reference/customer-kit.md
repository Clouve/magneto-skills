# The Customer Kit

In the Customer Kit, LimeSurvey sits next to SuiteCRM and sends survey responses in as leads. This file says what that link does on SuiteCRM's side, what it needs, what breaks it, and which fix belongs to whom. It applies only when a LimeSurvey container is in the same deployment. This prints variable names when it is, and nothing when it is not:

```bash
compgen -e | grep -i limesurvey
```

The survey side (the surveys, the field mapping, the plugin's settings and its log) belongs to the `limesurvey` skill. This skill looks after SuiteCRM's half and the leads once they are in.

## What LimeSurvey does on SuiteCRM's side

- Clouve's SuiteCRM plugin in LimeSurvey calls SuiteCRM inside the deployment, at `http://suitecrm/...`, over plain HTTP.
- It signs in through an OAuth2 client named "LimeSurvey Integration". The plugin makes that client itself, by writing a row into SuiteCRM's `oauth2clients` table over a database connection of its own. For that it holds SuiteCRM's database password. The client's secret is kept only in LimeSurvey's settings.
- It asks for a token with the password grant, as SuiteCRM's main admin, with the admin's password as the plugin's settings hold it. At install that is the admin's first password, the one the Clouve dashboard shows. A token lasts an hour.
- With the token it makes three kinds of call: a list of modules as its connection test, the field list of a module for its mapping screen, and one call per survey response that creates the record, usually a lead.
- Those records are created as the main admin, through SuiteCRM's own code. So the admin shows as their creator, as for everything the assistant's own scripts write, and module logic and workflows apply to them.

## What it needs from SuiteCRM

1. The addresses `/Api/access_token` and `/Api/V8/...` at the root of the site.
2. The row "LimeSurvey Integration" in `oauth2clients`, not deleted, with the secret LimeSurvey knows.
3. The password grant, which SuiteCRM 8.10.2 has switched on.
4. The key pair `public/legacy/Api/V8/OAuth2/private.key` and `public.key`, readable by `www-data`. SuiteCRM signs every token with it.
5. The main admin active, an admin, and with the same login and password as when LimeSurvey stored them.
6. The database account able to write to `oauth2clients` from the LimeSurvey container.

SuiteCRM 8.10.2 changed none of this. In a test the token request and all three calls answered after an upgrade from 8.9.1 as they did before it.

## What breaks it, and the fix

When the link breaks, SuiteCRM shows nothing. The only sign on this side is that no new leads arrive. On LimeSurvey's side the sign is a failed row in the survey's sync log. Don't judge the link by the plugin's own status check alone. It asks SuiteCRM whether the client is still there, and says so when it is gone, until "Initialize OAuth2" has been run in the plugin's settings. It does not try the sign-in: with the main admin's password changed or the account switched off it still reads "ready".

| What happened | Fix | Whose |
|---|---|---|
| Someone changed the main admin's password in SuiteCRM | Either of two things puts it right. `restore-admin-password.sh --yes-reset` puts the dashboard's password back, the one the plugin holds from the install. Or the admin types the same new password into the plugin's settings in LimeSurvey (SuiteCRM Admin Password), which keeps the new password | This skill for the first, the `limesurvey` skill for the second |
| The main admin was deactivated or lost its admin rights in the browser | The same command makes the account active and an admin again | This skill |
| The main admin's login was renamed | The admin renames it back in SuiteCRM, to the login in `SUITECRM_ADMIN_USER`. The skill has no command that renames a user | The admin, in the browser |
| The client "LimeSurvey Integration" was deleted or edited | "Initialize OAuth2" in the plugin's settings in LimeSurvey makes the client again. Nothing on this side repairs the row, and nobody writes it by hand | The `limesurvey` skill |
| A restore brought back an older `oauth2clients` table | A client the plugin made after that backup is gone. "Initialize OAuth2" in the plugin's settings makes a new one | The `limesurvey` skill |
| The key pair is missing, or its two halves no longer match | Token requests then fail for every API client (reasoned from how tokens are signed, not tested). This goes to Clouve support. A full restore of a backup that holds the pair also brings it back, together with everything else in that backup | Clouve support |
| The database password was rotated | The image writes the new password into both apps' settings at their next start, which the assistant can't trigger | Clouve support |

Two rules follow for this skill in a Customer Kit:

- This skill only ever sets the main admin's password back to the dashboard's. `temp-password.sh` refuses to reset it for this reason. SuiteCRM and the plugin have to hold the same password afterwards: if the plugin was given another one earlier, it needs the dashboard's again.
- After any restore, check the client row with the query below, and tell the user that the survey link may need to be set up again on the LimeSurvey side.

The first form below changes nothing and says what the second would do.

Gate. Say that the main admin's password goes back to the one on the Clouve dashboard, and that whoever knows the current one loses it. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/restore-admin-password.sh --yes-reset
```

The script also makes the account active and an admin again. It does not end the sign-in throttle.

## Read-only checks

Is the client there? One row with `deleted` 0 and the grant type `password` is what the plugin needs. No row, or `deleted` 1, means the plugin has to make a new client ("Initialize OAuth2" in its settings). `sql-read.sh` refuses the `secret` column and the token tables, so the client is checked by name and state only.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table 'SELECT id, name, deleted, allowed_grant_type FROM oauth2clients WHERE name = "LimeSurvey Integration"'
```

Is the main admin as LimeSurvey expects? `status` should be Active and `is_admin` true.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/users.sh show "${SUITECRM_ADMIN_USER}"
```

Are the keys there? This lists the two files with their owner and mode, and reads nothing from them. Never print a key.

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 clouve-ops@${SUITECRM_HOST} 'sudo -n -u www-data ls -l /var/www/html/public/legacy/Api/V8/OAuth2/private.key /var/www/html/public/legacy/Api/V8/OAuth2/public.key'
```

Are leads still arriving? The first query counts leads by source with the newest arrival of each, the second counts new leads per day for two weeks, and the third shows the newest ten with who created them. Leads from surveys have the main admin as their creator.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table 'SELECT lead_source, COUNT(*) AS leads, MAX(date_entered) AS newest FROM leads WHERE deleted = 0 GROUP BY lead_source ORDER BY newest DESC'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table 'SELECT DATE(date_entered) AS created_on, COUNT(*) AS leads FROM leads WHERE deleted = 0 AND date_entered >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 14 DAY) GROUP BY DATE(date_entered) ORDER BY created_on DESC'
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/sql-read.sh --table 'SELECT l.first_name, l.last_name, l.lead_source, l.date_entered, u.user_name AS created_by FROM leads l LEFT JOIN users u ON u.id = l.created_by AND u.deleted = 0 WHERE l.deleted = 0 ORDER BY l.date_entered DESC LIMIT 10'
```

The times are in UTC. The lead source of a survey's leads is whatever that survey's mapping sets, so ask the user what to look for.

## What this skill can't check

The assistant can't try the sign-in itself. The client's secret is in LimeSurvey's settings, and the admin's password must not travel in a command. The test of the whole path, a survey response that becomes a lead, belongs to the `limesurvey` skill. The plugin's status check is not that test: it reports a client that is gone, and it can read "ready" while the admin's password no longer matches. A failed row in the survey's sync log is the sign that the link is broken. When the checks above are all good and leads still don't arrive, hand over to that skill, and say which checks passed.
