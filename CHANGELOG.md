# Changelog

## Unreleased

- **gibbon**, **moodle**: added per-plugin `install.sh` runtime install hooks at `plugins/<name>/install.sh`. [Magneto Agent](https://github.com/Clouve/magneto-agent)'s marketplace plugin-stager runs each one after staging the plugin payload to apt-install the binaries the skill's scripts shell out to (`default-mysql-client`, `openssh-client`, `sshpass`). Replaces the previous per-app `apps/<name>/image/ai-studio/` Dockerfile layers in [Clouve/magneto](https://github.com/Clouve/magneto), so both apps now consume the upstream Magneto Agent image directly with no per-app image layer.
- Documented the per-plugin install hook convention in `CLAUDE.md`.
- Updated `README.md` and `CLAUDE.md` for the upstream platform changes: the AI Studio image source moved out of `Clouve/magneto` (`apps/ai-studio/image/`) into the standalone [`Clouve/magneto-agent`](https://github.com/Clouve/magneto-agent) repo and was renamed **Magneto Agent**. The activation env var was renamed `AI_STUDIO_SKILLS` → `MAGNETO_AGENT_SKILLS` and now takes Claude Code marketplace URLs (with optional `?plugins=` filter and `#branch` ref) rather than `<Category>/<Name>` plugin slugs against this repo's tree.

## 1.0.0 — 2026-05-03

- Restructured repository as a Claude Code plugin marketplace.
- Skills previously at `<Category>/<SkillName>/skill/` are now at `plugins/<plugin-name>/skills/<plugin-name>/`.
- Added `.claude-plugin/marketplace.json` and per-plugin `.claude-plugin/plugin.json` manifests.
- Removed all `CONTEXT.md.tpl` files (root and per-skill); AI Studio persona templates are now managed in a separate repo.
- Dropped `Web_Development/MERN` and `Web_Development/Next.js`: they only contained `CONTEXT.md.tpl` (no `SKILL.md`), so nothing remained after the persona templates moved out. Add them back as plugins when they have a `SKILL.md`.
- **Breaking change** for any consumer that referenced the old `<Category>/<SkillName>/` paths directly.
