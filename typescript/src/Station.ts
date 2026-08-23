import { adapterFeature } from './adapter'
import { StationError } from './error'
import { EventBuffer } from './events'
import { canonicalSerialize, normalizeDescriptor, secretnameDefault } from './descriptor'
import {
  configScope, loadConfig, refapi, resolveProfile, selectProfile,
  ResolvedProfile,
} from './profile'
import { FactoryEntry, factoryFor } from './factory'
import { loadAsync, loadSync } from './loader'
import {
  checkfeatures, checkpin, composefeatures, featuresources, mergefeatures,
  resolveorder,
} from './feature'
import { normalizeConfig, validateConfig } from './shape'
import { SecretBroker, placeholderFor } from './secrets'
import {
  Binding, PluginEntry, ResolvedInstance, SdkBlock, StationEvent,
  StationOptions,
} from './types'

// The station library core, solo mode (design D1): fully functional
// in-process with no other component running. The proxy (D2) is a
// deferred amplifier - `require` therefore fails on the operation path
// (design §2.1/§14), and `auto` degrades to solo with one warning event.

/** §6.1: `as` IS A TAG, NOT A FREE NAME.
 *
 * The api comes from the SDK being passed, so the resulting ref is
 * `<api>$<tag>` and multi-instance works imperatively too. A full ref is
 * also accepted and is VALIDATED: its name must equal the SDK's api
 * slug, or it is `station_instance_api`.
 *
 * Both forms are needed because the imperative path is where the api is
 * implicit in an argument rather than written in a key. An `as` that
 * took an arbitrary name would reintroduce exactly the second-identity
 * problem the ref re-key removed: under the ref invariant
 * `as: 'solar-eu'` would denote the untagged `solar-eu` DEFINITION, not
 * an instance of the SDK just handed in, and registry grouping, api
 * defaults and every ref consumer would disagree about what it is.
 *
 * A bare connect(SDK) with no name falls back to the descriptor slug,
 * which is today's behaviour and why the single-instance case is
 * unchanged to the byte. */
export function instanceRef(api: string, fopts?: any): string {
  const explicit = firstNonEmpty(fopts?.instance)
  if (null != explicit) { return checkapi(api, explicit) }

  const as = firstNonEmpty(fopts?.as)
  if (null == as) { return api }

  // A full ref is validated against the api; a `$`-less string is a TAG
  // and is joined to it.
  //
  // §6.1 gives both branches and does not say how to disambiguate a
  // `$`-less string, which is a real ambiguity because a bare name is
  // itself a valid (untagged) ref: `as: 'stripe'` on api `stripe` could
  // read as the untagged ref `stripe` or as tag `stripe`. It is read as
  // a TAG, giving `stripe$stripe`, because §6.1 says twice and
  // emphatically that `as` is a tag rather than a free name, and a rule
  // with no exceptions is the one that ports the same way twenty times.
  // The alternative - collapsing when the tag happens to equal the api -
  // is a special case that would make `as` mean different things at
  // different values. Someone who wants the untagged instance passes no
  // `as` at all, which is the documented spelling for it.
  return -1 === as.indexOf('$') ? api + '$' + as : checkapi(api, as)
}

function checkapi(api: string, ref: string): string {
  if (refapi(ref) !== api) {
    throw new StationError('station_instance_api',
      'instance "' + ref + '" names api "' + refapi(ref) + '", but the SDK ' +
      'passed is api "' + api + '"; `as` is a tag, not a free name (§6.1)')
  }
  return ref
}

export class Station {
  private static ambient: Station | null = null
  private static ambientOpts: string | null = null

  private opts: StationOptions
  private profile: ResolvedProfile
  private broker: SecretBroker
  private buffer: EventBuffer
  private registry = new Map<string, PluginEntry>()
  // §6.1: `sdk(name)` caches; `create()` deliberately does not.
  private clients = new Map<string, any>()
  // The raw config, kept for §8.7's provenance: the resolved profile
  // has already collapsed the levels that provenance has to name.
  private raw: any = null
  private repoScoped = true
  private requireProxy: boolean
  private closed = false

  // Ambient instance (design §10.2): open() is the idempotent
  // process-wide singleton; a second open() with conflicting options is
  // an error; `new Station(opts)` stays isolated for tests and
  // multi-tenant hosts. open() is non-blocking - solo involves no
  // network, and the deferred proxy probe must never change that.
  static open(opts?: StationOptions): Station {
    const key = JSON.stringify(opts || {})
    if (null != Station.ambient) {
      if (key !== Station.ambientOpts) {
        throw new StationError('station_open_conflict',
          'Station.open() was already called with different options')
      }
      return Station.ambient
    }
    Station.ambient = new Station(opts)
    Station.ambientOpts = key
    return Station.ambient
  }

