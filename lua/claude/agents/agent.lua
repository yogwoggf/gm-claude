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
  ["openai/gpt-5.6-luna"] = {
    "openai"
  },
  ["openai/gpt-5.6-terra"] = {
    "openai"
  },
  ["google/gemini-3-flash-preview:nitro"] = {
    "google-ai-studio",
  },
  ["qwen/qwen3.6-35b-a3b:nitro"] = {
    "parasail"
  },
  -- Pinned to DeepSeek's own deployment. Left unpinned this one flaps between
  -- DeepSeek and Cloudflare *mid-task*, which throws away the prefix cache on every
  -- hop — the transcript is 15k+ tokens by the back half of a build.
  ["deepseek/deepseek-v4-flash-0731"] = {
    "deepseek"
  }
}

--- Provider forcing is per-model, but a model slug may carry a routing suffix
--- (`:nitro`, `:floor`) that isn't part of the model's identity. Both the table keys
--- and the lookup are reduced to the bare slug, so adding or dropping a suffix can
--- never silently disable a force entry. A DATE suffix (`-0731`) is a different
--- thing — it names a different model, so it stays part of the key and a pin written
--- for the undated slug will (correctly) not apply to it.
local function bareSlug(model)
  return model and (string.match(model, "^[^:]+") or model)
end

local FORCE_BY_SLUG = {}
for model, providers in pairs(MODEL_PROVIDER_FORCE) do
  FORCE_BY_SLUG[bareSlug(model)] = providers
end

local function forcedProviders(model)
  if not model then return nil end
  return FORCE_BY_SLUG[bareSlug(model)]
end

local TOOL_CALL_TIMEOUT = 30 -- seconds before a hung tool call is force-completed so the agent can't stall forever
local MAX_TOOL_CALLS = 5
-- `reasoning_details` is kept deliberately. A reasoning model in a tool loop that
-- gets its own thinking stripped from the transcript re-derives it from scratch every
-- round: measured on deepseek-v4-flash, two thirds of all reasoning tokens were spent
-- on rounds 2+ re-reaching conclusions the model had already reached. Passing it back
-- verbatim is what makes the loop amortize instead of compound. The sibling
-- `reasoning` field is byte-identical to reasoning_details[].text, so it stays
-- stripped — keeping both would double the transcript growth for nothing.
local ALLOWED_RESPONSE_FIELDS = {"content", "role", "tool_calls", "tool_call_id", "reasoning_details"}

-- Stale-transcript hygiene: tool results older than this many trailing messages
-- have been acted on and are dead weight re-sent every round. They get truncated
-- in place — once, at a fixed lag, so the mutation frontier trails the transcript
-- and the provider's prefix cache still covers everything before it.
local STALE_TOOL_KEEP_LAST = 4 -- messages at the tail left untouched
local STALE_TOOL_MAX_CHARS = 600 -- longer stale tool results get truncated to...
local STALE_TOOL_TRUNCATE_TO = 300

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
  self.temperature = opts.temperature -- sampling temperature; nil leaves the API default (1). Code wants well below that.
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
  -- Truncate tool results that have scrolled out of the working window (see the
  -- STALE_TOOL_* constants). Idempotent: once truncated, a message is under the
  -- threshold and is never touched again.
  for i = 1, #self.messages - STALE_TOOL_KEEP_LAST do
    local msg = self.messages[i]
    if msg.role == "tool" and isstring(msg.content) and #msg.content > STALE_TOOL_MAX_CHARS then
      msg.content = string.sub(msg.content, 1, STALE_TOOL_TRUNCATE_TO) .. "... [stale tool result truncated]"
    end
  end

  local wireTools = {}
  for i, tool in ipairs(self.tools) do
    wireTools[i] = tool:toWire()
  end

  self.api:sendMessage("prompt", {
    messages = self.messages,
    -- Empty list serializes to `{}`, not `[]`. Omit it.
    tools = #wireTools > 0 and wireTools or nil,
    id = self.id,
    model = self.model,
    user = self.user,
    priority = self.priority,
    forceProviders = forcedProviders(self.model),
    reasoningEffort = self.reasoningEffort, -- dropped from JSON when nil (server uses its default)
    temperature = self.temperature, -- likewise: nil means "leave the API default alone"
  })

  self:reportProgress()
end

--- Nudge the requesting player's progress bar one tick. Every agent working on a
--- prompt (planner and its coders) shares that player, so parallel work all feeds
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

--- Accumulate + log per-round token usage (when the sidecar forwards the
--- provider's `usage` object). The cached/reasoning splits are the two numbers
--- that decide where the money goes: cached tells you whether prefix caching is
--- actually engaging at the forced provider, reasoning is billed as output and
--- invisible in the text you see.
function Agent:recordUsage(usage)
  if not istable(usage) then return end
  local u = self.usage or {input = 0, cached = 0, output = 0, reasoning = 0, rounds = 0}
  self.usage = u

  local cached = istable(usage.prompt_tokens_details) and (usage.prompt_tokens_details.cached_tokens or 0) or 0
  local reasoning = istable(usage.completion_tokens_details) and (usage.completion_tokens_details.reasoning_tokens or 0) or 0
  u.input = u.input + (usage.prompt_tokens or 0)
  u.cached = u.cached + cached
  u.output = u.output + (usage.completion_tokens or 0)
  u.reasoning = u.reasoning + reasoning
  u.rounds = u.rounds + 1

  print(string.format("[gm-claude] Agent %s round %d usage: in=%d (cached=%d) out=%d (reasoning=%d)",
    self.id, u.rounds, usage.prompt_tokens or 0, cached, usage.completion_tokens or 0, reasoning))
end

function Agent:onResponse(response)
  self:recordUsage(response.usage)

  -- Strip provider bookkeeping so only real message fields go back into history.
  for k in pairs(response) do
    if not table.HasValue(ALLOWED_RESPONSE_FIELDS, k) then
      response[k] = nil
    end
  end

  -- A round that did no thinking comes back with an empty reasoning_details. Lua has
  -- one table type, so util.TableToJSON writes that as `{}` — an object where the API
  -- expects an array — and the malformed field would then be re-sent on every
  -- subsequent round of this agent. Drop it instead.
  if response.reasoning_details and table.IsEmpty(response.reasoning_details) then
    response.reasoning_details = nil
  end

  table.insert(self.messages, response)

  -- From here we either terminate, or run the requested tools and loop again.
  if response.tool_calls and #response.tool_calls > 0 then
    if self.toolCallCount >= self.maxToolCalls then
      -- Budget spent: nothing further is EXECUTED. The protocol still requires a
      -- result message per requested call, so answer them with stubs, warn the
      -- model once (onToolLimit), and if it still asks for tools after that,
      -- cut it off instead of looping forever.
      if self.toolLimitWarned then
        self:onFinish("(stopped: tool-call budget exhausted)")
        return
      end
      self.toolLimitWarned = true
      for _, toolCall in ipairs(response.tool_calls) do
        table.insert(self.messages, {role = "tool", tool_call_id = toolCall.id,
          content = j({error = "Tool budget exhausted - this call was NOT executed and no further calls will be."})})
      end
      self:onToolLimit()
      self:send()
      return
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
  if self.usage then
    local u = self.usage
    print(string.format("[gm-claude] Agent %s TOTAL usage: %d rounds, in=%d (cached=%d, %.0f%%) out=%d (reasoning=%d)",
      self.id, u.rounds, u.input, u.cached, u.input > 0 and (u.cached / u.input * 100) or 0, u.output, u.reasoning))
  end
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
