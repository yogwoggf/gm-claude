local command
command = {
    trigger = "removeclienthooks",
    description = "Ask clients to remove all hooks registered by Claude.",
    keepInChat = true,

    initialize = function(deps)
        command.sandbox = deps.sandbox
    end,

    run = function(ply)
        command.sandbox:removeClientHooks()
        ply:ChatPrint("Requested clients to remove all hooks registered by Claude.")
    end
}

return command
