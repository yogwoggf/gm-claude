-- SWEP driver: give the weapon to a throwaway bot and call its server-side methods
-- (Deploy, PrimaryAttack, ...) with a real owner, so an attack that indexes a nil
-- field or misuses a GMod API errors here instead of the first time a player fires.
--
-- Needs a valid owner to be realistic — a weapon with no owner would error in setup
-- and produce false positives — so it relies on the mock bot. When the bot is
-- disabled or not yet available, SWEP exercise is simply skipped (clientside SWEP
-- errors are still caught via the OnLuaError siphon).

---@module "lua.claude.mock.bot"
local bot = include("claude/mock/bot.lua")

-- Server-side methods worth driving. Deploy/Holster bracket the "in hand" lifecycle;
-- the attacks/reload/think are where runtime bugs usually live.
local METHODS = { "Deploy", "PrimaryAttack", "SecondaryAttack", "Reload", "Think", "Holster" }

local Weapon = {}

function Weapon:run(class, done)
  -- Async: a bot has to spawn in before it can hold the weapon. It's kicked as soon
  -- as we're done, so nothing lingers on the server.
  bot:acquire(function(b)
    if not IsValid(b) then return done() end -- disabled / full / never spawned; skip

    b:StripWeapons()
    b:Give(class)
    local wep = b:GetWeapon(class)
    if not IsValid(wep) then
      print("[gm-claude] Mock: bot did not receive SWEP '" .. tostring(class) .. "'")
      bot:release(b)
      return done()
    end

    for _, m in ipairs(METHODS) do
      if IsValid(wep) and isfunction(wep[m]) then
        wep[m](wep) -- wrapped method; any error is caught + reported via the interceptor
      end
    end

    bot:release(b)
    done()
  end)
end

return Weapon
