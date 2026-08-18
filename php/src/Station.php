<?php

/**
 * The station library core, solo mode (design D1): fully functional
 * in-process with no other component running. The proxy (D2) is a
 * deferred amplifier - `require` therefore fails on the operation path
 * (design station.md 2.1/14), and `auto` degrades to solo with one
 * warning event.
 *
 * A port of typescript/src/Station.ts, which is canonical. SDK-facing
 * seams follow the generated PHP SDKs' conventions: the transport slot
 * is a callable returning a [response, err] tuple; client mode is the
 * public `mode` property; per-op state rides ctx->meta['station']. Two
 * php-specific mappings, pinned by the target notes: (1) the base
 * transport's non-curl branch synthesizes a status-0 response with NO
 * err for network-level failures, so a status-0 response is treated as
 * a transport failure (http event at status 0 plus an error event) -
 * the same observable outcome the ts library produces when its fetch
 * throws; (2) PHP arrays are value types, so copy-on-inject (5.3) holds
 * by construction - the middleware still swaps only its own copy.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Descriptor.php';
require_once __DIR__ . '/Events.php';
require_once __DIR__ . '/Profile.php';
require_once __DIR__ . '/Secrets.php';
require_once __DIR__ . '/Adapter.php';

class Station
{
    private static ?Station $ambient = null;
    private static ?string $ambient_opts = null;

    /** @var array<string, mixed> */
    private array $opts;
    /** @var array{name: string, providers: array<int, mixed>, plugin: array<string, array<string, mixed>>} */
    private array $profile;
    private SecretBroker $broker;
    private EventBuffer $buffer;
    /** @var array<string, array<string, mixed>> */
    private array $registry = [];
    /** @var array<string, string> */
    private array $secret_override = [];
    private bool $require_proxy;
    private bool $closed = false;

    /**
     * Ambient instance (design station.md 10.2): open() is the
     * idempotent process-wide singleton; a second open() with
     * conflicting options is an error; `new Station($opts)` stays
     * isolated for tests and multi-tenant hosts. open() is non-blocking
     * - solo involves no network, and the deferred proxy probe must
     * never change that.
     *
     * @param array<string, mixed>|null $opts
     */
    public static function open(?array $opts = null): Station
    {
        $key = self::opts_key($opts);
        if (null !== self::$ambient) {
            if ($key !== self::$ambient_opts) {
                throw new StationError('station_open_conflict',
                    'Station::open() was already called with different options');
            }
            return self::$ambient;
        }
        self::$ambient = new Station($opts);
        self::$ambient_opts = $key;
        return self::$ambient;
    }

    /**
     * The ambient instance, or null - never creates one. The generated
     * station feature binds through this when no explicit handle rides
     * its options (design station.md 3.1: binding is never implicit;
     * only open() creates the ambient instance).
     */
    public static function current(): ?Station
    {
        return self::$ambient;
    }

    /** Test seam: drop the ambient instance. */
    public static function reset(): void
    {
        self::$ambient = null;
        self::$ambient_opts = null;
    }

    public static function _reset_if(Station $station): void
    {
        if (self::$ambient === $station) {
            self::reset();
        }
    }

    /** @param array<string, mixed>|null $opts */
    private static function opts_key(?array $opts): string
    {
        $key = json_encode($opts ?? []);
        if (false === $key) {
            $key = print_r($opts ?? [], true);
        }
        return $key;
    }

    /** @param array<string, mixed>|null $opts */
    public function __construct(?array $opts = null)
    {
        $this->opts = $opts ?? [];

        $config = array_key_exists('config', $this->opts)
            ? $this->opts['config']
            : load_config(is_string($this->opts['folder'] ?? null)
                ? $this->opts['folder'] : null);

        $this->profile = resolve_profile(
            $config,
            select_profile(is_string($this->opts['profile'] ?? null)
                ? $this->opts['profile'] : null));
        $this->broker = new SecretBroker($this->profile['providers']);
        $this->buffer = new EventBuffer();

        $proxy = $this->opts['proxy'] ?? 'auto';
        $this->require_proxy = 'require' === $proxy;

        if ('auto' === $proxy) {
            // The probe is deferred with the proxy itself; absence
            // degrades to solo with a single warning event naming the
            // cause (14).
            $this->emit([
                't' => now_ms(), 'kind' => 'station',
                'meta' => ['warn' => 'proxy absent (not found); running solo'],
            ]);
        }
    }

    // --- binding forms (design station.md 3.1) ---

    /**
     * connect(SDK::class, opts): station constructs the SDK itself,
     * activating the adapter with 3.3 ordering (the generated
     * make_options hoists a map-form station entry to just after test).
     *
     * @param class-string $sdk_class
     * @param array<string, mixed>|null $opts
     */
    public function connect(string $sdk_class, ?array $opts = null): object
    {
        return $this->construct($sdk_class, $opts);
    }

    /**
     * adopt(SDK::class, opts): the retrofit path - construction-time
     * sugar, not post-hoc attachment (3.1). In php it is the same
     * construction as connect; a resident options apikey is hoisted by
     * the adapter.
     *
     * @param class-string $sdk_class
     * @param array<string, mixed>|null $opts
     */
    public function adopt(string $sdk_class, ?array $opts = null): object
    {
        return $this->construct($sdk_class, $opts);
    }

    /**
     * Inverted binding (design station.md 3.1): build the plain options
     * array a generated constructor already accepts - the handle and the
     * activation entry; the profile's per-plugin base is applied by the
     * adapter at init (caller opts still win).
     *
     * @param array<string, mixed>|null $extra
     * @return array<string, mixed>
     */
    public function options(?array $extra = null): array
    {
        $extra = $extra ?? [];
        $fmap = is_array($extra['feature'] ?? null) ? $extra['feature'] : [];
        $sf = is_array($fmap['station'] ?? null) ? $fmap['station'] : [];
        $sf['active'] = true;
        $sf['station'] = $this;
        $sf['calleropts'] = $extra;
        $fmap['station'] = $sf;
        $extra['feature'] = $fmap;
        return $extra;
    }

    // --- registration (design station.md 3 item 1, called by the adapter) ---

    /**
     * The registry entry whose client IS this object, or null. Used by
     * feature_binding for idempotency: connect/adopt activate the
     * station entry AND ride the carried adapter on extend, so on an SDK
     * whose generated features carry a real station feature class the
     * same construction reaches feature_binding twice - the second
     * arrival must no-op, while a genuinely second client of the same
     * SDK class still fails _register's slug check (10.2).
     *
     * @return array<string, mixed>|null
     */
    public function _bound_entry(mixed $client): ?array
    {
        foreach ($this->registry as $entry) {
            if ($entry['client'] === $client) {
                return $entry;
            }
        }
        return null;
    }

    /**
     * @return array{binding: array<string, mixed>, profile_plugin: array<string, mixed>|null}
     */
    public function _register(mixed $client, mixed $config, mixed $options,
        mixed $_calleropts, mixed $fopts = null): array
    {
        $normalized = normalize_descriptor(
            $config, is_array($options) ? ($options['feature'] ?? null) : null);
        $descriptor = $normalized['descriptor'];
        $warnings = $normalized['warnings'];
        $slug = $descriptor['slug'];

        if (isset($this->registry[$slug])) {
            throw new StationError('station_bound_twice',
                'plugin "' . $slug . '" is already registered; binding one ' .
                'client twice is an error (10.2)');
        }

        $fopts = is_array($fopts) ? $fopts : [];
        $profile_plugin = $this->profile['plugin'][$slug] ?? null;

        // Secret name precedence: the feature option (in-code, design
        // station.md 9 config.options.secret) beats the profile, which
        // beats the descriptor default.
        $fsecret = $fopts['secret'] ?? null;
        if (is_string($fsecret) && '' !== $fsecret) {
            $this->secret_override[$slug] = $fsecret;
        }
        $secretname = $this->first_non_empty(
            $fsecret,
            is_array($profile_plugin) ? ($profile_plugin['secret'] ?? null) : null)
            ?? $descriptor['auth']['secretname'];

        $auth_active = true === $descriptor['auth']['active'];
        $rung = $auth_active ? 'R1' : 'none';
        $binding = [
            'plugin' => $slug,
            'placeholder' => $auth_active ? placeholder_for($slug) : null,
            'secretname' => $auth_active ? $secretname : null,
            'rung' => $rung,
        ];

        $this->registry[$slug] = [
            'slug' => $slug, 'descriptor' => $descriptor, 'rung' => $rung,
            'client' => $client, 'warnings' => $warnings,
        ];

        foreach ($warnings as $w) {
            $this->emit(['t' => now_ms(), 'kind' => 'station',
                'plugin' => $slug, 'meta' => ['warn' => $w]]);
        }
        $this->emit([
            't' => now_ms(), 'kind' => 'construct', 'plugin' => $slug,
            'meta' => [
                'name' => $descriptor['name'],
                'version' => $descriptor['version'],
                'rung' => $rung,
            ],
        ]);

        return ['binding' => $binding, 'profile_plugin' => $profile_plugin];
    }

    public function _hoist(string $slug, string $value): void
    {
        $this->broker->hoist($slug, $value);
        $this->emit([
            't' => now_ms(), 'kind' => 'station', 'plugin' => $slug,
            'meta' => [
                'warn' => 'a resident credential was hoisted into the broker ' .
                    'and replaced by the placeholder; prefer configuring the ' .
                    'secret name and letting sekreto resolve it',
            ],
        ]);
    }

    // --- the transport middleware (design station.md 3.3, 5.3) ---

    /**
     * Called by the adapter's TransportWrap; `inner` is the transport
     * that was current at init time. Returns the SDK's [response, err]
     * tuple.
     *
     * @return array{0: mixed, 1: mixed}
     */
    public function _transport(string $slug, mixed $inner, mixed $fctx,
        string $fullurl, array $fetchdef): array
    {
        // Fail-closed means traffic (2.1): with the proxy deferred,
        // `require` can never attach, so every operation fails here -
        // the operation path, never the constructor.
        if ($this->require_proxy) {
            $err = new StationError('station_no_proxy',
                'proxy: "require" is set and no proxy is attached');
            $this->emit_err($slug, $fctx, $err);
            return [null, $err];
        }

        $entry = $this->registry[$slug] ?? null;
        $placeholder = placeholder_for($slug);
        $live = 'live' === ($fctx->client->mode ?? null);
        $profile_plugin = $this->profile['plugin'][$slug] ?? null;

        // Egress policy (design station.md 16), solo half: the hosts
        // allowlist is enforced at the seam every request crosses. When
        // a policy is present, redirects come back manual - a 3xx is a
        // response like any other, so a Location off the allowlist
        // cannot pull an automatic credentialed follow-up to an
        // unapproved host (8.2's rule, applied at the library seam; the
        // generated fetcher's curl branch never follows, and its stream
        // branch honours the annotation).
        $hosts = is_array($profile_plugin) && is_array($profile_plugin['policy'] ?? null)
            ? ($profile_plugin['policy']['hosts'] ?? null) : null;
        if (is_array($hosts) && $live) {
            $hostname = parse_url($fullurl, PHP_URL_HOST);
            $hostname = is_string($hostname) ? $hostname : '';
            if (!in_array($hostname, $hosts, true)) {
                $err = new StationError('station_host_allow',
                    'egress to "' . $hostname . '" denied by the hosts policy ' .
                    'of plugin "' . $slug . '"');
                $this->emit_err($slug, $fctx, $err);
                return [null, $err];
            }
        }

        $senddef = $fetchdef;
        if (is_array($hosts) && $live) {
            $senddef['redirect'] = 'manual';
        }

        // Injection: at the last boundary, below every recording
        // feature, and never into mock transports (3.3) - in test/mock
        // modes the placeholder rides through untouched, so real
        // credentials never enter in-memory mock stores. Copy-on-inject
        // (5.3): $senddef is this function's own copy (value semantics),
        // so the fetchdef reachable from ctx/spec/ctrl keeps the
        // placeholder, ever.
        if ($live && null !== $entry && 'R1' === $entry['rung']) {
            $secretname = $this->first_non_empty(
                $this->secret_override[$slug] ?? null,
                is_array($profile_plugin) ? ($profile_plugin['secret'] ?? null) : null)
                ?? $entry['descriptor']['auth']['secretname'];

            try {
                $value = $this->broker->value($slug, $secretname);
            } catch (\Throwable $e) {
                $this->emit_err($slug, $fctx, $e);
                return [null, $e];
            }

            $headers = is_array($senddef['headers'] ?? null) ? $senddef['headers'] : [];
            foreach ($headers as $h => $v) {
                if (is_string($v) && str_contains($v, $placeholder)) {
                    $headers[$h] = str_replace($placeholder, $value, $v);
                }
            }
            $senddef['headers'] = $headers;
        }

        $st = is_array($fctx->meta ?? null) ? ($fctx->meta['station'] ?? null) : null;
        $corr = is_array($st) ? ($st['corr'] ?? null) : null;
        $started = now_ms();

        try {
            [$res, $err] = ($inner)($fctx, $fullurl, $senddef);
        } catch (\Throwable $e) {
            $this->emit_http($slug, $corr, $fullurl, $senddef, 0, $started, 0);
            $this->emit_err($slug, $fctx, $e);
            throw $e;
        }

        if (null !== $err) {
            $this->emit_http($slug, $corr, $fullurl, $senddef, 0, $started, 0);
            $this->emit_err($slug, $fctx, $err);
            return [$res, $err];
        }

        $status = is_array($res) && is_numeric($res['status'] ?? null)
            ? (int) $res['status'] : 0;

        if (0 === $status) {
            // The php base transport's stream branch synthesizes a
            // status-0 response (no err) for network-level failures; map
            // it to the same events the ts library emits when its
            // transport throws.
            $this->emit_http($slug, $corr, $fullurl, $senddef, 0, $started, 0);
            if (is_array($res)) {
                $message = (string) ($res['statusText'] ?? '');
                $message = '' === $message ? 'transport failure' : $message;
                $this->emit(['t' => now_ms(), 'kind' => 'error',
                    'plugin' => $slug, 'corr' => $corr,
                    'err' => ['message' => $this->redact($message)]]);
            }
            return [$res, $err];
        }

        $bytes = 0;
        $rheaders = is_array($res) && is_array($res['headers'] ?? null)
            ? $res['headers'] : [];
        $cl = $rheaders['content-length'] ?? null;
        if (null !== $cl) {
            $bytes = (int) $cl;
        }
        $this->emit_http($slug, $corr, $fullurl, $senddef, $status, $started, $bytes);

        return [$res, $err];
    }

    /** Op events from the hook bridge (design station.md 3 item 3). */
    public function _op_event(string $slug, mixed $ctx, string $outcome): void
    {
        $st = is_array($ctx->meta ?? null) ? ($ctx->meta['station'] ?? null) : null;
        $st = is_array($st) ? $st : [];

        // ctx->op is the SDK's resolved Operation: name + entity, with
        // '_' as the generated PHP SDKs' absence sentinel.
        $op = $ctx->op ?? null;
        $entity = is_object($op) ? (string) ($op->entity ?? '') : '';
        $entity = '_' === $entity ? '' : $entity;
        if ('' === $entity && is_object($ctx->entity ?? null) &&
            method_exists($ctx->entity, 'get_name')) {
            $entity = (string) $ctx->entity->get_name();
        }
        $opname = is_object($op) ? (string) ($op->name ?? '') : '';
        $opname = '_' === $opname ? '' : $opname;

        $this->emit([
            't' => now_ms(), 'kind' => 'op', 'plugin' => $slug,
            'corr' => $st['corr'] ?? null,
            'op' => [
                'entity' => $entity,
                'op' => $opname,
                'outcome' => $outcome,
                'durationMs' => isset($st['start']) ? now_ms() - $st['start'] : 0,
            ],
        ]);
    }

    // --- the query/observe surface (design station.md 3.2, 6) ---

    /** @return array<int, array<string, mixed>> */
    public function plugins(): array
    {
        $out = [];
        foreach ($this->registry as $e) {
            $out[] = [
                'slug' => $e['slug'],
                'descriptor' => $e['descriptor'],
                'rung' => $e['rung'],
                'warnings' => $e['warnings'],
            ];
        }
        return $out;
    }

    /** @return array<string, mixed> */
    public function descriptor_of(string $slug): array
    {
        $entry = $this->registry[$slug] ?? null;
        if (null === $entry) {
            throw new StationError('station_no_plugin', 'unknown plugin "' .
                $slug . '"; known: [' .
                implode(', ', array_keys($this->registry)) . ']');
        }
        return $entry['descriptor'];
    }

    public function canonical_descriptor(string $slug): string
    {
        return canonical_serialize($this->descriptor_of($slug));
    }

    /** @return array<int, array<string, mixed>> */
    public function events(): array
    {
        return $this->buffer->events();
    }

    /** Subscribe; the returned callable unsubscribes. */
    public function tap(callable $fn): callable
    {
        return $this->buffer->tap($fn);
    }

    /** @return array<string, mixed> */
    public function status(): array
    {
        $plugins = [];
        foreach ($this->registry as $e) {
            $plugins[] = ['slug' => $e['slug'], 'rung' => $e['rung']];
        }
        return [
            'mode' => 'solo',
            'profile' => $this->profile['name'],
            'plugins' => $plugins,
            'events' => $this->buffer->status(),
        ];
    }

    public function redact(string $text): string
    {
        return $this->broker->scrub($text);
    }

    public function refresh_secrets(): void
    {
        $this->broker->refresh();
    }

    /**
     * close(): flush (solo: nothing in flight), then warn on profile
     * plugin keys that matched no registered plugin - a typo'd key
     * silently configuring nothing is the worst outcome for a
     * secrets-and-policy file (design station.md 11).
     */
    public function close(): void
    {
        if ($this->closed) {
            return;
        }
        foreach (array_keys($this->profile['plugin']) as $slug) {
            if (!isset($this->registry[$slug])) {
                $this->emit([
                    't' => now_ms(), 'kind' => 'station',
                    'meta' => [
                        'warn' => 'profile plugin key "' . $slug .
                            '" matched no registered plugin',
                    ],
                ]);
            }
        }
        $this->closed = true;
        self::_reset_if($this);
    }

    public function is_closed(): bool
    {
        return $this->closed;
    }

    // --- internals ---

    /**
     * @param class-string $sdk_class
     * @param array<string, mixed>|null $opts
     */
    private function construct(string $sdk_class, ?array $opts): object
    {
        if ($this->closed) {
            throw new StationError('station_no_plugin', 'station is closed');
        }
        $opts = $opts ?? [];
        $fmap = is_array($opts['feature'] ?? null) ? $opts['feature'] : [];
        $sf = is_array($fmap['station'] ?? null) ? $fmap['station'] : [];
        $sf['active'] = true;
        $sf['station'] = $this;
        $sf['calleropts'] = $opts;
        $fmap['station'] = $sf;

        $extend = is_array($opts['extend'] ?? null) ? $opts['extend'] : [];

        // The carried adapter rides extend for SDKs generated WITHOUT
        // the station feature; when the generated class exists the
        // constructor uses it and the extend copy's bind is made inert
        // by _bound_entry (both delegate to feature_binding, so behavior
        // is identical).
        $extend[] = adapter_feature($this, $opts);

        $options = $opts;
        $options['feature'] = $fmap;
        $options['extend'] = $extend;

        return new $sdk_class($options);
    }

    /** @param array<string, mixed> $ev */
    private function emit(array $ev): void
    {
        $this->buffer->emit($ev);
    }

    private function emit_http(string $slug, mixed $corr, string $fullurl,
        mixed $fetchdef, int $status, int $started, int $bytes): void
    {
        $host = '';
        $path = '';
        $parts = parse_url($fullurl);
        if (is_array($parts) && isset($parts['host'])) {
            $host = $parts['host'];
            // Mirror the ts URL.host: the port rides along unless it is
            // the scheme default.
            $port = $parts['port'] ?? null;
            $scheme = strtolower((string) ($parts['scheme'] ?? ''));
            $default = 'https' === $scheme ? 443 : ('http' === $scheme ? 80 : null);
            if (null !== $port && $port !== $default) {
                $host .= ':' . $port;
            }
            $path = (string) ($parts['path'] ?? '');
        } else {
            $path = $fullurl;
        }
        $this->emit([
            't' => $started, 'kind' => 'http', 'plugin' => $slug, 'corr' => $corr,
            'http' => [
                'method' => is_array($fetchdef) && is_string($fetchdef['method'] ?? null)
                    ? $fetchdef['method'] : 'GET',
                'host' => $host, 'path' => $path, 'status' => $status,
                'durationMs' => now_ms() - $started, 'bytes' => $bytes,
            ],
        ]);
    }

    private function emit_err(string $slug, mixed $fctx, mixed $err): void
    {
        $st = is_object($fctx) && is_array($fctx->meta ?? null)
            ? ($fctx->meta['station'] ?? null) : null;

        $code = null;
        if ($err instanceof StationError) {
            $code = $err->code();
        } elseif (is_object($err) && is_string($err->sdk_code ?? null) &&
            '' !== $err->sdk_code) {
            $code = $err->sdk_code;
        }

        $message = $err instanceof \Throwable
            ? $err->getMessage()
            : (is_scalar($err) ? (string) $err : print_r($err, true));

        $ev_err = [
            // The scrub keeps an upstream echo of a credential out of
            // the event stream (design station.md 7 as revised:
            // exact-value, no length floor).
            'message' => $this->redact($message),
        ];
        if (null !== $code) {
            $ev_err['code'] = $code;
        }
        $this->emit([
            't' => now_ms(), 'kind' => 'error', 'plugin' => $slug,
            'corr' => is_array($st) ? ($st['corr'] ?? null) : null,
            'err' => $ev_err,
        ]);
    }

    private function first_non_empty(mixed ...$vals): ?string
    {
        foreach ($vals as $v) {
            if (null !== $v && '' !== $v) {
                return (string) $v;
            }
        }
        return null;
    }
}
