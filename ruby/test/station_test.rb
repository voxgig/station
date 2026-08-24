# frozen_string_literal: true

# RUN: ruby test/station_test.rb
# RUN-SOME: ruby test/station_test.rb -n test_inject_copy_on_inject
#
# Focused unit tests for the parts the corpus cannot express without an
# SDK: the binding (wrap position, placeholder planting, hoist), the
# transport middleware (copy-on-inject, mock skip, status-0 mapping,
# hosts policy, require-proxy fail-closed, secret miss), and the event
# surface. A miniature duck-typed SDK stands in for a generated one,
# mirroring the generated rb feature-test harness idiom.

require 'json'
require 'tmpdir'

require 'minitest/autorun'

require_relative 'helper'

# --- a miniature generated-SDK stand-in ---

class FakeUtility
  attr_accessor :fetcher
end

class FakeClient
  attr_accessor :mode, :features, :options

  def initialize
    @mode = 'live'
    @features = []
    @options = nil
  end
end

class FakeOp
  attr_reader :entity, :name

  def initialize(entity, name)
    @entity = entity
    @name = name
  end
end

class FakeResult
  attr_accessor :ok, :err

  def initialize(ok, err = nil)
    @ok = ok
    @err = err
  end
end

class FakeCtx
  attr_accessor :client, :utility, :options, :config, :op, :result, :entity

  def initialize(client, utility, options, config)
    @client = client
    @utility = utility
    @options = options
    @config = config
  end
end

class FakeFeature
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def get_name
    @name
  end
end

CONFIG = {
  'main' => { 'name' => 'GnarlyPets', 'slug' => 'gnarly-pets',
              'version' => '0.0.1', 'target' => 'rb' },
  'feature' => { 'test' => {} },
  'options' => {
    'base' => 'http://localhost:8903',
    'auth' => { 'prefix' => 'Bearer' },
    'entity' => { 'pet' => {} },
  },
  'entity' => {},
}.freeze

PLACEHOLDER = '[station:gnarly-pets]'

# Build a bound miniature client: station feature first (bare SDK), a
# stub inner transport, and the station wrap installed by
# feature_binding.
def bind(station, inner, opts = {})
  client = FakeClient.new
  utility = FakeUtility.new
  utility.fetcher = inner

  options = {
    'apikey' => opts['apikey'] || '',
    'base' => 'http://localhost:8903',
    'feature' => { 'station' => { 'active' => true } },
  }
  client.options = options

  ctx = FakeCtx.new(client, utility, options, opts['config'] || CONFIG.dup)

  feature = VoxgigStation.adapter_feature(station, opts['calleropts'] || {})
  (opts['pre_features'] || []).each { |f| client.features << f }
  client.features << feature
  (opts['post_features'] || []).each { |f| client.features << f }

  fopts = options['feature']['station']
    .merge('station' => station, 'calleropts' => opts['calleropts'] || {})
  feature.init(ctx, fopts)

  { client: client, utility: utility, ctx: ctx, feature: feature, options: options }
end

def okres(status = 200, headers = {})
  { 'status' => status, 'statusText' => 'OK',
    'headers' => headers, 'json' => -> { nil }, 'body' => '' }
end


# --- a miniature FACTORY-registered SDK, for the declarative front door ---
#
# The generated package emits its config as a module-level constant
# (design station.md 6.2), so a factory is a constructor PLUS that
# constant. This stand-in carries both, and its constructor consumes
# `extend` the way a generated one does.

SOLAR_CONFIG = {
  'main' => { 'name' => 'Solar', 'slug' => 'solar',
              'version' => '1.2.3', 'target' => 'rb' },
  'feature' => {
    'debug' => { 'options' => { 'level' => 0 } },
    'ratelimit' => { 'options' => { 'rate' => 1, 'burst' => 1 } },
    'retry' => { 'options' => { 'max' => 1, 'wait' => 100 } },
    'test' => { 'transport' => 'base' },
  },
  'options' => {
    'base' => 'http://solar.test',
    'auth' => { 'prefix' => 'Bearer' },
  },
  'entity' => {},
}.freeze

class SolarSDK
  attr_reader :options, :client, :utility, :ctx

  def initialize(options)
    @options = options
    @client = FakeClient.new
    @utility = FakeUtility.new
    @utility.fetcher = ->(_c, _u, _d) { [okres, nil] }
    @client.options = options
    @ctx = FakeCtx.new(@client, @utility, options, SOLAR_CONFIG)

    fopts = (options['feature'] || {})['station'] || {}
    (options['extend'] || []).each do |f|
      @client.features << f
      f.init(@ctx, fopts)
    end
  end
end

# ONE pair, so `provide` twice is the documented no-op rather than a
# conflict.
SOLAR_CONSTRUCT = ->(o) { SolarSDK.new(o) }
SOLAR_FACTORY = { 'construct' => SOLAR_CONSTRUCT, 'config' => SOLAR_CONFIG }.freeze

# The retrofit path (design station.md 6.3): a package that
# self-registers nothing, whose constructor and `config` singleton are
# read off the namespace. In rb the "module" is a NAMESPACE and `export`
# names a constant in it.
module RetroPackage
  CONFIG = SOLAR_CONFIG

  class SDK
    attr_reader :options

    def initialize(options)
      @options = options
    end
  end
end

module CtorlessPackage
  CONFIG = SOLAR_CONFIG
end

module ConfiglessPackage
  class SDK
    def initialize(options); end
  end
end

