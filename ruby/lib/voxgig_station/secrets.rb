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

  def placeholder_for(slug)
    '[station:' + slug + ']'
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

    def hoist(slug, value)
      @mutex.synchronize do
        @overrides[slug] = value
        @held << value
      end
    end

    # Resolve the value for a plugin's secret name. Misses and store
    # errors keep sekreto's distinction (design station.md 5.2): a miss
    # is station_secret_no_value, a store that could not answer is
    # station_secret_error with sekreto's message intact - and never a
    # retry against a weaker store (sekreto owns the chain).
    def value(slug, name)
      @mutex.synchronize do
        override = @overrides[slug]
        return override unless override.nil?

        cached = @cache[slug]
        return cached unless cached.nil?
      end

      begin
        value = @sekreto.get(name)
      rescue StandardError => e
        if e.is_a?(VoxgigSekreto::SekretoError) && e.message.include?('unknown secret')
          raise StationError.new('station_secret_no_value',
            'no store had "' + name + '" for plugin "' + slug + '"')
        end
        raise StationError.new('station_secret_error', e.message.to_s)
      end

      @mutex.synchronize do
        @cache[slug] = value
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
