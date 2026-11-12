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
use Voxgig\Station\SecretBroker;
use Voxgig\Station\Station;
use Voxgig\Station\StationError;
use Voxgig\Station\TransportWrap;

use function Voxgig\Station\adapter_anchor;
use function Voxgig\Station\adapter_feature;
use function Voxgig\Station\block_of;
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
use function Voxgig\Station\instance_options;
use function Voxgig\Station\instance_ref;
use function Voxgig\Station\known_code;
use function Voxgig\Station\merge_features;
use function Voxgig\Station\normalize_config;
use function Voxgig\Station\normalize_descriptor;
use function Voxgig\Station\parse_config;
use function Voxgig\Station\placeholder_for;
use function Voxgig\Station\provide;
use function Voxgig\Station\provided;
use function Voxgig\Station\reset_factories;
use function Voxgig\Station\resolve_order;
use function Voxgig\Station\resolve_profile;
use function Voxgig\Station\secretname_default;
use function Voxgig\Station\select_profile;
use function Voxgig\Station\substitute;
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

    'substitute' => fn($vin) => substitute($vin['url'], $vin['headers'] ?? null,
        $vin['placeholder'], $vin['value']),

    'descriptor' => fn($vin) => normalize_descriptor(denull($vin['config']),
        denull($vin['feature'] ?? null))['descriptor'],

    'descriptorwarnings' => fn($vin) => count(normalize_descriptor(
        denull($vin['config']), denull($vin['feature'] ?? null))['warnings']),

    'canonical' => fn($vin) => canonical_serialize(denull($vin)),

    // Normalize, then validate (design 4.2). The entry is a RAW config
    // in, and either the normalized output or the expected error out -
    // the two steps are one pipeline and a port that splits them is free
    // to validate the wrong form.
    'config' => fn($vin) => validate_config(normalize_config(
        is_string($vin) ? parse_config($vin) : denull($vin))),

    // The 3.3 merge, and the whole of this port's profile contract. A
    // `ref` asks for the options that named instance is constructed with.
    'instance' => function ($vin) {
        $profile = resolve_profile(denull($vin['config']), $vin['profile']);
        if (null === ($vin['ref'] ?? null)) {
            return $profile;
        }
        return instance_options(block_of($profile, $vin['ref']),
            denull($vin['opts'] ?? null));
    },

    // Design 8's pure half (10.1): the three-level merge with its depth
    // boundary, the 8.4 order resolution, and the 8.5 option checker. ONE
    // driver, THREE entry shapes - `check` selects the checker, `merged`
    // the resolver, anything else the merge - because a port that guessed
    // from looser cues would run the wrong subject on a mistyped entry.
    'feature' => function ($vin) {
        if (null !== ($vin['check'] ?? null)) {
            return array_map(
                fn($f) => array_intersect_key($f, ['code' => 1, 'feature' => 1, 'key' => 1]),
                check_features(denull($vin['check']),
                    ['features' => denull($vin['features'])]));
        }
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
 * entry here is a DECISION, not an omission. EMPTY: this port runs every
 * section the corpus carries.
 *
 * @var array<string, string>
 */
$PENDING = [];

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

testcase('http_event_path_keeps_the_request_escapes', function () {
    $cases = [
        ['https://h/vault/projects%2Flaunch%20plan.md', 'h',
            '/vault/projects%2Flaunch%20plan.md'],
        ['https://h', 'h', '/'],
        ['/vault/projects%2Flaunch%20plan.md?x=1', '',
            '/vault/projects%2Flaunch%20plan.md?x=1'],
    ];
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);
    $b['client']->mode = 'test';
    foreach ($cases as [$url]) {
        ($b['utility']->fetcher)($b['ctx'], $url, ['method' => 'GET', 'headers' => []]);
    }
    $http = array_values(array_filter($st->events(), fn($e) => 'http' === $e['kind']));
    eq(array_map(fn($c) => [$c[1], $c[2]], $cases),
        array_map(fn($e) => [$e['http']['host'], $e['http']['path']], $http));
});

testcase('http_event_host_reads_as_url_host', function () {
    $cases = [
        ['https://h:443/x', 'h', '/x'],
        ['http://h:80/x', 'h', '/x'],
        ['https://h:8443/x', 'h:8443', '/x'],
        ['https://u:p@h/x', 'h', '/x'],
        ['https://u:p@ss@h/x', 'h', '/x'],
        ['http://[::1]:8080/x', '[::1]:8080', '/x'],
        ['http://[::1]/x', '[::1]', '/x'],
        ['https://H/x', 'h', '/x'],
        ['https://h:/x', 'h', '/x'],
        ['https://h:0443/x', 'h', '/x'],
        ['https://h:08443/x', 'h:8443', '/x'],
    ];
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);
    $b['client']->mode = 'test';
    foreach ($cases as [$url]) {
        ($b['utility']->fetcher)($b['ctx'], $url, ['method' => 'GET', 'headers' => []]);
    }
    $http = array_values(array_filter($st->events(), fn($e) => 'http' === $e['kind']));
    eq(array_map(fn($c) => [$c[1], $c[2]], $cases),
        array_map(fn($e) => [$e['http']['host'], $e['http']['path']], $http));
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

/** @return array{0: Station, 1: mixed, 2: bool} */
function mode_request(array $policy, string $mode = 'live'): array
{
    putenv('GNARLY_PETS_APIKEY=k');
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['sdk' => ['gnarly-pets' => ['policy' => $policy]]]],
    ]]);
    $called = false;
    $b = bind($st, function ($_c, $_u, $_d) use (&$called) {
        $called = true;
        return [okres(), null];
    });
    $b['client']->mode = $mode;
    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    return [$st, $err, $called];
}

