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
 */
class ModSecurity {
	// Patterns that allow filesystem write/delete or arbitrary code exec.
	static final LUA_PATTERNS_HIGH:Array<{p:EReg, name:String}> = [
		{p: ~/\bsaveFile\b/,         name: "saveFile"},
		{p: ~/\bdeleteFile\b/,       name: "deleteFile"},
		{p: ~/\brunHaxeCode\b/,      name: "runHaxeCode"},
		{p: ~/\brunHaxeFunction\b/,  name: "runHaxeFunction"},
		{p: ~/\baddHaxeLibrary\b/,   name: "addHaxeLibrary"},
		{p: ~/\bos\.execute\b/,      name: "os.execute"},
		{p: ~/\bos\.remove\b/,       name: "os.remove"},
		{p: ~/\bos\.rename\b/,       name: "os.rename"},
		{p: ~/\bio\.popen\b/,        name: "io.popen"},
		{p: ~/\bloadstring\b/,       name: "loadstring"},
		{p: ~/\bdofile\b/,           name: "dofile"},
		{p: ~/\bloadfile\b/,         name: "loadfile"},
	];
	// Patterns that read files or do dynamic class lookup (lower risk).
	static final LUA_PATTERNS_MED:Array<{p:EReg, name:String}> = [
		{p: ~/\bgetTextFromFile\b/,  name: "getTextFromFile"},
		{p: ~/\bio\.open\b/,         name: "io.open"},
	];

	static final HX_PATTERNS_HIGH:Array<{p:EReg, name:String}> = [
		{p: ~/\bSys\.command\b/,        name: "Sys.command"},
		{p: ~/\bSys\.exit\b/,           name: "Sys.exit"},
		{p: ~/\bsys\.io\.File\b/,       name: "sys.io.File"},
		{p: ~/\bsys\.io\.Process\b/,    name: "sys.io.Process"},
		{p: ~/\bsys\.FileSystem\b/,     name: "sys.FileSystem"},
		{p: ~/\bcpp\.Lib\.load\b/,      name: "cpp.Lib.load"},
		{p: ~/\bopenfl\.Lib\.application\b/, name: "openfl.Lib.application"},
	];
	static final HX_PATTERNS_MED:Array<{p:EReg, name:String}> = [
		{p: ~/\bType\.resolveClass\b/,    name: "Type.resolveClass"},
		{p: ~/\bType\.createInstance\b/,  name: "Type.createInstance"},
		{p: ~/\bReflect\.callMethod\b/,   name: "Reflect.callMethod"},
		{p: ~/\bimport\s+sys(\.|\s|;)/,   name: "import sys"},
		{p: ~/\bimport\s+cpp(\.|\s|;)/,   name: "import cpp"},
		{p: ~/\bimport\s+Sys(\s|;)/,      name: "import Sys"},
	];

	public static var records:Map<String, ModSecurityRecord> = new Map();
	static var loaded:Bool = false;
	// Per-session cache: once we've validated a mod's hash this run, don't
	// re-hash on every subsequent script load (was killing perf -- HScript.new
	// and FunkinLua.new both call isBlocked, often dozens of times per state).
	static var checkedThisSession:Map<String, Bool> = new Map();

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
				findings: (rec.findings != null) ? rec.findings : []
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

	public static function setDecision(folder:String, allowed:Bool):Void {
		load();
		var rec = records.get(folder);
		if (rec == null) {
			rec = {hash: computeHash(folder), allowed: allowed, findings: scanMod(folder)};
			records.set(folder, rec);
		} else {
			rec.allowed = allowed;
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
		var currentHash = computeHash(folder);
		if (rec == null) {
			var findings = scanMod(folder);
			rec = {hash: currentHash, allowed: (findings.length == 0), findings: findings};
			records.set(folder, rec);
			save();
			checkedThisSession.set(folder, true);
			return !rec.allowed;
		}
		if (currentHash != rec.hash) {
			// Scripts changed -- re-scan and revoke trust if anything risky
			// is now present. If the new scan is clean, keep the mod allowed.
			var findings = scanMod(folder);
			rec.hash = currentHash;
			rec.findings = findings;
			if (findings.length == 0) rec.allowed = true;
			else rec.allowed = false;
			save();
		}
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
			if (rec != null && !rec.allowed && rec.findings.length > 0)
				out.push(folder);
		}
		return out;
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
					if (pat.p.match(line))
						findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 0, snippet: trimSnippet(line)});
				}
				for (pi in 0...medCount) {
					final pat = meds[pi];
					if (pat.p.match(line))
						findings.push({file: rel, line: li + 1, pattern: pat.name, severity: 1, snippet: trimSnippet(line)});
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
