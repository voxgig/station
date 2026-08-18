<?php

/**
 * RUN: php test/run.php
 * RUN-SOME: php test/run.php secretname
 *
 * The station conformance suite plus focused unit tests. The conformance
 * half is the pure-contract part of the design's (station.md 13) corpus,
 * from spec/station.json, through voxgig/omni - the same file every port
 * runs. The unit half covers the parts the corpus cannot express without
 * an SDK: the binding (wrap position, placeholder planting, hoist), the
 * transport middleware (copy-on-inject, mock skip, status-0 mapping,
 * hosts policy, require-proxy fail-closed, secret miss), and the event
 * surface - a miniature duck-typed SDK stands in for a generated one,
 * mirroring the generated php feature-test harness idiom.
 *
 * No third-party test framework: a failing omni check throws OmniError,
 * and the assert helpers throw RuntimeException, so `make test` needs no
 * composer install (the sekreto/php harness pattern).
 */

declare(strict_types=1);

namespace Voxgig\Station\Test;

use Voxgig\Omni\Runner;
use Voxgig\Station\EventBuffer;
use Voxgig\Station\Station;
use Voxgig\Station\StationError;
use Voxgig\Station\TransportWrap;

use function Voxgig\Station\adapter_feature;
use function Voxgig\Station\canonical_serialize;
use function Voxgig\Station\envtoken;
use function Voxgig\Station\known_code;
use function Voxgig\Station\normalize_descriptor;
use function Voxgig\Station\placeholder_for;
use function Voxgig\Station\resolve_profile;
use function Voxgig\Station\secretname_default;
use function Voxgig\Station\select_profile;

require_once __DIR__ . '/../src/Station.php';

/** Find the shared spec directory by walking up from this file. */
function specfile(string $name): string
{
    $dir = __DIR__;
    for ($i = 0; $i < 8; $i++) {
        $cand = $dir . '/spec/' . $name;
        if (file_exists($cand)) {
            return $cand;
        }
        $dir = dirname($dir);
    }
    throw new \RuntimeException('station: spec not found: ' . $name);
}

/** omni is a sibling checkout, not a published package (yet). */
function omnihome(): string
{
    $cands = [
        getenv('OMNI_HOME') ?: null,
        __DIR__ . '/../../../omni',
        __DIR__ . '/../../../../omni',
        '/workspace/omni',
        '/home/user/omni',
    ];

    foreach ($cands as $cand) {
        if (null !== $cand && file_exists($cand . '/spec/fib.json')) {
            return $cand;
        }
    }

    throw new \RuntimeException('station: voxgig/omni not found - set OMNI_HOME');
}

require_once omnihome() . '/php/src/Runner.php';

$only = $argv[1] ?? null;
$pass = 0;
$fail = 0;

/** Run one named test case, reporting pass or fail. */
function testcase(string $name, callable $body): void
{
    global $only, $pass, $fail;

    if (null !== $only && $name !== $only) {
        return;
    }

    Station::reset();
    putenv('GNARLY_PETS_APIKEY');
    putenv('VOXGIG_STATION_PROFILE');

    try {
        $body();
        $pass++;
        echo "ok   - $name\n";
    } catch (\Throwable $err) {
        $fail++;
        echo "FAIL - $name\n" . $err->getMessage() . "\n";
    } finally {
        Station::reset();
        putenv('GNARLY_PETS_APIKEY');
        putenv('VOXGIG_STATION_PROFILE');
    }
}

// --- tiny assertion helpers ---

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

function raises(callable $body, string $code): StationError
{
    try {
        $body();
    } catch (StationError $e) {
        eq($code, $e->code(), 'error code');
        return $e;
    }
    throw new \RuntimeException('expected StationError ' . $code . ', none thrown');
}

/** Spec nulls arrive as omni's NULLMARK sentinel; restore them. */
function denull(mixed $val): mixed
{
    if (Runner::NULLMARK === $val) {
        return null;
    }
    if (is_array($val)) {
        $out = [];
        foreach ($val as $k => $v) {
            $out[$k] = denull($v);
        }
        return $out;
    }
    return $val;
}

// =====================================================================
// Conformance: spec/station.json through voxgig/omni (station.md 13)
// =====================================================================

// The secretname round-trip checks against sekreto's own envkey().
\Voxgig\Station\sekreto_load();

