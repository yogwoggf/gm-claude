-- !timeout - bar a player from chat entirely for a while.

local OWNER = "STEAM_0:1:104828323"
local timedOut = {} -- [player] = CurTime() it lifts

local command
command = {
    trigger = "timeout",
    args = {
        {
            name = "target",
            type = "string"
        },
        {
            name = "duration",
            type = "string"
        }
    },
    description = "Time a player out of chat. Duration is like 30s or 10m.",
    keepInChat = true,

    -- Seconds left, or 0. The chat hook gates every line on this.
    remaining = function(ply)
        local lifts = timedOut[ply]
        if not lifts then return 0 end
        if CurTime() >= lifts then
            timedOut[ply] = nil
            return 0
        end

        return math.ceil(lifts - CurTime())
    end,

    run = function(ply, args)
        if ply:SteamID() ~= OWNER then
            ply:ChatPrint("You don't have permission to use this command.")
            return
        end

        if not args.target or not args.duration then
            ply:ChatPrint("Invalid command format. Usage: !timeout <player> <duration>")
            return
        end

        local target
        for _, p in pairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), string.lower(args.target), 1, true) then
                target = p
                break
            end
        end

        if not target then
            ply:ChatPrint("Player not found: " .. args.target)
            return
        end

        if command.remaining(target) > 0 then
            ply:ChatPrint("Player is already timed out: " .. target:Nick())
            return
        end

        local unit = args.duration:sub(-1)
        local amount = tonumber(args.duration:sub(1, -2))
        if not amount or (unit ~= "s" and unit ~= "m") then
            ply:ChatPrint("Invalid duration format. Use 's' for seconds or 'm' for minutes. Example: 30s or 10m")
            return
        end

        timedOut[target] = CurTime() + amount * (unit == "m" and 60 or 1)
        ply:ChatPrint("Timed out player " .. target:Nick() .. " for " .. args.duration)
    end
}

return command
