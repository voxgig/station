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
use function Voxgig\Station\camelify;
use function Voxgig\Station\canonical_serialize;
use function Voxgig\Station\check_features;
use function Voxgig\Station\check_package;
use function Voxgig\Station\check_pin;
use function Voxgig\Station\config_scope;
use function Voxgig\Station\config_shape;
use function Voxgig\Station\envtoken;
use function Voxgig\Station\factory_for;
use function Voxgig\Station\factory_from_module;
use function Voxgig\Station\feature_sources;
use function Voxgig\Station\instance_ref;
use function Voxgig\Station\known_code;
use function Voxgig\Station\merge_features;
use function Voxgig\Station\normalize_config;
use function Voxgig\Station\normalize_descriptor;
use function Voxgig\Station\placeholder_for;
use function Voxgig\Station\provide;
use function Voxgig\Station\provided;
use function Voxgig\Station\reset_factories;
use function Voxgig\Station\resolve_order;
use function Voxgig\Station\resolve_profile;
use function Voxgig\Station\secretname_default;
use function Voxgig\Station\select_profile;
use function Voxgig\Station\validate_config;

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
    reset_factories();
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
        reset_factories();
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

/**
 * ONE DRIVER PER SECTION THIS PORT RUNS, keyed by the corpus section
 * name - the tests below are REGISTERED FROM THIS TABLE, so a section
 * listed here cannot silently not run, and `sections-covered` closes the
 * other direction.
 *
 * @var array<string, callable>
 */
$DRIVERS = [
    'secretname' => function ($vin) {
        $secretname = secretname_default($vin['slug']);
        return [
            'envtoken' => envtoken($vin['slug']),
            'secretname' => $secretname,
            'envkey' => \Voxgig\Sekreto\Name::envkey($secretname),
        ];
    },

    'placeholder' => fn($slug) => placeholder_for($slug),

    'descriptor' => fn($vin) => normalize_descriptor(denull($vin['config']),
        denull($vin['feature'] ?? null))['descriptor'],

    'descriptorwarnings' => fn($vin) => count(normalize_descriptor(
        denull($vin['config']), denull($vin['feature'] ?? null))['warnings']),

    'canonical' => fn($vin) => canonical_serialize(denull($vin)),

    // Normalize, then validate (design 4.2). The entry is a RAW config
    // in, and either the normalized output or the expected error out -
    // the two steps are one pipeline and a port that splits them is free
    // to validate the wrong form.
    'config' => fn($vin) => validate_config(normalize_config(denull($vin))),

    // The 3.3 merge, and the whole of this port's profile contract.
    'instance' => fn($vin) => resolve_profile(denull($vin['config']), $vin['profile']),

    // Design 8's pure half (10.1): the three-level merge with its depth
    // boundary, and the 8.4 order resolution. ONE driver, TWO entry
    // shapes - `merged` selects the resolver, anything else the merge -
    // because a port that guessed from looser cues would run the wrong
    // subject on a mistyped entry.
    'feature' => function ($vin) {
        if (null !== ($vin['merged'] ?? null)) {
            $ordered = resolve_order(denull($vin['merged']));
            check_pin($ordered);
            return array_map(fn($o) => $o['name'], $ordered);
        }
        return merge_features(feature_sources(
            denull($vin['base'] ?? null), denull($vin['overlay'] ?? null),
            $vin['api'] ?? null, $vin['ref'] ?? null));
    },

    // Design 6.1's `as` rule: pure over (api, opts), so it is
    // corpus-shaped rather than driver-shaped even though it decides a
    // registry key.
    'instanceref' => fn($vin) => instance_ref($vin['api'],
        denull($vin['opts'] ?? null)),

    'errors' => fn($code) => known_code($code),
];

/**
 * The sections this port deliberately does NOT run, with the reason - an
 * entry here is a DECISION, not an omission.
 *
 * @var array<string, string>
 */
