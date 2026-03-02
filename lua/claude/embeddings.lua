-- Shared embeddings generator from prompts,
-- basically allows privileged persons to
-- add new embedding examples on the fly FROM good prompts that were generated,
-- so its kind of like self-improving as it goes along, and can learn from its successes

if SERVER then
    AddCSLuaFile()
    util.AddNetworkString("embedding.get-prompt-as-example")
    util.AddNetworkString("embedding.example-response")
    util.AddNetworkString("embedding.save-example")
    util.AddNetworkString("embedding.save-result")
    
    util.AddNetworkString("embedding.delete-example")
    util.AddNetworkString("embedding.get-all-examples")
    util.AddNetworkString("embedding.all-examples-chunk")
end

-- Max net message payload we'll use per chunk (staying under Source's 64KB limit)
local NET_CHUNK_SIZE = 60000

embeddings = {}

if SERVER then
    embeddings.SavedPrompts = {}
    embeddings.API = nil
    function embeddings.SetAPI(api)
        embeddings.API = api
    end

    function embeddings.SavePromptObject(id, prompt)
        embeddings.SavedPrompts[id] = prompt
    end

    function embeddings.PromptToEmbeddingExample(id)
        local prompt = embeddings.SavedPrompts[id]

        local example = {}
        example.prompt = prompt.prompt
        example.tags = ""
        example.toolcalls = prompt.toolCalls or {}
        example.response = prompt.luaCode or ""

        return example
    end

    function embeddings.SaveEmbedding(example, callback)
        if not embeddings.API then
            print("[gm-claude] Cannot save embedding, API not set!")
            return
        end

        embeddings.API:addLiveEmbedding(example, function(success, message)
            if success then
                print("[gm-claude] Successfully added new embedding example!")
            else
                print("[gm-claude] Failed to add new embedding example: " .. message)
            end

            callback(success, message)
        end)
    end

    --- Splits a string into chunks of at most `size` bytes
    local function ChunkString(str, size)
        local chunks = {}
        local len = #str
        for i = 1, len, size do
            chunks[#chunks + 1] = string.sub(str, i, i + size - 1)
        end
        return chunks
    end

    net.Receive("embedding.get-prompt-as-example", function(len, ply)
        local promptId = net.ReadString()
        local prompt = embeddings.SavedPrompts[promptId]
        if not prompt then
            print("[gm-claude] No prompt found with ID: " .. promptId)
            return
        end

        local example = embeddings.PromptToEmbeddingExample(promptId)
        net.Start("embedding.example-response")
        net.WriteString(promptId)
        net.WriteString(util.TableToJSON(example))
        net.Send(ply)
    end)

    net.Receive("embedding.save-example", function(len, ply)
        local exampleJson = net.ReadString()
        local example = util.JSONToTable(exampleJson)
        if not example then
            print("[gm-claude] Failed to decode embedding example JSON from client!")
            return
        end

        embeddings.SaveEmbedding(example, function(success, message)
            if success then
                print("[gm-claude] Successfully saved embedding example from client!")
                net.Start("embedding.save-result")
                net.WriteBool(true)
                net.WriteString("Embedding example saved successfully!")
                net.Send(ply)
            else
                print("[gm-claude] Failed to save embedding example from client: " .. message)
                net.Start("embedding.save-result")
                net.WriteBool(false)
                net.WriteString(message)
                net.Send(ply)
            end
        end)
    end)

    net.Receive("embedding.delete-example", function(len, ply)
        local prompt = net.ReadString()
        if not embeddings.API then
            print("[gm-claude] Cannot delete embedding, API not set!")
            return
        end

        embeddings.API:deleteEmbedding(prompt)
    end)

    net.Receive("embedding.get-all-examples", function(len, ply)
        if not embeddings.API then
            print("[gm-claude] Cannot get all embeddings, API not set!")
            return
        end

        embeddings.API:getAllEmbeddings(function(examples)
            local fullJson = util.TableToJSON(examples)
            local chunks = ChunkString(fullJson, NET_CHUNK_SIZE)
            local totalChunks = #chunks

            print("[gm-claude] Sending " .. totalChunks .. " embedding chunks to " .. ply:Nick() .. " (" .. #fullJson .. " bytes)")

            for i, chunk in ipairs(chunks) do
                -- Stagger sends slightly to avoid net buffer overflow
                timer.Simple((i - 1) * 0.05, function()
                    if not IsValid(ply) then return end

                    net.Start("embedding.all-examples-chunk")
                    net.WriteUInt(i, 16)            -- chunk index (1-based)
                    net.WriteUInt(totalChunks, 16)   -- total chunk count
                    net.WriteUInt(#chunk, 32)        -- chunk byte length
                    net.WriteData(chunk, #chunk)     -- raw chunk data
                    net.Send(ply)
                end)
            end
        end)
    end)
end


if CLIENT then
    embeddings.CurrentExample = nil
    embeddings.CurrentPromptId = nil
    embeddings.AllExamples = {}

    -- Chunk reassembly state
    embeddings._chunks = {}
    embeddings._totalChunks = 0
    embeddings._receivedCount = 0

    net.Receive("embedding.all-examples-chunk", function(len)
        local chunkIndex = net.ReadUInt(16)
        local totalChunks = net.ReadUInt(16)
        local chunkLen = net.ReadUInt(32)
        local chunkData = net.ReadData(chunkLen)

        -- Reset if we're starting a new transfer
        if chunkIndex == 1 then
            embeddings._chunks = {}
            embeddings._totalChunks = totalChunks
            embeddings._receivedCount = 0
        end

        embeddings._chunks[chunkIndex] = chunkData
        embeddings._receivedCount = embeddings._receivedCount + 1

        -- Notify progress
        hook.Run("EmbeddingsChunkReceived", embeddings._receivedCount, totalChunks)

        -- All chunks received, reassemble
        if embeddings._receivedCount >= totalChunks then
            local parts = {}
            for i = 1, totalChunks do
                parts[i] = embeddings._chunks[i] or ""
            end
            local fullJson = table.concat(parts)

            local examples = util.JSONToTable(fullJson)
            if not examples then
                print("[gm-claude] Failed to decode reassembled embeddings JSON! (" .. #fullJson .. " bytes)")
                hook.Run("EmbeddingsListFailed", "Failed to decode JSON data")
                return
            end

            embeddings.AllExamples = examples
            embeddings._chunks = {}
            embeddings._totalChunks = 0
            embeddings._receivedCount = 0

            hook.Run("EmbeddingsListReceived")
        end
    end)

    net.Receive("embedding.example-response", function(len)
        local promptId = net.ReadString()
        local exampleJson = net.ReadString()
        local example = util.JSONToTable(exampleJson)
        if not example then
            print("[gm-claude] Failed to decode embedding example JSON from server!")
            return
        end

        embeddings.CurrentPromptId = promptId
        embeddings.CurrentExample = example
    end)

    function embeddings.RequestPromptAsExample(promptId)
        net.Start("embedding.get-prompt-as-example")
        net.WriteString(promptId)
        net.SendToServer()
    end

    function embeddings.SaveExample(example)
        local exampleJson = util.TableToJSON(example)
        net.Start("embedding.save-example")
        net.WriteString(exampleJson)
        net.SendToServer()
    end

    function embeddings.DeleteExample(prompt)
        net.Start("embedding.delete-example")
        net.WriteString(prompt)
        net.SendToServer()
    end

    function embeddings.RequestAllExamples()
        net.Start("embedding.get-all-examples")
        net.SendToServer()
    end

    net.Receive("embedding.save-result", function(len)
        local success = net.ReadBool()
        local message = net.ReadString()

        for _, pnl in ipairs(vgui.GetWorldPanel():GetChildren()) do
            if IsValid(pnl) and pnl.ClassName == "EmbeddingEditor" then
                if success then
                    pnl:SetStatus("Saved successfully!")
                    timer.Simple(1.5, function()
                        if IsValid(pnl) then pnl:Close() end
                    end)
                else
                    pnl:SetStatus("Failed: " .. message, true)
                end
                return
            end
        end

        if success then
            print("[gm-claude] Embedding saved: " .. message)
        else
            print("[gm-claude] Embedding failed: " .. message)
        end
    end)

    -- =============================================
    -- Embedding List Panel (browse all embeddings)
    -- =============================================
    local LIST_PANEL = {}

    function LIST_PANEL:Init()
        self:SetSize(800, 550)
        self:Center()
        self:SetTitle("All Embeddings")
        self:MakePopup()
        self:SetDeleteOnClose(true)
        self:SetSizable(true)
        self:SetMinWidth(500)
        self:SetMinHeight(300)

        -- Top bar with refresh button
        local topBar = vgui.Create("DPanel", self)
        topBar:Dock(TOP)
        topBar:DockMargin(4, 4, 4, 0)
        topBar:SetTall(30)
        topBar.Paint = function() end

        self.SearchEntry = vgui.Create("DTextEntry", topBar)
        self.SearchEntry:Dock(FILL)
        self.SearchEntry:DockMargin(0, 0, 8, 0)
        self.SearchEntry:SetPlaceholderText("Search prompts...")
        self.SearchEntry.OnChange = function()
            self:FilterList()
        end

        local refreshBtn = vgui.Create("DButton", topBar)
        refreshBtn:Dock(RIGHT)
        refreshBtn:SetWide(100)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetIcon("icon16/arrow_refresh.png")
        refreshBtn.DoClick = function()
            self:BeginLoading()
            embeddings.RequestAllExamples()
        end

        -- Progress bar (hidden by default)
        self.ProgressPanel = vgui.Create("DPanel", self)
        self.ProgressPanel:Dock(TOP)
        self.ProgressPanel:DockMargin(4, 4, 4, 0)
        self.ProgressPanel:SetTall(24)
        self.ProgressPanel:SetVisible(false)

        self._progressFrac = 0
        self._progressText = ""

        self.ProgressPanel.Paint = function(pnl, w, h)
            -- Background
            draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40, 255))

            -- Filled portion
            local fillW = math.floor(w * self._progressFrac)
            if fillW > 0 then
                draw.RoundedBox(4, 0, 0, fillW, h, Color(70, 140, 230, 255))
            end

            -- Text
            draw.SimpleText(
                self._progressText,
                "DermaDefault",
                w / 2, h / 2,
                Color(255, 255, 255, 255),
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER
            )
        end

        -- List view
        self.ListView = vgui.Create("DListView", self)
        self.ListView:Dock(FILL)
        self.ListView:DockMargin(4, 4, 4, 4)
        self.ListView:SetMultiSelect(false)
        self.ListView:AddColumn("Prompt"):SetWidth(400)
        self.ListView:AddColumn("Tags"):SetWidth(200)
        self.ListView:AddColumn("Has Code"):SetWidth(80)

        self.ListView.OnRowRightClick = function(_, lineId, line)
            self:OpenRowContextMenu(line)
        end

        self.ListView.DoDoubleClick = function(_, lineId, line)
            self:OpenInEditor(line)
        end

        -- Bottom bar
        local bottomBar = vgui.Create("DPanel", self)
        bottomBar:Dock(BOTTOM)
        bottomBar:DockMargin(4, 0, 4, 4)
        bottomBar:SetTall(30)
        bottomBar.Paint = function() end

        self.StatusLabel = vgui.Create("DLabel", bottomBar)
        self.StatusLabel:Dock(FILL)
        self.StatusLabel:SetText("")

        local openBtn = vgui.Create("DButton", bottomBar)
        openBtn:Dock(RIGHT)
        openBtn:DockMargin(4, 0, 0, 0)
        openBtn:SetWide(150)
        openBtn:SetText("Open in Editor")
        openBtn:SetIcon("icon16/page_edit.png")
        openBtn.DoClick = function()
            local line = self.ListView:GetSelectedLine()
            if not line then
                self:SetStatus("Select an embedding first", true)
                return
            end
            self:OpenInEditor(self.ListView:GetLine(line))
        end

        local deleteBtn = vgui.Create("DButton", bottomBar)
        deleteBtn:Dock(RIGHT)
        deleteBtn:DockMargin(4, 0, 0, 0)
        deleteBtn:SetWide(120)
        deleteBtn:SetText("Delete")
        deleteBtn:SetIcon("icon16/cross.png")
        deleteBtn.DoClick = function()
            local lineId = self.ListView:GetSelectedLine()
            if not lineId then
                self:SetStatus("Select an embedding first", true)
                return
            end
            self:ConfirmDelete(self.ListView:GetLine(lineId))
        end

        -- Hook into chunk progress
        self._hookId = "EmbeddingsListPanel_" .. tostring(SysTime())

        hook.Add("EmbeddingsChunkReceived", self._hookId, function(received, total)
            if not IsValid(self) then
                hook.Remove("EmbeddingsChunkReceived", self._hookId)
                return
            end
            self:UpdateProgress(received, total)
        end)

        hook.Add("EmbeddingsListReceived", self._hookId, function()
            if not IsValid(self) then
                hook.Remove("EmbeddingsListReceived", self._hookId)
                return
            end
            self:FinishLoading()
            self:PopulateList()
        end)

        hook.Add("EmbeddingsListFailed", self._hookId, function(errMsg)
            if not IsValid(self) then
                hook.Remove("EmbeddingsListFailed", self._hookId)
                return
            end
            self:FinishLoading()
            self:SetStatus("Error: " .. (errMsg or "unknown"), true)
        end)

        -- Request data on open
        self:BeginLoading()
        embeddings.RequestAllExamples()
    end

    function LIST_PANEL:OnRemove()
        if self._hookId then
            hook.Remove("EmbeddingsChunkReceived", self._hookId)
            hook.Remove("EmbeddingsListReceived", self._hookId)
            hook.Remove("EmbeddingsListFailed", self._hookId)
        end
    end

    function LIST_PANEL:BeginLoading()
        self._progressFrac = 0
        self._progressText = "Requesting data..."
        self.ProgressPanel:SetVisible(true)
        self:SetStatus("Loading...")
    end

    function LIST_PANEL:UpdateProgress(received, total)
        self._progressFrac = received / total
        self._progressText = string.format("Downloading: %d / %d chunks (%d%%)", received, total, math.floor(self._progressFrac * 100))
        self.ProgressPanel:SetVisible(true)
    end

    function LIST_PANEL:FinishLoading()
        self._progressFrac = 1
        self._progressText = "Done!"

        -- Hide progress bar after a short delay
        timer.Simple(1, function()
            if IsValid(self) and IsValid(self.ProgressPanel) then
                self.ProgressPanel:SetVisible(false)
            end
        end)
    end

    function LIST_PANEL:PopulateList()
        self.ListView:Clear()
        self._exampleData = {}

        for i, example in ipairs(embeddings.AllExamples) do
            local prompt = example.prompt or "(no prompt)"
            local tags = example.tags or ""
            local hasCode = (example.response and example.response ~= "") and "Yes" or "No"

            local line = self.ListView:AddLine(prompt, tags, hasCode)
            self._exampleData[line] = example
        end

        self:SetStatus(#embeddings.AllExamples .. " embeddings loaded")
        self:FilterList()
    end

    function LIST_PANEL:FilterList()
        local query = self.SearchEntry:GetValue():lower()
        if query == "" then
            for _, line in pairs(self.ListView:GetLines()) do
                line:SetVisible(true)
            end
            self.ListView:InvalidateLayout()
            return
        end

        for _, line in pairs(self.ListView:GetLines()) do
            local example = self._exampleData[line]
            if example then
                local prompt = (example.prompt or ""):lower()
                local tags = (example.tags or ""):lower()
                local visible = string.find(prompt, query, 1, true) or string.find(tags, query, 1, true)
                line:SetVisible(visible ~= nil)
            end
        end
        self.ListView:InvalidateLayout()
    end

    function LIST_PANEL:OpenRowContextMenu(line)
        local example = self._exampleData[line]
        if not example then return end

        local menu = DermaMenu()
        menu:AddOption("Open in Editor", function()
            self:OpenInEditor(line)
        end):SetIcon("icon16/page_edit.png")

        menu:AddSpacer()

        menu:AddOption("Delete", function()
            self:ConfirmDelete(line)
        end):SetIcon("icon16/cross.png")

        menu:Open()
    end

    function LIST_PANEL:OpenInEditor(line)
        local example = self._exampleData[line]
        if not example then return end

        local editor = vgui.Create("EmbeddingEditor")
        editor:LoadExample(example)
    end

    function LIST_PANEL:ConfirmDelete(line)
        local example = self._exampleData[line]
        if not example then return end

        Derma_Query(
            "Delete this embedding?\n\n" .. (example.prompt or "(no prompt)"),
            "Confirm Delete",
            "Delete",
            function()
                embeddings.DeleteExample(example.prompt)
                self._exampleData[line] = nil
                self.ListView:RemoveLine(line:GetID())
                self:SetStatus("Deleted embedding")
            end,
            "Cancel",
            function() end
        )
    end

    function LIST_PANEL:SetStatus(text, isError)
        self.StatusLabel:SetText(text)
        self.StatusLabel:SetColor(isError and Color(255, 100, 100) or Color(200, 200, 200))
    end

    vgui.Register("EmbeddingList", LIST_PANEL, "DFrame")

    -- =============================================
    -- Embedding Editor Panel
    -- =============================================
    local PANEL = {}

    function PANEL:Init()
        self:SetSize(700, 600)
        self:Center()
        self:SetTitle("Embedding Example Editor")
        self:MakePopup()
        self:SetDeleteOnClose(true)
        self:SetSizable(true)
        self:SetMinWidth(500)
        self:SetMinHeight(400)

        self.Scroll = vgui.Create("DScrollPanel", self)
        self.Scroll:Dock(FILL)
        self.Scroll:DockMargin(4, 4, 4, 4)

        local metaLabel = vgui.Create("DLabel", self.Scroll)
        metaLabel:Dock(TOP)
        metaLabel:DockMargin(0, 0, 0, 2)
        metaLabel:SetText("Metadata JSON (prompt, tags, toolcalls)")
        metaLabel:SetFont("DermaDefaultBold")

        self.MetaEntry = vgui.Create("DTextEntry", self.Scroll)
        self.MetaEntry:Dock(TOP)
        self.MetaEntry:DockMargin(0, 0, 0, 8)
        self.MetaEntry:SetTall(200)
        self.MetaEntry:SetMultiline(true)
        self.MetaEntry:SetPlaceholderText('{\n  "prompt": "Make a SWEP that shoots melons",\n  "tags": "swep weapon gun shoot melon",\n  "toolcalls": []\n}')

        local codeLabel = vgui.Create("DLabel", self.Scroll)
        codeLabel:Dock(TOP)
        codeLabel:DockMargin(0, 0, 0, 2)
        codeLabel:SetText("Lua Code (the generated response)")
        codeLabel:SetFont("DermaDefaultBold")

        self.CodeEntry = vgui.Create("DTextEntry", self.Scroll)
        self.CodeEntry:Dock(TOP)
        self.CodeEntry:DockMargin(0, 0, 0, 8)
        self.CodeEntry:SetTall(280)
        self.CodeEntry:SetMultiline(true)
        self.CodeEntry:SetPlaceholderText("Lua code here...")

        local btnPanel = vgui.Create("DPanel", self.Scroll)
        btnPanel:Dock(TOP)
        btnPanel:DockMargin(0, 4, 0, 0)
        btnPanel:SetTall(35)
        btnPanel.Paint = function() end

        local saveBtn = vgui.Create("DButton", btnPanel)
        saveBtn:Dock(RIGHT)
        saveBtn:DockMargin(4, 0, 0, 0)
        saveBtn:SetWide(150)
        saveBtn:SetText("Save Embedding")
        saveBtn:SetIcon("icon16/disk.png")
        saveBtn.DoClick = function()
            self:SaveExample()
        end

        local cancelBtn = vgui.Create("DButton", btnPanel)
        cancelBtn:Dock(RIGHT)
        cancelBtn:DockMargin(4, 0, 0, 0)
        cancelBtn:SetWide(100)
        cancelBtn:SetText("Cancel")
        cancelBtn.DoClick = function()
            self:Close()
        end

        local browseBtn = vgui.Create("DButton", btnPanel)
        browseBtn:Dock(RIGHT)
        browseBtn:DockMargin(4, 0, 0, 0)
        browseBtn:SetWide(150)
        browseBtn:SetText("All Embeddings")
        browseBtn:SetIcon("icon16/table.png")
        browseBtn.DoClick = function()
            embeddings.OpenList()
        end

        self.StatusLabel = vgui.Create("DLabel", btnPanel)
        self.StatusLabel:Dock(FILL)
        self.StatusLabel:SetText("")
    end

    function PANEL:LoadExample(example)
        if not example then return end

        local meta = {
            prompt = example.prompt or "",
            tags = example.tags or "",
            toolcalls = example.toolcalls or {},
        }
        self.MetaEntry:SetValue(util.TableToJSON(meta, true))
        self.CodeEntry:SetValue(example.response or "")
    end

    function PANEL:BuildExample()
        local metaText = self.MetaEntry:GetValue()
        local meta = util.JSONToTable(metaText)
        if not meta then
            return nil, "Invalid metadata JSON"
        end

        if not meta.prompt or meta.prompt == "" then
            return nil, "Prompt is required"
        end

        if not meta.tags or meta.tags == "" then
            return nil, "Tags are required"
        end

        local code = self.CodeEntry:GetValue()
        if not code or code == "" then
            return nil, "Lua code is required"
        end

        return {
            prompt = meta.prompt,
            tags = meta.tags,
            toolcalls = meta.toolcalls or {},
            response = code,
        }
    end

    function PANEL:SetStatus(text, isError)
        self.StatusLabel:SetText(text)
        self.StatusLabel:SetColor(isError and Color(255, 100, 100) or Color(100, 255, 100))
    end

    function PANEL:SaveExample()
        local example, err = self:BuildExample()
        if not example then
            self:SetStatus(err, true)
            return
        end

        self:SetStatus("Saving...")
        embeddings.SaveExample(example)
    end

    vgui.Register("EmbeddingEditor", PANEL, "DFrame")

    -- =============================================
    -- Public API
    -- =============================================
    function embeddings.OpenEditor(promptId)
        if promptId then
            embeddings.RequestPromptAsExample(promptId)

            local hookId = "EmbeddingEditorWait_" .. tostring(SysTime())
            hook.Add("Think", hookId, function()
                if embeddings.CurrentPromptId == promptId and embeddings.CurrentExample then
                    hook.Remove("Think", hookId)
                    local editor = vgui.Create("EmbeddingEditor")
                    editor:LoadExample(embeddings.CurrentExample)
                    embeddings.CurrentExample = nil
                    embeddings.CurrentPromptId = nil
                end
            end)
        else
            vgui.Create("EmbeddingEditor")
        end
    end

    function embeddings.OpenList()
        vgui.Create("EmbeddingList")
    end

    concommand.Add("embedding_editor", function(ply, cmd, args)
        local promptId = args[1]
        embeddings.OpenEditor(promptId)
    end)

    concommand.Add("embedding_list", function()
        embeddings.OpenList()
    end)
end