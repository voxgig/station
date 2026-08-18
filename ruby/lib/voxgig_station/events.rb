# frozen_string_literal: true

# The solo event surface (design station.md 6): a bounded ring buffer plus
# a live tap with serialized callbacks. Events never fail an operation;
# overflow drops oldest and the drop count is visible in status.
#
# A port of typescript/src/events.ts, which is canonical. Public station
# operations are safe from any thread (design station.md 10.2), so the
# ring and tap list are guarded by a mutex; tap callbacks run serialized
# under it.

module VoxgigStation
  class EventBuffer
    def initialize(max = nil)
      @max = max.nil? ? 1000 : max
      @ring = []
      @drops = 0
      @taps = []
      @mutex = Mutex.new
    end

    def emit(ev)
      taps = nil
      @mutex.synchronize do
        @ring << ev
        if @ring.length > @max
          @ring.shift
          @drops += 1
        end
        taps = @taps.dup
      end
      # Serialized, and a raising tap must not fail the operation that
      # emitted the event.
      taps.each do |fn|
        begin
          fn.call(ev)
        rescue StandardError
          # deliberately swallowed
        end
      end
    end

    def events
      @mutex.synchronize { @ring.dup }
    end

    # Subscribe; returns an unsubscribe lambda.
    def tap(fn = nil, &blk)
      fn ||= blk
      @mutex.synchronize { @taps << fn }
      -> { @mutex.synchronize { @taps.delete(fn) } }
    end

    def status
      @mutex.synchronize { { 'buffered' => @ring.length, 'dropped' => @drops } }
    end
  end
end
