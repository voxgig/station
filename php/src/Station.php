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
 *
 * The declarative front door (design 6) is here too: sdk()/create(),
 * the instance-keyed registry, instances()/features()/check()/warm().
 * php is synchronous throughout, so sdk() is a plain call and warm()
 * resolves serially over the deduplicated secret names.
 */

declare(strict_types=1);

namespace Voxgig\Station;

require_once __DIR__ . '/Error.php';
require_once __DIR__ . '/Kind.php';
require_once __DIR__ . '/Descriptor.php';
require_once __DIR__ . '/Events.php';
require_once __DIR__ . '/Shape.php';
require_once __DIR__ . '/Profile.php';
require_once __DIR__ . '/Secrets.php';
require_once __DIR__ . '/Feature.php';
require_once __DIR__ . '/Factory.php';
require_once __DIR__ . '/Loader.php';
require_once __DIR__ . '/Adapter.php';

/**
 * The ref grammar is the JOINT identity model's (station-and-plugin.md
 * 2, plugin design 4): a name is a package-ish specifier
 * (`^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`), a tag is not (`^[a-zA-Z0-9.~_-]+$`
 * or empty - it MAY start with a digit because auto-tagging assigns
 * integer tags, and admits neither `@` nor `/`); both cap at 1024; the
 * split is on the FIRST `$`, so `a$b$c` is a good name with a bad tag.
 */
const REF_NAME_RE = '/^[a-zA-Z@][a-zA-Z0-9.~_\-\/]*$/';
const REF_TAG_RE = '/^[a-zA-Z0-9.~_-]+$/';
const REF_MAX = 1024;

function check_instance_name(mixed $name): bool
{
    if (!is_string($name)) {
        return false;
    }
    if (0 === strlen($name) || REF_MAX < strlen($name)) {
        return false;
    }
    return 1 === preg_match(REF_NAME_RE, $name);
}

function check_instance_tag(mixed $tag): bool
{
    if (!is_string($tag)) {
        return false;
    }
    // The empty tag is an ordinary tag: the single-instance case writes
    // no tag and never learns tags exist.
    if (0 === strlen($tag)) {
        return true;
    }
    if (REF_MAX < strlen($tag)) {
        return false;
    }
    return 1 === preg_match(REF_TAG_RE, $tag);
}

/**
 * Validate a ref against the joint grammar and return its CANONICAL
 * spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
 * `stripe` are ONE registry key rather than two.
 */
function checkref(string $ref): string
{
    $cut = strpos($ref, '$');
    $name = false === $cut ? $ref : substr($ref, 0, $cut);
    $tag = false === $cut ? '' : substr($ref, $cut + 1);
    if (!check_instance_name($name)) {
        throw new StationError('station_instance_api',
            'invalid instance name "' . $name . '" in ref "' . $ref . '": a ' .
            'name starts with a letter or `@` and uses ' .
            '`[a-zA-Z0-9.~_-/]`, max 1024 (6.1)');
    }
    if (!check_instance_tag($tag)) {
        throw new StationError('station_instance_api',
            'invalid instance tag "' . $tag . '" in ref "' . $ref . '": a tag ' .
            'uses `[a-zA-Z0-9.~_-]`, max 1024 (6.1)');
    }
    return '' === $tag ? $name : $ref;
}

function checkapi(string $api, string $ref): string
{
    if (refapi($ref) !== $api) {
        throw new StationError('station_instance_api',
            'instance "' . $ref . '" names api "' . refapi($ref) . '", but ' .
            'the SDK passed is api "' . $api . '"; `as` is a tag, not a free ' .
            'name (6.1)');
    }
    return $ref;
}

/**
 * Design 6.1: `as` IS A TAG, NOT A FREE NAME.
 *
 * The api comes from the SDK being passed, so the resulting ref is
 * `<api>$<tag>` and multi-instance works imperatively too. A full ref is
 * also accepted and is VALIDATED: its name must equal the SDK's api
 * slug, or it is station_instance_api.
 *
 * A bare connect(SDK) with no name falls back to the descriptor slug,
 * which is today's behaviour and why the single-instance case is
 * unchanged to the byte.
 *
 * A `$`-LESS STRING IS ALWAYS A TAG: `as: 'stripe'` on api `stripe`
 * yields `stripe$stripe`, not `stripe`. 6.1 says twice and emphatically
 * that `as` is a tag rather than a free name, and a rule with no
 * exceptions is the one that ports the same way twenty times; collapsing
 * when the tag happens to equal the api would make `as` mean different
 * things at different values. Someone who wants the untagged instance
 * passes no `as` at all.
 */
function instance_ref(string $api, mixed $fopts): string
{
    $fopts = is_array($fopts) ? $fopts : [];

    $explicit = first_non_empty($fopts['instance'] ?? null);
    if (null !== $explicit) {
        return checkref(checkapi($api, $explicit));
    }

    $as = first_non_empty($fopts['as'] ?? null);
    // The bare fallback is the SLUG - a name, never a ref: a `$` in it
    // is an invalid name, not an implicit tag.
    if (null === $as) {
        if (!check_instance_name($api)) {
            throw new StationError('station_instance_api',
                'invalid instance name "' . $api . '": a name starts with a ' .
                'letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (6.1)');
        }
        return $api;
    }

    return checkref(!str_contains($as, '$') ? $api . '$' . $as : checkapi($api, $as));
}

/** The first non-empty value, as a string, or null. */
function first_non_empty(mixed ...$vals): ?string
{
    foreach ($vals as $v) {
        if (null !== $v && '' !== $v) {
            return (string) $v;
        }
    }
    return null;
}

