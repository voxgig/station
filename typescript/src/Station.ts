import { adapterFeature } from './adapter'
import { StationError } from './error'
import { EventBuffer } from './events'
import { canonicalSerialize, normalizeDescriptor, secretnameDefault } from './descriptor'
import { loadConfig, refapi, resolveProfile, selectProfile, ResolvedProfile } from './profile'
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
  private secretOverride = new Map<string, string>()
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

    const profilePlugin = this.profile.sdk[name]
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
    if (null != fopts?.secret && '' !== fopts.secret) {
      this.secretOverride.set(name, fopts.secret)
    }

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
    const profilePlugin = this.profile.sdk[name]

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
      const secretname = firstNonEmpty(this.secretOverride.get(name),
        profilePlugin?.secret) || entry.descriptor.auth.secretname

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
