# frozen_string_literal: true

# RUN: ruby test/exposure_test.rb
#
# A port of typescript/test/exposure.test.ts, which is canonical.

require 'json'
require 'pp'

require 'minitest/autorun'

require_relative 'helper'

module ExposureSDK
  SECRET = 'exposure-key-101'

  CONFIG = {
    'main' => { 'name' => 'taskpad', 'slug' => 'taskpad', 'version' => '1.0.0', 'target' => 'rb' },
    'options' => { 'base' => 'http://api.test', 'auth' => { 'prefix' => '' } },
    'entity' => {},
  }.freeze

  class Ctx
    attr_accessor :client, :utility, :options, :config, :op, :result, :entity

    def initialize(client, utility, options)
      @client = client
      @utility = utility
      @options = options
      @config = CONFIG
    end
  end

  class Utility
    attr_accessor :fetcher
  end

  # An SDK generated without the station feature, reduced to what the
  # carried adapter touches: the options kept as given, extend features
  # initialised in order, and a transport that answers 200.
  class SDK
    attr_accessor :mode, :features, :options

    def initialize(options)
      @options = options
      @mode = 'live'
      @features = []
      @utility = Utility.new
      @utility.fetcher = ->(_c, _u, _d) { [{ 'status' => 200, 'headers' => {} }, nil] }
      @ctx = Ctx.new(self, @utility, options)
      (options['extend'] || []).each do |f|
        @features << f
        f.init(@ctx, (options['feature'] || {})[f.get_name] || {})
      end
    end

    def call
      @utility.fetcher.call(@ctx, 'http://api.test/todo',
        { 'method' => 'GET', 'headers' => { 'authorization' => @options['apikey'] } })
    end
  end
end

class ExposureTest < Minitest::Test
  SECRET = ExposureSDK::SECRET

  def setup
    VoxgigStation::Station.reset
    ENV['TASKPAD_APIKEY'] = SECRET
  end

  def teardown
    VoxgigStation::Station.reset
    ENV.delete('TASKPAD_APIKEY')
  end

  def shows(value)
    value.inspect + PP.pp(value, +'') + JSON.generate(value)
  end

  def reaches_station(value, seen = {})
    return true if value.is_a?(VoxgigStation::Station)
    return false if seen[value.object_id]

    seen[value.object_id] = true
    case value
    when Hash then value.values.any? { |v| reaches_station(v, seen) }
    when Array then value.any? { |v| reaches_station(v, seen) }
    else false
    end
  end

  def test_a_bound_clients_options_hold_no_secret_after_a_live_request
    st = VoxgigStation::Station.open('config' => nil)
    client = st.connect(ExposureSDK::SDK, {})
    res, err = client.call
    assert_nil err
    assert_equal 200, res['status']

    refute_includes shows(client.options), SECRET
    refute_includes st.inspect + PP.pp(st, +''), SECRET
    refute reaches_station(client.options['feature']), 'the options reach no Station'
    st.close
  end

  def test_the_callers_own_key_does_not_ride_the_activation_entry
    ENV.delete('TASKPAD_APIKEY')
    st = VoxgigStation::Station.open('config' => nil)
    client = st.adopt(ExposureSDK::SDK, 'apikey' => SECRET)
    client.call

    refute_includes client.options.inspect, SECRET
    refute_includes st.inspect, SECRET
    st.close
  end

  def test_inverted_binding_the_activation_entry_holds_neither
    st = VoxgigStation::Station.open('config' => nil)
    options = st.options('apikey' => SECRET)

    assert_equal SECRET, options['apikey'], 'the SDK still gets the key it is given'
    refute_includes options['feature']['station'].inspect, SECRET
    refute reaches_station(options), 'the options reach no Station'
    st.close
  end
end
