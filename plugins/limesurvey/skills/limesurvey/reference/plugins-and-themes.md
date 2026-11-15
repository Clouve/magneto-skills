# Plugins and themes

## Where they live

| | Comes with LimeSurvey | Added by the admin |
|---|---|---|
| Plugins | `application/core/plugins/<Name>/` (type core) | `upload/plugins/<Name>/` (type upload: a zip uploaded in the plugin manager) or `plugins/<Name>/` (type user: a folder put there by hand) |
| Survey themes | `themes/survey/` (vanilla, fruity, bootswatch, fruity_twentythree) | `upload/themes/survey/<name>/` |

`upload/` is its own volume, and the image's upgrade keeps the folders under `plugins/` that it does not ship itself. So added plugins and themes survive an image change. Changes the admin made inside LimeSurvey's own theme files don't: an upgrade replaces those files.

A plugin is a folder `<Name>` with `<Name>.php` and `config.xml`. A theme is a folder with a `config.xml` that names it.

```bash
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh plugins
/clouve/skills/limesurvey/plugin/skills/limesurvey/scripts/extensions.sh themes
```

## The compatibility rule

A plugin's or theme's `config.xml` lists the LimeSurvey versions it supports:

```text
<compatibility>
    <version>6.0</version>
    <version>7.0</version>
</compatibility>
```

LimeSurvey looks for an entry whose first digit is the installed major version. An extension that lists only `6.0` is not compatible with LimeSurvey 7, and one with no `<compatibility>` section is compatible with nothing. LimeSurvey applies the rule when a plugin is switched on and when a theme is installed. `extensions.sh plugin-activate` and `theme-register` apply the same rule and refuse the same extensions.

Don't work around it. Editing a plugin's `config.xml` so that it claims LimeSurvey 7, or switching a plugin on with SQL, loads code that was never tried on this version, with every answer in its reach. The fix is a new version from the plugin's author.

## Switching a plugin on

`extensions.sh plugin-activate <Name>` does what the plugin manager's "Activate" does: it registers a new plugin folder, checks compatibility, runs the plugin's own activation step (which can make tables), and switches it on. A plugin can refuse its own activation, and the script then reports its reason.

A plugin runs as PHP inside LimeSurvey. It can read and change everything LimeSurvey can. So switching one on needs a named source, a backup first, and the admin's yes.

## When a plugin breaks the site

When a plugin throws an error while it loads, LimeSurvey marks it as broken (a load error), stops loading it, and emails the site admin. `extensions.sh plugins` shows the mark and its message. The mark stays until someone clears it in the plugin manager, after the plugin is fixed. `extensions.sh plugin-deactivate <Name>` switches a plugin off when pages break right after it was switched on.

## What an upgrade does

LimeSurvey's database update switches every added plugin off, compatible or not. Core plugins stay as they were. The image records which plugins were on before, and `extensions.sh plugins-off-after-upgrade` shows that list with what can be switched on again ([playbooks/after-an-upgrade.md](../playbooks/after-an-upgrade.md)).

For themes, an added theme that lists LimeSurvey 6 or 7 stays registered and assigned to its surveys. One that lists only version 5 or older is uninstalled.

## Themes and the new editor

LimeSurvey 7's new survey editor works with themes that build on `fruity_twentythree`, which is also the default theme. An older theme still shows surveys to participants. The admin picks a survey's theme in its settings.

## Clouve's own plugin

The image ships one plugin of Clouve's in `plugins/`: `SuiteCRMIntegration`, for the Customer Kit, where LimeSurvey runs next to SuiteCRM ([customer-kit.md](customer-kit.md)). On a LimeSurvey on its own it is there, off, and has nothing to connect to. Leave it off, and don't offer it when you list the plugins that are off.

## Core plugins worth knowing

| Plugin | What it does |
|---|---|
| Authdb | Password sign-in. Leave it on. |
| PasswordRequirement | The rules for passwords people set |
| ReactEditor | The new survey editor. It can't be switched off. |
| UpdateCheck, ComfortUpdateChecker | Look for updates. The image's version comes from Clouve, so ignore their notices. |
| TwoFactorAdminLogin | Two-step sign-in, off by default |
| ExportR, ExportSTATAxml, ExportSPSSsav | More export formats in LimeSurvey's own export page |

Tested on 7.10.0.
