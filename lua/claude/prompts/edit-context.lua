-- Builds the shared "you are editing existing code" block injected into both the
-- planner and the coding agents when a request arrives via !edit.

local REALM_LABEL = {
  server = "SERVER",
  client = "CLIENT",
  shared = "SHARED (SWEP/SENT — both realms)",
}

--- @param ctx table { originalPrompt = string, artifacts = { {realm, code} | {shader, name, material, code}, ... } }
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

  local hasShader = false
  for _, art in ipairs(ctx.artifacts or {}) do
    if art.shader then hasShader = true break end
  end

  if hasShader then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "This creation includes a compiled SHADER, shown below as HLSL. Re-run"
    lines[#lines + 1] = "compile_shader for EVERY shader piece, even ones you are not changing —"
    lines[#lines + 1] = "identical source is cached and costs almost nothing, and the client needs it"
    lines[#lines + 1] = "mounted before your Lua calls Material()."
    lines[#lines + 1] = "IMPORTANT: the material path contains a hash of the source. If you change one"
    lines[#lines + 1] = "character of HLSL you get a DIFFERENT path back — use the path compile_shader"
    lines[#lines + 1] = "returns this time and never the old one shown below."
  end

  for i, art in ipairs(ctx.artifacts or {}) do
    lines[#lines + 1] = ""
    if art.shader then
      lines[#lines + 1] = string.format("--- current piece #%d [SHADER HLSL, name %q] ---", i, tostring(art.name))
      lines[#lines + 1] = string.format("-- compiled last time to: %s", tostring(art.material))
    else
      lines[#lines + 1] = string.format("--- current piece #%d [%s] ---", i, REALM_LABEL[art.realm] or art.realm)
    end
    lines[#lines + 1] = art.code
  end

  return table.concat(lines, "\n")
end
