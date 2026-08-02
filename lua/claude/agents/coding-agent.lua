-- A nimble coding agent. It receives one self-contained task
-- from the planner and builds it by executing Lua via the run_*_lua realm tools,
-- iterating on any errors it gets back.

---@module "lua.claude.agents.agent"
local Agent = include("claude/agents/agent.lua")

---@module "lua.claude.tools.asset-tools"
local defaultTools = include("claude/tools/asset-tools.lua")
---@module "lua.claude.tools.lua-tools"
local luaTools = include("claude/tools/lua-tools.lua")
---@module "lua.claude.tools.notify-tool"
local notifyTool = include("claude/tools/notify-tool.lua")
---@module "lua.claude.wiki.tool"
local wikiTool = include("claude/wiki/tool.lua")

---@module "lua.claude.prompts.system-prompt"
local systemPrompt = include("claude/prompts/system-prompt.lua")
---@module "lua.claude.prompts.coding-system-prompt"
local codingPrompt = include("claude/prompts/coding-system-prompt.lua")
---@module "lua.claude.prompts.edit-context"
local buildEditContext = include("claude/prompts/edit-context.lua")
---@module "lua.claude.services.demand"
local demand = include("claude/services/demand.lua")
---@module "lua.claude.prompts.playbooks.init"
local playbooks = include("claude/prompts/playbooks/init.lua")
---@module "lua.claude.prompts.asset-palette"
local assetPalette = include("claude/prompts/asset-palette.lua")
---@module "lua.claude.wiki.api"
local wikiApi = include("claude/wiki/api.lua")
---@module "lua.claude.services.memory"
local memory = include("claude/services/memory.lua")
---@module "lua.claude.services.distill"
local distill = include("claude/services/distill.lua")

local CODING_MAX_TOOL_CALLS = 32 -- coders need several run_lua iterations

local CodingAgent = setmetatable({}, {__index = Agent})
CodingAgent.__index = CodingAgent

--- @param opts table { api, player, task, kind?, promptId?, editContext? }
function CodingAgent.new(opts)
  local self = setmetatable({}, CodingAgent)
  local cfg = demand:current().coding -- models + reasoning scale with server load
  Agent.init(self, {
    api = opts.api,
    model = cfg.draft.model, -- the first draft is what decides how many rounds follow
    user = opts.player:SteamID(),
    maxToolCalls = CODING_MAX_TOOL_CALLS,
    reasoningEffort = cfg.draft.reasoning,
    priority = cfg.draft.priority, -- "auto" = unsorted/quality routing for the draft
    temperature = cfg.draft.temperature,
    promptId = opts.promptId, -- inherit the planner's creation id so artifacts group together
  })

  -- Two-tier model use. Writing the thing correctly the first time is the hard,
  -- open-ended part and gets the strong model; fixing a reported error is narrow,
  -- mechanical work a cheap model does fine. Because a good draft collapses several
  -- iteration rounds into none, this is usually CHEAPER than running the cheap model
  -- throughout — every round re-sends the full system prompt and transcript.
  self.fixModel = cfg.fix.model
  self.fixReasoning = cfg.fix.reasoning
  self.fixPriority = cfg.fix.priority -- nil = fall back to the api default (latency)
  self.fixTemperature = cfg.fix.temperature
  self.downgraded = false

  self.player = opts.player
  self.task = opts.task
  self.kind = opts.kind -- which playbook this deliverable needs
  self.oneShot = opts.oneShot -- no planner: task is the player's verbatim request
  self.successCriteria = opts.successCriteria -- observable definition of done, from the planner
  self.editContext = opts.editContext -- set when this is an !edit; carries the existing code
  self.ranLua = false
  self.lastError = nil
  self.ranChunks = {} -- { {realm, code}, ... } this coder put live

  -- Core Lua knowledge (content block, for provider-side caching) + the coding
  -- operating contract + the ONE playbook for this deliverable + the verified
  -- asset palette for that kind. RAG is retired: durable principles live in the
  -- playbooks, known-good assets in the palette, live API grounding in the
  -- pre-fetched wiki results (with search_wiki as the fallback tool).
  -- Everything up to here is byte-stable per kind — keep dynamic content below it
  -- so the provider's prefix cache can cover this block.
  self:addMessage({role = "system", content = {{type = "text", text = systemPrompt}}})
  self:addSystem(codingPrompt)
  self:addSystem(playbooks.get(self.kind))
  self:addSystem(assetPalette.get(self.kind))

  -- PROVEN only, cached: stays prefix-stable.
  local learned = memory:promotedBlock(self.kind)
  if learned then self:addSystem(learned) end

  -- One-shot: there is no planner, so the message below is the PLAYER talking, not a
  -- prepared task. Nobody else will interpret it, fill its gaps, or set its bar — so
  -- the coder does the small amount of planning itself, in this same call rather than
  -- in an extra round-trip.
  if self.oneShot then
    self:addSystem(
      "The request below comes DIRECTLY from the player, in their own words — there is no planner between you and them. " ..
      "It may be short, casual, or leave details unstated. You own the whole thing:\n" ..
      "- Read what they actually asked for, including the flavour of how they said it. Build THAT, not a generic version of it.\n" ..
      "- Fill unstated details with the most fun, obvious interpretation and keep going. Do not ask; do not stall.\n" ..
      "- Before you write code, state 2-4 concrete OBSERVABLE outcomes that will mean this succeeded — what the player will see. " ..
      "Build to them, meet every floor in your playbook, and confirm each one before you finish.\n" ..
      "- Deliver the complete thing in one build. If it needs both a weapon and a visible effect, that is still one deliverable: yours.")
  end

  self:addTools(defaultTools) -- search_files, is_valid_model, is_valid_material
  self:addTool(luaTools.server) -- run_server_lua
  self:addTool(luaTools.client) -- run_client_lua
  self:addTool(luaTools.shared) -- run_shared_lua
  self:addTool(notifyTool)
  self:addTool(wikiTool) -- wiki_search
  return self