class Station
{
    private static ?Station $ambient = null;
    private static ?string $ambient_opts = null;

    /** @var array<string, mixed> */
    private array $opts;
    /** The RAW config, kept for 8.7's provenance: the resolved profile
     * has already collapsed the levels provenance has to name. */
    public mixed $raw = null;
    /** Design 6.3: which side of the repo review boundary the config
     * came from - `package` is honoured only from inside it. */
    public bool $repo_scoped = true;
    /** @var array{name: string, providers: array<int, mixed>, api: array<string, array<string, mixed>>, sdk: array<string, array<string, mixed>>} */
    private array $profile;
    private SecretBroker $broker;
    private EventBuffer $buffer;
    /** Keyed by INSTANCE NAME (design 7.1). @var array<string, array<string, mixed>> */
    private array $registry = [];
    /** The sdk() cache: same name -> same client. @var array<string, object> */
    private array $clients = [];
    /** An auto-assigned tag -> the DECLARED instance it stands for
     * (5.3). @var array<string, string> */
    private array $alias_of = [];
    /** The shared per-api descriptor cache (7.4). @var array<string, array<string, mixed>> */
    private array $descriptor_cache = [];
    private bool $require_proxy;
    private bool $closed = false;

    /**
     * Design 6.2's second path, and the front door the docs name.
     * Delegates to the same process-global table the free function
     * fills; there is one registry, not two.
     *
     * @param array<string, mixed> $factory ['construct' => callable, 'config' => mixed]
     */
    public static function provide(mixed $api, array $factory): void
    {
        provide($api, $factory);
    }

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

        // Design 6.3. EXPLICIT WINS, then an in-code config (the
        // application wrote it, so it is repo-scoped by construction),
        // then where the file was found. Inferring BEFORE reading the
        // explicit option is a real precedence bug: it makes
        // `repo_scoped: false` unsettable for any caller passing a
        // config in code, which is every test of the rule.
        $explicit = $this->opts['repo_scoped'] ?? ($this->opts['repoScoped'] ?? null);
        if (is_bool($explicit)) {
            $this->repo_scoped = $explicit;
        } elseif (array_key_exists('config', $this->opts)) {
            $this->repo_scoped = true;
        } else {
            $this->repo_scoped = 'user' !== config_scope(
                is_string($this->opts['folder'] ?? null) ? $this->opts['folder'] : null);
        }

        // Normalize, then validate (design 4.2). A malformed
        // station.json fails open() with EVERY error at once - an
        // eighteen-instance config must not die because the eighteenth
        // has a typo'd package name.
        //
        // resolve_profile then reads the RAW config, NOT the normalized
        // one. The normalized form is an input to validation and to
        // nothing else: block defaults synthesized before the profile
        // merge would let a one-key overlay overwrite the base's
        // `active: false` and silently re-enable a barred integration
        // (3.3, 4.2).
        if (null !== $config) {
            validate_config(normalize_config($config));
        }

