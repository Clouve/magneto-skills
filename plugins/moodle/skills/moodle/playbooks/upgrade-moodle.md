# Playbook: Upgrade Moodle

Use this playbook whenever the tenant asks to upgrade Moodle to a newer version, or when diagnosing shows that `mdl_config(version)` is behind `public/version.php` (a pending migration).

On Clouve, a newer Moodle comes with a newer image, and the image upgrades the site by itself at the first start of the container (see [reference/upgrade.md → The upgrade on Clouve](../reference/upgrade.md#the-upgrade-on-clouve)). Your part is everything around that start: the checks and the backup before it, and the checks after it. Step 6 then normally finds nothing to do.

## Preconditions

- [ ] Backup taken within the last 24 hours, **and verified restorable** (or running [scripts/backup.sh](../scripts/backup.sh) right now). DB-only is not enough — `<dataroot>` must be in the same backup. See [reference/backup-restore.md](../reference/backup-restore.md).
- [ ] Tenant has acknowledged the maintenance window. Upgrades block writes for the duration; schools usually do this overnight or on a weekend.
- [ ] Release notes read. [https://github.com/moodle/moodle/blob/v\<target\>/UPGRADING.md](https://github.com/moodle/moodle/blob/v5.3.0/UPGRADING.md). Look for the `Removed` and `Changed` sections under `### core` and any plugin you have installed. Any `requires` floor changes? Cache store removals? Auth changes?
- [ ] Source version satisfies the `requires` floor of the target. For 5.2 and 5.3: source must be **`>= 4.4`**. Check with:
      ```sql
      SELECT value FROM mdl_config WHERE name = 'version';
      ```
- [ ] PHP and DB versions on the target image satisfy the new minima — see [reference/changes-in-5.3.md](../reference/changes-in-5.3.md) (and [reference/changes-in-5.2.md](../reference/changes-in-5.2.md) for a site on 5.1 or older).
- [ ] No MUC mappings reference removed cache stores (memcached and mongodb, gone since 5.2). See [reference/changes-in-5.2.md](../reference/changes-in-5.2.md).
- [ ] For a move to 5.3, the three checks in [reference/changes-in-5.3.md → Before the upgrade](../reference/changes-in-5.3.md#before-the-upgrade) are done and their results told to the user: who uses the Classic theme, which added plugins 5.3 will hold back, and whether an added `report_aiusage` or `aiprovider_anthropic` will stop the upgrade.

## Steps

### 1. Capture the pre-upgrade state

```bash
# 1a. Code version (what's on disk):
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \"Code: \", \$CFG->version, PHP_EOL;"'

# 1b. DB version (what's been applied):
MYSQL_PWD="${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}" mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" "$MOODLE_DB_NAME" -sN \
    -e "SELECT CONCAT('DB: ', value) FROM mdl_config WHERE name='version';"
# Or for Postgres:
# PGPASSWORD="${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}" psql -h "$MOODLE_DB_HOST" -U "$MOODLE_DB_USER" -d "$MOODLE_DB_NAME" \
#     -tAc "SELECT 'DB: ' || value FROM mdl_config WHERE name='version';"

# 1c. Row counts in the canaries — capture, you'll compare after:
MYSQL_PWD="${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}" mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" "$MOODLE_DB_NAME" -e "
  SELECT 'mdl_user' AS t, COUNT(*) FROM mdl_user
  UNION ALL SELECT 'mdl_course', COUNT(*) FROM mdl_course
  UNION ALL SELECT 'mdl_quiz_attempts', COUNT(*) FROM mdl_quiz_attempts
  UNION ALL SELECT 'mdl_assign_submission', COUNT(*) FROM mdl_assign_submission
  UNION ALL SELECT 'mdl_grade_grades', COUNT(*) FROM mdl_grade_grades
  UNION ALL SELECT 'mdl_files', COUNT(*) FROM mdl_files
  UNION ALL SELECT 'mdl_logstore_standard_log', COUNT(*) FROM mdl_logstore_standard_log;"
```

Write these numbers down — literally put them in chat. You'll compare after.

### 2. Take a verified backup

```bash
bash "$SKILL_DIR/scripts/backup.sh"
```

Confirm the backup file exists and its size is non-trivial (Moodle DB dumps for a real school are at least tens of MB; `<dataroot>/filedir` archives can be many GB). Do NOT proceed if backup is missing, zero bytes, or the table count looks too low.

### 3. Verify the upgrade is required (and what scope)

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-pending; echo "exit: $?"'
```

| Exit | Meaning |
|---|---|
| `0` | Nothing to upgrade — DB matches code. Stop, no upgrade needed. |
| `2` | Upgrade is pending — proceed to step 4. |

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-maintenance-required; echo "exit: $?"'
```

| Exit | Meaning |
|---|---|
| `2` | Maintenance mode is required (this is the normal case for a major upgrade). |
| `3` | Maintenance mode is NOT required (rare — a no-DDL plugin update). |

Tell the user the result before proceeding.

### 4. Disable cron during the window

If cron fires while the upgrader is mid-flight, you'll get a hung lock. Either pause the schedule (preferred) or:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --disable-wait=120'
```

This disables cron after waiting up to 120s for the current task to finish. Verify no cron is running:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --list'
```

Should report no running tasks.

### 5. Deploy the new code

This step is outside Magneto Agent — the tenant clicks "Update" in the Clouve marketplace UI, or Clouve ops triggers a redeploy with the new `MOODLE_VERSION` in the app's compose. Tell the user:

> Trigger the app update from the Clouve marketplace. The `moodle` container will be recreated with the new code; your data volumes (`moodledata`, the DB volume) are preserved.

Wait for the container to come back up. On the Clouve image the upgrade runs during that start, in maintenance mode and before Apache answers, so a big site can take several minutes. Then confirm the login page answers 200: `curl -sI -H "Host: ${MOODLE_URL#*://}" http://${MOODLE_HOST}/login/index.php` (Moodle answers any other host with a 303).

### 6. Run the upgrade (only if one is still pending)

On the Clouve image, check first: the start in step 5 has normally run it already.

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --is-pending; echo "exit: $?"'
```

Exit `0`: nothing pending, so go on to step 7. Exit `2`: the code is newer than the database, so run the upgrade:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/upgrade.php --non-interactive'
```

The upgrader:
1. Enables CLI maintenance mode (`--maintenance` defaults to `true`).
2. Runs `db/upgrade.php` for core and every installed plugin.
3. Updates `mdl_config(version)` and per-plugin `mdl_config_plugins(*, name=version)`.
4. Disables maintenance mode.
5. Exits 0.

If it fails mid-flight: **stop**, look at the error message, and follow [rollback-from-backup.md](rollback-from-backup.md) unless you can clearly identify and fix the failing plugin. Do NOT re-run with `--allow-unstable` to "force through" — that flag relates to target maturity, not error suppression.

### 7. Purge caches

**Mandatory.** The upgrader's own warning says: *"Caches (except theme) will be STALE and MUST be purged after upgrading."*

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/purge_caches.php'
```

### 8. Re-enable cron

If you disabled it in step 4:

```bash
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/cron.php --enable'
```

Or unpause the external scheduler.

### 9. Verify post-upgrade

```bash
# 9a. Versions match — code and DB:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php -r "require \"/var/www/html/config.php\"; echo \"Code: \", \$CFG->version, PHP_EOL;"'
MYSQL_PWD="${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}" mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" "$MOODLE_DB_NAME" -sN \
    -e "SELECT CONCAT('DB: ', value) FROM mdl_config WHERE name='version';"
# Both should match the new release.

# 9b. Row counts compare to step 1c — none should have dropped:
MYSQL_PWD="${MOODLE_DB_PASSWORD:-$(clv-secret MOODLE_DB_PASSWORD)}" mysql -h "$MOODLE_DB_HOST" -u "$MOODLE_DB_USER" "$MOODLE_DB_NAME" -e "
  SELECT 'mdl_user' AS t, COUNT(*) FROM mdl_user
  UNION ALL SELECT 'mdl_course', COUNT(*) FROM mdl_course
  UNION ALL SELECT 'mdl_quiz_attempts', COUNT(*) FROM mdl_quiz_attempts
  UNION ALL SELECT 'mdl_assign_submission', COUNT(*) FROM mdl_assign_submission
  UNION ALL SELECT 'mdl_grade_grades', COUNT(*) FROM mdl_grade_grades
  UNION ALL SELECT 'mdl_files', COUNT(*) FROM mdl_files;"

# 9c. Health checks pass:
SSHPASS="${CLOUVE_OPS_PASSWORD:-$(clv-secret CLOUVE_OPS_PASSWORD)}" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null clouve-ops@${MOODLE_HOST} \
    'sudo -u www-data php /var/www/html/admin/cli/checks.php'
```

If 9a doesn't match: the upgrade didn't complete fully. Check `mdl_config_log` for the last upgrade run and re-run `admin/cli/upgrade.php`.

If 9b shows a count drop in a sacred table (`mdl_quiz_attempts`, `mdl_grade_grades`, `mdl_files`): **stop immediately** and surface to the user. This is the rollback case.

If 9c shows red items: investigate before letting users in.

### 10. Smoke-test as a real user

- Log in as the admin user.
- Open the home page; verify it renders without errors.
- Open one course (the one with the most activity).
- Open one quiz attempt screen (read-only — don't submit a fake attempt).
- Open one assignment grading screen.
- Check Site administration → Notifications for any red flags.

### 11. Tell the user

Report:
- Source → target version.
- Backup location.
- Cache purge confirmation.
- Row-count comparison: any deltas, expected or surprising.
- Any warnings from the checks dashboard.
- That cron is back on.

## What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| `requires` not satisfied (e.g. source 4.3, target 5.3) | Skipping versions | Upgrade to 4.4 (or 4.5/5.0/5.1/5.2) first, then to 5.3 |
| Plugin's `db/upgrade.php` errors | Plugin doesn't support the new version | Either fix the plugin, uninstall it via [admin/cli/uninstall_plugins.php](https://github.com/moodle/moodle/blob/v5.3.0/admin/cli/uninstall_plugins.php), or roll back |
| MUC error after upgrade ("unable to load store memcached") | 5.2 dropped these stores | Edit `<cachedir>/config.php` to remove the mapping; purge caches |
| Site loads but plugins missing settings UI | Stale MUC | `purge_caches.php` |
| A plugin is gone after the image's upgrade | The image held it back in `/var/www/html/clouve/upgrade-stash/<UTC time>/` | See [install-plugin.md → Putting back a held-back plugin](install-plugin.md#putting-back-a-held-back-plugin) |
| Still on the old version after the new image started (`public/version.php` and `/var/www/html/clouve/installed/version` unchanged) | The image found an added plugin that the new Moodle ships in an older version, and left the site on its old code | See [reference/changes-in-5.3.md → A site the image doesn't upgrade](../reference/changes-in-5.3.md#a-site-the-image-doesnt-upgrade) |
| "Site is being upgraded, please retry later" | A start was cut off during Moodle's upgrade | The next start clears the lock and runs the upgrade again; otherwise wait about five minutes for the lock to expire |
| Site looks different after 5.3 (theme, block layout) | The Classic theme is gone; Moodle moved the site to Boost | See [reference/changes-in-5.3.md → The Classic theme is gone](../reference/changes-in-5.3.md#the-classic-theme-is-gone) |
| Site loads but theme is broken | Stale theme cache | `purge_caches.php --theme` and hard-reload browser |
| `wwwroot` mismatch warnings | The site's address changed (HTTP to HTTPS, a new domain) | The image writes `wwwroot` from the deployment's address at every start. If they still differ after a start, that's a Clouve support request |
| `Database connection failed` post-upgrade | `config.php`'s database lines don't match the database | Check that MySQL answers ([diagnose-500.md](diagnose-500.md) step 3b). The image writes those lines from the deployment's settings at every start, so a mismatch that lasts past a start is a Clouve support request |

## After-action

If you learned something Moodle-specific that future upgrade sessions will benefit from, capture it per [SKILL.md → Maintaining this skill](../SKILL.md#maintaining-this-skill). Especially worth capturing:

- A specific plugin that needed special handling.
- A row-count canary that turned out to be misleading.
- A specific DB engine quirk during the migration.
