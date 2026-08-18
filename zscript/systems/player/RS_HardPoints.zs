// Body-anchored holsters: calibration + anchor placement + grip-claim
// arbitration. This is the part that actually DRIVES the engine's
// HolsterClaimMain/HolsterClaimOff -- without this handler running, those
// fields stay false, the native grip redirect never fires, and grip keeps its
// normal meaning everywhere (see DoomXR vk_openxrdevice.cpp).
//
// Anchors are computed from HmdPos and HmdYaw ONLY -- never HmdPitch/Roll.
// That is deliberate: pitch/roll come from looking up or down, and a holster
// anchored to full head orientation would swing away from the body every time
// the player looked at it. Yaw is the only rotation a real hip or shoulder
// actually follows.
//
// Calibration is one sample of standing eye height above the floor, not a menu
// flow. Every anchor height is a FRACTION of that number, so a 5'2" and a 6'4"
// player both get anchors on their own body rather than at some fixed offset
// tuned for one height.
//
// NOTE ON SHAPE: the holster table is an indexed accessor rather than an
// Array of structs, because ZScript dynamic arrays only accept integral and
// object types -- Array<SomeStruct> does not compile. Since the table is
// compile-time constant anyway, a switch costs nothing and allocates nothing.
//
// Scope: this owns calibration, anchors, and claims. It does not yet spawn
// holster props -- that is the next piece.

class RS_HardPointManager : EventHandler
{
	const HOLSTER_COUNT = 14;

	// Indices 0-7 are the original torso holsters (head + bodyYaw anchored).
	// Indices 8-13 are off-hand-anchored forearm/wrist hardpoints, added
	// later -- anchored to the OFF hand's own live pose (OffhandPos/Angle/
	// Pitch/Roll) rather than HmdPos/bodyYaw, because that is what a thing
	// strapped to your own arm actually has to track. See handAnchorPos and
	// the isHandAnchored callers below for the full split; GetHolster's own
	// comment block explains what hsFwd/hsSide/hsFrac mean for this range.
	const HAND_HOLSTER_START = 8;
	const FOREARM_HOLSTER_END = 11;   // exclusive -- 8,9,10 are Forearm1-3

	// Both Forearm1-3 (8-10) and WristBelow/Knuckle/Joint (11-13) are
	// anchored the same way: origin AND basis both come from the OFF hand's
	// own live pose (OffhandPos/Angle/Pitch/Roll), unconditionally -- it
	// does not matter which hand is holding a weapon, or whether either
	// hand is holding one at all. (A prior version of this tried deriving
	// the forearm row's direction from the MAIN hand's aim instead, on the
	// theory that the off hand's own orientation would be unreliably canted
	// by gripping a foregrip. The owner rejected that in headset testing --
	// simpler is correct here: it's the off-arm's own hardpoint rig, full
	// stop, not a weapon-aim-tracking accessory rail. Reverted.)

	// Forearm1-3 alone get an extra yaw correction on top of the raw off
	// hand angle -- empirically 90 degrees, determined in headset (a red
	// reference line drawn across a screenshot showing where the row should
	// trail vs. where it actually rendered). The negative hsFwd on those
	// three cases already means "the reverse of forward" -- pointing back
	// along the arm, per the owner's own framing: "if I were holding that
	// SMG backwards, pointing 180, it would be pointing along my forearm."
	// So this constant is NOT that 180 -- it corrects a separate mismatch
	// between raw OffhandAngle and where the held weapon visually appears to
	// point, which this mod has no way to introspect (that gap is owned by
	// the engine's own VR weapon rendering, not by RS_HardPointProp's model
	// binding, which only corrects HOLSTERED props via
	// level.GetModelOrientationHint -- there is no equivalent hint for a
	// weapon actively held in a hand). If this overshoots or undershoots,
	// the fix is changing this one number, not re-deriving the geometry.
	const FOREARM_YAW_CORRECTION = 90.0;

	// Doom's player scale puts a map unit at roughly one real inch (player
	// radius 16 ~ a person's half shoulder width), so these read as inches.
	//
	//   hsFwd    + is in FRONT of the eye plane, - is behind
	//   hsSide   + is the player's right
	//   hsFrac   height as a fraction of calibrated standing EYE height
	//   hsRadius grab radius, map units
	//
	// Everything is measured from the headset, which sits at your eyes -- the
	// FRONT of your head. That is why almost every hsFwd here is negative:
	// your chest, your back and your hips are all behind your own eyes. An
	// anchor at +fwd would float in front of your face.
	//
	// Heights are fractions of EYE height, not total height. Eye height is
	// about 0.93 of a person's stature, so these do not match the more
	// familiar stature-based proportions: shoulder is ~0.82 of stature but
	// ~0.88 of eye height.
	//
	// Front/back pairs are the tight ones -- a torso is only ~9-10 inches
	// deep, so pectoral and shoulderblade anchors are close enough that
	// oversized radii would overlap. They stay separable in practice because
	// the hand approaches a pectoral from the front and a blade from over the
	// shoulder, never from the same direction.
	// Hips only for now. The chest and shoulderblade anchors are removed
	// rather than commented out -- two working holsters beat six that get in
	// each other's way while the placement is still being tuned.
	//
	// Radius 3.0 = a 6 INCH WIDE catch volume. The marker sphere is drawn at
	// exactly this radius (MODELDEF Scale must match), so what you see is the
	// actual volume, not a decorative shell around it.
	// Orientation is PER HOLSTER, not global: a hip wants a gun hanging
	// barrel-down while a pectoral wants one lying flat across the chest at an
	// angle. One shared set of angles cannot serve both, so pitch/yaw/roll ride
	// in the table alongside position and are captured the same way -- from
	// your hand, in edit mode.
	// FIELD MEANING SPLITS AT idx == HAND_HOLSTER_START. For idx 0-7 (the
	// torso holsters, below), hsFwd/hsSide are offsets from HmdPos along
	// bodyYaw's forward/right, hsFrac is a FRACTION of calibrated eye
	// height, and hsPitch/hsYaw/hsRoll are ABSOLUTE angles. For idx 8-13
	// (the forearm/wrist hardpoints), hsFwd/hsSide/hsFrac are instead raw
	// map-unit (inch) offsets, always from OffhandPos and along the OFF
	// HAND's own live forward/right/up axes -- see handBasisPose/
	// handAnchorPos -- and hsPitch/hsYaw/hsRoll are TRIMS added on top of
	// that basis, not absolute
	// angles (see updateProps' baseAngle/basePitch/baseRoll). Reusing the
	// same six fields for both rather than adding a 7th out-param: nothing
	// that only moves these doubles around (dumpTable, saveProfile,
	// loadProfile) ever needs to know which meaning applies, only the code
	// that actually turns them into a world position/orientation does, and
	// that code already has to branch on isHandAnchored anyway.
	static void GetHolster(int idx, out string hsName, out double hsFwd, out double hsSide, out double hsFrac, out double hsRadius,
	                       out double hsPitch, out double hsYaw, out double hsRoll)
	{
		// sensible starting angles; every one of these is meant to be dragged
		hsPitch = 90.0; hsYaw = 0.0; hsRoll = 0.0;

		switch (idx)
		{
			// Hips: barrel straight down, the way a sidearm hangs.
			case 0:
				hsName = "HipLeft";   hsFwd = -2.0; hsSide = -9.0; hsFrac = 0.57; hsRadius = 3.0; break;
			case 1:
				hsName = "HipRight";  hsFwd = -2.0; hsSide =  9.0; hsFrac = 0.57; hsRadius = 3.0; break;

			// Head-side pair. TEMPORARILY PLACED IN FRONT (positive hsFwd) so
			// they are actually visible while being set up -- at their real
			// position beside the ears they sit in peripheral vision, which
			// makes them impossible to aim a hand at or confirm by eye.
			// Drag them back beside the head in edit mode once they work;
			// roughly hsFwd -2, hsSide +/-8 is where they belong.
			case 2:
				hsName = "HeadLeft";  hsFwd = 7.0; hsSide = -10.0; hsFrac = 0.95; hsRadius = 3.0; break;
			case 3:
				hsName = "HeadRight"; hsFwd = 7.0; hsSide =  10.0; hsFrac = 0.95; hsRadius = 3.0; break;

			// Pectorals: pistols and SMGs, lying flat against the chest,
			// angled down and outward rather than hanging vertically. Yaw
			// splits left/right so each points away from the centreline.
			// Barrel down, same as everything else -- no per-holster angle
			// worth the complexity right now. hsPitch/hsYaw/hsRoll default to
			// 90/0/0 at the top of this function already.
			case 4:
				hsName = "PectoralLeft";  hsFwd = -1.0; hsSide = -6.0; hsFrac = 0.78; hsRadius = 3.0; break;
			case 5:
				hsName = "PectoralRight"; hsFwd = -1.0; hsSide =  6.0; hsFrac = 0.78; hsRadius = 3.0; break;

			// Second hip pair -- the "2/4/6/8" tier's last step. Same depth
			// and height as the first hip pair, offset further out along
			// hsSide so the two sit side by side rather than overlapping:
			// radius 3.0 means each is a 6-inch catch volume, so two
			// centres 7 units apart leave a 1-inch gap between them, not a
			// shared boundary. Like the others, a starting guess meant to
			// be dragged into place, not a measured position.
			case 6:
				hsName = "HipLeft2";  hsFwd = -2.0; hsSide = -16.0; hsFrac = 0.57; hsRadius = 3.0; break;
			case 7:
				hsName = "HipRight2"; hsFwd = -2.0; hsSide =  16.0; hsFrac = 0.57; hsRadius = 3.0; break;

			// Forearm hardpoints: OFF-HAND anchored (see the field-meaning
			// comment above GetHolster), sitting behind the off-hand along
			// its OWN aim vector and spaced toward the elbow -- hsFwd
			// negative means "back", hsFrac 0.0 means "right on the aim
			// line" since there is no IK yet to say where the forearm's
			// actual surface is. hsPitch is 0.0, NOT the 90.0 the switch
			// defaults to above -- that 90 means "barrel down" in the
			// torso holsters' ABSOLUTE-angle world and would silently
			// mispitch every one of these, which are TRIMS on top of the
			// hand's live pose instead. Radius 2.0 (4" catch volume) and
			// 5-unit spacing leave a 1" gap between neighbours, same
			// gap-math the second hip pair already uses. Placeholders
			// meant to be dragged in edit mode, same as every other entry
			// in this table.
			case 8:
				hsName = "Forearm1"; hsFwd =  -4.0; hsSide = 0.0; hsFrac =  0.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;
			case 9:
				hsName = "Forearm2"; hsFwd =  -9.0; hsSide = 0.0; hsFrac =  0.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;
			case 10:
				hsName = "Forearm3"; hsFwd = -14.0; hsSide = 0.0; hsFrac =  0.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;

			// Wrist hardpoints: also off-hand anchored, hsFrac here is local
			// "up" inches (negative = below), not eye-height fraction. Same
			// hsPitch = 0.0 note as the forearm cases above applies.
			//
			// Owner's own reference pose: hand outstretched holding a
			// pistol, pistol at the top of the hand. Below/Knuckle/Wrist
			// aren't symmetric -- Knuckle sits slightly FORWARD (toward the
			// fingers, +hsFwd) and Wrist sits slightly BACK (toward the
			// actual wrist joint, -hsFwd), not just mirrored left/right at
			// the same depth. Left/right sign is hand-local (edSide's rx/ry
			// basis in handAnchorPos), so which physical side each name
			// lands on depends on the off-hand's own resting yaw -- exactly
			// what edit-mode dragging is for; these starting numbers just
			// need to be roughly in the right neighbourhood, not exact.
			case 11:
				hsName = "WristBelow";   hsFwd =  0.0; hsSide =  0.0; hsFrac = -3.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;
			case 12:
				hsName = "WristKnuckle"; hsFwd =  2.5; hsSide = -3.0; hsFrac =  0.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;
			default: // case 13, and a defensive fallback for idx >= 14
				hsName = "WristJoint";   hsFwd = -2.5; hsSide =  3.0; hsFrac =  0.0; hsRadius = 2.0; hsPitch = 0.0; hsYaw = 0.0; hsRoll = 0.0; break;
		}
	}

