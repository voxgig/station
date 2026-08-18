<?php

/**
 * The descriptor normalizer and canonical serializer (design station.md 4):
 * a VIEW over the embedded config every generated SDK carries - never a
 * second model. Legacy configs (no main.slug/version/target) get fixed
 * sentinels plus a warning.
 *
 * A port of typescript/src/descriptor.ts, which is canonical. All data is
 * string-keyed associative arrays, matching the generated PHP SDKs' config
 * arrays and the conformance corpus.
 */

declare(strict_types=1);

namespace Voxgig\Station;

/**
 * The ONLY way to build an env-var token in station, mirroring sdkgen's
 * packageMeta envToken exactly: 'gnarly-pets' -> 'GNARLY_PETS'. The
 * `secretname` corpus section pins the round-trip against sekreto's
 * envkey() and sdkgen's envName() - the one place three grammars meet.
 */
function envtoken(mixed $name): string
{
    $out = strtoupper((string) ($name ?? ''));
    $out = preg_replace('/[^A-Z0-9]+/', '_', $out) ?? '';
    return trim($out, '_');
}

/**
 * The default sekreto name for a plugin (design station.md 5.1):
 * envtoken(slug) lowercased, plus '.apikey'. sekreto's envkey() then
 * yields exactly the env var the SDK's README documents:
 * gnarly_pets.apikey -> GNARLY_PETS_APIKEY.
 */
function secretname_default(string $slug): string
{
    return strtolower(envtoken($slug)) . '.apikey';
}

/**
 * Best-effort slug from a camel name, for SDKs whose embedded config
 * predates main.slug (design station.md 4 legacy sentinels). The hyphen
 * caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
 * 'voxgig-solardemo' - callers surface a warning event when this path is
 * taken.
 */
function legacy_slug(string $name): string
{
    return strtolower($name);
}

/**
 * Normalize a generated SDK's embedded config into descriptor v1
 * (design station.md 4). Returns ['descriptor' => ..., 'warnings' => ...].
 *
 * @param mixed $config          the SDK's embedded config array
 * @param mixed $active_features options['feature'] map (activation state)
 * @return array{descriptor: array<string,mixed>, warnings: string[]}
 */
