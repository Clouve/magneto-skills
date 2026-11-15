<?php
/**
 * SuiteCRM skill: remote/packages.php (runs inside the SuiteCRM container as www-data; packages.sh sends it)
 *
 * Module Loader packages through SuiteCRM's own PackageManager: the list, an install from a zip on stdin, and
 * an uninstall. A package runs its own PHP as the web user while it installs, so packages.sh vets the zip and
 * asks for a yes and a backup before it calls this.
 *
 * Usage: packages.php list | install FILE_NAME SHA256 (the zip on stdin) | uninstall ID keep|remove
 *   SHA256 is the checksum of the file that packages.sh inspect read. What arrives on stdin must have it,
 *   or nothing is written.
 *   keep leaves the tables and custom fields the package made, with the data in them. remove drops them, which
 *   is what SuiteCRM's own uninstall screen does unless "Do Not Remove Tables" is picked.
 *   An uninstall is refused when SuiteCRM's stored copy of the package's zip is gone: SuiteCRM would only
 *   take the package off its list and leave its files in place.
 *
 * Exit codes: 0 done; 64 usage; 65 not a package SuiteCRM accepts, or not the file that was inspected
 * (nothing was installed); 2 the install or uninstall did not end as expected, or the stored zip is gone
 * (nothing was changed); 3 no such package; 4 it is installed already.
 */

require __DIR__ . '/boot.php';
require_once 'ModuleInstall/PackageManager/PackageManager.php';
require_once 'ModuleInstall/ModuleInstaller.php';

function sc_packages(): array
{
    global $db;
    $out = [];
    $res = $db->query("SELECT id_name, name, version, type, status, date_entered, filename FROM upgrade_history ORDER BY date_entered DESC");
    while ($row = $db->fetchByAssoc($res)) {
        $row['filename'] = basename((string) $row['filename']);
        $out[] = $row;
    }
    return $out;
}

function sc_package(string $id): ?array
{
    foreach (sc_packages() as $row) {
        if ($row['id_name'] === $id && $row['status'] === 'installed') {
            return $row;
        }
    }
    return null;
}

global $mod_strings;
$mod_strings = return_module_language('en_us', 'Administration');
$action = $argv[1] ?? '';
switch ($action) {
    case 'list':
        sc_done(['packages' => sc_packages()]);

    case 'install':
        $name = $argv[2] ?? '';
        if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.zip$/', $name)) {
            sc_fail(64, 'the package needs a plain file name that ends in .zip');
        }
        $want = strtolower($argv[3] ?? '');
        if (!preg_match('/^[0-9a-f]{64}$/', $want)) {
            sc_fail(64, 'install needs the sha256 checksum of the file that was inspected. Nothing was installed.');
        }
        $zip = 'upload/' . $name;
        $data = stream_get_contents(STDIN);
        if ($data === false || strlen($data) < 100 || substr($data, 0, 2) !== 'PK') {
            sc_fail(65, 'what arrived is not a zip file. Nothing was installed.');
        }
        // The bytes that arrived are what would be installed, so they are what is checked.
        if (!hash_equals($want, hash('sha256', $data))) {
            sc_fail(65, 'what arrived is not the file that was inspected: its sha256 checksum differs. Nothing was installed. Run packages.sh inspect on the file again.');
        }
        if (file_put_contents($zip, $data) === false) {
            sc_fail(2, 'could not write the package into SuiteCRM\'s upload folder. Nothing was installed.');
        }
        $archive = new ZipArchive();
        if ($archive->open($zip) !== true || $archive->locateName('manifest.php') === false) {
            @unlink($zip);
            sc_fail(65, 'the zip has no manifest.php at its top, so it is not a Module Loader package. Nothing was installed.');
        }
        // The id comes from the manifest's text: nothing of the package runs before the install itself.
        $manifestText = (string) $archive->getFromName('manifest.php');
        $archive->close();
        $id = preg_match('/[\'"]id[\'"]\s*=>\s*[\'"]([A-Za-z0-9_.-]+)[\'"]/', $manifestText, $m) ? $m[1] : '';
        if ($id !== '' && sc_package($id) !== null) {
            @unlink($zip);
            sc_fail(4, "the package \"$id\" is installed already. Uninstall it first to install another version. Nothing was changed.");
        }
        $before = array_column(sc_packages(), 'id_name');
        $pm = new PackageManager();
        try {
            $pm->performSetup($zip, 'module', false);
            $staged = 'upload/upgrades/module/' . $name;
            if (!is_file($staged)) {
                @unlink($zip);
                sc_fail(65, 'SuiteCRM did not accept the package (its manifest does not allow this SuiteCRM version, or is not valid). Nothing was installed.');
            }
            $pm->performInstall($staged, true);
        } catch (Throwable $e) {
            @unlink($zip);
            sc_fail(2, 'the install stopped: ' . $e->getMessage() . '. Check packages.sh list, and restore the backup if SuiteCRM misbehaves.');
        }
        @unlink($zip);
        $new = array_values(array_filter(sc_packages(), fn ($p) => !in_array($p['id_name'], $before, true) && $p['status'] === 'installed'));
        if (count($new) !== 1) {
            sc_fail(2, 'the install ran, but SuiteCRM\'s list of packages does not show exactly one new one. Check packages.sh list.');
        }
        sc_done(['installed' => true, 'package' => $new[0]]);

    case 'uninstall':
        $id = $argv[2] ?? '';
        if (sc_package($id) === null) {
            sc_fail(3, "no installed package has the id \"$id\". packages.sh list shows them.");
        }
        // SuiteCRM undoes a package from the zip it kept at the install. Without that file its uninstall only
        // deletes the package's row (PackageManager::performUninstall) and every file of the package stays.
        $stored = (string) $db->getOne("SELECT filename FROM upgrade_history WHERE status = 'installed' AND id_name = " . $db->quoted($id) . ' ORDER BY date_entered DESC');
        if ($stored === '' || !is_file($stored)) {
            sc_fail(2, "SuiteCRM no longer has its copy of this package's zip (" . ($stored !== '' ? $stored : 'no file name is stored') . " in public/legacy), so it can't take the package's files and changes out: an uninstall now would only take \"$id\" off the list and leave them in place. Nothing was changed. Ask the user for the zip that was installed; with that same file back at that path, owned by the web user, this uninstall works.");
        }
        $remove = ($argv[3] ?? 'keep') === 'remove';
        // PackageManager drops the package's tables and custom fields unless this is set to false first.
        $GLOBALS['mi_remove_tables'] = $remove;
        $pm = new PackageManager();
        try {
            $pm->performUninstall($id);
        } catch (Throwable $e) {
            sc_fail(2, 'the uninstall stopped: ' . $e->getMessage() . '. Check packages.sh list.');
        }
        if (sc_package($id) !== null) {
            sc_fail(2, 'SuiteCRM still lists the package as installed. Check packages.sh list.');
        }
        sc_done(['uninstalled' => true, 'id' => $id, 'tables_and_custom_fields' => $remove ? 'removed' : 'kept']);

    default:
        sc_fail(64, 'unknown action: ' . $action);
}