	// Keyed by player number rather than stored on the pawn: pawns are
	// destroyed and replaced on death and hub travel, and the calibration
	// measurement should not have to be retaken every time that happens.
	double eyeHeight[MAXPLAYERS];
	bool   calibrated[MAXPLAYERS];
	int    spawnTries[MAXPLAYERS];

	// Which holster each hand is currently inside, -1 for none. Recorded
	// during the claim pass so the swap acts on the holster the hand was in
	// at the moment of the grip press, rather than re-testing a tic later.
	int nearMain[MAXPLAYERS];
	int nearOff[MAXPLAYERS];

	// Holster index awaiting an auto-diagnostic dump, -1 for none. Set by
	// doSwap right after a store; consumed one tic later in WorldTick, AFTER
	// updateClaims (and the updateProps it calls) has actually repositioned
	// the prop for the new contents. Dumping inside doSwap itself would print
	// the PREVIOUS tic's prop position -- correct orientation numbers (those
	// are computed fresh from the weapon class) but a stale/misleading
	// "actual pos vs sphere" line, since that part only updates on
	// WorldTick's own pass, not the instant contents[] changes.
	int pendingDump[MAXPLAYERS];

	// Contents by holster index, flattened to one array because ZScript has
	// no 2D dynamic arrays: index as (player * HOLSTER_COUNT + holster).
	// Empty string means the holster holds nothing, which reads to the player
	// as holding fists -- the fist is never stored, it is what empty looks like.
	Array<string> contents;

	// Per PLAYER, not per hand, and deliberately so. player.PendingWeapon is a
	// SINGLE field shared by both hands, and BringUpWeapon consumes it
	// hand-blind. With a per-hand cooldown, an off-hand store landing inside the
	// main hand's still-running lower overwrote the main hand's PendingWeapon --
	// so that switch completed into the WRONG hand, the main hand got nothing,
	// and its weapon was never actually put away.
	int lastSwapTic[MAXPLAYERS];

	// One prop per holster per player, flattened like contents. Held as
	// pointers so a destroyed prop (level change, player death) reads null and
	// gets respawned rather than leaving a dangling anchor.
	Array<RS_HardPointProp> props;
	Array<RS_HardPointMarker> markers;

	// ---- live offsets ----
	// The switch in GetHolster is the DEFAULT table; these are what anchorPos
	// actually reads, seeded from it once. Edit mode writes here, so a holster
	// can be dragged to where it belongs on a real body instead of being
	// guessed at from proportion tables. Not per-player: this is a tuning
	// surface for one person wearing the headset, not gameplay state.
	double edFwd[HOLSTER_COUNT];
	double edSide[HOLSTER_COUNT];
	double edFrac[HOLSTER_COUNT];
	// Orientation lives here too, so a hip and a pectoral can hold a weapon at
	// completely different angles. Captured from the hand while dragging: point
	// your hand the way the gun should sit and drop it.
	double edPitch[HOLSTER_COUNT];
	double edYaw[HOLSTER_COUNT];
	double edRoll[HOLSTER_COUNT];
	bool   edInit;

	// Not per-player, same reason edFwd etc. are not: one person wears the
	// headset. Set by saveProfile/loadProfile whenever the name is "seated"
	// or "standing" -- the two names switchProfile() toggles between -- so a
	// switch always flips AWAY from whichever of the two you last touched by
	// any means (a dedicated Save/Load button, not just the toggle itself).
	string activeProfile;

	bool editMode;
	int  grabbedMain;  // holster index being dragged, -1 for none
	int  grabbedOff;

	// ---- body yaw ----
	// Anchors follow THIS, not HmdYaw directly. Your hips do not counter-rotate
	// every time you glance sideways, and neither should a holster: driving
	// them straight off head yaw means a head shake whips them around the body.
	//
	// Two separate defences, because there are two separate problems:
	//
	//  1. NECK RANGE. Within +/- BODY_YAW_DEADZONE of where the body faces,
	//     head rotation moves nothing at all. That is a real person turning
	//     their head without turning their torso.
	//  2. PITCH DEGENERACY. Yaw stops meaning anything useful when you look
	//     near-vertical -- at straight down, a tiny head movement swings yaw
	//     wildly. Past BODY_YAW_MAX_PITCH the body simply stops tracking, which
	//     is the specific fix for "look down and shake, holsters go bananas".
	double bodyYaw[MAXPLAYERS];
	bool   bodyYawInit[MAXPLAYERS];
	// Last seen controller-turn total, to difference against. Tracked rather
	// than read absolutely because only the CHANGE should move the body.
	double lastTurnYaw[MAXPLAYERS];

	const BODY_YAW_DEADZONE  = 50.0;  // degrees of free head turn
	const BODY_YAW_FOLLOW    = 0.15;  // catch-up rate past the deadzone
	const BODY_YAW_MAX_PITCH = 55.0;  // stop tracking beyond this head pitch

	// SLOW_SWAP_COOLDOWN (20, not 12): a default A_Lower needs (WEAPONBOTTOM 128
	// - WEAPONTOP 32) / 6 = 16 tics to finish before BringUpWeapon runs, so at
	// 12 the cooldown expired while ReadyWeapon was STILL the gun being put
	// away. The next store then read that stale weapon as "held" and the
	// dedupe pass wiped the holster it had just gone into -- the gun appeared
	// to hop between holsters and leave the first one empty.
	//
	// FAST_SWAP_COOLDOWN (4) is what actually applies whenever instant switch
	// is on (see swapCooldown() below): the whole reason for the 16-tic wait
	// stops existing once CF_INSTANTWEAPSWITCH makes A_Lower/BringUpWeapon
	// resolve in the SAME tic they are called, not 16 tics later. 4 is pure
	// debounce against one physical press registering as two, not animation
	// settling -- and it is what makes two-hand near-simultaneous store/draw
	// actually work, instead of the second hand eating the first hand's
	// cooldown window for an animation that, with instant switch on, does not
	// even happen.
	const SLOW_SWAP_COOLDOWN = 20;
	const FAST_SWAP_COOLDOWN = 4;
	const CLAIM_HYSTERESIS = 1.4;   // exit radius multiplier; see updateClaims
	const CALIBRATE_MAX_TRIES = 35; // ~1 second, then stop rather than loop forever
	const EYE_MIN = 36.0;           // sanity floor, map units (~3 feet)
	const EYE_MAX = 96.0;           // sanity ceiling (~8 feet)

	override void WorldTick()
	{
		for (int i = 0; i < MAXPLAYERS; ++i)
		{
			if (!playeringame[i] || players[i].mo == null)
				continue;

			PlayerPawn pawn = players[i].mo;

			if (!calibrated[i])
			{
				bool wasCalibrated = calibrated[i];
				tryCalibrate(i, pawn);
				// int arrays default to 0, a VALID holster index -- not -1.
				// Reset right on the transition into calibrated, once, so the
				// very first WorldTick pass after calibration can't misread a
				// zero-default as "holster 0 has a pending dump" and print an
				// empty auto-dump header before anything has ever been stored.
				if (calibrated[i] && !wasCalibrated)
					pendingDump[i] = -1;
				continue; // no anchors, no claims, until calibration lands
			}

			updateBodyYaw(i, pawn);
			updateGrabs(i, pawn);
			updateClaims(i, pawn); // also repositions props, via updateProps

			// Consume a dump queued by last tic's store, now that this tic's
			// updateClaims has actually moved the prop into place.
			if (pendingDump[i] >= 0)
			{
				Console.Printf("\c[Gold]--- RS_HOLSTER auto (stored) ---");
				dumpOneHolsterProp(i, pawn, pendingDump[i]);
				pendingDump[i] = -1;
			}
		}
	}

	// One-shot sample of standing eye height. Retried rather than taken
	// immediately because the pawn can still be mid-drop on its first tics,
	// and because HmdPos reads as a zero vector until the VR backend has
	// written a pose at least once.
	private void tryCalibrate(int i, PlayerPawn pawn)
	{
		spawnTries[i]++;
		if (spawnTries[i] > CALIBRATE_MAX_TRIES)
		{
			// Never got a plausible reading. Fall back to the pawn's own
			// height so holsters still exist, rather than silently doing
			// nothing forever with no indication why.
			eyeHeight[i] = pawn.Height * 0.9;
			calibrated[i] = true;
			Console.Printf("RS_HOLSTER: calibration timed out, using fallback eye height %.1f", eyeHeight[i]);
			return;
		}

		// A zero HmdPos means the VR backend has not written a head pose into
		// the field yet -- distinct from "the player is standing somewhere
		// implausible". Called out separately because it is the failure that
		// looks identical to "nothing is happening" from the outside.
		if (pawn.HmdPos.Length() == 0)
		{
			if (spawnTries[i] == CALIBRATE_MAX_TRIES)
				Console.Printf("\cgRS_HOLSTER: HmdPos is zero -- engine is not writing head pose. Holsters cannot work.");
			return;
		}

		double measured = pawn.HmdPos.Z - pawn.floorz;
		if (measured < EYE_MIN || measured > EYE_MAX)
		{
			if (spawnTries[i] == CALIBRATE_MAX_TRIES)
				Console.Printf("\cgRS_HOLSTER: eye height %.1f outside sane range %.0f-%.0f (HmdPos.Z %.1f, floor %.1f)",
					measured, EYE_MIN, EYE_MAX, pawn.HmdPos.Z, pawn.floorz);
			return;
		}

		eyeHeight[i] = measured;
		calibrated[i] = true;
		Console.Printf("RS_HOLSTER: calibrated standing eye height %.1f map units", measured);
	}

	// For a bindable recalibrate command (sat down during the auto sample,
	// playspace floor changed).
	void ForceRecalibrate(int playerNum)
	{
		if (playerNum < 0 || playerNum >= MAXPLAYERS)
			return;
		calibrated[playerNum] = false;
		spawnTries[playerNum] = 0;
	}

