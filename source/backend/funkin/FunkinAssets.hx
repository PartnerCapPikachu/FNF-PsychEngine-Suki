package backend.funkin;

#if MODS_ALLOWED
import sys.FileSystem;
#end

/**
 * Path/library resolver for the official Funkin asset layout.
 *
 * Funkin organizes assets into "libraries" (subfolders of the asset root):
 *   preload/, tutorial/, week1/, week2/, ..., weekend1/, erect/, pico/, ...
 *
 * The asset root is dropped, unmodified, into `mods/funkin/`, so the on-disk
 * layout looks like:
 *   mods/funkin/preload/data/characters/bf.json
 *   mods/funkin/preload/songs/bopeebo/Inst.ogg
 *   mods/funkin/week1/images/...
 *
 * Funkin references cross-library assets with a `<library>:<path>` prefix:
 *   "shared:characters/bf"  -> the "preload" library, file `characters/bf`
 *   "tutorial:characters/..."
 *
 * Helpers here are pure path lookups — no caching, no side effects on the
 * Psych asset pipeline. Higher phases (chart/character/stage adapters) call
 * into these to find Funkin source files when the Psych equivalent is absent.
 *
 * NOTE: `shared` is Funkin's alias for the `preload` library.
 */
class FunkinAssets {
	/** Folder name (under `mods/`) that holds the Funkin asset drop. */
	public static var modFolder:String = 'funkin';

	/**
	 * Library subfolders to scan, in priority order. `preload` is checked
	 * first because most base-game assets live there.
	 */
	public static var libraries:Array<String> = [
		'preload',
		'shared', // alias some forks ship under this name
		'tutorial',
		'week1',
		'week2',
		'week3',
		'week4',
		'week5',
		'week6',
		'week7',
		'weekend1',
		'erect',
		'pico'
	];

	/** `mods/funkin/` (with trailing slash). */
	public static inline function root():String {
		return 'mods/' + modFolder + '/';
	}

	/**
	 * True if the Funkin mod folder is physically present on disk.
	 * Cheap enough to call per-load; cache at the call site if hot.
	 */
	public static function isAvailable():Bool {
		#if MODS_ALLOWED
		return FileSystem.exists(root());
		#else
		return false;
		#end
	}

	/**
	 * Resolve a Funkin-style asset reference (e.g. "shared:characters/bf")
	 * into a usable on-disk path WITHOUT extension. The caller appends
	 * whatever extension(s) it needs (`.png`, `.xml`, `.json`, ...).
	 *
	 * If `ref` has no `library:` prefix, every library is searched.
	 * Returns null if nothing matches and no probing extension is provided.
	 *
	 * @param ref       The Funkin reference. May be `"lib:relative/path"` or
	 *                  just `"relative/path"`.
	 * @param probeExt  Optional extension (without dot) used to probe disk.
	 *                  If null, returns the first candidate path built from
	 *                  the explicit library prefix, or null if no prefix.
	 */
	public static function resolve(ref:String, ?probeExt:String):String {
		#if MODS_ALLOWED
		if (ref == null || ref.length == 0) return null;

		var lib:String = null;
		var rel:String = ref;
		final colon:Int = ref.indexOf(':');
		if (colon > 0) {
			lib = ref.substr(0, colon);
			rel = ref.substr(colon + 1);
			// Funkin's "shared" is the preload library on disk.
			if (lib == 'shared') lib = 'preload';
		}

		if (lib != null) {
			final base:String = root() + lib + '/' + rel;
			if (probeExt == null) return base;
			final full:String = base + '.' + probeExt;
			if (FileSystem.exists(full)) return full;
			return null;
		}

		// No library prefix — probe every library.
		final libs:Array<String> = libraries;
		final len:Int = libs.length;
		for (i in 0...len) {
			final base:String = root() + libs[i] + '/' + rel;
			if (probeExt == null) {
				if (FileSystem.exists(base)) return base;
			} else {
				final full:String = base + '.' + probeExt;
				if (FileSystem.exists(full)) return full;
			}
		}
		return null;
		#else
		return null;
		#end
	}

	/**
	 * Find a file by relative path (e.g. `"data/characters/bf.json"`) across
	 * all libraries. Returns the first match or null.
	 */
	public static function find(relativePath:String):String {
		#if MODS_ALLOWED
		if (relativePath == null || relativePath.length == 0) return null;
		final libs:Array<String> = libraries;
		final len:Int = libs.length;
		final base:String = root();
		for (i in 0...len) {
			final candidate:String = base + libs[i] + '/' + relativePath;
			if (FileSystem.exists(candidate)) return candidate;
		}
		return null;
		#else
		return null;
		#end
	}

	// --- Convenience lookups for the well-known Funkin data folders --- //

	public static inline function characterJson(id:String):String
		return find('data/characters/' + id + '.json');

	public static inline function stageJson(id:String):String
		return find('data/stages/' + id + '.json');

	public static inline function levelJson(id:String):String
		return find('data/levels/' + id + '.json');

	public static inline function noteStyleJson(id:String):String
		return find('data/notestyles/' + id + '.json');

	/**
	 * Path to a song's chart file, optionally for a variation.
	 *   variation null -> "<song>-chart.json"
	 *   variation "erect" -> "<song>-chart-erect.json"
	 */
	public static function songChartJson(song:String, ?variation:String):String {
		final suffix:String = (variation != null && variation.length > 0) ? ('-' + variation) : '';
		return find('data/songs/' + song + '/' + song + '-chart' + suffix + '.json');
	}

	/** Metadata sibling of the chart. Same variation rules as `songChartJson`. */
	public static function songMetadataJson(song:String, ?variation:String):String {
		final suffix:String = (variation != null && variation.length > 0) ? ('-' + variation) : '';
		return find('data/songs/' + song + '/' + song + '-metadata' + suffix + '.json');
	}

	/** `<lib>/songs/<song>/Inst.ogg` */
	public static function songInst(song:String):String
		return find('songs/' + song + '/Inst.' + Paths.SOUND_EXT);

	/** `<lib>/songs/<song>/Voices-<character>.ogg` */
	public static function songVoices(song:String, character:String):String
		return find('songs/' + song + '/Voices-' + character + '.' + Paths.SOUND_EXT);
}
