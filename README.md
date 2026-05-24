# RE9VR Simple Haptics

bHaptics support for RE9VR, inspired by RE9VR Immersion Enhancer mod by charlotteliuok.

The haptics code lives in `zz_re9vr_simple_haptics.lua`. It does not overwrite or patch RE9VR files; install is just copying this package's `reframework` from a release zip into the game directory.

## What it adds

- bHaptics TactSuit feedback for weapon fire, holster changes, melee, throwable use, healing, damage, electric damage, death, camera shake, item pickup, parry, block impact, bike mode, and startup confirmation.
- TactSleeve feedback for right-hand weapon/melee/dry-fire/throw/syringe effects and left-hand reload/block/healing effects.
- Manual reload stage feedback by observing RE9VR's weapon sound trigger IDs, including mag grab, insert, drop, rack back, rack forward, dry fire, and barrel close.
- A bundled REFramework bHaptics direct bridge for sending effects to bHaptics Player.
- `tools\preview_haptics.py`, a companion console app that lists and previews every effect used by the game mod.
- Editable `.tact` files for every effect. The mod registers `.tact` effects with bHaptics Player after the game start and then invokes the effects when appropriate.

## Install

1. Install Talemann's RE9VR mod first and make sure it works.
2. Download the release zip if you want an install-ready package with `bhaptics_bridge2.dll` already included. A source checkout does not include the compiled DLL; build it first if you are installing from source.
3. Copy this mod's `reframework` folder into the game folder and let Windows merge folders. Overwrite files if Windows asks.

This is the default game directory:
   ```text
   C:\Program Files (x86)\Steam\steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem
   ```

   If your game is installed somewhere else, copy the folder into that game directory instead.

4. Start bHaptics Player and turn on your TactSuit and optionally TactSleeves if you want haptics for this session. The game can still launch without bHaptics Player running; this mod will retry the bridge periodically.
5. Start the game. You should feel a haptic effect as the game is loading. Play.

## Troubleshooting

Oen the REFramework menu in the game. `RE9VR Simple Haptics` should appear in Script Generated UI.

When working correctly, it should show:

```text
Bridge: lua_bridge
```

Use `Preview revolver shot` and `Preview healing` buttons at the bottom of Script Generated UI menu to quickly confirm that haptics are working.

## How to preview effects without running the game

Launch the included console app:

```powershell
py .\tools\preview_haptics.py
```

The app prints the list of haptic effects and allows you to preview them by pressing digits and letters.

The preview app uses the same playback path as the game: it registers the selected `.tact` project with bHaptics Player, then plays it by submitting the registered effect key.

Press the shown shortcut to play an effect. Press `?` to reprint the reference table, or press `q`, `Esc`, or `Ctrl-C` to exit. bHaptics Player must be running for preview playback, of course. `q` is reserved for quitting.

## Project structure

The mod files are:

- `reframework\autorun\zz_re9vr_simple_haptics.lua`
- `reframework\plugins\bhaptics_bridge2.dll` in release zips, or after you build from source
- `reframework\data\bhaptics\*.tact`
- `reframework\data\bhaptics\re9vr_simple_haptics_effects.json`

## Building the DLL

Release zips include a prebuilt `bhaptics_bridge2.dll`; source checkouts only contain the source. If you cloned the source repo or want to change the native bridge, rebuild it from the mod root with:

```powershell
.\native\bhaptics_bridge2\build.ps1
```

Requirements:

- Visual Studio C++ build tools with the x64 MSVC toolchain.
- `git` available on `PATH`, because the build script sparse-clones REFramework headers and Lua sources into `native\bhaptics_bridge2\.deps\REFramework`.

The build script compiles the bridge and bundled Lua C sources, links against `winhttp.lib`, and writes:

```text
reframework\plugins\bhaptics_bridge2.dll
```

It also creates temporary build output under `native\bhaptics_bridge2\build`, `native\bhaptics_bridge2\.deps`, and linker side files such as `.lib`/`.exp`. Those are build artifacts and should not be committed. After rebuilding, copy this package's `reframework` folder into the game directory again.

## How the DLL works

`bhaptics_bridge2.dll` is a REFramework native plugin. When REFramework creates the Lua state, the DLL publishes one bridge table under two compatible global names: `BhapticsBridge` and `bhaptics_bridge` (trying to preserve compatibility with the original DLL from RE9VR Immersion Enhancer 2.1.3).

The Lua script calls that bridge directly:

- `ensure_connected()` opens a websocket to bHaptics Player at `127.0.0.1:15881`.
- `register_project(key, project_json)` registers the raw `.tact` `project` JSON with Player.
- `submit_registered(key)` plays a registered effect by key.

