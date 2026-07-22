-- Base agentic loop. Holds message history, a toolset, and model/priority, and
-- drives the send -> tool-calls -> send / finish cycle. Subclasses customize the
-- pre-steps (start / onEvent) and the terminal step (onFinish).

local j = util.TableToJSON
local jt = util.JSONToTable

-- Force certain providers for certain models based on our benchmarking.
local MODEL_PROVIDER_FORCE = {
  ["openai/gpt-oss-120b:nitro"] = {
    "cerebras", -- Best cache/prices
  },
  ["google/gemini-3-flash-preview:nitro"] = {
    "google-ai-studio",
  },
  ["qwen/qwen3.6-35b-a3b:nitro"] = {
    "parasail"
  },
  ["deepseek/deepseek-v4-flash:nitro"] = {
    "alibaba" -- Better pricing
  }
}

local TOOL_CALL_TIMEOUT = 30 -- seconds before a hung tool call is force-completed so the agent can't stall forever
local MAX_TOOL_CALLS = 5
local ALLOWED_RESPONSE_FIELDS = {"content", "role", "tool_calls", "tool_call_id"}

-- Drives the client progress bar: every LLM round-trip any agent makes for a prompt
-- is one "tick" sent to the requesting player, who advances the bar with diminishing
-- returns. Registered once (this file is include()d by every agent module).
if not _G.__claudeProgressNet then
  util.AddNetworkString("claude.progress")
  _G.__claudeProgressNet = true
end

local Agent = {}
Agent.__index = Agent

--- Initialize an already-allocated instance. Subclasses call this on their own
--- table so inherited fields are set up before they add their own.
--- @param opts table { api, model?, priority?, user?, maxToolCalls?, onFinish? }
function Agent.init(self, opts)
  self.id = tostring(math.random(100000, 9999999))
  -- Stable id for the *creation* this agent contributes to, shared by a planner
  -- and all of its coders (unlike self.id, which is per-agent). Used to attribute
  -- Lua in the sandbox and to group artifacts in history; an edit reuses it so the
  -- rebuilt code overwrites the original in place. Defaults to this agent's own id.
  self.promptId = opts.promptId or self.id
  self.api = opts.api
  self.model = opts.model or opts.api.CURRENT_MODEL
  self.priority = opts.priority or opts.api.CURRENT_PRIORITY
  self.user = opts.user -- steamid string for the API `user` field, optional
  self.messages = {}
  self.tools = {} -- list of Tool objects
  self.toolCallCount = 0
  self.toolCalls = {} -- introspection: { {tool, args, result}, ... }
  self.maxToolCalls = opts.maxToolCalls or MAX_TOOL_CALLS
  self.reasoningEffort = opts.reasoningEffort -- OpenRouter reasoning effort: max|xhigh|high|medium|low|minimal|none, or nil for the server default
  self.onComplete = opts.onComplete -- fun(result, agent); invoked exactly once when done
  self.finished = false
end

function Agent.new(opts)
  local self = setmetatable({}, Agent)
  Agent.init(self, opts)
  return self
end

function Agent:addTool(tool)
  table.insert(self.tools, tool)
end

function Agent:addTools(tools)
  for _, tool in ipairs(tools) do
    self:addTool(tool)
  end
end

function Agent:addMessage(msg)
  table.insert(self.messages, msg)
end

function Agent:addSystem(content)
  self:addMessage({role = "system", content = content})
end

function Agent:addUser(content)
  self:addMessage({role = "user", content = content})
end

--- Kick off the agent. Base assumes messages are already seeded; subclasses that
--- need pre-steps (routing, RAG) override this.
function Agent:start()
  self:send()
end

--- Post the current conversation + toolset to the API under this agent's id.
function Agent:send()
  local wireTools = {}
  for i, tool in ipairs(self.tools) do
    wireTools[i] = tool:toWire()
  end

  self.api:sendMessage("prompt", {
    messages = self.messages,
    tools = wireTools,
    id = self.id,
    model = self.model,
    user = self.user,
    priority = self.priority,
    forceProviders = MODEL_PROVIDER_FORCE[self.model],
    reasoningEffort = self.reasoningEffort, -- dropped from JSON when nil (server uses its default)
  })

  self:reportProgress()
end

--- Nudge the requesting player's progress bar one tick. Every agent working on a
--- prompt (planner, coders, reviewer) shares that player, so parallel work all feeds
--- one bar. self.player is set by each subclass; a player-less agent just no-ops.
function Agent:reportProgress()
  if not IsValid(self.player) then return end
  net.Start("claude.progress")
  net.Send(self.player)
