# frozen_string_literal: true

# The station library core, solo mode (design D1): fully functional
# in-process with no other component running. The proxy (D2) is a
# deferred amplifier - `require` therefore fails on the operation path
# (design station.md 2.1/14), and `auto` degrades to solo with one
# warning event.
#
# A port of typescript/src/Station.ts, which is canonical. SDK-facing
# seams follow the generated Ruby SDKs' conventions: the transport is a
# lambda returning a [response, err] tuple; client mode is the public
# `mode` accessor; per-op state rides an instance variable on the SDK's
# own ctx object. One rb-specific mapping, pinned by the target notes:
# the base transport converts network-level failures into a synthesized
# status-0 response with NO err, so a status-0 response is treated as a
# transport failure (http event at status 0 plus an error event), the
# same observable outcome the ts library produces when its fetch throws.

require 'json'
require 'uri'

require_relative 'descriptor'
require_relative 'error'
require_relative 'events'
require_relative 'profile'
require_relative 'secrets'

module VoxgigStation
  class Station
    AMBIENT_MUTEX = Mutex.new
    @ambient = nil
    @ambient_opts = nil

    class << self
      # Ambient instance (design station.md 10.2): open() is the
      # idempotent process-wide singleton; a second open() with
      # conflicting options is an error; Station.new(opts) stays isolated
      # for tests and multi-tenant hosts. open() is non-blocking - solo
      # involves no network, and the deferred proxy probe must never
      # change that.
      def open(opts = nil)
        key = opts_key(opts)
        AMBIENT_MUTEX.synchronize do
          unless @ambient.nil?
            if key != @ambient_opts
              raise StationError.new('station_open_conflict',
                'Station.open() was already called with different options')
            end
            return @ambient
          end
          @ambient = Station.new(opts)
          @ambient_opts = key
          @ambient
        end
      end

      # The ambient instance, or nil - never creates one. The generated
      # station feature binds through this when no explicit handle rides
      # its options (design station.md 3.1: binding is never implicit;
      # only open() creates the ambient instance).
      def current
        @ambient
      end

      # Test seam: drop the ambient instance.
      def reset
        AMBIENT_MUTEX.synchronize do
          @ambient = nil
          @ambient_opts = nil
        end
      end

      def _reset_if(station)
        AMBIENT_MUTEX.synchronize do
          if @ambient.equal?(station)
            @ambient = nil
            @ambient_opts = nil
          end
        end
      end

      def opts_key(opts)
        JSON.generate(opts || {})
      rescue StandardError
        (opts || {}).inspect
      end
    end

    def initialize(opts = nil)
      @opts = opts.is_a?(Hash) ? opts : {}

      config = if opt_key?('config')
                 opt('config')
               else
                 VoxgigStation.load_config(opt('folder'))
               end

      @profile = VoxgigStation.resolve_profile(
        config, VoxgigStation.select_profile(opt('profile')))
      @broker = SecretBroker.new(@profile['providers'])
      @buffer = EventBuffer.new
      @registry = {}
      @secret_override = {}
      @registry_mutex = Mutex.new
      @closed = false

      proxy = opt('proxy') || 'auto'
      @require_proxy = 'require' == proxy

      return unless 'auto' == proxy

      # The probe is deferred with the proxy itself; absence degrades
      # to solo with a single warning event naming the cause (14).
      emit('t' => now_ms, 'kind' => 'station',
           'meta' => { 'warn' => 'proxy absent (not found); running solo' })
    end

    # --- binding forms (design station.md 3.1) ---

    # connect(SDK, opts): station constructs the SDK itself, activating
    # the adapter with 3.3 ordering (the generated make_options hoists a
    # map-form station entry to just after test).
    def connect(sdk_class, opts = nil)
      construct(sdk_class, opts)
    end

    # adopt(SDK, opts): the retrofit path - construction-time sugar, not
    # post-hoc attachment (3.1). In rb it is the same construction as
    # connect; a resident options apikey is hoisted by the adapter.
    def adopt(sdk_class, opts = nil)
      construct(sdk_class, opts)
    end

    # Inverted binding (design station.md 3.1): build the plain options
    # hash a generated constructor already accepts - the handle and the
    # activation entry; the profile's per-plugin base is applied by the
    # adapter at init (caller opts still win).
    def options(extra = nil)
      extra = extra.is_a?(Hash) ? extra : {}
      fmap = extra['feature'].is_a?(Hash) ? extra['feature'].dup : {}
      fmap['station'] = (fmap['station'].is_a?(Hash) ? fmap['station'] : {})
        .merge('active' => true, 'station' => self, 'calleropts' => extra)
      extra.merge('feature' => fmap)
    end

    # --- registration (design station.md 3 item 1, called by the adapter) ---

    # The registry entry whose client IS this object, or nil. Used by
    # feature_binding for idempotency: connect/adopt activate the station
    # entry AND ride the carried adapter on extend, so on an SDK whose
    # generated features carry a real station feature class the same
    # construction reaches feature_binding twice - the second arrival
    # must no-op, while a genuinely second client of the same SDK class
    # still fails _register's slug check (10.2).
    def _bound_entry(client)
      @registry_mutex.synchronize do
        @registry.each_value do |entry|
          return entry if entry[:client].equal?(client)
        end
      end
      nil
    end

    def _register(client, config, _options, _calleropts, fopts = nil)
      normalized = VoxgigStation.normalize_descriptor(
        config, _options.is_a?(Hash) ? _options['feature'] : nil)
      descriptor = normalized[:descriptor]
      warnings = normalized[:warnings]
      slug = descriptor['slug']

      fopts = fopts.is_a?(Hash) ? fopts : {}

      @registry_mutex.synchronize do
        if @registry.key?(slug)
          raise StationError.new('station_bound_twice',
            'plugin "' + slug + '" is already registered; binding one ' +
            'client twice is an error (10.2)')
        end

        profile_plugin = @profile['plugin'][slug]

        # Secret name precedence: the feature option (in-code, design
        # station.md 9 config.options.secret) beats the profile, which
        # beats the descriptor default.
        if !fopts['secret'].nil? && '' != fopts['secret']
          @secret_override[slug] = fopts['secret']
        end
        secretname = first_non_empty(fopts['secret'],
          profile_plugin.is_a?(Hash) ? profile_plugin['secret'] : nil) ||
          descriptor['auth']['secretname']

        auth_active = true == descriptor['auth']['active']
        rung = auth_active ? 'R1' : 'none'
        binding = {
          'plugin' => slug,
          'placeholder' => auth_active ? VoxgigStation.placeholder_for(slug) : nil,
          'secretname' => auth_active ? secretname : nil,
          'rung' => rung,
        }

        @registry[slug] = {
          slug: slug, descriptor: descriptor, rung: rung,
          client: client, warnings: warnings,
        }

        warnings.each do |w|
          emit('t' => now_ms, 'kind' => 'station', 'plugin' => slug,
               'meta' => { 'warn' => w })
        end
        emit('t' => now_ms, 'kind' => 'construct', 'plugin' => slug,
             'meta' => {
               'name' => descriptor['name'],
               'version' => descriptor['version'],
               'rung' => rung,
             })

        { binding: binding, profile_plugin: profile_plugin }
      end
    end

    def _hoist(slug, value)
      @broker.hoist(slug, value)
      emit('t' => now_ms, 'kind' => 'station', 'plugin' => slug,
           'meta' => {
             'warn' => 'a resident credential was hoisted into the broker ' +
               'and replaced by the placeholder; prefer configuring the ' +
               'secret name and letting sekreto resolve it',
           })
    end

    # --- the transport middleware (design station.md 3.3, 5.3) ---
    #
    # Called by the adapter's wrap lambda; `inner` is the transport that
    # was current at init time. Returns the SDK's [response, err] tuple.
    def _transport(slug, inner, fctx, fullurl, fetchdef)
      # Fail-closed means traffic (2.1): with the proxy deferred,
      # `require` can never attach, so every operation fails here - the
      # operation path, never the constructor.
      if @require_proxy
        err = StationError.new('station_no_proxy',
          'proxy: "require" is set and no proxy is attached')
        emit_err(slug, fctx, err)
        return nil, err
      end

      entry = @registry_mutex.synchronize { @registry[slug] }
      placeholder = VoxgigStation.placeholder_for(slug)
      live = 'live' == fctx.client.mode
      profile_plugin = @profile['plugin'][slug]

      # Egress policy (design station.md 16), solo half: the hosts
      # allowlist is enforced at the seam every request crosses. The
      # generated Ruby transport (Net::HTTP) never follows redirects, so
      # 8.2's manual-redirect rule - a 3xx rides back like any other
      # response, and a Location off the allowlist cannot pull an
      # automatic credentialed follow-up - holds by construction; no
      # per-request redirect override is needed here.
      hosts = profile_plugin.is_a?(Hash) &&
        profile_plugin['policy'].is_a?(Hash) ? profile_plugin['policy']['hosts'] : nil
      if hosts.is_a?(Array) && live
        hostname = begin
          URI.parse(fullurl).host.to_s
        rescue StandardError
          ''
        end
        unless hosts.include?(hostname)
          err = StationError.new('station_host_allow',
            'egress to "' + hostname + '" denied by the hosts policy of ' +
            'plugin "' + slug + '"')
          emit_err(slug, fctx, err)
          return nil, err
        end
      end

      senddef = fetchdef

      # Injection: at the last boundary, below every recording feature,
      # and never into mock transports (3.3) - in test/mock modes the
      # placeholder rides through untouched, so real credentials never
      # enter in-memory mock stores. Copy-on-inject: fetchdef["headers"]
      # IS spec.headers and ctrl.explain holds the fetchdef by reference,
      # so the headers hash is duplicated before the swap - the object
      # graph reachable from ctx/spec/ctrl keeps the placeholder, ever
      # (5.3).
      if live && !entry.nil? && 'R1' == entry[:rung]
        secretname = first_non_empty(@secret_override[slug],
          profile_plugin.is_a?(Hash) ? profile_plugin['secret'] : nil) ||
          entry[:descriptor]['auth']['secretname']

        begin
          value = @broker.value(slug, secretname)
        rescue StandardError => e
          emit_err(slug, fctx, e)
          return nil, e
        end

        headers = (senddef['headers'].is_a?(Hash) ? senddef['headers'] : {}).dup
        headers.each do |h, v|
          headers[h] = v.split(placeholder, -1).join(value) if v.is_a?(String) && v.include?(placeholder)
        end
        senddef = senddef.merge('headers' => headers)
      end

      st = fctx.instance_variable_get(:@_station)
      corr = st.is_a?(Hash) ? st['corr'] : nil
      started = now_ms

      begin
        res, err = inner.call(fctx, fullurl, senddef)
      rescue StandardError => e
        emit_http(slug, corr, fullurl, senddef, 0, started, 0)
        emit_err(slug, fctx, e)
        raise
      end

      unless err.nil?
        emit_http(slug, corr, fullurl, senddef, 0, started, 0)
        emit_err(slug, fctx, err)
        return res, err
      end

      status = res.is_a?(Hash) && res['status'].is_a?(Numeric) ? res['status'].to_i : 0

      if 0 == status
        # The rb base transport synthesizes a status-0 response (no err)
        # for network-level failures; map it to the same events the ts
        # library emits when its transport throws.
        emit_http(slug, corr, fullurl, senddef, 0, started, 0)
        if res.is_a?(Hash)
          message = (res['statusText'] || 'transport failure').to_s
          emit('t' => now_ms, 'kind' => 'error', 'plugin' => slug,
               'corr' => corr, 'err' => { 'message' => redact(message) })
        end
        return res, err
      end

      bytes = 0
      rheaders = res.is_a?(Hash) && res['headers'].is_a?(Hash) ? res['headers'] : {}
      cl = rheaders['content-length']
      bytes = cl.to_i unless cl.nil?
      emit_http(slug, corr, fullurl, senddef, status, started, bytes)

      [res, err]
    end

    # Op events from the hook bridge (design station.md 3 item 3).
    def _op_event(slug, ctx, outcome)
      st = ctx.instance_variable_get(:@_station)
      st = {} unless st.is_a?(Hash)

      # ctx.op is the SDK's resolved Operation: name + entity, with '_'
      # as the generated Ruby SDKs' absence sentinel.
      entity = ctx.respond_to?(:op) && !ctx.op.nil? ? ctx.op.entity.to_s : ''
      entity = '' if '_' == entity
      if '' == entity && ctx.respond_to?(:entity) &&
         !ctx.entity.nil? && ctx.entity.respond_to?(:get_name)
        entity = ctx.entity.get_name.to_s
      end
      opname = ctx.respond_to?(:op) && !ctx.op.nil? ? ctx.op.name.to_s : ''
      opname = '' if '_' == opname

      emit('t' => now_ms, 'kind' => 'op', 'plugin' => slug,
           'corr' => st['corr'],
           'op' => {
             'entity' => entity,
             'op' => opname,
             'outcome' => outcome,
             'durationMs' => st['start'].nil? ? 0 : now_ms - st['start'],
           })
    end

    # --- the query/observe surface (design station.md 3.2, 6) ---

    def plugins
      @registry_mutex.synchronize do
        @registry.values.map do |e|
          {
            'slug' => e[:slug],
            'descriptor' => e[:descriptor],
            'rung' => e[:rung],
            'warnings' => e[:warnings].dup,
          }
        end
      end
    end

    def descriptor_of(slug)
      entry = @registry_mutex.synchronize { @registry[slug] }
      if entry.nil?
        known = @registry_mutex.synchronize { @registry.keys }
        raise StationError.new('station_no_plugin', 'unknown plugin "' +
          slug.to_s + '"; known: [' + known.join(', ') + ']')
      end
      entry[:descriptor]
    end

    def canonical_descriptor(slug)
      VoxgigStation.canonical_serialize(descriptor_of(slug))
    end

    def events
      @buffer.events
    end

    def tap(fn = nil, &blk)
      @buffer.tap(fn, &blk)
    end

    def status
      {
        'mode' => 'solo',
        'profile' => @profile['name'],
        'plugins' => plugins.map { |p| { 'slug' => p['slug'], 'rung' => p['rung'] } },
        'events' => @buffer.status,
      }
    end

    def redact(text)
      @broker.scrub(text)
    end

    def refresh_secrets
      @broker.refresh
    end

    # close: flush (solo: nothing in flight), then warn on profile
    # plugin keys that matched no registered plugin - a typo'd key
    # silently configuring nothing is the worst outcome for a
    # secrets-and-policy file (design station.md 11).
    def close
      return if @closed

      registered = @registry_mutex.synchronize { @registry.keys }
      @profile['plugin'].each_key do |slug|
        next if registered.include?(slug)

        emit('t' => now_ms, 'kind' => 'station',
             'meta' => {
               'warn' => 'profile plugin key "' + slug +
                 '" matched no registered plugin',
             })
      end
      @closed = true
      Station._reset_if(self)
      nil
    end

    def closed?
      @closed
    end

    private

    def construct(sdk_class, opts)
      if @closed
        raise StationError.new('station_no_plugin', 'station is closed')
      end

      opts = opts.is_a?(Hash) ? opts : {}
      fmap = opts['feature'].is_a?(Hash) ? opts['feature'].dup : {}
      fmap['station'] = (fmap['station'].is_a?(Hash) ? fmap['station'] : {})
        .merge('active' => true, 'station' => self, 'calleropts' => opts)

      extend_list = opts['extend'].is_a?(Array) ? opts['extend'] : []

      # The carried adapter rides extend for SDKs generated WITHOUT the
      # station feature; when the generated class exists the constructor
      # uses it and the extend copy's bind is made inert by _bound_entry
      # (both delegate to feature_binding, so behavior is identical).
      options = opts.merge(
        'feature' => fmap,
        'extend' => extend_list + [VoxgigStation.adapter_feature(self, opts)])

      sdk_class.new(options)
    end

    def emit(ev)
      @buffer.emit(ev)
    end

    def emit_http(slug, corr, fullurl, fetchdef, status, started, bytes)
      host = ''
      path = ''
      begin
        u = URI.parse(fullurl)
        host = u.host.to_s
        # Mirror the ts URL.host: the port rides along unless it is the
        # scheme default.
        host = host + ':' + u.port.to_s if !u.port.nil? && u.port != u.default_port
        path = u.path.to_s
      rescue StandardError
        path = fullurl.to_s
      end
      emit('t' => started, 'kind' => 'http', 'plugin' => slug, 'corr' => corr,
           'http' => {
             'method' => fetchdef.is_a?(Hash) && fetchdef['method'] ? fetchdef['method'] : 'GET',
             'host' => host, 'path' => path, 'status' => status,
             'durationMs' => now_ms - started, 'bytes' => bytes,
           })
    end

    def emit_err(slug, fctx, err)
      st = fctx.respond_to?(:instance_variable_get) ?
        fctx.instance_variable_get(:@_station) : nil
      code = err.respond_to?(:code) ? err.code : nil
      code = nil unless code.is_a?(String) && '' != code
      ev_err = {
        # The scrub keeps an upstream echo of a credential out of the
        # event stream (design station.md 7 as revised: exact-value, no
        # length floor).
        'message' => redact(err.respond_to?(:message) ? err.message.to_s : err.to_s),
      }
      ev_err['code'] = code unless code.nil?
      emit('t' => now_ms, 'kind' => 'error', 'plugin' => slug,
           'corr' => st.is_a?(Hash) ? st['corr'] : nil,
           'err' => ev_err)
    end

    def opt(key)
      return @opts[key] if @opts.key?(key)

      @opts[key.to_sym]
    end

    def opt_key?(key)
      @opts.key?(key) || @opts.key?(key.to_sym)
    end

    def first_non_empty(*vals)
      vals.each do |v|
        return v if !v.nil? && '' != v
      end
      nil
    end

    def now_ms
      (Time.now.to_f * 1000).to_i
    end
  end
end
