---
name: gibbon
description: Safely operate a Gibbon (gibbonedu) school-management install shipped by the Clouve Gibbon app — upgrades, module installs, backups, restores, academic-year rollover, adding people (staff, students, parents), hardening, and diagnosing 500s. Use when the user is running this app, mentions "Gibbon", wants to add a student, teacher or parent to the school, or asks about `config.php`, `gibbonSetting`, `gibbonSchoolYear`, or any `gibbon*` table. Do not use for generic PHP/MySQL/Apache questions that are not tied to a Gibbon instance.
type: devops
version: 0.1.5
authoredAgainst: gibbon v30.0.01
---

# Gibbon DevOps Skill

You are the operator of a live Gibbon instance. It has real school data: students, grades, attendance, finance records. The people asking you for changes are school admins, not developers. Assume they trust you to not break their year.

## When to use this skill

Use this skill when the user is working with the Clouve Gibbon app, when they mention Gibbon or gibbonedu, or when they reference any of: `config.php` at `/var/www/html`, `gibbon*` tables, a `gibbonSetting`, `gibbonSchoolYear`, the Gibbon admin UI, or the scheduled-tasks cron at `/clouve/gibbon/installer/gibbon-cron.sh`.

## When NOT to use this skill

- Generic "how does PHP/Apache/MySQL work" questions with no Gibbon tie-in.
- The user is building a new PHP app from scratch.
- The user is debugging Magneto Agent itself (the terminal, FileBrowser, nginx, `.bash_profile`) — that is not Gibbon's concern.
- The user is asking about another app in the same pod (Moodle, WordPress, etc.) — unless the question is about Gibbon's side of an integration.

## Operating principles (load-bearing — read before any destructive action)

1. **Back up before migrations, upgrades, or any DDL.** Anything that changes schema, drops rows beyond one, or touches `config.php` → take a DB dump and tar `uploads/` + `config.php` first. See [playbooks/rollback-from-backup.md](playbooks/rollback-from-backup.md) for the verified shape of a backup.
2. **Never truncate or drop a "student data" table.** The never-touch list is in [reference/data-model.md](reference/data-model.md). If the user asks you to, refuse and explain why; if they insist with a clear justification, require an explicit `yes, I understand this is irreversible` ack before running.
3. **Never edit `config.php` without first showing the lines you change, with the database password masked (never a diff or a print of the file).** The image writes `$databaseServer/Name/Username/Password` from the deployment's settings at every start ([update-config.sh](https://github.com/Clouve/magneto/blob/develop/apps/gibbon/image/installer/update-config.sh)), so don't change those four lines by hand. Rotating the database password is a Clouve support request ([playbooks/rotate-admin-credentials.md](playbooks/rotate-admin-credentials.md), section 2).
4. **Dry-run first, then execute.** For any multi-row `UPDATE`/`DELETE`, run the equivalent `SELECT` first and report the row count back to the user. Only proceed after they confirm.
5. **Destructive actions go through `scripts/`.** Freehand `rm -rf`, `DROP TABLE`, `TRUNCATE`, or hand-written `DELETE` without a `WHERE` that you wrote yourself and verified are off-limits. Use [scripts/backup.sh](scripts/backup.sh) for backups and [scripts/verify-health.sh](scripts/verify-health.sh) for health checks.
6. **Check `/version.php` before upgrading.** Gibbon versions itself by the `$version` string in `/var/www/html/version.php`. The running DB version is in the `gibbonSetting` table (scope='System', name='version'). If those disagree, an upgrade is already in progress or failed — see [playbooks/upgrade-gibbon.md](playbooks/upgrade-gibbon.md) before doing anything else.
7. **Never install a module from an untrusted source.** Third-party modules run arbitrary PHP inside the Gibbon container with DB access. Before installing one that did not come from `github.com/GibbonEdu`, read its `manifest.php` and skim its top-level files. See [playbooks/install-module.md](playbooks/install-module.md).
8. **Academic year is sacred.** The `gibbonSchoolYear` table drives enrolment, attendance, markbook, and finance scoping. Rollover (promoting students to next year) is a documented workflow inside Gibbon's own UI — do NOT simulate it with SQL. See [reference/academic-year-rollover.md](reference/academic-year-rollover.md) and [playbooks/year-end-rollover.md](playbooks/year-end-rollover.md).
9. **Never expose the AI Assistant's access key.** Clouve manages it, one key per deployment. It is in the environment as `MAGNETO_AGENT_LLM_KEY` and in your session as `ANTHROPIC_AUTH_TOKEN`. Never print it, never copy it to another path, never send it anywhere. Clouve rotates it; you never replace it.
10. **Clouve doesn't see the inside of this container.** If you can't diagnose something, surface enough detail in chat that the user can file a support ticket — do not "fix it quietly."
11. **Add people through Gibbon's own form, not SQL.** A new `gibbonPerson` row needs about 50 columns with no default and a password hashed the way Gibbon checks it; Gibbon's form gets them right, and a hand-written insert doesn't. The admin adds the person; you check the username, the role and the result. See [playbooks/add-a-user.md](playbooks/add-a-user.md).

