# frozen_string_literal: true

# The config grammar, as data (design station.md 4).
#
# TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
#
# struct drops the unexpected-key check for a map whose spec node ends
# up empty - "an empty spec object means the object can be open". An
# optional key is `['$ONE','$NIL', spec]`, and when the data does not
# carry that key the validator REMOVES it from the spec node. So a block
# whose keys are all optional degenerates into an open map exactly when
# the data has none of them, and `{"solar": {"bass": 1}}` validates
# clean - the one property the whole exercise is for, silently absent in
# the one case that matters.
#
# So: normalize_config materializes every documented default, and
# validate_config then runs a shape WITH NO OPTIONAL CONTAINERS AT ALL.
# After normalization every container is present, so the shape can
# require them, so unexpected-key detection is live at every level and
# every error names its path.
#
# A port of typescript/src/shape.ts, which is canonical.

require 'json'

require 'voxgig_sekreto'

require_relative 'descriptor'
require_relative 'error'
require_relative 'structhome'

module VoxgigStation
  # ---------------------------------------------------------------------
  # The defaults table - ONE table, two callers
  # ---------------------------------------------------------------------

  # Profile-level containers. Safe to materialize early either way: they
  # are containers, and a missing one merges as empty regardless.
  PROFILE_DEFAULTS = {
    'secrets' => -> { { 'providers' => [{ 'kind' => 'env' }] } },
    'api' => -> { {} },
    'sdk' => -> { {} },
    'feature' => -> { {} },
  }.freeze

  # Block-level. `feature` is a container and safe early.
  #
  # `active` IS NOT, and that is the whole timing rule: a default
  # synthesized into an OVERLAY block overwrites the base's real value
  # and silently reactivates an integration the base deliberately barred
  # (design station.md 3.3). So the two consumers read this same table at
  # different moments - validate_config BEFORE, to every block, because a
  # block with no present keys is an open map; the profile resolver
  # AFTER, to the merged instance, because an absent key must stay absent
  # through the merge.
  BLOCK_DEFAULTS = {
    'active' => -> { true },
    'feature' => -> { {} },
  }.freeze

  # The one block key carrying the timing rule. Named rather than
  # inferred, so a reader does not have to work out which of the two it
  # is, and so a port can assert it.
  MERGE_SENSITIVE = ['active'].freeze

  # Credential-shaped keys (design station.md 5.2). `secret` is here AND
  # is the one exempt key - see secret_value below; a blanket deny would
  # reject the very mechanism that keeps values out of the file.
  CREDENTIAL_KEYS = %w[
    apikey auth authorization token secret password credential bearer
  ].freeze

  # The suffix rule catches `access_key`, `X-Api-Token` and friends in
  # one rule rather than a growing list of spellings.
  CREDENTIAL_SUFFIX = %w[_KEY _TOKEN _SECRET _PASSWORD].freeze

  # design station.md 5.2's backstop, and it is stated as one rather than
  # as a grammar. `validname()` is a NAME grammar, not a credential
  # filter: it rejects uppercase, hyphens, `+`, `/` and `=`, so it
  # excludes most real credential formats - but a lowercase hex token
  # passes it cleanly. A character class cannot tell a name from a
  # secret.
  #
  # Derived names break on every separator (`voxgig_solardemo.apikey`
  # runs 6/9/6) and a hand-written name for a human to read does too; a
  # 24-character unbroken run is not a name anybody writes. Note this is
  # a RUN bound, not a length bound: `acme_internal_billing_service.apikey`
  # is 36 characters and passes, which is the false positive a naive
  # length bound would produce.
  RUN_BOUND = 24
  UNBROKEN_RUN = /[A-Za-z0-9]{#{RUN_BOUND},}/.freeze

  SCHEME_RE = %r{\A[a-zA-Z][a-zA-Z0-9+.\-]*://}.freeze

  # `budget` is a map whose keys are ALL optional scalars - see
  # check_policy.
  BUDGET_KEYS = %w[concurrency rps].freeze

  SHAPE_MUTEX = Mutex.new

  module_function

  # ---------------------------------------------------------------------
  # normalize_config
  # ---------------------------------------------------------------------

  # Materialize every documented default, DEFENSIVELY: a node that is not
  # the kind it expects is left alone for validate to reject with a
  # proper message. Pure data-in/data-out, which is what makes it
  # portable to sixteen languages and expressible in the corpus.
  #
  # THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE,
  # and the input is never mutated: every map is copied before writing.
  def normalize_config(raw)
    return raw unless raw.is_a?(Hash)

    out = raw.dup

    out['station'] = 1 unless out.key?('station')
    out['profiles'] = {} unless out.key?('profiles')
    return out unless out['profiles'].is_a?(Hash)

    profiles = {}
    out['profiles'].each do |pname, p|
      unless p.is_a?(Hash)
        profiles[pname] = p
        next
      end

      prof = p.dup

      PROFILE_DEFAULTS.each do |k, mk|
        prof[k] = mk.call unless prof.key?(k)
      end
      # A `secrets` written without `providers` still gets the chain.
      if prof['secrets'].is_a?(Hash) && !prof['secrets'].key?('providers')
        prof['secrets'] = prof['secrets'].merge('providers' => [{ 'kind' => 'env' }])
      end
      prof['feature'] = norm_features(prof['feature'])

      %w[api sdk].each do |bkey|
        next unless prof[bkey].is_a?(Hash)

        blocks = {}
        prof[bkey].each do |ref, b|
          unless b.is_a?(Hash)
            blocks[ref] = b
            next
          end

          block = b.dup
          BLOCK_DEFAULTS.each do |k, mk|
            block[k] = mk.call unless block.key?(k)
          end
          block['feature'] = norm_features(block['feature'])
          blocks[ref] = block
        end
        prof[bkey] = blocks
      end

      profiles[pname] = prof
    end

    out['profiles'] = profiles
    out
  end

  # Per feature entry, at every level: `active` -> true.
  #
  # A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
  # own default is `active: false` for all but `log`, and
  # `{"retry": {"retries": 3}}` plainly means "retry, with three
  # attempts". It also keeps the feature map closed, for the same reason
  # every other block needs one present key.
  #
  # Defensive like the rest: a non-map is returned untouched for validate
  # to reject by path.
  def norm_features(f)
    return f unless f.is_a?(Hash)

    out = {}
    f.each do |name, e|
      out[name] = e.is_a?(Hash) && !e.key?('active') ? e.merge('active' => true) : e
    end
    out
  end

  # ---------------------------------------------------------------------
  # validate_config
  # ---------------------------------------------------------------------

  # `spec/config-shape.json`, design station.md 4.3 verbatim - the
  # artifact every port reads. This port runs straight from `lib` in the
  # repo (like test/helper.rb's specfile), so it reads the JSON itself
  # rather than shipping a mirror the way a published, compiled artifact
  # must.
  #
  # A FRESH DEEP COPY EVERY CALL: struct's validate CONSUMES the spec it
  # walks (it deletes satisfied `$ONE` branches as it goes), so handing
  # it the parsed constant twice would validate the second config against
  # a spec the first had already eaten.
  def config_shape
    shape = SHAPE_MUTEX.synchronize do
      if @config_shape.nil?
        here = File.dirname(File.expand_path(__FILE__))
        file = File.expand_path(
          File.join(here, '..', '..', '..', 'spec', 'config-shape.json'))
        @config_shape = JSON.parse(File.read(file))
      end
      @config_shape
    end
    structmod.clone(shape)
  end

  # Normalize, then validate (design station.md 4.2). Raises
  # station_config_invalid with EVERY struct error at once - an
  # eighteen-instance config that touches three of them must not die
  # because the eighteenth has a typo'd package name - then the 5.2
  # scans.
  #
  # The 4.4 workarounds are merged into the SAME throw as struct's own
  # errors: a struct new enough to reject a first-element gap itself
  # reports a DIFFERENT spelling ("to be one of ..."), and the corpus
  # pins the explicit one - so the pinned message is produced here either
  # way, and behavior is identical whatever struct version resolves.
  #
  # Takes the NORMALIZED form. Handing it a raw config is the mistake 4.2
  # exists to prevent, so every caller goes through normalize_config
  # first.
  def validate_config(normalized)
    errs = []
    structmod.validate(normalized, config_shape, 'errs' => errs)

    secrets, reserved, invalid = scan_config(normalized)

    if !errs.empty? || !invalid.empty?
      raise StationError.new('station_config_invalid',
        (errs + invalid).join('; ') + rename_hint(normalized))
    end
    if !reserved.empty?
      raise StationError.new('station_feature_reserved', reserved.join('; '))
    end
    if !secrets.empty?
      raise StationError.new('station_config_secret', secrets.join('; '))
    end

    normalized
  end

  # `plugin` is REMOVED, not aliased (design station.md 3.4) - a
  # deprecated alias would be a second grammar for one concept in sixteen
  # ports. The shape already rejects it as an unexpected key; this says
  # WHAT TO RENAME, because "unexpected key: plugin" alone does not, and
  # the migration for a single-instance project is exactly this one
  # rename.
  def rename_hint(cfg)
    profiles = cfg.is_a?(Hash) && cfg['profiles'].is_a?(Hash) ? cfg['profiles'] : {}
    hit = profiles.keys.select do |p|
      profiles[p].is_a?(Hash) && profiles[p].key?('plugin')
    end
    return '' if hit.empty?

    '; rename `plugin` to `sdk` in ' +
      hit.map { |p| 'profiles.' + p.to_s }.join(', ') +
      ' - the keys are unchanged, an untagged ref IS an api slug (3.4)'
  end

  # The 5.2 scans, over the parts of the grammar that hold arbitrary
  # data. Everything else is closed by construction and needs no scan -
  # `profiles.<p>.secrets.providers` INCLUDED: a provider block
  # legitimately carries an `auth` sub-map ({method, role}), so the scan
  # deliberately does not reach there. Collects rather than throws;
  # validate_config owns the throw order.
  def scan_config(cfg)
    secrets = []
    reserved = []
    invalid = []

    profiles = cfg.is_a?(Hash) && cfg['profiles'].is_a?(Hash) ? cfg['profiles'] : {}
    profiles.each do |pname, prof|
      next unless prof.is_a?(Hash)

      ppath = 'profiles.' + pname.to_s

      scan_features(prof['feature'], ppath + '.feature', secrets, reserved, invalid)

      %w[api sdk].each do |bkey|
        next unless prof[bkey].is_a?(Hash)

        prof[bkey].each do |ref, block|
          next unless block.is_a?(Hash)

          bpath = ppath + '.' + bkey + '.' + ref.to_s

          # The block's own `secret` holds a NAME. resolve_profile checks
          # it again per instance (station_secret_name); this catches it
          # at open(), for the whole file at once.
          secret_value(block['secret'], bpath + '.secret', secrets) if block.key?('secret')

          # `options` is passthrough to a generated constructor, so it is
          # the one place a value can hide.
          scan_node(block['options'], bpath + '.options', secrets, reserved)
          scan_features(block['feature'], bpath + '.feature', secrets, reserved, invalid)

          # design station.md 4.4's explicit checks, applied where the
          # shape cannot reach, raising the same code the shape would -
          # and pinned in the corpus so each workaround is removed
          # deliberately when struct is fixed rather than forgotten.
          check_policy(block['policy'], bpath + '.policy', invalid)
        end
      end
    end

    [secrets, reserved, invalid]
  end

  # A feature map at any level. `station` is reserved: station composes
  # its own wrap and a config that reconfigures it is asking for a state
  # the ordering rules cannot express (design station.md 8.4) - and a
  # config file that can switch off the component reading it is not a
  # surface, it is a trap.
  def scan_features(f, path, secrets, reserved, invalid)
    return unless f.is_a?(Hash)

    f.each do |name, entry|
      fpath = path + '.' + name.to_s
      if 'station' == name
        reserved << (path + '.station is reserved: station composes its own ' \
          'wrap and it cannot be configured from station.json')
      end

      order = entry.is_a?(Hash) ? entry['order'] : nil
      if order.is_a?(Hash)
        first_element(order['before'], fpath + '.order.before', invalid)
        first_element(order['after'], fpath + '.order.after', invalid)
      end

      scan_node(entry, fpath, secrets, reserved)
    end
  end

  # The policy block's 4.4 workarounds, in one place because they are one
  # class of gap: struct cannot check what its own defects hide.
  #
  #  - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
  #    so element 0 escapes the shape (see first_element below).
  #  - `budget` is a map whose keys are ALL optional scalars, and struct
  #    removes an unsatisfied optional key from the spec node - so
  #    `budget: {rp: 1}` degenerates the spec into an open map and the
  #    typo passes. `allow` does not have this problem (its `$CHILD` keys
  #    stay in the spec whether or not the data carries them, keeping the
  #    map closed), and neither does `policy` itself (`hosts` anchors
  #    it); `budget` alone needs the explicit unexpected-key check,
  #    phrased as struct would phrase it.
  def check_policy(policy, path, invalid)
    return unless policy.is_a?(Hash)

    first_element(policy['hosts'], path + '.hosts', invalid)

    allow = policy['allow']
    if allow.is_a?(Hash)
      first_element(allow['op'], path + '.allow.op', invalid)
      first_element(allow['method'], path + '.allow.method', invalid)
    end

    budget = policy['budget']
    return unless budget.is_a?(Hash)

    unknown = budget.keys.map(&:to_s).reject { |k| BUDGET_KEYS.include?(k) }.sort
    return if unknown.empty?

    invalid << ('Unexpected keys at field ' + path + '.budget: ' + unknown.join(', '))
  end

  # design station.md 4.4: `$CHILD` in list mode DOES NOT VALIDATE
  # ELEMENT 0. Verified: `["a", 1]` fails at index 1, `[1]` passes, at
  # any list length - filed upstream as voxgig/struct#113. It reaches
  # THREE string lists in this shape: `policy.hosts`, and the per-feature
  # `order.before` / `order.after`. Applied where the shape cannot reach,
  # raising the same code the shape would, and PINNED IN THE CORPUS so
  # the workaround is removed deliberately when struct is fixed rather
  # than forgotten.
  def first_element(list, path, invalid)
    return unless list.is_a?(Array)
    return if list.empty?
    return if list[0].is_a?(String)

    invalid << ('Expected field ' + path + '.0 to be string, but found ' +
      shape_kindof(list[0]) + ': ' + json_of(list[0]))
  end

  # Recursive over EVERY nested map and list, not just the top level - a
  # credential one level down is the case a top-level scan misses.
  def scan_node(node, path, secrets, reserved)
    if node.is_a?(Array)
      node.each_with_index do |item, i|
        scan_node(item, path + '.' + i.to_s, secrets, reserved)
      end
      return
    end
    if node.is_a?(String)
      userinfo(node, path, secrets)
      return
    end
    return unless node.is_a?(Hash)

    node.each do |key, val|
      kpath = path + '.' + key.to_s

      # design station.md 8.6: station owns feature composition, so an
      # `options.feature` in a declarative config is a second,
      # unreconciled ordering input.
      if 'feature' == key
        reserved << (kpath + ' is reserved: configure features under the ' \
          "block's own `feature` key, not through `options`")
        next
      end

      if 'secret' == key.to_s.downcase
        secret_value(val, kpath, secrets)
        next
      end

      if credential_key?(key)
        secrets << (kpath + ' is a credential-shaped key: station.json ' \
          'holds secret NAMES, never values (5.2)')
        next
      end

      scan_node(val, kpath, secrets, reserved)
    end
  end

  def credential_key?(key)
    low = key.to_s.downcase.gsub(/[^a-z0-9]+/, '')
    return true if CREDENTIAL_KEYS.include?(low)

    tok = envtoken(key)
    CREDENTIAL_SUFFIX.any? { |s| tok.end_with?(s) }
  end

  # A `secret`-named key holds a NAME, and that exemption is not a
  # loophole - it is the whole design. THREE checks, not one, and they
  # live in the same handful of lines precisely so a port cannot
  # implement only the first and inherit the gap the others close.
  def secret_value(val, path, secrets)
    unless val.is_a?(String)
      secrets << (path + ' must be a secret name (a string), but found ' +
        shape_kindof(val))
      return
    end
    unless VoxgigSekreto.validname(val)
      secrets << (path + ' is not a valid sekreto name, so it cannot be a ' \
        'name and must not be a value: ' + json_of(val))
      return
    end
    return unless UNBROKEN_RUN.match?(val)

    secrets << (path + ' contains an unbroken alphanumeric run of ' +
      RUN_BOUND.to_s + ' or more characters, which is not a name anybody writes')
  end

  # One rule about VALUES rather than keys, because the `proxy` feature
  # makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
  # failure is not an error - it returns silently.
  def userinfo(val, path, secrets)
    return unless SCHEME_RE.match?(val)

    authority = val.split('://', 2)[1]
    return if authority.nil?

    ['/', '?', '#'].each do |cut|
      at = authority.index(cut)
      authority = authority[0...at] unless at.nil?
    end

    at = authority.rindex('@')
    return if at.nil?

    info = authority[0...at]
    return if '' == info

    secrets << (path + ' is a URL carrying userinfo, which puts a credential ' \
      "in the config file; use the proxy feature's `fromEnv` option " \
      'instead (8.6)')
  end

  # The SHAPE kindof, which must agree with struct's own spellings. NOT
  # the feature one in feature.rb - the two disagree on numbers and maps
  # on purpose, and unifying them would report struct's grammar in the
  # SDK's words.
  def shape_kindof(v)
    return 'null' if v.nil?
    return 'boolean' if true == v || false == v
    return 'list' if v.is_a?(Array)
    return 'object' if v.is_a?(Hash)
    return 'string' if v.is_a?(String)

    if v.is_a?(Numeric)
      integral = v.is_a?(Integer) || (v.is_a?(Float) && v.finite? && v == v.truncate)
      return integral ? 'integer' : 'decimal'
    end

    v.class.name.to_s.downcase
  end

  # JSON.stringify's spacing, so the pinned messages read the same in
  # every port.
  def json_of(v)
    JSON.generate(v)
  end
end
