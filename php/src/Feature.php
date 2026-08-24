<?php

/**
 * Feature management (design station.md 8): the three-level merge, the
 * constraint-and-band resolver, and the descriptor-derived checker.
 *
 * The resolver is written to voxgig/plugin's 7 semantics so plugin can
 * extract it - this is one of the pieces the joint plan means by
 * "station builds natively to plugin's semantics".
 *
 * A port of typescript/src/feature.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Kind.php';

// ---------------------------------------------------------------------
// 8.3 - the merge
// ---------------------------------------------------------------------

/** Reserved on a feature entry: not options, and never passed through to
 * the SDK's own option map. */
const RESERVED_KEYS = ['active', 'order'];

/**
 * The six sources, in 3.3's order extended by the profile level:
 *
 *   1 base.feature            4 overlay.feature
 *   2 base.api[<api>].feature 5 overlay.api[<api>].feature
 *   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
 *
 * PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
 * the narrower block wins - the same principle as 3.3, one level down.
 *
 * `feature` is the ONE key where 3.3's shallow-per-key rule is wrong:
 * composition is the entire point, a fleet default plus a per-instance
 * tweak. So it is a TWO-LEVEL merge - per feature name, then per option
 * key - and NO DEEPER. A map-valued option REPLACES wholesale, which is
 * what `{"$MERGE": {"deep": 2}}` states and what a port defaulting to a
 * deep merge would silently get wrong.
 *
 * NO DEFAULTS ARE SYNTHESIZED HERE: an entry mentioned at one level with
 * only a tuning key must NOT synthesize `active` and switch on a feature
 * a broader level turned off. That is the 3.3 defect one level down, and
 * it is why the caller passes RAW blocks.
 *
 * @param array<int, mixed> $sources
 * @return array<string, mixed>
 */
function merge_features(array $sources): array
{
    $out = [];
    foreach ($sources as $src) {
        if (!is_map($src)) {
            continue;
        }
        foreach (map_entries($src) as $name => $entry) {
            $name = (string) $name;
            if (!is_map($entry)) {
                $out[$name] = $entry;
                continue;
            }
            // Per option key, and NOT deeper. Assigned key by key
            // rather than array_merge'd: php's array_merge RENUMBERS
            // integer-like keys, and a feature option named "0" is a
            // key like any other.
            $acc = is_map($out[$name] ?? null) ? map_entries($out[$name]) : [];
            foreach (map_entries($entry) as $k => $v) {
                $acc[$k] = $v;
            }
            $out[$name] = $acc;
        }
    }
    return $out;
}

/**
 * The six sources for one instance, in order. Assembled here rather than
 * at the call site so the order lives in exactly one place.
 *
 * @return array<int, mixed>
 */
function feature_sources(mixed $base, mixed $overlay, mixed $api, mixed $ref): array
{
    $api = (string) ($api ?? '');
    $ref = (string) ($ref ?? '');
    return [
        mval($base, 'feature'),
        mval(mval(mval($base, 'api'), $api), 'feature'),
        mval(mval(mval($base, 'sdk'), $ref), 'feature'),
        mval($overlay, 'feature'),
        mval(mval(mval($overlay, 'api'), $api), 'feature'),
        mval(mval(mval($overlay, 'sdk'), $ref), 'feature'),
    ];
}

// ---------------------------------------------------------------------
// 8.4 - activation and order
// ---------------------------------------------------------------------

/**
 * `test` substitutes the base transport, so it takes the innermost band;
 * `station` sits immediately outside it, pinned; everything else is band
 * 0, outside station. HIGHER IS FURTHER IN.
 *
 * THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
 * than as a special case: a project that writes no `order` anywhere sees
 * exactly today's nesting.
 */
const BAND_DEFAULT = 0;
const BAND_STATION = 100;
const BAND_TEST = 200;

function default_band(string $name): int
{
    if ('test' === $name) {
        return BAND_TEST;
    }
    if ('station' === $name) {
        return BAND_STATION;
    }
    return BAND_DEFAULT;
}

/**
 * A feature named in the config is one you are ASKING for, so an entry
 * with no `active` is active.
 */
function feature_active(mixed $entry): bool
{
    if (!is_map($entry)) {
        return false !== $entry;
    }
    return false !== mval($entry, 'active');
}

/**
 * Resolve the activation order: constraints, then bands, then the
 * feature's position in the merged map.
 *
 * `before`/`after` take a feature name or a list of them and are
 * SATISFIED VACUOUSLY when the named feature is absent - `after: 'test'`
 * loads fine in a project with no test feature, which is sdkgen's
 * `__after__` behaviour kept rather than reinvented.
 *
 * Constraints beat bands; bands break ties no constraint decides;
 * remaining ties break by DECLARATION POSITION, so the result is a
 * stable topological sort with no alphabetical accident in it.
 *
 * Returns OUTERMOST FIRST, which is the array form the constructor takes
 * and the direction plugin's chain composes in.
 *
 * @return array<int, array{name: string, band: int|float, entry: mixed}>
 */