testcase('policy_mode_block_refuses_with_its_own_code', function () {
    [$st, $err, $called] = mode_request(['mode' => 'block']);
    ok(!$called, 'inner transport never called');
    eq('station_blocked', $err?->code());
    ok(str_contains($err->getMessage(), 'mode "block"'), $err->getMessage());
    $errs = array_values(array_filter($st->events(), fn($e) => 'error' === $e['kind']));
    eq(['station_blocked'], array_map(fn($e) => $e['err']['code'], $errs));
});

testcase('policy_mode_block_wins_over_hosts_that_admit_the_host', function () {
    [$_st, $err, $called] = mode_request(['mode' => 'block', 'hosts' => ['localhost']]);
    ok(!$called, 'inner transport never called');
    eq('station_blocked', $err?->code());
});

testcase('policy_modes_that_need_a_proxy_fail_station_no_proxy', function () {
    foreach (['record', 'replay', 'mock'] as $mode) {
        [$_st, $err, $called] = mode_request(['mode' => $mode]);
        ok(!$called, $mode . ': inner transport never called');
        eq('station_no_proxy', $err?->code());
    }
});

testcase('policy_mode_live_or_absent_passes_and_only_live_is_gated', function () {
    foreach ([[['mode' => 'live'], 'live'], [['hosts' => ['localhost']], 'live'],
        [['mode' => 'block'], 'test']]
        as [$policy, $mode]) {
        [$_st, $err, $called] = mode_request($policy, $mode);
        ok(null === $err, json_encode($policy) . ' passes');
        ok($called, json_encode($policy) . ' reaches the transport');
    }
});

// An IPv6 host keeps its brackets, and neither a port nor the userinfo,
// a raw `@` in its password among it, reaches the host.
testcase('hosts_policy_compares_the_hostname_url_hostname_reads', function () {
    putenv('GNARLY_PETS_APIKEY=k');
    $cases = [
        ['[::1]', 'http://[::1]:8080/x', true],
        ['[::1]', 'http://[::2]:8080/x', false],
        ['api.test', 'https://api.test:443/x', true],
        ['api.test', 'https://evil.test:443/x', false],
        ['api.test', 'https://u:p@ss@api.test/x', true],
        ['api.test', 'https://api.test:x@evil.test/x', false],
        ['api.test', 'https://API.TEST/x', true],
        ['api.test', 'https://EVIL.TEST/x', false],
    ];
    foreach ($cases as [$host, $url, $allowed]) {
        $st = new Station(['config' => [
            'station' => 1,
            'profiles' => ['default' => ['sdk' => [
                'gnarly-pets' => ['policy' => ['hosts' => [$host]]],
            ]]],
        ]]);
        $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);
        [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], $url,
            ['method' => 'GET', 'headers' => []]);
        eq($allowed ? null : 'station_host_allow', $err?->code(), $host . ' against ' . $url);
    }
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

// sekreto keeps every kind but its built-ins behind a plugin definition, so
// this pins that the broker passes the full set. minivault reads no file
// until a lookup, so the vault need not exist.
testcase('a_profile_naming_a_plugin_kind_opens', function () {
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['secrets' => ['providers' => [
            ['kind' => 'minivault', 'passphrase' => 'p',
                'file' => sys_get_temp_dir() . '/station-absent.skmv'],
        ]]]],
    ]]);
    eq('default', $st->status()['profile']);
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

// A credential an `in: query` security scheme places in the URL.
const QUERY_URL = 'http://localhost:8903/api/pet?fields=id%2Cname&token=%5Bstation%3Agnarly-pets%5D';
const WIRE_URL = 'http://localhost:8903/api/pet?fields=id%2Cname&token=tok%21en%201';

testcase('a_query_placed_credential_reaches_the_wire_and_nothing_else', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    $st = new Station(['config' => null]);
    $seen = [];
    $b = bind($st, function ($_c, $u, $d) use (&$seen) {
        $seen[] = [$u, $d];
        return [okres(), null];
    });

    $fetchdef = ['url' => QUERY_URL, 'method' => 'GET', 'headers' => []];
    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], QUERY_URL, $fetchdef);

    eq(null, $err);
    eq(1, count($seen));
    eq(WIRE_URL, $seen[0][0]);
    eq(WIRE_URL, $seen[0][1]['url']);
    eq(QUERY_URL, $fetchdef['url'], 'the SDK fetchdef keeps the placeholder');
    $events = json_encode($st->events()) ?: '';
    ok(!str_contains($events, 'tok%21en%201'), 'no encoded value in events');
    ok(!str_contains($events, 'tok!en 1'), 'no value in events');
});

testcase('a_returned_transport_error_quoting_the_url_is_scrubbed', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $u, $_d) => [null, 'failed: GET ' . $u]);

    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], QUERY_URL,
        ['method' => 'GET', 'headers' => []]);
    ok(!str_contains($err, 'tok%21en%201'), $err);
    ok(str_contains($err, '[redacted]'), $err);
    ok(!str_contains(json_encode($st->events()) ?: '', 'tok%21en%201'));
});

testcase('a_thrown_transport_error_quoting_the_url_is_scrubbed', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    $st = new Station(['config' => null]);
    $b = bind($st, function ($_c, $u, $_d) {
        throw new \RuntimeException('failed: GET ' . $u);
    });

    $thrown = null;
    try {
        ($b['utility']->fetcher)($b['ctx'], QUERY_URL, ['method' => 'GET', 'headers' => []]);
    } catch (\RuntimeException $e) {
        $thrown = $e;
    }
    ok(null !== $thrown, 'the transport error surfaces');
    ok(!str_contains($thrown->getMessage(), 'tok%21en%201'), $thrown->getMessage());
    ok(str_contains($thrown->getMessage(), '[redacted]'), $thrown->getMessage());
});

