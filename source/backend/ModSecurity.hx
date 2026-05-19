package backend;

#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;
import haxe.crypto.Md5;

typedef ModSecurityFinding = {
	var file:String;
	var line:Int;
	var pattern:String;
	var severity:Int; // 0 = high, 1 = medium
	var snippet:String;
}

typedef ModSecurityRecord = {
	var hash:String;
	var allowed:Bool;
	var findings:Array<ModSecurityFinding>;
	// Fast pre-check: file count + summed mtimes of all script files. If this
	// matches, we skip the expensive content hash entirely. Optional for
	// backward compat with previously saved records.
	@:optional var stamp:String;
	// True once the user has explicitly chosen Trust or Block in the prompt.
	// `getPendingMods` ignores any record where this is true so we never
	// re-prompt for an already-decided mod -- only when its scripts actually
	// change (hash mismatch in `isBlocked`) does this get reset to false.
	@:optional var decided:Bool;
}

/**
 * Static-scans mod scripts for sensitive APIs (file IO, code execution,
 * reflection) at mod-enable time and persists per-mod trust decisions.
 *
 * If a mod has any risky finding and no recorded user decision (or its
 * scripts changed since the last decision), `isBlocked` returns true and
 * the script-loading paths in FunkinLua / HScript skip that mod's scripts
 * entirely. The mod itself stays enabled -- its assets, stages, characters
 * etc. continue to load -- only its scripts are gated.
 *
 * `@:unreflective` strips the cpp reflection scaffolding from this class,
 * so `Reflect.field` / `Reflect.setField` against it return null/no-op even
 * if a mod somehow gets a `Class<>` reference. Combined with the runtime
 * `BLOCKED_CLASSES` blocklist used by `safeResolveClass`, this is two
 * independent layers of defense against tampering with trust state.
 */
@:unreflective
class ModSecurity {
	// Patterns that allow filesystem write/delete or arbitrary code exec.
	// Note: runHaxeCode / runHaxeFunction / addHaxeLibrary are intentionally
	// NOT in this list. They're just bridges into HScript -- the vast majority
	// of mods use them for harmless logic, so flagging the bridge call itself
	// would prompt for trust on nearly every modern mod. Instead, when a Lua
	// file contains a Haxe-bridge call, we scan its full content against the
	// HX patterns below (see `scanDir`), so embedded Sys.command / sys.io.File /
	// cpp.Lib.load etc. still get caught by their real, dangerous pattern.
	static final LUA_PATTERNS_HIGH:Array<{p:EReg, name:String}> = [
		{p: ~/\bsaveFile\b/,         name: "saveFile"},
		{p: ~/\bdeleteFile\b/,       name: "deleteFile"},
		{p: ~/\bos\.execute\b/,      name: "os.execute"},
		{p: ~/\bos\.remove\b/,       name: "os.remove"},
		{p: ~/\bos\.rename\b/,       name: "os.rename"},
		{p: ~/\bos\.exit\b/,         name: "os.exit"},
		{p: ~/\bio\.popen\b/,        name: "io.popen"},
		{p: ~/\bloadstring\b/,       name: "loadstring"},
		{p: ~/\bdofile\b/,           name: "dofile"},
		{p: ~/\bloadfile\b/,         name: "loadfile"},
		{p: ~/\bModSecurity\b/,      name: "ModSecurity (tamper)"},
	];
	// Patterns that read files or do dynamic class lookup (lower risk).
	static final LUA_PATTERNS_MED:Array<{p:EReg, name:String}> = [
		{p: ~/\bgetTextFromFile\b/,  name: "getTextFromFile"},
		{p: ~/\bio\.open\b/,         name: "io.open"},
		{p: ~/\bos\.getenv\b/,       name: "os.getenv"},
		{p: ~/\bos\.tmpname\b/,      name: "os.tmpname"},
		{p: ~/\bos\.setlocale\b/,    name: "os.setlocale"},
	];

	// Bridge calls from Lua into Haxe. Presence of any of these in a .lua file
	// means embedded Haxe code may exist (either inline as a string, or running
	// later under an HScript context the Lua file set up), so we additionally
	// scan that file's content against HX_PATTERNS_HIGH/MED to catch the real
	// dangerous calls (Sys.command, sys.io.File, cpp.Lib.load, etc.).
	static final LUA_HAXE_BRIDGE:EReg = ~/\b(runHaxeCode|runHaxeFunction|addHaxeLibrary)\b/;