$R = (Runner::makeRunner(specfile('station.json')))('station');
$spec = $R['spec'];
$runset = $R['runset'];

testcase('secretname', fn() => $runset($spec['secretname'], function ($vin) {
    $secretname = secretname_default($vin['slug']);
    return [
        'envtoken' => envtoken($vin['slug']),
        'secretname' => $secretname,
        'envkey' => \Voxgig\Sekreto\Name::envkey($secretname),
    ];
}));

testcase('placeholder', fn() => $runset($spec['placeholder'],
    fn($slug) => placeholder_for($slug)));

testcase('descriptor', fn() => $runset($spec['descriptor'],
    fn($vin) => normalize_descriptor(denull($vin['config']),
        denull($vin['feature'] ?? null))['descriptor']));

testcase('descriptorwarnings', fn() => $runset($spec['descriptorwarnings'],
    fn($vin) => count(normalize_descriptor(denull($vin['config']),
        denull($vin['feature'] ?? null))['warnings'])));

testcase('canonical', fn() => $runset($spec['canonical'],
    fn($vin) => canonical_serialize(denull($vin))));

testcase('profile', fn() => $runset($spec['profile'],
    fn($vin) => resolve_profile(denull($vin['config']), $vin['profile'])));

testcase('errors', fn() => $runset($spec['errors'], fn($code) => known_code($code)));

// =====================================================================
// Unit: a miniature generated-SDK stand-in (station.md 3, 5.3, 6)
// =====================================================================

// The secretname corpus above already loaded sekreto (Name::envkey).

#[\AllowDynamicProperties]
class FakeUtility
{
    public mixed $fetcher = null;
}

#[\AllowDynamicProperties]
class FakeClient
{
    public string $mode = 'live';
    public array $features = [];
    public ?array $options = null;
}

class FakeOp
{
    public function __construct(public string $entity, public string $name)
    {
    }
}

class FakeResult
{
    public function __construct(public bool $ok, public mixed $err = null)
    {
    }
}

#[\AllowDynamicProperties]
class FakeCtx
{
    public array $meta = [];
    public mixed $op = null;
    public mixed $result = null;
    public mixed $entity = null;

    public function __construct(
        public mixed $client,
        public mixed $utility,
        public array $options,
        public mixed $config,
    ) {
    }
}

class FakeFeature
{
    public function __construct(public string $name)
    {
    }

    public function get_name(): string
    {
        return $this->name;
    }
}

const CONFIG = [
    'main' => ['name' => 'GnarlyPets', 'slug' => 'gnarly-pets',
        'version' => '0.0.1', 'target' => 'php'],
    'feature' => ['test' => []],
    'options' => [
        'base' => 'http://localhost:8903',
        'auth' => ['prefix' => 'Bearer'],
        'entity' => ['pet' => []],
    ],
    'entity' => [],
];

const PLACEHOLDER = '[station:gnarly-pets]';

/**
 * Build a bound miniature client: station feature first (bare SDK), a
 * stub inner transport, and the station wrap installed by
 * feature_binding.
 *
 * @return array{client: FakeClient, utility: FakeUtility, ctx: FakeCtx, feature: object, options: array<string,mixed>}
 */
function bind(Station $station, callable $inner, array $opts = []): array
{
    $client = new FakeClient();
    $utility = new FakeUtility();
    $utility->fetcher = $inner;

    $options = [
        'apikey' => $opts['apikey'] ?? '',
        'base' => 'http://localhost:8903',
        'feature' => ['station' => ['active' => true]],
    ];
    $client->options = $options;

    $ctx = new FakeCtx($client, $utility, $options, $opts['config'] ?? CONFIG);

    $feature = adapter_feature($station, $opts['calleropts'] ?? []);
    foreach ($opts['pre_features'] ?? [] as $f) {
        $client->features[] = $f;
    }
    $client->features[] = $feature;
    foreach ($opts['post_features'] ?? [] as $f) {
        $client->features[] = $f;
    }

    $fopts = array_merge($options['feature']['station'],
        ['station' => $station, 'calleropts' => $opts['calleropts'] ?? []]);
    $feature->init($ctx, $fopts);

    return ['client' => $client, 'utility' => $utility, 'ctx' => $ctx,
        'feature' => $feature, 'options' => $options];
}

