<?php

/**
 * The solo event surface (design station.md 6): a bounded ring buffer plus
 * a live tap with serialized callbacks. Events never fail an operation;
 * overflow drops oldest and the drop count is visible in status().
 *
 * A port of typescript/src/events.ts, which is canonical. PHP (NTS) is
 * single-threaded per request, so no locking is needed - the observable
 * contract (serialized taps, bounded buffer) is the same.
 */

declare(strict_types=1);

namespace Voxgig\Station;

class EventBuffer
{
    /** @var array<int, array<string, mixed>> */
    private array $ring = [];
    private int $max;
    private int $drops = 0;
    /** @var array<int, callable> */
    private array $taps = [];
    private int $tapseq = 0;

    public function __construct(?int $max = null)
    {
        $this->max = $max ?? 1000;
    }

    /** @param array<string, mixed> $ev */
    public function emit(array $ev): void
    {
        $this->ring[] = $ev;
        if (count($this->ring) > $this->max) {
            array_shift($this->ring);
            $this->drops++;
        }
        // Serialized, and a throwing tap must not fail the operation that
        // emitted the event.
        foreach ($this->taps as $fn) {
            try {
                $fn($ev);
            } catch (\Throwable $_e) {
                // deliberately ignored
            }
        }
    }

    /** @return array<int, array<string, mixed>> */
    public function events(): array
    {
        return $this->ring;
    }

    /** Subscribe; the returned callable unsubscribes. */
    public function tap(callable $fn): callable
    {
        $id = $this->tapseq++;
        $this->taps[$id] = $fn;
        return function () use ($id): void {
            unset($this->taps[$id]);
        };
    }

    /** @return array{buffered: int, dropped: int} */
    public function status(): array
    {
        return ['buffered' => count($this->ring), 'dropped' => $this->drops];
    }
}
