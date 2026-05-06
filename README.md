# magneto-skills

Clouve's AI client skills — Anthropic-style `SKILL.md` bundles packaged as a [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces) and designed to be consumed by **Claude Code**, **Gemini CLI**, **OpenAI Codex CLI**, or any other AI client that can read a `SKILL.md` tree.

Each skill is its own plugin under `plugins/<plugin-name>/`. The marketplace format is the Claude Code spec, but the underlying skill payload (`SKILL.md` + `playbooks/` + `reference/` + `scripts/`) is client-agnostic — only the loading mechanism differs per client.

## Supported clients

| Client | How it loads these skills |
| --- | --- |
| **Claude Code** | Native plugin marketplace (`/plugin marketplace add` + `/plugin install`). Skills auto-load from `~/.claude/skills/<skill-name>/`. |
| **Gemini CLI** | No built-in skills convention yet — skill content is surfaced to the agent via a `## Skill: <plugin>` section appended to the merged `~/.gemini/GEMINI.md` context file. |
| **OpenAI Codex CLI** | Same as Gemini — skill content reaches the agent through a `## Skill: <plugin>` section appended to `~/.codex/AGENTS.md`. |
| **Other** | Anything that can read a `SKILL.md` tree at a known path can consume these directly — clone the repo (or a single plugin's directory) and point the client at `plugins/<plugin-name>/skills/<plugin-name>/`. |

The two production consumers today are Claude Code's native plugin marketplace and Clouve's [Magneto Agent](https://github.com/Clouve/magneto-agent) runtime container (which orchestrates loading for all three CLIs above — see [Magneto Agent](#magneto-agent) below).

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

For Gemini CLI, OpenAI Codex CLI, or other clients, use the [Magneto Agent](#magneto-agent) runtime path below — that loader handles staging the skill payload and synthesizing the per-client context file.

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

Clouve's [Magneto Agent](https://github.com/Clouve/magneto-agent) container is the runtime that consumes these skills for all three supported AI clients (Claude Code, Gemini CLI, OpenAI Codex CLI) — a single marketplace, three loading paths, picked at session start by the user. Magneto Agent's marketplace loader treats this repo as one Claude Code plugin marketplace among possibly many — set on the `MAGNETO_AGENT_SKILLS` env var as a comma-separated list of marketplace repository URLs, each optionally narrowed with `?plugins=<n1>,<n2>` and pinned with `#<branch>`:

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