/** @return array<string, mixed> */
function okres(int $status = 200, array $headers = []): array
{
    return ['status' => $status, 'statusText' => 'OK', 'headers' => $headers,
        'json' => fn() => null, 'body' => ''];
}

// --- ambient instance (station.md 10.2) ---

testcase('open_is_idempotent_and_conflicts_error', function () {
    $a = Station::open(['config' => null]);
    $b = Station::open(['config' => null]);
    ok($a === $b, 'same ambient instance');
    raises(fn() => Station::open(['config' => null, 'profile' => 'prod']),
        'station_open_conflict');
    ok($a === Station::current());
    Station::reset();
    eq(null, Station::current());
});

testcase('close_resets_ambient_and_warns_unmatched_plugin_keys', function () {
    $st = Station::open(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['plugin' => ['typo-slug' => ['base' => 'http://x']]]],
    ]]);
    $st->close();
    $warns = array_values(array_filter($st->events(), fn($e) =>
        'station' === $e['kind'] &&
        str_contains((string) ($e['meta']['warn'] ?? ''), 'typo-slug')));
    eq(1, count($warns));
    eq(null, Station::current());
});

// --- binding (station.md 3) ---

testcase('binding_plants_placeholder_and_registers', function () {
    putenv('GNARLY_PETS_APIKEY=k-123');
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);

    eq(PLACEHOLDER, $b['client']->options['apikey']);
    eq(PLACEHOLDER, $b['ctx']->options['apikey']);
    eq(1, count($st->plugins()));
    eq('gnarly-pets', $st->plugins()[0]['slug']);
    eq('R1', $st->plugins()[0]['rung']);
    $construct = array_values(array_filter($st->events(),
        fn($e) => 'construct' === $e['kind']));
    eq(1, count($construct));
    eq('php', $st->descriptor_of('gnarly-pets')['target']);
});

testcase('binding_hoists_a_resident_credential', function () {
    $st = new Station(['config' => null]);
    $seen = null;
    $b = bind($st, function ($_c, $_u, $d) use (&$seen) {
        $seen = $d['headers']['authorization'];
        return [okres(), null];
    }, ['apikey' => 'resident-1']);

    eq(PLACEHOLDER, $b['client']->options['apikey']);
    $warns = array_values(array_filter($st->events(), fn($e) =>
        'station' === $e['kind'] &&
        str_contains((string) ($e['meta']['warn'] ?? ''), 'hoisted')));
    eq(1, count($warns));

    // The hoisted value is injected on the wire without any store.
    [$res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => ['authorization' => 'Bearer ' . PLACEHOLDER]]);
    eq(null, $err);
    eq(200, $res['status']);
    eq('Bearer resident-1', $seen);
    // ...and the scrub covers it, whatever its length (no 4-char floor).
    eq('[redacted]', $st->redact('resident-1'));
});

testcase('wrap_order_guard_trips_when_a_wrapper_precedes', function () {
    $st = new Station(['config' => null]);
    raises(fn() => bind($st, fn($_c, $_u, $_d) => [okres(), null],
        ['pre_features' => [new FakeFeature('retry')]]),
        'station_wrap_order');
});

testcase('second_bind_of_same_client_is_inert', function () {
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);

    // Same client, second arrival (generated feature + carried adapter):
    // must no-op, not raise, and not double-wrap.
    $second = adapter_feature($st, []);
    $b['client']->features[] = $second;
    $fopts = array_merge($b['options']['feature']['station'],
        ['station' => $st, 'calleropts' => []]);
    $second->init($b['ctx'], $fopts);

    eq(1, count($st->plugins()));
    ok($b['utility']->fetcher instanceof TransportWrap, 'single wrap marker');
});

testcase('binding_a_second_client_of_same_slug_errors', function () {
    $st = new Station(['config' => null]);
    bind($st, fn($_c, $_u, $_d) => [okres(), null]);
    raises(fn() => bind($st, fn($_c, $_u, $_d) => [okres(), null]),
        'station_bound_twice');
});

testcase('profile_base_applied_unless_caller_base_wins', function () {
    $config = [
        'station' => 1,
        'profiles' => ['default' => [
            'plugin' => ['gnarly-pets' => ['base' => 'http://profile:9']],
        ]],
    ];
    $st = new Station(['config' => $config]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null], ['calleropts' => []]);
    eq('http://profile:9', $b['client']->options['base']);

    $st2 = new Station(['config' => $config]);
    $b2 = bind($st2, fn($_c, $_u, $_d) => [okres(), null],
        ['calleropts' => ['base' => 'http://caller:7']]);
    eq('http://localhost:8903', $b2['client']->options['base']);
});

