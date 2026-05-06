# Changelog

## Unreleased

- **gibbon**: added `plugins/gibbon/install.sh` runtime install hook. AI Studio's marketplace plugin-stager runs this after staging the plugin payload to apt-install the binaries the skill's scripts shell out to (`default-mysql-client`, `openssh-client`, `sshpass`). Replaces the previous `apps/gibbon/image/ai-studio/` Dockerfile layer in [Clouve/magneto](https://github.com/Clouve/magneto), so the Gibbon app now consumes the upstream `ai-studio` image directly with no per-app image layer.
- Documented the per-plugin install hook convention in `CLAUDE.md`.

## 1.0.0 — 2026-05-03

- Restructured repository as a Claude Code plugin marketplace.
- Skills previously at `<Category>/<SkillName>/skill/` are now at `plugins/<plugin-name>/skills/<plugin-name>/`.
- Added `.claude-plugin/marketplace.json` and per-plugin `.claude-plugin/plugin.json` manifests.
- Removed all `CONTEXT.md.tpl` files (root and per-skill); AI Studio persona templates are now managed in a separate repo.
- Dropped `Web_Development/MERN` and `Web_Development/Next.js`: they only contained `CONTEXT.md.tpl` (no `SKILL.md`), so nothing remained after the persona templates moved out. Add them back as plugins when they have a `SKILL.md`.
- **Breaking change** for any consumer that referenced the old `<Category>/<SkillName>/` paths directly.
