<?php
/**
 * LimeSurvey skill: remote/ls-extensions.php
 *
 * Runs INSIDE the LimeSurvey container, as www-data, sent by run-in-limesurvey.sh. extensions.sh is its front end
 * on the agent. It lists plugins and survey themes, and registers or switches them through LimeSurvey's own
 * models, with the checks LimeSurvey's own pages make.
 *
 * Request (stdin): one JSON object with "action" and what the action needs.
 *   plugin-list        every plugin LimeSurvey knows, and every plugin folder on disk it does not know yet: name,
 *                      type (core, user in plugins/, upload in upload/plugins/), on or off, version, whether its
 *                      config.xml lists this LimeSurvey major version, and a load error if it has one
 *   plugin-activate    name. Registers the plugin when it is new, checks that its config.xml lists this LimeSurvey
 *                      major version (LimeSurvey's own rule), runs the plugin's own activation step, and switches
 *                      it on. A plugin that is not compatible is refused, as in LimeSurvey's plugin manager.
 *   plugin-deactivate  name. Switches a plugin off. LimeSurvey's core plugins that refuse this stay on.
 *   theme-list         the survey themes LimeSurvey has registered, and the theme folders in upload/themes/survey
 *                      it has not
 *   theme-register     name. Registers the theme folder upload/themes/survey/<name> that the admin uploaded, after
 *                      checking that its config.xml names it, lists this LimeSurvey major version, and builds on a
 *                      theme that is installed.
 * Reply (stdout): one line, {"result": ..., "error": null} or {"result": null, "error": "..."}; exit 0 or 1.
 */

require __DIR__ . '/lib/boot.php';
require __DIR__ . '/lib/actions.php';

$request = ls_rc_request();
$action = isset($request['action']) ? $request['action'] : '';

/** A plugin or theme name from the request, checked. */
function ls_extension_name(array $request)
{
    $name = (string) ls_need($request, 'name');
    if (!preg_match('/^[A-Za-z_][A-Za-z0-9_-]*$/', $name)) {
        ls_rc_fail('"' . $name . '" is not a plugin or theme name (letters, digits, _ and -, starting with a letter)');
    }
    return $name;
}

/** Whether a config.xml lists the installed LimeSurvey major version. Null when the file cannot be read. */
function ls_config_compatible($file)
{
    if (!is_file($file)) {
        return null;
    }
    $xml = @simplexml_load_file($file);
    if (!$xml) {
        return null;
    }
    $config = new ExtensionConfig($xml);
    return (bool) $config->isCompatible();
}

/** Where a plugin of that type keeps its folder. */
function ls_plugin_dir($root, $type, $name)
{
    switch ($type) {
        case 'core':
            return "$root/application/core/plugins/$name";
        case 'upload':
            return "$root/upload/plugins/$name";
        default:
            return "$root/plugins/$name";
    }
}

/** One plugin row for the reply. */
function ls_plugin_row($root, $plugin)
{
    $dir = ls_plugin_dir($root, $plugin->plugin_type, $plugin->name);
    return array(
        'name' => $plugin->name,
        'type' => $plugin->plugin_type,
        'on' => (int) $plugin->active === 1,
        'version' => $plugin->version,
        'registered' => true,
        'folder_there' => is_dir($dir),
        'compatible' => ls_config_compatible("$dir/config.xml"),
        'load_error' => (int) $plugin->load_error === 1 ? (string) $plugin->load_error_message : null,
    );
}

