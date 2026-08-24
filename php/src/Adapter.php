<?php

/**
 * The station side of the plugin contract (design station.md 3), in ONE
 * place: feature_binding() is what both entry paths delegate to -
 *  - the GENERATED station feature (sdkgen-station's php template) calls
 *    it from its init() and forwards its hook methods;
 *  - the library's carried adapter (adapter_feature, the adopt/connect
 *    retrofit for SDKs generated without the feature) is a thin shell
 *    over the same call.
 * Registration at init, wrap position verified, transport wrapped with
 * copy-on-inject, hooks bridged to op events. Anything changed here
 * changes both paths - which is the point.
 *
 * A port of typescript/src/adapter.ts, which is canonical. SDK-facing
 * seams follow the generated PHP SDKs' conventions: the transport slot is
 * a callable returning a [response, err] tuple; per-op state rides
 * ctx->meta['station'] (PHP arrays are value types, so a captured array
 * could not be shared - the ctx object's own array property can).
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Station.php';

function next_corr(): int
{
    static $seq = 0;
    return ++$seq;
}

function now_ms(): int
{
    return (int) round(microtime(true) * 1000);
}

/**
 * The wrapped transport installed over utility->fetcher. An invokable
 * class rather than a closure because the wrap MARKER (ts's __station__
 * property) must ride the callable itself, and PHP closures cannot carry
 * properties - `instanceof TransportWrap` is the marker.
 */
class TransportWrap
{
    public function __construct(
        private Station $station,
        /** The INSTANCE name (design 7.1), not the api slug. */
        private string $name,
        private mixed $inner,
    ) {
    }

    /** @return array{0: mixed, 1: mixed} */
    public function __invoke(mixed $fctx, string $fullurl, array $fetchdef): array
    {
        return $this->station->_transport(
            $this->name, $this->inner, $fctx, $fullurl, $fetchdef);
    }
}

/**
 * The hook bridge handed back to the feature (design station.md 3 item
 * 3): operation semantics correlated with the HTTP events via a per-op
 * id stashed on the SDK's own ctx.
 */
class FeatureBinding
{
    public function __construct(
        private Station $station,
        /** The INSTANCE name (design 7.1). The FIELD keeps its name so
         * the generated adapter contract is unchanged; for a
         * single-instance project it is the api slug, exactly as
         * before. */
        public readonly string $slug,
    ) {
    }

    public function PrePoint(mixed $ctx): void
    {
        $ctx->meta['station'] = [
            'corr' => 'c' . next_corr(),
            'start' => now_ms(),
        ];
    }

    public function PreDone(mixed $ctx): void
    {
        $this->station->_op_event($this->slug, $ctx, result_outcome($ctx));
    }

    public function PreUnexpected(mixed $ctx): void
    {
        $this->station->_op_event($this->slug, $ctx, 'unexpected');
    }
}

/**
 * Resolve the station this activation binds to: an explicit handle in
 * the feature options (connect/adopt and st->options() pass one), else
 * the ambient instance. No station open -> null: an activated feature
 * with no opened station is an inert no-op that emits nothing and fails
 * nothing (design station.md 3.1).
 */
