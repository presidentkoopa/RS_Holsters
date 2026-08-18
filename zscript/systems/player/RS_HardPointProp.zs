// The visible half of a holster: a prop actor parked at each anchor, showing
// the weapon stored there.
//
// HOW THE MODEL GETS THERE. MODELDEF binds a model to a (class, sprite, frame)
// triple, and FindModelFrameRaw matches the class by EXACT pointer -- so a
// subclass does not inherit its parent's model, and no generic prop class can
// ever have a weapon's model bound to it directly.
//
// A_ChangeModel is the way through. It creates per-instance model data and
// sets modelDef on it, and FindModelFrame prefers modelData->modelDef over the
// actor's real class. So this prop borrows the weapon's model definition at
// runtime, then wears the weapon's own Ready-state sprite and frame so the
// (class, sprite, frame) lookup resolves. No new art, no generated MODELDEF
// entries, no spawning real Weapon actors just to look at them.
//
// Why not spawn the actual weapon as a prop: a Weapon in the world runs its
// own BeginPlay and lands in this mod's condition/rarity/GunBonsai paths. A
// display object must not be able to roll a rarity.
//
// Why the Ready state rather than Spawn: Spawn is the PICKUP sprite (RIFK),
// which has no model bound. The held frames (RIFL) are the ones MODELDEF
// actually covers.
// A visible ring at every holster anchor, whether or not anything is stored
// there. Without this an empty holster is invisible and the player has nothing
// to aim a hand at -- and no way to tell a mispositioned anchor from a dead
// one. Frame A is idle, frame B lights up while a hand is inside the radius,
// which doubles as live confirmation that the claim is firing.
class RS_HardPointMarker : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOGRAVITY
		+NOINTERACTION
		+DONTSPLASH
		+NOTONAUTOMAP
		+BRIGHT
		+FORCEXYBILLBOARD
		RenderStyle "Add";
		Alpha 0.85;
		Radius 1;
		Height 1;
	}

	States
	{
	Idle:
		RSHM A -1;
		Stop;
	Hot:
		RSHM B -1;
		Stop;
	Spawn:
		RSHM A -1;
		Stop;
	}

	// Tracks the current look so the state is only re-entered on a change.
	// SetStateLabel restarts the state, so calling it every tic would keep
	// resetting the sprite forever. lastShape rides along in the SAME guard
	// -- without it, changing the shape cvar mid-session would sit inert
	// until this holster's hot/idle state happened to toggle on its own
	// (the next time a hand entered or left it), which reads as "the menu
	// setting did nothing" rather than "not yet, still waiting."
	private bool isHot;
	private bool everSet;
	// No sentinel needed: everSet already gates "first call ever" on its own
	// (no field initializer here -- there is no precedent anywhere in this
	// codebase for one, and no way to confirm ZScript even allows it without
	// a test-compile this session cannot do). The default 0 is never
	// mistaken for "already matches", because everSet being false forces the
	// guard below to proceed regardless of what lastShape happens to hold.
	private int lastShape;

	// 0 = bracket reticle (the default), 1 = the original wireframe sphere.
	// Both files stay on disk permanently now -- this is a choice, not a
	// replacement.
	static int holsterMarkerShape()
	{
		let cv = CVar.GetCVar("rs_hardpoint_marker_shape", players[consoleplayer]);
		return (cv != null) ? cv.GetInt() : 0;
	}

	// A fixed small palette, not an arbitrary color picker. GZDoom's
	// Translation is a per-CLASS Default property (Actor.Translation is
	// writable, but there is no runtime API in this fork for building an
	// arbitrary RGB translation from a plain int/color at a holster's own
	// spawn time without risking an unverified cast this session has no way
	// to test-compile) -- so each choice is its own subclass carrying one
	// hardcoded Translation string, in the same "%[desat]:[tint]" syntax
	// RS_Main already uses on monster skins (RS_Archvile.zs). SetHot() is
	// inherited unchanged by every one of them, and A_ChangeModel's modeldef
	// argument there is the LITERAL name 'RS_HardPointMarker', not
	// self.GetClassName() -- so every subclass still redirects model lookup
	// to the one MODELDEF block that actually exists, regardless of which of
	// these actually gets spawned. Translation is the only thing that
	// differs; model binding does not care which of these it is.
	static class<Actor> holsterMarkerColorClass()
	{
		let cv = CVar.GetCVar("rs_hardpoint_marker_color", players[consoleplayer]);
		int c = (cv != null) ? cv.GetInt() : 0;
		switch (c)
		{
			case 1: return "RS_HardPointMarker_Blue";
			case 2: return "RS_HardPointMarker_Red";
			case 3: return "RS_HardPointMarker_Gold";
			case 4: return "RS_HardPointMarker_Purple";
			default: return "RS_HardPointMarker";
		}
	}

	void SetHot(bool hot)
	{
		int wantShape = holsterMarkerShape();
		if (everSet && hot == isHot && wantShape == lastShape)
			return;
		isHot = hot;
		everSet = true;
		lastShape = wantShape;

		// Literal labels only -- a StateLabel cannot be produced by a ternary
		// or built from a string at runtime.
		if (hot) { SetStateLabel("Hot"); }
		else     { SetStateLabel("Idle"); }

		// Swap the SKIN directly rather than trusting the frame to select a
		// different MODELDEF model slot. Two Model entries pointing at the
		// same .obj is exactly the case where slot selection is least certain,
		// and A_ChangeModel is the mechanism already proven to work on the
		// weapon props -- so use the one that is known good.
		name skinWanted = hot ? 'rs_wire_hot.png' : 'rs_wire_idle.png';
		name modelWanted = (wantShape == 1) ? 'rs_wiresphere.obj' : 'rs_hardpoint_bracket.obj';
		A_ChangeModel('RS_HardPointMarker', 0, "models", modelWanted, 0, "models", skinWanted);
	}

	// 0 = no hand within sense range, 1 = hand exactly at the anchor. Fed by
	// the manager every tic (RS_HardPoints.zs updateProps) from the same
	// hand-to-anchor distance updateClaims already computes for the claim
	// radius -- this marker has no way to know a hand position on its own.
	private double proximity01;

	void SetProximity(double t)
	{
		proximity01 = (t < 0.0) ? 0.0 : (t > 1.0) ? 1.0 : t;
	}

	// Fade instead of a hard bINVISIBLE cut. FADE_STEP is a CLASS-level
	// const, not a local one -- a const declared inside a method body has no
	// precedent anywhere in this codebase and no way to confirm ZScript even
	// allows it without a test-compile this session cannot do (caught making
	// exactly that mistake once already tonight, in RS_HardPoints.zs).
	const FADE_STEP = 0.125;   // ~8 tics for a full fade, either direction

	private double fadeAlpha;
	private bool   fadeVisible;

	void SetVisible(bool show)
	{
		fadeVisible = show;
		if (show)
			bINVISIBLE = false;   // visible-but-transparent during fade-in, not hidden
	}

	override void Tick()
	{
		Super.Tick();

		if (fadeVisible)
		{
			fadeAlpha += FADE_STEP;
			if (fadeAlpha > 1.0) fadeAlpha = 1.0;
		}
		else
		{
			fadeAlpha -= FADE_STEP;
			if (fadeAlpha < 0.0) fadeAlpha = 0.0;
			if (fadeAlpha <= 0.0)
				bINVISIBLE = true;   // only actually hide once fully faded out
		}

		// Tighten: brackets draw inward as a hand approaches. Actor Scale is
		// a straight multiplier on top of MODELDEF's own Scale (RenderModel:
		// scaleFactorX = actor->Scale.X * smf->xscale) -- the same mechanism
		// RS_HardPointProp already uses to size the stored weapon, just driven
		// by proximity here instead of a fixed cvar.
		double s = 1.0 - (0.28 * proximity01);
		Scale = (s, s);

		// Pulse, hot state only -- a marker breathing at every holster all
		// the time is noise the player has to learn to filter out, which
		// defeats the point of a state cue. Idle stays flat at the base
		// alpha; only the one you could actually reach right now moves.
		// Multiplied by fadeAlpha, not replaced by it, so the pulse and the
		// fade compose instead of one clobbering the other mid-transition.
		double baseAlpha = isHot ? (0.70 + 0.25 * sin(360.0 * ((level.time % 70) / 70.0))) : 0.85;
		Alpha = fadeAlpha * baseAlpha;
	}
}

