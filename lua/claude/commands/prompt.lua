-- !c - send a prompt to GilbLM and build whatever comes back.
if _G.GilbPromptCommand then return _G.GilbPromptCommand end

local COOLDOWN = 30
local lastPromptTime = {} -- [player] = CurTime() of their last accepted prompt

local command
command = {
    trigger = "c",
    args = {
        {
            name = "prompt",
            type = "string",
            consumeAll = true
        }
    },
    description = "Send a prompt to GilbLM.",
    keepInChat = true,

    -- api and analytics are injected rather than included.
    initialize = function(deps)
        command.api = deps.api
        command.analytics = deps.analytics
    end,

    start = function(ply, prompt, opts)
        lastPromptTime[ply] = lastPromptTime[ply] or -COOLDOWN
        if CurTime() - lastPromptTime[ply] < COOLDOWN then
            local timeLeft = math.ceil(COOLDOWN - (CurTime() - lastPromptTime[ply]))
            ply:ChatPrint("Please wait " .. timeLeft .. " seconds before sending another prompt.")
            return false
        end
        lastPromptTime[ply] = CurTime()

        ply:ChatPrint("Sending your request to GilbLM...")
        print("[gm-claude] Sending prompt to API: " .. prompt)
        ply:SendLua("ChangeClaudeStatus('thinking')")
        print("[gm-claude] Sending analytics for prompt...")
        command.analytics:sendPrompt(prompt, ply)
        command.api:sendPrompt(ply, prompt, function(result, promptId)
            -- The planner + coding agents already executed everything via run_lua,
            -- and the coders self-correct on errors, so there's nothing to run here.
            ply:SendLua("ChangeClaudeStatus('idle')")
            print("[gm-claude] Prompt " .. tostring(promptId) .. " finished.")
            if type(result) == "string" and #result > 0 then
                net.Start("claude.chat")
                net.WriteString(result)
                net.Send(ply)
            end
        end, opts)
        return true
    end,

    run = function(ply, args)
        local prompt = string.Trim(args.prompt or "")
        if prompt == "" then
            ply:ChatPrint("Usage: !c <what you want built>")
            return
        end

        if prompt:lower():find("kanye") then
            ply:ChatPrint("Fuck you.")
            ply:Kill()
            return
        end

        command.start(ply, prompt)
    end
}

_G.GilbPromptCommand = command
return command