        $this->raw = $config;
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
     * activation entry; the profile's per-instance base is applied by
     * the adapter at init (caller opts still win).
     *
     * Design 6.1: `options(instanceName?, extra?)`. THE NAME IS OPTIONAL
     * AND LEADING, so every existing `options([...])` call is unchanged
     * - the inverted binding is the static languages' path and they need
     * to say which instance they are building without a second method.
     *
     * @return array<string, mixed>
     */
    public function options(mixed $a = null, mixed $b = null): array
    {
        $named = is_string($a);
        $instance = $named ? $a : null;
        $extra = $named ? $b : $a;
        $extra = is_array($extra) ? $extra : [];

        $fmap = is_array($extra['feature'] ?? null) ? $extra['feature'] : [];
        $sf = is_array($fmap['station'] ?? null) ? $fmap['station'] : [];
        $sf['active'] = true;
        $sf['station'] = $this;
        $sf['calleropts'] = $extra;
        if (null !== $instance) {
            $sf['instance'] = $instance;
        }
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
     * instance still fails _register's key check (10.2).
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
     * The profile block that governs an instance - its own if the
     * profile declares it, otherwise its API'S.
     *
     * resolve_profile builds `profile.sdk` from the declared refs alone
     * ("an api block declares no instance, so the ref set comes from the
     * two `sdk` maps"), shallow-merging `profile.api[a]` into each. That
     * is right for a declared instance and leaves an IMPERATIVE one -
     * connect(SDK, ['as' => 'test']), named but never written into
     * config - with no block at all. The api-level `secret`, `base` and
     * most seriously `policy.hosts` then did not reach it, so a profile
     * that denies egress everywhere denied nothing for a tagged client.
     *
     * ONE RULE, ONE PLACE: registration and the transport seam both ask
     * here, because them disagreeing is how the credential and the
     * allowlist came apart in the first place.
     *
     * @return array<string, mixed>|null
     */
    public function block_for(string $name): ?array
    {
        $own = $this->profile['sdk'][$this->declared_ref($name)] ?? null;
        if (null !== $own) {
            return $own;
        }
        return $this->profile['api'][refapi($name)] ?? null;
    }

    /**
     * The DECLARED instance an assigned tag stands for, or the name
     * itself. create('stripe$prod') registers under `stripe$1`, and
     * every question about that client's configuration - its secret, its
     * base, its egress policy - is a question about `stripe$prod`.
     */
    public function declared_ref(string $name): string
    {
        return $this->alias_of[$name] ?? $name;
    }

    /**
     * @return array{binding: array<string, mixed>, profile_plugin: array<string, mixed>|null}
     */
    public function _register(mixed $client, mixed $config, mixed $options,
        mixed $_calleropts, mixed $fopts = null): array
    {
        $normalized = $this->describe($config);
        $descriptor = $normalized['descriptor'];
        $warnings = $normalized['warnings'];
        $api = (string) $descriptor['slug'];

        $fopts = is_array($fopts) ? $fopts : [];

        // Design 7.5: station knows the instance name before
        // construction begins and passes it through the feature options.
        // A bare connect(SDK) with no name falls back to the descriptor
        // slug, which is today's behaviour.
        $name = instance_ref($api, $fopts);

        // Design 7.1: the check moves to the INSTANCE key. Two clients
        // of one api is the NORMAL case now; two bindings of one
        // instance is still the error it was.
        if (isset($this->registry[$name])) {
            throw new StationError('station_bound_twice',
                'instance "' . $name . '" is already registered; binding one ' .
                'client twice is an error (10.2)');
        }

        $profile_plugin = $this->block_for($name);

        // Secret name precedence: the feature option (in-code, design
        // station.md 9 config.options.secret) beats the profile, which
        // beats the INSTANCE-derived default - and the default takes the
        // DECLARED ref, not the assigned tag, so every per-request
        // client of one instance shares one broker cache entry (5.3).
        //
        // The descriptor's own `auth.secretname` stays the API-level
        // default and is NOT used here (7.4): one descriptor is shared
        // by every instance of an api and cannot hold two
        // instance-derived names.
        $secretname = first_non_empty(
            $fopts['secret'] ?? null,
            is_array($profile_plugin) ? ($profile_plugin['secret'] ?? null) : null)
            ?? secretname_default($this->declared_ref($name));

        $auth_active = true === $descriptor['auth']['active'];
        $rung = $auth_active ? 'R1' : 'none';
        $binding = [
            'plugin' => $name,
            'api' => $api,
            // Design 7.2: two live instances of one api MUST have
            // distinct placeholders or the injection seam cannot tell
            // which credential a header wants.
            'placeholder' => $auth_active ? placeholder_for($name) : null,
            'secretname' => $auth_active ? $secretname : null,
            'rung' => $rung,
        ];

        $this->registry[$name] = [
            'name' => $name, 'api' => $api, 'descriptor' => $descriptor,
            'rung' => $rung, 'client' => $client, 'warnings' => $warnings,
            'secretname' => $auth_active ? $secretname : null,
        ];

        foreach ($warnings as $w) {
            $this->emit(['t' => now_ms(), 'kind' => 'station',
                'plugin' => $name, 'api' => $api, 'meta' => ['warn' => $w]]);
        }
        $this->emit([
            't' => now_ms(), 'kind' => 'construct', 'plugin' => $name, 'api' => $api,
            'meta' => [
                'name' => $descriptor['name'],
                'version' => $descriptor['version'],
                'rung' => $rung,
            ],
        ]);

        return ['binding' => $binding, 'profile_plugin' => $profile_plugin];
    }

    /**
     * Design 7.4: THE DESCRIPTOR IS SHARED, because it describes the api
     * rather than any use of it. normalize_descriptor runs once per api
     * and every instance of that api holds the same value - at 26
     * instances over 20 apis that is 20 normalizations, not 26, and the
     * canonical serialization the proxy dedupes registrations by is
     * computed once per api too.
     *
     * Normalized with NO per-instance features, so the shared value
     * holds only API-stable metadata - which is what the factory table
     * already does at provide time. Per-instance activation is
     * features_of(name)'s answer; a cache keyed by slug but built from
     * the first instance's feature map would make descriptor_of()
     * construction-order-dependent.
     *
     * @return array{descriptor: array<string, mixed>, warnings: string[]}
     */
    public function describe(mixed $config): array
    {
        $slug = is_array($config) && is_array($config['main'] ?? null)
            ? (string) ($config['main']['slug'] ?? '') : '';
        if ('' !== $slug && isset($this->descriptor_cache[$slug])) {
            return $this->descriptor_cache[$slug];
        }
        $out = normalize_descriptor($config, null);
        $this->descriptor_cache[(string) $out['descriptor']['slug']] = $out;
        return $out;
    }

    public function _hoist(string $name, string $value): void
    {
        $this->broker->hoist($name, $value);
        $this->emit([
            't' => now_ms(), 'kind' => 'station',
            'plugin' => $name, 'api' => refapi($name),
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
     * that was current at init time. `name` is the INSTANCE. Returns the
     * SDK's [response, err] tuple.
     *
     * @return array{0: mixed, 1: mixed}
     */
    public function _transport(string $name, mixed $inner, mixed $fctx,
        string $fullurl, array $fetchdef): array
    {
        // Fail-closed means traffic (2.1): with the proxy deferred,
        // `require` can never attach, so every operation fails here -
        // the operation path, never the constructor.
        if ($this->require_proxy) {
            $err = new StationError('station_no_proxy',
                'proxy: "require" is set and no proxy is attached');
            $this->emit_err($name, $fctx, $err);
            return [null, $err];
        }

        $entry = $this->registry[$name] ?? null;
        $placeholder = placeholder_for($name);
        $live = 'live' === ($fctx->client->mode ?? null);
        $profile_plugin = $this->block_for($name);

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
                    'of plugin "' . $name . '"');
                $this->emit_err($name, $fctx, $err);
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
            // Design 7.4: THE EFFECTIVE NAME, resolved once at
            // registration and stored on the entry. Re-deriving it here
            // gets the precedence right and the FALLBACK wrong:
            // `descriptor.auth.secretname` is the API-level default, and
            // one descriptor is shared by every instance of an api - so
            // a tagged instance with no explicit `secret` would read
            // `stripe.apikey` where registration recorded
            // `stripe_test.apikey`. No fallback: this branch is guarded
            // by the same condition that populates the field.
            $secretname = (string) $entry['secretname'];

            try {
                $value = $this->broker->value($name, $secretname);
            } catch (\Throwable $e) {
                $this->emit_err($name, $fctx, $e);
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
            $this->emit_http($name, $corr, $fullurl, $senddef, 0, $started, 0);
            $this->emit_err($name, $fctx, $e);
            throw $e;
        }

        if (null !== $err) {
            $this->emit_http($name, $corr, $fullurl, $senddef, 0, $started, 0);
            $this->emit_err($name, $fctx, $err);
            return [$res, $err];
        }

        $status = is_array($res) && is_numeric($res['status'] ?? null)
            ? (int) $res['status'] : 0;

        if (0 === $status) {
            // The php base transport's stream branch synthesizes a
            // status-0 response (no err) for network-level failures; map
            // it to the same events the ts library emits when its
            // transport throws.
            $this->emit_http($name, $corr, $fullurl, $senddef, 0, $started, 0);
            if (is_array($res)) {
                $message = (string) ($res['statusText'] ?? '');
                $message = '' === $message ? 'transport failure' : $message;
                $this->emit(['t' => now_ms(), 'kind' => 'error',
                    'plugin' => $name, 'api' => refapi($name), 'corr' => $corr,
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
        $this->emit_http($name, $corr, $fullurl, $senddef, $status, $started, $bytes);

        return [$res, $err];
    }

    /** Op events from the hook bridge (design station.md 3 item 3). */
    public function _op_event(string $name, mixed $ctx, string $outcome): void
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
            't' => now_ms(), 'kind' => 'op', 'plugin' => $name,
            'api' => refapi($name),
            'corr' => $st['corr'] ?? null,
            'op' => [
                'entity' => $entity,
                'op' => $opname,
                'outcome' => $outcome,
                'durationMs' => isset($st['start']) ? now_ms() - $st['start'] : 0,
            ],
        ]);
    }

    // --- the declarative front door (design station.md 6) ---

    /**
     * The instance, constructed on first call and CACHED: same name ->
     * same object. That caching is what makes "get it where you need it"
     * a real instruction - call it in a request handler, in a worker, in
     * a test, and the first call pays construction while the rest are a
     * map lookup.
     */
    public function sdk(string $name): object
    {
        if (isset($this->clients[$name])) {
            return $this->clients[$name];
        }
        $client = $this->build($name, null);
        $this->clients[$name] = $client;
        return $client;
    }

    /**
     * An UNCACHED client from the same resolved config plus overrides,
     * for the case that genuinely wants a distinct one - a per-request
     * credential scope, a test double. Deliberately the longer name.
     *
     * It registers under an AUTO-ASSIGNED TAG, because 7.5 registers
     * every constructed adapter under its instance name and
     * station_bound_twice fires on a second binding of one name: a
     * second create('stripe') would otherwise throw, which is exactly
     * the per-request case this exists for.
     *
     * @param array<string, mixed>|null $overrides
     */
    public function create(string $name, ?array $overrides = null): object
    {
        return $this->build($name, $this->autotag($name), $overrides);
    }

    /**
     * The lowest positive integer tag not already taken, by a LIVE
     * instance or a DECLARED one.
     *
     * THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
     * and until something constructs it the registry says false - so
     * create('stripe$prod') would take that identity, instances() would
     * report the declared `stripe$1` as live with the wrong client, and
     * a later sdk('stripe$1') would fail station_bound_twice against a
     * binding that was never its own. Declaration reserves the name
     * whether or not it has been built.
     */
    public function autotag(string $name): string
    {
        $api = refapi($name);
        for ($n = 1; ; $n++) {
            $ref = $api . '$' . $n;
            if (!isset($this->registry[$ref]) &&
                !isset($this->profile['sdk'][$ref])) {
                return $ref;
            }
        }
    }

    /**
     * The shared construction path behind sdk() and create().
     *
     * @param array<string, mixed>|null $overrides
     */
    public function build(string $name, ?string $as = null, ?array $overrides = null): object
    {
        if ($this->closed) {
            throw new StationError('station_no_plugin', 'station is closed');
        }

        $block = $this->profile['sdk'][$name] ?? null;
        if (null === $block) {
            $declared = array_keys($this->profile['sdk']);
            sort($declared, SORT_STRING);
            throw new StationError('station_no_instance',
                'no declared instance "' . $name . '"; declared: [' .
                implode(', ', $declared) . ']');
        }
        if (false === ($block['active'] ?? null)) {
            throw new StationError('station_instance_inactive',
                'instance "' . $name . '" is declared with `active: false`, ' .
                'which bars it from running while keeping it visible in ' .
                'instances()');
        }

        $api = refapi($name);
        $entry = $this->resolve_factory($api, $block);

        // Design 8.5 VALIDATES HERE, not only in check(). The schema
        // arrives with the factory, so the moment a factory is resolved
        // is the first moment validation is possible - and running it in
        // check() alone left two gaps: production sdk() silently ignored
        // an unknown option like `retry.retires`, and check() itself
        // missed the case where the factory is discovered by the LOADER
        // (its pre-check sees no registered factory, then sdk() loads
        // and constructs unvalidated). One call here closes both,
        // because EVERY path to a constructor comes through this line.
        $resolved = $this->features_of($name);
        $faults = check_features($resolved['merged'], $entry['descriptor']);
        if (0 < count($faults)) {
            throw new StationError((string) $faults[0]['code'],
                implode('; ', array_map(fn($f) => (string) $f['message'], $faults)));
        }

        // Design 8.4: compose the merged feature map into the ORDERED
        // form and hand it to the constructor. No new seam - it is the
        // same options['feature'] map connect() already uses for
        // station's own placement, with more in it, and a php array
        // preserves insertion order so the order rides the map.
        //
        // Station's own entry is composed AFTER the user merge and
        // always wins (8.4), which is why `station` is dropped here and
        // added by options(): a config file that can switch off the
        // component reading it is not a surface, it is a trap.
        // `feature.station` is already station_feature_reserved at
        // validation, so this is the second half of one rule.
        $rows = [];
        foreach (resolve_order($resolved['merged']) as $row) {
            if ('station' !== $row['name']) {
                $rows[] = $row;
            }
        }
        $fmap = [];
        foreach (compose_features($rows) as $f) {
            $fname = (string) $f['name'];
            unset($f['name']);
            $fmap[$fname] = $f;
        }

        $opts = is_array($block['options'] ?? null) ? $block['options'] : [];
        if (null !== ($block['base'] ?? null)) {
            $opts['base'] = $block['base'];
        }
        foreach (($overrides ?? []) as $k => $v) {
            $opts[$k] = $v;
        }
        $ofeature = is_array(($overrides ?? [])['feature'] ?? null)
            ? $overrides['feature'] : [];
        foreach ($ofeature as $k => $v) {
            $fmap[$k] = $v;
        }
        $opts['feature'] = $fmap;

        // RECORD THE ALIAS, NOT THE FIELDS. Carrying the declared
        // `secret` through the feature options and stopping there leaves
        // `policy`, `base` and everything else behind, so an auto-tagged
        // client silently loses its declared instance's HOSTS ALLOWLIST
        // and falls back to the wider api-level one. Recording what the
        // tag STANDS FOR is one rule every lookup already goes through.
        //
        // Only when the tag was ASSIGNED - a caller naming its own is
        // naming an instance, not aliasing one.
        if (null !== $as && $as !== $name) {
            $this->alias_of[$as] = $name;
        }

        // ...AND THE CARRIED ADAPTER RIDES EXTEND, exactly as on
        // connect. The 3.1 retrofit case - an SDK generated before the
        // station feature, which factory_from_module explicitly supports
        // - has no generated feature to consume the `feature.station`
        // activation this path sets, so a declarative sdk() without this
        // either fails on an unknown feature or returns an unregistered,
        // unwrapped client with no credential injection and no events.
        // Safe on a regenerated SDK too: the constructor uses its own
        // station feature and skips the extend copy by name, and both
        // delegate to feature_binding, whose already-bound check no-ops
        // a second arrival for the same client.
        $extend = is_array($opts['extend'] ?? null) ? $opts['extend'] : [];
        $extend[] = adapter_feature($this, $opts);
        $with_adapter = $opts;
        $with_adapter['extend'] = $extend;

        // The instance name reaches the adapter the same way it does on
        // the imperative path, so registration has one spelling (7.5).
        if (!is_callable($entry['construct'] ?? null)) {
            throw new StationError('station_no_factory',
                'the factory registered for api "' . $api . '" has no ' .
                '`construct`; a factory is a constructor PLUS the SDK\'s ' .
                'static config (6.2)');
        }
        $client = ($entry['construct'])($this->options($as ?? $name, $with_adapter));
        if (!is_object($client)) {
            throw new StationError('station_no_factory',
                'the factory for api "' . $api . '" returned no client');
        }
        return $client;
    }

    /**
     * Design 6.2's paths, in order of preference: self-registration or
     * an explicit provide(), then the loader.
     *
     * @param array<string, mixed> $block
     * @return array<string, mixed>
     */
    public function resolve_factory(string $api, array $block): array
    {
        $direct = factory_for($api);
        if (null !== $direct) {
            return $direct;
        }

        $pkg = $this->loader_package($api, $block);
        if (null !== $pkg) {
            load_sync($api, $pkg,
                is_string($block['export'] ?? null) ? $block['export'] : null);
            $loaded = factory_for($api);
            if (null !== $loaded) {
                return $loaded;
            }
        }

        throw new StationError('station_no_factory',
            'no factory for api "' . $api . '"; either link a generated ' .
            'package that self-registers, call Station::provide("' . $api .
            '", ...), or set `api.' . $api . '.package` so the loader can ' .
            'import it');
    }

    /**
     * `package` is honoured only from repo-scoped config (design 6.3),
     * and a user-level one is IGNORED WITH A WARNING rather than
     * imported - it names code to load and sits outside the repo's
     * review boundary.
     *
     * @param array<string, mixed> $block
     */
    public function loader_package(string $api, array $block): ?string
    {
        $pkg = $block['package'] ?? null;
        if (null === $pkg || '' === $pkg) {
            return null;
        }
        if (false === ($this->opts['load'] ?? null)) {
            return null;
        }

        if (!$this->repo_scoped) {
            $this->emit([
                't' => now_ms(), 'kind' => 'station', 'plugin' => $api, 'api' => $api,
                'meta' => [
                    'warn' => 'ignoring `package` for api "' . $api . '": it ' .
                        'came from a user-level station.json, which is outside ' .
                        'the repo\'s review boundary; everything else in that ' .
                        'config still applies',
                ],
            ]);
            return null;
        }
        return (string) $pkg;
    }

    /**
     * Preload every declared active instance's package into the factory
     * table (design 6.3). php has ONE module system and no async, so
     * this is a plain synchronous call rather than ts/js's `await` - and
     * sdk() was synchronous all along, so nothing depends on it.
     * Station::open(['load' => false]) makes it inert.
     */
    public function load(): void
    {
        if (false === ($this->opts['load'] ?? null)) {
            return;
        }
        $names = array_keys($this->profile['sdk']);
        sort($names, SORT_STRING);
        foreach ($names as $name) {
            $block = $this->profile['sdk'][$name];
            if (false === ($block['active'] ?? null)) {
                continue;
            }
            $api = refapi((string) $name);
            if (null !== factory_for($api)) {
                continue;
            }
            $pkg = $this->loader_package($api, $block);
            if (null === $pkg) {
                continue;
            }
            load_sync($api, $pkg,
                is_string($block['export'] ?? null) ? $block['export'] : null);
        }
    }

    /**
     * The merged, ordered feature set for one instance, WITH PROVENANCE
     * (design 8.7): which config level set each value.
     *
     * Provenance is the half that makes a fleet view usable rather than
     * merely correct - at 26 instances "why is retry off here" is the
     * question, and a merged map alone cannot answer it.
     *
     * @return array{ordered: array<int, string>, merged: array<string, mixed>, from: array<string, array<string, string>>}
     */
    public function features_of(string $name): array
    {
        $api = refapi($name);
        $profiles = is_array($this->raw) && is_array($this->raw['profiles'] ?? null)
            ? $this->raw['profiles'] : [];
        $base = is_array($profiles['default'] ?? null) ? $profiles['default'] : [];
        $pname = $this->profile['name'];
        $overlay = 'default' === $pname
            ? [] : (is_array($profiles[$pname] ?? null) ? $profiles[$pname] : []);

        $levels = [
            'default.feature', 'default.api', 'default.sdk',
            $pname . '.feature', $pname . '.api', $pname . '.sdk',
        ];
        $sources = feature_sources($base, $overlay, $api, $name);

        // Last writer per (feature, key) wins, and the level that wrote
        // it is what `from` records.
        $from = [];
        foreach ($sources as $i => $src) {
            if (!is_map($src)) {
                continue;
            }
            foreach (map_entries($src) as $fname => $entry) {
                if (!is_map($entry)) {
                    continue;
                }
                $fname = (string) $fname;
                if (!isset($from[$fname])) {
                    $from[$fname] = [];
                }
                foreach (array_keys(map_entries($entry)) as $k) {
                    $from[$fname][(string) $k] = $levels[$i];
                }
            }
        }

        $merged = merge_features($sources);

        // Policy budget (design 16): rps/concurrency ceilings ride "the
        // SDK `ratelimit` feature, configured by station". Composed
        // HERE, into the merged map every consumer reads, rather than
        // patched in at construction alone - so build() orders it with
        // the ordinary constraint-and-band rules, check()'s 8.5 pass
        // catches a budget on an SDK with no ratelimit feature as
        // station_feature_unknown rather than a setting that quietly did
        // nothing, and the fleet view answers "is ratelimit on?"
        // truthfully.
        //
        // `rps` maps to the token bucket's refill `rate` (per second -
        // the same unit); `concurrency` to its capacity `burst`, the
        // number of requests that can be in flight from a full bucket.
        // POLICY WINS over a `feature.ratelimit` config entry on exactly
        // the keys it sets - it is enforcement, not a default - and
        // other tuning keys survive beside it.
        $block = $this->block_for($name);
        $budget = mval(mval($block, 'policy'), 'budget');
        if (is_map($budget)) {
            $prior = $merged['ratelimit'] ?? null;
            $entry = is_map($prior) ? map_entries($prior) : [];
            $entry['active'] = true;
            if (!isset($from['ratelimit'])) {
                $from['ratelimit'] = [];
            }
            $from['ratelimit']['active'] = 'policy.budget';
            $rps = mval($budget, 'rps');
            if (null !== $rps) {
                $entry['rate'] = $rps;
                $from['ratelimit']['rate'] = 'policy.budget';
            }
            $conc = mval($budget, 'concurrency');
            if (null !== $conc) {
                $entry['burst'] = $conc;
                $from['ratelimit']['burst'] = 'policy.budget';
            }
            $merged['ratelimit'] = $entry;
        }

        // THE IMPLICIT STATION ENTRY, added for ORDERING ONLY.
        // `station` is never in `merged` - `feature.station` is reserved
        // and rejected at validation (8.4) - so without it check_pin
        // finds no station row and is a PERMANENT NO-OP: a constraint
        // like `retry.order.after: 'station'` would be treated as
        // vacuous rather than rejected, and the reported order would
        // omit the one feature whose position is supposedly pinned.
        $fororder = $merged;
        $fororder['station'] = ['active' => true];
        $ordered = resolve_order($fororder);
        check_pin($ordered);

        return [
            'ordered' => array_map(fn($o) => (string) $o['name'], $ordered),
            'merged' => $merged,
            'from' => $from,
        ];
    }

    /**
     * The fleet feature view: instance x feature, effective options, and
     * which config level set each (design 8.7).
     *
     * The filter is either a STRING - shorthand for "this instance or
     * this api", loose - or a map ['instance'?, 'api'?, 'feature'?].
     * Only the map form can express the question the view exists for:
     * ['feature' => 'debug'], "is debug on anywhere?", the one that is
     * twenty greps today.
     *
     * @return array<int, array<string, mixed>>
     */
    public function features(mixed $filter = null): array
    {
        $loose = is_string($filter);
        $f = is_array($filter) ? $filter : [];
        $want_instance = $loose ? $filter : ($f['instance'] ?? null);
        $want_api = $loose ? $filter : ($f['api'] ?? null);

        $rows = [];
        foreach ($this->instances() as $r) {
            if ($loose) {
                if (null !== $want_instance &&
                    $r['name'] !== $want_instance && $r['api'] !== $want_api) {
                    continue;
                }
            } else {
                if (null !== $want_instance &&
                    $r['name'] !== $want_instance && $r['api'] !== $want_instance) {
                    continue;
                }
                if (null !== $want_api && $r['api'] !== $want_api) {
                    continue;
                }
            }
            $rows[] = array_merge(
                ['instance' => $r['name'], 'api' => $r['api']],
                $this->features_of($r['name']));
        }

        // `feature` filters the ROWS, not the instances: an instance
        // that does not carry the named feature is not part of the
        // answer, and the rows that remain are narrowed to it so the
        // view answers "where is debug on, and with what" rather than
        // "here is everything, go and look".
        $want = $loose ? null : ($f['feature'] ?? null);
        if (null === $want) {
            return $rows;
        }
        $out = [];
        foreach ($rows as $row) {
            if (!array_key_exists($want, $row['merged'])) {
                continue;
            }
            $out[] = [
                'instance' => $row['instance'],
                'api' => $row['api'],
                'ordered' => array_values(array_filter($row['ordered'],
                    fn($n) => $n === $want)),
                'merged' => [$want => $row['merged'][$want]],
                'from' => [$want => $row['from'][$want] ?? []],
            ];
        }
        return $out;
    }

    /**
     * Eagerly resolve and construct every ACTIVE declared instance - for
     * CI (design 6.6). The point is to turn availability errors, which
     * are deliberately deferred to first use, into ONE failure at a
     * moment somebody is watching.
     *
     * @return array{ok: array<int, string>, failed: array<int, array<string, mixed>>}
     */
    public function check(): array
    {
        $ok = [];
        $failed = [];
        foreach ($this->instances() as $row) {
            if (!$row['active']) {
                continue;
            }
            try {
                // 8.5 runs FIRST and needs no construction: the schema
                // arrives with the factory, not with a live client, so a
                // feature typo is a CI failure rather than a setting
                // that quietly did nothing in production.
                $entry = factory_for($row['api']);
                if (null !== $entry) {
                    $faults = check_features(
                        $this->features_of($row['name'])['merged'],
                        $entry['descriptor']);
                    if (0 < count($faults)) {
                        $failed[] = [
                            'name' => $row['name'],
                            'code' => (string) $faults[0]['code'],
                            'message' => implode('; ', array_map(
                                fn($x) => (string) $x['message'], $faults)),
                        ];
                        continue;
                    }
                }
                $this->sdk($row['name']);
                $ok[] = $row['name'];
            } catch (\Throwable $e) {
                $failed[] = [
                    'name' => $row['name'],
                    'code' => $e instanceof StationError ? $e->code() : null,
                    'message' => $e->getMessage(),
                ];
            }
        }
        return ['ok' => $ok, 'failed' => $failed];
    }

    /**
     * Batch-resolve secrets (design 5.5).
     *
     * With no argument it warms the ACTIVE declared instances only,
     * because reaching for a credential belonging to a disabled
     * integration is the wrong default. warm(names) warms exactly what
     * it is given, inactive included, because an explicit name is an
     * explicit request.
     *
     * THE REGISTRY IS THE AUTHORITY: a registered instance already
     * carries the resolved name, in-code `secret` feature option
     * included. A NAME NOBODY DECLARED OR REGISTERED IS A MISS, not a
     * lookup - a wider fallback would let a typo like `stripe$prodd`
     * derive a secret name and call the provider, so a nonexistent
     * instance could be reported `warmed` off a shared api-level
     * credential. Registered OR declared, and nothing else.
     *
     * php is synchronous and has no async idiom, so the plan is resolved
     * SERIALLY over the DEDUPLICATED secret names rather than
     * concurrently. The deduplication is the half that matters here: the
     * broker's cache is keyed by secret name, so several instances
     * sharing one api-level `secret` cost one round-trip either way.
     *
     * @param array<int, string>|null $names
     * @return array{warmed: array<int, string>, missed: array<int, string>}
     */
    public function warm(?array $names = null): array
    {
        $wanted = $names;
        if (null === $wanted) {
            $wanted = [];
            foreach ($this->instances() as $r) {
                if ($r['active']) {
                    $wanted[] = $r['name'];
                }
            }
        }

        $warmed = [];
        $missed = [];
        /** @var array<string, array<int, string>> $bysecret */
        $bysecret = [];
        foreach ($wanted as $name) {
            $name = (string) $name;
            $entry = $this->registry[$name] ?? null;
            if (null === $entry && !isset($this->profile['sdk'][$name])) {
                $missed[] = $name;
                continue;
            }
            $secretname = null !== $entry && null !== $entry['secretname']
                ? (string) $entry['secretname']
                : (first_non_empty(
                    is_array($this->block_for($name))
                        ? ($this->block_for($name)['secret'] ?? null) : null)
                    ?? secretname_default($this->declared_ref($name)));
            $bysecret[$secretname][] = $name;
        }

        foreach ($bysecret as $secretname => $snames) {
            $okay = true;
            try {
                $this->broker->value($snames[0], (string) $secretname);
            } catch (\Throwable $e) {
                $okay = false;
            }
            foreach ($snames as $n) {
                if ($okay) {
                    $warmed[] = $n;
                } else {
                    $missed[] = $n;
                }
            }
        }

        sort($warmed, SORT_STRING);
        sort($missed, SORT_STRING);
        return ['warmed' => $warmed, 'missed' => $missed];
    }

    /**
     * Every DECLARED instance (design 6.1) - a different question from
     * plugins(), and the answers differ routinely: a lazily-started
     * instance is `active: true` and not yet live.
     *
     * @return array<int, array<string, mixed>>
     */
    public function instances(): array
    {
        $names = array_keys($this->profile['sdk']);
        sort($names, SORT_STRING);
        $out = [];
        foreach ($names as $name) {
            $name = (string) $name;
            $block = $this->profile['sdk'][$name];
            $entry = $this->registry[$name] ?? null;
            $out[] = [
                'name' => $name,
                'api' => refapi($name),
                // `active: false` means BARRED FROM RUNNING - a
                // declaration that stays in the file and here while
                // being refused a client.
                'active' => false !== ($block['active'] ?? null),
                'live' => null !== $entry,
                'rung' => null !== $entry ? $entry['rung'] : 'none',
                'block' => $block,
            ];
        }
        return $out;
    }

    // --- the query/observe surface (design station.md 3.2, 6) ---

    /**
     * One entry per LIVE INSTANCE (design 6.1), and EXHAUSTIVE:
     * auto-tagged entries are NOT collapsed here, because inspection,
     * health reporting and cleanup all need to enumerate the clients
     * create() produced, which is exactly when you most want them.
     * Truncation is a presentation decision and belongs to status().
     *
     * @return array<int, array<string, mixed>>
     */
    public function plugins(): array
    {
        $out = [];
        foreach ($this->registry as $e) {
            $out[] = [
                'name' => $e['name'],
                'api' => $e['api'],
                // Retained: it is the api, which is what `slug` always
                // meant here, and dropping it would break every consumer
                // for no gain while the two are equal for untagged
                // instances.
                'slug' => $e['api'],
                'descriptor' => $e['descriptor'],
                'rung' => $e['rung'],
                'secretname' => $e['secretname'],
                'warnings' => $e['warnings'],
            ];
        }
        return $out;
    }

    /**
     * Design 7.4: accepts an INSTANCE name and returns its api's
     * descriptor - one value shared by every instance of that api.
     *
     * @return array<string, mixed>
     */
    public function descriptor_of(string $name): array
    {
        $entry = $this->registry[$name] ?? null;
        if (null === $entry) {
            throw new StationError('station_no_plugin', 'unknown plugin "' .
                $name . '"; known: [' .
                implode(', ', array_keys($this->registry)) . ']');
        }
        return $entry['descriptor'];
    }

    public function canonical_descriptor(string $name): string
    {
        return canonical_serialize($this->descriptor_of($name));
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
        foreach ($this->plugins() as $p) {
            // Design 7.1: the registry is keyed by INSTANCE, so a status
            // page that projects only `slug` shows two indistinguishable
            // rows for `stripe$test` and `stripe$live` and omits the
            // names it is keyed by - an operator cannot tell which one
            // is unhealthy. `slug` stays for compatibility; `name` and
            // `api` are what answer the question.
            $plugins[] = ['name' => $p['name'], 'api' => $p['api'],
                'slug' => $p['slug'], 'rung' => $p['rung']];
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
     * instance keys that matched no registered instance - a typo'd key
     * silently configuring nothing is the worst outcome for a
     * secrets-and-policy file (design station.md 11).
     */
    public function close(): void
    {
        if ($this->closed) {
            return;
        }
        foreach (array_keys($this->profile['sdk']) as $ref) {
            if (!isset($this->registry[$ref])) {
                $this->emit([
                    't' => now_ms(), 'kind' => 'station',
                    'meta' => [
                        'warn' => 'profile plugin key "' . $ref .
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
        // Design 6.1: `as` is a TAG, resolved against the api in
        // _register - the api comes from the SDK being passed and is not
        // knowable here until that SDK's config has been normalized.
        if (null !== ($opts['as'] ?? null)) {
            $sf['as'] = $opts['as'];
        }
        if (null !== ($opts['instance'] ?? null)) {
            $sf['instance'] = $opts['instance'];
        }
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

    private function emit_http(string $name, mixed $corr, string $fullurl,
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
            't' => $started, 'kind' => 'http', 'plugin' => $name,
            'api' => refapi($name), 'corr' => $corr,
            'http' => [
                'method' => is_array($fetchdef) && is_string($fetchdef['method'] ?? null)
                    ? $fetchdef['method'] : 'GET',
                'host' => $host, 'path' => $path, 'status' => $status,
                'durationMs' => now_ms() - $started, 'bytes' => $bytes,
            ],
        ]);
    }

    private function emit_err(string $name, mixed $fctx, mixed $err): void
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
            // Design 7.3's grouping contract: `plugin` is the INSTANCE
            // and `api` is what groups its siblings. Construction events
            // carrying both while runtime events carried only one is
            // grouping that works exactly until it is used.
            't' => now_ms(), 'kind' => 'error', 'plugin' => $name,
            'api' => refapi($name),
            'corr' => is_array($st) ? ($st['corr'] ?? null) : null,
            'err' => $ev_err,
        ]);
    }
}
