-- Runtime error bus + on-the-fly repair for AI-generated Lua.
if _G.GilbRepair then return _G.GilbRepair end

---@module "lua.claude.history"
local history = include("claude/history.lua")

local repair = {}
repair.prompts = {}      -- [promptId] = { player = Player, repairing = bool, lastRepair = CurTime }
repair.buckets = {}      -- [promptId] = { [errString] = { count = n, realm = str, detail = str } }
repair.interceptors = {} -- [promptId] = fn(realm, err, detail); diverts reports while set
repair.REPAIR_THRESHOLD = 1  -- occurrences of the same error before we try to repair
repair.REPAIR_COOLDOWN = 60  -- min seconds between repair passes for one promptId
repair.api = nil
repair.sandbox = nil

function repair:setInterceptor(promptId, fn)
  self.interceptors[promptId] = fn
end

function repair:initialize(api, sandbox)
  self.api = api
  self.sandbox = sandbox
end

--- Note that a promptId is one of ours (so isAi recognizes its chunk names) and
--- remember which player owns it, so a repair pass can be re-dispatched as them.
function repair:register(promptId, player)
  local p = self.prompts[promptId]
  if p then
    p.player = player -- an edit reuses the id; keep the latest owner
    return
  end
  self.prompts[promptId] = { player = player, repairing = false, lastRepair = -math.huge }
end

--- Whether a chunk name belongs to AI-generated code we're tracking.
function repair:isAi(chunkName)
  return chunkName ~= nil and self.prompts[chunkName] ~= nil
end

--- The single entry point for every runtime error, from any source/realm.
--- @param promptId string chunk name / creation id the error was attributed to
--- @param realm string "server" | "client"
--- @param errString string the raw error message (bucket key)
--- @param detail string|nil richer context (traceback + locals) if the source had it
function repair:reportError(promptId, realm, errString, detail)
  if not self.prompts[promptId] then return end -- unknown / not ours; ignore
  errString = tostring(errString)
  realm = realm or "server"

  -- Diverted to the mock harness (or any other transient collector) if one is active.
  local intercept = self.interceptors[promptId]
  if intercept then
    intercept(realm, errString, detail)
    return
  end

  local b = self.buckets[promptId]
  if not b then b = {}; self.buckets[promptId] = b end
  local entry = b[errString]
  if not entry then entry = { count = 0 }; b[errString] = entry end

  entry.count = entry.count + 1
  entry.realm = realm
  if detail then entry.detail = detail end -- prefer the most detailed report

  print(string.format("[gm-claude] Runtime error (%s) x%d for prompt %s: %s",
    realm, entry.count, promptId, errString))

  if entry.count >= self.REPAIR_THRESHOLD then
    self:tryRepair(promptId, entry)
  end
end

--- The live code for a promptId, shaped as an editContext.
function repair:buildEditContext(promptId, player)
  local snap = history:snapshot(promptId)
  if snap then return snap end

  for _, rec in ipairs(history:list(player)) do
    if rec.promptId == promptId then
      return { originalPrompt = rec.prompt, artifacts = rec.artifacts }
    end
  end
  return nil
end

--- Dispatch a repair pass for a persistently-failing prompt.
function repair:tryRepair(promptId, entry)
  if not self.api then return end
  local p = self.prompts[promptId]
  if not p or p.repairing then return end
  if CurTime() - p.lastRepair < self.REPAIR_COOLDOWN then return end

  local player = p.player
  if not IsValid(player) then
    print("[gm-claude] Skipping repair for " .. promptId .. ": owner is no longer connected.")
    return
  end

  local editContext = self:buildEditContext(promptId, player)
  if not editContext then
    print("[gm-claude] No code on record to repair for prompt " .. promptId)
    return
  end

  p.repairing = true
  p.lastRepair = CurTime()
  print("[gm-claude] Attempting runtime repair for prompt " .. promptId)

  local instruction = string.format(
    "The code you generated for this creation is throwing a runtime error (realm: %s):\n\n%s\n\n" ..
    "This only surfaces when the code actually runs (a hook, SWEP/ENT method, timer, or net callback), " ..
    "so it was NOT caught when you first ran it. Fix the cause and re-run the corrected code, keeping the " ..
    "original behavior. Common culprits: comparing/indexing a nil value, wrong realm, or a bad GMod API assumption.",
    entry.realm or "server", entry.detail or "(no detail captured)")

  self.api:sendPrompt(player, instruction, function()
    p.repairing = false
    self.buckets[promptId] = nil -- start fresh; if the fix held, nothing re-accumulates
    print("[gm-claude] Runtime repair pass finished for prompt " .. promptId)
  end, { promptId = promptId, editContext = editContext })
end

-- Catches any errors that somehow bubbled up to the global error handler.
hook.Add("OnLuaError", "claude.repair", function(err, realm, stack)
  if not istable(stack) then return end
  for _, frame in ipairs(stack) do
    local chunk = frame.File or frame.source or frame.short_src
    if repair:isAi(chunk) then
      repair:reportError(chunk, realm or "server", err)
      return
    end
  end
end)

-- Clientside errors are siphoned back over the network.
util.AddNetworkString("claude.clienterror")
net.Receive("claude.clienterror", function(_, ply)
  local promptId = net.ReadString()
  local err = net.ReadString()
  local detail = net.ReadString()
  if not repair:isAi(promptId) then return end -- ignore spoofed / stale ids
  repair:reportError(promptId, "client", err, detail ~= "" and detail or nil)
end)

_G.GilbRepair = repair
return repair
