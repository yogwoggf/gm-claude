-- A tiny, cheap reviewer. After a coding agent has built and run its Lua, this
-- agent audits ONLY the GMod/Lua API usage of what it ran and reports a PASS/FAIL
-- verdict back up to the planner, which can then dispatch a corrective pass.
-- It has no power to change the game: its only tool is search_wiki (read-only),
-- so it can confirm real API signatures instead of guessing.

---@module "lua.claude.agents.agent"
local Agent = include("claude/agents/agent.lua")
---@module "lua.claude.wiki.tool"
local wikiTool = include("claude/wiki/tool.lua")
---@module "lua.claude.prompts.reviewer-system-prompt"
local reviewerPrompt = include("claude/prompts/reviewer-system-prompt.lua")

local REVIEWER_MODEL = "openai/gpt-oss-20b:nitro" -- small + cheap; provider forced to groq in agent.lua
local REVIEWER_REASONING = "low" -- a little reasoning helps spot misuse; keep it cheap
local REVIEWER_MAX_TOOL_CALLS = 6 -- a handful of wiki lookups is plenty

local ReviewerAgent = setmetatable({}, {__index = Agent})
ReviewerAgent.__index = ReviewerAgent

--- @param opts table { api, player, task, successCriteria, chunks }
---   chunks: array of { realm = string, code = string } the coder actually ran
function ReviewerAgent.new(opts)
  local self = setmetatable({}, ReviewerAgent)
  Agent.init(self, {
    api = opts.api,
    model = REVIEWER_MODEL,
    user = opts.player and opts.player:SteamID() or nil,
    maxToolCalls = REVIEWER_MAX_TOOL_CALLS,
    reasoningEffort = REVIEWER_REASONING,
  })

  self.player = opts.player -- so its round-trips also tick the progress bar
  self.task = opts.task or ""
  self.successCriteria = opts.successCriteria or {}
  self.chunks = opts.chunks or {}

  self:addMessage({role = "system", content = {{type = "text", text = reviewerPrompt}}})
  self:addTool(wikiTool) -- search_wiki, its only (read-only) tool
  return self
end

-- Format the coder's task, its success criteria, and the exact Lua it ran into one
-- review request.
local function buildReviewMessage(task, criteria, chunks)
  local parts = {
    "The coding agent was given this task:",
    task,
  }

  if criteria and #criteria > 0 then
    table.insert(parts, "\nIt was expected to meet these observable success criteria:")
    for _, c in ipairs(criteria) do
      table.insert(parts, "- " .. tostring(c))
    end
  end

  table.insert(parts, "\nIt built and ran the following Lua in the live game. Audit the GMod/Lua API usage, and whether the code plausibly meets the criteria above:")
  for _, chunk in ipairs(chunks) do
    table.insert(parts, string.format("\n--- [%s realm] ---\n%s", chunk.realm, chunk.code))
  end
  return table.concat(parts, "\n")
end

function ReviewerAgent:start()
  self:addUser(buildReviewMessage(self.task, self.successCriteria, self.chunks))
  self:send()
end

function ReviewerAgent:onToolLimit()
  self:addSystem("Stop searching now and give your verdict (`VERDICT: PASS` or `VERDICT: FAIL`, with any findings above it).")
end

-- The reviewer's final (no-tool) reply carries the verdict (a plain string, like
-- every agent's content). Parse it into a structured result for the planner: a
-- FAIL surfaces the findings for a fix pass.
function ReviewerAgent:onFinish(content)
  local text = type(content) == "string" and content or tostring(content)

  -- Default to passing on an ambiguous/verdict-less reply, so a mush-mouthed tiny
  -- model can't trap the build in an endless "fix" loop over nothing concrete.
  local failed = string.find(text, "VERDICT:%s*FAIL") ~= nil

  self:finish({
    ok = not failed,
    findings = failed and text or nil,
  })
end

return ReviewerAgent