class TestStation < Minitest::Test
  ENVKEYS = %w[
    GNARLY_PETS_APIKEY VOXGIG_STATION_PROFILE
    SOLAR_APIKEY SOLAR_EU_APIKEY SHARED_APIKEY CUSTOM_TOKEN
  ].freeze

  def setup
    VoxgigStation::Station.reset
    # The factory table is PROCESS-GLOBAL by design (6.2), so a suite
    # that registers factories has to be able to put the process back.
    VoxgigStation.reset_factories
    ENVKEYS.each { |k| ENV.delete(k) }
  end

  def teardown
    VoxgigStation::Station.reset
    VoxgigStation.reset_factories
    ENVKEYS.each { |k| ENV.delete(k) }
  end

  # A station over one in-code default profile - repo-scoped by
  # construction, because the application wrote it (6.3).
  def solar_station(profile)
    VoxgigStation::Station.new(
      'config' => { 'station' => 1, 'profiles' => { 'default' => profile } })
  end

  # --- ambient instance (design station.md 10.2) ---

  def test_open_is_idempotent_and_conflicts_error
    a = VoxgigStation::Station.open('config' => nil)
    b = VoxgigStation::Station.open('config' => nil)
    assert_same a, b
    err = assert_raises(VoxgigStation::StationError) do
      VoxgigStation::Station.open('config' => nil, 'profile' => 'prod')
    end
    assert_equal 'station_open_conflict', err.code
    assert_same a, VoxgigStation::Station.current
    VoxgigStation::Station.reset
    assert_nil VoxgigStation::Station.current
  end

  def test_close_resets_ambient_and_warns_unmatched_plugin_keys
    st = VoxgigStation::Station.open('config' => {
      'station' => 1,
      'profiles' => { 'default' => { 'sdk' => { 'typo-slug' => { 'base' => 'http://x' } } } },
    })
    st.close
    warns = st.events.select do |e|
      'station' == e['kind'] && e.dig('meta', 'warn').to_s.include?('typo-slug')
    end
    assert_equal 1, warns.length
    assert_nil VoxgigStation::Station.current
  end

  # --- binding (design station.md 3) ---

  def test_binding_plants_placeholder_and_registers
    ENV['GNARLY_PETS_APIKEY'] = 'k-123'
    st = VoxgigStation::Station.new('config' => nil)
    b = bind(st, ->(_c, _u, _d) { [okres, nil] })

    assert_equal PLACEHOLDER, b[:options]['apikey']
    assert_equal 1, st.plugins.length
    assert_equal 'gnarly-pets', st.plugins[0]['slug']
    assert_equal 'R1', st.plugins[0]['rung']
    construct = st.events.select { |e| 'construct' == e['kind'] }
    assert_equal 1, construct.length
    assert_equal 'rb', st.descriptor_of('gnarly-pets')['target']
  end

  def test_binding_hoists_a_resident_credential
    st = VoxgigStation::Station.new('config' => nil)
    seen = nil
    b = bind(st, lambda { |_c, _u, d|
      seen = d['headers']['authorization']
      [okres, nil]
    }, 'apikey' => 'resident-1')

    assert_equal PLACEHOLDER, b[:options]['apikey']
    warns = st.events.select do |e|
      'station' == e['kind'] && e.dig('meta', 'warn').to_s.include?('hoisted')
    end
    assert_equal 1, warns.length

    # The hoisted value is injected on the wire without any store.
    res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => { 'authorization' => 'Bearer ' + PLACEHOLDER })
    assert_nil err
    assert_equal 200, res['status']
    assert_equal 'Bearer resident-1', seen
    # ...and the scrub covers it, whatever its length (no 4-char floor).
    assert_equal '[redacted]', st.redact('resident-1')
  end

  def test_wrap_order_guard_trips_when_a_wrapper_precedes
    st = VoxgigStation::Station.new('config' => nil)
    err = assert_raises(VoxgigStation::StationError) do
      bind(st, ->(_c, _u, _d) { [okres, nil] },
        'pre_features' => [FakeFeature.new('retry')])
    end
    assert_equal 'station_wrap_order', err.code
  end

  def test_wrap_order_guard_ignores_inert_base_strays
    st = VoxgigStation::Station.new('config' => nil)
    b = bind(st, ->(_c, _u, _d) { [okres, nil] },
      'pre_features' => [FakeFeature.new('base')])
    assert_equal 1, st.plugins.length
    assert_equal PLACEHOLDER, b[:options]['apikey']
  end

  def test_second_bind_of_same_client_is_inert
    st = VoxgigStation::Station.new('config' => nil)
    b = bind(st, ->(_c, _u, _d) { [okres, nil] })

    # Same client, second arrival (generated feature + carried adapter):
    # must no-op, not raise, and not double-wrap.
    second = VoxgigStation.adapter_feature(st, {})
    b[:client].features << second
    fopts = b[:options]['feature']['station'].merge('station' => st, 'calleropts' => {})
    second.init(b[:ctx], fopts)

    assert_equal 1, st.plugins.length
    outer = b[:utility].fetcher
    assert outer.instance_variable_get(:@__station__)
  end

  def test_binding_a_second_client_of_same_slug_errors
    st = VoxgigStation::Station.new('config' => nil)
    bind(st, ->(_c, _u, _d) { [okres, nil] })
    err = assert_raises(VoxgigStation::StationError) do
      bind(st, ->(_c, _u, _d) { [okres, nil] })
    end
    assert_equal 'station_bound_twice', err.code
  end

  def test_profile_base_applied_unless_caller_base_wins
    config = {
      'station' => 1,
      'profiles' => { 'default' => {
        'sdk' => { 'gnarly-pets' => { 'base' => 'http://profile:9' } },
      } },
    }
    st = VoxgigStation::Station.new('config' => config)
    b = bind(st, ->(_c, _u, _d) { [okres, nil] }, 'calleropts' => {})
    assert_equal 'http://profile:9', b[:options]['base']

    VoxgigStation::Station.reset
    st2 = VoxgigStation::Station.new('config' => config)
    b2 = bind(st2, ->(_c, _u, _d) { [okres, nil] },
      'calleropts' => { 'base' => 'http://caller:7' })
    assert_equal 'http://localhost:8903', b2[:options]['base']
  end

  # --- the transport middleware (design station.md 3.3, 5.3) ---

  def test_inject_copy_on_inject
    ENV['GNARLY_PETS_APIKEY'] = 'wire-key-9'
    st = VoxgigStation::Station.new('config' => nil)
    seen = nil
    b = bind(st, lambda { |_c, _u, d|
      seen = d
      [okres(200, 'content-length' => '12'), nil]
    })

    fetchdef = { 'method' => 'GET',
                 'headers' => { 'authorization' => 'Bearer ' + PLACEHOLDER } }
    b[:feature].PrePoint(b[:ctx])
    res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/api/pet', fetchdef)

    assert_nil err
    assert_equal 200, res['status']
    # The wire got the real value...
    assert_equal 'Bearer wire-key-9', seen['headers']['authorization']
    # ...and the caller-visible fetchdef still holds the placeholder
    # (copy-on-inject: ctrl.explain / ctx.spec share this hash).
    assert_equal 'Bearer ' + PLACEHOLDER, fetchdef['headers']['authorization']
    refute_same fetchdef['headers'], seen['headers']

    # The http event is wire truth, correlated with the op.
    b[:ctx].op = FakeOp.new('pet', 'list')
    b[:ctx].result = FakeResult.new(true)
    b[:feature].PreDone(b[:ctx])

    http = st.events.select { |e| 'http' == e['kind'] }
    op = st.events.select { |e| 'op' == e['kind'] }
    assert_equal 1, http.length
    assert_equal 1, op.length
    assert_equal http[0]['corr'], op[0]['corr']
    assert_equal 200, http[0]['http']['status']
    assert_equal 12, http[0]['http']['bytes']
    assert_equal 'localhost:8903', http[0]['http']['host']
    assert_equal '/api/pet', http[0]['http']['path']
    assert_equal({ 'entity' => 'pet', 'op' => 'list', 'outcome' => 'ok' },
      op[0]['op'].slice('entity', 'op', 'outcome'))
    # No credential anywhere in the event stream.
    refute_includes JSON.generate(st.events), 'wire-key-9'
  end

  def test_no_injection_into_mock_transports
    ENV['GNARLY_PETS_APIKEY'] = 'never-on-mock'
    st = VoxgigStation::Station.new('config' => nil)
    seen = nil
    b = bind(st, lambda { |_c, _u, d|
      seen = d['headers']['authorization']
      [okres, nil]
    })

    b[:client].mode = 'test'
    _res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => { 'authorization' => 'Bearer ' + PLACEHOLDER })
    assert_nil err
    # Placeholder rides through untouched; the http event still records
    # the mock attempt.
    assert_equal 'Bearer ' + PLACEHOLDER, seen
    assert_equal 1, st.events.count { |e| 'http' == e['kind'] }
  end

  def test_status_0_is_a_transport_failure
    ENV['GNARLY_PETS_APIKEY'] = 'status-zero-key'
    st = VoxgigStation::Station.new('config' => nil)
    b = bind(st, lambda { |_c, _u, _d|
      [{ 'status' => 0, 'statusText' => 'SocketError: boom',
         'headers' => {}, 'json' => -> { nil }, 'body' => nil }, nil]
    })

    res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => {})
    assert_nil err
    assert_equal 0, res['status']

    http = st.events.select { |e| 'http' == e['kind'] }
    errs = st.events.select { |e| 'error' == e['kind'] }
    assert_equal 1, http.length
    assert_equal 0, http[0]['http']['status']
    assert_equal 1, errs.length
    assert_includes errs[0]['err']['message'], 'SocketError'
  end

  def test_hosts_policy_denies_off_list_egress
    ENV['GNARLY_PETS_APIKEY'] = 'k'
    st = VoxgigStation::Station.new('config' => {
      'station' => 1,
      'profiles' => { 'default' => { 'sdk' => {
        'gnarly-pets' => { 'policy' => { 'hosts' => ['api.other.example'] } },
      } } },
    })
    called = false
    b = bind(st, ->(_c, _u, _d) { called = true; [okres, nil] })

    _res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => {})
    refute called
    assert_equal 'station_host_allow', err.code
    errs = st.events.select { |e| 'error' == e['kind'] }
    assert_equal 'station_host_allow', errs[0]['err']['code']
  end

  def test_require_proxy_fails_on_the_operation_path
    ENV['GNARLY_PETS_APIKEY'] = 'k'
    st = VoxgigStation::Station.new('config' => nil, 'proxy' => 'require')
    # Construction succeeds (non-blocking open, design station.md 2.1)...
    b = bind(st, ->(_c, _u, _d) { [okres, nil] })
    # ...and every operation fails closed.
    _res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => {})
    assert_equal 'station_no_proxy', err.code
  end

  def test_missing_secret_is_no_value_on_the_op_path
    st = VoxgigStation::Station.new('config' => nil)
    b = bind(st, ->(_c, _u, _d) { [okres, nil] })

    _res, err = b[:utility].fetcher.call(b[:ctx], 'http://localhost:8903/x',
      'method' => 'GET', 'headers' => { 'authorization' => PLACEHOLDER })
    assert_equal 'station_secret_no_value', err.code
    errs = st.events.select { |e| 'error' == e['kind'] }
    assert_equal 1, errs.length
    assert_equal 'station_secret_no_value', errs[0]['err']['code']
  end

  def test_secret_option_overrides_the_default_name
    ENV['CUSTOM_TOKEN'] = 'custom-9'
    begin
      st = VoxgigStation::Station.new('config' => nil)
      client = FakeClient.new
      utility = FakeUtility.new
      seen = nil
      utility.fetcher = ->(_c, _u, d) { seen = d['headers']['authorization']; [okres, nil] }
      options = { 'apikey' => '', 'base' => 'http://localhost:8903',
                  'feature' => { 'station' => { 'active' => true, 'secret' => 'custom.token' } } }
      client.options = options
      ctx = FakeCtx.new(client, utility, options, CONFIG.dup)
      feature = VoxgigStation.adapter_feature(st, {})
      client.features << feature
      feature.init(ctx, options['feature']['station']
        .merge('station' => st, 'calleropts' => {}))

      _res, err = utility.fetcher.call(ctx, 'http://localhost:8903/x',
        'method' => 'GET', 'headers' => { 'authorization' => PLACEHOLDER })
      assert_nil err
      assert_equal 'custom-9', seen
    ensure
      ENV.delete('CUSTOM_TOKEN')
    end
  end

  # --- events (design station.md 6) ---

  def test_ring_overflow_drops_oldest_and_counts
    buffer = VoxgigStation::EventBuffer.new(3)
    5.times { |i| buffer.emit('t' => i, 'kind' => 'station') }
    assert_equal [2, 3, 4], buffer.events.map { |e| e['t'] }
    assert_equal({ 'buffered' => 3, 'dropped' => 2 }, buffer.status)
  end

  def test_tap_serializes_and_unsubscribes
    buffer = VoxgigStation::EventBuffer.new
    seen = []
    unsub = buffer.tap(->(ev) { seen << ev['t'] })
    raising = buffer.tap(->(_ev) { raise 'tap failure never fails the op' })
    buffer.emit('t' => 1, 'kind' => 'station')
    unsub.call
    raising.call
    buffer.emit('t' => 2, 'kind' => 'station')
    assert_equal [1], seen
  end

  # --- profile selection (design station.md 3.5) ---

  def test_env_profile_selected_unless_opt_wins
    ENV['VOXGIG_STATION_PROFILE'] = 'prod'
    assert_equal 'prod', VoxgigStation.select_profile(nil)
    assert_equal 'stage', VoxgigStation.select_profile('stage')
    ENV.delete('VOXGIG_STATION_PROFILE')
    assert_equal 'default', VoxgigStation.select_profile(nil)
  end

  # --- the config shape, as data (design station.md 4) ---

  # The two block specs are ONE grammar written twice; a drift between
  # them is how `api` and `sdk` stop accepting the same keys.
  def test_shape_block_specs_are_identical
    child = VoxgigStation.config_shape['profiles']['`$CHILD`']
    assert_equal child['api']['`$CHILD`'], child['sdk']['`$CHILD`']
  end

  # `$OPEN` re-opens a map where a foreign grammar must pass through, and
  # the only foreign grammar in this shape is a feature's own options.
  # Anywhere else it would be a hole in the unexpected-key check that 4.2
  # exists to keep live.
  def test_shape_open_nodes_are_only_the_three_feature_entries
    found = []
    walk = lambda do |node, path|
      if node.is_a?(Hash)
        found << path if node.key?('`$OPEN`')
        node.each { |k, v| walk.call(v, path + '.' + k.to_s) }
      elsif node.is_a?(Array)
        node.each_with_index { |v, i| walk.call(v, path + '.' + i.to_s) }
      end
    end
    walk.call(VoxgigStation.config_shape, '')

    assert_equal [
      '.profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`',
      '.profiles.`$CHILD`.feature.`$CHILD`',
      '.profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`',
    ], found.sort
  end

  # struct's validate CONSUMES the spec it walks, so a shared constant
  # would validate the second config against a spec the first had eaten.
  def test_config_shape_is_a_fresh_copy_every_call
    a = VoxgigStation.config_shape
    b = VoxgigStation.config_shape
    refute_same a, b
    assert_equal a, b
    a['profiles'] = 'eaten'
    refute_equal a, VoxgigStation.config_shape
  end

  # The timing rule, asserted rather than inferred (4.2): `active` is the
  # one block default that must NOT be synthesized before the merge, and
  # it is exactly the one that is not a container.
  def test_block_defaults_and_merge_sensitive_agree
    assert_equal ['active'], VoxgigStation::MERGE_SENSITIVE

    VoxgigStation::MERGE_SENSITIVE.each do |k|
      assert VoxgigStation::BLOCK_DEFAULTS.key?(k),
        'merge-sensitive key with no default: ' + k
    end

    VoxgigStation::BLOCK_DEFAULTS.each do |k, mk|
      v = mk.call
      next if v.is_a?(Hash) || v.is_a?(Array)

      assert_includes VoxgigStation::MERGE_SENSITIVE, k
    end
  end

  def test_normalize_config_never_mutates_the_input
    raw = { 'station' => 1,
            'profiles' => { 'default' => { 'sdk' => { 'solar' => {} } } } }
    before = JSON.generate(raw)

    out = VoxgigStation.normalize_config(raw)

    assert_equal before, JSON.generate(raw)
    refute_same raw, out
    assert_equal true, out['profiles']['default']['sdk']['solar']['active']
    assert_equal({ 'providers' => [{ 'kind' => 'env' }] },
      out['profiles']['default']['secrets'])
  end

  # A node that is not the kind it expects is LEFT ALONE for validate to
  # reject with a message that names the path.
  def test_normalize_config_returns_non_map_input_untouched
    assert_equal 7, VoxgigStation.normalize_config(7)
    assert_nil VoxgigStation.normalize_config(nil)
    assert_equal [], VoxgigStation.normalize_config([])
  end

  def test_open_fails_on_a_malformed_config_with_every_error_at_once
    err = assert_raises(VoxgigStation::StationError) do
      VoxgigStation::Station.new('config' => {
        'station' => 1,
        'profiles' => { 'default' => { 'sdk' => {
          'a' => { 'bass' => 1 }, 'b' => { 'tuba' => 2 },
        } } },
      })
    end
    assert_equal 'station_config_invalid', err.code
    assert_includes err.message, 'sdk.a: bass'
    assert_includes err.message, 'sdk.b: tuba'
  end

  def test_load_config_wraps_a_json_parse_failure
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'station.json'), '{ not json')
      err = assert_raises(VoxgigStation::StationError) do
        VoxgigStation.load_config(dir)
      end
      assert_equal 'station_config_invalid', err.code
      assert_includes err.message, 'is not valid JSON'
    end
  end

  # --- the factory table (design station.md 6.2) ---

  def test_provide_is_idempotent_for_one_pair_and_conflicts_on_another
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)

    assert_equal ['solar'], VoxgigStation.provided
    # NORMALIZED AT PROVIDE TIME, so check() can validate without
    # constructing anything.
    assert_equal 'solar', VoxgigStation.factory_for('solar')[:descriptor]['slug']

    err = assert_raises(VoxgigStation::StationError) do
      VoxgigStation::Station.provide('solar',
        'construct' => ->(o) { SolarSDK.new(o) }, 'config' => SOLAR_CONFIG)
    end
    assert_equal 'station_factory_conflict', err.code
  end

  def test_descriptor_carries_feature_options_and_transport
    d = VoxgigStation.normalize_descriptor(SOLAR_CONFIG, nil)[:descriptor]

    retryrow = d['features'].find { |f| 'retry' == f['name'] }
    assert_equal({ 'max' => 1, 'wait' => 100 }, retryrow['options'])

    testrow = d['features'].find { |f| 'test' == f['name'] }
    assert_equal 'base', testrow['transport']
    refute testrow.key?('options')
  end

  # --- the ref grammar (design station.md 6.1) ---

  def test_instance_name_and_tag_grammars
    assert VoxgigStation.check_instance_name('@acme/solar')
    refute VoxgigStation.check_instance_name('9solar')
    refute VoxgigStation.check_instance_name('')

    # The empty tag is an ordinary tag; a tag MAY start with a digit
    # (auto-tagging assigns integers) and admits neither `@` nor `/`.
    assert VoxgigStation.check_instance_tag('')
    assert VoxgigStation.check_instance_tag('1')
    refute VoxgigStation.check_instance_tag('a/b')
    refute VoxgigStation.check_instance_tag('a@b')
  end

  # --- the loader (design station.md 6.3) ---

  def test_check_package_rejects_anything_that_is_not_a_module_name
    ['', '.', './x', '/abs/x', '~/x', 'pkg/../../escape',
     'http://x/y', 'a\\b'].each do |bad|
      err = assert_raises(VoxgigStation::StationError) do
        VoxgigStation.check_package('solar', bad)
      end
      assert_equal 'station_sdk_load', err.code, 'accepted: ' + bad.inspect
    end

    assert_equal '@acme/solar-sdk',
      VoxgigStation.check_package('solar', '@acme/solar-sdk')
    assert_equal 'solar_sdk', VoxgigStation.check_package('solar', 'solar_sdk')
  end

  def test_camelify_is_the_second_attempt_export_name
    assert_equal 'StripeEu', VoxgigStation.camelify('stripe-eu')
    assert_equal 'VoxgigSolardemo', VoxgigStation.camelify('voxgig_solardemo')
  end

  def test_factory_from_module_reads_the_constructor_and_the_config
    factory = VoxgigStation.factory_from_module('solar', RetroPackage)
    assert_same SOLAR_CONFIG, factory[:config]
    client = factory[:construct].call('base' => 'http://x')
    assert_instance_of RetroPackage::SDK, client
    assert_equal 'http://x', client.options['base']
  end

  def test_factory_from_module_names_what_it_tried
    err = assert_raises(VoxgigStation::StationError) do
      VoxgigStation.factory_from_module('solar', CtorlessPackage)
    end
    assert_equal 'station_sdk_load', err.code
    assert_includes err.message, 'tried [SDK, SolarSDK]'

    err2 = assert_raises(VoxgigStation::StationError) do
      VoxgigStation.factory_from_module('solar', ConfiglessPackage)
    end
    assert_equal 'station_sdk_load', err2.code
    assert_includes err2.message, '`config` singleton'
  end

  # The whole loop: a config names a package, station requires it, the
  # package self-registers, and sdk() gets a client.
  def test_the_loader_requires_a_package_that_self_registers
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'fake_loadme_sdk.rb'), <<~RB)
        require 'voxgig_station'

        class LoadmeSDK
          attr_reader :options

          def initialize(options)
            @options = options
          end
        end

        VoxgigStation.provide('loadme',
          'construct' => ->(o) { LoadmeSDK.new(o) },
          'config' => { 'main' => { 'name' => 'Loadme', 'slug' => 'loadme',
                                    'version' => '0.1.0', 'target' => 'rb' } })
      RB

      $LOAD_PATH.unshift(dir)
      begin
        st = solar_station(
          'api' => { 'loadme' => { 'package' => 'fake_loadme_sdk' } },
          'sdk' => { 'loadme' => {} })

        client = st.sdk('loadme')
        assert_equal 'LoadmeSDK', client.class.name
        assert_includes VoxgigStation.provided, 'loadme'
      ensure
        $LOAD_PATH.delete(dir)
      end
    end
  end

  # `package` names CODE TO LOAD, and a user-level file sits outside the
  # repo's review boundary - so that one key is ignored with a warning
  # while everything else in the config still applies.
  def test_loader_package_is_ignored_outside_the_repo_boundary
    st = VoxgigStation::Station.new(
      'config' => { 'station' => 1,
                    'profiles' => { 'default' => { 'sdk' => { 'solar' => {} } } } },
      'repo_scoped' => false)

    assert_nil st.loader_package('solar', 'package' => 'solar_sdk')
    warns = st.events.select do |e|
      e.dig('meta', 'warn').to_s.include?('ignoring `package`')
    end
    assert_equal 1, warns.length
    assert_equal 'solar', warns[0]['api']
  end

  def test_load_false_disables_the_loader
    st = VoxgigStation::Station.new(
      'config' => { 'station' => 1,
                    'profiles' => { 'default' => { 'sdk' => { 'solar' => {} } } } },
      'load' => false)

    assert_nil st.loader_package('solar', 'package' => 'solar_sdk')
    assert_nil st.load
  end

  def test_config_scope_and_repo_scoped_precedence
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'station.json'), JSON.generate('station' => 1))
      assert_equal 'repo', VoxgigStation.config_scope(dir)
    end

    # An in-code config is repo-scoped by construction - the application
    # wrote it. EXPLICIT STILL WINS, which is the precedence bug this
    # pins: inferring first makes `repo_scoped: false` unsettable for any
    # caller passing a config in code.
    assert_equal true,
      VoxgigStation::Station.new('config' => { 'station' => 1 }).repo_scoped
    assert_equal false,
      VoxgigStation::Station.new('config' => { 'station' => 1 },
        'repo_scoped' => false).repo_scoped
  end

  # --- the declarative front door (design station.md 6) ---

  def test_sdk_constructs_once_and_caches
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => {} })

    a = st.sdk('solar')
    b = st.sdk('solar')

    assert_same a, b
    assert_equal '[station:solar]', a.options['apikey']
    assert_equal 1, st.plugins.length
    assert_equal 'solar', st.plugins[0]['name']
    assert_equal 'solar', st.plugins[0]['api']
    assert_equal 'solar.apikey', st.plugins[0]['secretname']
  end

  # create() is UNCACHED and registers under an auto-assigned integer
  # tag; the SECRET NAME follows the DECLARED instance the tag stands
  # for, so every per-request client shares one broker cache entry.
  def test_create_auto_tags_and_keeps_the_declared_secret_name
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => {} })

    one = st.create('solar')
    two = st.create('solar')

    refute_same one, two
    assert_equal ['solar$1', 'solar$2'], st.plugins.map { |p| p['name'] }.sort
    assert_equal '[station:solar$1]', one.options['apikey']
    st.plugins.each { |p| assert_equal 'solar.apikey', p['secretname'] }
    assert_equal 'solar', st.declared_ref('solar$1')
  end

  # THE REGISTRY ALONE IS NOT ENOUGH: declaration reserves a name
  # whether or not it has been built.
  def test_auto_tag_skips_a_declared_instance
    st = solar_station('sdk' => { 'solar' => {}, 'solar$1' => {} })
    assert_equal 'solar$2', st.auto_tag('solar')
  end

  def test_build_errors_name_the_remedies
    st = solar_station('sdk' => { 'solar' => {}, 'dark' => { 'active' => false } })

    e1 = assert_raises(VoxgigStation::StationError) { st.sdk('nope') }
    assert_equal 'station_no_instance', e1.code
    assert_includes e1.message, 'declared: [dark, solar]'

    e2 = assert_raises(VoxgigStation::StationError) { st.sdk('dark') }
    assert_equal 'station_instance_inactive', e2.code

    e3 = assert_raises(VoxgigStation::StationError) { st.sdk('solar') }
    assert_equal 'station_no_factory', e3.code
    assert_includes e3.message, 'Station.provide("solar", ...)'
    assert_includes e3.message, 'api.solar.package'
  end

  # 8.5 runs on EVERY path to a constructor, not only in check(): an
  # unknown option like `retry.retires` is accepted and silently ignored
  # by the SDK's own `$OPEN` feature spec, so nothing else looks.
  def test_a_feature_typo_fails_the_build
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station(
      'sdk' => { 'solar' => { 'feature' => { 'retry' => { 'retires' => 5 } } } })

    err = assert_raises(VoxgigStation::StationError) { st.sdk('solar') }
    assert_equal 'station_feature_option', err.code
    assert_includes err.message, 'declares no option "retires"'
    assert_includes err.message, '[max, wait]'
  end

  def test_an_unknown_feature_fails_the_build
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => { 'feature' => { 'bogus' => {} } } })

    err = assert_raises(VoxgigStation::StationError) { st.sdk('solar') }
    assert_equal 'station_feature_unknown', err.code
    assert_includes err.message, 'the SDK has no feature "bogus"'
  end

  def test_a_feature_option_of_the_wrong_kind_fails_the_build
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station(
      'sdk' => { 'solar' => { 'feature' => { 'retry' => { 'max' => 'lots' } } } })

    err = assert_raises(VoxgigStation::StationError) { st.sdk('solar') }
    assert_equal 'station_feature_option', err.code
    assert_includes err.message, 'expects number, but found string: "lots"'
  end

  # The composed feature map reaches the constructor in ORDER, with the
  # reserved keys stripped and station's own entry dropped (it is
  # composed after the user merge by options(), and always wins).
  def test_the_composed_feature_map_reaches_the_constructor
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => { 'feature' => {
      'debug' => { 'level' => 2 },
      'retry' => { 'max' => 3, 'order' => { 'before' => 'debug' } },
    } } })

    client = st.sdk('solar')
    fmap = client.options['feature']

    assert_equal ['retry', 'debug', 'station'], fmap.keys
    assert_equal({ 'active' => true, 'max' => 3 }, fmap['retry'])
    assert_equal true, fmap['station']['active']
  end

  # --- features_of and the fleet view (design station.md 8.7) ---

  def test_features_of_reports_the_merge_with_provenance
    st = solar_station(
      'feature' => { 'retry' => { 'max' => 1, 'wait' => 100 } },
      'api' => { 'solar' => { 'feature' => { 'retry' => { 'max' => 2 } } } },
      'sdk' => { 'solar$eu' => { 'feature' => {
        'retry' => { 'max' => 3 }, 'debug' => { 'level' => 2 },
      } } })

    view = st.features_of('solar$eu')

    assert_equal({ 'max' => 3, 'wait' => 100 }, view['merged']['retry'])
    assert_equal 'default.sdk', view['from']['retry']['max']
    assert_equal 'default.feature', view['from']['retry']['wait']
    # OUTERMOST FIRST, and the implicit station row is innermost.
    assert_equal ['retry', 'debug', 'station'], view['ordered']
  end

  # The overlay profile outranks the block level, one level down from
  # 3.3's rule.
  def test_features_of_lets_the_profile_outrank_the_block
    st = VoxgigStation::Station.new(
      'profile' => 'prod',
      'config' => { 'station' => 1, 'profiles' => {
        'default' => { 'sdk' => { 'solar' => {
          'feature' => { 'debug' => { 'level' => 3 } },
        } } },
        'prod' => { 'feature' => { 'debug' => { 'level' => 1 } } },
      } })

    view = st.features_of('solar')
    assert_equal({ 'level' => 1 }, view['merged']['debug'])
    assert_equal 'prod.feature', view['from']['debug']['level']
  end

  # Policy is ENFORCEMENT, not a default: it wins on exactly the keys it
  # sets, and other tuning keys survive beside it.
  def test_policy_budget_composes_the_ratelimit_feature
    st = solar_station('sdk' => { 'solar' => {
      'feature' => { 'ratelimit' => { 'rate' => 99 } },
      'policy' => { 'budget' => { 'rps' => 5, 'concurrency' => 2 } },
    } })

    view = st.features_of('solar')

    assert_equal({ 'rate' => 5, 'active' => true, 'burst' => 2 },
      view['merged']['ratelimit'])
    assert_equal 'policy.budget', view['from']['ratelimit']['rate']
    assert_equal 'policy.budget', view['from']['ratelimit']['burst']
    assert_includes view['ordered'], 'ratelimit'
  end

  def test_features_view_narrows_rows_and_contents_to_one_feature
    st = solar_station('sdk' => {
      'solar' => {},
      'solar$eu' => { 'feature' => { 'debug' => { 'level' => 2 } } },
    })

    rows = st.features('feature' => 'debug')

    assert_equal ['solar$eu'], rows.map { |r| r['instance'] }
    assert_equal({ 'debug' => { 'level' => 2 } }, rows[0]['merged'])
    assert_equal ['debug'], rows[0]['ordered']

    # The string form is the loose "this instance or this api" shorthand.
    assert_equal ['solar', 'solar$eu'],
      st.features('solar').map { |r| r['instance'] }
  end

  # --- instances, check, warm ---

  def test_instances_lists_every_declared_ref
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => {}, 'solar$off' => { 'active' => false } })

    rows = st.instances
    assert_equal ['solar', 'solar$off'], rows.map { |r| r['name'] }
    assert_equal [true, false], rows.map { |r| r['active'] }
    assert_equal [false, false], rows.map { |r| r['live'] }

    st.sdk('solar')
    assert_equal [true, false], st.instances.map { |r| r['live'] }
    assert_equal ['R1', 'none'], st.instances.map { |r| r['rung'] }
  end

  def test_check_turns_deferred_availability_errors_into_one_report
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => {
      'solar' => {}, 'ghost' => {}, 'solar$off' => { 'active' => false },
    })

    res = st.check

    assert_equal ['solar'], res['ok']
    assert_equal ['ghost'], res['failed'].map { |f| f['name'] }
    assert_equal 'station_no_factory', res['failed'][0]['code']
  end

  # check() validates the feature config WITHOUT constructing: the schema
  # arrives with the factory, not with a live client.
  def test_check_reports_a_feature_fault_without_constructing
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station(
      'sdk' => { 'solar' => { 'feature' => { 'retry' => { 'retires' => 5 } } } })

    res = st.check

    assert_equal [], res['ok']
    assert_equal 'station_feature_option', res['failed'][0]['code']
    assert_equal 0, st.plugins.length
  end

  def test_warm_resolves_declared_instances_and_misses_unknown_names
    ENV['SHARED_APIKEY'] = 'w-1'
    st = solar_station(
      'api' => { 'solar' => { 'secret' => 'shared.apikey' } },
      'sdk' => { 'solar' => {}, 'solar$eu' => {} })

    assert_equal({ 'warmed' => ['solar', 'solar$eu'], 'missed' => [] }, st.warm)

    # A NAME NOBODY DECLARED OR REGISTERED IS A MISS, never a lookup - a
    # wider fallback would derive a secret name from a typo and report a
    # nonexistent instance warmed off a shared credential.
    assert_equal({ 'warmed' => [], 'missed' => ['solar$typo'] },
      st.warm(['solar$typo']))
  end

  def test_warm_skips_inactive_instances_unless_named
    ENV['SOLAR_APIKEY'] = 'w-2'
    st = solar_station('sdk' => { 'solar' => {}, 'solar$off' => { 'active' => false } })

    assert_equal ['solar'], st.warm['warmed']
    # An explicit name is an explicit request.
    assert_equal ['solar$off'], st.warm(['solar$off'])['missed']
  end

  # The broker's resolution cache is keyed by SECRET NAME, so several
  # instances sharing one api-level `secret` cost one round-trip.
  def test_broker_cache_is_keyed_by_secret_name
    ENV['SHARED_APIKEY'] = 'v-1'
    broker = VoxgigStation::SecretBroker.new([{ 'kind' => 'env' }])
    assert_equal 'v-1', broker.value('solar', 'shared.apikey')

    ENV.delete('SHARED_APIKEY')
    assert_equal 'v-1', broker.value('solar$eu', 'shared.apikey')
  end

  # --- block_for, policy, options ---

  # An IMPERATIVE instance is named but never written into config, so
  # `profile.sdk` has no block for it - and without this rule the
  # api-level `secret`, `base` and `policy.hosts` never reach it.
  def test_block_for_gives_an_imperative_instance_its_api_block
    st = solar_station('api' => { 'solar' => {
      'policy' => { 'hosts' => ['api.solar.test'] },
    } })

    client = st.connect(SolarSDK, 'as' => 'test')
    refute_nil client

    assert_equal ['solar$test'], st.plugins.map { |p| p['name'] }
    assert_equal ['api.solar.test'], st.block_for('solar$test')['policy']['hosts']
  end

  def test_policy_allow_is_enforcement_and_reaches_the_sdk_options
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station(
      'api' => { 'solar' => { 'policy' => {
        'allow' => { 'op' => %w[find list], 'method' => ['GET'] },
      } } },
      'sdk' => { 'solar' => {} })

    client = st.sdk('solar')
    assert_equal({ 'op' => 'find,list', 'method' => 'GET' },
      client.options['allow'])
  end

  def test_options_takes_an_optional_leading_instance_name
    st = VoxgigStation::Station.new('config' => nil)

    plain = st.options('base' => 'http://x')
    assert_equal 'http://x', plain['base']
    assert_nil plain['feature']['station']['instance']

    named = st.options('solar$eu', 'base' => 'http://x')
    assert_equal 'solar$eu', named['feature']['station']['instance']
    assert_equal true, named['feature']['station']['active']
  end


  # THE IMPLICIT STATION ROW IS WHAT MAKES THE PIN REAL: `station` is
  # never in `merged` (feature.station is reserved at validation), so
  # without it check_pin finds no station row and is a permanent no-op -
  # `after: 'station'` would be treated as vacuous rather than rejected.
  def test_an_order_against_station_is_rejected_not_shrugged_at
    st = solar_station('sdk' => { 'solar' => {
      'feature' => { 'retry' => { 'order' => { 'after' => 'station' } } },
    } })

    err = assert_raises(VoxgigStation::StationError) { st.features_of('solar') }
    assert_equal 'station_feature_order', err.code
    assert_includes err.message, 'pinned innermost'
  end

  # 7.4/7.2: the descriptor describes the API rather than any use of it,
  # so every instance of one api shares ONE normalization - while the
  # placeholder and the derived secret name are per INSTANCE, or the
  # injection seam cannot tell which credential a header wants.
  def test_two_instances_of_one_api_share_a_descriptor_and_not_a_placeholder
    VoxgigStation::Station.provide('solar', SOLAR_FACTORY)
    st = solar_station('sdk' => { 'solar' => {}, 'solar$eu' => {} })

    a = st.sdk('solar')
    b = st.sdk('solar$eu')

    assert_same st.descriptor_of('solar'), st.descriptor_of('solar$eu')
    assert_equal '[station:solar]', a.options['apikey']
    assert_equal '[station:solar$eu]', b.options['apikey']
    assert_equal ['solar.apikey', 'solar_eu.apikey'],
      st.plugins.map { |p| p['secretname'] }
    # status() projects the instance AND the api: a page that showed only
    # `slug` would show two indistinguishable rows.
    assert_equal [%w[solar solar], ['solar$eu', 'solar']],
      st.status['plugins'].map { |p| [p['name'], p['api']] }
  end

end
