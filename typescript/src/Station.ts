import { adapterFeature } from './adapter'
import { StationError } from './error'
import { EventBuffer } from './events'
import { canonicalSerialize, normalizeDescriptor, secretnameDefault } from './descriptor'
import {
  configScope, loadConfig, refapi, resolveProfile, selectProfile, ResolvedProfile,
} from './profile'
import { FactoryEntry, factoryFor, provide } from './factory'
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

export function instanceRef(api: string, fopts?: any): string {
  const explicit = firstNonEmpty(fopts?.instance)
  if (null != explicit) { return checkref(checkapi(api, explicit)) }

  const as = firstNonEmpty(fopts?.as)
  // The bare fallback is the SLUG - a name, never a ref: a `$` in it is
  // an invalid name, not an implicit tag.
  if (null == as) {
    if (!checkInstanceName(api)) {
      throw new StationError('station_instance_api',
        'invalid instance name "' + api + '": a name starts with a letter ' +
        'or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (§6.1)')
    }
    return api
  }

  return checkref(-1 === as.indexOf('$') ? api + '$' + as : checkapi(api, as))
}

const REF_NAME_RE = /^[a-zA-Z@][a-zA-Z0-9.~_\-\/]*$/
const REF_TAG_RE = /^[a-zA-Z0-9.~_-]+$/
const REF_MAX = 1024

export function checkInstanceName(name: string): boolean {
  if ('string' !== typeof name) { return false }
  if (0 === name.length || REF_MAX < name.length) { return false }
  return REF_NAME_RE.test(name)
}

export function checkInstanceTag(tag: string): boolean {
  if ('string' !== typeof tag) { return false }
  if (0 === tag.length) { return true }
  if (REF_MAX < tag.length) { return false }
  return REF_TAG_RE.test(tag)
}

/** Validate a ref against the joint grammar and return its CANONICAL
 * spelling: a trailing `$` (empty tag) is never kept, so `stripe$` and
 * `stripe` are one registry key rather than two. */