// --- the transport middleware (station.md 3.3, 5.3) ---

testcase('inject_copy_on_inject', function () {
    putenv('GNARLY_PETS_APIKEY=wire-key-9');
    $st = new Station(['config' => null]);
    $seen = null;
    $b = bind($st, function ($_c, $_u, $d) use (&$seen) {
        $seen = $d;
        return [okres(200, ['content-length' => '12']), null];
    });

    $fetchdef = ['method' => 'GET',
        'headers' => ['authorization' => 'Bearer ' . PLACEHOLDER]];
    $b['feature']->PrePoint($b['ctx']);
    [$res, $err] = ($b['utility']->fetcher)($b['ctx'],
        'http://localhost:8903/api/pet', $fetchdef);

    eq(null, $err);
    eq(200, $res['status']);
    // The wire got the real value...
    eq('Bearer wire-key-9', $seen['headers']['authorization']);
    // ...and the caller-visible fetchdef still holds the placeholder
    // (copy-on-inject: ctrl.explain / ctx.spec share that array's value).
    eq('Bearer ' . PLACEHOLDER, $fetchdef['headers']['authorization']);

    // The http event is wire truth, correlated with the op.
    $b['ctx']->op = new FakeOp('pet', 'list');
    $b['ctx']->result = new FakeResult(true);
    $b['feature']->PreDone($b['ctx']);

    $http = array_values(array_filter($st->events(), fn($e) => 'http' === $e['kind']));
    $op = array_values(array_filter($st->events(), fn($e) => 'op' === $e['kind']));
    eq(1, count($http));
    eq(1, count($op));
    eq($http[0]['corr'], $op[0]['corr']);
    ok(null !== $http[0]['corr']);
    eq(200, $http[0]['http']['status']);
    eq(12, $http[0]['http']['bytes']);
    eq('localhost:8903', $http[0]['http']['host']);
    eq('/api/pet', $http[0]['http']['path']);
    eq('pet', $op[0]['op']['entity']);
    eq('list', $op[0]['op']['op']);
    eq('ok', $op[0]['op']['outcome']);
    // No credential anywhere in the event stream.
    ok(!str_contains(json_encode($st->events()) ?: '', 'wire-key-9'));
});

testcase('no_injection_into_mock_transports', function () {
    putenv('GNARLY_PETS_APIKEY=never-on-mock');
    $st = new Station(['config' => null]);
    $seen = null;
    $b = bind($st, function ($_c, $_u, $d) use (&$seen) {
        $seen = $d['headers']['authorization'];
        return [okres(), null];
    });

    $b['client']->mode = 'test';
    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => ['authorization' => 'Bearer ' . PLACEHOLDER]]);
    eq(null, $err);
    // Placeholder rides through untouched; the http event still records
    // the mock attempt.
    eq('Bearer ' . PLACEHOLDER, $seen);
    eq(1, count(array_filter($st->events(), fn($e) => 'http' === $e['kind'])));
});

testcase('status_0_is_a_transport_failure', function () {
    putenv('GNARLY_PETS_APIKEY=status-zero-key');
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [
        ['status' => 0, 'statusText' => 'stream failure: boom',
            'headers' => [], 'json' => fn() => null, 'body' => ''],
        null,
    ]);

    [$res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    eq(null, $err);
    eq(0, $res['status']);

    $http = array_values(array_filter($st->events(), fn($e) => 'http' === $e['kind']));
    $errs = array_values(array_filter($st->events(), fn($e) => 'error' === $e['kind']));
    eq(1, count($http));
    eq(0, $http[0]['http']['status']);
    eq(1, count($errs));
    ok(str_contains($errs[0]['err']['message'], 'stream failure'));
});

testcase('hosts_policy_denies_off_list_egress', function () {
    putenv('GNARLY_PETS_APIKEY=k');
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['plugin' => [
            'gnarly-pets' => ['policy' => ['hosts' => ['api.other.example']]],
        ]]],
    ]]);
    $called = false;
    $b = bind($st, function ($_c, $_u, $_d) use (&$called) {
        $called = true;
        return [okres(), null];
    });

    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    ok(!$called, 'inner transport never called');
    eq('station_host_allow', $err->code());
    $errs = array_values(array_filter($st->events(), fn($e) => 'error' === $e['kind']));
    eq('station_host_allow', $errs[0]['err']['code']);
});