$PENDING = [
    // Pins the pre-Stage-1 `plugin` grammar, which this port no longer
    // speaks. It stays in the corpus for the ports that have not crossed
    // the rename yet and is deleted when the last one does - see
    // spec/README.md. Everything it pins is restated in the sdk/api
    // grammar the `instance` section runs.
    'profile' => 'pre-rename plugin grammar; superseded by the instance section',
];

/**
 * Section completeness: the sections RUN plus the explicit PENDING list
 * must exactly cover what spec/station.json carries. A section added to
 * the corpus and not picked up here fails loudly instead of silently not
 * running; a section removed or renamed while this port still lists it
 * fails too, so a stale driver or a stale pin is caught rather than
 * rotting.
 *
 * Reads the corpus file DIRECTLY as raw JSON - not through the omni
 * runner, which resolves and normalizes a named section and would hide
 * one it never resolved.
 */
testcase('sections-covered', function () use ($DRIVERS, $PENDING) {
    $raw = json_decode(file_get_contents(specfile('station.json')) ?: '',
        true, 512, JSON_THROW_ON_ERROR);
    $present = array_map('strval', array_keys($raw['primary']['station']));
    sort($present, SORT_STRING);
    $covered = array_map('strval',
        array_merge(array_keys($DRIVERS), array_keys($PENDING)));
    sort($covered, SORT_STRING);
    eq($present, $covered, 'corpus sections run or pinned pending');
});

