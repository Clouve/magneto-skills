# Learnings

Living scratchpad for WordPress-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

## What does NOT go here

- Secrets. Ever. (Including the literal value of `CLOUVE_OPS_PASSWORD`, the AI Assistant's access key (`MAGNETO_AGENT_LLM_KEY`), or any DB password.)

The rest of what stays out is in [SKILL.md → What does NOT qualify](SKILL.md#what-does-not-qualify).

---

## 2026-11-02 — Correction: the channel docs match the images

Both Clouve-packaged images ship the `clouve-ops` sshd, as the 2026-08-05 check recorded (now in [reference/shell-access.md](reference/shell-access.md)). The playbooks and reference files now lead with the shell on Shape A and keep the TCP/HTTP paths for Shape B and failed probes; [reference/shell-access.md](reference/shell-access.md) has the details and the failure modes.

---

## Pruning rule

When a learning is now covered by a dedicated reference file or playbook, delete its entry here — git history retains the original capture. This file should not grow beyond a screenful.
