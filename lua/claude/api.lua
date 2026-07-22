---@module "lua.claude.services.connection"
local Connection = include("claude/services/connection.lua")
---@module "lua.claude.agents.planner-agent"
local PlannerAgent = include("claude/agents/planner-agent.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")
---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua")

return {
  API_URL = "ws://claude-api:3000/",
  CURRENT_MODEL = "google/gemini-3-flash-preview:nitro",
  CURRENT_PRIORITY = "latency",
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

  --- Runs a prompt through the entire pipeline. Callback is called once
  --- the planner and all coding agents have finished.
  --- @param callback fun(result: any, promptId: string)
  --- @param opts table|nil { promptId?: string, editContext?: table }
  sendPrompt = function(self, player, prompt, callback, opts)
    opts = opts or {}
    local planner = PlannerAgent.new({
      api = self,
      player = player,
      prompt = prompt,
      promptId = opts.promptId,
      editContext = opts.editContext,
    })

    local label = opts.editContext and opts.editContext.originalPrompt or prompt
    history:begin(player, planner.promptId, label)
    repair:register(planner.promptId, player)

    self:launchAgent(planner, function(result, agent)
      history:finish(agent.promptId)
      callback(result, agent.promptId)
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