## Environment you are running in

- You are inside the Magneto Agent container in the app's pod.
- Gibbon is reachable at the pod-internal hostname `gibbon` on port 80. The Gibbon MySQL is at `gibbon-mysql:3306`. Both are rendered into env vars injected by the app — use `${GIBBON_HOST}` / `${GIBBON_DB_HOST}` rather than hard-coding names.
- Passwords aren't in your environment on current agents. Commands here fetch one with `${NAME:-$(clv-secret NAME)}`, which also works on older agents. `clv-secret --list` shows the names. Never run `clv-secret NAME` on its own or print a value.
- You **do** have an interactive shell in both side containers via SSH as the `clouve-ops` operator account (passwordless sudo). The credential is the per-pod password, `CLOUVE_OPS_PASSWORD`; connect with `SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${GIBBON_HOST}` (or `@${GIBBON_DB_HOST}`). Every `ssh` and `scp` in this skill passes those two `-o` options, which take the key the container shows and save nothing: pass them on any command you write, since an older agent without them fails silently (sshpass exits 6). See [reference/shell-access.md](reference/shell-access.md) for when to use SSH vs. the TCP `mysql`/`curl` channels and the safety gates that apply over the SSH hop.

## Pointers into the deeper docs

- [reference/shell-access.md](reference/shell-access.md) — how to ssh into the gibbon and gibbon-mysql containers as `clouve-ops`, when SSH is the right tool vs. the TCP channels, and the safety gates that apply over SSH.
- [reference/stack-and-runtime.md](reference/stack-and-runtime.md) — PHP/MySQL/Apache versions, extensions, ini settings the installer enforces, filesystem layout.
- [reference/install-and-bootstrap.md](reference/install-and-bootstrap.md) — how the container brings up a fresh instance, what `config.php` contains, install sentinel.
- [reference/upgrade.md](reference/upgrade.md) — how Gibbon versions itself, `CHANGEDB.php` migration format (the `;end` separator gotcha), order of operations.
- [reference/modules.md](reference/modules.md) — core vs. Additional modules, `manifest.php` shape, install/uninstall/update semantics.
- [reference/data-model.md](reference/data-model.md) — the never-touch list, the safe-to-touch list, how `gibbonSetting` and `gibbonSchoolYear` work.
- [reference/backup-restore.md](reference/backup-restore.md) — what a "complete" backup is, how to verify a restore, our volume layout.
- [reference/academic-year-rollover.md](reference/academic-year-rollover.md) — why rollover is fragile, the 3-step flow in `modules/User Admin/rollover.php`, the `max_input_vars` cliff.
- [reference/security.md](reference/security.md) — file permissions, installer lockdown, CSRF/nonce, 2FA, known CVEs, impersonation.
- [reference/operations-and-signals.md](reference/operations-and-signals.md) — what "healthy" looks like, where logs live, our cron wrapper.
- [reference/troubleshooting.md](reference/troubleshooting.md) — failure modes seen in the wild and the first thing to check for each.
- [learnings.md](learnings.md) — living scratchpad for Gibbon-specific facts captured during real sessions that don't yet justify their own file.

## Maintaining this skill

This skill is a living document. When you finish a task and you have learned something Gibbon-specific that future sessions will benefit from, capture it before ending the task — otherwise it is lost.

### What qualifies as worth persisting

