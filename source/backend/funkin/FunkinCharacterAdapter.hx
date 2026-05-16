package backend.funkin;

import objects.Character.CharacterFile;
import objects.Character.AnimArray;
import haxe.Json;

#if MODS_ALLOWED
import sys.io.File;
#end

/**
 * Translates a Funkin Crew v1 character JSON into a Psych `CharacterFile`.
 *
 * Funkin schema (excerpt):
 *   { version, name, renderType, assetPath, flipX,
 *     offsets, cameraOffsets, death:{cameraOffsets},
 *     animations: [{ name, prefix, frameRate?, looped?, frameIndices?,
 *                    offsets?, assetPath?, animType? }] }
 *
 * Conversion notes / limitations:
 *   - Funkin per-animation `assetPath` (e.g. `bf-death`, `bfFakeOut`) cannot
 *     be represented in a single Psych Character because Psych loads one
 *     spritesheet per character. Phase 3 ships with: primary-atlas only.
 *     Animations referencing a different `assetPath` are still registered
 *     so death/cutscene events fail gracefully (no crash), but their frames
 *     won't render. A trace warning is emitted per dropped atlas.
 *   - Funkin `offsets` is a sprite-render correction; Psych's `position` is
 *     stage placement. They're different concepts — we set position=[0,0]
 *     and let the stage adapter (phase 4) set per-character placement.
 *   - `cameraOffsets` maps to Psych `camera_position`.
 *   - `healthbar_colors` isn't in Funkin character files (lives in
 *     notestyles). Default is left null so Psych falls back to its default.
 *   - `healthicon` defaults to the character id (Funkin convention: icon
 *     asset name == character id).
 *   - `renderType` "sparrow"  -> normal sparrow atlas (Psych default).
 *     "animateatlas" / "multianimateatlas" / "symbol" -> flxanimate atlas;
 *     Psych autodetects this from a sibling Animation.json, no extra work.
 */
class FunkinCharacterAdapter {
	/** Default frame rate when a Funkin animation entry omits `frameRate`. */
	public static inline var DEFAULT_FPS:Int = 24;

	/**
	 * Cheap structural check — Funkin character JSON has `renderType` and
	 * `animations` as an Array of objects with `prefix` keys. Psych character
	 * JSON has `animations` with `name` + `anim` keys, no `renderType`.
	 */
	public static function isFunkinCharacter(parsed:Dynamic):Bool {
		if (parsed == null) return false;
		if (Reflect.field(parsed, 'renderType') != null) return true;
		final anims:Dynamic = Reflect.field(parsed, 'animations');
		if (anims != null && Std.isOfType(anims, Array)) {
			final arr:Array<Dynamic> = cast anims;
			if (arr.length > 0) {
				final first:Dynamic = arr[0];
				if (first != null && Reflect.hasField(first, 'prefix') && !Reflect.hasField(first, 'anim'))
					return true;
			}
		}
		return false;
	}

	#if MODS_ALLOWED
	/**
	 * Load and translate a Funkin character file by id. Returns null if no
	 * file is found in the Funkin mod folder.
	 */
	public static function loadFromFunkin(character:String):CharacterFile {
		final path:String = FunkinAssets.characterJson(character);
		if (path == null) return null;
		var raw:String;
		try {
			raw = File.getContent(path);
		} catch (e:Dynamic) {
			trace('FunkinCharacterAdapter: read failed for $character: $e');
			return null;
		}
		var parsed:Dynamic;
		try {
			parsed = Json.parse(raw);
		} catch (e:Dynamic) {
			trace('FunkinCharacterAdapter: parse failed for $character: $e');
			return null;
		}
		return translate(parsed, character);
	}
	#end

