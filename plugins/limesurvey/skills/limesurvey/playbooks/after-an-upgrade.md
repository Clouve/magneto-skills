# After an upgrade

The Clouve image upgrades LimeSurvey itself when a newer image starts on an older install: it saves the old code and a dump of the database, runs LimeSurvey's database update, and starts the new version. This playbook is what to check afterwards, and what to tell the admin. [reference/upgrade.md](../reference/upgrade.md) describes the upgrade itself.

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- The admin says the site looks different, or a plugin stopped working, after an update.
- upgrade-state.sh or verify-health.sh shows that an upgrade backup is kept.
- Not when the upgrade failed: that is [recover-from-a-failed-upgrade](recover-from-a-failed-upgrade.md).

## Steps

### 1. Read where the upgrade stands

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/upgrade-state.sh
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

"The upgrade ... is done" with exit 0 is the state this playbook is for. Exit 2 means it is still running: wait, and tell the user the site shows a short stand-in page meanwhile. Exit 3 means it failed, exit 4 means the container is waiting for a repair, and "did NOT try the upgrade" means the site still runs the old version: all three are in [recover-from-a-failed-upgrade](recover-from-a-failed-upgrade.md).

### 2. Plugins that the upgrade switched off

LimeSurvey's database update switches every added plugin off, compatible or not. The image switches Clouve's own SuiteCRM plugin back on in the Customer Kit, and leaves the others off.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugins-off-after-upgrade
```

The list says for each plugin whether it was on before the upgrade and whether it can be switched on again. Tell the admin which ones are off.

On a LimeSurvey that is not part of the Customer Kit, the list also names `SuiteCRMIntegration`. That is Clouve's plugin for the Customer Kit. It comes with the image, has nothing to connect to here, and stays off: don't offer it.

Gate: for each plugin the admin wants back and that is compatible, say that a plugin is code that runs with LimeSurvey's rights and can read every answer. Back up first ([back-up](back-up.md)), and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugin-activate '<plugin name>'
```

A plugin that is "NOT compatible" was written for an older LimeSurvey. It needs a new version from its author, and it stays off until then. Say what the plugin did, so the admin knows what is missing.

### 3. Themes

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh themes
```

A theme the admin uploaded stays registered when it lists LimeSurvey 6 or 7. One that lists only version 5 or older is uninstalled by the upgrade, and its surveys fall back to the default theme. It needs a new version from its author.

### 4. What changes for the admin in version 7

Tell them what they will notice, without waiting to be asked:

- A new survey editor opens by default. The classic editor is still there: the menu under their name at the top right has the entry "Editor version", which switches between the two.
- Changes they made inside LimeSurvey's own theme files are gone. Their own uploaded themes are kept.
- Times are recorded in UTC from now on. Answers from before the upgrade keep the times they had. LimeSurvey shows times in the time zone set in Global settings, or in each account's own.
- In a ranking question, a gap in someone's ranking was closed up (rank 3 became rank 2).

### 5. The kept backup

The upgrade keeps the old code and the database dump on the volume, about 600 MB. It is the only way back to the old version. Ask the admin to look at their surveys and a few answers first.

Gate: the admin has checked the upgraded site. Say that the folder is the only way back to the old version, and wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/upgrade-state.sh --remove-kept-backup <upgrade folder> --yes
```

The folder's name is in upgrade-state.sh's output. Without `--yes` nothing is removed.

## Verify

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

## Tell the user

Say which version the site runs now, which plugins or themes are off and why, and whether the upgrade's backup is still kept.
