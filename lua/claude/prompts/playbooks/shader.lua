-- Playbook: custom screenspace pixel shaders (HLSL -> compiled .vcs, mounted at
-- runtime). Loaded only when the planner tags a task kind = "shader".

return [====[
# Playbook: Building a Custom Screenspace Shader

You can compile real HLSL pixel shaders and run them over the whole screen. This is the only way to get effects the `render` library cannot express — per-pixel distortion, colour grading, edge detection, pixelation, CRT/VHS looks, kaleidoscope, heat haze.

## Scope — read this first
The limit is on **what surface you can shade**, not on what you can compute. You get one full-screen pass, and inside it you may do arbitrary per-pixel maths.

**You CAN** — and should not refuse — anything that resolves to a fullscreen pass:
- Post-processing the rendered frame (grading, distortion, blur, edge detection).
- **Raymarching a 3D scene**: volumetric clouds, fog, god rays, SDF geometry, tunnels, fractals. You reconstruct a camera ray per pixel, march it, and composite the result over the frame. This is a normal, expected use of a screenspace shader — see the raymarching section below.
- Anything procedural drawn over the screen: starfields, plasma, moving patterns.

- **Shaders on props and entities** — pass `usage = "model"` with a vertex shader. Glowing, dissolving, vertex-animated, custom-lit materials on real models.
- **Procedural geometry** — pass `usage = "mesh"` and build vertices with `mesh.Begin`.

**You CANNOT**:
- Shade a brush (world geometry) — only models, meshes and the fullscreen pass.
- Sample a texture inside a **vertex** shader. Only the pixel shader can.
- Bind arbitrary textures — but you get two useful ones: `$basetexture` (the frame) always, and the scene depth buffer on sampler s1 when you pass `scene_depth = true`.

If the look can be done with `DrawColorModify`, `DrawBloom`, `DrawMotionBlur`, `DrawSharpen`, `DrawSobel`, `DrawToyTown` or `DrawTexturize`, **use those** — they are free and instant. Reach for a custom shader when the request needs per-pixel maths those cannot do.

## Build the requested effect and nothing else
**Chromatic aberration, scanlines, film grain, vignette, barrel distortion and colour fringing are specific looks, not general polish.** Add one only when the request actually names it, or names something that plainly implies it ("old TV", "VHS", "retro", "damaged tape", "CRT").

The failure mode to avoid is garnish: bolting retro artifacts onto an effect that never asked for them. "Make everything blue" means tint it blue — not tint it blue with scanlines, aberration and a vignette. Garnishing makes every shader look like the same washed-out VHS filter, and it is worse than doing nothing because it buries the effect that was actually requested.

One effect, done well, beats four stacked. If you are unsure whether something belongs, leave it out.

## The workflow — two steps, in this order
1. `compile_shader` with your HLSL. It compiles, packs, ships and mounts on every client, then returns a `material` path.
2. `run_client_lua` that calls `Material(<that path>)` and draws it.

**Never call `Material()` on the path before `compile_shader` has returned.** Source caches a failed material lookup permanently for that name — if you race it, that material is poisoned for the rest of the client's session and no amount of re-running fixes it.

## The shader contract
Your source must declare its own inputs. This is the exact surface GMod's `screenspace_general` provides:

```hlsl
sampler TexBase : register(s0);   // $basetexture = the rendered frame
sampler Tex1    : register(s1);
sampler Tex2    : register(s2);
sampler Tex3    : register(s3);

float4 C0 : register(c0);   // $c0_x, $c0_y, $c0_z, $c0_w
float4 C1 : register(c1);   // $c1_*
float4 C2 : register(c2);   // $c2_*
float4 C3 : register(c3);   // $c3_*

struct PS_INPUT
{
    float2 uv : TEXCOORD0;  // 0..1 across the screen, (0,0) = top-left
};

float4 main(PS_INPUT i) : COLOR
{
    float3 col = tex2D(TexBase, i.uv).rgb;
    return float4(col, 1.0);
}
```

- Entry point is **`main`**, returning **`float4 : COLOR`**. Nothing else works.
- `TexBase` holds the frame as it looked before your pass. Sampling it is how you post-process.
- **Return alpha 1.0** unless you specifically want blending; a low alpha usually reads as "the shader did nothing".
- The VMT, compilation and mounting are all handled for you. Do not write a VMT.

## Shader model limits — ps_2_b by default
The default target is `ps_2_b`. It is roomier than it sounds, but it has two hard walls (these numbers are measured, not guessed):

**Loop bounds must be compile-time constant *when unrolling*.** ps_2_b has no dynamic flow control, so every loop unrolls and the bound cannot come from a constant register:
```hlsl
for (int k = 0; k < 8; k++)         // fine — unrolls
for (int k = 0; k < (int)C0.x; k++) // error X3511: unable to unroll loop
```
On `ver = "30"` this restriction disappears: mark the loop `[loop]` and a constant-register bound works. See the loop-attribute rule in the raymarching section — it is the single most important thing on this page.

**Texture-tap dependency chains.** A ~64-tap (8x8) blur compiles fine on ps_2_b. Around 144 taps (12x12) you hit `error X4018: texture addressing operations in a dependency chain that is too complex`. That one **is** fixed by `ver = "30"`.

**Arithmetic budget.** ps_2_b allows 512 arithmetic slots. Ordinary post-processing fits easily; anything with a marching loop or layered procedural noise does not — an 8-step raymarch measures ~1160 slots.

So: keep loops fixed-bound always, and go straight to `ver = "30"` for raymarching, volumetrics, or large sampling kernels. Do not silently downgrade the effect because of a compile error — read the error code and respond to it.

## Drawing it — the exact pattern
```lua
local mat = Material("gm_claude/shaders/<returned path>")

hook.Add("RenderScreenspaceEffects", "my_shader", function()
    render.UpdateScreenEffectTexture()   -- refresh TexBase; without this it is stale
    render.SetMaterial(mat)
    render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
end)
```
Three things here are load-bearing and easy to get wrong:
- `render.UpdateScreenEffectTexture()` **every frame, before the draw** — it is what fills `TexBase`. Skip it and you sample a stale or empty frame.
- Draw in `RenderScreenspaceEffects`. Do **not** wrap it in `cam.Start2D()` — the material already maps worldspace to the screen, and forcing a 2D context transforms it twice, which puts the quad in the wrong place and flattens your UVs.
- Use `DrawScreenQuadEx(0, 0, ScrW(), ScrH())` so the coverage is explicit.

## Animating and parameterising
The 16 float slots are the only way to get live values in. Set them from Lua each frame:
```lua
hook.Add("RenderScreenspaceEffects", "my_shader", function()
    mat:SetFloat("$c0_x", CurTime())          -- time, for anything animated
    mat:SetFloat("$c0_y", ScrW() / ScrH())    -- aspect, to keep circles round
    mat:SetFloat("$c0_z", intensity)
    render.UpdateScreenEffectTexture()
    render.SetMaterial(mat)
    render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
end)
```
Read them as `C0.x`, `C0.y`, `C0.z`, `C0.w`, `C1.x`, … in the shader. **Pass `CurTime()` in yourself — the shader has no clock.**

Correct for aspect ratio whenever you work with distance from a point, or your "circle" is an ellipse:
```hlsl
float2 p = i.uv - 0.5;
p.x *= C0.y;              // aspect
float d = length(p);
```

## Raymarching (SDF scenes, tunnels, fractals, god rays)
Needs `ver = "30"`. For clouds/fog/smoke go straight to the volumetrics section below — it has a complete working shader.

**Send the camera basis from Lua** (the shader has no view matrix) and rebuild the ray:
```hlsl
float2 ndc = i.uv * 2.0 - 1.0;
ndc.y = -ndc.y;                                  // uv is top-down, NDC is bottom-up
float3 up  = cross(C2.xyz, C1.xyz);              // derive it; slots are scarce
float3 dir = normalize(C1.xyz + C2.xyz * ndc.x * C1.w
                              + up * ndc.y * C1.w / C2.w);

float3 pos   = C0.xyz;                           // eye
float3 scene = tex2D(TexBase, i.uv).rgb;

[loop] for (int k = 0; k < 64; k++)              // [loop], NEVER [unroll]
{
    pos += dir * stepSize;
    // ... accumulate ...
    if (done) break;                             // early exit is free
}
```

### `[loop]`, not `[unroll]` — the most important rule on this page
`[unroll]` copies the body once per iteration. The shader compiles fine and then **fails to load in-game** with `Failed to create dynamic combos`. Measured, same 48-step march on ps_3_0:

| | instructions | bytecode |
|---|---|---|
| `[unroll]` | 2,035 | 33,308 B |
| `[loop]` | **63** | **1,388 B** |
| `[loop]`, 128 steps | **63** | **1,388 B** |

**With `[loop]` the step count is free at compile time.** Nesting is fine too, provided *both* loops are `[loop]` — 4 octaves x 48 steps is 71 instructions nested that way, versus 7,890 fully unrolled. It is nesting *unrolled* loops that kills.

**Rule: `[unroll]` only for 6 or fewer iterations. Everything longer gets `[loop]`.**

If `instructions` comes back in the thousands, you unrolled something. Fix the attribute — do not start deleting features. A correct marcher is well under 300 instructions no matter how many steps it takes; cost lives at *runtime*, so keep steps and octaves sane for framerate (32-64 steps, 2-4 octaves), not for the compiler.

## Volumetric rendering — any participating medium
Clouds, fog, smoke, steam, god rays, fire, murky water. All the same machinery; only the *bounds* and the *density field* change. `ver = "30"`, and `scene_depth = true` if it must stop at world geometry.

### The four parts of any volume
Everything below is one of these. Decide each one and you have your shader.

1. **Bounds** — where the medium exists. Intersect it analytically and march only inside. Never march from the eye to infinity.
2. **Density field** — how much medium is at a point. This is what makes smoke look different from cloud.
3. **Phase function** — which way it scatters light. This is what makes it read as a *medium* rather than as flat fog.
4. **Lighting** — usually a short march toward the light, using a *cheap* density.

### Non-negotiables
1. **Source is Z-UP.** `p.z` is height.
2. **`[loop]` on every march.** `[unroll]` compiles then fails to load.
3. **Cap the step size, do not just divide the span by a step count.** Span length swings wildly with ray angle, so a fixed step *count* gives wildly varying step *size*. **Step must stay well below your smallest density feature** — at ~1 sample per feature the march cannot resolve the medium and it breaks into visible flat shells.
4. **Dither the start**: `t += stepSize * ign(...)`. Trades banding for grain.
5. **Integrate as `inscatter += T * L * (1.0 - Tstep)`** where `Tstep = exp(-sigmaT * stepSize)`. Do **not** write `(S - S*Tstep)/sigmaT` — same thing only if `S` was premultiplied by `sigmaT`, and forgetting that scales every step ~30x and whites out the screen.
6. **Composite `scene * transmittance + inscatter`.** Never a lerp.
7. **Phase uses `(1 - k*cosTheta)`.** The `(1 + ...)` form mirrors the lobe away from the light and gives flat grey that ignores it.
8. **Light direction from Lua every frame** into `C3.xyz`, pointing **toward** the light. `util.GetSunInfo().direction` already does; do not negate.
9. **Derive `up = cross(right, forward)`** — only 16 float slots exist and the light needs three.
10. **Never clamp a march interval's far endpoint alone.** It can land behind `near`, making `stepSize` negative, `exp(-x) > 1`, and the screen pure white. Clamp the length or cull the ray.
11. **Gradient noise (`gnoise`) for anything you then threshold.** Value noise shows cube cells the moment you `remap` it.
12. **`frequency x visible extent >= 10`** or the field is one blob. A Source map is ~32,000 units.
13. **Cheap density inside the light march.** Fine detail is invisible in a shadow and that march runs 5-6x per lit sample.

### Helper library — paste what you need
Verified: these plus one medium compile at ~613 instructions.

```hlsl
// ---- ray -------------------------------------------------------------
float3 rayDir(float2 uv)
{
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float3 up = cross(C2.xyz, C1.xyz);
    return normalize(C1.xyz + C2.xyz * ndc.x * C1.w + up * ndc.y * C1.w / C2.w);
}

// ---- bounds ----------------------------------------------------------
float2 hitSlab(float3 ro, float3 rd, float zLo, float zHi)
{
    float rz = abs(rd.z) < 1e-5 ? (rd.z < 0.0 ? -1e-5 : 1e-5) : rd.z;
    float t0 = (zLo - ro.z) / rz, t1 = (zHi - ro.z) / rz;
    float tn = max(min(t0, t1), 0.0);
    return float2(tn, max(max(t0, t1), tn));
}

float2 hitSphere(float3 ro, float3 rd, float3 c, float r)
{
    float3 oc = ro - c;
    float b = dot(oc, rd), h = b * b - (dot(oc, oc) - r * r);
    if (h < 0.0) return float2(0.0, 0.0);
    h = sqrt(h);
    return float2(max(-b - h, 0.0), max(-b + h, 0.0));
}

float2 hitBox(float3 ro, float3 rd, float3 lo, float3 hi)
{
    float3 inv = 1.0 / (abs(rd) < 1e-5 ? 1e-5 : rd);
    float3 a = (lo - ro) * inv, b = (hi - ro) * inv;
    float3 n = min(a, b), f = max(a, b);
    float tn = max(max(n.x, n.y), max(n.z, 0.0));
    float tf = min(min(f.x, f.y), f.z);
    return float2(tn, max(tf, tn));
}

// ---- noise -----------------------------------------------------------
float3 hash33(float3 p)
{
    p = frac(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return frac((p.xxy + p.yxx) * p.zyx) * 2.0 - 1.0;
}

float gnoise(float3 p)
{
    float3 i = floor(p), f = frac(p);
    float3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    return lerp(lerp(lerp(dot(hash33(i + float3(0,0,0)), f - float3(0,0,0)),
                          dot(hash33(i + float3(1,0,0)), f - float3(1,0,0)), u.x),
                     lerp(dot(hash33(i + float3(0,1,0)), f - float3(0,1,0)),
                          dot(hash33(i + float3(1,1,0)), f - float3(1,1,0)), u.x), u.y),
                lerp(lerp(dot(hash33(i + float3(0,0,1)), f - float3(0,0,1)),
                          dot(hash33(i + float3(1,0,1)), f - float3(1,0,1)), u.x),
                     lerp(dot(hash33(i + float3(0,1,1)), f - float3(0,1,1)),
                          dot(hash33(i + float3(1,1,1)), f - float3(1,1,1)), u.x), u.y), u.z)
           * 0.5 + 0.5;
}

float fbm(float3 p, int octaves)
{
    float s = 0.0, a = 0.5;
    [loop] for (int k = 0; k < octaves; k++)
    {
        s += a * gnoise(p);
        p = mul(float3x3(0.00, 0.80, 0.60,
                        -0.80, 0.36,-0.48,
                        -0.60,-0.48, 0.64), p) * 2.02 + 11.7;
        a *= 0.5;
    }
    return s;
}

float ridged(float3 p, int octaves)
{
    float s = 0.0, a = 0.5;
    [loop] for (int k = 0; k < octaves; k++)
    {
        s += a * (1.0 - abs(2.0 * gnoise(p) - 1.0));
        p = mul(float3x3(0.00, 0.80, 0.60,
                        -0.80, 0.36,-0.48,
                        -0.60,-0.48, 0.64), p) * 2.03 + 7.1;
        a *= 0.5;
    }
    return s;
}

float remap(float v, float lo, float hi) { return saturate((v - lo) / max(hi - lo, 1e-5)); }

// ---- scattering ------------------------------------------------------
float phaseHG(float cosT, float g)
{
    float k = 1.55 * g - 0.55 * g * g * g;
    float d = 1.0 - k * cosT;
    return (1.0 - k * k) / (12.5663706 * max(d * d, 1e-4));
}

float beerPowder(float od, float k) { return exp(-od * k) * (1.0 - exp(-od * 2.0 * k) * 0.5); }

float ign(float2 px) { return frac(52.9829189 * frac(dot(px, float2(0.06711056, 0.00583715)))); }
```

### The march skeleton — identical for every medium
```hlsl
float3 dir  = rayDir(i.uv);
float2 span = <one of the hit* helpers>;
if (span.y - span.x < 1.0) return float4(scene, 1.0);

float stepSize = min((span.y - span.x) / STEPS, MAX_STEP);   // cap it
float t = span.x + stepSize * ign(i.uv * 2048.0);            // dither

float phase = phaseHG(dot(dir, C3.xyz), g);
float3 inscatter = 0.0;
float  T = 1.0;

[loop] for (int k = 0; k < STEPS; k++)
{
    float3 pos = C0.xyz + dir * t;
    if (!isSky && dot(pos - C0.xyz, C1.xyz) > sceneDepth) break;   // world geometry

    float d = density(pos);
    if (d > 0.001)                          // most samples are empty: this guard is most of your framerate
    {
        float sigmaT = d * DENSITY_SCALE;
        float3 L = ambient + lightColour * phase * lightMarch(pos) * GAIN;
        float Tstep = exp(-sigmaT * stepSize);
        inscatter += T * L * (1.0 - Tstep);
        T *= Tstep;
        if (T < 0.01) break;                // opaque: stop
    }
    t += stepSize;
}
return float4(saturate(scene * T + inscatter), 1.0);
```

### Shaping a medium — what to change, and nothing else
| medium | bounds | density field | phase `g` | notes |
|---|---|---|---|---|
| cloud layer | `hitSlab` above 4000 | coverage x vertical profile, eroded by ridged detail | 0.8 dual-lobe | see the worked example |
| ground fog | `hitSlab` at ground level | 1-2 octave `fbm`, no erosion | 0.3 | thin, wide, cheap |
| smoke plume | `hitSphere` or `hitBox` | `fbm` x radial falloff, offset upward by time so it rises | 0.2 | |
| steam / breath | small `hitSphere` | as smoke, short lifetime, low density | 0.1 | |
| god rays | `hitSlab` over the whole view | constant density | 0.85 strongly forward | brightness comes from the *light march*, not the density |
| fireball | `hitSphere` | `ridged` x falloff | 0.4 | add emission: `L += blackbody * d` before the phase term |
| murky water | `hitBox` of the volume | near-constant | 0.6 | tint `sigmaT` per channel for colour absorption |

Two ideas transfer everywhere: **rising or drifting = offset the noise lookup by time** (`p - float3(0,0,C0.w*70)` for rising smoke, `p + wind` for cloud), and **soft edges = multiply by a falloff and `remap`**, never a hard cutoff.

Emissive media (fire, plasma) add a term that does not depend on the light march at all:
```hlsl
L += emissionColour * pow(d, 2.0) * emissionGain;   // glows on its own
```

### Worked example — a cloud layer
Paste the helper library above, then this. Together they compile at 1115 instructions / 18 KB / 16 of 32 temp registers, well inside budget.

```hlsl
// ---- medium: layered cloud -------------------------------------------
#define CLOUD_BOTTOM 5000.0
#define CLOUD_TOP    9000.0
#define STEPS        64
#define MAX_STEP     220.0
#define MAX_LEN      16000.0
#define MAX_DIST     60000.0

float3 noisePos(float3 p)
{
    float3 wind = float3(C0.w * 14.0, C0.w * 4.0, 0.0);
    return (p + wind) * float3(0.0008, 0.0008, 0.0022);
}

float coverage(float3 p)
{
    return saturate(fbm(float3(p.xy * 0.00025, 0.0), 3) * 1.8 - 0.4 + C3.w);
}

float profile(float3 p, float cov)
{
    float h = saturate((p.z - CLOUD_BOTTOM) / (CLOUD_TOP - CLOUD_BOTTOM));
    // smoothstep, not saturate: a linear ramp leaves a visibly flat ceiling.
    return smoothstep(0.0, 0.28, h) * smoothstep(1.0, 0.55, h) * lerp(0.35, 1.0, cov);
}

float density(float3 p)
{
    float3 q = noisePos(p);
    float cov = coverage(p);
    float3 warp = (float3(gnoise(q * 0.5), gnoise(q * 0.5 + 19.7), gnoise(q * 0.5 + 37.1)) - 0.5) * 0.6;
    float shape = remap(fbm(q + warp, 3) * profile(p, cov), 1.0 - cov, 1.0);
    if (shape <= 0.001) return 0.0;                  // bail before paying for detail
    float h = saturate((p.z - CLOUD_BOTTOM) / (CLOUD_TOP - CLOUD_BOTTOM));
    return remap(shape, ridged(q * 7.0, 2) * lerp(0.45, 0.12, h), 1.0) * 1.6;
}

float densityCheap(float3 p)                          // shape only, for shadows
{
    float cov = coverage(p);
    return remap(fbm(noisePos(p), 2) * profile(p, cov), 1.0 - cov, 1.0) * 1.6;
}

float lightMarch(float3 p)
{
    float od = 0.0, s = 60.0;
    [loop] for (int j = 0; j < 6; j++)
    {
        p += C3.xyz * s;
        if (p.z > CLOUD_TOP) break;
        od += densityCheap(p) * s;
        s *= 1.6;                                     // grow: 6 fixed steps barely enter the layer
    }
    return beerPowder(od, 0.4);
}

float4 main(PS_INPUT i) : COLOR
{
    float3 scene = tex2D(TexBase, i.uv).rgb;
    float raw = tex2D(TexDepth, i.uv).r;
    if (raw <= 0.0) return float4(1.0, 0.0, 1.0, 1.0);   // depth pass missing

    float3 dir = rayDir(i.uv);
    float2 span = hitSlab(C0.xyz, dir, CLOUD_BOTTOM, CLOUD_TOP);
    if (span.x > MAX_DIST) return float4(scene, 1.0);
    span.y = min(span.y, span.x + MAX_LEN);             // clamp LENGTH, never `far` alone
    if (span.y - span.x < 1.0) return float4(scene, 1.0);

    float sceneDepth = raw * 4000.0;
    bool  isSky      = raw >= 0.999;
    float stepSize   = min((span.y - span.x) / float(STEPS), MAX_STEP);
    float t          = span.x + stepSize * ign(i.uv * 2048.0);

    float cosT  = dot(dir, C3.xyz);
    float phase = lerp(phaseHG(cosT, 0.8), phaseHG(cosT, -0.25), 0.3);

    float3 inscatter = 0.0;
    float  T = 1.0;
    float3 sunColour = float3(1.0, 0.95, 0.85);
    float3 ambient   = float3(0.22, 0.30, 0.45);

    [loop] for (int k = 0; k < STEPS; k++)
    {
        float3 pos = C0.xyz + dir * t;
        if (!isSky && dot(pos - C0.xyz, C1.xyz) > sceneDepth) break;
        float d = density(pos);
        if (d > 0.001)
        {
            float sigmaT = d * 0.02;
            float3 L = ambient + sunColour * phase * lightMarch(pos) * 2.2;
            float Tstep = exp(-sigmaT * stepSize);
            inscatter += T * L * (1.0 - Tstep);
            T *= Tstep;
            if (T < 0.01) break;
        }
        t += stepSize;
    }

    float fade = saturate(1.0 - span.x / MAX_DIST);     // no hard seam at the cull distance
    inscatter *= fade;
    T = lerp(1.0, T, fade);
    return float4(saturate(scene * T + inscatter), 1.0);
}
```

### The Lua that drives it
```lua
local mat = Material("gm_claude/shaders/<returned path>")

hook.Add("NeedsDepthPass", "vol_depth", function() return true end)

hook.Add("RenderScreenspaceEffects", "vol", function()
    local view = render.GetViewSetup()
    local f, r = view.angles:Forward(), view.angles:Right()

    -- Re-read every frame. direction already points TOWARD the sun; do not negate.
    local sun = util.GetSunInfo()
    local sd = sun and sun.direction:GetNormalized() or Vector(0.3, 0.2, 0.93)

    mat:SetFloat("$c0_x", view.origin.x) mat:SetFloat("$c0_y", view.origin.y)
    mat:SetFloat("$c0_z", view.origin.z) mat:SetFloat("$c0_w", CurTime())
    mat:SetFloat("$c1_x", f.x) mat:SetFloat("$c1_y", f.y) mat:SetFloat("$c1_z", f.z)
    mat:SetFloat("$c1_w", math.tan(math.rad(view.fov) * 0.5))
    mat:SetFloat("$c2_x", r.x) mat:SetFloat("$c2_y", r.y) mat:SetFloat("$c2_z", r.z)
    mat:SetFloat("$c2_w", view.aspect)
    mat:SetFloat("$c3_x", sd.x) mat:SetFloat("$c3_y", sd.y) mat:SetFloat("$c3_z", sd.z)
    mat:SetFloat("$c3_w", 0.5)

    render.UpdateScreenEffectTexture()
    render.SetMaterial(mat)
    render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
end)
```
Remove **both** hooks when the effect stops. For a light that is not the sun (a fire, a lamp) send its position instead and compute the direction per sample.

### Constant slots — all 16, no spares
| slot | contents |
|---|---|
| `C0.xyz` / `C0.w` | eye position / time |
| `C1.xyz` / `C1.w` | forward / tan(halfFovX) |
| `C2.xyz` / `C2.w` | right / aspect |
| `C3.xyz` / `C3.w` | light direction / main tunable |

Anything that does not change per frame is a `#define`, not a slot.

### What occlusion you can actually get
The scene depth texture saturates at **4000 units**, so geometry beyond that is indistinguishable from sky and *cannot* occlude your volume. Writing the `DEPTH0` semantic does not rescue this either — measured, the screenspace pass is not z-tested against it. So:
- Volumes **within** 4000 units occlude correctly against the world. Fog, smoke and fire all sit here — put them where the depth test works.
- A sky-height cloud layer will draw over distant terrain, and there is no fix from inside the shader. Keep such layers above 4000 so at least everything nearby occludes them properly.

## Lighting, BSDFs and path tracing
All of this is `ver = "30"` territory. The structural rule from the raymarching section still governs everything here.

**Structure: prefer analytic intersections.** A path tracer needs a loop over bounces, and if each bounce also marches you have nested loops — fine *provided both are `[loop]`*, fatal if either unrolls. Analytic intersection against spheres, planes and boxes is cheaper than marching per bounce anyway, so reach for it first:
```hlsl
// Returns distance along rd, or -1.0 for a miss.
float hitSphere(float3 ro, float3 rd, float3 c, float r)
{
    float3 oc = ro - c;
    float b = dot(oc, rd);
    float h = b * b - (dot(oc, oc) - r * r);
    if (h < 0.0) return -1.0;
    return -b - sqrt(h);
}

float hitPlane(float3 ro, float3 rd, float3 n, float d)
{
    float dn = dot(rd, n);
    if (abs(dn) < 1e-4) return -1.0;
    return -(dot(ro, n) + d) / dn;
}
```
Reserve SDF marching for single-bounce looks (terrain, clouds, fog) where one loop is enough.

**Randomness.** Every stochastic sample needs a per-pixel, per-frame stream. Seed from the UV and time, and thread it through by reference:
```hlsl
float rand(inout float seed)
{
    seed = frac(seed * 1.61803398875 + 0.1);
    return frac(sin(seed * 12.9898) * 43758.5453);
}
// float seed = dot(i.uv, float2(12.9898, 78.233)) + C0.w;
```
Without the time term every frame draws the identical noise pattern and it reads as a static texture, not sampling.

**This rule is specific to path tracing**, where the frames average out in the eye. A screen-space filter (AO, blur, DoF) wants the opposite — noise that is stable per pixel across frames, or it shimmers. See the sampling-kernel section under scene depth.

**Normals.** Analytic where you can — for a sphere it is just `normalize(hitPos - centre)`. For an SDF, the gradient costs **six** extra evaluations of your distance function, which is often the single most expensive thing in the shader:
```hlsl
float3 sdfNormal(float3 p)
{
    float2 e = float2(0.001, 0.0);
    return normalize(float3(map(p + e.xyy) - map(p - e.xyy),
                            map(p + e.yxy) - map(p - e.yxy),
                            map(p + e.yyx) - map(p - e.yyx)));
}
```

**Orienting a sample to a normal.** Build an orthonormal basis around `n`. Use the branchless construction — the naive `cross(n, up)` version degenerates when `n` is parallel to `up`, which shows up as a black seam at the poles:
```hlsl
void basis(float3 n, out float3 t, out float3 b)
{
    float s = n.z >= 0.0 ? 1.0 : -1.0;
    float a = -1.0 / (s + n.z);
    float c = n.x * n.y * a;
    t = float3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
    b = float3(c, s + n.y * n.y * a, -n.y);
}

// Cosine-weighted: the correct default for diffuse bounces.
float3 sampleHemisphere(float3 n, float u1, float u2)
{
    float r = sqrt(u1);
    float phi = 6.2831853 * u2;
    float3 t, b;
    basis(n, t, b);
    return normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(0.0, 1.0 - u1)));
}
```

**BSDFs.** Keep them cheap; you are on a fullscreen pass at 60fps.
```hlsl
// Diffuse. Cosine-weighted sampling cancels the cos/pdf terms exactly,
// so the whole estimator collapses to a multiply. Do NOT also divide by PI
// or multiply by dot(n, l) — that double-counts and darkens everything.
throughput *= albedo;

// Perfect mirror.
dir = reflect(dir, n);
throughput *= specular;

// Roughness, cheaply: blend the mirror direction toward a diffuse sample.
// Not physically exact, but stable and fast.
dir = normalize(lerp(reflect(dir, n), sampleHemisphere(n, r1, r2), roughness));

// Fresnel (Schlick) — drives the mirror-vs-diffuse choice on dielectrics.
float3 fresnel(float3 f0, float cosTheta)
{
    return f0 + (1.0 - f0) * pow(1.0 - cosTheta, 5.0);
}
```

**The bounce loop** — one loop, analytic hits, accumulate emission scaled by throughput:
```hlsl
float3 radiance = 0.0;
float3 throughput = 1.0;
[unroll] for (int b = 0; b < 3; b++)      // <= 6 iterations, so [unroll] is right
{
    // ... intersect scene analytically, get t, hitPos, normal, material ...
    if (t < 0.0) { radiance += throughput * skyColour(dir); break; }
    radiance += throughput * emission;
    throughput *= albedo;
    dir = sampleHemisphere(normal, rand(seed), rand(seed));
    ro  = hitPos + normal * 0.001;         // offset or you self-intersect
}
```
`hitPos + normal * 0.001` is not optional — without the offset the next ray re-hits the surface it just left and the image fills with black acne.

**Bounces are cheap; per-bounce work is not.** A measured 3-bounce tracer with analytic sphere+plane hits compiles to ~1.1 KB, and 12 bounces only reaches ~1.4 KB. So do not agonise over bounce count — 3 or 4 is visually plenty. What actually blows the budget is expensive work *inside* the bounce: an SDF `map()` march, a six-tap `sdfNormal`, or layered noise. Keep the per-bounce cost small and the loop depth stops mattering.

**Sample count.** One sample per pixel per frame is all you can afford, so a path traced image will be noisy. Two ways to improve it, in order of effort: accept the noise and lean into it stylistically, or accumulate across frames by pointing `$basetexture` at your own render target (`mat:SetTexture("$basetexture", rt)`) and blending a little of each new frame into it. Do not try to brute-force samples with an inner loop.

**Output range.** Path tracers produce values well above 1.0. Tone map and clamp, or everything bright turns into flat white blobs:
```hlsl
col = col / (col + 1.0);        // Reinhard
col = pow(col, 1.0 / 2.2);      // to gamma space
return float4(saturate(col), 1.0);
```

## Reading scene depth — how far away the world is
This is what lets a volumetric effect stop at a wall, or a fog shader thicken with distance.

**Reading depth takes THREE things and they are useless apart.** Two of them are not in the shader, which is why this is the most common way to ship a broken depth effect:

```
1. compile_shader argument:  scene_depth = true      <- BINDS sampler s1
2. HLSL:                     sampler TexDepth : register(s1);
3. Lua, in your draw file:   hook.Add("NeedsDepthPass", "my_shader_depth", function() return true end)
```

Miss **1** and the sampler is never bound. Samplers are bound at compile time — `screenspace_general` only enables one whose param exists in the VMT, so nothing you do from Lua can fix it. An unbound sampler reads the **purple/black error checkerboard**, and your guard below fires on every black square while the real shader never runs. Adding the hook does not bind anything.

Miss **3** and the sampler is bound to a buffer nothing filled, so every read is 0.

Remove the hook when you remove the effect. It is not free — it makes the engine render the whole scene a second time with the DepthWrite shader.

**Make a blank depth buffer announce itself.** This is the worst failure mode on this page: with no depth pass every sample reads 0, every derived position collapses onto the eye, every difference is zero, and the shader returns the frame untouched. A broken depth binding and a flawless shader look **exactly the same on screen**. So start every depth shader with a guard that cannot be mistaken for success:
```hlsl
float raw = tex2D(TexDepth, i.uv).r;
if (raw <= 0.0) return float4(1.0, 0.0, 1.0, 1.0);   // magenta = no depth data
```
Leave it in. It costs one instruction and it converts a silent no-op into an obvious magenta screen that tells you the problem is the binding, not your maths.

You do **not** need to set up the depth render target: the addon already re-declares it as a 32-bit float texture at load, so the depth you sample is full precision rather than the engine's default 8-bit (which quantises to ~16-unit steps and bands badly). Just sample s1 and decode.

**The decode.** The depth pass writes `viewDepth / 4000` into the **red channel only**; green, blue and alpha are meaningless. The 4000 is a hardcoded far plane in the engine, deliberately *not* the view's real far plane:
```hlsl
sampler TexDepth : register(s1);

// World units from the eye to whatever the world drew at this pixel.
float sceneDepth = tex2D(TexDepth, i.uv).r * 4000.0;
```
Consequences you must respect:
- **Anything beyond 4000 units reads as 1.0** and is indistinguishable from the sky. Treat `r >= 0.999` as "nothing there".
- The value is **view depth in world units**, matching `dot(hitPos - eye, forward)` — the same quantity the depth-writing section uses. It is *not* the non-linear `DEPTH0` value, so do not mix the two formulas up.

**Using it in a march** — stop the ray when it goes behind world geometry:
```hlsl
float sceneDepth = tex2D(TexDepth, i.uv).r * 4000.0;
bool  isSky      = tex2D(TexDepth, i.uv).r >= 0.999;

[loop] for (int k = 0; k < 64; k++)
{
    // Compare VIEW depth against view depth. `sceneDepth` is measured along
    // forward, so project onto forward — distance travelled along the ray is a
    // different quantity and over-reaches by 1/cos toward the screen edges.
    if (!isSky && dot(pos - C0.xyz, C1.xyz) > sceneDepth) break;
    acc += density(pos) * stepSize;
    pos += dir * stepSize;
}
```
Sample the depth **once, outside the loop** — it does not change along the ray, and sampling it per step wastes texture reads.

**The 4000-unit ceiling silently disables this test.** Every pixel showing geometry further than 4000 units reads as `isSky`, so the break never fires and your volume draws straight over it. For a distant skyline or terrain that reads as **the effect phasing through the world**. There is no fix inside the shader — the information is not in the buffer. What you can do is make the geometry irrelevant, which is the next point.

Depth-aware fog is the same idea without a march:
```hlsl
float fog = saturate(sceneDepth / fogDistance);
col = lerp(col, fogColour, isSky ? 1.0 : fog);
```

### Reconstructing world position from depth
Anything geometric — AO, decals, distance fields against the world, light falloff — needs the actual 3D point the pixel represents, not just its depth. Send the camera basis exactly as the raymarching section does, then:
```hlsl
// Camera ray for this pixel (same construction as raymarching).
float3 rayDir(float2 uv)
{
    float2 ndc = uv * 2.0 - 1.0;
    ndc.y = -ndc.y;
    return normalize(C1.xyz + C2.xyz * ndc.x * C1.w
                            + C3.xyz * ndc.y * C1.w / C2.w);
}

// Depth is measured ALONG FORWARD, not along the ray, so divide it back out.
float3 worldPos(float2 uv, float viewDepth)
{
    float3 d = rayDir(uv);
    return C0.xyz + d * (viewDepth / max(dot(d, C1.xyz), 1e-3));
}
```
That `dot(d, forward)` divide is not optional. Skipping it makes every point off the screen centre sit too close to the camera, which bends flat walls into a bowl.

### Reconstructing a normal from depth
Symmetric differences (`right - left`, `down - up`) are correct in the interior and **garbage on every silhouette**, where one of the two neighbours belongs to a different surface. Take the *closer* one-sided difference on each axis instead:
```hlsl
float3 p  = worldPos(uv, d);
float3 dx = abs(dR - d) < abs(d - dL) ? (worldPos(uvR, dR) - p) : (p - worldPos(uvL, dL));
float3 dy = abs(dD - d) < abs(d - dU) ? (worldPos(uvD, dD) - p) : (p - worldPos(uvU, dU));
float3 n  = normalize(cross(dy, dx));
if (dot(n, rayDir(uv)) > 0.0) n = -n;    // force it to face the camera
```

### Screen-space sampling kernels — SSAO, DoF, radial blur
These all have the same shape: many taps around the current pixel, at a **world-space** radius, in a pattern that differs per pixel. Three rules, and a 4-tap axis-aligned cross breaks all three.

**1. Convert the radius to UV, per pixel.** A fixed pixel offset is wrong at every distance but one:
```hlsl
// worldRadius units, projected. 0.5 because NDC spans -1..1 over 0..1 of UV.
float2 uvRadius = min(0.1, 0.5 * worldRadius / max(viewDepth, 1.0))
                / float2(C1.w, C1.w / C2.w);   // tanHalfFovX, tanHalfFovY
```
The `min` stops the kernel swallowing the screen when a surface is right against the camera.

**2. Use 12-16 taps in a `[loop]`, not 4 unrolled ones.** A `[loop]` kernel costs the same compiled whether it runs 4 times or 32 (see the raymarching table), so there is no reason to be stingy. Spread them on a golden-angle spiral, rotated per pixel:
```hlsl
// Interleaved gradient noise: stable per pixel, cheap, no texture needed.
float ign(float2 pixel)
{
    return frac(52.9829189 * frac(dot(pixel, float2(0.06711056, 0.00583715))));
}

float rot = ign(i.uv / texelSize) * 6.2831853;
[loop] for (int k = 0; k < 16; k++)
{
    float a = rot + float(k) * 2.39996323;      // golden angle
    float r = sqrt((float(k) + 0.5) / 16.0);    // sqrt = uniform over the disc
    float2 off = float2(cos(a), sin(a)) * r * uvRadius;
    // ... sample at i.uv + off ...
}
```
`sqrt` on the radius matters: without it the samples bunch in the middle and the effect has no reach.

**3. Rotate per pixel, but do NOT re-randomise per frame.** This is the opposite of the path-tracing rule. A screen-space filter has no accumulation buffer, so per-frame noise shimmers violently on every surface. `ign` of the pixel coordinate is stable frame to frame — leave the time term out.

**SSAO specifically.** The occlusion term must use a *normalised* direction — using the raw difference vector makes distant samples score higher than near ones, which is backwards and is the most common way to get an AO shader that produces nothing:
```hlsl
float3 q   = worldPos(i.uv + off, sampleDepth);
float3 dv  = q - p;
float  len = max(length(dv), 1e-3);
// bias in world units, ~1-2, kills self-occlusion on flat surfaces.
float  occ = max(0.0, dot(n, dv / len) - bias / len)
           * saturate(worldRadius / len);       // range check: ignore far geometry
ao += occ;
```
Then `ao /= 16.0`, and apply as `col *= saturate(1.0 - ao * strength)`. Sensible starting values in Source units: `worldRadius` 24-64, `bias` 1-2, `strength` 1-2. Skip any tap whose depth came back as sky.

**Expect visible grain, and say so.** 16 taps of stochastic AO is noisy; real engines fix that with a separate bilateral blur pass, which needs two materials and a render target. Within one pass your options are to raise the tap count, or accept the grain. Do not pretend it will be clean.

**If you do need a second pass**, render pass one into an RT and point the second material's `$basetexture` at it:
```lua
local rt = GetRenderTarget("my_ao_pass", ScrW(), ScrH())
render.PushRenderTarget(rt) ... render.PopRenderTarget()
matBlur:SetTexture("$basetexture", rt)
```
This is real but it is roughly double the work — only reach for it if the request specifically demands clean output.

### Screen-space reflections — read this before writing one
SSR can only reflect **what is already on the screen**. There is no other data. That single fact decides whether the request is achievable:

- A floor reflects what is *above* it. When the camera looks down at a floor, the things above it are behind the camera or off the top of the frame — **not on screen**. On an open map the reflected ray finds sky and there is nothing to show. This is correct behaviour, not a bug, and no amount of tuning fixes it.
- SSR pays off looking *along* a wet street or floor toward buildings, props and walls that are themselves visible.

So for **"make everything shiny/wet"**, SSR alone will look like nothing happened. Do this instead, and add SSR only on top if the request explicitly says reflections:
```hlsl
// Fresnel-weighted sheen. Always visible, costs ~10 instructions, no march.
float  f     = pow(1.0 - saturate(dot(n, -viewRay)), 4.0);   // grazing = bright
float3 sheen = skyColour * f * 0.6 + spec * pow(saturate(dot(reflected, sunDir)), 64.0);
col += sheen;
```

If you do march, five rules. The first two are what separate a working SSR from a blotchy one.

**1. Step proportionally to depth, never a fixed world distance.** `travel = k * 18.0` looks even in the world and is wildly uneven on screen: 18 units is dozens of pixels up close (so the ray leaps straight over thin geometry — this is what produces **gaps and holes** in the reflection) and sub-pixel far away (dozens of samples wasted in one texel). Grow the step with the sample's own depth so the screen-space rate stays constant:
```hlsl
float t = 8.0;
[loop] for (int k = 0; k < 40; k++)
{
    float3 q      = p + refl * t;
    float  qDepth = dot(q - C0.xyz, C1.xyz);
    // ... project, sample, test ...
    t += max(qDepth * 0.02, 4.0);   // ~constant pixels per step
}
```

**2. Reflections DIE at steep viewing angles, and that is geometry, not a bug.** A floor's reflected ray tends toward `tan(2 x viewAngle)` on screen; past ~45° below horizontal it points **behind the camera**, where no screen data exists. So reflections fade out as the player looks down or walks up to a surface. Do not fight it — detect it and cross-fade, or the reflection pops out of existence:
```hlsl
// refl.z rises as the ray tips toward the camera. Fade before it leaves.
float onScreen = saturate(1.0 - refl.z * 1.4);
col = lerp(fallbackColour, reflectedColour, onScreen * amount);
```
`fallbackColour` being a sky/ambient tint is what keeps the surface reading as reflective when the march has nothing to give. Without it the effect blinks off and looks broken.

**3. Never multiply your fades together.** The classic way to ship an invisible SSR: `strength 0.65 × fresnel-term 0.43 × distance-fade 0.27` lands at **7%** — mathematically alive, visually nothing. Pick ONE attenuation and floor the result:
```hlsl
amount = max(amount, 0.25);   // if it hits, it must be VISIBLE
```

**4. Do not fade on travel distance.** Floor hits happen at *long* travel — the ray must climb far before its depth catches the scene — so `travel / maxDistance` kills exactly the hits you get. Fade on angle (rule 2) instead.

**5. Thickness needs BOTH bounds, and the march must not start on its own surface.** `rayDepth >= surfaceDepth - t` alone accepts a sample a thousand units behind the wall and smears reflections. And a first sample sitting at `travel = 0` re-finds the pixel it started from, returning that pixel's own colour — a reflection that is invisible because it is a copy:
```hlsl
float3 p = worldPos + n * 2.0;                  // lift off the surface
// first sample at t > 0, never at the origin
if (rayDepth > surfaceDepth - t && rayDepth < surfaceDepth + t * 4.0) { /* hit */ }
```

Sample the depth buffer with `tex2Dlod(TexDepth, float4(uv, 0, 0))` inside the loop — gradients are undefined in dynamic flow control.

## Depth — making a volume sit behind world geometry
By default the pass draws over everything, so a raymarched cloud will happily cover a wall that should be in front of it. The fix is not to read the depth buffer — it is to **write** depth from the pixel shader and let the engine z-test you.

Pass `depth = true` to `compile_shader` (it sets `$depthtest 1` and clears `$ignorez`), and output the `DEPTH0` semantic:

```hlsl
struct PS_OUTPUT
{
    float4 color0 : COLOR0;
    float  depth0 : DEPTH0;
};

PS_OUTPUT main(PS_INPUT i)
{
    // ... march, producing hitDistance along `dir` ...
    float3 hitPos = C0.xyz + dir * hitDistance;

    // View-space depth, then the standard D3D non-linear depth curve.
    float zv = dot(hitPos - C0.xyz, C1.xyz);        // project onto forward
    float n  = C3.x;                                 // znear
    float f  = C3.y;                                 // zfar
    float depth = saturate(f * (zv - n) / (zv * (f - n)));

    PS_OUTPUT o = (PS_OUTPUT)0;
    o.color0 = float4(colour, 1.0);
    o.depth0 = depth;
    return o;
}
```
Feed `znear`/`zfar` from Lua — `render.GetViewSetup()` returns them alongside the camera, so use it instead of `EyePos()`/`EyeAngles()`:
```lua
local view = render.GetViewSetup()
local f, r = view.angles:Forward(), view.angles:Right()
mat:SetFloat("$c0_x", view.origin.x) -- ... y, z
mat:SetFloat("$c1_w", math.tan(math.rad(view.fov) * 0.5))
mat:SetFloat("$c2_w", view.aspect)
mat:SetFloat("$c3_x", view.znear)
mat:SetFloat("$c3_y", view.zfar)
```
`render.GetViewSetup()` is the camera the frame was actually rendered with; `EyePos()`/`EyeAngles()` can disagree with it when something overrides `CalcView`, which makes the volume visibly lag or swim.

Notes:
- **Derive `up` in the shader** with `cross(right, forward)` rather than sending it. That frees three constant slots, which is exactly what `znear`/`zfar` need.
- Where the ray hits nothing, either `discard;` or leave depth at 1.0 — do not write a near depth for empty space or you will occlude the world with nothing.
- `DEPTH0` disables early-z culling and causes overdraw, so it costs real performance. Use it only when the effect genuinely must be occluded; sky, full-screen fog and colour grading do not need it.

## Skies and backgrounds — draw BEFORE the world, not after
Anything that belongs *behind everything* — a space sky, nebula, aurora, alien horizon, a replacement for the map's sky — must not be drawn in `RenderScreenspaceEffects`. That hook runs when the world is already finished, so your quad covers it.

**Gating on scene depth does not fix this**, and reaching for it is the usual mistake. Depth saturates at 4000 units, so every distant skyline, terrain and 3D-skybox prop reads as `>= 0.999` — indistinguishable from sky — and gets painted over regardless. The information you need is not in the buffer.

Draw in the skybox pass instead and let the world paint over you:
```lua
-- Capital B. "PostDrawSkybox" is not a hook and fails silently.
hook.Add("PostDraw2DSkyBox", "my_sky", function()
    render.SetMaterial(mat)
    render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
end)
```

`PostDraw2DSkyBox` is the hook, and it is the **only** one that works. It runs before the main scene, so the 3D skybox and then the world both draw over you and z-test normally at any distance — no 4000-unit ceiling involved.

Do not substitute `PostDrawSkyBox` (no `2D`). It is a real hook, but a screen quad drawn there does not appear — measured, not guessed. `PreDrawSkyBox` is not a substitute either; it is for *suppressing* the sky, not drawing one.

Three things follow from drawing this early, and they are all *removals*:
- **No `scene_depth`, no `NeedsDepthPass`.** You are not competing with the world any more, so you do not need to know where it is — and you skip an entire second render of the scene.
- **No `render.UpdateScreenEffectTexture()`, and do not sample `TexBase`.** The world has not been drawn yet; there is nothing in the frame to read.
- **No `DEPTH0`.** Nothing needs to z-test against a sky.

**A sky is a function of ray direction alone.** It is infinitely far away, so the eye position is meaningless — drop `C0.xyz` from the maths and build the direction from the camera basis exactly as the raymarching section does. Note that `render.GetViewSetup().origin` is the *skybox* camera inside these hooks, so anything using it is subtly wrong; the angles are correct.

Map that direction onto a sphere so the pattern stays put as the player walks:
```hlsl
float2 sph = float2(atan2(d.y, d.x) * 0.15915494 + 0.5,   // 1/(2pi)
                    asin(d.z)       * 0.31830988 + 0.5);  // 1/pi
```
Star fields, constellations and nebula bands all key off `sph` or off `d` directly. Screen-space `i.uv` does not work here — it slides with the camera and looks painted on the lens.

## Shaders on models and meshes
All of these **require `vertex_source`** — `screenspace_general` has no fixed-function path for geometry, so with no vertex shader nothing projects the vertices and the material draws nothing at all.

**`usage` must match how you draw it.** The flags declare what vertex data exists; if they disagree with what the draw call actually supplies, the vertex format mismatches and **nothing renders — silently, with no error.** This is the single easiest way to get a blank screen here.

| `usage` | draw it with | vertex data available |
|---|---|---|
| `model` | `ent:DrawModel()` or `ent:SetMaterial(...)` | POSITION, TEXCOORD0, **NORMAL0** |
| `mesh` | `mesh.Begin` + `m:Draw()` | POSITION, TEXCOORD0, **COLOR0** |
| `primitive` | `render.DrawSphere` / `DrawBox` / `DrawQuad` | POSITION, TEXCOORD0 only |

So: reading `NORMAL0` in the vertex shader requires `usage = "model"` **and** an actual model. `render.DrawSphere` supplies no normals — ask for them and you get nothing on screen. Likewise `mesh.Color` only arrives under `usage = "mesh"`.

The tool sets the material flags for you. Do not write a VMT.

### The vertex shader contract
```hlsl
#include "common_vs_fxc.h"

struct VS_INPUT {
    float4 vPos      : POSITION;
    float4 vTexCoord : TEXCOORD0;
    float3 vNormal   : NORMAL0;      // models only
    float4 vColor    : COLOR0;       // meshes with mesh.Color
};

struct VS_OUTPUT {
    float4 proj_pos : POSITION;      // REQUIRED, and must be first
    float2 uv       : TEXCOORD0;     // anything after this is yours
    float3 normal   : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT vert)
{
    // Model space -> world space. Use SkinPosition if you do not need normals.
    float3 world_pos, world_normal;
    SkinPositionAndNormal(0, vert.vPos, vert.vNormal, 0, 0, world_pos, world_normal);

    // ... displace world_pos here for vertex animation ...

    VS_OUTPUT o = (VS_OUTPUT)0;
    o.proj_pos = mul(float4(world_pos, 1), cViewProj);   // world -> screen
    o.uv       = vert.vTexCoord.xy;
    o.normal   = world_normal;
    return o;
}
```
The pixel shader's `PS_INPUT` must match the vertex shader's `VS_OUTPUT` **minus** `POSITION`, in the same TEXCOORD order. A mismatch silently gives you garbage, not a compile error.

Pixel shaders for models should end with `FinalOutput`, which applies the engine's HDR and gamma handling:
```hlsl
#include "common_ps_fxc.h"
return FinalOutput(float4(col, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
```

### Getting values into a vertex shader
`screenspace_general` defines **no vertex shader constants**. `$c0_x` etc. reach the *pixel* shader only. The way in is the ambient cube, and the addon wraps it:
```lua
ClaudeShader.SetVertexConstants({
    Vector(CurTime(), intensity, 0),   -- read as cAmbientCubeX[0].xyz
    Vector(a, b, c),                   -- cAmbientCubeX[1].xyz
})  -- up to 6 vectors = 18 floats
```
Call it **every frame, immediately before drawing**. In the shader:
```hlsl
float t = cAmbientCubeX[0].x;
```
Without this the values are whatever the engine last uploaded, so a vertex animation simply will not move.

### Drawing — depth is the catch
`screenspace_general` **always writes depth**, so anything you draw with it sorts wrongly against the world unless you handle it. The addon wraps the fix:
```lua
local mat = Material("gm_claude/shaders/<returned path>")

hook.Add("PostDrawOpaqueRenderables", "my_shader", function(depthOnly, skybox)
    if depthOnly or skybox then return end
    ClaudeShader.SetVertexConstants({Vector(CurTime(), 0, 0)})
    ClaudeShader.DrawWithDepth(function()
        render.SetMaterial(mat)
        render.DrawSphere(pos, 30, 30, 30)
    end)
end)
```
Draw in a **3D** hook (`PostDrawOpaqueRenderables` / `PostDrawTranslucentRenderables`), never `RenderScreenspaceEffects`. Skip the `depthOnly` and `skybox` passes or you draw several times a frame.

**`ent:DrawModel()` ignores `render.SetMaterial` completely.** For a model the override must be on the entity:
```lua
-- SERVER-side: SetMaterial is a networked property, and a client-only override
-- is replaced by the server's value on the next entity update.
if SERVER then ent:SetMaterial("gm_claude/shaders/<returned path>") end
...
ClaudeShader.DrawWithDepth(function() ent:DrawModel() end)
```
`render.SetMaterial` only affects `render.*` calls — `DrawSphere`, `DrawBox`, `IMesh:Draw`. Mixing the two up gives you a normally-textured prop and no sign that anything went wrong.

Leaving the material on an entity and letting the engine draw it normally works too, but then there is no `DrawWithDepth` around it, so expect sorting artifacts unless your pixel shader writes `DEPTH0`. Draw the model yourself when sorting matters.

### Meshes
```lua
local m = Mesh()
mesh.Begin(m, MATERIAL_TRIANGLES, triangleCount)
    mesh.Position(Vector(x, y, z))
    mesh.Color(r, g, b, 255)          -- arrives as COLOR0, needs usage = "mesh"
    mesh.TexCoord(0, u, v)
    mesh.AdvanceVertex()
mesh.End()

-- Instancing: same mesh, many matrices.
cam.PushModelMatrix(matrix)
    m:Draw()
cam.PopModelMatrix()
```
Wrap `mesh.Begin`/`End` in a `pcall` — an error between them crashes the game rather than raising.

### Two things that silently produce nothing
**Deformation needs geometry.** A vertex shader moves existing vertices; it cannot
subdivide. A cube has 8 corners, so a jelly/wobble/melt shader on one is invisible
however good the maths is. Use a dense model, or `usage = "mesh"` where you control
the tessellation — a 16x16 grid has 289 vertices to push around.

**Alpha is ignored unless you pass `translucent = true`** to `compile_shader`. It
has to be set at compile time; `mat:SetInt("$translucent", 1)` from Lua is too late
and does nothing. Without it, glass and jelly render solid.

### Non-negotiables
1. **Every usage except `screen` requires `vertex_source`.** No vertex shader means nothing renders.
1b. **`usage` must match the draw call** — `model` for `DrawModel`, `mesh` for `mesh.Begin`, `primitive` for `render.DrawSphere`/`DrawBox`. A mismatch renders nothing and reports no error.
2. **`o.proj_pos = mul(float4(world_pos, 1), cViewProj)`** — miss this and the geometry never reaches the screen.
3. **`SkinPosition`/`SkinPositionAndNormal` first.** `vert.vPos` is model space; projecting it directly puts everything at the world origin.
4. **PS_INPUT must mirror VS_OUTPUT** minus POSITION, same order. Mismatches do not error.
5. **Draw in a 3D hook**, guarded against the `depthOnly`/`skybox` passes.
6. **Wrap manual draws in `ClaudeShader.DrawWithDepth`** or geometry sorts wrongly against the world.
7. **`ClaudeShader.SetVertexConstants` every frame** if the vertex shader reads `cAmbientCubeX`.
8. **No texture sampling in a vertex shader.** Move it to the pixel shader.
9. **`FinalOutput` at the end of a model pixel shader**, or colours come out wrong under HDR.

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
if SERVER then ent:SetMaterial("gm_claude/shaders/<returned path>") end  -- networked; not client-only

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

## Technique reference
A menu to pick the *one or two* entries the request actually calls for — not a checklist to work through.
- **Colour grading / tint**: sample, then transform. Luminance is `dot(col, float3(0.299, 0.587, 0.114))`; mix toward it with `lerp` for saturation control.
- **Distortion**: perturb the UV *before* sampling — `tex2D(TexBase, i.uv + offset)`. Waves: `offset.x = sin(i.uv.y * 40.0 + C0.x * 3.0) * 0.01`. Keep offsets small (0.002–0.02); large ones smear.
- **Chromatic aberration**: sample R, G, B at three slightly different UVs pushed radially out from centre. *Only when asked for a lens/retro/damaged look.*
- **Pixelation**: quantise the UV — `float2 uv = floor(i.uv * blocks) / blocks;`.
- **Vignette**: `col *= smoothstep(0.9, 0.3, length(i.uv - 0.5));` *Only when asked to darken the edges.*
- **Edge detection**: sample neighbours at `± 1.0 / ScrW()` (pass texel size in via `$c0_z`/`$c0_w`) and difference them.
- **Scanlines / CRT**: `col *= 0.85 + 0.15 * sin(i.uv.y * ScrH() * 3.14159);` — a CRT look is where barrel distortion, scanlines and slight aberration *do* belong together, because that is the thing being asked for. Do not lift them out of this recipe into unrelated effects.
- **Blur**: on ps_2_b, a small fixed set of taps (5–9) at offsets scaled by texel size — do not write a big loop there. On `ver = "30"` this limit is gone: a `[loop]` kernel of 16-32 taps compiles no larger than 4, so use one. The 5-9 figure is a ps_2_b constraint, **not** a quality target.

Always keep the result in a sane range — `saturate()` before returning if you are adding or multiplying anything up.

## Available HLSL
`tex2D`, `lerp`, `saturate`, `clamp`, `min`, `max`, `abs`, `floor`, `ceil`, `frac`, `fmod`, `step`, `smoothstep`, `pow`, `exp`, `log`, `sqrt`, `sin`, `cos`, `atan2`, `length`, `normalize`, `dot`, `cross`, `mul`. Swizzling (`col.rgb`, `col.zyx`, `p.xy`) works and is idiomatic. `sin`/`cos`/`pow` cost real instructions on ps_2_b — do not put ten of them in an unrolled loop.

## Cleanup and control
- Name your hook something specific and **remove it** when the effect should stop: `hook.Remove("RenderScreenspaceEffects", "my_shader")`.
- If the effect is temporary, add a `timer.Simple(n, ...)` that removes the hook. A permanent full-screen shader the player cannot escape is almost never what was asked for.
- If the request implies a toggle or a duration, build that in.

## Common failures
| Symptom | Cause |
|---|---|
| Screen is black / one flat colour | You did not call `render.UpdateScreenEffectTexture()`, or you are not sampling `TexBase` at all |
| Effect is offset, or UVs look wrong | You wrapped the draw in `cam.Start2D()` — remove it |
| Material renders as pink/black checkerboard | You called `Material()` before `compile_shader` finished; use a new shader name to escape the cached failure |
| `error X3511: unable to unroll loop` | Mark the loop `[loop]` and use `ver = "30"`, or make the bound a literal |
| `error X4018: ...dependency chain that is too complex` | Sampling kernel too large for ps_2_b — pass `ver = "30"` |
| `error X5608/X5609: too many arithmetic instruction slots` | Shader too heavy for ps_2_b (any raymarch) — pass `ver = "30"` |
| Raymarched volume hides the whole world | You returned the volume instead of compositing `scene * transmittance + inscatter` |
| Raymarched scene warps or swims when you turn | Camera basis not refreshed every frame, or `ndc.y` not flipped |
| `error X3004: undeclared identifier` | You used a sampler/constant without declaring it; copy the contract block above |
| `error X4505: maximum temp register index exceeded` | Too many live values at once. Nesting itself is fine (a full volumetric uses 15 of 32) — shorten expressions and reuse variables rather than deleting the inner loop |
| Console: `Failed to create dynamic combos for shader ...` | It compiled but the engine cannot create it — the shader is too big. Nested loop, or too many march steps. Flatten and shorten |
| Console: `Failed to create shader ...` | The `.vcs` did not load at all — check the material path is the one `compile_shader` returned |
| Compile times out | A loop is unrolling into thousands of iterations — use `[loop]` |
| `instructions` in the thousands | Something unrolled. Change the attribute, do not cut features |
| Circles look like ellipses | Not correcting for aspect ratio |
| Nothing visible at all | Returning alpha < 1, or the hook was never added / already removed |
| **model/mesh shader draws nothing at all** | `usage` does not match the draw call (e.g. `model` flags with `render.DrawSphere`, which supplies no normals), no `vertex_source`, or `o.proj_pos` never assigned from `mul(float4(world_pos,1), cViewProj)` |
| model shader renders at the world origin | Projected `vert.vPos` directly. Run it through `SkinPosition`/`SkinPositionAndNormal` first |
| model/mesh geometry sorts wrongly through walls | Manual draw not wrapped in `ClaudeShader.DrawWithDepth` |
| Vertex animation does not move | `ClaudeShader.SetVertexConstants` not called every frame before the draw |
| Pixel shader gets garbage inputs on a model | `PS_INPUT` does not mirror `VS_OUTPUT` minus POSITION, in order. This never errors |
| Model draws with its normal texture, shader ignored | Either you used `render.SetMaterial` before `ent:DrawModel()` (models need `ent:SetMaterial(path)`), or you called `SetMaterial` **client-only** — it is networked, so a client-side override is replaced by the server's empty value on the next entity update. Set it on the SERVER |
| **A glow/beam shows a dark rectangle that blocks the view** | Ordinary blending, so the dark parts of the quad are opaque. Pass `additive = true` — black then becomes transparent |
| Chromatic aberration on a quad does nothing | Offsetting `tex2D` on a flat texture returns the same colour three times. Split the procedural shape per channel instead |
| **Prop is invisible but still solid and grabbable** | It is drawing at alpha 0. On a model, `$vertexalpha` reads as zero because models supply no vertex alpha — only `usage = "mesh"` should ever set it. Otherwise check the entity's `Draw`/`DrawTranslucent` is not empty |
| Model colours look washed out or too dark | Missing `FinalOutput(...)` at the end of the pixel shader |
| Geometry drawn several times per frame | Not skipping the `depthOnly` / `skybox` passes in the 3D hook |
| Depth shader runs but changes nothing | No `NeedsDepthPass` hook, so every depth read is 0 and every difference cancels. Add the magenta guard |
| **Blocky magenta checkerboard over the screen** | `scene_depth = true` was not passed, so s1 is unbound and reads the error checkerboard. Your guard fires on its black squares. The `NeedsDepthPass` hook does NOT bind the sampler |
| Whole screen is flat magenta | The guard is right: s1 is bound but the buffer is empty. Missing the `NeedsDepthPass` hook |
| **A sky/background draws over the whole world** | Drawn in `RenderScreenspaceEffects`, which runs after the world. Draw in `PostDraw2DSkyBox` instead. Depth-gating cannot fix it — geometry past 4000 units reads as sky |
| Sky hook added, nothing appears at all | `PostDrawSkyBox` or a misspelled `PostDrawSkybox`. Only `PostDraw2DSkyBox` renders a screen quad |
| Sky pattern slides around with the camera | Keyed off `i.uv` instead of ray direction. Map `d` to spherical coordinates |
| AO/occlusion is invisible or barely there | Radius fixed in pixels instead of projected from world units, or the occlusion dot product using an unnormalised difference vector |
| **SSR compiles, normals are right, and nothing appears** | Either the fades were multiplied together down to a few percent, or the reflected ray only finds sky — a floor reflects what is ABOVE it, which is off-screen when you look down. Check the maths before assuming the shader is broken |
| **Gaps and holes in a reflection** | Fixed world-space march step. It is dozens of pixels near the camera, so the ray steps over thin geometry. Grow the step with the sample's depth |
| **Reflections vanish as the player walks closer** | Correct geometry, not a bug: a steeper view angle sends the reflected ray behind the camera. Fade on `refl.z` and cross-fade to a fallback colour instead of letting it pop off |
| Reflection looks like a copy of the surface itself | The march started at travel 0 and re-found its own pixel. Lift the origin along the normal and start the first sample past it |
| Screen-space kernel crawls or boils when you move | Noise seeded with time. Screen-space filters need per-pixel-stable noise (`ign`), not per-frame |
| Depth-derived normals are wrong at object edges | Symmetric differences straddle a silhouette; take the closer one-sided difference per axis |
| Clouds form a vertical wall across the map | Used `p.y` as height. Source is **Z-up** |
| **Clouds lit on the wrong side / uniform grey that ignores the sun** | Phase sign. Must be `(1 - k*cosTheta)`. Also check `C3.xyz` points toward the sun and is not negated |
| **Volume phases through world geometry** | Cloud layer below 4000 units, where the depth buffer saturates and cannot tell geometry from sky |
| **One single cloud instead of a sky full of them** | Coverage frequency too low. `frequency x visible extent` must be >= ~10; use ~`0.00025` |
| **Visible blocky / cube-shaped cells** | Using `vnoise` for the shape tier. Switch to `gnoise` |
| **Pure white over everything, often a band near the horizon** | Inverted march interval -> negative `stepSize` -> `exp(-x) > 1` -> transmittance grows. Never clamp the slab far endpoint alone |
| Clouds are a flat slab | Noise features as large as the layer is thick. Thicken the layer, raise the vertical noise frequency |
| Clouds are smooth blobs | No erosion. You must `remap` the shape against detail noise, not add it |
| Concentric rings stepping across the volume | Undithered march start. Offset `t` by `ign()` |
| Volumetric runs at single-digit FPS | `steps x octaves x 8 hashes` per pixel. Cut octaves, slab-clip, guard the light march behind `density > 0` |

## Before you finish
- Did you call `compile_shader` **first** and use the exact material path it returned?
- Is `render.UpdateScreenEffectTexture()` in the draw hook, every frame, before the draw? (Skies are the exception — they draw before the world, so there is no frame to capture.)
- If it belongs behind the world, is it on `PostDraw2DSkyBox` rather than `RenderScreenspaceEffects`?
- No `cam.Start2D()` around the quad?
- Is `CurTime()` fed in via a `$cN_*` slot if anything animates?
- Aspect corrected if you use radial distance?
- **Is every loop over ~6 iterations marked `[loop]`?** An `[unroll]`ed march compiles but will not load in-game, and it is the most common cause of a silent failure.
- Is the effect removable — named hook, and a timer or toggle if it is not meant to be permanent?
- **Does your shader do anything the request did not ask for?** List every visual element you added; if the request does not name it or clearly imply it, delete it. Aberration, scanlines, grain and vignette are the usual offenders.
- Does it actually look like what was asked for, not just "the screen is tinted"?

Screenspace shaders are judged on whether they match what was asked for. Quality comes from doing the requested effect *properly* — correct maths, sensible intensity, animated if it should move, tunable if it should vary — never from stacking extra artifacts on top of it.
]====]
