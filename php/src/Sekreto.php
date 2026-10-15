<?php

/**
 * Locate and load the voxgig/sekreto PHP port - the ONE dependency the
 * station library takes (design station.md 5, 10). sekreto/php ships as
 * "require_once and nothing else" (no Composer package yet), so station
 * carries the lookup: an already-loaded class wins, then SEKRETO_HOME,
 * then the usual sibling-checkout locations. When sekreto is published
 * as a composer package this file becomes a no-op behind class_exists.
 */

declare(strict_types=1);

namespace Voxgig\Station;

function sekreto_load(): void
{
    if (class_exists('\\Voxgig\\Sekreto\\Sekreto')) {
        return;
    }

    $cands = [
        getenv('SEKRETO_HOME') ?: null,
        __DIR__ . '/../../../sekreto',
        __DIR__ . '/../../../../sekreto',
        '/workspace/sekreto',
        '/home/user/sekreto',
    ];

    foreach ($cands as $cand) {
        if (null !== $cand && file_exists($cand . '/php/src/Sekreto.php')) {
            require_once $cand . '/php/src/Sekreto.php';
            return;
        }
    }

    throw new \RuntimeException(
        'station: voxgig/sekreto (php) not found - set SEKRETO_HOME'
    );
}

/** @return array<int, array<string, mixed>> */
function sekreto_plugins(): array
{
    sekreto_load();
    if (!function_exists('Voxgig\\Sekreto\\Plugins\\allplugins')) {
        // From the checkout the loaded core came from: each plugin file
        // requires that checkout's src/ by relative path.
        $core = (new \ReflectionClass(\Voxgig\Sekreto\Sekreto::class))->getFileName();
        require_once dirname((string) $core, 2) . '/plugins/plugins.php';
    }
    return \Voxgig\Sekreto\Plugins\allplugins();
}
