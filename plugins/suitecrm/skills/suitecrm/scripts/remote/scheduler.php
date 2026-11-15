<?php
/**
 * SuiteCRM skill: remote/scheduler.php (runs inside the SuiteCRM container as www-data; scheduler.sh and
 * upgrade-state.sh send it)
 *
 * Reads the state of SuiteCRM's scheduled jobs and its Messenger worker, and what would start if a held
 * scheduler were released. It changes nothing.
 *
 * Usage: scheduler.php status HOLD_FILE(yes|no|unknown) [SETTING(on|off|none|unknown) [ALSO]] | queued |
 *        queued-text before|now | migrations
 *
 *   status       one JSON document. HOLD_FILE is what remote/admin.sh says about the image's hold file
 *                (tmp/clouve-backup/scheduler-held): there, not there, or unknown because the state folder is
 *                not root's. SETTING is what the image's own tool says about its scheduler setting in
 *                SuiteCRM's settings: on, off, none (this image has no such setting) or unknown (it could not
 *                be read). ALSO is a comma-separated list of the other reasons why the image's loop runs no
 *                job (untrusted, moved-aside, loops-paused), or "-". The scheduler is held when the file is
 *                there, the setting is off, or ALSO names a reason. "held" is true, false, or null when that
 *                is not known; "held_by" lists the reasons.
 *   queued       one JSON document: what a release would start.
 *   queued-text  the same as plain lines, for scheduler.sh release: "before" a release (what it would start),
 *                or "now" (what starts).
 *   migrations   one JSON document: the Manual Migration Tasks by status ({} when there are none).
 *
 * Exit codes: 0 done; 64 usage.
 */

require __DIR__ . '/boot.php';

function sc_table_exists(string $table): bool
{
    global $db;
    return (bool) $db->tableExists($table);
}

function sc_count(string $sql): int
{
    global $db;
    return (int) $db->getOne($sql);
}

function sc_names(string $sql, int $limit = 20): array
{
    global $db;
    $out = [];
    $res = $db->limitQuery($sql, 0, $limit);
    while ($row = $db->fetchByAssoc($res)) {
        $out[] = html_entity_decode((string) reset($row), ENT_QUOTES);
    }
    return $out;
}

function sc_migrations(): array
{
    global $db;
    if (!sc_table_exists('manual_migration_tasks')) {
        return ['available' => false];
    }
    $by = [];
    $res = $db->query("SELECT status, COUNT(*) AS n FROM manual_migration_tasks GROUP BY status");
    while ($row = $db->fetchByAssoc($res)) {
        $by[$row['status']] = (int) $row['n'];
    }
    // An object, so that no tasks is {} in the JSON and not []
    return ['available' => true, 'by_status' => (object) $by];
}

/** What a release of the scheduler would start. */
function sc_queued(): array
{
    global $db;
    $workflows = [];
    if (sc_table_exists('aow_workflow')) {
        $res = $db->limitQuery("SELECT name, flow_module, flow_run_on, run_when FROM aow_workflow WHERE deleted = 0 AND status = 'Active' ORDER BY name", 0, 50);
        while ($row = $db->fetchByAssoc($res)) {
            $workflows[] = ['name' => html_entity_decode((string) $row['name'], ENT_QUOTES), 'module' => $row['flow_module'], 'runs_on' => $row['flow_run_on'], 'when' => $row['run_when']];
        }
    }
    return [
        'campaign_emails_waiting' => sc_table_exists('emailman') ? sc_count("SELECT COUNT(*) FROM emailman WHERE deleted = 0") : 0,
        'campaign_emails_due_now' => sc_table_exists('emailman') ? sc_count("SELECT COUNT(*) FROM emailman WHERE deleted = 0 AND (send_date_time IS NULL OR send_date_time <= UTC_TIMESTAMP())") : 0,
        'active_workflows' => $workflows,
        'workflows_that_run_on_all_records' => count(array_filter($workflows, fn ($w) => $w['runs_on'] === 'All_Records')),
        'scheduled_reports' => sc_table_exists('aor_scheduled_reports') ? sc_names("SELECT name FROM aor_scheduled_reports WHERE deleted = 0 AND status = 'active'") : [],
        'inbound_mailboxes' => sc_table_exists('inbound_email') ? sc_names("SELECT name FROM inbound_email WHERE deleted = 0 AND status = 'Active'") : [],
        'jobs_waiting' => sc_count("SELECT COUNT(*) FROM job_queue WHERE deleted = 0 AND status = 'queued'"),
        'scheduled_jobs_that_never_ran' => sc_count("SELECT COUNT(*) FROM schedulers WHERE deleted = 0 AND status = 'Active' AND last_run IS NULL"),
        'what_a_release_starts' => 'Every active scheduled job runs from the next minute on: campaign emails that are waiting go out, active workflows run (those set to all records go over old records too), inbound mailboxes are read, scheduled reports are mailed, and reminders are sent.',
    ];
}