	/** Translate parsed Funkin character JSON to a Psych CharacterFile. */
	public static function translate(parsed:Dynamic, character:String):CharacterFile {
		if (parsed == null) return null;

		// Strip Funkin library prefix (`shared:`, `tutorial:`, ...) — Psych
		// asset paths are bare, and the Paths.modFolders library probe will
		// locate the actual file under any library subfolder.
		final rawImage:String = readString(parsed, 'assetPath', 'characters/' + character);
		final image:String = stripLibraryPrefix(rawImage);

		final flipX:Bool = readBool(parsed, 'flipX', false);

		// cameraOffsets -> camera_position.
		final camArr:Array<Float> = readFloatArray(parsed, 'cameraOffsets', [0.0, 0.0]);

		// Funkin sprite-render offsets shouldn't drive stage placement.
		final position:Array<Float> = [0.0, 0.0];

		final animations:Array<AnimArray> = translateAnimations(parsed, image);

		final out:CharacterFile = {
			animations: animations,
			image: image,
			scale: 1.0,
			sing_duration: 4.0,
			healthicon: character,
			position: position,
			camera_position: camArr,
			flip_x: flipX,
			no_antialiasing: false,
			healthbar_colors: [161, 161, 161],
			vocals_file: ''
		};
		return out;
	}

	// --- Internals --- //

	private static function translateAnimations(parsed:Dynamic, primaryImage:String):Array<AnimArray> {
		final out:Array<AnimArray> = [];
		final src:Array<Dynamic> = cast Reflect.field(parsed, 'animations');
		if (src == null) return out;

		final len:Int = src.length;
		for (i in 0...len) {
			final a:Dynamic = src[i];
			if (a == null) continue;

			final perAsset:Dynamic = Reflect.field(a, 'assetPath');
			if (perAsset != null) {
				// Per-animation atlas — Psych Character can't host multiple
				// spritesheets. Warn and skip rather than register a broken
				// animation that would point at frames in the wrong atlas.
				final stripped:String = stripLibraryPrefix(cast perAsset);
				if (stripped != primaryImage) {
					trace('FunkinCharacterAdapter: dropping animation "${Reflect.field(a, "name")}" — secondary atlas "$stripped" not supported');
					continue;
				}
			}

			final indicesDyn:Dynamic = Reflect.field(a, 'frameIndices');
			final offsetsDyn:Dynamic = Reflect.field(a, 'offsets');
			final indices:Array<Int> = (indicesDyn != null) ? (cast indicesDyn : Array<Int>) : [];
			final offsets:Array<Int> = (offsetsDyn != null) ? toIntArray(cast offsetsDyn) : [0, 0];

			final entry:AnimArray = {
				anim: readString(a, 'name', ''),
				name: readString(a, 'prefix', ''),
				fps: readInt(a, 'frameRate', DEFAULT_FPS),
				loop: readBool(a, 'looped', false),
				indices: indices,
				offsets: offsets
			};
			out.push(entry);
		}
		return out;
	}

	private static inline function stripLibraryPrefix(ref:String):String {
		if (ref == null) return null;
		final colon:Int = ref.indexOf(':');
		return (colon > 0) ? ref.substr(colon + 1) : ref;
	}

	private static inline function readString(obj:Dynamic, key:String, fallback:String):String {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		return (v != null && Std.isOfType(v, String)) ? v : fallback;
	}

	private static inline function readBool(obj:Dynamic, key:String, fallback:Bool):Bool {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		return (v != null) ? (v == true) : fallback;
	}

	private static inline function readInt(obj:Dynamic, key:String, fallback:Int):Int {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		return (v != null) ? Std.int(cast v) : fallback;
	}

	private static function readFloatArray(obj:Dynamic, key:String, fallback:Array<Float>):Array<Float> {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		if (v == null || !Std.isOfType(v, Array)) return fallback;
		final src:Array<Dynamic> = cast v;
		final out:Array<Float> = [];
		final len:Int = src.length;
		for (i in 0...len) out.push(cast src[i]);
		return out;
	}

	private static function toIntArray(src:Array<Dynamic>):Array<Int> {
		final out:Array<Int> = [];
		final len:Int = src.length;
		for (i in 0...len) out.push(Std.int(cast src[i]));
		return out;
	}
}
