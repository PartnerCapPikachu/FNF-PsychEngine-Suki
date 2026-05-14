package substates;

#if MODS_ALLOWED
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import backend.ModSecurity;

/**
 * Per-mod trust prompt. Shown by MainMenuState when scanning enabled mods
 * surfaces sensitive APIs whose use the user hasn't yet decided on.
 *
 * Iterates through `pending` one mod at a time. Each decision is persisted
 * via ModSecurity.setDecision() the moment the user confirms.
 */
class ModSecuritySubstate extends MusicBeatSubstate {
	var pending:Array<String>;
	var currentIdx:Int = 0;

	var bg:FlxSprite;
	var titleTxt:FlxText;
	var bodyTxt:FlxText;
	var hintTxt:FlxText;
	var trustTxt:Alphabet;
	var blockTxt:Alphabet;
	var onTrust:Bool = false;

	public function new(pending:Array<String>) {
		super();
		this.pending = pending;
	}

	override function create() {
		super.create();

		bg = new FlxSprite().makeGraphic(FlxG.width, FlxG.height, FlxColor.BLACK);
		bg.alpha = 0.88;
		bg.scrollFactor.set();
		add(bg);

		titleTxt = new FlxText(20, 20, FlxG.width - 40, "", 28);
		titleTxt.setFormat(Paths.font("vcr.ttf"), 28, 0xFFFFD24A, LEFT, OUTLINE, FlxColor.BLACK);
		titleTxt.borderSize = 2;
		titleTxt.scrollFactor.set();
		add(titleTxt);

		bodyTxt = new FlxText(20, 90, FlxG.width - 40, "", 16);
		bodyTxt.setFormat(Paths.font("vcr.ttf"), 16, FlxColor.WHITE, LEFT, OUTLINE, FlxColor.BLACK);
		bodyTxt.borderSize = 1.5;
		bodyTxt.scrollFactor.set();
		add(bodyTxt);

		hintTxt = new FlxText(0, FlxG.height - 110, FlxG.width, "", 16);
		hintTxt.setFormat(Paths.font("vcr.ttf"), 16, FlxColor.WHITE, CENTER, OUTLINE, FlxColor.BLACK);
		hintTxt.borderSize = 1.5;
		hintTxt.scrollFactor.set();
		hintTxt.text = "Left/Right to choose -- Enter to confirm";
		add(hintTxt);

		trustTxt = new Alphabet(0, FlxG.height - 70, "TRUST", true);
		trustTxt.x = FlxG.width * 0.30 - trustTxt.width * 0.5;
		add(trustTxt);

		blockTxt = new Alphabet(0, FlxG.height - 70, "BLOCK", true);
		blockTxt.x = FlxG.width * 0.70 - blockTxt.width * 0.5;
		add(blockTxt);

		showCurrent();
		updateOptions();
	}

	function showCurrent():Void {
		if (currentIdx >= pending.length) {
			close();
			return;
		}
		final folder = pending[currentIdx];
		final rec = ModSecurity.records.get(folder);
		titleTxt.text = 'Mod "$folder" uses sensitive APIs';

		final sb = new StringBuf();
		sb.add('This mod\'s scripts can use APIs that are sometimes abused for harm.\n');
		sb.add('Trusting will let its scripts run normally.\n');
		sb.add('Blocking keeps the mod enabled but skips running its scripts.\n');

		if (rec != null) {
			final seenHigh = new Map<String, Bool>();
			final seenMed = new Map<String, Bool>();
			final highList:Array<String> = [];
			final medList:Array<String> = [];
			final findings = rec.findings;
			final fLen = findings.length;
			for (i in 0...fLen) {
				final f = findings[i];
				if (f.severity == 0) {
					if (seenHigh.exists(f.pattern)) continue;
					seenHigh.set(f.pattern, true);
					highList.push(f.pattern);
				} else {
					if (seenMed.exists(f.pattern)) continue;
					seenMed.set(f.pattern, true);
					medList.push(f.pattern);
				}
			}
			if (highList.length > 0) {
				sb.add('\n[HIGH] ');
				sb.add(highList.join(', '));
			}
			if (medList.length > 0) {
				sb.add('\n[MEDIUM] ');
				sb.add(medList.join(', '));
			}

			// Show up to 6 actual file:line examples so the user has something to look at.
			sb.add('\n\nExamples:');
			final shown:Int = fLen < 6 ? fLen : 6;
			for (i in 0...shown) {
				final f = findings[i];
				sb.add('\n  ');
				sb.add(f.file);
				sb.add(':');
				sb.add(Std.string(f.line));
				sb.add('  ');
				sb.add(f.pattern);
			}
			if (fLen > shown) {
				sb.add('\n  ... ');
				sb.add(Std.string(fLen - shown));
				sb.add(' more');
			}
		}

		sb.add('\n\nMod ');
		sb.add(Std.string(currentIdx + 1));
		sb.add(' of ');
		sb.add(Std.string(pending.length));
		bodyTxt.text = sb.toString();
		onTrust = false;
	}

	function updateOptions():Void {
		final trustColor:FlxColor = onTrust ? 0xFF22FF55 : FlxColor.WHITE;
		final blockColor:FlxColor = !onTrust ? 0xFFFF3344 : FlxColor.WHITE;
		final tLetters = trustTxt.letters;
		final tLen:Int = tLetters.length;
		for (i in 0...tLen) tLetters[i].color = trustColor;
		final bLetters = blockTxt.letters;
		final bLen:Int = bLetters.length;
		for (i in 0...bLen) bLetters[i].color = blockColor;
	}

	override function update(elapsed:Float):Void {
		super.update(elapsed);

		if (controls.UI_LEFT_P || controls.UI_RIGHT_P) {
			FlxG.sound.play(Paths.sound('scrollMenu'), 0.6);
			onTrust = !onTrust;
			updateOptions();
		}

		if (controls.ACCEPT) {
			FlxG.sound.play(Paths.sound('confirmMenu'), 0.6);
			ModSecurity.setDecision(pending[currentIdx], onTrust);
			currentIdx++;
			showCurrent();
			updateOptions();
		}
	}
}
#end