// The color palette for RS_HardPointMarker.holsterMarkerColorClass(). Each one
// adds ONLY a Translation -- everything else (states, Tick, SetHot, the
// shape choice) is inherited unchanged, and SetHot's A_ChangeModel already
// redirects model lookup to the parent class's literal name regardless of
// which of these is actually spawned, so subclassing here cannot break model
// binding. Desaturation weights are the standard NTSC luma split
// (0.30/0.59/0.11) for all four -- only the tint range after that differs.
// Same "%[desat]:[tint]" syntax RS_Main already uses on monster skins
// (RS_Archvile.zs), not a new mechanism.
class RS_HardPointMarker_Blue : RS_HardPointMarker
{
	Default { Translation "0:255=%[0.30,0.59,0.11]:[0.35,0.65,2.00]"; }
}
class RS_HardPointMarker_Red : RS_HardPointMarker
{
	Default { Translation "0:255=%[0.30,0.59,0.11]:[2.00,0.35,0.35]"; }
}
class RS_HardPointMarker_Gold : RS_HardPointMarker
{
	Default { Translation "0:255=%[0.30,0.59,0.11]:[2.00,1.55,0.30]"; }
}
class RS_HardPointMarker_Purple : RS_HardPointMarker
{
	Default { Translation "0:255=%[0.30,0.59,0.11]:[1.40,0.35,1.85]"; }
}