function feature_binding(mixed $ctx, mixed $fopts): ?FeatureBinding
{
    $fopts = is_array($fopts) ? $fopts : [];
    $station = ($fopts['station'] ?? null) instanceof Station
        ? $fopts['station'] : Station::current();
    if (null === $station) {
        return null;
    }

    $client = $ctx->client;

    // Same construction, second arrival (generated feature + carried
    // adapter both active on one client): the first bind won, this one
    // is inert. See Station::_bound_entry.
    if (null !== $station->_bound_entry($client)) {
        return null;
    }

    $utility = $ctx->utility;
    $calleropts = $fopts['calleropts'] ?? null;

    // Position guard (design station.md 3.3): the wrap must sit
    // immediately outside the base transport - inside retry/cache/
    // ratelimit - or its http events stop being wire truth. Position in
    // client->features IS init order, so verify it and fail loudly.
    $names = [];
    foreach ($client->features as $f) {
        if (is_object($f) && method_exists($f, 'get_name')) {
            $names[] = $f->get_name();
        } else {
            $names[] = is_object($f) ? ($f->name ?? null) : null;
        }
    }
    $self_at = array_search('station', $names, true);
    $test_at = array_search('test', $names, true);
    $expected = false === $test_at ? 0 : $test_at + 1;
    if ($self_at !== $expected) {
        throw new StationError('station_wrap_order',
            'station must init immediately after the base transport; ' .
            'feature order is [' . implode(', ', array_map('strval', $names)) . ']');
    }

    // Design 7.5: registration is driven by station now. `fopts.instance`
    // is where station puts the instance name it knew before
    // construction began; _register reads it and falls back to the
    // descriptor slug, which is today's behaviour for a bare
    // connect(SDK).
    $reg = $station->_register($client, $ctx->config, $ctx->options, $calleropts, $fopts);
    $binding = $reg['binding'];
    $profile_plugin = $reg['profile_plugin'];
    // The INSTANCE name, not the api slug. Everything below keys on it -
    // the placeholder, the transport seam, the op events - because two
    // live instances of one api must be distinguishable at each.
    $name = $binding['plugin'];

    // Base URL precedence (design station.md 3.5): caller opts (7) beat
    // the profile (4), which beats the SDK's config default (1) already
    // in options['base']. PHP arrays are value types, so the rootctx's
    // options and the client's options are separate copies - both are
    // updated (the client copy is what options_map/prepare/entity ops
    // read; the ctx copy is what derived op contexts inherit).
    if (is_array($calleropts) && null === ($calleropts['base'] ?? null) &&
        is_array($profile_plugin) && null !== ($profile_plugin['base'] ?? null)) {
        $ctx->options['base'] = $profile_plugin['base'];
        if (is_array($client->options ?? null)) {
            $client->options['base'] = $profile_plugin['base'];
        }
    }

    // Policy allowlists (design station.md 16): `allow.op` /
    // `allow.method` are "the same vocabulary the SDKs already enforce
    // (options.allow, and the raw-access gate every target implements);
    // station sets these SDK options from policy so enforcement is in
    // the SDK's own pipeline". The SDK's own option form is a
    // comma-separated string, so the policy's list joins into it.
    // Applied at binding time, which is inside the constructor, and on
    // BOTH entry paths - connect/adopt and the declarative build both
    // delegate here. Unlike `base` above, which is a DEFAULT the caller
    // may override, an allowlist is ENFORCEMENT: policy wins over
    // whatever the options carry, on exactly the keys it sets.
    $pallow = is_array($profile_plugin) && is_array($profile_plugin['policy'] ?? null)
        ? ($profile_plugin['policy']['allow'] ?? null) : null;
    if (is_array($pallow)) {
        $allow = is_array($ctx->options['allow'] ?? null) ? $ctx->options['allow'] : [];
        if (is_array($pallow['op'] ?? null)) {
            $allow['op'] = implode(',', $pallow['op']);
        }
        if (is_array($pallow['method'] ?? null)) {
            $allow['method'] = implode(',', $pallow['method']);
        }
        $ctx->options['allow'] = $allow;
        if (is_array($client->options ?? null)) {
            $client->options['allow'] = $allow;
        }
    }

    if ('none' !== $binding['rung']) {
        $placeholder = $binding['placeholder'];

        // A real credential already resident in the options is hoisted
        // into the broker and replaced by the placeholder before
        // construction completes (design station.md 3.1 adopt) -
        // options_map() and prepare() output become placeholder-safe
        // from here on.
        $resident = is_array($ctx->options ?? null)
            ? ($ctx->options['apikey'] ?? null) : null;
        if (is_string($resident) && '' !== $resident && $placeholder !== $resident) {
            $station->_hoist($name, $resident);
        }
        $ctx->options['apikey'] = $placeholder;
        if (is_array($client->options ?? null)) {
            $client->options['apikey'] = $placeholder;
        }
    }

    // Wrap the transport. Copy-on-inject (design station.md 5.3) happens
    // inside Station::_transport; auth-inactive plugins skip credential
    // planning but the wrap still observes.
    $inner = $utility->fetcher;
    if ($inner instanceof TransportWrap) {
        throw new StationError('station_bound_twice',
            'plugin "' . $name . '" already carries a station wrap');
    }
    $utility->fetcher = new TransportWrap($station, $name, $inner);

    return new FeatureBinding($station, $name);
}

/**
 * The carried adapter: the retrofit path for SDKs generated without the
 * station feature (design station.md 3.1 adopt). A duck-typed feature
 * whose init/hooks delegate to feature_binding - it exists so
 * connect/adopt work on any regenerated SDK, and it must stay
 * behaviorally identical to the generated feature template in
 * sdkgen-station.
 */
class AdapterFeature
{
    public string $version = '0.0.1';
    public string $name = 'station';
    public bool $active = true;

    /**
     * feature_add reads _options for positioning: immediately after the
     * test feature's base transport (design station.md 3.3). When test
     * is absent from the add order this is a no-op append, which for a
     * bare SDK still lands the wrap immediately outside the base
     * transport.
     *
     * @var array<string, mixed>|null
     */
    public ?array $_options = ['__after__' => 'test'];

    public ?FeatureBinding $_binding = null;

    public function __construct(
        private Station $station,
        private mixed $calleropts,
    ) {
    }

    public function get_version(): string
    {
        return $this->version;
    }

    public function get_name(): string
    {
        return $this->name;
    }

    public function get_active(): bool
    {
        return $this->active;
    }

    public function init(mixed $ctx, mixed $fopts): void
    {
        $fopts = is_array($fopts) ? $fopts : [];
        $fopts['station'] = $this->station;
        $fopts['calleropts'] = $this->calleropts;
        $this->_binding = feature_binding($ctx, $fopts);
    }

    public function PrePoint(mixed $ctx): void
    {
        $this->_binding?->PrePoint($ctx);
    }

    public function PreDone(mixed $ctx): void
    {
        $this->_binding?->PreDone($ctx);
    }

    public function PreUnexpected(mixed $ctx): void
    {
        $this->_binding?->PreUnexpected($ctx);
    }
}

function adapter_feature(Station $station, mixed $calleropts): AdapterFeature
{
    return new AdapterFeature($station, $calleropts);
}

function result_outcome(mixed $ctx): string
{
    $result = $ctx->result ?? null;
    if (null === $result) {
        return 'unknown';
    }
    $err = is_object($result) ? ($result->err ?? null) : ($result['err'] ?? null);
    if (null !== $err) {
        return 'err';
    }
    $ok = is_object($result) ? ($result->ok ?? null) : ($result['ok'] ?? null);
    if (false === $ok) {
        return 'err';
    }
    return 'ok';
}
