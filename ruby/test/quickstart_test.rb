# frozen_string_literal: true

# RUN: ruby test/quickstart_test.rb
#
# The (station.md 11) walkthroughs, run for real: the two-line quickstart
# against a live test API, injection at the transport seam,
# placeholder-safe options_map/prepare, and the event stream. The SDK is
# a REAL generated SDK (taskpad, built by sdkgen from an OpenAPI spec
# with the station feature installed) served by the taskpad test server -
# nothing here is mocked. Mirrors typescript/test/quickstart.test.ts and
# generated.test.ts.
#
# The integration suite runs against a generated rb SDK checkout; without
# one (STATION_TEST_RB_SDK, or the default locations below) it skips
# rather than fails.

require 'minitest/autorun'

require_relative 'helper'

SDK_ROOT = ENV.fetch('STATION_TEST_SDKS', '/home/user/voxgig-sdk')

SDK_DIR = [
  ENV.fetch('STATION_TEST_RB_SDK', nil),
  File.join(SDK_ROOT, 'taskpad-sdk', 'rb'),
  File.join(SDK_ROOT, 'st-rb-sdk', 'rb'),
].compact.find { |d| File.exist?(File.join(d, 'Taskpad_sdk.rb')) }

SERVER_JS = File.expand_path(File.join(HERE, '..', '..', 'test', 'api', 'taskpad', 'server.js'))

HAVE_SDK = !SDK_DIR.nil? && File.exist?(SERVER_JS)

APIKEY = 'taskpad-key-101'
# Own port: other suites may hold the SDK's default 8902.
PORT = 8932
BASE = 'http://localhost:' + PORT.to_s
PLACEHOLDER = '[station:taskpad]'

if HAVE_SDK
  $LOAD_PATH.unshift(SDK_DIR)
  require File.join(SDK_DIR, 'Taskpad_sdk')

  SERVER_PID = Process.spawn(
    { 'TASKPAD_APIKEY' => APIKEY, 'TASKPAD_PORT' => PORT.to_s },
    'node', SERVER_JS,
    out: File::NULL, err: File::NULL)
  Minitest.after_run do
    begin
      Process.kill('TERM', SERVER_PID)
      Process.wait(SERVER_PID)
    rescue StandardError
      nil
    end
  end

  # Wait for the server to accept connections.
  require 'net/http'
  40.times do
    begin
      Net::HTTP.get_response(URI(BASE + '/api/todo'))
      break
    rescue StandardError
      sleep(0.1)
    end
  end
end