  // The ambient instance, or null - never creates one. The generated
  // station feature binds through this when no explicit handle rides
  // its options (design §3.1: binding is never implicit; only open()
  // creates the ambient instance).
  static current(): Station | null {
    return Station.ambient
  }

  // Test seam: drop the ambient instance.
  static reset(): void {
    Station.ambient = null
    Station.ambientOpts = null
  }

  constructor(opts?: StationOptions) {
    this.opts = opts || {}

    const config = undefined !== this.opts.config
      ? this.opts.config
      : loadConfig(this.opts.folder)

    // §6.3: an in-code config is repo-scoped by construction - the
    // application wrote it. A file is repo-scoped unless it came from
    // ~/.voxgig/station.json.
    // Explicit wins, then an in-code config (the application wrote it,
    // so it is repo-scoped by construction), then where the file was
    // found. Inferring BEFORE reading the explicit option was a real
    // precedence bug: it made `repoScoped: false` unsettable for any
    // caller passing a config in code, which is every test of the rule.
    this.repoScoped = this.opts.repoScoped
      ?? (undefined !== this.opts.config
        ? true
        : 'user' !== configScope(this.opts.folder))

    // Normalize, then validate (design §4.2). A malformed station.json
    // fails open() with EVERY error at once - an eighteen-instance
    // config must not die because the eighteenth has a typo'd package
    // name.
    //
    // resolveProfile then reads the RAW config, NOT the normalized one.
    // The normalized form is an input to validation and to nothing
    // else: block defaults synthesized before the profile merge would
    // let a one-key overlay overwrite the base's `active: false` and
    // silently re-enable a barred integration (§3.3, §4.2).
    if (null != config) {
      validateConfig(normalizeConfig(config))
    }

    this.raw = config ?? null
    this.profile = resolveProfile(config ?? null, selectProfile(this.opts.profile))
    this.broker = new SecretBroker(this.profile.providers)
    this.buffer = new EventBuffer()

    const proxy = this.opts.proxy ?? 'auto'
    this.requireProxy = 'require' === proxy

    if ('auto' === proxy) {
      // The probe is deferred with the proxy itself; absence degrades
      // to solo with a single warning event naming the cause (§14).
      this.emit({
        t: Date.now(), kind: 'station',
        meta: { warn: 'proxy absent (not found); running solo' },
      })
    }
  }

  // --- binding forms (design §3.1) ---

  // connect(SDK, opts): station constructs the SDK itself, activating
  // the adapter with §3.3 ordering. The activation entry plus the
  // extend-supplied instance ride the tolerance added to the generated
  // constructor (sdkgen §9.3 change).
  connect(SDK: any, opts?: any): any {
    return this.construct(SDK, opts)
  }

  // adopt(SDK, opts): the retrofit path - construction-time sugar, not
  // post-hoc attachment (§3.1). In ts it is the same construction as
  // connect; a resident options.apikey is hoisted by the adapter.
  adopt(SDK: any, opts?: any): any {
    return this.construct(SDK, opts)
  }

  private construct(SDK: any, opts?: any): any {
    if (this.closed) {
      throw new StationError('station_no_plugin', 'station is closed')
    }
    opts = opts || {}
    const fmap = { ...(opts.feature || {}) }
    fmap['station'] = {
      ...(fmap['station'] || {}),
      active: true, station: this, calleropts: opts,
      // §6.1: `as` is a TAG, resolved against the api in _register -
      // the api comes from the SDK being passed and is not knowable
      // here until that SDK's config has been normalized.
      ...(null == opts.as ? {} : { as: opts.as }),
      ...(null == opts.instance ? {} : { instance: opts.instance }),
    }
    const options = {
      ...opts,
      feature: fmap,
      // The carried adapter rides extend for SDKs generated WITHOUT
      // the station feature; when the generated class exists the
      // constructor uses it and the extend copy is skipped by name
      // (both delegate to featureBinding, so behavior is identical).
      extend: [...(opts.extend || []), adapterFeature(this, opts)],
    }
    return new SDK(options)
  }

  // Inverted binding (design §3.1): build the plain options map a
  // generated constructor already accepts - the handle, the activation
  // entry, and the profile's per-plugin base (applied here, at
  // options-build time, so caller opts passed in `extra` still win).
  // §6.1: `options(instanceName?, extra?)`. The name is optional and
  // leading, so every existing `options({...})` call is unchanged - the
  // inverted binding is the static languages' path and they need to say
  // which instance they are building without a second method.
  options(a?: any, b?: any): any {
    const named = 'string' === typeof a
    const instance: string | undefined = named ? a : undefined
    const extra = (named ? b : a) || {}
    const fmap = { ...(extra.feature || {}) }
    fmap['station'] = {
      ...(fmap['station'] || {}),
      active: true, station: this, calleropts: extra,
      ...(null == instance ? {} : { instance }),
    }
    return { ...extra, feature: fmap }
  }

