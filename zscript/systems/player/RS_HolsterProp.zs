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
class RS_HolsterMarker : Actor
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
	// resetting the sprite forever.
	private bool isHot;
	private bool everSet;

	void SetHot(bool hot)
	{
		if (everSet && hot == isHot)
			return;
		isHot = hot;
		everSet = true;

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
		A_ChangeModel('RS_HolsterMarker', 0, "models", 'rs_wiresphere.obj', 0, "models", skinWanted);
	}
}

class RS_HolsterProp : Actor
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

	// Live-tunable rather than baked, for the same reason the anchors are:
	// the right number is found by looking at it in the headset, not by
	// reasoning about model units.
	static double holsterPropScale()
	{
		let cv = CVar.GetCVar("rs_holster_prop_scale", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.18;
	}

	// Yaw offset applied to every stored weapon, and a separate 180 for
	// main-hand weapons whose models are mirrored.
	//
	// This is a slider rather than a derived value because PITCH AND ROLL DO
	// NOTHING: no weapon block in MODELDEF carries USEACTORPITCH/USEACTORROLL,
	// so the renderer ignores those angles entirely and a model can only be
	// turned about the vertical axis. Yaw is the only knob that exists, so it
	// is the one you get to tune.
	static double holsterPropYaw()
	{
		let cv = CVar.GetCVar("rs_holster_prop_yaw", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropPitch()
	{
		let cv = CVar.GetCVar("rs_holster_prop_pitch", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 90.0;
	}

	static double holsterPropRoll()
	{
		let cv = CVar.GetCVar("rs_holster_prop_roll", players[consoleplayer]);
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
		let cv = CVar.GetCVar("rs_holster_prop_up", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropFwd()
	{
		let cv = CVar.GetCVar("rs_holster_prop_fwd", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	static double holsterPropSide()
	{
		let cv = CVar.GetCVar("rs_holster_prop_side", players[consoleplayer]);
		return (cv != null) ? cv.GetFloat() : 0.0;
	}

	States
	{
	Spawn:
		TNT1 A -1;
		Stop;
	}

	// Show a weapon, or pass null to go empty/invisible.
	void ShowWeapon(Weapon w)
	{
		let wantClass = (w != null) ? w.GetClass() : null;
		if (wantClass == shownClass)
			return; // already showing this; rebinding every tic is pure cost

		shownClass = wantClass;

		if (w == null)
		{
			ClearModelStateFrames();
			sprite = GetSpriteIndex("TNT1");
			frame = 0;
			bINVISIBLE = true;
			mirrored = false;
			bakedAngleOffset = 0.0;
			bakedPitchOffset = 0.0;
			bakedRollOffset = 0.0;
			bakedOffX = 0.0; bakedOffY = 0.0; bakedOffZ = 0.0;
			return;
		}

		// The held-weapon frame is the one MODELDEF covers. Ready is where a
		// weapon idles, so it is the pose a holstered gun should sit in.
		State rs = w.FindState("Ready");
		if (rs == null)
		{
			bINVISIBLE = true;
			return;
		}

		bINVISIBLE = false;
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

		// A weapon's MODELDEF Scale is tuned for the HUD/psprite path, where
		// the model sits inches from the camera under its own projection. Reuse
		// that scale on a world actor and you get a rifle the size of a car --
		// which is exactly what happened. Shrink it back to something that
		// reads as the same object you were just holding.
		double s = holsterPropScale();
		scale = (s, s);

		// Borrow the weapon's model definition onto this instance. After this,
		// FindModelFrame resolves against the weapon's class rather than
		// RS_HolsterProp, and the (sprite, frame) set above completes the key.
		A_ChangeModel(w.GetClassName());
	}
}
