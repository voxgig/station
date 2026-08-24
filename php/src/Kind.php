<?php

/**
 * THE ONE PLACE THE PHP MAP/LIST AMBIGUITY IS DECIDED.
 *
 * PHP arrays are both maps and lists, so `[]` is at once an empty map
 * and an empty list - the single representational gap this port carries
 * (the omni and struct php ports document the same one). Every other
 * language in the fleet can tell `{}` from `[]`; php cannot, and the
 * config grammar (design station.md 4) needs the difference in exactly
 * two places:
 *
 *  - NORMALIZATION reads `{}` as a map: `sdk: {"solar": {}}` must gain
 *    the block defaults, and `secrets: {}` must gain the provider chain
 *    (corpus config#untagged-ref-is-an-api-slug,
 *    config#secrets-written-without-providers-gets-the-chain). So
 *    is_map() calls an empty array a map.
 *  - VALIDATION reads `[]` as a list, because the shape rejects a list
 *    where a map belongs (corpus config#profiles-must-be-a-map,
 *    config#feature-must-be-a-map), and struct's php port agrees: it
 *    calls an empty array a list.
 *
 * Those two readings collide only on a container the normalizer
 * SYNTHESIZES - `api`, `sdk`, `feature`, `profiles` - which must be a
 * map when the shape sees it. So the normalizer writes synthesized empty
 * maps as `(object)[]`, PHP's only unambiguous "empty map", and
 * validate_config plains them back to `[]` before returning, so the
 * value a caller (and the corpus) sees is an ordinary php array.
 *
 * A user-written empty map (`"profiles": {}` in a real station.json) is
 * indistinguishable from an empty list here and is therefore rejected by
 * the shape - the one behaviour this port cannot match. `{"station": 1}`
 * with no `profiles` key at all is the documented spelling and works.
 */

declare(strict_types=1);

namespace Voxgig\Station;

/**
 * A map, for reading data: an empty array counts, because a JSON `{}`
 * arrives that way.
 */
function is_map(mixed $val): bool
{
    if ($val instanceof \stdClass) {
        return true;
    }
    return is_array($val) && (0 === count($val) || !array_is_list($val));
}

/** A list, for reading data: an empty array counts here too. */
function is_listv(mixed $val): bool
{
    return is_array($val) && array_is_list($val);
}

/** The synthesized empty map: unambiguous to struct, plained on return. */
function empty_map(): \stdClass
{
    return new \stdClass();
}

/** Map entries as an array, whether the map is an array or a stdClass. */
function map_entries(mixed $val): array
{
    if ($val instanceof \stdClass) {
        return get_object_vars($val);
    }
    return is_array($val) ? $val : [];
}

/**
 * Drop the synthesized-empty-map marks: every stdClass becomes a plain
 * array, so the value handed back is ordinary php data.
 */
function plain(mixed $val): mixed
{
    if ($val instanceof \stdClass) {
        $out = [];
        foreach (get_object_vars($val) as $k => $v) {
            $out[$k] = plain($v);
        }
        return $out;
    }
    if (is_array($val)) {
        $out = [];
        foreach ($val as $k => $v) {
            $out[$k] = plain($v);
        }
        return $out;
    }
    return $val;
}
