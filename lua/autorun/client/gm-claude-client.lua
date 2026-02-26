include("claude/mount.lua")
include("claude/embeddings.lua")
local claudeHooks = {}
local oldHookAdd = hook.Add
local isClaudeRunning = false
hook.Add = function(event, identifier, func)
  if isClaudeRunning then
    table.insert(claudeHooks, {event = event, identifier = identifier})
    print(string.format("[gm-claude] Registered hook during Claude execution: %s (%s)", event, identifier))
    if event == "InitPostEntity" then
      print("[gm-claude] Warning: Claude is adding a hook to InitPostEntity. This may cause issues if not handled properly. Executing it now...")
      func()
    end
  end

  return oldHookAdd(event, identifier, func)
end

net.Receive("claude.runlua", function()
  ENT = {}
  SWEP = {Primary = {}, Secondary = {}} -- make sure these tables exist for SWEP code
  isClaudeRunning = true
  RunString(net.ReadString(), "gm-claude-remote", false)
  isClaudeRunning = false
  ENT = nil
  SWEP = nil
  RunConsoleCommand("spawnmenu_reload")
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
end)

local FINISH_TEXT_DURATION = 2
local claudeStatus = "idle"
local finishTime = 0
local confettiParticles = {}

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
  if newStatus == "idle" then
    finishTime = CurTime() + 2
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
local moneyDeltaY = 50

function SetMoneyLeft(amount)
  moneyDelta = amount - moneyLeft
  moneyDeltaShowTime = CurTime() + 3
  moneyDeltaY = 50

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

hook.Add("HUDPaint", "claude.client.hud", function()
  draw.SimpleText("gilb land united", "ChatFont", 10, 10, Color(255, 255, 255, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
  -- type !c <prompt> in chat
  draw.SimpleText("!c <prompt> in chat", "ChatFont", 10, 30, Color(250, 250, 250, 100), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
  if moneyLeft >= 0 then
    draw.SimpleText("money left:", "ChatFont", 10, 50, Color(255, 255, 255, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(string.format("$%.2f", moneyLeft), "ChatFont", 90, 50, Color(0, 255, 0, 120), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
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
end)