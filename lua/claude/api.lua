require("gwsockets")
---@module "lua.claude.dynamic-prompt"
local dynamicPrompt = include("claude/dynamic-prompt.lua")
---@module "lua.claude.system-prompt"
local systemPrompt = include("claude/system-prompt.lua")
---@module "lua.claude.tools"
local registerTools = include("claude/tools.lua")

local j = util.TableToJSON
local jt = util.JSONToTable

local function Prompt(player, prompt, api, onLuaCallback)
  return {
    id = tostring(math.random(100000, 9999999)),
    player = player,
    prompt = prompt,
    api = api,
    messages = {}, -- State of the prompt
    model = api.CURRENT_MODEL,
    tools = {},
    onLuaCallback = onLuaCallback,
    toolCallCount = 0,
    toolCalls = {},
    
    start = function(self)
      -- Kicks off with RAG first, then kicks more off once we get it back from the API.
      print("[gm-claude] Starting prompt with RAG: " .. self.prompt)
      self.api:sendMessage("rag", {
        query = self.prompt,
        playerId = tostring(self.player:UserID()),
        id = self.id
      })
    end,

    send = function(self)
      local jsonTools = table.Copy(self.tools)
      for i, tool in ipairs(jsonTools) do
        jsonTools[i] = table.Copy(tool)
        jsonTools[i].callback = nil -- don't send the Lua callback
      end

      self.api:sendMessage("prompt", {
        messages = self.messages,
        tools = jsonTools,
        id = self.id,
        model = self.model,
        priority = self.api.CURRENT_PRIORITY
      })
    end,

    -- Called when the API receives a response and looks up prompt by ID to run the callback,
    onResponse = function(self, response)
      table.insert(self.messages, response)

      -- From here, we'll either terminate the state machine and run the Lua code,
      -- or if it wants to call a tool, we'll run the tool callback and send the result back to the API as another message in the conversation,
      -- which kicks it off again.
      if response.toolCalls then
        if self.toolCallCount >= 5 then
          table.insert(self.messages, {
            role = "system",
            content = "The AI has made too many tool calls (5+), this is your **last attempt**! **Please only return a Lua code block of your finished script after this!**"
          })
        end

        for _, toolCall in ipairs(response.toolCalls) do
          -- Tools respond with their raw content, we'll handle the message
          local toolResult = self:handleToolCall(toolCall["function"].name, jt(toolCall["function"].arguments))
          table.insert(self.messages, {role = "tool", toolCallId = toolCall.id, content = j(toolResult)})
        end

        self:send()
      elseif response.content and #response.content > 0 then
        -- No tool calls, so this must be the final response with Lua code to run
        -- Sometimes a zero-completion will happen, we just ignore it and hope
        -- it fixes itself.
        local luaCode = self.api:parseResponseForLua(response.content)
        local save = string.format("Prompt: %s\nResponse: %s", self.prompt, luaCode)
        file.Write("prompt-lua/" .. self.id .. ".txt", save) -- write the Lua code to a file for debugging/inspection later
        self.luaCode = luaCode
        embeddings.SavePromptObject(self.id, self)
        self.onLuaCallback(luaCode, self.id)
      end
    end,

    onRagResponse = function(self, examples)
      print("[gm-claude] Received RAG examples from API: " .. #examples)
      print("[gm-claude] Now running...")

      -- system prompt
      table.insert(self.messages, {role = "system", content = systemPrompt})
      local combined = "Here are some relevant examples to help you: "
      for _, example in pairs(examples) do
        combined = combined .. "\n" .. example -- already has ## Example and all that
      end
      table.insert(self.messages, {role = "system", content = combined})
      table.insert(self.messages, {role = "user", content = self.api:formatPlayerPrompt(self.player, self.prompt)})
      self:send()
     end,

    handleToolCall = function(self, toolName, args)
      self.toolCallCount = self.toolCallCount + 1

      for _, tool in ipairs(self.tools) do
        if tool["function"].name == toolName then
          local result = tool.callback(args)
          -- Introspection for later
          table.insert(self.toolCalls, {tool = toolName, args = args, result = result})
          return result
        end
      end

      print("[gm-claude] Received call for unknown tool: " .. toolName)
      return nil
    end,
    
    -- Expects an entire tool definition with a Lua callback, but basically
    -- 1:1 with the tool definition format that the API expects, except with an added `callback` field for the Lua function to call when the tool is invoked
    --[[
    const tools = [
  {
    type: 'function',
    function: {
      name: 'searchGutenbergBooks',
      description:
        'Search for books in the Project Gutenberg library based on specified search terms',
      parameters: {
        type: 'object',
        properties: {
          search_terms: {
            type: 'array',
            items: {
              type: 'string',
            },
            description:
              "List of search terms to find books in the Gutenberg library (e.g. ['dickens', 'great'] to search for books by Dickens with 'great' in the title)",
          },
        },
        required: ['search_terms'],
      },
    },
  },
];
]]
      addTool = function(self, toolDef)
        table.insert(self.tools, toolDef)
      end
  }
end

return {
  API_URL = "ws://claude-api:3000/",
  CURRENT_MODEL = "google/gemini-3-flash-preview:nitro",
  CURRENT_PRIORITY = "latency",
  SOCKET = nil,

  state = {
    promptsInFlight = {},
    moneyLeftCallback = nil,
    embeddingCallback = nil
  },

  connect = function(self)
    self.SOCKET = GWSockets.createWebSocket(self.API_URL)

    self.SOCKET.onMessage = function(_, msg)
      print("[gm-claude] Received message from API: " .. msg)
      local data = jt(msg)
      self:onMessage(data)
    end

    self.SOCKET.onConnected = function()
      print("[gm-claude] Successfully connected to API WebSocket.")
    end

    self.SOCKET.onDisconnected = function(_, code, reason)
      print("[gm-claude] Disconnected from API WebSocket.")
    end

    print("[gm-claude] Attempting to connect to API WebSocket...")
    self.SOCKET:open()
  end,

  sendMessage = function(self, type, data)
    local packet = data
    data.type = type -- merged
    self.SOCKET:write(j(packet))
  end,

  onMessage = function(self, data)
    if data.type == "prompt-response" then
      local prompt = self.state.promptsInFlight[data.id]
      if not prompt then
        print("[gm-claude] Received response for unknown prompt ID: " .. data.id)
        return
      end

      prompt:onResponse(data.response)
    elseif data.type == "credits-response" then
      if self.state.moneyLeftCallback then
        self.state.moneyLeftCallback(data.totalCredits - data.totalUsed)
        self.state.moneyLeftCallback = nil
      end
    elseif data.type == "rag-response" then
      local prompt = self.state.promptsInFlight[data.id]
      if not prompt then
        print("[gm-claude] Received RAG response for unknown prompt ID: " .. data.id)
        return
      end

      prompt:onRagResponse(data.examples)      
    elseif data.type == "add-embedding-response" then
      if self.state.embeddingCallback then
        self.state.embeddingCallback(data.success, data.message)
        self.state.embeddingCallback = nil
       end
    elseif data.type == "error" then
      print("[gm-claude] Received error from API: " .. data.message)
    else
      print("[gm-claude] Received message with unknown type: " .. tostring(data.type))
    end
  end,

  formatPlayerPrompt = function(self, player, request)
    return string.format("Player(%d): %s", player:UserID(), request)
  end,

  formatPromptIntoBody = function(self, prompt, modelOverride)
    return {
      playerPrompt = prompt,
      model = modelOverride or self.CURRENT_MODEL,
      dynamicPrompt = dynamicPrompt()
    }
  end,

  parseLuaCode = function(self, code)
    -- It can sometimes get confused and make a ```lua block
    code = code:gsub("```lua", "")
    code = code:gsub("```", "")
    return code
  end,

  parseResponseForLua = function(self, response)
    if response then
      return self:parseLuaCode(response)
    end

    return nil
  end,

  --- Sends a prompt to the API and returns the response via callback
  --- @param prompt string Prompt to send to the API
  --- @param callback fun(luaCode: string, promptId: string) Callback function that receives the Lua code and prompt ID.
  sendPrompt = function(self, player, prompt, callback, modelOverride)
    local newPrompt = Prompt(player, prompt, self, function(luaCode, promptId)
      self.state.promptsInFlight[promptId] = nil -- clear prompt from in-flight state
      callback(luaCode, promptId)
    end)

    self.state.promptsInFlight[newPrompt.id] = newPrompt
    registerTools(newPrompt) -- register tools for this prompt
    newPrompt:start() -- kick off the CoT state machine for this prompt
  end,
  
  addLiveEmbedding = function(self, example, callback)
    self.state.embeddingCallback = callback
    self:sendMessage("add-embedding", {example = example})
  end,

  getMoneyLeft = function(self, callback)
    if not self.SOCKET then
      print("[gm-claude] Cannot get money left: WebSocket is not connected.")
      callback(nil)
      return
    end

    self:sendMessage("get-credits", {})
    self.state.moneyLeftCallback = callback
  end,
}