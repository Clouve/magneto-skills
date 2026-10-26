# Learnings

Living scratchpad for Nextcloud-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

## What does NOT go here

- Secrets. Ever. (Including the literal value of `CLOUVE_OPS_PASSWORD`, the AI Assistant's access key (`MAGNETO_AGENT_LLM_KEY`), the database passwords, or any Nextcloud app password.)

The rest of what stays out is in [SKILL.md → What does NOT qualify](SKILL.md#what-does-not-qualify).

---

## Pruning rule

When a learning is now covered by a dedicated reference file or playbook, delete its entry here. Git history keeps the original capture. This file should not grow beyond a screenful.
