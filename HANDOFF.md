# RS_Holsters — Handoff / Extension Guide

For whoever (including future-me) picks this system up to extend it. Not a
user-facing doc — see README.md for that. This one assumes you're about to
edit code.

## Architecture, in one picture

`RS_HolsterManager` (EventHandler, `RS_Holsters.zs`) is the only stateful
owner. It runs the whole loop every tic: calibrate → body yaw → grabs →
claims → props. `GetHolster(idx, ...)` is the compile-time table of all 8
anchor definitions (position, radius, base orientation) — a switch, not an
array of structs, because ZScript dynamic arrays only accept integral/object
types. Everything else (`edFwd`/`edSide`/`edFrac`/`edPitch`/`edYaw`/`edRoll`)
is the LIVE, tunable copy of that table, seeded from it once and then
overwritten by Edit Mode dragging or a loaded JSON profile.

Two visible actor classes, both in `RS_HolsterProp.zs`:
- `RS_HolsterMarker` (+ `_Blue`/`_Red`/`_Gold`/`_Purple` subclasses) — the
  always-present ring/reticle at every holster.
- `RS_HolsterProp` — the stored weapon's model, invisible when the holster
  is empty.

Both are parked at the anchor and repositioned every tic from
`RS_HolsterManager.updateProps` (not parented — the anchor moves with the
player's head every frame, and there is nothing to parent to). Both fade
in/out on visibility change rather than hard-cutting `bINVISIBLE`.

The system does not exist without engine support. `HolsterClaimMain/Off` are
engine-owned fields the native grip arbiter (`vk_openxrdevice.cpp`) reads
every frame to decide whether a hand's grip button means "holster" this
frame — this mod SETS those fields (`updateClaims`), the ENGINE reads them
to redirect grip input. If that field ever stops existing or stops being
read, grip silently reverts to its non-holster meaning everywhere, with no
error.

## The engine dependency — read this before touching anything

RS_Holsters is built on native fields/functions added to the UZDXREMA
engine fork (`E:\UZDXREMA`). None of this exists in stock GZDoom or in a
different DoomXR build. If you're extending this mod and find yourself
wanting a new piece of engine-level data or behavior, it probably needs a
new native, not a script workaround.

**Fields on AActor** (`src/playsim/actor.h` + ZScript decl in
`wadsrc/static/zscript/actors/actor.zs` + binding in
`src/scripting/vmthunks_actors.cpp`):
- `HmdPos` (DVector3), `HmdYaw/HmdPitch/HmdRoll` (DAngle) — head pose
- `VRTurnYaw` (double) — mirrors the engine's internal snap-turn
  accumulator; this is what body yaw tracks the DELTA of, not raw HmdYaw,
  which is what fixed the snap-turn drift bug
- `HolsterClaimMain/Off` (bool) — script writes, engine's grip arbiter reads
- `GripContextMain/Off` (int) — published by the arbiter for diagnostics

**Functions on FLevelLocals** (`src/scripting/vmthunks.cpp` + ZScript decl
in `wadsrc/static/zscript/doombase.zs`):
- `VRHaptic(hand, intensity, durationMs)` — pre-existing, hand 0=main 1=off
- `GetModelOrientationHint(cls, sprite, frame)` → found, mirrored,
  angleoffset, pitchoffset, rolloffset — measures a weapon's baked MODELDEF
  rotation quirks instead of guessing them
- `GetModelOffsetHint(cls, sprite, frame, pixelstretch)` → found, x, y, z —
  the model's baked local position offset
- `GetModelWorldOffset(cls, sprite, frame, pixelstretch, angle, pitch,
  roll, scaleX, scaleY)` → found, dx, dy, dz — replays RenderModel's actual
  rotation AND scale math to give the true world-space correction. Do NOT
  hand-derive this kind of thing again; it took three wrong attempts before
  landing on "just replay the engine's own matrix" (see Lessons below).
- `JSONProfileBegin/SetDouble/GetDouble/Save(name)/Load(name)` — the only
  file I/O ZScript has. Flat key→double documents only; see the big comment
  block above these in vmthunks.cpp for the full protocol and the name
  sanitization rules.

**Engine build**: `E:\UZDXREMA\build-dxr\DoomXR.slnx`, MSBuild,
`Configuration=RelWithDebInfo /Platform=x64`. Output lands directly at
`E:\UZDXREMA\build-dxr\RelWithDebInfo\doomxr.exe` + `doomxr.pk3` — that IS
the launch location, no separate copy step for the engine itself.

## Build & deploy checklist (mod side)

- `RS_Holsters`: run `E:\RS_Holsters\build.ps1`. It always deletes the old
  zip first — `7z a` on an EXISTING archive only adds/updates, never
  removes entries whose source file is gone. `RS_Holsters.zip` sitting at
  the repo root IS the load path; nothing else to copy.
- `RS_Main`: no build script. Manual: delete `RS_Main.zip`, then
  `7z a -tzip -mx=1 RS_Main.zip . -r -xr!.git -x!.gitattributes
  -x!.gitignore -x!RS_Main.zip -xr!.claude`. Deploy by copying to
  `D:\SteamLibrary\steamapps\common\DooM VR\__CurrentRotationDONOTDELETE\RS_MAIN.pk3`.
- **After EVERY pk3 rebuild, before trusting it**: `7z l <pk3> | grep -i
  <lumpname>` for MODELDEF, KEYCONF, CVARINFO, SNDINFO — must show EXACTLY
  ONE entry each. GZDoom builds a lump's short name by stripping the
  extension, so a stray `.bak`/`.bak2`/`.old` file anywhere in the tree
  registers under the SAME short name as the real lump and can silently
  win the lookup. This actually happened once this session and cost a full
  debugging cycle — a backup file created BY a fix script shadowed the fix
  it was supposed to ship.

## Hard-won lessons (read before you hit these again)

**MODELDEF**: `USEACTORPITCH`/`USEACTORROLL`/`Rotating` and friends MUST
appear BEFORE the `FrameIndex` lines in a `Model` block. Each `FrameIndex`
immediately pushes a snapshot of the flags-so-far into the render table
(`r_data/models.cpp:1204`) — flags written after the last `FrameIndex`
parse cleanly and apply to nothing.

**RenderModel's offset math**: the model's baked Offset gets multiplied by
the ACTOR's own Scale (not just the MODELDEF's own xscale, which cancels
out) — because the offset `translate()` happens after the `scale()` call in
source order, and later calls apply to raw vertices FIRST. Also: the
`stretch`/pixelstretch variable used in that same translate is 1.0 unless
`MDL_CORRECTPIXELSTRETCH` is explicitly set on that block (nothing in this
MODELDEF sets it) — do not divide by pixelstretch there.

