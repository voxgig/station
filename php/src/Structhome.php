<?php

/**
 * Locate and load the voxgig/struct PHP port, which backs
 * validate_config (design station.md 4).
 *
 * struct is not published as a composer package yet, so this port finds
 * it on disk - by STRUCT_HOME, or by looking where a sibling checkout
 * usually sits. The same convention Sekreto.php uses, and the same one
 * the conformance suite uses for voxgig/omni.
 *
 * Unlike omni this is a RUNTIME dependency: validate_config runs at
 * open(), not just under test. It is the second and last dependency the
 * station library takes (design station.md 9 sanctions it); nothing else
 * is added.
 */

declare(strict_types=1);

namespace Voxgig\Station;

function struct_home(string $marker = 'php/src/Struct.php'): string
{
    $cands = [
        getenv('STRUCT_HOME') ?: null,
        __DIR__ . '/../../../struct',
        __DIR__ . '/../../../../struct',
        '/workspace/struct',
        '/home/user/struct',
    ];

    foreach ($cands as $cand) {
        if (null !== $cand && file_exists($cand . '/' . $marker)) {
            return realpath($cand) ?: $cand;
        }
    }

    throw new \RuntimeException(
        'station: voxgig/struct (php) not found - set STRUCT_HOME'
    );
}

function struct_load(): void
{
    if (class_exists('\\Voxgig\\Struct\\Struct')) {
        return;
    }
    require_once struct_home() . '/php/src/Struct.php';
}
