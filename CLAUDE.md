# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Clouve's [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces). Each plugin is a single, self-contained Anthropic-style skill bundle. There is no build, no test suite, no lint — the deliverables are a `marketplace.json` catalog, per-plugin `plugin.json` manifests, and `SKILL.md` payloads with their supporting files.

This repo was **split out of `Clouve/magneto`**. Old links of the form `../../image/...` or `apps/ai-studio/...` are now cross-repo references — they point into [Clouve/magneto](https://github.com/Clouve/magneto), not into this tree. Don't try to resolve them locally.

The AI Studio persona templates (`CONTEXT.md.tpl`) that used to live alongside the skills here are managed in a different repo as of the marketplace migration. Don't re-introduce them.

## Layout

```
magneto-skills/
├── .claude-plugin/
│   └── marketplace.json          # catalog of every plugin
├── plugins/<plugin-name>/
│   ├── .claude-plugin/
│   │   └── plugin.json           # manifest: name, version, description, author
│   └── skills/<plugin-name>/
│       ├── SKILL.md              # entry point — YAML frontmatter required
│       ├── learnings.md
│       ├── playbooks/*.md
│       ├── reference/*.md
│       └── scripts/*.sh
├── CHANGELOG.md
└── README.md
```

Plugin names are lowercase kebab-case (`[a-z0-9-]+`). The plugin's directory name, `name` in `plugin.json`, and `name` in the `SKILL.md` frontmatter must all match. The `name` in `marketplace.json`'s entry must match the same value.

## SKILL.md frontmatter

Required fields: `name`, `description`. DevOps skills additionally carry `type`, `version`, and `authoredAgainst` (pinned upstream version).

`description` is what triggers the skill — write it as a precise "use when … do not use for …" so it doesn't fire on unrelated PHP/MySQL questions. The same description should appear in `marketplace.json` and `plugin.json` for that plugin; keep them in sync when one changes.

## Runtime persistence — why the "captured to skill learnings" echo matters

When tenants run these skills inside an AI Studio container, the skill mount path is **not** in the persistent path set (`/usr`, `/var`, `/opt`, `/home`). Edits a tenant Claude makes at runtime survive the rest of the session but are wiped on pod restart, and they do **not** propagate back to this repo on their own.

The mechanism every DevOps skill uses to bridge that gap: when a runtime session captures a learning, it surfaces a one-line summary in chat:

> _Captured to skill learnings: `<file>` — `<one-line summary>`_

The operator (you, when working in this repo) is expected to mirror those captured learnings into the matching files here so the next image rebuild bakes them in for every tenant. **When a user pastes one of those echoes into a session in this repo, the task is: find the right file under `plugins/<plugin-name>/skills/<plugin-name>/` and apply the learning following that skill's own dedup/edit rules** (documented in the skill's `SKILL.md` "Maintaining this skill" section and `learnings.md`).

## Authoring conventions

- **Prefer the right file over the catch-all.** `learnings.md` is for cross-cutting / too-small / speculative facts. Reference facts go in `reference/*.md`. Verified procedures go in `playbooks/*.md`. Audited automation goes in `scripts/`.
- **De-duplicate before appending.** Grep the target file (and `learnings.md`) for the topic first; extend related entries instead of creating parallel ones.
- **Keep entries terse and dated.** ISO-8601 (`YYYY-MM-DD`); promote anything past ~10 lines to its own file with a one-line pointer left behind.
- **Don't bake secrets, tenant-identifying data, or `/_clv/`-related content into any skill.** The `/_clv/` namespace is platform-managed and explicitly outside skill scope.
- **Cross-repo references stay as URLs**, not relative paths. Files like `apps/ai-studio/image/installer/chat/skills.sh` live in [Clouve/magneto](https://github.com/Clouve/magneto), not here.

## Adding a new plugin

1. Create `plugins/<plugin-name>/.claude-plugin/plugin.json` with `name`, `version`, `description`, `author`. Keep it minimal — only add `commands`, `hooks`, `mcpServers` if the plugin actually ships them.
2. Create `plugins/<plugin-name>/skills/<plugin-name>/SKILL.md` with frontmatter (`name` matching the plugin name, plus `description`). Add `playbooks/`, `reference/`, `scripts/` as needed.
3. Add a corresponding entry to `.claude-plugin/marketplace.json`. Keep the `plugins[]` array sorted alphabetically by `name`.
4. Validate (see below) before opening a PR.

## Validating

From the marketplace root:

```sh
claude plugin validate .
```

If `claude plugin validate` is unavailable, fall back to manual checks: every `source` path resolves, every `plugin.json` parses, every plugin directory contains at least one `SKILL.md`, and every plugin name in `marketplace.json` matches its directory and its `plugin.json`.
