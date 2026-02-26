AddCSLuaFile()

mount = mount or {}
mount.LoadedAddons = mount.LoadedAddons or {}
function mount.RecordLoadedAddon(id)
    if not table.HasValue(mount.LoadedAddons, id) then
        table.insert(mount.LoadedAddons, id)
        file.Write("claude_loaded_addons.txt", table.concat(mount.LoadedAddons, ","))
        print("[gm-claude] Recorded loaded addon: " .. id)
    end
end

function mount.RestoreLoadedAddons()
    local stored = file.Read("claude_loaded_addons.txt", "DATA") or ""
    local storedIds = string.Split(stored, ",")
    for _, id in ipairs(storedIds) do
        if id ~= "" then
            table.insert(mount.LoadedAddons, id)
        end
    end
    
    print("[gm-claude] Restored loaded addons from previous session: " .. table.concat(mount.LoadedAddons, ", "))
end

if SERVER then
    require("workshop") -- gmsv_workshop
    util.AddNetworkString("claude.mount")
    util.AddNetworkString("claude.requestMounts")

    mount.RestoreLoadedAddons()
end

function mount.WorkshopAddon(id)
    if SERVER then
        net.Start("claude.mount")
        net.WriteString(id)
        net.Broadcast()
        resource.AddWorkshop(id)
        mount.RecordLoadedAddon(id)
    end

    steamworks.DownloadUGC(id, function(path, _)
        if path then
            print("[gm-claude] Successfully downloaded addon from Workshop: " .. id)
            print("[gm-claude] Mounting addon...")

            local success, files = game.MountGMA(path)
            if success then
                print("[gm-claude] Successfully mounted addon: " .. id)
                if CLIENT then
                    steamworks.FileInfo(id, function(info)
                        notification.AddLegacy("Mounted " .. info.title .. " for next map!", NOTIFY_GENERIC, 5)
                    end)
                end
            else
                print("[gm-claude] Failed to mount addon: " .. id)
            end
        else
            print("[gm-claude] Failed to download addon from Workshop: " .. id)
        end
    end)
end

function mount.ForcePlayerMount(ply, id)
    if SERVER then
        net.Start("claude.mount")
        net.WriteString(id)
        net.Send(ply)
    end
end

if CLIENT then
    net.Receive("claude.mount", function()
        local id = net.ReadString()
        mount.WorkshopAddon(id)
    end)
end