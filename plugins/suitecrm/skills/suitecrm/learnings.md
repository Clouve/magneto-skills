# Learnings

A scratchpad for SuiteCRM facts that real sessions captured and that don't yet justify a file of their own under `reference/` or `playbooks/`. [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) says what qualifies and how to write an entry.

## Format

Each entry has an ISO-8601 date, stays short and starts with the fact. If an entry grows past about 10 lines, promote it to its own file and leave a one-line pointer here.

## What does NOT go here

- Secrets. Ever. (Including the literal value of `CLOUVE_OPS_PASSWORD`, the AI Assistant's access key (`MAGNETO_AGENT_LLM_KEY`), the database and admin passwords, an SMTP password, or an OAuth2 client secret.)
- Customer data. No names, companies, amounts, email addresses or anything else from a record.

The rest of what stays out is in [SKILL.md → What does NOT qualify](SKILL.md#what-does-not-qualify).

---

## Pruning rule

When a reference file or a playbook now covers a learning, delete its entry here. Git history keeps the original capture. This file should not grow beyond a screenful.