/** One name for a line of text: no line breaks, at most 80 characters. */
function sc_line_name(string $name): string
{
    return mb_substr(trim((string) preg_replace('/[\x00-\x1F\x7F]+/', ' ', $name)), 0, 80);
}

/** The queue as plain lines, under a title. */
function sc_queued_text(array $q, string $title): string
{
    $list = fn (array $names) => $names === [] ? 'none' : count($names) . ' (' . implode(', ', array_map(fn ($n) => '"' . sc_line_name((string) $n) . '"', $names)) . ')';
    $lines = [$title];
    $lines[] = '  Campaign emails waiting: ' . $q['campaign_emails_waiting'] . ' (' . $q['campaign_emails_due_now'] . ' due now)';
    if ($q['active_workflows'] === []) {
        $lines[] = '  Active workflows: none';
    } else {
        $lines[] = '  Active workflows: ' . count($q['active_workflows']) . ' (' . $q['workflows_that_run_on_all_records'] . ' run on all records, old ones too)';
        foreach ($q['active_workflows'] as $w) {
            $on = ['All_Records' => 'all records', 'New_Records' => 'new records', 'Modified_Records' => 'modified records'][$w['runs_on']] ?? (string) $w['runs_on'];
            $when = ['Always' => 'on save and in the scheduler', 'On_Save' => 'on save only', 'In_Scheduler' => 'in the scheduler only'][$w['when']] ?? (string) $w['when'];
            $lines[] = '    "' . sc_line_name($w['name']) . '" on ' . sc_line_name((string) $w['module']) . ': ' . $on . ', ' . $when;
        }
    }
    $lines[] = '  Scheduled reports: ' . $list($q['scheduled_reports']);
    $lines[] = '  Inbound mailboxes: ' . $list($q['inbound_mailboxes']);
    $lines[] = '  Jobs waiting: ' . $q['jobs_waiting'];
    $lines[] = '  Scheduled jobs that never ran: ' . $q['scheduled_jobs_that_never_ran'];
    $lines[] = '  ' . $q['what_a_release_starts'];
    return implode("\n", $lines) . "\n";
}

