<?php

/**
 * The loader (design station.md 6.3), where the language allows it.
 *
 * THE PHP SHAPE OF "IMPORT A MODULE BY NAME", stated plainly because it
 * is the one place this port's loader differs from the ts/js one:
 *
 * php has no runtime module import. What it has is CLASS AUTOLOADING -
 * a class named but not yet defined is resolved by the registered
 * autoloaders, which in an ordinary application is Composer's PSR-4 map,
 * "the host language's ordinary resolution from the application root".
 * So `api.<slug>.package` names the SDK package's ROOT NAMESPACE (or a
 * composer package name, which is camelized into one: `acme/stripe-sdk`
 * -> `Acme\StripeSdk`), and the loader resolves `<package>\SDK` -
 * exactly the fixed alias 6.3 names - through that map.
 *
 * 6.2 path 1 (self-registration) is available too, and in php it is
 * Composer's `autoload.files`: a generated package whose entry file
 * calls Voxgig\Station\provide() has registered itself before station
 * runs, and load_sync() finds the factory already there.
 *
 * `sdk()` IS SYNCHRONOUS, and php has ONE module system and no async, so
 * there is no ESM split to accommodate: load_sync is the whole loader
 * and Station::load() is a synchronous preload over the declared
 * instances rather than an `await`.
 *
 * THIS IS A CODE-LOADING SURFACE DRIVEN BY A CONFIG FILE, so it has
 * rules, and they are enforced here rather than documented and hoped
 * for. See check_package, and Station::loader_package for the
 * repo-scoped half.
 *
 * A port of typescript/src/loader.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Factory.php';
require_once __DIR__ . '/Kind.php';

/**
 * The fixed alias every generated package exports.
 *
 * `export` defaults to this rather than to a derived class name because
 * it is the same identifier in every generated package, where
 * camelify(slug) . 'SDK' is a rule that has to be recomputed and can be
 * wrong. The derived name is the SECOND attempt and an explicit `export`
 * the third. `package` has NO default: a guessed package name that
 * resolves to the wrong thing is worse than a required key.
 */
const DEFAULT_EXPORT = 'SDK';

/** `stripe-eu` -> `StripeEu`, for the second-attempt export name. */
function camelify(mixed $slug): string
{
    $parts = preg_split('/[^A-Za-z0-9]+/', (string) $slug) ?: [];
    $out = '';
    foreach ($parts as $part) {
        if ('' === $part) {
            continue;
        }
        $out .= strtoupper($part[0]) . substr($part, 1);
    }
    return $out;
}

/**
 * Only MODULE NAMES, resolved by the host language's ordinary resolution
 * from the application root. Never a filesystem path, never a URL, never
 * anything relative - a config file naming a path is a config file
 * reaching outside the dependency graph it is allowed to name.
 *
 * A TRAVERSAL SEGMENT IS NOT A LEADING MARKER, and checking only the
 * first character misses it: `pkg/../../escape` starts with neither `.`
 * nor `/`, so a first-character check passes it, and the host resolves
 * it through `vendor/pkg/../../escape` - application-local code from
 * OUTSIDE the named dependency. The whole point of this function is that
 * a configured package stays inside the dependency graph a reviewer can
 * see.
 */
function check_package(mixed $api, mixed $pkg): string
{
    $p = (string) $pkg;
    $segment = false;
    foreach (explode('/', $p) as $seg) {
        if ('.' === $seg || '..' === $seg) {
            $segment = true;
        }
    }
    $bad = '' === $p ||
        str_starts_with($p, '.') ||
        str_starts_with($p, '/') ||
        str_starts_with($p, '~') ||
        $segment ||
        str_contains($p, '://') ||
        str_contains($p, '\\');
    if ($bad) {
        throw new StationError('station_sdk_load',
            'api "' . $api . '": `package` must be a module name resolved ' .
            'from the application root, not a path or URL: ' . jsonify($pkg));
    }
    return $p;
}

/**
 * The export names tried, in order: an explicit `export`, then the fixed
 * `SDK` alias, then the derived class name. Shared by the module probe
 * and factory_from_module so the two cannot disagree about what was
 * looked for.
 *
 * @return array<int, string>
 */
function export_names(mixed $api, mixed $export = null): array
{
    $names = [];
    if (null !== $export && '' !== $export) {
        $names[] = (string) $export;
    }
    $names[] = DEFAULT_EXPORT;
    $names[] = camelify($api) . 'SDK';
    return $names;
}

/**
 * The namespace prefixes a `package` can mean, most literal first:
 * the string itself with `/` as the separator, and the camelized
 * composer-package reading of it. The global namespace is last, because
 * the generated php SDKs put their class there.
 *
 * @return array<int, string>
 */
function package_namespaces(string $pkg): array
{
    $out = [];
    $literal = trim(str_replace('/', '\\', $pkg), '\\');
    if ('' !== $literal) {
        $out[] = $literal . '\\';
    }
    $camel = '';
    foreach (explode('/', ltrim($pkg, '@')) as $seg) {
        if ('' === $seg) {
            continue;
        }
        $camel .= ('' === $camel ? '' : '\\') . camelify($seg);
    }
    if ('' !== $camel && !in_array($camel . '\\', $out, true)) {
        $out[] = $camel . '\\';
    }
    $out[] = '';
    return $out;
}

