-- A single tool the model can call. Tools are stateless and shareable across
-- agents; per-call execution state (timeout, completion guard) lives in Agent.

local Tool = {}
Tool.__index = Tool

--- @param def table
---   name        string
---   description string
---   parameters  table   JSON schema for the arguments
---   run         fun(args: table, done: fun(result: any), agent: table)  call done(result) exactly once
---   coerceArg   string? smaller models sometimes invent the argument name, so if
---                       set, whatever value they sent is forced onto this key
---   timeout     number? seconds before the Agent force-completes a hung call;
---                       raise it for tools that legitimately run long (sub-agents)
function Tool.new(def)
  return setmetatable({
    name = def.name,
    description = def.description,
    parameters = def.parameters,
    run = def.run,
    coerceArg = def.coerceArg,
    timeout = def.timeout,
  }, Tool)
end

--- The wire format the API expects (no Lua callback attached).
function Tool:toWire()
  return {
    type = "function",
    ["function"] = {
      name = self.name,
      description = self.description,
      parameters = self.parameters,
    },
  }
end

--- Run the tool. done(result) must be called exactly once (Agent guards this).
--- `agent` is the calling agent, so tools can reach its api, id, player, etc.
function Tool:execute(args, done, agent)
  args = args or {}
  if self.coerceArg then
    -- The model sometimes calls us with the wrong argument name. Grab whatever
    -- value it sent and put it on the key we actually expect. (Assigned after the
    -- loop so we never add a key mid-iteration.)
    local value
    for _, v in pairs(args) do
      value = v
    end
    if value ~= nil then
      args[self.coerceArg] = value
    end
  end

  self.run(args, done, agent)
end

return Tool
