# frozen_string_literal: true

# The station side of the plugin contract (design station.md 3), in ONE
# place: VoxgigStation.feature_binding is what both entry paths delegate
# to -
#  - the GENERATED station feature (sdkgen-station's rb template) calls
#    it from its init and forwards its hook methods;
#  - the library's carried adapter (adapter_feature, the adopt/connect
#    retrofit for SDKs generated without the feature) is a thin shell
#    over the same call.
# Registration at init, wrap position verified, transport wrapped with
# copy-on-inject, hooks bridged to op events. Anything changed here
# changes both paths - which is the point.
#
# A port of typescript/src/adapter.ts, which is canonical.

require_relative 'error'
require_relative 'station'

module VoxgigStation
  CORR_MUTEX = Mutex.new
  @corr_seq = 0

  def self.next_corr
    CORR_MUTEX.synchronize { @corr_seq += 1 }
  end

  # The hook bridge handed back to the feature (design station.md 3 item
  # 3): operation semantics correlated with the HTTP events via a
  # per-operation id stashed on the SDK's own ctx (an instance variable,
  # the generated Ruby features' per-op idiom).
  class FeatureBinding
    attr_reader :slug

    def initialize(station, slug)
      @station = station
      @slug = slug
    end

    def PrePoint(ctx)
      ctx.instance_variable_set(:@_station,
        'corr' => 'c' + VoxgigStation.next_corr.to_s,
        'start' => (Time.now.to_f * 1000).to_i)
    end

    def PreDone(ctx)
      @station._op_event(@slug, ctx, VoxgigStation.result_outcome(ctx))
    end

    def PreUnexpected(ctx)
      @station._op_event(@slug, ctx, 'unexpected')
    end
  end

  module_function

  # Resolve the station this activation binds to: an explicit handle in
  # the feature options (connect/adopt and st.options pass one), else the
  # ambient instance. No station open -> nil: an activated feature with
  # no opened station is an inert no-op that emits nothing and fails
  # nothing (design station.md 3.1).
  def feature_binding(ctx, fopts)
    fopts = {} unless fopts.is_a?(Hash)
    station = fopts['station'].is_a?(Station) ? fopts['station'] : Station.current
    return nil if station.nil?

    client = ctx.client

    # Same construction, second arrival (generated feature + carried
    # adapter both active on one client): the first bind won, this one
    # is inert. See Station#_bound_entry.
    return nil unless station._bound_entry(client).nil?

    utility = ctx.utility
    options = ctx.options
    calleropts = fopts['calleropts']

    # Position guard (design station.md 3.3): the wrap must sit
    # immediately outside the base transport - inside retry/cache/
    # ratelimit - or its http events stop being wire truth. Position in
    # client.features IS init order, so verify it and fail loudly.
    #
    # One rb-specific tolerance: the generated feature factory FALLS
    # BACK to an inert base feature for unknown names, so an activated
    # station entry on a pre-station SDK appends a stray named "base"
    # (the ts constructor skips such names instead). A base feature has
    # a no-op init - it can never wrap or record the transport - so
    # strays are excluded from the order check, which keeps the guard's
    # actual meaning: nothing that could wrap sits between the base
    # transport and station.
    names = client.features.map do |f|
      if f.respond_to?(:get_name)
        f.get_name
      elsif f.respond_to?(:name)
        f.name
      end
    end
    order = names.reject { |n| 'base' == n }
    self_at = order.index('station')
    test_at = order.index('test')
    expected = test_at.nil? ? 0 : test_at + 1
    if self_at != expected
      raise StationError.new('station_wrap_order',
        'station must init immediately after the base transport; ' +
        'feature order is [' + names.map(&:to_s).join(', ') + ']')
    end

    reg = station._register(client, ctx.config, options, calleropts, fopts)
    binding = reg[:binding]
    profile_plugin = reg[:profile_plugin]
    slug = binding['plugin']

    # Base URL precedence (design station.md 3.5): caller opts (7) beat
    # the profile (4), which beats the SDK's config default (1) already
    # in options["base"]. calleropts is knowable on every binding form
    # (connect/adopt and st.options both pass it).
    if calleropts.is_a?(Hash) && calleropts['base'].nil? &&
       profile_plugin.is_a?(Hash) && !profile_plugin['base'].nil?
      options['base'] = profile_plugin['base']
    end

    if 'none' != binding['rung']
      placeholder = binding['placeholder']

      # A real credential already resident in the options is hoisted
      # into the broker and replaced by the placeholder before
      # construction completes (design station.md 3.1 adopt) -
      # options_map and prepare output become placeholder-safe from
      # here on.
      resident = options['apikey']
      if resident.is_a?(String) && '' != resident && placeholder != resident
        station._hoist(slug, resident)
      end
      options['apikey'] = placeholder
    end

    # Wrap the transport. Copy-on-inject (design station.md 5.3) happens
    # inside Station#_transport; auth-inactive plugins skip credential
    # planning but the wrap still observes. Ruby utilities are lambdas,
    # so the wrap marker (ts's __station__ property) rides an instance
    # variable on the Proc.
    inner = utility.fetcher
    if true == inner.instance_variable_get(:@__station__)
      raise StationError.new('station_bound_twice',
        'plugin "' + slug + '" already carries a station wrap')
    end
    wrapped = lambda do |fctx, fullurl, fetchdef|
      station._transport(slug, inner, fctx, fullurl, fetchdef)
    end
    wrapped.instance_variable_set(:@__station__, true)
    utility.fetcher = wrapped

    FeatureBinding.new(station, slug)
  end

  # The carried adapter: the retrofit path for SDKs generated without
  # the station feature (design station.md 3.1 adopt). A duck-typed
  # feature whose init/hooks delegate to feature_binding - it exists so
  # connect/adopt work on any regenerated SDK, and it must stay
  # behaviorally identical to the generated feature template in
  # sdkgen-station.
  class AdapterFeature
    attr_accessor :version, :name, :active, :_options

    def initialize(station, calleropts)
      @version = '0.0.1'
      @name = 'station'
      @active = true
      @station = station
      @calleropts = calleropts
      @_binding = nil
      # feature_add reads _options for positioning: immediately after
      # the test feature's base transport (design station.md 3.3). When
      # test is absent from the add order this is a no-op append, which
      # for a bare SDK still lands the wrap immediately outside the base
      # transport.
      @_options = { '__after__' => 'test' }
    end

    def get_version
      @version
    end

    def get_name
      @name
    end

    def get_active
      @active
    end

    def init(ctx, fopts)
      fopts = fopts.is_a?(Hash) ? fopts.dup : {}
      fopts['station'] = @station
      fopts['calleropts'] = @calleropts
      @_binding = VoxgigStation.feature_binding(ctx, fopts)
    end

    def PrePoint(ctx)
      @_binding&.PrePoint(ctx)
    end

    def PreDone(ctx)
      @_binding&.PreDone(ctx)
    end

    def PreUnexpected(ctx)
      @_binding&.PreUnexpected(ctx)
    end
  end

  def adapter_feature(station, calleropts)
    AdapterFeature.new(station, calleropts)
  end

  def result_outcome(ctx)
    result = ctx.respond_to?(:result) ? ctx.result : nil
    return 'unknown' if result.nil?
    return 'err' unless result.err.nil?
    return 'err' if false == result.ok

    'ok'
  end
end
