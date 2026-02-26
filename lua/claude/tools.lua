--- Provides plenty of tools for the LLM to use

return function(prompt)
    prompt:addTool({
        type = "function",
        ["function"] = {
            name = "search_files",
            description = "Searches for files in the Garry's Mod VFS. Very useful for finding real models, sounds and materials. Supports paths like `models/*.mdl`." ..
            "\nGlob patterns work like so: `*` matches any sequence of characters, so `models/*.mdl` matches any model with any characters ending in .mdl" ..
            "\nIt does **NOT** support directory globs like `**`, it only does the first directory, but the directories are returned to you if you need them." ..
            "\nThe results are capped to 40 files and 20 directories to avoid abuse, so try to be specific with your search terms! For example, searching `models/props_c17/*.mdl` is more likely to get you the model you want than `models/*.mdl`.",
            arguments = {
                type = "object",
                properties = {
                    path = {
                        type = "string",
                        description = "The path to search for, with optional wildcards. For example, `models/*.mdl` to search for all models, or `materials/*/*.vtf` to search for all materials. You can also search specific folders like `sound/weapons/`. Don't search for everything in practice, very wasteful."
                    }
                },
                required = {"path"}
            }
        },
        callback = function(args)
            for k, v in pairs(args) do
                -- Force it all to path, the AI can hallucinate the name sometimes
                args.path = args[k]
            end

            if not args.path then
                print("[gm-claude] search_files tool called without a path argument!")
                return {files = {}, directories = {}}
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

            return {files = cappedFiles, directories = cappedDirs}
        end
    })

    -- is_model_valid tool, so it can double check any models it wants to spawn before trying to spawn them
    prompt:addTool({
        type = "function",
        ["function"] = {
            name = "is_valid_model",
            description = "Checks if a model path is valid. Useful for double-checking any models you want to spawn before trying to spawn them.",
            arguments = {
                type = "object",
                properties = {
                    modelPath = {
                        type = "string",
                        description = "The path of the model to check. For example, `models/props_c17/oildrum001.mdl`."
                    }
                },
                required = {"modelPath"}
            }
        },
        callback = function(args)
            for k, v in pairs(args) do
                -- Force it all to modelPath, the AI can hallucinate the name sometimes
                args.modelPath = args[k]
            end

            if not args.modelPath then
                print("[gm-claude] is_model_valid tool called without a modelPath argument!")
                return {valid=false}
            end

            print("[gm-claude] is_model_valid tool called with modelPath: " .. args.modelPath)
            return {valid=util.IsValidModel(args.modelPath)}
        end
    })

    -- is_material_valid tool, so it can double check any materials it wants to use before trying to use them
    -- this one has no special func, just a file.Exists check, but it can save a lot of errors and help it find the correct paths for materials
    prompt:addTool({
        type = "function",
        ["function"] = {
            name = "is_valid_material",
            description = "Checks if a material path is valid. Useful for double-checking any materials you want to use before trying to use them.",
            arguments = {
                type = "object",
                properties = {
                    materialPath = {
                        type = "string",
                        description = "The path of the material to check. For example, `models/props_c17/oildrum001.mdl`."
                    }
                },
                required = {"materialPath"},
            }
        },
        callback = function(args)
            for k, v in pairs(args) do
                -- Force it all to materialPath, the AI can hallucinate the name sometimes
                args.materialPath = args[k]
            end

            if not args.materialPath then
                print("[gm-claude] is_material_valid tool called without a materialPath argument!")
                return {valid=false}
            end

            print("[gm-claude] is_material_valid tool called with materialPath: " .. args.materialPath)
            return {valid=file.Exists(args.materialPath, "GAME")}
        end
    })
end