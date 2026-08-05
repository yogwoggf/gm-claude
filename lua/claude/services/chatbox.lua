-- Literal port of hud_basechat.cpp and hud_basechat.h from Source.
-- Chat is now down via network messages so we can send messages of any size, not just 127 chars.

AddCSLuaFile()

local chatbox = {}

local MAX_CHARS = 2000
local SAY_COOLDOWN = 0.4

if SERVER then
  util.AddNetworkString("claude.chatbox.say")
  util.AddNetworkString("claude.chatbox.msg")
  util.AddNetworkString("claude.chatbox.commands")

  net.Receive("claude.chatbox.commands", function(_, ply)
    local runner = _G.GilbCommandRunner
    if not runner then return end

    net.Start("claude.chatbox.commands")
    net.WriteString(util.TableToJSON(runner.manifest()))
    net.Send(ply)
  end)

  local lastSay = {}

  net.Receive("claude.chatbox.say", function(_, ply)
    if not IsValid(ply) then return end
    if (lastSay[ply] or 0) + SAY_COOLDOWN > CurTime() then return end
    lastSay[ply] = CurTime()

    local text = string.Trim(string.sub(net.ReadString(), 1, MAX_CHARS))
    local teamChat = net.ReadBool()
    if text == "" then return end

    -- Run the hook first, so other addons can intercept it like it's normal.
    local result = hook.Run("PlayerSay", ply, text, teamChat)
    if result == "" then return end
    if isstring(result) then text = result end
    if text == "" then return end

    net.Start("claude.chatbox.msg")
    net.WriteEntity(ply)
    net.WriteString(text)
    net.WriteBool(teamChat)
    if teamChat then net.Send(team.GetPlayers(ply:Team())) else net.Broadcast() end
  end)

  hook.Add("PlayerDisconnected", "claude.chatbox", function(ply)
    lastSay[ply] = nil
  end)

  return chatbox
end


-- Don't know why you'd do this
local enabled = CreateClientConVar("claude_chatbox", "1", true, false,
  "Use the gm-claude chatbox instead of GMod's.")

local FONT = "ChatFont"

-- hud_basechat.cpp: the g_Color* globals.
local COLOR_BLUE      = Color(153, 204, 255)
local COLOR_RED       = Color(255, 63, 63)
local COLOR_GREEN     = Color(153, 255, 153)
local COLOR_DARKGREEN = Color(64, 255, 64)
local COLOR_YELLOW    = Color(255, 178, 0)
local COLOR_GREY      = Color(204, 204, 204)

chatbox.Colors = {
  blue = COLOR_BLUE, red = COLOR_RED, green = COLOR_GREEN,
  darkgreen = COLOR_DARKGREEN, yellow = COLOR_YELLOW, grey = COLOR_GREY,
}

-- GetDefaultTextColor() returns g_ColorYellow; GetClientColor() returns green for
-- console (index 0) and grey for a real player.
local COLOR_DEFAULT = COLOR_YELLOW
local COLOR_CONSOLE = COLOR_BLUE
local COLOR_PLAYER  = COLOR_YELLOW -- Changed in GMod to be yellow.

-- All from hud_basechat.h.
local SAYTEXT_TIME   = 12    -- ConVar hud_saytext_time
local HISTORY_ALPHA  = 127   -- CHAT_HISTORY_ALPHA
local FADE_TIME      = 0.25  -- CHAT_HISTORY_FADE_TIME
local IDLE_TIME      = 15    -- CHAT_HISTORY_IDLE_TIME (unused: InsertFade owns line lifetime)
local IDLE_FADE_TIME = 2.5   -- CHAT_HISTORY_IDLE_FADE_TIME

-- CBaseHudChat::OnTick(): the input line sits at chatH - fontHeight*1.75 and the
-- history stops at chatH - fontHeight*2.25.
local INPUT_OFFSET   = 1.75
local HISTORY_OFFSET = 2.25
local PROMPT_INSET   = 2 -- m_pPrompt->SetTextInset(2, 0)
local INPUT_GAP      = 2 -- m_pInput->SetBounds(w + 2, ...)