end

--- The Connection routes every id-matched event here.
function Agent:onEvent(event)
  if event.type == "prompt-response" then
    self:onResponse(event.response)
  else
    print("[gm-claude] Agent " .. self.id .. " received unknown event type: " .. tostring(event.type))
  end
end

function Agent:onResponse(response)
  -- Strip provider bookkeeping so only real message fields go back into history.
  for k in pairs(response) do
    if not table.HasValue(ALLOWED_RESPONSE_FIELDS, k) then
      response[k] = nil
    end
  end

  table.insert(self.messages, response)

  -- From here we either terminate, or run the requested tools and loop again.
  if response.tool_calls and #response.tool_calls > 0 then
    if self.toolCallCount >= self.maxToolCalls then
      self:onToolLimit()
    end

    -- Tools may complete asynchronously, so gather every result before looping.
    self:dispatchToolCalls(response.tool_calls, function()
      self:send()
    end)
  elseif response.content and #response.content > 0 then
    self:onFinish(response.content)
  else
    print("[gm-claude] Agent " .. self.id .. " received an empty response, retrying.")
    -- Don't let that stick.
    table.remove(self.messages, #self.messages)
    self:send()
  end
end

--- Injected once the tool-call budget is spent. Subclasses override to steer the
--- model toward whatever their final answer should look like.
function Agent:onToolLimit()
  self:addSystem(string.format(
    "You have made too many tool calls (%d+). This is your **last attempt** — respond with your final answer now.",
    self.maxToolCalls))
end

--- Terminal step. Base hands the raw content back to the creator; subclasses
--- override to post-process (e.g. parse Lua, persist, package a result, etc.).
function Agent:onFinish(content)
  self:finish(content)
end

--- Completes the agent exactly once, handing `result` to whoever launched it.
function Agent:finish(result)
  if self.finished then return end
  self.finished = true
  if self.onComplete then
    self.onComplete(result, self)
  end
end

--- Runs a single tool call. Tools signal completion by calling done(result), so
--- they can be async (network round trips, sub-agents, waiting on the player).
--- done is guaranteed to fire exactly once.
function Agent:handleToolCall(toolName, args, done)
  self.toolCallCount = self.toolCallCount + 1

  for _, tool in ipairs(self.tools) do
    if tool.name == toolName then
      local finished = false
      local function complete(result)
        if finished then
          print("[gm-claude] Tool '" .. toolName .. "' tried to complete more than once, ignoring.")
          return
        end
        finished = true
        table.insert(self.toolCalls, {tool = toolName, args = args, result = result})
        done(result)
      end

      -- Safety net: a hung tool must never stall the whole agent forever. Tools
      -- that legitimately run long (e.g. dispatching sub-agents) raise the bar
      -- with their own tool.timeout.
      local timeout = tool.timeout or TOOL_CALL_TIMEOUT
      timer.Simple(timeout, function()
        if not finished then
          print(string.format("[gm-claude] Tool '%s' timed out after %ds", toolName, timeout))
          complete({error = "Tool timed out"})
        end
      end)

      tool:execute(args, complete, self)
      return
    end
  end

  print("[gm-claude] Agent " .. self.id .. " received call for unknown tool: " .. toolName)
  done({error = "Unknown tool: " .. toolName}) -- still complete the slot, or the agent hangs
end

--- Runs every tool call from a turn (each possibly async, all in parallel) and
--- invokes onAllDone once every result is in. Result messages are inserted in the
--- original call order so providers that care about ordering stay happy.
function Agent:dispatchToolCalls(toolCalls, onAllDone)
  local remaining = #toolCalls
  if remaining == 0 then
    onAllDone()
    return
  end

  local results = {}
  local allDispatched = false

  local function checkDone()
    if remaining > 0 or not allDispatched then return end
    for i = 1, #toolCalls do
      table.insert(self.messages, results[i])
    end
    onAllDone()
  end

  for index, toolCall in ipairs(toolCalls) do
    local name = toolCall["function"].name
    local args = jt(toolCall["function"].arguments)
    self:handleToolCall(name, args, function(result)
      results[index] = {role = "tool", tool_call_id = toolCall.id, content = j(result)}
      remaining = remaining - 1
      checkDone()
    end)
  end

  allDispatched = true
  checkDone()
end

return Agent