  // --- registration (design §3 item 1, called by the adapter) ---

  // The registry entry whose client IS this object, or null. Used by
  // featureBinding for idempotency: connect/adopt activate the station
  // entry AND ride the carried adapter on extend, so on an SDK whose
  // generated config carries a real station feature class the same
  // construction reaches featureBinding twice - the second arrival
  // must no-op, while a genuinely second client of the same SDK class
  // still fails _register's slug check (§10.2).
  _boundEntry(client: any): PluginEntry | null {
    for (const entry of this.registry.values()) {
      if (entry.client === client) { return entry }
    }
    return null
  }

  /** The profile block that governs an instance — its own if the
   * profile declares it, otherwise its **api's**.
   *
   * `resolveProfile` builds `profile.sdk` from the declared refs alone
   * ("an api block declares no instance, so the ref set comes from the
   * two `sdk` maps"), shallow-merging `profile.api[a]` into each. That
   * is right for a declared instance and leaves an IMPERATIVE one —
   * `connect(SDK, { as: 'test' })`, named but never written into
   * config — with no block at all. The api-level `secret`, `base` and
   * most seriously `policy.hosts` then did not reach it, so a profile
   * that denies egress everywhere denied nothing for a tagged client.
   *
   * ONE RULE, ONE PLACE: registration and the transport seam both ask
   * here, because they disagreeing is how the credential and the
   * allowlist came apart in the first place. */
  private blockFor(name: string): SdkBlock | undefined {
    return this.profile.sdk[name] ?? this.profile.api[refapi(name)]
  }

  _register(client: any, config: any, options: any, _calleropts: any,
    fopts?: any):
    { binding: Binding, profilePlugin?: SdkBlock } {

    const { descriptor, warnings } = this.describe(config, options.feature)
    const api = descriptor.slug

    // §7.5: station knows the instance name before construction begins
    // and passes it through the feature options. A bare connect(SDK)
    // with no name falls back to the descriptor slug, which is today's
    // behaviour and why the single-instance case is unchanged.
    const name = instanceRef(api, fopts)

    // §7.1: the check moves to the instance key. Two clients of one api
    // is the NORMAL case now; two bindings of one instance is still the
    // error it was.
    if (this.registry.has(name)) {
      throw new StationError('station_bound_twice',
        'instance "' + name + '" is already registered; binding one client ' +
        'twice is an error (§10.2)')
    }

    const profilePlugin = this.blockFor(name)
    // Secret name precedence: the feature option (in-code, design §9
    // config.options.secret) beats the profile, which beats the
    // INSTANCE-derived default.
    //
    // §5.1: `secretnameDefault` takes the instance name, not the slug.
    // For an untagged instance the two are the same string, so the
    // single-instance case is unchanged to the byte - `voxgig-solardemo`
    // still derives `voxgig_solardemo.apikey` and still reads
    // VOXGIG_SOLARDEMO_APIKEY. `stripe$test` derives
    // `stripe_test.apikey`, because each instance IS a separate
    // credentialed use of the API.
    //
    // The descriptor's own `auth.secretname` stays the API-level
    // default and is NOT used here (§7.4): one descriptor is shared by
    // every instance of an api and cannot hold two instance-derived
    // names, so whichever instance built the cached copy would report
    // the other's secret metadata wrongly. This is the authority; that
    // field is documentation.
    const secretname = firstNonEmpty(fopts?.secret, profilePlugin?.secret) ||
      secretnameDefault(name)

    const rung = descriptor.auth.active ? 'R1' : 'none'
    const binding: Binding = {
      plugin: name,
      instance: api,
      // §7.2: two live instances of one api MUST have distinct
      // placeholders or the injection seam cannot tell which credential
      // a header wants.
      placeholder: descriptor.auth.active ? placeholderFor(name) : undefined,
      secretname: descriptor.auth.active ? secretname : undefined,
      rung,
    }

    this.registry.set(name, {
      name, api, descriptor, rung, client, warnings,
      secretname: descriptor.auth.active ? secretname : undefined,
    })

    for (const w of warnings) {
      this.emit({
        t: Date.now(), kind: 'station', plugin: name, api,
        meta: { warn: w },
      })
    }
    this.emit({
      t: Date.now(), kind: 'construct', plugin: name, api,
      meta: { name: descriptor.name, version: descriptor.version, rung },
    })

    return { binding, profilePlugin }
  }

