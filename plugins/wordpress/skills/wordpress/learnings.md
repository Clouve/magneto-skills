# Learnings

Living scratchpad for WordPress-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

---

## 2026-08-05 — Channel reality at authoring time: no shell into WordPress siblings

Neither the Clouve-packaged WordPress image nor vanilla `wordpress:<ver>-apache` ships sshd or the `clouve-ops` operator account (unlike the moodle/gibbon images). At authoring time the only live channels from the Magneto Agent container are TCP `mysql` to the DB sibling and HTTP `curl` to the WordPress sibling — everything filesystem-side (wp-config edits, plugin file surgery, `.maintenance` removal, wp-cli) is documented as conditional on a shell existing. Playbooks probe first ([reference/shell-access.md](reference/shell-access.md)) and each step is labeled with its channel. If the magneto WordPress images later add `clouve-ops` sshd, the probes light up and no skill change is needed — but re-verify the wp-cli invocation user (image runs as root; `--allow-root` leaves root-owned files outside `wp-content/uploads`).

---

## Pruning rule

When a learning is now covered by a dedicated reference file or playbook, delete its entry here — git history retains the original capture. This file should not grow beyond a screenful.
