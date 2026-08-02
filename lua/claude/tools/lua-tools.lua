-- The realm-specific Lua execution tools.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")
---@module "lua.claude.mock.init"
local mock = include("claude/mock/init.lua")
---@module "lua.claude.services.memory"
local memory = include("claude/services/memory.lua")

-- The sandbox already bounds captured print per line/line-count; this bounds the
-- total, since even 60 tight lines re-sent every round adds up in the transcript.
local OUTPUT_TOTAL_MAX = 3500

-- A successful run shorter than this is a probe/scout snippet, not the build —
-- it must not downgrade the draft model (the real build hasn't been written yet).
local DRAFT_SPENT_MIN_BYTES = 400

local function capOutput(printed)
  if not printed or #printed == 0 then return nil end
  if #printed > OUTPUT_TOTAL_MAX then
    return string.sub(printed, 1, OUTPUT_TOTAL_MAX) .. "\n...(output truncated - print less next time)"
  end
  return printed
end

--- Lessons onto an error already being sent.
local function withMemories(agent, errorText, code)
  local ok, block, ids = pcall(memory.blockForError, memory, agent.kind, errorText, code)
  if not ok or not block then return errorText end
  agent.pendingMemoryIds = ids
  return errorText .. block
end

--- Score the last injection.
local function settleMemories(agent, succeeded)
  if not agent.pendingMemoryIds then return end
  local ids = agent.pendingMemoryIds
  agent.pendingMemoryIds = nil
  pcall(memory.reward, memory, ids, succeeded)
end

--- Score the pre-gen injection once, against the
--- first REAL build attempt. Probe snippets say
--- nothing about whether the hints helped.
local function settleProactive(agent, codeLen, succeeded)
  if not agent.proactiveMemoryIds then return end
  if codeLen < DRAFT_SPENT_MIN_BYTES then return end
  local ids = agent.proactiveMemoryIds
  agent.proactiveMemoryIds = nil
  pcall(memory.reward, memory, ids, succeeded, "proactive")
end

local function makeRunner(realm, name, description)
  return Tool.new({
    name = name,
    description = description,
    parameters = {
      type = "object",
      properties = {
        code = {
          type = "string",
          description = "The complete GMod Lua to execute in this realm, in one piece."
        }
      },
      required = {"code"}
    },
    coerceArg = "code",
    run = function(args, done, agent)
      if not args.code or args.code == "" then
        done({success = false, error = "No code was provided, follow the schema."})
        return
      end

      local sandbox = agent.api.sandbox
      if not sandbox then
        done({success = false, error = "Sandbox is unavailable on the server."})
        return
      end

      print(string.format("[gm-claude] Agent %s running %s Lua (%d bytes)", agent.id, realm, #args.code))

      -- Before-half of a repair pair.
      local priorError, priorCode = agent.lastError, agent.lastErrorCode

      -- Attribute the code to the shared promptId (not the ephemeral agent id) so
      -- error chunk-names and history grouping line up across a prompt's coders.
      local ok, err, printed = sandbox:run(args.code, agent.promptId, realm)
      agent.ranLua = true
      -- Anything the code printed comes back with the result, so the agent can
      -- actually inspect what happened instead of only learning whether it threw.
      local output = capOutput(printed)

      if ok then
        history:record(agent.promptId, realm, args.code)
        -- Also keep a per-agent record of what THIS agent ran, reconstructed later.
        agent.ranChunks = agent.ranChunks or {}
        table.insert(agent.ranChunks, {realm = realm, code = args.code})

        -- If the code loaded, exercise it to see if it actually works.
        mock:exercise(agent.promptId, function(errors)
          if #errors > 0 then
            local parts = {}
            for _, e in ipairs(errors) do
              parts[#parts + 1] = e.detail or e.err
            end
            agent.lastError = table.concat(parts, "\n\n")
            agent.lastErrorCode = args.code
            settleMemories(agent, false)
            settleProactive(agent, #args.code, false)
            done({success = false, output = output, error = withMemories(agent,
              "The code loaded, but exercising it triggered runtime error(s):\n" .. agent.lastError ..
              "\n\nFix the cause and re-run the corrected code.", args.code)})
          else
            agent.lastError = nil
            agent.lastErrorCode = nil
            settleMemories(agent, true)
            settleProactive(agent, #args.code, true)

            -- Verified: loaded clean + survived.
            if priorError and priorCode then
              agent.repairPairs = agent.repairPairs or {}
              table.insert(agent.repairPairs, {
                error = priorError,
                broken = priorCode,
                fixed = args.code,
              })
            end
            -- Only NOW is the draft spent: a substantial build loaded clean and
            -- survived the exercise. A failed run keeps the strong model on the
            -- job — the cheap fix model is for narrow error-driven iteration after
            -- a working build, not for rescuing a draft that never landed.
            if agent.onDraftComplete and #args.code >= DRAFT_SPENT_MIN_BYTES then
              agent:onDraftComplete()
            end
            done({success = true, output = output})
          end
        end)
      else
        agent.lastError = tostring(err or "unknown error")
        agent.lastErrorCode = args.code
        settleMemories(agent, false)
        settleProactive(agent, #args.code, false)
        done({success = false, output = output, error = withMemories(agent, agent.lastError, args.code)})
      end
    end
  })
end

return {
  server = makeRunner("server", "run_server_lua",
    "Runs GMod Lua on the SERVER only, immediately. Use for entities, spawning, hooks, physics, health/gravity, and game logic — anything that isn't visual/UI. Write the complete Lua in one call, and append your verification `print(...)` probes to the END of the SAME call (trace results, entity state, positions) — the output comes back with the result so you can VERIFY behavior without spending an extra call. Fix and re-run on error."),

  client = makeRunner("client", "run_client_lua",
    "Runs GMod Lua on EVERY client, immediately. Use for HUDs, VGUI/Derma, client-side effects, sounds, and screen effects. Write the complete Lua in one call. Note: client-side errors cannot be reported back, so get it right (validate assets first). Returns once broadcast."),

  shared = makeRunner("shared", "run_shared_lua",
    "Runs GMod Lua on BOTH the server and every client from a SINGLE call — this is how you make SWEPs and SENTs, which MUST be defined in both realms. Put the ENTIRE definition (the full SWEP/ENT table plus its weapons.Register / scripted_ents.Register) in one run_shared_lua call. Never split an entity across realms or across calls — clients will get a broken, half-defined entity. The server runs it first; if it errors, nothing is sent to clients, so fix and re-run. Append your verification `print(...)` probes to the END of this same call — the server-side output comes back with the result, so you VERIFY behavior without spending an extra call."),
}
