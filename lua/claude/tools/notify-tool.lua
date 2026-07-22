-- A shared tool that lets any agent (planner or coding) send a short status
-- update to the player who made the request. Purely informational — it just
-- pushes a chat message down the same "claude.chat" channel the client already
-- listens on. Reused across agents, so the calling agent arrives as the 3rd arg.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")

return Tool.new({
  name = "notify_user",
  description = "Sends a short status update to the player who made the request, shown in their chat (e.g. 'Planning your request...', 'Building the SWEP...', 'Spawning props...'). Purely informational — it does not change anything in the game. Use it to keep the player in the loop during longer work; keep messages short and friendly.",
  parameters = {
    type = "object",
    properties = {
      message = {
        type = "string",
        description = "The status message to show the player. One short, friendly sentence."
      }
    },
    required = {"message"}
  },
  coerceArg = "message",
  run = function(args, done, agent)
    local message = args.message
    if not message or message == "" then
      done({success = false, error = "No message was provided."})
      return
    end

    local player = agent.player
    if IsValid(player) then
      net.Start("claude.chat")
      net.WriteString(message)
      net.Send(player)
    end

    done({success = true})
  end
})
