-- Demand tiers.

-- A player count at or below this is "low" demand; above it is "high".
local LOW_DEMAND_MAX_PLAYERS = 4

--
-- `coding` is split in two. `draft` writes the thing from scratch — the hard,
-- open-ended part, and the one that decides how many iteration rounds follow, so it
-- gets the strong model. `fix` takes over after the first execution, where the work
-- is narrow and driven by a concrete error message. A good draft needing no fixes is
-- cheaper overall than a weak one needing four, since every round re-sends the whole
-- system prompt and transcript.
local CONFIGS = {
  -- 1..LOW_DEMAND_MAX_PLAYERS players: quiet server, spend on quality.
  low = {
    planner = {model = "openai/gpt-5.6-terra:nitro", reasoning = nil},
    coding  = {
      -- No `:nitro` and priority "auto": nitro forces throughput-optimized routing,
      -- which prefers the fastest (often quantized) deployment. The draft is the one
      -- call whose quality decides the whole build, so it takes the slower, better
      -- route. Everything else stays latency-sorted.
      -- temperature: code wants low. 1 (the API default) samples adventurously and
      -- shows up as sloppy, run-to-run-inconsistent output. Fixes go lower still,
      -- since a correction should be conservative rather than creative.
      -- reasoning: the draft is left at the model's own default — thinking hard about
      -- the build from scratch is what it's for, and that round is a minority of the
      -- total spend. Fixes are capped: they're narrow and driven by a concrete error,
      -- so unbounded thinking there buys nothing and a single runaway round has been
      -- measured at 34k output tokens (~450s of generation on its own).
      draft  = {model = "openai/gpt-5.6-luna", reasoning = "high", priority = "throughput", temperature = 0.4},
      fix    = {model = "openai/gpt-5.6-luna",   reasoning = "low", temperature = 0.2},
    },
  },
  -- More than LOW_DEMAND_MAX_PLAYERS players: busy server, cheaper/faster.
  high = {
    planner = {model = "openai/gpt-5.6-luna:nitro", reasoning = "max"},
    coding  = {
      draft  = {model = "google/gemini-3.6-flash", reasoning = "medium", priority = "auto", temperature = 0.4},
      fix    = {model = "google/gemma-4-31b-it:nitro",   reasoning = "medium", temperature = 0.2},
    },
  },
}

-- No singleton guard at the top of this file: it would return the cached table
-- before the new CONFIGS above was ever built, so model edits would appear to do
-- nothing until a full map change. Reuse the existing table instead (keeping any
-- hook closures pointing at a live object) and refresh its methods on re-include.
local Demand = _G.GilbDemand or {}
Demand.__index = Demand

--- "low" or "high", from the live player count.
function Demand:tier()
  return player.GetCount() <= LOW_DEMAND_MAX_PLAYERS and "low" or "high"
end

--- The config for the current tier:
--- { planner = {model, reasoning}, coding = { draft = {model, reasoning}, fix = {...} } }
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