-- resource/UI/BaseChat.res, in Source's 640x480 proportional space. Scaled by
-- ScrH()/480, which is how vgui scales HUD .res coordinates.
local RES_X, RES_Y, RES_W, RES_H = 10, 275, 320, 120 -- HudChat
local RES_HIST_X, RES_HIST_Y, RES_HIST_W = 10, 17, 300 -- HudChatHistory
local RES_MAXCHARS = 64000 -- HudChatHistory "maxchars"

-- Escape hatch in case GMod's proportional scaling does not match Source's.
local cvScale = CreateClientConVar("claude_chatbox_scale", "1", true, false,
  "Multiplier on the chatbox's BaseChat.res proportions.")

local function scaled(v)
  return math.floor(v * (ScrH() / 480) * cvScale:GetFloat())
end

local panel, history, prompt, entry
local messageMode = 0 -- MM_NONE / MM_SAY / MM_SAY_TEAM
local historyFadeTime = 0 -- m_flHistoryFadeTime

--- CBaseHudChat::OnTick uses surface()->GetFontTall(font) + 2.
local function fontHeight()
  surface.SetFont(FONT)
  local _, h = surface.GetTextSize("Wg")
  return h + 2
end

local function chatBounds()
  return scaled(RES_X), scaled(RES_Y), scaled(RES_W), scaled(RES_H)
end

local commands = {}
local suggestions = {}
local suggestIndex = 1

local COLOR_CMD_OK  = Color(120, 220, 130) -- a trigger the server knows
local COLOR_CMD_BAD = Color(230, 110, 110) -- one it does not
local COLOR_ARG     = Color(150, 190, 235)
local MAX_SUGGESTIONS = 6
local TEXT_INSET    = 3 -- DTextEntry's own left inset, so highlights line up

