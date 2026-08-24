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
require_relative 'factory'
require_relative 'feature'
require_relative 'loader'
require_relative 'profile'
require_relative 'secrets'
require_relative 'shape'

module VoxgigStation
  # The ref grammar is the JOINT identity model's (station-and-plugin.md
  # 2, plugin design 4): a NAME is a package-ish specifier
  # (`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`), a TAG is not
  # (`^[a-zA-Z0-9.~_-]+$` or empty - it MAY start with a digit because
  # auto-tagging assigns integer tags, and admits neither `@` nor `/`);
  # both cap at 1024; the split is on the FIRST `$`, so `a$b$c` is a good
  # name with a bad tag.
  REF_NAME_RE = %r{\A[a-zA-Z@][a-zA-Z0-9.~_\-/]*\z}.freeze
  REF_TAG_RE = /\A[a-zA-Z0-9.~_-]+\z/.freeze
  REF_MAX = 1024

  module_function

  def check_instance_name(name)
    return false unless name.is_a?(String)
    return false if name.empty? || REF_MAX < name.length

    REF_NAME_RE.match?(name)
  end

  def check_instance_tag(tag)
    return false unless tag.is_a?(String)
    # The empty tag is an ordinary tag: the single-instance case writes
    # no tag and never learns tags exist.
    return true if tag.empty?
    return false if REF_MAX < tag.length

    REF_TAG_RE.match?(tag)
  end

  # Validate a ref against the joint grammar and return its CANONICAL
  # spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
  # `stripe` are ONE registry key rather than two.
  def checkref(ref)
    cut = ref.index('$')
    name = cut.nil? ? ref : ref[0...cut]
    tag = cut.nil? ? '' : ref[(cut + 1)..]

    unless check_instance_name(name)
      raise StationError.new('station_instance_api',
        'invalid instance name "' + name.to_s + '" in ref "' + ref + '": a ' \
        'name starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, ' \
        'max 1024 (6.1)')
    end
    unless check_instance_tag(tag)
      raise StationError.new('station_instance_api',
        'invalid instance tag "' + tag.to_s + '" in ref "' + ref + '": a ' \
        'tag uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)')
    end

    '' == tag ? name : ref
  end

  def checkapi(api, ref)
    return ref if refapi(ref) == api

    raise StationError.new('station_instance_api',
      'instance "' + ref + '" names api "' + refapi(ref) + '", but the SDK ' \
      'passed is api "' + api.to_s + '"; `as` is a tag, not a free name (6.1)')
  end

  # design station.md 6.1: `as` IS A TAG, NOT A FREE NAME.
  #
  # The api comes from the SDK being passed, so the resulting ref is
  # `<api>$<tag>` and multi-instance works imperatively too. A full ref
  # is also accepted and is VALIDATED: its name must equal the SDK's api
  # slug, or it is station_instance_api.
  #
  # Both forms are needed because the imperative path is where the api is
  # implicit in an argument rather than written in a key. An `as` that
  # took an arbitrary name would reintroduce exactly the second-identity
  # problem the ref re-key removed.
  #
  # A bare connect(SDK) with no name falls back to the descriptor slug,
  # which is today's behaviour and why the single-instance case is
  # unchanged to the byte.
  def instance_ref(api, fopts)
    fopts = {} unless fopts.is_a?(Hash)

    explicit = fopts['instance']
    return checkref(checkapi(api, explicit)) if !explicit.nil? && '' != explicit

    as = fopts['as']
    # The bare fallback is the SLUG - a NAME, never a ref: a `$` in it is
    # an invalid name, not an implicit tag.
    if as.nil? || '' == as
      unless check_instance_name(api)
        raise StationError.new('station_instance_api',
          'invalid instance name "' + api.to_s + '": a name starts with a ' \
          'letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)')
      end
      return api
    end

    # A full ref is validated against the api; a `$`-less string is a TAG
    # and is joined to it.
    #
    # 6.1 gives both branches and does not say how to disambiguate a
    # `$`-less string, which is a real ambiguity because a bare name is
    # itself a valid (untagged) ref: `as: 'stripe'` on api `stripe` could
    # read as the untagged ref `stripe` or as tag `stripe`. It is read as
    # a TAG, giving `stripe$stripe`, because 6.1 says twice and
    # emphatically that `as` is a tag rather than a free name, and a rule
    # with no exceptions is the one that ports the same way twenty times.
    # Someone who wants the untagged instance passes no `as` at all.
    checkref(as.index('$').nil? ? api.to_s + '$' + as : checkapi(api, as))
  end

  class Station
    AMBIENT_MUTEX = Mutex.new
    @ambient = nil
    @ambient_opts = nil

    class << self
      # design station.md 6.2's second path, and the front door the docs
      # name. Delegates to the same process-global table the free
      # function fills; there is ONE registry, not two.
      def provide(api, factory)
        VoxgigStation.provide(api, factory)
        nil
      end

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

    attr_reader :repo_scoped, :raw

    def initialize(opts = nil)
      @opts = opts.is_a?(Hash) ? opts : {}

      config = if opt_key?('config')
                 opt('config')
               else
                 VoxgigStation.load_config(opt('folder'))
               end

      # design station.md 6.3. EXPLICIT WINS, then an in-code config (the
      # application wrote it, so it is repo-scoped by construction), then
      # where the file was found. Inferring BEFORE reading the explicit
      # option is a real precedence bug: it makes `repo_scoped: false`
      # unsettable for any caller passing a config in code, which is
      # every test of the rule.
      scoped = opt_first('repo_scoped', 'repoScoped')
      @repo_scoped = if !scoped.nil?
                       false != scoped
                     elsif opt_key?('config')
                       true
                     else
                       'user' != VoxgigStation.config_scope(opt('folder'))
                     end

      # Normalize, then validate (design station.md 4.2). A malformed
      # station.json fails open() with EVERY error at once - an
      # eighteen-instance config must not die because the eighteenth has
      # a typo'd package name.
      #
      # resolve_profile then reads the RAW config, NOT the normalized
      # one. The normalized form is an input to validation and to nothing
      # else: block defaults synthesized before the profile merge would
      # let a one-key overlay overwrite the base's `active: false` and
      # silently re-enable a barred integration (3.3, 4.2).
      VoxgigStation.validate_config(VoxgigStation.normalize_config(config)) unless config.nil?

      # The raw config, kept for 8.7's provenance: the resolved profile
      # has already collapsed the levels that provenance has to name.
      @raw = config
      @profile = VoxgigStation.resolve_profile(
        config, VoxgigStation.select_profile(opt('profile')))
      @broker = SecretBroker.new(@profile['providers'])
      @buffer = EventBuffer.new
      @registry = {}
      # design 6.1: sdk(name) caches; create() deliberately does not.
      @clients = {}
      # An auto-assigned tag to the DECLARED instance it stands for
      # (5.3). Kept beside the registry rather than inside it because the
      # mapping exists before construction, and block_for needs it during
      # registration.
      @alias_of = {}
      # 7.4: the shared per-api descriptor cache - see describe().
      @descriptor_cache = {}
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
    # activation entry; the profile's per-instance base is applied by the
    # adapter at init (caller opts still win).
    #
    # design 6.1: `options(instance_name?, extra?)`. The name is OPTIONAL
    # AND LEADING, so every existing `options({...})` call is unchanged -
    # the inverted binding is the static languages' path and they need to
    # say which instance they are building without a second method.
    def options(a = nil, b = nil)
      named = a.is_a?(String)
      instance = named ? a : nil
      extra = named ? b : a
      extra = extra.is_a?(Hash) ? extra : {}

      fmap = extra['feature'].is_a?(Hash) ? extra['feature'].dup : {}
      entry = (fmap['station'].is_a?(Hash) ? fmap['station'] : {})
        .merge('active' => true, 'station' => self, 'calleropts' => extra)
      entry['instance'] = instance unless instance.nil?
      fmap['station'] = entry

      extra.merge('feature' => fmap)
    end

    # --- registration (design station.md 3 item 1, called by the adapter) ---

    # The registry entry whose client IS this object, or nil. Used by
    # feature_binding for idempotency: connect/adopt activate the station
    # entry AND ride the carried adapter on extend, so on an SDK whose
    # generated features carry a real station feature class the same
    # construction reaches feature_binding twice - the second arrival
    # must no-op, while a genuinely second client of the same instance
    # still fails _register's key check (10.2).
    def _bound_entry(client)
      @registry_mutex.synchronize do
        @registry.each_value do |entry|
          return entry if entry[:client].equal?(client)
        end
      end
      nil
    end

    # The profile block that governs an instance - its own if the profile
    # declares it, otherwise its API'S.
    #
    # resolve_profile builds `profile.sdk` from the DECLARED refs alone
    # ("an api block declares no instance, so the ref set comes from the
    # two `sdk` maps"), shallow-merging `profile.api[a]` into each. That
    # is right for a declared instance and leaves an IMPERATIVE one -
    # connect(SDK, 'as' => 'test'), named but never written into config -
    # with no block at all. The api-level `secret`, `base` and most
    # seriously `policy.hosts` then did not reach it, so a profile that
    # denies egress everywhere denied nothing for a tagged client.
    #
    # ONE RULE, ONE PLACE: registration and the transport seam both ask
    # here, because them disagreeing is how the credential and the
    # allowlist came apart in the first place.
    def block_for(name)
      declared = @profile['sdk'][declared_ref(name)]
      return declared unless declared.nil?

      @profile['api'][VoxgigStation.refapi(name)]
    end

    # The DECLARED instance an assigned tag stands for, or the name
    # itself. create('stripe$prod') registers under `stripe$1`, and every
    # question about that client's configuration - its secret, its base,
    # its egress policy - is a question about `stripe$prod`.
    def declared_ref(name)
      @alias_of.fetch(name, name)
    end

    def _register(client, config, _options, _calleropts, fopts = nil)
      normalized = describe(config)
      descriptor = normalized[:descriptor]
      warnings = normalized[:warnings]
      api = descriptor['slug']

      fopts = fopts.is_a?(Hash) ? fopts : {}

      # 7.5: station knows the instance name before construction begins
      # and passes it through the feature options. A bare connect(SDK)
      # with no name falls back to the descriptor slug, which is today's
      # behaviour and why the single-instance case is unchanged.
      name = VoxgigStation.instance_ref(api, fopts)

      @registry_mutex.synchronize do
        # 7.1: the check moves to the INSTANCE key. Two clients of one
        # api is the NORMAL case now; two bindings of one instance is
        # still the error it was.
        if @registry.key?(name)
          raise StationError.new('station_bound_twice',
            'instance "' + name + '" is already registered; binding one ' \
            'client twice is an error (10.2)')
        end

        profile_plugin = block_for(name)

        # Secret name precedence: the feature option (in-code, design
        # station.md 9 config.options.secret) beats the profile, which
        # beats the INSTANCE-derived default.
        #
        # 5.1: secretname_default takes the INSTANCE name, not the api
        # slug. For an untagged instance the two are the same string, so
        # the single-instance case is unchanged to the byte. And the
        # default takes the DECLARED name, not the assigned tag, so every
        # per-request client of one instance shares one broker cache
        # entry (5.3).
        #
        # The descriptor's own `auth.secretname` stays the API-level
        # default and is NOT used here (7.4): one descriptor is shared by
        # every instance of an api and cannot hold two instance-derived
        # names.
        secretname = first_non_empty(fopts['secret'],
          profile_plugin.is_a?(Hash) ? profile_plugin['secret'] : nil) ||
          VoxgigStation.secretname_default(declared_ref(name))

        auth_active = true == descriptor['auth']['active']
        rung = auth_active ? 'R1' : 'none'
        binding = {
          'plugin' => name,
          'api' => api,
          # 7.2: two live instances of one api MUST have distinct
          # placeholders or the injection seam cannot tell which
          # credential a header wants.
          'placeholder' => auth_active ? VoxgigStation.placeholder_for(name) : nil,
          'secretname' => auth_active ? secretname : nil,
          'rung' => rung,
        }

        @registry[name] = {
          name: name, api: api, descriptor: descriptor, rung: rung,
          client: client, warnings: warnings,
          secretname: auth_active ? secretname : nil,
        }

        warnings.each do |w|
          emit('t' => now_ms, 'kind' => 'station', 'plugin' => name,
               'api' => api, 'meta' => { 'warn' => w })
        end
        emit('t' => now_ms, 'kind' => 'construct', 'plugin' => name,
             'api' => api,
             'meta' => {
               'name' => descriptor['name'],
               'version' => descriptor['version'],
               'rung' => rung,
             })

        { binding: binding, profile_plugin: profile_plugin }
      end
    end

    # 7.4: THE DESCRIPTOR IS SHARED, because it describes the api rather
    # than any use of it. normalize_descriptor runs once per api and
    # every instance of that api holds a reference to the same hash - at
    # 26 instances over 20 apis that is 20 normalizations, not 26, and
    # the canonical serialization the proxy dedupes registrations by is
    # computed once per api too.
    #
    # Normalized with NO per-instance features, so the shared value holds
    # only API-stable metadata - which is what factory.rb already does at
    # provide time. Per-instance activation is features_of(name)'s
    # answer; a cache keyed by slug but built from the first instance's
    # feature map would make descriptor_of() construction-order-dependent.
    def describe(config)
      slug = config.is_a?(Hash) && config['main'].is_a?(Hash) ?
        config['main']['slug'].to_s : ''
      unless '' == slug
        hit = @descriptor_cache[slug]
        return hit unless hit.nil?
      end

      out = VoxgigStation.normalize_descriptor(config, nil)
      @descriptor_cache[out[:descriptor]['slug']] = out
      out
    end

    def _hoist(name, value)
      @broker.hoist(name, value)
      emit('t' => now_ms, 'kind' => 'station', 'plugin' => name,
           'api' => VoxgigStation.refapi(name),
           'meta' => {
             'warn' => 'a resident credential was hoisted into the broker ' \
               'and replaced by the placeholder; prefer configuring the ' \
               'secret name and letting sekreto resolve it',
           })
    end

    # --- the transport middleware (design station.md 3.3, 5.3) ---
    #
    # Called by the adapter's wrap lambda; `inner` is the transport that
    # was current at init time. Returns the SDK's [response, err] tuple.
    def _transport(name, inner, fctx, fullurl, fetchdef)
      # Fail-closed means traffic (2.1): with the proxy deferred,
      # `require` can never attach, so every operation fails here - the
      # operation path, never the constructor.
      if @require_proxy
        err = StationError.new('station_no_proxy',
          'proxy: "require" is set and no proxy is attached')
        emit_err(name, fctx, err)
        return nil, err
      end

      entry = @registry_mutex.synchronize { @registry[name] }
      placeholder = VoxgigStation.placeholder_for(name)
      live = 'live' == fctx.client.mode
      profile_plugin = block_for(name)

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
            'egress to "' + hostname + '" denied by the hosts policy of ' \
            'plugin "' + name + '"')
          emit_err(name, fctx, err)
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
        # 7.4: THE EFFECTIVE NAME, resolved once at registration and
        # stored on the entry. Re-deriving it here gets the precedence
        # right and the FALLBACK wrong: `descriptor.auth.secretname` is
        # the API-level default and one descriptor is shared by every
        # instance of an api - so a tagged instance with no explicit
        # `secret` would read `stripe.apikey` where registration recorded
        # `stripe_test.apikey`. NO FALLBACK: this branch is guarded by
        # 'R1' == entry[:rung], the same condition under which
        # entry[:secretname] is populated.
        secretname = entry[:secretname]

        begin
          value = @broker.value(name, secretname)
        rescue StandardError => e
          emit_err(name, fctx, e)
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
        emit_http(name, corr, fullurl, senddef, 0, started, 0)
        emit_err(name, fctx, e)
        raise
      end

      unless err.nil?
        emit_http(name, corr, fullurl, senddef, 0, started, 0)
        emit_err(name, fctx, err)
        return res, err
      end

      status = res.is_a?(Hash) && res['status'].is_a?(Numeric) ? res['status'].to_i : 0

      if 0 == status
        # The rb base transport synthesizes a status-0 response (no err)
        # for network-level failures; map it to the same events the ts
        # library emits when its transport throws.
        emit_http(name, corr, fullurl, senddef, 0, started, 0)
        if res.is_a?(Hash)
          message = (res['statusText'] || 'transport failure').to_s
          emit('t' => now_ms, 'kind' => 'error', 'plugin' => name,
               'api' => VoxgigStation.refapi(name), 'corr' => corr,
               'err' => { 'message' => redact(message) })
        end
        return res, err
      end

      bytes = 0
      rheaders = res.is_a?(Hash) && res['headers'].is_a?(Hash) ? res['headers'] : {}
      cl = rheaders['content-length']
      bytes = cl.to_i unless cl.nil?
      emit_http(name, corr, fullurl, senddef, status, started, bytes)

      [res, err]
    end

    # Op events from the hook bridge (design station.md 3 item 3).
    def _op_event(name, ctx, outcome)
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

      emit('t' => now_ms, 'kind' => 'op', 'plugin' => name,
           'api' => VoxgigStation.refapi(name),
           'corr' => st['corr'],
           'op' => {
             'entity' => entity,
             'op' => opname,
             'outcome' => outcome,
             'durationMs' => st['start'].nil? ? 0 : now_ms - st['start'],
           })
    end

    # --- the declarative front door (design station.md 6) ---

    # The instance, constructed on first call and CACHED: same name ->
    # same object. That caching is what makes "get it where you need it"
    # a real instruction - call it in a request handler, in a worker, in
    # a test, and the first call pays construction while the rest are a
    # hash lookup.
    #
    # SYNCHRONOUS (6.3), which is what bounds the loader.
    def sdk(name)
      cached = @clients[name]
      return cached unless cached.nil?

      client = build(name, nil)
      @clients[name] = client
      client
    end

    # An UNCACHED client from the same resolved config plus overrides,
    # for the case that genuinely wants a distinct one - a per-request
    # credential scope, a test double. Deliberately the longer name.
    #
    # It registers under an AUTO-ASSIGNED TAG, because registration keys
    # every constructed adapter by instance name and station_bound_twice
    # fires on a second binding of one name: a second create('stripe')
    # would otherwise raise, which is exactly the per-request case this
    # exists for.
    def create(name, overrides = nil)
      build(name, auto_tag(name), overrides)
    end

    # The lowest positive integer tag not already taken, by a LIVE
    # instance or a DECLARED one.
    #
    # THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
    # and until something constructs it the registry says false - so
    # create('stripe$prod') would take that identity, instances() would
    # report the declared `stripe$1` as live with the wrong client, and a
    # later sdk('stripe$1') would fail station_bound_twice against a
    # binding that was never its own. Declaration reserves the name
    # whether or not it has been built.
    def auto_tag(name)
      api = VoxgigStation.refapi(name)
      n = 1
      loop do
        ref = api + '$' + n.to_s
        taken = @registry_mutex.synchronize { @registry.key?(ref) }
        return ref if !taken && @profile['sdk'][ref].nil?

        n += 1
      end
    end

    # The shared construction path behind sdk() and create().
    def build(name, as = nil, overrides = nil)
      raise StationError.new('station_no_plugin', 'station is closed') if @closed

      block = @profile['sdk'][name]
      if block.nil?
        raise StationError.new('station_no_instance',
          'no declared instance "' + name.to_s + '"; declared: [' +
          @profile['sdk'].keys.sort.join(', ') + ']')
      end
      if false == block['active']
        raise StationError.new('station_instance_inactive',
          'instance "' + name + '" is declared with `active: false`, which ' \
          'bars it from running while keeping it visible in instances()')
      end

      api = VoxgigStation.refapi(name)
      entry = resolve_factory(api, block)

      # 8.5 VALIDATES HERE, not only in check(). The schema arrives with
      # the factory, so the moment a factory is resolved is the first
      # moment validation is possible - and running it in check() alone
      # left two gaps: production sdk() silently ignored an unknown
      # option like `retry.retires`, and check() itself missed the case
      # where the factory is discovered by the LOADER (its pre-check sees
      # no registered factory, then sdk() loads and constructs
      # unvalidated). One call here closes both, because EVERY path to a
      # constructor comes through this line.
      resolved = features_of(name)
      faults = VoxgigStation.check_features(resolved['merged'], entry[:descriptor])
      unless faults.empty?
        raise StationError.new(faults[0]['code'],
          faults.map { |f| f['message'] }.join('; '))
      end

      # 8.4: compose the merged feature map into the ORDERED form and
      # hand it to the constructor. No new seam - it is the same
      # `options['feature']` map connect() already uses for station's own
      # placement, with more in it, and a Ruby hash preserves insertion
      # order so the order rides the map.
      #
      # Station's own entry is composed AFTER the user merge and always
      # wins (8.4), which is why `station` is dropped here and re-added
      # by options(): a config file that can switch off the component
      # reading it is not a surface, it is a trap. `feature.station` is
      # already station_feature_reserved at validation, so this is the
      # second half of one rule rather than a second rule.
      fmap = {}
      ordered = VoxgigStation.resolve_order(resolved['merged'])
        .reject { |o| 'station' == o['name'] }
      VoxgigStation.compose_features(ordered).each do |f|
        rest = f.dup
        fname = rest.delete('name')
        fmap[fname] = rest
      end

      opts = block['options'].is_a?(Hash) ? block['options'].dup : {}
      opts['base'] = block['base'] unless block['base'].nil?
      opts = opts.merge(overrides) if overrides.is_a?(Hash)
      over_feature = overrides.is_a?(Hash) && overrides['feature'].is_a?(Hash) ?
        overrides['feature'] : {}
      opts['feature'] = fmap.merge(over_feature)

      # 5.3: THE ALIAS IS RECORDED, NOT THE FIELDS. Carrying the declared
      # `secret` through the feature options and stopping there leaves
      # `policy`, `base` and everything else behind, so an auto-tagged
      # client silently loses its declared instance's HOSTS ALLOWLIST and
      # falls back to the wider api-level one. Recording what the tag
      # STANDS FOR is one rule that every lookup already goes through.
      #
      # Only when the tag was ASSIGNED - a caller naming its own is
      # naming an instance, not aliasing one.
      @alias_of[as] = name if !as.nil? && as != name

      # ...AND THE CARRIED ADAPTER RIDES `extend`, exactly as it does on
      # connect. The 3.1 retrofit case - an SDK generated before the
      # station feature, which factory_from_module explicitly supports -
      # has no generated feature to consume the `feature.station`
      # activation this path sets, so a declarative sdk() without this
      # either fails on an unknown feature or returns an unregistered,
      # unwrapped client with no credential injection and no events.
      #
      # Safe on a REGENERATED SDK too: the constructor uses its own
      # station feature and skips the extend copy by name, and both
      # delegate to feature_binding, whose _bound_entry check no-ops a
      # second arrival for the same client.
      extend_list = opts['extend'].is_a?(Array) ? opts['extend'] : []
      with_adapter = opts.merge(
        'extend' => extend_list + [VoxgigStation.adapter_feature(self, opts)])

      # The instance name reaches the adapter the same way it does on the
      # imperative path, so registration has one spelling (7.5).
      entry[:construct].call(options(as.nil? ? name : as, with_adapter))
    end

    # 6.2's three paths, in order of preference: self-registration,
    # Station.provide, then the loader.
    def resolve_factory(api, block)
      direct = VoxgigStation.factory_for(api)
      return direct unless direct.nil?

      pkg = loader_package(api, block)
      unless pkg.nil?
        VoxgigStation.load_sync(api, pkg, block.is_a?(Hash) ? block['export'] : nil)
        loaded = VoxgigStation.factory_for(api)
        return loaded unless loaded.nil?
      end

      raise StationError.new('station_no_factory',
        'no factory for api "' + api + '"; either link a generated package ' \
        'that self-registers, call Station.provide("' + api + '", ...), or ' \
        'set `api.' + api + '.package` so the loader can import it')
    end

    # `package` is honoured only from REPO-SCOPED config (6.3), and a
    # user-level one is IGNORED WITH A WARNING rather than required - it
    # names code to load and sits outside the repo's review boundary.
    def loader_package(api, block)
      pkg = block.is_a?(Hash) ? block['package'] : nil
      return nil if pkg.nil? || '' == pkg
      return nil if false == opt('load')

      unless @repo_scoped
        emit('t' => now_ms, 'kind' => 'station', 'plugin' => api, 'api' => api,
             'meta' => {
               'warn' => 'ignoring `package` for api "' + api + '": it came ' \
                 'from a user-level station.json, which is outside the ' \
                 "repo's review boundary; everything else in that config " \
                 'still applies',
             })
        return nil
      end

      pkg
    end

    # Preload every declared active instance's package into the factory
    # table.
    #
    # rb-specific: SYNCHRONOUS, and never required. ts/js need
    # `await station.load()` because an ESM-only package cannot be loaded
    # from a synchronous sdk(); rb has one module system, so sdk() loads
    # whatever load() would have. It is kept because loading the fleet at
    # startup - where a require error is ONE failure at a moment somebody
    # is watching - is worth having.
    def load
      return nil if false == opt('load')

      @profile['sdk'].keys.sort.each do |name|
        block = @profile['sdk'][name]
        next if false == block['active']

        api = VoxgigStation.refapi(name)
        next unless VoxgigStation.factory_for(api).nil?

        pkg = loader_package(api, block)
        next if pkg.nil?

        VoxgigStation.load_sync(api, pkg, block['export'])
      end
      nil
    end

    # The merged, ordered feature set for one instance, WITH PROVENANCE
    # (design station.md 8.7): which config level set each value.
    #
    # Provenance is the half that makes a fleet view usable rather than
    # merely correct - at 26 instances "why is retry off here" is the
    # question, and a merged map alone cannot answer it.
    def features_of(name)
      api = VoxgigStation.refapi(name)
      profiles = @raw.is_a?(Hash) && @raw['profiles'].is_a?(Hash) ? @raw['profiles'] : {}
      base = profiles['default'].is_a?(Hash) ? profiles['default'] : {}
      pname = @profile['name']
      overlay = 'default' == pname ? {} :
        (profiles[pname].is_a?(Hash) ? profiles[pname] : {})

      levels = [
        'default.feature', 'default.api', 'default.sdk',
        pname + '.feature', pname + '.api', pname + '.sdk',
      ]
      sources = VoxgigStation.feature_sources(base, overlay, api, name)

      # Last writer per (feature, key) wins, and the level that wrote it
      # is what `from` records.
      from = {}
      sources.each_with_index do |src, i|
        next unless src.is_a?(Hash)

        src.each do |fname, entry|
          next unless entry.is_a?(Hash)

          at = (from[fname] ||= {})
          entry.each_key { |k| at[k] = levels[i] }
        end
      end

      merged = VoxgigStation.merge_features(sources)

      # Policy budget (design station.md 16): rps/concurrency ceilings
      # ride "the SDK `ratelimit` feature, configured by station".
      # Composed HERE, into the merged map every consumer reads, rather
      # than patched in at construction alone - so build() orders it with
      # the ordinary constraint-and-band rules, check()'s 8.5 pass
      # validates it against the SDK's own declaration (a budget on an
      # SDK with no ratelimit feature is station_feature_unknown, not a
      # setting that quietly did nothing), and the 8.7 fleet view answers
      # "is ratelimit on?" truthfully.
      #
      # `rps` maps to the token bucket's refill `rate` (per second - the
      # same unit); `concurrency` to its capacity `burst`, the number of
      # requests that can be in flight from a full bucket. POLICY WINS
      # over a `feature.ratelimit` config entry on exactly the keys it
      # sets - it is enforcement, not a default - and other tuning keys
      # survive beside it.
      block = block_for(name)
      policy = block.is_a?(Hash) && block['policy'].is_a?(Hash) ? block['policy'] : {}
      budget = policy['budget']
      if budget.is_a?(Hash)
        prior = merged['ratelimit']
        entry = prior.is_a?(Hash) ? prior.dup : {}
        entry['active'] = true
        at = (from['ratelimit'] ||= {})
        at['active'] = 'policy.budget'
        unless budget['rps'].nil?
          entry['rate'] = budget['rps']
          at['rate'] = 'policy.budget'
        end
        unless budget['concurrency'].nil?
          entry['burst'] = budget['concurrency']
          at['burst'] = 'policy.budget'
        end
        merged = merged.merge('ratelimit' => entry)
      end

      # THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station` is
      # never in `merged` - `feature.station` is reserved and rejected at
      # validation (8.4) - so without it check_pin finds no station row
      # and is a PERMANENT NO-OP: a constraint like
      # `retry.order.after: 'station'` would be treated as vacuous rather
      # than rejected, and the reported order would omit the one feature
      # whose position is supposedly pinned.
      #
      # Added here rather than into `merged`, which stays the user's own
      # merge result.
      ordered = VoxgigStation.resolve_order(
        merged.merge('station' => { 'active' => true }))
      VoxgigStation.check_pin(ordered)

      {
        'ordered' => ordered.map { |o| o['name'] },
        'merged' => merged,
        'from' => from,
      }
    end

    # The fleet feature view: instance x feature, effective options, and
    # which config level set each (8.7).
    #
    # 8.7's documented shape is an OBJECT, and only the object form can
    # express the question the view exists for: `{'feature' => 'debug'}` -
    # "is debug on anywhere?", the one that is twenty greps today. The
    # string form is kept as shorthand for "this instance or this api",
    # because it is what the imperative path already uses and it costs
    # one line.
    def features(filter = nil)
      loose = filter.is_a?(String)
      f = if loose
            { 'instance' => filter, 'api' => filter }
          else
            filter.is_a?(Hash) ? filter : {}
          end

      rows = instances.select { |r|
        if loose
          f['instance'].nil? || r['name'] == f['instance'] || r['api'] == f['api']
        elsif !f['instance'].nil? && r['name'] != f['instance'] &&
              r['api'] != f['instance']
          false
        else
          f['api'].nil? || r['api'] == f['api']
        end
      }.map { |r|
        { 'instance' => r['name'], 'api' => r['api'] }.merge(features_of(r['name']))
      }

      # `feature` filters the ROWS, not the instances: an instance that
      # does not carry the named feature is not part of the answer, and
      # the rows that remain are NARROWED to it so the view answers
      # "where is debug on, and with what" rather than "here is
      # everything, go and look".
      want = filter.is_a?(Hash) ? filter['feature'] : nil
      return rows if want.nil?

      rows.select { |row| !row['merged'][want].nil? }.map do |row|
        {
          'instance' => row['instance'],
          'api' => row['api'],
          'ordered' => row['ordered'].select { |n| n == want },
          'merged' => { want => row['merged'][want] },
          'from' => { want => (row['from'][want] || {}) },
        }
      end
    end

    # Eagerly resolve and construct every ACTIVE declared instance - for
    # CI (6.6). The point is to turn availability errors, which are
    # deliberately deferred to first use, into ONE failure at a moment
    # somebody is watching.
    def check
      ok = []
      failed = []

      instances.each do |row|
        next unless row['active']

        begin
          # 8.5 runs FIRST and needs no construction: the schema arrives
          # with the factory, not with a live client, so a feature typo
          # is a CI failure rather than a setting that quietly did
          # nothing in production.
          entry = VoxgigStation.factory_for(row['api'])
          unless entry.nil?
            faults = VoxgigStation.check_features(
              features_of(row['name'])['merged'], entry[:descriptor])
            unless faults.empty?
              failed << {
                'name' => row['name'], 'code' => faults[0]['code'],
                'message' => faults.map { |f| f['message'] }.join('; '),
              }
              next
            end
          end

          sdk(row['name'])
          ok << row['name']
        rescue StandardError => e
          failed << {
            'name' => row['name'],
            'code' => (e.respond_to?(:code) ? e.code : nil),
            'message' => e.message.to_s,
          }
        end
      end

      { 'ok' => ok, 'failed' => failed }
    end

    # Batch-resolve secrets for ACTIVE instances (5.5).
    #
    # With no argument it warms the ACTIVE ones only, because reaching
    # for a credential belonging to a disabled integration is the wrong
    # default. warm(names) warms exactly what it is given, inactive
    # included, because an explicit name is an explicit request.
    def warm(names = nil)
      wanted = if names.nil?
                 instances.select { |r| r['active'] }.map { |r| r['name'] }
               else
                 names.to_a
               end

      plan = []
      warmed = []
      missed = []

      wanted.each do |name|
        # THE REGISTRY IS THE AUTHORITY: a registered instance already
        # carries the resolved name, in-code `secret` feature option
        # included (design 9). A NAME NOBODY DECLARED OR REGISTERED IS A
        # MISS, not a lookup - a wider fallback would let a typo like
        # `stripe$prodd` derive a secret name and call the provider, so a
        # nonexistent instance could be reported `warmed` off a shared
        # api-level credential. Registered OR declared, and nothing else.
        entry = @registry_mutex.synchronize { @registry[name] }
        if entry.nil? && @profile['sdk'][name].nil?
          missed << name
          next
        end

        secretname = entry.nil? ? nil : entry[:secretname]
        if secretname.nil?
          block = block_for(name)
          secretname = first_non_empty(block.is_a?(Hash) ? block['secret'] : nil) ||
            VoxgigStation.secretname_default(declared_ref(name))
        end
        plan << [name, secretname]
      end

      # ONE RESOLUTION PER DISTINCT SECRET NAME, and they are resolved
      # TOGETHER. Resolving inside the loop makes warm cost the SUM of
      # every provider round-trip, which defeats the one thing the method
      # exists for; and names are deduped first because the broker's
      # resolution cache is keyed by SECRET NAME (5.3), so firing
      # duplicates together would race past the cache and make several
      # round-trips of one.
      bysecret = {}
      plan.each { |name, secretname| (bysecret[secretname] ||= []) << name }

      threads = bysecret.map do |secretname, snames|
        Thread.new do
          begin
            @broker.value(snames[0], secretname)
            [snames, true]
          rescue StandardError
            [snames, false]
          end
        end
      end

      threads.map(&:value).each do |snames, resolved|
        (resolved ? warmed : missed).concat(snames)
      end

      { 'warmed' => warmed.sort, 'missed' => missed.sort }
    end

    # --- the query/observe surface (design station.md 3.2, 6) ---

    # Every DECLARED instance (6.1) - a different question from
    # plugins(), and the answers differ routinely: a lazily-started
    # instance is `active: true` and not yet live.
    def instances
      sdkmap = @profile['sdk']
      sdkmap.keys.sort.map do |name|
        entry = @registry_mutex.synchronize { @registry[name] }
        {
          'name' => name,
          'api' => VoxgigStation.refapi(name),
          # `active: false` means BARRED FROM RUNNING - a declaration
          # that stays in the file and here while being refused a client.
          'active' => false != sdkmap[name]['active'],
          'live' => !entry.nil?,
          'rung' => entry.nil? ? 'none' : entry[:rung],
          'block' => sdkmap[name],
        }
      end
    end

    # One entry per LIVE INSTANCE (6.1), and EXHAUSTIVE: auto-tagged
    # entries are NOT collapsed here, because inspection, health
    # reporting and cleanup all need to enumerate the clients create()
    # produced, which is exactly when you most want them. Truncation is a
    # presentation decision and belongs to status().
    def plugins
      @registry_mutex.synchronize do
        @registry.values.map do |e|
          {
            'name' => e[:name],
            'api' => e[:api],
            # Retained: it is the api, which is what `slug` always meant
            # here, and dropping it would break every consumer for no
            # gain while the two are equal for untagged instances.
            'slug' => e[:api],
            'descriptor' => e[:descriptor],
            'rung' => e[:rung],
            'secretname' => e[:secretname],
            'warnings' => e[:warnings].dup,
          }
        end
      end
    end

    # 7.4: accepts an INSTANCE name and returns its api's descriptor -
    # one hash shared by every instance of that api.
    def descriptor_of(name)
      entry = @registry_mutex.synchronize { @registry[name] }
      if entry.nil?
        known = @registry_mutex.synchronize { @registry.keys }
        raise StationError.new('station_no_plugin', 'unknown plugin "' +
          name.to_s + '"; known: [' + known.join(', ') + ']')
      end
      entry[:descriptor]
    end

    def canonical_descriptor(name)
      VoxgigStation.canonical_serialize(descriptor_of(name))
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
        # 7.1: the registry is keyed by INSTANCE, so a status page that
        # projects only `slug` shows two indistinguishable rows for
        # `stripe$test` and `stripe$live` and omits the names it is keyed
        # by - an operator cannot tell which one is unhealthy. `slug`
        # stays for compatibility; `name` and `api` are what answer the
        # question.
        'plugins' => plugins.map { |p|
          { 'name' => p['name'], 'api' => p['api'], 'slug' => p['slug'],
            'rung' => p['rung'] }
        },
        'events' => @buffer.status,
      }
    end

    def redact(text)
      @broker.scrub(text)
    end

    def refresh_secrets
      @broker.refresh
    end

    # close: flush (solo: nothing in flight), then warn on declared
    # instances that matched no registered client - a typo'd key silently
    # configuring nothing is the worst outcome for a secrets-and-policy
    # file (design station.md 11).
    def close
      return if @closed

      registered = @registry_mutex.synchronize { @registry.keys }
      @profile['sdk'].each_key do |name|
        next if registered.include?(name)

        emit('t' => now_ms, 'kind' => 'station',
             'meta' => {
               'warn' => 'profile plugin key "' + name +
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
      entry = (fmap['station'].is_a?(Hash) ? fmap['station'] : {})
        .merge('active' => true, 'station' => self, 'calleropts' => opts)
      # 6.1: `as` is a TAG, resolved against the api in _register - the
      # api comes from the SDK being passed and is not knowable here
      # until that SDK's config has been normalized.
      entry['as'] = opts['as'] unless opts['as'].nil?
      entry['instance'] = opts['instance'] unless opts['instance'].nil?
      fmap['station'] = entry

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

    def emit_http(name, corr, fullurl, fetchdef, status, started, bytes)
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
      emit('t' => started, 'kind' => 'http', 'plugin' => name,
           'api' => VoxgigStation.refapi(name), 'corr' => corr,
           'http' => {
             'method' => fetchdef.is_a?(Hash) && fetchdef['method'] ? fetchdef['method'] : 'GET',
             'host' => host, 'path' => path, 'status' => status,
             'durationMs' => now_ms - started, 'bytes' => bytes,
           })
    end

    def emit_err(name, fctx, err)
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
      # 7.3's grouping contract: `plugin` is the INSTANCE and `api` is
      # what groups its siblings. Construction events carrying both while
      # runtime events carried only one is grouping that works exactly
      # until it is used.
      emit('t' => now_ms, 'kind' => 'error', 'plugin' => name,
           'api' => VoxgigStation.refapi(name),
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

    # The first of several spellings of one option that is present, or
    # nil - construction options are string- or symbol-keyed, and a
    # camelCase key is spelled snake_case in rb.
    def opt_first(*keys)
      keys.each do |k|
        return opt(k) if opt_key?(k)
      end
      nil
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
