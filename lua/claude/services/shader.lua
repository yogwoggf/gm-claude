-- Runtime screenspace shaders.

AddCSLuaFile()

-- Re-running would rebind net handlers onto a fresh `store`, orphaning anything
-- already compiled. Include is safe to repeat; execution is not.
if ClaudeShader and ClaudeShader.__loaded then return ClaudeShader end

ClaudeShader = ClaudeShader or {}
local S = ClaudeShader
S.__loaded = true

local SERVICE_URL = "http://shader-compile:3000/compile"
local DIR = "gm-claude/shaders"
local CHUNK = 24000 -- net caps at 64KiB; leave headroom
local CHUNK_DELAY = 0.05 -- don't flood a client's channel

S.mounted = S.mounted or {} -- hash -> IMaterial
S.mountedPath = S.mountedPath or {} -- hash -> material path (ent:SetMaterial needs the string)

if SERVER then

util.AddNetworkString("claude.shader.offer")
util.AddNetworkString("claude.shader.need")
util.AddNetworkString("claude.shader.chunk")
util.AddNetworkString("claude.shader.ack")
util.AddNetworkString("claude.shader.show")
util.AddNetworkString("claude.shader.probe")
util.AddNetworkString("claude.shader.probe.result")
util.AddNetworkString("claude.shader.geometry")

local store = {} -- hash -> {gma, material}
local acks = {} -- hash -> function(ply, ok, err)
local probes = {} -- hash -> function(stats)
local backfills = {} -- ply -> {left, ok, total, done, timer}

-- A joining client has none of these, so every shader ever compiled this map has
-- to be re-offered before their Lua backlog replays. Spread out: they are also
-- receiving entities and Lua at the same time.
local BACKFILL_STAGGER = 0.1
local BACKFILL_TIMEOUT = 30 -- never strand the Lua sync behind one stuck mount

--- Draw the shader for one frame on a client and read the framebuffer back.
--- The only way the model learns whether the effect actually rendered - a
--- shader that compiles and mounts can still be invisible or blown out.
function S.Probe(hash, target, onResult)
  local entry = store[hash]
  if not entry then return false end
  probes[hash] = onResult
  net.Start("claude.shader.probe")
  net.WriteString(hash)
  net.WriteString(entry.usage or "screen")
  net.Send(target)
  return true
end

net.Receive("claude.shader.probe.result", function(_, ply)
  local hash = net.ReadString()
  local stats = {
    changed = net.ReadFloat(),
    lum = net.ReadFloat(),
    baseLum = net.ReadFloat(),
    spread = net.ReadFloat(),
    blown = net.ReadFloat(),
    black = net.ReadFloat(),
  }
  local cb = probes[hash]
  probes[hash] = nil
  if cb then cb(stats) end
end)

--- Compile HLSL into a mountable GMA.
--- @param done function(ok, resultOrError)
function S.Compile(name, source, opts, done)
  opts = opts or {}

  HTTP({
    method = "POST",
    url = SERVICE_URL,
    type = "application/json",
    headers = {["Content-Type"] = "application/json"},
    -- ver omitted: let the service pick its default.
    body = util.TableToJSON({
      name = name,
      source = source,
      ver = opts.ver,
      depth = opts.depth and true or nil,
      scene_depth = opts.sceneDepth and true or nil,
      vertex_source = opts.vertexSource,
      usage = opts.usage,
      translucent = opts.translucent and true or nil,
      textures = opts.textures,
      additive = opts.additive and true or nil,
    }),
    success = function(code, body)
      local res = util.JSONToTable(body or "")
      if not istable(res) then
        done(false, "shader service returned unparseable body (HTTP " .. tostring(code) .. ")")
        return
      end
      if not res.ok then
        -- Compiler diagnostics: hand back verbatim.
        done(false, tostring(res.errors or "unknown compile error"))
        return
      end

      local gma = util.Base64Decode(res.gma_b64 or "")
      if not gma or #gma == 0 then
        done(false, "shader service returned an empty GMA")
        return
      end

      store[res.hash] = {gma = gma, material = res.material, usage = res.usage}
      print(string.format(
        "[gm-claude] Shader %s compiled: %s (%s, ps_%s, %s instructions, %s B bytecode, maxTemp %s%s)",
        name, res.material, tostring(res.usage or "screen"),
        tostring(res.shader_model or "?"),
        tostring(res.instructions or "?"), tostring(res.bytecode_bytes or "?"),
        tostring(res.max_temp_reg or "?"),
        res.vertexshader and (", vs " .. res.vertexshader) or ""))
      done(true, res)
    end,
    failed = function(err)
      done(false, "shader service unreachable: " .. tostring(err))
    end,
  })
