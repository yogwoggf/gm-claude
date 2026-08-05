-- Not too strict of a sandbox, but it should be good enough
-- to prevent any major problems, like dropping SQL tables or reading/writing files.
-- It also includes some helper functions and a custom environment to run the code in.

local naughty = include("claude/runtime/naughty.lua")
local analyze = include("claude/runtime/analysis.lua")
---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua") -- runtime error bus; wrapped callbacks report here
---@module "lua.claude.mock.init"
local mock = include("claude/mock/init.lua") -- records registered SENTs/SWEPs for the exercise pass
---@module "lua.claude.runtime.error-capture"
local capture = include("claude/runtime/error-capture.lua")

local wrapCallback = capture.wrap

capture.setSink(function(promptId, realm, err, detail)
  -- Always surface it in the console, even for unregistered chunks (test envs,
  -- the dev rerun command) where the repair bus will ignore it — an error we've
  -- swallowed must never disappear without a trace.
  print(string.format("[gm-claude] Deferred %s error in %s: %s", realm, promptId, err))
  repair:reportError(promptId, realm, err, detail)
end)

--- A library table proxied so a few functions are overridden while everything else
--- falls through to the real library (hook.Remove, hook.Run, ... stay intact).
local function proxyLib(lib, overrides)
  local p = setmetatable({}, { __index = lib })
  for k, v in pairs(overrides) do p[k] = v end
  return p
end

util.AddNetworkString("claude.runlua")
util.AddNetworkString("claude.requestlua")
util.AddNetworkString("claude.chat")

-- Bounds on captured print output, so a debug loop can't flood the agent's context.
local PRINT_CAPTURE_MAX_LINES = 60
local PRINT_CAPTURE_MAX_LINE = 300

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

