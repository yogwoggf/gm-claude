-- Wiki search tool, uses semantic search to find relevant results and returns them to the agent.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")

---@module "lua.claude.wiki.api"
local wikiApi = include("claude/wiki/api.lua")

-- If longer than this, wiki is probably down
local WIKI_TOOL_TIMEOUT = 60

return Tool.new({
    name = "search_wiki",
    timeout = WIKI_TOOL_TIMEOUT,
    description = "Search the Garry's Mod wiki for relevant information. Uses **semantic search** to find the most relevant results. Returns a list of results with their address, description, and signature (if applicable). Query a brief sentence or phrase.",
    parameters = {
        type = "object",
        properties = {
            query = {
                type = "string",
                description = "The search query to send to the wiki."
            }
        },
        required = {"query"}
    },
    coerceArg = "query",
    run = function(args, done, agent)
        local query = args.query
        if not query or query == "" then
            done({error = "No query was provided."})
            return
        end

        print("[gm-claude] wiki_search tool called with query: " .. query)
        wikiApi.fetchSemanticSearchResults(query, function(results)
            print("[gm-claude] wiki_search tool received " .. tostring(#results) .. " result(s)")
            done({results = results})
        end)
    end
})
