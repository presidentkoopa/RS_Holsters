# Holsters and Hardpoints — project context

Claude Code auto-loads this file for any session opened in this repo — that
is deliberate, not a rename of convenience. If you're a fresh agent reading
this cold: this is the handoff doc, written so you don't have to rediscover
any of it. Not a user-facing doc — see README.md for that.

## Working with the owner

- **No test-compile exists here.** Don't burn turns manually re-verifying
  ZScript syntax (brace counting, re-reading a whole file to eyeball it) —
  run the build and find out from a real load/headset error instead. Owner's
  own words: "if there are syntax errors we will find out on compile, i
  can't spare 500k tokens for it."
- **Don't bounce confirmations back as questions.** When the owner reports
  what they're seeing in headset (a position, an angle, "X is left of Y"),
  that's ground truth, not an invitation to ask "does that look right to
  you?" — take it as given and either act on it or move to the next thing.
  Asking them to re-confirm what they just told you reads as not listening,
  and it makes them angry. If there's a genuine fork in what to BUILD (e.g.
  which hand an anchor should track), that's worth asking about; whether an
  already-reported observation is "good" is not.
- Owner tests live in a headset mid-session and reports back in real time,
  including mid-turn while you're still working — expect rapid, informal,
  sometimes sharp corrections, and expect to revise a just-shipped design
  based on one screenshot. That's the normal workflow here, not a sign
  something went wrong.

**Rename history.** This mod started life as `RS_Holsters` (display title
"Holsters and Hardpoints" once the forearm/wrist feature landed), then got a
full internal rename to `RS_HardPoints` the same session, on direct owner
instruction. Renamed: ZScript class names (`RS_HardPointManager`,
`RS_HardPointProp`, `RS_HardPointMarker` + color subclasses), file names
(`RS_HardPoints.zs`, `RS_HardPointProp.zs`, via `git mv` to keep history),
every `rs_hardpoint_*` cvar and `rs-hardpoint-*` netevent, MENUDEF option
IDs, the KEYCONF key section, the MODELDEF class match, and the
`RS_HardPoints.zip` build/deploy filename. Verified afterward with a repo-wide
grep for zero remaining `RS_Holster`/`rs_holster_`/`rs-holster-` references
before committing.

**NOT renamed, on purpose:**
- **Bare internal identifiers without an `RS_`/`rs_`/`rs-` prefix** —
  `GetHolster()`, `HOLSTER_COUNT`, `holsterActive()`, `holsterPropScale()`
  and its siblings, `dumpOneHolsterProp()`, etc. — plus ordinary prose
  comments that just use "holster" as the English word for what these are.
  These are private, never referenced outside this pk3, and sweeping every
  one of them was judged not worth the added risk of touching yet more of
  an already heavily-modified file in the same pass. Free to rename later;
  flag if it should happen.
- **`HolsterClaimMain/Off` and `GripContextMain/Off`** (engine-native
  fields, `E:\UZDXREMA`) — these live in a SEPARATE repo (the engine fork,
  not this mod) and this mod only reads/writes them; renaming them means
  rebuilding the engine, out of scope here. This mod's own name changing
  does not require the native fields it consumes to match.
- **The repo's containing folder** (`E:\RS_Holsters` at the time of this
  rename). Claude Code's own shell stays anchored inside the project's
  working directory between every tool call, and Windows will not rename a
  directory that is any process's current working directory — so this had
  to be left for the owner to do by hand:
  `Rename-Item 'E:\RS_Holsters' 'E:\RS_HardPoints'`. If you are a fresh
  session reading this cold and the folder is still called `RS_Holsters`,
  that rename has not happened yet.
- **The GitHub remote** (`github.com/presidentkoopa/RS_Holsters`) — a
  separate, external, shared action (not just a local file edit), flagged
  to the owner rather than done unasked.

## Architecture, in one picture

`RS_HardPointManager` (EventHandler, `RS_HardPoints.zs`) is the only stateful
owner. It runs the whole loop every tic: calibrate → body yaw → grabs →
claims → props. `GetHolster(idx, ...)` is the compile-time table of all 14
anchor definitions (position, radius, base orientation) — a switch, not an
array of structs, because ZScript dynamic arrays only accept integral/object
types. Everything else (`edFwd`/`edSide`/`edFrac`/`edPitch`/`edYaw`/`edRoll`)
is the LIVE, tunable copy of that table, seeded from it once and then
overwritten by Edit Mode dragging or a loaded JSON profile.