// The per-section tests are REGISTERED BY ITERATING $DRIVERS, never
// written out by hand: a section in the table either has a test that
// runs or is not in the table at all, and the guard above catches that.
foreach ($DRIVERS as $section => $driver) {
    testcase($section, function () use ($spec, $runset, $section, $driver) {
        ok(null !== ($spec[$section] ?? null), 'corpus section missing: ' . $section);
        $runset($spec[$section], $driver);
    });
}

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
        'profiles' => ['default' => ['sdk' => ['typo-slug' => ['base' => 'http://x']]]],
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
            'sdk' => ['gnarly-pets' => ['base' => 'http://profile:9']],
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
        'profiles' => ['default' => ['sdk' => [
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
        'profiles' => ['default' => ['sdk' => [
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

// =====================================================================
// Unit: the declarative front door (station.md 4, 6, 8)
// =====================================================================

/**
 * A miniature GENERATED SDK, for the declarative path: its constructor
 * takes the options map station builds and inits the features it was
 * handed, which is the whole of what feature_binding needs.
 */
#[\AllowDynamicProperties]
class FakeSDK
{
    public FakeClient $client;
    public FakeUtility $utility;
    public FakeCtx $ctx;
    public array $options;

    public function __construct(array $options)
    {
        $this->options = $options;
        $opts = $options;
        $opts['apikey'] = $options['apikey'] ?? '';
        $opts['base'] = $options['base'] ?? 'http://solar:1';

        $this->client = new FakeClient();
        $this->client->options = $opts;
        $this->utility = new FakeUtility();
        $this->utility->fetcher = fn($_c, $_u, $_d) => [okres(), null];
        $this->ctx = new FakeCtx($this->client, $this->utility, $opts, SDKCONFIG);

        foreach (($options['extend'] ?? []) as $f) {
            $this->client->features[] = $f;
        }
        $fopts = is_array($options['feature']['station'] ?? null)
            ? $options['feature']['station'] : [];
        foreach ($this->client->features as $f) {
            if (is_object($f) && method_exists($f, 'init')) {
                $f->init($this->ctx, $fopts);
            }
        }
    }
}

const SDKCONFIG = [
    'main' => ['name' => 'Solar', 'slug' => 'solar',
        'version' => '1.0.0', 'target' => 'php'],
    'feature' => [
        'retry' => ['options' => ['retries' => 3, 'wait' => 100]],
        'test' => [],
    ],
    'options' => ['base' => 'http://solar:1', 'auth' => ['prefix' => 'Bearer']],
    'entity' => [],
];

/** @return array<string, mixed> */
function solarfactory(): array
{
    return [
        'construct' => fn(array $options) => new FakeSDK($options),
        'config' => SDKCONFIG,
    ];
}

// --- the factory table (station.md 6.2) ---

testcase('provide_is_idempotent_and_a_different_pair_conflicts', function () {
    $f = solarfactory();
    $entry = provide('solar', $f);
    eq('solar', $entry['api']);
    eq('solar', $entry['descriptor']['slug']);
    // The SAME pair twice is ordinary - self-registration plus an
    // explicit provide() for one api.
    ok($entry === provide('solar', $f), 'same pair is a no-op');
    eq(['solar'], provided());

    raises(fn() => provide('solar', solarfactory()), 'station_factory_conflict');
});

// --- the loader's rules (station.md 6.3) ---

testcase('check_package_takes_module_names_only', function () {
    eq('acme/solar-sdk', check_package('solar', 'acme/solar-sdk'));
    foreach (['', './local', '/abs/path', '~/home', 'https://x/y',
        'pkg\\win', 'pkg/../../escape', '../up'] as $bad) {
        raises(fn() => check_package('solar', $bad), 'station_sdk_load');
    }
    // The traversal SEGMENT is not implied by the leading checks.
    eq('StripeEu', camelify('stripe-eu'));
    eq('VoxgigSolardemo', camelify('voxgig_solardemo'));
});

testcase('factory_from_module_needs_a_constructor_and_a_config', function () {
    $e = raises(fn() => factory_from_module('solar', []), 'station_sdk_load');
    ok(str_contains($e->getMessage(), 'tried [SDK, SolarSDK]'), $e->getMessage());

    $e2 = raises(fn() => factory_from_module('solar', ['SDK' => FakeSDK::class]),
        'station_sdk_load');
    ok(str_contains($e2->getMessage(), '`config` singleton'), $e2->getMessage());

    $f = factory_from_module('solar',
        ['SDK' => FakeSDK::class, 'config' => SDKCONFIG]);
    eq(SDKCONFIG, $f['config']);
    ok(($f['construct'])(['feature' => []]) instanceof FakeSDK);
});

// --- sdk()/create() (station.md 6.1, 6.5) ---

/** @return array<string, mixed> */
function solarconfig(array $sdk = ['solar' => []], array $extra = []): array
{
    return array_merge([
        'station' => 1,
        'profiles' => ['default' => ['sdk' => $sdk]],
    ], $extra);
}

testcase('sdk_caches_and_create_takes_the_next_free_tag', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig()]);

    $a = $st->sdk('solar');
    ok($a === $st->sdk('solar'), 'sdk() caches by name');
    eq(1, count($st->plugins()));
    eq('solar', $st->plugins()[0]['name']);
    eq('solar.apikey', $st->plugins()[0]['secretname']);

    // create() is UNCACHED and registers under an auto-assigned tag.
    $b = $st->create('solar');
    ok($a !== $b, 'create() is uncached');
    eq(2, count($st->plugins()));
    eq('solar$1', $st->plugins()[1]['name']);
    eq('solar', $st->plugins()[1]['api']);
    // The secret name follows the DECLARED instance, not the tag.
    eq('solar.apikey', $st->plugins()[1]['secretname']);
    eq('solar', $st->declared_ref('solar$1'));
});

testcase('autotag_skips_a_declared_tag', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig(
        ['solar' => [], 'solar$1' => []])]);
    // `solar$1` is DECLARED but not live; declaration reserves it.
    eq('solar$2', $st->autotag('solar'));
});

testcase('an_autotagged_client_keeps_the_declared_policy', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig(['solar$eu' => [
        'policy' => ['hosts' => ['eu.solar.example']],
    ]])]);
    $client = $st->create('solar$eu');
    ok($client instanceof FakeSDK);
    // THE ALIAS IS RECORDED, NOT THE FIELDS: block_for('solar$1') has to
    // reach the declared instance's own hosts allowlist.
    eq('solar$eu', $st->declared_ref('solar$1'));
    eq(['eu.solar.example'], $st->block_for('solar$1')['policy']['hosts']);
});

