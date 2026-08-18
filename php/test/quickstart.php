<?php

/**
 * RUN: php test/quickstart.php
 *
 * The (station.md 11) walkthroughs, run for real: the two-line quickstart
 * against a live test API, injection at the transport seam,
 * placeholder-safe options_map/prepare, and the event stream. The SDK is
 * a REAL generated SDK (taskpad, built by sdkgen from an OpenAPI spec
 * with the station feature installed) served by the taskpad test server -
 * nothing here is mocked. Mirrors typescript/test/quickstart.test.ts and
 * ruby/test/quickstart_test.rb.
 *
 * The suite runs against a generated php SDK checkout; without one
 * (STATION_TEST_PHP_SDK, or the default locations below) it skips rather
 * than fails. The SDK's composer vendor/autoload.php is used when present
 * (it resolves voxgig/station through the path-repository shim);
 * otherwise the SDK entry and this library are require'd directly.
 *
 * An already-running taskpad server is reused when TASKPAD_PORT is set
 * and answering; otherwise one is spawned on a private port.
 */

declare(strict_types=1);

namespace Voxgig\Station\Quickstart;

use Voxgig\Station\Station;

const APIKEY = 'taskpad-key-101';

$sdk_root = getenv('STATION_TEST_SDKS') ?: '/home/user/voxgig-sdk';
$sdk_dir = null;
foreach ([
    getenv('STATION_TEST_PHP_SDK') ?: null,
    $sdk_root . '/taskpad-sdk/php',
    $sdk_root . '/st-php-sdk/php',
] as $cand) {
    if (null !== $cand && file_exists($cand . '/taskpad_sdk.php')) {
        $sdk_dir = $cand;
        break;
    }
}

$server_js = realpath(__DIR__ . '/../../test/api/taskpad/server.js') ?: '';

if (null === $sdk_dir || '' === $server_js) {
    echo "skip - no generated php SDK checkout (set STATION_TEST_PHP_SDK)\n";
    exit(0);
}

// Load the SDK (and, through its vendor autoload when present, this
// library); fall back to direct require - the path-shim resolution story.
if (file_exists($sdk_dir . '/vendor/autoload.php')) {
    require_once $sdk_dir . '/vendor/autoload.php';
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
if (!class_exists('\\Voxgig\\Station\\Station')) {
    require_once __DIR__ . '/../src/Station.php';
}

// --- the taskpad server: reuse a live one, else spawn our own ---

function alive(string $base): bool
{
    $ctx = stream_context_create(['http' => ['timeout' => 1, 'ignore_errors' => true]]);
    return false !== @file_get_contents($base . '/api/todo', false, $ctx);
}

$port = getenv('TASKPAD_PORT') ?: null;
$proc = null;
if (null !== $port && alive('http://localhost:' . $port)) {
    $base = 'http://localhost:' . $port;
} else {
    // Own port: other suites may hold the SDK's default 8902.
    $port = '8933';
    $base = 'http://localhost:' . $port;
    $proc = proc_open(
        ['node', $server_js],
        [['file', '/dev/null', 'r'], ['file', '/dev/null', 'w'], ['file', '/dev/null', 'w']],
        $_pipes,
        null,
        array_merge(getenv(), ['TASKPAD_PORT' => $port, 'TASKPAD_APIKEY' => APIKEY])
    );
    $up = false;
    for ($i = 0; $i < 50 && !$up; $i++) {
        usleep(100000);
        $up = alive($base);
    }
    if (!$up) {
        echo "FAIL - taskpad server did not start\n";
        exit(1);
    }
}

register_shutdown_function(function () use ($proc) {
    if (is_resource($proc)) {
        proc_terminate($proc);
        proc_close($proc);
    }
});

const PLACEHOLDER = '[station:taskpad]';

$pass = 0;
$fail = 0;

function testcase(string $name, callable $body): void
{
    global $pass, $fail;
    Station::reset();
    putenv('TASKPAD_APIKEY');
    try {
        $body();
        $pass++;
        echo "ok   - $name\n";
    } catch (\Throwable $err) {
        $fail++;
        echo "FAIL - $name\n" . $err->getMessage() . "\n" .
            $err->getTraceAsString() . "\n";
    } finally {
        Station::reset();
        putenv('TASKPAD_APIKEY');
    }
}

function eq(mixed $want, mixed $got, string $msg = ''): void
{
    if ($want !== $got) {
        throw new \RuntimeException('eq failed' . ('' === $msg ? '' : ' (' . $msg . ')') .
            ': want=' . var_export($want, true) . ' got=' . var_export($got, true));
    }
}

function ok(mixed $cond, string $msg = ''): void
{
    if (true !== (bool) $cond) {
        throw new \RuntimeException('ok failed' . ('' === $msg ? '' : ': ' . $msg));
    }
}

// --- the walkthroughs ---

testcase('two_lines_secret_from_the_documented_env_var', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class, ['base' => $base]);

    $result = $pad->Todo()->list();
    ok(is_array($result), 'list() returns entities');
    ok(0 < count($result));

    // The op and http events correlate via corr (3, 6).
    $events = $station->events();
    $http = array_values(array_filter($events, fn($e) => 'http' === $e['kind']));
    $op = array_values(array_filter($events, fn($e) => 'op' === $e['kind']));
    eq(1, count($http));
    eq(1, count($op));
    eq($http[0]['corr'], $op[0]['corr']);
    ok(null !== $http[0]['corr']);
    eq(200, $http[0]['http']['status']);
    eq('todo', $op[0]['op']['entity']);
    eq('list', $op[0]['op']['op']);
    eq('ok', $op[0]['op']['outcome']);

    $station->close();
});

