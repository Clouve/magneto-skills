<?php
/**
 * LimeSurvey skill: remote/lib/boot-classes.php (included by boot.php once LimeSurvey has started and its own
 * classes can be loaded)
 */

/** An admin controller that skips the browser-only start-up (sign-in redirect, forced SSL). */
class LsRcController extends AdminController
{
    public function __construct($id, $module = null)
    {
        CController::__construct($id, $module);
    }
}

/** RemoteControl with the session check replaced: every call runs as the user given here. */
class LsRcHandle extends remotecontrol_handle
{
    public function __construct(AdminController $controller, $username)
    {
        parent::__construct($controller);
        $this->_jumpStartSession($username);
    }
    protected function _checkSessionKey($sSessionKey)
    {
        return true;
    }
}