  // §7.4: THE DESCRIPTOR IS SHARED, because it describes the api rather
  // than any use of it. `normalizeDescriptor` runs once per api and
  // every instance of that api holds a reference to the same object - at
  // 26 instances over 20 apis that is 20 normalizations, not 26, and the
  // canonical serialization the proxy dedupes registrations by is
  // computed once per api too.
  //
  // Keyed by the slug the config carries, which is available before
  // normalization only from the config itself, so the miss path
  // normalizes and then keys on the result.
  private descriptorCache = new Map<string, { descriptor: any, warnings: string[] }>()

  private describe(config: any, feature: any):
    { descriptor: any, warnings: string[] } {
    const slug = String(config?.main?.slug ?? '')
    if ('' !== slug) {
      const hit = this.descriptorCache.get(slug)
      if (null != hit) { return hit }
    }
    const out = normalizeDescriptor(config, feature)
    this.descriptorCache.set(out.descriptor.slug, out)
    return out
  }

  _hoist(name: string, value: string): void {
    this.broker.hoist(name, value)
    this.emit({
      t: Date.now(), kind: 'station', plugin: name,
      meta: {
        warn: 'a resident credential was hoisted into the broker and ' +
          'replaced by the placeholder; prefer configuring the secret ' +
          'name and letting sekreto resolve it',
      },
    })
  }

  // --- the transport middleware (design §3.3, §5.3) ---

  async _transport(name: string, inner: any, fctx: any, fullurl: string,
    fetchdef: any): Promise<any> {

    // Fail-closed means traffic (§2.1): with the proxy deferred,
    // `require` can never attach, so every operation fails here - the
    // operation path, never the constructor.
    if (this.requireProxy) {
      const err = new StationError('station_no_proxy',
        'proxy: "require" is set and no proxy is attached')
      this.emitErr(name, fctx, err)
      return err
    }

    const entry = this.registry.get(name)
    const placeholder = placeholderFor(name)
    const live = 'live' === fctx.client._mode
    const profilePlugin = this.blockFor(name)

    // Egress policy (design §16), solo half: the hosts allowlist is
    // enforced at the seam every request crosses. When a policy is
    // present, redirects come back manual - a 3xx is a response like
    // any other, so a Location off the allowlist cannot pull an
    // automatic credentialed follow-up to an unapproved host (§8.2's
    // rule, applied at the library seam).
    const hosts = profilePlugin?.policy?.hosts
    if (null != hosts && live) {
      let hostname = ''
      try { hostname = new URL(fullurl).hostname } catch (_e) { }
      if (!hosts.includes(hostname)) {
        const err = new StationError('station_host_allow',
          'egress to "' + hostname + '" denied by the hosts policy of ' +
          'plugin "' + name + '"')
        this.emitErr(name, fctx, err)
        return err
      }
    }

    let senddef = fetchdef
    if (null != hosts && live) {
      senddef = { ...senddef, redirect: 'manual' }
    }

    // Injection: at the last boundary, below every recording feature,
    // and never into mock transports (§3.3) - in test/mock modes the
    // placeholder rides through untouched, so real credentials never
    // enter in-memory mock stores. Copy-on-inject: the object graph
    // reachable from ctx/spec/ctrl keeps the placeholder, ever (§5.3).
    if (live && null != entry && 'R1' === entry.rung) {
      // §7.4: THE EFFECTIVE NAME, resolved once at registration and
      // stored on the entry. Re-deriving it here got the precedence
      // right and the FALLBACK wrong: `descriptor.auth.secretname` is
      // the API-level default, and one descriptor is shared by every
      // instance of an api — so a tagged instance with no explicit
      // `secret` read `stripe.apikey` where registration had recorded
      // `stripe_test.apikey`. Either the request fails despite the
      // credential being configured, or it succeeds with a sibling's.
      //
      // No fallback, and the `!` is the invariant rather than a shrug:
      // this branch is guarded by `'R1' === entry.rung`, which is set
      // only when `descriptor.auth.active` — the same condition under
      // which `entry.secretname` is populated. Substituting a different
      // name when it is absent is the bug above, written again.
      const secretname = entry.secretname!

      let value: string
      try {
        value = await this.broker.value(name, secretname)
      }
      catch (e: any) {
        this.emitErr(name, fctx, e)
        return e instanceof Error ? e : new Error(String(e))
      }

      senddef = { ...senddef, headers: { ...(senddef.headers || {}) } }
      for (const h of Object.keys(senddef.headers)) {
        const v = senddef.headers[h]
        if ('string' === typeof v && v.includes(placeholder)) {
          senddef.headers[h] = v.split(placeholder).join(value)
        }
      }
    }

    const corr = fctx.station$?.corr
    const started = Date.now()

    let res: any
    try {
      res = await inner(fctx, fullurl, senddef)
    }
    catch (e: any) {
      this.emitHttp(name, corr, fullurl, senddef, 0, started, 0)
      this.emitErr(name, fctx, e)
      throw e
    }

    if (res instanceof Error) {
      this.emitHttp(name, corr, fullurl, senddef, 0, started, 0)
      this.emitErr(name, fctx, res)
      return res
    }

    let bytes = 0
    const cl = res?.headers?.get?.('content-length')
    if (null != cl) { bytes = parseInt(cl, 10) || 0 }
    this.emitHttp(name, corr, fullurl, senddef, res?.status || 0, started, bytes)

    return res
  }

