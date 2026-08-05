include("claude/services/mount.lua")
include("claude/services/shader.lua")

-- Chunk names (promptIds) of AI-generated code this client has run, so the error
-- reporters can tell which errors are ours and worth siphoning to the server. The
-- server threads the promptId alongside the code (see sandbox.lua).
local claudePromptIds = {}
-- The promptId currently being executed, so callbacks registered during the run are
-- wrapped with the id that owns them (they fire later, when isClaudeRunning is false).
local currentPromptId = nil
local isClaudeRunning = false

-- ------------------------------------------------------------ error capture ----
-- The client mirror of the server sandbox's capture: wrap the callbacks AI code
-- registers so a deferred error inside one is caught *before the stack unwinds* —
-- which is the only place we can read the locals — enriched, and siphoned to the
-- server. Without this a client error only reaches the coarse OnLuaError backstop
-- (no locals), which is why runtime repairs used to arrive with "(no detail)".

local function tostringSafe(v)
  local ok, s = pcall(tostring, v)
  if not ok then s = "<tostring error>" end
  if #s > 80 then s = s:sub(1, 77) .. "..." end
  return s
end

--- Dump the locals of the failing frame(s) that live in the generated chunk. Runs
--- inside the xpcall handler, so the values at the moment of the error are still live.
local function snapshotLocals(promptId)
  local out = {}
  for level = 2, 16 do
    local info = debug.getinfo(level, "Sln")
    if not info then break end
    local src = tostring(info.short_src or info.source or "")
    if src == promptId or src:find(promptId, 1, true) then
      local parts = {}
      for i = 1, 40 do
        local name, value = debug.getlocal(level, i)
        if not name then break end
        if name:sub(1, 1) ~= "(" then
          parts[#parts + 1] = string.format("%s = %s", name, tostringSafe(value))
        end
      end
      out[#out + 1] = string.format("line %d: %s", info.currentline or -1, table.concat(parts, ", "))
    end
  end
  return table.concat(out, "\n")
end

-- Siphon a clientside error (with detail) back to the server. A client error
-- otherwise never leaves the client, so the server and the repair loop would never
-- learn the code failed for players. Rate-limited per (promptId, error).
local lastClientErrorReport = {}
local CLIENT_ERROR_MIN_INTERVAL = 1
local function reportClientError(promptId, err, detail)
  if not promptId or not claudePromptIds[promptId] then return end
  local key = promptId .. "\0" .. tostring(err)
  if (lastClientErrorReport[key] or 0) + CLIENT_ERROR_MIN_INTERVAL > CurTime() then return end
  lastClientErrorReport[key] = CurTime()

  net.Start("claude.clienterror")
  net.WriteString(promptId)
  net.WriteString(tostring(err))
  net.WriteString(detail or "")
  net.SendToServer()
end

--- Wrap a callback so a runtime error inside it is caught, enriched with a traceback
--- + locals, and reported. Returns pass through untouched on success.
local function wrapCallback(promptId, fn)
  if type(fn) ~= "function" then return fn end
  local function handler(err)
    local okCap, detail = pcall(function()
      local locals = snapshotLocals(promptId)
      local trace = debug.traceback(tostring(err), 2)
      return locals ~= "" and (trace .. "\nLocals at error:\n" .. locals) or trace
    end)
    reportClientError(promptId, tostring(err), okCap and detail or nil)
    return err
  end
  return function(...)
    local res = { xpcall(fn, handler, ...) }
    if res[1] then return unpack(res, 2) end
  end
end

-- Detour the async entry points, wrapping only what AI code registers (guarded by
-- isClaudeRunning — the window is a single RunString, so no other addon registers
-- inside it). Consistent with how hook.Add was already detoured here.
local claudeHooks = {}
local oldHookAdd = hook.Add
hook.Add = function(event, identifier, func)
  if isClaudeRunning then
    table.insert(claudeHooks, {event = event, identifier = identifier})
    print(string.format("[gm-claude] Registered hook during Claude execution: %s (%s)", event, identifier))
    func = wrapCallback(currentPromptId, func)
    if event == "InitPostEntity" then
      print("[gm-claude] Warning: Claude is adding a hook to InitPostEntity. This may cause issues if not handled properly. Executing it now...")
      func()
    end
  end
  return oldHookAdd(event, identifier, func)
end

local function wrapRegister(orig)
  return function(tbl, name)
    if isClaudeRunning then
      for k, v in pairs(tbl) do
        if type(v) == "function" then tbl[k] = wrapCallback(currentPromptId, v) end
      end
    end
    return orig(tbl, name)
  end
end
weapons.Register = wrapRegister(weapons.Register)
scripted_ents.Register = wrapRegister(scripted_ents.Register)

local oldTimerCreate = timer.Create
timer.Create = function(name, delay, reps, func, ...)
  if isClaudeRunning then func = wrapCallback(currentPromptId, func) end
  return oldTimerCreate(name, delay, reps, func, ...)
end
local oldTimerSimple = timer.Simple
timer.Simple = function(delay, func)
  if isClaudeRunning then func = wrapCallback(currentPromptId, func) end
  return oldTimerSimple(delay, func)
end
local oldNetReceive = net.Receive
net.Receive = function(name, func)
  if isClaudeRunning then func = wrapCallback(currentPromptId, func) end
  return oldNetReceive(name, func)
end

-- --------------------------------------------------------------- boot splash ----
-- On join the screen is plain black with the logo centred. The server streams this
-- client its backlog of Lua one chunk at a time (see the claude.requestlua handler in
-- sandbox.lua), so "everything has run" is simply "nothing more arrived for a beat":
-- each chunk pushes the release back, and when the wait expires the black fades out
-- while the logo flies to its HUD corner. A hard cap releases it if the sync stalls.
local LOGO_CORNER_X, LOGO_CORNER_Y, LOGO_CORNER_SIZE = -10, -20, 128
local SPLASH_LOGO_FRAC = 0.7  -- centred logo size, as a fraction of screen height
local SPLASH_HOLD      = 2    -- seconds of quiet before the splash lets go
local SPLASH_FLIGHT    = 1.2  -- seconds spent flying to the corner / fading the black
local SPLASH_MAX       = 30   -- seconds after spawn we release regardless of the sync
local splashDone        = false -- true once the intro is over and the HUD is normal
local splashReadyAt     = 0     -- CurTime() the flight starts; 0 while nothing scheduled
local splashDeadline    = 0     -- CurTime() we release no matter what; 0 before spawn
local splashFlightStart = 0     -- CurTime() the flight began; 0 while still on black

--- Push the splash release back by the hold. Called on spawn and again for every
--- chunk of Lua, so the countdown only runs out once the stream has gone quiet.
local function delaySplash()
  if splashDone or splashFlightStart > 0 then return end
  splashReadyAt = CurTime() + SPLASH_HOLD
end

-- Shader GMAs stream before the Lua does, so they have to hold the splash too.
hook.Add("ClaudeSyncActivity", "claude.splash", delaySplash)

net.Receive("claude.runlua", function()
  local code = net.ReadString()
  local promptId = net.ReadString()
  if promptId ~= "" then claudePromptIds[promptId] = true end

  ENT = {}
  SWEP = {Primary = {}, Secondary = {}} -- make sure these tables exist for SWEP code
  currentPromptId = promptId ~= "" and promptId or nil
  isClaudeRunning = true
  -- handleError = true so a load-time error is reported through OnLuaError (and thus
  -- siphoned to the server) instead of halting this receiver. The chunk name is the
  -- promptId so every error — load-time or deferred — is attributable to its creation.
  RunString(code, currentPromptId or "gm-claude-remote", true)
  isClaudeRunning = false
  currentPromptId = nil
  ENT = nil
  SWEP = nil
  RunConsoleCommand("spawnmenu_reload")
  delaySplash()
end)

-- Backstop for errors NOT caught by a wrapper (top-level load errors, or code that
-- reached a raw global). No locals are available this late, but forward the parsed
-- stack so the report still carries context instead of just the message.
hook.Add("OnLuaError", "claude.report", function(err, realm, stack)
  if not istable(stack) then return end

  local promptId
  for _, frame in ipairs(stack) do
    if frame.File and claudePromptIds[frame.File] then
      promptId = frame.File
      break
    end
  end
  if not promptId then return end

  local lines = { tostring(err) }
  for _, frame in ipairs(stack) do
    lines[#lines + 1] = string.format("  %s:%s in %s",
      tostring(frame.File), tostring(frame.Line), tostring(frame.Function or "?"))
  end
  reportClientError(promptId, err, table.concat(lines, "\n"))
end)

function RemoveClientClaudeHooks()
  for _, hookInfo in ipairs(claudeHooks) do
    hook.Remove(hookInfo.event, hookInfo.identifier)
    print(string.format("[gm-claude] Removed hook: %s (%s)", hookInfo.event, hookInfo.identifier))
  end
  claudeHooks = {}
end

print("[gm-claude] Clientside code loaded. Waiting for commands from the server...")

hook.Add("InitPostEntity", "claude.client.init", function()
  print("[gm-claude] Client environment initialized. Ready to receive Lua code from the server.")
  net.Start("claude.requestlua")
  net.SendToServer()

  -- Start the countdown now: if the server has no Lua for us it sends nothing at all,
  -- and the splash would otherwise sit on black waiting for a chunk that never comes.
  splashDeadline = CurTime() + SPLASH_MAX
  delaySplash()
end)

local FINISH_TEXT_DURATION = 2
local claudeStatus = "idle"
local finishTime = 0
local confettiParticles = {}

-- Logo rainbow flourish on finish: hue spins while saturation ramps in and then
-- back out, so the logo blooms out of white and settles back into it.
local LOGO_RAINBOW_DURATION = 2    -- seconds the whole flourish lasts
local LOGO_RAINBOW_SPEED    = 480  -- degrees of hue per second
local LOGO_RAINBOW_RAMP     = 0.15 -- fraction of the duration spent fading colour in
local logoRainbowStart = 0         -- CurTime() the flourish began; 0 while inactive

-- Progress bar under the status text. There's no known max number of steps, so it's
-- exponential: each tick from the server (one agent LLM round-trip) closes a fixed
-- fraction of the REMAINING gap to 1 — fast at first, ever slower, never quite full.
-- On done it snaps to 100% and fades out.
local PROGRESS_STEP  = 0.10 -- fraction of the remaining gap each tick closes
local PROGRESS_LERP  = 7    -- how fast the drawn bar eases toward its target
local PROGRESS_HOLD  = 0.5  -- seconds held at full before fading
local PROGRESS_FADE  = 1.0  -- fade-out duration
local PROGRESS_WIDTH = 220
local PROGRESS_HEIGHT = 4
local progressActive  = false
local progressTarget  = 0
local progressDisplay = 0
local progressDoneAt  = 0   -- CurTime() when it snapped to done; 0 while in progress

net.Receive("claude.progress", function()
  -- Ignore ticks once we've snapped to done, so a late straggler can't unsettle it.
  if not progressActive or progressDoneAt > 0 then return end
  progressTarget = progressTarget + (1 - progressTarget) * PROGRESS_STEP
end)

local function makeConfettiParticle(x, y, velX, velY)
  return {
    x = x,
    y = y,
    velX = velX,
    velY = velY,
    size = math.random(4, 8),
    color = Color(math.random(50, 255), math.random(50, 255), math.random(50, 255)),
    lifetime = CurTime() + math.random(1, 3),
    rotation = math.random(0, 360),
  }
end

function ChangeClaudeStatus(newStatus)
  claudeStatus = newStatus
  if newStatus == "thinking" then
    -- New prompt: reset the bar and start filling from empty.
    progressActive = true
    progressTarget = 0
    progressDisplay = 0
    progressDoneAt = 0
  elseif newStatus == "idle" then
    -- Finished: snap the bar to 100% and let it fade out.
    progressTarget = 1
    progressDoneAt = CurTime()

    finishTime = CurTime() + 2
    logoRainbowStart = CurTime()
    surface.PlaySound("garrysmod/save_load" .. math.random(1, 4) .. ".wav")
    util.ScreenShake(Vector(0, 0, 0), 5, 150, 0.5, 500)
    for i = 1, math.random(20, 70) do
      local x, y = chat.GetChatBoxPos()
      table.insert(confettiParticles, makeConfettiParticle(x + 30, y, math.random(320, 800), math.random(-500, -300)))
    end
  end
end

local dots = ""
local lastDotUpdate = 0
local moneyLeft = -1
local moneyDelta = 0
local moneyDeltaShowTime = 0
local moneyDeltaY = 115

function SetMoneyLeft(amount)
  moneyDelta = amount - moneyLeft
  moneyDeltaShowTime = CurTime() + 3
  moneyDeltaY = 115

  moneyLeft = amount

  if moneyDelta < 0 then
    -- Play a bad button buzzing sound
    surface.PlaySound("buttons/button10.wav")
    -- Shoot out some confetti!!!
    for i = 1, math.random(10, 30) do
      table.insert(confettiParticles, makeConfettiParticle(150, 50, math.random(320, 800), math.random(-500, -300)))
    end
  end
end

local logoMat = Material("glu/gilb-land-united.png", "smooth")

--- Where the logo belongs this frame, plus how opaque the black behind it is.
--- Returns x, y, size, blackness (0-1). Advances the splash and retires it when done.
local function logoPlacement()
  if splashDone then return LOGO_CORNER_X, LOGO_CORNER_Y, LOGO_CORNER_SIZE, 0 end

  -- On a live reload InitPostEntity never fires again, so arm the timers here too —
  -- the first painted frame is the latest point the splash can safely start from.
  if splashDeadline == 0 then
    splashDeadline = CurTime() + SPLASH_MAX
    delaySplash()
  end

  -- Sized off screen height so it fills the same amount of the screen at any res.
  local splashSize = ScrH() * SPLASH_LOGO_FRAC
  local centreX = ScrW() * 0.5 - splashSize * 0.5
  local centreY = ScrH() * 0.5 - splashSize * 0.5

  if splashFlightStart == 0 then
    local due = splashReadyAt > 0 and CurTime() >= splashReadyAt
    local expired = splashDeadline > 0 and CurTime() >= splashDeadline
    if not (due or expired) then
      return centreX, centreY, splashSize, 1
    end
    splashFlightStart = CurTime()
  end

  local frac = (CurTime() - splashFlightStart) / SPLASH_FLIGHT
  if frac >= 1 then
    splashDone = true
    return LOGO_CORNER_X, LOGO_CORNER_Y, LOGO_CORNER_SIZE, 0
  end

  -- Smoothstep, so the logo leaves the centre and lands in the corner without a jolt.
  local eased = frac * frac * (3 - 2 * frac)
  return Lerp(eased, centreX, LOGO_CORNER_X),
         Lerp(eased, centreY, LOGO_CORNER_Y),
         Lerp(eased, splashSize, LOGO_CORNER_SIZE),
         1 - eased
end

local function drawLogo(x, y, size)
  surface.SetMaterial(logoMat)
  local logoColor = color_white
  if logoRainbowStart > 0 then
    local frac = (CurTime() - logoRainbowStart) / LOGO_RAINBOW_DURATION
    if frac >= 1 then
      logoRainbowStart = 0
    else
      -- Saturation eases up over the first slice, then back down over the rest,
      -- so both ends of the flourish meet plain white with no pop.
      local sat
      if frac < LOGO_RAINBOW_RAMP then
        sat = frac / LOGO_RAINBOW_RAMP
      else
        sat = 1 - (frac - LOGO_RAINBOW_RAMP) / (1 - LOGO_RAINBOW_RAMP)
      end
      local hue = ((CurTime() - logoRainbowStart) * LOGO_RAINBOW_SPEED) % 360
      logoColor = HSVToColor(hue, math.Clamp(sat, 0, 1), 1)
    end
  end
  surface.SetDrawColor(logoColor.r, logoColor.g, logoColor.b, 255)
  surface.DrawTexturedRect(x, y, size, size)
end

hook.Add("HUDPaint", "claude.client.hud", function()
  local logoX, logoY, logoSize, black = logoPlacement()

  -- type !c <prompt> in chat
  draw.SimpleText("!c <prompt> in chat", "ChatFont", 10, 75, Color(250, 250, 250, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
  -- current server demand tier (low = smarter models, high = faster/cheaper)
  local demand = _G.ClaudeDemand or "low"
  local demandColor = demand == "high" and Color(255, 170, 90, 120) or Color(150, 220, 255, 120)
  draw.SimpleText("demand: " .. demand, "ChatFont", 10, 95, demandColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
  if moneyLeft >= 0 then
    draw.SimpleText("money left:", "ChatFont", 10, 115, Color(255, 255, 255, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(string.format("$%.2f", moneyLeft), "ChatFont", 90, 115, Color(0, 255, 0, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    -- If it goes down, show a little funny -$x text that fades out
    if moneyDelta < 0 and CurTime() < moneyDeltaShowTime then
      local alpha = math.Clamp((moneyDeltaShowTime - CurTime()) / 3, 0, 1) * 255
      moneyDeltaY = moneyDeltaY - FrameTime() * 20
      draw.SimpleText(string.format("-$%.2f", -moneyDelta), "ChatFont", 140, moneyDeltaY, Color(255, 0, 0, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
  end

  local x, y = chat.GetChatBoxPos()
  local w, h = chat.GetChatBoxSize()

  if claudeStatus ~= "idle" then
    if CurTime() - lastDotUpdate > 0.5 then
      dots = dots .. "."
      if #dots > 3 then
        dots = ""
      end
      lastDotUpdate = CurTime()
    end

    if claudeStatus == "thinking" then
      draw.SimpleText("Thinking" .. dots, "ChatFont", x, y, Color(255, 255, 0, 200), TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
    end
  end

  if finishTime > CurTime() then
    local alpha = math.Clamp((finishTime - CurTime()) / FINISH_TEXT_DURATION, 0, 1) * 200
    draw.SimpleText("Done!", "ChatFont", x, y, Color(0, 255, 0, alpha), TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
  end

  -- Progress bar, just below the status text (which is bottom-aligned to y).
  if progressActive then
    -- Ease the drawn value toward the target so ticks slide in instead of jumping.
    progressDisplay = progressDisplay + (progressTarget - progressDisplay) * math.min(1, FrameTime() * PROGRESS_LERP)

    local alpha = 1
    if progressDoneAt > 0 then
      local since = CurTime() - progressDoneAt
      if since > PROGRESS_HOLD then
        alpha = math.Clamp(1 - (since - PROGRESS_HOLD) / PROGRESS_FADE, 0, 1)
        if alpha <= 0 then progressActive = false end
      end
    end

    local by = y + 4
    surface.SetDrawColor(0, 0, 0, 140 * alpha)
    surface.DrawRect(x, by, PROGRESS_WIDTH, PROGRESS_HEIGHT)
    surface.SetDrawColor(120, 220, 255, 235 * alpha)
    surface.DrawRect(x, by, PROGRESS_WIDTH * math.Clamp(progressDisplay, 0, 1), PROGRESS_HEIGHT)
  end

  -- Render all confetti particles
  for i = #confettiParticles, 1, -1 do
    local p = confettiParticles[i]
    if CurTime() > p.lifetime then
      table.remove(confettiParticles, i)
    else
      p.x = p.x + p.velX * FrameTime()
      p.y = p.y + p.velY * FrameTime()
      p.velY = p.velY + 800 * FrameTime() -- gravity
      p.rotation = p.rotation + 180 * FrameTime() -- spin
      p.rotation = p.rotation % 360

      local alpha = math.Clamp((p.lifetime - CurTime()) / 3, 0, 1) * 255
      surface.SetDrawColor(p.color.r, p.color.g, p.color.b, alpha)
      draw.NoTexture()
      surface.DrawTexturedRectRotated(p.x, p.y, p.size, p.size, p.rotation)
    end
  end

  -- The splash curtain goes over the HUD chrome above, so that chrome fades in as the
  -- black lifts. The logo rides on top of the curtain the whole way to its corner.
  if black > 0 then
    surface.SetDrawColor(0, 0, 0, 255 * black)
    surface.DrawRect(0, 0, ScrW(), ScrH())
  end
  drawLogo(logoX, logoY, logoSize)
end)