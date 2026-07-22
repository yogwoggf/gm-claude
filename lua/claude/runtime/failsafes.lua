-- Assorted fail-safes to make more prompts work. Main one is the model correcter.

local Entity = FindMetaTable("Entity")
local oldSetModel = Entity.SetModel
local FALLBACK_MODEL = "models/hunter/blocks/cube1x1x1.mdl"

function Entity:SetModel(model)
    if not util.IsValidModel(model) and model:sub(1, 1) ~= "*" then
        print("[gm-claude] Attempted to set invalid model: " .. model)
        return oldSetModel(self, FALLBACK_MODEL)
    end

    return oldSetModel(self, model)
end