testcase('hosts_policy_marks_redirects_manual', function () {
    putenv('GNARLY_PETS_APIKEY=k');
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['plugin' => [
            'gnarly-pets' => ['policy' => ['hosts' => ['localhost']]],
        ]]],
    ]]);
    $seen = null;
    $b = bind($st, function ($_c, $_u, $d) use (&$seen) {
        $seen = $d;
        return [okres(), null];
    });

    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    eq(null, $err);
    // A 3xx must ride back like any other response (station.md 8.2's
    // rule at the library seam): the fetcher is told not to follow.
    eq('manual', $seen['redirect'] ?? null);
});

testcase('require_proxy_fails_on_the_operation_path', function () {
    putenv('GNARLY_PETS_APIKEY=k');
    $st = new Station(['config' => null, 'proxy' => 'require']);
    // Construction succeeds (non-blocking open, station.md 2.1)...
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);
    // ...and every operation fails closed.
    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    eq('station_no_proxy', $err->code());
});

testcase('missing_secret_is_no_value_on_the_op_path', function () {
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);

    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => ['authorization' => PLACEHOLDER]]);
    eq('station_secret_no_value', $err->code());
    $errs = array_values(array_filter($st->events(), fn($e) => 'error' === $e['kind']));
    eq(1, count($errs));
    eq('station_secret_no_value', $errs[0]['err']['code']);
});

testcase('secret_option_overrides_the_default_name', function () {
    putenv('CUSTOM_TOKEN=custom-9');
    try {
        $st = new Station(['config' => null]);
        $client = new FakeClient();
        $utility = new FakeUtility();
        $seen = null;
        $utility->fetcher = function ($_c, $_u, $d) use (&$seen) {
            $seen = $d['headers']['authorization'];
            return [okres(), null];
        };
        $options = ['apikey' => '', 'base' => 'http://localhost:8903',
            'feature' => ['station' => ['active' => true, 'secret' => 'custom.token']]];
        $client->options = $options;
        $ctx = new FakeCtx($client, $utility, $options, CONFIG);
        $feature = adapter_feature($st, []);
        $client->features[] = $feature;
        $feature->init($ctx, array_merge($options['feature']['station'],
            ['station' => $st, 'calleropts' => []]));

        [$_res, $err] = ($utility->fetcher)($ctx, 'http://localhost:8903/x',
            ['method' => 'GET', 'headers' => ['authorization' => PLACEHOLDER]]);
        eq(null, $err);
        eq('custom-9', $seen);
    } finally {
        putenv('CUSTOM_TOKEN');
    }
});

// --- events (station.md 6) ---

testcase('ring_overflow_drops_oldest_and_counts', function () {
    $buffer = new EventBuffer(3);
    for ($i = 0; $i < 5; $i++) {
        $buffer->emit(['t' => $i, 'kind' => 'station']);
    }
    eq([2, 3, 4], array_map(fn($e) => $e['t'], $buffer->events()));
    eq(['buffered' => 3, 'dropped' => 2], $buffer->status());
});

testcase('tap_serializes_and_unsubscribes', function () {
    $buffer = new EventBuffer();
    $seen = [];
    $unsub = $buffer->tap(function ($ev) use (&$seen) {
        $seen[] = $ev['t'];
    });
    $raising = $buffer->tap(function ($_ev) {
        throw new \RuntimeException('tap failure never fails the op');
    });
    $buffer->emit(['t' => 1, 'kind' => 'station']);
    $unsub();
    $raising();
    $buffer->emit(['t' => 2, 'kind' => 'station']);
    eq([1], $seen);
});

// --- profile selection (station.md 3.5) ---

testcase('env_profile_selected_unless_opt_wins', function () {
    putenv('VOXGIG_STATION_PROFILE=prod');
    eq('prod', select_profile(null));
    eq('stage', select_profile('stage'));
    putenv('VOXGIG_STATION_PROFILE');
    eq('default', select_profile(null));
});

echo "\npass: $pass, fail: $fail\n";
exit(0 < $fail ? 1 : 0);
