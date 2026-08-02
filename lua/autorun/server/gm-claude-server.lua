---@module "lua.claude.api"
local api = include("claude/api.lua")
---@module "lua.claude.runtime.sandbox"
local sandbox = include("claude/runtime/sandbox.lua")
_G.GilbSandbox = sandbox  -- exposed for tests.lua net handler
api.sandbox = sandbox     -- coding agents run Lua through this via the run_lua tool
---@module "lua.claude.clarify"
local clarify = include("claude/clarify.lua") -- routes chat replies back to an agent's clarify_with_user tool
---@module "lua.claude.history"
local history = include("claude/history.lua") -- per-player recent creations, for !edit
---@module "lua.claude.services.mount"
include("claude/services/mount.lua")
---@module "lua.claude.runtime.failsafes"
include("claude/runtime/failsafes.lua")
---@module "lua.claude.services.analytics"
local analytics = include("claude/services/analytics.lua")
---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua")
api:connect()
repair:initialize(api, sandbox)
sandbox:setupDevCmd()
---@module "lua.claude.services.embeddings"
include("claude/services/embeddings.lua")
embeddings.SetAPI(api)
include("claude/tests.lua")

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

local COOLDOWN = 30
local TEST_MODE = false
local playerLastPromptTime = {}
local timeoutPlayers = {}

-- Shared entry point for both a new request (!c) and an edit (!edit). Enforces the
-- per-player cooldown, kicks the planner pipeline, and relays its closing summary.
-- opts is forwarded to api:sendPrompt (nil for a fresh build; {promptId, editContext}
-- for an edit). Returns true if the request was accepted, false if rate-limited.
local function startPrompt(ply, prompt, opts)
  playerLastPromptTime[ply] = playerLastPromptTime[ply] or -COOLDOWN
  if CurTime() - playerLastPromptTime[ply] < COOLDOWN then
    local timeLeft = math.ceil(COOLDOWN - (CurTime() - playerLastPromptTime[ply]))
    ply:ChatPrint("Please wait " .. timeLeft .. " seconds before sending another prompt.")
    return false
  end
  playerLastPromptTime[ply] = CurTime()

  ply:ChatPrint("Sending your request to GilbLM...")
  print("[gm-claude] Sending prompt to API: " .. prompt)
  ply:SendLua("ChangeClaudeStatus('thinking')")
  print("[gm-claude] Sending analytics for prompt...")
  analytics:sendPrompt(prompt, ply)
  api:sendPrompt(ply, prompt, function(result, promptId)
    -- The planner + coding agents already executed everything via run_lua, and
    -- the coders self-correct on errors, so there's nothing to run here anymore.
    ply:SendLua("ChangeClaudeStatus('idle')")
    print("[gm-claude] Prompt " .. tostring(promptId) .. " finished.")
    if type(result) == "string" and #result > 0 then
      net.Start("claude.chat")
      net.WriteString(result)
      net.Send(ply)
    end
  end, opts)
  return true
end

