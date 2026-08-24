<?php

/**
 * station.json lookup and profile resolution (design station.md 3.5).
 *
 * A port of typescript/src/profile.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Descriptor.php';
require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Kind.php';
require_once __DIR__ . '/Sekreto.php';
require_once __DIR__ . '/Shape.php';

/**
 * station.json lookup: cwd upward to the repo root, then
 * ~/.voxgig/station.json (design station.md 3.5). A repo root is where
 * .git lives; with no repo the walk stops at the filesystem root.
 */
function find_config_file(?string $from = null): ?string
{
    $dir = $from ?? getcwd();
    $dir = false === $dir ? '.' : $dir;
    $dir = realpath($dir) ?: $dir;
    for (;;) {
        $candidate = $dir . DIRECTORY_SEPARATOR . 'station.json';
        if (file_exists($candidate)) {
            return $candidate;
        }
        $at_repo_root = file_exists($dir . DIRECTORY_SEPARATOR . '.git');
        $parent = dirname($dir);
        if ($at_repo_root || $parent === $dir) {
            break;
        }
        $dir = $parent;
    }
    $home = getenv('HOME') ?: '';
    if ('' !== $home) {
        $cand = $home . DIRECTORY_SEPARATOR . '.voxgig' .
            DIRECTORY_SEPARATOR . 'station.json';
        if (file_exists($cand)) {
            return $cand;
        }
    }
    return null;
}

/** @return array<string, mixed>|null */
function load_config(?string $from = null): ?array
{
    $file = find_config_file($from);
    if (null === $file) {
        return null;
    }
    $text = file_get_contents($file);
    if (false === $text) {
        return null;
    }
    // A file that is not JSON is a CONFIG ERROR, not a raw parse error
    // escaping open(): the reader found station.json and could not use
    // it, which is exactly what station_config_invalid exists to say.
    try {
        $out = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
    } catch (\JsonException $e) {
        throw new StationError('station_config_invalid',
            'station.json at ' . $file . ' is not valid JSON: ' . $e->getMessage());
    }
    return is_array($out) ? $out : null;
}

/**
 * Which side of the review boundary the config came from (design 6.3).
 *
 * `package` and `export` are honoured only from REPO-SCOPED config,
 * because a user-level file is outside the repo's review boundary and a
 * `package` key arriving from it names code to import. Everything else
 * in a user-level config still applies - this narrows one key rather
 * than distrusting the file.
 */
function config_scope(?string $from = null): string
{
    $file = find_config_file($from);
    if (null === $file) {
        return 'none';
    }
    $home = getenv('HOME') ?: '';
    if ('' === $home) {
        return 'repo';
    }
    $user = $home . DIRECTORY_SEPARATOR . '.voxgig' .
        DIRECTORY_SEPARATOR . 'station.json';
    return $file === $user ? 'user' : 'repo';
}

/**
 * Profile selection: VOXGIG_STATION_PROFILE, else the open() option,
 * else 'default' (design station.md 3.5 - env vars rank above
 * station.json but below open() opts; profile NAME selection follows the
 * same order with open() opts winning).
 */
function select_profile(?string $opt_profile = null): string
{
    if (null !== $opt_profile && '' !== $opt_profile) {
        return $opt_profile;
    }
    $env = getenv('VOXGIG_STATION_PROFILE');
    if (false !== $env && '' !== $env) {
        return $env;
    }
    return 'default';
}

/**
 * The api half of a ref is the substring before the first `$`, and an
 * untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
 * point: under the old free-form identity which api an instance used
 * was itself a merged value, so a port that got the phasing wrong
 * silently picked another api's defaults.
 */
function refapi(string $ref): string
{
    $at = strpos($ref, '$');
    return false === $at ? $ref : substr($ref, 0, $at);
}

/**
 * Shallow merge, per key, left to right - each source over the one
 * before it. An overlay's `policy` REPLACES the base's entirely rather
 * than merging `hosts` into it; an allowlist that widens because two
 * precedence levels merged is the failure this rule prevents.
 *
 * @return array<string, mixed>
 */
function shallow(mixed ...$sources): array
{
    $out = [];
    foreach ($sources as $src) {
        if (is_array($src)) {
            $out = array_merge($out, $src);
        }
    }
    return $out;
}

/** @return array<int, string> */
function sortedkeys(mixed ...$maps): array
{
    $keys = [];
    foreach ($maps as $m) {
        if (is_array($m)) {
            foreach (array_keys($m) as $k) {
                $keys[(string) $k] = true;
            }
        }
    }
    $out = array_keys($keys);
    sort($out);
    return $out;
}

/**
 * Merge the base profile ('default') with the selected overlay.
 *
 * Design 3.3's total order for the two block levels, lowest first:
 *
 *   base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]
 *
 * PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
 * LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
 * namespace, then put instance over api" - that lets every instance
 * value beat every api value, so a production `api.stripe.policy` would
 * fail to override a default profile's `sdk.stripe$test.policy`,
 * silently keeping the wider allowlist in production.
 *
 * `secrets.providers` replaces wholesale, never merges (3.5, 5.2).
 *
 * @param mixed $config decoded station.json, or null
 * @return array{name: string, providers: array<int, mixed>, api: array<string, array<string, mixed>>, sdk: array<string, array<string, mixed>>}
 */