  private emitHttp(slug: string, corr: string | undefined, fullurl: string,
    fetchdef: any, status: number, started: number, bytes: number): void {
    let host = '', path = ''
    try {
      const u = new URL(fullurl)
      host = u.host
      path = u.pathname
    } catch (_e) { path = fullurl }
    this.emit({
      t: started, kind: 'http', plugin: slug, corr,
      http: {
        method: fetchdef?.method || 'GET', host, path, status,
        durationMs: Date.now() - started, bytes,
      },
    })
  }

  private emitErr(name: string, fctx: any, err: any): void {
    this.emit({
      t: Date.now(), kind: 'error', plugin: name, corr: fctx?.station$?.corr,
      err: {
        code: err?.code,
        // The scrub keeps an upstream echo of a credential out of the
        // event stream (§7 as revised: exact-value, no length floor).
        message: this.redact(String(err?.message || err)),
      },
    })
  }

  // Op events from the hook bridge (design §3 item 3).
  _opEvent(name: string, ctx: any, outcome: string): void {
    const st = ctx.station$ || {}
    this.emit({
      t: Date.now(), kind: 'op', plugin: name, corr: st.corr,
      // ctx.op is the SDK's resolved Operation: name + entity, in the
      // descriptor's lowercase spelling.
      op: {
        entity: String(ctx.op?.entity ?? ctx.entity?.name ?? ''),
        op: String(ctx.op?.name ?? ''),
        outcome,
        durationMs: null != st.start ? Date.now() - st.start : 0,
      },
    })
  }

  // --- the query/observe surface (design §3.2, §6) ---

  // One entry per LIVE INSTANCE (§6.1), and exhaustive: auto-tagged
  // entries are not collapsed here, because inspection, health
  // reporting and cleanup all need to enumerate the clients `create()`
  // produced, which is exactly when you most want them. Truncation is a
  // presentation decision and belongs to `status()`.
  plugins(): {
    name: string, api: string, slug: string, descriptor: any,
    rung: string, secretname?: string, warnings: string[]
  }[] {
    return Array.from(this.registry.values()).map((e) => ({
      name: e.name,
      api: e.api,
      // Retained: it is the api, which is what `slug` always meant here,
      // and dropping it would break every consumer for no gain while
      // the two are equal for untagged instances.
      slug: e.api,
      descriptor: e.descriptor,
      rung: e.rung,
      secretname: e.secretname,
      warnings: e.warnings.slice(),
    }))
  }

  // --- the declarative front door (design §6) ---

  /** The instance, constructed on first call and CACHED: same name ->
   * same object. That caching is what makes "get it where you need it"
   * a real instruction - call it in a request handler, in a worker, in
   * a test, and the first call pays construction while the rest are a
   * map lookup.
   *
   * SYNCHRONOUS (§6.3), which is what bounds the loader to CommonJS. */
  sdk(name: string): any {
    const cached = this.clients.get(name)
    if (null != cached) { return cached }
    const client = this.build(name, undefined)
    this.clients.set(name, client)
    return client
  }

  /** An UNCACHED client from the same resolved config plus overrides,
   * for the case that genuinely wants a distinct one - a per-request
   * credential scope, a test double. Deliberately the longer name.
   *
   * It registers under an AUTO-ASSIGNED TAG, because §7.5 registers
   * every constructed adapter under its instance name and
   * `station_bound_twice` fires on a second binding of one name: a
   * second `create('stripe')` would otherwise throw, which is exactly
   * the per-request case this exists for. The tag is the lowest unused
   * positive integer, so an auto-tagged instance is an ORDINARY
   * instance rather than a parallel identity scheme - `plugins()`, the
   * placeholder, the event stream and `station_bound_twice` all keep
   * working on one identity model.
   *
   * The SECRET NAME does not follow the assigned tag: it resolves from
   * the DECLARED instance the tag was assigned under, so every client
   * of one instance shares one broker cache entry rather than
   * re-resolving per request (§5.3). */
  create(name: string, overrides?: any): any {
    return this.build(name, this.autotag(name), overrides)
  }