	static final HX_PATTERNS_HIGH:Array<{p:EReg, name:String}> = [
		{p: ~/\bSys\.command\b/,        name: "Sys.command"},
		{p: ~/\bSys\.exit\b/,           name: "Sys.exit"},
		{p: ~/\bsys\.io\.File\b/,       name: "sys.io.File"},
		{p: ~/\bsys\.io\.Process\b/,    name: "sys.io.Process"},
		{p: ~/\bsys\.FileSystem\b/,     name: "sys.FileSystem"},
		{p: ~/\bcpp\.Lib\.load\b/,      name: "cpp.Lib.load"},
		{p: ~/\bopenfl\.Lib\.application\b/, name: "openfl.Lib.application"},
		{p: ~/\bModSecurity\b/,         name: "ModSecurity (tamper)"},
	];
	static final HX_PATTERNS_MED:Array<{p:EReg, name:String}> = [
		{p: ~/\bType\.resolveClass\b/,    name: "Type.resolveClass"},
		{p: ~/\bType\.createInstance\b/,  name: "Type.createInstance"},
		{p: ~/\bReflect\.callMethod\b/,   name: "Reflect.callMethod"},
		{p: ~/\bimport\s+sys(\.|\s|;)/,   name: "import sys"},
		{p: ~/\bimport\s+cpp(\.|\s|;)/,   name: "import cpp"},
		{p: ~/\bimport\s+Sys(\s|;)/,      name: "import Sys"},
	];

	// Class names that mod scripts are NOT allowed to resolve via reflection.
	// Anything in here returns null from `safeResolveClass`, even if Haxe RTTI
	// would otherwise hand back the Class<>. This prevents a mod from doing
	// `setPropertyFromClass("backend.ModSecurity", "records", {})` to clear
	// its own block, flip `allowed = true`, etc. The scanner also flags any
	// textual mention of these names as a HIGH finding.
	public static final BLOCKED_CLASSES:Map<String, Bool> = [
		"ModSecurity" => true,
		"backend.ModSecurity" => true,
		"ModSecuritySubstate" => true,
		"substates.ModSecuritySubstate" => true,
	];

	/**
	 * Reflection-safe replacement for `Type.resolveClass`. Returns null for
	 * any class on the blocklist. Use this from EVERY mod-script entry point
	 * that resolves a class by name (Lua callbacks, HScript imports, etc.).
	 */
	public static inline function safeResolveClass(name:String):Class<Dynamic> {
		if (name == null) return null;
		if (BLOCKED_CLASSES.exists(name)) return null;
		return Type.resolveClass(name);
	}

	public static var records:Map<String, ModSecurityRecord> = new Map();
	static var loaded:Bool = false;
	// Per-session cache: once we've validated a mod's hash this run, don't
	// re-hash on every subsequent script load (was killing perf -- HScript.new
	// and FunkinLua.new both call isBlocked, often dozens of times per state).
	static var checkedThisSession:Map<String, Bool> = new Map();

	/**
	 * Returns every pattern name the scanner knows about, in display order
	 * (HIGH first, MED second; Lua then Haxe within each tier; deduplicated).
	 * Used by the options UI to enumerate per-check toggles.
	 */
	public static function getAllCheckNames():Array<String> {
		final seen = new Map<String, Bool>();
		final out:Array<String> = [];
		inline function push(arr:Array<{p:EReg, name:String}>) {
			for (i in 0...arr.length) {
				final n = arr[i].name;
				if (seen.exists(n)) continue;
				seen.set(n, true);
				out.push(n);
			}
		}
		push(LUA_PATTERNS_HIGH);
		push(HX_PATTERNS_HIGH);
		push(LUA_PATTERNS_MED);
		push(HX_PATTERNS_MED);
		return out;
	}

	/**
	 * True if the named pattern is currently enabled for scanning. Missing
	 * entries in `ClientPrefs.data.modSecurityChecks` default to enabled, so
	 * any newly-added check is on out of the box. The "ModSecurity (tamper)"
	 * pattern is force-enabled regardless -- disabling it would let a mod
	 * defeat the security system by simply referencing the class.
	 */
	public static inline function isCheckEnabled(name:String):Bool {
		if (name == "ModSecurity (tamper)") return true;
		final map = ClientPrefs.data.modSecurityChecks;
		if (map == null) return true;
		return !map.exists(name) || map.get(name) == true;
	}

	public static function setCheckEnabled(name:String, v:Bool):Void {
		if (name == "ModSecurity (tamper)") return; // cannot be disabled
		var map = ClientPrefs.data.modSecurityChecks;
		if (map == null) {
			map = new Map();
			ClientPrefs.data.modSecurityChecks = map;
		}
		map.set(name, v);
	}