class QuickstartRb < Minitest::Test
  def setup
    skip 'no generated rb SDK checkout (set STATION_TEST_RB_SDK)' unless HAVE_SDK
    VoxgigStation::Station.reset
    ENV.delete('TASKPAD_APIKEY')
  end

  def teardown
    VoxgigStation::Station.reset
    ENV.delete('TASKPAD_APIKEY')
  end

  def test_two_lines_secret_from_the_documented_env_var
    ENV['TASKPAD_APIKEY'] = APIKEY

    station = VoxgigStation::Station.open('config' => nil)
    pad = station.connect(TaskpadSDK, 'base' => BASE)

    result = pad.Todo.list
    assert_kind_of Array, result
    assert result.length.positive?

    # The op and http events correlate via corr (3, 6).
    events = station.events
    http = events.select { |e| 'http' == e['kind'] }
    op = events.select { |e| 'op' == e['kind'] }
    assert_equal 1, http.length
    assert_equal 1, op.length
    assert_equal http[0]['corr'], op[0]['corr']
    refute_nil http[0]['corr']
    assert_equal 200, http[0]['http']['status']
    assert_equal 'todo', op[0]['op']['entity']
    assert_equal 'list', op[0]['op']['op']
    assert_equal 'ok', op[0]['op']['outcome']

    station.close
  end

  def test_options_and_prepare_are_placeholder_safe_r1
    ENV['TASKPAD_APIKEY'] = APIKEY

    station = VoxgigStation::Station.open('config' => nil)
    pad = station.connect(TaskpadSDK, 'base' => BASE)

    # The key is out of app code's way: options_map never exposes the
    # value, prepare output is safe to hand to an agent (5.3, 11).
    assert_equal PLACEHOLDER, pad.options_map['apikey']

    fetchdef = pad.prepare('path' => '/api/todo', 'method' => 'GET')
    assert_includes fetchdef['headers'].to_s, PLACEHOLDER
    refute_includes fetchdef.to_s, APIKEY

    # And the wire still gets the real value.
    result = pad.Todo.list
    assert_kind_of Array, result

    # No credential anywhere in the event stream either.
    refute_includes JSON.generate(station.events), APIKEY

    station.close
  end

  def test_adopt_hoists_a_resident_credential
    station = VoxgigStation::Station.open('config' => nil)
    pad = station.adopt(TaskpadSDK, 'apikey' => APIKEY, 'base' => BASE)

    assert_equal PLACEHOLDER, pad.options_map['apikey']

    result = pad.Todo.list
    assert_kind_of Array, result

    warns = station.events.select do |e|
      'station' == e['kind'] && e.dig('meta', 'warn').to_s.include?('hoisted')
    end
    assert_equal 1, warns.length

    station.close
  end

  def test_missing_secret_is_station_secret_no_value_on_the_op_path
    station = VoxgigStation::Station.open('config' => nil)
    pad = station.connect(TaskpadSDK, 'base' => BASE)

    thrown = assert_raises(StandardError) { pad.Todo.list }
    assert_includes thrown.message, 'station_secret_no_value'

    errs = station.events.select { |e| 'error' == e['kind'] }
    assert_equal 1, errs.length
    assert_equal 'station_secret_no_value', errs[0]['err']['code']

    station.close
  end

  def test_descriptor_carries_slug_version_target_from_the_embedded_config
    ENV['TASKPAD_APIKEY'] = APIKEY

    station = VoxgigStation::Station.open('config' => nil)
    station.connect(TaskpadSDK, 'base' => BASE)

    d = station.descriptor_of('taskpad')
    assert_equal 'taskpad', d['slug']
    assert_equal 'TASKPAD', d['envtoken']
    assert_equal 'rb', d['target']
    assert_equal '0.0.1', d['version']
    assert_equal 'taskpad.apikey', d['auth']['secretname']
    assert_equal ['todo'], d['entities'].keys
    refute_nil d['entities']['todo']['ops']['list']

    # The canonical form serializes (proxy dedupe input).
    assert station.canonical_descriptor('taskpad').start_with?('{"auth":')

    station.close
  end

  def test_test_feature_stays_mocked_no_injection_into_mock_transports
    ENV['TASKPAD_APIKEY'] = APIKEY

    station = VoxgigStation::Station.open('config' => nil)
    pad = station.connect(TaskpadSDK,
      'feature' => { 'test' => { 'active' => true,
        'entity' => { 'todo' => { 't9' => { 'id' => 't9', 'title' => 'mock' } } } } })

    got = pad.Todo.load('id' => 't9').data_get
    assert_equal 'mock', got['title']

    # The http event saw the mock attempt; the placeholder was never
    # swapped (mode != live), so no real value entered the mock store.
    assert_equal 1, station.events.count { |e| 'http' == e['kind'] }
    refute_includes JSON.generate(station.events), APIKEY

    station.close
  end

  def test_inverted_binding_new_sdk_of_station_options
    ENV['TASKPAD_APIKEY'] = APIKEY

    st = VoxgigStation::Station.open('config' => nil)

    # The generated constructor, station-built options - the primary
    # binding form for static languages (3.1), exercised here so the
    # GENERATED feature (not the carried adapter) makes the binding.
    pad = TaskpadSDK.new(st.options('base' => BASE))

    assert_equal PLACEHOLDER, pad.options_map['apikey']

    result = pad.Todo.list
    assert_kind_of Array, result

    http = st.events.select { |e| 'http' == e['kind'] }
    op = st.events.select { |e| 'op' == e['kind'] }
    assert_equal 1, http.length
    assert_equal 1, op.length
    assert_equal http[0]['corr'], op[0]['corr']
    assert_equal 'ok', op[0]['op']['outcome']

    st.close
  end

  def test_connect_on_the_regenerated_sdk_does_not_double_bind
    ENV['TASKPAD_APIKEY'] = APIKEY

    st = VoxgigStation::Station.open('config' => nil)

    # connect() activates the station entry AND rides the carried
    # adapter on extend, so this construction reaches feature_binding
    # twice - generated feature first, carried adapter second. The
    # second arrival must be inert (_bound_entry), not an error.
    pad = st.connect(TaskpadSDK, 'base' => BASE)

    stations = pad.features.select { |f| 'station' == f.get_name }
    assert_equal 2, stations.length,
      'both the generated feature and the carried adapter are present'

    assert_equal 1, st.events.count { |e| 'construct' == e['kind'] }
    assert_equal 1, st.plugins.length

    result = pad.Todo.list
    assert_kind_of Array, result

    # One wrap, one hook bridge: no doubled events either.
    assert_equal 1, st.events.count { |e| 'http' == e['kind'] }
    assert_equal 1, st.events.count { |e| 'op' == e['kind'] }

    st.close
  end

  def test_live_tap_sees_traffic
    ENV['TASKPAD_APIKEY'] = APIKEY

    st = VoxgigStation::Station.open('config' => nil)
    pad = st.connect(TaskpadSDK, 'base' => BASE)

    seen = []
    unsub = st.tap(->(ev) { seen << ev['kind'] })
    pad.Todo.list
    unsub.call

    assert_includes seen, 'http'
    assert_includes seen, 'op'
    assert_equal 'solo', st.status['mode']
    assert_equal [{ 'slug' => 'taskpad', 'rung' => 'R1' }], st.status['plugins']

    st.close
  end
end