The normal runtime path is registered-key playback: Lua reads each `.tact`, extracts the raw `project` object, and registers every effect up front. After registration finishes, the script waits briefly before the automatic startup pulse. Later gameplay effects do not check or repeat registration; they only submit the registered key.

If bHaptics Player is not running, the mod backs off after 3 failed connection attempts and then retries no more than once every 15 seconds until a connection succeeds. The game should still start and run normally.

The DLL does not mirror the controller vibration.

On game exit it does not perform a graceful websocket close from `DllMain`, because that can sometimes stall process shutdown.

## Effect reference

| Shortcut | Effect | Hook / trigger details | Expected feel |
| --- | --- | --- | --- |
| `0` | `RE9_SH_Startup.tact` | First `re.on_frame` after effects are loaded and the bridge can play. | Short confirmation pulse on back and both sleeves, then front vest. |
| `1` | `RE9_SH_Pistol_Right.tact` | Post-hook on `app.PlayerEquipment.execFire`; selected for handgun, revolver, or default weapon ids. | Compact right-sleeve trigger/recoil with right chest/back kick. |
| `2` | `RE9_SH_Auto_Right.tact` | Same `execFire` hook; selected for SMG/automatic weapon ids. | Fast right-sleeve tick with light right torso recoil. |
| `3` | `RE9_SH_Shotgun_Right.tact` | Same `execFire` hook; selected for shotgun or magnum ids, ignored while `__vr_pump_fire_blocked` is true. | Heavy right forearm and shoulder blast with a short aftershock. |
| `4` | `RE9_SH_Rifle_Right.tact` | Same `execFire` hook; selected for rifle/launcher ids. | Long-gun kick through right arm and shoulder, with support-sleeve/body follow-through. |
| `5` | `RE9_SH_Melee_Swing_R.tact` | Wraps RE9VR's `re9_vr_trigger_melee_swing_haptic`; also watches the `vr_axe_swing` edge. | Right-arm sweep with a light torso brush. |
| `6` | `RE9_SH_Melee_Hit_R.tact` | Wraps RE9VR's `re9_vr_trigger_melee_hit_haptic`. | Hard right-arm impact that lands into the vest. |
| `7` | `RE9_SH_Grenade.tact` | `execFire` hook selected for throwable weapon ids. | Left chest and sleeve handling pulse. |
| `8` | `RE9_SH_Holster_Hip.tact` | Per-frame weapon-id change while `__vr_in_holster_zone` is active; chosen for pistols/default weapons. | Right hip locator pulse moving through right torso/forearm. |
| `9` | `RE9_SH_Holster_Shoulder.tact` | Same holster watcher; chosen for shotguns, automatics, and rifles. | Right shoulder draw/stow sweep with back/front vest emphasis. |
| `a` | `RE9_SH_Holster_Chest.tact` | Same holster watcher; chosen for magnums and throwables. | Left chest slot pulse with a small left-sleeve accent. |
| `b` | `RE9_SH_Heal.tact` | Hooks `app.HitPoint` recovery/set-current-HP methods and plays when HP rises past a threshold; also used by `syringe_success` external event. | Healing pulse starts on left sleeve and spreads into the torso. |
| `c` | `RE9_SH_Player_Damage.tact` | Hook on `app.PlayerAttackDamageDriver.onDamageCalc`; used for normal damage when block/electric conditions do not apply. | Broad torso hit with both-sleeve shock. |
| `d` | `RE9_SH_Electric_Damage.tact` | Same damage hook; selected when attack attribute is electric (`8`). | Alternating torso and sleeve crackle. |
| `e` | `RE9_SH_Player_Death.tact` | Hook on `app.PlayerUpdaterBase.onDead`. | Long fading collapse pulse across torso and sleeves. |
| `f` | `RE9_SH_Camera_Shake.tact` | Hook on `app.CameraShakeController.request`. | Short environmental thump on the torso. |
| `g` | `RE9_SH_Add_Item.tact` | Post-hook on `app.Inventory.mergeOrAdd(...)`. | Small pickup confirmation on chest and sleeve. |
| `h` | `RE9_SH_Reload_Mag_Grab.tact` | Hook on `soundlib.SoundContainer.trigger(System.UInt32)`; mapped reload grab sound ids, gated to left-hand manual reload context. | Left sleeve and pouch tap for grabbing ammo, shell, or bullet. |
| `i` | `RE9_SH_Reload_Mag_Insert.tact` | Same sound hook; mapped insert ids, gated to active/recent reload context. | Firm left-hand insert click into the weapon. |
| `j` | `RE9_SH_Reload_Mag_Drop.tact` | Same sound hook; mapped magazine/shell drop ids, gated to active/recent reload context. | Low release pulse for dropped magazine, shell, or bullet. |
| `k` | `RE9_SH_Reload_Rack_Back.tact` | Same sound hook; mapped slide/bolt/pump-back ids. | Left support sleeve pulls backward from wrist toward forearm. |
| `l` | `RE9_SH_Reload_Rack_Forward.tact` | Same sound hook; mapped slide/bolt/pump-forward ids. | Left support sleeve snaps forward into lock. |
| `m` | `RE9_SH_Dry_Fire_Right.tact` | Same sound hook; mapped dry-fire sound id. | Tiny right-sleeve trigger click. |
| `n` | `RE9_SH_Barrel_Close.tact` | Same sound hook; mapped revolver cylinder/break-action close ids. | Short right-sleeve latch click. |
| `o` | `RE9_SH_Throwable_Equip.tact` | Per-frame current-weapon watcher; fires when entering a throwable weapon id outside holster-zone changes. | Chest slot and sleeve pulse as throwable is equipped. |
| `p` | `RE9_SH_Throwable_Release.tact` | Hook on `app.PlayerMelee.createShell`. | Throwing-arm sweep through right sleeve with torso release. |
| `y` | `RE9_SH_Block_Stance.tact` | Per-frame edge from `__vr_bhaptics_block_pose_active`, or short window after wrapped `vigem.set_button("LB", pressed)` for parry-capable weapons. | Subtle left forearm brace cue. |
| `r` | `RE9_SH_Block_Impact.tact` | Damage hook selects this when block pose is active during `onDamageCalc`. | Forearm shield impact into front torso. |
| `s` | `RE9_SH_Parry_Success.tact` | Hook on `app.PlayerAttackDamageDriver.onParrySuccess`. | Sharp successful parry snap across forearm and vest. |
| `t` | `RE9_SH_Syringe_Ready.tact` | Optional external event: `_G.re9_vr_trigger_bhaptics_event("syringe_ready")`. | Right-sleeve confirmation that manual syringe is armed. |
| `u` | `RE9_SH_Syringe_Zone.tact` | Optional external event: `_G.re9_vr_trigger_bhaptics_event("syringe_zone")`. | Small right-sleeve alignment cue for valid injection position. |
| `v` | `RE9_SH_Syringe_Fail.tact` | Optional external event: `_G.re9_vr_trigger_bhaptics_event("syringe_fail")`. | Low right-sleeve buzz for failed syringe use/no stock. |
| `w` | `RE9_SH_Bike_Start.tact` | Per-frame edge when `__vr_bike_fp_active` becomes true. | Low torso and sleeve pulse as bike mode starts. |
| `x` | `RE9_SH_Bike_Rumble.tact` | Per-frame bike watcher repeats while `__vr_bike_fp_active` remains true. | Short low torso engine rumble tick. |

