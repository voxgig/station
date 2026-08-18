// The solo event surface (station design 6): a bounded ring buffer plus a
// live tap with serialized callbacks. Events never fail an operation;
// overflow drops oldest and the drop count is visible in Status().
//
// A port of typescript/src/events.ts, which is canonical. Public station
// operations are safe from any thread (design 10.2), so the buffer is
// internally synchronized and tap callbacks run serialized under the
// same lock.

using System;
using System.Collections.Generic;

namespace Voxgig.Station
{
    public class EventBuffer
    {
        private readonly LinkedList<Dictionary<string, object>> ring =
            new LinkedList<Dictionary<string, object>>();
        private readonly int max;
        private long drops = 0;
        private readonly List<Action<Dictionary<string, object>>> taps =
            new List<Action<Dictionary<string, object>>>();
        private readonly object gate = new object();

        public EventBuffer() : this(1000)
        {
        }

        public EventBuffer(int max)
        {
            this.max = max;
        }

        public void Emit(Dictionary<string, object> ev)
        {
            lock (gate)
            {
                ring.AddLast(ev);
                if (ring.Count > max)
                {
                    ring.RemoveFirst();
                    drops++;
                }
                // Serialized, and a throwing tap must not fail the operation
                // that emitted the event.
                foreach (var tap in taps.ToArray())
                {
                    try
                    {
                        tap(ev);
                    }
                    catch (Exception)
                    {
                        // Deliberately swallowed.
                    }
                }
            }
        }

        public List<Dictionary<string, object>> Events()
        {
            lock (gate)
            {
                return new List<Dictionary<string, object>>(ring);
            }
        }

        /// <summary>Subscribe. The returned handle unsubscribes when run.</summary>
        public Action Tap(Action<Dictionary<string, object>> tap)
        {
            lock (gate)
            {
                taps.Add(tap);
            }
            return () =>
            {
                lock (gate)
                {
                    taps.Remove(tap);
                }
            };
        }

        public Dictionary<string, object> Status()
        {
            lock (gate)
            {
                return new Dictionary<string, object>
                {
                    ["buffered"] = ring.Count,
                    ["dropped"] = drops,
                };
            }
        }
    }
}