function normalize_descriptor(mixed $config, mixed $active_features = null): array
{
    $warnings = [];
    $config = is_array($config) ? $config : [];
    $main = is_array($config['main'] ?? null) ? $config['main'] : [];
    $options = is_array($config['options'] ?? null) ? $config['options'] : [];

    $name = (string) ($main['name'] ?? '');
    $slug = $main['slug'] ?? null;
    if (null === $slug || '' === $slug) {
        $slug = legacy_slug($name);
        $warnings[] = 'descriptor: legacy config has no main.slug; derived "' .
            $slug . '" from the camel name - hyphens in the original name are lost';
    }
    $slug = (string) $slug;

    $version = null === ($main['version'] ?? null) ? '0.0.0' : (string) $main['version'];
    $target = null === ($main['target'] ?? null) ? 'unknown' : (string) $main['target'];

    $server = [];
    $svr = is_array($options['server'] ?? null) ? $options['server'] : [];
    $skeys = array_map('strval', array_keys($svr));
    sort($skeys, SORT_STRING);
    foreach ($skeys as $k) {
        $server[] = ['name' => $k, 'value' => (string) $svr[$k]];
    }

    $auth_active = null !== ($options['auth'] ?? null);
    $auth = [
        'active' => $auth_active,
        'prefix' => $auth_active && is_array($options['auth'])
            ? (string) ($options['auth']['prefix'] ?? '') : '',
        'secretname' => secretname_default($slug),
    ];

    $entities = [];
    $entdefs = is_array($config['entity'] ?? null) ? $config['entity'] : [];
    $enames = array_map('strval', array_keys($entdefs));
    sort($enames, SORT_STRING);
    foreach ($enames as $ename) {
        $e = is_array($entdefs[$ename] ?? null) ? $entdefs[$ename] : [];

        $fields = [];
        foreach ((is_array($e['fields'] ?? null) ? $e['fields'] : []) as $f) {
            if (is_array($f) && null !== ($f['name'] ?? null)) {
                $fields[$f['name']] =
                    ['kind' => (string) ($f['kind'] ?? $f['type'] ?? '')];
            }
        }

        $ops = [];
        $opdefs = is_array($e['op'] ?? null) ? $e['op'] : [];
        $opnames = array_map('strval', array_keys($opdefs));
        sort($opnames, SORT_STRING);
        foreach ($opnames as $opname) {
            $op = is_array($opdefs[$opname] ?? null) ? $opdefs[$opname] : [];
            $points = [];
            foreach ((is_array($op['points'] ?? null) ? $op['points'] : []) as $p) {
                if (!is_array($p)) {
                    continue;
                }
                $params = [];
                foreach ((is_array($p['parts'] ?? null) ? $p['parts'] : []) as $s) {
                    if (is_string($s) && str_starts_with($s, ':')) {
                        $params[] = substr($s, 1);
                    }
                }
                $point = [
                    'method' => (string) ($p['method'] ?? ''),
                    'path' => (string) ($p['orig'] ?? $p['path'] ?? ''),
                    'params' => $params,
                ];
                if (null !== ($p['select'] ?? null)) {
                    $point['select'] = $p['select'];
                }
                $points[] = $point;
            }
            $ops[$opname] = ['points' => $points];
        }

        $entities[$ename] = ['fields' => $fields, 'ops' => $ops];
    }

    $features = [];
    $fdefs = is_array($config['feature'] ?? null) ? $config['feature'] : [];
    $factive = is_array($active_features) ? $active_features : [];
    $fnames = array_map('strval', array_keys($fdefs));
    sort($fnames, SORT_STRING);
    foreach ($fnames as $fname) {
        $fopts = $factive[$fname] ?? null;
        $features[] = [
            'name' => $fname,
            'active' => is_array($fopts) && true === ($fopts['active'] ?? null),
        ];
    }

    $descriptor = [
        'station' => 1,
        'name' => $name,
        'slug' => $slug,
        'envtoken' => envtoken($slug),
        'version' => $version,
        'target' => $target,
        'base' => (string) ($options['base'] ?? ''),
        'server' => $server,
        'auth' => $auth,
        'entities' => $entities,
        'features' => $features,
    ];

    return ['descriptor' => $descriptor, 'warnings' => $warnings];
}

/**
 * Canonical serialization (design station.md 4): UTF-8, object keys
 * sorted bytewise, no insignificant whitespace, minimal JSON escaping.
 * The proxy dedupes registrations by a hash of this, so every language
 * must produce identical bytes - the `canonical` corpus section carries
 * the adversarial cases.
 *
 * PHP's one representational gap: an empty map and an empty list are the
 * same value ([]), so an empty map serializes as '[]' - the same variance
 * the omni php port documents, and no descriptor field is an empty map
 * at the same path where another language would emit '{}' with data in it.
 */
function canonical_serialize(mixed $value): string
{
    if (null === $value || is_bool($value) || is_int($value) || is_float($value)) {
        return json_encode($value, JSON_THROW_ON_ERROR);
    }
    if (is_string($value)) {
        // Minimal escaping: no \/ and no \uXXXX for non-ASCII, matching
        // the ts JSON.stringify reference bytes.
        return json_encode(
            $value,
            JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
        );
    }
    if (is_array($value)) {
        if (array_is_list($value)) {
            $parts = [];
            foreach ($value as $v) {
                $parts[] = canonical_serialize($v);
            }
            return '[' . implode(',', $parts) . ']';
        }
        // Bytewise sort: PHP strcmp compares raw bytes, which for UTF-8
        // strings is exactly the byte-sequence order the spec pins.
        $keys = array_map('strval', array_keys($value));
        usort($keys, 'strcmp');
        $parts = [];
        foreach ($keys as $k) {
            $parts[] = json_encode(
                $k,
                JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
            ) . ':' . canonical_serialize($value[$k]);
        }
        return '{' . implode(',', $parts) . '}';
    }
    if ($value instanceof \stdClass) {
        $vars = get_object_vars($value);
        if (0 === count($vars)) {
            // A deliberate map (the generated configs' (object)[] idiom)
            // keeps its map shape even when empty.
            return '{}';
        }
        return canonical_serialize($vars);
    }
    return 'null';
}
