<?php
/**
 * SuiteCRM skill: remote/repair.php (runs inside the SuiteCRM container as www-data; repair.sh sends it)
 *
 * SuiteCRM's Quick Repair and Rebuild (Admin > Repair), from the shell. It clears the legacy caches (compiled
 * templates, field definitions, language, themes, JavaScript), rebuilds the extensions and the audit tables,
 * and compares the database with the field definitions.
 *
 * Usage: repair.php dry|execute [MODULE]
 *   dry      reports the SQL the repair would run and runs none of it
 *   execute  runs that SQL too, then compares the database with the field definitions once more and
 *            reports what that finds: database_in_sync is the answer of that second comparison, and
 *            sql_still_needed lists what a repair would still run
 *   MODULE   one module, named as in its address (Accounts); default: all modules. It limits which caches
 *            are cleared. The comparison with the database, and the SQL an execute runs, always cover
 *            every module: that is how SuiteCRM's own Quick Repair works.
 *
 * Exit codes: 0 done; 64 usage; 3 no such module; 2 the repair stopped, or it ran and the database is still
 * not in sync with the field definitions (the JSON is printed all the same).
 */

require __DIR__ . '/boot.php';

$mode = $argv[1] ?? '';
if (!in_array($mode, ['dry', 'execute'], true)) {
    sc_fail(64, 'the mode is dry or execute');
}
$module = $argv[2] ?? '';
global $mod_strings, $beanList;
$mod_strings = return_module_language('en_us', 'Administration');
if ($module !== '' && !isset($beanList[$module])) {
    sc_fail(3, "SuiteCRM has no module \"$module\"");
}
require_once 'modules/Administration/QuickRepairAndRebuild.php';
// The repair of one module prints a page title with this helper, which the web entry point loads and the
// command line does not.
require_once 'include/utils/layout_utils.php';

/** The SQL in the page a repair printed, one statement per entry, and whether the page says "in sync". */
function sc_repair_result(string $html): array
{
    global $mod_strings;
    $sql = '';
    if (preg_match('/<textarea[^>]*name=["\']?sql["\']?[^>]*>(.*?)<\/textarea>/is', $html, $m) || preg_match('/<textarea[^>]*id=["\']?repairsql["\']?[^>]*>(.*?)<\/textarea>/is', $html, $m)) {
        $sql = trim(html_entity_decode($m[1], ENT_QUOTES));
    }
    $synced = strpos($html, (string) $mod_strings['LBL_REPAIR_DATABASE_SYNCED']) !== false;
    $statements = array_values(array_filter(array_map('trim', preg_split('/;\s*\n|\n/', $sql)), fn ($line) => $line !== '' && strpos($line, '/*') !== 0));
    return ['in_sync' => $synced && $sql === '', 'statements' => $statements];
}

/**
 * Compares the database with the field definitions of every module and runs nothing: SuiteCRM's own
 * modules/Administration/repairDatabase.php, as a dry pass. QuickRepairAndRebuild loads that file with
 * include_once, so a second pass in one process has to include it here.
 */
function sc_compare_database(): array
{
    global $dictionary, $mod_strings, $current_user, $beanFiles, $sugar_config, $app_strings;
    $_REQUEST['execute'] = false;
    unset($_REQUEST['repair_silent'], $_POST['raction']);
    $GLOBALS['reload_vardefs'] = true;
    $hideModuleMenu = true;
    $html = '';
    ob_start(function ($chunk) use (&$html) {
        $html .= $chunk;
        return '';
    });
    try {
        include 'modules/Administration/repairDatabase.php';
    } finally {
        ob_end_flush();
    }
    return sc_repair_result($html);
}

$started = microtime(true);
// The legacy code prints HTML and flushes it: it is collected here, and only the SQL is taken from it.
$html = '';
ob_start(function ($chunk) use (&$html) {
    $html .= $chunk;
    return '';
});
try {
    $repair = new RepairAndClear();
    $repair->repairAndClearAll(['clearAll'], [$module !== '' ? $module : $mod_strings['LBL_ALL_MODULES']], $mode === 'execute', true);
} catch (Throwable $e) {
    ob_end_clean();
    sc_fail(2, 'the repair stopped: ' . $e->getMessage() . ($mode === 'execute' ? ' Some of its SQL may have run. Run repair.sh without --execute to see what is still different.' : ''));
}
ob_end_flush();
$first = sc_repair_result($html);

if ($mode === 'dry') {
    sc_done([
        'executed' => false,
        'modules' => $module !== '' ? $module : 'all',
        'database_in_sync' => $first['in_sync'],
        'sql_it_would_run' => $first['statements'],
        'seconds' => round(microtime(true) - $started, 1),
        'note' => $first['statements']
            ? 'this SQL changes tables; show it to the user, take a backup, and run repair.sh --execute --yes-repair after a yes'
            : 'caches were cleared and nothing in the database needs changing',
    ]);
}

// After an execute: look again, and report what the comparison finds now.
try {
    $second = sc_compare_database();
} catch (Throwable $e) {
    sc_fail(2, 'the repair ran its SQL, but the check afterwards stopped: ' . $e->getMessage() . ' Run repair.sh without --execute to see whether the database is in sync.');
}
$result = [
    'executed' => true,
    'modules' => $module !== '' ? $module : 'all',
    'database_in_sync' => $second['in_sync'],
    'sql_that_was_run' => $first['statements'],
    'sql_still_needed' => $second['statements'],
    'seconds' => round(microtime(true) - $started, 1),
    'note' => $second['in_sync']
        ? 'the database was compared with the field definitions again after the run, and they agree'
        : 'the SQL ran, and the database is still not in sync with the field definitions: sql_still_needed is what a repair would run now. When it is the same SQL as before, the database could not make that change as asked, and running the repair again will not help. Show it to the user; suitecrm.log may name the reason.',
];
if ($second['in_sync']) {
    sc_done($result);
}
sc_flush_noise();
echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
fwrite(STDERR, "[suitecrm] the repair ran its SQL, and the database is still not in sync with the field definitions. The JSON lists what is left.\n");
exit(2);
