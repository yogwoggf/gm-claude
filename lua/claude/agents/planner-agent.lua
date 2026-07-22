-- The big-boss planner (deepseek-v4-pro). It takes the player's request, breaks it
-- into independent coding tasks, and dispatches a variable number of coding agents
-- in parallel to build them. It does not write Lua itself; each coding agent grounds
-- its own API usage with the search_wiki tool (RAG has been retired).

---@module "lua.claude.agents.agent"
local Agent = include("claude/agents/agent.lua")
---@module "lua.claude.agents.coding-agent"
local CodingAgent = include("claude/agents/coding-agent.lua")
---@module "lua.claude.agents.reviewer-agent"
local ReviewerAgent = include("claude/agents/reviewer-agent.lua")
---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")
---@module "lua.claude.tools.lua-tools"
local luaTools = include("claude/tools/lua-tools.lua")
---@module "lua.claude.tools.notify-tool"
local notifyTool = include("claude/tools/notify-tool.lua")
---@module "lua.claude.tools.clarify-tool"
local clarifyTool = include("claude/tools/clarify-tool.lua")
---@module "lua.claude.prompts.planner-system-prompt"
local plannerPrompt = include("claude/prompts/planner-system-prompt.lua")
---@module "lua.claude.prompts.edit-context"
local buildEditContext = include("claude/prompts/edit-context.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")
---@module "lua.claude.services.demand"
local demand = include("claude/services/demand.lua")

local DISPATCH_TIMEOUT = 300 -- coding agents make several LLM round trips; give them room
-- Hard cap on how many dispatch rounds get an automatic review. Round 1 is the
-- initial build; each reviewed round can trigger one corrective fix, so this value
-- is effectively the max number of fixes (2 → at most 2 fix passes; the final fix
-- runs unreviewed). Past the cap the reviewer stops running so a flip-flopping
-- verifier ("it's X" → "no, Y" → "actually V") can't loop the build forever.
local MAX_REVIEWED_ROUNDS = 2

