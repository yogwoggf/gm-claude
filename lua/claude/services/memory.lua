-- Lessons learned from our own failures.
-- Lexical retrieval on identifiers. Reactive
-- tier rides the error result: no round trip.

if _G.GilbMemory then return _G.GilbMemory end

local STORE_DIR = "gm-claude"
local STORE_FILE = "gm-claude/memory.json"

local MAX_MEMORIES = 400

local REACTIVE_TOP_K = 3
local REACTIVE_BLOCK_MAX = 1000

-- On every prompt of its kind: cap tight.
local PROMOTED_BLOCK_MAX = 1500
local PROMOTED_MAX_ENTRIES = 10

-- Pre-gen. Wiki addresses beat request prose.
local PROACTIVE_TOP_K = 3
local ANCHOR_STRONG = 2
local ANCHOR_WEAK = 1
local PROACTIVE_MIN_RELEVANCE = 2

-- Demote fast, delete slow (noisy evidence).
local WIN_POINTS = 1
local LOSS_POINTS = -2
local PROMOTE_AT = 3
local FORGET_AT = -6

-- Pre-gen causality is loose: weak, symmetric.
local PROACTIVE_WIN = 0.5
local PROACTIVE_LOSS = -0.5

local MIN_TERM_LEN = 4
local MIN_TOPIC_LEN = 3 -- "car", "npc" must survive
local MAX_TRIGGERS = 8
local MAX_TOPICS = 6
local MAX_LESSON_CHARS = 400
local ERROR_SIG_MAX = 200

-- In every Lua error: no signal.
local STOPWORDS = {}
for word in string.gmatch([[
  local function then else elseif end true false nil return break while repeat until
  self this that with from into have here there over when what which some none
  attempt index call field method upcast concat compare arithmetic value values
  string number table boolean userdata thread nan inf error errors stack traceback
  unknown expected got near line file chunk unexpected symbol close variable
  global globals argument arguments param params bad type types cannot could
  print pairs ipairs tostring tonumber format insert remove sort math util
  code lua gmod server client shared realm hook timer entity entities player
  name names text data test tests thing things does doing done make made
]], "%a+") do
  STOPWORDS[word] = true
end

local Memory = {}
Memory.__index = Memory

local entries = {}
local byId = {}
local promotedCache = {} -- kind -> {block, mems} or false
local dirty = false

-- Scores go fractional on the proactive tier.
local function fmtScore(n)
  return string.format(n % 1 == 0 and "%d" or "%.1f", n)
end

