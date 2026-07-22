-- Receives the current server demand tier ("low" / "high") and stashes it in a
-- global the HUD reads. Sent by claude/demand.lua on join and whenever the player
-- count crosses the threshold.

_G.ClaudeDemand = _G.ClaudeDemand or "low"

net.Receive("claude.demand", function()
  _G.ClaudeDemand = net.ReadString()
end)