end

-- The wiki round used to be mandatory, which cost a full LLM round-trip (a whole
-- context re-send) on every build. Instead, run the semantic search over the task
-- BEFORE the first model call and inject the results — one cheap HTTP fetch in
-- place of an LLM round. search_wiki stays available for follow-up lookups.
local WIKI_PREFETCH_TIMEOUT = 6 -- seconds; the wiki being slow must not stall the build
local WIKI_SIGNATURE_MAX = 900 -- chars per result's markup; signatures can be huge
local WIKI_BLOCK_MAX = 4000 -- chars for the whole injected block

local function formatWikiResults(results)
  local parts = {"Pre-fetched GMod wiki results for this task (semantic search). Ground your API usage in these; call search_wiki only for something they don't cover:"}
  local total = #parts[1]
  for _, r in ipairs(results) do
    local sig = r.signature
    if sig and #sig > WIKI_SIGNATURE_MAX then sig = string.sub(sig, 1, WIKI_SIGNATURE_MAX) .. "..." end
    local entry = string.format("## %s\n%s%s", tostring(r.address), tostring(r.description or ""),
      sig and ("\n" .. sig) or "")
    if total + #entry > WIKI_BLOCK_MAX then break end
    total = total + #entry
    parts[#parts + 1] = entry
  end
  return table.concat(parts, "\n\n")
end

-- Seed the task (and, for an edit, the existing code), pre-fetch wiki grounding,
-- and go into the loop.
function CodingAgent:start()
  -- Editing: hand the coder the exact existing Lua right before its task, so it
  -- modifies in place (overwriting hooks/entities by name) instead of rebuilding.
  if self.editContext then
    self:addSystem(buildEditContext(self.editContext))
  end

  -- The planner's observable definition of done. Giving it to the coder up front
  -- turns "build a thing" into "build a thing that does X, Y, Z", and it self-checks
  -- against these before finishing — catching no-ops and wrong logic, not just crashes.
  if self.successCriteria and #self.successCriteria > 0 then
    local lines = {"This task is only DONE when ALL of these observable outcomes hold. Build toward them, and confirm each one before you finish:"}
    for _, c in ipairs(self.successCriteria) do
      lines[#lines + 1] = "- " .. tostring(c)
    end
    self:addSystem(table.concat(lines, "\n"))
  end

  -- Wiki grounding is async; guard it with a timeout so an unreachable wiki costs
  -- at most WIKI_PREFETCH_TIMEOUT before the build proceeds ungrounded (the coder
  -- still has the search_wiki tool as a fallback).
  local launched = false
  local function launch(results)
    if launched then return end
    launched = true
    if results and #results > 0 then
      self:addSystem(formatWikiResults(results))
    end
    -- Unproven recall; varies, so tail not prefix.
    -- Keyed off the wiki hits: semantic, so a
    -- typo'd request still retrieves.
    local hints, ids = memory:blockForRequest(self.kind, self.task, results)
    if hints then
      self:addSystem(hints)
      self.proactiveMemoryIds = ids
    end

    self:addUser(self.task)
    self:send()
  end

  timer.Simple(WIKI_PREFETCH_TIMEOUT, function()
    if not launched then
      print(string.format("[gm-claude] Coder %s: wiki pre-fetch timed out, starting without grounding", self.id))
      launch(nil)
    end
  end)
  wikiApi.fetchSemanticSearchResults(self.task, launch)
end

--- Called by the Lua tools after this coder's first SUCCESSFUL run (loaded clean
--- and survived the mock exercise). Only then is the draft truly spent — a failed
--- first run means the strong model still owes the real build, and probe snippets
--- run before the build must not burn the draft either. After success, what's left
--- is narrow error-driven iteration the cheap model handles. Idempotent.
function CodingAgent:onDraftComplete()
  if self.downgraded or not self.fixModel then return end
  self.downgraded = true
  self.model = self.fixModel
  self.reasoningEffort = self.fixReasoning
  -- Back to fast routing: fixes are mechanical, and the quality route is slower.
  self.priority = self.fixPriority or self.api.CURRENT_PRIORITY
  self.temperature = self.fixTemperature
  print(string.format("[gm-claude] Coder %s drafted; switching to %s for iteration", self.id, self.fixModel))
end

function CodingAgent:onToolLimit()
  self:addSystem("You've hit the tool-call limit. Stop calling tools and reply with a one-line summary of what you built and whether it is working.")
end

-- No terminal parsing: package the outcome and hand it back to the planner.
function CodingAgent:onFinish(content)
  -- Learn from repairs, off the critical path.
  if self.repairPairs then
    distill.run(self.api, self.kind, self.repairPairs)
  end

  self:finish({
    summary = content,
    ranLua = self.ranLua,
    ok = self.ranLua and not self.lastError,
    error = self.lastError,
  })
end

return CodingAgent
