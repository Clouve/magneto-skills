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
│   │   ├── install.sh            # optional runtime install hook (apt deps)
│   │   └── skills/
│   │       └── gibbon/
│   │           ├── SKILL.md      # Anthropic-style skill entry point
│   │           ├── learnings.md
│   │           ├── playbooks/
│   │           ├── reference/
│   │           └── scripts/
│   └── moodle/
│       └── …                     # same shape as gibbon (also ships install.sh)
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

Each plugin currently ships a single skill at `plugins/<name>/skills/<name>/`. Multi-skill plugins are supported by the spec but not used here.

## Magneto Agent

The same skill content is consumed by Clouve's [Magneto Agent](https://github.com/Clouve/magneto-agent) container at runtime. Magneto Agent's marketplace loader treats this repo as one Claude Code plugin marketplace among possibly many — set on the `MAGNETO_AGENT_SKILLS` env var as a comma-separated list of marketplace repository URLs, each optionally narrowed with `?plugins=<n1>,<n2>` and pinned with `#<branch>`:

```yaml
# All plugins from this marketplace, default branch
MAGNETO_AGENT_SKILLS: https://github.com/Clouve/magneto-skills.git

# Subset filter
MAGNETO_AGENT_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=gibbon,moodle

# Pinned branch
MAGNETO_AGENT_SKILLS: https://github.com/Clouve/magneto-skills.git?plugins=gibbon#release/2026-q2
```

See the [Magneto Agent README](https://github.com/Clouve/magneto-agent/blob/main/README.md#ai-skills) for the full URL syntax, private-marketplace credentials (`MAGNETO_AGENT_SKILLS_GIT_TOKEN[__<HOST>]`), and error semantics.

## See also

- [Claude Code plugin marketplace docs](https://code.claude.com/docs/en/plugin-marketplaces)
- [`CHANGELOG.md`](CHANGELOG.md)
