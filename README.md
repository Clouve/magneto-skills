# magneto-skills

Clouve's AI client skills, packaged as a [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces).

Each skill is its own plugin under `plugins/<plugin-name>/`. Install the marketplace once, then install the plugins you want.

## Install (Claude Code)

```
/plugin marketplace add Clouve/magneto-skills
/plugin install <plugin-name>@clouve
```

For example, to install the Gibbon skill:

```
/plugin marketplace add Clouve/magneto-skills
/plugin install gibbon@clouve
```

## Plugins

| Plugin | Category | Version | Description |
| --- | --- | --- | --- |
| `gibbon` | DevOps | 0.1.0 | Safely operate a Gibbon (gibbonedu) school-management install — upgrades, module installs, backups/restores, year rollover, hardening, diagnosing 500s. |
| `moodle` | DevOps | 0.1.0 | Safely operate a Moodle 5.2.x LMS install — upgrades, plugin installs, cron, MUC purge, backups/restores, maintenance mode, hardening, diagnosing 500s. |

## On-disk layout

```
magneto-skills/
├── .claude-plugin/
│   └── marketplace.json          # marketplace catalog (every plugin listed here)
├── plugins/
│   ├── gibbon/
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json       # plugin manifest
│   │   └── skills/
│   │       └── gibbon/
│   │           ├── SKILL.md      # Anthropic-style skill entry point
│   │           ├── learnings.md
│   │           ├── playbooks/
│   │           ├── reference/
│   │           └── scripts/
│   └── moodle/
│       └── …                     # same shape as gibbon
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

Each plugin currently ships a single skill at `plugins/<name>/skills/<name>/`. Multi-skill plugins are supported by the spec but not used here.

## AI Studio

The same skill content is consumed by Clouve's AI Studio container via the `AI_STUDIO_SKILLS` env var. The loader resolves plugin slugs (e.g. `gibbon`, `moodle`) against this repo's `plugins/` tree.

## See also

- [Claude Code plugin marketplace docs](https://code.claude.com/docs/en/plugin-marketplaces)
- [`CHANGELOG.md`](CHANGELOG.md)