	public static function load():Void {
		if (loaded) return;
		loaded = true;
		var raw:Dynamic = FlxG.save.data.modSecurity;
		if (raw == null) return;
		var fields = Reflect.fields(raw);
		for (i in 0...fields.length) {
			var folder = fields[i];
			var rec:Dynamic = Reflect.field(raw, folder);
			if (rec == null) continue;
			// Defensive coerce: serialized record may be missing fields.
			var r:ModSecurityRecord = {
				hash:     (rec.hash != null) ? rec.hash : "",
				allowed:  (rec.allowed == true),
				findings: (rec.findings != null) ? rec.findings : [],
				stamp:    (rec.stamp != null) ? rec.stamp : null,
				decided:  (rec.decided == true)
			};
			records.set(folder, r);
		}
	}

	public static function save():Void {
		var out:Dynamic = {};
		for (folder => rec in records)
			Reflect.setField(out, folder, rec);
		FlxG.save.data.modSecurity = out;
		FlxG.save.flush();
	}

	/** Force a re-scan of every enabled mod (e.g. user pressed "rescan"). */
	public static function clearAll():Void {
		records = new Map();
		checkedThisSession = new Map();
		FlxG.save.data.modSecurity = null;
		FlxG.save.flush();
	}

	public static function clearMod(folder:String):Void {
		load();
		records.remove(folder);
		checkedThisSession.remove(folder);
		save();
	}

	/**
	 * Re-scan every enabled mod while preserving existing user decisions where
	 * still applicable. Called by the per-check options menu after toggles
	 * change so disabling a check immediately drops the corresponding findings
	 * (and auto-trusts any mod that no longer has any).
	 */
	public static function rescanAll():Void {
		load();
		checkedThisSession = new Map();
		final enabled = Mods.parseList().enabled;
		for (i in 0...enabled.length) {
			final folder = enabled[i];
			final findings = scanMod(folder);
			final hash = computeHash(folder);
			final stamp = computeStamp(folder);
			var rec = records.get(folder);
			if (rec == null) {
				rec = {hash: hash, allowed: (findings.length == 0), findings: findings, stamp: stamp, decided: false};
				records.set(folder, rec);
			} else {
				rec.findings = findings;
				rec.hash = hash;
				rec.stamp = stamp;
				// If nothing risky remains, auto-trust regardless of prior decision.
				if (findings.length == 0) {
					rec.allowed = true;
					rec.decided = false;
				}
				// Otherwise keep the user's prior allowed/decided as-is. If they
				// hadn't decided yet, the next pending-mods check will still pick
				// this mod up.
			}
		}
		save();
	}

	public static function setDecision(folder:String, allowed:Bool):Void {
		load();
		var rec = records.get(folder);
		if (rec == null) {
			rec = {hash: computeHash(folder), allowed: allowed, findings: scanMod(folder), stamp: computeStamp(folder), decided: true};
			records.set(folder, rec);
		} else {
			rec.allowed = allowed;
			rec.decided = true;
			if (rec.stamp == null) rec.stamp = computeStamp(folder);
		}
		checkedThisSession.set(folder, true);
		save();
	}

	/**
	 * True if this mod's scripts must NOT run right now. Lazy-scans the
	 * mod on first hit so it works even if the menu prompt hasn't shown
	 * yet. A mod with zero risky findings is auto-trusted (no prompt).
	 */
	public static function isBlocked(folder:String):Bool {
		if (folder == null || folder.length == 0) return false; // not a mod
		if (!ClientPrefs.data.modSecurityEnabled) return false;
		load();
		// Fast path: already validated this session, just answer from the record.
		if (checkedThisSession.exists(folder)) {
			final cached = records.get(folder);
			return cached == null ? false : !cached.allowed;
		}
		var rec = records.get(folder);
		// Fast pre-check: stat-based stamp. If it matches the saved one, skip
		// the expensive content hash + scan entirely.
		if (rec != null && rec.stamp != null) {
			final currentStamp = computeStamp(folder);
			if (currentStamp == rec.stamp) {
				checkedThisSession.set(folder, true);
				return !rec.allowed;
			}
		}
		var currentHash = computeHash(folder);
		if (rec == null) {
			var findings = scanMod(folder);
			rec = {hash: currentHash, allowed: (findings.length == 0), findings: findings, stamp: computeStamp(folder)};
			records.set(folder, rec);
			save();
			checkedThisSession.set(folder, true);
			return !rec.allowed;
		}
		if (currentHash != rec.hash) {
			// Scripts changed -- re-scan, revoke trust if anything risky is now
			// present, and clear the user's prior decision so the prompt re-shows.
			var findings = scanMod(folder);
			rec.hash = currentHash;
			rec.findings = findings;
			if (findings.length == 0) rec.allowed = true;
			else rec.allowed = false;
			rec.decided = false;
		}
		rec.stamp = computeStamp(folder);
		save();
		checkedThisSession.set(folder, true);
		return !rec.allowed;
	}

