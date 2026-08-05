-- !edit - revise something you already built.

local history = include("claude/history.lua")
local prompt = include("claude/commands/prompt.lua")

return {
    trigger = "edit",
    args = {
        {
            name = "index",
            type = "number"
        },
        {
            name = "change",
            type = "string",
            consumeAll = true
        }
    },
    description = "Revise one of your recent creations. !edit alone lists them.",

    run = function(ply, args)
        local recent = history:list(ply)

        if not args.index then
            if #recent == 0 then
                ply:ChatPrint("You have nothing to edit yet - make something with !c first.")
                return
            end

            ply:ChatPrint("Your recent creations - use !edit <number> <change>:")
            for i, rec in ipairs(recent) do
                ply:ChatPrint(string.format("  %d. %s", i, rec.prompt))
            end
            return
        end

        local change = string.Trim(args.change or "")
        if change == "" then
            ply:ChatPrint("Usage: !edit <number> <what to change>  (e.g. !edit 2 make more explosions). Send !edit alone to list.")
            return
        end

        local rec = recent[args.index]
        if not rec then
            ply:ChatPrint("No creation #" .. args.index .. " in your recent list. Send !edit to see it.")
            return
        end

        ply:ChatPrint(string.format('Editing "%s"...', rec.prompt))
        prompt.start(ply, change, {
            promptId = rec.promptId, -- reuse the id so the rebuild overwrites the original
            editContext = {originalPrompt = rec.prompt, artifacts = rec.artifacts}
        })
    end
}
