-- The mock harness.
--
-- After AI code runs, drive the entry points it registered — a SENT's Think, a
-- SWEP's PrimaryAttack/Deploy, and so on — so runtime errors that would otherwise
-- only fire when a real player later triggers them surface *now*, inside the coding
-- turn. The wrapped callbacks (sandbox.lua) already catch and report those errors;
-- the harness just provokes them, collecting the results through a temporary bus
-- interceptor so exercising doesn't itself trip the auto-repair threshold.
--
-- Everything here is best-effort and heavily guarded: a fault in the harness must
-- never break the actual build, so a driver that throws during setup is logged and
-- treated as "nothing to report".

-- include() re-runs the file; keep one shared instance so the registry set by the
-- sandbox and the exercise() called by the run tool refer to the same tables.
if _G.GilbMock then return _G.GilbMock end

---@module "lua.claude.runtime.repair"
local repair = include("claude/runtime/repair.lua")

local Mock = {}
Mock.registered = {} -- [promptId] = { [class] = kind }  where kind = "sent" | "swep"
Mock.enabled = CreateConVar("claude_mock", "1", FCVAR_ARCHIVE,
  "Exercise AI-generated entities after they run, to surface runtime errors in-turn")
Mock.drivers = {} -- [kind] = driver module with :run(class, done)

--- Note that `class` (kind sent|swep) was registered under `promptId`, so a later
--- exercise pass knows to drive it. Keyed by class so re-running the same entity
--- (an edit/fix) overwrites rather than piling up duplicates.
function Mock:record(promptId, kind, class)
  if not promptId or promptId == "" or not class then return end
  self.registered[promptId] = self.registered[promptId] or {}
  self.registered[promptId][class] = kind
end

function Mock:clear(promptId)
  self.registered[promptId] = nil
end

--- Exercise every entity registered under `promptId`. `done(errors)` receives a list
--- of { realm, err, detail }, deduped by error string. Safe for any promptId — one
--- that registered nothing (or when disabled) calls done({}) immediately.
function Mock:exercise(promptId, done)
  if not self.enabled:GetBool() then return done({}) end
  local set = self.registered[promptId]
  if not set then return done({}) end

  -- Collect the classes to drive first (drivers may be async — a SWEP needs a bot).
  local jobs = {}
  for class, kind in pairs(set) do
    local driver = self.drivers[kind]
    if driver then jobs[#jobs + 1] = { driver = driver, class = class } end
  end
  if #jobs == 0 then return done({}) end

  -- Divert the errors these drivers provoke to us instead of the repair bucket.
  local seen, errors = {}, {}
  repair:setInterceptor(promptId, function(realm, err, detail)
    if seen[err] then return end
    seen[err] = true
    errors[#errors + 1] = { realm = realm, err = err, detail = detail }
  end)

  local remaining = #jobs
  local function finish()
    repair:setInterceptor(promptId, nil)
    done(errors)
  end

  for _, job in ipairs(jobs) do
    local jobDone = false
    local function jobFinished()
      if jobDone then return end
      jobDone = true
      remaining = remaining - 1
      if remaining == 0 then finish() end
    end

    -- A harness fault in setup can never break the build: log and move on.
    local ok, err = pcall(job.driver.run, job.driver, job.class, jobFinished)
    if not ok then
      print(string.format("[gm-claude] Mock driver failed for '%s': %s", tostring(job.class), tostring(err)))
      jobFinished()
    end
  end
end

Mock.drivers.sent = include("claude/mock/entity.lua")
Mock.drivers.swep = include("claude/mock/weapon.lua")

_G.GilbMock = Mock
return Mock
