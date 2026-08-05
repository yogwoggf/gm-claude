-- Guarded: the chatbox includes this for the command manifest, and a second copy
-- would be an empty registry. Set before anything else so a command file that
-- includes the runner back cannot re-enter.
if _G.GilbCommandRunner then return _G.GilbCommandRunner end

local runner = {}
runner.commands = {}
_G.GilbCommandRunner = runner

function runner.trigger(text)
    return text:Split(" ")[1]:sub(2)
end

local function coerce(argumentInfo, raw)
    if argumentInfo.type == "number" then
        local number = tonumber(raw)
        if not number then
            return nil, string.format("%s must be a number, got %q", argumentInfo.name, raw)
        end

        return number
    end

    return raw
end

function runner.parse(text)
    local parts = text:Split(" ")
    local trigger = runner.trigger(text)

    local commandInfo = runner.commands[trigger]
    if not commandInfo then
        return nil, "Unknown command: " .. trigger
    end

    local arguments = {}
    if not commandInfo.args then
        return commandInfo, arguments
    end

    for i = 2, #parts do
        local argumentIndex = i - 1
        local argumentInfo = commandInfo.args[argumentIndex]
        if not argumentInfo then
            return nil, "Too many arguments for command: " .. trigger
        end

        local consumeAll = argumentInfo.consumeAll
        local value, err = coerce(argumentInfo, consumeAll and table.concat(parts, " ", i) or parts[i])
        if err then
            return nil, err
        end

        arguments[argumentInfo.name] = value
        if consumeAll then break end
    end

    return commandInfo, arguments
end

function runner.register(command)
    if not command.trigger or not command.run then
        error("Invalid command registration: missing trigger or run function")
    end

    runner.commands[command.trigger] = command
end

function runner.loadAll(deps)
    for _, f in ipairs(file.Find("claude/commands/*.lua", "LUA")) do
        if f ~= "runner.lua" then
            local command = include("claude/commands/" .. f)
            if command.initialize then command.initialize(deps) end
            runner.register(command)
        end
    end
end

--- @return boolean handled, string|table errorOrCommand
function runner.consume(player, chat)
    local commandInfo, arguments = runner.parse(chat)
    if not commandInfo then
        return false, arguments -- arguments contains the error message in this case
    end

    local success, errorMessage = pcall(commandInfo.run, player, arguments)
    if not success then
        return false, "Error executing command: " .. errorMessage
    end

    return true, commandInfo
end

--- The parts of the registry a client needs to highlight and autocomplete:
--- names and arg shapes, never the run functions.
function runner.manifest()
    local out = {}
    for trigger, command in pairs(runner.commands) do
        local args = {}
        for i, arg in ipairs(command.args or {}) do
            args[i] = {name = arg.name, type = arg.type, consumeAll = arg.consumeAll}
        end
        out[#out + 1] = {
            trigger = trigger,
            description = command.description,
            args = args,
        }
    end

    table.sort(out, function(a, b) return a.trigger < b.trigger end)
    return out
end

return runner
