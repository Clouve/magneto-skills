# Upgrades

LimeSurvey's version comes from the Clouve image. When a newer image starts on a volume with older LimeSurvey code, the image upgrades the site itself, before the web server starts. Nothing in this skill starts an upgrade, and LimeSurvey's own updater (ComfortUpdate) is switched off.

## Why it runs before the web server

With new code on an old database, LimeSurvey offers a "Database upgrade" page to anyone who opens the admin address, without a sign-in. So the image finishes the update first. While it runs, a stand-in answers on port 8080 with a short page, so that the platform's health check does not restart the container halfway. The same page shows while a start waits for the database ([stack-and-runtime.md](stack-and-runtime.md#what-the-image-does-at-every-start)).

## What the image does

1. Checks that the volume has the space and the inodes for the old code (about 520 MB) and a dump of the database. When it has not, or when the backup can't be made, the image does not try the upgrade: it writes a note with its reason (`clouve/upgrade-skipped`), starts the old version, and tries again at its next start. Nothing was changed.
2. Saves a dump of the database and moves the old code into `/var/www/html/clouve/upgrade-<from>-to-<to>/`. It keeps in place: `config.php`, `security.php`, `allowed_hosts.php`, the plugins the admin added under `plugins/`, and anything at the top level that LimeSurvey does not ship. `upload/` is its own volume and is not touched.
3. Copies the new code in.
4. Runs LimeSurvey's database update as `www-data`, under maintenance mode.
5. On success: switches Clouve's SuiteCRM plugin back on when it was on before (Customer Kit), flushes the caches, and keeps the backup folder.
6. On failure: puts the old version back. The old code is moved back, and the database is loaded from the dump only when the upgrade had begun to write to it (the marker `db-touched` in the upgrade's folder). Then it tries once more. After the second failure it records the failure with its reason (`clouve/upgrade-failed`) and starts the old version. It does not try again until a newer image arrives.
7. When it can't get to a site that fits together, it does not exit and start over and over. It leaves a note with its reason (`clouve/needs-attention`), keeps the stand-in page and its sshd up, and waits for a repair. That is the case when its own way back failed or could not be recorded (a full volume), and when the code and the database don't belong together and it has no backup it trusts. The state file can still say `upgrade` or `restore` then, although no work is going on: the note is what tells the two apart. A start that finds an unfinished restore of this skill waits in the same way, until the restore is done, and its note says so (`kind=restore`). The note has five lines: `reason`, `since` (UTC), `from` and `to` (the version on the volume and the image's) and `kind` (`repair` or `restore`). upgrade-state.sh and verify-health.sh show them.

## The state

The image keeps a state file in the upgrade's folder, with the phase and the step within it, and the skill reads it:

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/upgrade-state.sh
```

| Phase | Meaning | The skill's scripts |
|---|---|---|
| none | No upgrade under way | run |
| `backup` | The image is saving the old code and the dump. Nothing in the site has changed. | refuse (exit 75) |
| `upgrade` | The backup is complete; the new code and the database update are going in. | refuse |
| `restore` | The upgrade failed and the old version is being put back. | refuse |
| `failed` | The old version is back and runs. upgrade-state.sh gives the image's reason. | run |
| `done` | The upgrade finished. Its backup is kept. | run |

Next to the phases, upgrade-state.sh reports three more states:

| State | Meaning | The skill's scripts |
|---|---|---|
| Starting | The web server is not up yet, and no phase is written: the start is waiting for the database. | refuse (exit 75) |
| Not tried | The image did not try the upgrade, and says why. The old version runs. | run |
| Waiting for a repair (exit 4) | The image can't go on by itself. It serves no LimeSurvey, and the Clouve dashboard shows the deployment as running. | The two reports, the listings, a restore over its own marker and the keys-only restore run. Everything else refuses. |

upgrade-state.sh names the step next to the phase: `moving`, `copying`, `updating` or `finishing` in the phase `upgrade`, and `removing-new` or `moving-back` on the way back. It is what Clouve's staff ask for first.

A container that is restarted in the middle picks the upgrade up at its next start, by the phase it finds. The same goes for a first install: the image keeps a stamp (`clouve/install-in-progress`) while it installs, and the scripts refuse during that time too.

After a failed upgrade and after one that was not tried, the site keeps the version it had: LimeSurvey 6, for the move to 7. This skill's scripts were written for version 7 and were not run on 6, so on version 6 keep to verify-health.sh and upgrade-state.sh until the site is on version 7.

## What changes from LimeSurvey 6 to 7

- Each survey's answer table is renamed (`lime_survey_<id>` becomes `lime_responses_<id>`) and its columns too (`Q<question id>`). The update copies every answer.
- Ranking questions store their items as subquestions. A gap in someone's ranking is closed up.
- A new survey editor opens by default. The classic one is still there.
- Times are recorded in UTC. Older times are not converted.
- Every added plugin is switched off ([plugins-and-themes.md](plugins-and-themes.md#what-an-upgrade-does)).
- Themes that list only LimeSurvey 5 or older are uninstalled.
- Changes made inside LimeSurvey's own theme files are lost. Uploaded themes are kept.
- Tables keep the storage engine they had: an older install stays on MyISAM.

## The kept backup

After a successful upgrade the folder `clouve/upgrade-<from>-to-<to>/` stays on the volume: the old code and the dump, about 600 MB. It is the only way back to the old version, and only Clouve's staff would use it. Once the admin has checked their surveys and answers on the new version and said yes, remove it:

```text
upgrade-state.sh --remove-kept-backup <folder> --yes
```

The script refuses for an upgrade that failed or is still running.

## After a failed upgrade

The site runs the old version, with its data as it was. [playbooks/recover-from-a-failed-upgrade.md](../playbooks/recover-from-a-failed-upgrade.md) says what to check and what to tell the user. LimeSurvey 6 has had no security support since August 2026, so report a failed upgrade to Clouve.

## What never to do

- Run ComfortUpdate, or put newer LimeSurvey code on the volume by hand. The image compares the volume's version with its own and refuses to start on code that is newer than the image.
- Run `console.php updatedb` outside the failed-upgrade playbook.
- Remove or edit anything in `clouve/` by hand, or put back a `clouve.untrusted-*` folder that the image moved aside. The second is a step for Clouve support.
