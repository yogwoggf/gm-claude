---@module "lua.claude.services.connection"
local Connection = include("claude/services/connection.lua")
---@module "lua.claude.agents.planner-agent"
local PlannerAgent = include("claude/agents/planner-agent.lua")
---@module "lua.claude.agents.coding-agent"
local CodingAgent = include("claude/agents/coding-agent.lua")
---@module "lua.claude.services.classify"
local classify = include("claude/services/classify.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")
---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua")

return {
  API_URL = "ws://claude-api:3000/",
  CURRENT_MODEL = "google/gemini-3-flash-preview:nitro",
  CURRENT_PRIORITY = "latency",
  -- 1 = one coding agent on the player's verbatim request (fast, no paraphrase).
  -- 0 = the planner + dispatch path. Flip live to A/B the same prompt.
  ONE_SHOT = CreateConVar("claude_oneshot", "1", FCVAR_ARCHIVE,
    "Route prompts straight to a single coding agent instead of the planner pipeline."),
  connection = nil,
  sandbox = nil, -- set by the server autorun; coding agents run Lua through it

  connect = function(self)
    self.connection = Connection(self.API_URL)
    self.connection:connect()
  end,

  -- Thin passthrough so agents can post raw messages over the shared connection.
  sendMessage = function(self, messageType, data)
    self.connection:send(messageType, data)
  end,

  formatPlayerPrompt = function(self, player, request)
    return string.format("Player(%d): %s", player:UserID(), request)
  end,

  --- Registers an agent on the connection and starts it, cleaning up its handler
  --- when it finishes. onComplete receives (result, agent). Used both for the
  --- top-level planner and for coding agents spawned by the dispatch tool.
  launchAgent = function(self, agent, onComplete)
    self.connection:registerHandler(agent.id, function(event)
      agent:onEvent(event)
    end)

    agent.onComplete = function(result, ag)
      self.connection:unregisterHandler(ag.id) -- stream is done, stop routing events to it
      if onComplete then
        onComplete(result, ag)
      end
    end

    agent:start()
  end,

  --- Runs a prompt through the pipeline. Callback fires once everything has finished.
  ---
  --- Two routes. ONE-SHOT (default) hands the player's verbatim request straight to a
  --- single coding agent — no planner, so no paraphrase between what the player asked
  --- for and the model that writes the code, and 2-4 sequential calls instead of 8-12.
  --- PLANNER keeps the multi-agent path for genuinely multi-deliverable requests.
  --- Error capture, the mock exercise, fix iterations and the repair bus are identical
  --- on both routes — they live in the Lua tools and the sandbox, not in the planner.
  --- @param callback fun(result: any, promptId: string)
  --- @param opts table|nil { promptId?: string, editContext?: table }
  sendPrompt = function(self, player, prompt, callback, opts)
    opts = opts or {}

    local agent
    if self.ONE_SHOT:GetBool() then
      agent = CodingAgent.new({
        api = self,
        player = player,
        task = prompt, -- verbatim: the coder sees exactly what the player typed
        kind = classify:playbook(opts.editContext and opts.editContext.originalPrompt or prompt),
        oneShot = true,
        promptId = opts.promptId,
        editContext = opts.editContext,
      })
    else
      agent = PlannerAgent.new({
        api = self,
        player = player,
        prompt = prompt,
        promptId = opts.promptId,
        editContext = opts.editContext,
      })
    end

    local label = opts.editContext and opts.editContext.originalPrompt or prompt
    history:begin(player, agent.promptId, label)
    repair:register(agent.promptId, player)

    self:launchAgent(agent, function(result, ag)
      history:finish(ag.promptId)
      -- The planner finishes with a summary string; a coding agent finishes with an
      -- outcome table. Normalize so the chat entry point stays route-agnostic.
      if istable(result) then
        result = result.summary or result.error or ""
      end
      callback(result, ag.promptId)
    end)
  end,

  addLiveEmbedding = function(self, example, callback)
    self.connection:request("add-embedding", {example = example}, "add-embedding-response", function(data)
      callback(data.success, data.message)
    end)
  end,

  deleteEmbedding = function(self, prompt, callback)
    -- Callers may fire-and-forget; only queue a waiter when they actually want the result.
    if callback then
      self.connection:request("delete-embedding", {prompt = prompt}, "add-embedding-response", function(data)
        callback(data.success, data.message)
      end)
    else
      self.connection:send("delete-embedding", {prompt = prompt})
    end
  end,

  getAllEmbeddings = function(self, callback)
    self.connection:request("get-all-embeddings", {}, "get-all-embeddings-response", function(data)
      callback(data.examples)
    end)
  end,

  getMoneyLeft = function(self, callback)
    if not self.connection or not self.connection:isConnected() then
      print("[gm-claude] Cannot get money left: WebSocket is not connected.")
      callback(nil)
      return
    end

    self.connection:request("get-credits", {}, "credits-response", function(data)
      callback(data.totalCredits - data.totalUsed)
    end)
  end,
}
