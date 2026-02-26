---@module "lua.claude.api"
local api = include("claude/api.lua")
---@module "lua.claude.sandbox"
local sandbox = include("claude/sandbox.lua")
---@module "lua.claude.mount"
include("claude/mount.lua")
---@module "lua.claude.failsafes"
include("claude/failsafes.lua")
---@module "lua.claude.analytics"
local analytics = include("claude/analytics.lua")
---@module "lua.claude.repair"
local repair = include("claude/repair.lua")
api:connect()
repair:initialize(api, sandbox)
---@module "lua.claude.embeddings"
include("claude/embeddings.lua")
embeddings.SetAPI(api)

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

timer.Create("claude.moneyleft", 8, 0, function()
  api:getMoneyLeft(function(amount)
    for _, ply in pairs(player.GetAll()) do
      ply:SendLua(string.format("SetMoneyLeft(%.2f)", amount))
    end
  end)
end)

local COOLDOWN = 30
local playerLastPromptTime = {}
local timeoutPlayers = {}

hook.Add("PlayerSay", "claude.chat", function(ply, text)
  -- if timed out, no!
  if timeoutPlayers[ply] and text:sub(1, 1) == "!" then
    if CurTime() < timeoutPlayers[ply] then
      local timeLeft = math.ceil(timeoutPlayers[ply] - CurTime())
      ply:ChatPrint("You are timed out from using anything for another " .. timeLeft .. " seconds.")
      return ""
    else
      timeoutPlayers[ply] = nil
    end
  end

  if string.sub(text, 1, 2) == "!c" then
    playerLastPromptTime[ply] = playerLastPromptTime[ply] or 0
    if CurTime() - playerLastPromptTime[ply] < COOLDOWN then
      local timeLeft = math.ceil(COOLDOWN - (CurTime() - playerLastPromptTime[ply]))
      ply:ChatPrint("Please wait " .. timeLeft .. " seconds before sending another prompt.")
      return
    end
    playerLastPromptTime[ply] = CurTime()

    local prompt = string.Trim(string.sub(text, 3))

    ply:ChatPrint("Sending your request to Claude...")
    print("[gm-claude] Sending prompt to API: " .. prompt)
    ply:SendLua("ChangeClaudeStatus('thinking')")
    print("[gm-claude] Sending analytics for prompt...")
    analytics:sendPrompt(prompt, ply)
    api:sendPrompt(ply, prompt, function(luaCode, promptId)
      repair:add(promptId, ply, prompt, luaCode)
      ply:SendLua("ChangeClaudeStatus('idle')")
      print("[gm-claude] Received Lua code from API: " .. luaCode)
      print("[gm-claude] promptId: " .. tostring(promptId))
      local success, errMsg = sandbox:run(luaCode, promptId)
      if not success then
        ply:ChatPrint("Sorry, there was an error executing the code from Claude. Check the server console for details.")
        if errMsg then
          ply:ChatPrint("Error details: " .. errMsg)
        end
        ply:ChatPrint("Retrying with Gemini...")
        ply:SendLua("ChangeClaudeStatus('thinking')")
        api:sendPrompt(ply, prompt, function(geminiLuaCode, geminiPromptId)
          repair:add(geminiPromptId, ply, prompt, geminiLuaCode)
          ply:SendLua("ChangeClaudeStatus('idle')")
          print("[gm-claude] Received Lua code from Gemini: " .. geminiLuaCode)
          local geminiSuccess, geminiErrMsg = sandbox:run(geminiLuaCode, geminiPromptId)
          if not geminiSuccess then
            ply:ChatPrint("Sorry, there was also an error executing the code from Gemini. Check the server console for details.")
            if geminiErrMsg then
              ply:ChatPrint("Gemini error details: " .. geminiErrMsg)
            end
          else
            ply:ChatPrint("Successfully executed Gemini's response!")
          end
        end, "google/gemini-3-flash-preview:nitro")
      end
    end)
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