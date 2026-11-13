# Install a theme or a plugin

A survey theme changes how surveys look. A plugin adds behaviour, and runs as code with LimeSurvey's rights: it can read every answer. The admin gets the theme or plugin and uploads it, and you register it with LimeSurvey's own compatibility check. Both steps need a backup and the admin's yes ([SKILL.md](../SKILL.md#safety-gates-enforce-these-in-every-flow)).

Script names in the text stand for the scripts in `/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/`. The commands to run are written out in full. A step that starts with "Gate:" waits for the admin's yes before its command runs.

## When to use

- "We have a theme with our logo and colours." "Please switch on this plugin." "Our plugin is off since the update."
- Not for LimeSurvey's own themes and core plugins: those are there already, and the admin picks a theme in a survey's settings.

## Before you start

1. Ask where the theme or plugin comes from. Don't install code from a source the admin can't name.
2. Back up ([back-up](back-up.md)).

   Gate: a backup locks the site while it runs: participants and admins see a maintenance page for that time. Say so, and wait for a yes.

   ```bash
   /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/run-in-limesurvey.sh backup.sh
   ```

## A theme

### 1. The admin uploads it

The simplest way is LimeSurvey's own page: Configuration, Themes, then the button "Upload & install", with the theme's zip file. LimeSurvey registers it itself, and you only check the result. When the admin has put the theme's folder into `upload/themes/survey/` another way, it still has to be registered.

### 2. See what is there

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh themes
```

A folder that is "not registered yet" is listed with whether its `config.xml` lists this LimeSurvey version.

### 3. Register it

Gate: say that this makes the uploaded theme available to every survey. The admin knows where it came from; a backup exists; wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh theme-register '<theme name>'
```

The script refuses a theme whose `config.xml` does not name it, does not list LimeSurvey 7 under `<compatibility>`, or builds on a theme that is not installed. A theme made for LimeSurvey 5 or older needs a new version from its author. LimeSurvey's new editor works with themes that build on `fruity_twentythree`.

### 4. Use it

The admin picks the theme in the survey's settings (Presentation). Or you set it for them.

Gate: say which survey gets which theme. On an active survey, the people who are answering it see the new look at once. Wait for a yes.

```bash
printf '%s' '{"iSurveyID": <survey id>, "aSurveyData": {"template": "<theme name>"}}' | /clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/rc.sh --yes --stdin set_survey_properties
```

## A plugin

### 1. The admin uploads it

In LimeSurvey: Configuration, Plugins, then the button "Upload & install", with the plugin's zip file. It lands in `upload/plugins/`.

### 2. See what is there

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugins
```

Each plugin is listed with its type (core, user, upload), whether it is on, and whether it is compatible with this LimeSurvey.

### 3. Switch it on

Gate: say that a plugin is code that runs with LimeSurvey's rights and can read every answer. The admin knows where it came from; a backup exists; wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugin-activate '<plugin name>'
```

The script does what LimeSurvey's plugin manager does: it checks that the plugin's `config.xml` lists LimeSurvey 7, runs the plugin's own activation step, and switches it on. A plugin that lists only older versions is refused. It needs a newer version from its author, and nothing here forces it.

### 4. If pages break afterwards

Gate: say that you switch the plugin off again, and what stops working with it. Wait for a yes.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugin-deactivate '<plugin name>'
```

## After an upgrade

A LimeSurvey upgrade switches every added plugin off. [after-an-upgrade](after-an-upgrade.md) lists them and switches the compatible ones back on.

## Verify

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/verify-health.sh
```

The plugins line must not report a load error, and the site has to answer.

## Tell the user

Say what is installed and switched on now. If something was refused, say why in plain words: "this plugin was written for LimeSurvey 6 and its author has to update it".
