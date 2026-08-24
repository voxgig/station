# frozen_string_literal: true

# Feature management (design station.md 8): the three-level merge, the
# constraint-and-band resolver, and the descriptor-derived checker.
#
# The resolver is written to voxgig/plugin's 7 semantics so plugin can
# extract it - this is one of the pieces the joint plan means by
# "station builds natively to plugin's semantics".
#
# A port of typescript/src/feature.ts, which is canonical.

require 'json'

require_relative 'error'

module VoxgigStation
  # Reserved on a feature entry: not options, and never passed through to
  # the SDK's own option map.
  RESERVED_KEYS = %w[active order].freeze

  # `test` substitutes the base transport, so it takes the innermost
  # band; `station` sits immediately outside it, pinned; everything else
  # is band 0, outside station.
  #
  # THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
  # than as a special case: a project that writes no `order` anywhere
  # sees exactly today's nesting, and sdkgen's two make_options special
  # cases become two band values rather than two branches.
  BAND_DEFAULT = 0
  BAND_STATION = 100
  BAND_TEST = 200

  module_function

  # ---------------------------------------------------------------------
  # design station.md 8.3 - the merge
  # ---------------------------------------------------------------------

  # `feature` is the ONE key where 3.3's shallow-per-key rule is wrong:
  # composition is the entire point, a fleet default plus a per-instance
  # tweak. So it is a TWO-LEVEL merge - per feature name, then per option
  # key - and NO DEEPER. A map-valued option REPLACES wholesale, which is
  # what `{"$MERGE": {"deep": 2}}` states and what a port defaulting to a
  # deep merge would silently get wrong.
  #
  # Same defaults-after-merge rule as 3.3, one level down: an entry
  # mentioned at one level with only a tuning key must NOT synthesize
  # `active` and switch on a feature a broader level turned off. That is
  # the 3.3 defect one level down, and it is why the caller passes RAW
  # blocks here.
  def merge_features(sources)
    out = {}
    (sources || []).each do |src|
      next unless src.is_a?(Hash)

      src.each do |name, entry|
        unless entry.is_a?(Hash)
          out[name] = entry
          next
        end

        # Per option key, and NOT deeper.
        prior = out[name].is_a?(Hash) ? out[name] : {}
        out[name] = prior.merge(entry)
      end
    end
    out
  end

  # The six sources for one instance, in 3.3's order extended by the
  # profile level:
  #
  #   1 base.feature            4 overlay.feature
  #   2 base.api[<api>].feature 5 overlay.api[<api>].feature
  #   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
  #
  # PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
  # the narrower block wins - the same principle as 3.3, one level down.
  # Assembled here rather than at the call site so the order lives in
  # exactly one place.
  def feature_sources(base, overlay, api, ref)
    [
      level_feature(base),
      block_feature(base, 'api', api),
      block_feature(base, 'sdk', ref),
      level_feature(overlay),
      block_feature(overlay, 'api', api),
      block_feature(overlay, 'sdk', ref),
    ]
  end

  def level_feature(profile)
    profile.is_a?(Hash) ? profile['feature'] : nil
  end

  def block_feature(profile, bkey, key)
    return nil unless profile.is_a?(Hash)

    blocks = profile[bkey]
    return nil unless blocks.is_a?(Hash)

    block = blocks[key]
    block.is_a?(Hash) ? block['feature'] : nil
  end

  # ---------------------------------------------------------------------
  # design station.md 8.4 - activation and order
  # ---------------------------------------------------------------------

  # Higher is further IN.
  def default_band(name)
    return BAND_TEST if 'test' == name
    return BAND_STATION if 'station' == name

    BAND_DEFAULT
  end

  # A feature named in the config is one you are ASKING for, so an entry
  # with no `active` is active.
  def feature_active?(entry)
    return false != entry unless entry.is_a?(Hash)

    false != entry['active']
  end

  # `before`/`after` take a feature name or a list of them.
  def list_of(v)
    return [] if v.nil?

    (v.is_a?(Array) ? v : [v]).map(&:to_s)
  end

  # Resolve the activation order: constraints, then bands, then the
  # feature's position in the merged map.
  #
  # `before`/`after` are SATISFIED VACUOUSLY when the named feature is
  # absent - `after: 'test'` loads fine in a project with no test
  # feature, which is sdkgen's `__after__` behaviour kept rather than
  # reinvented.
  #
  # Constraints beat bands; bands break ties no constraint decides;
  # remaining ties break by DECLARATION POSITION, so the result is a
  # stable topological sort with no alphabetical accident in it. Ruby
  # hashes iterate in insertion order, so the corpus's authored key order
  # is the declaration order.
  #
  # Returns OUTERMOST FIRST, which is the array form the constructor
  # takes and the direction plugin's chain composes in.
  def resolve_order(merged)
    merged = {} unless merged.is_a?(Hash)
    names = merged.keys.select { |n| feature_active?(merged[n]) }

    pos = {}
    names.each_with_index { |n, i| pos[n] = i }

    band = {}
    names.each do |n|
      o = merged[n].is_a?(Hash) ? merged[n]['order'] : nil
      band[n] = o.is_a?(Hash) && o['band'].is_a?(Numeric) ? o['band'] : default_band(n)
    end

    # edges: from OUTER to INNER. `after: X` means "further in than X".
    inner = {}
    names.each { |n| inner[n] = [] }

    names.each do |n|
      o = merged[n].is_a?(Hash) ? merged[n]['order'] : nil
      next unless o.is_a?(Hash)

      # Vacuous when absent: an unknown name is not an error here.
      list_of(o['after']).each do |other|
        inner[other] << n if inner.key?(other) && !inner[other].include?(n)
      end
      list_of(o['before']).each do |other|
        inner[n] << other if inner.key?(other) && !inner[n].include?(other)
      end
    end

    indeg = {}
    names.each { |n| indeg[n] = 0 }
    names.each { |n| inner[n].each { |m| indeg[m] += 1 } }

    # Kahn, picking the LOWEST BAND first (outermost), then declaration
    # position - so ties break the same way in every port.
    ready = names.select { |n| 0 == indeg[n] }
    out = []
    until ready.empty?
      ready.sort_by! { |n| [band[n], pos[n]] }
      n = ready.shift
      out << { 'name' => n, 'band' => band[n], 'entry' => merged[n] }
      inner[n].each do |m|
        indeg[m] -= 1
        ready << m if 0 == indeg[m]
      end
    end

    if out.length != names.length
      stuck = (names - out.map { |o| o['name'] }).sort
      raise StationError.new('station_feature_order',
        'feature ordering constraints form a cycle among [' +
        stuck.join(', ') + ']')
    end

    out
  end

  # Station's own position is PINNED and not orderable (8.4): an order
  # that moves `station` away from immediately-outside-the-base is
  # REJECTED, not honoured.
  #
  # The pin is `innermost`, and THE SPELLING MATTERS. A chain composes
  # with the FIRST binding outermost, so a pin written in sort terms -
  # "station first" - would place every other wrapper between the adapter
  # and the base: the exact inversion of the invariant, and one that
  # would leave station's wire-truth events observing the wrong boundary
  # while still looking ordered.
  def check_pin(ordered)
    i = ordered.index { |o| 'station' == o['name'] }
    return if i.nil?

    base = ordered.index { |o| 'test' == o['name'] }
    # station must be the innermost wrapper: last, or immediately outside
    # the base-transport feature when one is active.
    want = base.nil? ? ordered.length - 1 : base - 1
    return if i == want

    raise StationError.new('station_feature_order',
      'an ordering would move `station` away from immediately outside ' \
      'the base transport; its position is pinned innermost and is not ' \
      'orderable (8.4)')
  end

  # Compose the merged map into the ORDERED ARRAY FORM the constructor
  # takes. No new seam: it is what connect() already does for station's
  # own placement, with more in it.
  def compose_features(ordered)
    ordered.map do |o|
      entry = o['entry'].is_a?(Hash) ? o['entry'] : {}
      out = { 'name' => o['name'], 'active' => true }
      entry.each do |k, v|
        next if RESERVED_KEYS.include?(k.to_s)

        out[k] = v
      end
      out
    end
  end

  # ---------------------------------------------------------------------
  # design station.md 8.5 - the checker, derived from the descriptor
  # ---------------------------------------------------------------------

  # Check a merged feature map against THE SDK'S OWN DECLARATION.
  #
  # The schema arrives with the FACTORY rather than with a live client
  # (6.2), so this needs no construction and no network - which is what
  # lets check() run it for every instance in CI.
  #
  # Derived from the descriptor, NEVER hand-written, so it cannot drift:
  # when a feature gains an option, the next regeneration teaches station
  # about it with no station change.
  #
  # SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED
  # ONLY, and that limit is real and deliberate: an empty list default
  # says nothing reliable about its element type and a nested map default
  # says nothing about its value shapes.
  #
  # COLLECTS, never raises - the callers own the throw.
  def check_features(merged, descriptor)
    faults = []
    declared = descriptor.is_a?(Hash) && descriptor['features'].is_a?(Array) ?
      descriptor['features'] : []

    byname = {}
    declared.each { |f| byname[f['name'].to_s] = f if f.is_a?(Hash) }

    merged = {} unless merged.is_a?(Hash)
    merged.keys.map(&:to_s).sort.each do |name|
      spec = byname[name]
      if spec.nil?
        faults << {
          'code' => 'station_feature_unknown',
          'feature' => name,
          'message' => 'the SDK has no feature "' + name + '"; it declares [' +
            byname.keys.sort.join(', ') + ']',
        }
        next
      end

      entry = merged[name]
      next unless entry.is_a?(Hash)

      defaults = spec['options'].is_a?(Hash) ? spec['options'] : {}

      entry.keys.map(&:to_s).sort.each do |key|
        next if RESERVED_KEYS.include?(key)

        unless defaults.key?(key)
          # THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is accepted
          # and silently ignored today, because the SDK's own feature
          # spec is `$OPEN` per feature so the SDK cannot catch it and
          # nothing else looks.
          faults << {
            'code' => 'station_feature_option',
            'feature' => name,
            'key' => key,
            'message' => 'feature "' + name + '" declares no option "' + key +
              '"; it declares [' + defaults.keys.map(&:to_s).sort.join(', ') + ']',
          }
          next
        end

        want = feature_kindof(defaults[key])
        got = feature_kindof(entry[key])
        next if want == got

        faults << {
          'code' => 'station_feature_option',
          'feature' => name,
          'key' => key,
          'message' => 'feature "' + name + '" option "' + key + '" expects ' +
            want + ', but found ' + got + ': ' + JSON.generate(entry[key]),
        }
      end
    end

    faults
  end

  # The FEATURE kindof, in the SDK's own words. NOT shape.rb's - the two
  # disagree on numbers and maps on purpose, and unifying them would
  # report struct's grammar where the SDK's belongs.
  def feature_kindof(v)
    return 'null' if v.nil?
    return 'boolean' if true == v || false == v
    return 'list' if v.is_a?(Array)
    return 'number' if v.is_a?(Numeric)
    return 'map' if v.is_a?(Hash)
    return 'string' if v.is_a?(String)

    v.class.name.to_s.downcase
  end
end
