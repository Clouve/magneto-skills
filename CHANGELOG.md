# Changelog

## 1.0.0 — 2026-05-03

- Restructured repository as a Claude Code plugin marketplace.
- Skills previously at `<Category>/<SkillName>/skill/` are now at `plugins/<plugin-name>/skills/<plugin-name>/`.
- Added `.claude-plugin/marketplace.json` and per-plugin `.claude-plugin/plugin.json` manifests.
- Removed all `CONTEXT.md.tpl` files (root and per-skill); AI Studio persona templates are now managed in a separate repo.
- Dropped `Web_Development/MERN` and `Web_Development/Next.js`: they only contained `CONTEXT.md.tpl` (no `SKILL.md`), so nothing remained after the persona templates moved out. Add them back as plugins when they have a `SKILL.md`.
- **Breaking change** for any consumer that referenced the old `<Category>/<SkillName>/` paths directly.