--- Log which memories went into a prompt, and why.
local function logUse(tier, list, relevance)
  if not list or #list == 0 then return end
  print(string.format("[gm-claude] Memory injected (%s, %d):", tier, #list))
  for i, mem in ipairs(list) do
    print(string.format("  %s [%s] score=%s w%d/l%d%s :: %s",
      mem.id, mem.source or "?", fmtScore(mem.score), mem.wins, mem.losses,
      relevance and string.format(" rel=%.2f", relevance[i] or 0) or "",
      mem.lesson))
  end
end

--------------------------------------------------------------------------------
-- Text -> terms
--------------------------------------------------------------------------------

--- Discriminative identifiers, as a set.
local function extractTerms(text, out, minLen)
  out = out or {}
  minLen = minLen or MIN_TERM_LEN
  for word in string.gmatch(string.lower(tostring(text or "")), "[%a_][%w_]*") do
    if #word >= minLen and not STOPWORDS[word] then
      out[word] = true
    end
  end
  return out
end

--- Raw strings -> tokens retrieval matches on.
-- Must match extractTerms or dotted names die
local function normalizeAnchors(list, minLen, max)
  local seen, out = {}, {}
  if isstring(list) then list = {list} end -- models emit bare strings
  if not istable(list) then return out end
  for _, raw in ipairs(list) do
    for word in string.gmatch(string.lower(tostring(raw)), "[%a_][%w_]*") do
      if #word >= minLen and not STOPWORDS[word] and not seen[word] then
        seen[word] = true
        out[#out + 1] = word
      end
    end
    if #out >= max then break end
  end
  while #out > max do table.remove(out) end
  return out
end

-- Triggers: API symbols, matched on errors.
local function normalizeTriggers(list)
  return normalizeAnchors(list, MIN_TERM_LEN, MAX_TRIGGERS)
end

-- Topics: plain words, matched before code.
local function normalizeTopics(list)
  return normalizeAnchors(list, MIN_TOPIC_LEN, MAX_TOPICS)
end

--- Stable key for "this same error".
-- Digits go: promptId + lines both move.
local function errorSignature(err)
  local s = string.lower(tostring(err or ""))
  s = string.gsub(s, "%d+", "#")
  s = string.gsub(s, "%s+", " ")
  s = string.Trim(s)
  if #s > ERROR_SIG_MAX then s = string.sub(s, 1, ERROR_SIG_MAX) end
  return s
end

--------------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------------

--- Load. A corrupt store starts empty.
function Memory:load()
  entries, byId, promotedCache = {}, {}, {}

  local raw = file.Read(STORE_FILE, "DATA")
  if not raw or raw == "" then return end

  local decoded = util.JSONToTable(raw)
  if not istable(decoded) then
    print("[gm-claude] Memory store is corrupt, starting empty")
    return
  end

  for _, mem in ipairs(decoded) do
    if isstring(mem.id) and isstring(mem.lesson) and istable(mem.triggers) then
      -- Backfill: the store is hand-editable JSON.
      mem.score = tonumber(mem.score) or 0
      mem.wins = tonumber(mem.wins) or 0
      mem.losses = tonumber(mem.losses) or 0
      mem.kind = isstring(mem.kind) and mem.kind or "*"
      mem.promoted = mem.promoted == true
      -- No source on disk = someone hand-wrote it.
      mem.source = isstring(mem.source) and mem.source or "seeded"
      mem.triggers = normalizeTriggers(mem.triggers)
      mem.topics = normalizeTopics(mem.topics) -- absent on older entries
      if #mem.triggers > 0 then
        entries[#entries + 1] = mem
        byId[mem.id] = mem
      end
    end
  end
  print(string.format("[gm-claude] Loaded %d memories", #entries))
end

function Memory:save()
  if not dirty then return end
  dirty = false
  file.CreateDir(STORE_DIR)
  file.Write(STORE_FILE, util.TableToJSON(entries))
end

-- Debounced: rewards come in bursts.
local function markDirty()
  if dirty then return end
  dirty = true
  timer.Simple(5, function() Memory:save() end)
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

--- Trim. Promoted ones are protected.
local function evict()
  if #entries <= MAX_MEMORIES then return end
  table.sort(entries, function(a, b)
    if a.promoted ~= b.promoted then return a.promoted end
    if a.score ~= b.score then return a.score > b.score end
    return (a.created or 0) > (b.created or 0)
  end)
  for i = #entries, MAX_MEMORIES + 1, -1 do
    byId[entries[i].id] = nil
    entries[i] = nil
  end
end

--- Add a candidate, deduped sig+triggers.
--- @param entry table { kind?, triggers, topics?, lesson, errorSig? }
function Memory:add(entry)
  local lesson = string.Trim(tostring(entry.lesson or ""))
  if lesson == "" then return nil end
  if #lesson > MAX_LESSON_CHARS then lesson = string.sub(lesson, 1, MAX_LESSON_CHARS) end

  -- No anchors = never retrievable.
  local triggers = normalizeTriggers(entry.triggers)
  if #triggers == 0 then return nil end

  local sig = entry.errorSig and errorSignature(entry.errorSig) or nil
  local key = (sig or "") .. "|" .. table.concat(triggers, ",")

  for _, mem in ipairs(entries) do
    if mem.dedupeKey == key then
      mem.seenCount = (mem.seenCount or 1) + 1
      markDirty()
      print(string.format("[gm-claude] Memory %s re-observed (%dx), not duplicated: %s",
        mem.id, mem.seenCount, mem.lesson))
      return mem
    end
  end

  local mem = {
    id = "m" .. tostring(os.time()) .. tostring(math.random(1000, 9999)),
    kind = entry.kind or "*",
    triggers = triggers,
    topics = normalizeTopics(entry.topics),
    lesson = lesson,
    errorSig = sig,
    dedupeKey = key,
    source = entry.source or "manual",
    score = 0,
    wins = 0,
    losses = 0,
    seenCount = 1,
    promoted = false,
    created = os.time(),
  }
  entries[#entries + 1] = mem
  byId[mem.id] = mem
  evict()
  markDirty()
  print(string.format("[gm-claude] Memory %s ADDED via %s (kind=%s): %s",
    mem.id, mem.source, mem.kind, lesson))
  print(string.format("  triggers: %s", table.concat(triggers, ", ")))
  if #mem.topics > 0 then print(string.format("  topics: %s", table.concat(mem.topics, ", "))) end
  if sig then print(string.format("  from error: %s", sig)) end
  return mem
end

--- Score once the run resolved.
--- @param tier string|nil "proactive" scores at half, both ways
function Memory:reward(ids, ok, tier)
  if not ids or #ids == 0 then return end
  local proactive = tier == "proactive"

  for _, id in ipairs(ids) do
    local mem = byId[id]
    if mem then
      if ok then
        mem.wins = mem.wins + 1
        mem.score = mem.score + (proactive and PROACTIVE_WIN or WIN_POINTS)
      else
        mem.losses = mem.losses + 1
        mem.score = mem.score + (proactive and PROACTIVE_LOSS or LOSS_POINTS)
      end

      print(string.format("[gm-claude] Memory %s %s (%s) -> score=%s (w%d/l%d)",
        mem.id, ok and "WIN" or "LOSS", tier or "reactive",
        fmtScore(mem.score), mem.wins, mem.losses))

      if mem.score <= FORGET_AT then
        self:forget(mem.id)
      elseif not mem.promoted and mem.score >= PROMOTE_AT then
        mem.promoted = true
        promotedCache = {}
        print(string.format("[gm-claude] Promoted memory %s to the always-on %s block", mem.id, mem.kind))
      elseif mem.promoted and mem.score < PROMOTE_AT then
        -- Promotion is not a ratchet.
        mem.promoted = false
        promotedCache = {}
        print(string.format("[gm-claude] Demoted memory %s back to candidate (score %s)", mem.id, fmtScore(mem.score)))
      end
    end
  end
  markDirty()
end

function Memory:forget(id)
  local mem = byId[id]
  if not mem then return end
  byId[id] = nil
  for i = #entries, 1, -1 do
    if entries[i].id == id then table.remove(entries, i) end
  end
  if mem.promoted then promotedCache = {} end
  markDirty()
  print(string.format("[gm-claude] Forgot memory %s (score %s): %s", id, fmtScore(mem.score), mem.lesson))
end

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

local function kindMatches(mem, kind)
  return mem.kind == "*" or kind == nil or mem.kind == kind
end

--- Render a capped block. Also returns what fit,
-- so logs match what the model actually saw.
local function render(header, list, maxChars)
  local lines, used = {header}, {}
  local total = #header
  for _, mem in ipairs(list) do
    local line = "- " .. mem.lesson
    if total + #line + 1 > maxChars then break end
    total = total + #line + 1
    lines[#lines + 1] = line
    used[#used + 1] = mem
  end
  if #used == 0 then return nil, used end
  return table.concat(lines, "\n"), used
end

--- Lessons for a failure, best first.
function Memory:forError(kind, errorText, code)
  -- Error hits beat hits buried in code.
  local errorTerms = extractTerms(errorText)
  local codeTerms = extractTerms(code)
  local sig = errorSignature(errorText)

  local scored = {}
  for _, mem in ipairs(entries) do
    if kindMatches(mem, kind) then
      local errorHits, codeHits = 0, 0
      for _, t in ipairs(mem.triggers) do
        if errorTerms[t] then
          errorHits = errorHits + 1
        elseif codeTerms[t] then
          codeHits = codeHits + 1
        end
      end

      -- Exact repeat of a solved failure wins.
      local sigMatch = mem.errorSig ~= nil and mem.errorSig == sig
      if errorHits > 0 or codeHits > 0 or sigMatch then
        scored[#scored + 1] = {
          mem = mem,
          relevance = errorHits * 2 + codeHits + (sigMatch and 10 or 0)
            + math.Clamp(mem.score, -2, 2) * 0.25,
        }
      end
    end
  end

  table.sort(scored, function(a, b) return a.relevance > b.relevance end)

  local out, rel = {}, {}
  for i = 1, math.min(#scored, REACTIVE_TOP_K) do
    out[i] = scored[i].mem
    rel[i] = scored[i].relevance
  end
  return out, rel
end

--- Reactive block + its ids, for scoring.
--- @return string|nil block, table ids
function Memory:blockForError(kind, errorText, code)
  local matches, rel = self:forError(kind, errorText, code)
  if #matches == 0 then return nil, {} end

  local block, used = render(
    "\n\nPreviously learned about failures like this on THIS server (may not all apply — check before acting):",
    matches, REACTIVE_BLOCK_MAX)
  if not block then return nil, {} end

  logUse("reactive", used, rel)

  local ids = {}
  for i, mem in ipairs(used) do ids[i] = mem.id end
  return block, ids
end

--- Always-on block for a kind. Cached.
function Memory:promotedBlock(kind)
  local key = kind or "*"
  local cached = promotedCache[key]

  if cached == nil then
    local list = {}
    for _, mem in ipairs(entries) do
      if mem.promoted and kindMatches(mem, kind) then
        list[#list + 1] = mem
      end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    while #list > PROMOTED_MAX_ENTRIES do table.remove(list) end

    local block, used = render(
      "# Learned API notes\nHard-won corrections from previous builds on this server. These describe real GMod behaviour that has burned us before — follow them:",
      list, PROMOTED_BLOCK_MAX)

    cached = block and {block = block, mems = used} or false
    promotedCache[key] = cached
  end

  if not cached then return nil end
  logUse("promoted/" .. key, cached.mems)
  return cached.block
end

--- Pre-gen recall, for CANDIDATES only (promoted
--- ones are already in the cached prefix).
--- The wiki addresses are the real query: that
--- search is semantic, so a typo'd request still
--- lands on the right symbols. Request prose is
--- the weak fallback.
--- @return string|nil block, table ids
function Memory:blockForRequest(kind, requestText, wikiResults)
  local strong, weak = {}, {}
  for _, r in ipairs(wikiResults or {}) do
    extractTerms(r.address, strong, MIN_TOPIC_LEN)
    extractTerms(r.description, weak, MIN_TOPIC_LEN)
  end
  extractTerms(requestText, weak, MIN_TOPIC_LEN)

  local scored = {}
  for _, mem in ipairs(entries) do
    if not mem.promoted and kindMatches(mem, kind) then
      -- Either vocabulary can anchor a hit.
      local relevance, counted = 0, {}
      for _, set in ipairs({mem.triggers, mem.topics}) do
        for _, t in ipairs(set) do
          if not counted[t] then
            counted[t] = true
            if strong[t] then
              relevance = relevance + ANCHOR_STRONG
            elseif weak[t] then
              relevance = relevance + ANCHOR_WEAK
            end
          end
        end
      end

      -- One strong hit, or two weak ones.
      if relevance >= PROACTIVE_MIN_RELEVANCE then
        scored[#scored + 1] = {
          mem = mem,
          relevance = relevance + math.Clamp(mem.score, -2, 2) * 0.25,
        }
      end
    end
  end
  if #scored == 0 then return nil, {} end

  table.sort(scored, function(a, b) return a.relevance > b.relevance end)

  local matches, rel = {}, {}
  for i = 1, math.min(#scored, PROACTIVE_TOP_K) do
    matches[i] = scored[i].mem
    rel[i] = scored[i].relevance
  end

  local block, used = render(
    "Possibly relevant notes learned from previous builds (unproven — verify before relying on them):",
    matches, REACTIVE_BLOCK_MAX)
  if not block then return nil, {} end

  logUse("proactive", used, rel)

  local ids = {}
  for i, mem in ipairs(used) do ids[i] = mem.id end
  return block, ids
end

--------------------------------------------------------------------------------
-- Introspection
--------------------------------------------------------------------------------

function Memory:all()
  return entries
end

function Memory:stats()
  local promoted = 0
  for _, mem in ipairs(entries) do
    if mem.promoted then promoted = promoted + 1 end
  end
  return {total = #entries, promoted = promoted, candidates = #entries - promoted}
end

Memory:load()

concommand.Add("claude_memory_list", function(ply)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end
  local stats = Memory:stats()
  print(string.format("[gm-claude] %d memories (%d promoted, %d candidates)",
    stats.total, stats.promoted, stats.candidates))
  for _, mem in ipairs(entries) do
    print(string.format("  %s [%s] %s via %s score=%s (w%d/l%d seen%d) %s\n      triggers: %s\n      topics: %s",
      mem.id, mem.promoted and "PROMOTED" or "candidate", mem.kind, mem.source or "?",
      fmtScore(mem.score), mem.wins, mem.losses, mem.seenCount or 1,
      mem.lesson, table.concat(mem.triggers, ", "), table.concat(mem.topics, ", ")))
  end
end, nil, "List every learned memory with its score and anchors.")

concommand.Add("claude_memory_forget", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end
  if not args[1] then
    print("[gm-claude] Usage: claude_memory_forget <memory id>")
    return
  end
  Memory:forget(args[1])
end, nil, "Delete a learned memory by id.")

_G.GilbMemory = Memory
return Memory
