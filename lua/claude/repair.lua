-- Tries to initiate prompt repairs on the fly if
-- they error at runtime

local repair = {}
repair.idToLua = {}
repair.errorIdBuckets = {}
repair.REPAIR_THRESHOLD = 3 -- how many times an error has to occur for the same prompt before we try to repair it
repair.api = nil
repair.sandbox = nil

function repair:initialize(api, sandbox)
    self.api = api
    self.sandbox = sandbox
end

function repair:add(promptId, prompt, player, luaCode)
    self.idToLua[promptId] = {prompt, player, luaCode, false}
end

function repair:isAi(ident)
    return self.idToLua[ident] ~= nil
end

function repair:logError(promptId, error)
    if not self.errorIdBuckets[promptId] then
        self.errorIdBuckets[promptId] = {}
    end

    self.errorIdBuckets[promptId][error] = (self.errorIdBuckets[promptId][error] or 0) + 1
end

function repair:getRepairPrompt(promptId, error)
    -- Basically, we'll just tell it
    -- 1. Here's an error
    -- 2. Here's the original prompt
    -- 3. Here's the original Lua code you generated
    -- And then ask it to try to fix and then re-run the Lua code to achieve the same goal as the original prompt, but without the error

    return string.format([[
The following Lua code was generated in response to a prompt, but it caused this error when we tried to run it:
```
%s
```
Here is the original prompt that was given to you:
```
%s
```

Here is the original Lua code that you generated:
```
%s
```

Generate a fixed version of the Lua code that achieves the same goal as the original prompt, but does not cause the error. Only provide the fixed Lua code in your response, and nothing else.
    ]], error, self.idToLua[promptId][1], self.idToLua[promptId][3])
end

function repair:tryRepair(id, err)
    if not self.idToLua[id] then
        print("[gm-claude] No original prompt or Lua code found for prompt ID: " .. id)
        return
    end

    if self.idToLua[id][4] then
        print("[gm-claude] Prompt ID " .. id .. " is already being repaired. Not attempting another repair simultaneously.")
        return
    end
    
    self:logError(id, err)

    if self.errorIdBuckets[id][err] < self.REPAIR_THRESHOLD then
        print(string.format("[gm-claude] Error for prompt ID %s has occurred %d times. Not repairing yet.", id, self.errorIdBuckets[id][err]))
        return
    end

    print(string.format("[gm-claude] Error for prompt ID %s has occurred %d times. Attempting repair...", id, self.errorIdBuckets[id][err]))
    
    self.idToLua[id][4] = true -- mark as being repaired to avoid multiple simultaneous repair attempts for the same prompt ID
    local api, sandbox = self.api, self.sandbox
    local repairPrompt = self:getRepairPrompt(id, err)
    api:sendPrompt(self.idToLua[id][2], repairPrompt, function(repairedLuaCode)
        print("[gm-claude] Received repaired Lua code from API: " .. repairedLuaCode)
        local success, errMsg = sandbox:run(repairedLuaCode, id .. "-repair")
        if not success then
            print("[gm-claude] Repair attempt failed for prompt ID " .. id .. ". Error: " .. tostring(errMsg))
        else
            print("[gm-claude] Repair attempt succeeded for prompt ID " .. id)
        end
    end, "google/gemini-3-flash-preview:nitro") -- Gemini always, Kimi won't be good at repair.
end

hook.Add("OnLuaError", "claude.repair", function(err, realm, stack)
    local entry = nil
    for _, frame in ipairs(stack) do
        if repair:isAi(frame.File) then
            entry = frame
            break
        end
    end
       
    if entry then
        print("[gm-claude] Lua error detected from AI-generated code. Prompt ID: " .. entry.File .. ". Error: " .. err)
        repair:tryRepair(entry.File, err)
    end
end)

return repair