testcase('options_and_prepare_are_placeholder_safe_r1', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class, ['base' => $base]);

    // The key is out of app code's way: options_map never exposes the
    // value, prepare output is safe to hand to an agent (5.3, 11).
    eq(PLACEHOLDER, $pad->options_map()['apikey']);

    $fetchdef = $pad->prepare(['path' => '/api/todo', 'method' => 'GET']);
    ok(str_contains(json_encode($fetchdef['headers']) ?: '', PLACEHOLDER));
    ok(!str_contains(json_encode($fetchdef) ?: '', APIKEY));

    // And the wire still gets the real value.
    $result = $pad->Todo()->list();
    ok(is_array($result));

    // No credential anywhere in the event stream either.
    ok(!str_contains(json_encode($station->events()) ?: '', APIKEY));

    $station->close();
});

testcase('adopt_hoists_a_resident_credential', function () use ($base) {
    $station = Station::open(['config' => null]);
    $pad = $station->adopt(\TaskpadSDK::class, ['apikey' => APIKEY, 'base' => $base]);

    eq(PLACEHOLDER, $pad->options_map()['apikey']);

    $result = $pad->Todo()->list();
    ok(is_array($result));

    $warns = array_values(array_filter($station->events(), fn($e) =>
        'station' === $e['kind'] &&
        str_contains((string) ($e['meta']['warn'] ?? ''), 'hoisted')));
    eq(1, count($warns));

    $station->close();
});

testcase('missing_secret_is_station_secret_no_value_on_the_op_path', function () use ($base) {
    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class, ['base' => $base]);

    $thrown = null;
    try {
        $pad->Todo()->list();
    } catch (\Throwable $e) {
        $thrown = $e;
    }
    ok(null !== $thrown, 'op failed');
    ok(str_contains($thrown->getMessage(), 'station_secret_no_value'),
        'message carries the code: ' . $thrown->getMessage());

    $errs = array_values(array_filter($station->events(), fn($e) => 'error' === $e['kind']));
    eq(1, count($errs));
    eq('station_secret_no_value', $errs[0]['err']['code']);

    $station->close();
});

