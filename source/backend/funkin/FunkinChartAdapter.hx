package backend.funkin;

import backend.Song;
import haxe.Json;

#if MODS_ALLOWED
import sys.io.File;
import sys.FileSystem;
#end

/**
 * Translates a Funkin Crew v2 chart (+ its sibling metadata file) into a
 * Psych `SwagSong`. The result is a normal SwagSong with `format` set to
 * `'funkin_v2_convert'`; the rest of the engine consumes it unchanged.
 *
 * Funkin layout (per song):
 *   <song>-chart.json    : notes (per-difficulty), events, scrollSpeed
 *   <song>-metadata.json : bpm/timeChanges, character ids, stage, variations
 *
 * Variation files sit alongside (`<song>-chart-erect.json`,
 * `<song>-metadata-erect.json`). Phase 2 supports the default variation only;
 * variation routing arrives with the level/week adapter.
 *
 * Mapping summary:
 *   - Sections are synthesized at 4 beats per section (Funkin has no section
 *     concept). bpm changes mid-section are snapped to the next section
 *     boundary; for constant-bpm base-game charts this is exact.
 *   - Funkin note `d`: 0-3 = opponent strums, 4-7 = player strums (fixed).
 *     Psych lane: 0-3 = player, 4-7 = opponent. Translation flips by ±4.
 *   - `mustHitSection` is derived from the most recent `FocusCamera` event
 *     at or before the section start. v=1 -> player (true), else false.
 *   - `FocusCamera` events that land mid-section are dropped (camera follows
 *     mustHitSection at section granularity). Explicit-coordinate variants
 *     `{x,y}` are emitted as Psych "Camera Follow Pos" events so they still
 *     work for fine-grained scripted moves.
 *   - `PlayAnimation` events are emitted as Psych "Play Animation" events.
 *   - Other Funkin events are passed through with their original name so
 *     custom Lua/HScript can read them.
 */
class FunkinChartAdapter {
	/** Default beats-per-section assumed when metadata gives no clue. */
	public static inline var DEFAULT_BEATS_PER_SECTION:Int = 4;

	/**
	 * Heuristic: is this parsed JSON a Funkin v2 chart?
	 * Cheap structural check — does not validate the entire schema.
	 */
	public static function isFunkinChart(parsed:Dynamic):Bool {
		if (parsed == null) return false;
		final version:Dynamic = Reflect.field(parsed, 'version');
		if (version != null && Std.isOfType(version, String) && cast(version, String).indexOf('2.') == 0) {
			// Funkin charts have `notes` as an object keyed by difficulty.
			// Psych charts have `notes` as an Array<SwagSection>.
			final notes:Dynamic = Reflect.field(parsed, 'notes');
			if (notes != null && !Std.isOfType(notes, Array)) return true;
		}
		return false;
	}

	#if MODS_ALLOWED
	/**
	 * Load a Funkin chart + metadata pair from disk and translate to a
	 * SwagSong. Returns null if either file is missing or unparseable.
	 *
	 * @param song        Song id (folder name), e.g. "bopeebo".
	 * @param difficulty  Funkin difficulty key (e.g. "easy"/"normal"/"hard").
	 *                    If null or unknown, falls back to "normal" then to
	 *                    the first available difficulty.
	 * @param variation   Variation suffix (e.g. "erect"). null = default.
	 */
	public static function loadFromFunkin(song:String, ?difficulty:String, ?variation:String):SwagSong {
		final chartPath:String = FunkinAssets.songChartJson(song, variation);
		if (chartPath == null) return null;

		final metaPath:String = FunkinAssets.songMetadataJson(song, variation);
		if (metaPath == null) {
			trace('FunkinChartAdapter: metadata missing for $song (variation=$variation)');
			return null;
		}

		var chartRaw:String, metaRaw:String;
		try {
			chartRaw = File.getContent(chartPath);
			metaRaw = File.getContent(metaPath);
		} catch (e:Dynamic) {
			trace('FunkinChartAdapter: read failed for $song: $e');
			return null;
		}

		var chartJson:Dynamic, metaJson:Dynamic;
		try {
			chartJson = Json.parse(chartRaw);
			metaJson = Json.parse(metaRaw);
		} catch (e:Dynamic) {
			trace('FunkinChartAdapter: parse failed for $song: $e');
			return null;
		}

		return translate(chartJson, metaJson, song, difficulty);
	}
	#end