testcase('an_error_quoting_only_the_fetchdef_url_is_scrubbed', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    $url = 'http://localhost:8903/api/pet';
    $fetchdef = ['url' => QUERY_URL, 'method' => 'GET', 'headers' => []];

    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $d) => [null, 'failed: GET ' . $d['url']]);
    [$_res, $err] = ($b['utility']->fetcher)($b['ctx'], $url, $fetchdef);
    ok(!str_contains($err, 'tok%21en%201'), $err);
    ok(str_contains($err, '[redacted]'), $err);

    $st = new Station(['config' => null]);
    $b = bind($st, function ($_c, $_u, $d) {
        throw new \RuntimeException('failed: GET ' . $d['url']);
    });
    $thrown = null;
    try {
        ($b['utility']->fetcher)($b['ctx'], $url, $fetchdef);
    } catch (\RuntimeException $e) {
        $thrown = $e;
    }
    ok(null !== $thrown, 'the transport error surfaces');
    ok(!str_contains($thrown->getMessage(), 'tok%21en%201'), $thrown->getMessage());
    ok(str_contains($thrown->getMessage(), '[redacted]'), $thrown->getMessage());
});

// A cause that keeps the URL in a property of its own.
class UrlCause extends \Exception
{
    public function __construct(public string $url)
    {
        parent::__construct('GET ' . $url);
    }
}

// The same, where the property cannot be rewritten.
class SealedCause extends \Exception
{
    public function __construct(public readonly string $url)
    {
        parent::__construct('refused');
    }
}

// Every string a printer reaches: the chain's text, and its trace arguments.
function chain_shows(\Throwable $err): string
{
    $shown = (string) $err;
    for ($link = $err; null !== $link; $link = $link->getPrevious()) {
        $trace = $link->getTrace();
        array_walk_recursive($trace, function ($v) use (&$shown) {
            $shown .= is_string($v) ? $v : '';
        });
        foreach (get_object_vars($link) as $v) {
            $shown .= is_string($v) ? $v : '';
        }
    }
    return $shown;
}

testcase('a_transport_error_cause_chain_is_scrubbed', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    // Captured arguments are what a development php.ini gives.
    $ignore = ini_set('zend.exception_ignore_args', '0');
    $send = function (callable $inner): \Throwable {
        $st = new Station(['config' => null]);
        $b = bind($st, $inner);
        try {
            ($b['utility']->fetcher)($b['ctx'], QUERY_URL, ['method' => 'GET', 'headers' => []]);
        } catch (\Throwable $e) {
            $shown = chain_shows($e);
            ok(!str_contains($shown, 'tok%21en%201'), $shown);
            ok(!str_contains($shown, 'tok!en 1'), $shown);
            return $e;
        }
        throw new \LogicException('no transport error');
    };
    try {
        $err = $send(function ($_c, $u, $_d) {
            throw new \RuntimeException('fetch failed', 0, new UrlCause($u));
        });
        ok($err->getPrevious() instanceof UrlCause, 'the cause is kept');
        ok(str_contains($err->getPrevious()->url, '[redacted]'), $err->getPrevious()->url);

        $err = $send(function ($_c, $u, $_d) {
            throw new \RuntimeException('fetch failed', 0, new SealedCause($u));
        });
        eq(null, $err->getPrevious(), 'a cause that cannot be scrubbed is cut off');

        $err = $send(function ($_c, $u, $_d) {
            throw new SealedCause($u);
        });
        ok(!($err instanceof SealedCause), 'an error that cannot be scrubbed is replaced');
    } finally {
        ini_set('zend.exception_ignore_args', (string) $ignore);
    }
});

testcase('one_failed_operation_emits_one_op_event', function () {
    $st = new Station(['config' => null]);
    $b = bind($st, fn($_c, $_u, $_d) => [okres(), null]);

    // PreDone sees the error result; the pipeline then throws it.
    $b['ctx']->op = new FakeOp('note', 'load');
    $b['ctx']->result = new FakeResult(false);
    $b['feature']->PrePoint($b['ctx']);
    $b['feature']->PreDone($b['ctx']);
    $b['feature']->PreUnexpected($b['ctx']);
    $b['feature']->PreUnexpected($b['ctx']);

    $op = array_values(array_filter($st->events(), fn($e) => 'op' === $e['kind']));
    eq(['err'], array_map(fn($e) => $e['op']['outcome'], $op));

    $unopened = clone $b['ctx'];
    $unopened->meta = [];
    $b['feature']->PreUnexpected($unopened);
    eq(1, count(array_filter($st->events(), fn($e) => 'op' === $e['kind'])),
        'an operation station never opened emits nothing');
});

testcase('a_status_0_response_after_a_placement_is_scrubbed', function () {
    putenv('GNARLY_PETS_APIKEY=tok!en 1');
    $st = new Station(['config' => null]);
    $sent = null;
    $b = bind($st, function ($_c, $u, $_d) use (&$sent) {
        $sent = ['status' => 0, 'statusText' => 'stream failure: GET ' . $u,
            'headers' => ['content-type' => 'text/plain'], 'json' => fn() => null,
            'body' => 'no answer from ' . $u,
            'err' => new \RuntimeException('failed: GET ' . $u)];
        return [$sent, null];
    });

    [$res, $err] = ($b['utility']->fetcher)($b['ctx'], QUERY_URL,
        ['method' => 'GET', 'headers' => []]);
    eq(null, $err);
    eq(0, $res['status']);
    foreach ([$res['statusText'], $res['body'], $res['err']->getMessage()] as $text) {
        ok(!str_contains($text, 'tok%21en%201'), $text);
        ok(str_contains($text, '[redacted]'), $text);
    }
    eq(['content-type' => 'text/plain'], $res['headers']);
    eq(null, ($res['json'])());

    // Nothing placed: the response comes back untouched.
    [$res, $err] = ($b['utility']->fetcher)($b['ctx'], 'http://localhost:8903/x',
        ['method' => 'GET', 'headers' => []]);
    ok($sent === $res, 'an unplaced response is returned as it came');
});