-- This client wants to get all the Lua code that Claude has sent to clients so far, so we can run it and make sure our clientside environment is up to date
local function syncClientLua(ply)
  if not IsValid(ply) then return end
  ply:SendLua([[notification.AddProgress("claude", "Syncing Claude Lua code...", 0)]])
  -- cant overwhelm them so one at a time with a small delay
  local delay = 0
  for i, entry in ipairs(ALL_CLIENT_LUA) do
    timer.Simple(delay, function()
      if IsValid(ply) then
        net.Start("claude.runlua")
        net.WriteString(entry.code)
        net.WriteString(entry.promptId or "")
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
end

net.Receive("claude.requestlua", function(len, ply)
  -- Also ensure they have everything mounted!
  for _, id in ipairs(mount.LoadedAddons) do
    mount.ForcePlayerMount(ply, id)
  end

  -- Shaders BEFORE Lua, always. Material() permanently caches the error material
  -- for a name that is not mounted yet, so an effect replayed ahead of its GMA
  -- stays broken for this client until they rejoin.
  local shader = _G.ClaudeShader
  if not shader or not shader.SendAll then
    syncClientLua(ply)
    return
  end

  ply:SendLua([[notification.AddProgress("claude", "Syncing Claude shaders...", 0)]])
  shader.SendAll(ply, function()
    syncClientLua(ply)
  end)
end)

return {
  initializeEnv = function(self, promptId, realm)
    realm = realm or "server"
    local env = {}
    -- Copy all of _G in
    for k, v in pairs(_G) do
      env[k] = v
    end

    -- Proxy the async entry points so every callback the generated code registers
    -- is wrapped: a runtime error inside it (which fires long after this run, when
    -- the game actually triggers it) is caught and routed to the repair bus instead
    -- of dying silently in the console. Everything else on these libraries falls
    -- through untouched.
    env.hook = proxyLib(hook, {
      Add = function(event, name, fn)
        return hook.Add(event, name, wrapCallback(promptId, realm, fn))
      end,
    })
    env.timer = proxyLib(timer, {
      Create = function(name, delay, reps, fn)
        return timer.Create(name, delay, reps, wrapCallback(promptId, realm, fn))
      end,
      Simple = function(delay, fn)
        return timer.Simple(delay, wrapCallback(promptId, realm, fn))
      end,
    })
    env.net = proxyLib(net, {
      Receive = function(name, fn)
        return net.Receive(name, wrapCallback(promptId, realm, fn))
      end,
    })

    -- Capture print() so the agent can SEE what its code observed, not just whether
    -- it threw. Without this it can execute code but never inspect a trace result, an
    -- entity, or any game state — so it cannot test its own work, and ships builds
    -- whose main path has never been run. Still echoes to the server console.
    env.print = function(...)
      print(...)

      local buffer = self.printBuffer
      if not buffer or #buffer >= PRINT_CAPTURE_MAX_LINES then return end

      local parts = {}
      for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
      end

      local line = table.concat(parts, "\t")
      if #line > PRINT_CAPTURE_MAX_LINE then
        line = string.sub(line, 1, PRINT_CAPTURE_MAX_LINE) .. "...(truncated)"
      end
      buffer[#buffer + 1] = line
    end
    env.Msg = env.print
    env.MsgN = env.print
    env.PrintTable = function(tbl, indent)
      -- Route the stock table dump through the captured print.
      indent = indent or 0
      if not istable(tbl) then env.print(tostring(tbl)) return end
      local pad = string.rep("  ", indent)
      for k, v in pairs(tbl) do
        if istable(v) and indent < 3 then
          env.print(pad .. tostring(k) .. ":")
          env.PrintTable(v, indent + 1)
        else
          env.print(pad .. tostring(k) .. " = " .. tostring(v))
        end
      end
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

    FindMetaTable("Player").IsAdmin = function(ply)
      return true
    end

    FindMetaTable("Player").IsSuperAdmin = function(ply)
      return true
    end

    local function safeCompile(code, ident, handleError)
      local func, err = CompileString(code, promptId, false)
      -- CompileString returns the error string as the first value (truthy) on failure
      if type(func) ~= "function" then
        if handleError then
          error("[gm-claude] Error compiling dynamic Lua code: " .. tostring(func or err))
        end
        return func -- return the error string (or nil)
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

    local function tagAsClaude(orig, tbl, name, kind)
      tbl.IsClaude = true
      tbl.Author = "GILB PROMPTS"
      -- Wrap every method (Think, PrimaryAttack, Initialize, ...) so a deferred
      -- error inside one is caught and attributed, the same as hooks/timers. The
      -- engine calls these with the entity as self; args/returns pass through.
      for k, v in pairs(tbl) do
        if type(v) == "function" then
          tbl[k] = wrapCallback(promptId, realm, v)
        end
      end
      -- Remember it so the mock harness can exercise it after this run.
      mock:record(promptId, kind, name)
      return orig(tbl, name)
    end

    local oldWeaponsRegister = weapons.Register
    env.weapons = table.Copy(weapons)
    env.weapons.Register = function(tbl, name)
      return tagAsClaude(oldWeaponsRegister, tbl, name, "swep")
    end

    local oldScriptedEntsRegister = scripted_ents.Register
    env.scripted_ents = table.Copy(scripted_ents)
    env.scripted_ents.Register = function(tbl, name)
      return tagAsClaude(oldScriptedEntsRegister, tbl, name, "sent")
    end

    env.RunClientLua = function(luaCode)
      self:broadcastClientLua(luaCode, promptId)
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

  --- Ships client Lua to every connected client, and records it so late-joiners
  --- receive it too (via the sync in the claude.requestlua handler). The promptId
  --- rides along as the client-side chunk name, so a clientside runtime error can be
  --- attributed back to this creation and siphoned to the server.
  broadcastClientLua = function(self, code, promptId)
    print(code)
    net.Start("claude.runlua")
    net.WriteString(code)
    net.WriteString(promptId or "")
    net.Broadcast()
    table.insert(ALL_CLIENT_LUA, { code = code, promptId = promptId })
  end,

  --- Runs Claude-made code safely in a given realm.
  --- @param code string Lua code to run
  --- @param promptId string Chunk name, used for error attribution
  --- @param realm string|nil "server" (default), "client", or "shared"
  --- @return boolean success, string|nil error, string|nil printed output from the run
  run = function(self, code, promptId, realm)
    realm = realm or "server"

    local isSafe = analyze(code)
    if not isSafe then
      return false, "Code was rejected by the safety analysis."
    end

    -- Client-only: nothing executes on the server, just broadcast to clients.
    if realm == "client" then
      self:broadcastClientLua(code, promptId)
      return true
    end

    -- Server and shared both execute on the server. Shared code additionally
    -- defines a SWEP/SENT, so scaffold those tables the way RunSharedLua did.
    local prepared = code
    local env = self:initializeEnv(promptId, realm)
    if realm == "shared" then
      prepared = prepared:gsub("SWEP = {}", "SWEP = {Primary = {}, Secondary = {}}")
      env.ENT = {}
      env.SWEP = {Primary = {}, Secondary = {}}
    end

    -- CompileString returns the error string (truthy) on failure, not a function.
    local func = CompileString(prepared, promptId, false)
    if type(func) ~= "function" then
      print("[gm-claude] Error compiling Lua code: " .. tostring(func))
      return false, func
    end

    setfenv(func, env)

    -- Collect anything the code prints during this synchronous run, so the result
    -- can carry it back to the agent. Deferred prints (timers, hooks) land after the
    -- tool has already returned, so env.print guards on this being set.
    self.printBuffer = {}
    local success, execErr = pcall(func)
    local printed = table.concat(self.printBuffer, "\n")
    self.printBuffer = nil

    if not success then
      print("[gm-claude] Error executing Lua code: " .. tostring(execErr))
      return false, execErr, printed
    end

    -- Shared: only after a clean server run do we broadcast the same code to
    -- clients, so both realms come from one atomic call and clients never see
    -- code that already errored on the server.
    if realm == "shared" then
      self:broadcastClientLua(prepared, promptId)
    end

    return true, nil, printed
  end,

  removeClientHooks = function(self)
    -- Routed through broadcastClientLua so the runlua protocol (code + promptId)
    -- stays consistent; this housekeeping call carries no promptId.
    self:broadcastClientLua("RemoveClientClaudeHooks()", "")
  end,

  setupDevCmd = function(self)
    -- Dev command to re-run an arbitrary prompt (prompt-lua/<id>.txt) in the real environment for testing.
    concommand.Add("claude_rerun_prompt", function(ply, cmd, args)
      if not args[1] then
        print("Please provide a prompt ID to re-run. Usage: claude_rerun_prompt <prompt_id>")
        return
      end

      if not args[2] then
        print("Please provide a player ID to send client Lua to. Usage: claude_rerun_prompt <prompt_id> <player_id>")
        return
      end

      local promptId = args[1]
      local playerId = args[2]
      local filePath = string.format("prompt-lua/%s.txt", promptId)
      if not file.Exists(filePath, "DATA") then
        print("No Lua code found for prompt ID: " .. promptId)
        return
      end

      local luaCode = file.Read(filePath, "DATA")
      luaCode = luaCode:gsub("{{ID}}", playerId) -- replace any {{ID}} placeholders with the actual player ID
      print("Re-running Lua code for prompt ID: " .. promptId)
      print(luaCode)
      self:run(luaCode, promptId)
    end)
  end
}