hook.Add("PlayerSay", "claude.chat", function(ply, text)
  -- A pending clarify_with_user question takes priority: this chat line is the
  -- player's answer, so hand it to the waiting agent and swallow the message.
  if clarify:consume(ply, text) then
    net.Start("claude.chat")
    net.WriteString("Your answer has been received. Thank you!")
    net.Send(ply)
    return ""
  end

  -- if timed out, no!
  timeoutPlayers[ply] = timeoutPlayers[ply] or 0
  
    if CurTime() < timeoutPlayers[ply] then
      local timeLeft = math.ceil(timeoutPlayers[ply] - CurTime())
      ply:ChatPrint("You are timed out from using anything for another " .. timeLeft .. " seconds.")
      return ""
    else
      timeoutPlayers[ply] = nil
    end

  -- Don't allow anyone but me to use commands in test mode, to prevent spam while I'm developing.
  if TEST_MODE and ply:SteamID() ~= "STEAM_0:1:104828323" and text:sub(1, 1) == "!" then
    ply:ChatPrint("The server is currently in test mode, and commands are disabled for regular users. Please wait until testing is complete. Thanks for your understanding!")
    return
  end

  if string.sub(text, 1, 5) == "!edit" then
    -- !edit               -> list this player's recent creations
    -- !edit <n> <change>  -> re-run creation #n with the change applied
    local rest = string.Trim(string.sub(text, 6))
    local recent = history:list(ply)

    if rest == "" then
      if #recent == 0 then
        ply:ChatPrint("You have nothing to edit yet - make something with !c first.")
      else
        ply:ChatPrint("Your recent creations - use !edit <number> <change>:")
        for i, rec in ipairs(recent) do
          ply:ChatPrint(string.format("  %d. %s", i, rec.prompt))
        end
      end
      return ""
    end

    local idxStr, instruction = string.match(rest, "^(%d+)%s+(.+)$")
    local idx = tonumber(idxStr)
    if not idx or not instruction then
      ply:ChatPrint("Usage: !edit <number> <what to change>  (e.g. !edit 2 make more explosions). Send !edit alone to list.")
      return ""
    end

    local rec = recent[idx]
    if not rec then
      ply:ChatPrint("No creation #" .. idx .. " in your recent list. Send !edit to see it.")
      return ""
    end

    ply:ChatPrint(string.format('Editing "%s"...', rec.prompt))
    startPrompt(ply, instruction, {
      promptId = rec.promptId, -- reuse the id so the rebuild overwrites the original
      editContext = {originalPrompt = rec.prompt, artifacts = rec.artifacts},
    })
    return ""
  elseif string.sub(text, 1, 2) == "!c" then
    if text:lower():find("kanye") then
      ply:ChatPrint("Fuck you.")
      ply:Kill()
      return
    end

    local prompt = string.Trim(string.sub(text, 3))
    startPrompt(ply, prompt)
  elseif string.sub(text, 1, 6) == "!mount" then
    local addonId = string.Trim(string.sub(text, 7))
    if addonId ~= "" then
      ply:ChatPrint("Attempting to mount Workshop addon with ID: " .. addonId)
      mount.WorkshopAddon(addonId)
    else
      ply:ChatPrint("Please provide a valid Workshop addon ID. Usage: !mount <addon_id>")
    end
  elseif string.sub(text, 1, 6) == "!model" then
    local modelName = string.Trim(string.sub(text, 7))
    if modelName ~= "" then
      api.CURRENT_MODEL = modelName
      ply:ChatPrint("Set the current model to: " .. modelName)
    else
      ply:ChatPrint("Please provide a valid model name. Usage: !model <model_name>")
    end
  elseif string.sub(text, 1, 9) == "!priority" then
    local priority = string.Trim(string.sub(text, 10))
    if priority ~= "" then
      api.CURRENT_PRIORITY = priority
      ply:ChatPrint("Set the current priority to: " .. priority)
    else
      ply:ChatPrint("Please provide a valid priority. Usage: !priority <priority>")
    end
  elseif string.sub(text, 1, 18) == "!removeclienthooks" then
    sandbox:removeClientHooks()
    ply:ChatPrint("Requested clients to remove all hooks registered by Claude.")
    -- !timeout
  elseif string.sub(text, 1, 8) == "!timeout" then
    if ply:SteamID() ~= "STEAM_0:1:104828323" then
      ply:ChatPrint("You don't have permission to use this command.")
      return
    end

    -- !timeout <ply, can be short name> 10m
    local args = string.Split(string.Trim(string.sub(text, 9)), " ")
    if #args ~= 2 then
      ply:ChatPrint("Invalid command format. Usage: !timeout <player> <duration>")
      return
    end

    local targetPly = nil
    for _, p in pairs(player.GetAll()) do
      if string.find(string.lower(p:Nick()), string.lower(args[1]), 1, true) then
        targetPly = p
        break
      end
    end

    if not targetPly then
      ply:ChatPrint("Player not found: " .. args[1])
      return
    end

    if timeoutPlayers[targetPly] then
      ply:ChatPrint("Player is already timed out: " .. targetPly:Nick())
      return
    end

    if args[2]:sub(-1) == "m" then
      timeoutPlayers[targetPly] = CurTime() + tonumber(args[2]:sub(1, -2)) * 60
    elseif args[2]:sub(-1) == "s" then
      timeoutPlayers[targetPly] = CurTime() + tonumber(args[2]:sub(1, -2))
    else
      ply:ChatPrint("Invalid duration format. Use 's' for seconds or 'm' for minutes. Example: 30s or 10m")
      return
    end

    ply:ChatPrint("Timed out player " .. targetPly:Nick() .. " for " .. args[2])
  end
end)

-- Remove base game auth, no need.
hook.Remove("PlayerInitialSpawn", "PlayerAuthSpawn")

timer.Create("claude.heartbeat", 15, 0, function()
  print("[gm-claude] Sending heartbeat to analytics...")
  analytics:sendHeartbeat()
end)