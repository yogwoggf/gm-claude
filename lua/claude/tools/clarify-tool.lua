-- A shared tool that lets an agent pause and ask the player a single clarifying
-- question, then wait for their reply in chat before continuing. Async: it does
-- not call done() until the player answers (or the wait times out), so the
-- agent's loop naturally blocks on the human.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")
---@module "lua.claude.clarify"
local clarify = include("claude/clarify.lua")

-- Must comfortably outlast Clarify's own wait (120s) so the player, not the
-- Agent's hung-tool backstop, is what decides when this call ends.
local CLARIFY_TOOL_TIMEOUT = 150

return Tool.new({
  name = "clarify_with_user",
  timeout = CLARIFY_TOOL_TIMEOUT,
  description = "Ask the player ONE clarifying question and wait for their reply in chat. Use this only when the request is genuinely ambiguous and you cannot proceed sensibly without an answer (e.g. 'Which weapon should I base it on?', 'What color?'). Prefer making a reasonable assumption over asking. Their next chat message is returned as the answer; if they don't reply in time you'll get answered=false and should proceed with your best guess.",
  parameters = {
    type = "object",
    properties = {
      question = {
        type = "string",
        description = "The single, specific question to ask the player. One sentence."
      }
    },
    required = {"question"}
  },
  coerceArg = "question",
  run = function(args, done, agent)
    local question = args.question
    if not question or question == "" then
      done({error = "No question was provided."})
      return
    end

    local player = agent.player
    if not IsValid(player) then
      done({error = "The player is no longer connected; proceed with your best assumption."})
      return
    end

    clarify:ask(player, question, function(answer)
      if answer == nil then
        done({answered = false, note = "The player did not respond in time. Proceed with your best assumption."})
      else
        done({answered = true, answer = answer})
      end
    end)
  end
})