function resolve_profile(mixed $config, string $profile_name): array
{
    $profiles = is_array($config) && is_array($config['profiles'] ?? null)
        ? $config['profiles'] : [];
    $base = is_array($profiles['default'] ?? null) ? $profiles['default'] : [];
    $overlay = 'default' === $profile_name
        ? []
        : (is_array($profiles[$profile_name] ?? null) ? $profiles[$profile_name] : []);

    $providers = providers_of($overlay) ?? providers_of($base) ?? [['kind' => 'env']];

    $base_api = is_array($base['api'] ?? null) ? $base['api'] : [];
    $over_api = is_array($overlay['api'] ?? null) ? $overlay['api'] : [];
    $base_sdk = is_array($base['sdk'] ?? null) ? $base['sdk'] : [];
    $over_sdk = is_array($overlay['sdk'] ?? null) ? $overlay['sdk'] : [];

    // The api-level defaults in effect for this profile. A REPORT, not
    // an input to the instance merge below.
    $api = [];
    foreach (sortedkeys($base_api, $over_api) as $slug) {
        $api[$slug] = shallow($base_api[$slug] ?? null, $over_api[$slug] ?? null);
    }

    // An api block declares no instance of its own (3.1), so the ref set
    // comes from the two `sdk` maps alone.
    $sdk = [];
    foreach (sortedkeys($base_sdk, $over_sdk) as $ref) {
        $a = refapi($ref);
        $merged = shallow(
            $base_api[$a] ?? null,
            $base_sdk[$ref] ?? null,
            $over_api[$a] ?? null,
            $over_sdk[$ref] ?? null
        );

        // Defaults are applied ONCE, to the fully merged instance. Had
        // the overlay block carried a synthesized `active` into the
        // merge, a one-key environment override would silently re-enable
        // an integration the base declared inactive.
        // The SAME table validate_config reads, at the OTHER moment
        // (Shape.php block_defaults). Plained on the way in: the
        // synthesized empty map is a validation spelling, and a resolved
        // instance is ordinary php data.
        foreach (block_defaults() as $k => $make) {
            if (!array_key_exists($k, $merged)) {
                $merged[$k] = plain($make());
            }
        }

        $sdk[$ref] = $merged;
    }

    checksecrets($sdk, $profile_name);

    return [
        'name' => $profile_name, 'providers' => $providers,
        'api' => $api, 'sdk' => $sdk,
    ];
}

/**
 * A configured secret name sekreto would reject is caught at profile
 * load, not first request (14 station_secret_name) - and then the
 * DERIVED names are checked for uniqueness, because envtoken is lossy:
 * it collapses any run of non-alphanumerics to `_`, so `stripe$test` and
 * an untagged instance of a `stripe-test` api both derive
 * `stripe_test.apikey` and would silently share one credential.
 *
 * Two instances that EXPLICITLY name one secret are not a collision -
 * that is the shared-key case the api-level `secret` exists for.
 *
 * @param array<string, array<string, mixed>> $sdk
 */
function checksecrets(array $sdk, string $profile_name): void
{
    sekreto_load();
    $refs = array_keys($sdk);
    sort($refs);

    foreach ($refs as $ref) {
        $name = $sdk[$ref]['secret'] ?? null;
        if (null === $name) {
            continue;
        }
        if (!\Voxgig\Sekreto\Name::valid($name)) {
            throw new StationError('station_secret_name',
                'profile "' . $profile_name . '" sdk "' . $ref .
                '": secret name rejected by sekreto: ' .
                json_encode($name, JSON_UNESCAPED_SLASHES));
        }
    }

    $seen = [];
    foreach ($refs as $ref) {
        $written = $sdk[$ref]['secret'] ?? null;
        $derived = null === $written || '' === $written;
        $name = $derived ? secretname_default($ref) : $written;

        if (isset($seen[$name]) && ($derived || $seen[$name][1])) {
            throw new StationError('station_secret_collision',
                'profile "' . $profile_name . '": instances "' . $seen[$name][0] .
                '" and "' . $ref . '" both resolve to secret name "' . $name .
                '", so they would share one credential; name it explicitly ' .
                'on each, or at the api level to share it deliberately (5.1)');
        }
        if (!isset($seen[$name])) {
            $seen[$name] = [$ref, $derived];
        }
    }
}

/** @return array<int, mixed>|null */
function providers_of(mixed $profile): ?array
{
    $secrets = is_array($profile) ? ($profile['secrets'] ?? null) : null;
    if (!is_array($secrets)) {
        return null;
    }
    $p = $secrets['providers'] ?? null;
    return is_array($p) && array_is_list($p) ? $p : null;
}
