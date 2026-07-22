-- Owns the WebSocket transport and all request/response correlation for the API.
-- There are two correlation styles:
--   * id-based handlers: long-lived streams. A prompt/agent receives many events
--     over its lifetime, all routed by the `id` field on incoming messages.
--   * type-based RPC: one-shot request/response (credits, embeddings). Each pending
--     request is queued FIFO under its expected response `type`, so concurrent
--     requests resolve in order instead of clobbering a single shared callback slot.

require("gwsockets")

local j = util.TableToJSON
local jt = util.JSONToTable

--- @param url string WebSocket URL to connect to
local function Connection(url)
  return {
    url = url,
    socket = nil,
    handlers = {}, -- id -> function(event)
    pending = {},  -- responseType -> FIFO list of callbacks

    connect = function(self)
      self.socket = GWSockets.createWebSocket(self.url)

      self.socket.onMessage = function(_, msg)
        print("[gm-claude] Received message from API: " .. msg)
        self:onMessage(jt(msg))
      end

      self.socket.onConnected = function()
        print("[gm-claude] Successfully connected to API WebSocket.")
      end

      self.socket.onDisconnected = function(_, code, reason)
        print("[gm-claude] Disconnected from API WebSocket.")
      end

      print("[gm-claude] Attempting to connect to API WebSocket...")
      self.socket:open()
    end,

    isConnected = function(self)
      return self.socket ~= nil
    end,

    --- Fire a raw message with its type merged in.
    send = function(self, messageType, data)
      data.type = messageType
      self.socket:write(j(data))
    end,

    --- One-shot RPC: send a request and resolve `callback` with the next message
    --- of `responseType`. Multiple in-flight requests of the same type resolve in
    --- the order they were sent.
    request = function(self, requestType, data, responseType, callback)
      self.pending[responseType] = self.pending[responseType] or {}
      table.insert(self.pending[responseType], callback)
      self:send(requestType, data)
    end,

    --- Register a long-lived handler for every message carrying this id.
    registerHandler = function(self, id, handler)
      self.handlers[id] = handler
    end,

    unregisterHandler = function(self, id)
      self.handlers[id] = nil
    end,

    onMessage = function(self, data)
      -- id-correlated streams (prompts/agents) take priority. RPC responses carry
      -- no id, so they fall through to the type-based queue below.
      if data.id and self.handlers[data.id] then
        self.handlers[data.id](data)
        return
      end

      local waiters = self.pending[data.type]
      if waiters and #waiters > 0 then
        local callback = table.remove(waiters, 1)
        callback(data)
        return
      end

      if data.type == "error" then
        print("[gm-claude] Received error from API: " .. tostring(data.message))
        return
      end

      print("[gm-claude] Received message with unknown type: " .. tostring(data.type))
    end,
  }
end

return Connection