testcase('availability_errors_are_fatal_at_first_use', function () {
    $st = new Station(['config' => solarconfig(
        ['solar' => [], 'dim' => ['active' => false]])]);

    $e = raises(fn() => $st->sdk('nope'), 'station_no_instance');
    ok(str_contains($e->getMessage(), 'declared: [dim, solar]'), $e->getMessage());

    raises(fn() => $st->sdk('dim'), 'station_instance_inactive');

    // No factory, and the message names the remedies this port offers.
    $e2 = raises(fn() => $st->sdk('solar'), 'station_no_factory');
    ok(str_contains($e2->getMessage(), 'Station::provide("solar"'), $e2->getMessage());
    ok(str_contains($e2->getMessage(), 'api.solar.package'), $e2->getMessage());
});

testcase('package_is_ignored_outside_the_repo_review_boundary', function () {
    $st = new Station([
        'config' => solarconfig(['solar' => ['package' => 'acme/solar-sdk']]),
        'repo_scoped' => false,
    ]);
    // EXPLICIT WINS over the in-code-config inference.
    eq(false, $st->repo_scoped);
    eq(null, $st->loader_package('solar', $st->block_for('solar')));
    $warns = array_values(array_filter($st->events(), fn($e) =>
        str_contains((string) ($e['meta']['warn'] ?? ''), 'user-level station.json')));
    eq(1, count($warns));

    // ...and `load: false` disables it even inside the boundary.
    $st2 = new Station([
        'config' => solarconfig(['solar' => ['package' => 'acme/solar-sdk']]),
        'load' => false,
    ]);
    eq(true, $st2->repo_scoped);
    eq(null, $st2->loader_package('solar', $st2->block_for('solar')));
    $st2->load();
});

// --- features (station.md 8.5, 8.7) ---

testcase('features_of_merges_three_levels_with_provenance', function () {
    $config = [
        'station' => 1,
        'profiles' => [
            'default' => [
                'feature' => ['retry' => ['retries' => 1, 'wait' => 5]],
                'api' => ['solar' => ['feature' => ['retry' => ['retries' => 2]]]],
                'sdk' => ['solar$eu' => ['feature' => ['retry' => ['retries' => 3]]]],
            ],
            'prod' => ['feature' => ['retry' => ['wait' => 9]]],
        ],
    ];
    $st = new Station(['config' => $config, 'profile' => 'prod']);
    $out = $st->features_of('solar$eu');
    eq(['retries' => 3, 'wait' => 9], $out['merged']['retry']);
    eq('default.sdk', $out['from']['retry']['retries']);
    eq('prod.feature', $out['from']['retry']['wait']);
    // The implicit `station` row is ORDERING ONLY: it is in `ordered`
    // and never in `merged`.
    eq(['retry', 'station'], $out['ordered']);
    ok(!array_key_exists('station', $out['merged']), 'station is not merged');
});

testcase('policy_budget_composes_into_the_ratelimit_feature', function () {
    $st = new Station(['config' => solarconfig(['solar' => [
        'policy' => ['budget' => ['concurrency' => 2, 'rps' => 5]],
        'feature' => ['ratelimit' => ['burstiness' => 7]],
    ]])]);
    $out = $st->features_of('solar');
    eq(['burstiness' => 7, 'active' => true, 'rate' => 5, 'burst' => 2],
        $out['merged']['ratelimit']);
    eq('policy.budget', $out['from']['ratelimit']['rate']);
    eq('default.sdk', $out['from']['ratelimit']['burstiness']);
});