	/** Mods that need user attention. Used by MainMenuState to drive the prompt. */
	public static function getPendingMods():Array<String> {
		load();
		var out:Array<String> = [];
		var enabled = Mods.parseList().enabled;
		for (i in 0...enabled.length) {
			var folder = enabled[i];
			isBlocked(folder); // ensures record exists / is up-to-date
			var rec = records.get(folder);
			// Only mods that have findings AND the user has never decided on yet
			// (or whose decision was reset by a script change) are pending.
			if (rec != null && !rec.decided && rec.findings.length > 0)
				out.push(folder);
		}
		return out;
	}

	/** All enabled mods that have any sensitive findings, regardless of prior decision.
	    Used by the Mods menu "MOD SECURITY" button to let users review/change trust. */
	public static function getReviewableMods():Array<String> {
		load();
		var out:Array<String> = [];
		var enabled = Mods.parseList().enabled;
		for (i in 0...enabled.length) {
			var folder = enabled[i];
			isBlocked(folder); // ensures record exists / is up-to-date
			var rec = records.get(folder);
			if (rec != null && rec.findings.length > 0)
				out.push(folder);
		}
		return out;
	}

	/** True if a single mod has any sensitive findings (i.e. would show in a review). */
	public static function hasFindings(folder:String):Bool {
		load();
		isBlocked(folder); // ensures record exists / is up-to-date
		var rec = records.get(folder);
		return rec != null && rec.findings.length > 0;
	}

	public static function scanMod(folder:String):Array<ModSecurityFinding> {
		var modPath:String = Paths.mods(folder);
		if (!FileSystem.exists(modPath) || !FileSystem.isDirectory(modPath))
			return [];
		var findings:Array<ModSecurityFinding> = [];
		try scanDir(modPath, modPath, findings) catch (e:Dynamic) trace('ModSecurity scan failed for $folder: $e');
		return findings;
	}

	static function scanDir(root:String, dir:String, findings:Array<ModSecurityFinding>):Void {
		final entries = FileSystem.readDirectory(dir);
		final entryCount:Int = entries.length;
		for (i in 0...entryCount) {
			final entry = entries[i];
			final full:String = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full)) {
				scanDir(root, full, findings);
				continue;
			}
			final lower:String = entry.toLowerCase();
			final isLua:Bool = lower.endsWith('.lua');
			final isHx:Bool = lower.endsWith('.hx') || lower.endsWith('.hxs') || lower.endsWith('.hscript') || lower.endsWith('.hxc');
			if (!isLua && !isHx) continue;

			var content:String;
			try content = File.getContent(full) catch (e:Dynamic) continue;

			final rel:String = full.substr(root.length + 1).split('\\').join('/');
			final lines = content.split('\n');
			final lineCount:Int = lines.length;
			final highs = isLua ? LUA_PATTERNS_HIGH : HX_PATTERNS_HIGH;
			final meds  = isLua ? LUA_PATTERNS_MED  : HX_PATTERNS_MED;
			final highCount:Int = highs.length;
			final medCount:Int = meds.length;

			// If this is a Lua file that bridges into Haxe, also scan it against
			// the Haxe patterns so embedded Sys/sys/cpp calls inside runHaxeCode
			// strings (or any Haxe set up via addHaxeLibrary) get flagged with
			// their real, concrete pattern instead of a generic "runHaxeCode".
			final alsoScanHx:Bool = isLua && LUA_HAXE_BRIDGE.match(content);
			final extraHighs = alsoScanHx ? HX_PATTERNS_HIGH : null;
			final extraMeds  = alsoScanHx ? HX_PATTERNS_MED  : null;
			final extraHighCount:Int = alsoScanHx ? HX_PATTERNS_HIGH.length : 0;
			final extraMedCount:Int  = alsoScanHx ? HX_PATTERNS_MED.length  : 0;

