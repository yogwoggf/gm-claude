-- !mount - mount a Workshop addon so Claude can use its assets.

return {
    trigger = "mount",
    args = {
        {
            name = "addonId",
            type = "string"
        }
    },
    description = "Mount a Workshop addon by ID.",
    keepInChat = true,

    run = function(ply, args)
        local addonId = string.Trim(args.addonId or "")
        if addonId == "" then
            ply:ChatPrint("Please provide a valid Workshop addon ID. Usage: !mount <addon_id>")
            return
        end

        ply:ChatPrint("Attempting to mount Workshop addon with ID: " .. addonId)
        mount.WorkshopAddon(addonId)
    end
}
