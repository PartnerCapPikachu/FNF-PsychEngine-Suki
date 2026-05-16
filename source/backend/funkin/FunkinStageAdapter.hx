package backend.funkin;

#if MODS_ALLOWED
import sys.FileSystem;
import sys.io.File;
#end
import haxe.Json;
import backend.StageData.StageFile;

/**
 * Translates a Funkin Crew v1 stage JSON into a Psych `StageFile` in memory.
 *
 * Funkin stage schema (abridged):
 * {
 *   "version": "1.0.x",
 *   "name": "Stage",
 *   "cameraZoom": 1.0,
 *   "directory": "",
 *   "props": [
 *     { "name": "stageback", "assetPath": "stageback",
 *       "position": [-600,-200], "zIndex": 10,
 *       "scale": [1,1], "scroll": [0.9,0.9],
 *       "danceEvery": 0, "animations": [...] }
 *   ],
 *   "characters": {
 *     "bf":  { "zIndex": 4, "position": [770,100], "cameraOffsets": [0,0] },
 *     "gf":  { "zIndex": 3, "position": [400,130], "cameraOffsets": [0,0] },
 *     "dad": { "zIndex": 2, "position": [100,100], "cameraOffsets": [0,0] }
 *   }
 * }
 *
 * Mapping notes:
 *  - `props[]` is sorted by `zIndex` ascending and emitted into `objects[]`.
 *    Psych draws in array order, so lowest z is added first (drawn behind).
 *  - Character anchors emit `boyfriend/girlfriend/opponent` placeholder
 *    objects so `addObjectsToState` can interleave the real sprites at the
 *    right z-layer.
 *  - `assetPath` strips its library prefix (`shared:stageback` -> `stageback`),
 *    mirroring the character adapter. The Funkin layout probe in
 *    `Paths.modFolders` handles the actual disk lookup.
 *  - `danceEvery`, `isPixel`, `alphaMultiplier`, named layers, and most other
 *    Funkin-only fields are dropped silently — Psych has no analog.
 */
class FunkinStageAdapter {
	public static function isFunkinStage(parsed:Dynamic):Bool {
		if (parsed == null) return false;
		// Psych stages have `boyfriend` / `defaultZoom` at the root.
		// Funkin stages have `props` and `characters` instead.
		return Reflect.hasField(parsed, 'props') || Reflect.hasField(parsed, 'characters');
	}

	public static function loadFromFunkin(stage:String):StageFile {
		#if MODS_ALLOWED
		if (stage == null || stage.length == 0) return null;
		final path:String = FunkinAssets.stageJson(stage);
		if (path == null) return null;
		try {
			final parsed:Dynamic = Json.parse(File.getContent(path));
			if (!isFunkinStage(parsed)) return null;
			return translate(parsed);
		} catch (e:Dynamic) {
			trace('FunkinStageAdapter: failed to parse stage "$stage": $e');
			return null;
		}
		#else
		return null;
		#end
	}

	public static function translate(json:Dynamic):StageFile {
		final out:StageFile = backend.StageData.dummy();

		final zoom:Dynamic = Reflect.field(json, 'cameraZoom');
		if (zoom != null) out.defaultZoom = cast zoom;

		final dir:Dynamic = Reflect.field(json, 'directory');
		if (dir != null) out.directory = Std.string(dir);
		else out.directory = '';

		// --- Characters --- //
		final chars:Dynamic = Reflect.field(json, 'characters');
		var bfZ:Int = 0, gfZ:Int = 0, dadZ:Int = 0;
		var hasBf:Bool = false, hasGf:Bool = false, hasDad:Bool = false;

		if (chars != null) {
			final bf:Dynamic = Reflect.field(chars, 'bf');
			if (bf != null) {
				hasBf = true;
				applyCharacter(bf, out, 'boyfriend');
				final z:Dynamic = Reflect.field(bf, 'zIndex');
				if (z != null) bfZ = Std.int(cast z);
			}
			final gf:Dynamic = Reflect.field(chars, 'gf');
			if (gf != null) {
				hasGf = true;
				applyCharacter(gf, out, 'girlfriend');
				final z:Dynamic = Reflect.field(gf, 'zIndex');
				if (z != null) gfZ = Std.int(cast z);
			}
			final dad:Dynamic = Reflect.field(chars, 'dad');
			if (dad != null) {
				hasDad = true;
				applyCharacter(dad, out, 'opponent');
				final z:Dynamic = Reflect.field(dad, 'zIndex');
				if (z != null) dadZ = Std.int(cast z);
			}
		}
		out.hide_girlfriend = !hasGf;

		// --- Props + character anchors merged + z-sorted --- //
		final entries:Array<{z:Int, obj:Dynamic}> = [];
		final props:Array<Dynamic> = cast Reflect.field(json, 'props');
		if (props != null) {
			final pLen:Int = props.length;
			for (i in 0...pLen) {
				final p:Dynamic = props[i];
				if (p == null) continue;
				final obj:Dynamic = translateProp(p);
				if (obj == null) continue;
				final zRaw:Dynamic = Reflect.field(p, 'zIndex');
				entries.push({z: (zRaw != null ? Std.int(cast zRaw) : 0), obj: obj});
			}
		}
		if (hasGf) entries.push({z: gfZ, obj: {name: 'gf', type: 'gfGroup'}});
		if (hasDad) entries.push({z: dadZ, obj: {name: 'dad', type: 'dadGroup'}});
		if (hasBf) entries.push({z: bfZ, obj: {name: 'boyfriend', type: 'boyfriendGroup'}});

		// Stable insertion sort by z ascending; small N, avoids allocator churn.
		entries.sort(function(a, b) return a.z - b.z);

		final objs:Array<Dynamic> = [];
		final eLen:Int = entries.length;
		for (i in 0...eLen) objs.push(entries[i].obj);
		out.objects = objs;

		return out;
	}