  /** The lowest positive integer tag not already taken, by a LIVE
   * instance or a DECLARED one.
   *
   * The registry alone was not enough: a profile may declare
   * `stripe$1`, and until something constructs it `registry.has` says
   * false — so `create('stripe$prod')` took that identity for a client
   * built from the `stripe$prod` block. `instances()` then reported the
   * declared `stripe$1` as live with the wrong client, and a later
   * `sdk('stripe$1')` failed `station_bound_twice` against a binding
   * that was never its own. Declaration reserves the name whether or
   * not it has been built. */
  private autotag(name: string): string {
    const api = refapi(name)
    for (let n = 1; ; n++) {
      const ref = api + '$' + n
      if (!this.registry.has(ref) && null == this.profile.sdk[ref]) {
        return ref
      }
    }
  }

  private build(name: string, as?: string, overrides?: any): any {
    if (this.closed) {
      throw new StationError('station_no_plugin', 'station is closed')
    }

    const block = this.profile.sdk[name]
    if (null == block) {
      throw new StationError('station_no_instance',
        'no declared instance "' + name + '"; declared: [' +
        Object.keys(this.profile.sdk).sort().join(', ') + ']')
    }
    if (false === block.active) {
      throw new StationError('station_instance_inactive',
        'instance "' + name + '" is declared with `active: false`, which ' +
        'bars it from running while keeping it visible in instances()')
    }

    const api = refapi(name)
    const entry = this.resolveFactory(api, block)

    // §8.4: compose the merged feature map into the ORDERED form and
    // hand it to the constructor. No new seam - it is the same
    // `options.feature` map `connect()` already uses for station's own
    // placement, with more in it, and a JS object preserves the
    // insertion order of string keys so the order rides the map.
    //
    // Station's own entry is composed AFTER the user merge and always
    // wins (§8.4), which is why `station` is dropped here and added by
    // `options()`: a config file that can switch off the component
    // reading it is not a surface, it is a trap. `feature.station` is
    // already `station_feature_reserved` at validation, so this is the
    // second half of one rule rather than a second rule.
    const resolved = this.featuresOf(name)
    const fmap: { [k: string]: any } = {}
    for (const f of composefeatures(
      resolveorder(resolved.merged).filter((o) => 'station' !== o.name))) {
      const { name: fname, ...rest } = f
      fmap[fname] = rest
    }

    const opts = {
      ...(block.options || {}),
      ...(null == block.base ? {} : { base: block.base }),
      ...(overrides || {}),
      feature: { ...fmap, ...((overrides || {}).feature || {}) },
    }

    // §5.3, and `create`'s own doc comment: "the SECRET NAME does not
    // follow the assigned tag: it resolves from the DECLARED instance
    // the tag was assigned under". It was stated and not implemented —
    // only the generated identity reached registration, which then
    // looked up `profile.sdk['stripe$1']`, lost the declared block's
    // explicit `secret`, and otherwise derived `stripe_1.apikey` where
    // the declared instance promises `stripe_test.apikey`. Every
    // per-request client resolved a different or missing credential,
    // and each one cost its own store round-trip — the opposite of the
    // shared cache entry §5.3 asks for.
    //
    // Carried through the feature-option slot, which already has the
    // precedence this needs (in-code beats profile, §9), and only when
    // the tag was ASSIGNED — a caller naming its own is naming an
    // instance, not aliasing one.
    if (null != as && as !== name && null == opts.feature?.station?.secret) {
      const declared = firstNonEmpty(block.secret) || secretnameDefault(name)
      opts.feature = {
        ...opts.feature,
        station: { ...(opts.feature?.station || {}), secret: declared },
      }
    }

    // ...AND THE CARRIED ADAPTER RIDES EXTEND, exactly as it does on
    // `connect`. §3.1's retrofit case — an SDK generated before the
    // station feature, which `factoryFromModule` explicitly supports —
    // has no generated feature to consume the `feature.station`
    // activation this path sets, so declarative `sdk()` either failed
    // on an unknown feature or returned an unregistered, unwrapped
    // client with no credential injection and no events. The imperative
    // path carried it and the declarative one did not, which is the
    // whole defect.
    //
    // Safe on a REGENERATED SDK too: the constructor uses its own
    // station feature and skips the extend copy by name, and both
    // delegate to `featureBinding`, whose `_boundEntry` check no-ops a
    // second arrival for the same client.
    const withAdapter = {
      ...opts,
      extend: [...((opts as any).extend || []), adapterFeature(this, opts)],
    }

    // The instance name reaches the adapter the same way it does on the
    // imperative path, so registration has one spelling (§7.5).
    return entry.construct(this.options(as ?? name, withAdapter))
  }

