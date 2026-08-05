---@module "lua.claude.api"
local api = include("claude/api.lua")
---@module "lua.claude.runtime.sandbox"
local sandbox = include("claude/runtime/sandbox.lua")
api.sandbox = sandbox     -- coding agents run Lua through this via the run_lua tool
_G.ClaudeAPI = api        -- exposed for the classify eval concommand
---@module "lua.claude.clarify"
local clarify = include("claude/clarify.lua") -- routes chat replies back to an agent's clarify_with_user tool
---@module "lua.claude.history"
include("claude/history.lua") -- per-player recent creations, for !edit
---@module "lua.claude.services.mount"
include("claude/services/mount.lua")
---@module "lua.claude.services.shader"
include("claude/services/shader.lua")
---@module "lua.claude.services.shader-test"
include("claude/services/shader-test.lua")
---@module "lua.claude.services.classify-eval"
include("claude/services/classify-eval.lua")
---@module "lua.claude.runtime.failsafes"
include("claude/runtime/failsafes.lua")
---@module "lua.claude.services.analytics"
local analytics = include("claude/services/analytics.lua")
---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua")
---@module "lua.claude.commands.runner"
local commands = include("claude/commands/runner.lua")
commands.loadAll({api = api, analytics = analytics, sandbox = sandbox})
api:connect()
repair:initialize(api, sandbox)
sandbox:setupDevCmd()

local function sendDir(name)
  name = name .. "/"
  local files, dirs = file.Find("claude/" .. name .. "*", "LUA")
  for _, f in ipairs(files) do
    AddCSLuaFile("claude/" .. name .. f)
    print(string.format("[gm-claude] Sending Lua file to clients: %s", name .. f))
  end

  for _, d in ipairs(dirs) do
    sendDir(name .. d)
  end
end

sendDir("client")
resource.AddSingleFile("materials/glu/gilb-land-united.png")

timer.Create("claude.moneyleft", 8, 0, function()
  api:getMoneyLeft(function(amount)
    for _, ply in pairs(player.GetAll()) do
      ply:SendLua(string.format("SetMoneyLeft(%.2f)", amount))
    end
  end)
end)

local TEST_MODE = false
local timeoutCmd = commands.commands.timeout

hook.Add("PlayerSay", "claude.chat", function(ply, text)
  -- A pending clarify_with_user question takes priority: this chat line is the
  -- player's answer, so hand it to the waiting agent and swallow the message.
  if clarify:consume(ply, text) then
    net.Start("claude.chat")
    net.WriteString("Your answer has been received. Thank you!")
    net.Send(ply)
    return ""
  end

  local timeLeft = timeoutCmd.remaining(ply)
  if timeLeft > 0 then
    ply:ChatPrint("You are timed out from using anything for another " .. timeLeft .. " seconds.")
    return ""
  end

  if string.sub(text, 1, 1) ~= "!" then return end

  -- Don't allow anyone but me to use commands in test mode, to prevent spam while I'm developing.
  if TEST_MODE and ply:SteamID() ~= "STEAM_0:1:104828323" then
    ply:ChatPrint("The server is currently in test mode, and commands are disabled for regular users. Please wait until testing is complete. Thanks for your understanding!")
    return
  end

  -- Anything unregistered is left alone: it may be another addon's command.
  local command = commands.commands[commands.trigger(text)]
  if not command then return end

  local ok, err = commands.consume(ply, text)
  if not ok then
    ply:ChatPrint(tostring(err))
    return ""
  end

  return command.keepInChat and text or ""
end)

-- Remove base game auth, no need.
hook.Remove("PlayerInitialSpawn", "PlayerAuthSpawn")

timer.Create("claude.heartbeat", 15, 0, function()
  print("[gm-claude] Sending heartbeat to analytics...")
  analytics:sendHeartbeat()
end)