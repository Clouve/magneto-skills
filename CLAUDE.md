# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Clouve's [Claude Code plugin marketplace](https://code.claude.com/docs/en/plugin-marketplaces). Each plugin is a single, self-contained Anthropic-style skill bundle. There is no build and no lint, and the only tests are the bash scripts in `tests/` and gibbon's `plugins/gibbon/skills/gibbon/scripts/tests/mysql-tls.test.sh`. The deliverables are a `marketplace.json` catalog, per-plugin `plugin.json` manifests, and `SKILL.md` payloads with their supporting files.

This repo was **split out of `Clouve/magneto`**, and the runtime container that consumes these skills (the **[Magneto Agent](https://github.com/Clouve/magneto-agent)**, formerly known as "AI Studio") was subsequently split out into its own repo too. Old links of the form `../../image/...` or `apps/ai-studio/image/installer/...` are cross-repo references — the agent's image source resolves in [Clouve/magneto-agent](https://github.com/Clouve/magneto-agent). Note: `apps/ai-studio/` in [Clouve/magneto](https://github.com/Clouve/magneto) is now a **different thing** — an Ubuntu sibling workspace, pre-seeded with a running MERN starter and supervised by supervisord, that pairs with the Magneto Agent at deploy time (one of several sibling apps, alongside `apps/moodle/`, `apps/gibbon/`, etc.). Don't conflate the two; the name overlap is historical.

The per-plugin persona templates (`CONTEXT.md.tpl`) that used to live alongside the skills here are managed in a different repo as of the marketplace migration — Magneto Agent pulls them from each app's sidecar at init via `sidecar-fetcher.sh`, into `/clouve/context/<plugin>/CONTEXT.md.tpl`. Don't re-introduce them in this tree.

## Layout

```
magneto-skills/
├── .claude-plugin/
│   └── marketplace.json          # catalog of every plugin
├── plugins/<plugin-name>/
│   ├── .claude-plugin/
│   │   └── plugin.json           # manifest: name, version, description, author
│   ├── install.sh                # OPTIONAL — runtime install hook (see below)
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

### Optional: per-plugin runtime install hook

A plugin that needs runtime apt packages, binaries, or other host-side state on the [Magneto Agent](https://github.com/Clouve/magneto-agent) container may ship an `install.sh` at the plugin root (`plugins/<plugin-name>/install.sh`). Magneto Agent's marketplace plugin-stager runs it after staging the payload, on every container start. `gibbon`, `moodle`, and `ai-studio` use this without bloating the upstream Magneto Agent image: `gibbon` and `moodle` pull in `default-mysql-client`, `openssh-client`, and `sshpass`; `ai-studio` pulls in only `openssh-client` and `sshpass` (no mysql-client). These are what the skills' scripts shell out to.

Contract:

- The hook runs as **root** with no arguments. CWD is the staged payload directory (`/clouve/skills/<plugin>/plugin/`).
- The hook **must be idempotent** — it is invoked on every container start, not only the first. Gate each step on `dpkg-query`, `command -v`, or a sentinel file in `/var/lib/clouve/`.
- Errors are **non-fatal** — a non-zero exit is logged but does not abort plugin activation or other plugins.
- Persistence: package state in `/usr` and `/var` survives pod restarts (those are persistent volumes); `/etc` edits only survive if Magneto Agent's SIGTERM trap fires on graceful shutdown.

The hook is the right home for runtime deps that are tied to *this skill's scripts and playbooks*. It is **not** a place for content edits to the skill itself, image rebuild logic, or anything that should live in the upstream Magneto Agent image. Generic Magneto Agent enhancements belong in [Clouve/magneto-agent](https://github.com/Clouve/magneto-agent) (the standalone image source); each sibling app's image source (Dockerfile, installer scripts, persona) lives under its own directory in [Clouve/magneto](https://github.com/Clouve/magneto) — for example, the AI Studio sibling at `apps/ai-studio/`.

The full hook contract lives in the plugin-stager source at [image/installer/chat/marketplace/plugin-stager.sh](https://github.com/Clouve/magneto-agent/blob/main/image/installer/chat/marketplace/plugin-stager.sh).

## Secrets contract

### Where the secrets are

On a current Magneto Agent, deployment secrets are not environment variables. The agent keeps them in `/run/clouve/secrets.env` (root, mode 0600, rebuilt at every start), and `/usr/local/bin/clv-secret` reads that file for the assistant. `clv-secret` has three forms:

```sh
clv-secret NAME         # prints the value, with no newline
clv-secret --list       # prints the names, one per line, never a value
clv-secret --has NAME   # prints nothing; exits 0 if NAME is there, 1 if not
```

While the agent is still fetching its apps' settings, `--list` and a lookup of a missing name wait, and say so on stderr ("clv-secret: waiting for the agent to finish connecting to its apps..."). A name still missing after the fetch exits 2 with "clv-secret: NAME is not set on this server". Skills never run `clv-secret NAME` on its own, never print a value, and never open the file.

An older agent has the secrets in its environment and no `clv-secret`. Skills reach every agent from git at its start, so each use of a secret has to work on both kinds.

### In markdown

An agent-side secret in a command is written `${NAME:-$(clv-secret NAME)}`:

```sh
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh clouve-ops@${MOODLE_HOST}
```

Both halves are needed. An older agent has `NAME`, so bash never runs the `clv-secret` half. A current agent doesn't have it, so bash does. Without the second half the command gets an empty password on a current agent, and without the first it fails on an older one. Where the text only names a variable and isn't a command, write the bare name in backticks: `CLOUVE_OPS_PASSWORD`.

### In scripts

A script that uses an agent-side secret loads it once, on a line of its own above its first other use:

```sh
: "${NAME:=$(clv-secret NAME)}"
```

The `:` keeps it safe under `set -e`. A plain `NAME=$(clv-secret NAME)` ends the script when `clv-secret` exits non-zero, and this line doesn't. `:=` only assigns when `NAME` is unset or empty, so an older agent that has `NAME` never runs `clv-secret`. The line has no `2>/dev/null`, because `clv-secret`'s own messages (the wait, "not set on this server", a sudo failure) have to reach whoever ran the script. A script that runs on the sibling, piped over SSH, reads the sibling's own variables and gets no loader line.

### Which names

A name is a secret when one of its `_`-separated words is PASSWORD, PASSWORDS, PASSWD, PASS, PWD, SECRET, SECRETS, KEY, KEYS, TOKEN, TOKENS, CREDENTIAL, CREDENTIALS, PRIVATE or AUTH. `MAGNETO_AGENT_LLM_KEY`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` are the exceptions. The agent-side ones start with `CLOUVE_OPS_`, `GIBBON_`, `MOODLE_`, `NEXTCLOUD_`, `ODOO_`, `WORDPRESS_` or `AI_STUDIO_`. A name without one of those prefixes (`DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `MYSQL_PWD`) is a sibling's own, or a script's local copy, and stays as written.

The SKILL.md of a plugin that uses secrets says in its environment section that passwords aren't in the environment, shows the form above, and names `clv-secret --list`. A step that lists names with `compgen -e | grep` gets a `clv-secret --list | grep` line for the passwords.

### The test

`tests/skills-env-values.test.sh` enforces these rules for the skills. It fails on:

- `printenv` of a secret name;
- a `$NAME` or `${NAME...}` of an agent-side secret, in markdown or a script comment, that isn't exactly the markdown form;
- a script that uses an agent-side secret above its loader line, or whose loader line differs from the script form;
- a line that calls an agent-side secret "already in your" environment, and a script line that sends the reader to `compgen` for one;
- a SKILL.md that never says `clv-secret --list`, in a plugin that uses `clv-secret`, and a `learnings.md` without the "Secrets. Ever." line.

It also runs both forms against a stand-in agent with `clv-secret` and one without it, with the variable set and not set. Run it with `bash tests/skills-env-values.test.sh`, and keep its name rule in step with `_clv_is_secret_name` in magneto-agent's [secrets-lib.sh](https://github.com/Clouve/magneto-agent/blob/main/image/installer/secrets/secrets-lib.sh).

## SKILL.md frontmatter

Required fields: `name`, `description`. DevOps skills additionally carry `type`, `version`, and `authoredAgainst` (pinned upstream version).

`description` is what triggers the skill — write it as a precise "use when … do not use for …" so it doesn't fire on unrelated PHP/MySQL questions. The same description should appear in `marketplace.json` and `plugin.json` for that plugin; keep them in sync when one changes.

## Runtime persistence — why the "captured to skill learnings" echo matters

When tenants run these skills inside a Magneto Agent container, the skill mount path (`/clouve/skills/`) is **not** in the persistent path set (`/usr`, `/var`, `/opt`, `/home`). The marketplace loader rebuilds it on every container start by re-cloning the marketplaces in `MAGNETO_AGENT_SKILLS`. Edits a tenant Claude makes at runtime survive the rest of the session but are wiped on pod restart, and they do **not** propagate back to this repo on their own.

The mechanism every DevOps skill uses to bridge that gap: when a runtime session captures a learning, it surfaces a one-line summary in chat:

> _Captured to skill learnings: `<file>` — `<one-line summary>`_

The operator (you, when working in this repo) is expected to mirror those captured learnings into the matching files here so the next image rebuild bakes them in for every tenant. **When a user pastes one of those echoes into a session in this repo, the task is: find the right file under `plugins/<plugin-name>/skills/<plugin-name>/` and apply the learning following that skill's own dedup/edit rules** (documented in the skill's `SKILL.md` "Maintaining this skill" section and `learnings.md`).

## Authoring conventions

- **Prefer the right file over the catch-all.** `learnings.md` is for cross-cutting / too-small / speculative facts. Reference facts go in `reference/*.md`. Verified procedures go in `playbooks/*.md`. Audited automation goes in `scripts/`.
- **De-duplicate before appending.** Grep the target file (and `learnings.md`) for the topic first; extend related entries instead of creating parallel ones.
- **Keep entries terse and dated.** ISO-8601 (`YYYY-MM-DD`); promote anything past ~10 lines to its own file with a one-line pointer left behind.
- **Don't bake secrets, tenant-identifying data, or `/_clv/`-related content into any skill.** The `/_clv/` namespace is platform-managed and explicitly outside skill scope.
- **Cross-repo references stay as URLs**, not relative paths. Files like `image/installer/chat/skills.sh` live in [Clouve/magneto-agent](https://github.com/Clouve/magneto-agent), not here.

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