  /** §6.2's three paths, in order of preference: self-registration,
   * `Station.provide`, then the loader. */
  private resolveFactory(api: string, block: SdkBlock): FactoryEntry {
    const direct = factoryFor(api)
    if (null != direct) { return direct }

    const pkg = this.loaderPackage(api, block)
    if (null != pkg) {
      loadSync(api, pkg, block.export)
      const loaded = factoryFor(api)
      if (null != loaded) { return loaded }
    }

    throw new StationError('station_no_factory',
      'no factory for api "' + api + '"; either link a generated package ' +
      'that self-registers, call Station.provide("' + api + '", ...), or ' +
      'set `api.' + api + '.package` so the loader can import it')
  }

  /** `package` is honoured only from repo-scoped config (§6.3), and a
   * user-level one is IGNORED WITH A WARNING rather than imported - it
   * names code to load and sits outside the repo's review boundary. */
  private loaderPackage(api: string, block: SdkBlock): string | undefined {
    const pkg = block.package
    if (null == pkg || '' === pkg) { return undefined }
    if (false === this.opts.load) { return undefined }

    if (!this.repoScoped) {
      this.emit({
        t: Date.now(), kind: 'station', plugin: api, api,
        meta: {
          warn: 'ignoring `package` for api "' + api + '": it came from a ' +
            'user-level station.json, which is outside the repo\'s review ' +
            'boundary; everything else in that config still applies',
        },
      })
      return undefined
    }
    return pkg
  }

  /** ts/js only: preload ESM packages into the factory table, after
   * which `sdk()` is synchronous again for everything (§6.3). One
   * `await` at startup rather than one per call site. */
  async load(): Promise<void> {
    if (false === this.opts.load) { return }
    for (const name of Object.keys(this.profile.sdk).sort()) {
      const block = this.profile.sdk[name]
      if (false === block.active) { continue }
      const api = refapi(name)
      if (null != factoryFor(api)) { continue }
      const pkg = this.loaderPackage(api, block)
      if (null == pkg) { continue }
      await loadAsync(api, pkg, block.export)
    }
  }

  /** The merged, ordered feature set for one instance, WITH
   * PROVENANCE (§8.7): which config level set each value.
   *
   * Provenance is the half that makes a fleet view usable rather than
   * merely correct - at 26 instances "why is retry off here" is the
   * question, and a merged map alone cannot answer it. */
  featuresOf(name: string): {
    ordered: string[]
    merged: { [k: string]: any }
    from: { [k: string]: { [k: string]: string } }
  } {
    const api = refapi(name)
    const profiles = (this.raw?.profiles || {}) as any
    const base = profiles['default'] || {}
    const overlay = 'default' === this.profile.name
      ? {} : (profiles[this.profile.name] || {})

    const LEVELS = [
      'default.feature', 'default.api', 'default.sdk',
      this.profile.name + '.feature',
      this.profile.name + '.api',
      this.profile.name + '.sdk',
    ]
    const sources = featuresources(base, overlay, api, name)

    // Last writer per (feature, key) wins, and the level that wrote it
    // is what `from` records.
    const from: { [k: string]: { [k: string]: string } } = {}
    sources.forEach((src, i) => {
      if (null == src || 'object' !== typeof src) { return }
      for (const fname of Object.keys(src)) {
        const entry = src[fname]
        if (null == entry || 'object' !== typeof entry) { continue }
        from[fname] = from[fname] || {}
        for (const k of Object.keys(entry)) { from[fname][k] = LEVELS[i] }
      }
    })

    const merged = mergefeatures(sources)
    const ordered = resolveorder(merged)
    checkpin(ordered)
    return { ordered: ordered.map((o) => o.name), merged, from }
  }

  /** The fleet feature view: instance x feature, effective options, and
   * which config level set each (§8.7). */
  features(filter?: string): any[] {
    return this.instances()
      .filter((r) => null == filter || r.name === filter || r.api === filter)
      .map((r) => ({ instance: r.name, api: r.api, ...this.featuresOf(r.name) }))
  }

