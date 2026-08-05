-- Picks the set of capabilities a request needs, using a small fast model.
---@module "lua.claude.agents.agent"
local Agent = include("claude/agents/agent.lua")
---@module "lua.claude.prompts.playbooks.init"
local playbooks = include("claude/prompts/playbooks/init.lua")

local ClassifierAgent = {}
ClassifierAgent.__index = ClassifierAgent
setmetatable(ClassifierAgent, {__index = Agent})

-- Specifically tuned to not reason a lot, which makes it almost zero-cost.
ClassifierAgent.MODEL = "openai/gpt-oss-20b"

-- I don't know how or why, but it seems like using AI dashes tends to
-- make the model follow the instructions better.

local MAX_SECONDARY = 2
local DESCRIPTIONS = {
  swep = "a weapon the player holds and fires",
  sent = "a spawnable entity, prop or machine that exists in the world",
  effect = "visual effects: particles, beams, explosions, trails, lights",
  shader = "custom HLSL — screenspace post-processing, or a real material on a prop",
  ui = "HUD, menus, panels, scoreboards — anything drawn in 2D",
  logic = "gameplay rules, movement, spawning, timers, server behaviour",
}

local function buildPrompt()
  local lines = {
    "You label a Garry's Mod build request with the capabilities it needs. Reply with JSON only.",
    "",
    "Capabilities:",
  }
  for _, k in ipairs(playbooks.kinds) do
    lines[#lines + 1] = string.format("- %s: %s", k, DESCRIPTIONS[k] or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Return: {\"primary\": \"<capability>\", \"secondary\": [\"<capability>\", ...]}"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "PRIMARY is the deliverable — the thing that exists when the build is done."
  lines[#lines + 1] = "SECONDARY are supporting techniques the deliverable needs. Not extra deliverables."
  lines[#lines + 1] = "Rules:"
  lines[#lines + 1] = "- The container wins. A gun that shoots fireworks is primary swep, secondary effect: the weapon is what gets built."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "shader vs effect - the most common mistake:"
  lines[#lines + 1] = "  shader = maths on pixels or vertices. Anything that bends, filters, reads or reshapes what is"
  lines[#lines + 1] = "    already on screen or on a surface: refraction, heat haze, distortion, screen filters,"
  lines[#lines + 1] = "    colour grading, dissolve, hologram, x-ray, wireframe, cloaking, volumetrics, god rays."
  lines[#lines + 1] = "  effect = things made of particles, sprites, beams and lights placed in the world:"
  lines[#lines + 1] = "    explosions, fire, smoke, trails, sparks, lightning, a glowing lamp."
  lines[#lines + 1] = "  If the look could be drawn with sprites and lights, it is effect. If it needs to alter"
  lines[#lines + 1] = "  pixels that are already there, it is shader."
  lines[#lines + 1] = "  EXCEPTION - atmospherics are always shader: clouds, sky, fog, haze, god rays,"
  lines[#lines + 1] = "  volumetrics, water surfaces. A crude version could be sprites, but these are"
  lines[#lines + 1] = "  raymarched and there is a full playbook for them."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Secondaries - be strict:"
  lines[#lines + 1] = "- Add one ONLY if the deliverable cannot be built without that technique."
  lines[#lines + 1] = "- Most requests need NONE. If you are unsure, leave it out."
  lines[#lines + 1] = "- Never add a secondary just because it might look nice."
  lines[#lines + 1] = "- At most " .. MAX_SECONDARY .. "."
  lines[#lines + 1] = "- logic is a real capability, not just a fallback. Use it when the request is about behaviour."
  lines[#lines + 1] = "- sent vs logic: sent means AUTHORING a new scripted entity class. Spawning, moving or"
  lines[#lines + 1] = "  controlling entities that already exist (npc_zombie, prop_physics, vehicles) is logic."
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Examples:"
  lines[#lines + 1] = '"a gun that shoots exploding barrels" -> {"primary":"swep","secondary":["effect"]}'
  lines[#lines + 1] = '"a statue that slowly melts" -> {"primary":"sent","secondary":["shader"]}'
  lines[#lines + 1] = '"make a double jump with a shader effect" -> {"primary":"logic","secondary":["shader"]}'
  lines[#lines + 1] = '"heat haze coming off the ground" -> {"primary":"shader","secondary":[]}'
  lines[#lines + 1] = '"god rays through the windows" -> {"primary":"shader","secondary":[]}'
  lines[#lines + 1] = '"a hologram entity that flickers" -> {"primary":"sent","secondary":["shader"]}'
  lines[#lines + 1] = '"glowing red lamp" -> {"primary":"effect","secondary":[]}'
  lines[#lines + 1] = '"a rifle with a scope" -> {"primary":"swep","secondary":[]}'
  lines[#lines + 1] = '"a vending machine that dispenses props" -> {"primary":"sent","secondary":[]}'
  lines[#lines + 1] = '"make it rain money every 30 seconds" -> {"primary":"logic","secondary":[]}'
  lines[#lines + 1] = '"a scoreboard showing kills" -> {"primary":"ui","secondary":[]}'
  lines[#lines + 1] = '"epic looking clouds" -> {"primary":"shader","secondary":[]}'
  lines[#lines + 1] = '"spawn a bunch of zombies" -> {"primary":"logic","secondary":[]}'
  return table.concat(lines, "\n")
end

--- @param opts table { api, task }. The completion callback comes from
function ClassifierAgent.new(opts)
  local self = setmetatable({}, ClassifierAgent)
  Agent.init(self, {
    api = opts.api,
    model = ClassifierAgent.MODEL,
    maxToolCalls = 0, -- no tools; a single labelling turn
    priority = "latency",
    temperature = 0,
    reasoningEffort = "low", -- INCREDIBLY IMPORTANT
  })
  self.task = opts.task
  return self
end

function ClassifierAgent:start()
  self:addSystem(buildPrompt())
  self:addUser(self.task)
  self:send()
end

--- Pull the first {...} out of the reply. Small models
--- can't really control their output formatting that well.
local function extractJSON(text)
  if not isstring(text) then return nil end
  local body = string.match(text, "%b{}")
  if not body then return nil end
  local ok, decoded = pcall(util.JSONToTable, body)
  if not ok or not istable(decoded) then return nil end
  return decoded
end

--- @return table|nil { primary = string, secondary = {string,...} }
--- Written highly defensively because the model is not very good at formatting output well.
function ClassifierAgent.parse(text)
  local decoded = extractJSON(text)
  if not decoded then return nil end

  local valid = {}
  for _, k in ipairs(playbooks.kinds) do valid[k] = true end

  local primary = decoded.primary
  if not isstring(primary) or not valid[primary] then return nil end

  local secondary, seen = {}, {[primary] = true}
  if istable(decoded.secondary) then
    for _, k in ipairs(decoded.secondary) do
      if isstring(k) and valid[k] and not seen[k] and #secondary < MAX_SECONDARY then
        seen[k] = true
        secondary[#secondary + 1] = k
      end
    end
  end
  return {primary = primary, secondary = secondary}
end

function ClassifierAgent:onFinish(content)
  local parsed = ClassifierAgent.parse(content)
  if self.onComplete then self.onComplete(parsed, self) end
end

return ClassifierAgent
