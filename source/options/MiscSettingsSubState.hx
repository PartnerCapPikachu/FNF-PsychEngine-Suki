package options;

class MiscSettingsSubState extends BaseOptionsMenu {
	// Sentinel variable name used to mark the "open Mod Security Checks
	// submenu" row. The row is a BOOL placeholder; `update()` below intercepts
	// ACCEPT on it and opens the submenu instead of toggling a value.
	static inline final OPEN_MOD_SECURITY_CHECKS_VAR:String = '__openModSecurityChecks';

	public function new() {
		title = Language.getPhrase('misc_menu', 'Misc Settings');
		rpcTitle = 'Misc Settings Menu'; // for Discord Rich Presence

		var option:Option = new Option('Script Deprecation Warnings',
			"If checked, scripts that use deprecated functions (e.g. \"camera.setFilters(...)\") will print a warning to the debug console.\nDisable to silence noisy mods.",
			'scriptDeprecationWarnings',
			BOOL);
		addOption(option);

		#if MODS_ALLOWED
		// Opener row for the per-check toggles submenu. Uses a BOOL row that
		// always reports `true` so the checkbox is just decorative; the real
		// action happens in update() when ACCEPT is pressed on this row.
		var openChecks:Option = new Option('Mod Security Checks...',
			"Configure which suspicious script calls (saveFile, Sys.command, etc.) the Mod Security scanner looks for.\nPress ACCEPT to open.",
			OPEN_MOD_SECURITY_CHECKS_VAR,
			BOOL);
		openChecks.defaultValue = true;
		openChecks.getValue = function():Dynamic return true;
		openChecks.setValue = function(v:Dynamic):Dynamic return true;
		addOption(openChecks);
		#end

		super();
	}

	#if MODS_ALLOWED
	override function update(elapsed:Float):Void {
		// Intercept ACCEPT on the opener row BEFORE super.update() toggles its
		// BOOL value. Mirrors the guards super.update() uses so we don't fire
		// while a keybind is being captured / immediately after entering.
		if (!bindingKey && nextAccept <= 0 && controls.ACCEPT
			&& optionsArray[curSelected].variable == OPEN_MOD_SECURITY_CHECKS_VAR) {
			FlxG.sound.play(Paths.sound('scrollMenu'));
			openSubState(new ModSecurityChecksSubState());
			nextAccept = 5;
			return;
		}

		super.update(elapsed);
	}
	#end
}