class RS_HardPointProp : Actor
{
	Default
	{
		+NOBLOCKMAP
		+NOGRAVITY
		+NOINTERACTION
		+DONTSPLASH
		+NOTONAUTOMAP
		Radius 1;
		Height 1;
	}

	// The class currently displayed, so a re-show with the same weapon does
	// not rebind the model every tic.
	class<Weapon> shownClass;

	// Measured, not guessed. Whether THIS specific weapon's MODELDEF mirrors
	// it (negative X Scale) plus its own baked AngleOffset/PitchOffset/
	// RollOffset, read via level.GetModelOrientationHint -- the native that
	// exposes exactly what FindModelFrameRaw already knows internally.
	//
	// The thing this replaced: "needsFlip = !offhand" assumed mirroring
	// correlates with which hand a weapon is normally held in. It does not.
	// Scale sign is a per-model AUTHORING choice -- chainsaw is -1.5 X, SMG is
	// -1.0 X, rifle/pistol/revolver are positive and unmirrored -- with zero
	// relationship to hand assignment. That mismatch is why some stored
	// weapons pointed forward, some backward, some sideways: one global
	// guess cannot be right for a mixed-convention arsenal.
	bool   mirrored;
	double bakedAngleOffset;
	double bakedPitchOffset;
	double bakedRollOffset;

	// The model's baked POSITION offset (MODELDEF Offset/ZOffset), from
	// level.GetModelOffsetHint. Different bug from the rotation ones above:
	// this is why a stored weapon did not sit at the actor's own origin, not
	// why it pointed the wrong way. Expressed in the model's own LOCAL axes
	// (pre-rotation) -- the manager rotates it by the same angle/pitch it
	// assigns the actor before applying it, since that offset gets carried
	// along by the actor's rotation in the renderer (r_data/models.cpp: the
	// offset translate is composed INSIDE the actor rotation, not after it).
	double bakedOffX;
	double bakedOffY;
	double bakedOffZ;