	// Seed the live offsets from the default table, once.
	private void ensureEdit()
	{
		if (edInit)
			return;
		edInit = true;
		grabbedMain = -1;
		grabbedOff = -1;
		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);
			edFwd[h] = hsFwd;
			edSide[h] = hsSide;
			edFrac[h] = hsFrac;
			edPitch[h] = hsPitch;
			edYaw[h] = hsYaw;
			edRoll[h] = hsRoll;
		}
	}

	// Advance the body's facing toward the head's, the way a torso actually
	// follows a neck. Called once per tic, before anchors are computed.
	private void updateBodyYaw(int i, PlayerPawn pawn)
	{
		if (!bodyYawInit[i])
		{
			bodyYawInit[i] = true;
			bodyYaw[i] = pawn.HmdYaw;
			lastTurnYaw[i] = pawn.VRTurnYaw;
			return;
		}

		// CONTROLLER TURN MOVES THE BODY 1:1, no deadzone, no smoothing.
		//
		// Snap turn and stick turn rotate the whole virtual body -- your hips
		// went with it, because nothing physical happened at all. Feeding that
		// through the neck deadzone was the drift: a 45 degree snap fits inside
		// a 50 degree deadzone, so the body refused to follow, and every snap
		// left the holsters a little further behind where the body actually
		// faced. It never recovered because each snap was individually "within
		// neck range".
		double turnDelta = normalizeDeg(pawn.VRTurnYaw - lastTurnYaw[i]);
		lastTurnYaw[i] = pawn.VRTurnYaw;
		if (turnDelta != 0)
			bodyYaw[i] = normalizeDeg(bodyYaw[i] + turnDelta);

		// Yaw is meaningless near-vertical: looking straight down, a small head
		// movement swings it wildly. Freeze rather than chase the noise.
		if (abs(pawn.HmdPitch) > BODY_YAW_MAX_PITCH)
			return;

		// Shortest signed difference, written out by hand -- deltaangle() is
		// not callable as a free function from a plain Object like this one.
		double d = pawn.HmdYaw - bodyYaw[i];
		while (d >  180.0) { d -= 360.0; }
		while (d < -180.0) { d += 360.0; }

		// Inside the neck's range the body does not move at all. This is what
		// makes a head shake cost nothing.
		if (abs(d) <= BODY_YAW_DEADZONE)
			return;

		// Past it, follow only the EXCESS, and only partway per tic, so the
		// body eases around instead of snapping.
		double excess = (d > 0) ? (d - BODY_YAW_DEADZONE) : (d + BODY_YAW_DEADZONE);
		bodyYaw[i] += excess * BODY_YAW_FOLLOW;

		while (bodyYaw[i] >  360.0) { bodyYaw[i] -= 360.0; }
		while (bodyYaw[i] < -360.0) { bodyYaw[i] += 360.0; }
	}

	// World-space position of one holster anchor for this player.
	private Vector3 anchorPos(int i, PlayerPawn pawn, int idx)
	{
		ensureEdit();

		// Forearm/wrist hardpoints track the off-hand's own live pose, not
		// the torso -- a completely different basis, so it is its own
		// function rather than a few more branches folded into this one.
		if (isHandAnchored(idx))
			return handAnchorPos(pawn, idx);

		// bodyYaw, NOT HmdYaw: anchors hang off the torso's facing so they do
		// not whip around when the head turns. ZScript's cos/sin take DEGREES.
		double yaw = bodyYaw[i];
		double fx = cos(yaw), fy = sin(yaw);   // forward vector
		double rx = sin(yaw), ry = -cos(yaw);  // player's right: yaw - 90 degrees

		double floorZ = pawn.HmdPos.Z - eyeHeight[i];

		return (
			pawn.HmdPos.X + (edFwd[idx] * fx) + (edSide[idx] * rx),
			pawn.HmdPos.Y + (edFwd[idx] * fy) + (edSide[idx] * ry),
			floorZ + (eyeHeight[i] * edFrac[idx])
		);
	}

	// The inverse of anchorPos: take a world point (a hand) and express it in
	// the same body-local numbers the table uses. This is what makes edit mode
	// work -- drag a sphere to where it belongs and read the offsets straight
	// back out, rather than deriving them from proportions and hoping.
	private void worldToBody(int i, PlayerPawn pawn, Vector3 world, out double oFwd, out double oSide, out double oFrac)
	{
		// Same frame anchorPos uses -- bodyYaw, not HmdYaw. Mixing the two
		// would make a dragged holster land somewhere other than the hand.
		double yaw = bodyYaw[i];
		double fx = cos(yaw), fy = sin(yaw);
		double rx = sin(yaw), ry = -cos(yaw);

		double dx = world.X - pawn.HmdPos.X;
		double dy = world.Y - pawn.HmdPos.Y;

		oFwd  = (dx * fx) + (dy * fy);
		oSide = (dx * rx) + (dy * ry);

		double floorZ = pawn.HmdPos.Z - eyeHeight[i];
		oFrac = (eyeHeight[i] != 0) ? ((world.Z - floorZ) / eyeHeight[i]) : 0.0;
	}

	// The live angle/pitch/roll every hand-anchored holster's basis is built
	// from: the OFF hand's own live pose, unconditionally, for both position
	// (handAnchorPos/worldToHand, which only read ang/pit -- position
	// deliberately ignores roll, see handAnchorPos' own comment) and
	// orientation (updateProps/dumpOneHolsterProp/updateGrabs, which need
	// all three). A single small function rather than reading
	// pawn.OffhandAngle/Pitch/Roll inline at every call site so there is one
	// place to touch if that ever needs to change again. Forearm indices
	// (8-10) get FOREARM_YAW_CORRECTION added on top -- see its own comment
	// up top for why -- and their pitch is forced to 0 rather than read
	// live. Confirmed in headset: tilting the off hand's gun down swung
	// Forearm1-3 the WRONG way (up, mirrored) instead of leaving them
	// roughly put, because a pure 180-degree reversal of a downward-tilted
	// vector points backward-and-UP -- mathematically correct for "the
	// exact reverse of wherever the controller points this instant," but
	// physically wrong for "my forearm," which does not flip upside down
	// just because I flex my wrist. There is no elbow tracking to give a
	// real forearm direction (see the IK note elsewhere in this file), so
	// this is the stand-in: forearm hardpoints follow the arm's YAW only
	// (turning left/right) and ignore wrist PITCH (tilting up/down)
	// entirely, for both position (this function feeds handAnchorPos) and
	// the stored item's own orientation (this function also feeds
	// updateProps' basePitch) -- a forearm-mounted item should sit level
	// and stay level, not wobble with every wrist flex.
	private void handBasisPose(PlayerPawn pawn, int idx, out double ang, out double pit, out double rol)
	{
		ang = pawn.OffhandAngle;
		if (idx < FOREARM_HOLSTER_END)
		{
			ang = normalizeDeg(ang + FOREARM_YAW_CORRECTION);
			pit = 0.0;
		}
		else
		{
			pit = pawn.OffhandPitch;
		}
		rol = pawn.OffhandRoll;
	}

	// World-space position of one HAND-anchored holster (idx 8-13): the
	// off-hand-relative counterpart to anchorPos, above. ORIGIN is always
	// OffhandPos -- these are physically on your off-arm -- but the
	// forward/right/up BASIS also comes from handBasisPose -- the off hand's
	// own live angle/pitch. Same local-basis shape already proven in
	// updateProps' trim-slider math (localFwdX/localUpX/rightX there) and in
	// RS_Main's RS_GrenadeThrower.Throw (positive pitch looks DOWN in this
	// engine, hence the negated Z on forward/up), just re-sourced here.
	// Deliberately yaw+pitch only, NOT roll -- rolling the off hand will
	// visibly rotate whatever is mounted here (updateProps carries roll into
	// orientation) but will not swing the ANCHOR POSITION around the arm.
	// Known v1 gap, not an oversight: this is the #1 thing to look at in
	// headset before guessing at a roll-aware basis blind (see the plan/
	// CLAUDE.md notes on this file's two previous wrong hand-derived
	// rotation attempts).
	private Vector3 handAnchorPos(PlayerPawn pawn, int idx)
	{
		double ang, pit, unusedRoll;
		handBasisPose(pawn, idx, ang, pit, unusedRoll);

		double fx =  cos(ang) * cos(pit);
		double fy =  sin(ang) * cos(pit);
		double fz = -sin(pit);
		double rx = sin(ang);
		double ry = -cos(ang);   // right is yaw-only, matches anchorPos' rx/ry
		// up = right x forward (verified by direct cross-product expansion
		// at pit=0, where forward/right/up must reduce to the familiar
		// facing/right/world-up trio) -- NOT the -cos/-sin signs the prop
		// trim sliders in updateProps use, which get away with being
		// inverted because they are a symmetric bidirectional knob nobody
		// would notice the polarity of. hsFrac has a HARD physical meaning
		// here (WristBelow's -3.0 means "below", full stop), so the sign
		// has to be actually correct, not just self-consistent.
		double upx = cos(ang) * sin(pit);
		double upy = sin(ang) * sin(pit);
		double upz = cos(pit);

		return (
			pawn.OffhandPos.X + (edFwd[idx] * fx) + (edSide[idx] * rx) + (edFrac[idx] * upx),
			pawn.OffhandPos.Y + (edFwd[idx] * fy) + (edSide[idx] * ry) + (edFrac[idx] * upy),
			pawn.OffhandPos.Z + (edFwd[idx] * fz)                      + (edFrac[idx] * upz)
		);
	}

	// The inverse of handAnchorPos, mirroring how worldToBody inverts
	// anchorPos -- what makes edit mode able to drag a forearm/wrist sphere
	// and read hand-local offsets straight back out. oUp takes the third
	// out-param name (not oFrac) because it is a raw inch offset here, never
	// a fraction of anything. Takes idx now (not just to index ed* arrays --
	// handBasisPose needs it too, for the forearm yaw correction).
	private void worldToHand(PlayerPawn pawn, int idx, Vector3 world, out double oFwd, out double oSide, out double oUp)
	{
		double ang, pit, unusedRoll;
		handBasisPose(pawn, idx, ang, pit, unusedRoll);

		double fx = cos(ang) * cos(pit),  fy = sin(ang) * cos(pit),  fz = -sin(pit);
		double rx = sin(ang), ry = -cos(ang);
		// up = right x forward -- see handAnchorPos' own comment on this
		// exact formula for why it is NOT the same sign as updateProps'
		// prop-trim basis.
		double upx = cos(ang) * sin(pit), upy = sin(ang) * sin(pit), upz = cos(pit);

		double dx = world.X - pawn.OffhandPos.X;
		double dy = world.Y - pawn.OffhandPos.Y;
		double dz = world.Z - pawn.OffhandPos.Z;

		oFwd  = (dx * fx)  + (dy * fy)  + (dz * fz);
		oSide = (dx * rx)  + (dy * ry);
		oUp   = (dx * upx) + (dy * upy) + (dz * upz);
	}

	// While a holster is grabbed, it simply lives wherever that hand is.
	private void updateGrabs(int i, PlayerPawn pawn)
	{
		// Position AND orientation follow the hand, so a holster is placed the
		// way you would actually place one: hold your hand where the gun goes,
		// angled how the gun should sit, and let go.
		if (grabbedMain >= 0)
		{
			if (isHandAnchored(grabbedMain))
			{
				// Position always updates -- this is what lets you drag a
				// forearm/wrist sphere to a new spot on your arm either way.
				worldToHand(pawn, grabbedMain, pawn.AttackPos, edFwd[grabbedMain], edSide[grabbedMain], edFrac[grabbedMain]);

				// Orientation trim is captured RELATIVE to the off hand's
				// own basis pose (handBasisPose), same idea as edYaw being
				// relative to bodyYaw for the torso case below -- the
				// dragging hand (main) and the basis hand (off) are always
				// different hands here, so this delta is always meaningful.
				double bAng, bPit, bRol;
				handBasisPose(pawn, grabbedMain, bAng, bPit, bRol);
				edYaw[grabbedMain]   = normalizeDeg(pawn.AttackAngle - bAng);
				edPitch[grabbedMain] = normalizeDeg(pawn.AttackPitch - bPit);
				edRoll[grabbedMain]  = normalizeDeg(pawn.AttackRoll  - bRol);
			}
			else
			{
				worldToBody(i, pawn, pawn.AttackPos, edFwd[grabbedMain], edSide[grabbedMain], edFrac[grabbedMain]);
				edPitch[grabbedMain] = pawn.AttackPitch;
				edRoll[grabbedMain]  = pawn.AttackRoll;
				// yaw relative to the BODY, not the world, or the stored angle
				// would only be right while facing the direction you set it in
				edYaw[grabbedMain] = normalizeDeg(pawn.AttackAngle - bodyYaw[i]);
			}
		}
		if (grabbedOff >= 0)
		{
			// No hand-anchored branch here: updateClaims never lets the off
			// hand claim its own hand-anchored gear (see there for why), so
			// grabbedOff can never actually BE a hand-anchored index -- this
			// is structurally unreachable, not just untested. worldToHand's
			// own origin is pawn.OffhandPos, so "drag a wrist sphere with
			// the same hand it's mounted on" has no meaningful answer to
			// give it anyway.
			worldToBody(i, pawn, pawn.OffhandPos, edFwd[grabbedOff], edSide[grabbedOff], edFrac[grabbedOff]);
			edPitch[grabbedOff] = pawn.OffhandPitch;
			edRoll[grabbedOff]  = pawn.OffhandRoll;
			edYaw[grabbedOff] = normalizeDeg(pawn.OffhandAngle - bodyYaw[i]);
		}
	}

	private static double normalizeDeg(double d)
	{
		while (d >  180.0) { d -= 360.0; }
		while (d < -180.0) { d += 360.0; }
		return d;
	}

	// Prints the live table as a ready-to-paste replacement for GetHolster's
	// switch. The whole point of edit mode: tune it on a body, then bake it.
	private void dumpTable()
	{
		Console.Printf("\c[Gold]--- RS_HOLSTER TABLE (paste over GetHolster's switch) ---");
		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);
			Console.Printf("case %d: hsName = \"%s\"; hsFwd = %.2f; hsSide = %.2f; hsFrac = %.3f; hsRadius = %.1f; hsPitch = %.1f; hsYaw = %.1f; hsRoll = %.1f; break;",
				h, hsName, edFwd[h], edSide[h], edFrac[h], hsRadius, edPitch[h], edYaw[h], edRoll[h]);
		}
	}

	// Real persistence, replacing "read the console dump, hand-paste it into
	// GetHolster's switch, recompile". A profile is a flat JSON document keyed
	// "h<index>_<field>" -- level.JSONProfile* (E:\UZDXREMA
	// src\scripting\vmthunks.cpp) is the ONLY file I/O ZScript has; it does not
	// parse JSON on the script side, so a flat key/double shape is what the
	// native protocol supports, not a design choice made here.
	//
	// name is not sanitized here -- the native refuses anything outside
	// [A-Za-z0-9_-] on its own and returns false, which both callers already
	// report to the console.
	private void saveProfile(string name)
	{
		ensureEdit();
		level.JSONProfileBegin();
		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			string key = String.Format("h%d_", h);
			level.JSONProfileSetDouble(key .. "fwd",   edFwd[h]);
			level.JSONProfileSetDouble(key .. "side",  edSide[h]);
			level.JSONProfileSetDouble(key .. "frac",  edFrac[h]);
			level.JSONProfileSetDouble(key .. "pitch", edPitch[h]);
			level.JSONProfileSetDouble(key .. "yaw",   edYaw[h]);
			level.JSONProfileSetDouble(key .. "roll",  edRoll[h]);
		}
		if (level.JSONProfileSave(name))
		{
			Console.Printf("\c[Gold]RS_HOLSTER: saved profile \"%s\"", name);
			if (name == "seated" || name == "standing")
				activeProfile = name;
		}
		else
			Console.Printf("\cgRS_HOLSTER: could not save profile \"%s\" (bad name, or write failed)", name);
	}

	// Loads into the LIVE edit table, same as dragging every sphere by hand --
	// so it takes effect immediately (updateProps reads edFwd/etc every tic)
	// and a bad or missing profile just leaves the current table untouched
	// rather than zeroing anything out.
	private void loadProfile(string name)
	{
		ensureEdit();
		if (!level.JSONProfileLoad(name))
		{
			Console.Printf("\cgRS_HOLSTER: no profile \"%s\" on disk", name);
			return;
		}
		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			// GetHolster's own defaults are the fallback per field, not 0 --
			// a profile saved before a 7th holster existed (hypothetically)
			// should not zero-pitch a field it never wrote.
			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);

			string key = String.Format("h%d_", h);
			edFwd[h]   = level.JSONProfileGetDouble(key .. "fwd",   hsFwd);
			edSide[h]  = level.JSONProfileGetDouble(key .. "side",  hsSide);
			edFrac[h]  = level.JSONProfileGetDouble(key .. "frac",  hsFrac);
			edPitch[h] = level.JSONProfileGetDouble(key .. "pitch", hsPitch);
			edYaw[h]   = level.JSONProfileGetDouble(key .. "yaw",   hsYaw);
			edRoll[h]  = level.JSONProfileGetDouble(key .. "roll",  hsRoll);
		}
		Console.Printf("\c[Gold]RS_HOLSTER: loaded profile \"%s\"", name);
		if (name == "seated" || name == "standing")
			activeProfile = name;
	}

	// Flips between the two saved profiles and re-samples eye height for
	// whichever posture that implies. Reloading the offset TABLE alone is not
	// enough: anchorPos multiplies edFrac by eyeHeight[i], and that height is
	// only ever sampled once (tryCalibrate, WorldTick) -- carrying a standing
	// measurement into a freshly-loaded seated table (or vice versa) would
	// place every anchor using the wrong body's proportions on the right
	// table, or the right body's proportions on the wrong one. Neither reads
	// as "positioned for how you are sitting right now."
	private void switchProfile(int playerNum, PlayerPawn pawn)
	{
		// Empty (never touched activeProfile) falls to the "standing" branch,
		// matching GetHolster's own built-in defaults -- a first press that
		// does not visibly move anything, rather than jumping to a table that
		// has never been saved and quietly falling back to those same
		// defaults anyway.
		string target = (activeProfile == "standing") ? "seated" : "standing";
		loadProfile(target);
		ForceRecalibrate(playerNum);
		Console.Printf("\c[Gold]RS_HOLSTER: switched to \"%s\" -- hold still a moment for height to resample", target);
	}

	private void updateClaims(int i, PlayerPawn pawn)
	{
		// Hysteresis: a hand already inside a holster keeps it until it leaves
		// a LARGER radius than it took to get in. Without this, a hand resting
		// near the boundary flickers claimed/unclaimed many times a second --
		// which is worse than not claiming at all, because grip's MEANING
		// flips with it, and the player cannot tell what a press will do.
		int prevMain = nearMain[i];
		int prevOff  = nearOff[i];

		bool mainClaimed = false;
		bool offClaimed = false;
		nearMain[i] = -1;
		nearOff[i] = -1;

		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			// An inactive holster (active count dialed below 8) is not
			// visible and must not be claimable either -- a hand should
			// never be able to trigger a store/draw on a holster it cannot
			// see, hysteresis-held or not.
			if (!holsterActive(h))
				continue;

			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);

			Vector3 anchor = anchorPos(i, pawn, h);

			double mainR = (prevMain == h) ? hsRadius * CLAIM_HYSTERESIS : hsRadius;
			double offR  = (prevOff  == h) ? hsRadius * CLAIM_HYSTERESIS : hsRadius;

			if (!mainClaimed && (pawn.AttackPos - anchor).Length() < mainR)
			{
				mainClaimed = true;
				nearMain[i] = h;
			}

			// The off hand can never claim its OWN hand-anchored gear. For
			// a hand-anchored index, anchor is OffhandPos plus a rotation of
			// that SAME hand's own live basis, so |OffhandPos - anchor| is
			// the constant sqrt(edFwd^2+edSide^2+edFrac^2) every tic, no
			// matter how the player moves -- never a meaningful "did the
			// hand reach it" test. Depending on tuned offsets that constant
			// would land either permanently inside the radius (the off hand
			// stuck claiming its own wrist forever) or permanently outside
			// (dead code) -- excluding the test outright is the only
			// correct fix, not something radius tuning could paper over.
			if (!isHandAnchored(h) && !offClaimed && (pawn.OffhandPos - anchor).Length() < offR)
			{
				offClaimed = true;
				nearOff[i] = h;
			}
		}

		// Edge-logged rather than per-tic: this is the signal that the whole
		// chain works, and it should be visible without being a spam source.
		if (mainClaimed != pawn.HolsterClaimMain)
		{
			Console.Printf("RS_HOLSTER: main hand %s holster range", mainClaimed ? "ENTERED" : "left");
			// A short, light tap on ENTER only -- a real holster does not buzz
			// your hand when you pull away from it, only when you find it.
			if (mainClaimed) level.VRHaptic(0, 0.35, 25.0);
		}
		if (offClaimed != pawn.HolsterClaimOff)
		{
			Console.Printf("RS_HOLSTER: off hand %s holster range", offClaimed ? "ENTERED" : "left");
			if (offClaimed) level.VRHaptic(1, 0.35, 25.0);
		}

		pawn.HolsterClaimMain = mainClaimed;
		pawn.HolsterClaimOff  = offClaimed;

		updateProps(i, pawn);
	}

	// Park a prop at every anchor and keep it showing whatever is stored there.
	// Position is rewritten each tic rather than parented, because the anchors
	// move with the player's head every frame and there is nothing to parent to.
	private void updateProps(int i, PlayerPawn pawn)
	{
		if (!showProps())
		{
			// Setting invisible rather than destroying: the player can toggle
			// this mid-session, and respawning six actors on every toggle is
			// worse than leaving six invisible ones parked.
			for (int h = 0; h < HOLSTER_COUNT; ++h)
			{
				int pi = (i * HOLSTER_COUNT) + h;
				if (pi < props.Size() && props[pi] != null)
					props[pi].SetVisible(false);
			}
			return;
		}

		ensureContents();
		ensureProps();

		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			int pi = (i * HOLSTER_COUNT) + h;

			// Same "invisible, not destroyed" treatment showProps() already
			// uses for the whole system -- dialing the active count down
			// hides a holster without evacuating whatever might be stored in
			// it, so raising the count back up later shows it exactly as it
			// was left. updateClaims already refuses to claim an inactive
			// index; this is what makes it actually disappear too.
			if (!holsterActive(h))
			{
				if (pi < markers.Size() && markers[pi] != null)
					markers[pi].SetVisible(false);
				if (pi < props.Size() && props[pi] != null)
					props[pi].SetVisible(false);
				continue;
			}

			Vector3 at = anchorPos(i, pawn, h);

			// Declared here, once, rather than where the weapon prop's own
			// orientation math used to declare it further down -- the marker
			// needs the same basis now too. It used to matter for nothing
			// but the prop, back when the marker was a sphere with no
			// orientation to get right; a bracket reticle is not
			// rotationally symmetric, so it needs pointing the same way.
			//
			// baseAngle/basePitch/baseRoll, not a single byaw: torso
			// holsters (h < HAND_HOLSTER_START) keep the exact old
			// behaviour -- body yaw only, edPitch/edRoll used as ABSOLUTE
			// values -- while hand-anchored holsters (8-13) take their base
			// from handBasisPose (the off hand's own live pose), with
			// edPitch/edRoll added as TRIMS on top. For the torso branch
			// basePitch/baseRoll are 0.0, which makes every formula below
			// reduce to exactly what it was before this split --
			// behavior-preserving for 0-7.
			double baseAngle, basePitch, baseRoll;
			if (isHandAnchored(h))
			{
				handBasisPose(pawn, h, baseAngle, basePitch, baseRoll);
			}
			else
			{
				baseAngle = bodyYaw[i];
				basePitch = 0.0;
				baseRoll  = 0.0;
			}

			string hsNameM; double hsFwdM, hsSideM, hsFracM, hsRadius, hsPitchM, hsYawM, hsRollM;
			GetHolster(h, hsNameM, hsFwdM, hsSideM, hsFracM, hsRadius, hsPitchM, hsYawM, hsRollM);

			// --- the ring marker: always present, so an empty holster is
			// still something the player can see and aim a hand at ---
			//
			// Color is a CLASS choice (RS_HardPointMarker.holsterMarkerColorClass,
			// RS_HardPointProp.zs), not a settable field -- an existing marker
			// whose class no longer matches the cvar gets destroyed and
			// respawned so a color change takes effect immediately instead of
			// waiting for something else to force a respawn later.
			class<Actor> wantColorClass = RS_HardPointMarker.holsterMarkerColorClass();
			if (markers[pi] != null && markers[pi].GetClass() != wantColorClass)
			{
				markers[pi].Destroy();
				markers[pi] = null;
			}
			if (markers[pi] == null)
				markers[pi] = RS_HardPointMarker(Actor.Spawn(wantColorClass, at, NO_REPLACE));

			if (markers[pi] != null)
			{
				markers[pi].SetVisible(true);
				markers[pi].SetOrigin(at, true);
				markers[pi].SetHot(nearMain[i] == h || nearOff[i] == h);

				// Same live-tunable orientation the weapon prop uses (edYaw/
				// edPitch/edRoll, not a fresh GetHolster read) -- so dragging
				// a holster in edit mode reorients its marker too, instead of
				// the reticle staying frozen at the un-tuned default.
				markers[pi].angle = baseAngle + edYaw[h];
				markers[pi].pitch = basePitch + edPitch[h];
				markers[pi].roll  = baseRoll  + edRoll[h];

				// Proximity feed for the tighten effect: 1.0 at the anchor,
				// fading to 0 by SENSE_MULT*hsRadius out. Wider than the
				// actual grab radius on purpose -- the point is a reticle
				// that visibly notices a hand APPROACHING, not one that only
				// reacts once the hand is already inside the tiny grab
				// volume (at which point SetHot's binary swap already fired).
				// Plain local, not const -- every const in this codebase is a
				// CLASS-level member (HOLSTER_COUNT, SWAP_COOLDOWN, etc.), never
				// a local declared inside a method body, and there is no way to
				// test-compile before this ships to find out the hard way.
				double senseMult = 4.0;
				double dMain = (pawn.AttackPos - at).Length();
				double dOff  = (pawn.OffhandPos - at).Length();
				// No bare Min()/Clamp() -- neither has any precedent as a
				// builtin anywhere in this engine's own ZScript (only Max()
				// does), and there is no way to test-compile before this
				// ships, so plain comparisons it is.
				double dNear = (dMain < dOff) ? dMain : dOff;
				double senseRange = hsRadius * senseMult;
				double norm = (senseRange > 0.0) ? (dNear / senseRange) : 1.0;
				if (norm < 0.0) norm = 0.0;
				if (norm > 1.0) norm = 1.0;
				markers[pi].SetProximity(1.0 - norm);
			}

			// --- the stored weapon's model, when there is one ---
			if (props[pi] == null)
			{
				props[pi] = RS_HardPointProp(Actor.Spawn("RS_HardPointProp", at, NO_REPLACE));
				if (props[pi] == null)
					continue;
			}

			let p = props[pi];

			string stored = contents[(i * HOLSTER_COUNT) + h];

			// --- reconcile the slot against reality ---
			// contents[] is only ever written by doSwap, so it drifts: a stored
			// weapon stays in inventory and the engine can re-arm it (ammo
			// pickup -> CheckWeaponSwitch), or it can be dropped, or promoted
			// into a different class by a tier upgrade. Any of those leaves the
			// table describing a holster that does not match the world.
			//
			// GATED ON THE SWITCH HAVING SETTLED, and that gate is the whole
			// trick: for the ~16 tics a weapon spends lowering, ReadyWeapon is
			// STILL the gun being put away. Reconciling during that window would
			// see "the stored weapon is in a hand" on the very tic after every
			// store and erase all six holsters as fast as they were filled.
			// PendingWeapon == WP_NOCHANGE means no switch is in flight.
			if (stored != "" && pawn.player.PendingWeapon == WP_NOCHANGE
			    && level.time - lastSwapTic[i] >= swapCooldown())
			{
				let rw = pawn.player.ReadyWeapon;
				let ow = pawn.player.OffhandWeapon;
				bool inHand = (rw != null && rw.GetClassName() == stored)
				           || (ow != null && ow.GetClassName() == stored);

				if (inHand || pawn.FindInventory(stored) == null)
				{
					// The weapon drifted back into a hand through something
					// other than doSwap (ammo-pickup re-arm via
					// CheckWeaponSwitch, the native VR wheel, a tier
					// promotion) -- give it the same reset doSwap's own draw
					// branch gives a normal draw. Clearing the table alone
					// left the weapon ITSELF permanently flagged: excluded
					// from weapnext/weapprev forever (CheckAmmo gates on
					// bHolsterHidden) and, worse, unable to ever fire again
					// (CheckAmmo gates that too, unconditionally) -- nothing
					// else in this file clears either flag.
					if (inHand)
					{
						let strayWeapon = (rw != null && rw.GetClassName() == stored) ? rw : ow;
						if (strayWeapon != null)
						{
							strayWeapon.bNoAutoSwitchTo = strayWeapon.Default.bNoAutoSwitchTo;
							strayWeapon.bHolsterHidden = false;
						}
					}

					contents[(i * HOLSTER_COUNT) + h] = "";
					stored = "";
				}
			}
			// Show first: it reads level.GetModelOrientationHint, which the
			// angle below depends on. Hand-anchored holsters get their own,
			// smaller default scale (RS_HardPointProp.holsterPropScaleArm) --
			// a wrist-mounted flashlight should read as compact gear, not a
			// full holstered sidearm.
			double propScale = isHandAnchored(h) ? RS_HardPointProp.holsterPropScaleArm() : RS_HardPointProp.holsterPropScale();
			p.ShowWeapon(stored == "" ? null : Weapon(pawn.FindInventory(stored)), propScale, hsRadius);

			// Face the same way the BODY does (not the head), so a holstered
			// gun stays put on the hip when you look around, plus a tunable
			// yaw, MEASURED mirroring, and cancellation of whatever that
			// specific model bakes into its own MODELDEF block.
			//
			// Mirroring (p.mirrored) comes from level.GetModelOrientationHint,
			// not a guess: it is true exactly when that weapon's own Scale has
			// a negative X, which is a per-model authoring choice uncorrelated
			// with which hand it is normally held in. A mirrored mesh points
			// the opposite way for the same actor angle, hence +180.
			//
			// bakedAngleOffset/PitchOffset/RollOffset are MODELDEF fields
			// (e.g. the SMG's PitchOffset 45) that the renderer applies AFTER
			// actor rotation (r_data/models.cpp, step 5 follows step 1) --
			// so they land on top of whatever pitch/angle/roll is set here
			// REGARDLESS of what this code does. Subtracting them cancels
			// that per-weapon quirk out, so every weapon ends up at the same
			// intended final orientation instead of each carrying its own
			// baked-in deviation. Exact for the common case here, where a
			// weapon bakes at most one of the three axes; a weapon baking two
			// or more non-commuting axes at once would need real matrix math
			// to cancel exactly, which none of the current data requires.
			// baseAngle/basePitch/baseRoll are declared once, up with the
			// marker orientation code above.
			double extra = RS_HardPointProp.holsterPropYaw() + edYaw[h];
			if (p.mirrored)
				extra += 180.0;
			double finalAngle = baseAngle + extra - p.bakedAngleOffset;
			double finalPitch = basePitch + edPitch[h] + RS_HardPointProp.holsterPropPitch() - p.bakedPitchOffset;

			p.angle = finalAngle;
			p.pitch = finalPitch;
			p.roll  = baseRoll + edRoll[h] + RS_HardPointProp.holsterPropRoll() - p.bakedRollOffset;

			// Local basis for the MANUAL TRIM sliders only now (below). "Push it
			// forward" should mean forward-relative-to-the-gun, not raw world X,
			// so the trim still rides this rotated frame -- but this basis is no
			// longer used for the automatic correction. It was a hand-derived
			// reconstruction of the engine's own rotation, and it was wrong: two
			// independent derivations (direct and cross-product-verified) each
			// passed their own internal consistency check and still landed the
			// prop exactly 4.55 units off, on opposite sides depending on sign,
			// because neither accounted for RenderModel silently NEGATING pitch
			// before rotating (r_data/models.cpp: "pitch -= angles.Pitch.Degrees()"
			// under MDL_USEACTORPITCH without MDL_BADROTATION). That is not a
			// mistake worth repeating a third time by hand.
			double localFwdX =  cos(finalAngle) * cos(finalPitch);
			double localFwdY =  sin(finalAngle) * cos(finalPitch);
			double localFwdZ = -sin(finalPitch);
			double localUpX  = -cos(finalAngle) * sin(finalPitch);
			double localUpY  = -sin(finalAngle) * sin(finalPitch);
			double localUpZ  = -cos(finalPitch);
			double rightX = sin(finalAngle);
			double rightY = -cos(finalAngle);

			// AUTOMATIC centering: level.GetModelWorldOffset builds the SAME
			// VSMatrix with the SAME rotate() calls RenderModel itself makes
			// (including the pitch negation above) and transforms the model's
			// baked local offset through it directly -- the engine's own
			// transform, replayed, not a reconstruction of it. p.sprite/p.frame
			// are exactly the (sprite,frame) A_ChangeModel bound in ShowWeapon.
			double stretch = (level.info != null) ? level.info.pixelstretch : 1.0;
			bool foundWorld;
			double worldOffX, worldOffY, worldOffZ;
			// p.scale is passed because the renderer multiplies the model's
			// baked offset by it. Omitting it (defaulting to 1,1) subtracted a
			// full-size correction from a prop drawn at 0.18 -- roughly four
			// times too much -- which is why shrinking a weapon threw it out of
			// the sphere instead of settling it in the middle.
			[foundWorld, worldOffX, worldOffY, worldOffZ] =
				level.GetModelWorldOffset(p.shownClass, p.sprite, p.frame, stretch, finalAngle, finalPitch, p.roll,
				                          p.scale.X, p.scale.Y);
			if (!foundWorld) { worldOffX = 0.0; worldOffY = 0.0; worldOffZ = 0.0; }

			// Manual trim, local rotated frame, on top of the automatic
			// correction -- a residual nudge now, not the whole mechanism.
			double nUp   = RS_HardPointProp.holsterPropUp();
			double nFwd  = RS_HardPointProp.holsterPropFwd();
			double nSide = RS_HardPointProp.holsterPropSide();

			Vector3 placed = (
				at.X - worldOffX + (nFwd * localFwdX) + (nUp * localUpX) + (nSide * rightX),
				at.Y - worldOffY + (nFwd * localFwdY) + (nUp * localUpY) + (nSide * rightY),
				at.Z - worldOffZ + (nFwd * localFwdZ) + (nUp * localUpZ)
			);
			p.SetOrigin(placed, true);
		}
	}

	// Grab the sphere this hand is inside, or drop the one it is holding.
	private void toggleGrab(int i, bool mainHand)
	{
		ensureEdit();

		int held = mainHand ? grabbedMain : grabbedOff;
		if (held >= 0)
		{
			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(held, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);
			Console.Printf("RS_HOLSTER: dropped %s at fwd %.2f  side %.2f  frac %.3f",
				hsName, edFwd[held], edSide[held], edFrac[held]);
			level.VRHaptic(mainHand ? 0 : 1, 0.6, 15.0);
			if (mainHand) { grabbedMain = -1; } else { grabbedOff = -1; }
			return;
		}

		// Nothing held -- grab whatever this hand is inside. While editing,
		// the claim radius is what decides, same as a real grab, so a sphere
		// you cannot claim is also a sphere you cannot drag: that is the
		// feedback, not a limitation.
		int want = mainHand ? nearMain[i] : nearOff[i];
		if (want < 0)
		{
			Console.Printf("RS_HOLSTER: no sphere in reach for that hand");
			return;
		}

		string hsName2; double f2, s2, fr2, r2, p2, y2, rl2;
		GetHolster(want, hsName2, f2, s2, fr2, r2, p2, y2, rl2);
		Console.Printf("RS_HOLSTER: grabbed %s -- move your hand, press again to drop", hsName2);
		level.VRHaptic(mainHand ? 0 : 1, 0.35, 25.0);
		if (mainHand) { grabbedMain = want; } else { grabbedOff = want; }
	}

	// Whatever this player's melee weapon actually is. Walks inventory rather
	// than naming a class, so it survives new player classes and new fist
	// variants without edits here.
	// Must return a fist that ALREADY belongs to the hand being filled.
	// MoveWeaponToHand's first guard is:
	//     if (weap.bNoHandSwitch && weap.bOffhandWeapon != (hand == 1)) return;
	// and every fist here carries +WEAPON.NOHANDSWITCH -- so handing it the
	// main-hand fist for the off hand makes it bail SILENTLY. That was the
	// "offhand never lets go of the gun" bug: the store happened, the hand
	// was never emptied, and nothing reported a failure.
	// One definition of "is this a fist", used by both the store guard and the
	// fist lookup. Name-based on purpose -- see the note at the store guard.
	static bool isFistClass(string cn)
	{
		return cn.IndexOf("Fist") >= 0;
	}

	private Weapon findFist(PlayerPawn pawn, bool offhand) const
	{
		for (Inventory item = pawn.Inv; item != null; item = item.Inv)
		{
			let w = Weapon(item);
			if (w == null)
				continue;
			// GetClassName() is a Name; IndexOf is a String method, so it has
			// to land in a string first.
			string cn = w.GetClassName();
			if (cn.IndexOf("Fist") < 0)
				continue;

			if (w.bOffhandWeapon == offhand)
				return w;      // the one that belongs in this hand
		}

		// No fallback to "any fist". A wrong-hand fist can NEVER be seated --
		// MoveWeaponToHand's first guard rejects it silently because every fist
		// carries +WEAPON.NOHANDSWITCH -- so handing one back only produced a
		// store that emptied nothing while the table recorded it as done. That
		// is the "offhand never lets go of the gun" bug, reintroduced by the
		// very fallback that was meant to be defensive. Null is the honest
		// answer, and the caller rolls the store back.
		return null;
	}

	private void ensureProps()
	{
		int want = MAXPLAYERS * HOLSTER_COUNT;
		while (props.Size() < want)
			props.Push(null);
		while (markers.Size() < want)
			markers.Push(null);
	}

	private bool showProps() const
	{
		let cv = CVar.GetCVar("rs_hardpoint_props", players[consoleplayer]);
		return (cv != null) ? cv.GetBool() : true;
	}

	// How many of the 8 declared holsters are actually live: 2 (hip), 4
	// (+shoulder), 6 (+pectoral), 8 (+second hip pair) -- matching the
	// GetHolster index order exactly, so "active count N" always means
	// "indices 0..N-1", no separate ordering table needed. Clamped and
	// snapped to the nearest valid step rather than trusted raw, since this
	// cvar can be hand-edited in an ini to any int.
	private int activeCount() const
	{
		let cv = CVar.GetCVar("rs_hardpoint_active_count", players[consoleplayer]);
		int n = (cv != null) ? cv.GetInt() : HOLSTER_COUNT;
		if (n <= 2) return 2;
		if (n <= 4) return 4;
		if (n <= 6) return 6;
		return 8;
	}

	// True for the 6 off-hand-anchored forearm/wrist indices (8-13), false
	// for the original 8 torso holsters. The one predicate everything else
	// in this file branches on to tell the two anchor models apart.
	private bool isHandAnchored(int idx) const
	{
		return idx >= HAND_HOLSTER_START;
	}

	// Mirrors activeCount(), but for the arm rig: 0 off, 3 forearm only, 6
	// forearm + wrist -- a SEPARATE cvar and tier from the body holsters'
	// 2/4/6/8, and defaulted OFF (not "everything on" like the body count's
	// fallback) because this anchor model is new and unproven in headset,
	// where the existing 8 are already tuned and trusted. Turning this on
	// should never be a side effect of anything else.
	private int armActiveCount() const
	{
		let cv = CVar.GetCVar("rs_hardpoint_arm_active_count", players[consoleplayer]);
		int n = (cv != null) ? cv.GetInt() : 0;
		if (n <= 0) return 0;
		if (n <= 3) return 3;
		return 6;
	}

	private bool holsterActive(int h) const
	{
		if (!isHandAnchored(h))
			return h < activeCount();
		return (h - HAND_HOLSTER_START) < armActiveCount();
	}

	private bool instantSwitchEnabled() const
	{
		let cv = CVar.GetCVar("rs_hardpoint_instant_switch", players[consoleplayer]);
		return (cv != null) ? cv.GetBool() : true;
	}

	private int swapCooldown() const
	{
		return instantSwitchEnabled() ? FAST_SWAP_COOLDOWN : SLOW_SWAP_COOLDOWN;
	}

	override void NetworkProcess(ConsoleEvent evt)
	{
		if (evt.player < 0) return;
		PlayerPawn pawn = players[evt.player].mo;
		if (!pawn) return;

		if (evt.name == "rs-hardpoint-recalibrate")
		{
			ForceRecalibrate(evt.player);
			return;
		}

		if (evt.name == "rs-hardpoint-debug")
		{
			dumpDebug(evt.player, pawn);
			return;
		}

		if (evt.name == "rs-hardpoint-edit")
		{
			ensureEdit();
			editMode = !editMode;
			grabbedMain = -1;
			grabbedOff = -1;
			if (editMode)
			{
				Console.Printf("\c[Gold]RS_HOLSTER: EDIT MODE ON");
				Console.Printf("  put a hand in a sphere and press its holster key to GRAB it");
				Console.Printf("  move your hand, press again to DROP it there");
				Console.Printf("  then: netevent rs-hardpoint-table   (prints the numbers)");
			}
			else
			{
				Console.Printf("\c[Gold]RS_HOLSTER: edit mode off");
			}
			return;
		}

		if (evt.name == "rs-hardpoint-table")
		{
			ensureEdit();
			dumpTable();
			return;
		}

		if (evt.name == "rs-hardpoint-reset")
		{
			edInit = false;
			ensureEdit();
			Console.Printf("RS_HOLSTER: offsets reset to the built-in defaults");
			return;
		}

		// Two named profiles, not a generic named-save flow: a hip/pectoral
		// table tuned standing does not fit a seated body (shorter reach,
		// different eye-to-hip fraction), so "which profile" is really "which
		// posture", and posture only has two values worth a dedicated bind.
		if (evt.name == "rs-hardpoint-save-seated")   { saveProfile("seated");   return; }
		if (evt.name == "rs-hardpoint-load-seated")   { loadProfile("seated");   return; }
		if (evt.name == "rs-hardpoint-save-standing") { saveProfile("standing"); return; }
		if (evt.name == "rs-hardpoint-load-standing") { loadProfile("standing"); return; }

		// The switcher: flips to whichever of the two you are not currently
		// on, and re-samples eye height for it. One bind, no menu digging --
		// this is the one meant for mid-session use (you just sat down),
		// where the four buttons above are a setup-time thing.
		if (evt.name == "rs-hardpoint-switch-profile") { switchProfile(evt.player, pawn); return; }

		// One key per hand -- which hand pressed decides which weapon moves,
		// or in edit mode which sphere gets dragged.
		if (evt.name == "rs-hardpoint-grab-main")
		{
			if (editMode) { toggleGrab(evt.player, true); }
			else          { doSwap(evt.player, pawn, nearMain[evt.player], false); }
		}
		else if (evt.name == "rs-hardpoint-grab-off")
		{
			if (editMode) { toggleGrab(evt.player, false); }
			else          { doSwap(evt.player, pawn, nearOff[evt.player], true); }
		}
	}

	// Wraps MoveWeaponToHand with a transient CF_INSTANTWEAPSWITCH, restored
	// immediately after. A dedicated helper rather than inlining this at both
	// call sites in doSwap means there is no early-return path that could
	// leave the flag set -- set/call/restore is one atomic sequence with
	// nothing else inside it to return out of early. (An earlier version of
	// this set the flag before doSwap's validation checks instead of right
	// around the call; those checks have their own early returns, which would
	// have left the flag stuck on for the rest of the session.)
	//
	// CF_INSTANTWEAPSWITCH is a real, complete GZDoom mechanism
	// (constants.zs) that both A_Lower and BringUpWeapon already check
	// (weapons.zs / player.zs) -- setting it makes psp.y jump straight to
	// WEAPONBOTTOM/WEAPONTOP instead of climbing 6 units/tic, so the whole
	// lower-then-raise sequence resolves SYNCHRONOUSLY inside the
	// MoveWeaponToHand call, same tic, rather than over the ~16 tics that
	// made two-hand near-simultaneous store/draw fight over one shared
	// PendingWeapon. Restored right after so ordinary weapon switching
	// (number keys, the wheel) keeps its normal animated feel -- this only
	// ever touches the switch a holster itself just triggered.
	//
	// Checked for side effects before using it: RS_ScoreRevival.zs is the
	// only place in RS_Main that reads player.cheats for anything besides a
	// single unrelated HUD check (CF_CHASECAM in RS_HealthBars.zs), and it
	// only tests the invincibility bits (CF_BUDDHA/CF_BUDDHA2/CF_GODMODE/
	// CF_GODMODE2) -- nothing anywhere treats "cheats nonzero" as a global
	// cheated-run flag that this would trip.
	private void moveWeaponInstant(PlayerPawn pawn, Weapon w, int hand)
	{
		if (!instantSwitchEnabled())
		{
			pawn.MoveWeaponToHand(w, hand);
			return;
		}
		bool wasSet = (pawn.player.cheats & CF_INSTANTWEAPSWITCH) != 0;
		pawn.player.cheats |= CF_INSTANTWEAPSWITCH;
		pawn.MoveWeaponToHand(w, hand);
		if (!wasSet)
			pawn.player.cheats &= ~CF_INSTANTWEAPSWITCH;
	}

	// Swap what the hand is holding with what the holster holds. Because an
	// empty hand always means "fists" and an empty holster always means
	// "nothing stored", both directions are the same operation: read both
	// sides, write both sides. Draw, store, and swap are all this.
	private void doSwap(int i, PlayerPawn pawn, int holsterIdx, bool offhand)
	{
		if (holsterIdx < 0)
			return; // hand was not in a holster; nothing claimed it

		// Debounce. A held or repeating key must not swap more than once. With
		// instant switch OFF, a swap also cannot settle immediately --
		// PendingWeapon takes ~16 tics to become ReadyWeapon, so a second swap
		// inside that window reads the OLD held weapon and shuffles the same
		// gun back and forth; with it ON (the default), that window is gone
		// and swapCooldown() is pure debounce, short enough that both hands
		// can act within the same reach without one eating the other's.
		// Checked here but NOT charged here -- the write lives at the end, next
		// to the confirm haptic. Charging on entry meant every no-op press
		// (fists into an empty holster, a same-weapon repeat, a stale slot)
		// burned a full cooldown, so recovering from a bad slot needed two
		// presses spaced a cooldown apart with no indication why the first did
		// nothing.
		if (level.time - lastSwapTic[i] < swapCooldown())
			return;

		ensureContents();

		int slot = (i * HOLSTER_COUNT) + holsterIdx;

		// Evict any fist a previous build managed to store. Without this the
		// bad slots persist in a running session and keep showing a fist at
		// the holster even after the store guard is fixed.
		for (int c = 0; c < HOLSTER_COUNT; ++c)
		{
			int ci = (i * HOLSTER_COUNT) + c;
			if (contents[ci] != "" && isFistClass(contents[ci]))
				contents[ci] = "";
		}

		string stored = contents[slot];
		Weapon held = offhand ? pawn.player.OffhandWeapon : pawn.player.ReadyWeapon;

		// Never store the fist. It is what an empty holster looks like, not a
		// thing that occupies one -- otherwise "swap fists into an empty
		// holster" would fill it with a weapon the player still has anyway.
		// "is Fist" does NOT work here: VR_Fist derives from RS_Weapon, not
		// from Doom's Fist, so the inheritance test is always false and every
		// fist got stored like a real weapon. That is where the extra fists
		// came from. Match on the name, the same way findFist does.
		string heldName = "";
		if (held != null && !isFistClass(held.GetClassName()))
			heldName = held.GetClassName();

		if (stored == "" && heldName == "")
			return; // fists into an empty holster: nothing to do

		// The slot names the very gun this hand is holding. That is not a
		// legitimate no-op -- it is a STALE SLOT. A stored weapon never leaves
		// inventory, so CheckWeaponSwitch re-arms it on the next ammo pickup
		// while the table still claims the holster holds it.
		//
		// Used to clear the slot and RETURN here -- that fixed the permanent
		// jam (a stale slot could never be drawn from OR stored into again)
		// but traded it for a quieter one: the press that discovered the
		// stale slot did nothing visible at all (no haptic, no sound, no
		// console line), identical to a no-op press, so it read as "I have
		// to holster something else first to unstick it" even though the
		// table was already fixed by that first press. Resync stored to ""
		// and fall through into the ordinary store logic below instead, so
		// the SAME press that finds the desync is the press that actually
		// completes the store, with the normal confirmation.
		if (stored != "" && stored == heldName)
		{
			contents[slot] = "";
			stored = "";
		}

		// A weapon lives in exactly one holster. Without this, storing the
		// same gun in two places leaves both claiming it, and drawing from
		// one silently empties the other.
		if (heldName != "")
		{
			for (int h = 0; h < HOLSTER_COUNT; ++h)
			{
				int other = (i * HOLSTER_COUNT) + h;
				if (other != slot && contents[other] == heldName)
					contents[other] = "";
			}
		}

		contents[slot] = heldName;

		// Bring out whatever was in there. Selecting the player's OWN existing
		// instance rather than spawning a fresh one is essential: GunBonsai
		// perks live on the instance, and a new copy would silently drop every
		// perk rolled on that weapon.
		int hand = offhand ? 1 : 0;

		if (stored != "")
		{
			let w = Weapon(pawn.FindInventory(stored));
			if (w == null)
			{
				// Owned when stored, gone now (dropped, tier-promoted into a
				// different class, mod removed it). Clear the slot rather than
				// leaving a holster pointing at a weapon that cannot be drawn.
				contents[slot] = "";
				Console.Printf("RS_HOLSTER: %s no longer in inventory, slot cleared", stored);
				return;
			}

			// MoveWeaponToHand is VOID and bails SILENTLY on a hand mismatch:
			//     if (weap.bNoHandSwitch && weap.bOffhandWeapon != (hand == 1)) return;
			// Every weapon in this arsenal carries +WEAPON.NOHANDSWITCH, and
			// nothing binds a holster to a hand -- either hand can claim any of
			// the six anchors, and the hip pair sit on opposite sides of the
			// body. Without this check the store above was already committed, so
			// reaching across with the wrong hand ATE the slot and delivered
			// nothing: the weapon ended up in no holster and in no hand, and the
			// console cheerfully printed a swap that never happened.
			if (w.bNoHandSwitch && w.bOffhandWeapon != offhand)
			{
				contents[slot] = stored;   // roll back the commit above
				Console.Printf("\cgRS_HOLSTER: %s belongs to the %s hand", stored, offhand ? "main" : "off");
				return;
			}

			// Coming back out, so it is an ordinary auto-switch candidate again,
			// and weapnext/weapprev/slot-select can land on it again too.
			w.bNoAutoSwitchTo = w.Default.bNoAutoSwitchTo;
			w.bHolsterHidden = false;

			// MoveWeaponToHand, never a raw OffhandWeapon assignment.
			// Assigning the pointer directly leaves the hand's psprite
			// still running the OLD weapon's states with the new weapon as
			// caller, and the VM aborts the moment one of those state
			// functions type-checks its owner:
			//   "Invalid class VR_Fist in function call to VR_SMG.StateFunction"
			// This routes through PendingWeapon and DropWeapon/BringUpWeapon
			// so the psprite is torn down and rebuilt properly.
			moveWeaponInstant(pawn, w, hand);
		}
		else
		{
			// Holster was empty, so the hand comes back to fists. Resolved by
			// search, not by name: this arsenal has VR_Fist, RS_GH_Fist and
			// RS_PS_Fist (plus numbered tiers of each) and the right one
			// depends on the player class. Hardcoding "Fist" found nothing,
			// which is why storing a weapon appeared to do nothing at all --
			// the gun went into the holster but never left the hand.
			let fist = findFist(pawn, offhand);
			if (fist == null)
			{
				// No fist this hand can actually accept. Refusing loudly beats
				// the old behaviour, which committed the store and then failed
				// to empty the hand -- leaving the player still holding a gun
				// the table had already filed away.
				contents[slot] = stored;   // roll back; the store did not happen
				Console.Printf("\cgRS_HOLSTER: no %s-hand fist to empty into", offhand ? "off" : "main");
				return;
			}
			moveWeaponInstant(pawn, fist, hand);
		}

		// The gun that just went IN stops being an auto-switch candidate. A
		// holstered weapon is still in inventory, so without this the engine's
		// CheckWeaponSwitch picks it straight back out on the next ammo pickup
		// (the fists it is compared against are +WEAPON.WIMPY_WEAPON, so the
		// test always passes) -- and then the holster and the hand both claim
		// the same gun. Restored on draw, above.
		//
		// bHolsterHidden alongside it, same lifecycle: without this,
		// weapnext/weapprev/slot-select would still happily cycle straight
		// to a weapon that is sitting in a holster, pulling it into the hand
		// through a path that never goes through doSwap at all -- the
		// holster would then show empty (this mod's own reconciliation in
		// updateProps catches the desync) while the gun ends up in-hand
		// unasked for. bHolsterHidden makes CheckAmmo itself refuse to
		// treat a stowed weapon as a valid candidate, which is what actually
		// keeps it out of the cycle in the first place.
		if (held != null && heldName != "")
		{
			held.bNoAutoSwitchTo = true;
			held.bHolsterHidden = true;
		}

		// Charged only now that real work happened -- see the check at the top.
		lastSwapTic[i] = level.time;

		// Firmer and shorter than the entry tap -- a confirm, not a notice.
		level.VRHaptic(offhand ? 1 : 0, 0.6, 15.0);

		// Diegetic confirm, fired from the HOLSTER's own position rather than
		// the player -- a sound with a place in the world, not a UI blip
		// glued to your head. Two choices, both borrowed from RS_Main's own
		// SNDINFO rather than new assets: rs_fx_holster (a $random 3-variant
		// clunk that sat unused until now) or rs_allclear_ready (the
		// ready-to-fire cadence beep, freed up for this now that
		// rs_allclear_enable defaults off).
		let sndCv = CVar.GetCVar("rs_hardpoint_sound", pawn.player);
		if (sndCv == null || sndCv.GetBool())
		{
			let styleCv = CVar.GetCVar("rs_hardpoint_sound_style", pawn.player);
			string sndName = (styleCv != null && styleCv.GetInt() == 1) ? "rs_allclear_ready" : "rs_fx_holster";

			if (slot < props.Size() && props[slot] != null)
				props[slot].A_StartSound(sndName, CHAN_AUTO, CHANF_DEFAULT, 0.7);
			else
				pawn.A_StartSound(sndName, CHAN_AUTO, CHANF_DEFAULT, 0.7);
		}

		string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
		GetHolster(holsterIdx, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);
		Console.Printf("RS_HOLSTER: %s <-> %s (%s)",
			heldName == "" ? "fists" : heldName,
			stored == "" ? "empty" : stored,
			hsName);

		// Auto-diagnostic: if a real weapon just went INTO this holster (not a
		// fists-only draw with nothing to measure), queue a dump for next tic.
		// This is what makes "record as I play" true -- store a gun and the
		// full orientation/offset breakdown lands in the log on its own, no
		// menu, no netevent, nothing to remember mid-session.
		if (contents[slot] != "")
			pendingDump[i] = holsterIdx;
	}

	// Everything needed to tell WHY a holster is not triggering, in one dump.
	// Without this a mislocated anchor is indistinguishable from a dead
	// system: both produce no console output at all.
	private void dumpDebug(int i, PlayerPawn pawn)
	{
		Console.Printf("\c[Gold]--- RS_HOLSTER DEBUG ---");
		Console.Printf("calibrated: %s   eye height: %.1f", calibrated[i] ? "yes" : "NO", eyeHeight[i]);
		Console.Printf("HmdPos  %.1f, %.1f, %.1f   yaw %.1f", pawn.HmdPos.X, pawn.HmdPos.Y, pawn.HmdPos.Z, pawn.HmdYaw);
		Console.Printf("pawn    %.1f, %.1f, %.1f   floor %.1f", pawn.pos.X, pawn.pos.Y, pawn.pos.Z, pawn.floorz);
		Console.Printf("mainhnd %.1f, %.1f, %.1f", pawn.AttackPos.X, pawn.AttackPos.Y, pawn.AttackPos.Z);
		Console.Printf("offhand %.1f, %.1f, %.1f", pawn.OffhandPos.X, pawn.OffhandPos.Y, pawn.OffhandPos.Z);

		if (!calibrated[i])
		{
			Console.Printf("\cgnot calibrated -- no anchors computed yet");
			return;
		}

		ensureContents();

		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
			GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);

			Vector3 anchor = anchorPos(i, pawn, h);
			double dMain = (pawn.AttackPos - anchor).Length();
			double dOff  = (pawn.OffhandPos - anchor).Length();
			string slotHas = contents[(i * HOLSTER_COUNT) + h];

			Console.Printf("%-13s at %.1f,%.1f,%.1f  r%.0f  main %.1f%s  off %.1f%s  [%s]",
				hsName, anchor.X, anchor.Y, anchor.Z, hsRadius,
				dMain, dMain < hsRadius ? " IN" : "",
				dOff,  dOff  < hsRadius ? " IN" : "",
				slotHas == "" ? "empty" : slotHas);
		}

		dumpPropOrientation(i, pawn);
	}

	// Everything the two orientation/offset natives measured for each occupied
	// holster's model, plus what actually got applied to the actor and where
	// the mesh ended up relative to the sphere it should be centred in. Built
	// for exactly the "still not centred / still not barrel-down" reports --
	// without this, the only way to tell "the native returned garbage" apart
	// from "the math consuming it is wrong" was to keep guessing at both.
	private void dumpPropOrientation(int i, PlayerPawn pawn)
	{
		Console.Printf("\c[Gold]--- prop orientation ---");

		bool anyStored = false;
		for (int h = 0; h < HOLSTER_COUNT; ++h)
		{
			if (contents[(i * HOLSTER_COUNT) + h] == "") continue;
			anyStored = true;
			dumpOneHolsterProp(i, pawn, h);
		}

		if (!anyStored)
			Console.Printf("(nothing stored anywhere -- store a weapon first, then run this again)");
	}

	// Everything the two orientation/offset natives measured for ONE occupied
	// holster's model, plus what actually got applied and where the mesh ended
	// up relative to the sphere. Factored out of dumpPropOrientation so the
	// same diagnostic can fire AUTOMATICALLY the instant a store happens (see
	// doSwap), not just on a manual dump -- "record as I play" instead of
	// needing to remember a menu press.
	private void dumpOneHolsterProp(int i, PlayerPawn pawn, int h)
	{
		string stored = contents[(i * HOLSTER_COUNT) + h];
		if (stored == "") return;

		let w = Weapon(pawn.FindInventory(stored));
		if (w == null)
		{
			Console.Printf("%-13s [%s] -- NOT in inventory, cannot resolve", "?", stored);
			return;
		}

		State rs = w.FindState("Ready");
		if (rs == null)
		{
			Console.Printf("%-13s [%s] -- no Ready state, cannot resolve model", "?", stored);
			return;
		}

		bool foundOri, mirrored;
		double angOff, pitOff, rolOff;
		[foundOri, mirrored, angOff, pitOff, rolOff] = level.GetModelOrientationHint(w.GetClass(), rs.sprite, rs.Frame);

		double stretch = (level.info != null) ? level.info.pixelstretch : 1.0;
		bool foundOff;
		double offX, offY, offZ;
		[foundOff, offX, offY, offZ] = level.GetModelOffsetHint(w.GetClass(), rs.sprite, rs.Frame, stretch);

		string hsName; double hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll;
		GetHolster(h, hsName, hsFwd, hsSide, hsFrac, hsRadius, hsPitch, hsYaw, hsRoll);

		// Same baseAngle/basePitch/baseRoll split as updateProps -- kept as
		// its own copy here rather than factored out, matching this
		// function's existing role as an independent recomputation for
		// diagnostics (see the file header comment on dumpOneHolsterProp).
		// Without this branch the auto-dump-on-store would print body-yaw
		// numbers for a wrist/forearm item, which is exactly the kind of
		// misleading "actual vs sphere" report this function exists to
		// prevent.
		double baseAngle, basePitch, baseRoll;
		if (isHandAnchored(h))
		{
			handBasisPose(pawn, h, baseAngle, basePitch, baseRoll);
		}
		else
		{
			baseAngle = bodyYaw[i];
			basePitch = 0.0;
			baseRoll  = 0.0;
		}
		double extra = RS_HardPointProp.holsterPropYaw() + edYaw[h] + (mirrored ? 180.0 : 0.0);
		double finalAngle = baseAngle + extra - angOff;
		double finalPitch = basePitch + edPitch[h] + RS_HardPointProp.holsterPropPitch() - pitOff;

		double finalRoll = baseRoll + edRoll[h] + RS_HardPointProp.holsterPropRoll() - rolOff;

		// Same fill-vs-fallback split ShowWeapon actually applies -- kept as
		// its own copy for the same independent-recomputation reason as the
		// angle/pitch/roll split above, not factored out into a shared
		// helper. Using the REAL applied scale here (not always the flat
		// fallback) matters: GetModelWorldOffset's own correctness depends
		// on being handed the actor scale that is actually in effect, or
		// this dump's "world offset" stops matching what is really on screen.
		bool foundBounds; double measuredRadius;
		[foundBounds, measuredRadius] = level.GetModelBoundsHint(w.GetClass(), rs.sprite, rs.Frame);
		double fallbackScale = isHandAnchored(h) ? RS_HardPointProp.holsterPropScaleArm() : RS_HardPointProp.holsterPropScale();
		double propScale = (foundBounds && measuredRadius > 0.0)
			? (hsRadius * RS_HardPointProp.holsterPropFill()) / measuredRadius
			: fallbackScale;

		bool foundWorld; double worldDX, worldDY, worldDZ;
		[foundWorld, worldDX, worldDY, worldDZ] =
			level.GetModelWorldOffset(w.GetClass(), rs.sprite, rs.Frame, stretch, finalAngle, finalPitch, finalRoll,
			                          propScale, propScale);

		Console.Printf("%-13s [%s]", hsName, stored);
		Console.Printf("  orientation hint: found=%d mirrored=%d angOff=%.1f pitOff=%.1f rolOff=%.1f",
			foundOri, mirrored, angOff, pitOff, rolOff);
		Console.Printf("  offset hint:      found=%d  local(fwd,side,up)= %.2f, %.2f, %.2f",
			foundOff, offX, offY, offZ);
		Console.Printf("  bounds hint:      found=%d  radius=%.2f  holster r=%.2f fill=%.2f -> scale=%.4f  (fallback would be %.4f)",
			foundBounds, measuredRadius, hsRadius, RS_HardPointProp.holsterPropFill(), propScale, fallbackScale);
		Console.Printf("  world offset:     found=%d  world(x,y,z)= %.2f, %.2f, %.2f  (via GetModelWorldOffset, replays the engine's own rotation)",
			foundWorld, worldDX, worldDY, worldDZ);
		Console.Printf("  applied:          angle=%.1f pitch=%.1f  (base angle %.1f, holster pitch %.1f, trim yaw %.1f pitch %.1f)",
			finalAngle, finalPitch, baseAngle, hsPitch, RS_HardPointProp.holsterPropYaw(), RS_HardPointProp.holsterPropPitch());

		if (!foundOri || !foundOff || !foundWorld)
			Console.Printf("\cg  NATIVE RETURNED NOT-FOUND -- class/sprite/frame lookup failed, model may not have hasmodel set or FSpriteModelFrame is missing for this (sprite,frame)");

		int pi = (i * HOLSTER_COUNT) + h;
		if (pi < props.Size() && props[pi] != null)
		{
			Vector3 anchor = anchorPos(i, pawn, h);
			double drift = (props[pi].pos - anchor).Length();
			Console.Printf("  prop actual pos:  %.1f, %.1f, %.1f   sphere at %.1f, %.1f, %.1f   drift %.2f%s",
				props[pi].pos.X, props[pi].pos.Y, props[pi].pos.Z,
				anchor.X, anchor.Y, anchor.Z, drift,
				drift > hsRadius ? "  <-- OUTSIDE the sphere" : "");
		}
	}

	private void ensureContents()
	{
		int want = MAXPLAYERS * HOLSTER_COUNT;
		while (contents.Size() < want)
			contents.Push("");
	}
}