end

local function offer(hash, entry, backfill)
  net.Start("claude.shader.offer")
  net.WriteString(hash)
  net.WriteString(entry.material)
  net.WriteUInt(#entry.gma, 32)
  -- Echoed back in the ack so a backfill mount cannot re-fire the callback a
  -- tool registered for this hash while it was generating.
  net.WriteBool(backfill and true or false)
end

--- Offer a compiled shader to clients. They ask
--- for bytes only if they don't already have it.
function S.Send(hash, targets, onAck)
  local entry = store[hash]
  if not entry then return false end
  if onAck then acks[hash] = onAck end

  offer(hash, entry, false)
  if targets then net.Send(targets) else net.Broadcast() end
  return true
end

local function finishBackfill(ply, timedOut)
  local state = backfills[ply]
  if not state then return end
  backfills[ply] = nil
  timer.Remove(state.timer)

  print(string.format("[gm-claude] Shader backfill for %s: %d/%d mounted%s",
    IsValid(ply) and ply:Nick() or "<gone>", state.ok, state.total,
    timedOut and " (TIMED OUT)" or ""))
  if state.done then state.done(state.ok, state.total) end
end

--- Offer every shader compiled this map to one player, then call
--- done(mounted, total) once they have all landed (or the wait expires).
---
--- Ordering is the whole point: Material() permanently caches the error
--- material for a name that is not mounted yet, so generated Lua replayed to a
--- joining client ahead of its GMA leaves that effect broken until they rejoin.
--- Callers must wait for `done` before sending any shader-using code.
function S.SendAll(ply, done)
  local hashes = {}
  for hash in pairs(store) do hashes[#hashes + 1] = hash end

  local total = #hashes
  if total == 0 then
    if done then done(0, 0) end
    return 0
  end

  local state = {left = total, ok = 0, total = total, done = done,
                 timer = "claude.shader.backfill." .. ply:EntIndex()}
  backfills[ply] = state

  for i, hash in ipairs(hashes) do
    timer.Simple((i - 1) * BACKFILL_STAGGER, function()
      -- Bail if they left, or a second backfill superseded this one.
      if not IsValid(ply) or backfills[ply] ~= state then return end
      local entry = store[hash]
      if not entry then
        state.left = state.left - 1
        if state.left <= 0 then finishBackfill(ply, false) end
        return
      end
      offer(hash, entry, true)
      net.Send(ply)
    end)
  end

  timer.Create(state.timer, BACKFILL_TIMEOUT + total * BACKFILL_STAGGER, 1, function()
    finishBackfill(ply, true)
  end)
  return total
end

hook.Add("PlayerDisconnected", "claude.shader.backfill", function(ply)
  local state = backfills[ply]
  if not state then return end
  -- Dropped, not finished: do not run `done` for a player who is gone.
  backfills[ply] = nil
  timer.Remove(state.timer)
end)

--- Draw a model/mesh shader on test geometry in front of the player.
function S.ShowGeometry(hash, seconds, targets, kind)
  if not store[hash] then return false end
  net.Start("claude.shader.geometry")
  net.WriteString(hash)
  net.WriteUInt(math.Clamp(seconds or 20, 0, 300), 16)
  net.WriteString(kind or "sphere")
  if targets then net.Send(targets) else net.Broadcast() end
  return true
end

--- Draw it as a screenspace pass for N seconds.
--- needsDepth also installs the NeedsDepthPass hook, which is
--- what actually fills the scene depth texture on sampler s1.
function S.Show(hash, seconds, targets, needsDepth, drawHook)
  net.Start("claude.shader.show")
  net.WriteString(hash)
  net.WriteUInt(math.Clamp(seconds or 5, 0, 300), 16)
  net.WriteBool(needsDepth and true or false)
  net.WriteString(drawHook or "")
  if targets then net.Send(targets) else net.Broadcast() end
end

net.Receive("claude.shader.need", function(_, ply)
  local hash = net.ReadString()
  local entry = store[hash]
  if not entry then return end

  local total = math.ceil(#entry.gma / CHUNK)
  for i = 1, total do
    local part = string.sub(entry.gma, (i - 1) * CHUNK + 1, i * CHUNK)
    -- Staggered: a burst can overflow the channel.
    timer.Simple((i - 1) * CHUNK_DELAY, function()
      if not IsValid(ply) then return end
      net.Start("claude.shader.chunk")
      net.WriteString(hash)
      net.WriteUInt(i, 16)
      net.WriteUInt(total, 16)
      net.WriteUInt(#part, 16)
      net.WriteData(part, #part)
      net.Send(ply)
    end)
  end
  print(string.format("[gm-claude] Shader %s: sending %d chunk(s) to %s",
    hash, total, ply:Nick()))
end)

net.Receive("claude.shader.ack", function(_, ply)
  local hash = net.ReadString()
  local ok = net.ReadBool()
  local err = net.ReadString()
  local backfill = net.ReadBool()

  if backfill then
    local state = backfills[ply]
    if not state then return end
    -- One line per shader would be dozens on a busy map; only failures matter.
    if ok then state.ok = state.ok + 1
    else print(string.format("[gm-claude] Shader %s backfill FAILED on %s - %s",
      hash, ply:Nick(), err)) end

    state.left = state.left - 1
    if state.left <= 0 then finishBackfill(ply, false) end
    return
  end

  print(string.format("[gm-claude] Shader %s on %s: %s", hash, ply:Nick(),
    ok and "MOUNTED" or ("FAILED - " .. err)))

  local cb = acks[hash]
  if cb then cb(ply, ok, err) end
end)

else

local pending = {} -- hash -> {parts, material}

-- The engine's own _rt_ResolvedFullFrameDepth is low-precision, so
-- viewDepth/4000 quantises to ~16-unit steps and banding is unusable.
-- Re-declaring the name as R32F gives full float depth. Whoever creates the
-- RT first owns the format, so this has to happen at load, not on demand.
local IMAGE_FORMAT_R32F = 27
local TEXFLAGS = 4 + 8 + 256 + 512 -- CLAMPS, CLAMPT, NOMIP, NOLOD

S.depthRT = S.depthRT or nil

function S.EnsureDepthRT()
  if S.depthRT then return S.depthRT end
  local ok, rt = pcall(GetRenderTargetEx,
    "_rt_resolvedfullframedepth", 1, 1,
    RT_SIZE_FULL_FRAME_BUFFER,
    MATERIAL_RT_DEPTH_SHARED,
    TEXFLAGS,
    0,
    IMAGE_FORMAT_R32F)
  if not ok or not rt then
    print("[gm-claude] Could not upgrade the depth RT to R32F: " .. tostring(rt))
    return nil
  end
  S.depthRT = rt
  -- GetRenderTargetEx returns the EXISTING texture if the name is already
  -- taken, with no error, so this is a request rather than a guarantee. If
  -- sampled depth still looks banded, something claimed the name first.
  print(string.format("[gm-claude] Requested depth RT as R32F (%dx%d)",
    rt:GetMappingWidth(), rt:GetMappingHeight()))
  return rt
end

S.EnsureDepthRT()

--------------------------------------------------------------------------------
-- Vertex shader support.
--------------------------------------------------------------------------------

-- screenspace_general defines no vertex shader constants at all, so the only
-- way in is to hijack something the engine already uploads. The ambient cube is
-- the most usable: 6 directions x 3 floats = 18 values, readable in the vertex
-- shader as cAmbientCubeX[0].x .. cAmbientCubeZ[1].z.
--
-- Source only uploads it while setting up model lighting, so a model must
-- actually be drawn between the SetModelLighting calls or nothing is committed.
local VS_CONST_DIRS = 6
local dummyModel = nil

local function ensureDummy()
  if IsValid(dummyModel) then return dummyModel end
  -- Any model works; it is scaled to nothing and only exists to make the engine
  -- commit the lighting state. error.mdl is always present.
  dummyModel = ClientsideModel("models/error.mdl", RENDERGROUP_OTHER)
  -- Scale 0 only. Do NOT SetNoDraw: the DrawModel call below is what makes the
  -- engine commit the ambient cube, and NoDraw can suppress exactly that.
  if IsValid(dummyModel) then dummyModel:SetModelScale(0) end
  return dummyModel
end

--- Upload up to 6 float3s readable from a vertex shader.
--- Call every frame, immediately before drawing.
--- @param values table array of up to 6 Vectors (or {x,y,z} tables)
function S.SetVertexConstants(values)
  local m = ensureDummy()
  if not IsValid(m) then return false end

  -- Must suppress first, or the engine overwrites what we set.
  render.SuppressEngineLighting(true)
  for i = 0, VS_CONST_DIRS - 1 do
    local v = values[i + 1]
    if v then
      render.SetModelLighting(i, v.x or v[1] or 0, v.y or v[2] or 0, v.z or v[3] or 0)
    end
  end
  m:DrawModel() -- forces the ambient cube to be committed
  render.SuppressEngineLighting(false)
  return true
end

--- screenspace_general ALWAYS writes depth, so anything drawn with it sorts
--- wrongly against the world. Wrap model and mesh draws in this.
function S.DrawWithDepth(fn)
  render.OverrideDepthEnable(true, true)
  local ok, err = pcall(fn)
  render.OverrideDepthEnable(false, false)
  if not ok then ErrorNoHalt("[gm-claude] shader draw failed: " .. tostring(err) .. "\n") end
end

local function ack(hash, ok, err, backfill)
  net.Start("claude.shader.ack")
  net.WriteString(hash)
  net.WriteBool(ok)
  net.WriteString(err or "")
  net.WriteBool(backfill and true or false)
  net.SendToServer()
end

--- Mount and resolve the material. Must mount
--- BEFORE Material() or the name caches as error.
--- Acking is the caller's job: one transfer can owe several acks.
--- @return boolean ok, string|nil err
local function mount(hash, material)
  local ok, files = game.MountGMA("data/" .. DIR .. "/" .. hash .. ".gma")
  if not ok then return false, "MountGMA failed" end

  local mat = Material(material)
  if not mat or mat:IsError() then
    return false, "material is the error material: " .. material
  end

  S.mounted[hash] = mat
  S.mountedPath[hash] = material
  print(string.format("[gm-claude] Mounted shader %s (%d file(s)): %s",
    hash, files and #files or 0, material))
  return true
end

net.Receive("claude.shader.offer", function()
  local hash = net.ReadString()
  local material = net.ReadString()
  local size = net.ReadUInt(32)
  local backfill = net.ReadBool()

  -- Keeps the join splash on black while shaders stream: it releases after a
  -- beat of silence, and shaders now go first, so without this it lets go
  -- during the gap before any Lua arrives.
  if backfill then hook.Run("ClaudeSyncActivity") end

  if S.mounted[hash] then
    ack(hash, true, nil, backfill)
    return
  end

  -- Hashed names, so a match is the same bytes.
  local path = DIR .. "/" .. hash .. ".gma"
  if file.Exists(path, "DATA") and file.Size(path, "DATA") == size then
    local ok, err = mount(hash, material)
    ack(hash, ok, err, backfill)
    return
  end

  local p = pending[hash]
  if p then
    -- Already streaming these exact bytes. Restarting would discard the parts
    -- already received and the transfer would never complete; just note that
    -- this offer is owed an ack too when it lands.
    if backfill then p.ackBackfill = true else p.ackNormal = true end
    return
  end

  pending[hash] = {parts = {}, material = material,
                   ackNormal = not backfill, ackBackfill = backfill}
  net.Start("claude.shader.need")
  net.WriteString(hash)
  net.SendToServer()
end)

net.Receive("claude.shader.chunk", function()
  local hash = net.ReadString()
  local index = net.ReadUInt(16)
  local total = net.ReadUInt(16)
  local len = net.ReadUInt(16)
  local data = net.ReadData(len)

  local p = pending[hash]
  if not p then return end

  p.parts[index] = data
  if table.Count(p.parts) < total then return end

  pending[hash] = nil
  file.CreateDir(DIR)
  file.Write(DIR .. "/" .. hash .. ".gma", table.concat(p.parts))

  local ok, err = mount(hash, p.material)
  if p.ackNormal then ack(hash, ok, err, false) end
  if p.ackBackfill then ack(hash, ok, err, true) end
end)

net.Receive("claude.shader.show", function()
  local hash = net.ReadString()
  local seconds = net.ReadUInt(16)
  local needsDepth = net.ReadBool()
  local drawHook = net.ReadString()
  S.Draw(S.mounted[hash], seconds, needsDepth, drawHook ~= "" and drawHook or nil)
end)

S.drawHook = S.drawHook or "RenderScreenspaceEffects"

local function clearDraw()
  hook.Remove(S.drawHook, "claude.shader.draw")
  hook.Remove("NeedsDepthPass", "claude.shader.depth")
  timer.Remove("claude.shader.draw")
end

--- Screenspace pass. nil material clears it.
--- drawHook defaults to RenderScreenspaceEffects. Pass
--- PostDrawTranslucentRenderables to draw inside the 3D scene instead, which
--- is the only place the depth buffer is still bound for a DEPTH0 z-test.
function S.Draw(mat, seconds, needsDepth, drawHook)
  clearDraw()
  if not mat then return end
  S.drawHook = drawHook or "RenderScreenspaceEffects"

  -- Without this the depth texture is never written.
  if needsDepth then
    hook.Add("NeedsDepthPass", "claude.shader.depth", function() return true end)
  end

  local function paint()
    render.UpdateScreenEffectTexture()
    render.SetMaterial(mat)
    -- No cam.Start2D here: render.* draws in worldspace and the VMT's
    -- $vertextransform 1 is what maps that to the screen. Forcing a 2D
    -- context on top would transform twice.
    render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
  end

  if S.drawHook == "PostDrawTranslucentRenderables" then
    -- Fires several times a frame; skip the depth and skybox passes.
    hook.Add(S.drawHook, "claude.shader.draw", function(depthOnly, skybox, sky3d)
      if depthOnly or skybox or sky3d then return end
      paint()
    end)
  else
    hook.Add(S.drawHook, "claude.shader.draw", paint)
  end

  -- Always self-clearing: never strand the view.
  if seconds and seconds > 0 then
    timer.Create("claude.shader.draw", seconds, 1, clearDraw)
  end
end

concommand.Add("claude_shader_stop", function()
  S.Draw(nil)
  print("[gm-claude] Cleared screenspace shader")
end, nil, "Stop drawing the current test shader.")

--------------------------------------------------------------------------------
-- Geometry test draw, for model/mesh shaders.
--------------------------------------------------------------------------------

local geo = nil -- {mat, kind, ent}
local testMesh = nil

-- usage="model" declares $vertexnormal, so it must be drawn as a real model.
-- A render.DrawSphere primitive supplies no normals, the vertex format
-- disagrees, and nothing renders at all.
local function ensureTestModel()
  if IsValid(geo and geo.ent) then return geo.ent end
  local e = ClientsideModel("models/props_c17/oildrum001.mdl", RENDERGROUP_OPAQUE)
  if IsValid(e) then e:SetNoDraw(true) end
  return e
end

local function buildTestMesh()
  if testMesh then return testMesh end
  testMesh = Mesh()
  -- A vertex-coloured quad: proves $vertexcolor and mesh.Color reach the shader.
  local ok = pcall(function()
    mesh.Begin(testMesh, MATERIAL_TRIANGLES, 2)
      local function v(x, y, z, r, g, b)
        mesh.Position(Vector(x, y, z)) mesh.Color(r, g, b, 255)
        mesh.TexCoord(0, (x + 20) / 40, (z + 20) / 40) mesh.AdvanceVertex()
      end
      v(-20, 0, -20, 255, 0, 0) v(20, 0, -20, 0, 255, 0) v(20, 0, 20, 0, 0, 255)
      v(-20, 0, -20, 255, 0, 0) v(20, 0,  20, 0, 0, 255) v(-20, 0, 20, 255, 255, 0)
    mesh.End()
  end)
  if not ok then testMesh = nil end
  return testMesh
end

local function stopGeometry()
  hook.Remove("PostDrawOpaqueRenderables", "claude.shader.geometry")
  timer.Remove("claude.shader.geometry")
  if geo and IsValid(geo.ent) then geo.ent:Remove() end
  geo = nil
end

-- Isolation: same hook, same position, same draw calls, but a stock material.
-- If this is invisible too, the problem is the draw/hook/position, not the shader.
concommand.Add("claude_shader_plain", function(_, _, args)
  local kind = args[1] or "sphere"
  local mat = Material("models/debug/debugwhite")
  stopGeometry()
  geo = {mat = mat, kind = kind, plain = true}
  if kind == "model" or kind == "refract" or kind == "glass" then
    geo.ent = ensureTestModel()
    if IsValid(geo.ent) then geo.ent:SetMaterial("models/debug/debugwhite") end
  end
  print("[gm-claude] Drawing a PLAIN white " .. kind ..
    " ~110u ahead. If you cannot see THIS, the shader is not the problem.")
  if kind ~= "mesh" and kind ~= "model" then
    print("[gm-claude]   two spheres: LEFT is +radius, RIGHT is -radius. " ..
      "If only one shows, that is the winding that renders.")
  end

  hook.Add("PostDrawOpaqueRenderables", "claude.shader.geometry", function(a, b, sky3d)
    if not geo or sky3d then return end
    local pos = EyePos() + EyeAngles():Forward() * 110
    S.DrawWithDepth(function()
      render.SetMaterial(geo.mat)
      if geo.kind == "mesh" then
        local m = buildTestMesh()
        if m then
          local mtx = Matrix() mtx:SetTranslation(pos)
          cam.PushModelMatrix(mtx) m:Draw() cam.PopModelMatrix()
        end
      elseif geo.kind == "model" then
        if IsValid(geo.ent) then
          geo.ent:SetPos(pos - Vector(0, 0, 25))
          geo.ent:SetupBones()
          geo.ent:DrawModel()
        end
      else
        -- Both signs: render.DrawSphere winds inside-out for one of them, and
        -- with $cull 1 the wrong sign is culled away to nothing.
        local right = EyeAngles():Right()
        render.DrawSphere(pos - right * 40, 30, 30, 30)
        render.DrawSphere(pos + right * 40, -30, 30, 30)
      end
    end)
  end)
  timer.Create("claude.shader.geometry", 30, 1, stopGeometry)
end, nil, "Draw test geometry with a stock material. Usage: claude_shader_plain [sphere|mesh|model]")

net.Receive("claude.shader.geometry", function()
  local hash = net.ReadString()
  local seconds = net.ReadUInt(16)
  local kind = net.ReadString()

  local mat = S.mounted[hash]
  if not mat then
    print("[gm-claude] Geometry test: shader " .. hash .. " is not mounted on this client")
    return
  end
  stopGeometry()
  geo = {mat = mat, kind = kind, path = S.mountedPath[hash]}
  if kind == "model" or kind == "refract" or kind == "glass" then
    geo.ent = ensureTestModel()
    -- DrawModel() ignores render.SetMaterial entirely; the override has to be
    -- on the entity. This is the difference between a shaded prop and a normal one.
    if IsValid(geo.ent) and geo.path then geo.ent:SetMaterial(geo.path) end
    if not IsValid(geo.ent) then
      print("[gm-claude] Geometry test: could not create the test model")
      return
    end
  end
  print(string.format("[gm-claude] Drawing %s with %s, ~110u in front of you (%s)",
    kind, tostring(geo.path), mat:IsError() and "ERROR MATERIAL" or "material ok"))

  -- The guide skips only the 3D skybox pass here, so match it rather than
  -- guessing at the other two flags.
  hook.Add("PostDrawOpaqueRenderables", "claude.shader.geometry", function(_, _, sky3d)
    if not geo or sky3d then return end
    if not geo.drew then
      geo.drew = true
      local branch = (geo.kind == "mesh" and "IMesh")
        or ((geo.kind == "model" or geo.kind == "refract" or geo.kind == "glass")
            and "ClientsideModel (oil drum)")
        or (geo.kind == "box" and "render.DrawBox")
        or "render.DrawSphere x2"
      print(string.format("[gm-claude] Draw hook running: kind=%q -> %s%s",
        tostring(geo.kind), branch,
        geo.kind ~= "model" and geo.kind ~= "mesh" and geo.kind ~= "box"
          and geo.kind ~= "sphere" and " + framebuffer refresh" or ""))
    end

    -- Time into the vertex shader via the ambient cube.
    S.SetVertexConstants({Vector(CurTime(), 0, 0)})
    S.SetStandardConstants(geo.mat)

    local pos = EyePos() + EyeAngles():Forward() * 110
    S.DrawWithDepth(function()
      render.SetMaterial(geo.mat)
      if geo.kind == "mesh" then
        local m = buildTestMesh()
        if not m then return end
        local mtx = Matrix()
        mtx:SetTranslation(pos)
        mtx:SetAngles(Angle(0, CurTime() * 30 % 360, 0))
        cam.PushModelMatrix(mtx)
          m:Draw()
        cam.PopModelMatrix()
      elseif geo.kind == "model" or geo.kind == "refract" or geo.kind == "glass" then
        if not IsValid(geo.ent) then return end
        -- _rt_FullFrameFB only holds the frame once this is called. Without it a
        -- refraction shader samples an empty RT and the test proves nothing.
        if geo.kind ~= "model" then render.UpdateScreenEffectTexture() end
        geo.ent:SetPos(pos - Vector(0, 0, 25))
        geo.ent:SetAngles(Angle(0, CurTime() * 30 % 360, 0))
        geo.ent:SetupBones()
        geo.ent:DrawModel()  -- uses the entity's material override, set on mount
      elseif geo.kind == "box" then
        render.DrawBox(pos, Angle(0, CurTime() * 30 % 360, 0),
          Vector(-25, -25, -25), Vector(25, 25, 25))
      else
        -- Draw both windings; $cull 1 culls whichever one is inside-out.
        local right = EyeAngles():Right()
        render.DrawSphere(pos - right * 40, 30, 30, 30)
        render.DrawSphere(pos + right * 40, -30, 30, 30)
      end
    end)
  end)

  if seconds > 0 then timer.Create("claude.shader.geometry", seconds, 1, stopGeometry) end
end)

concommand.Add("claude_shader_ungeo", stopGeometry, nil, "Stop the geometry shader test.")

--------------------------------------------------------------------------------
-- Probe: render one frame with the shader, one without, and compare.
--------------------------------------------------------------------------------

local GRID = 12 -- 144 ReadPixel calls; fine as a one-off

--- The slot layout the playbook mandates, so a probe can supply valid inputs
--- to any shader following it. Without this a camera-basis shader normalises
--- a zero vector and produces NaN.
function S.SetStandardConstants(mat)
  local view = render.GetViewSetup()
  local f, r = view.angles:Forward(), view.angles:Right()
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
end

local function readGrid()
  local w, h = ScrW(), ScrH()
  local px = {}
  render.CapturePixels()
  for gy = 0, GRID - 1 do
    for gx = 0, GRID - 1 do
      local x = math.floor((gx + 0.5) * w / GRID)
      local y = math.floor((gy + 0.5) * h / GRID)
      local r, g, b = render.ReadPixel(x, y)
      px[#px + 1] = {r or 0, g or 0, b or 0}
    end
  end
  return px
end

local function luminance(p)
  return (0.299 * p[1] + 0.587 * p[2] + 0.114 * p[3]) / 255
end

local function compare(base, shaded)
  local n = #shaded
  local changed, blown, black = 0, 0, 0
  local sum, sumSq, counted = 0, 0, 0
  local baseSum = 0

  for i = 1, n do
    local b, s = base[i], shaded[i]
    baseSum = baseSum + luminance(b)

    local diff = math.abs(s[1] - b[1]) + math.abs(s[2] - b[2]) + math.abs(s[3] - b[3])
    if diff > 6 then
      changed = changed + 1
      -- Brightness, contrast and clipping are measured ONLY over the pixels the
      -- effect actually touched. A model shader covers a small part of the frame,
      -- so whole-screen averages are dominated by pixels it never wrote and make
      -- a correct shader look broken.
      local l = luminance(s)
      sum, sumSq, counted = sum + l, sumSq + l * l, counted + 1
      if s[1] >= 250 and s[2] >= 250 and s[3] >= 250 then blown = blown + 1 end
      if s[1] <= 4 and s[2] <= 4 and s[3] <= 4 then black = black + 1 end
    end
  end

  local denom = math.max(counted, 1)
  local mean = sum / denom
  return {
    changed = changed / math.max(n, 1),
    lum = mean,
    baseLum = baseSum / math.max(n, 1),
    spread = math.sqrt(math.max(sumSq / denom - mean * mean, 0)),
    blown = blown / denom,
    black = black / denom,
  }
end

local probe = nil -- {hash, mat, usage, stage, base}

net.Receive("claude.shader.probe", function()
  local hash = net.ReadString()
  local usage = net.ReadString()
  local mat = S.mounted[hash]
  if not mat then return end
  probe = {hash = hash, mat = mat, usage = usage, stage = 0}
end)

hook.Add("RenderScreenspaceEffects", "claude.shader.probe.draw", function()
  -- Stage 1 only: this is the frame we want the shader in.
  if not probe or probe.stage ~= 1 or probe.usage ~= "screen" then return end
  S.SetStandardConstants(probe.mat)
  render.UpdateScreenEffectTexture()
  render.SetMaterial(probe.mat)
  render.DrawScreenQuadEx(0, 0, ScrW(), ScrH())
end)

-- model/mesh shaders draw geometry, so a fullscreen quad would tell us nothing.
-- Put a sphere in front of the camera instead and see whether it shows up.
-- Currently unreachable: shader-tool only probes usage == "screen". Kept because
-- the mechanism is sound, but it has two problems to solve before it is trusted
-- again. The ClientsideModel is created inside this hook on the single frame that
-- gets captured, and a clientside entity does not render on its creation frame —
-- so it always measured as invisible. And even fixed, it draws a stand-in prop
-- with default constants, which is not what the build actually ships.
hook.Add("PostDrawOpaqueRenderables", "claude.shader.probe.draw3d", function(depthOnly, skybox)
  if not probe or probe.stage ~= 1 or probe.usage == "screen" then return end
  if depthOnly or skybox then return end

  S.SetStandardConstants(probe.mat)
  S.SetVertexConstants({Vector(CurTime(), 0, 0)})

  local pos = EyePos() + EyeAngles():Forward() * 90
  S.DrawWithDepth(function()
    render.SetMaterial(probe.mat)
    if probe.usage == "model" then
      -- $vertexnormal demands a real model's vertex format.
      if not IsValid(probe.ent) then
        probe.ent = ClientsideModel("models/props_c17/oildrum001.mdl", RENDERGROUP_OPAQUE)
        if IsValid(probe.ent) then
          probe.ent:SetNoDraw(true)
          -- DrawModel ignores render.SetMaterial; override on the entity.
          local path = S.mountedPath[probe.hash]
          if path then probe.ent:SetMaterial(path) end
        end
      end
      if IsValid(probe.ent) then
        probe.ent:SetPos(pos - Vector(0, 0, 25))
        probe.ent:SetupBones()
        probe.ent:DrawModel()
      end
    else
      render.DrawSphere(pos, 26, 24, 24)
    end
  end)
end)

hook.Add("PostRender", "claude.shader.probe", function()
  if not probe then return end

  if probe.stage == 0 then
    probe.base = readGrid() -- clean frame
    probe.stage = 1
    return
  end

  local stats = compare(probe.base, readGrid())
  local hash = probe.hash
  if IsValid(probe.ent) then probe.ent:Remove() end
  probe = nil

  net.Start("claude.shader.probe.result")
  net.WriteString(hash)
  net.WriteFloat(stats.changed)
  net.WriteFloat(stats.lum)
  net.WriteFloat(stats.baseLum)
  net.WriteFloat(stats.spread)
  net.WriteFloat(stats.blown)
  net.WriteFloat(stats.black)
  net.SendToServer()
end)

--------------------------------------------------------------------------------
end
--------------------------------------------------------------------------------

return S
