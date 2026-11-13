<?php
/**
 * LimeSurvey skill: remote/lib/boot-session.php (included by boot.php once Yii is loaded, before LimeSurvey starts)
 */

/**
 * The session lives in memory for this one process. No session file, no row in the sessions table, no cookie,
 * whatever session storage the site uses.
 */
class LsRcSession extends CHttpSession
{
    public $autoStart = false;
    public function open()
    {
    }
    public function close()
    {
    }
    public function destroy()
    {
        $_SESSION = array();
    }
    public function getIsStarted()
    {
        return true;
    }
    public function getSessionID()
    {
        return 'ls-rc-cli';
    }
    public function regenerateID($deleteOldSession = false)
    {
    }
}
