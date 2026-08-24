# frozen_string_literal: true

# station.json lookup and profile resolution (design station.md 3.5).
#
# A port of typescript/src/profile.ts, which is canonical.

require 'json'

require 'voxgig_sekreto'

require_relative 'error'
require_relative 'descriptor'
require_relative 'shape'

module VoxgigStation
  module_function

  # station.json lookup: cwd upward to the repo root, then
  # ~/.voxgig/station.json (design station.md 3.5). A repo root is where
  # .git lives; with no repo the walk stops at the filesystem root.
  def find_config_file(from = nil)
    dir = File.expand_path(from || Dir.pwd)
    loop do
      candidate = File.join(dir, 'station.json')
      return candidate if File.exist?(candidate)

      at_repo_root = File.exist?(File.join(dir, '.git'))
      parent = File.dirname(dir)
      break if at_repo_root || parent == dir

      dir = parent
    end
    home = File.join(Dir.home, '.voxgig', 'station.json')
    File.exist?(home) ? home : nil
  end

  def load_config(from = nil)
    file = find_config_file(from)
    return nil if file.nil?

    begin
      JSON.parse(File.read(file))
    rescue JSON::ParserError => e
      # A file that is not JSON is a CONFIG error, not a raw parse error
      # escaping open(): the reader found station.json and could not use
      # it, which is exactly what station_config_invalid exists to say.
      raise StationError.new('station_config_invalid',
        'station.json at ' + file + ' is not valid JSON: ' + e.message.to_s)
    end
  end

  # Which side of the review boundary the config came from
  # (design station.md 6.3).
  #
  # `package` and `export` are honoured only from REPO-SCOPED config,
  # because a user-level file is outside the repo's review boundary and a
  # `package` key arriving from it names code to require. Everything else
  # in a user-level config still applies - this narrows one key rather
  # than distrusting the file.
  def config_scope(from = nil)
    file = find_config_file(from)
    return 'none' if file.nil?

    home = File.join(Dir.home, '.voxgig', 'station.json')
    file == home ? 'user' : 'repo'
  end

  # Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
  # else 'default' (design station.md 3.5 - env vars rank above
  # station.json but below open() opts; profile NAME selection follows
  # the same order with open() opts winning).
  def select_profile(opt_profile = nil)
    return opt_profile if !opt_profile.nil? && '' != opt_profile

    env = ENV.fetch('VOXGIG_STATION_PROFILE', nil)
    return env if !env.nil? && '' != env

    'default'
  end

  # The api half of a ref is the substring before the first `$`, and an
  # untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
  # point: under the old free-form identity which api an instance used
  # was itself a merged value, so a port that got the phasing wrong
  # silently picked another api's defaults.
  def refapi(ref)
    ref = ref.to_s
    at = ref.index('$')
    at.nil? ? ref : ref[0...at]
  end

  # Shallow merge, per key, left to right - each source over the one
  # before it. An overlay's `policy` REPLACES the base's entirely rather
  # than merging `hosts` into it; an allowlist that widens because two
  # precedence levels merged is the failure this rule prevents.
  def shallow(*sources)
    out = {}
    sources.each do |src|
      out.merge!(src) if src.is_a?(Hash)
    end
    out
  end

  def sortedkeys(*maps)
    keys = []
    maps.each do |m|
      keys.concat(m.keys) if m.is_a?(Hash)
    end
    keys.uniq.sort
  end

  # Merge the base profile ('default') with the selected overlay.
  #
  # Design 3.3's total order for the two block levels, lowest first:
  #
  #   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
  #
  # PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
  # LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
  # namespace, then put instance over api" - that lets every instance
  # value beat every api value, so a production `api.stripe.policy` would
  # fail to override a default profile's `sdk.stripe$test.policy`,
  # silently keeping the wider allowlist in production.
  #
  # `secrets.providers` replaces wholesale, never merges (3.5, 5.2).
  def resolve_profile(config, profile_name)
    profiles = config.is_a?(Hash) && config['profiles'].is_a?(Hash) ? config['profiles'] : {}
    base = profiles['default'].is_a?(Hash) ? profiles['default'] : {}
    overlay = 'default' == profile_name ? {} : (profiles[profile_name].is_a?(Hash) ? profiles[profile_name] : {})

    providers = providers_of(overlay) || providers_of(base) || [{ 'kind' => 'env' }]

    base_api = base['api'].is_a?(Hash) ? base['api'] : {}
    over_api = overlay['api'].is_a?(Hash) ? overlay['api'] : {}
    base_sdk = base['sdk'].is_a?(Hash) ? base['sdk'] : {}
    over_sdk = overlay['sdk'].is_a?(Hash) ? overlay['sdk'] : {}

    # The api-level defaults in effect for this profile. A REPORT, not an
    # input to the instance merge below.
    api = {}
    sortedkeys(base_api, over_api).each do |slug|
      api[slug] = shallow(base_api[slug], over_api[slug])
    end

    # An api block declares no instance of its own (3.1), so the ref set
    # comes from the two `sdk` maps alone.
    sdk = {}
    sortedkeys(base_sdk, over_sdk).each do |ref|
      a = refapi(ref)
      merged = shallow(base_api[a], base_sdk[ref], over_api[a], over_sdk[ref])

      # Defaults are applied ONCE, to the fully merged instance. Had the
      # overlay block carried a synthesized `active` into the merge, a
      # one-key environment override would silently re-enable an
      # integration the base declared inactive.
      # BLOCK_DEFAULTS is shape.rb's table, read here at the SECOND of
      # its two moments (design 4.2): validate_config applies it BEFORE,
      # to every block, because a block with no present keys is an open
      # map; the resolver applies it AFTER, to the merged instance,
      # because an absent key must stay absent through the merge.
      BLOCK_DEFAULTS.each do |k, mk|
        merged[k] = mk.call unless merged.key?(k)
      end

      sdk[ref] = merged
    end

    checksecrets(sdk, profile_name)

    { 'name' => profile_name, 'providers' => providers, 'api' => api, 'sdk' => sdk }
  end

  # A configured secret name sekreto would reject is caught at profile
  # load, not first request (14 station_secret_name) - and then the
  # DERIVED names are checked for uniqueness, because envtoken is lossy:
  # it collapses any run of non-alphanumerics to `_`, so `stripe$test`
  # and an untagged instance of a `stripe-test` api both derive
  # `stripe_test.apikey` and would silently share one credential.
  #
  # Two instances that EXPLICITLY name one secret are not a collision -
  # that is the shared-key case the api-level `secret` exists for.
  def checksecrets(sdk, profile_name)
    refs = sdk.keys.sort

    refs.each do |ref|
      name = sdk[ref]['secret']
      next if name.nil?
      next if VoxgigSekreto.validname(name)

      raise StationError.new('station_secret_name',
        'profile "' + profile_name + '" sdk "' + ref +
        '": secret name rejected by sekreto: ' + name.inspect)
    end

    seen = {}
    refs.each do |ref|
      written = sdk[ref]['secret']
      derived = written.nil? || '' == written
      name = derived ? secretname_default(ref) : written

      prior = seen[name]
      if !prior.nil? && (derived || prior[1])
        raise StationError.new('station_secret_collision',
          'profile "' + profile_name + '": instances "' + prior[0] + '" and "' +
          ref + '" both resolve to secret name "' + name +
          '", so they would share one credential; name it explicitly on ' +
          'each, or at the api level to share it deliberately (5.1)')
      end
      seen[name] = [ref, derived] if prior.nil?
    end
  end

  def providers_of(profile)
    secrets = profile.is_a?(Hash) ? profile['secrets'] : nil
    return nil unless secrets.is_a?(Hash)

    p = secrets['providers']
    p.is_a?(Array) ? p : nil
  end
end
