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

local CODING_MAX_TOOL_CALLS = 32 -- coders need several run_lua iterations

local CodingAgent = setmetatable({}, {__index = Agent})
CodingAgent.__index = CodingAgent

--- @param opts table { api, player, task, promptId?, editContext? }
function CodingAgent.new(opts)
  local self = setmetatable({}, CodingAgent)
  local cfg = demand:current().coding -- model + reasoning scale with server load
  Agent.init(self, {
    api = opts.api,
    model = cfg.model,
    user = opts.player:SteamID(),
    maxToolCalls = CODING_MAX_TOOL_CALLS,
    reasoningEffort = cfg.reasoning,
    promptId = opts.promptId, -- inherit the planner's creation id so artifacts group together
  })

  self.player = opts.player
  self.task = opts.task
  self.successCriteria = opts.successCriteria -- observable definition of done, from the planner
  self.editContext = opts.editContext -- set when this is an !edit; carries the existing code
  self.ranLua = false
  self.lastError = nil
  self.ranChunks = {} -- { {realm, code}, ... } this coder put live; audited by the reviewer

  -- Lua knowledge base (content blocks for provider-side caching) + the coding
  -- operating contract. RAG is retired: durable SWEP/SENT/realm principles live in
  -- the system prompt, and live API grounding comes from the search_wiki tool.
  self:addMessage({role = "system", content = {{type = "text", text = systemPrompt}}})
  self:addSystem(codingPrompt)

  self:addTools(defaultTools) -- search_files, is_valid_model, is_valid_material
  self:addTool(luaTools.server) -- run_server_lua
  self:addTool(luaTools.client) -- run_client_lua
  self:addTool(luaTools.shared) -- run_shared_lua
  self:addTool(notifyTool)
  self:addTool(wikiTool) -- wiki_search
  return self
end

-- No RAG pre-step: seed the task (and, for an edit, the existing code) and go
-- straight into the loop. The coder grounds its API usage with search_wiki instead
-- of pre-fetched examples.
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

  self:addUser(self.task)
  self:send()
end

function CodingAgent:onToolLimit()
  self:addSystem("You've hit the tool-call limit. Stop calling tools and reply with a one-line summary of what you built and whether it is working.")
end

-- No terminal parsing: package the outcome and hand it back to the planner.
function CodingAgent:onFinish(content)
  self:finish({
    summary = content,
    ranLua = self.ranLua,
    ok = self.ranLua and not self.lastError,
    error = self.lastError,
  })
end

return CodingAgent
