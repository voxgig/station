// The solo event surface (station design 6): a bounded ring buffer plus a
// live tap with serialized callbacks. Events never fail an operation;
// overflow drops oldest and the drop count is visible in status().
//
// A port of typescript/src/events.ts, which is canonical. Public station
// operations are safe from any thread (design 10.2), so the buffer is
// internally synchronized and tap callbacks run serialized under the
// same lock.

package com.voxgig.station;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Consumer;

public class EventBuffer {

  private final Deque<Map<String, Object>> ring = new ArrayDeque<>();
  private final int max;
  private long drops = 0;
  private final List<Consumer<Map<String, Object>>> taps = new ArrayList<>();

  public EventBuffer() {
    this(1000);
  }

  public EventBuffer(int max) {
    this.max = max;
  }

  public synchronized void emit(Map<String, Object> event) {
    ring.addLast(event);
    if (ring.size() > max) {
      ring.removeFirst();
      drops++;
    }
    // Serialized, and a throwing tap must not fail the operation that
    // emitted the event.
    for (Consumer<Map<String, Object>> tap : new ArrayList<>(taps)) {
      try {
        tap.accept(event);
      } catch (RuntimeException err) {
        // Deliberately swallowed.
      }
    }
  }

  public synchronized List<Map<String, Object>> events() {
    return new ArrayList<>(ring);
  }

  /** Subscribe. The returned handle unsubscribes when run. */
  public synchronized Runnable tap(Consumer<Map<String, Object>> tap) {
    taps.add(tap);
    return () -> {
      synchronized (this) {
        taps.remove(tap);
      }
    };
  }

  public synchronized Map<String, Object> status() {
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("buffered", ring.size());
    out.put("dropped", drops);
    return out;
  }
}
