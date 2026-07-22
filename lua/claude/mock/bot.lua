-- A throwaway bot for exercising SWEPs.

local enabled = CreateConVar("claude_mock_bot", "1", FCVAR_ARCHIVE,
  "Allow the mock harness to spawn a bot to exercise SWEPs on the server")
local PARK_POS = Vector(0, 0, 16000)
local POLL_INTERVAL = 0.25
local POLL_TRIES = 20 -- ~5s, comfortably under the 30s tool timeout

local Bot = {}

local function park(ply)
  ply:SetPos(PARK_POS)
  ply:GodEnable()
  ply:Freeze(true)
  ply:SetNoDraw(true)
  ply:SetNoTarget(true)
end

--- Spawn a fresh bot and hand it to cb once it has spawned in and been parked.
--- cb(nil) if we can't or it doesn't show up in time. Always pair with release().
function Bot:acquire(cb)
  if not enabled:GetBool() then return cb(nil) end
  if game.MaxPlayers() <= player.GetCount() then return cb(nil) end

  -- Remember which bots already existed so we can pick out the one we spawn.
  local before = {}
  for _, p in ipairs(player.GetBots()) do before[p] = true end

  RunConsoleCommand("bot")

  local id = "claude.mock.bot." .. tostring(SysTime())
  local tries = 0
  timer.Create(id, POLL_INTERVAL, POLL_TRIES, function()
    tries = tries + 1
    for _, p in ipairs(player.GetBots()) do
      if IsValid(p) and not before[p] and p:Alive() then
        timer.Remove(id)
        park(p)
        cb(p)
        return
      end
    end
    if tries >= POLL_TRIES then
      timer.Remove(id)
      cb(nil)
    end
  end)
end

--- Kick a bot returned by acquire, as soon as the driver is finished with it.
function Bot:release(ply)
  if IsValid(ply) and ply:IsBot() then
    ply:Kick("gm-claude: mock exercise complete")
  end
end

return Bot
