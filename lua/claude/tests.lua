-- Test runner module.
-- Server: reads test_manifest.json + test_*.txt files, executes through the real sandbox.
-- Client: browseable list UI with live pass/fail status + code preview.
--
-- Workflow:
--   1.  bun scripts/prep-tests.ts          (writes test_*.txt + manifest to data/prompt-lua/)
--   2.  test_runner  (client console)       (opens the UI)

if SERVER then
    AddCSLuaFile()

    util.AddNetworkString("tests.get-manifest")
    util.AddNetworkString("tests.manifest-response")
    util.AddNetworkString("tests.get-code")
    util.AddNetworkString("tests.code-response")
    util.AddNetworkString("tests.run-test")
    util.AddNetworkString("tests.run-result")

    -- tests.get-manifest → send sorted list of test names
    net.Receive("tests.get-manifest", function(_, ply)
        local names = {}

        -- Try manifest first
        local newNames = {}
        local json = file.Read("prompt-lua/test_manifest.json", "DATA")
        if json then
            local manifest = util.JSONToTable(json)
            if manifest then
                names    = manifest.names or manifest
                newNames = manifest["new"] or {}
            end
        end

        -- Fall back to file discovery
        if #names == 0 then
            local files = file.Find("prompt-lua/test_*.txt", "DATA")
            for _, f in ipairs(files) do
                local name = f:match("^test_(.+)%.txt")
                if name then table.insert(names, name) end
            end
            table.sort(names)
        end

        net.Start("tests.manifest-response")
        net.WriteString(util.TableToJSON({ names = names, new = newNames }))
        net.Send(ply)
    end)

    -- tests.get-code → send raw lua source for preview
    net.Receive("tests.get-code", function(_, ply)
        local testName = net.ReadString()
        local fname    = "prompt-lua/test_" .. testName .. ".txt"
        local code     = file.Exists(fname, "DATA")
            and file.Read(fname, "DATA")
            or  "(file not found — run: bun scripts/prep-tests.ts)"

        net.Start("tests.code-response")
        net.WriteString(testName)
        net.WriteString(code)
        net.Send(ply)
    end)

    -- tests.run-test → execute through the real sandbox, return pass/fail
    net.Receive("tests.run-test", function(_, ply)
        local testName = net.ReadString()
        local plyIdx   = ply:UserID()

        local fname = "prompt-lua/test_" .. testName .. ".txt"
        if not file.Exists(fname, "DATA") then
            net.Start("tests.run-result")
                net.WriteString(testName)
                net.WriteBool(false)
                net.WriteString("File not found. Run: bun scripts/prep-tests.ts")
            net.Send(ply)
            return
        end

        local code = file.Read(fname, "DATA")
        code = code:gsub("{{ID}}", tostring(plyIdx)) -- replace any {{ID}} placeholders with the actual player ID

        local sandbox = GilbSandbox
        local success, errMsg

        if sandbox then
            local func, compileErr = CompileString(code, "test_ui_" .. testName, false)
            if not func or type(func) == "string" then
                success = false
                errMsg  = "compile: " .. tostring(compileErr or func)
            else
                local env = sandbox:initializeEnv("test_ui_" .. testName)
                setfenv(func, env)
                local ok, runErr = pcall(func)
                success = ok
                errMsg  = ok and "" or ("runtime: " .. tostring(runErr))
            end
        else
            success = false
            errMsg  = "GilbSandbox not set — check server load order"
        end

        net.Start("tests.run-result")
            net.WriteString(testName)
            net.WriteBool(success)
            net.WriteString(errMsg or "")
        net.Send(ply)
    end)
end

