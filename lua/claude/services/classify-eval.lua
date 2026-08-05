-- Tests the classify service against a set of known cases, really helpful
-- for identifying regressions and such.

-- Note most of this was vibed, it's not used in production.

---@module "lua.claude.services.classify"
local classify = include("claude/services/classify.lua")

-- {request, primary, secondary...}. Labels are the deliverable-vs-supporting
-- reading: the container wins, and a secondary is only listed when the build
-- genuinely needs that technique.
local CASES = {
  {"make everything look like a VHS tape", "shader"},
  {"volumetric clouds over the map", "shader"},
  {"god rays through the windows", "shader"},
  {"a kaleidoscope filter on my screen", "shader"},
  {"make the world look underwater", "shader"},
  {"heat haze coming off the ground", "shader"},

  {"a crystal prop that dissolves when shot", "sent", "shader"},
  {"a hologram entity that flickers", "sent", "shader"},
  {"spawnable force field bubble", "sent", "shader"},
  {"a prop with an iridescent oil slick finish", "sent", "shader"},
  {"a statue that slowly melts", "sent", "shader"},
  {"a turret that shoots lasers", "sent", "effect"},
  {"a vending machine that dispenses props", "sent"},

  {"a sword that makes enemies disintegrate", "swep", "shader"},
  {"a gun with a holographic sight", "swep", "shader"},
  {"a shotgun that fires exploding barrels", "swep", "effect"},
  {"a rifle with a scope", "swep"},
  {"a gun that pixelates the screen", "swep", "shader"},

  {"glowing red lamp", "effect"},
  {"spawn some fireworks", "effect"},
  {"a lightning storm", "effect"},
  {"smoke trail behind the player", "effect"},

  {"a scoreboard showing kills", "ui"},
  {"health bar over players heads", "ui"},

  {"teleport everyone to spawn", "logic"},
  {"make it rain money every 30 seconds", "logic"},
  {"give the player x-ray vision", "shader"},
  {"a wireframe view of the map", "shader"},
  {"make a double jump with a shader effect", "logic", "shader"},

  {"epic looking clouds", "shader"},
  {"trippy screen effect", "shader"},
  {"make everything look shiny and wet", "shader"},
  {"sick laser gun", "swep", "effect"},
  {"cool explosion", "effect"},
  {"make my hud look better", "ui"},
  {"spawn a bunch of zombies", "logic"},
  {"a car that goes really fast", "sent"},
  {"gimme something that looks like tron", "shader"},
  {"make the sky crazy", "shader"},
}

local function expectedSet(case)
  local set = {}
  for i = 3, #case do set[case[i]] = true end
  return set
end

local function score(caps, case)
  local exp = expectedSet(case)
  local got = {}
  for _, k in ipairs(caps.secondary or {}) do got[k] = true end

  local hit, extra, missed = 0, 0, 0
  for k in pairs(exp) do if got[k] then hit = hit + 1 else missed = missed + 1 end end
  for k in pairs(got) do if not exp[k] then extra = extra + 1 end end
  return caps.primary == case[2], hit, extra, missed
end

local function report(rows, label)
  local n = math.max(#rows, 1)
  local okPrimary, hit, extra, missed = 0, 0, 0, 0
  for _, r in ipairs(rows) do
    if r.primaryOk then okPrimary = okPrimary + 1 end
    hit, extra, missed = hit + r.hit, extra + r.extra, missed + r.missed
    if not r.primaryOk or r.extra > 0 or r.missed > 0 then
      print(string.format("  %-46s want %-7s got %-7s %s", r.text, r.want, r.got,
        (r.extra > 0 or r.missed > 0)
          and string.format("(secondary +%d -%d)", r.extra, r.missed) or ""))
    end
  end
  local recall = (hit + missed) > 0 and (hit / (hit + missed)) or 1
  local precision = (hit + extra) > 0 and (hit / (hit + extra)) or 1
  print(string.format(
    "[%s] primary %d/%d = %d%% | secondary recall %d%% precision %d%%",
    label, okPrimary, n, math.floor(okPrimary / n * 100 + 0.5),
    math.floor(recall * 100 + 0.5), math.floor(precision * 100 + 0.5)))
end

concommand.Add("claude_classify_eval", function(ply, _, args)
  if IsValid(ply) and not ply:IsSuperAdmin() then return end
  local useModel = args[1] == "model"

  print(string.format("[gm-claude] Classification eval over %d cases (%s)",
    #CASES, useModel and "MODEL" or "keyword fallback"))
  print("[gm-claude] Only mismatches are listed.")

  if not useModel then
    local rows = {}
    for _, case in ipairs(CASES) do
      local caps = classify:fallback(case[1])
      local pOk, hit, extra, missed = score(caps, case)
      rows[#rows + 1] = {text = case[1], want = case[2], got = caps.primary,
        primaryOk = pOk, hit = hit, extra = extra, missed = missed}
    end
    report(rows, "keyword")
    return
  end

  if not _G.ClaudeAPI then
    print("[gm-claude] No API available; run without 'model' for the keyword baseline")
    return
  end

  local EVAL_TIMEOUT = 90
  local rows, done = {}, 0
  local n = #CASES
  local started = SysTime()

  for idx, case in ipairs(CASES) do
    classify:capabilities(_G.ClaudeAPI, case[1], function(caps, source)
      local pOk, hit, extra, missed = score(caps, case)
      rows[idx] = {text = case[1], want = case[2], got = caps.primary,
        primaryOk = pOk, hit = hit, extra = extra, missed = missed, source = source}

      done = done + 1
      if done % 10 == 0 then
        print(string.format("[gm-claude]   %d/%d ...", done, n))
      end
      if done < n then return end

      -- Compact the sparse array; callbacks land out of order.
      local ordered, fellBack = {}, 0
      for i = 1, n do
        if rows[i] then
          ordered[#ordered + 1] = rows[i]
          if rows[i].source ~= "model" then fellBack = fellBack + 1 end
        end
      end
      print(string.format("[gm-claude] Finished in %.1fs", SysTime() - started))
      if fellBack > 0 then
        print(string.format("[gm-claude] WARNING: %d/%d fell back to keywords - " ..
          "those rows measure the fallback, not the model", fellBack, n))
      end
      report(ordered, "model")
    end, EVAL_TIMEOUT)
  end

end, nil, "Score capability classification. Usage: claude_classify_eval [model]")
