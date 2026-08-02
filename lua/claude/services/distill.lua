-- Verified repair -> durable lesson.
-- Post-build, cheap fix model, off the path.
-- Most repairs teach nothing: prompt says SKIP

---@module "lua.claude.agents.agent"
local Agent = include("claude/agents/agent.lua")
---@module "lua.claude.services.memory"
local memory = include("claude/services/memory.lua")
---@module "lua.claude.services.demand"
local demand = include("claude/services/demand.lua")

local CODE_EXCERPT_MAX = 1800
local ERROR_MAX = 600
local MAX_PAIRS_PER_BUILD = 2

local SYSTEM = [[
You extract durable, reusable lessons about the Garry's Mod Lua API from build failures.

You are given a runtime error, the code that caused it, and the corrected code that
then ran clean. Decide whether this teaches something about GMOD ITSELF that a
competent Lua programmer could not have predicted.

Answer with SKIP unless the fix reveals genuine GMod API behaviour. SKIP is the
right answer most of the time. SKIP for: typos, misspelled or undefined locals,
wrong variable names, logic bugs, missing nil checks on the coder's own values,
anything specific to this one build's design.

Emit a lesson ONLY for things like: a function that must be called before or after
another, a field that must be set prior to Spawn, a realm restriction, an argument
that must be a specific type or format, an API that silently no-ops instead of
erroring, a required KeyValue or spawnflag, a hook that fires at an unexpected time.

Respond with raw JSON and nothing else. No markdown, no code fences.

To skip:
{"skip": true}

To record a lesson:
{"skip": false, "triggers": ["identifier", "identifier"], "topics": ["word", "word"], "lesson": "One or two sentences, imperative."}

Rules for a lesson:
- "triggers" are the exact identifiers that should surface this lesson later:
  function names, class names, field names, KeyValue names. Lowercase. 2 to 6 of
  them. Only identifiers that literally appear in code hitting this issue.
- "topics" are 2 to 4 plain everyday words naming the SUBJECT this comes up in —
  what someone would say they were building ("vehicle", "car", "seat", "door",
  "npc", "ragdoll"). Never API names, never Lua words. These surface the lesson
  BEFORE any code exists, so pick words that describe the thing, not the bug.
- "lesson" states the rule and the consequence of getting it wrong. Name the real
  API symbols. Do not reference "this build", the player, or any variable name
  invented by the coder. Someone building something unrelated must be able to use it.
- Keep it under 300 characters.
]]

-- Keep both ends: top names the build.
local function excerpt(code, limit)
  code = tostring(code or "")
  if #code <= limit then return code end
  local head = math.floor(limit * 0.6)
  return string.sub(code, 1, head) .. "\n-- ...(truncated)...\n" .. string.sub(code, -(limit - head))
end

local function stripFence(text)
  text = string.Trim(tostring(text or ""))
  text = string.gsub(text, "^```[%a]*%s*", "")
  text = string.gsub(text, "%s*```$", "")
  return text
end

local Distill = {}

local function distillOne(api, kind, pair)
  local cfg = demand:current().coding.fix

  local agent = Agent.new({
    api = api,
    model = cfg.model,
    reasoningEffort = cfg.reasoning,
    temperature = cfg.temperature,
    maxToolCalls = 0,
  })

  agent:addSystem(SYSTEM)
  agent:addUser(string.format(
    "Runtime error:\n%s\n\nCode that failed:\n```lua\n%s\n```\n\nCorrected code that ran clean:\n```lua\n%s\n```",
    string.sub(tostring(pair.error or ""), 1, ERROR_MAX),
    excerpt(pair.broken, CODE_EXCERPT_MAX),
    excerpt(pair.fixed, CODE_EXCERPT_MAX)))

  print(string.format("[gm-claude] Distilling a %s repair: %s",
    tostring(kind), string.sub(tostring(pair.error or ""), 1, 120)))

  api:launchAgent(agent, function(result)
    local decoded = util.JSONToTable(stripFence(result))
    if not istable(decoded) then
      print("[gm-claude] Distiller returned unparseable output, discarding")
      return
    end
    if decoded.skip ~= false then -- absent or true both skip
      print("[gm-claude] Distiller: nothing durable here, skipped")
      return
    end

    memory:add({
      kind = kind,
      triggers = decoded.triggers,
      topics = decoded.topics,
      lesson = decoded.lesson,
      errorSig = pair.error,
      source = "distilled",
    })
  end)
end

--- Distill a build's repairs. Async.
function Distill.run(api, kind, pairs_)
  if not api or not pairs_ or #pairs_ == 0 then return end

  for i = 1, math.min(#pairs_, MAX_PAIRS_PER_BUILD) do
    local pair = pairs_[i]
    if pair.error and pair.broken and pair.fixed then
      -- Staggered off the socket.
      timer.Simple(i * 2, function()
        local ok, err = pcall(distillOne, api, kind, pair)
        if not ok then
          print("[gm-claude] Distillation failed: " .. tostring(err))
        end
      end)
    end
  end
end

return Distill
