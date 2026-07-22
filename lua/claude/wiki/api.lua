local API_ROOT_URL = "https://gmodwiki.com/websearch.json?query="
local FACEPUNCH_ROOT_URL = "https://wiki.facepunch.com/gmod/"
local TOP_K = 5

local function urlEncode(string)
  if string.find(string, "\n") then
    string = string.gsub(string, "\n", "\r\n")
  end
  string = string.gsub(string, "([^%w ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  string = string.gsub(string, " ", "+")
  return string
end

local function normalizeSearchResult(result)
    return {
        address = result.address,
        description = result.snippet,
    }
end

local function isValidSearchResult(result)
    if not result then
        return false
    end

    return result.source == "both" or result.source == "semantic"
end

local function getSignatureForSearchResult(result, callback)
    -- We need to fetch the detailed data from the wiki,
    -- check if it's a function, then pull the markup and pass it to the
    -- LLM. Quite complicated.

    http.Fetch(FACEPUNCH_ROOT_URL .. result.address .. "?format=json", function(body)
        local result = util.JSONToTable(body)
        if result and result.tags and result.tags:find("function") then
            callback(result.markup)
        else
            callback(nil)
        end
    end, function(err)
        print("[gm-claude] Error fetching signature for search result:", err)
        callback(nil)
    end)
end

local function fetchSemanticSearchResults(query, callback)
    local url = API_ROOT_URL .. urlEncode(query)
    http.Fetch(url, function(body)
        local results = util.JSONToTable(body)
        if not results then
            print("[gm-claude] Error parsing semantic search results: invalid JSON")
            callback({})
            return
        end

        local normalizedResults = {}
        for i, result in ipairs(results) do
            if i > TOP_K then break end
            if not isValidSearchResult(result) then
                continue
            end

            table.insert(normalizedResults, normalizeSearchResult(result))
        end

        -- Fetch all the signatures for the results, then call the callback with the final results.
        local remaining = #normalizedResults
        for i, result in ipairs(normalizedResults) do
            getSignatureForSearchResult(result, function(signature)
                if signature then
                    result.signature = signature
                end

                remaining = remaining - 1
                if remaining == 0 then
                    callback(normalizedResults)
                end
            end)
        end
    end, function(err)
        print("[gm-claude] Error fetching semantic search results:", err)
        callback({})
    end)
end

return {
    fetchSemanticSearchResults = fetchSemanticSearchResults,
}