  /** Eagerly resolve and construct every ACTIVE instance - for CI
   * (§6.6). The point is to turn availability errors, which are
   * deliberately deferred to first use, into one failure at a moment
   * somebody is watching. */
  check(): { ok: string[], failed: { name: string, code?: string, message: string }[] } {
    const ok: string[] = []
    const failed: { name: string, code?: string, message: string }[] = []
    for (const row of this.instances()) {
      if (!row.active) { continue }
      try {
        // §8.5 runs FIRST and needs no construction: the schema arrives
        // with the factory, not with a live client, so a feature typo
        // is a CI failure rather than a setting that quietly did
        // nothing in production.
        const entry = factoryFor(row.api)
        if (null != entry) {
          const faults = checkfeatures(
            this.featuresOf(row.name).merged, entry.descriptor)
          if (0 < faults.length) {
            failed.push({
              name: row.name, code: faults[0].code,
              message: faults.map((f) => f.message).join('; '),
            })
            continue
          }
        }
        this.sdk(row.name); ok.push(row.name)
      }
      catch (e: any) {
        failed.push({
          name: row.name, code: e?.code, message: String(e?.message || e),
        })
      }
    }
    return { ok, failed }
  }

  /** Batch-resolve secrets for ACTIVE instances (§5.5).
   *
   * With no argument it warms the active ones only, because reaching
   * for a credential belonging to a disabled integration is the wrong
   * default. `warm(names)` warms exactly what it is given, inactive
   * included, because an explicit name is an explicit request. */
  async warm(names?: string[]): Promise<{ warmed: string[], missed: string[] }> {
    const wanted = null != names
      ? names
      : this.instances().filter((r) => r.active).map((r) => r.name)

    const warmed: string[] = []
    const missed: string[] = []
    for (const name of wanted) {
      // THE REGISTRY IS THE AUTHORITY, and asking the profile instead
      // was wrong twice: an IMPERATIVE instance has no `profile.sdk`
      // block, so it was pushed to `missed` and never warmed at all —
      // and the re-derivation dropped the in-code `secret` feature
      // option, which beats the profile (§9). A registered instance
      // already carries the resolved name.
      const entry = this.registry.get(name)
      const secretname = entry?.secretname ??
        (this.blockFor(name)?.secret || secretnameDefault(name))
      try { await this.broker.value(name, secretname); warmed.push(name) }
      catch (_e) { missed.push(name) }
    }
    return { warmed, missed }
  }

  // Every DECLARED instance (§6.1) - a different question from
  // `plugins()`, and the answers differ routinely: a lazily-started
  // instance is `active: true` and not yet live.
  instances(): ResolvedInstance[] {
    const sdk = this.profile.sdk
    return Object.keys(sdk).sort().map((name) => {
      const entry = this.registry.get(name)
      return {
        name,
        api: refapi(name),
        // `active: false` means BARRED FROM RUNNING - a declaration that
        // stays in the file and here while being refused a client.
        active: false !== sdk[name].active,
        live: null != entry,
        rung: entry?.rung ?? 'none',
        block: sdk[name],
      }
    })
  }

  // §7.4: accepts an INSTANCE name and returns its api's descriptor -
  // one object shared by every instance of that api.
  descriptorOf(slug: string): any {
    const entry = this.registry.get(slug)
    if (null == entry) {
      throw new StationError('station_no_plugin', 'unknown plugin "' + slug +
        '"; known: [' + Array.from(this.registry.keys()).join(', ') + ']')
    }
    return entry.descriptor
  }

  canonicalDescriptor(slug: string): string {
    return canonicalSerialize(this.descriptorOf(slug))
  }

  events(): StationEvent[] {
    return this.buffer.events()
  }

  tap(fn: (ev: StationEvent) => void): () => void {
    return this.buffer.tap(fn)
  }

  status(): any {
    return {
      mode: 'solo',
      profile: this.profile.name,
      plugins: this.plugins().map((p) => ({ slug: p.slug, rung: p.rung })),
      events: this.buffer.status(),
    }
  }

  redact(text: string): string {
    return this.broker.scrub(text)
  }

  refreshSecrets(): void {
    this.broker.refresh()
  }

  // close(): flush (solo: nothing in flight), then warn on profile
  // plugin keys that matched no registered plugin - a typo'd key
  // silently configuring nothing is the worst outcome for a
  // secrets-and-policy file (design §11).
  close(): void {
    if (this.closed) { return }
    for (const slug of Object.keys(this.profile.sdk)) {
      if (!this.registry.has(slug)) {
        this.emit({
          t: Date.now(), kind: 'station',
          meta: {
            warn: 'profile plugin key "' + slug +
              '" matched no registered plugin',
          },
        })
      }
    }
    this.closed = true
    if (Station.ambient === this) {
      Station.reset()
    }
  }

  private emit(ev: StationEvent): void {
    this.buffer.emit(ev)
  }
}

function firstNonEmpty(...vals: (string | undefined)[]): string | undefined {
  for (const v of vals) {
    if (null != v && '' !== v) { return v }
  }
  return undefined
}