testcase('a_held_value_inside_another_held_values_encoded_form', function () {
    foreach ([['%', 'secret!'], ['secret!', '%']] as $held) {
        $broker = new SecretBroker([]);
        foreach ($held as $i => $value) {
            $broker->hoist('k' . $i, $value);
        }
        eq('token=[redacted]', $broker->scrub('token=secret%21'), implode(' ', $held));
    }
});

testcase('forms_that_overlap_in_the_text_are_redacted_as_one_span', function () {
    $broker = new SecretBroker([]);
    $broker->hoist('a', 'ab!');
    $broker->hoist('b', '!c');
    eq('x=[redacted]&y=[redacted]', $broker->scrub('x=ab%21c&y=!c'));
});

testcase('sekretos_own_redact_cannot_hide_an_encoded_form', function () {
    putenv('SCRUB_APIKEY=abcd');
    try {
        $broker = new SecretBroker([['kind' => 'env']]);
        eq('abcd', $broker->value('scrub', 'scrub.apikey'));
        $broker->hoist('other', 'abcd!x');
        eq('k=[redacted]', $broker->scrub('k=abcd%21x'));
    } finally {
        putenv('SCRUB_APIKEY');
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
        'retry' => ['options' => ['retries' => 3, 'wait' => 100], 'strict' => true],
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

/**
 * The design 6.3 loader resolves a `package` through CLASS AUTOLOADING,
 * which is php's ordinary resolution from the application root. This
 * stands in for composer's PSR-4 map: `test/pkg/solar_sdk.php` is never
 * required directly, so the loader has to find `Acme\SolarSdk\SDK` the
 * way php finds any class.
 */
spl_autoload_register(function (string $class): void {
    if (str_starts_with($class, 'Acme\\SolarSdk\\')) {
        require_once __DIR__ . '/pkg/solar_sdk.php';
    }
});

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

testcase('the_loader_resolves_a_package_through_class_autoloading', function () {
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => [
            'api' => ['solar' => ['package' => 'acme/solar-sdk']],
            'sdk' => ['solar' => []],
        ]],
    ]]);
    eq([], provided());

    // No factory registered: `package` closes the loop, and the
    // constructed client is bound like any other.
    $client = $st->sdk('solar');
    ok($client instanceof \Acme\SolarSdk\SDK, 'loaded from the package');
    eq(['solar'], provided());
    eq('[station:solar]', $client->client->options['apikey']);
    eq('solar', $st->plugins()[0]['name']);
});

