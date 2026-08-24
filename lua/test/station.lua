-- RUN: lua5.4 test/station.lua
-- RUN-SOME: lua5.4 test/station.lua inject
--
-- Focused unit tests for the Lua station library, framework-free (the
-- omni lua harness pattern). The corpus (test/conform.lua) pins the
-- pure contracts; this suite drives the SDK-facing seams through a fake
-- client that reproduces the generated Lua SDKs' exact conventions:
-- (res, err) multi-return transport, client.mode, client.features init
-- order, duck-typed hook methods, and the 'station$' per-op slot.

package.path = 'src/?.lua;' .. package.path

local st = require('voxgig_station')

local ONLY = arg[1]
local PASSCOUNT = 0
local FAILCOUNT = 0

local function testcase(name, body)
  if ONLY ~= nil and name ~= ONLY then
    return
  end
  st.reset()
  local ok, err = pcall(body)
  if ok then
    PASSCOUNT = PASSCOUNT + 1
    print('ok   - ' .. name)
  else
    FAILCOUNT = FAILCOUNT + 1
    print('FAIL - ' .. name)
    print('       ' .. tostring(err))
  end
end

local function check(cond, msg)
  if not cond then
    error(msg or 'check failed', 2)
  end
end

local function checkeq(got, want, msg)
  if got ~= want then
    error((msg or 'not equal') .. '\n  expected: ' .. tostring(want) ..
      '\n  actual:   ' .. tostring(got), 2)
  end
end

-- Expect fn to raise a station error with the given code.
local function checkfails(code, fn)
  local ok, err = pcall(fn)
  check(not ok, 'expected a raised ' .. code)
  check(type(err) == 'table' and err.code == code,
    'expected code ' .. code .. ', got: ' .. tostring(err))
end

-- ---------------------------------------------------------------------
-- A fake generated SDK: the exact seams the adapter touches.
-- ---------------------------------------------------------------------

-- An embedded config like the one every generated Lua SDK carries
-- (post-MainMeta: main.slug/version/target present).
local function make_config(overrides)
  overrides = overrides or {}
  local config = {
    main = {
      name = 'Taskpad',
      slug = 'taskpad',
      version = '1.0.0',
      target = 'lua',
    },
    feature = { test = {} },
    options = {
      base = 'http://localhost:8901',
      auth = { prefix = 'Bearer' },
      headers = {},
      entity = { task = {} },
    },
    entity = {
      task = {
        fields = { { name = 'title', kind = 'String' } },
        op = {
          load = {
            points = {
              { method = 'GET', orig = '/api/task/:task_id',
                parts = { 'api', 'task', ':task_id' } },
            },
          },
        },
      },
    },
  }
  for k, v in pairs(overrides) do
    config[k] = v
  end
  return config
end

