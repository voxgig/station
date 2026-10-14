# frozen_string_literal: true

# The secret broker (design station.md 5): sekreto resolves, station
# places. The broker holds resolved values privately - they never enter
# options, events, or captures; the SDK sees only the placeholder.
#
# A port of typescript/src/secrets.ts, which is canonical.

require 'voxgig_sekreto'

require_relative 'error'

module VoxgigStation
  HEXPAIR_RE = /\A[0-9A-Fa-f]{2}\z/.freeze

  module_function

  # Keyed by INSTANCE (design station.md 7.2). Two live instances of one
  # api MUST have distinct placeholders or the injection seam cannot tell
  # which credential a header wants. For an untagged instance this is the
  # api slug, so the single-instance case is unchanged.
  def placeholder_for(name)
    '[station:' + name.to_s + ']'
  end

  # Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX.
  def encode_query_value(value)
    value.to_s.b.gsub(/[^A-Za-z0-9\-._~]/n) { |c| format('%%%02X', c.ord) }
      .force_encoding(Encoding::UTF_8)
  end

  def query_match_at(text, at, stop, placeholder)
    i = at
    placeholder.each_char do |ch|
      if i < stop && text[i] == ch
        i += 1
      elsif i + 3 <= stop && '%' == text[i] && HEXPAIR_RE.match?(text[i + 1, 2]) &&
            text[i + 1, 2].to_i(16) == ch.ord
        i += 3
      else
        return -1
      end
    end
    i - at
  end

  # The placeholder becomes the value in header values and in the URL query,
  # where an SDK percent-encodes it (any hex case) and the value is encoded in
  # turn. The path and fragment are never touched; the headers are a copy.
  def substitute(url, headers, placeholder, value)
    out = headers.is_a?(Hash) ? headers.dup : {}
    return { 'url' => url, 'headers' => out } if '' == placeholder

    out.each do |h, v|
      out[h] = v.split(placeholder, -1).join(value) if v.is_a?(String) && v.include?(placeholder)
    end

    q = url.index('?')
    return { 'url' => url, 'headers' => out } if q.nil?

    hash_at = url.index('#', q)
    stop = hash_at.nil? ? url.length : hash_at
    encoded = encode_query_value(value)
    query = +''
    i = q + 1
    while i < stop
      n = query_match_at(url, i, stop, placeholder)
      if n.positive?
        query << encoded
        i += n
      else
        query << url[i]
        i += 1
      end
    end
    { 'url' => url[0..q] + query + url[stop..], 'headers' => out }
  end

  class SecretBroker
    def initialize(providers)
      @sekreto = VoxgigSekreto::Sekreto.new('providers' => providers)
      # Values hoisted by adopt() from resident options apikey
      # (design station.md 3.1).
      @overrides = {}
      @cache = {}
      # Every value this broker ever held, for the exact-value scrub.
      @held = []
      @mutex = Mutex.new
    end

    def hoist(instance, value)
      @mutex.synchronize do
        @overrides[instance] = value
        @held << value
      end
    end

    # Resolve the value for a plugin's secret name. Misses and store
    # errors keep sekreto's distinction (design station.md 5.2): a miss
    # is station_secret_no_value, a store that could not answer is
    # station_secret_error with sekreto's message intact - and never a
    # retry against a weaker store (sekreto owns the chain).
    # OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
    # SECRET NAME (design station.md 5.3). A hoisted credential belongs
    # to the one instance it was resident in, but a resolved VALUE
    # belongs to the NAME it was resolved for - so several instances
    # sharing one api-level `secret` cost one lookup rather than one
    # each, and every client an auto-tagged create() produces shares the
    # declared instance's entry instead of re-resolving per request.
    #
    # Keying the cache by instance instead is the defect this replaces:
    # at 26 instances over 20 apis it turns one store round-trip into 26.
    def value(instance, name)
      @mutex.synchronize do
        override = @overrides[instance]
        return override unless override.nil?

        cached = @cache[name]
        return cached unless cached.nil?
      end

      begin
        value = @sekreto.get(name)
      rescue StandardError => e
        if e.is_a?(VoxgigSekreto::SekretoError) && e.message.include?('unknown secret')
          raise StationError.new('station_secret_no_value',
            'no store had "' + name + '" for plugin "' + instance.to_s + '"')
        end
        raise StationError.new('station_secret_error', e.message.to_s)
      end

      @mutex.synchronize do
        @cache[name] = value
        @held << value
      end
      value
    end

    # Exact-value scrub, deliberately WITHOUT sekreto's four-character
    # readability floor (design station.md 7 as revised): on boundaries
    # where the promise is absolute, every held value is scrubbed
    # whatever its length. sekreto's own redact() runs too, covering
    # values resolved by the underlying instance that station never held.
    def scrub(text)
      out = @sekreto.redact(text.to_s)
      held = @mutex.synchronize { @held.dup }
      held.each do |value|
        next if '' == value.to_s

        out = out.split(value, -1).join('[redacted]')
        encoded = VoxgigStation.encode_query_value(value)
        out = out.split(encoded, -1).join('[redacted]') unless encoded == value
      end
      out
    end

    # Drop caches so the next resolve asks the stores again (rotation
    # support rides on sekreto's refresh, design station.md 5.3).
    def refresh
      @mutex.synchronize { @cache.clear }
      @sekreto.refresh if @sekreto.respond_to?(:refresh)
    end
  end
end