testcase('load_preloads_every_declared_active_package', function () {
    $st = new Station(['config' => [
        'station' => 1,
        'profiles' => ['default' => ['sdk' => [
            'solar' => ['package' => 'acme/solar-sdk'],
            'solar$off' => ['active' => false, 'package' => 'acme/nope-sdk'],
        ]]],
    ]]);
    // php has one module system and no async, so this is a plain call.
    $st->load();
    eq(['solar'], provided());
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
    // The static front door delegates to the one process-global table.
    Station::provide('solar', solarfactory());
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

        file_put_contents($dir . '/station.json', '{ "station": 1, "profiles": { "x\\ud800": {} } }');
        $e = raises(fn() => \Voxgig\Station\load_config($dir), 'station_config_invalid');
        eq('station_config_invalid: station.json at ' . $dir . '/station.json'
            . ' has an unpaired surrogate escape in "x\\ud800"', $e->getMessage());
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

class ClosedSDK
{
    public function __construct(public array $options)
    {
    }
}

testcase('connect_keeps_as_and_instance_out_of_the_sdk_options', function () {
    $st = new Station(['config' => null]);
    $sdk = $st->connect(ClosedSDK::class, ['as' => 'spare', 'base' => 'http://x']);
    $keys = array_keys($sdk->options);
    sort($keys);
    eq(['base', 'extend', 'feature'], $keys);
    eq('spare', $sdk->options['feature']['station']['as']);

    $sdk = $st->adopt(ClosedSDK::class, ['instance' => 'solar$spare']);
    $keys = array_keys($sdk->options);
    sort($keys);
    eq(['extend', 'feature'], $keys);
    eq('solar$spare', $sdk->options['feature']['station']['instance']);
});

// A generated SDK is its own client, so the registry holds what connect
// returns.
#[\AllowDynamicProperties]
class SelfBoundSDK extends FakeClient
{
    public function __construct(array $options)
    {
        $this->options = $options;
        $utility = new FakeUtility();
        $utility->fetcher = fn($_c, $_u, $_d) => [okres(), null];
        $ctx = new FakeCtx($this, $utility, $options, SDKCONFIG);
        $fopts = is_array($options['feature']['station'] ?? null)
            ? $options['feature']['station'] : [];
        foreach (($options['extend'] ?? []) as $f) {
            $this->features[] = $f;
            $f->init($ctx, $fopts);
        }
    }
}

const NOTES = [
    'base' => 'http://127.0.0.1:9',
    'options' => ['headers' => ['x-api-version' => '2022-06-28'], 'prefix' => '/v1'],
];

function sdk_options(object $sdk): array
{
    $o = $sdk->options;
    unset($o['feature'], $o['extend']);
    return $o;
}

testcase('options_hands_a_named_instance_its_declared_options', function () {
    $st = new Station(['config' => solarconfig(['notes' => NOTES])]);
    $named = $st->options('notes', ['suffix' => '.json']);
    unset($named['feature']);
    ksort($named);
    eq(['base' => 'http://127.0.0.1:9', 'headers' => ['x-api-version' => '2022-06-28'],
        'prefix' => '/v1', 'suffix' => '.json'], $named);
    $unnamed = $st->options(['suffix' => '.json']);
    unset($unnamed['feature']);
    eq(['suffix' => '.json'], $unnamed);
});

testcase('options_names_the_instance_from_a_top_level_instance_or_as', function () {
    foreach ([['instance' => 'solar$eu'], ['as' => 'solar$eu']] as $named) {
        $st = new Station(['config' => solarconfig([
            'solar' => ['options' => ['headers' => ['x-api-version' => '1']]],
            'solar$eu' => ['options' => ['prefix' => '/eu']],
        ])]);
        $built = $st->options(array_merge($named, ['suffix' => '.json']));
        $sdkopts = $built;
        unset($sdkopts['feature']);
        ksort($sdkopts);
        eq(['prefix' => '/eu', 'suffix' => '.json'], $sdkopts);

        $client = new FakeClient();
        $ctx = new FakeCtx($client, new FakeUtility(), $built, SDKCONFIG);
        $feature = adapter_feature($st, []);
        $client->features[] = $feature;
        $feature->init($ctx, $built['feature']['station']);
        eq(['solar$eu'], array_map(fn($p) => $p['name'], $st->plugins()));
    }
});

testcase('connect_and_adopt_hand_a_named_instance_its_options', function () {
    $st = new Station(['config' => solarconfig(['notes' => NOTES])]);
    $want = ['base' => 'http://127.0.0.1:9',
        'headers' => ['x-api-version' => '2022-06-28'], 'prefix' => '/v1'];
    foreach ([
        $st->connect(ClosedSDK::class, ['instance' => 'notes']),
        $st->adopt(ClosedSDK::class, ['instance' => 'notes']),
        $st->connect(ClosedSDK::class, ['feature' => ['station' => ['instance' => 'notes']]]),
    ] as $sdk) {
        $got = sdk_options($sdk);
        ksort($got);
        eq($want, $got);
    }

    // The caller wins per top-level key, as in build().
    $got = sdk_options($st->connect(ClosedSDK::class, [
        'as' => 'notes$', 'headers' => ['x-caller' => 'yes'], 'suffix' => '.json']));
    ksort($got);
    eq(['base' => 'http://127.0.0.1:9', 'headers' => ['x-caller' => 'yes'],
        'prefix' => '/v1', 'suffix' => '.json'], $got);
});

testcase('an_unnamed_connect_warns_that_options_cannot_reach', function () {
    $st = new Station(['config' => solarconfig(['solar' => [
        'options' => ['headers' => ['x-api-version' => '1']]]])]);
    $client = $st->connect(SelfBoundSDK::class, ['prefix' => '/mine']);
    ok(!array_key_exists('headers', $client->options));

    $warns = [];
    foreach ($st->events() as $e) {
        if ('solar' === ($e['plugin'] ?? null) && isset($e['meta']['warn'])) {
            $warns[] = $e['meta']['warn'];
        }
    }
    eq(1, count($warns));
    ok(str_contains($warns[0], '[headers]'), $warns[0]);
    ok(str_contains($warns[0], '{ instance: "solar" }'), $warns[0]);
});

testcase('an_undeclared_key_is_refused_only_when_strict', function () {
    $faults = check_features(['retry' => ['retires' => 5]],
        normalize_descriptor(SDKCONFIG, null)['descriptor']);
    eq(['retires'], array_map(fn($f) => $f['key'], $faults));

    $loose = ['features' => [['name' => 'retry', 'active' => false,
        'options' => ['retries' => 3], 'strict' => false]]];
    eq([], check_features(['retry' => ['retires' => 5]], $loose));
});

testcase('an_optspec_key_is_declared_and_type_checked', function () {
    $d = ['features' => [['name' => 'test', 'active' => false,
        'options' => ['active' => false],
        'optspec' => ['entity' => '`$MAP`', 'net' => '`$MAP`'], 'strict' => false]]];
    eq([], check_features(['test' => ['active' => true,
        'entity' => ['note' => []], 'net' => ['offline' => true]]], $d));
    // An empty php array is an empty map as well as an empty list.
    eq([], check_features(['test' => ['entity' => []]], $d));
    $faults = check_features(['test' => ['net' => 'offline']], $d);
    ok(str_contains($faults[0]['message'], 'expects map, but found string'),
        $faults[0]['message']);
});

testcase('a_native_callable_is_a_function_option', function () {
    $d = ['features' => [['name' => 'retry', 'active' => false,
        'options' => ['active' => false],
        'optspec' => ['sleep' => '`$FUNCTION`', 'label' => '`$STRING`'], 'strict' => false]]];
    foreach ([fn($ms) => $ms, function ($ms) { return $ms; }, strlen(...), \Closure::fromCallable('strlen')] as $sleep) {
        eq([], check_features(['retry' => ['sleep' => $sleep]], $d));
    }
    eq(1, count(check_features(['retry' => ['sleep' => 'fast']], $d)));
    // A callable string is a string, as struct's typify has it.
    eq([], check_features(['retry' => ['label' => 'strlen']], $d));
    eq(1, count(check_features(['retry' => ['label' => fn() => null]], $d)));
});

testcase('sdk_takes_the_test_feature_options_its_optspec_declares', function () {
    $config = SDKCONFIG;
    $config['main']['slug'] = 'joplin';
    $config['feature'] = ['test' => [
        'options' => ['active' => false],
        'optspec' => ['entity' => '`$MAP`', 'net' => '`$MAP`'],
        'strict' => false, 'transport' => 'base']];
    provide('joplin', ['construct' => fn(array $o) => new ClosedSDK($o), 'config' => $config]);

    foreach ([['active' => true, 'entity' => ['note' => ['id' => 'n1']]],
              ['active' => true, 'net' => ['offline' => true]]] as $test) {
        (new Station(['config' => solarconfig(['joplin' => ['feature' => ['test' => $test]]])]))
            ->sdk('joplin');
    }

    $st = new Station(['config' => solarconfig(['joplin' => [
        'feature' => ['test' => ['entity' => 'note']]]])]);
    $e = raises(fn() => $st->sdk('joplin'), 'station_feature_option');
    ok(str_contains($e->getMessage(), 'expects map, but found string'), $e->getMessage());
});

// --- the carried adapter's place in a generated constructor (3.3) ---

class PlacementFeature
{
    public function __construct(public string $name)
    {
    }

    public function get_name(): string
    {
        return $this->name;
    }

    public function init(mixed $ctx, mixed $fopts): void
    {
        $inner = $ctx->utility->fetcher;
        if ('test' === $this->name) {
            $ctx->utility->fetcher = fn($c, $u, $d) => [['status' => 200, 'headers' => []], null];
        } elseif ('retry' === $this->name) {
            $ctx->utility->fetcher = function ($c, $u, $d) use ($inner) {
                [$res, $err] = $inner($c, $u, $d);
                for ($i = 0; $i < 2 && null === $err && 503 === $res['status']; $i++) {
                    [$res, $err] = $inner($c, $u, $d);
                }
                return [$res, $err];
            };
        } else {
            $ctx->utility->fetcher = fn($c, $u, $d) => $inner($c, $u, $d);
        }
    }
}

/** @return list<string> */
function placement_order(array $fmap): array
{
    $names = array_values(array_filter(array_keys($fmap), 'is_string'));
    sort($names, SORT_STRING);
    if (in_array('test', $names, true)) {
        $names = array_merge(['test'], array_values(array_filter($names, fn($n) => 'test' !== $n)));
    }
    $si = array_search('station', $names, true);
    if (false !== $si) {
        array_splice($names, $si, 1);
        $ti = array_search('test', $names, true);
        array_splice($names, false === $ti ? 0 : $ti + 1, 0, ['station']);
    }
    return $names;
}

function placement_add(array &$features, object $f): void
{
    $fopts = property_exists($f, '_options') && is_array($f->_options) ? $f->_options : [];
    $before = $fopts['__before__'] ?? null;
    $after = $fopts['__after__'] ?? null;
    $replace = $fopts['__replace__'] ?? null;
    if (null !== $before || null !== $after || null !== $replace) {
        foreach ($features as $i => $ef) {
            $name = property_exists($ef, 'name') ? $ef->name : null;
            if ($before === $name) {
                array_splice($features, $i, 0, [$f]);
                return;
            }
            if ($after === $name) {
                array_splice($features, $i + 1, 0, [$f]);
                return;
            }
            if ($replace === $name) {
                $features[$i] = $f;
                return;
            }
        }
    }
    $features[] = $f;
}

/**
 * What an SDK generated without the station feature does when it is
 * constructed: make_options' feature order, the constructor's loops,
 * feature_add's anchors and feature_init, as sdkgen's php templates
 * write them. `$statuses` scripts the wire, one status per attempt.
 */
#[\AllowDynamicProperties]
class PlacementSDK
{
    public const CONFIG = [
        'main' => ['name' => 'taskpad', 'slug' => 'taskpad', 'version' => '1.0.0',
            'target' => 'php'],
        'feature' => ['cache' => ['strict' => false], 'retry' => ['strict' => false],
            'test' => ['strict' => false]],
        'options' => ['base' => 'http://api.test', 'auth' => ['prefix' => '']],
        'entity' => [],
    ];

    /** @var list<int> */
    public static array $statuses = [];

    /** @var list<string> */
    public static array $sent = [];

    public string $mode = 'live';
    public array $features = [];
    public array $options;
    private FakeUtility $utility;

    public function __construct(array $options)
    {
        $this->options = $options;
        $fmap = is_array($options['feature'] ?? null) ? $options['feature'] : [];
        if (true === ($fmap['test']['active'] ?? null)) {
            $this->mode = 'test';
        }
        $this->utility = new FakeUtility();
        $this->utility->fetcher = function ($c, string $url, $def): array {
            self::$sent[] = $url;
            $status = self::$statuses[count(self::$sent) - 1] ?? 200;
            return [['status' => $status, 'headers' => []], null];
        };
        $ctx = new FakeCtx($this, $this->utility, $options, self::CONFIG);

        $extend = is_array($options['extend'] ?? null) ? $options['extend'] : [];
        foreach (placement_order($fmap) as $fname) {
            if (true !== ($fmap[$fname]['active'] ?? null)) {
                continue;
            }
            if (!isset(self::CONFIG['feature'][$fname])) {
                foreach ($extend as $ef) {
                    if ($fname === $ef->get_name()) {
                        continue 2;
                    }
                }
            }
            placement_add($this->features, new PlacementFeature($fname));
        }
        foreach ($extend as $f) {
            placement_add($this->features, $f);
        }
        foreach ($this->features as $f) {
            $fopts = $fmap[$f->get_name()] ?? null;
            if (is_array($fopts) && true === ($fopts['active'] ?? null)) {
                $f->init($ctx, $fopts);
            }
        }
    }

    public function list(): mixed
    {
        $ctx = new FakeCtx($this, $this->utility, $this->options, self::CONFIG);
        $ctx->op = new FakeOp('todo', 'list');
        foreach ($this->features as $f) {
            if (method_exists($f, 'PrePoint')) {
                $f->PrePoint($ctx);
            }
        }
        [$res, $err] = ($this->utility->fetcher)($ctx, 'http://api.test/todo',
            ['method' => 'GET', 'headers' => []]);
        $ctx->result = new FakeResult(null === $err && 200 === $res['status'], $err);
        foreach ($this->features as $f) {
            if (method_exists($f, 'PreDone')) {
                $f->PreDone($ctx);
            }
        }
        return $res;
    }
}

/** @return list<string> */
function placement_names(object $client): array
{
    return array_map(fn($f) => $f->get_name(), $client->features);
}

/** @return list<array{0: string, 1: mixed}> */
function placement_wire(Station $st): array
{
    $out = [];
    foreach ($st->events() as $e) {
        if ('http' === $e['kind']) {
            $out[] = ['http', $e['http']['status']];
        } elseif ('op' === $e['kind']) {
            $out[] = ['op', $e['op']['outcome']];
        }
    }
    return $out;
}

function placement_case(array $statuses, callable $body): void
{
    PlacementSDK::$statuses = $statuses;
    PlacementSDK::$sent = [];
    putenv('TASKPAD_APIKEY=taskpad-key');
    try {
        $body();
    } finally {
        putenv('TASKPAD_APIKEY');
    }
}

testcase('adapter_anchor_after_test_when_active_else_before_the_first_by_name', function () {
    eq([], adapter_anchor(null));
    eq([], adapter_anchor([]));
    eq([], adapter_anchor(['station' => ['active' => true]]));
    eq(['__before__' => 'retry'], adapter_anchor(['retry' => ['active' => true]]));
    eq(['__before__' => 'cache'],
        adapter_anchor(['retry' => ['active' => true], 'cache' => ['active' => true]]));
    eq(['__before__' => 'retry'],
        adapter_anchor(['cache' => ['active' => false], 'retry' => ['active' => true]]));
    eq(['__before__' => 'timeout'],
        adapter_anchor(['station' => ['active' => true], 'timeout' => ['active' => true]]));
    eq(['__after__' => 'test'],
        adapter_anchor(['test' => ['active' => true], 'retry' => ['active' => true]]));
    eq(['__before__' => 'retry'],
        adapter_anchor(['test' => ['active' => false], 'retry' => ['active' => true]]));
    eq([], adapter_anchor([['name' => 'retry', 'active' => true]]));
});

testcase('placement_live_with_retry_station_is_the_base_wrap', function () {
    placement_case([503, 200], function () {
        $st = new Station(['config' => null]);
        $client = $st->connect(PlacementSDK::class,
            ['feature' => ['retry' => ['active' => true]]]);
        eq(['station', 'retry'], placement_names($client));
        $client->list();
        eq(2, count(PlacementSDK::$sent));
        eq([['http', 503], ['http', 200], ['op', 'ok']], placement_wire($st));
        $st->close();
    });
});

testcase('placement_live_with_two_features_before_the_first_by_name', function () {
    placement_case([], function () {
        $st = new Station(['config' => null]);
        $client = $st->adopt(PlacementSDK::class, ['feature' => [
            'retry' => ['active' => true], 'cache' => ['active' => true]]]);
        eq(['station', 'cache', 'retry'], placement_names($client));
        $st->close();
    });
});

testcase('placement_test_mode_station_sits_on_the_mock_transport', function () {
    placement_case([], function () {
        $st = new Station(['config' => null]);
        $client = $st->connect(PlacementSDK::class, ['feature' => [
            'test' => ['active' => true], 'retry' => ['active' => true]]]);
        eq(['test', 'station', 'retry'], placement_names($client));
        $st->close();
    });
});

testcase('placement_no_other_feature_station_alone', function () {
    placement_case([], function () {
        $st = new Station(['config' => null]);
        eq(['station'], placement_names($st->connect(PlacementSDK::class, [])));
        $st->close();
    });
});

testcase('placement_the_declarative_path_places_it_the_same_way', function () {
    placement_case([503, 200], function () {
        provide('taskpad', ['construct' => fn(array $o) => new PlacementSDK($o),
            'config' => PlacementSDK::CONFIG]);
        $st = new Station(['config' => ['station' => 1, 'profiles' => ['default' => [
            'sdk' => ['taskpad' => ['feature' => ['retry' => ['active' => true]]]]]]]]);
        $client = $st->sdk('taskpad');
        eq(['station', 'retry'], placement_names($client));
        $client->list();
        eq(2, count(PlacementSDK::$sent));
        eq([['http', 503], ['http', 200], ['op', 'ok']], placement_wire($st));
        $st->close();
    });
});

// --- the Station out of the SDK's options (design station.md 3.1) ---

const EXPOSURE_SECRET = 'exposure-key-101';

/**
 * An SDK generated without the station feature, reduced to what the
 * carried adapter touches: the options kept as given, extend features
 * initialised in order, and a transport that answers 200.
 */
#[\AllowDynamicProperties]
class ExposureSDK
{
    public const CONFIG = [
        'main' => ['name' => 'taskpad', 'slug' => 'taskpad', 'version' => '1.0.0',
            'target' => 'php'],
        'options' => ['base' => 'http://api.test', 'auth' => ['prefix' => '']],
        'entity' => [],
    ];

    public string $mode = 'live';
    public array $features = [];
    public array $options;
    private FakeUtility $utility;
    private FakeCtx $ctx;

    public function __construct(array $options)
    {
        $this->options = $options;
        $this->utility = new FakeUtility();
        $this->utility->fetcher = fn($c, $u, $d) => [['status' => 200, 'headers' => []], null];
        $this->ctx = new FakeCtx($this, $this->utility, $options, self::CONFIG);
        foreach ($options['extend'] ?? [] as $f) {
            $this->features[] = $f;
            $f->init($this->ctx, $options['feature'][$f->get_name()] ?? []);
        }
        $this->options = $this->ctx->options;
    }

    public function call(): array
    {
        return ($this->utility->fetcher)($this->ctx, 'http://api.test/todo',
            ['method' => 'GET', 'headers' => ['authorization' => $this->ctx->options['apikey']]]);
    }
}

function exposure_shows(mixed $value): string
{
    ob_start();
    var_dump($value);
    return print_r($value, true) . ob_get_clean();
}

function exposure_reaches_station(mixed $value, array &$seen = []): bool
{
    if ($value instanceof Station) {
        return true;
    }
    if (is_object($value)) {
        $id = spl_object_id($value);
        if (isset($seen[$id])) {
            return false;
        }
        $seen[$id] = true;
        $value = (array) $value;
    }
    if (is_array($value)) {
        foreach ($value as $v) {
            if (exposure_reaches_station($v, $seen)) {
                return true;
            }
        }
    }
    return false;
}

testcase('http_event_keeps_no_userinfo_of_a_url_reported_whole', function () {
    eq('https://h x/y', \Voxgig\Station\without_userinfo('https://u:s3cret@h x/y'));
    eq('https://h:99999/x', \Voxgig\Station\without_userinfo('https://u:p@h:99999/x'));
    eq('https://h x/y@z', \Voxgig\Station\without_userinfo('https://h x/y@z'));
    eq('/a@b', \Voxgig\Station\without_userinfo('/a@b'));

    $st = new Station(['config' => null]);
    $b = bind($st, fn($c, $u, $d) => [okres(), null]);
    $b['client']->mode = 'test';
    foreach (['https://u:s3cret@h x/y', 'https://u:p@h:99999/x'] as $url) {
        ($b['utility']->fetcher)($b['ctx'], $url, ['method' => 'GET', 'headers' => []]);
    }
    $shown = json_encode(array_values(array_map(fn($e) => $e['http'],
        array_filter($st->events(), fn($e) => 'http' === $e['kind']))));
    ok(!str_contains($shown, 's3cret'), $shown);
    ok(!str_contains($shown, 'u:p@'), $shown);
});

testcase('exposure_a_bound_clients_options_hold_no_secret_after_a_live_request', function () {
    putenv('TASKPAD_APIKEY=' . EXPOSURE_SECRET);
    try {
        $st = Station::open(['config' => null]);
        $client = $st->connect(ExposureSDK::class, []);
        [$res, $err] = $client->call();
        eq(null, $err);
        eq(200, $res['status']);

        ok(!str_contains(exposure_shows($client->options), EXPOSURE_SECRET), 'options');
        ok(!str_contains(exposure_shows($st), EXPOSURE_SECRET), 'station');
        ok(!exposure_reaches_station($client->options['feature']), 'the options reach no Station');
        $st->close();
    } finally {
        putenv('TASKPAD_APIKEY');
    }
});

/** A generated SDK's station feature, reduced to its binding call. */
#[\AllowDynamicProperties]
class InvertedSDK
{
    public string $mode = 'live';
    public array $features;
    public mixed $binding;

    public function __construct(array $options)
    {
        $this->features = [new FakeFeature('station')];
        $utility = new FakeUtility();
        $utility->fetcher = fn($c, $u, $d) => [['status' => 200, 'headers' => []], null];
        $ctx = new FakeCtx($this, $utility, $options, ExposureSDK::CONFIG);
        $this->binding = \Voxgig\Station\feature_binding($ctx, $options['feature']['station']);
    }
}

testcase('exposure_a_station_built_only_for_its_options_lives_to_bind', function () {
    $options = (function (): array {
        return (new Station(['config' => null]))->options([]);
    })();
    gc_collect_cycles();

    $client = new InvertedSDK($options);
    ok(null !== $client->binding, 'the options still reach their Station');
    ok(!str_contains(exposure_shows($options), 'broker'), 'the options dump none of its state');
});

testcase('exposure_the_callers_own_key_does_not_ride_the_activation_entry', function () {
    $st = Station::open(['config' => null]);
    $client = $st->adopt(ExposureSDK::class, ['apikey' => EXPOSURE_SECRET]);
    $client->call();

    ok(!str_contains(exposure_shows($client->options['feature']), EXPOSURE_SECRET), 'entry');
    ok(!str_contains(exposure_shows($st), EXPOSURE_SECRET), 'station');
    $st->close();
});

testcase('exposure_inverted_binding_the_activation_entry_holds_neither', function () {
    $st = Station::open(['config' => null]);
    $options = $st->options(['apikey' => EXPOSURE_SECRET]);

    eq(EXPOSURE_SECRET, $options['apikey'], 'the SDK still gets the key it is given');
    ok(!str_contains(exposure_shows($options['feature']['station']), EXPOSURE_SECRET), 'entry');
    ok(!exposure_reaches_station($options), 'the options reach no Station');
    $st->close();
});

echo "\npass: $pass, fail: $fail\n";
exit(0 < $fail ? 1 : 0);