	/**
	 * Translate parsed (chart, metadata) JSON pair into a SwagSong.
	 * Public so callers with pre-parsed JSON can reuse the logic.
	 */
	public static function translate(chartJson:Dynamic, metaJson:Dynamic, song:String, ?difficulty:String):SwagSong {
		if (chartJson == null || metaJson == null) return null;

		// --- Resolve difficulty key --- //
		final notesByDiff:Dynamic = Reflect.field(chartJson, 'notes');
		var resolvedDiff:String = pickDifficulty(notesByDiff, difficulty);
		if (resolvedDiff == null) {
			trace('FunkinChartAdapter: no notes in chart for $song');
			return null;
		}

		// --- Pull metadata fields --- //
		final playData:Dynamic = Reflect.field(metaJson, 'playData');
		final chars:Dynamic = (playData != null) ? Reflect.field(playData, 'characters') : null;

		final player1:String = readString(chars, 'player', 'bf');
		final player2:String = readString(chars, 'opponent', 'dad');
		final gfVersion:String = readString(chars, 'girlfriend', 'gf');
		final stage:String = (playData != null) ? readString(playData, 'stage', 'mainStage') : 'mainStage';
		final displayName:String = readString(metaJson, 'songName', song);

		// --- Scroll speed --- //
		final scrollSpeedObj:Dynamic = Reflect.field(chartJson, 'scrollSpeed');
		var speed:Float = 1.0;
		if (scrollSpeedObj != null) {
			final v:Dynamic = Reflect.field(scrollSpeedObj, resolvedDiff);
			if (v != null) speed = cast v;
			else {
				final fallback:Dynamic = Reflect.field(scrollSpeedObj, 'normal');
				if (fallback != null) speed = cast fallback;
			}
		}

		// --- Time changes (bpm map) --- //
		final timeChanges:Array<Dynamic> = cast Reflect.field(metaJson, 'timeChanges');
		final firstBpm:Float = (timeChanges != null && timeChanges.length > 0)
			? readFloat(timeChanges[0], 'bpm', 100.0) : 100.0;

		// --- Offset (Funkin stores it under offsets, may be missing) --- //
		var offset:Float = 0.0;
		final offsets:Dynamic = Reflect.field(metaJson, 'offsets');
		if (offsets != null) {
			final inst:Dynamic = Reflect.field(offsets, 'instrumental');
			if (inst != null) offset = cast inst;
		}

		// --- Synthesize sections from timeChanges --- //
		final notesArr:Array<Dynamic> = cast Reflect.field(notesByDiff, resolvedDiff);
		final eventsArr:Array<Dynamic> = cast Reflect.field(chartJson, 'events');
		final sections:Array<SwagSection> = buildSections(notesArr, eventsArr, timeChanges);

		// --- Build event list (Psych format) --- //
		final psychEvents:Array<Dynamic> = translateEvents(eventsArr);

		final out:SwagSong = {
			song: displayName,
			notes: sections,
			events: psychEvents,
			bpm: firstBpm,
			needsVoices: true,
			speed: speed,
			offset: offset,
			player1: player1,
			player2: player2,
			gfVersion: gfVersion,
			stage: stage,
			format: 'funkin_v2_convert'
		};
		return out;
	}

	// --- Internals --- //

	private static function pickDifficulty(notesByDiff:Dynamic, requested:String):String {
		if (notesByDiff == null) return null;
		if (requested != null && Reflect.hasField(notesByDiff, requested)) return requested;
		if (Reflect.hasField(notesByDiff, 'normal')) return 'normal';
		final fields:Array<String> = Reflect.fields(notesByDiff);
		return (fields.length > 0) ? fields[0] : null;
	}

	private static inline function readString(obj:Dynamic, key:String, fallback:String):String {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		return (v != null && Std.isOfType(v, String)) ? v : fallback;
	}

	private static inline function readFloat(obj:Dynamic, key:String, fallback:Float):Float {
		if (obj == null) return fallback;
		final v:Dynamic = Reflect.field(obj, key);
		return (v != null) ? cast v : fallback;
	}

