# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Canonical source for **AI Studio skill content** consumed by [Clouve/magneto](https://github.com/Clouve/magneto)'s `apps/ai-studio` container. There is no build, no test suite, no lint — the deliverables are markdown templates and a few audited shell scripts that get sparse-cloned (or baked) into running tenant pods at boot.

Skills live elsewhere by ID `<Category>/<Name>` (e.g. `DevOps/Gibbon`, `Web_Development/Next.js`). Categories are CamelCase or `Snake_Case`; names match `[A-Za-z0-9_.-]+`. The loader enforces a strict regex on both segments to block path traversal — keep new directory names in that grammar.

This repo was **split out of `Clouve/magneto`**. Old links of the form `../../image/...` or `apps/ai-studio/...` are now cross-repo references — they point into [Clouve/magneto](https://github.com/Clouve/magneto), not into this tree. Don't try to resolve them locally.

## The two file roles (load-bearing — read before authoring)

Every skill has up to two distinct rendering targets. Confusing them produces broken output:

### 1. `<Category>/<Name>/CONTEXT.md.tpl` — persona section (required)

Appended under a `## Skill: <Category> / <Name>` header to the agent's main context file (`~/.claude/CLAUDE.md`, `~/.gemini/GEMINI.md`, or `~/.codex/AGENTS.md`) at login. Authoring rules:

- **No leading `# H1`.** The renderer emits the H2 skill heading itself. Start with prose.
- **Use `### H3`** for subsections — the in-file hierarchy is H2 (skill) → H3 (subsections).
- **`${VAR}` syntax** is interpolated by `envsubst` at login. Always-available: `${AI_STUDIO_HOST}`, `${USERNAME}`, `${ROOT_PASSWORD}`. Per-app vars (`${GIBBON_HOST}`, `${MOODLE_DB_HOST}`, `${CLOUVE_OPS_PASSWORD}`, etc.) come from the deployment — confirm with `env | grep -i <app>` rather than hard-coding.

### 2. `<Category>/<Name>/skill/` — Anthropic-style payload (optional)

A full Claude Code skill package mounted at `~/.claude/skills/<slug>/` where Claude Code's native skill loader picks it up. Standard layout:

```
skill/
├── SKILL.md                # entry point — YAML frontmatter required
├── learnings.md            # session-captured facts; format protocol inside
├── playbooks/*.md          # verified procedures
├── reference/*.md          # narrow, lazily-loaded fact sheets
└── scripts/*.sh            # audited automation
```

`SKILL.md` frontmatter must include `name`, `description`, `type`, `version`, and (for DevOps skills) `authoredAgainst` pinning the upstream version. The `description` field is what triggers the skill — write it as a precise "use when … do not use for …" so it doesn't fire on unrelated PHP/MySQL questions.

Symlinks also land at `~/.gemini/skills/<slug>/` and `~/.codex/skills/<slug>/` for symmetry. Those clients don't auto-load skills today, but the path is stable for cross-references.

## `skills/CONTEXT.md.tpl` (root template)

The platform-wide skeleton — `/_clv/` namespace protection, persistent paths (`/usr`, `/var`, `/opt`, `/home`), the single-port-80 nginx-routing constraint, the `clouve-ops` SSH model. **Always staged**, regardless of `AI_STUDIO_SKILLS`. Edits here affect every container in every tenant pod — change with care, and never weaken the `/_clv/` guardrails.

## Activation and slugs

```yaml
environment:
  AI_STUDIO_SKILLS: DevOps/Gibbon,DevOps/Moodle
```

Slug = lowercase ID with `/` → `-`. So `DevOps/Gibbon` → `devops-gibbon`, mounted at `/clouve/skills/devops-gibbon/`. Order in `AI_STUDIO_SKILLS` is the order skill sections appear in the rendered context file.

## Runtime persistence — why the "captured to skill learnings" echo matters

The skill mount path `/clouve/skills/<slug>/` is **not in the persistent path set** (`/usr`, `/var`, `/opt`, `/home`). Edits a tenant Claude makes at runtime survive the rest of the session but are wiped on pod restart, and they do **not** propagate back to this repo on their own.

The mechanism every DevOps skill uses to bridge that gap: when a runtime session captures a learning, it surfaces a one-line summary in chat:

> _Captured to skill learnings: `<file>` — `<one-line summary>`_

The operator (you, when working in this repo) is expected to mirror those captured learnings into the matching files here so the next image rebuild bakes them in for every tenant. **When a user pastes one of those echoes into a session in this repo, the task is: find the right file under `<Category>/<Name>/skill/` and apply the learning following that skill's own dedup/edit rules** (documented in the skill's `SKILL.md` "Maintaining this skill" section and `learnings.md`).

## Authoring conventions

- **Prefer the right file over the catch-all.** `learnings.md` is for cross-cutting / too-small / speculative facts. Reference facts go in `reference/*.md`. Verified procedures go in `playbooks/*.md`. Audited automation goes in `scripts/`.
- **De-duplicate before appending.** Grep the target file (and `learnings.md`) for the topic first; extend related entries instead of creating parallel ones.
- **Keep entries terse and dated.** ISO-8601 (`YYYY-MM-DD`); promote anything past ~10 lines to its own file with a one-line pointer left behind.
- **Don't bake secrets, tenant-identifying data, or `/_clv/`-related content into any skill.** The `/_clv/` namespace is platform-managed and explicitly outside skill scope.
- **Cross-repo references stay as URLs**, not relative paths. Files like `apps/ai-studio/image/installer/chat/skills.sh` live in [Clouve/magneto](https://github.com/Clouve/magneto), not here.

## Loader behavior worth knowing

The loader resolves each asset in this order (documented in [README.md](README.md)):

1. **Git fetch** — if `AI_STUDIO_SKILLS_REPO` is set, sparse `git clone` pulls just the needed paths into `/var/lib/clouve/skills-fetch/`.
2. **Baked fallback** — `/clouve/skills-bundled/`, populated from this directory at image-build time.

A failed git fetch falls through to the baked copy with a warning. Missing/invalid skills are logged and skipped — container init never aborts on a skill-loading error. Implication for authors: a syntax error in `CONTEXT.md.tpl` (e.g., an unbalanced `${VAR}` block that breaks `envsubst`) won't crash the pod, but it will silently disable the skill section. Test new templates against `envsubst` locally before relying on them.
