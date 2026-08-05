-- Basically for all world-space shaders, or things that aren't specifically screen-space
-- AI-generated playbook. Don't judge, the smaller models tend to work better if another
-- LLM tells it. I think it's the AI dashes and markdown.

return [====[
# Appendix: custom shader materials on props and geometry

You also have `compile_shader`, which compiles real HLSL and returns a material path. Use it when the look genuinely needs **per-pixel or per-vertex maths on a surface** — dissolving, holograms, force fields, energy skins, iridescence, vertex wobble, x-ray. For a plain glow, a coloured light or a sprite, do **not** reach for this; `DynamicLight`, sprites and `render.DrawBeam` are cheaper and look better.

## Pick the usage to match how you draw it
`usage` declares what vertex data exists. If it disagrees with the draw call the vertex format mismatches and **nothing renders — silently, with no error.**

| `usage` | draw it with | vertex data |
|---|---|---|
| `model` | `ent:SetMaterial(path)` then `ent:DrawModel()` | POSITION, TEXCOORD0, **NORMAL0** |
| `mesh` | `mesh.Begin` then `m:Draw()` | POSITION, TEXCOORD0, **COLOR0** |
| `primitive` | `render.DrawSphere` / `DrawBox` | POSITION, TEXCOORD0 only |

All three **require `vertex_source`**. There is no fixed-function path — with no vertex shader, nothing projects the geometry and you get a blank screen.

## The vertex shader
```hlsl
#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 vPos      : POSITION;
    float4 vTexCoord : TEXCOORD0;
    float3 vNormal   : NORMAL0;      // usage = "model" only
};

struct VS_OUTPUT {
    float4 proj_pos : POSITION;      // REQUIRED, first
    float2 uv       : TEXCOORD0;
    float3 normal   : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT vert)
{
    float3 world_pos, world_normal;
    SkinPositionAndNormal(0, vert.vPos, vert.vNormal, 0, 0, world_pos, world_normal);

    float t = cAmbientCubeX[0].x;                  // see constants below
    world_pos += world_normal * sin(t) * 2.0;      // vertex animation goes here

    VS_OUTPUT o = (VS_OUTPUT)0;
    o.proj_pos = mul(float4(world_pos, 1), cViewProj);
    o.uv       = vert.vTexCoord.xy;
    o.normal   = world_normal;
    return o;
}
```
Use `SkinPosition(0, vert.vPos, 0, 0, world_pos)` when you do not need normals. **You cannot sample a texture in a vertex shader.**

## Vertex animation needs vertices
**A vertex shader can only move vertices that already exist.** It cannot subdivide
anything. `models/hunter/blocks/cube025x025x025.mdl` is a cube: 8 corners. Pushing
8 corners along their normals makes a slightly bigger cube, not jelly — the effect
is invisible no matter how good the maths is.

Before writing a deformation shader, ask how much geometry the surface has:
- **Dense organic models** (players, ragdolls, spheres, plants) deform well.
- **Blocky props** (crates, cubes, boards, most `props_c17`) have almost no
  interior vertices and will barely move.
- **`usage = "mesh"` is the reliable answer** when the deformation IS the effect.
  You control the tessellation, so build a grid with enough subdivisions:

```lua
-- A 16x16 grid has 289 vertices to push around; a cube has 8.
local STEPS = 16
mesh.Begin(m, MATERIAL_TRIANGLES, STEPS * STEPS * 2)
for x = 0, STEPS - 1 do
    for y = 0, STEPS - 1 do
        -- two triangles per cell, positions spanning the surface you want
    end
end
mesh.End()
```

Rule of thumb: if the request is jelly, cloth, water, waving, melting or
breathing, **either pick a dense model or build a mesh.** Putting a deformation
shader on a cube produces a shader that compiles, mounts, renders — and looks
like nothing happened.

## Textures — you choose what is bound
Samplers must be declared at COMPILE time. `mat:SetTexture(...)` from Lua afterwards
is **silently ignored**: the material only enables a sampler that the VMT declared.
Pass them to `compile_shader`:

```
textures = {
  basetexture = "phoenix_storms/wood",        -- sampler s0
  texture1    = "models/debug/debugwhite",    -- sampler s1
}
```
Read them in the pixel shader by register:
```hlsl
sampler Base  : register(s0);
sampler Extra : register(s1);
```
Four slots exist: `basetexture`, `texture1`, `texture2`, `texture3`. Anything on s1+
is bound with a linear read, so a texture used as *data* is not gamma-mangled.

Defaults if you pass nothing: the rendered frame for `usage = "screen"`, and a plain
white texture otherwise — which is why sampling `basetexture` on a model and getting
pure white means you forgot to ask for a real one.

**Refraction on a model is not solved by binding the framebuffer.** `_rt_FullFrameFB`
is accepted, but a full-frame render target on a material drawn *during* the scene is
not something the reference examples ever do, and it is a suspect in an earlier case
where geometry rendered nothing at all. For a refractive look that reliably works,
distort a texture you control rather than the live frame, or do the refraction as a
`usage = "screen"` pass where the framebuffer is the intended input.

## Screen-space sampling from a model (refraction, glass, cloaking)
Sampling a texture at the model's OWN uv is not refraction — it just draws that
texture on the surface. **Refraction means sampling what is BEHIND the object**,
which needs the frame, at SCREEN coordinates.

The pixel shader has no screen position unless the vertex shader hands it one.
Pass a copy of the projected position through a TEXCOORD:
```hlsl
// vertex shader
struct VS_OUTPUT {
    float4 proj_pos : POSITION;
    float3 normal   : TEXCOORD0;
    float4 screen   : TEXCOORD1;   // copy of proj_pos
};
...
float4 pp = mul(float4(world_pos, 1), cViewProj);
o.proj_pos = pp;
o.screen   = pp;
```
```hlsl
// pixel shader — perspective divide, then NDC -> 0..1 with the y flip
float2 uv   = frag.screen.xy / frag.screen.w * float2(0.5, -0.5) + 0.5;
float3 refr = tex2D(FrameBuf, saturate(uv + normalize(frag.normal).xy * 0.06)).rgb;
```
Bind the frame with `textures = { basetexture = "_rt_FullFrameFB" }`, and the Lua
must call `render.UpdateScreenEffectTexture()` before drawing the model — that RT
is empty otherwise, and you sample black.

**Verified working on models.** The Lua side, in full:
```lua
ent:SetMaterial("gm_claude/shaders/<returned path>")

hook.Add("PostDrawOpaqueRenderables", "refractive", function(_, _, sky3d)
    if sky3d then return end
    render.UpdateScreenEffectTexture()      -- fills _rt_FullFrameFB; without it you sample black
    ClaudeShader.DrawWithDepth(function() ent:DrawModel() end)
end)
```
`render.UpdateScreenEffectTexture()` works from inside that hook — the frame so far
is what gets sampled, which is exactly what you want behind a refractive surface.

Two consequences worth knowing. The object cannot refract itself or anything drawn
after it, so overlapping refractive props sample each other inconsistently. And the
offset is in screen space, so a large `normal.xy * k` visibly smears rather than
bending — keep `k` around 0.02-0.08.

## Transparency
Alpha returned from the pixel shader is **ignored unless the material is declared
translucent**, and that has to happen at compile time — `mat:SetInt("$translucent", 1)`
from Lua is too late and silently does nothing. Pass `translucent = true` to
`compile_shader` for glass, jelly, holograms, force fields or anything that should
show what is behind it.

## The pixel shader
`PS_INPUT` must mirror `VS_OUTPUT` **minus POSITION**, in the same order. A mismatch gives garbage, not a compile error.
```hlsl
#include "common_ps_fxc.h"

struct PS_INPUT {
    float2 uv     : TEXCOORD0;
    float3 normal : TEXCOORD1;
};

float4 main(PS_INPUT frag) : COLOR
{
    float3 col = frag.normal * 0.5 + 0.5;
    return FinalOutput(float4(col, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
```
End with `FinalOutput` or colours come out wrong under HDR.

## Drawing it
```lua
local mat = "gm_claude/shaders/<returned path>"

-- On a prop: the override goes ON THE ENTITY, and it must be set SERVER-side.
-- SetMaterial is a NETWORKED property. Calling it only on the client is a local
-- override that the next entity update replaces with the server's value (empty),
-- so the prop silently reverts to its own texture.
if SERVER then ent:SetMaterial(mat) end   -- render.SetMaterial does NOT affect DrawModel

-- Drawing it yourself, from a 3D hook:
hook.Add("PostDrawOpaqueRenderables", "my_fx", function(_, _, sky3d)
    if sky3d then return end
    ClaudeShader.SetVertexConstants({Vector(CurTime(), power, 0)})
    ClaudeShader.DrawWithDepth(function()
        ent:DrawModel()
    end)
end)
```

**On a scripted entity, draw it in `DrawTranslucent`, not a global hook.** The
engine calls that during the translucent pass — after opaque geometry, which is
exactly when the framebuffer holds the scene you want to refract:
```lua
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

function ENT:Initialize()
    -- SERVER, not CLIENT: SetMaterial is networked, and a client-only override is
    -- overwritten by the next entity update. This is why a prop can render with
    -- its own texture even though the shader compiled and mounted fine.
    if SERVER then
        self:SetMaterial("gm_claude/shaders/<returned path>")
        -- ... physics setup ...
    end
end

function ENT:DrawTranslucent()
    render.UpdateScreenEffectTexture()
    ClaudeShader.DrawWithDepth(function() self:DrawModel() end)
end
```
Do **not** leave `Draw`/`DrawTranslucent` empty and render from a
`PostDrawTranslucentRenderables` hook that walks `ents.FindByClass`. It works, but
the entity then has no fallback: if anything about the hook is wrong the prop is
completely invisible while still being solid and grabbable, which is much harder to
diagnose than a prop that draws with the wrong look.

## Beams, lasers and energy quads
A beam drawn with `render.DrawQuad` is `usage = "primitive"`, and two things decide
whether it looks like energy or like a dark rectangle stuck to your screen.

**1. Use `additive = true`.** The result is added to what is behind it, so black is
transparent for free and bright areas glow. This is why the stock `_add` sprites
look right. With ordinary blending, every dark pixel of your quad occludes the
world — that is what makes a beam read as "a black background obscuring vision".

**2. Generate the beam from `uv`. Do not sample a texture for it.** The quad's uv
runs 0..1 along and across the beam, and that is all you need:
```hlsl
float across = abs(frag.uv.y * 2.0 - 1.0);        // 0 at the centreline, 1 at the edges
float core   = pow(saturate(1.0 - across), 6.0);  // tight bright centre
float glow   = pow(saturate(1.0 - across), 1.5);  // wide soft falloff
float flicker = 0.85 + 0.15 * sin(frag.uv.x * 40.0 - C0.x * 30.0);
```

**Chromatic aberration means evaluating that function three times, slightly apart —
not `tex2D` at three offsets.** There is no framebuffer bound to a quad, so
offsetting a sampler just returns the same flat texture three times and nothing
visible happens:
```hlsl
// WRONG on a quad: basetexture defaults to flat white, so r == g == b.
float r = tex2D(BeamTex, uv + float2(0.02, 0)).r;

// RIGHT: split the shape itself.
float shift = 0.06;
float cr = pow(saturate(1.0 - abs((frag.uv.y + shift) * 2.0 - 1.0)), 6.0);
float cg = pow(saturate(1.0 - abs( frag.uv.y          * 2.0 - 1.0)), 6.0);
float cb = pow(saturate(1.0 - abs((frag.uv.y - shift) * 2.0 - 1.0)), 6.0);
float3 col = float3(cr, cg, cb) * intensity * flicker;
```
That gives real red/blue fringing on the beam's edges, because the three channels
have genuinely different shapes.

**To distort the world around the beam** — heat-haze, a lensing look — that is
refraction, not aberration: bind `_rt_FullFrameFB`, use the screen-space uv from
the section above, and offset the sample. Sampling the beam's own uv can never
distort anything behind it.

## Non-negotiables
1. **`usage` must match the draw call.** Mismatch = nothing renders, no error.
2. **`o.proj_pos = mul(float4(world_pos, 1), cViewProj)`** — without it nothing reaches the screen.
3. **`SkinPosition`/`SkinPositionAndNormal` first.** `vert.vPos` is model space; projecting it raw puts everything at the world origin.
4. **`ent:SetMaterial(path)` for models.** `render.SetMaterial` only affects `render.*` calls, and getting it wrong silently draws the normal texture.
5. **`ClaudeShader.SetVertexConstants({...})` every frame** if the vertex shader reads `cAmbientCubeX`. There are no real vertex constants — `$cN_*` reach the PIXEL shader only. Up to 6 Vectors.
6. **`ClaudeShader.DrawWithDepth(fn)`** around manual draws, or geometry sorts wrongly through walls.
7. **Draw from a 3D hook**, skipping the 3D-skybox pass.
8. `$c0_x`..`$c3_w` via `mat:SetFloat` reach the pixel shader, read as `C0.x`..`C3.w`.
9. **Deformation needs geometry.** A vertex shader cannot subdivide. On a cube or a
   crate it does nothing visible — use a dense model or `usage = "mesh"`.
10. **`translucent = true` at compile time** for anything see-through. Alpha is
    ignored otherwise, and setting `$translucent` from Lua is too late.

`compile_shader` returns a `rendered` field describing what actually appeared on screen. Read it — if it says invisible or blown out, fix and recompile before moving on.
]====]
