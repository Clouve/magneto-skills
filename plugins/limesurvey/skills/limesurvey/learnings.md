# Learnings

The scratchpad for LimeSurvey facts captured in real sessions that don't yet justify a file of their own under `reference/` or `playbooks/`. [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) says what qualifies and how to write an entry.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past about 10 lines, promote it to a file of its own and leave a one-line pointer.

## What does NOT go here

- Secrets. Ever. (Including the literal value of `CLOUVE_OPS_PASSWORD`, the AI Assistant's access key (`MAGNETO_AGENT_LLM_KEY`), the database and admin passwords, an SMTP password, or a participant's access code.)
- Anything from a survey's answers or its participant list.

The rest of what stays out is in [SKILL.md → What does NOT qualify](SKILL.md#what-does-not-qualify).

---

## Pruning rule

When a reference file or a playbook now covers a learning, delete its entry here. Git history keeps the original capture. This file should not grow beyond a screenful.
