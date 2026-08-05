-- Picks the CAPABILITIES a request needs.
-- Decided to separate it into primary vs secondary, because
-- if not then the agent might try to make independent deliverables for each capability, which is not what we want.
-- 
-- i.e. if SWEP and SHADER it might make a SWEP and a SHADER, when the SWEP is the deliverable and the SHADER is just a technique it needs for a part of the SWEP.

local Classify = {}
local ClassifierAgent = nil
local CLASSIFY_TIMEOUT = 8

-- Keyword-based matching, used only if model is timing out.
local RULES = {
  {kind = "swep", patterns = {
    "swep", "weapon", " gun", "^gun", "rifle", "pistol", "shotgun", "launcher",
    "cannon", "blaster", "sword", "knife", "melee", "firearm", "revolver", "smg",
  }},
  {kind = "sent", patterns = {
    "sent", "scripted entit", "entity", " ent ", "spawnable", "turret", "dispenser",
    "machine", "generator", "vehicle", "prop that", "device",
  }},
  -- Ahead of `ui` because "screen" is one of its patterns and would swallow
  -- "screenspace"; behind swep/sent so "a gun that pixelates the screen" still
  -- resolves to the weapon, per the container rule above.
  {kind = "shader", patterns = {
    "shader", "hlsl", "postprocess", "post-process", "post process",
    "screenspace", "screen space", "screen-space", "chromatic aberration",
    "kaleidoscope", "fisheye", "color grading", "colour grading",
    "scanlines", "pixelate", "pixelated", "vignette",
    "crt filter", "crt effect", "crt monitor", "vhs filter", "vhs effect",
    -- Bare forms: "make everything look like a VHS tape" was falling through
    -- to `logic` and getting no shader guidance at all.
    "vhs", "crt ",
    -- Volumetrics are a screenspace raymarch and the shader playbook carries a
    -- full worked example; without these they landed on `logic`.
    "volumetric", "raymarch", "ray march", "god ray", "godray",
    "sky shader", "cloud shader", "clouds over", "clouds above",
  }},
  {kind = "ui", patterns = {
    "hud", "menu", "panel", "derma", "vgui", "dhtml", "gui", "interface", "screen",
    "scoreboard", "leaderboard", "overlay", "window", "button", "counter", "meter",
  }},
  {kind = "effect", patterns = {
    "effect", "particle", "explosion", "beam", "laser", "glow", "trail", "spark",
    "fire", "smoke", "lightning", "aura", "firework", "confetti", "visual",
    "bloom", "blur",
  }},
}

local MATERIAL_PATTERNS = {
  "shader", "hlsl", "custom material", "vertex shader",
  "dissolve", "disintegrat", "hologram", "holographic",
  "force field", "forcefield", "energy shield", "shield bubble",
  "iridescent", "oil slick", "shimmer", "refract",
  "cloak", "invisibility", "x-ray", "xray", "see-through", "see through",
  "wireframe", "scan line", "digital", "glitch",
  "melt", "wobble", "jelly", "ripple", "distort",
  "energy skin", "plasma skin", "lava texture", "animated texture",
}

--- Used by the keyword fallback to add `shader` as a secondary capability.
--- @param prompt string
--- @return boolean
function Classify:wantsMaterial(prompt)
  local text = string.lower(tostring(prompt or ""))
  for _, pattern in ipairs(MATERIAL_PATTERNS) do
    if string.find(text, pattern, 1, true) then return true end
  end
  return false
end

--- The primary capability for a raw player request, by keyword.
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

  return "logic" -- the generic fallback
end

--- Keyword-only capability set
--- @param prompt string
--- @return table { primary = string, secondary = {string,...} }
function Classify:fallback(prompt)
  local primary = self:playbook(prompt)
  local secondary = {}
  if primary ~= "shader" and self:wantsMaterial(prompt) then
    secondary[#secondary + 1] = "shader"
  end
  return {primary = primary, secondary = secondary}
end

-- Cached prompts and their resolved capabilities, so repeated requests don't have to do it all over again.
local cache = {}
local cacheCount = 0
local CACHE_MAX = 200

local function cacheKey(prompt)
  return string.lower(string.Trim(tostring(prompt or "")))
end

--- Resolve capabilities for a request. The callback ALWAYS fires exactly once, and always with a usable
--- table, so no caller has to handle failure.
--- @param api table
--- @param prompt string
--- @param callback fun(caps: table, source: string)
--- @param timeout number|nil override the production timeout (the eval waits longer,
---        because a fallback there would measure the keywords, not the model)
function Classify:capabilities(api, prompt, callback, timeout)
  local key = cacheKey(prompt)
  if cache[key] then
    callback(cache[key], "cache")
    return
  end

  if not ClassifierAgent then
    -- Avoids a circular dependency.
    ---@module "lua.claude.agents.classifier-agent"
    ClassifierAgent = include("claude/agents/classifier-agent.lua")
  end

  local fallback = self:fallback(prompt)
  if not api or not ClassifierAgent then
    callback(fallback, "keyword")
    return
  end

  local settled = false
  local function finish(caps, source)
    if settled then return end
    settled = true
    if source ~= "keyword" then
      if cacheCount >= CACHE_MAX then cache, cacheCount = {}, 0 end
      cache[key] = caps
      cacheCount = cacheCount + 1
    end
    callback(caps, source)
  end

  local ok = pcall(function()
    local agent = ClassifierAgent.new({api = api, task = prompt})
    api:launchAgent(agent, function(parsed)
      if parsed then
        finish(parsed, "model")
      else
        print("[gm-claude] Classifier returned unusable output; using keywords")
        finish(fallback, "keyword")
      end
    end)
  end)
  
  if not ok then
    finish(fallback, "keyword")
    return
  end

  -- A classify call must never be able to hold up a build.
  timer.Simple(timeout or CLASSIFY_TIMEOUT, function()
    if not settled then
      print("[gm-claude] Classifier timed out; using keywords")
      finish(fallback, "keyword")
    end
  end)
end

return Classify
