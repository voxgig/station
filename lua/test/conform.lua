-- RUN: lua5.4 test/conform.lua
-- RUN-SOME: lua5.4 test/conform.lua secretname
--
-- The station conformance suite: the pure-contract half of the design's
-- (station.md 13) corpus, from spec/station.json, through voxgig/omni -
-- the same file every port runs. Sections that need live SDK machinery
-- (inject, order, event correlation) live in the unit suite's fake-seam
-- harness (test/station.lua) and, end to end, in generated-SDK runs;
-- the corpus carries what a port can prove with no SDK present.
--
-- No third-party test framework: a failing omni check raises an
-- OmniError table, printed here and reflected in the exit code (omni's
-- own lua harness pattern).
--
-- omni is a sibling checkout, not a published rock: found via
-- $OMNI_HOME, else the usual workspace locations.

package.path = 'src/?.lua;test/?.lua;' .. package.path

-- Locate the voxgig/omni checkout (the convention sekreto and the other
-- station ports use).
local function omnihome()
  -- The env var is APPENDED rather than written as the first element:
  -- an unset OMNI_HOME is nil, and a nil at index 1 makes `ipairs` stop
  -- immediately - so every sibling-checkout fallback below it was
  -- skipped, and the suite could only ever run with OMNI_HOME set. That
  -- is exactly the CI case (the other ports rely on the fallbacks), and
  -- it read as a port failure rather than a lookup bug.
  local candidates = {
    '../omni',
    '../../omni',
    '/workspace/omni',
    '/workspace/voxgig/omni',
    '/home/user/omni',
  }
  local declared = os.getenv('OMNI_HOME')
  if declared ~= nil and declared ~= '' then
    table.insert(candidates, 1, declared)
  end

  for _, candidate in ipairs(candidates) do
    local marker = io.open(candidate .. '/spec/fib.json', 'r')
    if marker ~= nil then
      marker:close()
      return candidate
    end
  end
  error('station: voxgig/omni not found - set OMNI_HOME', 0)
end

local OMNI = omnihome()
package.path = OMNI .. '/lua/src/?.lua;' .. package.path

local runner = require('runner')
local u = require('util')
local st = require('voxgig_station')

-- The station spec, wherever this port is running from (lua/ or the
-- repo root).
local function specfile()
  local dir = '.'
  for _ = 1, 8 do
    local cand = dir .. '/spec/station.json'
    local handle = io.open(cand, 'r')
    if handle ~= nil then
      handle:close()
      return cand
    end
    dir = dir .. '/..'
  end
  error('station: spec/station.json not found', 0)
end

-- ---------------------------------------------------------------------
-- Bridges between omni's value model (u.map/u.list/u.NULL) and the
-- library's (plain tables tagged st.map/st.list, st.NULL). Spec nulls
-- arrive as omni's NULL sentinel (or NULLMARK); restore them so a
-- subject sees what the spec means - kept for `canonical` (st.NULL),
-- dropped for config-shaped inputs (absent), exactly as the ts/rb
-- conform tests denull.
-- ---------------------------------------------------------------------

local function tostation(val, keepnull)
  if u.isnull(val) or u.NULLMARK == val then
    if keepnull then
      return st.NULL
    end
    return nil
  end
  if u.islist(val) then
    local out = st.list({})
    for i, v in ipairs(val) do
      local conv = tostation(v, keepnull)
      out[i] = conv == nil and st.NULL or conv
    end
    return out
  end
  if u.ismap(val) then
    local out = st.map({})
    for k, v in pairs(val) do
      local conv = tostation(v, keepnull)
      if conv ~= nil then
        out[k] = conv
      end
    end
    return out
  end
  return val
end

local function toomni(val)
  if val == st.NULL then
    return u.NULL
  end
  if type(val) == 'table' then
    if st.islist(val) then
      local out = u.list({})
      for i, v in ipairs(val) do
        rawset(out, i, toomni(v))
      end
      return out
    end
    local out = u.map({})
    for k, v in pairs(val) do
      rawset(out, tostring(k), toomni(v))
    end
    return out
  end
  return val
end

-- ---------------------------------------------------------------------
-- The suite
-- ---------------------------------------------------------------------

local ONLY = arg[1]
local PASSCOUNT = 0
local FAILCOUNT = 0

local function testcase(name, body)
  if ONLY ~= nil and name ~= ONLY then
    return
  end
  local ok, err = pcall(body)
  if ok then
    PASSCOUNT = PASSCOUNT + 1
    print('ok   - ' .. name)
  else
    FAILCOUNT = FAILCOUNT + 1
    print('FAIL - ' .. name)
    print(runner.errmessage(err))
  end
end

local R = runner.makeRunner(specfile())('station')

testcase('secretname', function()
  R.runset(R.set('secretname'), function(vin)
    local slug = u.get(vin, 'slug')
    local secretname = st.secretname_default(slug)
    return u.map({
      envtoken = st.envtoken(slug),
      secretname = secretname,
      envkey = st.envkey(secretname),
    })
  end)
end)

testcase('placeholder', function()
  R.runset(R.set('placeholder'), function(slug)
    return st.placeholder_for(slug)
  end)
end)

testcase('descriptor', function()
  R.runset(R.set('descriptor'), function(vin)
    local config = tostation(u.get(vin, 'config'), false)
    local feature = tostation(u.get(vin, 'feature'), false)
    local descriptor = st.normalize_descriptor(config, feature)
    return toomni(descriptor)
  end)
end)

testcase('descriptorwarnings', function()
  R.runset(R.set('descriptorwarnings'), function(vin)
    local config = tostation(u.get(vin, 'config'), false)
    local feature = tostation(u.get(vin, 'feature'), false)
    local _, warnings = st.normalize_descriptor(config, feature)
    return #warnings
  end)
end)

testcase('canonical', function()
  R.runset(R.set('canonical'), function(vin)
    return st.canonical_serialize(tostation(vin, true))
  end)
end)

-- The 3.3 merge, and the whole of this port's profile contract.
testcase('instance', function()
  R.runset(R.set('instance'), function(vin)
    local config = tostation(u.get(vin, 'config'), false)
    local profile = u.get(vin, 'profile')
    return toomni(st.resolve_profile(config, profile))
  end)
end)

testcase('errors', function()
  R.runset(R.set('errors'), function(code)
    return st.known_code(code)
  end)
end)

print('\n' .. PASSCOUNT .. ' passed, ' .. FAILCOUNT .. ' failed')

os.exit(0 == FAILCOUNT and 0 or 1)