-- Build a fake client + ctx and run the adapter's init the way the
-- generated constructor does (feature_add order, then feature_init).
-- `spec.features` is the pre-station features array (names only);
-- station's adapter is inserted per its own _options.__after__.
local function bind(station, spec)
  spec = spec or {}
  local config = spec.config or make_config()

  local options = spec.options or { apikey = '', base = 'http://localhost:8901' }
  options.feature = options.feature or {}
  if options.feature.station == nil then
    options.feature.station = { active = true }
  end

  local inner_calls = {}
  local inner = spec.inner or function(_fctx, fullurl, fetchdef)
    inner_calls[#inner_calls + 1] = { url = fullurl, fetchdef = fetchdef }
    return { status = 200, headers = { ['content-length'] = '2' },
      json = function() return {} end, body = '{}' }, nil
  end

  local utility = { fetcher = inner }

  local client = { mode = spec.mode or 'live', features = {}, options = options }

  local ctx = { client = client, utility = utility,
    options = options, config = config }

  for _, name in ipairs(spec.features or { 'test' }) do
    client.features[#client.features + 1] = { name = name }
  end

  local adapter = st.adapter_feature(station, spec.calleropts)

  -- The generated feature_add: honour _options.__after__.
  -- spec.no_position simulates a map-form activation with no station
  -- ordering splice (a pre-splice make_options): plain append.
  local placed = false
  if not spec.no_position then
    for i, f in ipairs(client.features) do
      if f.name == adapter._options.__after__ then
        table.insert(client.features, i + 1, adapter)
        placed = true
        break
      end
    end
  end
  if not placed then
    client.features[#client.features + 1] = adapter
  end

  -- The generated feature_init: init when the options entry is active.
  adapter:init(ctx, options.feature.station)

  return {
    adapter = adapter, client = client, ctx = ctx, utility = utility,
    options = options, inner_calls = inner_calls, config = config,
  }
end

-- ---------------------------------------------------------------------
-- Pure pieces
-- ---------------------------------------------------------------------

testcase('identity', function()
  checkeq(st.envtoken('gnarly-pets'), 'GNARLY_PETS')
  checkeq(st.envtoken('-lead-trail-'), 'LEAD_TRAIL')
  checkeq(st.secretname_default('voxgig-solardemo'), 'voxgig_solardemo.apikey')
  checkeq(st.envkey('voxgig_solardemo.apikey'), 'VOXGIG_SOLARDEMO_APIKEY')
  checkeq(st.placeholder_for('taskpad'), '[station:taskpad]')
  check(st.validname('api.token'))
  check(not st.validname('Not A Name'))
  check(not st.validname(''))
  check(st.known_code('station_wrap_order'))
  check(not st.known_code('station_made_up'))
end)

testcase('canonical', function()
  checkeq(st.canonical_serialize(st.map({ b = 1, a = 2 })), '{"a":2,"b":1}')
  checkeq(st.canonical_serialize(st.list({})), '[]')
  checkeq(st.canonical_serialize(st.map({})), '{}')
  checkeq(st.canonical_serialize(st.map({ x = st.NULL })), '{"x":null}')
  -- Real Lua 5.3+ lexes this as an int64 and the corpus pins it; guard
  -- for JS-hosted validation VMs (fengari) whose numbers are doubles.
  if math.type(9007199254740991) == 'integer' then
    checkeq(st.canonical_serialize(9007199254740991), '9007199254740991')
  end
  checkeq(st.canonical_serialize('a"b\\c\n'), '"a\\"b\\\\c\\n"')
  checkeq(st.canonical_serialize(true), 'true')
  checkeq(st.canonical_serialize(nil), 'null')
  -- Untagged non-empty sequences read as lists; bytewise key order.
  checkeq(st.canonical_serialize({ 3, 1, 2 }), '[3,1,2]')
  checkeq(st.canonical_serialize(st.map({ ['é'] = 1, e = 2 })), '{"e":2,"é":1}')
end)

testcase('parse_json', function()
  local v = st.parse_json('{"a":[1,2],"b":null,"c":"x\\u00e9","d":{}}')
  checkeq(v.a[2], 2)
  checkeq(v.b, st.NULL)
  checkeq(v.c, 'x\195\169')
  check(st.ismap(v.d))
  check(st.islist(v.a))
  checkeq(st.parse_json('9007199254740991'), 9007199254740991)
  check(not pcall(st.parse_json, '{'))
end)

testcase('profile', function()
  local config = st.parse_json([[{
    "station": 1,
    "profiles": {
      "default": {
        "secrets": { "providers": [ { "kind": "env" }, { "kind": "dotenv" } ] },
        "sdk": { "a": { "base": "http://a" }, "b": { "base": "http://b" } }
      },
      "prod": {
        "secrets": { "providers": [ { "kind": "hashicorp" } ] },
        "sdk": { "a": { "secret": "custom.name" } }
      }
    }
  }]])

  -- secrets.providers replaces wholesale; sdk instances merge per ref,
  -- shallow, base then overlay (design station.md 3.3, 3.5).
  local prod = st.resolve_profile(config, 'prod')
  checkeq(#prod.providers, 1)
  checkeq(prod.providers[1].kind, 'hashicorp')
  checkeq(prod.sdk.a.base, 'http://a')
  checkeq(prod.sdk.a.secret, 'custom.name')
  checkeq(prod.sdk.b.base, 'http://b')

  -- Block defaults land AFTER the merge, only where the key is absent,
  -- and `active` is a real boolean (design 3.3, 4.2).
  checkeq(prod.sdk.b.active, true)
  check(st.ismap(prod.sdk.b.feature), 'feature defaults to an empty map')

  local dflt = st.resolve_profile(config, 'default')
  checkeq(#dflt.providers, 2)

  -- No config at all: the one-provider env chain (today's behavior).
  local bare = st.resolve_profile(nil, 'default')
  checkeq(#bare.providers, 1)
  checkeq(bare.providers[1].kind, 'env')

  -- A malformed configured name fails at profile load, not first
  -- request (design station.md 14).
  checkfails('station_secret_name', function()
    st.resolve_profile({ station = 1, profiles = {
      default = { sdk = { a = { secret = 'Not A Name' } } } } }, 'default')
  end)
end)

testcase('events', function()
  local buffer = st.EventBuffer.new(3)
  for i = 1, 5 do
    buffer:emit({ t = i, kind = 'station' })
  end
  local events = buffer:events()
  checkeq(#events, 3)
  checkeq(events[1].t, 3)
  checkeq(buffer:status().dropped, 2)

  local seen = {}
  local untap = buffer:tap(function(ev) seen[#seen + 1] = ev end)
  local boom = buffer:tap(function() error('tap boom') end)
  buffer:emit({ t = 6, kind = 'station' })
  checkeq(#seen, 1, 'a throwing tap must not fail the emit')
  untap()
  boom()
  buffer:emit({ t = 7, kind = 'station' })
  checkeq(#seen, 1)
end)

testcase('broker', function()
  local broker = st.SecretBroker.new({ { kind = 'env' } })

  -- Unset env var: a miss, with sekreto's meaning kept.
  checkfails('station_secret_no_value', function()
    broker:value('no-such-plugin', 'no_such_xyz_station_secret.apikey')
  end)

  -- Hoisted values win, and scrub is exact-value with NO length floor -
  -- every occurrence goes, even mid-word (the ts reference's split/join
  -- semantics: the promise is absolute, readability is not the goal).
  broker:hoist('taskpad', 'k')
  checkeq(broker:value('taskpad', 'taskpad.apikey'), 'k')
  checkeq(broker:scrub('key k here'), '[redacted]ey [redacted] here')
  broker:refresh()
  checkeq(broker:value('taskpad', 'taskpad.apikey'), 'k',
    'hoisted overrides survive refresh')
end)

testcase('ambient', function()
  local a = st.open({ config = st.NULL })
  checkeq(st.current(), a)
  checkeq(st.open({ config = st.NULL }), a, 'open is idempotent for equal options')
  checkfails('station_open_conflict', function()
    st.open({ profile = 'prod', config = st.NULL })
  end)
  st.reset()
  checkeq(st.current(), nil)
  local isolated = st.new({ config = st.NULL })
  check(isolated ~= nil)
  checkeq(st.current(), nil, 'new() never becomes ambient')
end)

-- ---------------------------------------------------------------------
-- The adapter through the fake SDK seams
-- ---------------------------------------------------------------------

testcase('register', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station)

  local plugins = station:plugins()
  checkeq(#plugins, 1)
  checkeq(plugins[1].slug, 'taskpad')
  checkeq(plugins[1].rung, 'R1')
  checkeq(plugins[1].descriptor.envtoken, 'TASKPAD')
  checkeq(plugins[1].descriptor.auth.secretname, 'taskpad.apikey')
  checkeq(plugins[1].descriptor.target, 'lua')

  -- The placeholder was planted at construction.
  checkeq(b.options.apikey, '[station:taskpad]')

  -- The canonical descriptor serializes (a smoke of tagging: entities
  -- is an object, server an array).
  local canon = station:canonical_descriptor('taskpad')
  check(string.find(canon, '"server":[]', 1, true) ~= nil, canon)
  check(string.find(canon, '"entities":{"task"', 1, true) ~= nil, canon)

  checkfails('station_no_plugin', function()
    station:descriptor_of('nope')
  end)

  -- A construct event was emitted.
  local found = false
  for _, ev in ipairs(station:events()) do
    if ev.kind == 'construct' and ev.plugin == 'taskpad' then
      found = true
    end
  end
  check(found, 'expected a construct event')
end)

testcase('inject', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station, { options = {
    apikey = 'real-secret', base = 'http://localhost:8901' } })

  -- The resident credential was hoisted; options holds the placeholder.
  checkeq(b.options.apikey, '[station:taskpad]')

  -- Drive the wrapped transport the way the pipeline does.
  local fctx = { client = b.client }
  local fetchdef = { method = 'GET',
    headers = { authorization = 'Bearer [station:taskpad]' } }
  local res, err = b.utility.fetcher(fctx, 'http://localhost:8901/api/task/x', fetchdef)
  checkeq(err, nil)
  checkeq(res.status, 200)

  -- The wire saw the real value...
  checkeq(#b.inner_calls, 1)
  checkeq(b.inner_calls[1].fetchdef.headers.authorization, 'Bearer real-secret')
  -- ...and copy-on-inject kept it out of the caller's object graph
  -- (ctrl.explain holds this fetchdef by reference).
  checkeq(fetchdef.headers.authorization, 'Bearer [station:taskpad]')

  -- The value never appears in redacted text either - exact-value, no
  -- length floor.
  checkeq(station:redact('oops real-secret leaked'), 'oops [redacted] leaked')

  -- One wire-truth http event, correlated when PrePoint ran.
  local httpev = nil
  for _, ev in ipairs(station:events()) do
    if ev.kind == 'http' then
      httpev = ev
    end
  end
  check(httpev ~= nil, 'expected an http event')
  checkeq(httpev.http.status, 200)
  checkeq(httpev.http.host, 'localhost:8901')
  checkeq(httpev.http.path, '/api/task/x')
  checkeq(httpev.http.bytes, 2)
end)

testcase('mock-no-inject', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station, {
    mode = 'test',
    options = { apikey = 'real-secret', base = 'http://x' },
  })

  local fctx = { client = b.client }
  local fetchdef = { headers = { authorization = 'Bearer [station:taskpad]' } }
  b.utility.fetcher(fctx, 'http://x/api/task', fetchdef)

  -- Injection is skipped when the base transport is a mock: real
  -- credentials never enter in-memory mock stores (design 3.3).
  checkeq(b.inner_calls[1].fetchdef.headers.authorization,
    'Bearer [station:taskpad]')
end)

testcase('secret-miss', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  -- No resident credential, nothing in the environment for this slug:
  -- the operation fails (nil, err) with the miss code - never a raise
  -- on the transport path.
  local config = make_config({ main = {
    name = 'NoSuchXyzStation', slug = 'no-such-xyz-station',
    version = '0.0.1', target = 'lua' } })
  local b = bind(station, { config = config,
    options = { apikey = '', base = 'http://x' } })

  local res, err = b.utility.fetcher({ client = b.client }, 'http://x/api', {
    headers = { authorization = '[station:no-such-xyz-station]' } })
  checkeq(res, nil)
  check(type(err) == 'table' and err.code == 'station_secret_no_value',
    'expected station_secret_no_value, got: ' .. tostring(err))
  checkeq(#b.inner_calls, 0, 'the wire must not be reached without a credential')
end)

testcase('order', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  -- A wrapping feature between the base transport and station (a
  -- map-form activation with no ordering splice): the position guard
  -- fails loudly (design 3.3).
  checkfails('station_wrap_order', function()
    bind(station, { features = { 'test', 'retry' }, no_position = true })
  end)

  -- An inert base stray (the lua _make_feature fallback on a
  -- pre-station SDK) is tolerated wherever it lands: it can never wrap.
  local station2 = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station2, { features = { 'test', 'base' }, no_position = true })
  check(b.adapter._binding ~= nil, 'base strays must not trip the guard')
end)

testcase('bound-twice', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station)

  -- Same client, second arrival (generated feature + carried adapter):
  -- inert, not an error.
  local second = st.adapter_feature(station, nil)
  second:init(b.ctx, { active = true })
  checkeq(second._binding, nil)

  -- A genuinely different client of the same SDK: the slug check fails.
  checkfails('station_bound_twice', function()
    bind(station)
  end)
end)

testcase('inert-without-station', function()
  st.reset()
  -- No handle, no ambient instance: the adapter is a no-op that emits
  -- nothing and fails nothing (design 3.1).
  local adapter = st.adapter_feature(nil, nil)
  local ctx = { client = { mode = 'live', features = {} },
    utility = { fetcher = function() end }, options = {}, config = make_config() }
  adapter:init(ctx, { active = true })
  checkeq(adapter._binding, nil)
  adapter:PrePoint({})
  adapter:PreDone({})
end)

testcase('hooks', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local b = bind(station)
  local bridge = b.adapter._binding

  local opctx = { client = b.client, op = { entity = 'task', name = 'load' } }
  bridge.PrePoint(opctx)
  check(type(opctx['station$']) == 'table')
  local corr = opctx['station$'].corr
  check(type(corr) == 'string' and corr ~= '')

  opctx.result = { ok = true }
  bridge.PreDone(opctx)

  local opev = nil
  for _, ev in ipairs(station:events()) do
    if ev.kind == 'op' then
      opev = ev
    end
  end
  check(opev ~= nil, 'expected an op event')
  checkeq(opev.op.entity, 'task')
  checkeq(opev.op.op, 'load')
  checkeq(opev.op.outcome, 'ok')
  checkeq(opev.corr, corr)

  -- The '_' absence sentinel reads as empty; err results read as err.
  checkeq(st.result_outcome({ result = { ok = false } }), 'err')
  checkeq(st.result_outcome({ result = { err = 'x' } }), 'err')
  checkeq(st.result_outcome({}), 'unknown')
  bridge.PreUnexpected({ op = { entity = '_', name = '_' } })
  local last = station:events()
  local ev = last[#last]
  checkeq(ev.op.entity, '')
  checkeq(ev.op.outcome, 'unexpected')
end)

testcase('hosts-policy', function()
  local station = st.new({ proxy = 'off', config = {
    station = 1,
    profiles = { default = { sdk = { taskpad = {
      policy = { hosts = { 'api.good.example' } } } } } },
  } })
  local b = bind(station)

  local res, err = b.utility.fetcher({ client = b.client },
    'http://evil.example/api/task', { headers = {} })
  checkeq(res, nil)
  check(type(err) == 'table' and err.code == 'station_host_allow',
    'expected station_host_allow, got: ' .. tostring(err))
  checkeq(#b.inner_calls, 0)

  -- An allowed host passes, with manual redirects asked of the
  -- transport.
  b.options.apikey = '[station:taskpad]'
  station.broker:hoist('taskpad', 'v')
  local res2 = b.utility.fetcher({ client = b.client },
    'http://api.good.example/api/task', { headers = {} })
  check(res2 ~= nil)
  checkeq(b.inner_calls[1].fetchdef.redirect, 'manual')
end)

testcase('require-proxy', function()
  local station = st.new({ config = st.NULL, proxy = 'require' })
  local b = bind(station)

  -- Fail-closed means traffic (design 2.1): construction succeeded,
  -- every operation fails on the operation path.
  local res, err = b.utility.fetcher({ client = b.client },
    'http://x/api', { headers = {} })
  checkeq(res, nil)
  check(type(err) == 'table' and err.code == 'station_no_proxy',
    'expected station_no_proxy, got: ' .. tostring(err))
end)

testcase('noauth', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local config = make_config()
  config.options.auth = nil
  local b = bind(station, { config = config,
    options = { base = 'http://x' } })

  checkeq(station:plugins()[1].rung, 'none')
  check(b.options.apikey == nil or b.options.apikey == '',
    'no placeholder is planted for auth-inactive plugins')

  -- The wrap still observes.
  b.utility.fetcher({ client = b.client }, 'http://x/api', { headers = {} })
  local httpev = nil
  for _, ev in ipairs(station:events()) do
    if ev.kind == 'http' then
      httpev = ev
    end
  end
  check(httpev ~= nil, 'auth-inactive plugins still get wire-truth events')
end)

testcase('legacy-config', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local config = make_config({ main = { name = 'VoxgigSolardemo' } })
  bind(station, { config = config, options = { apikey = '', base = 'http://x' } })

  local plugin = station:plugins()[1]
  checkeq(plugin.slug, 'voxgigsolardemo')
  checkeq(plugin.descriptor.version, '0.0.0')
  checkeq(plugin.descriptor.target, 'unknown')
  checkeq(#plugin.warnings, 1)
end)

testcase('env-only-says-so', function()
  local station = st.new({ proxy = 'off', config = {
    station = 1,
    profiles = { default = { secrets = { providers = {
      { kind = 'env' }, { kind = 'hashicorp' }, { kind = 'dotenv' } } } } },
  } })
  local warned = false
  for _, ev in ipairs(station:events()) do
    local warn = ev.meta ~= nil and ev.meta.warn or ''
    if string.find(warn, 'env%-only') ~= nil then
      warned = true
      check(string.find(warn, 'hashicorp', 1, true) ~= nil, warn)
      check(string.find(warn, 'dotenv', 1, true) ~= nil, warn)
    end
  end
  check(warned, 'an env-only port must say so when the chain names other stores')
  checkeq(station:status().secrets, 'env-only')
end)

testcase('close', function()
  local station = st.new({ proxy = 'off', config = {
    station = 1,
    profiles = { default = { sdk = { typo = { base = 'http://x' } } } },
  } })
  station:close()
  local warned = false
  for _, ev in ipairs(station:events()) do
    local warn = ev.meta ~= nil and ev.meta.warn or ''
    if string.find(warn, 'typo', 1, true) ~= nil then
      warned = true
    end
  end
  check(warned, 'close() warns on profile plugin keys matching nothing')

  checkfails('station_no_plugin', function()
    station:connect({ new = function() end }, {})
  end)
end)

testcase('profile-base', function()
  local station = st.new({ proxy = 'off', config = {
    station = 1,
    profiles = { default = { sdk = { taskpad = {
      base = 'http://from-profile' } } } },
  } })
  -- No caller base: the profile's per-plugin base wins over the SDK
  -- config default (design 3.5 rungs 4 over 1).
  local b = bind(station, { calleropts = {},
    options = { apikey = '', base = 'http://localhost:8901' } })
  checkeq(b.options.base, 'http://from-profile')

  -- Caller base (rung 7) beats the profile.
  local station2 = st.new({ proxy = 'off', config = {
    station = 1,
    profiles = { default = { sdk = { taskpad = {
      base = 'http://from-profile' } } } },
  } })
  local b2 = bind(station2, { calleropts = { base = 'http://mine' },
    options = { apikey = '', base = 'http://mine' } })
  checkeq(b2.options.base, 'http://mine')
end)

testcase('options-form', function()
  local station = st.new({ config = st.NULL, proxy = 'off' })
  local options = station:options({ base = 'http://mine' })
  checkeq(options.base, 'http://mine')
  checkeq(options.feature.station.active, true)
  check(type(options.feature.station.station) == 'function',
    'the handle rides as a function closure')
  checkeq(options.feature.station.station(), station)
end)

print('\n' .. PASSCOUNT .. ' passed, ' .. FAILCOUNT .. ' failed')

os.exit(0 == FAILCOUNT and 0 or 1)