-- Spawns one coding agent per task, runs them in parallel, and (asynchronously)
-- resolves once every one has finished, returning their outcomes to the planner.
local dispatchTool = Tool.new({
  name = "dispatch_coding_agents",
  timeout = DISPATCH_TIMEOUT,
  description = "Spawn one coding agent per independent deliverable and run them in parallel; each executes GMod Lua to build its part. Most requests need exactly ONE agent — only use several for genuinely separate deliverables (e.g. a SWEP AND a separate SENT). The coding agent sees ONLY the task you give it — NOT the player's prompt — and grounds its own API usage with a wiki-search tool, so you don't supply code patterns; just describe the deliverable clearly and completely. Each agent's built code is then audited by a reviewer for GMod/Lua API misuse AND for whether it plausibly meets the success criteria you set. Returns each agent's outcome, including a `review` field ({ok, findings}) — re-dispatch a corrected task when an agent failed (ok=false) OR its review flagged problems (review.ok=false).",
  parameters = {
    type = "object",
    properties = {
      agents = {
        type = "array",
        description = "One entry per independent coding task.",
        items = {
          type = "object",
          properties = {
            task = {
              type = "string",
              description = "Complete, self-contained instructions for this coding agent: exactly what to build, how it behaves, and the realm(s) involved. Describe it clearly and completely — it's all the coder gets."
            },
            successCriteria = {
              type = "array",
              items = {type = "string"},
              description = "2-4 concrete, OBSERVABLE outcomes that mean this task succeeded — what a player would see or what game state would hold after it runs. Each must be a checkable statement, e.g. 'Firing the weapon raises the hit entity's gravity', 'A red ammo counter shows at the top-right of the screen', 'The spawned crate falls and rests on the ground'. NO vague or aesthetic criteria ('looks cool', 'is fun'). These become the coder's definition of done and what the reviewer checks the code against, so make them precise and complete."
            }
          },
          required = {"task", "successCriteria"}
        }
      }
    },
    required = {"agents"}
  },
  run = function(args, done, planner)
    local tasks = args.agents or {}
    if #tasks == 0 then
      done({error = "Provide at least one agent with a task."})
      return
    end

    print(string.format("[gm-claude] Planner %s dispatching %d coding agent(s)", planner.id, #tasks))

    -- A re-dispatch (2nd+ call for this planner) is a corrective pass: hand its
    -- coders the code that's already live under this promptId, framed as an edit,
    -- so a fix builds ON the existing script instead of from scratch. The first
    -- dispatch is fresh — its parallel coders are peers and must NOT see each
    -- other's code, so we gate on the call count, not on history having content.
    planner.dispatchRound = (planner.dispatchRound or 0) + 1
    local isRedispatch = planner.dispatchRound > 1
    -- Stop reviewing once the fix budget is spent; a FAIL now would only trigger a
    -- fix beyond the cap. Without a review verdict the planner has nothing to loop on.
    local reviewEnabled = planner.dispatchRound <= MAX_REVIEWED_ROUNDS
    local fixContext = isRedispatch and history:snapshot(planner.promptId) or nil
    if fixContext then
      -- The fix coder re-runs the whole (edited) script, so clear the old record
      -- first — it re-records cleanly instead of stacking duplicates. snapshot()
      -- above already captured the current code for its context.
      history:reset(planner.promptId)
    end

    local results = {}
    local remaining = #tasks
    local allDispatched = false

    local function check()
      if remaining > 0 or not allDispatched then return end
      done({agents = results})
    end

    local function finalize(i, outcome)
      results[i] = outcome
      remaining = remaining - 1
      check()
    end

    for i, spec in ipairs(tasks) do
      local coder = CodingAgent.new({
        api = planner.api,
        player = planner.player,
        task = spec.task or "",
        successCriteria = spec.successCriteria, -- observable definition of done; guides the build
        promptId = planner.promptId,     -- group the coder's artifacts under this creation
        -- On a corrective re-dispatch, the live code so far; else the !edit context
        -- (nil for a fresh first build). Either way the coder edits rather than rebuilds.
        editContext = fixContext or planner.editContext,
      })

      planner.api:launchAgent(coder, function(result)
        local outcome = {
          agent = i,
          ok = result.ok,
          ranLua = result.ranLua,
          error = result.error,
          summary = result.summary,
        }

        -- Only audit code that actually went live cleanly. A coder that errored or
        -- ran nothing is already its own signal — no reviewer needed, and the
        -- reviewer has nothing correct to check. Also skip once the fix budget is
        -- spent, so a flip-flopping verifier can't keep the build looping.
        if not result.ok or #coder.ranChunks == 0 or not reviewEnabled then
          finalize(i, outcome)
          return
        end

        local reviewer = ReviewerAgent.new({
          api = planner.api,
          player = planner.player,
          task = spec.task or "",
          successCriteria = spec.successCriteria, -- reviewer checks the code plausibly meets these
          chunks = coder.ranChunks,
        })

        planner.api:launchAgent(reviewer, function(review)
          outcome.review = {ok = review.ok, findings = review.findings}
          finalize(i, outcome)
        end)
      end)
    end

    allDispatched = true
    check()
  end
})

local PlannerAgent = setmetatable({}, {__index = Agent})
PlannerAgent.__index = PlannerAgent

--- @param opts table { api, player, prompt, promptId?, editContext? }
function PlannerAgent.new(opts)
  local self = setmetatable({}, PlannerAgent)
  local cfg = demand:current().planner -- model + reasoning scale with server load
  Agent.init(self, {
    api = opts.api,
    model = cfg.model,
    user = opts.player:SteamID(),
    reasoningEffort = cfg.reasoning,
    promptId = opts.promptId, -- reused across an !edit so the rebuild overwrites the original
  })

  self.player = opts.player
  self.prompt = opts.prompt
  self.editContext = opts.editContext -- set when this request is an !edit of an existing creation

  self:addTool(dispatchTool)
  -- realm tools, for highly trivial tasks the planner handles itself
  self:addTool(luaTools.server)
  self:addTool(luaTools.client)
  self:addTool(luaTools.shared)
  self:addTool(notifyTool)
  self:addTool(clarifyTool) -- ask the player before dispatching when the request is ambiguous
  return self
end

-- No RAG pre-step anymore — the planner reasons straight from the request and
-- hands off to the inherited tool loop (uses base Agent:onEvent for responses).
function PlannerAgent:start()
  print("[gm-claude] Planner starting for prompt: " .. self.prompt)

  self:addMessage({role = "system", content = {{type = "text", text = plannerPrompt}}})

  -- On an !edit, show the planner the existing code so it can scope the change and
  -- brief its coders precisely (they also receive it directly, via editContext).
  if self.editContext then
    self:addSystem(buildEditContext(self.editContext))
  end

  self:addUser(self.api:formatPlayerPrompt(self.player, self.prompt))
  self:send()
end

return PlannerAgent