**`+FORCEXYBILLBOARD`** only affects the sprite rendering pipeline
(`hw_sprites.cpp`). `RenderModel` never looks at it. Once `A_ChangeModel`
binds a real model, that flag is inert — full angle/pitch/roll control is
available, unconstrained by billboarding.

**`FindModelFrameRaw` matches by EXACT class pointer** — a subclass does
NOT inherit its parent's MODELDEF binding. This is why the marker color
subclasses work at all: `SetHot()`'s `A_ChangeModel` call hardcodes the
PARENT class's literal name as the `modeldef` argument, regardless of which
subclass the actual instance is, redirecting model lookup to the one block
that exists no matter which color got spawned.

**ZScript language limits found by hitting them** (none of these have any
precedent anywhere in this codebase, so don't reintroduce them without
verifying first — there is no way to test-compile from here):
- `const` is a CLASS-level declaration only. A `const X = ...;` inside a
  method body is not something this codebase does anywhere, and it may not
  even parse.
- No confirmed `Min()`/`Clamp()` builtin (`Max()` is real and used in
  stock wadsrc). Write comparisons by hand.
- No confirmed `double(x)`-style cast-as-function-call. To force int→double
  promotion, multiply by a double literal (`x * 1.0`) instead — that's
  ordinary operator promotion, not a cast, and every C-family language
  agrees on it.
- No field initializers (`private int x = 5;`). Rely on the zero-default
  and set explicitly before first use.
- `Actor.Spawn` takes `class<Actor>`, not a string/name — a literal string
  auto-resolves at compile time in that context, but a runtime `string`
  variable will not. Where a runtime-selected class was needed (marker
  color), the pattern is a function returning `class<Actor>` with each
  `case` returning its own literal — resolved per-literal at compile time,
  no runtime cast involved.

**Store/draw**: `player.PendingWeapon` is ONE field shared by both hands —
anything that lets one hand's switch overwrite it while the other hand's is
still resolving will misdeliver a weapon. Every weapon here carries
`+WEAPON.NOHANDSWITCH`, so `MoveWeaponToHand` SILENTLY no-ops on a hand
mismatch (check `weap.bOffhandWeapon` yourself before calling it, don't
trust it to fail loudly). The engine's own `CheckWeaponSwitch` can re-arm a
holstered weapon on any ammo pickup, since holstering never removes it from
inventory — `bNoAutoSwitchTo` is what stops that.

## Where to extend things

- **A 9th/10th holster**: bump `HOLSTER_COUNT`, add a `GetHolster` case,
  extend `activeCount()`'s snap-to-tier logic, extend the
  `RS_HolsterActiveCount` `OptionValue` block in MENUDEF.
- **A new marker shape**: author a new unit-radius `.obj` (corner/feature
  distance from origin = 1.0, so MODELDEF's existing `Scale 3.0 3.0 3.0`
  keeps mapping correctly) — see
  `E:\Tools\...\Generate-BracketReticle.ps1`-style generator scripts rather
  than hand-typing vertex/face lines. Add a shape enum value, extend
  `SetHot()`'s `modelWanted` selection.
- **A new marker color**: add a subclass with its own `Translation "0:255=
  %[...]:[...]"` (desaturate-then-tint syntax, see RS_Main's
  `RS_Archvile.zs` for more examples), extend
  `holsterMarkerColorClass()`'s switch.
- **Per-holster sound identity**: `doSwap`'s sound choice is currently one
  global pick (`rs_holster_sound_style`). Per-holster identity would mean
  threading a sound name through `GetHolster`'s table instead.
- **Forearm/wrist hardpoints** (discussed, not started): explicitly a
  bigger scope than holsters — grenades/rockets need real aim-and-throw
  mechanics on top of store/swap, not just two more anchor points. Scope
  this properly before starting rather than treating it as "two more
  holsters."

## Open / not done

- Seated and standing profiles exist as a system (save/load/switch, all
  working) but have not actually been tuned and saved yet — currently
  tabled by the owner, not blocked on anything.
- Centering is "close enough" per the owner but was never chased to a
  literal 0.00 drift for every weapon in the arsenal, only spot-checked on
  a couple.