testcase('the_fleet_view_filters_rows_and_narrows_them', function () {
    $st = new Station(['config' => solarconfig([
        'solar' => ['feature' => ['debug' => ['level' => 1]]],
        'lunar' => ['feature' => ['retry' => ['retries' => 2]]],
    ])]);
    eq(2, count($st->features()));
    eq(1, count($st->features('solar')));
    // A `feature` filter narrows the ROWS, not the instances.
    $rows = $st->features(['feature' => 'debug']);
    eq(1, count($rows));
    eq('solar', $rows[0]['instance']);
    eq(['debug'], $rows[0]['ordered']);
    eq(['debug' => ['level' => 1]], $rows[0]['merged']);
});

testcase('an_unknown_feature_option_fails_at_build_not_silently', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig(['solar' => [
        'feature' => ['retry' => ['retires' => 5]],
    ]])]);
    $e = raises(fn() => $st->sdk('solar'), 'station_feature_option');
    ok(str_contains($e->getMessage(), 'declares no option "retires"'), $e->getMessage());

    // ...and check() reports it WITHOUT constructing anything.
    $res = $st->check();
    eq([], $res['ok']);
    eq('solar', $res['failed'][0]['name']);
    eq('station_feature_option', $res['failed'][0]['code']);
});

testcase('check_constructs_every_active_instance', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig(
        ['solar' => [], 'solar$eu' => [], 'solar$off' => ['active' => false]])]);
    $res = $st->check();
    eq(['solar', 'solar$eu'], $res['ok']);
    eq([], $res['failed']);

    $rows = $st->instances();
    eq(['solar', 'solar$eu', 'solar$off'], array_map(fn($r) => $r['name'], $rows));
    eq([true, true, false], array_map(fn($r) => $r['active'], $rows));
    eq([true, true, false], array_map(fn($r) => $r['live'], $rows));
});

testcase('feature_kind_and_unknown_name_are_both_faults', function () {
    $descriptor = normalize_descriptor(SDKCONFIG, null)['descriptor'];
    $faults = check_features([
        'ghost' => [],
        'retry' => ['retries' => 'three'],
    ], $descriptor);
    eq(2, count($faults));
    eq('station_feature_unknown', $faults[0]['code']);
    ok(str_contains($faults[0]['message'], 'it declares [retry, test]'),
        $faults[0]['message']);
    eq('station_feature_option', $faults[1]['code']);
    ok(str_contains($faults[1]['message'], 'expects number, but found string'),
        $faults[1]['message']);
});

// --- secrets (station.md 5.3, 5.5) ---

testcase('warm_is_registry_or_declaration_and_nothing_else', function () {
    putenv('SOLAR_SHARED_APIKEY=v-1');
    try {
        provide('solar', solarfactory());
        // An api-level `secret` is the shared-key case: both instances
        // resolve to ONE name, so the plan deduplicates to one lookup.
        $st = new Station(['config' => [
            'station' => 1,
            'profiles' => ['default' => [
                'api' => ['solar' => ['secret' => 'solar_shared.apikey']],
                'sdk' => ['solar' => [], 'solar$eu' => [], 'lunar' => []],
            ]],
        ]]);
        eq('solar_shared.apikey', $st->block_for('solar$eu')['secret']);
        $out = $st->warm();
        eq(['solar', 'solar$eu'], $out['warmed']);
        // `lunar` derives lunar.apikey, which no store has.
        eq(['lunar'], $out['missed']);

        // A NAME NOBODY DECLARED IS A MISS, never a lookup.
        eq(['warmed' => [], 'missed' => ['solar$prodd']],
            $st->warm(['solar$prodd']));
    } finally {
        putenv('SOLAR_SHARED_APIKEY');
    }
});

testcase('two_instances_of_one_api_get_distinct_placeholders', function () {
    provide('solar', solarfactory());
    $st = new Station(['config' => solarconfig(['solar' => [], 'solar$eu' => []])]);
    $st->sdk('solar');
    $st->sdk('solar$eu');
    eq('[station:solar]', $st->sdk('solar')->client->options['apikey']);
    eq('[station:solar$eu]', $st->sdk('solar$eu')->client->options['apikey']);
    // Two clients of one api is the NORMAL case; two bindings of one
    // instance is still the error it was.
    raises(fn() => $st->build('solar'), 'station_bound_twice');
});

