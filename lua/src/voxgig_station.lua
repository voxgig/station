-- voxgig/station - one control surface for outbound integrations (Lua port).
--
-- The station library core, solo mode (design D1): fully functional
-- in-process with no other component running. The proxy (D2) is a
-- deferred amplifier - `require` therefore fails on the operation path
-- (design station.md 2.1/14), and `auto` degrades to solo with one
-- warning event.
--
-- A port of typescript/src/*.ts, which is canonical, in one module -
-- idiomatic for a single-file Lua rock and for vendoring. SDK-facing
-- seams follow the generated Lua SDKs' conventions: the transport is a
-- function returning a (response, err) MULTI-RETURN pair - errors are
-- values, never raised, and this middleware propagates both slots
-- unchanged; client mode is client.mode; per-op state rides the
-- 'station$' slot on the SDK's own ctx table; hooks are dispatched by
-- literal method-name lookup, so the adapter is just a table carrying
-- those method names.
--
-- SECRETS ARE ENV-ONLY, and this library says so (design station.md
-- 2.2): there is no sekreto Lua port, so the broker reads the process
-- environment directly under the envkey of the secret name
-- (voxgig_solardemo.apikey -> VOXGIG_SOLARDEMO_APIKEY, the same mapping
-- sekreto's envkey() defines and the one the generated SDKs already
-- document). It grows no second provider: a profile whose chain names
-- any other store gets a warning event at open, not a silent partial
-- implementation. The permanent fix is a sekreto Lua port, contributed
-- to sekreto (design station.md 18).
--
-- Canonical serialization does not - cannot - rely on pairs() order
-- (design station.md 4 calls Lua out by name): keys are collected and
-- sorted bytewise, which Lua's default string comparison already is.
-- Lua tables also cannot hold nil and cannot tell an empty list from an
-- empty map, so the module carries the standard sentinels: M.NULL for a
-- present JSON null, and M.map{}/M.list{} taggers using the dkjson
-- __jsontype metatable convention so tagged values interoperate with
-- the SDKs' own dkjson-decoded config.
--
-- NOTE ON COPIES: the canonical source of this library lives in the
-- voxgig/station repo at lua/src/voxgig_station.lua. The sdkgen-station
-- package carries a VENDORED copy under
-- .sdk/tm/lua/feature/station/voxgig_station.lua (LuaRocks has no
-- voxgig-station rock yet, and a rockspec dependency on a nonexistent
-- package would break every consumer install). Edit HERE first, then
-- refresh the vendored copy - the two must stay byte-identical.

local M = {}

M.VERSION = '0.0.1'


-- ---------------------------------------------------------------------
-- Value model: NULL sentinel + map/list tagging
-- ---------------------------------------------------------------------

-- A present JSON null (Lua tables cannot hold nil).
M.NULL = setmetatable({}, { __tostring = function() return 'null' end })

local MAP_MT = { __jsontype = 'object' }
local LIST_MT = { __jsontype = 'array' }

-- Tag a table as a JSON object (survives emptiness).
function M.map(t)
  return setmetatable(t or {}, MAP_MT)
end

-- Tag a table as a JSON array (survives emptiness).
function M.list(t)
  return setmetatable(t or {}, LIST_MT)
end

local function jsontype(t)
  local mt = getmetatable(t)
  return type(mt) == 'table' and mt.__jsontype or nil
end

-- Is this table a list? Tag wins; untagged non-empty tables count as a
-- list when their keys are exactly 1..n.
function M.islist(t)
  if type(t) ~= 'table' or t == M.NULL then
    return false
  end
  local tag = jsontype(t)
  if tag ~= nil then
    return 'array' == tag
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n > 0 and n == #t
end

function M.ismap(t)
  return type(t) == 'table' and t ~= M.NULL and not M.islist(t)
end

-- nil and NULL both read as "no value" on config surfaces.
local function isnil(v)
  return v == nil or v == M.NULL
end

-- Read a map entry, treating NULL as absent.
local function getk(t, k)
  if type(t) ~= 'table' or t == M.NULL then
    return nil
  end
  local v = t[k]
  if v == M.NULL then
    return nil
  end
  return v
end

-- Sorted string keys of a map (byte order - never pairs() order).
local function sortedkeys(t)
  local keys = {}
  if type(t) == 'table' then
    for k in pairs(t) do
      if type(k) == 'string' then
        keys[#keys + 1] = k
      end
    end
  end
  table.sort(keys)
  return keys
end

local function shallowcopy(t)
  local out = {}
  if type(t) == 'table' then
    for k, v in pairs(t) do
      out[k] = v
    end
  end
  return out
end

-- Literal (non-pattern) replace-all.
local function replaceall(s, find, rep)
  if find == '' then
    return s
  end
  local out, i = {}, 1
  while true do
    local a, b = string.find(s, find, i, true)
    if a == nil then
      break
    end
    out[#out + 1] = string.sub(s, i, a - 1)
    out[#out + 1] = rep
    i = b + 1
  end
  out[#out + 1] = string.sub(s, i)
  return table.concat(out)
end

-- Wall-clock milliseconds: luasocket's gettime when present (the SDKs
-- already optionally depend on it), else whole-second os.time - event
-- timestamps stay truthful either way, durations just get coarse.
local socket_ok, socket = pcall(require, 'socket')
local function now_ms()
  if socket_ok and type(socket) == 'table' and type(socket.gettime) == 'function' then
    return math.floor(socket.gettime() * 1000)
  end
  return os.time() * 1000
end


-- ---------------------------------------------------------------------
-- Errors (design station.md 14): <subject>_<condition>, absence as
-- no_<thing>, gates as _allow. The `errors` corpus section pins the
-- exact strings.
-- ---------------------------------------------------------------------

local CODES = {
  'station_no_proxy',
  'station_secret_no_value',
  'station_secret_error',
  'station_secret_name',
  'station_host_allow',
  'station_grant_expired',
  'station_wrap_order',
  'station_protocol',
  'station_no_plugin',
  'station_no_entity',
  'station_no_op',
  'station_agent_allow',
  'station_body_limit',
  'station_replay_lossy',
  'station_open_conflict',
  'station_bound_twice',

  -- Declarative config (design 6.4). Only the reference ports raise
  -- the config-validation codes so far (Stage 1); the catalog is
  -- repo-wide, so every port knows them.
  'station_config_invalid',
  'station_config_secret',
  'station_secret_collision',
  'station_feature_reserved',

  -- Instances (design 6.4). `as` is a tag, not a free name.
  'station_instance_api',

  -- The declarative front door (design 6.4). Availability errors are
  -- fatal at first use, not at open().
  'station_no_instance',
  'station_instance_inactive',
  'station_sdk_load',
  'station_no_factory',
  'station_factory_conflict',

  -- Features (design 8.4, 8.5).
  'station_feature_unknown',
  'station_feature_option',
  'station_feature_order',
}

local CODESET = {}
for _, code in ipairs(CODES) do
  CODESET[code] = true
end

function M.known_code(code)
  return CODESET[code] == true
end

local ERROR_MT = {
  __tostring = function(err)
    return err.message
  end,
}

-- A station error VALUE: a table, so a raised one stays distinguishable
-- from plain-string errors, with .code and .message like the ts
-- StationError (message carries the code prefix).
function M.make_error(code, msg)
  return setmetatable({
    is_station_error = true,
    name = 'StationError',
    code = code,
    message = code .. ': ' .. msg,
    msg = code .. ': ' .. msg,
  }, ERROR_MT)
end

function M.is_station_error(err)
  return type(err) == 'table' and err.is_station_error == true
end

-- Raise a station error (construction-path failures raise; the
-- transport path returns (nil, err) instead - the SDKs' convention).
local function fail(code, msg)
  error(M.make_error(code, msg), 0)
end

M.fail = fail


-- ---------------------------------------------------------------------
-- Identity: envtoken / secret names (design station.md 5.1)
-- ---------------------------------------------------------------------

-- The ONLY way to build an env-var token in station, mirroring sdkgen's
-- packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
-- `secretname` corpus section pins the round-trip against sekreto's
-- envkey() and sdkgen's envName() - the one place three grammars meet.
function M.envtoken(name)
  local s = string.upper(tostring(name == nil and '' or name))
  s = string.gsub(s, '[^A-Z0-9]+', '_')
  s = string.gsub(s, '^_+', '')
  s = string.gsub(s, '_+$', '')
  return s
end

-- The default sekreto name for a plugin (design station.md 5.1):
-- envtoken(slug) lowercased, plus '.apikey'. envkey() then yields
-- exactly the env var the SDK's README documents:
-- gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
function M.secretname_default(slug)
  return string.lower(M.envtoken(slug)) .. '.apikey'
end

-- Best-effort slug from a camel name, for SDKs whose embedded config
-- predates main.slug (design station.md 4 legacy sentinels). The hyphen
-- caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
-- 'voxgig-solardemo' - callers surface a warning event when this path
-- is taken.
local function legacy_slug(name)
  return string.lower(tostring(name == nil and '' or name))
end

-- Is this a well-formed secret name? sekreto's grammar: dot-separated
-- segments of [a-z0-9_]+ (restated here because there is no sekreto Lua
-- port to import it from; the grammar is sekreto's, pinned by its spec).
function M.validname(name)
  if type(name) ~= 'string' or #name == 0 then
    return false
  end
  for part in string.gmatch(name .. '.', '(.-)%.') do
    if not string.match(part, '^[a-z0-9_]+$') then
      return false
    end
  end
  return true
end

-- The environment-variable key for a name: api.token -> API_TOKEN
-- (sekreto's envkey mapping - the one store mapping an env-only library
-- legitimately carries, because it is the mapping it reads by).
function M.envkey(name)
  if not M.validname(name) then
    fail('station_secret_error', 'invalid secret name: ' .. tostring(name))
  end
  return string.upper((string.gsub(name, '%.', '_')))
end


-- ---------------------------------------------------------------------
-- JSON: canonical serializer + a small strict parser
-- ---------------------------------------------------------------------

local JSON_ESCAPE = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escape_string(s)
  return (string.gsub(s, '[%z\1-\31"\\]', function(c)
    return JSON_ESCAPE[c] or string.format('\\u%04x', string.byte(c))
  end))
end

local function serialize_number(v)
  if math.type(v) == 'integer' then
    return string.format('%d', v)
  end
  if v ~= v or v == math.huge or v == -math.huge then
    error('station: cannot serialize non-finite number', 0)
  end
  -- An integral float prints as an integer, matching JSON.stringify
  -- (via tointeger; '%.0f' as the fallback for double-only VMs whose
  -- tointeger range is narrow - '%d' on a float is refused by some).
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
    local i = math.tointeger(v)
    if i ~= nil then
      return string.format('%d', i)
    end
    return string.format('%.0f', v)
  end
  return tostring(v)
end

-- Canonical serialization (design station.md 4): UTF-8, object keys
-- sorted bytewise (Lua string order IS byte order), no insignificant
-- whitespace, minimal JSON escaping. The proxy dedupes registrations by
-- a hash of this, so every language must produce identical bytes - the
-- `canonical` corpus section carries the adversarial cases. nil never
-- occurs inside a Lua table (absent is absent by construction); a
-- present null is the M.NULL sentinel.
function M.canonical_serialize(value)
  if value == nil or value == M.NULL then
    return 'null'
  end
  local t = type(value)
  if t == 'boolean' then
    return value and 'true' or 'false'
  end
  if t == 'number' then
    return serialize_number(value)
  end
  if t == 'string' then
    return '"' .. escape_string(value) .. '"'
  end
  if t == 'table' then
    if M.islist(value) then
      local parts = {}
      for i = 1, #value do
        parts[i] = M.canonical_serialize(value[i])
      end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = tostring(k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      local v = value[k]
      if v == nil then
        v = value[tonumber(k)]
      end
      parts[#parts + 1] = '"' .. escape_string(k) .. '":' .. M.canonical_serialize(v)
    end
    return '{' .. table.concat(parts, ',') .. '}'
  end
  error('station: cannot serialize a ' .. t, 0)
end

-- A small strict JSON parser (station.json profiles; the library must
-- not depend on dkjson being installed - inside a generated SDK it is,
-- standalone it may not be). Objects come back tagged M.map, arrays
-- M.list, null as M.NULL.
local function json_parse(text)
  local pos = 1
  local n = #text

  local function err_at(msg)
    error('station: invalid JSON at ' .. pos .. ': ' .. msg, 0)
  end

  local function skip_ws()
    while pos <= n do
      local c = string.byte(text, pos)
      if c == 32 or c == 9 or c == 10 or c == 13 then
        pos = pos + 1
      else
        break
      end
    end
  end

  local function utf8_encode(cp)
    if cp < 0x80 then
      return string.char(cp)
    elseif cp < 0x800 then
      return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    elseif cp < 0x10000 then
      return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end
    return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
      0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end

  local parse_value

  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      if pos > n then
        err_at('unterminated string')
      end
      local c = string.sub(text, pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == '\\' then
        local e = string.sub(text, pos + 1, pos + 1)
        pos = pos + 2
        if e == 'u' then
          local hex = string.sub(text, pos, pos + 3)
          if not string.match(hex, '^%x%x%x%x$') then
            err_at('bad \\u escape')
          end
          local cp = tonumber(hex, 16)
          pos = pos + 4
          if cp >= 0xD800 and cp <= 0xDBFF and string.sub(text, pos, pos + 1) == '\\u' then
            local hex2 = string.sub(text, pos + 2, pos + 5)
            if string.match(hex2, '^%x%x%x%x$') then
              local lo = tonumber(hex2, 16)
              if lo >= 0xDC00 and lo <= 0xDFFF then
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                pos = pos + 6
              end
            end
          end
          out[#out + 1] = utf8_encode(cp)
        elseif e == '"' or e == '\\' or e == '/' then
          out[#out + 1] = e
        elseif e == 'b' then
          out[#out + 1] = '\b'
        elseif e == 'f' then
          out[#out + 1] = '\f'
        elseif e == 'n' then
          out[#out + 1] = '\n'
        elseif e == 'r' then
          out[#out + 1] = '\r'
        elseif e == 't' then
          out[#out + 1] = '\t'
        else
          err_at('bad escape')
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end

  local function parse_number()
    local numstr = string.match(text, '^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    if numstr == nil or numstr == '' then
      err_at('bad number')
    end
    pos = pos + #numstr
    if string.match(numstr, '^-?%d+$') then
      local i = math.tointeger(tonumber(numstr))
      if i ~= nil then
        return i
      end
    end
    local v = tonumber(numstr)
    if v == nil then
      err_at('bad number')
    end
    return v
  end

  parse_value = function()
    skip_ws()
    if pos > n then
      err_at('unexpected end')
    end
    local c = string.sub(text, pos, pos)
    if c == '{' then
      pos = pos + 1
      local out = M.map({})
      skip_ws()
      if string.sub(text, pos, pos) == '}' then
        pos = pos + 1
        return out
      end
      while true do
        skip_ws()
        if string.sub(text, pos, pos) ~= '"' then
          err_at('expected key')
        end
        local key = parse_string()
        skip_ws()
        if string.sub(text, pos, pos) ~= ':' then
          err_at('expected :')
        end
        pos = pos + 1
        out[key] = parse_value()
        skip_ws()
        local d = string.sub(text, pos, pos)
        if d == ',' then
          pos = pos + 1
        elseif d == '}' then
          pos = pos + 1
          return out
        else
          err_at('expected , or }')
        end
      end
    elseif c == '[' then
      pos = pos + 1
      local out = M.list({})
      skip_ws()
      if string.sub(text, pos, pos) == ']' then
        pos = pos + 1
        return out
      end
      while true do
        out[#out + 1] = parse_value()
        skip_ws()
        local d = string.sub(text, pos, pos)
        if d == ',' then
          pos = pos + 1
        elseif d == ']' then
          pos = pos + 1
          return out
        else
          err_at('expected , or ]')
        end
      end
    elseif c == '"' then
      return parse_string()
    elseif string.sub(text, pos, pos + 3) == 'true' then
      pos = pos + 4
      return true
    elseif string.sub(text, pos, pos + 4) == 'false' then
      pos = pos + 5
      return false
    elseif string.sub(text, pos, pos + 3) == 'null' then
      pos = pos + 4
      return M.NULL
    else
      return parse_number()
    end
  end

  local out = parse_value()
  skip_ws()
  if pos <= n then
    err_at('trailing content')
  end
  return out
end

M.parse_json = json_parse


-- ---------------------------------------------------------------------
-- Descriptor (design station.md 4): a view over the SDK's embedded
-- config, normalized - never a second model.
-- ---------------------------------------------------------------------

-- Normalize a generated SDK's embedded config into descriptor v1. The
-- config is the one every SDK carries (config.main / .feature /
-- .options / .entity - dkjson-decoded above the size threshold, a plain
-- table literal below it; both shapes land here). Returns the
-- descriptor plus a list of legacy warnings (multi-return, the Lua
-- idiom).
function M.normalize_descriptor(config, active_features)
  local warnings = {}
  local main = getk(config, 'main') or {}
  local options = getk(config, 'options') or {}

  local name = tostring(getk(main, 'name') or '')
  local slug = getk(main, 'slug')
  if isnil(slug) or slug == '' then
    slug = legacy_slug(name)
    warnings[#warnings + 1] = 'descriptor: legacy config has no main.slug; derived "' ..
      slug .. '" from the camel name - hyphens in the original name are lost'
  else
    slug = tostring(slug)
  end

  local version = getk(main, 'version')
  version = isnil(version) and '0.0.0' or tostring(version)
  local target = getk(main, 'target')
  target = isnil(target) and 'unknown' or tostring(target)

  local server = M.list({})
  local svr = getk(options, 'server') or {}
  for _, k in ipairs(sortedkeys(svr)) do
    server[#server + 1] = M.map({ name = k, value = tostring(getk(svr, k) or '') })
  end

  local optauth = getk(options, 'auth')
  local auth_active = not isnil(optauth)
  local auth = M.map({
    active = auth_active,
    prefix = auth_active and tostring(getk(optauth, 'prefix') or '') or '',
    secretname = M.secretname_default(slug),
  })

  local entities = M.map({})
  local entdefs = getk(config, 'entity') or {}
  for _, ename in ipairs(sortedkeys(entdefs)) do
    local e = getk(entdefs, ename) or {}

    local fields = M.map({})
    local fdefs = getk(e, 'fields')
    if type(fdefs) == 'table' then
      for _, f in ipairs(fdefs) do
        local fname = getk(f, 'name')
        if not isnil(fname) then
          fields[tostring(fname)] = M.map({
            kind = tostring(getk(f, 'kind') or getk(f, 'type') or ''),
          })
        end
      end
    end

    local ops = M.map({})
    local opdefs = getk(e, 'op') or {}
    for _, opname in ipairs(sortedkeys(opdefs)) do
      local op = getk(opdefs, opname) or {}
      local points = M.list({})
      local pdefs = getk(op, 'points')
      if type(pdefs) == 'table' then
        for _, p in ipairs(pdefs) do
          if type(p) == 'table' and p ~= M.NULL then
            local params = M.list({})
            local parts = getk(p, 'parts')
            if type(parts) == 'table' then
              for _, part in ipairs(parts) do
                if type(part) == 'string' and string.sub(part, 1, 1) == ':' then
                  params[#params + 1] = string.sub(part, 2)
                end
              end
            end
            local point = M.map({
              method = tostring(getk(p, 'method') or ''),
              path = tostring(getk(p, 'orig') or getk(p, 'path') or ''),
              params = params,
            })
            local sel = getk(p, 'select')
            if sel ~= nil then
              point.select = sel
            end
            points[#points + 1] = point
          end
        end
      end
      ops[opname] = M.map({ points = points })
    end

    entities[ename] = M.map({ fields = fields, ops = ops })
  end

  local features = M.list({})
  local fdefs = getk(config, 'feature') or {}
  local factive = type(active_features) == 'table' and active_features or {}
  for _, fname in ipairs(sortedkeys(fdefs)) do
    local fopts = getk(factive, fname)
    features[#features + 1] = M.map({
      name = fname,
      active = type(fopts) == 'table' and getk(fopts, 'active') == true,
    })
  end

  local descriptor = M.map({
    station = 1,
    name = name,
    slug = slug,
    envtoken = M.envtoken(slug),
    version = version,
    target = target,
    base = tostring(getk(options, 'base') or ''),
    server = server,
    auth = auth,
    entities = entities,
    features = features,
  })

  return descriptor, warnings
end


-- ---------------------------------------------------------------------
-- Profiles (design station.md 3.5): station.json lookup + resolution
-- ---------------------------------------------------------------------

local function file_exists(path)
  local handle = io.open(path, 'r')
  if handle ~= nil then
    handle:close()
    return true
  end
  return false
end

-- A directory (or file) exists when the no-op rename succeeds - Lua's
-- stdlib has no stat, and io.open refuses directories on POSIX.
local function path_exists(path)
  if file_exists(path) then
    return true
  end
  local ok = os.rename(path, path)
  return ok == true
end

-- station.json lookup: cwd upward to the repo root, then
-- ~/.voxgig/station.json (design station.md 3.5). A repo root is where
-- .git lives; the stdlib has no cwd, so the walk is relative
-- ('.', '..', '../..', ...) and bounded.
function M.find_config_file(from)
  local dir = from == nil and '.' or from
  for _ = 1, 16 do
    local candidate = dir .. '/station.json'
    if file_exists(candidate) then
      return candidate
    end
    if path_exists(dir .. '/.git') then
      break
    end
    dir = dir .. '/..'
  end
  local home = os.getenv('HOME')
  if home ~= nil and home ~= '' then
    local candidate = home .. '/.voxgig/station.json'
    if file_exists(candidate) then
      return candidate
    end
  end
  return nil
end

function M.load_config(from)
  local file = M.find_config_file(from)
  if file == nil then
    return nil
  end
  local handle = io.open(file, 'r')
  if handle == nil then
    return nil
  end
  local text = handle:read('a')
  handle:close()
  -- A file that is not JSON is a config error, not a raw parser error
  -- escaping open(): the reader found station.json and could not use
  -- it, which is exactly what station_config_invalid exists to say.
  local ok, parsed = pcall(json_parse, text)
  if not ok then
    fail('station_config_invalid',
      'station.json at ' .. file .. ' is not valid JSON: ' .. tostring(parsed))
  end
  return parsed
end

-- Profile selection: the open() option, else VOXGIG_STATION_PROFILE,
-- else 'default' (design station.md 3.5 - open() opts outrank env vars).
function M.select_profile(opt_profile)
  if type(opt_profile) == 'string' and opt_profile ~= '' then
    return opt_profile
  end
  local env = os.getenv('VOXGIG_STATION_PROFILE')
  if env ~= nil and env ~= '' then
    return env
  end
  return 'default'
end

-- Block-level defaults, applied ONCE to the fully merged instance,
-- never to a block before the merge (design 3.3, 4.2). Factories, so
-- every application gets a FRESH feature map - and `active` is a real
-- JSON boolean true, which the canonical serializer keeps as `true`.
local BLOCK_DEFAULTS = {
  active = function()
    return true
  end,
  feature = function()
    return M.map({})
  end,
}

-- The one block key carrying the timing rule: applied AFTER the merge,
-- never before (design 3.3, 4.2). Named rather than inferred, so a
-- reader does not have to work out which of the two it is.
M.MERGE_SENSITIVE = { 'active' }

-- The api half of a ref is the substring before the first `$`, and an
-- untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
-- point: under the old free-form identity which api an instance used
-- was itself a merged value, so a port that got the phasing wrong
-- silently picked another api's defaults.
function M.refapi(ref)
  local s = tostring(ref == nil and '' or ref)
  local at = string.find(s, '$', 1, true)
  if at == nil then
    return s
  end
  return string.sub(s, 1, at - 1)
end

-- Shallow merge, per key, left to right - each source over the one
-- before it; non-map sources are skipped. ONE level only: an overlay's
-- `policy` REPLACES the base's entirely rather than merging `hosts`
-- into it; an allowlist that widens because two precedence levels
-- merged is the failure this rule prevents.
local function shallow(...)
  local out = M.map({})
  for i = 1, select('#', ...) do
    local src = select(i, ...)
    if M.ismap(src) then
      for k, v in pairs(src) do
        out[k] = v
      end
    end
  end
  return out
end

-- Sorted distinct string keys across several maps (byte order,
-- non-maps skipped). The single-map sortedkeys above predates this
-- union form, so the union helper is named distinctly.
local function mergedkeys(...)
  local seen = {}
  local keys = {}
  for i = 1, select('#', ...) do
    local m = select(i, ...)
    if M.ismap(m) then
      for k in pairs(m) do
        if type(k) == 'string' and not seen[k] then
          seen[k] = true
          keys[#keys + 1] = k
        end
      end
    end
  end
  table.sort(keys)
  return keys
end

-- The providers list of one profile, or nil - only an actual list
-- counts (wholesale replacement, never a positional merge).
local function providers_of(profile)
  local secrets = getk(profile, 'secrets')
  if not M.ismap(secrets) then
    return nil
  end
  local p = getk(secrets, 'providers')
  if type(p) == 'table' and M.islist(p) then
    return p
  end
  return nil
end

-- A configured secret name sekreto would reject is caught at profile
-- load, not first request (design station.md 14 station_secret_name) -
-- and then the DERIVED names are checked for uniqueness, because
-- envtoken is LOSSY: it collapses any run of non-alphanumerics to `_`,
-- so `stripe$test` and an untagged instance of a `stripe-test` api both
-- derive `stripe_test.apikey` and would silently share one credential.
--
-- Two instances that EXPLICITLY name one secret are not a collision -
-- that is the shared-key case the api-level `secret` exists for.
local function checksecrets(sdk, profile_name)
  local refs = sortedkeys(sdk)

  for _, ref in ipairs(refs) do
    local name = getk(sdk[ref], 'secret')
    if name ~= nil and not M.validname(name) then
      fail('station_secret_name',
        'profile "' .. profile_name .. '" sdk "' .. ref ..
        '": secret name rejected by sekreto: ' .. M.canonical_serialize(tostring(name)))
    end
  end

  local seen = {}
  for _, ref in ipairs(refs) do
    local written = getk(sdk[ref], 'secret')
    local derived = written == nil or written == ''
    local name = derived and M.secretname_default(ref) or written

    local prior = seen[name]
    if prior ~= nil and (derived or prior.derived) then
      fail('station_secret_collision',
        'profile "' .. profile_name .. '": instances "' .. prior.ref .. '" and "' ..
        ref .. '" both resolve to secret name "' .. name ..
        '", so they would share one credential; name it explicitly on ' ..
        'each, or at the api level to share it deliberately (5.1)')
    end
    if prior == nil then
      seen[name] = { ref = ref, derived = derived }
    end
  end
end

-- Merge the base profile ('default') with the selected overlay.
--
-- Design 3.3's total order for the two block levels, lowest first:
--
--   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
--
-- PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
-- LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
-- namespace, then put instance over api" - that lets every instance
-- value beat every api value, so a production `api.stripe.policy` would
-- fail to override a default profile's `sdk.stripe$test.policy`,
-- silently keeping the wider allowlist in production.
--
-- `secrets.providers` replaces wholesale, never merges (design
-- station.md 3.5, 5.2 - chain order decides which store wins, so a
-- positional merge would be actively dangerous). The `instance` corpus
-- section pins all of this.
function M.resolve_profile(config, profile_name)
  local profiles = getk(config, 'profiles')
  if not M.ismap(profiles) then
    profiles = {}
  end
  local base = getk(profiles, 'default')
  if not M.ismap(base) then
    base = {}
  end
  local overlay = {}
  if 'default' ~= profile_name then
    overlay = getk(profiles, profile_name)
    if not M.ismap(overlay) then
      overlay = {}
    end
  end

  local providers = providers_of(overlay)
  if providers == nil then
    providers = providers_of(base)
  end
  if providers == nil then
    providers = M.list({ M.map({ kind = 'env' }) })
  end

  local base_api = getk(base, 'api')
  if not M.ismap(base_api) then
    base_api = {}
  end
  local over_api = getk(overlay, 'api')
  if not M.ismap(over_api) then
    over_api = {}
  end
  local base_sdk = getk(base, 'sdk')
  if not M.ismap(base_sdk) then
    base_sdk = {}
  end
  local over_sdk = getk(overlay, 'sdk')
  if not M.ismap(over_sdk) then
    over_sdk = {}
  end

  -- The api-level defaults in effect for this profile. A REPORT, not an
  -- input to the instance merge below, and never defaulted.
  local api = M.map({})
  for _, slug in ipairs(mergedkeys(base_api, over_api)) do
    api[slug] = shallow(base_api[slug], over_api[slug])
  end

  -- An api block declares no instance of its own (design 3.1), so the
  -- ref set comes from the two `sdk` maps alone.
  local sdk = M.map({})
  for _, ref in ipairs(mergedkeys(base_sdk, over_sdk)) do
    local a = M.refapi(ref)
    local merged = shallow(base_api[a], base_sdk[ref], over_api[a], over_sdk[ref])

    -- Defaults are applied ONCE, to the fully merged instance, and only
    -- where the key is ABSENT (an explicit false or {} survives). Had
    -- the overlay block carried a synthesized `active` into the merge,
    -- a one-key environment override would silently re-enable an
    -- integration the base declared inactive.
    for k, default in pairs(BLOCK_DEFAULTS) do
      if merged[k] == nil then
        merged[k] = default()
      end
    end

    sdk[ref] = merged
  end

  checksecrets(sdk, profile_name)

  return M.map({ name = profile_name, providers = providers, api = api, sdk = sdk })
end


-- ---------------------------------------------------------------------
-- Events (design station.md 6): a bounded ring buffer plus a live tap
-- with serialized callbacks. Events never fail an operation; overflow
-- drops oldest and the drop count is visible in status().
-- ---------------------------------------------------------------------

local EventBuffer = {}
EventBuffer.__index = EventBuffer

function EventBuffer.new(max)
  local self = setmetatable({}, EventBuffer)
  self.ring = {}
  self.max = max == nil and 1000 or max
  self.drops = 0
  self.taps = {}
  return self
end

function EventBuffer:emit(ev)
  self.ring[#self.ring + 1] = ev
  if #self.ring > self.max then
    table.remove(self.ring, 1)
    self.drops = self.drops + 1
  end
  -- Serialized, and a throwing tap must not fail the operation that
  -- emitted the event.
  for _, fn in ipairs(self.taps) do
    pcall(fn, ev)
  end
end

function EventBuffer:events()
  local out = {}
  for i, ev in ipairs(self.ring) do
    out[i] = ev
  end
  return out
end

function EventBuffer:tap(fn)
  local taps = self.taps
  taps[#taps + 1] = fn
  return function()
    for i, f in ipairs(taps) do
      if f == fn then
        table.remove(taps, i)
        return
      end
    end
  end
end

function EventBuffer:status()
  return { buffered = #self.ring, dropped = self.drops }
end

M.EventBuffer = EventBuffer


-- ---------------------------------------------------------------------
-- Secrets (design station.md 5): the broker holds resolved values
-- privately - they never enter options, events, or captures; the SDK
-- sees only the placeholder. ENV-ONLY: no sekreto Lua port exists, so
-- the one provider is the process environment, read directly under
-- envkey(name) (design station.md 2.2). No second provider is grown
-- here; other configured provider kinds are reported at open, not
-- silently half-implemented.
-- ---------------------------------------------------------------------

function M.placeholder_for(slug)
  return '[station:' .. tostring(slug == nil and '' or slug) .. ']'
end

local SecretBroker = {}
SecretBroker.__index = SecretBroker

function SecretBroker.new(providers)
  local self = setmetatable({}, SecretBroker)
  self.providers = type(providers) == 'table' and providers or {}
  -- Values hoisted by adopt() from a resident options.apikey (design
  -- station.md 3.1).
  self.overrides = {}
  self.cache = {}
  -- Every value this broker ever held, for the exact-value scrub.
  self.held = {}
  return self
end

-- The provider kinds this env-only broker cannot serve (everything but
-- 'env'), for the one honest warning at open.
function SecretBroker:unsupported_kinds()
  local out = {}
  local seen = {}
  for _, p in ipairs(self.providers) do
    local kind = type(p) == 'table' and getk(p, 'kind') or nil
    kind = type(kind) == 'string' and kind or '?'
    if kind ~= 'env' and not seen[kind] then
      seen[kind] = true
      out[#out + 1] = kind
    end
  end
  table.sort(out)
  return out
end

function SecretBroker:hoist(slug, value)
  self.overrides[slug] = value
  self.held[#self.held + 1] = value
end

-- Resolve the value for a plugin's secret name. Env-only, and the miss
-- keeps sekreto's meaning (design station.md 5.2): an unset variable is
-- station_secret_no_value; a set-but-empty variable is a present (empty)
-- value, exactly as sekreto's env provider reads it. There is no store
-- that can "fail to answer" here, so station_secret_error is reserved
-- for malformed names.
function SecretBroker:value(slug, name)
  local override = self.overrides[slug]
  if override ~= nil then
    return override
  end

  local cached = self.cache[slug]
  if cached ~= nil then
    return cached
  end

  local value = os.getenv(M.envkey(name))
  if value == nil then
    fail('station_secret_no_value',
      'no store had "' .. name .. '" for plugin "' .. slug .. '"')
  end

  self.cache[slug] = value
  self.held[#self.held + 1] = value
  return value
end

-- Exact-value scrub, deliberately WITHOUT sekreto's four-character
-- readability floor (design station.md 7 as revised): on boundaries
-- where the promise is absolute, every held value is scrubbed whatever
-- its length.
function SecretBroker:scrub(text)
  local out = tostring(text == nil and '' or text)
  for _, value in ipairs(self.held) do
    if value ~= '' then
      out = replaceall(out, value, '[redacted]')
    end
  end
  return out
end

-- Drop caches so the next resolve asks the environment again (rotation
-- support, design station.md 5.3).
function SecretBroker:refresh()
  self.cache = {}
end

M.SecretBroker = SecretBroker


-- ---------------------------------------------------------------------
-- The Station (design D1: the in-process hub, solo mode)
-- ---------------------------------------------------------------------

local Station = {}
Station.__index = Station
M.Station = Station

local AMBIENT = nil
local AMBIENT_OPTS = nil

local function opts_key(opts)
  local ok, key = pcall(M.canonical_serialize, opts == nil and {} or opts)
  return ok and key or ''
end

-- Ambient instance (design station.md 10.2): open() is the idempotent
-- process-wide singleton; a second open() with conflicting options is
-- an error; M.new(opts) stays isolated for tests and multi-tenant
-- hosts. open() is non-blocking - solo involves no network, and the
-- deferred proxy probe must never change that.
function M.open(opts)
  local key = opts_key(opts)
  if AMBIENT ~= nil then
    if key ~= AMBIENT_OPTS then
      fail('station_open_conflict',
        'Station.open() was already called with different options')
    end
    return AMBIENT
  end
  AMBIENT = M.new(opts)
  AMBIENT_OPTS = key
  return AMBIENT
end

-- The ambient instance, or nil - never creates one. The generated
-- station feature binds through this when no explicit handle rides its
-- options (design station.md 3.1: binding is never implicit; only
-- open() creates the ambient instance).
function M.current()
  return AMBIENT
end

-- Test seam: drop the ambient instance.
function M.reset()
  AMBIENT = nil
  AMBIENT_OPTS = nil
end

local function reset_if(station)
  if AMBIENT == station then
    AMBIENT = nil
    AMBIENT_OPTS = nil
  end
end

function M.new(opts)
  opts = type(opts) == 'table' and opts or {}
  local self = setmetatable({}, Station)

  -- opts.config: a table is used verbatim; M.NULL (or false) means "no
  -- config, do not look for a file" - Lua cannot tell {config = nil}
  -- from absence, so the sentinel stands in for ts's explicit
  -- undefined-vs-null distinction.
  local config
  if opts.config ~= nil then
    config = (opts.config == M.NULL or opts.config == false) and nil or opts.config
  else
    config = M.load_config(opts.folder)
  end

  self._is_station = true
  self.opts = opts
  self.profile = M.resolve_profile(config, M.select_profile(opts.profile))
  self.broker = SecretBroker.new(self.profile.providers)
  self.buffer = EventBuffer.new()
  self.registry = {}
  self.order = {}
  self.secret_override = {}
  self.closed = false

  local proxy = opts.proxy == nil and 'auto' or opts.proxy
  self.require_proxy = 'require' == proxy

  if 'auto' == proxy then
    -- The probe is deferred with the proxy itself; absence degrades to
    -- solo with a single warning event naming the cause (design 14).
    self:_emit({
      t = now_ms(), kind = 'station',
      meta = { warn = 'proxy absent (not found); running solo' },
    })
  end

  -- Env-only honesty (design station.md 2.2): a chain naming stores
  -- this port cannot reach gets said out loud, once, rather than
  -- silently resolving from a weaker store than the profile asked for.
  local missing = self.broker:unsupported_kinds()
  if #missing > 0 then
    self:_emit({
      t = now_ms(), kind = 'station',
      meta = {
        warn = 'lua station is env-only (no sekreto lua port): provider kind(s) [' ..
          table.concat(missing, ', ') .. '] are not available; secrets are read ' ..
          'from the process environment only (design 2.2)',
      },
    })
  end

  return self
end

-- --- binding forms (design station.md 3.1) ---

-- The activation entry. The station handle rides the options as a
-- FUNCTION closure: the generated make_options deep-clones and merges
-- its options, and a plain-table handle could be flattened to a copy on
-- the way through - a function passes by reference, so the handle
-- survives (the perl port's device, for the same reason).
local function activation(self, fmap, calleropts)
  local out = shallowcopy(fmap)
  local entry = shallowcopy(out.station)
  entry.active = true
  entry.station = function()
    return self
  end
  entry.calleropts = calleropts
  out.station = entry
  return out
end

local function construct(self, SDK, opts)
  if self.closed then
    fail('station_no_plugin', 'station is closed')
  end
  opts = type(opts) == 'table' and opts or {}
  local options = shallowcopy(opts)
  options.feature = activation(self, options.feature, opts)

  -- The carried adapter rides extend for SDKs generated WITHOUT the
  -- station feature; when the generated class exists the constructor
  -- uses it and the extend copy's bind is made inert by _bound_entry
  -- (both delegate to feature_binding, so behavior is identical).
  local extend = {}
  if type(opts.extend) == 'table' then
    for i, f in ipairs(opts.extend) do
      extend[i] = f
    end
  end
  extend[#extend + 1] = M.adapter_feature(self, opts)
  options.extend = extend

  if type(SDK) == 'table' and type(SDK.new) == 'function' then
    return SDK.new(options)
  end
  if type(SDK) == 'function' then
    return SDK(options)
  end
  fail('station_no_plugin', 'connect: not a constructable SDK')
end

-- connect(SDK, opts): station constructs the SDK itself, activating the
-- adapter with 3.3 ordering (the generated make_options hoists a
-- map-form station entry to just after test).
function Station:connect(SDK, opts)
  return construct(self, SDK, opts)
end

-- adopt(SDK, opts): the retrofit path - construction-time sugar, not
-- post-hoc attachment (design 3.1). In lua it is the same construction
-- as connect; a resident options.apikey is hoisted by the adapter.
function Station:adopt(SDK, opts)
  return construct(self, SDK, opts)
end

-- Inverted binding (design station.md 3.1): build the plain options map
-- a generated constructor already accepts - the handle and the
-- activation entry; the profile's per-plugin base is applied by the
-- adapter at init (caller opts still win).
function Station:options(extra)
  extra = type(extra) == 'table' and extra or {}
  local out = shallowcopy(extra)
  out.feature = activation(self, out.feature, extra)
  return out
end

-- --- registration (design station.md 3 item 1, called by the adapter) ---

-- The registry entry whose client IS this object, or nil. Used by
-- feature_binding for idempotency: connect/adopt activate the station
-- entry AND ride the carried adapter on extend, so on an SDK whose
-- generated features carry a real station feature class the same
-- construction reaches feature_binding twice - the second arrival must
-- no-op, while a genuinely second client of the same SDK class still
-- fails _register's slug check (design 10.2).
function Station:_bound_entry(client)
  if client == nil then
    return nil
  end
  for _, slug in ipairs(self.order) do
    local entry = self.registry[slug]
    if entry ~= nil and entry.client == client then
      return entry
    end
  end
  return nil
end

local function first_non_empty(...)
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if v ~= nil and v ~= '' then
      return v
    end
  end
  return nil
end

function Station:_register(client, config, options, _calleropts, fopts)
  fopts = type(fopts) == 'table' and fopts or {}

  local descriptor, warnings = M.normalize_descriptor(config,
    type(options) == 'table' and options.feature or nil)
  local slug = descriptor.slug

  if self.registry[slug] ~= nil then
    fail('station_bound_twice',
      'plugin "' .. slug .. '" is already registered; binding one client ' ..
      'twice is an error (10.2)')
  end

  local profile_plugin = self.profile.sdk[slug]

  -- Secret name precedence: the feature option (in-code, design
  -- station.md 9 config.options.secret) beats the profile, which beats
  -- the descriptor default.
  local fsecret = type(fopts.secret) == 'string' and fopts.secret or nil
  if fsecret ~= nil and fsecret ~= '' then
    self.secret_override[slug] = fsecret
  end
  local secretname = first_non_empty(fsecret,
    type(profile_plugin) == 'table' and profile_plugin.secret or nil)
  if secretname == nil then
    secretname = descriptor.auth.secretname
  end

  local auth_active = descriptor.auth.active == true
  local rung = auth_active and 'R1' or 'none'
  local binding = {
    plugin = slug,
    placeholder = auth_active and M.placeholder_for(slug) or nil,
    secretname = auth_active and secretname or nil,
    rung = rung,
  }

  self.registry[slug] = {
    slug = slug,
    descriptor = descriptor,
    rung = rung,
    client = client,
    warnings = warnings,
  }
  self.order[#self.order + 1] = slug

  for _, warning in ipairs(warnings) do
    self:_emit({
      t = now_ms(), kind = 'station', plugin = slug,
      meta = { warn = warning },
    })
  end
  self:_emit({
    t = now_ms(), kind = 'construct', plugin = slug,
    meta = { name = descriptor.name, version = descriptor.version, rung = rung },
  })

  return binding, profile_plugin
end

function Station:_hoist(slug, value)
  self.broker:hoist(slug, value)
  self:_emit({
    t = now_ms(), kind = 'station', plugin = slug,
    meta = {
      warn = 'a resident credential was hoisted into the broker and ' ..
        'replaced by the placeholder; prefer configuring the secret ' ..
        'name and letting the environment resolve it',
    },
  })
end

-- --- the transport middleware (design station.md 3.3, 5.3) ---

-- ( host-with-port, hostname, path ) from a URL, stdlib patterns only.
-- Mirrors ts URL semantics: host keeps a non-default port, hostname
-- strips it, an empty path reads as '/'.
local function parse_url(fullurl)
  local url = type(fullurl) == 'string' and fullurl or ''
  local scheme, authority, path =
    string.match(url, '^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)')
  if scheme == nil then
    return '', '', url
  end
  scheme = string.lower(scheme)
  authority = string.gsub(authority, '^[^@]*@', '')
  local hostname, port = string.match(authority, '^(.*):(%d+)$')
  if hostname == nil then
    hostname = authority
    port = nil
  end
  local default = scheme == 'http' and '80' or (scheme == 'https' and '443' or '')
  local host = hostname
  if port ~= nil and port ~= default then
    host = hostname .. ':' .. port
  end
  if path == nil or path == '' then
    path = '/'
  end
  return host, hostname, path
end

-- Build an operation-path error: the SDK's own error object when the
-- ctx can make one (so downstream err handling sees the shape every
-- other SDK error has), else a station error table.
local function op_error(fctx, code, message)
  if type(fctx) == 'table' and type(fctx.make_error) == 'function' then
    return fctx:make_error(code, code .. ': ' .. message)
  end
  return M.make_error(code, message)
end

local function op_error_from(fctx, err)
  if M.is_station_error(err) and type(fctx) == 'table' and
    type(fctx.make_error) == 'function' then
    return fctx:make_error(err.code, err.message)
  end
  return err
end

-- Called by the adapter's wrap; `inner` is the transport that was
-- current at init time. Returns the SDK's (response, err) pair - err is
-- a value here, never a raise, matching every generated Lua seam.
function Station:_transport(slug, inner, fctx, fullurl, fetchdef)
  -- Fail-closed means traffic (design 2.1): with the proxy deferred,
  -- `require` can never attach, so every operation fails here - the
  -- operation path, never the constructor.
  if self.require_proxy then
    local err = op_error(fctx, 'station_no_proxy',
      'proxy: "require" is set and no proxy is attached')
    self:_emit_err(slug, fctx, err)
    return nil, err
  end

  local entry = self.registry[slug]
  local placeholder = M.placeholder_for(slug)
  local mode = type(fctx) == 'table' and type(fctx.client) == 'table' and
    fctx.client.mode or ''
  local live = 'live' == mode
  local profile_plugin = self.profile.sdk[slug]

  -- Egress policy (design station.md 16), solo half: the hosts
  -- allowlist is enforced at the seam every request crosses. When a
  -- policy is present the fetchdef asks for manual redirects - a 3xx is
  -- a response like any other, so a Location off the allowlist cannot
  -- pull an automatic credentialed follow-up to an unapproved host
  -- (design 8.2's rule at the library seam). NOTE the lua SDK's default
  -- luasocket transport follows GET redirects itself and ignores the
  -- redirect slot; an app-supplied system.fetch should honour it.
  local hosts = type(profile_plugin) == 'table' and
    type(profile_plugin.policy) == 'table' and profile_plugin.policy.hosts or nil
  if type(hosts) ~= 'table' then
    hosts = nil
  end

  if hosts ~= nil and live then
    local _, hostname = parse_url(fullurl)
    local allowed = false
    for _, h in ipairs(hosts) do
      if h == hostname then
        allowed = true
        break
      end
    end
    if not allowed then
      local err = op_error(fctx, 'station_host_allow',
        'egress to "' .. hostname .. '" denied by the hosts policy of ' ..
        'plugin "' .. slug .. '"')
      self:_emit_err(slug, fctx, err)
      return nil, err
    end
  end

  local senddef = fetchdef
  if hosts ~= nil and live then
    senddef = shallowcopy(senddef)
    senddef.redirect = 'manual'
  end

  -- Injection: at the last boundary, below every recording feature, and
  -- never into mock transports (design 3.3) - in test/mock modes the
  -- placeholder rides through untouched, so real credentials never
  -- enter in-memory mock stores. Copy-on-inject (design 5.3): the
  -- generated request machinery shares references - fetchdef.headers IS
  -- spec.headers, and ctrl.explain holds the fetchdef - so the fetchdef
  -- and its headers map are duplicated before the swap; the object
  -- graph reachable from ctx/spec/ctrl holds only the placeholder, ever.
  if live and entry ~= nil and 'R1' == entry.rung then
    local secretname = first_non_empty(self.secret_override[slug],
      type(profile_plugin) == 'table' and profile_plugin.secret or nil)
    if secretname == nil then
      secretname = entry.descriptor.auth.secretname
    end

    local ok, value = pcall(function()
      return self.broker:value(slug, secretname)
    end)
    if not ok then
      local err = op_error_from(fctx, value)
      self:_emit_err(slug, fctx, err)
      return nil, err
    end

    senddef = shallowcopy(senddef)
    local headers = shallowcopy(senddef.headers)
    for h, v in pairs(headers) do
      if type(v) == 'string' and string.find(v, placeholder, 1, true) ~= nil then
        headers[h] = replaceall(v, placeholder, value)
      end
    end
    senddef.headers = headers
  end

  local st = type(fctx) == 'table' and type(fctx['station$']) == 'table' and
    fctx['station$'] or nil
  local corr = st ~= nil and st.corr or nil
  local started = now_ms()

  local ok, res, err = pcall(inner, fctx, fullurl, senddef)
  if not ok then
    -- The transport raised (not the SDK convention, but a wrap must not
    -- swallow it): record, then re-raise unchanged.
    self:_emit_http(slug, corr, fullurl, senddef, 0, started, 0)
    self:_emit_err(slug, fctx, res)
    error(res, 0)
  end

  if err ~= nil then
    self:_emit_http(slug, corr, fullurl, senddef, 0, started, 0)
    self:_emit_err(slug, fctx, err)
    return res, err
  end

  if res == nil then
    -- No response and no err: surface it as the transport failure the
    -- pipeline will treat it as.
    self:_emit_http(slug, corr, fullurl, senddef, 0, started, 0)
    return res, err
  end

  local status = 0
  if type(res) == 'table' and type(res.status) == 'number' then
    status = math.floor(res.status)
  end
  local bytes = 0
  if type(res) == 'table' and type(res.headers) == 'table' then
    local cl = res.headers['content-length']
    bytes = math.floor(tonumber(cl) or 0)
  end
  self:_emit_http(slug, corr, fullurl, senddef, status, started, bytes)

  return res, err
end

-- Op events from the hook bridge (design station.md 3 item 3).
function Station:_op_event(slug, ctx, outcome)
  local st = type(ctx) == 'table' and type(ctx['station$']) == 'table' and
    ctx['station$'] or {}

  -- ctx.op is the SDK's resolved Operation: name + entity, with '_' as
  -- the generated Lua SDKs' absence sentinel (core/context resolve_op).
  local op = type(ctx) == 'table' and type(ctx.op) == 'table' and ctx.op or {}
  local entity = type(op.entity) == 'string' and op.entity or ''
  if '_' == entity then
    entity = ''
  end
  if '' == entity and type(ctx) == 'table' and type(ctx.entity) == 'table' and
    type(ctx.entity.get_name) == 'function' then
    local ok, name = pcall(function()
      return ctx.entity:get_name()
    end)
    if ok and type(name) == 'string' then
      entity = name
    end
  end
  local opname = type(op.name) == 'string' and op.name or ''
  if '_' == opname then
    opname = ''
  end

  self:_emit({
    t = now_ms(), kind = 'op', plugin = slug, corr = st.corr,
    op = {
      entity = entity,
      op = opname,
      outcome = outcome,
      durationMs = st.start ~= nil and (now_ms() - st.start) or 0,
    },
  })
end

-- --- the query/observe surface (design station.md 3.2, 6) ---

function Station:plugins()
  local out = {}
  for _, slug in ipairs(self.order) do
    local entry = self.registry[slug]
    local warnings = {}
    for i, w in ipairs(entry.warnings) do
      warnings[i] = w
    end
    out[#out + 1] = {
      slug = entry.slug,
      descriptor = entry.descriptor,
      rung = entry.rung,
      warnings = warnings,
    }
  end
  return out
end

function Station:descriptor_of(slug)
  local entry = slug ~= nil and self.registry[slug] or nil
  if entry == nil then
    fail('station_no_plugin', 'unknown plugin "' .. tostring(slug) ..
      '"; known: [' .. table.concat(self.order, ', ') .. ']')
  end
  return entry.descriptor
end

function Station:canonical_descriptor(slug)
  return M.canonical_serialize(self:descriptor_of(slug))
end

function Station:events()
  return self.buffer:events()
end

function Station:tap(fn)
  return self.buffer:tap(fn)
end

function Station:status()
  local plugins = {}
  for _, p in ipairs(self:plugins()) do
    plugins[#plugins + 1] = { slug = p.slug, rung = p.rung }
  end
  return {
    mode = 'solo',
    profile = self.profile.name,
    plugins = plugins,
    events = self.buffer:status(),
    -- Env-only, stated where an operator will read it (design 2.2).
    secrets = 'env-only',
  }
end

function Station:redact(text)
  return self.broker:scrub(text)
end

function Station:refresh_secrets()
  self.broker:refresh()
end

-- close(): flush (solo: nothing in flight), then warn on profile plugin
-- keys that matched no registered plugin - a typo'd key silently
-- configuring nothing is the worst outcome for a secrets-and-policy
-- file (design station.md 11).
function Station:close()
  if self.closed then
    return
  end
  for _, slug in ipairs(sortedkeys(self.profile.sdk)) do
    if self.registry[slug] == nil then
      self:_emit({
        t = now_ms(), kind = 'station',
        meta = {
          warn = 'profile plugin key "' .. slug ..
            '" matched no registered plugin',
        },
      })
    end
  end
  self.closed = true
  reset_if(self)
end

-- --- internals ---

function Station:_emit(ev)
  self.buffer:emit(ev)
end

function Station:_emit_http(slug, corr, fullurl, fetchdef, status, started, bytes)
  local host, _, path = parse_url(fullurl)
  self:_emit({
    t = started, kind = 'http', plugin = slug, corr = corr,
    http = {
      method = type(fetchdef) == 'table' and type(fetchdef.method) == 'string' and
        fetchdef.method or 'GET',
      host = host,
      path = path,
      status = status,
      durationMs = now_ms() - started,
      bytes = bytes,
    },
  })
end

function Station:_emit_err(slug, fctx, err)
  local st = type(fctx) == 'table' and type(fctx['station$']) == 'table' and
    fctx['station$'] or nil

  local code = nil
  if type(err) == 'table' and type(err.code) == 'string' and err.code ~= '' then
    code = err.code
  end

  -- The scrub keeps an upstream echo of a credential out of the event
  -- stream (design station.md 7 as revised: exact-value, no length
  -- floor).
  local message
  if type(err) == 'table' and getmetatable(err) == nil and err.msg ~= nil then
    message = tostring(err.msg)
  else
    message = tostring(err == nil and '' or err)
  end

  self:_emit({
    t = now_ms(), kind = 'error', plugin = slug,
    corr = st ~= nil and st.corr or nil,
    err = { code = code, message = self:redact(message) },
  })
end


-- ---------------------------------------------------------------------
-- The adapter (design station.md 3), in ONE place: feature_binding() is
-- what both entry paths delegate to -
--  - the GENERATED station feature (sdkgen-station's lua template)
--    calls it from its init and forwards its hook methods;
--  - the library's carried adapter (adapter_feature, the adopt/connect
--    retrofit for SDKs generated without the feature) is a thin shell
--    over the same call.
-- Registration at init, wrap position verified, transport wrapped with
-- copy-on-inject, hooks bridged to op events. Anything changed here
-- changes both paths - which is the point.
-- ---------------------------------------------------------------------

local CORR_SEQ = 0

-- The station wrap marker (ts's __station__ property). Lua functions
-- carry no fields, so the mark lives in a weak-keyed table - keys are
-- garbage-collected with the functions, so entries are never stale.
local WRAP_MARK = setmetatable({}, { __mode = 'k' })

-- Resolve the station a binding names: a live handle, a function
-- closure (how connect/adopt/options ride the handle through the
-- generated make_options, whose clone/merge could flatten a plain
-- table), or nil.
local function resolve_station(handle)
  if type(handle) == 'table' and handle._is_station == true then
    return handle
  end
  if type(handle) == 'function' then
    local ok, station = pcall(handle)
    if ok and type(station) == 'table' and station._is_station == true then
      return station
    end
  end
  return nil
end

-- Resolve the station this activation binds to: an explicit handle in
-- the feature options (connect/adopt and st:options() pass one), else
-- the ambient instance. No station open -> nil: an activated feature
-- with no opened station is an inert no-op that emits nothing and fails
-- nothing (design station.md 3.1).
function M.feature_binding(ctx, fopts)
  fopts = type(fopts) == 'table' and fopts or {}

  local station = resolve_station(fopts.station)
  if station == nil then
    station = M.current()
  end
  if station == nil then
    return nil
  end

  local client = ctx.client

  -- Same construction, second arrival (generated feature + carried
  -- adapter both active on one client): the first bind won, this one is
  -- inert. See Station:_bound_entry.
  if station:_bound_entry(client) ~= nil then
    return nil
  end

  local utility = ctx.utility
  local options = ctx.options
  local calleropts = fopts.calleropts

  -- Position guard (design station.md 3.3): the wrap must sit
  -- immediately outside the base transport - inside retry/cache/
  -- ratelimit - or its http events stop being wire truth. Position in
  -- client.features IS init order, so verify it and fail loudly.
  --
  -- One lua-specific tolerance (the rb and perl ports', for the same
  -- reason): the generated _make_feature FALLS BACK to an inert base
  -- feature for unknown names, so an activated station entry on a
  -- pre-station SDK adds a stray named "base" (the ts constructor skips
  -- such names instead). A base feature has a no-op init - it can never
  -- wrap or record the transport - so strays are excluded from the
  -- order check, which keeps the guard's actual meaning: nothing that
  -- could wrap sits between the base transport and station.
  local names = {}
  local features = type(client) == 'table' and client.features or nil
  if type(features) == 'table' then
    for _, f in ipairs(features) do
      local name = nil
      if type(f) == 'table' then
        if type(f.name) == 'string' then
          name = f.name
        elseif type(f.get_name) == 'function' then
          local ok, got = pcall(function()
            return f:get_name()
          end)
          if ok and type(got) == 'string' then
            name = got
          end
        end
      end
      names[#names + 1] = name == nil and '' or name
    end
  end
  local order = {}
  for _, name in ipairs(names) do
    if 'base' ~= name then
      order[#order + 1] = name
    end
  end
  local self_at, test_at = nil, nil
  for i, name in ipairs(order) do
    if self_at == nil and 'station' == name then
      self_at = i
    end
    if test_at == nil and 'test' == name then
      test_at = i
    end
  end
  local expected = test_at == nil and 1 or test_at + 1
  if self_at == nil or self_at ~= expected then
    fail('station_wrap_order',
      'station must init immediately after the base transport; ' ..
      'feature order is [' .. table.concat(names, ', ') .. ']')
  end

  local binding, profile_plugin = station:_register(
    client, ctx.config, options, calleropts, fopts)
  local slug = binding.plugin

  -- Base URL precedence (design station.md 3.5): caller opts (7) beat
  -- the profile (4), which beats the SDK's config default (1) already
  -- in options.base. calleropts is knowable on every binding form
  -- (connect/adopt and st:options() all pass it).
  if type(calleropts) == 'table' and calleropts.base == nil and
    type(profile_plugin) == 'table' and profile_plugin.base ~= nil then
    options.base = profile_plugin.base
  end

  if 'none' ~= binding.rung then
    local placeholder = binding.placeholder

    -- A real credential already resident in the options is hoisted into
    -- the broker and replaced by the placeholder before construction
    -- completes (design station.md 3.1 adopt) - options_map() and
    -- prepare() output become placeholder-safe from here on.
    local resident = options.apikey
    if type(resident) == 'string' and resident ~= '' and resident ~= placeholder then
      station:_hoist(slug, resident)
    end
    options.apikey = placeholder
  end

  -- Wrap the transport. Copy-on-inject (design station.md 5.3) happens
  -- inside Station:_transport; auth-inactive plugins skip credential
  -- planning but the wrap still observes.
  local inner = utility.fetcher
  if WRAP_MARK[inner] then
    fail('station_bound_twice',
      'plugin "' .. slug .. '" already carries a station wrap')
  end
  local wrapped = function(fctx, fullurl, fetchdef)
    return station:_transport(slug, inner, fctx, fullurl, fetchdef)
  end
  WRAP_MARK[wrapped] = true
  utility.fetcher = wrapped

  -- The hook bridge (design station.md 3 item 3): operation semantics
  -- correlated with the HTTP events via a per-operation id carried on
  -- the SDK's own ctx ('station$' - a plain table key). Plain-function
  -- fields taking the op ctx: callers use dot-call.
  local bridge = {
    slug = slug,

    PrePoint = function(opctx)
      CORR_SEQ = CORR_SEQ + 1
      opctx['station$'] = { corr = 'c' .. CORR_SEQ, start = now_ms() }
    end,

    PreDone = function(opctx)
      station:_op_event(slug, opctx, M.result_outcome(opctx))
    end,

    PreUnexpected = function(opctx)
      station:_op_event(slug, opctx, 'unexpected')
    end,
  }
  return bridge
end

function M.result_outcome(ctx)
  local result = type(ctx) == 'table' and ctx.result or nil
  if result == nil then
    return 'unknown'
  end
  if result.err ~= nil then
    return 'err'
  end
  if result.ok == false then
    return 'err'
  end
  return 'ok'
end

-- The carried adapter: the retrofit path for SDKs generated without the
-- station feature (design station.md 3.1 adopt). A duck-typed feature
-- table whose init/hooks delegate to feature_binding - it exists so
-- connect/adopt work on any regenerated SDK, and it must stay
-- behaviorally identical to the generated feature template in
-- sdkgen-station. State rides on `self`, never on upvalues: the
-- generated make_options CLONES options.extend, and the cloned table is
-- the instance whose methods actually run. The station handle is a
-- function field for the same reason (function refs survive the clone).
function M.adapter_feature(station, calleropts)
  local feature = {
    name = 'station',
    version = '0.0.1',
    active = true,
    _binding = nil,
    _station = function()
      return station
    end,
    _calleropts = calleropts,

    -- feature_add reads _options for positioning: immediately after the
    -- test feature's base transport (design station.md 3.3). When test
    -- is absent from the add order this is a no-op append, which for a
    -- bare SDK still lands the wrap immediately outside the base
    -- transport.
    _options = { __after__ = 'test' },
  }

  function feature.get_name(self)
    return self.name
  end

  function feature.get_version(self)
    return self.version
  end

  function feature.get_active(self)
    return self.active
  end

  function feature.init(self, ctx, fopts)
    local merged = shallowcopy(fopts)
    merged.station = self._station
    merged.calleropts = self._calleropts
    self._binding = M.feature_binding(ctx, merged)
  end

  function feature.PrePoint(self, ctx)
    if self._binding ~= nil then
      self._binding.PrePoint(ctx)
    end
  end

  function feature.PreDone(self, ctx)
    if self._binding ~= nil then
      self._binding.PreDone(ctx)
    end
  end

  function feature.PreUnexpected(self, ctx)
    if self._binding ~= nil then
      self._binding.PreUnexpected(ctx)
    end
  end

  return feature
end


return M
