# frozen_string_literal: true

# RUN: ruby test/placement_test.rb
#
# A port of typescript/test/placement.test.ts, which is canonical.

require 'minitest/autorun'

require_relative 'helper'

# What an SDK generated without the station feature does when it is
# constructed: make_options' feature order, the constructor's loops,
# feature_add's anchors and feature_init, as sdkgen's rb templates write
# them. The rb factory answers a name it has no class for with an inert
# `base` feature. `statuses` scripts the wire, one status per attempt.
module PlacementSDK
  Op = Struct.new(:entity, :name)
  Result = Struct.new(:ok, :err)

  class Ctx
    attr_accessor :client, :utility, :options, :config, :op, :result, :entity

    def initialize(client, utility, options, config)
      @client = client
      @utility = utility
      @options = options
      @config = config
    end
  end

  class Utility
    attr_accessor :fetcher
  end

  class Feature
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def get_name
      @name
    end

    def init(ctx, _fopts)
      inner = ctx.utility.fetcher
      ctx.utility.fetcher =
        case @name
        when 'test' then ->(_c, _u, _d) { [{ 'status' => 200 }, nil] }
        when 'retry'
          lambda do |c, url, fdef|
            res, err = inner.call(c, url, fdef)
            2.times do
              break unless err.nil? && 503 == res['status']

              res, err = inner.call(c, url, fdef)
            end
            [res, err]
          end
        else ->(c, url, fdef) { inner.call(c, url, fdef) }
        end
    end
  end

  def self.featureorder(fmap)
    names = fmap.keys.select { |k| k.is_a?(String) }.sort
    names = ['test'] + names.reject { |n| 'test' == n } if names.include?('test')
    if names.include?('station')
      names.delete('station')
      ti = names.index('test')
      names.insert(ti.nil? ? 0 : ti + 1, 'station')
    end
    names
  end

  def self.feature_add(features, f)
    fopts = f.instance_variable_get(:@_options) || {}
    features.each_with_index do |ef, i|
      name = ef.respond_to?(:name) ? ef.name : nil
      if fopts['__before__'] == name
        features.insert(i, f)
        return
      elsif fopts['__after__'] == name
        features.insert(i + 1, f)
        return
      elsif fopts['__replace__'] == name
        features[i] = f
        return
      end
    end
    features << f
  end

  def self.build(slug, statuses)
    config = {
      'main' => { 'name' => slug, 'slug' => slug, 'version' => '1.0.0', 'target' => 'rb' },
      'feature' => { 'cache' => {}, 'retry' => {}, 'test' => {} },
      'options' => { 'base' => 'http://api.test', 'auth' => { 'prefix' => '' } },
      'entity' => {},
    }
    sent = []
    wire = lambda do |_c, url, _d|
      sent << url
      [{ 'status' => statuses[sent.length - 1] || 200 }, nil]
    end

    sdk = Class.new do
      attr_accessor :mode, :features, :options

      define_method(:initialize) do |options|
        @options = options
        fmap = options['feature'].is_a?(Hash) ? options['feature'] : {}
        @mode = fmap['test'].is_a?(Hash) && true == fmap['test']['active'] ? 'test' : 'live'
        @features = []
        @utility = Utility.new
        @utility.fetcher = wire
        @ctx = Ctx.new(self, @utility, options, config)

        PlacementSDK.featureorder(fmap).each do |fname|
          fopts = fmap[fname]
          next unless fopts.is_a?(Hash) && true == fopts['active']

          known = config['feature'].key?(fname)
          PlacementSDK.feature_add(@features, Feature.new(known ? fname : 'base'))
        end
        (options['extend'] || []).each do |f|
          PlacementSDK.feature_add(@features, f) if f.respond_to?(:get_name)
        end
        @features.each do |f|
          fopts = fmap[f.get_name]
          f.init(@ctx, fopts) if fopts.is_a?(Hash) && true == fopts['active']
        end
      end

      define_method(:list) do
        ctx = Ctx.new(self, @utility, @options, config)
        ctx.op = Op.new('todo', 'list')
        @features.each { |f| f.PrePoint(ctx) if f.respond_to?(:PrePoint) }
        res, err = @utility.fetcher.call(ctx, 'http://api.test/todo',
          { 'method' => 'GET', 'headers' => {} })
        ctx.result = Result.new(err.nil? && 200 == res['status'], err)
        @features.each { |f| f.PreDone(ctx) if f.respond_to?(:PreDone) }
        res
      end
    end

    { sdk: sdk, config: config, sent: sent }
  end
end

