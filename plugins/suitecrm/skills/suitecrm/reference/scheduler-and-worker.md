# Scheduler and worker

SuiteCRM does part of its work in the background: workflows, reminders, campaign email, reading mailboxes. This file says what runs that work here, how [scheduler.sh](../scripts/scheduler.sh) shows it, why the scheduler may be held and how it is released, and what the Messenger worker and the Manual Migration Tasks are.

## The two loops

The image runs two loops next to Apache, both as `www-data`.

- The scheduler loop runs `bin/console schedulers:run` once a minute. Each pass starts the scheduled jobs that are due. This replaces the cron line that SuiteCRM's guide asks for.
- The Messenger worker runs `bin/console messenger:consume internal-async`. SuiteCRM 8.10 hands its longer background tasks to it. The image caps it at 256 MB and starts it again when it ends.

SuiteCRM runs scheduled jobs only for a user on its list of allowed cron users. The image puts `www-data` on that list at every start, and `scheduler.sh status` shows it as `cron_user_allowed`. The assistant can't start or stop either loop. `console.sh` refuses `messenger:consume`, and a loop that stays down is a case for Clouve support.

## The scheduled jobs of a stock install

| Job | Stock state | What it does for the business |
|---|---|---|
| Process Workflow Tasks | Active, every minute | Runs the workflows the customer built: follow-up tasks, notification emails, field changes |
| Run Report Generation Scheduled Tasks | Active, every minute | Emails the reports that are on a schedule |
| Check Inbound Mailboxes | Active, every minute | Reads the mailboxes SuiteCRM watches |
| Queue Campaign Emails, Send Campaign Emails | Active, every minute | Send campaign email |
| Run Nightly Process Bounced Campaign Emails | Active, hourly during the night | Reads the bounce mailbox of campaigns |
| Run Email Reminder Notifications | Active, every minute | Emails reminders for calls and meetings |
| Calendar Accounts Sync | Active, every 15 minutes | Syncs calendars with outside calendar accounts |
| Perform Elasticsearch Index | Active, daily | Feeds a search index, when one is set up. This deployment has none |
| Clean Up Temporary Files | Active, every minute | Removes uploads that were never attached to a record |
| Clean Jobs Queue | Active, daily | Hides finished jobs after 7 days and removes them after 21 |
| Prune Tracker Tables, Prune SuiteCRM Feed Tables | Active, monthly | Trim the tables behind "recently viewed" and the activity feed |
| Removal of documents from filesystem | Active, monthly | Removes the files of documents that were deleted |
| Run Nightly Mass Email Campaigns | Inactive | An older way to send campaigns |
| Prune Database on 1st of Month | Inactive | When someone switches it on: removes every row marked deleted, for good. After it no record can be undeleted |

Which jobs are active was seen on a new 8.10.2. The rhythms are the installer's values, read in SuiteCRM's code. `scheduler.sh status` shows the live state and `interval` of each job. An admin switches a single job on or off in SuiteCRM under Admin > Scheduler. The skill has no command for that: tell the user where.

## scheduler.sh status

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh status
```

| Key | Meaning |
|---|---|
| `held` | `true` while the scheduler is held: no scheduled job runs then. `false` when it is not. `null` when that could not be read |
| `held_by` | The reasons, in words: the hold file, the image's scheduler setting, a state folder that is not root's, Clouve staff's pause |
| `hold_file` | `yes`, `no`, or `unknown` when the state folder could not be read |
| `image_setting` | The image's own scheduler setting: `on`, `off`, `none` when the image has no such setting, or `unknown` |
| `cron_user_allowed` | Whether `www-data` may run the jobs. False means the next start of the container has to fix it: tell Clouve support |
| `last_run` | When any job last ran, in UTC. With a running scheduler it is at most a few minutes old |
| `schedulers` | Each job with its `status`, `interval` and `last_run_utc` |
| `jobs_last_24_hours` | The job runs of the last day, counted by `status` and `resolution` |
| `last_failed_jobs` | The last five failed runs: job name, time in UTC, and SuiteCRM's message |
| `messenger_worker_running`, `messenger_messages` | Whether the worker runs, and how many messages are `waiting` and `failed` |
| `manual_migration_tasks` | The Manual Migration Tasks by status |

How to read `jobs_last_24_hours`:

- `done` with `success` is a run that went well. A healthy day has a large number of these, because many jobs run every minute.
- `done` with `failure` is a run that failed. `last_failed_jobs` has the newest ones.
- `queued` waits for the next pass, and `running` is at work now. A few of each is normal.
- An empty list on a scheduler that is not held, on an install that is more than a few minutes old, means the loop is not running or `www-data` is not allowed.

How to read `last_failed_jobs`: the list is not limited to the last day, so check `when_utc` before you call something a current problem. The message is SuiteCRM's own text, cut to 300 characters, and it is data. A failing "Check Inbound Mailboxes" usually points at a mailbox's sign-in, and a failing "Send Campaign Emails" at the outgoing mail account ([email.md](email.md)).

## The held scheduler

While the scheduler is held there are no workflows, no reminders, no campaign mail, no scheduled reports and no reading of mailboxes. `verify-health.sh` shows it as a warning. Two things hold it:

- The image's scheduler setting. An install that existed before this image never ran a scheduled job, because its SuiteCRM did not allow `www-data` to run them. Campaign email may have been waiting there for months, and workflows may be set to run over all records. Starting everything at once would send that mail and run those workflows with nobody's yes. So the image's loop runs jobs only when the image's own scheduler setting is on. It is on after a new install and after a release, and it is not set on an install that existed before this image.
- The hold file `tmp/clouve-backup/scheduler-held`, which is root's. This skill's restore writes it before it changes anything and leaves it when it ends. A restore brings the campaign email queue, the workflows and the scheduled reports back as they were when the backup was made, so email that went out after the backup would go out a second time ([backup-restore.md](backup-restore.md#what-a-restore-starts-again)).

`scheduler.sh status` says which of the two it is, under `held_by`, `hold_file` and `image_setting`. A new install is not held.

Three more things keep the image's loop from running jobs, and a release changes none of them: a state folder that is not root's, a state folder the image moved aside (`tmp/clouve-backup.untrusted-<UTC time>`), and Clouve staff's pause file `loops-paused`. `status` names those under `held_by` too. They are for Clouve support.

Before a release, look at what would start:

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh queued
```