			for (li in 0...lineCount) {
				final line = lines[li];
				// Skip comment-only lines cheaply -- avoids flagging docs.
				final trimmed = StringTools.ltrim(line);
				if (isLua) {
					if (trimmed.length == 0 || (trimmed.length >= 2 && trimmed.charCodeAt(0) == 45 && trimmed.charCodeAt(1) == 45)) continue;
				} else {
					if (trimmed.length == 0 || (trimmed.length >= 2 && trimmed.charCodeAt(0) == 47 && trimmed.charCodeAt(1) == 47)) continue;
				}
				for (pi in 0...highCount) {
					final pat = highs[pi];
					if (!isCheckEnabled(pat.name)) continue;
					if (pat.p.match(line))
						findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 0, snippet: trimSnippet(line)});
				}
				for (pi in 0...medCount) {
					final pat = meds[pi];
					if (!isCheckEnabled(pat.name)) continue;
					if (pat.p.match(line))
						findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 1, snippet: trimSnippet(line)});
				}
				if (alsoScanHx) {
					for (pi in 0...extraHighCount) {
						final pat = extraHighs[pi];
						if (!isCheckEnabled(pat.name)) continue;
						if (pat.p.match(line))
							findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 0, snippet: trimSnippet(line)});
					}
					for (pi in 0...extraMedCount) {
						final pat = extraMeds[pi];
						if (!isCheckEnabled(pat.name)) continue;
						if (pat.p.match(line))
							findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 1, snippet: trimSnippet(line)});
					}
				}
			}
		}
	}

	static inline function trimSnippet(line:String):String {
		final t = StringTools.trim(line);
		return t.length > 140 ? t.substr(0, 140) + '...' : t;
	}

	public static function computeHash(folder:String):String {
		final modPath:String = Paths.mods(folder);
		if (!FileSystem.exists(modPath) || !FileSystem.isDirectory(modPath)) return '';
		final buf = new StringBuf();
		try hashDir(modPath, buf) catch (e:Dynamic) {}
		return Md5.encode(buf.toString());
	}

	// Cheap fingerprint: script file count + summed modification times.
	// Pure stat calls (no content reads / no MD5). Used as a fast-skip
	// pre-check so we only fall back to the real content hash when the
	// stamp differs from what we recorded last time.
	public static function computeStamp(folder:String):String {
		final modPath:String = Paths.mods(folder);
		if (!FileSystem.exists(modPath) || !FileSystem.isDirectory(modPath)) return '';
		final acc = {count: 0, mtimeSum: 0.0};
		try stampDir(modPath, acc) catch (e:Dynamic) {}
		return acc.count + ':' + acc.mtimeSum;
	}

	static function stampDir(dir:String, acc:{count:Int, mtimeSum:Float}):Void {
		final entries = FileSystem.readDirectory(dir);
		final entryCount:Int = entries.length;
		for (i in 0...entryCount) {
			final entry = entries[i];
			final full = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full)) {
				stampDir(full, acc);
				continue;
			}
			final lower = entry.toLowerCase();
			if (!lower.endsWith('.lua') && !lower.endsWith('.hx') && !lower.endsWith('.hxs') && !lower.endsWith('.hscript') && !lower.endsWith('.hxc')) continue;
			try {
				final stat = FileSystem.stat(full);
				acc.count++;
				acc.mtimeSum += stat.mtime.getTime();
			} catch (e:Dynamic) {}
		}
	}

	static function hashDir(dir:String, buf:StringBuf):Void {
		final entries = FileSystem.readDirectory(dir);
		entries.sort(function(a, b) return a < b ? -1 : (a > b ? 1 : 0));
		final entryCount:Int = entries.length;
		for (i in 0...entryCount) {
			final entry = entries[i];
			final full = Path.join([dir, entry]);
			if (FileSystem.isDirectory(full)) {
				hashDir(full, buf);
				continue;
			}
			final lower = entry.toLowerCase();
			if (!lower.endsWith('.lua') && !lower.endsWith('.hx') && !lower.endsWith('.hxs') && !lower.endsWith('.hscript') && !lower.endsWith('.hxc')) continue;
			try {
				buf.add(full);
				buf.add(':');
				buf.add(File.getContent(full));
				buf.add('\n');
			} catch (e:Dynamic) {}
		}
	}
}
#else
class ModSecurity {
	public static inline function isBlocked(folder:String):Bool return false;
	public static inline function getPendingMods():Array<String> return [];
	public static inline function load():Void {}
	public static inline function setDecision(folder:String, allowed:Bool):Void {}
	public static inline function clearAll():Void {}
	public static inline function clearMod(folder:String):Void {}
}
#end
