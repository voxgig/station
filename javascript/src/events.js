// The solo event surface (design §6): a bounded ring buffer plus a live
// tap with serialized callbacks. Events never fail an operation; overflow
// drops oldest and the drop count is visible in status().
//
// A port of typescript/src/events.ts, which is canonical.

class EventBuffer {
  constructor(max) {
    this.ring = []
    this.max = null == max ? 1000 : max
    this.drops = 0
    this.taps = []
  }

  emit(ev) {
    this.ring.push(ev)
    if (this.ring.length > this.max) {
      this.ring.shift()
      this.drops++
    }
    // Serialized, and a throwing tap must not fail the operation that
    // emitted the event.
    for (const fn of this.taps) {
      try { fn(ev) } catch (_e) { }
    }
  }

  events() {
    return this.ring.slice()
  }

  tap(fn) {
    this.taps.push(fn)
    return () => {
      const i = this.taps.indexOf(fn)
      if (-1 !== i) { this.taps.splice(i, 1) }
    }
  }

  status() {
    return { buffered: this.ring.length, dropped: this.drops }
  }
}

module.exports = {
  EventBuffer,
}