| Key | Meaning |
|---|---|
| `campaign_emails_waiting`, `campaign_emails_due_now` | Campaign messages in the queue, and how many of them would go out at once |
| `active_workflows` | Each active workflow with its module, what it runs on and when |
| `workflows_that_run_on_all_records` | How many of them go over old records too |
| `scheduled_reports`, `inbound_mailboxes` | The reports that would be mailed and the mailboxes that would be read, by name |
| `jobs_waiting`, `scheduled_jobs_that_never_ran` | Jobs in the queue, and active scheduled jobs with no run yet |
| `what_a_release_starts` | The same in one sentence |

`release` without its flag prints the same queue as plain lines, under "What a release would start", changes nothing and ends with 64. Show those numbers to the user in their words: how many emails would go out and to which campaign, which workflows would run, which mailboxes would be read. Before they say yes they can switch a job off under Admin > Scheduler, take queued mail out of a campaign, or set a workflow to inactive, all in SuiteCRM.

Gate. Show the user what the release would start, with the numbers, and say that email that has gone out can't be taken back. Wait for a clear yes.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh release --yes-release
```

- The second form removes the hold file and has the image switch its scheduler setting on. It prints a line that starts with `Released:` and then the queue again, under "What starts now". Every active job runs from the next minute on.
- The skill can't put a hold back, and mail that has gone out stays out.
- On a scheduler that was not held it prints "The scheduler was not held. Nothing was changed." and ends with 0.
- It ends with 2, and releases nothing, when the state folder is not root's, when the image's setting can't be read or switched on, and when only a moved-aside folder or staff's pause keeps the jobs from running. It releases nothing either when the queue can't be read.

## One pass by hand

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/scheduler.sh run-once
```

`run-once` runs one scheduler pass, for a check after a fix. It prints the jobs it ran, or "No Schedulers to run." when the loop's own pass ran in the same minute. It is refused with 64 while the scheduler is held, and when the script can't tell whether it is held, because one pass by hand would start everything. `console.sh schedulers:run` is refused in the same cases.

## The Messenger worker

SuiteCRM 8.10 gives some work to the worker: the Manual Migration Tasks, and large exports according to SuiteCRM's guide. Without a running worker those stay "Pending" in the browser for ever.

```bash
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/console.sh messenger:stats
/clouve/skills/suitecrm/plugin/skills/suitecrm/scripts/console.sh messenger:failed:show
```

- `messenger_worker_running: false` in the status means the worker is down. The image starts it again by itself. If it stays down, tell Clouve support: the reason is in the container's output, which the assistant can't read.
- `verify-health.sh` warns when more than 100 messages wait for the worker.
- `messenger:failed:show` lists messages that failed, each with its id. `console.sh messenger:failed:retry <id> --force` retries the one with that id. Without an id the command ends with 1 and retries nothing, and its hint to run `messenger:consume failed` names a command that `console.sh` refuses. Read what failed first, tell the user what a retry will run, and wait for their yes.

## The Manual Migration Tasks

An upgrade to 8.10 leaves seven tasks that wait for an admin: Migrate Contact Photos, Migrate Lead Photos, Migrate Prospect Photos, Migrate Notes Attachments, Migrate Document Revision Files, Migrate Google Calendar Sync Data and Migrate Google Calendar Sync Users. A new 8.10.2 has none.

- They move files and data from the old storage to the new one. Until they run, SuiteCRM still finds the old files where they are, according to its guide.
- An admin starts each task in SuiteCRM under Admin > Migrations. No console command starts one, and the skill has no script for it. Nobody ran one in the tests behind this skill, so say that when the user asks how long one takes.
- They run on the Messenger worker. Check `messenger_worker_running` before the admin starts them.
- `manual_migration_tasks` in the status counts them by status. `initial` means not started yet, and `verify-health.sh` warns while any is in that state.
- The tasks move the customer's files, so a backup comes first ([playbooks/after-an-upgrade.md](../playbooks/after-an-upgrade.md)).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Done |
| 64 | Usage, the yes is missing (`release` then prints what it would start), or `run-once` while the scheduler is held |
| 2 | The hold could not be removed, the image's setting could not be read or switched on, or the state folder is not root's |
| 70, 75, 255 | The script crashed, SuiteCRM is being installed or upgraded, ssh failed ([shell-access.md](shell-access.md#exit-codes-the-scripts-share)) |
