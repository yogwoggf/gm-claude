-- Picks which playbook a request needs, without an LLM round-trip.
--
-- The planner used to tag this. In the one-shot path there is no planner, and
-- spending a whole model call to choose between five files would give back the
-- latency the one-shot path exists to save. Keyword rules are instant, free, and
-- deterministic; when they are wrong the cost is a less-specific playbook, not a
-- broken build, and the coder still has search_wiki.

local Classify = {}

-- Ordered: the FIRST matching rule wins, so the more specific container wins over
-- what it contains. "a gun that shoots fireworks" is a swep, not an effect —
-- the weapon is the deliverable and its playbook already points at the effect floors.
local RULES = {
  {kind = "swep", patterns = {
    "swep", "weapon", " gun", "^gun", "rifle", "pistol", "shotgun", "launcher",
    "cannon", "blaster", "sword", "knife", "melee", "firearm", "revolver", "smg",
  }},
  {kind = "sent", patterns = {
    "sent", "scripted entit", "entity", " ent ", "spawnable", "turret", "dispenser",
    "machine", "generator", "vehicle", "prop that", "device",
  }},
  {kind = "ui", patterns = {
    "hud", "menu", "panel", "derma", "vgui", "dhtml", "gui", "interface", "screen",
    "scoreboard", "leaderboard", "overlay", "window", "button", "counter", "meter",
  }},
  {kind = "effect", patterns = {
    "effect", "particle", "explosion", "beam", "laser", "glow", "trail", "spark",
    "fire", "smoke", "lightning", "aura", "firework", "confetti", "visual", "shader",
    "bloom", "blur",
  }},
}

--- The playbook kind for a raw player request.
--- @param prompt string
--- @return string one of playbooks.kinds
function Classify:playbook(prompt)
  local text = string.lower(tostring(prompt or ""))

  for _, rule in ipairs(RULES) do
    for _, pattern in ipairs(rule.patterns) do
      -- plain find: these are literal substrings, not Lua patterns
      if string.find(text, pattern, 1, true) then
        return rule.kind
      end
    end
  end

  return "logic" -- the generic fallback; never leaves the coder without a playbook
end

return Classify
