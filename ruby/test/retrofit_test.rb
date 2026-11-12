# frozen_string_literal: true

# RUN: ruby test/retrofit_test.rb
#
# A port of typescript/test/retrofit.test.ts, which is canonical: an SDK
# generated without the station feature, as connect() and adopt()
# retrofit it, against a server whose first answer is a 503.

require 'minitest/autorun'

require_relative 'helper'

SDK_ROOT = ENV.fetch('STATION_TEST_SDKS', '/home/user/voxgig-sdk')
SDK_DIR = File.join(SDK_ROOT, 'taskpad-plain-sdk', 'rb')
SERVER_JS = File.expand_path(File.join(HERE, '..', '..', 'test', 'api', 'taskpad', 'server.js'))

HAVE_SDK = File.exist?(File.join(SDK_DIR, 'Taskpad_sdk.rb'))

APIKEY = 'taskpad-key-101'
PORT = 8943
BASE = 'http://localhost:' + PORT.to_s

if HAVE_SDK
  $LOAD_PATH.unshift(SDK_DIR)
  require File.join(SDK_DIR, 'Taskpad_sdk')

  SERVER_PID = Process.spawn(
    { 'TASKPAD_APIKEY' => APIKEY, 'TASKPAD_PORT' => PORT.to_s, 'TASKPAD_FAIL' => '1' },
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

class RetrofitRb < Minitest::Test
  def setup
    unless HAVE_SDK
      flunk 'STATION_REQUIRE_SDKS is set but there is no generated rb SDK - run `make fixtures`' if ENV['STATION_REQUIRE_SDKS']
      skip 'no generated rb SDK without the station feature'
    end
    VoxgigStation::Station.reset
    ENV['TASKPAD_APIKEY'] = APIKEY
  end

  def teardown
    VoxgigStation::Station.reset
    ENV.delete('TASKPAD_APIKEY')
  end

  def test_live_with_retry_station_wraps_the_wire_and_sees_each_attempt
    station = VoxgigStation::Station.open('config' => nil)
    pad = station.connect(TaskpadSDK,
      'base' => BASE, 'feature' => { 'retry' => { 'active' => true } })

    names = pad.features.map(&:get_name).reject { |n| 'base' == n }
    assert_equal %w[station retry], names

    todos = pad.Todo.list
    assert todos.length.positive?

    events = station.events.select { |e| %w[http op].include?(e['kind']) }
    assert_equal [['http', 503], ['http', 200], %w[op ok]],
      events.map { |e| [e['kind'], 'http' == e['kind'] ? e['http']['status'] : e['op']['outcome']] }
    assert_equal 1, events.map { |e| e['corr'] }.uniq.length

    station.close
  end
end
