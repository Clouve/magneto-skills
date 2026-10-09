# magneto-skills

Clouve's AI Assistant skills: Anthropic-style `SKILL.md` bundles packaged as a [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces). Clouve's AI Assistant runs Claude Code inside the [Magneto Agent](https://github.com/Clouve/magneto-agent) container and loads these skills from here. Any other tool that reads a `SKILL.md` tree can use them too.

Each skill is its own plugin under `plugins/<plugin-name>/`. The skill payload (`SKILL.md` + `playbooks/` + `reference/` + `scripts/`) is plain Markdown and shell, so only the loading mechanism depends on the consumer.

## How the skills load

| Consumer | How it loads these skills |
| --- | --- |
| **Claude Code** | Native plugin marketplace (`/plugin marketplace add` + `/plugin install`). Skills auto-load from `~/.claude/skills/<skill-name>/`. |
| **Magneto Agent** | Clouve's AI Assistant container. At start it clones the marketplaces named in `MAGNETO_AGENT_SKILLS`, stages each selected plugin under `/clouve/skills/<plugin>/`, runs the plugin's optional `install.sh`, and links its skills into `~/.claude/skills/`. See [Magneto Agent](#magneto-agent) below. |
| **Other** | Anything that can read a `SKILL.md` tree at a known path can consume these directly: clone the repo (or a single plugin's directory) and point the tool at `plugins/<plugin-name>/skills/<plugin-name>/`. |

## Install via Claude Code

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
| `ai-studio` | DevOps | 0.2.1 | Operate the Clouve AI Studio workspace — an Ubuntu 26.04 LTS server pre-seeded with a running MERN starter — install software, write code, run supervised services, debug, and verify. |
| `gibbon` | DevOps | 0.1.1 | Safely operate a Gibbon (gibbonedu) school-management install — upgrades, module installs, backups/restores, year rollover, hardening, diagnosing 500s. |
| `mern` | DevOps | 0.2.0 | Build, run, and operate MERN-stack apps (MongoDB, Express, React, Node) on a Debian/Ubuntu Linux system. |
| `moodle` | DevOps | 0.1.2 | Safely operate a Moodle 5.2.x LMS install — upgrades, plugin installs, cron, MUC purge, backups/restores, maintenance mode, hardening, diagnosing 500s. |
| `odoo` | DevOps | 0.1.1 | Safely operate an Odoo 19.0 ERP install — module installs/upgrades, filestore-aware backups/restores, prod→staging neutralization, database-manager hardening, diagnosing module failures. |
| `wordpress` | DevOps | 0.1.2 | Safely operate a WordPress site deployed on Clouve — backups/restores, plugin and theme management, core updates, site URL changes, wp-cron, hardening, diagnosing WSODs/500s. |

## On-disk layout

```
magneto-skills/
├── .claude-plugin/
│   └── marketplace.json          # marketplace catalog (every plugin listed here)
├── plugins/
│   ├── ai-studio/
│   │   └── …                     # same shape as gibbon (also ships install.sh)
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
│   ├── mern/
│   │   └── …                     # same shape as gibbon, but no install.sh
│   └── moodle/
│       └── …                     # same shape as gibbon (also ships install.sh)
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

Each plugin currently ships a single skill at `plugins/<name>/skills/<name>/`. Multi-skill plugins are supported by the spec but not used here.

## Magneto Agent

Clouve's [Magneto Agent](https://github.com/Clouve/magneto-agent) container is the AI Assistant runtime. It runs Claude Code and loads these skills at container start. Its marketplace loader treats this repo as one Claude Code plugin marketplace among possibly many, set on the `MAGNETO_AGENT_SKILLS` env var as a comma-separated list of marketplace repository URLs, each optionally narrowed with `?plugins=<n1>,<n2>` and pinned with `#<branch>`:

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