ls_rc_run(function (array $ctx) use ($request, $action) {
    $root = $ctx['root'];
    $app = $ctx['app'];

    switch ($action) {
        case 'plugin-list':
            $rows = array();
            $known = array();
            foreach (Plugin::model()->findAll(array('order' => 'plugin_type, name')) as $plugin) {
                $rows[] = ls_plugin_row($root, $plugin);
                $known[$plugin->name] = true;
            }
            foreach (array('user' => "$root/plugins", 'upload' => "$root/upload/plugins") as $type => $base) {
                foreach ((array) glob("$base/*/config.xml") as $config) {
                    $name = basename(dirname($config));
                    if (isset($known[$name])) {
                        continue;
                    }
                    $rows[] = array('name' => $name, 'type' => $type, 'on' => false, 'version' => null, 'registered' => false,
                        'folder_there' => true, 'compatible' => ls_config_compatible($config), 'load_error' => null);
                }
            }
            ls_rc_reply(array('limesurvey_version' => $app->getConfig('versionnumber'), 'plugins' => $rows));
            break;

        case 'plugin-activate':
            $name = ls_extension_name($request);
            $plugin = Plugin::model()->findByAttributes(array('name' => $name));
            if (!$plugin) {
                $type = null;
                foreach (array('user', 'upload') as $candidate) {
                    if (is_file(ls_plugin_dir($root, $candidate, $name) . "/$name.php") && is_file(ls_plugin_dir($root, $candidate, $name) . '/config.xml')) {
                        $type = $candidate;
                        break;
                    }
                }
                if ($type === null) {
                    ls_rc_fail("there is no plugin folder $name with $name.php and config.xml in plugins/ or upload/plugins/");
                }
                if (ls_config_compatible(ls_plugin_dir($root, $type, $name) . '/config.xml') !== true) {
                    ls_rc_fail("the plugin $name is not compatible with LimeSurvey " . $app->getConfig('versionnumber') . ': its config.xml does not list this major version under <compatibility>. Its author has to release a version that does');
                }
                $plugin = new Plugin();
                $plugin->name = $name;
                $plugin->plugin_type = $type;
                $plugin->active = 0;
                if (!$plugin->save()) {
                    ls_rc_fail('LimeSurvey did not register the plugin: ' . json_encode($plugin->getErrors()));
                }
            }
            if ((int) $plugin->active === 1) {
                ls_rc_reply(array('changed' => false, 'note' => 'the plugin is already on') + ls_plugin_row($root, $plugin));
            }
            $compatible = null;
            try {
                $compatible = $plugin->isCompatible();
            } catch (Throwable $e) {
                ls_rc_fail('the plugin ' . $name . ' has no config.xml that LimeSurvey can read: ' . $e->getMessage());
            }
            if (!$compatible) {
                ls_rc_fail("the plugin $name is not compatible with LimeSurvey " . $app->getConfig('versionnumber') . ': its config.xml does not list this major version under <compatibility>. Its author has to release a version that does');
            }
            if ((int) $plugin->load_error === 1) {
                ls_rc_fail("LimeSurvey marked the plugin $name as broken when it last tried to load it: " . $plugin->load_error_message . '. Fix the plugin first; reference/plugins-and-themes.md says how the mark is cleared');
            }
            // What LimeSurvey's plugin manager does for "Activate".
            $manager = $app->getPluginManager();
            $manager->loadPlugin($plugin->name, $plugin->id);
            $result = $manager->dispatchEvent(new \LimeSurvey\PluginManager\PluginEvent('beforeActivate', $ctx['controller']), $plugin->name);
            if (!$result->get('success', true)) {
                ls_rc_fail("the plugin $name refused to be switched on: " . ($result->get('message') ?: 'it gave no reason'));
            }
            $plugin->active = 1;
            if (!$plugin->save()) {
                ls_rc_fail('LimeSurvey did not save the plugin: ' . json_encode($plugin->getErrors()));
            }
            ls_rc_reply(array('changed' => true) + ls_plugin_row($root, Plugin::model()->findByPk($plugin->id)));
            break;

        case 'plugin-deactivate':
            $name = ls_extension_name($request);
            $plugin = Plugin::model()->findByAttributes(array('name' => $name));
            if (!$plugin) {
                ls_rc_fail("LimeSurvey has no plugin $name registered");
            }
            if ((int) $plugin->active !== 1) {
                ls_rc_reply(array('changed' => false, 'note' => 'the plugin is already off') + ls_plugin_row($root, $plugin));
            }
            $result = $app->getPluginManager()->dispatchEvent(new \LimeSurvey\PluginManager\PluginEvent('beforeDeactivate', $ctx['controller']), $plugin->name);
            if (!$result->get('success', true)) {
                ls_rc_fail("the plugin $name refused to be switched off: " . ($result->get('message') ?: 'it gave no reason'));
            }
            $plugin->active = 0;
            if (!$plugin->save()) {
                ls_rc_fail('LimeSurvey did not save the plugin: ' . json_encode($plugin->getErrors()));
            }
            ls_rc_reply(array('changed' => true) + ls_plugin_row($root, Plugin::model()->findByPk($plugin->id)));
            break;

        case 'theme-list':
            $rows = array();
            $known = array();
            foreach (Template::model()->findAll(array('order' => 'name')) as $theme) {
                $own = is_dir("$root/upload/themes/survey/" . $theme->folder);
                $rows[] = array('name' => $theme->name, 'registered' => true, 'uploaded' => $own, 'extends' => (string) $theme->extends,
                    'surveys' => (int) Yii::app()->db->createCommand('SELECT COUNT(*) FROM {{surveys}} WHERE template = :name')->queryScalar(array(':name' => $theme->name)));
                $known[$theme->name] = true;
            }
            foreach ((array) glob("$root/upload/themes/survey/*/config.xml") as $config) {
                $name = basename(dirname($config));
                if (!isset($known[$name])) {
                    $rows[] = array('name' => $name, 'registered' => false, 'uploaded' => true, 'extends' => null, 'surveys' => 0,
                        'compatible' => ls_config_compatible($config));
                }
            }
            ls_rc_reply(array('default_theme' => $app->getConfig('defaulttheme'), 'themes' => $rows));
            break;

        case 'theme-register':
            $name = ls_extension_name($request);
            if (Template::model()->findByPk($name)) {
                ls_rc_reply(array('changed' => false, 'name' => $name, 'note' => 'the theme is already registered'));
            }
            $config = "$root/upload/themes/survey/$name/config.xml";
            if (!is_file($config)) {
                ls_rc_fail("there is no theme folder upload/themes/survey/$name with a config.xml. The admin uploads the theme first (as a zip in LimeSurvey's Themes page, or as a folder)");
            }
            $xml = @simplexml_load_file($config);
            if (!$xml || !isset($xml->metadata->name)) {
                ls_rc_fail("upload/themes/survey/$name/config.xml is not a theme's config.xml");
            }
            if ((string) $xml->metadata->name !== $name) {
                ls_rc_fail("the folder is called $name and its config.xml names the theme \"" . $xml->metadata->name . '". The two have to be the same');
            }
            if (ls_config_compatible($config) !== true) {
                ls_rc_fail("the theme $name is not compatible with LimeSurvey " . $app->getConfig('versionnumber') . ': its config.xml does not list this major version under <compatibility>');
            }
            $extends = (string) $xml->metadata->extends;
            if ($extends !== '' && !Template::model()->findByPk($extends)) {
                ls_rc_fail("the theme $name builds on the theme \"$extends\", which is not installed. Register that one first");
            }
            if (!TemplateManifest::importManifest($name)) {
                ls_rc_fail("LimeSurvey did not register the theme $name");
            }
            ls_rc_reply(array('changed' => true, 'name' => $name, 'extends' => $extends));
            break;

        default:
            ls_rc_fail('unknown action. ls-extensions.php takes plugin-list, plugin-activate, plugin-deactivate, theme-list and theme-register');
    }
});