-- ============================================================
-- CLIENT
-- ============================================================
if CLIENT then
    tests = tests or {}
    tests.Names   = {}
    tests.Results = {}   -- name → {ok, err}
    tests.Code    = {}   -- name → string
    tests.New     = {}   -- name → true  (set of names added since last prep-tests run)

    net.Receive("tests.manifest-response", function()
        local data    = util.JSONToTable(net.ReadString()) or {}
        tests.Names   = data.names or data  -- fallback: old servers sent a plain array
        tests.New     = {}
        for _, n in ipairs(data.new or {}) do
            tests.New[n] = true
        end
        hook.Run("Tests_ManifestReceived")
    end)

    net.Receive("tests.code-response", function()
        local name = net.ReadString()
        local code = net.ReadString()
        tests.Code[name] = code
        hook.Run("Tests_CodeReceived", name)
    end)

    net.Receive("tests.run-result", function()
        local name   = net.ReadString()
        local ok     = net.ReadBool()
        local errMsg = net.ReadString()
        tests.Results[name] = { ok = ok, err = errMsg }
        hook.Run("Tests_ResultReceived", name, ok, errMsg)
    end)

    function tests.RequestManifest()
        net.Start("tests.get-manifest")
        net.SendToServer()
    end

    function tests.RequestCode(name)
        net.Start("tests.get-code")
        net.WriteString(name)
        net.SendToServer()
    end

    function tests.RunTest(name)
        net.Start("tests.run-test")
        net.WriteString(name)
        net.SendToServer()
    end

    -- ──────────────────────────────────────────────────────────
    -- Panel
    -- ──────────────────────────────────────────────────────────

    local COL_PENDING = Color(160, 160, 160)
    local COL_PASS    = Color(80, 200, 80)
    local COL_FAIL    = Color(220, 80, 80)
    local COL_RUN     = Color(220, 180, 60)
    local COL_NEW     = Color(90, 160, 255)

    local PANEL = {}

    function PANEL:Init()
        self:SetSize(940, 600)
        self:Center()
        self:SetTitle("Test Runner")
        self:MakePopup()
        self:SetDeleteOnClose(true)
        self:SetSizable(true)
        self:SetMinWidth(640)
        self:SetMinHeight(400)

        self._hookId      = "TestRunnerPanel_" .. tostring(SysTime())
        self._lineForName = {}
        self._selected    = nil
        self._running     = 0

        -- ── top bar ──────────────────────────────────────────
        local topBar = vgui.Create("DPanel", self)
        topBar:Dock(TOP)
        topBar:DockMargin(4, 4, 4, 2)
        topBar:SetTall(28)
        topBar.Paint = function() end

        self.SearchEntry = vgui.Create("DTextEntry", topBar)
        self.SearchEntry:Dock(FILL)
        self.SearchEntry:DockMargin(0, 0, 6, 0)
        self.SearchEntry:SetPlaceholderText("Filter tests...")
        self.SearchEntry.OnChange = function() self:ApplyFilter() end

        local runAllBtn = vgui.Create("DButton", topBar)
        runAllBtn:Dock(RIGHT)
        runAllBtn:DockMargin(4, 0, 0, 0)
        runAllBtn:SetWide(90)
        runAllBtn:SetText("Run All")
        runAllBtn:SetIcon("icon16/lightning.png")
        runAllBtn.DoClick = function() self:RunAll() end

        local runNewBtn = vgui.Create("DButton", topBar)
        runNewBtn:Dock(RIGHT)
        runNewBtn:DockMargin(4, 0, 0, 0)
        runNewBtn:SetWide(90)
        runNewBtn:SetText("Run New")
        runNewBtn:SetIcon("icon16/lightning_add.png")
        runNewBtn.DoClick = function() self:RunNew() end

        local refreshBtn = vgui.Create("DButton", topBar)
        refreshBtn:Dock(RIGHT)
        refreshBtn:DockMargin(4, 0, 0, 0)
        refreshBtn:SetWide(90)
        refreshBtn:SetText("Refresh")
        refreshBtn:SetIcon("icon16/arrow_refresh.png")
        refreshBtn.DoClick = function()
            self:SetStatus("Refreshing...")
            tests.RequestManifest()
        end

        -- ── split area ───────────────────────────────────────
        local split = vgui.Create("DPanel", self)
        split:Dock(FILL)
        split:DockMargin(4, 4, 4, 0)
        split.Paint = function() end

        -- Left: list
        local leftPanel = vgui.Create("DPanel", split)
        leftPanel:Dock(LEFT)
        leftPanel:SetWide(310)
        leftPanel.Paint = function() end

        self.ListView = vgui.Create("DListView", leftPanel)
        self.ListView:Dock(FILL)
        self.ListView:SetMultiSelect(false)
        local col1 = self.ListView:AddColumn("Test Name")
        col1:SetWidth(236)
        local col2 = self.ListView:AddColumn("Status")
        col2:SetWidth(64)

        self.ListView.OnRowSelected = function(_, lineId, line)
            self:SelectTest(line:GetValue(1))
        end

        self.ListView.OnRowDoubleClick = function(_, lineId, line)
            self:RunTest(line:GetValue(1))
        end

        -- Divider
        local divider = vgui.Create("DPanel", split)
        divider:Dock(LEFT)
        divider:SetWide(4)
        divider.Paint = function(_, w, h)
            surface.SetDrawColor(50, 50, 50, 255)
            surface.DrawRect(0, 0, w, h)
        end

        -- Right: result + code preview
        local rightPanel = vgui.Create("DPanel", split)
        rightPanel:Dock(FILL)
        rightPanel.Paint = function() end

        self.ResultLabel = vgui.Create("DLabel", rightPanel)
        self.ResultLabel:Dock(TOP)
        self.ResultLabel:DockMargin(6, 4, 6, 4)
        self.ResultLabel:SetTall(18)
        self.ResultLabel:SetText("")
        self.ResultLabel:SetFont("DermaDefaultBold")

        self.CodePreview = vgui.Create("DTextEntry", rightPanel)
        self.CodePreview:Dock(FILL)
        self.CodePreview:SetMultiline(true)
        self.CodePreview:SetEditable(false)
        self.CodePreview:SetValue("← select a test")

        -- ── bottom bar ───────────────────────────────────────
        local bottomBar = vgui.Create("DPanel", self)
        bottomBar:Dock(BOTTOM)
        bottomBar:DockMargin(4, 2, 4, 4)
        bottomBar:SetTall(28)
        bottomBar.Paint = function() end

        self.StatusLabel = vgui.Create("DLabel", bottomBar)
        self.StatusLabel:Dock(FILL)
        self.StatusLabel:SetText("Loading manifest...")

        local runBtn = vgui.Create("DButton", bottomBar)
        runBtn:Dock(RIGHT)
        runBtn:DockMargin(4, 0, 0, 0)
        runBtn:SetWide(130)
        runBtn:SetText("Run Selected")
        runBtn:SetIcon("icon16/control_play.png")
        runBtn.DoClick = function()
            local lineId = self.ListView:GetSelectedLine()
            if not lineId then
                self:SetStatus("Select a test first", true)
                return
            end
            self:RunTest(self.ListView:GetLine(lineId):GetValue(1))
        end

        local errLogBtn = vgui.Create("DButton", bottomBar)
        errLogBtn:Dock(RIGHT)
        errLogBtn:DockMargin(4, 0, 0, 0)
        errLogBtn:SetWide(100)
        errLogBtn:SetText("Error Log")
        errLogBtn:SetIcon("icon16/exclamation.png")
        errLogBtn.DoClick = function() self:OpenErrorLog() end

        -- ── hooks ────────────────────────────────────────────
        hook.Add("Tests_ManifestReceived", self._hookId, function()
            if not IsValid(self) then
                hook.Remove("Tests_ManifestReceived", self._hookId)
                return
            end
            self:PopulateList()
        end)

        hook.Add("Tests_CodeReceived", self._hookId, function(name)
            if not IsValid(self) then return end
            if self._selected == name then
                self.CodePreview:SetValue(tests.Code[name] or "")
            end
        end)

        hook.Add("Tests_ResultReceived", self._hookId, function(name, ok, errMsg)
            if not IsValid(self) then return end
            self:OnResult(name, ok, errMsg)
        end)

        tests.RequestManifest()
    end

    function PANEL:OnRemove()
        if self._hookId then
            hook.Remove("Tests_ManifestReceived", self._hookId)
            hook.Remove("Tests_CodeReceived",     self._hookId)
            hook.Remove("Tests_ResultReceived",   self._hookId)
        end
    end

    function PANEL:PopulateList()
        self.ListView:Clear()
        self._lineForName = {}

        for _, name in ipairs(tests.Names) do
            local res    = tests.Results[name]
            local status = self:StatusText(name)
            local line   = self.ListView:AddLine(name, status)
            self._lineForName[name] = line
            self:ColorLine(line, name)
        end

        local newCount = 0
        for _ in pairs(tests.New) do newCount = newCount + 1 end
        local statusStr = #tests.Names .. " tests  (double-click to run)"
        if newCount > 0 then
            statusStr = statusStr .. "  —  " .. newCount .. " new"
        end
        self:SetStatus(statusStr)
        self:ApplyFilter()
    end

    function PANEL:StatusText(name)
        local res = tests.Results[name]
        if not res      then return tests.New[name] and "new" or "—" end
        if res.running  then return "…"     end
        if res.ok       then return "✓"     end
        return "✗"
    end

    function PANEL:ColorLine(line, name)
        if not IsValid(line) then return end
        local res = tests.Results[name]
        local isNew = tests.New[name] and not res  -- only highlight until first run
        local barCol
        if not res         then barCol = isNew and COL_NEW or Color(90, 90, 90)
        elseif res.running then barCol = COL_RUN
        elseif res.ok      then barCol = COL_PASS
        else                    barCol = COL_FAIL end

        -- DListView_Line has no SetTextColor; override Paint to draw a colored
        -- left-edge bar and manually restore the selection highlight.
        line.Paint = function(pnl, w, h)
            if pnl:IsSelected() then
                surface.SetDrawColor(70, 120, 180, 100)
                surface.DrawRect(0, 0, w, h)
            end
            -- NEW: faint blue background tint for unrun new tests
            if isNew then
                surface.SetDrawColor(90, 160, 255, 18)
                surface.DrawRect(0, 0, w, h)
            end
            surface.SetDrawColor(barCol)
            surface.DrawRect(0, 0, 3, h)
        end
    end

    function PANEL:SelectTest(name)
        self._selected = name

        -- Update result label
        local res = tests.Results[name]
        if res and not res.running then
            if res.ok then
                self.ResultLabel:SetText("PASS")
                self.ResultLabel:SetColor(COL_PASS)
            else
                self.ResultLabel:SetText("FAIL  " .. (res.err or ""))
                self.ResultLabel:SetColor(COL_FAIL)
            end
        else
            self.ResultLabel:SetText("")
        end

        -- Code preview
        if tests.Code[name] then
            self.CodePreview:SetValue(tests.Code[name])
        else
            self.CodePreview:SetValue("Loading...")
            tests.RequestCode(name)
        end
    end

    function PANEL:RunTest(name)
        tests.Results[name] = { running = true }
        local line = self._lineForName[name]
        if IsValid(line) then
            line:SetValue(2, "running…")
            self:ColorLine(line, name)
        end
        if self._selected == name then
            self.ResultLabel:SetText("running…")
            self.ResultLabel:SetColor(COL_RUN)
        end
        self._running = self._running + 1
        self:SetStatus("Running " .. self._running .. " test(s)...")
        tests.RunTest(name)
    end

    function PANEL:RunAll()
        local visible = {}
        for _, line in pairs(self.ListView:GetLines()) do
            if line:IsVisible() then
                table.insert(visible, line:GetValue(1))
            end
        end
        if #visible == 0 then
            self:SetStatus("No tests visible", true)
            return
        end
        for i, name in ipairs(visible) do
            timer.Simple((i - 1) * 0.12, function()
                if not IsValid(self) then return end
                self:RunTest(name)
            end)
        end
    end

    function PANEL:RunNew()
        local newNames = {}
        for _, name in ipairs(tests.Names) do
            if tests.New[name] then
                table.insert(newNames, name)
            end
        end
        if #newNames == 0 then
            self:SetStatus("No new tests to run", true)
            return
        end
        for i, name in ipairs(newNames) do
            timer.Simple((i - 1) * 0.12, function()
                if not IsValid(self) then return end
                self:RunTest(name)
            end)
        end
    end

    function PANEL:OnResult(name, ok, errMsg)
        self._running = math.max(0, self._running - 1)

        local line = self._lineForName[name]
        if IsValid(line) then
            line:SetValue(2, ok and "pass" or "fail")
            self:ColorLine(line, name)
        end

        if self._selected == name then
            if ok then
                self.ResultLabel:SetText("PASS")
                self.ResultLabel:SetColor(COL_PASS)
            else
                self.ResultLabel:SetText("FAIL  " .. (errMsg or ""))
                self.ResultLabel:SetColor(COL_FAIL)
            end
        end

        -- Recount totals
        local passed, failed, pending = 0, 0, 0
        for _, n in ipairs(tests.Names) do
            local r = tests.Results[n]
            if not r or r.running then pending = pending + 1
            elseif r.ok           then passed  = passed  + 1
            else                       failed  = failed  + 1
            end
        end

        local statusStr = string.format(
            "%d/%d  ✓ %d  ✗ %d",
            passed + failed, #tests.Names, passed, failed
        )
        if self._running > 0 then
            statusStr = statusStr .. "  (" .. self._running .. " running)"
        end
        self:SetStatus(statusStr)
    end

    function PANEL:OpenErrorLog()
        local failures = {}
        for _, name in ipairs(tests.Names) do
            local r = tests.Results[name]
            if r and not r.ok and not r.running then
                table.insert(failures, { name = name, err = r.err or "(no message)" })
            end
        end

        if #failures == 0 then
            self:SetStatus("No failures to show — run some tests first", true)
            return
        end

        -- Build log text
        local lines = {
            string.format("=== Error Log  (%d failures) ===", #failures),
            "",
        }
        for _, f in ipairs(failures) do
            table.insert(lines, "✗  " .. f.name)
            table.insert(lines, "   " .. f.err)
            table.insert(lines, "")
        end
        local logText = table.concat(lines, "\n")

        -- Small popup frame
        local frame = vgui.Create("DFrame")
        frame:SetSize(680, 460)
        frame:Center()
        frame:SetTitle("Error Log  —  " .. #failures .. " failed")
        frame:MakePopup()
        frame:SetDeleteOnClose(true)
        frame:SetSizable(true)

        local bar = vgui.Create("DPanel", frame)
        bar:Dock(BOTTOM)
        bar:DockMargin(6, 0, 6, 6)
        bar:SetTall(28)
        bar.Paint = function() end

        local copyBtn = vgui.Create("DButton", bar)
        copyBtn:Dock(RIGHT)
        copyBtn:SetWide(140)
        copyBtn:SetText("Copy to Clipboard")
        copyBtn:SetIcon("icon16/page_copy.png")
        copyBtn.DoClick = function()
            SetClipboardText(logText)
            copyBtn:SetText("Copied!")
            timer.Simple(1.5, function()
                if IsValid(copyBtn) then copyBtn:SetText("Copy to Clipboard") end
            end)
        end

        local txt = vgui.Create("DTextEntry", frame)
        txt:Dock(FILL)
        txt:DockMargin(6, 6, 6, 6)
        txt:SetMultiline(true)
        txt:SetEditable(false)
        txt:SetValue(logText)
    end

    function PANEL:ApplyFilter()
        local q = self.SearchEntry:GetValue():lower()
        for _, line in pairs(self.ListView:GetLines()) do
            local name = line:GetValue(1):lower()
            line:SetVisible(q == "" or string.find(name, q, 1, true) ~= nil)
        end
        self.ListView:InvalidateLayout()
    end

    function PANEL:SetStatus(text, isErr)
        self.StatusLabel:SetText(text)
        self.StatusLabel:SetColor(isErr and COL_FAIL or Color(200, 200, 200))
    end

    vgui.Register("TestRunnerPanel", PANEL, "DFrame")

    -- Singleton open/toggle
    function tests.Open()
        for _, pnl in ipairs(vgui.GetWorldPanel():GetChildren()) do
            if IsValid(pnl) and pnl.ClassName == "TestRunnerPanel" then
                pnl:Close()
                return
            end
        end
        vgui.Create("TestRunnerPanel")
    end

    concommand.Add("test_runner", function()
        tests.Open()
    end)
end
