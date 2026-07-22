-- Demand tiers.

if _G.GilbDemand then return _G.GilbDemand end

-- A player count at or below this is "low" demand; above it is "high".
local LOW_DEMAND_MAX_PLAYERS = 4

local CONFIGS = {
  -- 1..LOW_DEMAND_MAX_PLAYERS players: quiet server, spend on quality.
  low = {
    planner = {model = "openai/gpt-5.6-terra:nitro",  reasoning = nil},
    coding  = {model = "openai/gpt-5.6-luna:nitro", reasoning = "medium"},
  },
  -- More than LOW_DEMAND_MAX_PLAYERS players: busy server, cheaper/faster.
  high = {
    planner = {model = "openai/gpt-5.6-luna:nitro",  reasoning = "max"},
    coding  = {model = "google/gemma-4-31b-it:nitro", reasoning = "medium"},
  },
}

local Demand = {}
Demand.__index = Demand

--- "low" or "high", from the live player count.
function Demand:tier()
  return player.GetCount() <= LOW_DEMAND_MAX_PLAYERS and "low" or "high"
end

--- The config table for the current tier: { planner = {model, reasoning}, coding = {...} }.
function Demand:current()
  return CONFIGS[self:tier()]
end

-- Server: tell clients which tier we're in, and keep them updated as the player
-- count crosses the threshold (join/leave). Client just listens (see the client
-- autorun); the tier logic above never runs there.
if SERVER then
  util.AddNetworkString("claude.demand")

  function Demand:broadcast()
    net.Start("claude.demand")
    net.WriteString(self:tier())
    net.Broadcast()
  end

  -- Defer past the frame the player is added/removed so player.GetCount() is current.
  hook.Add("PlayerInitialSpawn", "claude.demand.join", function()
    timer.Simple(5, function() Demand:broadcast() end) -- give the new client's receiver time to register
  end)
  hook.Add("PlayerDisconnected", "claude.demand.leave", function()
    timer.Simple(0, function() Demand:broadcast() end)
  end)
end

_G.GilbDemand = Demand
return Demand
