# The solo event surface (design station.md 6): a bounded ring buffer plus
# a live tap with serialized callbacks. Events never fail an operation;
# overflow drops oldest and the drop count is visible in status().
#
# A port of typescript/src/events.ts, which is canonical. Pure functions
# over an immutable buffer value - the mutable cell holding the buffer is
# the station instance's ETS slot (see Voxgig.Station), which also keeps
# the taps out of this module's hands: emit/2 returns the tap functions to
# run, and the caller invokes them OUTSIDE the state write so a tap may
# re-enter the query surface (events/status) safely.

defmodule Voxgig.Station.Events do
  @default_max 1000

  def buffer(max \\ @default_max) do
    %{queue: :queue.new(), count: 0, max: max, drops: 0, taps: []}
  end

  # Append one event; drop the oldest past the cap. Returns the updated
  # buffer plus the tap functions to invoke (in subscription order - the
  # serialized-callbacks contract of design station.md 10.2).
  def emit(buf, ev) do
    queue = :queue.in(ev, buf.queue)

    {queue, count, drops} =
      if buf.count + 1 > buf.max do
        {_, queue} = :queue.out(queue)
        {queue, buf.max, buf.drops + 1}
      else
        {queue, buf.count + 1, buf.drops}
      end

    taps = Enum.map(buf.taps, fn {_ref, fun} -> fun end)
    {%{buf | queue: queue, count: count, drops: drops}, taps}
  end

  # All buffered events, oldest first.
  def events(buf), do: :queue.to_list(buf.queue)

  def tap(buf, ref, fun), do: %{buf | taps: buf.taps ++ [{ref, fun}]}

  def untap(buf, ref) do
    %{buf | taps: Enum.reject(buf.taps, fn {r, _fun} -> r == ref end)}
  end

  def status(buf), do: %{"buffered" => buf.count, "dropped" => buf.drops}
end