--- "<prompt...>" for a consumeAll arg, "<index>" otherwise.
local function argHint(command)
  local parts = {}
  for _, arg in ipairs(command.args or {}) do
    parts[#parts + 1] = "<" .. arg.name .. (arg.consumeAll and "..." or "") .. ">"
  end
  return table.concat(parts, " ")
end

--- Clip to a pixel width, ending in "..." when it does not fit. Binary search
--- rather than trimming a character at a time, and memoised because the same few
--- descriptions get measured every frame the list is up.
local truncCache = {}
local function truncate(text, maxWidth)
  if maxWidth <= 0 then return "" end

  local key = text .. "\0" .. maxWidth
  local hit = truncCache[key]
  if hit then return hit end

  surface.SetFont(FONT)
  local result = text
  if surface.GetTextSize(text) > maxWidth then
    local room = maxWidth - surface.GetTextSize("...")
    if room <= 0 then
      result = ""
    else
      local lo, hi = 0, #text
      while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if surface.GetTextSize(string.sub(text, 1, mid)) <= room then
          lo = mid
        else
          hi = mid - 1
        end
      end
      result = string.Trim(string.sub(text, 1, lo)) .. "..."
    end
  end

  truncCache[key] = result
  return result
end

--- The leading !trigger, or nil. Same split the runner does, so what highlights
--- green is exactly what would actually run.
local function parseTrigger(text)
  return string.match(text or "", "^!([%w_]*)")
end

local function updateSuggestions()
  suggestions = {}
  suggestIndex = 1
  if not IsValid(entry) then return end

  local text = entry:GetValue() or ""
  local trigger = parseTrigger(text)
  -- Only while still typing the trigger itself: once there is a space the player
  -- is writing arguments and a dropdown would be in the way.
  if not trigger or string.find(text, " ", 1, true) then return end

  local lower = string.lower(trigger)
  for name, command in pairs(commands) do
    if string.sub(name, 1, #lower) == lower then
      suggestions[#suggestions + 1] = command
    end
  end
  table.sort(suggestions, function(a, b) return a.trigger < b.trigger end)
end

local function applySuggestion()
  local pick = suggestions[suggestIndex]
  if not pick or not IsValid(entry) then return false end

  local text = "!" .. pick.trigger .. " "
  entry:SetText(text)
  if entry.SetCaretPos then entry:SetCaretPos(#text) end
  updateSuggestions()
  return true
end

local function stopMessageMode()
  messageMode = 0
  if not IsValid(panel) then return end

  -- We handle escape in OnPauseMenuShow.
  panel:SetKeyboardInputEnabled(false)
  panel:SetMouseInputEnabled(false)
  gui.EnableScreenClicker(false)

  historyFadeTime = CurTime() + FADE_TIME
  history:SetMouseInputEnabled(false)
  history:SetVerticalScrollbarEnabled(false)
  history:ResetAllFades(false, true, FADE_TIME)
  history:GotoTextEnd()
  if IsValid(entry) then entry:SetText("") end
  if IsValid(prompt) then prompt:SetVisible(false) end
  if IsValid(entry) then entry:SetVisible(false) end

  hook.Run("FinishChat")
end

local function send()
  if not IsValid(entry) then return end
  local text = string.Trim(entry:GetValue() or "")
  local teamChat = messageMode == 2

  if text ~= "" then
    net.Start("claude.chatbox.say")
    net.WriteString(string.sub(text, 1, MAX_CHARS))
    net.WriteBool(teamChat)
    net.SendToServer()
  end
  stopMessageMode()
end

local function layout()
  if not IsValid(panel) then return end

  local x, y, w, h = chatBounds()
  local fh = fontHeight()
  panel:SetPos(x, y)
  panel:SetSize(w, h)

  -- OnTick() recomputes both children's Y and height from the font, keeping only
  -- X and width from the .res. Panel has no SetBounds in GMod: SetPos + SetSize.
  local hx, hy, hw = scaled(RES_HIST_X), scaled(RES_HIST_Y), scaled(RES_HIST_W)
  local historyH = math.floor(h - fh * HISTORY_OFFSET - hy)
  history:SetPos(hx, hy)
  history:SetSize(hw, historyH)
  panel.backing:SetPos(hx, hy)
  panel.backing:SetSize(hw, historyH)

  -- CBaseHudChatInputLine::PerformLayout: prompt takes its content width, the
  -- entry takes the rest of the line.
  surface.SetFont(FONT)
  local pw = surface.GetTextSize(prompt:GetText() or "") + PROMPT_INSET * 2
  local inputY = math.floor(h - fh * INPUT_OFFSET)

  -- Sits directly above the input line, growing upward.
  if IsValid(panel.suggest) then
    panel.suggest:SetPos(hx, 0)
    panel.suggest:SetSize(hw, inputY)
  end

  prompt:SetPos(hx, inputY)
  prompt:SetSize(pw, fh)
  entry:SetPos(hx + pw + INPUT_GAP, inputY)
  entry:SetSize(hw - pw - INPUT_GAP, fh)
end

local function startMessageMode(team)
  if not IsValid(panel) then return end
  messageMode = team and 2 or 1

  entry:SetText("")
  -- StartMessageMode(): "Say :" / "Say (TEAM) :"
  prompt:SetText(team and "Say (TEAM) :" or "Say :")
  prompt:SetVisible(true)
  entry:SetVisible(true)
  layout()

  historyFadeTime = CurTime() + FADE_TIME
  -- StartMessageMode(): the history takes MOUSE input (so the scrollbar works)
  -- but never keyboard, or it steals typing from the entry.
  history:SetMouseInputEnabled(true)
  history:SetKeyboardInputEnabled(false)
  history:SetVerticalScrollbarEnabled(true)
  -- ResetAllFades(true). Without this, every line whose InsertFade has expired
  -- stays invisible forever - opening the box shows an empty history.
  history:ResetAllFades(true, false, -1)
  history:GotoTextEnd()

  panel:SetAlpha(255)
  panel:SetKeyboardInputEnabled(true)
  panel:SetMouseInputEnabled(true)
  gui.EnableScreenClicker(true)
  entry:RequestFocus()

  -- "Place the mouse cursor near the text so people notice it." Also means the
  -- wheel is already over the history, so scrolling works without hunting.
  local hw, hh = history:GetSize()
  input.SetCursorPos(history:LocalToScreen(math.floor(hw / 2), math.floor(hh / 2)))

  hook.Run("StartChat")
end

--------------------------------------------------------------------------------

local function build()
  panel = vgui.Create("EditablePanel")
  panel:SetPaintBackgroundEnabled(false)
  panel:MakePopup()
  panel:SetKeyboardInputEnabled(false)
  panel:SetMouseInputEnabled(false)
  panel:SetZPos(-30) -- SetZPos(-30)

  history = vgui.Create("RichText", panel)
  history:SetVerticalScrollbarEnabled(false)
  history:SetBGColor(0, 0, 0, 0)
  history:SetMaximumCharCount(RES_MAXCHARS)
  -- CHudChatHistory's constructor does InsertFade(-1, -1).
  history:InsertFade(-1, -1)
  -- RichText ignores the font until its scheme is applied, so re-apply on layout.
  history.PerformLayout = function(self)
    self:SetFontInternal(FONT)
    self:SetFGColor(255, 255, 255, 255)
  end

  -- The history's dark backing. CBaseHudChatLine uses Color(0,0,0,100); the panel
  -- behind it uses CHAT_HISTORY_ALPHA.
  local backing = vgui.Create("DPanel", panel)
  backing:SetMouseInputEnabled(false)
  backing.Paint = function(_, w, h)
    local frac = (historyFadeTime - CurTime()) / FADE_TIME
    local a = math.Clamp(frac * HISTORY_ALPHA, 0, HISTORY_ALPHA)
    local bg = messageMode ~= 0 and (HISTORY_ALPHA - a) or a
    if bg <= 0 then return end

    surface.SetDrawColor(0, 0, 0, bg)
    surface.DrawRect(0, 0, w, h)
  end
  backing:MoveToBack()
  panel.backing = backing

  prompt = vgui.Create("DLabel", panel)
  prompt:SetFont(FONT)
  prompt:SetTextColor(color_white)
  prompt:SetContentAlignment(4) -- a_west
  prompt:SetTextInset(PROMPT_INSET, 0)
  prompt:SetVisible(false)

  entry = vgui.Create("DTextEntry", panel)
  entry:SetFont(FONT)
  entry:SetVisible(false)
  entry.Paint = function(self, w, h)
    surface.SetDrawColor(0, 0, 0, HISTORY_ALPHA)
    surface.DrawRect(0, 0, w, h)

    -- Highlight is drawn BEHIND the text rather than colouring it.
    local text = self:GetValue() or ""
    local trigger = parseTrigger(text)
    if trigger and trigger ~= "" then
      surface.SetFont(FONT)
      local tw = surface.GetTextSize("!" .. trigger)
      local col = commands[string.lower(trigger)] and COLOR_CMD_OK or COLOR_CMD_BAD
      surface.SetDrawColor(col.r, col.g, col.b, 55)
      surface.DrawRect(TEXT_INSET, 1, tw, h - 2)
    end

    self:DrawTextEntryText(color_white, Color(30, 130, 255), color_white)
  end
  entry.OnEnter = send
  -- CBaseHudChatEntry::OnKeyCodeTyped: Enter/PadEnter send then close, Escape
  -- just closes, and Tab is swallowed -- "Ignore tab, otherwise vgui will screw
  -- up the focus."
  entry.OnTextChanged = updateSuggestions
  entry.OnKeyCodeTyped = function(self, key)
    if key == KEY_ENTER or key == KEY_PAD_ENTER then send() return true end
    if key == KEY_ESCAPE then stopMessageMode() return true end

    -- Tab was already swallowed on Valve's advice ("otherwise vgui will screw up
    -- the focus"), so completing on it costs nothing.
    if key == KEY_TAB then applySuggestion() return true end

    if #suggestions > 1 then
      if key == KEY_DOWN then
        suggestIndex = suggestIndex % #suggestions + 1
        return true
      elseif key == KEY_UP then
        suggestIndex = (suggestIndex - 2) % #suggestions + 1
        return true
      end
    end
  end

  -- Suggestions render inside the popup.
  local suggest = vgui.Create("DPanel", panel)
  suggest:SetMouseInputEnabled(false)
  suggest:SetPaintBackgroundEnabled(false)
  panel.suggest = suggest
  suggest.Paint = function(_, w, h)
    if messageMode == 0 or #suggestions == 0 then return end

    surface.SetFont(FONT)
    local fh = fontHeight()
    local rows = math.min(#suggestions, MAX_SUGGESTIONS)
    local top = h - rows * fh

    surface.SetDrawColor(0, 0, 0, HISTORY_ALPHA)
    surface.DrawRect(0, top, w, rows * fh)

    for i = 1, rows do
      local command = suggestions[i]
      local y = top + (i - 1) * fh
      if i == suggestIndex then
        surface.SetDrawColor(COLOR_CMD_OK.r, COLOR_CMD_OK.g, COLOR_CMD_OK.b, 40)
        surface.DrawRect(0, y, w, fh)
      end

      local label = "!" .. command.trigger
      draw.SimpleText(label, FONT, TEXT_INSET, y, COLOR_CMD_OK)
      local x = TEXT_INSET + surface.GetTextSize(label) + 6

      local hint = argHint(command)
      if hint ~= "" then
        draw.SimpleText(hint, FONT, x, y, COLOR_ARG)
        x = x + surface.GetTextSize(hint) + 8
      end
      if command.description then
        draw.SimpleText(truncate(command.description, w - x - TEXT_INSET),
          FONT, x, y, COLOR_GREY)
      end
    end
  end

  -- Backstop: never let the panel hold input while ignoring it.
  panel.Think = function(self)
    if not enabled:GetBool() and messageMode ~= 0 then stopMessageMode() return end
    if messageMode == 0 then return end
    -- OnPauseMenuShow handles Escape; this catches the game UI arriving any
    -- other way (alt-tab, Shift+Escape) rather than leaving us holding input.
    if gui.IsGameUIVisible() then stopMessageMode() return end
    if not IsValid(entry) or not entry:HasFocus() then
      if not self.graceUntil then self.graceUntil = CurTime() + 0.5 end
      if CurTime() > self.graceUntil then
        self.graceUntil = nil
        stopMessageMode()
      end
    else
      self.graceUntil = nil
    end
  end

  layout()
end

hook.Add("InitPostEntity", "claude.chatbox.build", function()
  if not enabled:GetBool() then return end
  local ok, err = pcall(build)
  if ok then return end
  if IsValid(panel) then panel:Remove() end
  panel = nil
  ErrorNoHalt("[gm-claude] chatbox failed to build: " .. tostring(err) .. "\n")
end)

--------------------------------------------------------------------------------

cvars.AddChangeCallback("claude_chatbox_scale", function()
  if IsValid(panel) then layout() end
end, "claude.chatbox")

hook.Add("HUDShouldDraw", "claude.chatbox", function(name)
  if name == "CHudChat" and IsValid(panel) then return false end
end)

-- GMod's answer to gameui_preventescapetoshow, which the C++ uses here and which
-- GMod blocks. Escape closes the box instead of opening the pause menu; the
-- entry's OnKeyCodeTyped does the closing, this just stops the menu.
-- Shift+Escape still bypasses it, so nobody can be trapped.
net.Receive("claude.chatbox.commands", function()
  local list = util.JSONToTable(net.ReadString() or "") or {}
  commands = {}
  for _, command in ipairs(list) do
    commands[string.lower(command.trigger)] = command
  end
  updateSuggestions()
end)

hook.Add("InitPostEntity", "claude.chatbox.commands", function()
  net.Start("claude.chatbox.commands")
  net.SendToServer()
end)

hook.Add("OnPauseMenuShow", "claude.chatbox", function()
  if messageMode == 0 then return end
  stopMessageMode()
  return false
end)

hook.Add("PlayerBindPress", "claude.chatbox", function(_, bind, pressed)
  if not pressed or not enabled:GetBool() or not IsValid(panel) then return end
  if bind ~= "messagemode" and bind ~= "messagemode2" then return end

  -- Only swallow the bind if we actually opened. If startMessageMode throws, the
  -- engine chatbox opens instead of the player having no chat at all — but it
  -- MUST be all-or-nothing: both boxes open at once means the engine steals our
  -- focus and the focus guard shuts us straight back down.
  local ok, err = pcall(startMessageMode, bind == "messagemode2")
  if ok then return true end

  stopMessageMode()
  ErrorNoHalt("[gm-claude] chatbox failed to open: " .. tostring(err) .. "\n")
end)

-- The panel itself stays fully opaque: text lines fade individually via
-- InsertFade and the backing fades on its own clock above. Fading the panel too
-- would take the text with it.

--------------------------------------------------------------------------------

--- Append coloured segments, the way ChatPrintf -> InsertAndColorizeText does.
-- Saved before the override below, and used whenever our history is not up yet
-- (early boot, or a failed build) so nothing is ever silently swallowed.
local engineAddText = chat.AddText

function chatbox.AddText(...)
  if not IsValid(history) then return engineAddText(...) end

  history:InsertColorChange(COLOR_DEFAULT.r, COLOR_DEFAULT.g, COLOR_DEFAULT.b, 255)
  for _, part in ipairs({...}) do
    if IsColor(part) then
      history:InsertColorChange(part.r, part.g, part.b, part.a or 255)
    elseif isstring(part) then
      history:AppendText(part)
    elseif IsEntity(part) and part:IsPlayer() then
      history:InsertColorChange(COLOR_PLAYER.r, COLOR_PLAYER.g, COLOR_PLAYER.b, 255)
      history:AppendText(part:Nick())
    else
      history:AppendText(tostring(part))
    end
    -- Colorize(): every segment gets the fade, then the line is closed with
    -- InsertFade(-1, -1) so later text is not swept up in it.
    history:InsertFade(SAYTEXT_TIME, IDLE_FADE_TIME)
  end
  history:AppendText("\n")
  history:InsertFade(-1, -1)
  history:GotoTextEnd()

  if IsValid(panel) then panel:SetAlpha(255) end
end

net.Receive("claude.chatbox.msg", function()
  local ply = net.ReadEntity()
  local text = net.ReadString()
  local teamChat = net.ReadBool()
  if not IsValid(ply) then return end

  -- Give other addons the hook a normal `say` would have fired.
  if hook.Run("OnPlayerChat", ply, text, teamChat, not ply:Alive()) then return end

  if teamChat then
    chatbox.AddText(COLOR_DARKGREEN, "(TEAM) ", COLOR_PLAYER, ply:Nick(), COLOR_DEFAULT, ": ", text)
  else
    chatbox.AddText(COLOR_PLAYER, ply:Nick(), COLOR_DEFAULT, ": ", text)
  end
  chat.PlaySound()
end)

-- chat.AddText writes straight into GMod's chatbox, which we hide, so every
-- caller in the addon (and the base gamemode's own OnPlayerChat) would render
-- into an invisible panel. Redirect it at the source instead of chasing callers.
chat.AddText = chatbox.AddText

local trace = CreateClientConVar("claude_chatbox_trace", "0", false, false,
  "Log every ChatText the chatbox receives, with its type.")

-- Player:ChatPrint and the engine's system messages do NOT go through
-- chat.AddText -- they render directly into GMod's chatbox, which we hide. So
-- redirecting chat.AddText was not enough on its own.
hook.Add("ChatText", "claude.chatbox", function(index, name, text, kind)
  if not IsValid(history) then return end
  if trace:GetBool() then
    print(string.format("[gm-claude] ChatText index=%s name=%q type=%q text=%q",
      tostring(index), tostring(name), tostring(kind), tostring(text)))
  end

  -- GetClientColor(0) is green for anything console/server originated.
  chatbox.AddText(COLOR_CONSOLE, text)
  return true -- suppress the render into the hidden box
end)


concommand.Add("claude_chatbox_close", function()
  stopMessageMode()
  print("[gm-claude] Chatbox closed.")
end, nil, "Escape hatch: force the chatbox out of message mode.")

concommand.Add("claude_chatbox_reload", function()
  if IsValid(panel) then panel:Remove() end
  panel = nil
  local ok, err = pcall(build)
  print("[gm-claude] chatbox rebuild ok=" .. tostring(ok) .. (ok and "" or ("  " .. tostring(err))))
  if IsValid(panel) then
    local x, y = panel:GetPos()
    print(string.format("[gm-claude] panel at %d,%d size %dx%d", x, y, panel:GetWide(), panel:GetTall()))
  end
end, nil, "Rebuild the chatbox without rejoining.")

return chatbox
