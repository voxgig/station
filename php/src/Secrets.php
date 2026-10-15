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

/**
 * Design 7.2: keyed by INSTANCE. Two live instances of one api MUST have
 * distinct placeholders or the injection seam cannot tell which
 * credential a header wants. For an untagged instance this is the api
 * slug, so the single-instance case is unchanged to the byte.
 */
function placeholder_for(string $name): string
{
    return '[station:' . $name . ']';
}

/** Every UTF-8 byte outside RFC 3986's unreserved set becomes upper-case %XX. */
function encode_query_value(string $value): string
{
    return rawurlencode($value);
}

function placeholder_match_at(string $text, int $at, int $end, string $placeholder): int
{
    $i = $at;
    $len = strlen($placeholder);
    for ($k = 0; $k < $len; $k++) {
        $ch = $placeholder[$k];
        if ($i < $end && $text[$i] === $ch) {
            $i++;
            continue;
        }
        $hex = substr($text, $i + 1, 2);
        if ($i + 3 <= $end && '%' === $text[$i] &&
            2 === strspn($hex, '0123456789abcdefABCDEF') && hexdec($hex) === ord($ch)) {
            $i += 3;
            continue;
        }
        return -1;
    }
    return $i - $at;
}

/**
 * The placeholder becomes the value in header values and in the URL
 * query, where an SDK percent-encodes it (any hex case) and the value is
 * encoded in turn. The path and fragment are never touched; the headers
 * are a copy.
 *
 * @param array<string, mixed>|null $headers
 * @return array{url: string, headers: array<string, mixed>}
 */
function substitute(string $url, ?array $headers, string $placeholder, string $value): array
{
    $out = $headers ?? [];
    if ('' === $placeholder) {
        return ['url' => $url, 'headers' => $out];
    }

    foreach ($out as $h => $v) {
        if (is_string($v) && str_contains($v, $placeholder)) {
            $out[$h] = str_replace($placeholder, $value, $v);
        }
    }

    $q = strpos($url, '?');
    $hash = strpos($url, '#');
    if (false === $q || (false !== $hash && $hash < $q)) {
        return ['url' => $url, 'headers' => $out];
    }
    $end = false === $hash ? strlen($url) : $hash;
    $encoded = encode_query_value($value);
    $query = '';
    for ($i = $q + 1; $i < $end;) {
        $n = placeholder_match_at($url, $i, $end, $placeholder);
        if (0 < $n) {
            $query .= $encoded;
            $i += $n;
        } else {
            $query .= $url[$i];
            $i++;
        }
    }
    return ['url' => substr($url, 0, $q + 1) . $query . substr($url, $end), 'headers' => $out];
}

/**
 * Every form of every value is matched against the original text and the
 * union of the matches redacted, so no replacement can hide another form.
 *
 * @param array<int, string> $values
 */
function redact_values(string $text, array $values): string
{
    $forms = [];
    foreach ($values as $value) {
        if ('' !== $value) {
            $forms[] = $value;
            $forms[] = encode_query_value($value);
        }
    }
    $reach = function (int $at) use ($text, $forms): int {
        $end = $at;
        foreach ($forms as $form) {
            $len = strlen($form);
            if ($at + $len > $end && substr($text, $at, $len) === $form) {
                $end = $at + $len;
            }
        }
        return $end;
    };

    $out = '';
    $size = strlen($text);
    for ($i = 0; $i < $size;) {
        $stop = $reach($i);
        if ($stop === $i) {
            $out .= $text[$i];
            $i++;
            continue;
        }
        for ($j = $i + 1; $j < $stop; $j++) {
            $stop = max($stop, $reach($j));
        }
        $out .= '[redacted]';
        $i = $stop;
    }
    return $out;
}

class SecretBroker
{
    private \Voxgig\Sekreto\Sekreto $sekreto;
    /**
     * Values hoisted by adopt() from a resident options apikey
     * (design station.md 3.1), keyed by INSTANCE.
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

    public function hoist(string $instance, string $value): void
    {
        $this->overrides[$instance] = $value;
        $this->held[] = $value;
    }

    /**
     * Resolve the value for an instance's secret name. Misses and store
     * errors keep sekreto's distinction (design station.md 5.2): a miss
     * is station_secret_no_value, a store that could not answer is
     * station_secret_error with sekreto's message intact - and never a
     * retry against a weaker store (sekreto owns the chain).
     *
     * OVERRIDES ARE KEYED BY INSTANCE; THE RESOLUTION CACHE IS KEYED BY
     * SECRET NAME (design 5.3). A hoisted credential belongs to the one
     * instance it was resident in, but a resolved VALUE belongs to the
     * name it was resolved for - so several instances sharing one
     * api-level `secret` cost one lookup rather than one each, and every
     * client an auto-tagged create() produces shares the declared
     * instance's entry instead of re-resolving per request. Keying the
     * cache by instance instead is the defect this replaces: at 26
     * instances over 20 apis it turns one store round-trip into 26.
     */
    public function value(string $instance, string $name): string
    {
        if (isset($this->overrides[$instance])) {
            return $this->overrides[$instance];
        }
        if (isset($this->cache[$name])) {
            return $this->cache[$name];
        }

        try {
            $value = $this->sekreto->get($name);
        } catch (\Throwable $e) {
            if ($e instanceof \Voxgig\Sekreto\SekretoError &&
                str_contains($e->getMessage(), 'unknown secret')) {
                throw new StationError('station_secret_no_value',
                    'no store had "' . $name . '" for plugin "' . $instance . '"');
            }
            throw new StationError('station_secret_error', $e->getMessage());
        }

        $this->cache[$name] = $value;
        $this->held[] = $value;
        return $value;
    }

    /**
     * Exact-value scrub, deliberately WITHOUT sekreto's four-character
     * readability floor (design station.md 7 as revised): on boundaries
     * where the promise is absolute, every held value is scrubbed
     * whatever its length. sekreto's own redact() runs after, covering
     * values resolved by the underlying instance that station never held;
     * run first, its raw-value replacement could split an encoded form.
     */
    public function scrub(string $text): string
    {
        return $this->sekreto->redact(redact_values($text, $this->held));
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
