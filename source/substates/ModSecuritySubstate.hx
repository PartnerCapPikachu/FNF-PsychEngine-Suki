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
	// Patterns we still scan/track but don't surface in the prompt because
	// they're so common that listing them just adds noise. The mod can still
	// trip the prompt via *other* sensitive APIs; this only filters display.
	static final HIDDEN_FROM_DISPLAY:Map<String, Bool> = [
		"runHaxeCode" => true,
		"runHaxeFunction" => true,
		"addHaxeLibrary" => true,
	];

	// Panel layout (centered)
	static inline final PANEL_W:Int = 900;
	static inline final PANEL_H:Int = 560;
	static inline final BORDER:Int = 3;

	var pending:Array<String>;
	var currentIdx:Int = 0;

	var bg:FlxSprite;
	var panelBorder:FlxSprite;
	var panel:FlxSprite;
	var headerBar:FlxSprite;

	var titleTxt:FlxText;
	var subTitleTxt:FlxText;
	var bodyTxt:FlxText;
	var examplesTxt:FlxText;
	var hintTxt:FlxText;
	var counterTxt:FlxText;

	var trustTxt:Alphabet;
	var blockTxt:Alphabet;
	var onTrust:Bool = false;

	public function new(pending:Array<String>) {
		super();
		this.pending = pending;
	}

	override function create() {
		super.create();

		// Full-screen dimmer
		bg = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		bg.scale.set(FlxG.width, FlxG.height);
		bg.updateHitbox();
		bg.alpha = 0.78;
		bg.scrollFactor.set();
		add(bg);

		final px:Float = (FlxG.width - PANEL_W) * 0.5;
		final py:Float = (FlxG.height - PANEL_H) * 0.5;

		// Border (slightly larger than panel, drawn behind it)
		panelBorder = new FlxSprite(px - BORDER, py - BORDER).makeGraphic(1, 1, 0xFFFFD24A);
		panelBorder.scale.set(PANEL_W + BORDER * 2, PANEL_H + BORDER * 2);
		panelBorder.updateHitbox();
		panelBorder.scrollFactor.set();
		add(panelBorder);

		// Panel body
		panel = new FlxSprite(px, py).makeGraphic(1, 1, 0xFF14161E);
		panel.scale.set(PANEL_W, PANEL_H);
		panel.updateHitbox();
		panel.alpha = 0.96;
		panel.scrollFactor.set();
		add(panel);

		// Header strip
		headerBar = new FlxSprite(px, py).makeGraphic(1, 1, 0xFF1F2230);
		headerBar.scale.set(PANEL_W, 70);
		headerBar.updateHitbox();
		headerBar.scrollFactor.set();
		add(headerBar);

		titleTxt = new FlxText(px + 18, py + 10, PANEL_W - 200, "Sensitive API Warning", 22);
		titleTxt.setFormat(Paths.font("vcr.ttf"), 22, 0xFFFFD24A, LEFT, OUTLINE, FlxColor.BLACK);
		titleTxt.borderSize = 1.5;
		titleTxt.scrollFactor.set();
		add(titleTxt);

		counterTxt = new FlxText(px, py + 18, PANEL_W - 18, "", 16);
		counterTxt.setFormat(Paths.font("vcr.ttf"), 16, 0xFFB0B0B0, RIGHT, OUTLINE, FlxColor.BLACK);
		counterTxt.borderSize = 1;
		counterTxt.scrollFactor.set();
		add(counterTxt);

		subTitleTxt = new FlxText(px + 18, py + 38, PANEL_W - 36, "", 18);
		subTitleTxt.setFormat(Paths.font("vcr.ttf"), 18, FlxColor.WHITE, LEFT, OUTLINE, FlxColor.BLACK);
		subTitleTxt.borderSize = 1.25;
		subTitleTxt.scrollFactor.set();
		add(subTitleTxt);

		bodyTxt = new FlxText(px + 18, py + 86, PANEL_W - 36, "", 15);
		bodyTxt.setFormat(Paths.font("vcr.ttf"), 15, FlxColor.WHITE, LEFT, OUTLINE, FlxColor.BLACK);
		bodyTxt.borderSize = 1.25;
		bodyTxt.scrollFactor.set();
		add(bodyTxt);

		examplesTxt = new FlxText(px + 18, py + 240, PANEL_W - 36, "", 13);
		examplesTxt.setFormat(Paths.font("vcr.ttf"), 13, 0xFFCCCCCC, LEFT, OUTLINE, FlxColor.BLACK);
		examplesTxt.borderSize = 1;
		examplesTxt.scrollFactor.set();
		add(examplesTxt);

		// Choice buttons inside the panel
		final btnY:Float = py + PANEL_H - 90;
		trustTxt = new Alphabet(0, btnY, "TRUST", true);
		trustTxt.x = px + PANEL_W * 0.30 - trustTxt.width * 0.5;
		trustTxt.scrollFactor.set();
		add(trustTxt);

		blockTxt = new Alphabet(0, btnY, "BLOCK", true);
		blockTxt.x = px + PANEL_W * 0.70 - blockTxt.width * 0.5;
		blockTxt.scrollFactor.set();
		add(blockTxt);

		hintTxt = new FlxText(px, py + PANEL_H - 28, PANEL_W, "Left/Right to choose -- Enter to confirm", 14);
		hintTxt.setFormat(Paths.font("vcr.ttf"), 14, 0xFFB0B0B0, CENTER, OUTLINE, FlxColor.BLACK);
		hintTxt.borderSize = 1;
		hintTxt.scrollFactor.set();
		add(hintTxt);

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

		counterTxt.text = 'Mod ${currentIdx + 1} / ${pending.length}';
		subTitleTxt.text = '"$folder"';

		final body = new StringBuf();
		body.add('This mod\'s scripts use APIs that can be abused for harm.\n');
		body.add('  - TRUST: scripts run normally.\n');
		body.add('  - BLOCK: mod stays enabled, but its scripts are skipped.\n');

		if (rec != null) {
			final seenHigh = new Map<String, Bool>();
			final seenMed = new Map<String, Bool>();
			final highList:Array<String> = [];
			final medList:Array<String> = [];
			final findings = rec.findings;
			final fLen = findings.length;
			for (i in 0...fLen) {
				final f = findings[i];
				if (HIDDEN_FROM_DISPLAY.exists(f.pattern)) continue;
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
				body.add('\nHIGH risk:    ');
				body.add(highList.join(', '));
			}
			if (medList.length > 0) {
				body.add('\nMEDIUM risk:  ');
				body.add(medList.join(', '));
			}
			if (highList.length == 0 && medList.length == 0)
				body.add('\n(only common APIs found -- listed examples below)');

			// Build examples from non-hidden findings only.
			final exBuf = new StringBuf();
			exBuf.add('Examples:');
			var shown:Int = 0;
			var skipped:Int = 0;
			final maxShown:Int = 6;
			for (i in 0...fLen) {
				final f = findings[i];
				if (HIDDEN_FROM_DISPLAY.exists(f.pattern)) continue;
				if (shown >= maxShown) {
					skipped++;
					continue;
				}
				exBuf.add('\n  ');
				exBuf.add(f.file);
				exBuf.add(':');
				exBuf.add(Std.string(f.line));
				exBuf.add('  ');
				exBuf.add(f.pattern);
				shown++;
			}
			if (shown == 0)
				exBuf.add('\n  (no displayable examples)');
			else if (skipped > 0) {
				exBuf.add('\n  ... ');
				exBuf.add(Std.string(skipped));
				exBuf.add(' more');
			}
			examplesTxt.text = exBuf.toString();
		} else {
			examplesTxt.text = '';
		}

		bodyTxt.text = body.toString();
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
