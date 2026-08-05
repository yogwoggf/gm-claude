-- First-light + diagnostics for the shader pipeline.
-- Server-only: clients get everything over net.

---@module "lua.claude.services.shader"
local S = include("claude/services/shader.lua")

-- GMod's screenspace_general surface: 4 samplers,
-- 4 float4 constants from the $cN_* material vars.
local HEADER = [[
sampler TexBase : register(s0); // $basetexture
sampler Tex1    : register(s1);
sampler Tex2    : register(s2);
sampler Tex3    : register(s3);

float4 C0 : register(c0); // $c0_x .. $c0_w
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT
{
	float2 uv : TEXCOORD0;
};
]]

-- Geometry only: covers the screen or it doesn't.
local RED = HEADER .. [[
float4 main(PS_INPUT i) : COLOR
{
	return float4(1.0, 0.0, 0.0, 1.0);
}
]]

-- Paints UV space. Black top-left, red rightward,
-- green downward. Reads wrong UVs at a glance.
local UV = HEADER .. [[
float4 main(PS_INPUT i) : COLOR
{
	return float4(i.uv.x, i.uv.y, 0.0, 1.0);
}
]]

-- Samples the framebuffer: proves texcoords AND
-- that _rt_FullFrameFB actually holds the frame.
local TINT = HEADER .. [[
float4 main(PS_INPUT i) : COLOR
{
	float4 col = tex2D(TexBase, i.uv);
	col.r = 1.0;
	return col;
}
]]

-- Is the scene depth buffer actually being written? A shader reading blank
-- depth looks identical to a correct one, so this answers it by colour:
--   magenta      -> RT reads 0: never written at all
--   all blue     -> everything reads >= 0.999, i.e. sky or past the 4000 cap.
--                   Aim at a near wall; still blue means depth is NOT working.
--   grey bands   -> working. Bands step every 100 units away from the eye.
local DEPTH = HEADER .. [[
float4 main(PS_INPUT i) : COLOR
{
	float raw = tex2D(Tex1, i.uv).r;
	if (raw <= 0.0) return float4(1.0, 0.0, 1.0, 1.0);
	if (raw >= 0.999) return float4(0.0, 0.3, 1.0, 1.0);

	float units = raw * 4000.0;
	float g = saturate(units / 1000.0);
	float band = frac(units / 100.0) < 0.5 ? 1.0 : 0.65;
	return float4(g * band, g * band, g * band, 1.0);
}
]]

-- Does writing the DEPTH0 semantic actually get z-tested by the engine? The
-- scene depth TEXTURE saturates at 4000 units, so it cannot occlude anything
-- further out; DEPTH0 would use the real z-buffer instead. Unverified until now.
--
-- Ramps view depth 100 (left, red) -> 4000 (right, green) across the screen.
-- WORKS:  aim at a wall and everything right of the wall's distance vanishes;
--         the boundary slides as you walk toward or away from it.
-- BROKEN: the full gradient covers the screen no matter what you look at.
local DEPTHWRITE = HEADER .. [[
struct PS_OUTPUT
{
	float4 color0 : COLOR0;
	float  depth0 : DEPTH0;
};

PS_OUTPUT main(PS_INPUT i)
{
	float zv = lerp(100.0, 4000.0, i.uv.x);
	float n = 3.0;
	float f = 35000.0;

	PS_OUTPUT o;
	o.color0 = float4(1.0 - i.uv.x, i.uv.x, 0.15, 1.0);
	o.depth0 = saturate(f * (zv - n) / (zv * (f - n)));
	return o;
}
]]

