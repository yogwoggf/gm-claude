-- Builds the shared "you are editing existing code" block injected into both the
-- planner and the coding agents when a request arrives via !edit.

local REALM_LABEL = {
  server = "SERVER",
  client = "CLIENT",
  shared = "SHARED (SWEP/SENT — both realms)",
}

--- @param ctx table { originalPrompt = string, artifacts = { {realm, code}, ... } }
return function(ctx)
  local lines = {
    "You are EDITING an existing creation, NOT building from scratch.",
    "",
    "Original request that created it: " .. tostring(ctx.originalPrompt),
    "",
    "The exact Lua that is currently live is shown below, one block per piece.",
    "Apply ONLY the requested change and keep everything else identical. Re-run the",
    "COMPLETE creation — every piece below, in its proper run_*_lua call, including",
    "the pieces you are NOT changing — so the live state stays whole. Reuse the same",
    "hook names, timer names, and entity classes so they overwrite in place, and",
    "explicitly hook.Remove / timer.Remove anything you are dropping so nothing from",
    "the old version keeps running.",
  }

  for i, art in ipairs(ctx.artifacts or {}) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("--- current piece #%d [%s] ---", i, REALM_LABEL[art.realm] or art.realm)
    lines[#lines + 1] = art.code
  end

  return table.concat(lines, "\n")
end
