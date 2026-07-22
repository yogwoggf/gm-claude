-- The realm-specific Lua execution tools.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")
---@module "lua.claude.history"
local history = include("claude/history.lua")
---@module "lua.claude.mock.init"
local mock = include("claude/mock/init.lua")

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
        done({success = false, error = "No code was provided."})
        return
      end

      local sandbox = agent.api.sandbox
      if not sandbox then
        done({success = false, error = "Sandbox is unavailable on the server."})
        return
      end

      print(string.format("[gm-claude] Agent %s running %s Lua (%d bytes)", agent.id, realm, #args.code))
      -- Attribute the code to the shared promptId (not the ephemeral agent id) so
      -- error chunk-names and history grouping line up across a prompt's coders.
      local ok, err = sandbox:run(args.code, agent.promptId, realm)
      agent.ranLua = true

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
            done({success = false, error =
              "The code loaded, but exercising it triggered runtime error(s):\n" .. agent.lastError ..
              "\n\nFix the cause and re-run the corrected code."})
          else
            agent.lastError = nil
            done({success = true})
          end
        end)
      else
        agent.lastError = tostring(err or "unknown error")
        done({success = false, error = agent.lastError})
      end
    end
  })
end

return {
  server = makeRunner("server", "run_server_lua",
    "Runs GMod Lua on the SERVER only, immediately. Use for entities, spawning, hooks, physics, health/gravity, and game logic — anything that isn't visual/UI. Write the complete Lua in one call. Returns whether it worked; fix and re-run on error."),

  client = makeRunner("client", "run_client_lua",
    "Runs GMod Lua on EVERY client, immediately. Use for HUDs, VGUI/Derma, client-side effects, sounds, and screen effects. Write the complete Lua in one call. Note: client-side errors cannot be reported back, so get it right (validate assets first). Returns once broadcast."),

  shared = makeRunner("shared", "run_shared_lua",
    "Runs GMod Lua on BOTH the server and every client from a SINGLE call — this is how you make SWEPs and SENTs, which MUST be defined in both realms. Put the ENTIRE definition (the full SWEP/ENT table plus its weapons.Register / scripted_ents.Register) in one run_shared_lua call. Never split an entity across realms or across calls — clients will get a broken, half-defined entity. The server runs it first; if it errors, nothing is sent to clients, so fix and re-run."),
}