function resolve_order(mixed $merged): array
{
    $entries = map_entries($merged);
    $names = [];
    foreach ($entries as $name => $entry) {
        if (feature_active($entry)) {
            $names[] = (string) $name;
        }
    }

    $pos = [];
    foreach ($names as $i => $n) {
        $pos[$n] = $i;
    }

    $band = [];
    foreach ($names as $n) {
        $order = is_map($entries[$n]) ? mval($entries[$n], 'order') : null;
        $b = is_map($order) ? mval($order, 'band') : null;
        $band[$n] = (is_int($b) || is_float($b)) ? $b : default_band($n);
    }

    // edges: from OUTER to INNER. `after: X` means "further in than X".
    $inner = [];
    foreach ($names as $n) {
        $inner[$n] = [];
    }

    foreach ($names as $n) {
        $order = is_map($entries[$n]) ? mval($entries[$n], 'order') : null;
        if (!is_map($order)) {
            continue;
        }
        // Vacuous when absent: an unknown name is not an error here.
        foreach (listof(mval($order, 'after')) as $other) {
            if (array_key_exists($other, $inner) && !in_array($n, $inner[$other], true)) {
                $inner[$other][] = $n;
            }
        }
        foreach (listof(mval($order, 'before')) as $other) {
            if (array_key_exists($other, $inner) && !in_array($other, $inner[$n], true)) {
                $inner[$n][] = $other;
            }
        }
    }

    $indeg = [];
    foreach ($names as $n) {
        $indeg[$n] = 0;
    }
    foreach ($names as $n) {
        foreach ($inner[$n] as $m) {
            $indeg[$m]++;
        }
    }

    // Kahn, picking the LOWEST BAND first (outermost), then declaration
    // position - so ties break the same way in every port.
    $ready = [];
    foreach ($names as $n) {
        if (0 === $indeg[$n]) {
            $ready[] = $n;
        }
    }

    $out = [];
    $done = [];
    while (0 < count($ready)) {
        usort($ready, function (string $a, string $b) use ($band, $pos): int {
            if ($band[$a] != $band[$b]) {
                return $band[$a] < $band[$b] ? -1 : 1;
            }
            return $pos[$a] <=> $pos[$b];
        });
        $n = array_shift($ready);
        $out[] = ['name' => $n, 'band' => $band[$n], 'entry' => $entries[$n]];
        $done[$n] = true;
        foreach ($inner[$n] as $m) {
            $indeg[$m]--;
            if (0 === $indeg[$m]) {
                $ready[] = $m;
            }
        }
    }

    if (count($out) !== count($names)) {
        $stuck = [];
        foreach ($names as $n) {
            if (!isset($done[$n])) {
                $stuck[] = $n;
            }
        }
        sort($stuck, SORT_STRING);
        throw new StationError('station_feature_order',
            'feature ordering constraints form a cycle among [' .
            implode(', ', $stuck) . ']');
    }

    return $out;
}

/**
 * A single name or a list of them, stringified.
 *
 * @return array<int, string>
 */
function listof(mixed $val): array
{
    if (null === $val) {
        return [];
    }
    $vals = is_listv($val) ? $val : [$val];
    $out = [];
    foreach ($vals as $v) {
        $out[] = is_scalar($v) ? (string) $v : '';
    }
    return $out;
}

/**
 * Station's own position is PINNED and not orderable (design 8.4): an
 * order that moves `station` away from immediately-outside-the-base is
 * REJECTED, not honoured.
 *
 * THE PIN IS `INNERMOST`, AND THE SPELLING MATTERS. A chain composes
 * with the FIRST binding outermost, so a pin written in sort terms -
 * "station first" - would place every other wrapper between the adapter
 * and the base: the exact inversion of the invariant, and one that would
 * leave station's wire-truth events observing the wrong boundary while
 * still looking ordered.
 *
 * @param array<int, array{name: string, band: int|float, entry: mixed}> $ordered
 */
function check_pin(array $ordered): void
{
    $i = -1;
    $base = -1;
    foreach ($ordered as $at => $row) {
        if ('station' === $row['name']) {
            $i = $at;
        }
        if ('test' === $row['name']) {
            $base = $at;
        }
    }
    if (-1 === $i) {
        return;
    }

    // station must be the innermost wrapper: last, or immediately
    // outside the base-transport feature when one is active.
    $want = -1 === $base ? count($ordered) - 1 : $base - 1;
    if ($i !== $want) {
        throw new StationError('station_feature_order',
            'an ordering would move `station` away from immediately outside ' .
            'the base transport; its position is pinned innermost and is not ' .
            'orderable (8.4)');
    }
}

