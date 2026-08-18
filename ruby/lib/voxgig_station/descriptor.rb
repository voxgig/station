# frozen_string_literal: true

# The descriptor normalizer and canonical serializer (design station.md 4):
# a VIEW over the embedded config every generated SDK carries - never a
# second model. Legacy configs (no main.slug/version/target) get fixed
# sentinels plus a warning.
#
# A port of typescript/src/descriptor.ts, which is canonical. All data is
# string-keyed, matching the generated SDKs' config hashes and the
# conformance corpus.

require 'json'

module VoxgigStation
  module_function

  # The ONLY way to build an env-var token in station, mirroring sdkgen's
  # packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
  # `secretname` corpus section pins the round-trip against sekreto's
  # envkey() and sdkgen's envName() - the one place three grammars meet.
  def envtoken(name)
    name.to_s.upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/\A_+|_+\z/, '')
  end

  # The default sekreto name for a plugin (design station.md 5.1):
  # envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
  # yields exactly the env var the SDK's README documents:
  # gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
  def secretname_default(slug)
    envtoken(slug).downcase + '.apikey'
  end

  # Best-effort slug from a camel name, for SDKs whose embedded config
  # predates main.slug (design station.md 4 legacy sentinels). The hyphen
  # caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
  # 'voxgig-solardemo' - callers surface a warning event when this path
  # is taken.
  def legacy_slug(name)
    name.to_s.downcase
  end

  # Normalize a generated SDK's embedded config into descriptor v1
  # (design station.md 4). Returns { descriptor:, warnings: }.
  def normalize_descriptor(config, active_features = nil)
    warnings = []
    config = {} unless config.is_a?(Hash)
    main = config['main'].is_a?(Hash) ? config['main'] : {}
    options = config['options'].is_a?(Hash) ? config['options'] : {}

    name = (main['name'] || '').to_s
    slug = main['slug']
    if slug.nil? || '' == slug
      slug = legacy_slug(name)
      warnings << ('descriptor: legacy config has no main.slug; derived "' +
        slug + '" from the camel name - hyphens in the original name are lost')
    end

    version = main['version'].nil? ? '0.0.0' : main['version'].to_s
    target = main['target'].nil? ? 'unknown' : main['target'].to_s

    server = []
    svr = options['server'].is_a?(Hash) ? options['server'] : {}
    svr.keys.sort.each do |k|
      server << { 'name' => k, 'value' => svr[k].to_s }
    end

    auth_active = !options['auth'].nil?
    auth = {
      'active' => auth_active,
      'prefix' => auth_active ? (options['auth']['prefix'] || '').to_s : '',
      'secretname' => secretname_default(slug),
    }

    entities = {}
    entdefs = config['entity'].is_a?(Hash) ? config['entity'] : {}
    entdefs.keys.sort.each do |ename|
      e = entdefs[ename].is_a?(Hash) ? entdefs[ename] : {}

      fields = {}
      (e['fields'].is_a?(Array) ? e['fields'] : []).each do |f|
        next unless f.is_a?(Hash) && !f['name'].nil?

        fields[f['name']] = { 'kind' => (f['kind'] || f['type'] || '').to_s }
      end

      ops = {}
      opdefs = e['op'].is_a?(Hash) ? e['op'] : {}
      opdefs.keys.sort.each do |opname|
        op = opdefs[opname].is_a?(Hash) ? opdefs[opname] : {}
        points = []
        (op['points'].is_a?(Array) ? op['points'] : []).each do |p|
          next unless p.is_a?(Hash)

          point = {
            'method' => (p['method'] || '').to_s,
            'path' => (p['orig'] || p['path'] || '').to_s,
            'params' => (p['parts'].is_a?(Array) ? p['parts'] : [])
              .select { |s| s.is_a?(String) && s.start_with?(':') }
              .map { |s| s[1..] },
          }
          point['select'] = p['select'] unless p['select'].nil?
          points << point
        end
        ops[opname] = { 'points' => points }
      end

      entities[ename] = { 'fields' => fields, 'ops' => ops }
    end

    features = []
    fdefs = config['feature'].is_a?(Hash) ? config['feature'] : {}
    factive = active_features.is_a?(Hash) ? active_features : {}
    fdefs.keys.sort.each do |fname|
      fopts = factive[fname]
      features << {
        'name' => fname,
        'active' => fopts.is_a?(Hash) && true == fopts['active'],
      }
    end

    descriptor = {
      'station' => 1,
      'name' => name,
      'slug' => slug,
      'envtoken' => envtoken(slug),
      'version' => version,
      'target' => target,
      'base' => (options['base'] || '').to_s,
      'server' => server,
      'auth' => auth,
      'entities' => entities,
      'features' => features,
    }

    { descriptor: descriptor, warnings: warnings }
  end

  # Canonical serialization (design station.md 4): UTF-8, object keys
  # sorted bytewise, no insignificant whitespace, minimal JSON escaping.
  # The proxy dedupes registrations by a hash of this, so every language
  # must produce identical bytes - the `canonical` corpus section carries
  # the adversarial cases.
  def canonical_serialize(value)
    case value
    when nil, true, false, Integer, Float, String
      JSON.generate(value)
    when Array
      '[' + value.map { |v| canonical_serialize(v) }.join(',') + ']'
    when Hash
      # Bytewise sort: compare UTF-8 byte sequences (Ruby string
      # comparison is bytewise for same-encoding strings; force binary
      # so mixed encodings cannot change the order).
      keys = value.keys.sort_by { |k| k.to_s.dup.force_encoding(Encoding::BINARY) }
      '{' + keys.map { |k|
        JSON.generate(k.to_s) + ':' + canonical_serialize(value[k])
      }.join(',') + '}'
    else
      'null'
    end
  end
end