/**
 * The php "module": the exports a package makes visible, gathered by
 * asking the registered autoloaders for each candidate class name and
 * then for the `config` singleton beside it.
 *
 * @return array<string, mixed>
 */
function module_exports(mixed $api, string $pkg, mixed $export = null): array
{
    $mod = [];
    $found = null;
    $foundns = '';
    foreach (export_names($api, $export) as $name) {
        foreach (package_namespaces($pkg) as $ns) {
            $cls = $ns . $name;
            // class_exists() runs the registered autoloaders, which IS
            // php's ordinary resolution from the application root.
            if (class_exists($cls)) {
                $mod[$name] = $cls;
                if (null === $found) {
                    $found = $cls;
                    $foundns = $ns;
                }
                break;
            }
        }
    }

    // The `config` singleton beside the constructor, in the spellings a
    // php package can offer one: a namespaced constant, a class
    // constant, a static property, a static accessor.
    foreach (['config', 'CONFIG'] as $cname) {
        if (defined($foundns . $cname)) {
            $mod['config'] = constant($foundns . $cname);
            return $mod;
        }
    }
    if (null !== $found) {
        if (defined($found . '::CONFIG')) {
            $mod['config'] = constant($found . '::CONFIG');
        } elseif (static_property($found, 'config')) {
            $mod['config'] = $found::$config;
        } elseif (method_exists($found, 'config')) {
            $mod['config'] = $found::config();
        }
    }
    return $mod;
}

/**
 * Build a `['construct' => ..., 'config' => ...]` pair from a module
 * that self-registered nothing - the retrofit path for a package whose
 * SDK predates the station feature. It is NOT descriptor-blind: a
 * generated main module exports its constructor AND the `config`
 * singleton beside it.
 *
 * @param array<string, mixed> $mod
 * @return array<string, mixed>
 */
function factory_from_module(mixed $api, mixed $mod, mixed $export = null): array
{
    $mod = is_array($mod) ? $mod : [];
    $tried = [];
    $ctor = null;
    foreach (export_names($api, $export) as $name) {
        $tried[] = $name;
        $cand = $mod[$name] ?? null;
        if (is_string($cand) && class_exists($cand)) {
            $ctor = $cand;
            break;
        }
        if ($cand instanceof \Closure || (is_object($cand) && is_callable($cand))) {
            $ctor = $cand;
            break;
        }
    }

    if (null === $ctor) {
        throw new StationError('station_sdk_load',
            'api "' . $api . '": no SDK constructor found on the module; ' .
            'tried [' . implode(', ', $tried) . ']. Set `export` to the ' .
            'exported name.');
    }

    $config = $mod['config'] ?? ($mod['CONFIG'] ?? null);
    if (null === $config) {
        throw new StationError('station_sdk_load',
            'api "' . $api . '": the module exports a constructor but no ' .
            '`config` singleton, so its feature schema and transport roles ' .
            'cannot be read before construction (6.2)');
    }

    $construct = is_string($ctor)
        ? fn(array $options) => new $ctor($options)
        : fn(array $options) => ($ctor)($options);

    return ['construct' => $construct, 'config' => $config];
}

/**
 * Synchronous load. Returns true when the api has a factory afterwards -
 * either because resolving the package triggered self-registration, or
 * because one was built from its exports.
 */
function load_sync(mixed $api, mixed $pkg, mixed $export = null): bool
{
    check_package($api, $pkg);
    if (null !== factory_for($api)) {
        return true;
    }

    try {
        $mod = module_exports($api, (string) $pkg, $export);
    } catch (StationError $e) {
        throw $e;
    } catch (\Throwable $e) {
        throw new StationError('station_sdk_load',
            'api "' . $api . '": package "' . $pkg . '" could not be ' .
            'imported: ' . $e->getMessage());
    }

    // Path 1: the package self-registered while its autoloader ran
    // (composer `autoload.files`, the php spelling of a module
    // side-effect).
    if (null !== factory_for($api)) {
        return true;
    }

    if (0 === count($mod)) {
        throw new StationError('station_sdk_load',
            'api "' . $api . '": package "' . $pkg . '" could not be ' .
            'imported: no autoloadable class under [' .
            implode(', ', array_map(
                fn($ns) => '' === $ns ? '<global>' : rtrim($ns, '\\'),
                package_namespaces((string) $pkg))) . ']');
    }

    provide($api, factory_from_module($api, $mod, $export));
    return true;
}

/** A STATIC property of that name - an instance property is not one. */
function static_property(string $class, string $name): bool
{
    if (!property_exists($class, $name)) {
        return false;
    }
    try {
        return (new \ReflectionProperty($class, $name))->isStatic();
    } catch (\Throwable $e) {
        return false;
    }
}
