return {
    API_URL = "http://gmod-exporter:9115/event",

    sendHeartbeat = function(self)
        local data = {
            type = "heartbeat",
            data = {
                players = #player.GetAll(),
                map = game.GetMap(),
            }
        }

        HTTP({
            method = "POST",
            url = self.API_URL,
            headers = {
                ["Content-Type"] = "application/json"
            },
            body = util.TableToJSON(data)
        }, function(code, body, headers)
            if code ~= 200 then
                print("[gm-claude] Failed to send heartbeat: " .. tostring(code))
            end
        end)
    end,
    
    sendPrompt = function(self, prompt, player)
        local data = {
            type = "prompt",
            data = {
                playerId = player:SteamID(),
                prompt = prompt
            }
        }

        print("[gm-claude] Sending prompt analytics for player " .. player:Nick() .. ": " .. prompt)
        HTTP({
            method = "POST",
            url = self.API_URL,
            headers = {
                ["Content-Type"] = "application/json"
            },
            body = util.TableToJSON(data)
        }, function(code, body, headers)
            if code ~= 200 then
                print("[gm-claude] Failed to send prompt analytics: " .. tostring(code))
            else
                print("[gm-claude] Successfully sent prompt analytics for player " .. player:Nick())
            end
            print("[gm-claude] Analytics API response: " .. tostring(body))
        end)
    end
}