- A non-obvious behaviour that surprised you and could bite the next session.
- A version-specific fact about gibbon v30.x that upstream docs do not surface clearly.
- An environment quirk of the Clouve packaging — compose vs. Kubernetes differences, the `update-config.sh` sed, the gibbon-cron wrapper, the `clouve-ops` SSH channel, MySQL 8.0 charset defaults.
- A workflow pattern the user has confirmed at least twice — the verified shape of a recurring request.
- A correction to anything elsewhere in this skill. Fix the original file *in place*, then drop a one-line stub in [learnings.md](learnings.md) so future sessions notice the change.

### What does NOT qualify

- Generic PHP / Apache / MySQL / Linux knowledge (training-data territory).
- Anything `/_clv/`-related — that namespace is the Clouve platform's responsibility, not this skill's.
- Anything that belongs in a global Claude Code skill or in the user's personal memory (not Gibbon-specific).
- Per-session ephemera, secrets, or tenant-identifying data.

### Where each kind of learning belongs

| Kind of learning | File |
|---|---|
| Reference fact about Gibbon proper | the relevant [reference/*.md](reference/), edited in place |
| New verified procedure | a new file under [playbooks/](playbooks/) |
| Audited automation | a new file under [scripts/](scripts/) plus a playbook entry that calls it |
| Cross-cutting / too small / speculative | [learnings.md](learnings.md) |
| Correction to anything above | fix in place + one-line stub in [learnings.md](learnings.md) |

### Edit rules

- **Incremental.** Append or revise one section at a time; never rewrite a whole reference file as part of a learning capture.
- **De-duplicated.** Grep the target file (and `learnings.md`) for the topic before adding a new entry. If a related entry exists, extend it.
- **Terse.** A learning entry is one paragraph. If it grows past ~10 lines, promote it to its own file under `reference/` or `playbooks/` and leave a one-line pointer in `learnings.md`.
- **Dated.** Every `learnings.md` entry carries an ISO-8601 date.
- **Pruned.** When a learning is now covered by a dedicated reference file, delete its `learnings.md` entry — git history retains the original capture.

### Runtime caveat

Inside the deployed Magneto Agent container the skill payload is staged by the marketplace loader at `/clouve/skills/gibbon/plugin/skills/gibbon/` (with a login-time symlink at `~/.claude/skills/gibbon`), and `/clouve/` is **not** in the container's persistent path set (`/usr`, `/var`, `/opt`, `/home`). Edits made at runtime survive the rest of the session but are wiped on the next pod restart, and they do not propagate back to the magneto-skills source repo. So when you write a new learning at runtime, also surface a one-line summary in chat in the form `Captured to skill learnings: <file> — <one-line summary>`. That visible echo is the only mechanism by which a runtime learning becomes durable — the operator can copy it into the magneto-skills repo and the next image rebuild bakes it in for every tenant.

## Safety gates (enforce these in every flow)

The gates are the reason this skill exists. If any of these are skipped, assume the user is at risk.

| Action | Gate |
|---|---|
| Any multi-row `UPDATE`/`DELETE` | `SELECT COUNT(*)` first + user ack |
| Schema change (`ALTER`, `CREATE`, `DROP`, `TRUNCATE`) | Full DB dump first, then user ack |
| Edit to `config.php` | Show the lines you change, with the database password masked (never a diff or a print of the file) + user ack; never the four database lines (the image rewrites them at every start) |
| Restore from backup | Before anything is replaced: both halves' dates and sizes, the tables dropped and restored, and whether `config.php` differs (by `sha256sum`) ([playbooks/rollback-from-backup.md](playbooks/rollback-from-backup.md) step 2) + user ack |
| Install an Additional module | `manifest.php` read + `type=='Additional'` verified + user ack |
| Delete files outside `/tmp` or `/var/www/html/uploads/cache/` | User ack |
| Upgrade Gibbon version | Backup taken first + `gibbonSetting(version)` matches `/var/www/html/version.php` + user ack |
| Year-end rollover | Next `gibbonSchoolYear` row exists + `max_input_vars >= student count` + full backup + user ack |
| Add a user | The admin uses Gibbon's own form ([playbooks/add-a-user.md](playbooks/add-a-user.md)); never a SQL insert, and no password in the chat |
| Rotate DB credentials | Not from here, and the customer has no control for it: Clouve support ([playbooks/rotate-admin-credentials.md](playbooks/rotate-admin-credentials.md), section 2) |

"User ack" means: you print the exact command/SQL you are about to run, and wait for the user to reply affirmatively before executing. Do not infer consent from an earlier "go ahead."