// --- the config grammar (station.md 4) ---

testcase('a_malformed_config_fails_open_with_every_error_at_once', function () {
    $e = raises(fn() => new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['sdk' => [
            'a' => ['bass' => 1], 'b' => ['tuba' => 2],
        ]]],
    ]]), 'station_config_invalid');
    ok(str_contains($e->getMessage(), 'sdk.a: bass'), $e->getMessage());
    ok(str_contains($e->getMessage(), 'sdk.b: tuba'), $e->getMessage());
});

testcase('the_shape_file_holds_the_invariants_the_normalizer_assumes', function () {
    $shape = config_shape();
    $block = $shape['profiles']['`$CHILD`'];

    // The two block specs are IDENTICAL - one grammar, two namespaces.
    eq($block['api']['`$CHILD`'], $block['sdk']['`$CHILD`']);

    // MERGE_SENSITIVE names `active` and only `active`, every
    // merge-sensitive key has a default, and every non-container default
    // is merge-sensitive.
    eq(['active'], \Voxgig\Station\MERGE_SENSITIVE);
    $defaults = \Voxgig\Station\block_defaults();
    foreach (\Voxgig\Station\MERGE_SENSITIVE as $k) {
        ok(array_key_exists($k, $defaults), 'no default for ' . $k);
    }
    foreach ($defaults as $k => $make) {
        $v = $make();
        if (!is_array($v) && !($v instanceof \stdClass)) {
            ok(in_array($k, \Voxgig\Station\MERGE_SENSITIVE, true),
                $k . ' is a scalar default and must be merge-sensitive');
        }
    }

    // The only `$OPEN` nodes are the three feature-entry nodes: a
    // foreign grammar passes through there and nowhere else.
    $opens = [];
    $walk = function ($node, string $path) use (&$walk, &$opens): void {
        if (!is_array($node)) {
            return;
        }
        foreach ($node as $k => $v) {
            if ('`$OPEN`' === $k) {
                $opens[] = $path;
                continue;
            }
            $walk($v, '' === $path ? (string) $k : $path . '.' . $k);
        }
    };
    $walk($shape, '');
    sort($opens, SORT_STRING);
    eq([
        'profiles.`$CHILD`.api.`$CHILD`.feature.`$CHILD`',
        'profiles.`$CHILD`.feature.`$CHILD`',
        'profiles.`$CHILD`.sdk.`$CHILD`.feature.`$CHILD`',
    ], $opens);
});

testcase('config_scope_reads_the_repo_review_boundary', function () {
    $dir = sys_get_temp_dir() . '/station-scope-' . getmypid();
    @mkdir($dir, 0777, true);
    try {
        eq('none', config_scope($dir));
        file_put_contents($dir . '/station.json', '{"station":1}');
        eq('repo', config_scope($dir));
        eq(['station' => 1], \Voxgig\Station\load_config($dir));

        file_put_contents($dir . '/station.json', '{not json');
        $e = raises(fn() => \Voxgig\Station\load_config($dir), 'station_config_invalid');
        ok(str_contains($e->getMessage(), 'is not valid JSON'), $e->getMessage());
    } finally {
        @unlink($dir . '/station.json');
        @rmdir($dir);
    }
});

testcase('options_takes_an_optional_leading_instance_name', function () {
    $st = new Station(['config' => null]);
    // Every existing options([...]) call is unchanged...
    $plain = $st->options(['base' => 'http://x']);
    eq('http://x', $plain['base']);
    ok(!array_key_exists('instance', $plain['feature']['station']));
    // ...and the leading name says which instance is being built.
    $named = $st->options('solar$eu', ['base' => 'http://x']);
    eq('solar$eu', $named['feature']['station']['instance']);
    eq('http://x', $named['feature']['station']['calleropts']['base']);
});

echo "\npass: $pass, fail: $fail\n";
exit(0 < $fail ? 1 : 0);
