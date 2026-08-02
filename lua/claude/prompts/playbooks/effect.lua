-- Playbook: visual effects — beams, glows, particles, screen effects. Loaded only
-- when the planner tags a task kind = "effect".

return [====[
# Playbook: Building a Visual Effect

Effects are judged on how they LOOK. A single flat draw with a random texture always looks cheap. Two rules decide almost everything.

## 1. Additive, or it looks broken
A material that isn't additive/translucent renders as a **black box** around your sprite — this is the #1 cause of "ugly texture with no alpha". Glow, beam, and energy effects MUST use an additive material. Known-good engine materials (verify with `is_valid_material`, and prefer these over guessing a path):
- Glows/sprites: `sprites/light_glow02_add`, `sprites/glow04_noz` (`_noz` = draws through walls), `sprites/orangecore1`, `particle/particle_glow_04`
- Beams/trails: `trails/laser`, `trails/plasma`, `trails/electric`, `trails/smoke`, `sprites/physbeam`, `effects/laser1`
- Impacts/sparks: `effects/spark`, `effects/blueflare1`, `particle/fire`, `particle/particle_smokegrenade`, `particle/smokesprites_0001`

Use a **saturated color, never pure white** — additive blending brightens toward white on its own, so a white sprite just blows out.

## 2. Layer it — never one draw
An intricate effect is 3-5 cheap layers stacked, not one clever one. For any energy/laser/magic effect, build:
1. **Core** — a thin, bright beam or sprite (the shape).
2. **Glow** — the same shape drawn 3-4x wider at low alpha, additive (the softness). This one layer is most of the visual quality.
3. **Light** — a `DynamicLight` at each end so it lights the world and feels real.
4. **Impact** — particles/sparks/decal where it lands.
5. **Motion** — never fully static: fade alpha, scale width, or scroll the texture over the effect's lifetime.

## 3. Richness floors — these are minimums, not targets
The most common failure is a technically-correct effect that is far too SPARSE. Ten particles is not a burst, it's a fizzle. Unless the task explicitly asks for something subtle, meet these:

| Thing | Floor |
|---|---|
| Burst / explosion / firework | **100-250 particles**, emitted across **2-3 passes** with different materials (bright core sprites + smoke + sparks) |
| Ambient / trail emission | **8-20 particles per tick**, not 1-2 |
| Particle velocity | **radial and randomized**: `VectorRand() * math.Rand(150, 450)` — never a single shared direction, never a constant magnitude |
| Particle lifetime | **varied**: `math.Rand(0.6, 2.0)` — a constant `SetDieTime` makes everything vanish at once, which reads as fake |
| Particle size | **varied**, and always shrinking: `SetStartSize(math.Rand(6, 14))`, `SetEndSize(0)` |
| Colour | **varied per particle** (`math.Rand` the channels ±40) — a single flat colour looks like a texture, not fire |
| Any explosion/impact | at least **one `DynamicLight` flash** + **2 sounds at different pitches** (`SetSoundLevel`/pitch varied) |
| Beam | core + glow, and the glow is **3-4x the core width** at **40-90 alpha** |
| Effect lifetime | nothing static — alpha, size, or texture scroll changes over **the whole lifetime** |

If you find yourself writing `for i = 1, 10 do` for a burst, that is the bug. Multiply it by ten.

## Motion is not linear
Real effects accelerate, decelerate, spread, and fall. A projectile that travels in a straight line at constant speed looks fake no matter how good the particles are.
- Give projectiles **gravity** — a physics object, or subtract from velocity Z each tick.
- Give particles `SetGravity(Vector(0, 0, -300))` and `SetAirResistance(40-120)` so they arc and slow.
- Spread a burst over **a few frames** rather than emitting everything on one tick, when it should feel like it's expanding.

## Drawing in the world
3D effects go in `PostDrawTranslucentRenderables` (or an entity's `Draw`), **never** `HUDPaint` — that is 2D screen space only and 3D draws will not appear correctly there.
```lua
render.SetMaterial(Material("trails/laser"))
render.DrawBeam(startPos, endPos, width, 0, 1, color)   -- width, texStart, texEnd, color
render.DrawSprite(pos, size, size, color)               -- billboarded glow
```
Curved/segmented beams: `render.StartBeam(n)` / `render.AddBeam(pos, width, texCoord, color)` / `render.EndBeam()`.

## Dynamic light (client) — cheap, huge win for anything energetic
```lua
local dl = DynamicLight(entIndex)
dl.Pos, dl.r, dl.g, dl.b = pos, 80, 160, 255
dl.Brightness, dl.Size, dl.Decay, dl.DieTime = 3, 240, 1000, CurTime() + 0.1
```

## Particles
The knobs that separate good from bad are the *end* values and the drag. Always set start/end alpha AND start/end size so particles fade and shrink instead of popping out of existence; add `SetAirResistance` so they decelerate naturally, `SetGravity` for weight, `SetRollDelta` for spin, and `SetLighting(false)` on glowing particles so the map doesn't darken them. Prefer 2D emitters: `ParticleEmitter(pos)`, not `ParticleEmitter(pos, true)`. Always `:Finish()` the emitter.

## Free high-quality effects — prefer these when they fit
- `util.Effect("Explosion"|"cball_explode"|"ElectricSpark"|"MetalSpark"|"AR2Impact"|"StunstickImpact"|"GlassImpact"|"ThumperDust", effectdata)` — server-side, auto-broadcast, engine-quality.
- `util.SpriteTrail(ent, 0, color, true, startWidth, endWidth, lifetime, 1/(startWidth+endWidth)*0.5, "trails/laser.vmt")` — server-side; the easiest way to make any projectile look good.

## Screenspace effects
Client, in the `RenderScreenspaceEffects` hook: `DrawBloom`, `DrawBokehDOF`, `DrawColorModify`, `DrawMaterialOverlay`, `DrawMotionBlur`, `DrawSharpen`, `DrawSobel`, `DrawSunbeams`, `DrawTexturize`, `DrawToyTown`.

## Before you run it
- Every glow/beam material additive and verified with `is_valid_material`?
- **Every richness floor met?** Count your particles — is a burst in the 100-250 range, not 10?
- **Velocities, lifetimes, sizes and colours randomized per particle**, not constant?
- **Motion non-linear** — gravity and air resistance applied, projectiles arcing?
- Layered — core, wider low-alpha glow, dynamic light, impact — rather than a single flat draw?
- Changing over its lifetime (alpha, size, or scrolling texture) instead of sitting static?
- 3D rendering in `PostDrawTranslucentRenderables` or an entity `Draw`, not `HUDPaint`?
- Anything that spawns or removes itself cleaned up when it expires?

One draw with one texture is the difference between "works" and "looks good" — spend the extra layers. When unsure how a `render.` function is called, `search_wiki` it; that library is easy to get subtly wrong.
]====]
