-- Playbook: SWEP (scripted weapon). Loaded only when the planner tags a task
-- kind = "swep", so it can afford to be deep.

return [====[
# Playbook: Building a SWEP

A SWEP is shared code — it needs a server half (logic) and a client half (rendering/prediction), so build the ENTIRE definition in ONE `run_shared_lua` call: the full `SWEP` table plus its `weapons.Register(SWEP, "class")`. Never split it across calls or realms; clients would receive a half-defined, broken weapon.

## 1. The slot contract
A weapon feels broken when a slot is left empty, NOT when the logic is wrong. Fill **every** slot below; only deviate where the task specifically demands it.

| Slot | Fill with | If you omit it |
|---|---|---|
| `Base` | `"weapon_base"` | you inherit nothing — no deploy, no reload, no ammo handling |
| `PrintName` | a readable name | shows the class name |
| `Spawnable = true`, `Category` | so players can actually get it | it never appears in the spawn menu |
| `Slot` (0-5), `SlotPos` | a sensible weapon-wheel position | collides with other weapons |
| `ViewModel`, `WorldModel` | real `.mdl` paths — **verify with `is_valid_model`** | giant red ERROR sign in the player's hands |
| `UseHands = true` | required for any `c_*.mdl` viewmodel | floating gun, no arms |
| **`HoldType`** | `"pistol"`, `"smg"`, `"ar2"`, `"shotgun"`, `"rpg"`, `"grenade"`, `"melee"`, `"knife"`, `"crossbow"`, `"revolver"`, `"physgun"`, `"passive"` | **the player holds it wrong in third person — the single most common "looks broken" bug** |
| `Primary` / `Secondary` | `{ClipSize, DefaultClip, Automatic, Ammo}` | infinite-fire or no-fire weirdness |
| `Primary.Ammo` | a real ammo type: `"pistol"`, `"smg1"`, `"ar2"`, `"buckshot"`, `"357"`, `"XBowBolt"`, `"SMG1_Grenade"`, or `""` with `ClipSize = -1` for an ammo-less weapon | reload silently does nothing |

Lifecycle methods: `Initialize`, `Deploy`, `Holster`, `PrimaryAttack`, `SecondaryAttack`, `Reload`, `Think`.

## 2. The four feedback channels
An attack that only applies damage is invisible and feels dead. **Every shot must fire on all four channels**, whatever the weapon does:
1. **Sound** — `self:EmitSound("weapons/...")`. A silent weapon always reads as broken.
2. **Animation** — `self:SendWeaponAnim(ACT_VM_PRIMARYATTACK)` (viewmodel) **and** `owner:SetAnimation(PLAYER_ATTACK1)` (third person). Both, every shot.
3. **Recoil** — `owner:ViewPunch(Angle(-1, 0, 0))`, scaled to the weapon's power.
4. **World impact** — something visible where the shot lands: a tracer, decal, particle, or effect.

**Prefer `self:FireBullets({...})` for anything hitscan.** It gives you damage, tracer, impact decal, impact sound, and force in one predicted call — channel 4 for free. Hand-rolling `util.TraceLine` + `TakeDamage` is the usual cause of "it works but I see nothing".
```lua
self:FireBullets({
  Num = 1, Src = owner:GetShootPos(), Dir = owner:GetAimVector(),
  Spread = Vector(0.02, 0.02, 0), Tracer = 1, Force = 5, Damage = 15,
})
```
For non-hitscan weapons (projectiles, beams, magic), you still owe channel 4 — spawn the projectile, draw the beam, or `util.Effect(...)` at the impact point. Offset a projectile's spawn position forward so it doesn't clip the player.

## 3. Impact floors — a weapon has to hit HARD
A weapon that fires correctly but feels limp is the most common failure. Numbers decide this, and the safe-looking small number is almost always wrong. Unless the task says otherwise:

| Thing | Floor |
|---|---|
| Damage | a weapon that kills should do **35-100** per hit; a rapid-fire one **12-25**. Single-digit damage feels broken |
| Explosive radius | **150-350 units**, with `util.BlastDamage` so it actually affects everything in range |
| Knockback / force | `FireBullets` `Force = 5-20`; explosions apply `ApplyForceCenter` in the **10000-50000** range on props — small forces look like nothing happened |
| View punch | **-1 to -4** degrees pitch for a rifle, more for a cannon; add slight random yaw so repeat shots differ |
| Projectile speed | **1500-3500** units/s, and it must **arc under gravity** unless it's a laser |
| Fire rate | match the weapon's character — don't leave a hand cannon at 0.1s |
| Muzzle/impact effect | every shot gets a visible one; see the effect richness floors — a 10-particle impact is a fizzle |

If a weapon shoots something (fireworks, grenades, magic), **the projectile's effect is the whole point of the weapon** — it deserves more effort than the weapon plumbing, not less. Give it a trail (`util.SpriteTrail`), an arcing physics trajectory, and a burst on impact in the 100-250 particle range.

## 4. Prediction (the "acts weird" bugs)
Shared SWEP code runs on the server once and re-runs on the owning client many times per shot.
- Gate the fire rate with `self:SetNextPrimaryFire(CurTime() + delay)` — omit it and the weapon fires every single tick.
- Spend ammo with `self:TakePrimaryAmmo(1)`.
- Use `self:GetOwner()`, never `self.Owner`, and check it with `IsValid` before using it.
- `EmitSound`, `SendWeaponAnim`, `ViewPunch` and `FireBullets` are already predicted — call them plainly, do NOT wrap them in `if SERVER then`.
- Anything NOT predicted (spawning entities, `util.Effect`, `timer.Create`, `math.random` that must agree across realms) must be guarded: `if IsFirstTimePredicted() then ... end`, and entity spawning additionally with `if SERVER then`.
- `Think` runs constantly on both realms — drive it off `CurTime()`, never a per-call counter.

## Before you run it
- Every slot filled — especially `HoldType`, `UseHands`, `Slot`/`SlotPos`, `Category`, and models verified with `is_valid_model`?
- Every attack firing on all four channels?
- **Every impact floor met** — damage, force, view punch, projectile speed and arc?
- **If it fires a projectile, does that projectile look good** (trail, arc, rich impact burst) rather than being an afterthought?
- Hitscan going through `FireBullets` rather than a hand-rolled trace?
- Every non-predicted call guarded?

A weapon that passes its logic but skips these is a FAILED task, not a finished one — it will look and feel broken to the player.
]====]
