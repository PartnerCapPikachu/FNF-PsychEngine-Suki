# Release Notes -- Psych Engine "Continued" v1.1

A continuation of Psych Engine, picking up where the
archived upstream repo left off (last commit: March 24, 2025).

This release rolls in **147 commits** of fixes, modernization, and quality-of-life
work on top of the archived.

The goal of this fork is mostly maintenance and compability with newer libraries.
If something breaks existing mods, then it's not a welcome change.

New features may be added in the future.

Feel free to fork this fork and build upon it for your own mods or forks.

---

## Highlights

- **Engine version: 1.1** (up from 1.0.4)
- **Newer libs** -- upgraded to current HaxeFlixel 6, OpenFL 9.5,
  and Lime 8.3.
- **Build "just works" again** -- the install scripts have been completely
  rewritten so a fresh checkout builds cleanly on Windows, Linux, and macOS
  without hunting down compatible library versions.
- **New: ModSecurity** -- Psych will now scan mod scripts for risky behaviour
  and ask you whether to trust each mod before running it.
- **80+ bug fixes**, including a number of long-standing crashes and freezes.
- **30+ performance improvements**, especially around input handling, the
  scripting layer, and gameplay hot paths.

---

## What's new

### ModSecurity Module

Loading mods from people has so far has not caused any major incident motivated by malicious intent afaik. 
But now with AI coding agents being better it's extremely easy to make a lua script that can execute external commands and install backdoors on your system, simply by loading a song from a FNF mod. 

I confirmed this myself by creating a lua script that passed batch and powershell syntax, even as far as overriding admin prompts and installing scripts that let me gain full access to the entire system, giving me free reign to execute malicious code remotely on the target system.

Easiest solution is obviously to strip access to several of the os sys commands, but I also know there are indeed FNF mods that use these for trolling purposes, so I figured this module is the best compromise I can do.

ModSecurity adds a layer of protection:
- The first time you enable a mod, Psych scans its Lua and HScript files for
  potentially dangerous calls (process control, environment access,
  reflection tampering, dynamic Haxe execution, etc.).
- You get a clear prompt: **Trust** the mod, or **Block** its scripts.
- Your decision is remembered, and unchanged scripts are not re-scanned on
  subsequent launches.
- A new **SEC** button in the Mods menu lets you review or change your
  decision at any time.
- Scripts can't reach in and tamper with the security layer itself.

### Engine modernization

| Component       | Old                | New        |
| --------------- | ------------------ | ---------- |
| HaxeFlixel      | 5.6.1              | **6.1.2**  |
| flixel-addons   | 3.2.2              | **4.0.1**  |
| OpenFL          | 9.3.3              | **9.5.2**  |
| Lime            | 8.1.2              | **8.3.2**  |
| Discord RPC     | 1.2.4              | **1.3.0**  |
| VLC backend     | 2.0.1              | **2.2.6**  |
| LuaJIT bindings | `linc_luajit`      | **`hxluajit` + `hxluajit-wrapper`** (LuaJIT now links statically) |

### Build & install overhaul

- The `setup/windows.bat` and `setup/unix.sh` scripts now install everything
  with pinned, known-good versions and do not require any external dependency
  manager.
- On Windows the engine installs its dependencies into a **project-local
  `.haxelib/` folder**, so building Psych will no longer interfere with any
  other Haxe project you have on your machine.
- The setup builds `hxcpp` from source to dodge a broken release version that
  was preventing native compilation.
- A small patch is applied to one of the audio-visualizer dependencies so it
  works with the current audio library.

---

## Bug fixes

The fork closes out a backlog of crashes, freezes, and small gameplay bugs.
A non-exhaustive tour:

### Crashes & freezese.
- Several null-pointer crashes fixed across the dialogue system, cutscenes,
  the credits screen, the mods menu, the note offset menu, the options menu,
  the music player, and various stage / character code paths.
- Fixed an infinite freeze when a note's group member was null.
- Fixed an infinite loop in the dialogue box on malformed dialogue entries.
- Fixed a stack-overflow crash on hitsound volume lookups.
- Loading screen no longer crashes when a character JSON is missing -- it
  just skips the preload.
- Achievements menu no longer crashes when viewing non-score achievements, rare but did happen.

### Gameplay
- Per-song saved difficulty in Freeplay is now actually restored.
- Note clip-rect handling fixed for animated note skins.
- Health icon scaling fixed for tall or square icon graphics.
- Fixed a long-standing bug where note-type config files with errors would
  silently fall through and break gameplay.

### Editors
- Stage and Character editors now validate animation indices instead of
  throwing.
- Week Editor accepts pasted hex colors with stray characters.
- Text input fields handle Ctrl+C / Ctrl+X correctly when the selection
  starts at position 0.
- Numeric stepper fields no longer let stray minus signs slip through.

### Lua / HScript modding
- `setSoundPitch` and `setSoundVolume` now correctly target the music when
  called with an empty tag.
- Tween storage uses a canonical key so `cancelTween` reliably works.
- Lua error messages are now read from the correct stack slot (you'll
  actually see the real error).
- `getBool` accepts real Lua booleans (not just stringified ones).
- HScript runtime catches a wider class of script errors instead of
  bringing the entire game down with it.
- Animation-by-indices helpers now reject malformed index strings instead of
  crashing.

### Misc UI
- Main menu detects mouse motion on either axis (not just X).
---

## Performance
- Faster, lower-allocation input handling -- keypress checks no longer
  allocate arrays every frame.
- BPM-map lookups short-circuit once they pass the target time.
- Lua → Haxe callback dispatch reuses its argument buffer.
- Score popups now properly pool their sprites instead of allocating on every hit.
- Hitsounds are precached once per song instead of per note.
- `Highscore` lookups no longer flush the save file on every read.
- Mod list parsing is cached per state.
- Various hot-path text formatting helpers hoist their regexes to static.
- FPS counter is now much cheaper to draw.

---

## Notes for modders & developers

- Mods that previously relied on script behaviour that ModSecurity flags as
  dangerous will trigger a Trust prompt the first time they're enabled. End
  users can still allow them -- nothing is hard-blocked.
- The HaxeFlixel 5 → 6 jump and OpenFL 9.3 → 9.5 jump may surface minor
  source-script differences if your mod calls into the engine's Haxe API
  directly (Lua / HScript surface is unchanged).
- `Project.xml` no longer pins library versions in its `<haxelib>` tags --
  the active `.haxelib/` repo decides. Use the provided setup scripts to get
  a known-good environment.
- The bundled `Project.xml` injects a compile-time macro
  (`macros.PatchIris.patch()`) when `MODS_ALLOWED` is defined; this is what
  routes script class lookups through ModSecurity. Don't remove it if you
  want mod sandboxing to work.

---

## Credits

- Original Psych Engine by **ShadowMario** and contributors. This fork
  continues from upstream commit
  [`5c67ced`](https://github.com/ShadowMario/FNF-PsychEngine/commit/5c67ced49e5a98535298a6daa3f8f4ec79ac8399).
- For a full technical changelog (every commit, every file, every dependency
  diff), see [FORK_CHANGES.md](FORK_CHANGES.md).
