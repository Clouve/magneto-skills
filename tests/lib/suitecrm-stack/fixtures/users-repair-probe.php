<?php
// Test fixture for repair.sh: a field whose column the database can't make as asked. A varchar this long
// becomes a text column, so SuiteCRM's repair runs its SQL without an error and the database is still not
// in sync with the field definitions afterwards.
// Usage: users-repair-probe.php add | remove     adds or removes the field's definition (a vardef extension
//                                                of the Bugs module, as Studio or a package would add one)
require __DIR__ . '/boot.php';
$dir = 'custom/Extension/modules/Bugs/Ext/Vardefs';
$file = $dir . '/usr_repair_probe.php';
if (($argv[1] ?? '') === 'add') {
    if (!is_dir($dir) && !mkdir($dir, 0775, true)) {
        sc_fail(2, 'could not make ' . $dir);
    }
    file_put_contents($file, "<?php\n\$dictionary['Bug']['fields']['usr_repair_probe'] = ['name' => 'usr_repair_probe', 'vname' => 'LBL_DESCRIPTION', 'type' => 'varchar', 'len' => '70000'];\n");
    sc_done(['added' => $file]);
}
if (($argv[1] ?? '') === 'remove') {
    @unlink($file);
    sc_done(['removed' => $file]);
}
sc_fail(64, 'usage: users-repair-probe.php add | remove');
