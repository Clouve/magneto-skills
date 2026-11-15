<?php
// Test fixture: a workflow as an admin would build one in SuiteCRM's Workflow screen. It runs when a contact is
// created and writes "stamped by workflow" into the contact's description.
// Usage: workflow.php import-on | import-off | inactive | email-on | email-off
//   import-on, import-off  make it (or change it), with "Run on import" switched on or off
//   inactive               switch it off
//   email-on, email-off    give it a "Send Email" action as well, or take that action away again; the rest
//                          of the workflow stays as it is. Take it away before anything is saved or imported:
//                          the stack has no mail server for it.
require __DIR__ . '/boot.php';
$mode = $argv[1] ?? '';
$id = $db->getOne("SELECT id FROM aow_workflow WHERE deleted = 0 AND name = 'Test stamp'");
if ($mode === 'email-on' || $mode === 'email-off') {
    if (!$id) {
        sc_fail(2, 'make the workflow first: workflow.php import-on or import-off');
    }
    $mail = $db->getOne("SELECT id FROM aow_actions WHERE deleted = 0 AND action = 'SendEmail' AND aow_workflow_id = " . $db->quoted($id));
    if ($mode === 'email-on' && !$mail) {
        $action = BeanFactory::newBean('AOW_Actions');
        $action->aow_workflow_id = $id;
        $action->name = 'Send a welcome email';
        $action->action = 'SendEmail';
        $action->action_order = 2;
        $action->parameters = base64_encode(serialize(['individual_email' => '1', 'email_template' => '', 'email_target_type' => [0 => 'to'],
            'email_to_type' => [0 => 'Record Email'], 'email' => [0 => '']]));
        $action->save();
    } elseif ($mode === 'email-off' && $mail) {
        $db->query('UPDATE aow_actions SET deleted = 1 WHERE id = ' . $db->quoted($mail));
    }
    sc_done(['workflow' => $id, 'mode' => $mode]);
}
$flow = $id ? BeanFactory::getBean('AOW_WorkFlow', $id) : BeanFactory::newBean('AOW_WorkFlow');
$flow->name = 'Test stamp';
$flow->flow_module = 'Contacts';
$flow->run_when = 'Create';
$flow->flow_run_on = 'New_Records';
$flow->status = $mode === 'inactive' ? 'Inactive' : 'Active';
$flow->run_on_import = $mode === 'import-on' ? 1 : 0;
$flow->multiple_runs = 0;
$flow->save();
if (!$id) {
    $action = BeanFactory::newBean('AOW_Actions');
    $action->aow_workflow_id = $flow->id;
    $action->name = 'Stamp the description';
    $action->action = 'ModifyRecord';
    $action->action_order = 1;
    $action->parameters = base64_encode(serialize(['record_type' => 'Contacts', 'field' => [0 => 'description'],
        'value_type' => [0 => 'Value'], 'value' => [0 => 'stamped by workflow']]));
    $action->save();
}
sc_done(['workflow' => $flow->id, 'mode' => $mode]);
