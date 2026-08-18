<?php

/**
 * The secret broker (design station.md 5): sekreto resolves, station
 * places. The broker holds resolved values privately - they never enter
 * options, events, or captures; the SDK sees only the placeholder.
 *
 * A port of typescript/src/secrets.ts, which is canonical. Synchronous
 * throughout - the php SDK pipeline is synchronous, and so is sekreto's
 * php port.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Sekreto.php';

function placeholder_for(string $slug): string
{
    return '[station:' . $slug . ']';
}

class SecretBroker
{
    private \Voxgig\Sekreto\Sekreto $sekreto;
    /**
     * Values hoisted by adopt() from resident options apikey
     * (design station.md 3.1).
     *
     * @var array<string, string>
     */
    private array $overrides = [];
    /** @var array<string, string> */
    private array $cache = [];
    /**
     * Every value this broker ever held, for the exact-value scrub.
     *
     * @var array<int, string>
     */
    private array $held = [];

    /** @param array<int, mixed> $providers */
    public function __construct(array $providers)
    {
        sekreto_load();
        $this->sekreto = new \Voxgig\Sekreto\Sekreto(['providers' => $providers]);
    }

    public function hoist(string $slug, string $value): void
    {
        $this->overrides[$slug] = $value;
        $this->held[] = $value;
    }

    /**
     * Resolve the value for a plugin's secret name. Misses and store
     * errors keep sekreto's distinction (design station.md 5.2): a miss
     * is station_secret_no_value, a store that could not answer is
     * station_secret_error with sekreto's message intact - and never a
     * retry against a weaker store (sekreto owns the chain).
     */
    public function value(string $slug, string $name): string
    {
        if (isset($this->overrides[$slug])) {
            return $this->overrides[$slug];
        }
        if (isset($this->cache[$slug])) {
            return $this->cache[$slug];
        }

        try {
            $value = $this->sekreto->get($name);
        } catch (\Throwable $e) {
            if ($e instanceof \Voxgig\Sekreto\SekretoError &&
                str_contains($e->getMessage(), 'unknown secret')) {
                throw new StationError('station_secret_no_value',
                    'no store had "' . $name . '" for plugin "' . $slug . '"');
            }
            throw new StationError('station_secret_error', $e->getMessage());
        }

        $this->cache[$slug] = $value;
        $this->held[] = $value;
        return $value;
    }

    /**
     * Exact-value scrub, deliberately WITHOUT sekreto's four-character
     * readability floor (design station.md 7 as revised): on boundaries
     * where the promise is absolute, every held value is scrubbed
     * whatever its length. sekreto's own redact() runs too, covering
     * values resolved by the underlying instance that station never held.
     */
    public function scrub(string $text): string
    {
        $out = $this->sekreto->redact($text);
        foreach ($this->held as $value) {
            if ('' !== $value) {
                $out = str_replace($value, '[redacted]', $out);
            }
        }
        return $out;
    }

    /**
     * Drop caches so the next resolve asks the stores again (rotation
     * support rides on sekreto's refresh, design station.md 5.3).
     */
    public function refresh(): void
    {
        $this->cache = [];
        if (method_exists($this->sekreto, 'refresh')) {
            $this->sekreto->refresh();
        }
    }
}
