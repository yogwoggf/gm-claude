-- compile_shader: HLSL -> compiled .vcs -> GMA -> mounted on every client.
-- Returns the material path only once a client confirms a real (non-error)
-- material, so the coder can safely Material() it in the next run_client_lua.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")
---@module "lua.claude.services.shader"
local S = include("claude/services/shader.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")

local MOUNT_TIMEOUT = 20
local PROBE_TIMEOUT = 6

-- Reads back a few samples of the framebuffer, so that the model knows if it messed up or not.
-- Usage-aware: a model shader covers only what the object covers, and judging that
-- against fullscreen expectations made the model "fix" shaders that already worked.
local function verdict(s, usage)
  local isScreen = (usage or "screen") == "screen"
  local parts = {string.format(
    "Rendered check: the effect covers %d%% of the frame. Within that area: mean " ..
    "brightness %.2f (frame was %.2f), contrast %.3f, blown-out %d%%, black %d%%.",
    math.floor(s.changed * 100 + 0.5), s.lum, s.baseLum, s.spread,
    math.floor(s.blown * 100 + 0.5), math.floor(s.black * 100 + 0.5))}

  if not isScreen then
    parts[#parts + 1] = "Drawn on test geometry, so small coverage is EXPECTED. " ..
      "These numbers describe the object, not the screen."
  end

  -- Checked FIRST. The guard fires on every pixel it touches, so the output is
  -- perfectly uniform and every test below would describe it as flat noise —
  -- sending the model off to rewrite maths that never executed.
  if (s.magenta or 0) > 0.3 then
    parts[#parts + 1] = "PROBLEM: the effect is mostly pure magenta, which is the " ..
      "'no depth data' guard, not a colour you chose. The depth sampler is not returning " ..
      "depth, so your shader returned from the guard and NOTHING after it ran. Two causes, " ..
      "check both: compile_shader needs scene_depth = true (that is what binds sampler s1 - " ..
      "an unbound sampler reads the error checkerboard), AND your Lua needs a NeedsDepthPass " ..
      "hook returning true (that is what fills the buffer). You need both. Do not change the " ..
      "rest of the shader - none of it has run yet."
  elseif s.changed < 0.005 then
    parts[#parts + 1] = isScreen
      and ("PROBLEM: INVISIBLE - the frame is unchanged. Usual causes: alpha < 1, " ..
           "returning TexBase unmodified, an early return that always fires, or a " ..
           "march interval that is always empty.")
      or ("PROBLEM: nothing drew at all. Usual causes: `usage` does not match the " ..
          "draw call, no vertex_source, o.proj_pos never assigned, SetMaterial called " ..
          "client-only, or alpha 0.")
  elseif s.blown > 0.6 then
    parts[#parts + 1] = "PROBLEM: most of the effect is clipped to white. Find the term " ..
      "that is too large - a stray divide, a missing premultiply, or additive terms " ..
      "stacking. Do not compensate by scaling something else down."
  elseif s.black > 0.6 then
    parts[#parts + 1] = "PROBLEM: most of the effect is black. Probably returning your own " ..
      "colour instead of compositing over what was there."
  elseif s.spread < 0.02 then
    parts[#parts + 1] = "PROBLEM: flat, featureless colour. Check your noise, lighting or " ..
      "sampling actually varies per pixel."
  elseif isScreen and s.changed < 0.15 then
    parts[#parts + 1] = "NOTE: only a small part of the screen changed. Fine for a localised " ..
      "effect; if it should be fullscreen, something is limiting it."
  else
    parts[#parts + 1] = "This looks plausible: visible, varied, not clipped. Do not keep " ..
      "adjusting it on the strength of these numbers alone."
  end

  return table.concat(parts, " ")
end

-- The compiler accepts far more than the D3D9 runtime will create, so a big
-- shader compiles clean here and then fails in-game with "Failed to create
-- dynamic combos". Surfacing the count is the only feedback the model gets.
-- Provisional: tighten once a working/failing pair has been measured in-game.
local INSTRUCTION_WARN = 4000

-- Samplers are bound in the VMT at COMPILE time - screenspace_general gates
-- EnableTexture/BindTexture on the param existing there. Sampling one that was
-- never bound reads the purple/black error checkerboard, which compiles clean
-- and mounts clean, so nothing catches it until it is on screen. Caught here
-- instead: the source and the arguments are both in hand.
local SAMPLERS = {
  {slot = 1, param = "texture1", depth = true},
  {slot = 2, param = "texture2"},
  {slot = 3, param = "texture3"},
}

local function declaresSampler(source, slot)
  return string.find(source, "register%s*%(%s*[sS]" .. slot .. "%s*%)") ~= nil
end

--- Slots the shader samples but nothing binds.
local function unboundSamplers(source, sceneDepth, textures)
  local missing = {}
  for _, s in ipairs(SAMPLERS) do
    if declaresSampler(source, s.slot) then
      local bound = textures and textures[s.param] and textures[s.param] ~= ""
      if s.depth and sceneDepth then bound = true end
      if not bound then missing[#missing + 1] = s end
    end
  end
  return missing
end

local LOG_DIR = "prompt-lua"

--- Drop the HLSL next to the prompt's Lua trail, at COMPILE time rather than at
--- prompt finish, so the source survives a build that later fails outright.
--- file.Write's extension whitelist has no .fxc, hence .txt.
local function logSource(agent, name, source, res, vertexSource)
  local promptId = string.gsub(tostring(agent.promptId or "unknown"), "[^%w%-_]", "")
  local path = string.format("%s/%s-shader-%s-%s.txt",
    LOG_DIR, promptId, name, tostring(res.hash))

  local header = string.format([[
-- gm-claude generated shader
-- prompt:       %s
-- name:         %s
-- material:     %s
-- usage:        %s
-- pixshader:    %s
-- vertexshader: %s
-- model:        ps_%s
-- instructions: %s
-- bytecode:     %s bytes
-- max temp reg: %s
-- compiled:     %s

]],
    promptId, name, tostring(res.material), tostring(res.usage or "screen"),
    tostring(res.pixshader), tostring(res.vertexshader or "none"),
    tostring(res.shader_model or "?"), tostring(res.instructions or "?"),
    tostring(res.bytecode_bytes or "?"), tostring(res.max_temp_reg or "?"),
    os.date("%Y-%m-%d %H:%M:%S"))

  local body = source
  if vertexSource then
    body = "// ===== VERTEX SHADER =====\n" .. vertexSource ..
           "\n\n// ===== PIXEL SHADER =====\n" .. source
  end

  file.CreateDir(LOG_DIR)
  file.Write(path, header .. body)
  print(string.format("[gm-claude] Logged shader source to data/%s (%s instructions, %s B bytecode)",
    path, tostring(res.instructions or "?"), tostring(res.bytecode_bytes or "?")))
end

return Tool.new({
  name = "compile_shader",
  description = "Compiles a Source Engine HLSL shader and mounts it on every client, returning the material path to use with Material(). Four kinds, via `usage`: \"screen\" for full-screen post-processing the render library cannot do (colour grading, distortion, kaleidoscope, pixelation, edge detection, CRT/VHS, heat haze); \"model\" to put a real shader on a prop or entity (glowing, dissolving, vertex-animated, custom-lit materials); \"mesh\" for procedural geometry built with mesh.Begin; \"primitive\" for render.DrawSphere/DrawBox. Everything except \"screen\" also needs `vertex_source`, and `usage` must match how you actually draw it. Pixel entry point must be `main` returning float4 : COLOR. Compile errors come back verbatim; fix the HLSL and call again. After it succeeds, draw the returned material with run_client_lua. IMPORTANT: on success this also renders one frame on a client and reads the framebuffer back, returning a `rendered` field describing what actually appeared on screen. Read it. If it reports the effect is invisible, blown out to white, or a flat featureless colour, fix the shader and call compile_shader again BEFORE moving on - that field is the only feedback you get about how the effect really looks.",
  parameters = {
    type = "object",
    properties = {
      name = {
        type = "string",
        description = "Short identifier for this shader, lowercase letters/digits/underscore only, e.g. \"crt_warp\". Used to name the material."
      },
      source = {
        type = "string",
        description = "The complete HLSL pixel shader. Declare your samplers/constants and a `float4 main(PS_INPUT i) : COLOR` entry point. See the playbook for the exact input struct and register layout."
      },
      ver = {
        type = "string",
        description = "Shader model. Omit for the default \"20b\" (ps_2_b). Pass \"30\" for anything with a raymarching loop, or if you hit an instruction-count limit."
      },
      depth = {
        type = "boolean",
        description = "Set true if your shader outputs the DEPTH0 semantic so the engine z-tests it against world geometry (raymarched volumes that must be hidden behind walls). Requires a PS_OUTPUT struct with COLOR0 and DEPTH0. Leave unset for ordinary post-processing."
      },
      scene_depth = {
        type = "boolean",
        description = "Set true to bind the scene depth buffer to sampler s1, so you can read how far away the existing world geometry is at each pixel and occlude or fog against it. Your Lua MUST also add a NeedsDepthPass hook returning true, or the texture stays blank. See the playbook's scene depth section for the decode."
      },
      usage = {
        type = "string",
        enum = {"screen", "model", "mesh", "primitive"},
        description = "What the shader is drawn on, and it MUST match how you draw it or the vertex format disagrees and nothing renders. \"screen\" (default) is a fullscreen post-process. \"model\" is for a prop or entity drawn with ent:DrawModel()/SetMaterial - use for glowing, dissolving or vertex-animated props. \"mesh\" is for procedural geometry from mesh.Begin with mesh.Color. \"primitive\" is for render.DrawSphere/DrawBox/DrawQuad, which supply neither normals nor vertex colours. Everything except \"screen\" REQUIRES vertex_source."
      },
      textures = {
        type = "object",
        description = "Which textures to bind to the shader's samplers. Keys: \"basetexture\" (sampler s0), \"texture1\" (s1), \"texture2\" (s2), \"texture3\" (s3). Values are material paths like \"phoenix_storms/wood\". They MUST be set here - binding a texture from Lua with mat:SetTexture afterwards is silently ignored, because the material only enables a sampler that was declared at compile time. Defaults: basetexture is the rendered frame for usage \"screen\", and a plain white texture otherwise.",
        properties = {
          basetexture = {type = "string", description = "sampler s0"},
          texture1 = {type = "string", description = "sampler s1"},
          texture2 = {type = "string", description = "sampler s2"},
          texture3 = {type = "string", description = "sampler s3"}
        }
      },
      additive = {
        type = "boolean",
        description = "Set true for glows, beams, lasers, energy and fire. The result is ADDED to what is behind it, so black becomes transparent automatically and bright areas glow. Without it the dark parts of your effect are opaque and obscure the view - which is the usual reason a beam looks like a black rectangle. Only meaningful for usage model/mesh/primitive."
      },
      translucent = {
        type = "boolean",
        description = "Set true if the material should be see-through. Alpha returned from your pixel shader is IGNORED unless you set this - a glass, jelly, hologram or force-field look will render solid without it. Only meaningful for usage model/mesh/primitive."
      },
      vertex_source = {
        type = "string",
        description = "A vertex shader in HLSL, required for usage \"model\" and \"mesh\". It transforms each vertex onto the screen and passes data to the pixel shader. Must #include \"common_vs_fxc.h\", call SkinPositionAndNormal to get world position and normal, and output POSITION via mul(float4(worldPos,1), cViewProj). See the playbook's vertex shader section for the exact structs. You CANNOT sample textures in a vertex shader."
      }
    },
    required = {"name", "source"}
  },
  run = function(args, done, agent)
    local name = string.lower(string.Trim(tostring(args.name or "")))
    local source = tostring(args.source or "")

    if not string.match(name, "^[a-z0-9_]+$") then
      done({success = false, error = "name must be 1-40 characters of a-z, 0-9 and underscore only."})
      return
    end
    if source == "" then
      done({success = false, error = "No shader source was provided."})
      return
    end

    local usage = args.usage or "screen"
    local USAGES = {screen = true, model = true, mesh = true, primitive = true}
    if not USAGES[usage] then
      done({success = false, error = 'usage must be "screen", "model", "mesh" or "primitive".'})
      return
    end

    local vertexSource = args.vertex_source
    if vertexSource == "" then vertexSource = nil end
    if usage ~= "screen" and not vertexSource then
      done({success = false, error = "usage \"" .. usage .. "\" requires vertex_source. " ..
        "screenspace_general has no fixed-function path for geometry, so without a vertex " ..
        "shader nothing transforms the vertices onto the screen and the material draws nothing."})
      return
    end

    local unbound = unboundSamplers(source, args.scene_depth, args.textures)
    if #unbound > 0 then
      local parts = {}
      for _, s in ipairs(unbound) do
        parts[#parts + 1] = s.depth
          and ("Sampler s1 is declared in your HLSL but nothing binds it. If you meant to " ..
               "read scene depth, pass scene_depth = true. If you meant a texture, pass " ..
               "textures = {texture1 = \"...\"}.")
          or string.format(
               "Sampler s%d is declared in your HLSL but nothing binds it. Pass " ..
               "textures = {%s = \"...\"}.", s.slot, s.param)
      end
      parts[#parts + 1] = "Samplers are bound at COMPILE time - screenspace_general only " ..
        "enables a sampler whose param exists in the VMT, so binding one from Lua later is " ..
        "silently ignored. An unbound sampler reads the purple/black error checkerboard: any " ..
        "guard you wrote against it fires across half the screen and the rest of the shader " ..
        "never runs. Adding the NeedsDepthPass hook in Lua does NOT bind the sampler."
      done({success = false, error = table.concat(parts, " ")})
      return
    end

    -- model/mesh shaders are geometry, and a vertex shader cannot be built for
    -- ps_3_0-only features; the guide's model path is all ps_2_b.
    S.Compile(name, source, {
      ver = args.ver, depth = args.depth, sceneDepth = args.scene_depth,
      vertexSource = vertexSource, usage = usage,
      translucent = args.translucent,
      textures = args.textures,
      additive = args.additive,
    }, function(ok, result)
      if not ok then
        done({success = false, error = "Shader failed to compile:\n" .. tostring(result)})
        return
      end

      -- Recorded on compile, not on mount: the source is what an !edit needs to
      -- see, and it is equally the live source whether or not a client acked.
      history:recordShader(agent.promptId, name,
        vertexSource and ("// vertex shader\n" .. vertexSource ..
          "\n\n// pixel shader\n" .. source) or source,
        result.material)
      pcall(logSource, agent, name, source, result, vertexSource)

      -- Nobody to mount on: the compile still proves the HLSL is valid.
      if #player.GetAll() == 0 then
        done({success = true, material = result.material,
          note = "Compiled, but no players are connected so nothing was mounted."})
        return
      end

      local settled = false
      local function finish(payload)
        if settled then return end
        settled = true
        done(payload)
      end

      local instructions = tonumber(result.instructions)
      local warnings = {}

      -- Harmless to render, but the depth pass costs a whole extra render of the
      -- scene, so paying for it and never sampling it is always a mistake.
      if args.scene_depth and not declaresSampler(source, 1) then
        warnings[#warnings + 1] = "You passed scene_depth = true but your HLSL declares no " ..
          "sampler on register(s1), so the depth buffer is bound and never read. Either " ..
          "sample it or drop scene_depth - it forces the engine to render the whole scene " ..
          "a second time."
      end

      if instructions and instructions > INSTRUCTION_WARN then
        warnings[#warnings + 1] = string.format(
          "This shader is %d instructions. A shader this large usually means a loop was " ..
          "UNROLLED — check that every loop over ~6 iterations is marked [loop] and not " ..
          "[unroll], and that you passed ver=\"30\" (ps_2_b cannot do [loop]). A correctly " ..
          "written raymarcher is well under 300 instructions no matter how many steps it " ..
          "takes. Fix the loop attribute before cutting any features. Left as-is this will " ..
          "likely fail in-game with 'Failed to create dynamic combos'.",
          instructions)
      end
      local warning = #warnings > 0 and table.concat(warnings, " ") or nil

      S.Send(result.hash, nil, function(who, mounted, err)
        if not mounted then
          finish({success = false, error = "Clients could not mount the shader: " .. tostring(err)})
          return
        end

        local NOTES = {
          screen = "Draw it with run_client_lua: Material(\"%s\") in a " ..
            "RenderScreenspaceEffects hook, with render.UpdateScreenEffectTexture() first.",
          model = "NOTE: no automated visual check runs for this usage, so the absence " ..
            "of a `rendered` field means nothing either way - do not treat it as failure. " ..
            "Put it on an entity with ent:SetMaterial(\"%s\") SERVER-side, or draw a model " ..
            "yourself. screenspace_general always writes depth, so ANY manual draw must be " ..
            "wrapped in ClaudeShader.DrawWithDepth(function() ... end) or it sorts wrongly " ..
            "against the world. Feed vertex shader values with " ..
            "ClaudeShader.SetVertexConstants({Vector(CurTime(),0,0)}) every frame.",
          primitive = "Draw with render.DrawSphere/DrawBox inside " ..
            "ClaudeShader.DrawWithDepth(function() render.SetMaterial(Material(\"%s\")) " ..
            "... end), from a 3D hook. Feed vertex values with ClaudeShader.SetVertexConstants.",
          mesh = "Build geometry with mesh.Begin, then draw inside " ..
            "ClaudeShader.DrawWithDepth(function() render.SetMaterial(Material(\"%s\")) " ..
            "... mesh:Draw() end). Feed vertex values with ClaudeShader.SetVertexConstants.",
        }

        local function done(rendered)
          finish({
            success = true,
            material = result.material,
            usage = usage,
            instructions = instructions,
            warning = warning,
            rendered = rendered,
            note = "Mounted on clients. " .. string.format(NOTES[usage], result.material),
          })
        end

        -- Only screenspace shaders are probed. There the probe reproduces the real
        -- thing exactly: same fullscreen quad, same constants. For model/mesh it
        -- would draw a stand-in prop with default constants, which is not what the
        -- build ships, and it reported "invisible" for shaders that were working.
        -- A wrong verdict is worse than none - the model acts on it.
        if usage ~= "screen" then
          done(nil)
          return
        end

        -- Draw one frame on that client and read the framebuffer back, so the
        -- model finds out whether the effect is actually visible.
        local probed = false
        local ok = S.Probe(result.hash, who, function(stats)
          if probed then return end
          probed = true
          local v = verdict(stats, usage)
          print("[gm-claude] Shader " .. name .. " -> " .. v)
          done(v)
        end)
        if not ok then done(nil) return end

        timer.Simple(PROBE_TIMEOUT, function()
          if probed then return end
          probed = true
          done(nil)
        end)
      end)

      timer.Simple(MOUNT_TIMEOUT, function()
        finish({success = false, error = "Timed out waiting for a client to mount the shader."})
      end)
    end)
  end
})
