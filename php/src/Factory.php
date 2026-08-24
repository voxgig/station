<?php

/**
 * The factory table (design station.md 6.2).
 *
 * A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
 * callable, and leaving the second half out is a hole. Station composes
 * the ordered feature array FOR the constructor, so it needs the
 * transport roles and the feature option schemas BEFORE construction -
 * but the adapter builds and registers its descriptor DURING
 * construction. Nothing would be known in time. The generated package
 * emits its config as a module-level constant, so it exists as soon as
 * the package is linked. Station normalizes the descriptor AT PROVIDE
 * TIME, and three things follow:
 *
 *  - the per-api descriptor cache is populated at REGISTRATION rather
 *    than on first construction;
 *  - check() can validate every instance's feature config WITHOUT
 *    constructing anything;
 *  - the adapter's registration during construction becomes a
 *    RECONCILIATION - same descriptor, now bound to a live client -
 *    rather than the first sighting.
 *
 * The table is PROCESS-GLOBAL because path 1 of 6.2 is module
 * self-registration, which happens once per process and not once per
 * Station. php (NTS) is single-threaded per request, so a static
 * property is the whole of it - no lock, and the same
 * process-per-request note the rest of this port carries applies.
 *
 * A port of typescript/src/factory.ts, which is canonical.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Descriptor.php';

/** The one table. Not part of the public surface - use the functions. */
final class FactoryTable
{
    /** @var array<string, array<string, mixed>> */
    public static array $table = [];
}

/**
 * Register an api's `['construct' => callable, 'config' => mixed]` pair.
 *
 * Idempotent per api: registering the SAME pair twice is a no-op,
 * because module self-registration and an explicit provide() for one api
 * is an ordinary thing for an application to end up with. A second
 * registration with a DIFFERENT factory is station_factory_conflict -
 * silently picking one of two SDK builds is not a thing to do quietly.
 *
 * @param array<string, mixed> $factory
 * @return array<string, mixed>
 */
function provide(mixed $api, array $factory): array
{
    $slug = (string) $api;
    $prior = FactoryTable::$table[$slug] ?? null;
    if (null !== $prior) {
        if ($prior['construct'] === ($factory['construct'] ?? null) &&
            $prior['config'] === ($factory['config'] ?? null)) {
            return $prior;
        }
        throw new StationError('station_factory_conflict',
            'two different factories registered for api "' . $slug . '"; a ' .
            'process has one build of an SDK, and picking between two ' .
            'silently is not a thing to do quietly');
    }

    // AT PROVIDE TIME, which is the whole point of carrying `config`.
    $normalized = normalize_descriptor($factory['config'] ?? null, null);
    $entry = [
        'api' => $slug,
        'construct' => $factory['construct'] ?? null,
        'config' => $factory['config'] ?? null,
        'descriptor' => $normalized['descriptor'],
        'warnings' => $normalized['warnings'],
    ];
    FactoryTable::$table[$slug] = $entry;
    return $entry;
}

/** @return array<string, mixed>|null */
function factory_for(mixed $api): ?array
{
    return FactoryTable::$table[(string) $api] ?? null;
}

/** @return array<int, string> */
function provided(): array
{
    $keys = array_map('strval', array_keys(FactoryTable::$table));
    sort($keys, SORT_STRING);
    return $keys;
}

/**
 * Test seam. The table is process-global by design, so a suite that
 * registers factories has to be able to put the process back.
 */
function reset_factories(): void
{
    FactoryTable::$table = [];
}
