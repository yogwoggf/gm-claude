-- Wraps the asynchronous nature of player clarifications (we must wait until the user types again)

if _G.GilbClarify then return _G.GilbClarify end

local CLARIFY_TIMEOUT = 120 -- seconds to wait for the player before giving up

local Clarify = {}
Clarify.__index = Clarify

local pending = {} -- [player] = { resolve = fun(answer|nil), timer = string }

--- Asks a player a question and waits for their next chat line as the answer. Answer is
--- passed to callback, or nil if the player didn't answer in time.
function Clarify:ask(player, question, callback)
  if not IsValid(player) then
    callback(nil)
    return
  end

  self:cancel(player) -- drop any prior outstanding question for this player

  net.Start("claude.chat")
  net.WriteString(question)
  net.Send(player)

  local timerName = "claude.clarify." .. player:SteamID64() .. "." .. tostring(math.random(1, 1e9))
  pending[player] = { resolve = callback, timer = timerName }

  timer.Create(timerName, CLARIFY_TIMEOUT, 1, function()
    local entry = pending[player]
    if not entry then return end
    pending[player] = nil
    entry.resolve(nil)
  end)
end

function Clarify:cancel(player)
  local entry = pending[player]
  if not entry then return end
  pending[player] = nil
  timer.Remove(entry.timer)
end

function Clarify:consume(player, text)
  local entry = pending[player]
  if not entry then return false end

  pending[player] = nil
  timer.Remove(entry.timer)
  entry.resolve(text)
  return true
end

_G.GilbClarify = Clarify
return Clarify
