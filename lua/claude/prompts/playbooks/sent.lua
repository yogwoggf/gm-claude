-- Playbook: SENT (scripted entity). Loaded only when the planner tags a task
-- kind = "sent".

return [====[
# Playbook: Building a SENT

A SENT is shared code — it needs a server half (logic) and a client half (rendering), so build the ENTIRE definition in ONE `run_shared_lua` call: the full `ENT` table plus its `scripted_ents.Register(ENT, "class")`. Never split it across calls or realms; clients would receive a half-defined, broken entity.

## The slot contract
- `ENT.Type = "anim"` and `ENT.Base = "base_gmodentity"` for the usual physics-prop-like entity.
- `ENT.PrintName`, `ENT.Category`, `ENT.Spawnable = true` — without `Spawnable` it never appears in the spawn menu.
- `ENT.Author` / `ENT.Purpose` are optional polish.

## Lifecycle
- `Initialize` (SERVER): `SetModel` (verify the path with `is_valid_model`), then `PhysicsInit(SOLID_VPHYSICS)`, `SetMoveType(MOVETYPE_VPHYSICS)`, `SetSolid(SOLID_VPHYSICS)`, then wake the physics object:
  ```lua
  local phys = self:GetPhysicsObject()
  if IsValid(phys) then phys:Wake() end
  ```
  Skip the physics init and the entity will float in place, unmovable and lifeless.
- `Think` (SERVER): do the work, then `self:NextThink(CurTime() + n) return true` — omit that and it silently stops ticking after one frame.
- `Draw` (CLIENT): call `self:DrawModel()`, adding any custom rendering around it.
- `Use(activator, caller)` (SERVER): player interaction.
- `OnTakeDamage(dmginfo)` (SERVER): damage response — call `self:TakePhysicsDamage(dmginfo)` if it should react physically.
- `OnRemove`: clean up anything you created — timers, hooks, sounds, child entities. A SENT that leaves a `timer.Create` running after removal will error every tick forever.

## Networking state
Never assume a server-set field exists on the client — they are separate Lua states. Use either:
- `SetupDataTables` + `self:NetworkVar("Int", 0, "Charge")` → gives you `SetCharge`/`GetCharge` on both realms (preferred), or
- NWVars: `self:SetNWInt("charge", n)` / `self:GetNWInt("charge", 0)`.

Set them on the SERVER; read them anywhere.

## Before you run it
- `Spawnable`, `Category`, `Type`, and `Base` all set?
- Physics initialized and woken in `Initialize`?
- `Think` returning `true` after `NextThink`?
- Any client-visible state actually networked, not just assigned to `self`?
- `OnRemove` cleaning up everything the entity created?
]====]