// ---------------------------------------------------------------------
// 8.5 - the checker, derived from the descriptor
// ---------------------------------------------------------------------

/**
 * Check a merged feature map against the SDK'S OWN DECLARATION.
 *
 * The schema arrives with the FACTORY rather than with a live client
 * (6.2), so this needs no construction and no network - which is what
 * lets check() run it for every instance in CI.
 *
 * Derived from the descriptor, NEVER hand-written, so it cannot drift:
 * when a feature gains an option, the next regeneration teaches station
 * about it with no station change.
 *
 * SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED ONLY,
 * and that limit is real: an empty list default says nothing reliable
 * about its element type and a nested map default says nothing about its
 * value shapes.
 *
 * COLLECTS, never throws - the callers own the throw.
 *
 * @return array<int, array{code: string, feature: string, key?: string, message: string}>
 */
function check_features(mixed $merged, mixed $descriptor): array
{
    $faults = [];

    $declared = is_map($descriptor) ? mval($descriptor, 'features') : null;
    $byname = [];
    foreach (is_listv($declared) ? $declared : [] as $f) {
        if (is_map($f)) {
            $byname[(string) mval($f, 'name')] = $f;
        }
    }
    $declarednames = array_keys($byname);
    sort($declarednames, SORT_STRING);

    $entries = map_entries($merged);
    $names = array_map('strval', array_keys($entries));
    sort($names, SORT_STRING);

    foreach ($names as $name) {
        if (!array_key_exists($name, $byname)) {
            $faults[] = [
                'code' => 'station_feature_unknown',
                'feature' => $name,
                'message' => 'the SDK has no feature "' . $name . '"; it ' .
                    'declares [' . implode(', ', $declarednames) . ']',
            ];
            continue;
        }

        $entry = $entries[$name];
        if (!is_map($entry)) {
            continue;
        }
        $declopts = mval($byname[$name], 'options');
        $defaults = is_map($declopts) ? map_entries($declopts) : [];
        $defaultkeys = array_map('strval', array_keys($defaults));
        sort($defaultkeys, SORT_STRING);

        $keys = array_map('strval', array_keys(map_entries($entry)));
        sort($keys, SORT_STRING);

        foreach ($keys as $key) {
            if (in_array($key, RESERVED_KEYS, true)) {
                continue;
            }

            if (!array_key_exists($key, $defaults)) {
                // THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is
                // accepted and silently ignored today, because the SDK's
                // own feature spec is `$OPEN` per feature so the SDK
                // cannot catch it and nothing else looks.
                $faults[] = [
                    'code' => 'station_feature_option',
                    'feature' => $name,
                    'key' => $key,
                    'message' => 'feature "' . $name . '" declares no option "' .
                        $key . '"; it declares [' .
                        implode(', ', $defaultkeys) . ']',
                ];
                continue;
            }

            $want = kindof_feature($defaults[$key]);
            $got = kindof_feature(mval($entry, $key));
            if ($want !== $got) {
                $faults[] = [
                    'code' => 'station_feature_option',
                    'feature' => $name,
                    'key' => $key,
                    'message' => 'feature "' . $name . '" option "' . $key .
                        '" expects ' . $want . ', but found ' . $got . ': ' .
                        jsonify(mval($entry, $key)),
                ];
            }
        }
    }

    return $faults;
}

/**
 * Compose the merged map into the ORDERED ARRAY FORM the constructor
 * takes. No new seam: it is what connect() already does for station's
 * own placement, with more in it.
 *
 * @param array<int, array{name: string, band: int|float, entry: mixed}> $ordered
 * @return array<int, array<string, mixed>>
 */
function compose_features(array $ordered): array
{
    $out = [];
    foreach ($ordered as $row) {
        $entry = is_map($row['entry']) ? map_entries($row['entry']) : [];
        $one = ['name' => $row['name'], 'active' => true];
        foreach ($entry as $k => $v) {
            if (in_array((string) $k, RESERVED_KEYS, true)) {
                continue;
            }
            $one[(string) $k] = $v;
        }
        $out[] = $one;
    }
    return $out;
}

/**
 * The FEATURE kindof - "map"/"number", not the shape one's
 * "object"/"integer". Two different functions on purpose (design 2.8);
 * kindof_shape lives in Shape.php and must agree with struct's
 * spellings, this one with the 8.5 message vocabulary.
 */
function kindof_feature(mixed $val): string
{
    if (null === $val) {
        return 'null';
    }
    if (is_listv($val)) {
        return 'list';
    }
    if (is_int($val) || is_float($val)) {
        return 'number';
    }
    if (is_map($val)) {
        return 'map';
    }
    if (is_bool($val)) {
        return 'boolean';
    }
    if (is_string($val)) {
        return 'string';
    }
    return strtolower(gettype($val));
}
