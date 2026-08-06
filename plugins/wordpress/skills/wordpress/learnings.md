# Learnings

Living scratchpad for WordPress-specific facts captured during real sessions that don't yet justify their own file under `reference/` or `playbooks/`. See [SKILL.md → Maintaining this skill](SKILL.md#maintaining-this-skill) for the protocol on what qualifies and how to write entries.

## Format

Each entry: dated (ISO-8601), terse, leads with the fact. If an entry grows past ~10 lines, promote it to a dedicated file and leave a one-line pointer.

---

## 2026-08-05 — Channel reality: the Clouve-packaged shape now SHIPS clouve-ops sshd

Supersedes the earlier no-shell entry from the same date. As of the magneto `develop` wordpress agent-enablement change (2026-08-05, the change that added `x-clouve-agent` to `apps/wordpress`), BOTH packaged sibling images (`wordpress`, `wordpress-mariadb`) ship openssh-server + the `clouve-ops` account with passwordless sudo, moodle-pattern; sshd starts only when `CLOUVE_OPS_PASSWORD` is set, i.e. on agent-enabled deployments — agent-off deployments of the same images run shell-less by design. On that shape the [reference/shell-access.md](reference/shell-access.md) probe is EXPECTED GREEN and wp-cli lights up. Verified live on a Kubernetes deployment 2026-08-05: SSH probe GREEN to both siblings, `sudo -u www-data wp --path=/var/www/html core version` → 6.9 over SSH (prefer that invocation over `--allow-root`; chown after if root was unavoidable), and `scripts/verify-health.sh` GREEN end-to-end. The packaged DB image is now pinned `mariadb:12.3` (12.3.2 at pin time) — Shape A's "engine floats per pull" caveat no longer applies. Vanilla developer-submitted composes (Shape B) remain shell-less — probe-first still applies everywhere.

---

## Pruning rule

When a learning is now covered by a dedicated reference file or playbook, delete its entry here — git history retains the original capture. This file should not grow beyond a screenful.