-- Does drawing in the skybox pass put a quad BEHIND the world? A sky effect
-- cannot depth-test its way there: the depth texture caps at 4000 units, so
-- distant geometry is indistinguishable from sky. Drawing before the main
-- scene is the only way.
-- VERIFIED: PostDraw2DSkyBox works. PostDrawSkyBox draws nothing at all, so
-- `sky3d` stays as the negative control rather than being deleted.
--   sky replaced, world untouched -> works, use this for skies
--   whole screen covered          -> the quad is drawing over the scene
--   nothing changes               -> the hook does not take a screen quad
local SKY = HEADER .. [[
float4 main(PS_INPUT i) : COLOR
{
	float2 c = floor(i.uv * 12.0);
	float odd = frac((c.x + c.y) * 0.5) > 0.25 ? 1.0 : 0.0;
	return float4(lerp(float3(0.9, 0.1, 0.9), float3(0.1, 0.9, 0.9), odd), 1.0);
}
]]

-- sceneDepth entries also need the NeedsDepthPass hook, via S.Show.
local VARIANTS = {
  red = {src = RED},
  uv = {src = UV},
  tint = {src = TINT},
  depth = {src = DEPTH, sceneDepth = true},
  depthwrite = {src = DEPTHWRITE, depth = true, ver = "30"},
  -- Same shader, drawn inside the 3D scene instead of in post. If DEPTH0 is
  -- ever going to be z-tested, it is here: RenderScreenspaceEffects runs after
  -- the engine is finished with the depth buffer, so there is nothing to test.
  depthwrite3d = {src = DEPTHWRITE, depth = true, ver = "30",
                  drawHook = "PostDrawTranslucentRenderables"},
  sky = {src = SKY, drawHook = "PostDraw2DSkyBox"},
  sky3d = {src = SKY, drawHook = "PostDrawSkyBox"},   -- known negative
}

-- Bisect the point where a shader compiles but the engine refuses to create
-- it. Per-step cost is fixed, so instruction count scales with the step count.
local function stressSource(steps)
  return string.format([[
sampler TexBase : register(s0);
float4 C0 : register(c0);
float4 C1 : register(c1);
float4 C2 : register(c2);
float4 C3 : register(c3);

struct PS_INPUT { float2 uv : TEXCOORD0; };

float hash(float3 p) { return frac(sin(dot(p, float3(12.9898, 78.233, 37.719))) * 43758.5453); }

float4 main(PS_INPUT i) : COLOR
{
	float2 ndc = i.uv * 2.0 - 1.0;
	ndc.y = -ndc.y;
	float3 up = cross(C2.xyz, C1.xyz);
	float3 dir = normalize(C1.xyz + C2.xyz * ndc.x * C1.w + up * ndc.y * C1.w / C2.w);
	float3 p = C0.xyz;
	float acc = 0.0;
	[unroll] for (int k = 0; k < %d; k++)
	{
		p += dir * 60.0;
		float3 g = floor(p * 0.004);
		float3 f = frac(p * 0.004);
		f = f * f * (3.0 - 2.0 * f);
		float n = lerp(lerp(hash(g), hash(g + float3(1,0,0)), f.x),
		               lerp(hash(g + float3(0,1,0)), hash(g + float3(1,1,0)), f.x), f.y);
		acc += saturate(n - 0.5) * 0.05;
	}
	return float4(lerp(tex2D(TexBase, i.uv).rgb, float3(1.0, 0.3, 0.3), saturate(acc)), 1.0);
}
]], steps)
end

-- Vertex + pixel shader on real geometry. Proves the whole model path:
-- two .vcs in one GMA, $model/$vertexnormal/$softwareskin flags, SkinPosition,
-- and constants smuggled through the ambient cube.
local MODEL_VS = [[
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos      : POSITION;
	float4 vTexCoord : TEXCOORD0;
	float3 vNormal   : NORMAL0;
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float2 uv       : TEXCOORD0;
	float3 normal   : TEXCOORD1;
	float3 wpos     : TEXCOORD2;
};

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos, world_normal;
	SkinPositionAndNormal(0, vert.vPos, vert.vNormal, 0, 0, world_pos, world_normal);

	// Time arrives through the ambient cube - there are no real VS constants.
	float t = cAmbientCubeX[0].x;
	world_pos += world_normal * sin(world_pos.z * 0.15 + t * 3.0) * 2.5;

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = mul(float4(world_pos, 1), cViewProj);
	o.uv = vert.vTexCoord.xy;
	o.normal = world_normal;
	o.wpos = world_pos;
	return o;
}
]]

