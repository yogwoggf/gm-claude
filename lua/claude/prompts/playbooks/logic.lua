-- Playbook: game logic — hooks, spawning, physics, damage, timers. The fallback
-- kind when a task isn't a SWEP/SENT/effect/UI.

return [====[
# Playbook: Building Game Logic

Server-realm work: spawning, physics, damage, health/gravity, hooks, timers, rules.

## Hooks
- `hook.Add(event, "unique.identifier", fn)` — **always** use a unique, descriptive identifier string. Re-running with the same name replaces the old hook (good, and how you avoid duplicates); an unnamed or colliding one silently clobbers someone else's.
- Return a value only when the hook documents one — returning `true` from the wrong hook can suppress core game behavior.
- Keep per-frame hooks (`Think`, `Tick`) cheap: no `ents.FindBy*` every frame; cache and refresh on a timer instead.
- If your feature should be removable, pick a hook name you can `hook.Remove` later.

## Entities
- `ents.Create` is SERVER only, and you must call `:Spawn()` (and usually `:Activate()`) or it does nothing.
- Verify models with `is_valid_model` before spawning.
- **Always `IsValid(ent)`** before touching an entity you stored earlier — it may have been removed since. This is the single most common source of runtime errors.
- Clean up: `SafeRemoveEntityDelayed(ent, seconds)` for anything temporary. There is a hard 8192 entity limit, so batch large spawns and never spawn per-frame.
- Physics: `ent:GetPhysicsObject()` then `IsValid(phys)` before `ApplyForceCenter`/`SetVelocity` — a prop with no physics object returns an invalid one.

## Players
- Iterate with `player.GetAll()`; validate before use.
- Damage via `ent:TakeDamage(amount, attacker, inflictor)`, or build a `DamageInfo` for control over type and force.
- Movement/stat changes (`SetHealth`, `SetGravity`, `SetWalkSpeed`) are server-side and network automatically.

## Timers
- `timer.Simple(delay, fn)` for one-shots; `timer.Create(name, delay, reps, fn)` when you need to cancel or repeat it.
- Anything a timer captures may be invalid by the time it fires — re-check `IsValid` **inside** the callback, not just outside.
- `timer.Remove(name)` when the feature is torn down, or it keeps firing (and erroring) forever.

## Networking to clients
Server state is invisible to the client. To drive anything visual: `util.AddNetworkString("name")` once on the server, then `net.Start`/`net.Send`/`net.Broadcast`, with a matching `net.Receive` on the client. Or set a networked var on an entity and read it clientside.

## Before you run it
- Every stored entity re-checked with `IsValid` at the point of use, including inside timer callbacks?
- Hooks given unique identifiers?
- Anything temporary cleaned up (entity removal, `timer.Remove`, `hook.Remove`)?
- Anything the player is supposed to SEE either networked to the client or done in a client realm?
]====]
