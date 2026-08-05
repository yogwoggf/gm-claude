return {
    trigger = "goto",
    args = {
        {
            name = "target",
            type = "string"
        }
    },
    description = "Teleport to a target player.",
    keepInChat = true,

    run = function(ply, args)
        local targetName = args.target
        if not targetName or targetName == "" then
            ply:ChatPrint("Usage: !goto <target player name>")
            return
        end

        local targetPlayer = nil
        for _, p in ipairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), string.lower(targetName), 1, true) then
                targetPlayer = p
                break
            end
        end

        if not targetPlayer then
            ply:ChatPrint("No player found with name containing: " .. targetName)
            return
        end

        ply:SetPos(targetPlayer:GetPos() + Vector(0, 0, 80)) -- Teleport above the target player to avoid collision.
        ply:ChatPrint("Teleported to " .. targetPlayer:Nick())
    end
}