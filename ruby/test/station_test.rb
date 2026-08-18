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

class TestStation < Minitest::Test
  def setup
    VoxgigStation::Station.reset
    ENV.delete('GNARLY_PETS_APIKEY')
    ENV.delete('VOXGIG_STATION_PROFILE')
  end

  def teardown
    VoxgigStation::Station.reset
    ENV.delete('GNARLY_PETS_APIKEY')
    ENV.delete('VOXGIG_STATION_PROFILE')
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
      'profiles' => { 'default' => { 'plugin' => { 'typo-slug' => { 'base' => 'http://x' } } } },
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
        'plugin' => { 'gnarly-pets' => { 'base' => 'http://profile:9' } },
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
      'profiles' => { 'default' => { 'plugin' => {
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
end