$action = $argv[1] ?? '';
switch ($action) {
    case 'status':
        $holdFile = ['1' => 'yes', '0' => 'no'][$argv[2] ?? ''] ?? ($argv[2] ?? '');
        if (!in_array($holdFile, ['yes', 'no', 'unknown'], true)) {
            sc_fail(64, 'status needs yes, no or unknown for the hold file');
        }
        $setting = $argv[3] ?? 'none';
        if (!in_array($setting, ['on', 'off', 'none', 'unknown'], true)) {
            sc_fail(64, 'status needs on, off, none or unknown for the image\'s scheduler setting');
        }
        $heldBy = [];
        if ($holdFile === 'yes') {
            $heldBy[] = 'the hold file /var/www/html/tmp/clouve-backup/scheduler-held is there';
        }
        if ($setting === 'off') {
            $heldBy[] = 'the image\'s scheduler setting is off: SuiteCRM\'s own settings don\'t switch the scheduler loop on, as on an install that existed before this image, until someone releases it';
        }
        $also = array_values(array_filter(explode(',', $argv[4] ?? '-'), fn ($w) => $w !== '' && $w !== '-'));
        $alsoText = [
            'untrusted' => 'this image runs no scheduled job while /var/www/html/tmp/clouve-backup is not a folder of root\'s, because a hold file in it can\'t be read. Putting it right is a step for Clouve support',
            'moved-aside' => 'this image runs no scheduled job while a state folder it moved aside (tmp/clouve-backup.untrusted-<time>) is on the volume, because a hold file in it can\'t be read. Putting it back is a step for Clouve support',
            'loops-paused' => 'staff\'s pause file /var/www/html/tmp/clouve-backup/loops-paused is there: neither the scheduler nor the Messenger worker runs until Clouve support removes it',
        ];
        foreach ($also as $word) {
            if (!isset($alsoText[$word])) {
                sc_fail(64, 'status does not know this reason: ' . $word);
            }
            $heldBy[] = $alsoText[$word];
        }
        $held = $heldBy !== [];
        if ($holdFile === 'unknown' && !in_array('untrusted', $also, true)) {
            $heldBy[] = 'not known: /var/www/html/tmp/clouve-backup is not a folder of root\'s, so the hold file was not read. That is a job for Clouve support';
        }
        if ($setting === 'unknown') {
            $heldBy[] = 'not known: the image\'s scheduler setting could not be read';
        }
        if (!$held && $heldBy !== []) {
            $held = null;
        }
        $worker = false;
        foreach (glob('/proc/[0-9]*/cmdline') ?: [] as $file) {
            $cmd = @file_get_contents($file);
            if ($cmd !== false && strpos($cmd, 'messenger:consume') !== false && strpos($cmd, "php\0") !== false) {
                $worker = true;
                break;
            }
        }
        $allowed = (array) ($sugar_config['cron']['allowed_cron_users'] ?? []);
        $schedulers = [];
        $res = $db->query("SELECT name, status, job_interval, last_run FROM schedulers WHERE deleted = 0 ORDER BY name");
        while ($row = $db->fetchByAssoc($res)) {
            $schedulers[] = ['name' => html_entity_decode($row['name'], ENT_QUOTES), 'status' => $row['status'], 'interval' => $row['job_interval'], 'last_run_utc' => $row['last_run']];
        }
        $jobs = [];
        $res = $db->query("SELECT status, resolution, COUNT(*) AS n FROM job_queue WHERE deleted = 0 AND date_entered > DATE_SUB(UTC_TIMESTAMP(), INTERVAL 1 DAY) GROUP BY status, resolution");
        while ($row = $db->fetchByAssoc($res)) {
            $jobs[] = ['status' => $row['status'], 'resolution' => $row['resolution'], 'jobs' => (int) $row['n']];
        }
        $failed = [];
        $res = $db->limitQuery("SELECT name, date_modified, message FROM job_queue WHERE deleted = 0 AND resolution = 'failure' ORDER BY date_modified DESC", 0, 5);
        while ($row = $db->fetchByAssoc($res)) {
            $failed[] = ['name' => html_entity_decode((string) $row['name'], ENT_QUOTES), 'when_utc' => $row['date_modified'], 'message' => mb_substr(strip_tags(html_entity_decode((string) $row['message'], ENT_QUOTES)), 0, 300)];
        }
        $messenger = sc_table_exists('messenger_messages') ? [
            'waiting' => sc_count("SELECT COUNT(*) FROM messenger_messages WHERE queue_name <> 'failed' AND delivered_at IS NULL"),
            'failed' => sc_count("SELECT COUNT(*) FROM messenger_messages WHERE queue_name = 'failed'"),
        ] : null;
        sc_done([
            'held' => $held,
            'held_by' => $heldBy,
            'hold_file' => $holdFile,
            'image_setting' => $setting,
            'cron_user_allowed' => in_array('www-data', $allowed, true),
            'allowed_cron_users' => array_values($allowed),
            'last_run' => $db->getOne("SELECT MAX(last_run) FROM schedulers WHERE deleted = 0") ?: null,
            'schedulers' => $schedulers,
            'jobs_last_24_hours' => $jobs,
            'last_failed_jobs' => $failed,
            'messenger_worker_running' => $worker,
            'messenger_messages' => $messenger,
            'manual_migration_tasks' => sc_migrations(),
        ]);

    case 'queued':
        sc_done(sc_queued());

    case 'queued-text':
        $titles = ['before' => 'What a release would start (read just now):', 'now' => 'What starts now (read just before the release):'];
        if (!isset($titles[$argv[2] ?? ''])) {
            sc_fail(64, 'queued-text needs before or now');
        }
        $text = sc_queued_text(sc_queued(), $titles[$argv[2]]);
        sc_flush_noise();
        echo $text;
        exit(0);

    case 'migrations':
        sc_done(sc_migrations());

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