local MODEL_PS = [[
#include "common_ps_fxc.h"

struct PS_INPUT {
	float2 uv     : TEXCOORD0;
	float3 normal : TEXCOORD1;
	float3 wpos   : TEXCOORD2;
};

#define SUN_DIR normalize(float3(1.0, 1.0, 1.0))

float4 main(PS_INPUT frag) : COLOR {
	// Normals as colour: instantly shows whether skinning worked.
	float3 base = frag.normal * 0.5 + 0.5;
	float diffuse = max(dot(frag.normal, SUN_DIR), 0.0);
	float3 col = base * (0.35 + diffuse * 0.9);
	return FinalOutput(float4(col, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
]]

-- Mesh variant: vertex colours instead of normals, to prove $vertexcolor.
local MESH_VS = [[
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos      : POSITION;
	float4 vTexCoord : TEXCOORD0;
	float4 vColor    : COLOR0;
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float2 uv       : TEXCOORD0;
	float4 color    : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos;
	SkinPosition(0, vert.vPos, 0, 0, world_pos);

	float t = cAmbientCubeX[0].x;
	world_pos.z += sin(world_pos.x * 0.2 + t * 2.0) * 3.0;

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = mul(float4(world_pos, 1), cViewProj);
	o.uv = vert.vTexCoord.xy;
	o.color = vert.vColor;
	return o;
}
]]

local MESH_PS = [[
#include "common_ps_fxc.h"

struct PS_INPUT {
	float2 uv    : TEXCOORD0;
	float4 color : TEXCOORD1;
};

float4 main(PS_INPUT frag) : COLOR {
	return FinalOutput(float4(frag.color.rgb, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
]]

-- render.DrawSphere/DrawBox: POSITION + TEXCOORD0 only, exactly as guide
-- examples 5 and 6. No NORMAL0 - these primitives do not supply one.
local PRIM_VS = [[
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos      : POSITION;
	float4 vTexCoord : TEXCOORD0;
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float2 uv       : TEXCOORD0;
	float3 wpos     : TEXCOORD1;
};

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos;
	SkinPosition(0, vert.vPos, 0, 0, world_pos);

	float t = cAmbientCubeX[0].x;
	world_pos.z += sin(world_pos.x * 0.1 + t * 2.0) * 4.0;

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = mul(float4(world_pos, 1), cViewProj);
	o.uv = vert.vTexCoord.xy;
	o.wpos = world_pos;
	return o;
}
]]

local PRIM_PS = [[
#include "common_ps_fxc.h"

struct PS_INPUT {
	float2 uv   : TEXCOORD0;
	float3 wpos : TEXCOORD1;
};

float4 main(PS_INPUT frag) : COLOR {
	float3 col = frac(frag.wpos * 0.05);
	return FinalOutput(float4(col, 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
]]

-- Does binding the framebuffer to a MODEL material actually work? Refraction
-- needs to sample what is BEHIND the object, which means the frame, at SCREEN
-- coordinates. Removing exactly this binding is one of the changes that made
-- geometry start rendering earlier, so it has never been isolated.
--   works  -> the drum shows a warped view of the world behind it
--   white  -> sampler bound but the frame RT is empty
--   normal/invisible -> binding the framebuffer breaks geometry rendering
local REFRACT_VS = [[
#include "common_vs_fxc.h"

struct VS_INPUT {
	float4 vPos      : POSITION;
	float4 vTexCoord : TEXCOORD0;
	float3 vNormal   : NORMAL0;
};

struct VS_OUTPUT {
	float4 proj_pos : POSITION;
	float3 normal   : TEXCOORD0;
	float4 screen   : TEXCOORD1;   // copy of proj_pos, for screen-space sampling
};

VS_OUTPUT main(VS_INPUT vert) {
	float3 world_pos, world_normal;
	SkinPositionAndNormal(0, vert.vPos, vert.vNormal, 0, 0, world_pos, world_normal);
	float4 pp = mul(float4(world_pos, 1), cViewProj);

	VS_OUTPUT o = (VS_OUTPUT)0;
	o.proj_pos = pp;
	o.normal = world_normal;
	o.screen = pp;
	return o;
}
]]

local REFRACT_PS = [[
#include "common_ps_fxc.h"

sampler FrameBuf : register(s0);

struct PS_INPUT {
	float3 normal : TEXCOORD0;
	float4 screen : TEXCOORD1;
};

float4 main(PS_INPUT frag) : COLOR {
	// Perspective divide -> 0..1 screen UV. The y flip is the NDC convention.
	float2 uv = frag.screen.xy / frag.screen.w * float2(0.5, -0.5) + 0.5;
	float3 n = normalize(frag.normal);
	float3 refr = tex2D(FrameBuf, saturate(uv + n.xy * 0.06)).rgb;
	// Green tint so "sampled the frame" is distinguishable from "drew normally".
	return FinalOutput(float4(refr * float3(0.6, 1.0, 0.8), 1.0), 0, PIXEL_FOG_TYPE_NONE, TONEMAP_SCALE_LINEAR);
}
]]

concommand.Add("claude_shader_geo", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end

  local kind = args[1] or "model" -- model | mesh | sphere | box
  local seconds = tonumber(args[2]) or 30

  -- render.DrawSphere/DrawBox supply no normals and no vertex colours, so they
  -- need the minimal "primitive" flag set. Declaring $vertexnormal for them
  -- makes the vertex format disagree and nothing renders at all.
  -- `glass` is `refract` plus translucency: the pair isolates whether declaring
  -- the material translucent is what makes a refractive prop disappear.
  local USAGE = {model = "model", mesh = "mesh", sphere = "primitive", box = "primitive",
                 refract = "model", glass = "model"}
  local usage = USAGE[kind]
  if not usage then
    print("[gm-claude] Usage: claude_shader_geo <model|mesh|sphere|box|refract|glass> [seconds]")
    return
  end
  local isMesh = kind == "mesh"

  print(string.format("[gm-claude] Compiling %s-usage shader on a %s...", usage, kind))
  print("[gm-claude] Expect a wobbling shape ~110u in front of you:")
  if isMesh then
    print("[gm-claude]   red/green/blue/yellow corners = vertex colours reached the shader")
  elseif kind == "glass" then
    print("[gm-claude]   a SEE-THROUGH warped drum = translucent refraction works")
    print("[gm-claude]   INVISIBLE but refract works = declaring translucent is what breaks it")
  elseif kind == "refract" then
    print("[gm-claude]   a GREEN-TINTED WARPED VIEW of the world behind it = framebuffer refraction WORKS")
    print("[gm-claude]   flat green/white = sampler bound but the frame RT is empty")
    print("[gm-claude]   nothing at all   = binding the framebuffer breaks geometry rendering")
  elseif usage == "model" then
    print("[gm-claude]   an oil drum in pastel normal colours = skinning worked")
  else
    print("[gm-claude]   a lit shape = the vertex shader ran")
  end
  print("[gm-claude]   nothing at all = vertex shader or flag set wrong")
  print("[gm-claude]   not wobbling  = ambient cube constants not arriving")

  local isRefract = kind == "refract" or kind == "glass"
  local ps = isRefract and REFRACT_PS or (isMesh and MESH_PS or (usage == "model" and MODEL_PS or PRIM_PS))
  local vs = isRefract and REFRACT_VS or (isMesh and MESH_VS or (usage == "model" and MODEL_VS or PRIM_VS))

  S.Compile("geo_" .. kind, ps, {
    vertexSource = vs,
    usage = usage,
    -- Bind the frame to s0 so the shader can sample what is behind the model.
    textures = isRefract and {basetexture = "_rt_FullFrameFB"} or nil,
    translucent = kind == "glass" or nil,
  }, function(ok, result)
    if not ok then
      print("[gm-claude] Geometry shader FAILED to compile:\n" .. tostring(result))
      return
    end
    local targets = IsValid(ply) and {ply} or nil
    S.Send(result.hash, targets, function(who, mounted, err)
      if not mounted then
        print("[gm-claude] Geometry shader: mount failed - " .. tostring(err))
        return
      end
      S.ShowGeometry(result.hash, seconds, {who}, kind)
    end)
  end)
end, nil, "Vertex+pixel shader on geometry. Usage: claude_shader_geo [model|mesh|sphere|box|refract|glass] [seconds]")

concommand.Add("claude_shader_stress", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end

  local steps = math.Clamp(tonumber(args[1]) or 16, 1, 512)
  local ver = args[2] or "30"

  print(string.format("[gm-claude] Stress test: %d march steps, ver=%s", steps, ver))
  S.Compile("stress_" .. steps, stressSource(steps), {ver = ver}, function(ok, result)
    if not ok then
      print("[gm-claude] Stress FAILED to compile:\n" .. tostring(result))
      return
    end
    print(string.format(
      "[gm-claude] Stress %d steps -> %s instructions, %s bytes bytecode, maxTemp %s",
      steps, tostring(result.instructions), tostring(result.bytecode_bytes),
      tostring(result.max_temp_reg)))
    print("[gm-claude] Watch console: if the engine prints 'Failed to create ...' this size is over the limit.")

    local targets = IsValid(ply) and {ply} or nil
    S.Send(result.hash, targets, function(who, mounted, err)
      if mounted then S.Show(result.hash, 3, {who})
      else print("[gm-claude] Stress: mount failed - " .. err) end
    end)
  end)
end, nil, "Bisect the shader size limit. Usage: claude_shader_stress <marchSteps> [ver]")

concommand.Add("claude_shader_test", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end

  local which = args[1] or "red"
  local seconds = tonumber(args[2]) or 5
  -- 3rd arg forces the shader model, to tell "too complex" apart from
  -- "this shader model will not load at all".
  local ver = args[3]
  local variant = VARIANTS[which]
  if not variant then
    print("[gm-claude] Usage: claude_shader_test <red|uv|tint|depth|depthwrite|depthwrite3d|sky|sky3d> [seconds] [20b|30]")
    return
  end
  ver = ver or variant.ver

  print(string.format("[gm-claude] Compiling %s test shader (ver=%s)...", which, ver or "default 20b"))
  if variant.sceneDepth then
    print("[gm-claude] magenta = depth RT never written | all blue = everything reads as sky (aim at a near wall) | grey bands = working")
  end
  if variant.depth then
    print("[gm-claude] Depth ramps red(100u) -> green(4000u) left to right. Aim at a wall:")
    print("[gm-claude]   WORKS  = everything past the wall's distance is cut away, boundary moves as you walk")
    print("[gm-claude]   BROKEN = full gradient covers the screen regardless")
  end
  if which == "sky" or which == "sky3d" then
    print("[gm-claude] Look at the sky AND at distant geometry:")
    print("[gm-claude]   WORKS  = magenta/cyan checker only where the sky was, world untouched")
    print("[gm-claude]   BROKEN = checker covers the whole screen, or nothing changes at all")
    if which == "sky3d" then
      print("[gm-claude]   NEGATIVE CONTROL: PostDrawSkyBox draws nothing. Expect no change.")
    end
  end

  S.Compile("test_" .. which, variant.src,
    {ver = ver, sceneDepth = variant.sceneDepth, depth = variant.depth}, function(ok, result)
    if not ok then
      print("[gm-claude] Shader test FAILED to compile:\n" .. tostring(result))
      return
    end

    local targets = IsValid(ply) and {ply} or nil
    S.Send(result.hash, targets, function(who, mounted, err)
      if not mounted then
        print("[gm-claude] Shader test: " .. who:Nick() .. " could not mount - " .. err)
        return
      end
      -- Only draw once that client confirmed a real material.
      S.Show(result.hash, seconds, {who}, variant.sceneDepth, variant.drawHook)
    end)
  end)
end, nil, "Compile and display a test screenspace shader. Usage: claude_shader_test <red|uv|tint|depth> [seconds] [20b|30]")
