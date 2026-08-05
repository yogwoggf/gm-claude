-- Deferred-error capture for AI-generated code, shared by both realms.

AddCSLuaFile()

if _G.GilbErrorCapture then return _G.GilbErrorCapture end

local capture = {}
local sink = nil

--- Where reports go. fn(promptId, realm, err, detail)
function capture.setSink(fn)
  sink = fn
end

--- tostring that can't itself throw and won't dump a wall of text into an error
--- report (a bad __tostring or a huge table shouldn't drown the useful message).
local function tostringSafe(v)
  local ok, s = pcall(tostring, v)
  if not ok then s = "<tostring error>" end
  if #s > 80 then s = s:sub(1, 77) .. "..." end
  return s
end

--- Snapshot the locals of the failing frame(s) that live in the generated chunk.
--- Runs before the stack unwinds, so the values at the moment of the error are
--- still readable. Best-effort.
local function snapshotLocals(promptId)
  local out = {}
  for level = 2, 16 do
    local info = debug.getinfo(level, "Sln")
    if not info then break end
    local src = tostring(info.short_src or info.source or "")
    if src == promptId or src:find(promptId, 1, true) then
      local parts = {}
      for i = 1, 40 do
        local name, value = debug.getlocal(level, i)
        if not name then break end
        if name:sub(1, 1) ~= "(" then -- skip (temporary) / (for ...) internals
          parts[#parts + 1] = string.format("%s = %s", name, tostringSafe(value))
        end
      end
      out[#out + 1] = string.format("line %d: %s", info.currentline or -1, table.concat(parts, ", "))
    end
  end
  return table.concat(out, "\n")
end

--- Wrap a callback so a runtime error inside it is caught, attributed to promptId,
--- enriched with a traceback + locals, and handed to the sink. The error is
--- swallowed (the game keeps running) since it has been recorded. Return values
--- pass through untouched on success, so wrapped hooks/methods behave exactly as
--- before when they don't error.
function capture.wrap(promptId, realm, fn)
  if type(fn) ~= "function" then return fn end

  local function handler(err)
    -- Nesting matters: traceback's level 2 is counted from inside this pcall.
    local okCap, detail = pcall(function()
      local locals = snapshotLocals(promptId)
      local trace = debug.traceback(tostring(err), 2)
      return locals ~= "" and (trace .. "\nLocals at error:\n" .. locals) or trace
    end)

    if sink then
      pcall(sink, promptId, realm, tostring(err), okCap and detail or nil)
    end
    return err
  end

  return function(...)
    local res = {xpcall(fn, handler, ...)} -- LuaJIT xpcall forwards args
    if res[1] then return unpack(res, 2) end
  end
end

_G.GilbErrorCapture = capture
return capture
