// The solo event surface (station design 6): a bounded ring buffer plus a
// live tap with serialized callbacks. Events never fail an operation;
// overflow drops oldest and the drop count is visible in status().
//
// A port of typescript/src/events.ts, which is canonical. Public station
// operations are safe from any thread (design 10.2), so the buffer is
// internally synchronized and tap callbacks run serialized under the
// same lock. (Swift closures cannot throw here by type - `(Json) -> Void`
// - so the canonical "a throwing tap never fails the emitter" guarantee
// holds by construction rather than by a catch.)

import Foundation

public final class EventBuffer {
  private var ring: [Json] = []
  private let max: Int
  private var drops: Int64 = 0
  private var taps: [(id: Int, tap: (Json) -> Void)] = []
  private var tapSeq = 0
  private let gate = NSLock()

  public init(_ max: Int = 1000) {
    self.max = max
  }

  public func emit(_ ev: Json) {
    gate.lock()
    defer { gate.unlock() }

    ring.append(ev)
    if ring.count > max {
      ring.removeFirst()
      drops += 1
    }
    // Serialized under the buffer's own lock.
    for entry in taps {
      entry.tap(ev)
    }
  }

  public func events() -> [Json] {
    gate.lock()
    defer { gate.unlock() }
    return ring
  }

  /// Subscribe. The returned handle unsubscribes when run.
  public func tap(_ tap: @escaping (Json) -> Void) -> () -> Void {
    gate.lock()
    tapSeq += 1
    let id = tapSeq
    taps.append((id: id, tap: tap))
    gate.unlock()

    return { [weak self] in
      guard let self = self else { return }
      self.gate.lock()
      self.taps.removeAll { $0.id == id }
      self.gate.unlock()
    }
  }

  public func status() -> Json {
    gate.lock()
    defer { gate.unlock() }
    return .map([
      "buffered": .num(Double(ring.count)),
      "dropped": .num(Double(drops)),
    ])
  }
}
