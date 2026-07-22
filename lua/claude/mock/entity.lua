-- Runs some tests on a mock entity.

local TICKS = 5
local PARK_POS = Vector(0, 0, 16000) -- high above any playable area, out of the way

local Entity = {}

function Entity:run(class, done)
  local e = ents.Create(class)
  if not IsValid(e) then
    print("[gm-claude] Mock: could not create SENT '" .. tostring(class) .. "'")
    return done()
  end

  e:SetPos(PARK_POS)
  e:Spawn()     -- fires Initialize
  e:Activate()

  if isfunction(e.Think) then
    for _ = 1, TICKS do
      if not IsValid(e) then break end -- Think may remove the entity itself
      e:Think()
    end
  end

  if IsValid(e) then e:Remove() end
  done()
end

return Entity