class PlacementTest < Minitest::Test
  def setup
    VoxgigStation::Station.reset
    VoxgigStation.reset_factories
    ENV['TASKPAD_APIKEY'] = 'taskpad-key'
  end

  def teardown
    VoxgigStation::Station.reset
    VoxgigStation.reset_factories
    ENV.delete('TASKPAD_APIKEY')
  end

  def names(client)
    client.features.map(&:get_name).reject { |n| 'base' == n }
  end

  def wire(station)
    station.events.select { |e| %w[http op].include?(e['kind']) }.map do |e|
      ['http' == e['kind'] ? 'http' : 'op',
       'http' == e['kind'] ? e['http']['status'] : e['op']['outcome']]
    end
  end

  def test_after_test_when_active_else_before_the_first_by_name
    anchor = ->(fmap) { VoxgigStation.adapter_anchor(fmap) }
    assert_equal({}, anchor.call(nil))
    assert_equal({}, anchor.call({}))
    assert_equal({}, anchor.call('station' => { 'active' => true }))
    assert_equal({ '__before__' => 'retry' }, anchor.call('retry' => { 'active' => true }))
    assert_equal({ '__before__' => 'cache' },
      anchor.call('retry' => { 'active' => true }, 'cache' => { 'active' => true }))
    assert_equal({ '__before__' => 'retry' },
      anchor.call('cache' => { 'active' => false }, 'retry' => { 'active' => true }))
    assert_equal({ '__before__' => 'timeout' },
      anchor.call('station' => { 'active' => true }, 'timeout' => { 'active' => true }))
    assert_equal({ '__after__' => 'test' },
      anchor.call('test' => { 'active' => true }, 'retry' => { 'active' => true }))
    assert_equal({ '__before__' => 'retry' },
      anchor.call('test' => { 'active' => false }, 'retry' => { 'active' => true }))
    # sdkgen's ordered array form: array order is init order.
    assert_equal({ '__before__' => 'retry' }, anchor.call([{ 'name' => 'retry', 'active' => true }]))
    assert_equal({ '__before__' => 'retry' },
      anchor.call([{ 'name' => 'retry', 'active' => true }, { 'name' => 'cache', 'active' => true }]))
    assert_equal({ '__after__' => 'test' },
      anchor.call([{ 'name' => 'retry', 'active' => true }, { 'name' => 'test', 'active' => true }]))
    assert_equal({}, anchor.call([{ 'name' => 'station', 'active' => true }, { 'name' => 'retry' }]))
  end

  def test_live_with_retry_station_is_the_base_wrap
    built = PlacementSDK.build('taskpad', [503, 200])
    st = VoxgigStation::Station.new('config' => nil)
    client = st.connect(built[:sdk], 'feature' => { 'retry' => { 'active' => true } })

    assert_equal %w[station retry], names(client)
    client.list

    assert_equal 2, built[:sent].length
    assert_equal [['http', 503], ['http', 200], %w[op ok]], wire(st)
    st.close
  end

  def test_live_with_two_features_before_the_first_by_name
    built = PlacementSDK.build('taskpad', [])
    st = VoxgigStation::Station.new('config' => nil)
    client = st.adopt(built[:sdk], 'feature' => {
      'retry' => { 'active' => true }, 'cache' => { 'active' => true } })
    assert_equal %w[station cache retry], names(client)
    st.close
  end

  def test_test_mode_station_sits_on_the_mock_transport
    built = PlacementSDK.build('taskpad', [])
    st = VoxgigStation::Station.new('config' => nil)
    client = st.connect(built[:sdk], 'feature' => {
      'test' => { 'active' => true }, 'retry' => { 'active' => true } })
    assert_equal %w[test station retry], names(client)
    st.close
  end

  def test_no_other_feature_station_alone
    built = PlacementSDK.build('taskpad', [])
    st = VoxgigStation::Station.new('config' => nil)
    assert_equal %w[station], names(st.connect(built[:sdk], {}))
    st.close
  end

  def test_the_declarative_path_places_it_the_same_way
    built = PlacementSDK.build('taskpad', [503, 200])
    VoxgigStation.provide('taskpad',
      'construct' => ->(o) { built[:sdk].new(o) }, 'config' => built[:config])
    st = VoxgigStation::Station.new('config' => {
      'station' => 1,
      'profiles' => { 'default' => { 'sdk' => {
        'taskpad' => { 'feature' => { 'retry' => {} } } } } },
    })
    client = st.sdk('taskpad')

    assert_equal %w[station retry], names(client)
    client.list
    assert_equal 2, built[:sent].length
    assert_equal [['http', 503], ['http', 200], %w[op ok]], wire(st)
    st.close
  end
end
