-- Playbook registry. The planner tags each dispatched task with a `kind`; the
-- coding agent loads ONLY that playbook, so deep per-capability guidance costs
-- nothing on prompts that don't need it.

local Playbooks = {}

Playbooks.byKind = {
  swep   = include("claude/prompts/playbooks/swep.lua"),
  sent   = include("claude/prompts/playbooks/sent.lua"),
  effect = include("claude/prompts/playbooks/effect.lua"),
  ui     = include("claude/prompts/playbooks/ui.lua"),
  logic  = include("claude/prompts/playbooks/logic.lua"),
}

-- Kinds the planner may pick, for the tool schema enum.
Playbooks.kinds = {"swep", "sent", "effect", "ui", "logic"}

--- The playbook text for a kind, defaulting to `logic` for an unknown/missing tag
--- (the model can always emit something off-schema; never leave the coder bare).
--- @param kind string|nil
--- @return string
function Playbooks.get(kind)
  return Playbooks.byKind[kind] or Playbooks.byKind.logic
end

return Playbooks
