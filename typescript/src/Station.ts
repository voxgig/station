import { adapterFeature } from './adapter'
import { StationError } from './error'
import { EventBuffer } from './events'
import { canonicalSerialize, normalizeDescriptor } from './descriptor'
import { loadConfig, resolveProfile, selectProfile, ResolvedProfile } from './profile'
import { SecretBroker, placeholderFor } from './secrets'
import {
  Binding, PluginEntry, PluginProfile, StationEvent, StationOptions,
} from './types'

// The station library core, solo mode (design D1): fully functional
// in-process with no other component running. The proxy (D2) is a
// deferred amplifier - `require` therefore fails on the operation path
// (design §2.1/§14), and `auto` degrades to solo with one warning event.

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
  options(extra?: any): any {
    extra = extra || {}
    const fmap = { ...(extra.feature || {}) }
    fmap['station'] = {
      ...(fmap['station'] || {}),
      active: true, station: this, calleropts: extra,
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
    { binding: Binding, profilePlugin?: PluginProfile } {

    const { descriptor, warnings } = normalizeDescriptor(config, options.feature)
    const slug = descriptor.slug

    if (this.registry.has(slug)) {
      throw new StationError('station_bound_twice',
        'plugin "' + slug + '" is already registered; binding one client ' +
        'twice is an error (§10.2)')
    }

    const profilePlugin = this.profile.plugin[slug]
    // Secret name precedence: the feature option (in-code, design §9
    // config.options.secret) beats the profile, which beats the
    // descriptor default.
    const secretname = firstNonEmpty(fopts?.secret, profilePlugin?.secret) ||
      descriptor.auth.secretname
    if (null != fopts?.secret && '' !== fopts.secret) {
      this.secretOverride.set(slug, fopts.secret)
    }

    const rung = descriptor.auth.active ? 'R1' : 'none'
    const binding: Binding = {
      plugin: slug,
      placeholder: descriptor.auth.active ? placeholderFor(slug) : undefined,
      secretname: descriptor.auth.active ? secretname : undefined,
      rung,
    }

    this.registry.set(slug, { slug, descriptor, rung, client, warnings })

    for (const w of warnings) {
      this.emit({ t: Date.now(), kind: 'station', plugin: slug, meta: { warn: w } })
    }
    this.emit({
      t: Date.now(), kind: 'construct', plugin: slug,
      meta: { name: descriptor.name, version: descriptor.version, rung },
    })

    return { binding, profilePlugin }
  }

  _hoist(slug: string, value: string): void {
    this.broker.hoist(slug, value)
    this.emit({
      t: Date.now(), kind: 'station', plugin: slug,
      meta: {
        warn: 'a resident credential was hoisted into the broker and ' +
          'replaced by the placeholder; prefer configuring the secret ' +
          'name and letting sekreto resolve it',
      },
    })
  }

  // --- the transport middleware (design §3.3, §5.3) ---

  async _transport(slug: string, inner: any, fctx: any, fullurl: string,
    fetchdef: any): Promise<any> {

    // Fail-closed means traffic (§2.1): with the proxy deferred,
    // `require` can never attach, so every operation fails here - the
    // operation path, never the constructor.
    if (this.requireProxy) {
      const err = new StationError('station_no_proxy',
        'proxy: "require" is set and no proxy is attached')
      this.emitErr(slug, fctx, err)
      return err
    }

    const entry = this.registry.get(slug)
    const placeholder = placeholderFor(slug)
    const live = 'live' === fctx.client._mode
    const profilePlugin = this.profile.plugin[slug]

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
          'plugin "' + slug + '"')
        this.emitErr(slug, fctx, err)
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
      const secretname = firstNonEmpty(this.secretOverride.get(slug),
        profilePlugin?.secret) || entry.descriptor.auth.secretname

      let value: string
      try {
        value = await this.broker.value(slug, secretname)
      }
      catch (e: any) {
        this.emitErr(slug, fctx, e)
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
      this.emitHttp(slug, corr, fullurl, senddef, 0, started, 0)
      this.emitErr(slug, fctx, e)
      throw e
    }

    if (res instanceof Error) {
      this.emitHttp(slug, corr, fullurl, senddef, 0, started, 0)
      this.emitErr(slug, fctx, res)
      return res
    }

    let bytes = 0
    const cl = res?.headers?.get?.('content-length')
    if (null != cl) { bytes = parseInt(cl, 10) || 0 }
    this.emitHttp(slug, corr, fullurl, senddef, res?.status || 0, started, bytes)

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

  private emitErr(slug: string, fctx: any, err: any): void {
    this.emit({
      t: Date.now(), kind: 'error', plugin: slug, corr: fctx?.station$?.corr,
      err: {
        code: err?.code,
        // The scrub keeps an upstream echo of a credential out of the
        // event stream (§7 as revised: exact-value, no length floor).
        message: this.redact(String(err?.message || err)),
      },
    })
  }

  // Op events from the hook bridge (design §3 item 3).
  _opEvent(slug: string, ctx: any, outcome: string): void {
    const st = ctx.station$ || {}
    this.emit({
      t: Date.now(), kind: 'op', plugin: slug, corr: st.corr,
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

  plugins(): { slug: string, descriptor: any, rung: string, warnings: string[] }[] {
    return Array.from(this.registry.values()).map((e) => ({
      slug: e.slug,
      descriptor: e.descriptor,
      rung: e.rung,
      warnings: e.warnings.slice(),
    }))
  }

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
    for (const slug of Object.keys(this.profile.plugin)) {
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
