<?php

/**
 * RUN: php test/retrofit.php
 *
 * A port of typescript/test/retrofit.test.ts, which is canonical: an SDK
 * generated without the station feature, as connect() and adopt()
 * retrofit it, against a server whose first answer is a 503.
 */

declare(strict_types=1);

namespace Voxgig\Station\Retrofit;

use Voxgig\Station\Station;

const APIKEY = 'taskpad-key-101';
const PORT = '8944';

$sdk_root = getenv('STATION_TEST_SDKS') ?: '/home/user/voxgig-sdk';
$sdk_dir = $sdk_root . '/taskpad-plain-sdk/php';
$server_js = realpath(__DIR__ . '/../../test/api/taskpad/server.js') ?: '';

if (!file_exists($sdk_dir . '/taskpad_sdk.php') || '' === $server_js) {
    if (getenv('STATION_REQUIRE_SDKS')) {
        echo "fail - STATION_REQUIRE_SDKS is set but there is no generated php SDK - run `make fixtures`\n";
        exit(1);
    }
    echo "skip - no generated php SDK without the station feature\n";
    exit(0);
}

require_once $sdk_dir . '/taskpad_sdk.php';
if (!class_exists('\\TodoEntity')) {
    foreach (glob($sdk_dir . '/entity/*.php') ?: [] as $f) {
        require_once $f;
    }
    foreach (glob($sdk_dir . '/types/*.php') ?: [] as $f) {
        require_once $f;
    }
}
require_once __DIR__ . '/../src/Station.php';

function alive(string $base): bool
{
    $ctx = stream_context_create(['http' => ['timeout' => 1, 'ignore_errors' => true]]);
    return false !== @file_get_contents($base . '/api/todo', false, $ctx);
}

$base = 'http://localhost:' . PORT;
$proc = proc_open(
    ['node', $server_js],
    [['file', '/dev/null', 'r'], ['file', '/dev/null', 'w'], ['file', '/dev/null', 'w']],
    $_pipes,
    null,
    array_merge(getenv(), ['TASKPAD_PORT' => PORT, 'TASKPAD_APIKEY' => APIKEY,
        'TASKPAD_FAIL' => '1'])
);
$up = false;
for ($i = 0; $i < 50 && !$up; $i++) {
    usleep(100000);
    $up = alive($base);
}
register_shutdown_function(function () use ($proc) {
    if (is_resource($proc)) {
        proc_terminate($proc);
        proc_close($proc);
    }
});
if (!$up) {
    echo "FAIL - taskpad server did not start\n";
    exit(1);
}

$fail = 0;
Station::reset();
putenv('TASKPAD_APIKEY=' . APIKEY);
try {
    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class,
        ['base' => $base, 'feature' => ['retry' => ['active' => true]]]);

    $names = array_values(array_filter(
        array_map(fn($f) => $f->get_name(), $pad->features),
        fn($n) => 'base' !== $n));
    if (['station', 'retry'] !== $names) {
        throw new \RuntimeException('feature order: ' . json_encode($names));
    }

    $todos = $pad->Todo()->list();
    if (!is_array($todos) || 0 === count($todos)) {
        throw new \RuntimeException('list() returned no records');
    }

    $wire = [];
    $corrs = [];
    foreach ($station->events() as $e) {
        if ('http' === $e['kind']) {
            $wire[] = ['http', $e['http']['status']];
            $corrs[$e['corr']] = true;
        } elseif ('op' === $e['kind']) {
            $wire[] = ['op', $e['op']['outcome']];
            $corrs[$e['corr']] = true;
        }
    }
    if ([['http', 503], ['http', 200], ['op', 'ok']] !== $wire || 1 !== count($corrs)) {
        throw new \RuntimeException('events: ' . json_encode($wire) . ' corr: ' .
            json_encode(array_keys($corrs)));
    }

    $station->close();
    echo "ok   - live_with_retry_station_wraps_the_wire_and_sees_each_attempt\n";
} catch (\Throwable $err) {
    $fail++;
    echo "FAIL - live_with_retry_station_wraps_the_wire_and_sees_each_attempt\n" .
        $err->getMessage() . "\n";
} finally {
    Station::reset();
    putenv('TASKPAD_APIKEY');
}

// sdkgen's ordered list form: position is init order, so station takes
// its pinned place first rather than the caller's map spread.
putenv('TASKPAD_APIKEY=' . APIKEY);
try {
    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class,
        ['base' => $base, 'feature' => [['name' => 'retry', 'active' => true]]]);

    $names = array_values(array_filter(
        array_map(fn($f) => $f->get_name(), $pad->features),
        fn($n) => 'base' !== $n));
    if (['station', 'retry'] !== $names) {
        throw new \RuntimeException('feature order: ' . json_encode($names));
    }

    $todos = $pad->Todo()->list();
    if (!is_array($todos) || 0 === count($todos)) {
        throw new \RuntimeException('list() returned no records');
    }

    $wire = [];
    foreach ($station->events() as $e) {
        if ('http' === $e['kind']) {
            $wire[] = ['http', $e['http']['status']];
        } elseif ('op' === $e['kind']) {
            $wire[] = ['op', $e['op']['outcome']];
        }
    }
    if ([['http', 200], ['op', 'ok']] !== array_slice($wire, -2)) {
        throw new \RuntimeException('events: ' . json_encode($wire));
    }

    $station->close();
    echo "ok   - the_list_form_of_options_feature_binds_with_retry_outside_station\n";
} catch (\Throwable $err) {
    $fail++;
    echo "FAIL - the_list_form_of_options_feature_binds_with_retry_outside_station\n" .
        $err->getMessage() . "\n";
} finally {
    Station::reset();
    putenv('TASKPAD_APIKEY');
}

exit(0 < $fail ? 1 : 0);
