<?php

/**
 * station.json lookup and profile resolution (design station.md 3.5).
 *
 * A port of typescript/src/profile.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Sekreto.php';

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
    $out = json_decode($text, true, 512, JSON_THROW_ON_ERROR);
    return is_array($out) ? $out : null;
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
 * Merge the base profile ('default') with the selected overlay:
 * deep-merge per plugin, EXCEPT secrets.providers which replaces
 * wholesale (design station.md 3.5, 5.2 - chain order decides which
 * store wins, so a positional merge would be actively dangerous). The
 * `profile` corpus section pins this.
 *
 * @param mixed $config decoded station.json, or null
 * @return array{name: string, providers: array<int, mixed>, plugin: array<string, array<string, mixed>>}
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

    $plugin = [];
    foreach ([$base['plugin'] ?? null, $overlay['plugin'] ?? null] as $src) {
        if (!is_array($src)) {
            continue;
        }
        foreach ($src as $slug => $p) {
            if (!is_array($p)) {
                continue;
            }
            $slug = (string) $slug;
            $plugin[$slug] = array_merge($plugin[$slug] ?? [], $p);
        }
    }

    // A configured secret name sekreto would reject is caught at profile
    // load, not first request (design station.md 14 station_secret_name).
    sekreto_load();
    foreach ($plugin as $slug => $p) {
        $name = $p['secret'] ?? null;
        if (null === $name) {
            continue;
        }
        if (!\Voxgig\Sekreto\Name::valid($name)) {
            throw new StationError('station_secret_name',
                'profile "' . $profile_name . '" plugin "' . $slug .
                '": secret name rejected by sekreto: ' .
                json_encode($name, JSON_UNESCAPED_SLASHES));
        }
    }

    return ['name' => $profile_name, 'providers' => $providers, 'plugin' => $plugin];
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