	static function applyCharacter(c:Dynamic, out:StageFile, role:String):Void {
		final pos:Array<Dynamic> = cast Reflect.field(c, 'position');
		if (pos != null && pos.length >= 2) {
			final px:Float = cast pos[0];
			final py:Float = cast pos[1];
			switch (role) {
				case 'boyfriend':  out.boyfriend = [px, py];
				case 'girlfriend': out.girlfriend = [px, py];
				case 'opponent':   out.opponent = [px, py];
			}
		}
		final cam:Array<Dynamic> = cast Reflect.field(c, 'cameraOffsets');
		if (cam != null && cam.length >= 2) {
			final cx:Float = cast cam[0];
			final cy:Float = cast cam[1];
			switch (role) {
				case 'boyfriend':  out.camera_boyfriend = [cx, cy];
				case 'girlfriend': out.camera_girlfriend = [cx, cy];
				case 'opponent':   out.camera_opponent = [cx, cy];
			}
		}
	}

	static function translateProp(p:Dynamic):Dynamic {
		final name:String = Reflect.hasField(p, 'name') ? Std.string(Reflect.field(p, 'name')) : null;
		if (name == null || name.length == 0) return null;

		final assetPath:String = Reflect.field(p, 'assetPath');
		final image:String = stripLibraryPrefix(assetPath);

		final anims:Array<Dynamic> = cast Reflect.field(p, 'animations');
		final hasAnims:Bool = (anims != null && anims.length > 0);

		final obj:Dynamic = {
			name: name,
			type: hasAnims ? 'animatedSprite' : 'sprite',
			image: image,
			x: 0.0,
			y: 0.0,
			scale: [1.0, 1.0],
			scroll: [1.0, 1.0],
			alpha: 1.0,
			angle: 0.0,
			color: 'FFFFFF',
			antialiasing: true,
			flipX: false,
			flipY: false,
			filters: 0
		};

		final pos:Array<Dynamic> = cast Reflect.field(p, 'position');
		if (pos != null && pos.length >= 2) {
			obj.x = cast pos[0];
			obj.y = cast pos[1];
		}
		final scale:Array<Dynamic> = cast Reflect.field(p, 'scale');
		if (scale != null && scale.length >= 2) obj.scale = [cast scale[0], cast scale[1]];
		final scroll:Array<Dynamic> = cast Reflect.field(p, 'scroll');
		if (scroll != null && scroll.length >= 2) obj.scroll = [cast scroll[0], cast scroll[1]];

		if (Reflect.hasField(p, 'alpha')) obj.alpha = Reflect.field(p, 'alpha');
		if (Reflect.hasField(p, 'angle')) obj.angle = Reflect.field(p, 'angle');
		if (Reflect.hasField(p, 'isPixel') && Reflect.field(p, 'isPixel') == true) obj.antialiasing = false;

		if (hasAnims) {
			final outAnims:Array<Dynamic> = [];
			final aLen:Int = anims.length;
			var first:String = null;
			for (i in 0...aLen) {
				final a:Dynamic = anims[i];
				if (a == null) continue;
				final animName:String = Reflect.field(a, 'name');
				if (animName == null) continue;
				if (first == null) first = animName;

				final prefix:String = Reflect.field(a, 'prefix');
				final fpsRaw:Dynamic = Reflect.field(a, 'frameRate');
				final loopedRaw:Dynamic = Reflect.field(a, 'looped');
				final offsets:Array<Dynamic> = cast Reflect.field(a, 'offsets');
				final indices:Array<Dynamic> = cast Reflect.field(a, 'frameIndices');

				outAnims.push({
					anim: animName,
					name: prefix != null ? prefix : animName,
					fps: fpsRaw != null ? Std.int(cast fpsRaw) : 24,
					loop: loopedRaw == true,
					indices: indices != null ? indices : [],
					offsets: (offsets != null && offsets.length >= 2) ? [cast offsets[0], cast offsets[1]] : [0, 0]
				});
			}
			obj.animations = outAnims;
			if (first != null) obj.firstAnimation = first;
		}

		return obj;
	}

	static inline function stripLibraryPrefix(assetPath:String):String {
		if (assetPath == null) return null;
		final colon:Int = assetPath.indexOf(':');
		if (colon > 0) return assetPath.substr(colon + 1);
		return assetPath;
	}
}
