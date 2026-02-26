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
end

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
end

if CLIENT then
    embeddings.CurrentExample = nil
    embeddings.CurrentPromptId = nil

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

    -- Editor Panel
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

        local promptLabel = vgui.Create("DLabel", self.Scroll)
        promptLabel:Dock(TOP)
        promptLabel:DockMargin(0, 0, 0, 2)
        promptLabel:SetText("Prompt (what the player said)")
        promptLabel:SetFont("DermaDefaultBold")

        self.PromptEntry = vgui.Create("DTextEntry", self.Scroll)
        self.PromptEntry:Dock(TOP)
        self.PromptEntry:DockMargin(0, 0, 0, 8)
        self.PromptEntry:SetTall(30)
        self.PromptEntry:SetPlaceholderText("e.g. Make a SWEP that shoots watermelons")

        local tagsLabel = vgui.Create("DLabel", self.Scroll)
        tagsLabel:Dock(TOP)
        tagsLabel:DockMargin(0, 0, 0, 2)
        tagsLabel:SetText("Tags (space-separated, for embedding search)")
        tagsLabel:SetFont("DermaDefaultBold")

        self.TagsEntry = vgui.Create("DTextEntry", self.Scroll)
        self.TagsEntry:Dock(TOP)
        self.TagsEntry:DockMargin(0, 0, 0, 8)
        self.TagsEntry:SetTall(30)
        self.TagsEntry:SetPlaceholderText("e.g. swep weapon gun shoot projectile melon")

        local toolLabel = vgui.Create("DLabel", self.Scroll)
        toolLabel:Dock(TOP)
        toolLabel:DockMargin(0, 0, 0, 2)
        toolLabel:SetText("Toolcalls")
        toolLabel:SetFont("DermaDefaultBold")

        self.ToolcallList = vgui.Create("DPanel", self.Scroll)
        self.ToolcallList:Dock(TOP)
        self.ToolcallList:DockMargin(0, 0, 0, 4)
        self.ToolcallList:SetTall(0)
        self.ToolcallList.Paint = function() end
        self.ToolcallRows = {}

        local addToolBtn = vgui.Create("DButton", self.Scroll)
        addToolBtn:Dock(TOP)
        addToolBtn:DockMargin(0, 0, 0, 8)
        addToolBtn:SetTall(25)
        addToolBtn:SetText("+ Add Toolcall")
        addToolBtn.DoClick = function()
            self:AddToolcallRow("is_valid_model", "", "")
        end

        local codeLabel = vgui.Create("DLabel", self.Scroll)
        codeLabel:Dock(TOP)
        codeLabel:DockMargin(0, 0, 0, 2)
        codeLabel:SetText("Lua Code (the generated response)")
        codeLabel:SetFont("DermaDefaultBold")

        self.CodeEntry = vgui.Create("DTextEntry", self.Scroll)
        self.CodeEntry:Dock(TOP)
        self.CodeEntry:DockMargin(0, 0, 0, 8)
        self.CodeEntry:SetTall(250)
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

        self.StatusLabel = vgui.Create("DLabel", btnPanel)
        self.StatusLabel:Dock(FILL)
        self.StatusLabel:SetText("")
    end

    function PANEL:AddToolcallRow(tool, args, result)
        local row = vgui.Create("DPanel", self.ToolcallList)
        row:Dock(TOP)
        row:DockMargin(0, 0, 0, 2)
        row:SetTall(30)
        row.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(40, 40, 40, 200))
        end

        local toolCombo = vgui.Create("DComboBox", row)
        toolCombo:Dock(LEFT)
        toolCombo:DockMargin(4, 2, 4, 2)
        toolCombo:SetWide(140)
        toolCombo:AddChoice("is_valid_model")
        toolCombo:AddChoice("is_valid_material")
        toolCombo:AddChoice("search_files")
        toolCombo:SetValue(tool or "is_valid_model")

        local argsEntry = vgui.Create("DTextEntry", row)
        argsEntry:Dock(FILL)
        argsEntry:DockMargin(0, 2, 4, 2)
        argsEntry:SetPlaceholderText("args")
        argsEntry:SetValue(args or "")

        local resultEntry = vgui.Create("DTextEntry", row)
        resultEntry:Dock(RIGHT)
        resultEntry:DockMargin(0, 2, 4, 2)
        resultEntry:SetWide(150)
        resultEntry:SetPlaceholderText("result JSON")
        resultEntry:SetValue(result or "")

        local removeBtn = vgui.Create("DButton", row)
        removeBtn:Dock(RIGHT)
        removeBtn:DockMargin(0, 2, 4, 2)
        removeBtn:SetWide(25)
        removeBtn:SetText("X")
        removeBtn.DoClick = function()
            for i, r in ipairs(self.ToolcallRows) do
                if r.panel == row then
                    table.remove(self.ToolcallRows, i)
                    break
                end
            end
            row:Remove()
            self:RecalcToolcallHeight()
        end

        table.insert(self.ToolcallRows, {
            panel = row,
            tool = toolCombo,
            args = argsEntry,
            result = resultEntry,
        })

        self:RecalcToolcallHeight()
    end

    function PANEL:RecalcToolcallHeight()
        self.ToolcallList:SetTall(#self.ToolcallRows * 32)
        self.ToolcallList:InvalidateLayout(true)
    end

    function PANEL:LoadExample(example)
        if not example then return end

        self.PromptEntry:SetValue(example.prompt or "")
        self.TagsEntry:SetValue(example.tags or "")
        self.CodeEntry:SetValue(example.response or "")

        for _, row in ipairs(self.ToolcallRows) do
            row.panel:Remove()
        end
        self.ToolcallRows = {}

        if example.toolcalls then
            for _, tc in ipairs(example.toolcalls) do
                local resultStr = ""
                if tc.result then
                    resultStr = util.TableToJSON(tc.result) or ""
                end
                self:AddToolcallRow(tc.tool, tc.args, resultStr)
            end
        end
    end

    function PANEL:BuildExample()
        local example = {}
        example.prompt = self.PromptEntry:GetValue()
        example.tags = self.TagsEntry:GetValue()
        example.response = self.CodeEntry:GetValue()
        example.toolcalls = {}

        for _, row in ipairs(self.ToolcallRows) do
            local resultText = row.result:GetValue()
            local resultTable = nil
            if resultText and resultText ~= "" then
                resultTable = util.JSONToTable(resultText)
            end

            table.insert(example.toolcalls, {
                tool = row.tool:GetValue(),
                args = row.args:GetValue(),
                result = resultTable,
            })
        end

        return example
    end

    function PANEL:SetStatus(text, isError)
        self.StatusLabel:SetText(text)
        self.StatusLabel:SetColor(isError and Color(255, 100, 100) or Color(100, 255, 100))
    end

    function PANEL:SaveExample()
        local example = self:BuildExample()

        if example.prompt == "" then
            self:SetStatus("Prompt is required!", true)
            return
        end

        if example.tags == "" then
            self:SetStatus("Tags are required!", true)
            return
        end

        if example.response == "" then
            self:SetStatus("Lua code is required!", true)
            return
        end

        self:SetStatus("Saving...")
        embeddings.SaveExample(example)
    end

    vgui.Register("EmbeddingEditor", PANEL, "DFrame")

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

    concommand.Add("embedding_editor", function(ply, cmd, args)
        local promptId = args[1]
        embeddings.OpenEditor(promptId)
    end)
end