testcase('descriptor_carries_slug_version_target_from_the_embedded_config', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $station = Station::open(['config' => null]);
    $station->connect(\TaskpadSDK::class, ['base' => $base]);

    $d = $station->descriptor_of('taskpad');
    eq('taskpad', $d['slug']);
    eq('TASKPAD', $d['envtoken']);
    eq('php', $d['target']);
    eq('0.0.1', $d['version']);
    eq('taskpad.apikey', $d['auth']['secretname']);
    eq(['todo'], array_keys($d['entities']));
    ok(isset($d['entities']['todo']['ops']['list']));

    // The canonical form serializes (proxy dedupe input).
    ok(str_starts_with($station->canonical_descriptor('taskpad'), '{"auth":'));

    $station->close();
});

testcase('test_feature_stays_mocked_no_injection_into_mock_transports', function () {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $station = Station::open(['config' => null]);
    $pad = $station->connect(\TaskpadSDK::class, [
        'feature' => ['test' => ['active' => true,
            'entity' => ['todo' => ['t9' => ['id' => 't9', 'title' => 'mock']]]]],
    ]);

    $got = $pad->Todo()->load(['id' => 't9'])->data_get();
    eq('mock', $got['title']);

    // The http event saw the mock attempt; the placeholder was never
    // swapped (mode != live), so no real value entered the mock store.
    eq(1, count(array_filter($station->events(), fn($e) => 'http' === $e['kind'])));
    ok(!str_contains(json_encode($station->events()) ?: '', APIKEY));

    $station->close();
});

testcase('inverted_binding_new_sdk_of_station_options', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $st = Station::open(['config' => null]);

    // The generated constructor, station-built options - the primary
    // binding form for static languages (3.1), exercised here so the
    // GENERATED feature (not the carried adapter) makes the binding.
    $pad = new \TaskpadSDK($st->options(['base' => $base]));

    eq(PLACEHOLDER, $pad->options_map()['apikey']);

    $result = $pad->Todo()->list();
    ok(is_array($result));

    $http = array_values(array_filter($st->events(), fn($e) => 'http' === $e['kind']));
    $op = array_values(array_filter($st->events(), fn($e) => 'op' === $e['kind']));
    eq(1, count($http));
    eq(1, count($op));
    eq($http[0]['corr'], $op[0]['corr']);
    eq('ok', $op[0]['op']['outcome']);

    $st->close();
});

testcase('connect_on_the_regenerated_sdk_does_not_double_bind', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $st = Station::open(['config' => null]);

    // connect() activates the station entry AND rides the carried
    // adapter on extend, so this construction reaches feature_binding
    // twice - generated feature first, carried adapter second. The
    // second arrival must be inert (_bound_entry), not an error.
    $pad = $st->connect(\TaskpadSDK::class, ['base' => $base]);

    $stations = array_values(array_filter($pad->features,
        fn($f) => 'station' === $f->get_name()));
    eq(2, count($stations),
        'both the generated feature and the carried adapter are present');

    eq(1, count(array_filter($st->events(), fn($e) => 'construct' === $e['kind'])));
    eq(1, count($st->plugins()));

    $result = $pad->Todo()->list();
    ok(is_array($result));

    // One wrap, one hook bridge: no doubled events either.
    eq(1, count(array_filter($st->events(), fn($e) => 'http' === $e['kind'])));
    eq(1, count(array_filter($st->events(), fn($e) => 'op' === $e['kind'])));

    $st->close();
});

testcase('live_tap_sees_traffic', function () use ($base) {
    putenv('TASKPAD_APIKEY=' . APIKEY);

    $st = Station::open(['config' => null]);
    $pad = $st->connect(\TaskpadSDK::class, ['base' => $base]);

    $seen = [];
    $unsub = $st->tap(function ($ev) use (&$seen) {
        $seen[] = $ev['kind'];
    });
    $pad->Todo()->list();
    $unsub();

    ok(in_array('http', $seen, true));
    ok(in_array('op', $seen, true));
    eq('solo', $st->status()['mode']);
    eq([['slug' => 'taskpad', 'rung' => 'R1']], $st->status()['plugins']);

    $st->close();
});

echo "\npass: $pass, fail: $fail\n";
exit(0 < $fail ? 1 : 0);