	/**
	 * Walk timeChanges and emit one SwagSection per `DEFAULT_BEATS_PER_SECTION`
	 * beats, covering at least until the last note + last event timestamp.
	 * Notes are placed into the section containing their `t`. mustHitSection
	 * is derived from FocusCamera events occurring at/before each section start.
	 */
	private static function buildSections(notes:Array<Dynamic>, events:Array<Dynamic>, timeChanges:Array<Dynamic>):Array<SwagSection> {
		// Default to a single 100bpm segment if metadata gave nothing.
		final tcs:Array<Dynamic> = (timeChanges != null && timeChanges.length > 0)
			? timeChanges
			: ([{t: 0.0, b: 0.0, bpm: 100.0}] : Array<Dynamic>);

		// Determine how far to extend sections.
		var endMs:Float = 0.0;
		if (notes != null) {
			final nlen:Int = notes.length;
			for (i in 0...nlen) {
				final n:Dynamic = notes[i];
				final t:Float = cast Reflect.field(n, 't');
				final l:Dynamic = Reflect.field(n, 'l');
				final endT:Float = t + ((l != null) ? (cast l : Float) : 0.0);
				if (endT > endMs) endMs = endT;
			}
		}
		if (events != null) {
			final elen:Int = events.length;
			for (i in 0...elen) {
				final t:Float = cast Reflect.field(events[i], 't');
				if (t > endMs) endMs = t;
			}
		}

		// Build per-section boundaries by walking beats.
		// Section start times in ms, plus bpm at that section start.
		final sectionStartsMs:Array<Float> = [];
		final sectionBpm:Array<Float> = [];

		var tcIndex:Int = 0;
		var curBpm:Float = readFloat(tcs[0], 'bpm', 100.0);
		var curTcT:Float = readFloat(tcs[0], 't', 0.0);
		var nextTcT:Float = (tcs.length > 1) ? readFloat(tcs[1], 't', Math.POSITIVE_INFINITY) : Math.POSITIVE_INFINITY;

		var sectionT:Float = curTcT;
		var safety:Int = 0;
		final beatsPerSection:Int = DEFAULT_BEATS_PER_SECTION;

		// Emit sections until we cover endMs (plus one extra for trailing notes).
		while (sectionT <= endMs + 1.0 && safety < 100000) {
			// Advance time-change cursor if the section start crossed a boundary.
			while (tcIndex + 1 < tcs.length && sectionT >= nextTcT - 0.001) {
				tcIndex++;
				curBpm = readFloat(tcs[tcIndex], 'bpm', curBpm);
				curTcT = readFloat(tcs[tcIndex], 't', curTcT);
				nextTcT = (tcIndex + 1 < tcs.length) ? readFloat(tcs[tcIndex + 1], 't', Math.POSITIVE_INFINITY) : Math.POSITIVE_INFINITY;
			}
			sectionStartsMs.push(sectionT);
			sectionBpm.push(curBpm);

			final msPerBeat:Float = 60000.0 / curBpm;
			sectionT += msPerBeat * beatsPerSection;
			safety++;
		}

		// Ensure at least one section exists.
		if (sectionStartsMs.length == 0) {
			sectionStartsMs.push(0.0);
			sectionBpm.push(curBpm);
		}

		// Pre-compute mustHitSection per section from FocusCamera events.
		final sectionCount:Int = sectionStartsMs.length;
		final mustHit:Array<Bool> = [];
		var lastFocus:Int = 0; // default: opponent side focus
		var eventIdx:Int = 0;
		final eventsList:Array<Dynamic> = (events != null) ? events : [];
		final eventsLen:Int = eventsList.length;

		for (s in 0...sectionCount) {
			final sStart:Float = sectionStartsMs[s];
			while (eventIdx < eventsLen) {
				final ev:Dynamic = eventsList[eventIdx];
				final t:Float = cast Reflect.field(ev, 't');
				if (t > sStart + 0.001) break;
				final name:String = cast Reflect.field(ev, 'e');
				if (name == 'FocusCamera') {
					final v:Dynamic = Reflect.field(ev, 'v');
					// v can be a number (0/1/2) or an object with `char`.
					if (v != null) {
						if (Std.isOfType(v, Int) || Std.isOfType(v, Float)) {
							lastFocus = cast v;
						} else {
							final ch:Dynamic = Reflect.field(v, 'char');
							if (ch != null) lastFocus = cast ch;
						}
					}
				}
				eventIdx++;
			}
			mustHit.push(lastFocus == 1);
		}

		// Build SwagSections.
		final sections:Array<SwagSection> = [];
		for (s in 0...sectionCount) {
			final sec:SwagSection = {
				sectionNotes: [],
				sectionBeats: beatsPerSection,
				mustHitSection: mustHit[s],
				bpm: sectionBpm[s],
				changeBPM: (s == 0) ? false : (sectionBpm[s] != sectionBpm[s - 1])
			};
			sections.push(sec);
		}
		// First section's `changeBPM` stays false (chart-level bpm covers it).

		// Place notes into sections.
		if (notes != null) {
			final nlen:Int = notes.length;
			for (i in 0...nlen) {
				final n:Dynamic = notes[i];
				final t:Float = cast Reflect.field(n, 't');
				final d:Int = cast Reflect.field(n, 'd');
				final lDyn:Dynamic = Reflect.field(n, 'l');
				final length:Float = (lDyn != null) ? (cast lDyn : Float) : 0.0;

				// Funkin d 0-3 = opponent, 4-7 = player.
				// Psych lane 0-3 = player, 4-7 = opponent.
				final psychLane:Int = (d < 4) ? (d + 4) : (d - 4);

				// Binary search section by start time.
				var lo:Int = 0, hi:Int = sectionCount - 1, idx:Int = 0;
				while (lo <= hi) {
					final mid:Int = (lo + hi) >> 1;
					if (sectionStartsMs[mid] <= t) { idx = mid; lo = mid + 1; }
					else hi = mid - 1;
				}
				sections[idx].sectionNotes.push([t, psychLane, length, '']);
			}
		}
		return sections;
	}

