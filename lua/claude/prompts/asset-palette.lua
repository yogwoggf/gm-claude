-- Verified asset palette, injected into the coder's context so the common case
-- never needs a search_files / is_valid_model round: the model starts already
-- holding a set of known-good paths (which also stops it hallucinating them).
--
-- CANDIDATES lists well-known HL2/GMod-default paths; every entry is verified
-- against THIS server's mounted content on first use, so a typo or an unmounted
-- pack silently drops the entry instead of poisoning the palette. The rendered
-- text is cached per playbook kind — it's byte-stable after the first build,
-- which keeps the prompt prefix cache-friendly.

local CANDIDATES = {
  viewmodels = { -- all c_* (need UseHands = true)
    "models/weapons/c_pistol.mdl", "models/weapons/c_357.mdl",
    "models/weapons/c_smg1.mdl", "models/weapons/c_irifle.mdl",
    "models/weapons/c_shotgun.mdl", "models/weapons/c_rpg.mdl",
    "models/weapons/c_crossbow.mdl", "models/weapons/c_grenade.mdl",
    "models/weapons/c_crowbar.mdl", "models/weapons/c_stunstick.mdl",
    "models/weapons/c_physcannon.mdl", "models/weapons/c_slam.mdl",
  },
  worldmodels = {
    "models/weapons/w_pistol.mdl", "models/weapons/w_357.mdl",
    "models/weapons/w_smg1.mdl", "models/weapons/w_irifle.mdl",
    "models/weapons/w_shotgun.mdl", "models/weapons/w_rocket_launcher.mdl",
    "models/weapons/w_crossbow.mdl", "models/weapons/w_grenade.mdl",
    "models/weapons/w_crowbar.mdl", "models/weapons/w_stunstick.mdl",
    "models/weapons/w_physics.mdl", "models/weapons/w_slam.mdl",
  },
  props = {
    "models/props_c17/oildrum001.mdl", "models/props_c17/oildrum001_explosive.mdl",
    "models/props_junk/wood_crate001a.mdl", "models/props_junk/watermelon01.mdl",
    "models/props_junk/sawblade001a.mdl", "models/props_junk/garbage_metalcan001a.mdl",
    "models/props_borealis/bluebarrel001.mdl", "models/props_combine/combine_mine01.mdl",
    "models/props_c17/canister01a.mdl", "models/props_lab/huladoll.mdl",
    "models/combine_helicopter/helicopter_bomb01.mdl", "models/dav0r/hoverball.mdl",
    "models/hunter/blocks/cube025x025x025.mdl", "models/hunter/plates/plate1x1.mdl",
  },
  materials = { -- sprites / beams / trails (TexturedQuad, render.DrawBeam, util.SpriteTrail)
    "sprites/light_glow02_add", "sprites/glow04_noz", "sprites/animglow02",
    "sprites/heatwave", "sprites/physbeam",
    "effects/laser1", "effects/blueblacklargebeam", "effects/spark",
    "effects/blueflare1", "effects/tool_tracer", "effects/select_ring",
    "trails/laser", "trails/smoke", "trails/plasma", "trails/electric", "trails/tube",
    "cable/rope", "cable/cable2", "cable/redlaser", "cable/blue_elec", "cable/physbeam",
    "particle/particle_smokegrenade", "particle/particle_glow_04",
  },
  gunSounds = {
    "weapons/pistol/pistol_fire2.wav", "weapons/357/357_fire2.wav",
    "weapons/smg1/smg1_fire1.wav", "weapons/ar2/fire1.wav",
    "weapons/shotgun/shotgun_fire7.wav", "weapons/rpg/rocketfire1.wav",
    "weapons/crossbow/fire1.wav", "weapons/pistol/pistol_reload1.wav",
    "weapons/ar2/ar2_reload.wav", "weapons/physcannon/superphys_launch1.wav",
  },
  impactSounds = {
    "weapons/explode3.wav", "weapons/explode4.wav", "weapons/explode5.wav",
    "ambient/explosions/explode_4.wav", "ambient/energy/zap1.wav",
    "ambient/energy/zap9.wav", "ambient/energy/spark5.wav", "ambient/energy/weld2.wav",
    "weapons/physcannon/energy_sing_flyby1.wav", "weapons/fx/rics/ric4.wav",
  },
  uiSounds = {
    "ui/buttonclick.wav", "ui/buttonclickrelease.wav", "ui/buttonrollover.wav",
    "buttons/button14.wav", "buttons/button15.wav", "buttons/button17.wav",
    "buttons/blip1.wav", "buttons/combine_button1.wav",
  },
}

local VERIFIERS = {
  viewmodels = util.IsValidModel, worldmodels = util.IsValidModel, props = util.IsValidModel,
  materials = function(p) return file.Exists("materials/" .. p .. ".vmt", "GAME") end,
  gunSounds = function(p) return file.Exists("sound/" .. p, "GAME") end,
}
VERIFIERS.impactSounds, VERIFIERS.uiSounds = VERIFIERS.gunSounds, VERIFIERS.gunSounds

-- Which palette sections each playbook kind pays for. Keep each kind's set lean:
-- this text rides on EVERY prompt of that kind.
local SECTIONS_BY_KIND = {
  swep   = {"viewmodels", "worldmodels", "gunSounds", "impactSounds", "materials"},
  sent   = {"props", "impactSounds", "materials", "uiSounds"},
  effect = {"materials", "impactSounds", "props"},
  ui     = {"uiSounds", "materials"},
  logic  = {"props", "impactSounds", "uiSounds"},
}

local LABELS = {
  viewmodels = "Viewmodels (c_*, set UseHands = true)",
  worldmodels = "Worldmodels (w_*)",
  props = "Props",
  materials = "Sprite/beam/trail materials (use with Material(path))",
  gunSounds = "Weapon sounds",
  impactSounds = "Explosion/energy/impact sounds",
  uiSounds = "UI/click sounds",
}

local Palette = {}

local verified = nil -- section -> verified list, built once
local textByKind = {} -- kind -> rendered block, built once per kind

local function verifiedSection(section)
  if not verified then verified = {} end
  if verified[section] then return verified[section] end

  local ok = {}
  local check = VERIFIERS[section]
  for _, path in ipairs(CANDIDATES[section]) do
    if check(path) then ok[#ok + 1] = path end
  end
  verified[section] = ok
  return ok
end

--- The rendered palette block for a playbook kind. Cached; byte-stable per kind.
--- @param kind string|nil one of playbooks.kinds
--- @return string
function Palette.get(kind)
  kind = SECTIONS_BY_KIND[kind] and kind or "logic"
  if textByKind[kind] then return textByKind[kind] end

  local lines = {
    "# Verified asset palette",
    "Every path below has been checked against THIS server's mounted content. Use them directly — do NOT call is_valid_model / is_valid_material / search_files on them. Only reach for those tools when you need an asset that is not in this palette (then batch all such checks into a single round).",
  }
  for _, section in ipairs(SECTIONS_BY_KIND[kind]) do
    local paths = verifiedSection(section)
    if #paths > 0 then
      lines[#lines + 1] = string.format("- %s: %s", LABELS[section], table.concat(paths, ", "))
    end
  end

  textByKind[kind] = table.concat(lines, "\n")
  return textByKind[kind]
end

return Palette
