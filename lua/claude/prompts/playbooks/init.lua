-- Playbook registry. The planner tags each dispatched task with a `kind`; the
-- coding agent loads ONLY that playbook, so deep per-capability guidance costs
-- nothing on prompts that don't need it.

local Playbooks = {}

Playbooks.byKind = {
  swep   = include("claude/prompts/playbooks/swep.lua"),
  sent   = include("claude/prompts/playbooks/sent.lua"),
  effect = include("claude/prompts/playbooks/effect.lua"),
  shader = include("claude/prompts/playbooks/shader.lua"),
  ui     = include("claude/prompts/playbooks/ui.lua"),
  logic  = include("claude/prompts/playbooks/logic.lua"),
}

-- SECONDARY forms. When a capability is supporting rather than the deliverable,
-- this compact version is loaded instead of the full playbook. Only `shader`
-- needs one: it is ~13.8k tokens against 566-1608 for every other playbook, so
-- everything else rides along in full without the bookkeeping.
Playbooks.secondary = {
  shader = include("claude/prompts/playbooks/shader-material.lua"),
}

-- Kinds the planner may pick, for the tool schema enum.
Playbooks.kinds = {"swep", "sent", "effect", "shader", "ui", "logic"}

--- The playbook text for a kind, defaulting to `logic` for an unknown/missing tag
--- (the model can always emit something off-schema; never leave the coder bare).
--- @param kind string|nil
--- @return string
function Playbooks.get(kind)
  return Playbooks.byKind[kind] or Playbooks.byKind.logic
end

--- Full playbook for the primary capability, then the compact form of each
--- secondary. The framing matters as much as the content: without it, stacked
--- playbooks read as equal demands and the coder tries to build all of them.
--- @param primary string
--- @param secondary table|nil array of capability names
--- @return string
function Playbooks.assemble(primary, secondary)
  local parts = {Playbooks.get(primary)}

  for _, kind in ipairs(secondary or {}) do
    if kind ~= primary and Playbooks.byKind[kind] then
      local text = Playbooks.secondary[kind] or Playbooks.byKind[kind]
      parts[#parts + 1] = string.format(
        "The above is your deliverable. What follows is a SUPPORTING capability " ..
        "(%s) this build also needs — a technique available to you, not a second " ..
        "thing to build. Use it in service of the deliverable, and only as far as " ..
        "the request actually calls for.\n\n%s", kind, text)
    end
  end

  return table.concat(parts, "\n\n")
end

return Playbooks