	/**
	 * Translate Funkin events into Psych's event array.
	 * Psych format: `[[timeMs, [[name, value1, value2], ...]], ...]`
	 * One Funkin event = one Psych time-slot here (we don't merge concurrent
	 * events; PlayState handles either shape).
	 */
	private static function translateEvents(events:Array<Dynamic>):Array<Dynamic> {
		final out:Array<Dynamic> = [];
		if (events == null) return out;
		final len:Int = events.length;
		for (i in 0...len) {
			final ev:Dynamic = events[i];
			final t:Float = cast Reflect.field(ev, 't');
			final name:String = cast Reflect.field(ev, 'e');
			final v:Dynamic = Reflect.field(ev, 'v');

			switch (name) {
				case 'FocusCamera':
					// Coordinate-form focus survives as a Psych event so
					// scripted fine moves still work. Side-form is absorbed
					// into mustHitSection during section build (skip here).
					if (v != null && !Std.isOfType(v, Int) && !Std.isOfType(v, Float)) {
						final x:Dynamic = Reflect.field(v, 'x');
						final y:Dynamic = Reflect.field(v, 'y');
						if (x != null || y != null) {
							out.push([t, [['Camera Follow Pos', x != null ? Std.string(x) : '', y != null ? Std.string(y) : '']]]);
						}
					}
				case 'PlayAnimation':
					if (v != null) {
						final target:String = readString(v, 'target', 'bf');
						final anim:String = readString(v, 'anim', 'idle');
						out.push([t, [['Play Animation', anim, target]]]);
					}
				case 'ZoomCamera':
					if (v != null) {
						final zoom:Dynamic = Reflect.field(v, 'zoom');
						final dur:Dynamic = Reflect.field(v, 'duration');
						out.push([t, [['Add Camera Zoom', zoom != null ? Std.string(zoom) : '', dur != null ? Std.string(dur) : '']]]);
					}
				default:
					// Pass through unknown events. value1 = serialized payload,
					// value2 = original event name (so scripts can recover it).
					final payload:String = (v != null) ? Json.stringify(v) : '';
					out.push([t, [[name, payload, '']]]);
			}
		}
		return out;
	}
}