External scripts can trigger any mapped event with `_G.re9_vr_trigger_bhaptics_event(name, data)`. The copy-only install detects heal success from HP recovery, but RE9VR does not expose syringe ready, injection-zone, or fail state outside its healing script, so those syringe effects are preview/external-event only unless another script calls the event API.

## Development

There are two supported effect-authoring workflows. At the moment, the checked-in `.tact` files are derivative assets: they were generated from the effect definitions in `tools\generate_effects.py`.

The default workflow is to edit `tools\generate_effects.py` first. Change effect timing, motor points, intensity, cooldowns, descriptions, preview shortcuts, or add/remove effects there, then regenerate `.tact` files and `re9vr_simple_haptics_effects.json` manifest:

```powershell
py .\tools\generate_effects.py --write-tact
```

That overwrites all generated `.tact` files and rewrites `re9vr_simple_haptics_effects.json` from the Python definitions. Use this when the Python file is the source of truth.

The alternative workflow is to edit `.tact` files directly in bHaptics Designer, or replace them with `.tact` files from another source. If you keep the same filenames, the runtime will register and play those `.tact` files directly. If you also change manifest details in `tools\generate_effects.py` such as tact filenames, trigger descriptions, preview shortcuts, cooldowns, or the effect list, refresh metadata while preserving existing `.tact` files:

```powershell
py .\tools\generate_effects.py
```

This rewrites `re9vr_simple_haptics_effects.json` without overwriting existing `.tact` files. The metadata records effect keys, tact filenames, trigger descriptions, preview shortcuts, and cooldowns. After changing `.tact` files, restart the game or reload REFramework scripts so effects are loaded again.
