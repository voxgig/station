# frozen_string_literal: true

# The secret broker (design station.md 5): sekreto resolves, station
# places. The broker holds resolved values privately - they never enter
# options, events, or captures; the SDK sees only the placeholder.
#
# A port of typescript/src/secrets.ts, which is canonical.

require 'voxgig_sekreto'

require_relative 'error'

module VoxgigStation
  module_function

  # Keyed by INSTANCE (design station.md 7.2). Two live instances of one
  # api MUST have distinct placeholders or the injection seam cannot tell
  # which credential a header wants. For an untagged instance this is the
  # api slug, so the single-instance case is unchanged.
  def placeholder_for(name)
    '[station:' + name.to_s + ']'
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
