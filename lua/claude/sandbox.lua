-- Not too strict of a sandbox, but it should be good enough
-- to prevent any major problems, like dropping SQL tables or reading/writing files.
-- It also includes some helper functions and a custom environment to run the code in.

local naughty = include("claude/naughty.lua")
local analyze = include("claude/analysis.lua")

util.AddNetworkString("claude.runlua")
util.AddNetworkString("claude.requestlua")
util.AddNetworkString("claude.chat")

local ALL_CLIENT_LUA = {}
local CLIENT_LUA_SEND_DELAY = 3 -- helps prevent intense lag
local playerSuspendedEnts = {}

hook.Add("PlayerInitialSpawn", "claude.prevent-transmission", function(ply)
  playerSuspendedEnts[ply] = {}
  -- We want to prevent ANY of our Claude written entities from transmitting to the player,
  -- cause they dont have our Lua yet.  

  local claudeEnts = {}
  for k, v in pairs(ents.GetAll()) do
    local name = v:GetClass()
    local ent = scripted_ents.Get(name)
    local wep = weapons.Get(name)
    ent = ent or wep
    if ent and ent.IsClaude then
      table.insert(claudeEnts, v)
    end
  end

  playerSuspendedEnts[ply] = claudeEnts
  for k, ent in pairs(claudeEnts) do
    ent:SetPreventTransmit(ply, true)
  end
end)

net.Receive("claude.requestlua", function(len, ply)
  -- Also ensure they have everything mounted!
  for _, id in ipairs(mount.LoadedAddons) do
    mount.ForcePlayerMount(ply, id)
  end

  -- This client wants to get all the Lua code that Claude has sent to clients so far, so we can run it and make sure our clientside environment is up to date
  ply:SendLua([[notification.AddProgress("claude", "Syncing Claude Lua code...", 0)]])
  -- cant overwhelm them so one at a time with a small delay
  local delay = 0
  for i, luaCode in ipairs(ALL_CLIENT_LUA) do
    timer.Simple(delay, function()
      if IsValid(ply) then
        net.Start("claude.runlua")
        net.WriteString(luaCode)
        net.Send(ply)
        
        local frac = i / #ALL_CLIENT_LUA
        ply:SendLua(string.format([[notification.AddProgress("claude", "Syncing Claude Lua code...", %.1f)]], frac))
      end
      delay = delay + CLIENT_LUA_SEND_DELAY
    end)
  end

  timer.Simple(delay + 0.5, function()
    if IsValid(ply) then
      ply:SendLua([[notification.AddProgress("claude", "Claude Lua code synced!", 1)]])
      timer.Simple(2, function()
        if IsValid(ply) then
          ply:SendLua([[notification.Kill("claude")]])
          -- Allow any Claude entities to transmit to this player now, since their Lua is synced
          local suspendedEnts = playerSuspendedEnts[ply] or {}
          for k, ent in pairs(suspendedEnts) do
            if IsValid(ent) then
              ent:SetPreventTransmit(ply, false)
            end
          end
          playerSuspendedEnts[ply] = nil
        end
      end)
    end
  end)
end)

return {
  initializeEnv = function(self, promptId)
    local env = {}
    -- Copy all of _G in
    for k, v in pairs(_G) do
      env[k] = v
    end

    -- Blacklist some bad stuff
    env.sql = nil
    env.file = nil
    env.debug = nil
    env.http = nil
    env.jit = nil
    env.getfenv = nil
    env.setfenv = nil
    
    local function announceClaude(msg)
      net.Start("claude.chat")
      net.WriteString(msg)
      net.Broadcast()
    end

    FindMetaTable("Player").ChatPrint = function(ply, msg)
      net.Start("claude.chat")
      net.WriteString(msg)
      net.Send(ply)
    end

    FindMetaTable("Player").SetUserGroup = function(ply, group)
      -- noop to prevent Claude from breaking if it tries to change user groups
      naughty(ply)
    end

    FindMetaTable("Player").SetNWString = function(ply, key, value)
      -- noop to prevent errors if Claude tries to use SetNWString, which it might do if it was trained on older Lua code
      if key == "UserGroup" then
        naughty(ply)
      end
    end

    local function safeCompile(code, ident, handleError)
      local func, err = CompileString(code, promptId, false)
      if not func and handleError then
        error("[gm-claude] Error compiling dynamic Lua code: " .. err)
      elseif not func then
        return err
      end

      setfenv(func, env)
      return func
    end

    env.CompileString = safeCompile
    env.RunString = function(...)
      local func = safeCompile(...)
      return func()
    end
    env.RunStringEx = env.RunString

    local function tagAsClaude(orig, table, name)
      table.IsClaude = true
      table.Author = "GILB PROMPTS"
      return orig(table, name)
    end

    local oldWeaponsRegister = weapons.Register
    env.weapons = table.Copy(weapons)
    env.weapons.Register = function(tbl, name)
      return tagAsClaude(oldWeaponsRegister, tbl, name)
    end

    local oldScriptedEntsRegister = scripted_ents.Register
    env.scripted_ents = table.Copy(scripted_ents)
    env.scripted_ents.Register = function(tbl, name)
      return tagAsClaude(oldScriptedEntsRegister, tbl, name)
    end

    env.RunClientLua = function(luaCode)
      net.Start("claude.runlua")
      net.WriteString(luaCode)
      net.Broadcast()

      table.insert(ALL_CLIENT_LUA, luaCode)
    end

    env.RunSharedLua = function(luaCode)
      luaCode = luaCode:gsub("SWEP = {}", "SWEP = {Primary = {}, Secondary = {}}") -- make sure these tables exist for SWEP code
      -- Allows Claude to write SWEP code and have it be shared between the server and clients
      -- This is a bit hacky, but it works.
      local func = safeCompile(luaCode, promptId, true)
      if func then
        env.ENT = {}
        env.SWEP = {Primary = {}, Secondary = {}} -- make sure these tables exist for SWEP code
        func()
        env.ENT = nil
        env.SWEP = nil
      end

      env.RunClientLua(luaCode)
    end

    return env
  end,

  --- Runs Claude-made code safely
  --- @param code string Lua code to run
  run = function(self, code, promptId)
    local isSafe = analyze(code)
    if not isSafe then
      return false
    end

    local func, err = CompileString(code, promptId, false)
    if not func then
      print("[gm-claude] Error compiling Lua code: " .. err)
      return false
    end

    if type(func) == "string" then
      print("[gm-claude] Error compiling Lua code: " .. func)
      return false, func
    end

    setfenv(func, self:initializeEnv(promptId))

    local success, execErr = pcall(func)
    if not success then
      print("[gm-claude] Error executing Lua code: " .. execErr)
      return false
    end

    return true
  end,

  removeClientHooks = function(self)
    net.Start("claude.runlua")
    net.WriteString([[
      RemoveClientClaudeHooks()
    ]])
    net.Broadcast()
  end
}