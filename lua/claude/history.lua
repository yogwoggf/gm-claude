-- Per-player history of recent creations, so a player can !edit them later.

if _G.GilbHistory then return _G.GilbHistory end

local MAX_RECENT = 5 -- editable creations kept per player

local History = {}
History.__index = History

local active = {} -- [promptId] = record currently being built
local recent = {} -- [steamid]  = array of finished records, newest first

--- Start (or, for an edit, restart) recording a prompt's artifacts.
function History:begin(player, promptId, promptText)
  active[promptId] = {
    promptId = promptId,
    steamid = player:SteamID(),
    prompt = promptText,
    time = os.time(),
    artifacts = {}, -- { {realm = "shared", code = "..."}, ... }
  }
end

--- Record one Lua chunk an agent successfully ran under this promptId.
function History:record(promptId, realm, code)
  local rec = active[promptId]
  if not rec then return end
  table.insert(rec.artifacts, {realm = realm, code = code})
end

--- The artifacts that represent this record's current script — its own if it has
--- any, else the fallback stashed by a reset (so a fix pass that recorded nothing
--- doesn't erase the last-known-good version).
local function effectiveArtifacts(rec)
  if #rec.artifacts > 0 then return rec.artifacts end
  return rec.fallback or rec.artifacts
end

--- A snapshot of what an in-progress prompt has put live so far, shaped as an
--- editContext ({originalPrompt, artifacts}). Used to hand a re-dispatched fix
--- coder the current script so it edits in place instead of rebuilding blind.
--- Returns nil when nothing has been recorded yet (a first, fresh dispatch).
function History:snapshot(promptId)
  local rec = active[promptId]
  if not rec then return nil end

  local source = effectiveArtifacts(rec)
  if #source == 0 then return nil end

  local artifacts = {}
  for i, art in ipairs(source) do
    artifacts[i] = {realm = art.realm, code = art.code}
  end
  return {originalPrompt = rec.prompt, artifacts = artifacts}
end

--- Clear a prompt's recorded artifacts ahead of a corrective re-dispatch, whose
--- coder re-runs the COMPLETE script and would otherwise append duplicate/stale
--- pieces alongside the originals. The pre-reset set is stashed as a fallback:
--- if the fix pass records nothing (it errored out), finish/snapshot fall back to
--- it so the working original survives in the editable history. Snapshot the code
--- for the fix coder's context BEFORE calling this.
function History:reset(promptId)
  local rec = active[promptId]
  if not rec then return end
  if #rec.artifacts > 0 then
    rec.fallback = rec.artifacts -- last-known-good, restored on an empty fix pass
  end
  rec.artifacts = {}
end

--- Finalize a prompt: push it to the front of its player's recent list, deduping
--- by promptId so an edit replaces the original entry instead of duplicating it.
--- Prompts that produced no Lua (pure chat, or a wholly failed build) aren't kept.
function History:finish(promptId)
  local rec = active[promptId]
  active[promptId] = nil
  if not rec then return end

  -- Settle on the effective set (falls back to pre-reset code if a fix recorded
  -- nothing) so the stored record carries exactly the live script, no duplicates.
  rec.artifacts = effectiveArtifacts(rec)
  rec.fallback = nil
  if #rec.artifacts == 0 then return end

  local list = recent[rec.steamid] or {}
  for i = #list, 1, -1 do
    if list[i].promptId == promptId then
      table.remove(list, i)
    end
  end
  table.insert(list, 1, rec)
  while #list > MAX_RECENT do
    table.remove(list)
  end
  recent[rec.steamid] = list

  self:persist(rec)
end

--- Best-effort disk trail of the produced Lua (keeps the prompt-lua/<id>.txt dev
--- tooling fed). Not read back for editing — the recent list lives in memory.
function History:persist(rec)
  local parts = {}
  for _, art in ipairs(rec.artifacts) do
    table.insert(parts, string.format("-- [%s]\n%s", art.realm, art.code))
  end
  file.CreateDir("prompt-lua")
  file.Write("prompt-lua/" .. rec.promptId .. ".txt", table.concat(parts, "\n\n"))
end

--- The player's recent creations, newest first (array; may be empty).
function History:list(player)
  return recent[player:SteamID()] or {}
end

--- The player's Nth recent creation (1 = newest), or nil.
function History:get(player, index)
  local list = recent[player:SteamID()]
  if not list then return nil end
  return list[index]
end

_G.GilbHistory = History
return History