Indices 0-7 are the original 8 torso holsters, anchored off `HmdPos`/
`bodyYaw`. Indices 8-13 (`HAND_HOLSTER_START`) are the forearm/wrist
hardpoints — `Forearm1/2/3`, `WristBelow/Knuckle/Joint` — and BOTH origin
and basis are always the OFF hand's own live pose (`OffhandPos/Angle/
Pitch/Roll`), unconditionally, via `handBasisPose`. It does not matter
which hand is holding a weapon or whether either hand is holding one at
all — this is the off-arm's own hardpoint rig, full stop, not something
that tracks a weapon.

REJECTED APPROACH, kept here so it doesn't get re-tried: a mid-session
version had Forearm1-3 track the MAIN hand's aim (`AttackAngle/Pitch/
Roll`) instead, on the theory that the off hand's own orientation would be
unreliably canted relative to "the gun's barrel direction" by gripping a
foregrip. In headset testing this changed nothing visible and the owner
explicitly rejected the whole premise — "it doesn't matter what hand i
have a gun in, just put three hardpoints on the offhand behind the
controller position." Reverted back to the off-hand-only basis described
above. If forearm placement still looks wrong in headset after a full game
restart (not just a rebuilt zip — the owner hit exactly this: a real code
change that appeared to do nothing, most likely a stale loaded pk3), look
for a sign/axis bug in `handAnchorPos`'s forward vector before reaching
for a different-hand theory again.

`isHandAnchored(idx)` is the one predicate everything branches on to tell
torso from hand-anchored; `handBasisPose(pawn, idx, ang, pit, rol)` is
where the off hand's pose is read for both. Consumers: `anchorPos`/
`handAnchorPos` for position, the `baseAngle/basePitch/baseRoll` split in
`updateProps` (and its diagnostic twin `dumpOneHolsterProp`) for
orientation, `worldToBody`/`worldToHand` for edit-mode dragging, and a
guard in `updateClaims` that stops the off hand from ever claiming its own
hand-anchored gear (the anchor is a fixed offset from that same hand's own
live pose, so the distance to it never changes no matter how the player
moves — it would otherwise be a permanent self-claim, not a proximity
test). Gated by a separate, default-OFF cvar
(`rs_hardpoint_arm_active_count`, 0/3/6) from the body holsters'
`rs_hardpoint_active_count` (2/4/6/8) — new, unproven anchor math shouldn't
silently change the grab surface of an already-tuned body setup.

Known v1 gap: the hand-anchored basis is built from the off hand's
yaw+pitch only, not roll (matching the existing local-basis convention
already used elsewhere in this file). The PROP/MARKER's orientation still
tracks live roll correctly; the ANCHOR POSITION does not swing around the
arm when the off hand rolls. Left unfixed deliberately rather than guessed
at blind — see Hard-won lessons below on why this file does
not hand-derive rotation math speculatively. Fix, if it reads as wrong in
headset: rotate `handAnchorPos`/`worldToHand`'s right/up vectors around
forward by the same roll `handBasisPose` already returns for that index
(Rodrigues rotation).

Two visible actor classes, both in `RS_HardPointProp.zs`:
- `RS_HardPointMarker` (+ `_Blue`/`_Red`/`_Gold`/`_Purple` subclasses) — the
  always-present ring/reticle at every holster.
- `RS_HardPointProp` — the stored weapon's model, invisible when the holster
  is empty.

Both are parked at the anchor and repositioned every tic from
`RS_HardPointManager.updateProps` (not parented — the anchor moves with the
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

RS_HardPoints is built on native fields/functions added to the UZDXREMA
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

- `RS_HardPoints`: run `E:\RS_HardPoints\build.ps1`. It always deletes the old
  zip first — `7z a` on an EXISTING archive only adds/updates, never
  removes entries whose source file is gone. `RS_HardPoints.zip` sitting at
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

- **A 9th/10th TORSO holster**: bump `HAND_HOLSTER_START` (not
  `HOLSTER_COUNT`) to make room below the hand-anchored range, add a
  `GetHolster` case, extend `activeCount()`'s snap-to-tier logic, extend the
  `RS_HardPointActiveCount` `OptionValue` block in MENUDEF. A 7th hand-anchored
  slot instead: bump `HOLSTER_COUNT`, add a case after 13, extend
  `armActiveCount()` and `RS_HardPointArmActiveCount`.
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
  global pick (`rs_hardpoint_sound_style`). Per-holster identity would mean
  threading a sound name through `GetHolster`'s table instead.
- **Mirror the arm rig to the main hand too**: currently off-hand-anchored
  only (indices 8-13 all read `Offhand*`). A main-hand-mounted rig would be
  a parallel `handAnchorPos`/`worldToHand` pair reading `Attack*` instead,
  plus its own index range and active-count tier — not a flag on the
  existing one, since the existing off-hand exclusion in `updateClaims`
  would need the mirrored logic (main hand excluded from claiming its own
  gear instead).

### Forearm/wrist hardpoints — status

The 6 physical anchors (indices 8-13, off-hand-anchored, plain store/draw)
are built — see the Architecture section above. Two layers were explicitly
scoped OUT of that pass and are still open:

- **Gesture-gated "cast in place" activation** (the wrist rig's real
  point): arm-extended + wrist-tilted-up pose detection, then a
  grip/trigger/face-button combo per slot fires whatever's stored there
  IN PLACE — no draw into the hand, more like RS_Main's `RS_GrenadeThrower`
  (hold-to-charge/release-to-throw, driven by a button, never puts its
  weapon in-hand) than like a holster. Needs real ability implementations
  on the RS_Main side before there's anything to dispatch to. Owner's
  reference pose for the wrist rig specifically: hand outstretched holding
  a pistol, pistol at the top of the hand, palm rotating up "like Dr.
  Strange" to arm it. Visual idea for the not-yet-armed state: small solid
  squares that expand once the hand rolls into the correct orientation
  (would key `RS_HardPointMarker`'s existing proximity-pulse mechanism off
  orientation-correctness instead of hand-distance).
- **Paged/scrollable forearm inventory**: instead of each Forearm slot
  holding one fixed item, treat it as a row you can cycle through (for
  mods with expansive inventory lists), with a "card" visual that fades
  out as it activates into the held item. A real data/UI layer on top of
  the 3 physical anchors, not a replacement for them — the anchor a hand
  reaches toward doesn't care whether it holds one fixed item or the top
  of a paged stack.

Both are real, wanted features — deliberately sequenced after the physical
anchors so there is something concrete to test in headset first, same
reasoning that kept this whole feature scoped down originally.

## Open / not done

- Seated and standing profiles exist as a system (save/load/switch, all
  working) but have not actually been tuned and saved yet — currently
  tabled by the owner, not blocked on anything.
- Centering is "close enough" per the owner but was never chased to a
  literal 0.00 drift for every weapon in the arsenal, only spot-checked on
  a couple.
- Forearm/wrist hardpoints (indices 8-13) went through several real
  in-headset iterations the session they were added (yaw correction, an
  up-vector sign fix, locking forearm to yaw-only so wrist pitch stops
  swinging the row) but are still new relative to the 8 torso holsters --
  `rs_hardpoint_arm_active_count` defaults to 0 for exactly that reason.
  Keep expecting empirical corrections here, not treating the current
  numbers as settled. See the roll-tracking gap noted in Architecture and
  the gesture-cast/paged-inventory layers noted above.
- **Real IK / elbow tracking**, planned once the pending UZDXREMA engine
  update lands. Every hand-anchored position right now is a fixed offset
  from the off hand's own live pose (`handAnchorPos`) -- there is no elbow
  or forearm sensor, so "where the forearm actually is" is approximated,
  not measured, and the empirical corrections above (yaw offset, pitch
  lockout) are exactly the kind of thing real IK would remove the need
  for. This almost certainly means a new engine native (in the spirit of
  `GetModelWorldOffset` etc. -- see "The engine dependency" above), not a
  script-side trick, so it waits on that update rather than being
  guessed at now.
- See the "Rename history" note near the top of this file for what did
  and did not move from `RS_Holster*` to `RS_HardPoint*`, and what's still
  pending (the containing folder, the GitHub remote).
