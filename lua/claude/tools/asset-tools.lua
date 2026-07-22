--- The default toolset shared by codegen agents. Returns a list of Tool objects;
--- Tools are stateless, so the same instances are reused across every agent.

---@module "lua.claude.tools.tool"
local Tool = include("claude/tools/tool.lua")

return {
    Tool.new({
        name = "search_files",
        description = "Searches for files in the Garry's Mod VFS. Very useful for finding real models, sounds and materials. Supports paths like `models/*.mdl`." ..
        "\nGlob patterns work like so: `*` matches any sequence of characters, so `models/*.mdl` matches any model with any characters ending in .mdl" ..
        "\nIt does **NOT** support directory globs like `**`, it only does the first directory, but the directories are returned to you if you need them." ..
        "\nThe results are capped to 40 files and 20 directories to avoid abuse, so try to be specific with your search terms! For example, searching `models/props_c17/*.mdl` is more likely to get you the model you want than `models/*.mdl`." ..
        "\nDO *NOT* call is_valid_model or is_valid_material on any result listed here. It is valid if it's listed here, no need to double check. Just use the paths as they are returned here to spawn things or whatever you want to do with them.",
        parameters = {
            type = "object",
            properties = {
                path = {
                    type = "string",
                    description = "The path to search for, with optional wildcards. For example, `models/*.mdl` to search for all models, or `materials/*/*.vtf` to search for all materials. You can also search specific folders like `sound/weapons/`. Don't search for everything in practice, very wasteful."
                }
            },
            required = {"path"}
        },
        coerceArg = "path",
        run = function(args, done)
            if not args.path then
                print("[gm-claude] search_files tool called without a path argument!")
                done({files = {}, directories = {}})
                return
            end

            print("[gm-claude] search_files tool called with path: " .. args.path)
            local files, dirs = file.Find(args.path, "GAME")
            -- cap
            local cappedFiles = {}
            for i = 1, math.min(40, #files) do
                table.insert(cappedFiles, files[i])
            end

            local cappedDirs = {}
            for i = 1, math.min(20, #dirs) do
                table.insert(cappedDirs, dirs[i])
            end

            done({files = cappedFiles, directories = cappedDirs})
        end
    }),

    -- is_valid_model tool, so it can double check any models it wants to spawn before trying to spawn them
    Tool.new({
        name = "is_valid_model",
        description = "Checks if a model path is valid. Useful for double-checking any models you want to spawn before trying to spawn them.",
        parameters = {
            type = "object",
            properties = {
                modelPath = {
                    type = "string",
                    description = "The path of the model to check. For example, `models/props_c17/oildrum001.mdl`."
                }
            },
            required = {"modelPath"}
        },
        coerceArg = "modelPath",
        run = function(args, done)
            if not args.modelPath then
                print("[gm-claude] is_model_valid tool called without a modelPath argument!")
                done({valid = false})
                return
            end

            print("[gm-claude] is_model_valid tool called with modelPath: " .. args.modelPath)
            done({valid = util.IsValidModel(args.modelPath)})
        end
    }),

    -- is_valid_material tool, so it can double check any materials it wants to use before trying to use them
    Tool.new({
        name = "is_valid_material",
        description = "Checks if a material path is valid. Useful for double-checking any materials you want to use before trying to use them. **NOTE:** Any particle ending with _additive will look broken in-game. Don't use it.",
        parameters = {
            type = "object",
            properties = {
                materialPath = {
                    type = "string",
                    description = "The path of the material to check. For example, `effects/blueblacklargebeam`."
                }
            },
            required = {"materialPath"},
        },
        coerceArg = "materialPath",
        run = function(args, done)
            if not args.materialPath then
                print("[gm-claude] is_material_valid tool called without a materialPath argument!")
                done({valid = false})
                return
            end

            print("[gm-claude] is_material_valid tool called with materialPath: " .. args.materialPath)
            done({valid = file.Exists("materials/" .. args.materialPath .. ".vmt", "GAME")})
        end
    }),
}