	// The model's measured bounding radius (level.GetModelBoundsHint),
	// cached from the last class-change so ShowWeapon can recompute
	// baseScale from it EVERY call, not just when the weapon class
	// changes -- rs_hardpoint_prop_fill/_scale/_scale_arm need to apply
	// live to an already-holstered weapon, not just to the next weapon
	// that gets stored. Re-measuring the model itself every tic would be
	// the expensive part (native call + FindModelFrame lookup); this way
	// only the measurement is class-change-gated, and the cheap arithmetic
	// that turns it into a scale runs unconditionally.
	bool   boundsFound;
	double measuredRadius;

	// Live-tunable rather than baked, for the same reason the anchors are:
	// the right number is found by looking at it in the headset, not by
	// reasoning about model units.
	static double holsterPropScale()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_scale", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.18;
	}

	// Separate, smaller default for the forearm/wrist hardpoints -- a
	// utility item riding a wrist mount should read as compact gear, not a
	// full holstered sidearm. Its OWN cvar rather than reusing
	// rs_hardpoint_prop_scale means tuning one range never shrinks the other.
	static double holsterPropScaleArm()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_scale_arm", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.08;
	}

	// Fraction of the holster's own radius a measured model gets scaled to
	// fill. See CVARINFO.txt for why this is a separate dial from the flat
	// scale/scale_arm fallbacks rather than replacing them.
	static double holsterPropFill()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_fill", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.55;
	}

	// Yaw offset applied to every stored weapon, and a separate 180 for
	// main-hand weapons whose models are mirrored.
	//
	// This comment used to claim pitch and roll DO NOTHING and that yaw was the
	// only axis the renderer honoured. That was never a property of the engine
	// -- it was two stacked content bugs being mistaken for one. RenderModel
	// applies yaw unconditionally but gates pitch on MDL_USEACTORPITCH and roll
	// on MDL_USEACTORROLL, and neither flag was reaching the render table:
	// first because the MODELDEF tokens sat AFTER their FrameIndex lines (each
	// FrameIndex snapshots the flags set so far), and then, after that was
	// fixed, because a backup file named MODELDEF.bak2 in the mod root
	// registered under the same 8-character lump name "MODELDEF", parsed
	// second, and won the frame lookup with its stale flagless entries.
	// All three axes work. Keep this a slider anyway -- the right number is
	// found by looking at it in the headset, not by reasoning about it.
	static double holsterPropYaw()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_yaw", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	// Fallback was 90.0 here while CVARINFO.txt declared the cvar's real
	// default as 0.0 -- two places stating the same default, silently
	// disagreeing. That mattered: GetHolster's own table already defaults
	// EVERY torso holster's hsPitch to 90.0 (barrel down), and edPitch[h]
	// (below, via updateProps/dumpOneHolsterProp) is a straight copy of it
	// -- this cvar is documented as a TRIM on top of that per-holster
	// value, not a second full contribution. At the old 90.0 fallback,
	// clean defaults summed to 180 degrees (90 from the table, 90 again
	// here), not 90 -- nowhere near "points at the floor", and close
	// enough to the flip-over point that per-weapon pitch differences
	// pushed some guns visibly up and others down. 0.0 matches CVARINFO.txt
	// and actually behaves like a trim: does nothing until you move it.
	static double holsterPropPitch()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_pitch", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropRoll()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_roll", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	// Centring nudge, in the body's own frame. A weapon's MODELDEF carries an
	// Offset tuned for the HUD (the chainsaw's is "Offset 0.0 14.0 0.0"), which
	// puts the mesh well away from the actor origin. Scaling then shrinks the
	// model toward that origin rather than toward anything you can see, so it
	// drifts out of the sphere. There is no way to read a MODELDEF Offset from
	// script, so this is a manual correction -- and a slider, because the right
	// value is whatever makes it sit in the ring.
	static double holsterPropUp()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_up", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropFwd()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_fwd", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropSide()
	{
		let cv = CVar.GetCVar("rs_hardpoint_prop_side", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	// Fade instead of a hard bINVISIBLE cut, same mechanism as
	// RS_HardPointMarker (own copy, not shared -- these two classes have no
	// common base below Actor to hang a shared const/method off of).
	const FADE_STEP = 0.125;

	// The store/draw settle pop: a fresh weapon starts slightly OVERSIZED and
	// eases down to its real scale over POP_TICS, instead of just appearing
	// at final size. Pure polish -- POP_OVERSHOOT of 1.0 would make this a
	// no-op, so nothing breaks if these ever need retuning.
	const POP_TICS = 6;
	const POP_OVERSHOOT = 1.35;

	private double fadeAlpha;
	private bool   fadeVisible;
	private double baseScale;
	private int    popTicsRemaining;

	// Set true only by the w==null branch of ShowWeapon, and consumed here
	// once the fade-out actually finishes. The model/sprite reset used to
	// happen IMMEDIATELY on that transition -- but that is exactly what a
	// fade-out needs to still be showing while it plays. Clear on the spot
	// and there is nothing left to fade; defer it and the old weapon fades
	// out looking like itself, then vanishes for real only once Alpha has
	// actually reached 0.
	private bool pendingClear;

	void SetVisible(bool show)
	{
		fadeVisible = show;
		if (show)
			bINVISIBLE = false;
	}

	override void Tick()
	{
		Super.Tick();

		if (fadeVisible)
		{
			fadeAlpha += FADE_STEP;
			if (fadeAlpha > 1.0) fadeAlpha = 1.0;
		}
		else
		{
			fadeAlpha -= FADE_STEP;
			if (fadeAlpha < 0.0) fadeAlpha = 0.0;
			if (fadeAlpha <= 0.0)
			{
				bINVISIBLE = true;
				if (pendingClear)
				{
					ClearModelStateFrames();
					sprite = GetSpriteIndex("TNT1");
					frame = 0;
					pendingClear = false;
				}
			}
		}
		Alpha = fadeAlpha;

		double popMult = 1.0;
		if (popTicsRemaining > 0)
		{
			// (popTicsRemaining * 1.0) rather than a double(...) cast -- no
			// precedent anywhere in this codebase for that cast syntax in
			// ZScript specifically, and no way to test-compile to find out.
			// Multiplying by a double literal forces float promotion using
			// only ordinary arithmetic operator rules, which every C-family
			// language shares regardless of its exact cast syntax.
			double t = 1.0 - ((popTicsRemaining * 1.0) / POP_TICS);
			popMult = POP_OVERSHOOT - ((POP_OVERSHOOT - 1.0) * t);
			popTicsRemaining--;
		}
		Scale = (baseScale * popMult, baseScale * popMult);
	}

	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}

	// Show a weapon, or pass null to go empty/invisible. fallbackScale is
	// always passed in explicitly by the caller (holsterPropScale() or
	// holsterPropScaleArm(), picked per-holster in updateProps) rather than
	// read here via a default parameter value -- no confirmed precedent for
	// user-method default args anywhere in this codebase, and no way to
	// test-compile to find out, so the one call site just always supplies it.
	// holsterRadius is that same holster's hsRadius, passed through so a
	// measured model can be scaled to fill IT specifically rather than some
	// value this method would otherwise have no way to see.
	void ShowWeapon(Weapon w, double fallbackScale, double holsterRadius)
	{
		let wantClass = (w != null) ? w.GetClass() : null;
		if (wantClass != shownClass)
		{
			shownClass = wantClass;

			if (w == null)
			{
				pendingClear = true;   // Tick() clears the model once faded out
				SetVisible(false);
				mirrored = false;
				bakedAngleOffset = 0.0;
				bakedPitchOffset = 0.0;
				bakedRollOffset = 0.0;
				bakedOffX = 0.0; bakedOffY = 0.0; bakedOffZ = 0.0;
				boundsFound = false;
				measuredRadius = 0.0;
				return;
			}

			// The held-weapon frame is the one MODELDEF covers. Ready is where
			// a weapon idles, so it is the pose a holstered gun should sit in.
			State rs = w.FindState("Ready");
			if (rs == null)
			{
				SetVisible(false);
				return;
			}

			pendingClear = false;   // showing something new; any stale deferred clear is moot
			SetVisible(true);
			sprite = rs.sprite;
			frame  = rs.Frame;

			bool found;
			[found, mirrored, bakedAngleOffset, bakedPitchOffset, bakedRollOffset]
				= level.GetModelOrientationHint(w.GetClass(), sprite, frame);
			if (!found)
			{
				mirrored = false;
				bakedAngleOffset = 0.0;
				bakedPitchOffset = 0.0;
				bakedRollOffset = 0.0;
			}

			double stretch = (level.info != null) ? level.info.pixelstretch : 1.0;
			bool foundOff;
			[foundOff, bakedOffX, bakedOffY, bakedOffZ]
				= level.GetModelOffsetHint(w.GetClass(), sprite, frame, stretch);
			if (!foundOff)
			{
				bakedOffX = 0.0; bakedOffY = 0.0; bakedOffZ = 0.0;
			}

			// Measured once per class-change, same as the orientation/offset
			// hints above -- the native call and FindModelFrame lookup are
			// the expensive part. What that measurement is USED for (below)
			// is not gated the same way.
			[boundsFound, measuredRadius] = level.GetModelBoundsHint(w.GetClass(), sprite, frame);

			popTicsRemaining = POP_TICS;   // settle-pop on every fresh show

			// Borrow the weapon's model definition onto this instance. After
			// this, FindModelFrame resolves against the weapon's class rather
			// than RS_HardPointProp, and the (sprite, frame) set above
			// completes the key.
			A_ChangeModel(w.GetClassName());
		}

		if (w == null)
			return;   // still nothing to show; nothing below has anything to recompute

		// A weapon's MODELDEF Scale is tuned for the HUD/psprite path, where
		// the model sits inches from the camera under its own projection. Reuse
		// that scale on a world actor and you get a rifle the size of a car --
		// which is exactly what happened. Shrink it back to something that
		// reads as the same object you were just holding. fallbackScale is
		// that flat shrink, used as-is when there is no real geometry to
		// measure.
		//
		// When there IS real geometry, solve for the scale that makes this
		// SPECIFIC model's measured bounding radius fill a fraction of THIS
		// holster's own radius, instead of applying fallbackScale (a flat
		// number identical for every weapon) regardless of how physically
		// big the model actually is -- a BFG and a pistol stop reading as
		// the same size for no reason other than sharing one constant.
		//
		// Recomputed EVERY call (every tic), not just on a class-change --
		// otherwise rs_hardpoint_prop_fill/_scale/_scale_arm read as dead
		// cvars on any weapon that is already sitting in a holster, since
		// nothing else ever re-solves baseScale for it. Cheap: this is just
		// arithmetic over the cached measurement above, no native call.
		if (boundsFound && measuredRadius > 0.0)
			baseScale = (holsterRadius * holsterPropFill()) / measuredRadius;
		else
			baseScale = fallbackScale;

		// Also write the real Scale here, not just baseScale -- Tick() is
		// the only other writer, and the engine runs WorldTick (this call's
		// caller, updateProps) BEFORE Thinkers.RunThinkers (what actually
		// calls Tick()) every tic, confirmed in p_tick.cpp. updateProps
		// calls GetModelWorldOffset for centering using p.scale.X/Y right
		// after this returns, in the SAME WorldTick pass -- without this
		// line that call would read whatever Scale was left over from
		// LAST tic (a different weapon's size, on a fresh store) instead
		// of the value just solved above. Tick()'s pop-overshoot ramp
		// still overwrites this a moment later; this just makes sure
		// nothing reads a stale, wrong-weapon Scale in the meantime.
		Scale = (baseScale, baseScale);
	}
}
