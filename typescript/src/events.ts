import { StationEvent } from './types'

// The solo event surface (design §6): a bounded ring buffer plus a live
// tap with serialized callbacks. Events never fail an operation; overflow
// drops oldest and the drop count is visible in status().

export class EventBuffer {
  private ring: StationEvent[] = []
  private max: number
  private drops = 0
  private taps: ((ev: StationEvent) => void)[] = []

  constructor(max?: number) {
    this.max = null == max ? 1000 : max
  }

  emit(ev: StationEvent): void {
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

  events(): StationEvent[] {
    return this.ring.slice()
  }

  tap(fn: (ev: StationEvent) => void): () => void {
    this.taps.push(fn)
    return () => {
      const i = this.taps.indexOf(fn)
      if (-1 !== i) { this.taps.splice(i, 1) }
    }
  }

  status(): { buffered: number, dropped: number } {
    return { buffered: this.ring.length, dropped: this.drops }
  }
}