function checkref(ref: string): string {
  const cut = ref.indexOf('$')
  const name = -1 === cut ? ref : ref.substring(0, cut)
  const tag = -1 === cut ? '' : ref.substring(cut + 1)
  if (!checkInstanceName(name)) {
    throw new StationError('station_instance_api',
      'invalid instance name "' + name + '" in ref "' + ref + '": a name ' +
      'starts with a letter or `@` and uses `[a-zA-Z0-9.~_-/]`, max 1024 (§6.1)')
  }
  if (!checkInstanceTag(tag)) {
    throw new StationError('station_instance_api',
      'invalid instance tag "' + tag + '" in ref "' + ref + '": a tag ' +
      'uses `[a-zA-Z0-9.~_-]`, max 1024 (§6.1)')
  }
  return '' === tag ? name : ref
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

  static provide(api: string, factory: any): void {
    provide(api, factory)
  }

  private opts: StationOptions
  private profile: ResolvedProfile
  private broker: SecretBroker
  private buffer: EventBuffer
  private registry = new Map<string, PluginEntry>()
  private clients = new Map<string, any>()
  // The raw config, kept for §8.7's provenance: the resolved profile
  // has already collapsed the levels that provenance has to name.
  private raw: any = null
  private repoScoped = true
  private requireProxy: boolean
  /** An auto-assigned tag to the DECLARED instance it stands for
   * (§5.3). Kept beside the registry rather than inside it because the
   * mapping exists before construction, and `blockFor` needs it during
   * registration. */
  private aliasOf = new Map<string, string>()

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

  static reset(): void {
    Station.ambient = null
    Station.ambientOpts = null
  }

  constructor(opts?: StationOptions) {
    this.opts = opts || {}

    const config = undefined !== this.opts.config
      ? this.opts.config
      : loadConfig(this.opts.folder)

    this.repoScoped = this.opts.repoScoped
      ?? (undefined !== this.opts.config
        ? true
        : 'user' !== configScope(this.opts.folder))

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


  _boundEntry(client: any): PluginEntry | null {
    for (const entry of this.registry.values()) {
      if (entry.client === client) { return entry }
    }
    return null
  }

  private blockFor(name: string): SdkBlock | undefined {
    return this.profile.sdk[this.declaredRef(name)] ??
      this.profile.api[refapi(name)]
  }

  private declaredRef(name: string): string {
    return this.aliasOf.get(name) ?? name
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

    if (this.registry.has(name)) {
      throw new StationError('station_bound_twice',
        'instance "' + name + '" is already registered; binding one client ' +
        'twice is an error (§10.2)')
    }

    const profilePlugin = this.blockFor(name)
    const secretname = firstNonEmpty(fopts?.secret, profilePlugin?.secret) ||
      secretnameDefault(this.declaredRef(name))

    const rung = descriptor.auth.active ? 'R1' : 'none'
    const binding: Binding = {
      plugin: name,
      instance: api,
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

  private descriptorCache = new Map<string, { descriptor: any, warnings: string[] }>()

  private describe(config: any, _feature: any):
    { descriptor: any, warnings: string[] } {
    const slug = String(config?.main?.slug ?? '')
    if ('' !== slug) {
      const hit = this.descriptorCache.get(slug)
      if (null != hit) { return hit }
    }
    const out = normalizeDescriptor(config, undefined)
    this.descriptorCache.set(out.descriptor.slug, out)
    return out
  }

  _hoist(name: string, value: string): void {
    this.broker.hoist(name, value)
    this.emit({
      t: Date.now(), kind: 'station', plugin: name, api: refapi(name),
      meta: {
        warn: 'a resident credential was hoisted into the broker and ' +
          'replaced by the placeholder; prefer configuring the secret ' +
          'name and letting sekreto resolve it',
      },
    })
  }


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

    const mode = profilePlugin?.policy?.mode ?? 'live'
    if ('live' !== mode && live) {
      const err = 'block' === mode
        ? new StationError('station_host_allow',
          'egress denied: plugin "' + name + '" is policy mode "block", ' +
          'the kill switch (§16)')
        : new StationError('station_no_proxy',
          'policy mode "' + mode + '" for plugin "' + name + '" needs an ' +
          'attached proxy, and none is attached')
      this.emitErr(name, fctx, err)
      return err
    }

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
      t: started, kind: 'http', plugin: slug, api: refapi(slug), corr,
      http: {
        method: fetchdef?.method || 'GET', host, path, status,
        durationMs: Date.now() - started, bytes,
      },
    })
  }

  private emitErr(name: string, fctx: any, err: any): void {
    this.emit({
      t: Date.now(), kind: 'error', plugin: name, api: refapi(name),
      corr: fctx?.station$?.corr,
      err: {
        code: err?.code,
        // The scrub keeps an upstream echo of a credential out of the
        // event stream (§7 as revised: exact-value, no length floor).
        message: this.redact(String(err?.message || err)),
      },
    })
  }

  _opEvent(name: string, ctx: any, outcome: string): void {
    const st = ctx.station$ || {}
    this.emit({
      t: Date.now(), kind: 'op', plugin: name, api: refapi(name), corr: st.corr,
      op: {
        entity: String(ctx.op?.entity ?? ctx.entity?.name ?? ''),
        op: String(ctx.op?.name ?? ''),
        outcome,
        durationMs: null != st.start ? Date.now() - st.start : 0,
      },
    })
  }


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


  sdk(name: string): any {
    const cached = this.clients.get(name)
    if (null != cached) { return cached }
    const client = this.build(name, undefined)
    this.clients.set(name, client)
    return client
  }

  create(name: string, overrides?: any): any {
    return this.build(name, this.autotag(name), overrides)
  }

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

    const faults = checkfeatures(this.featuresOf(name).merged, entry.descriptor)
    if (0 < faults.length) {
      throw new StationError(faults[0].code as any,
        faults.map((f) => f.message).join('; '))
    }

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

    if (null != as && as !== name) { this.aliasOf.set(as, name) }

    const withAdapter = {
      ...opts,
      extend: [...((opts as any).extend || []), adapterFeature(this, opts)],
    }

    // The instance name reaches the adapter the same way it does on the
    // imperative path, so registration has one spelling (§7.5).
    return entry.construct(this.options(as ?? name, withAdapter))
  }

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

    let merged = mergefeatures(sources)

    const budget = this.blockFor(name)?.policy?.budget
    if (null != budget && 'object' === typeof budget && !Array.isArray(budget)) {
      const prior = merged.ratelimit
      const entry: any = {
        ...(null != prior && 'object' === typeof prior ? prior : {}),
        active: true,
      }
      from.ratelimit = from.ratelimit || {}
      from.ratelimit.active = 'policy.budget'
      if (null != budget.rps) {
        entry.rate = budget.rps
        from.ratelimit.rate = 'policy.budget'
      }
      if (null != budget.concurrency) {
        entry.burst = budget.concurrency
        from.ratelimit.burst = 'policy.budget'
      }
      merged = { ...merged, ratelimit: entry }
    }

    const ordered = resolveorder({ ...merged, station: { active: true } })
    checkpin(ordered)
    return { ordered: ordered.map((o) => o.name), merged, from }
  }

  /** The fleet feature view: instance x feature, effective options, and
   * which config level set each (§8.7). */
  features(filter?: string | { instance?: string, api?: string, feature?: string }): any[] {
    const f = 'string' === typeof filter
      ? { instance: filter, api: filter, loose: true }
      : { ...(filter || {}), loose: false }

    const rows = this.instances()
      .filter((r) => {
        if (f.loose) {
          return null == f.instance || r.name === f.instance || r.api === f.api
        }
        if (null != f.instance && r.name !== f.instance && r.api !== f.instance) {
          return false
        }
        return null == f.api || r.api === f.api
      })
      .map((r) => ({ instance: r.name, api: r.api, ...this.featuresOf(r.name) }))

    // `feature` filters the ROWS, not the instances: an instance that
    // does not carry the named feature is not part of the answer, and
    // the rows that remain are narrowed to it so the view answers
    // "where is debug on, and with what" rather than "here is
    // everything, go and look".
    const want = (filter as any)?.feature
    if (null == want) { return rows }
    return rows
      .filter((row: any) => null != row.merged[want])
      .map((row: any) => ({
        instance: row.instance,
        api: row.api,
        ordered: row.ordered.filter((n: string) => n === want),
        merged: { [want]: row.merged[want] },
        from: { [want]: row.from[want] || {} },
      }))
  }

  check(): { ok: string[], failed: { name: string, code?: string, message: string }[] } {
    const ok: string[] = []
    const failed: { name: string, code?: string, message: string }[] = []
    for (const row of this.instances()) {
      if (!row.active) { continue }
      try {
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

  async warm(names?: string[]): Promise<{ warmed: string[], missed: string[] }> {
    const wanted = null != names
      ? names
      : this.instances().filter((r) => r.active).map((r) => r.name)

    const plan: { name: string, secretname: string }[] = []
    const warmed: string[] = []
    const missed: string[] = []
    for (const name of wanted) {
      const entry = this.registry.get(name)
      if (null == entry && null == this.profile.sdk[name]) {
        missed.push(name)
        continue
      }
      const secretname = entry?.secretname ??
        (this.blockFor(name)?.secret ||
          secretnameDefault(this.declaredRef(name)))
      plan.push({ name, secretname })
    }

    // One resolution per distinct secret name, awaited together; the
    // per-instance results are mapped back afterwards so the reported
    // shape is unchanged.
    const bysecret = new Map<string, string[]>()
    for (const p of plan) {
      const at = bysecret.get(p.secretname)
      if (null == at) { bysecret.set(p.secretname, [p.name]) }
      else { at.push(p.name) }
    }

    const results = await Promise.all(
      Array.from(bysecret.entries()).map(async ([secretname, names]) => {
        try {
          await this.broker.value(names[0], secretname)
          return { names, ok: true }
        }
        catch (_e) { return { names, ok: false } }
      }))

    for (const r of results) {
      for (const n of r.names) { (r.ok ? warmed : missed).push(n) }
    }
    warmed.sort()
    missed.sort()
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
      plugins: this.plugins().map((p) => ({
        name: p.name, api: p.api, slug: p.slug, rung: p.rung,
      })),
      events: this.buffer.status(),
    }
  }

  redact(text: string): string {
    return this.broker.scrub(text)
  }

  refreshSecrets(): void {
    this.broker.refresh()
  }

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
