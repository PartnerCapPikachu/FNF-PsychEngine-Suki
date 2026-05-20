# Mod Migration Guide: Psych 1.0.4 → 1.1

This guide lists the script-facing changes a mod author may need to apply when
upgrading from Psych Engine **1.0.4** to **1.1.0+**.

The Lua / HScript surface area is *intentionally* kept unchanged wherever
possible. Most mods will run unchanged. The items below are the cases that
do not.

---

## Table of Contents
- [Modpack metadata](#modpack-metadata)
- [Camera filters API (Shaders)](#camera-filters-api-shaders)
  - [What changed](#what-changed)
  - [Before (1.0.4, HScript)](#before-104-hscript)
  - [After (1.1, HScript)](#after-11-hscript)
  - [Adding / removing a single filter](#adding--removing-a-single-filter)
- [FlxAnimate → flixel-animate (Texture Atlas)](#flxanimate--flixel-animate-texture-atlas)
  - [Why the swap](#why-the-swap)
  - [Package / import changes](#package--import-changes)
  - [API translation table](#api-translation-table)
  - [HScript example](#hscript-example)
  - [Lua bindings](#lua-bindings)
  - [`Paths.loadAnimateAtlas` behavior](#pathsloadanimateatlas-behavior)
- [Need help?](#need-help)

---

## Modpack metadata
Extended pack.json metadata a bit for convenience.
- Two types of packs, defined in pack.json. "Mod pack" or "Script Pack"
  - Script packs run globally and are always accessable through pause menus "Mod Settings".
  - Mod packs run locally with the option to opt in using "runsGlobally" as usual. If a mod pack has settings, it will also show up in pause menus "Mod Settings".

If no type is specified, it defaults to "modpack". So if your modpack is a collection of scripts, you should set type to "scriptpack" or runsGlobally to "true". I recommend setting type over runsGlobally as there may be changes to how runsGlobally is handled.


## Camera filters API (Shaders)

The old camera helper methods were removed when HaxeFlixel turned
`FlxCamera.filters` into a plain public field. Mods that previously called
those methods will now throw `Tried to call null function setFilters` (or
similar) when run.

### What changed

| Removed (Psych 1.0.4)              | Replace with (Psych 1.1)                       |
| ---------------------------------- | ---------------------------------------------- |
| `camera.setFilters([...])`         | `camera.filters = [...]`                       |
| `camera.addFilter(filter)`         | `camera.filters.push(filter)` *(init if null)* |
| `camera.removeFilter(filter)`      | `camera.filters.remove(filter)`                |
| `camera.clearFilters()`            | `camera.filters = null`                        |

Applies to **all** cameras (`camGame`, `camHUD`, `camOther`, custom cameras),
not just `PsychCamera`.

### Before (1.0.4, HScript)

```haxe
camHUD.setFilters([new ShaderFilter(shader)]);
// ...
camHUD.clearFilters();
```

### After (1.1, HScript)

```haxe
camHUD.filters = [new ShaderFilter(shader)];
// ...
camHUD.filters = null;
```

### Adding / removing a single filter

```haxe
// add
if (camHUD.filters == null) camHUD.filters = [];
camHUD.filters.push(new ShaderFilter(shader));

// remove
if (camHUD.filters != null) {
    camHUD.filters.remove(myFilter);
    if (camHUD.filters.length == 0) camHUD.filters = null;
}
```
---

## FlxAnimate → flixel-animate (Texture Atlas)

The Adobe Animate / Texture Atlas backend was swapped from
[`Dot-Stuff/flxanimate`](https://github.com/Dot-Stuff/flxanimate) to
[`MaybeMaru/flixel-animate`](https://github.com/MaybeMaru/flixel-animate).

This is a **breaking change** for any mod that imports the atlas library
directly in HScript, or that touches `sprite.anim.curInstance` /
`sprite.anim.curSymbol` / the old `pauseAnimation()` / `resumeAnimation()`
helpers from HScript or Lua callbacks.

Most mods do **not** need any changes: characters declared via
`character.json` (with a sibling `Animation.json`) continue to load and play
exactly as before. The Lua helpers `makeFlxAnimateSprite`,
`loadAnimateAtlas`, `addAnimationBySymbol`, and `addAnimationBySymbolIndices`
keep the same names and parameters — see [Lua bindings](#lua-bindings)
for the one signature trim.

### Why the swap

- The new library reuses Flixel's standard `FlxAnimationController`, so
  texture-atlas sprites now expose the *same* `anim.play() / .finished /
  .curAnim / .pause() / .resume()` surface as regular `FlxSprite`s. No more
  parallel "symbol" API to learn.
- `FlxAnimateFrames.fromAnimate(...)` auto-detects spritemap exports, so
  Psych's custom `PsychFlxAnimate.loadAtlasEx` subclass is gone (the
  multi-format loader logic now lives in upstream).
- It is actively maintained and ships fixes/features that the older fork
  never received.

### Package / import changes

| Old (`flxanimate`)                           | New (`flixel-animate`)                  |
| -------------------------------------------- | --------------------------------------- |
| `import flxanimate.FlxAnimate;`              | `import animate.FlxAnimate;`            |
| `import flxanimate.frames.FlxAnimateFrames;` | `import animate.FlxAnimateFrames;`      |
| `import flxanimate.PsychFlxAnimate;`         | **removed** — use `animate.FlxAnimate`  |
| `#if flxanimate`                             | `#if flixel_animate`                    |

In HScript the engine pre-registers `FlxAnimate` for you (it points at
`animate.FlxAnimate`), so `new FlxAnimate(x, y)` keeps working without an
explicit `import`.

### API translation table

All of these are **runtime-breaking** if your mod scripts touch them.

| Removed (old `flxanimate`)                                       | Replace with (new `flixel-animate`)                                  |
| ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| `sprite.anim.curInstance`                                        | `sprite.isAnimate` *(bool: "is currently playing a texture atlas")*   |
| `sprite.anim.curSymbol`                                          | `sprite.library` / `sprite.timeline` *(or `sprite.anim.curAnim`)*     |
| `sprite.anim.curInstance.symbol.name`                            | `sprite.anim.name` *(name passed to the last `play()`)*               |
| `sprite.anim.length`                                             | `sprite.anim.curAnim.numFrames` *(per-animation frame count)*         |
| `sprite.anim.curFrame` *(controller-level, animation-relative)*  | `sprite.anim.curAnim.curFrame` *(guard `curAnim != null`)*            |
| `sprite.anim.curFrame = N`                                       | `sprite.anim.curAnim.curFrame = N` *(guard `curAnim != null`)*        |
| `sprite.anim.isPlaying`                                          | `!sprite.anim.paused` *(or check `sprite.anim.finished`)*             |
| `sprite.anim.onComplete` *(FlxSignal)*                           | `sprite.anim.onFinish` *(FlxTypedSignal<(name:String)\->Void>)*       |
| `sprite.anim.animsMap` *(internal map, used with `@:privateAccess`)* | `sprite.anim.remove(name)` *(public method, no privateAccess needed)* |
| `sprite.anim.metadata`                                           | `sprite.library.frameRate` *(plus `sprite.timeline`)*                 |
| `sprite.pauseAnimation()`                                        | `sprite.anim.pause()`                                                 |
| `sprite.resumeAnimation()`                                       | `sprite.anim.resume()`                                                |
| `sprite.showPivot = false;`                                      | **removed** — no longer drawn, delete the line                        |
| `sprite.loadAtlasEx(img, json, anim)` *(Psych subclass)*         | `Paths.loadAnimateAtlas(sprite, folder)` *or* `sprite.frames = FlxAnimateFrames.fromAnimate(...)` |
| `sprite.anim.addBySymbol(name, sym, fps, loop, matX, matY)`      | `sprite.anim.addBySymbol(name, sym, fps, loop, flipX, flipY)` *(matX/matY dropped)* |
| `sprite.anim.addBySymbolIndices(..., matX, matY)`                | same minus `matX, matY`                                               |

Unchanged: `sprite.anim.play(name, force, reverse, frame)`,
`sprite.anim.finished`, `sprite.anim.paused`, `sprite.anim.name`,
`Paths.loadAnimateAtlas(sprite, folder)`.

> **Note on `onFinish` callback signature.** The old `onComplete` listener
> took no arguments. The new `onFinish` dispatches the *animation name*
> as a single `String` parameter. If your old listener was
> `function() { ... }`, change it to `function(name:String) { ... }`
> (or `_ -> ...`). The same applies to `signal.has(listener)` /
> `signal.remove(listener)` — they only match by reference, so the listener
> stored must already have the new signature.

### HScript example

```haxe
// 1.0.4
import flxanimate.FlxAnimate;

var atlas = new FlxAnimate(100, 100);
atlas.showPivot = false;
Paths.loadAnimateAtlas(atlas, 'cutscenes/myAtlas');
atlas.anim.addBySymbol('idle', 'My Symbol', 24, true);
atlas.anim.onComplete.add(function() trace('done'));
atlas.anim.play('idle', true);

function onUpdate(elapsed:Float) {
    if (atlas.anim.curInstance != null && atlas.anim.curSymbol != null) {
        // ...
    }
    if (someCondition) atlas.pauseAnimation();
    else atlas.resumeAnimation();
}
```

```haxe
// 1.1
// `FlxAnimate` is pre-imported by HScript; no `import` line needed.
var atlas = new FlxAnimate(100, 100);
Paths.loadAnimateAtlas(atlas, 'cutscenes/myAtlas');
atlas.anim.addBySymbol('idle', 'My Symbol', 24, true);
atlas.anim.onFinish.add(function(name:String) trace('done: ' + name));
atlas.anim.play('idle', true);

function onUpdate(elapsed:Float) {
    if (atlas.isAnimate) {
        // ...
    }
    atlas.anim.paused = someCondition; // or atlas.anim.pause()/resume()
}
```

### Lua bindings

All Lua callbacks keep their names. Two of them dropped trailing
parameters that the new library no longer supports:

| Callback                          | 1.0.4 signature                                                                | 1.1 signature                                                            |
| --------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `makeFlxAnimateSprite`            | `(tag, x, y, loadFolder)`                                                      | unchanged                                                                |
| `loadAnimateAtlas`                | `(tag, folderOrImg, spriteJson, animationJson)`                                | unchanged                                                                |
| `addAnimationBySymbol`            | `(tag, name, symbol, framerate, loop, matX, matY)`                             | `(tag, name, symbol, framerate, loop)` — *`matX`/`matY` ignored*         |
| `addAnimationBySymbolIndices`     | `(tag, name, symbol, indices, framerate, loop, matX, matY)`                    | `(tag, name, symbol, indices, framerate, loop)` — *`matX`/`matY` ignored* |

Lua scripts that pass `matX` / `matY` continue to load without errors
(the extra arguments are silently dropped by the Haxe callback dispatcher),
but the offsets will no longer apply. If you relied on them, apply the
offset by adjusting `sprite.x` / `sprite.y` instead.

### `Paths.loadAnimateAtlas` behavior

The helper is still the recommended entry point and its signature is
unchanged:

```haxe
Paths.loadAnimateAtlas(spr, folderOrImg, spriteJson = null, animationJson = null);
```

Internally it now:

1. Reads `images/<folder>/Animation.json` through Psych's mod-aware path
   resolver.
2. Picks up an optional `images/<folder>/metadata.json` if present (newer
   Animate exports ship one).
3. Walks `spritemap0.json` → `spritemap9.json` and pairs each with its
   matching `spritemap<N>.png`, supporting multi-page atlases out of the
   box.
4. Hands everything to `animate.FlxAnimateFrames.fromAnimate(...)` so the
   sprite gets a normal `FlxAtlasFrames` collection on its `.frames`
   property — no more custom subclass required.

If you previously called `spr.loadAtlasEx(...)` directly, switch the
call to `Paths.loadAnimateAtlas(spr, folder)` (or build a
`FlxAnimateFrames.fromAnimate(...)` call yourself with the JSON content
and spritemap inputs).

---


## Need help?

If your mod relied on something not covered here, open an issue report and we will either document the migration step or add a compatibility shim where it makes sense.
