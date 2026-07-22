-- The dynamic prompt is a dynamically changing system prompt with
-- instructions for the AI so it can adapt to the current state of the game and provide better responses.

local DYNAMIC_PROMPT_TEMPLATE = [[
--- LIVE GAME STATE ---
Playing on map: %s
Current player count: %d
List of current players: %s
--- END OF GAME STATE ---
]]

local function getPlayerInformation()
    local playerEntries = {}
    for _, ply in pairs(player.GetAll()) do
        table.insert(playerEntries, string.format("%s (UserID: %d)", ply:Nick(), ply:UserID()))
    end
    return table.concat(playerEntries, ", ")
end

return function()
    return string.format(DYNAMIC_PROMPT_TEMPLATE,
        game.GetMap() or "unknown",
        #player.GetAll(),
        getPlayerInformation()
    )
end