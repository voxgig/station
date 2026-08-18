# Design: voxgig/station — one control surface for outbound integrations

Status: **proposal** (2026-08-17). Revised same-day after an adversarial
design review against the codebase; the review's corrections are folded
in throughout (wrap ordering, adopt semantics, identity fields, support
tiers, proxy-side policy authority). Revised again to make
[voxgig/sekreto](https://github.com/voxgig/sekreto) the secrets
subcomponent: station no longer defines a secret-reference grammar or
any store client of its own (§5). Revised again (2026-08-18) after
a second automated review on the move PR: redirect policy on
`/v1/forward`, register-cache scoping to app identity, exact-value
credential scrubbing on the agent boundary, per-header upstream
metadata, a wire home for the proof-of-token challenge,
bounded-blocking event flush named as such, lossy-capture replay
refusal, the prod examples' provider order, and `require` failure
timing aligned to §2.1.

Moved here from `voxgig/sdkgen` (`docs/design/voxgig-station.md`), which
is where it was drafted; this repo is now its home. Unqualified source
paths below — `ts/src/...`, `ts/project/.sdk/...`, `docs/reference/...`
— are relative to the [sdkgen repo](https://github.com/voxgig/sdkgen),
the codebase this design reads against.

Station is the component that sits between an application and all of its
generated SDKs. Every sdkgen SDK an application uses registers with a
local `Station` as a **plugin**, and station becomes the single place
where outbound integrations are configured, credentialed, observed,
policed, and debugged — for the developer and, just as importantly, for
an AI agent working on or through the application.

Five architecture decisions are settled and everything below follows
from them:

- **D1 — Library-first core.** Station's core is a per-language library.
  It is fully functional in-process with no other component running.
- **D2 — Companion proxy.** `voxgig/station` also ships one optional
  companion binary (Go), runnable locally or deployed remotely. When a
  station library attaches to it, the proxy provides consolidated
  cross-process/cross-language observability, debugging (capture,
  replay, mock), proxy-boundary credential injection, and the MCP agent
  surface. The proxy is an amplifier, never a required dependency.
- **D3 — Generated adapter.** SDKs become plugins via a `station`
  sdkgen **feature**: generated per-target adapter source plus a
  machine-readable descriptor derived from the config every SDK already
  embeds. Deep integration, not transport-sniffing.
- **D4 — Secrets are brokered with isolation, over sekreto.**
  Application code names a secret, never a value.
  [voxgig/sekreto](https://github.com/voxgig/sekreto) — the sibling
  component that already speaks env, dotenv, mounted files, Vault,
  boru, AWS, GCP, Azure, 1Password, Doppler and Infisical in ten
  languages — does the resolving; station decides which plugin gets
  which secret and injects at the last possible boundary: the
  transport seam in-process, the proxy hop when attached (§5).
- **D5 — Hand-written libraries.** The per-language station libraries
  are hand-written idiomatic code, *not* generated. What makes that
  sustainable is a deliberate design constraint (§10) and a shared
  conformance corpus (§13), the same discipline that keeps the SDK
  targets honest today.

Developer and agent experience are the fundamental values: every
mechanism in this design has to earn its place in a two-line quickstart
(§11) or an agent transcript (§12).


## 1. How much of this already exists

More than expected. The generated SDKs already contain nearly every seam
station needs; what is missing is the thing on the other side of those
seams — a consolidated consumer. The inventory, with receipts:

- **A uniform transport seam in every language.** All SDK traffic flows
  through one function slot, `utility.fetcher`. The `test` feature
  installs the base (mock) transport by replacing that slot; `proxy`,
  `retry`, `cache`, `ratelimit`, `timeout`, and `netsim` wrap whatever
  is current, onion-style, in their `init()`
  (`ts/project/.sdk/tm/ts/src/feature/proxy/ProxyFeature.ts`). Wrap
  nesting is *feature init order* — first-inited is innermost — and the
  default order is `test` first, then **alphabetical**
  (`ts/project/.sdk/tm/ts/src/utility/MakeOptionsUtility.ts`). That
  default would place a `station` wrap outermost, which is the wrong
  place (§3.3); ordering is therefore a mechanism this design must pin,
  not a property it inherits. The wrap sees **all** traffic, including
  the `direct()`/`graphql()` escape hatches, which bypass the *hook
  pipeline* but not the transport.
- **A 14-stage hook pipeline in every language.** `init`,
  `PostConstruct`, `PostConstructEntity`, entity-state hooks, then
  per-operation `PrePoint → PreSpec → PreRequest → PreResponse →
  PreResult → PreDone`, with `PreUnexpected` on escaped errors
  (`docs/reference/hooks.md`,
  `ts/project/.sdk/tm/ts/src/feature/base/BaseFeature.ts`). Hooks give
  station *operation semantics* (which entity, which op); the transport
  wrap gives it *HTTP truth*. Station uses both.
- **A ready-made plugin descriptor.** `configDefinition(model)`
  (`ts/src/utility.ts`) builds the machine-readable object every
  generated SDK embeds in all targets: name, per-feature config,
  options (base URL, server variables, auth prefix, headers), and the
  full entity/op/points map including HTTP methods and path templates.
  A station descriptor is a view over this, not a new artifact (§4).
- **Observability features with nowhere to send anything.** `log`,
  `debug`, `telemetry`, `metrics`, `audit`, `clienttrack` all exist per
  language, and all buffer in-process on the client
  (`client._debug.entries`, `client._telemetry.spans`, …) with only
  per-feature callbacks (`onEntry`, `exporter`) as egress. There is no
  consolidated sink, no cross-SDK view, no cross-process view. Station
  is that sink (§6).
- **A redaction list.** The `debug` feature's `redact` header list
  (`authorization`, `cookie`, `set-cookie`, `api-key`, `apikey`,
  `x-api-key`, `idempotency-key` —
  `ts/project/.sdk/model/feature/debug.aontu`) is the current source of
  truth for what must never appear in captured traffic. Station adopts
  and extends it (§15). The *body*-field equivalent (`clean.keys`) is
  currently disabled in the reference implementation
  (`CleanUtility.ts`'s redaction body is commented out) — reviving it
  is a station prerequisite (§15).
- **A vault shape, and a sibling that fills it.** Runtime secret
  management does not exist *in sdkgen* — the entire consumer secret
  story is one env var, `<NAME>_APIKEY`. Publish-time credentials do
  have a modeled shape: `publish.registry.vault` `{recipe, alias,
  env}` and `publish.tag.vault` `{recipe, alias}`, with the stated
  principle "credentials are always injected by the aql key vault
  (never on disk or argv)" (`model/sdkgen.aontu`). The runtime half is
  where [voxgig/sekreto](https://github.com/voxgig/sekreto) comes in
  (§5) — and since sekreto ships a `boru` provider reading a boru
  vault, runtime and publish-time credentials can eventually come from
  one vault story rather than two. (Exactly how the `aql` recipe/alias
  mechanism and boru's vault relate is a wiring question for whoever
  lands that, not an assumption this design makes.)
- **An agent surface precedent.** `go-mcp` is a consumer target that
  turns one generated Go SDK into an MCP server: slug-prefixed tools,
  generic tools with an `entity` argument rather than per-entity tool
  explosion, stdio + streamable-HTTP transports, env-var-only config
  explicitly annotated "injectable by a secrets vault"
  (`ts/project/.sdk/src/cmp/go-mcp/`). Station's MCP surface (§7)
  generalizes this pattern across *all* registered plugins — and,
  unlike go-mcp, without needing a language runtime per SDK.
- **Distribution machinery.** The sdkgen package system
  (`docs/design/sdkgen-packages.md`) lets an external package ship a
  feature plus per-target source overlays for every language,
  installable with `package add`, with provenance stamping and doctor
  drift-detection. The `station` feature ships this way (§9).
- **Env-var grammar.** `<NAME>_APIKEY`, `<NAME>_TEST_LIVE`,
  `<NAME>_TEST_<ENTITY>_ENTID` (`ts/src/helpers/packageMeta.ts`
  `envName`/`envToken`) and the proxy feature's
  `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` handling define the naming
  conventions station's own env surface composes with (§8).

What does **not** exist in *sdkgen* today: named environments
(dev/staging/prod), any runtime secret provider beyond a raw env var,
any consolidated or remote collection point for the observability
features, any cross-SDK control surface, and any way for an agent to
see what an application's integrations are *doing*. That is station's
job description — minus the secrets half, which is sekreto's and is
already built (§5). Station's job there is narrower and more
interesting: deciding which plugin gets which secret, and making sure
the value never turns up anywhere it shouldn't.


## 2. The shape

Three parts, one contract:

```
┌────────────────────────── application process ──────────────────────────┐
│                                                                         │
│   app code ──► SolardemoSDK ──┐   (generated station feature:           │
│                               │    descriptor + hooks + fetcher wrap)   │
│   app code ──► PaymentsSDK ──┤                                          │
│                               ▼                                         │
│                        Station (library)                                │
│                • plugin registry   • profiles/policy                    │
│                • event buffer      • in-process injection               │
│                          │                                              │
│                          ▼                                              │
│                   sekreto (library)  ── env / dotenv / file /           │
│                   names → values        Vault / boru / AWS / GCP /      │
│                                         Azure / 1Password / Doppler     │
└───────────────────────────────┼─────────────────────────────────────────┘
                                │ station wire protocol v1 (optional)
                                ▼
                 voxgig-station proxy (one Go binary)
          • consolidated capture across processes/languages
          • proxy-boundary credential injection (grants)
          •   └─ sekreto (go) — the chain, proxy-side, R2
          • proxy-side policy authority   • replay / mock / record
          • MCP server (stdio + HTTP)     • OTLP export
          • tap/status/secrets/approve/revoke CLI
                                │
                                ▼
                        upstream APIs (outbound only)
```

- **The station library** (per language, hand-written): the in-process
  hub. Owns the plugin registry, profile/config loading, the secret
  broker, policy application, the event buffer, and the transport
  middleware that the generated station feature installs into each SDK.
  Complete on its own — this is D1.
- **The generated station feature** (sdkgen feature, per target): the
  adapter that connects a generated SDK to the library — registers the
  descriptor, bridges hooks to events, wraps the transport. Thin by
  design; all logic it calls lives in the library.
- **The proxy** (`voxgig-station`, one Go binary): everything that
  benefits from living outside the application process or being shared
  across processes and languages. Also the *only* place heavyweight
  integrations (OTLP, capture storage, TLS termination for remote
  mode) are implemented — so the libraries never grow N copies of
  them. It runs sekreto too (the Go port), which is what lets a
  language with no sekreto port still reach a vault (§2.2), and what
  keeps provider credentials out of every app's deployment config
  (§5.3, R2).

### 2.1 Attachment modes

A station instance is always in exactly one of:

- **`solo`** — no proxy. Everything in-process: env/file secret
  resolution, in-process credential injection, ring-buffer events,
  in-process tap.
- **`attached`** — a proxy was configured or discovered (§8). Traffic
  is enveloped through the proxy's data plane, events stream to it,
  secrets may be proxy-held (grants), and the plugin appears on the
  proxy's MCP and CLI surfaces.

Mode is chosen at `Station.open()` from config (`proxy: 'auto' | 'off'
| <url> | 'require'`). `auto` (the default) probes and degrades to
`solo` with a single warning event; `require` fails closed
(`station_no_proxy`) for deployments where unproxied egress is not
acceptable. Degradation semantics are in §14 — they interact with
secrets.

`open()` is **non-blocking** in every language (JS cannot do
synchronous network I/O, so no language gets to depend on it): probe
and registration run in the background. Under `auto`, operations that
need only library-resolved secrets proceed immediately in the
meantime; the first operation that needs a proxy-issued grant awaits
registration with a bounded timeout and then fails per §14. Under
`require`, fail-closed means *traffic*, not just construction: every
operation — whatever its secret provider — awaits successful
attachment with the same bounded timeout, so no request leaves the
process unproxied while the probe is pending; timeout or refusal is
`station_no_proxy`. The `degrade` conformance-corpus section pins
these transitions.

### 2.2 Support tiers

"~23 languages" is not one capability level, and pretending otherwise
was the biggest defect of this doc's first draft. The template trees
disagree per target on five axes: whether the platform/stdlib provides
an HTTP client (C has none at all — the C SDK ships no HTTP and
requires an app-supplied `system.fetch`; Lua's fetcher pcall-requires
optional luasocket; Haskell's target prides itself on zero non-boot
dependencies), whether a package manifest exists to declare the
library dependency in (`Package_c` is an explicit no-op; zig hardcodes
empty dependencies), whether the `options.extend` seam exists (absent
in c, zig, haskell, ocaml, lean), whether feature source is
per-feature files or one monolithic module (§9.1), and whether
**sekreto has a port** for the language (§5).

Station therefore ships with an explicit tier table, referenced
wherever this doc says "every language", maintained in the station
repo, and assessed per target at implementation time. The starting
assessment from today's trees:

| tier | targets (initial assessment) | solo | attached | mechanism notes |
|---|---|---|---|---|
| **A** | ts, js (node), go, py, rb, php, java, kotlin, scala\*, clojure\*, swift, dart, csharp, elixir, perl | full | full | platform/core HTTP stack; deps via manifest |
| **B** | rust, lua, haskell\*, ocaml\* | full | with one declared, well-known dependency (client crate; luasocket; http-client; …) | deps via manifest; \* single-module/static constraints in §9.1 |
| **C** | c, cpp, zig, lean | solo only in v1 (no wire client) | — | no manifest (c/cpp/zig: library vendored, §9.2); c/zig SDKs also have **no default transport** — see below |
| n/a | go-cli, go-mcp, py-data, seneca-provider | consumer targets, out of scope as plugins | | |

Remote-proxy attachment (TLS) is a stricter cut of the same table:
targets without platform TLS (perl's core HTTP::Tiny, lua) attach
locally only, or reach a remote proxy through a local `voxgig-station`
forwarding to it — a supported topology.

**Secrets coverage is its own cut, and it is mostly good news.**
sekreto ships ten ports — ts, js, py, rb, php, perl, go, rust, java,
csharp — which covers nine of tier A outright, plus rust in tier B;
the JVM targets (kotlin, scala, clojure) reach the Java port through
ordinary interop. That leaves swift, dart and elixir in tier A, lua,
haskell and ocaml in tier B, and all of tier C with no sekreto port
today. For the tier A and B members of that list, being port-less is
not being cut off from vaults, because **the resolution that matters
can happen proxy-side**: attached, with `resolve: proxy`, the proxy's
Go sekreto runs the chain and the application language resolves
nothing, so a Dart or Lua app reaches Vault, AWS and 1Password
without a Dart or Lua sekreto existing. Their gap is precisely *solo
mode with a non-env store*, where the library reads the environment
directly — the one provider that needs no library — and says so
rather than pretending.

**Tier C is the exception, and it compounds.** c, cpp, zig and lean
have no sekreto port *and* no wire client in v1, so proxy-side
resolution is not available to them either: they are env-only, full
stop, until they gain one or the other. Whichever arrives first
closes it — a sekreto port unlocks solo, a wire client unlocks
everything through the proxy — and a target with neither should not
be sold as covered. The permanent fix everywhere is a sekreto port,
contributed to sekreto; the tier table records who has one.

Two honesty notes the tiers force. In **c and zig** the SDKs' default
fetcher returns "live transport unavailable" unless the application
supplies `options.system.fetch` — so there, station's "HTTP truth" is
whatever that app-supplied callback does, and R1 injection necessarily
hands the credential back into app code (§5). In the **browser**, the
ts/js library must ship browser-safe entry points (conditional
exports; no unconditional `node:` imports for the file provider, token
file, or socket probe), and R1/R2 isolation does not exist at all —
any injected credential is readable by page code and DevTools; browser
station is observability-only with app-held credentials, and a
same-origin proxy endpoint is the only upgrade path. Both are Phase 1
statements, not Phase 2 discoveries, because bundlers consume the ts
package for browsers today.


## 3. The plugin contract

A **plugin** is a generated SDK bound to a station. The binding is made
by the generated station feature and consists of:

1. **Registration.** At SDK construction (`init` + `PostConstruct`),
   the feature builds the descriptor (§4) and registers it with the
   station, receiving a `Binding`: resolved base URL and server
   variables for the active profile, the credential plan (§5), the
   effective policy (§16), and capture settings.
2. **Transport middleware.** The feature wraps `utility.fetcher` with
   the station middleware, positioned per §3.3. The wrap covers
   `direct()` and `graphql()` traffic, which skip the hook pipeline
   but not the transport. In `attached` mode with proxied egress, this
   middleware is also where requests are enveloped to the proxy.
3. **Semantic events.** `PrePoint`, `PreDone`, and `PreUnexpected`
   hooks emit operation-level events (entity, op, outcome, duration)
   correlated with the HTTP-level events from the middleware via a
   per-operation id carried on the SDK's own `ctx`.
4. **Credential placement.** The feature never handles secret values.
   It arranges for `options.apikey` to hold a placeholder and lets the
   middleware perform injection (§5).

### 3.1 Binding forms

Three, all producing the identical binding (the placeholder is planted
at construction in each), because one shape does not fit 20 languages:

- **`station.connect(SDK, opts?)`** — where passing a
  class/constructor is idiomatic (ts, js, py, rb, …). Station
  constructs the SDK itself: merges the active profile's options,
  activates the station feature with explicit ordering (§3.3), plants
  the placeholder, returns the client.
- **Inverted binding** — where it is not (go, java, csharp, swift,
  c, zig): the app constructs the SDK through its **existing
  generated constructor** and hands it station-built options —
  `solardemo.NewSolardemoSDK(st.Options())` in go, `new
  SolardemoSDK(st.options())` in java — where `Options()` is the
  station library merging the handle, the activation entry, and the
  §3.3 feature order into the plain options map every generated
  constructor already accepts. The generated feature reads the
  handle from its feature options and performs the same registration
  and placement during construction. This is the *primary* binding
  form for static languages, not a fallback. (Sweeter per-language
  sugar — functional options in go, a builder in java — would be
  generator changes to the SDK targets themselves; deliberately not
  required for v1.)
- **`station.adopt(SDK, opts?)`** — the retrofit path for projects
  whose generated SDK predates the station feature. This is
  **construction-time sugar, not post-hoc attachment**: the first
  draft claimed `options.extend` could instrument an existing client
  instance, and the review killed that — `extend` is consumed exactly
  once, inside the constructor, and an extend-supplied feature's
  `init()` (where the transport wrap happens) only runs when a
  matching `feature.station.active: true` options entry exists.
  `adopt(SDK, opts)` therefore constructs the client itself with
  `extend: [station.adapterFeature()]` plus the activation entry and
  `__after__: 'test'` positioning, using the library's carried copy of
  the adapter. One core prerequisite makes this work: today the
  constructor's featureorder loop would see the activation entry and
  call `Config.makeFeature('station')` — which fails in an SDK whose
  generated `FEATURE_CLASS` has no station — *before* `extend` is
  processed. The generated constructor therefore learns to skip a
  featureorder name with no registered class when an extend-supplied
  instance carries that name (§9.3). The tolerance ships in the base
  templates, so `adopt()` works on any SDK regenerated after it
  lands, with or without the station feature installed; for SDKs
  older than that, regeneration is the retrofit. There is no
  supported late-attach of a live client in v1; a public
  `client.extend(feature)` runtime seam is noted in §9 as a possible
  future sdkgen change. In the five targets with no `extend` seam at
  all (c, zig, haskell, ocaml, lean), regeneration with the feature
  is the only retrofit either way.

If `adopt()` finds a real credential already resident in the options,
it hoists the value into the broker, overwrites `options.apikey` with
the placeholder before construction completes, and emits a one-time
warning event — so `options()`/`prepare()` become placeholder-safe
from that point, and the residual exposure is only "the value existed
in app code beforehand". The plugin's isolation rung (§5) is a visible
property everywhere plugins are listed — `station.plugins()`,
`voxgig-station status`, `station_integrations`, `station_secrets` —
never a silent downgrade.

An activated station feature with **no opened station** in the process
is an inert no-op that emits nothing and fails nothing (one warning
event once a station does open). Binding is never implicit: the
ambient instance exists (§10.2), but only `Station.open()` creates it.

### 3.2 Registry

The registry is explicit and queryable: `station.plugins()` returns
descriptors + live status + isolation rung. Nothing about the binding
is ambient magic; `connect`/`With`/`adopt` are sugar over documented
seams.

### 3.3 Wrap ordering — a pinned mechanism, not an assumption

Station's middleware must sit **immediately outside the base
transport** (i.e. inside `retry`, `cache`, `ratelimit`, `netsim`):
that position is what makes its `http` events wire-truth (each retry
attempt seen individually; cache hits *not* recorded as wire traffic)
and what keeps the injected credential below every
recording/buffering feature. The default feature order —
test-first-then-alphabetical — produces the *opposite* placement, and
the `__before__`/`__after__` controls are unusable for
config-constructed features (`makeFeature` builds instances without
`_options`). So the mechanism is explicit:

- `connect()`/`adopt()` pass the **ordered-array feature form** that
  `makeOptions` already supports — built from the *complete merged*
  feature set (the generated config's active features plus the
  caller's), with `station` placed immediately after `test`. A
  partial `[test, station]` array would do the opposite of its
  intent: `makeOptions` derives `featureorder` from the array names
  alone, so config-activated features (`log` is active by default)
  would silently drop out of init. The library computes the full
  order; it never hands `makeOptions` a subset;
- for the plain map-form activation (inverted binding, hand-written
  options), the generated `makeOptions` gains a station special case
  mirroring test's — a required sdkgen change listed in §9.3;
- the adapter verifies its position at runtime (mark the fetchdef,
  detect an unmarked inner wrapper) and fails loudly with
  `station_wrap_order` rather than silently reporting non-wire
  events;
- injection is skipped entirely when the base transport is a mock
  (`test`, `netsim` replay), so real credentials never enter
  in-memory mock stores;
- the `order` conformance-corpus section pins all of the above (a
  retried op yields N station `http` events; a cache hit yields
  none).

### 3.4 Lifecycle

Birth is §3-items-1-4. Death and duration, equally specified:

- **`station.close()`** — flush events with a bounded timeout,
  release grants, end the proxy session (`DELETE /v1/session`).
  Libraries hook the runtime's natural exit point where one exists;
  close is idempotent.
- **Sessions expire.** The proxy expires sessions on TTL; liveness
  piggybacks on `/v1/events` batches (no separate heartbeat
  endpoint). `status`/`station_integrations` therefore show truthful
  liveness, not ghosts.
- **Grants renew by re-registration.** On grant expiry the middleware
  re-registers (same descriptor, fresh session) transparently;
  reattachment after proxy loss is always a full re-register.
- **Process-per-request runtimes** (php, CGI perl) run solo by
  default; attached mode uses a cheap rejoin handshake (the register
  response is cacheable across requests, keyed by the authenticated
  app identity *plus* descriptor hash — hash alone would hand one
  app's `{ session, binding }` to another app that registered a
  byte-identical descriptor, straight through the per-app grant
  boundary of §8.4 — and the cached entry expires with the session
  TTL above) — specified so the per-request cost is one conditional,
  not one registration.

### 3.5 Config resolution

One total order, lowest to highest precedence, identical in every
library and pinned by the `profile` corpus section:

1. generated SDK `Config` defaults (including the feature's model
   defaults),
2. station feature options passed at SDK construction (in-code
   defaults),
3. `station.json` base (`profiles.default`),
4. `station.json` selected profile overlay (deep-merge per plugin —
   **except `secrets.providers`, which replaces wholesale**),
5. `VOXGIG_STATION_*` env vars,
6. `Station.open(opts)`,
7. `connect`/`adopt` per-plugin opts.

`station.json` is looked up from cwd upward to the repo root, then
`~/.voxgig/station.json`. The profile is `VOXGIG_STATION_PROFILE`,
else `default`. All station env vars are namespaced
`VOXGIG_STATION_*` (`VOXGIG_STATION_URL`, `VOXGIG_STATION_PROFILE`) —
one prefix, stated as a rule so future vars don't drift.


## 4. The descriptor

The descriptor is the machine-readable answer to "what is this
integration and what can it do?" — consumed by the station library,
the proxy, the MCP tools, and any agent that asks.

**Rule: the descriptor is a view over the embedded config, not a
second model.** Every generated SDK already carries the
`configDefinition()` output in every language. The station feature
exposes it; the library normalizes it into:

```
descriptor v1
├─ station: 1                    (descriptor schema version)
├─ name, slug, envtoken          (identity — slug carried, not derived; see below)
├─ version                       (SDK package version)
├─ target                        (language target id, e.g. 'ts', 'go')
├─ base, server[]                (base URL + server-variable spec)
├─ auth: { active, prefix, secretname-default }
├─ entities: { <name>: { fields, ops: { <op>:
│      { points: [{ method, path, params, select? }] } } } }
└─ features: [ present features + active state ]
```

Three small sdkgen changes fall out (all additive, all in
`configDefinition()` in `ts/src/utility.ts`, the single place the
embedded config is built):

- add `main.version` (the target's `publish.version`), so a running
  plugin can report what it is;
- add `main.target` (the generating target name), so the proxy can
  label cross-language traffic;
- add `main.slug` (= `model.name`, the hyphenated slug). Today the
  embedded config's only identity is the camel `Name`, and deriving
  an env token from the camel form *swallows hyphens* — the exact
  defect `packageMeta.ts` documents (`voxgig-solardemo` yielding
  `VOXGIGSOLARDEMO_…` instead of `VOXGIG_SOLARDEMO_…`). The slug is
  carried, `envtoken = envToken(slug)`, and `secretname-default` is
  then the **sekreto name** `<envToken(slug) lowercased>.apikey` —
  `voxgig_solardemo.apikey`, never an `env:`-prefixed reference,
  since §5 deleted that grammar and sekreto would reject the string
  as a malformed name. Without this field the "a project that does
  nothing gets current behavior" promise in §5 silently breaks.

For SDKs generated before these fields existed (`adopt()` targets),
the normalizer emits fixed sentinels — `version: "0.0.0"`, `target:
"unknown"`, `slug` derived best-effort from `name` with the hyphen
caveat surfaced as a warning event — and the corpus carries a
legacy-config case so all libraries agree.

Ops keep the **points array** (an op can multiplex several routes —
apidef folds `$action` routes into `create` today, e.g. `POST /planet`
and `POST /planet/{id}/terraform` under one op with `select.$action`).
`station_call` v1 targets each op's canonical point (the `opShape`
canonical-point rule); action routes via station are an open question
(§18), but the descriptor does not throw the information away.

**Canonical form.** "Byte-equivalent descriptors across languages" is
only meaningful with a serialization spec, so descriptor v1 defines
one: UTF-8, object keys sorted bytewise, no insignificant whitespace,
integers only in descriptor-defined numeric fields, minimal JSON
escaping. `canonical-serialize` is its own corpus section with
adversarial cases (non-ASCII entity names, large ints), because Lua's
`pairs()` and friends guarantee nothing without it. The proxy depends
on this when it synthesizes requests (§7) and when it dedupes
re-registrations by descriptor hash (§3.4).


## 5. Secrets: sekreto resolves, station places

The design principle: **application code names a secret; sekreto
resolves it; station places the value where the application cannot
reach it and the wire still gets it.**

Station does not implement secret access, because
[voxgig/sekreto](https://github.com/voxgig/sekreto) already does — one
interface over environment variables, `.env` files, mounted-secret
directories (Kubernetes, Docker, systemd credentials), HashiCorp Vault
and OpenBao, boru vaults, AWS Secrets Manager and SSM Parameter Store,
GCP Secret Manager, Azure Key Vault, 1Password Connect, Doppler and
Infisical. Ten language ports, all pinned to one shared conformance
spec (`spec/sekreto.json`, run by every port through voxgig/omni), all
with zero third-party dependencies except Rust's rustls for TLS. That
is precisely the discipline §10 and §13 ask of station's own
libraries, already done — for the half of the problem with the most
surface area and the worst failure modes. Rebuilding it inside station
would be the same code, less tested, in more languages.

The division of labour:

| concern | owner |
|---|---|
| what a secret is called, where it lives, how it is fetched | **sekreto** |
| which plugin needs which secret, in which profile | **station** (§5.2, §11) |
| keeping the value out of app code, captures, and agent context | **station** (§5.3) |
| resolving without the process ever holding the value | **station's proxy**, resolving through sekreto (R2) |

A want that is really a *store* want — an OS keychain provider, say,
which sekreto does not have today — belongs in sekreto as a provider
kind, not in station. That is what having a subcomponent means.

### 5.1 Naming — the mapping is already the SDK's

A sekreto name is dot-separated lowercase segments matching
`[a-z0-9_]+` (`api.token`, `db.pass.main`). Station's default name for
a plugin is **`envToken(slug)` lowercased, plus `.apikey`** —
`voxgig_solardemo.apikey`.

Deriving it from `envToken` rather than by replacing hyphens is the
load-bearing part. The model's `name` is an unrestricted string, so a
slug may carry uppercase or punctuation that is not a hyphen; a
narrow hyphen swap would then produce either an invalid sekreto name
or a valid one whose `envkey()` no longer equals the SDK's
`envName()`, which is the whole promise. `envToken` already
normalizes every non-alphanumeric and the case, in one place, and
this rule must call that same helper rather than restate it — the
"one rule, one place" discipline sdkgen has spent several fixes
enforcing.

The result is not a compromise but a coincidence worth keeping: it
lands character-for-character on the convention generated SDKs
already document. sekreto's `envkey()` joins segments with `_` and
upper-cases, so `voxgig_solardemo.apikey` → `VOXGIG_SOLARDEMO_APIKEY`,
which is exactly what sdkgen's `envName()` emits for the slug
`voxgig-solardemo`. The `secretname` corpus section (§13) pins the
round-trip in both directions, precisely because two independently
maintained grammars meet here. A
project that installs station and configures nothing keeps reading the
same environment variable it reads today, now through sekreto's `env`
provider: §11's "a project that does nothing gets current behavior"
with a named mechanism behind it rather than a promise.

Every other store follows from the same name by sekreto's own
mappings, with no station involvement: `vaultref()` → path
`voxgig_solardemo`, field `apikey`; `awsparam()` →
`/voxgig_solardemo/apikey`; `flatname()` → `voxgig_solardemo_apikey`
for GCP and, because Azure Key Vault's alphabet is letters, digits and
hyphens only, `voxgig-solardemo-apikey` for Azure — which lands back
on the project's own hyphenated slug. Station writes no store mapping
of its own, and the descriptor's `secretname-default` (§4) carries the
name, not a location.

### 5.2 The provider chain lives in station.json

A profile carries a sekreto **provider chain** verbatim — the
declarative `ProviderSpec` form sekreto already accepts in config —
plus the per-plugin secret name:

```json
{ "station": 1,
  "profiles": {
    "dev": {
      "secrets": { "providers": [
        { "kind": "env" },
        { "kind": "dotenv", "file": ".env.local" } ] } },
    "prod": {
      "secrets": { "providers": [
        { "kind": "hashicorp", "addr": "https://vault.example.com",
          "auth": { "method": "kubernetes", "role": "solar" } } ] },
      "plugin": { "solardemo": {
        "secret": "voxgig_solardemo.apikey",
        "resolve": "proxy" } } } } }
```

Transparent resolution is the default and the reason sekreto exists:
the first store that has it wins, and moving a secret from `.env` to a
vault is a config change, not a code change. Station adds nothing to
that. Where *which* store answers is part of the meaning — promoting a
value between environments, or checking that a secret really landed in
the vault — a plugin may name a store and station calls `getfrom`
instead of `get`.

Two sekreto semantics station must not paper over, both load-bearing:

- **A miss is not an error.** A store that does not hold the secret is
  a miss and the chain carries on; a store that *could not answer* — a
  locked vault, a refused login, an unreachable host — raises, because
  falling through there would quietly reach for a weaker store.
  Station surfaces the first as `station_secret_no_value` and the
  second as `station_secret_error` with sekreto's message intact, and
  never retries an error against a lower-trust provider.
- **Plaintext refusal.** sekreto raises before a socket is opened if a
  token would ride `http://` to anything but loopback. Station does
  not soften that for local-dev convenience; the profile is wrong, not
  the guard.

### 5.3 Isolation rungs — what each one actually is

- **R0 (legacy, no station):** `options.apikey` as today. Unchanged.
- **R1 (solo): hygiene, not a security boundary.** Station asks
  sekreto for the plugin's secret and holds the returned value
  privately; the SDK's `options.apikey` is an inert placeholder;
  `prepareAuth` runs normally and produces an `authorization` header
  containing the placeholder; the middleware swaps in the real value
  at send time. What R1 buys, by construction: `client.options()`
  never exposes the value; `client.prepare()` output is safe to log or
  hand to an agent (today it carries the real key); captures, events,
  and `ctrl.explain` never contain it. What R1 does **not** buy —
  stated plainly because an earlier draft overclaimed it: protection
  against hostile in-process code. In dynamic runtimes closures are
  introspectable (`__closure__`, `debug.getupvalue`), transport slots
  are reassignable, and with the default `env` provider the value sits
  in process environment regardless. R1 keeps secrets out of the
  places they *leak by accident* — logs, captures, diffs, agent
  context windows. R2 is the rung that removes the value from the
  process.
- **R2 (attached, `resolve: proxy`):** the application process never
  runs the chain at all — the **proxy** holds the sekreto instance and
  the provider credentials (the Vault token, the AWS keys), which is
  also why those credentials stop being per-app deployment config.
  Registration yields a **grant**: a token bound to the registration
  session, plugin-scoped, TTL'd (default 15m, renewed by
  re-registration, §3.4), revocable (`voxgig-station revoke <plugin>`
  / `DELETE /v1/grants/{plugin}`; `mode: block` is the hammer). The
  middleware sends the envelope with the grant; the proxy swaps in the
  real credential on the outbound hop. On a single-user local machine
  the register token file is the true boundary — a process that can
  read it can mint grants — so R2's honest local value is that **the
  secret value never enters or persists in the application process**;
  containment of a live local attacker is not claimed. Plugin-scoping
  becomes a real boundary on a remote proxy, where registration is
  authenticated per app identity (§8.4).

sekreto draws the same R1/R2 line from the other side, and says so in
its own README: "an app calling `secrets.get()` necessarily *holds*
the secret. If the caller is untrusted, boru's broker is the better
tool and sekreto is the wrong layer." R1 is sekreto used exactly as
intended, with station keeping the returned value out of the
accident-prone surfaces. R2 is the broker case, and station's proxy is
that broker for SDK-shaped traffic — using sekreto as its provision
layer rather than replacing it. Where an agent only needs to call an
HTTP API with a credential it must never hold, and no SDK semantics,
capture, policy or cross-language plugin registry are wanted, boru's
own `vault proxy` / `vault mcp` is the smaller correct tool and
station is over-specified. A design that cannot say when not to use it
is not finished.

**Copy-on-inject is mandatory.** The generated request machinery
shares object references — `fetchdef.headers` *is* `spec.headers`,
and `ctrl.explain` stores `fetchdef`/`spec` by reference before the
fetcher runs — so an in-place header swap would leak the real value
into `ctrl.explain`, `ctx.spec`, and every post-request hook. The
middleware clones the fetchdef and its headers map before swapping;
the object graph reachable from `ctx`/`spec`/`ctrl` holds only the
placeholder, ever. The `inject` corpus section asserts exactly this
(after a completed op, `ctrl.explain.fetchdef.headers` still holds
the placeholder) in every language.

**Injection placement:** below every recording feature and never into
mock transports (§3.3). In c/zig, where the app supplies the base
transport, the injected value necessarily crosses into that
app-supplied function — R1 there is conditional, and the tier table
(§2.2) says so.

SDKs whose model opted out of auth (`isAuthActive` false) skip
credential planning entirely but get everything else. The model's
single-credential reality (one `apikey`, no OAuth flows, no rotation)
keeps v1 honest: one secret name per plugin; the `Binding` reserves a
keyed name map for when the model grows multi-scheme auth, where
sekreto's `all(names)` fetches the set in one call (§18). Rotation,
when it comes, has a mechanism waiting too — sekreto's `refresh()`
drops the cache so the next resolve asks the stores again.


## 6. Observability and debugging

Station defines one normalized event stream and makes everything else
a producer into it or a consumer of it.

**`StationEvent` v1** (schema pinned by the `event` corpus section;
evolves additively — unknown fields are ignored):

```
{ t, session, plugin, corr,
  kind: construct | op | http | error | feature | station,
  op?:   { entity, op, outcome, durationMs },
  http?: { method, host, path, status, durationMs, bytes },
  err?:  { code, status, message },
  meta?: { … } }
```

Producers: the transport middleware (`http` events — wire truth,
including `direct()`/`graphql()`, one event per attempt); the hook
bridge (`op` events, correlated via `corr`); and the existing features
when active — `debug.onEntry`, `telemetry.exporter`, the `metrics`
counters, the `log` feature's injectable logger, `audit` entries
(bridged as `feature`-kind events; audit is the compliance-flavored
stream, so consolidation matters most there), and `clienttrack`'s
correlation ids (folded into `corr`). Projects already using those
features get consolidation for free; station requires none of them.

**Delivery semantics** are per execution model, stated because
"fire-and-forget" assumes concurrency some targets lack: threaded and
async runtimes flush batches in the background; synchronous
single-threaded libraries (c, lua, perl) flush inline at operation
boundaries under an explicit time/size budget that §14's latency
budget includes; process-per-request runtimes use the §3.4 rejoin
path or stay solo. In every model: events never fail an operation,
and never delay one beyond the stated budget — zero for threaded
and async runtimes, the explicit inline budget for the synchronous
single-threaded targets, which is *bounded blocking* and is named
as such rather than promised away as non-blocking (§14 line-items
it); buffers are bounded, overflow drops oldest, and drop counts
are visible in `status`.

Consumers: **solo** — a bounded ring buffer (`station.events()`), a
live subscription (`station.tap(fn)`, callbacks serialized), nothing
else. **attached** — NDJSON batches to the proxy, which holds the
cross-process capture store and exports **OTLP** from one place.

Capture depth is policy, not code: `capture: meta | headers | full`
(default `meta`; `headers`/`full` apply redaction, §15).

Debugging is a loop on top of the capture store:

- `voxgig-station tap [plugin]` — live redacted traffic across every
  attached process, any language (CLI-only surface; the MCP
  equivalent is cursor-based `station_traffic`).
- `voxgig-station traffic --plugin solardemo --since 5m --grep 404`.
- `voxgig-station replay <capture-id> [--set query.id=42]` — re-issue
  a captured request through the same policy/injection path.
  **Replay semantics per header class** (these two decisions collide
  otherwise): redacted auth headers are re-injected through the
  credential path; one-time headers (`idempotency-key` and
  project-configured equivalents) are stripped and freshly minted,
  with the response annotated that dedup identity changed; replaying
  a *mutating* capture refuses by default and requires an explicit
  flag — and, from the agent surface, the `agent.write` gate (§16).
  `--set` mutations are bound to query/params/body — never method,
  host, or path root.
- `voxgig-station mock --record` / `--replay` — record real traffic,
  serve it back; the complement of `netsim` (netsim fabricates
  conditions; mock replays reality).

The CLI and MCP tools are two skins over one proxy API. Parity is
enumerated, not aspirational: every query/replay/secrets/policy/call
verb exists on both; `tap` live-follow and `mock` control are
documented CLI-only surfaces in v1.


## 7. The agent surface (MCP)

The proxy is an MCP server (`voxgig-station mcp`, stdio for `claude
mcp add`; streamable HTTP on the daemon for shared use — the two
transports go-mcp already established, same official Go SDK).

**Design choice: few generic tools driven by descriptors, not tool
explosion.** go-mcp's precedent (generic tools with an `entity`
argument) scales to N plugins as station-prefixed tools; per-entity
registration would blow MCP hosts' tool budgets by the second SDK.

| tool | does |
|---|---|
| `station_status` | is station itself healthy: proxy version, per-plugin mode + isolation rung + secret resolution state, drop counters |
| `station_integrations` | list plugins with a compact entity/op summary — one call answers "what can I call" |
| `station_describe {plugin, entity?}` | drill into a descriptor: entities, ops, params, field types and requiredness |
| `station_call {plugin, entity, op, query?, data?}` | execute an operation (canonical point, §4) |
| `station_traffic {plugin?, since?, grep?, cursor?}` | query recent redacted captures (cursor-based; the MCP skin of tap) |
| `station_replay {id, mutate?}` | replay a capture, under §6's per-class semantics and §16's gates |
| `station_secrets {plugin?}` | resolution *status* per plugin — which store answered, never values, straight from sekreto's `sources()`/`stores()`/`has` (`describe()` returns `env:<prefix>`, `dotenv:<file>`, `hashicorp`, … — safe by construction) — plus secret-free remediation for anything unresolved ("set env var `VOXGIG_SOLARDEMO_APIKEY`"; "`hashicorp` is in the chain but returned a miss") |
| `station_policy {plugin?}` | effective policy view |

Agent-facing affordances are specified, not hoped for: entity/op
matching is case-insensitive with the canonical form echoed back;
unknown plugin/entity/op errors list the valid candidates in the
error payload; every error carries a §14 catalog code.

`station_call` is the significant one: the proxy synthesizes the HTTP
request directly from the descriptor and sends it through the same
policy, injection, and capture path as library traffic. **The agent
surface therefore has no dependency on any language runtime** — a
Python app's integrations are callable by an agent whether or not
Python is installed where the proxy runs. This is what the canonical
descriptor (§4) buys.

Safety defaults, because agents are a first-class *threat* as well as
a first-class user: `station_call` allows `load`/`list` by default;
mutating ops require the plugin's policy to opt in (`agent.write:
true`), and `station_replay` of a mutating capture sits behind the
same gate. An `agent.read` knob exists too — default true on a local
proxy, default false on a remote one (§8.4). Tool *output* is
untrusted content: `station_traffic` and `station_call` feed
upstream-controlled response bodies into the agent's context, and the
threat model (§15) names prompt injection through that channel
explicitly — the MCP server labels tool results as external data and
never embeds instructions in them.

Secrets are structurally invisible on this surface — with one caveat
handled rather than hand-waved: no tool *emits* a value by design,
but an upstream can echo an injected credential back (a 401
diagnostic, a token exchange), and `station_call`'s live result is
not the capture store, so capture-time redaction alone would not
cover it. Tool responses therefore pass the same credential-aware
scrub as captures before entering the agent's context: redact-list
headers, plus sekreto's own `redact(text)`, which replaces every
value *that* sekreto instance resolved — and without sekreto's
four-character readability floor, which is right for logs and wrong
here. On this boundary and in capture redaction, station scrubs
every resolved credential exactly, whatever its length, because the
promise is absolute. With that in place, an agent given full
station access can
operate every integration without being *able* to read a credential
— the §5 caveats about in-process code do not apply on the MCP side
of the proxy.


## 8. The wire protocol and the proxy

**Protocol v1: HTTP/1.1 + JSON**, versioned in the path (`/v1/…`) and
a `Station-Protocol: 1` header; NDJSON for event batches. Tier A
languages implement it with their platform stack; tier B with one
declared dependency; tier C not at all in v1 (§2.2).

### 8.1 Discovery and local auth

1. explicit `proxy: <url>` in config;
2. `VOXGIG_STATION_URL`;
3. `auto` probe: the unix socket `~/.voxgig/station/station.sock`
   first **where the library's HTTP stack supports it** (an optional
   per-library optimization — several stacks can't speak HTTP over
   UDS), else loopback TCP (default `127.0.0.1:8299`, configurable
   via `--listen`/`VOXGIG_STATION_URL`).

Local auth is a token file (`~/.voxgig/station/token`, 0600, in a
0700 directory, created by the proxy on first run). But a fixed
loopback port is not the Docker-socket model — any local user can
bind it first — so the client **authenticates the proxy before
sending anything sensitive**: on TCP, a challenge-response
proof-of-token precedes the bearer token, envelopes, and events —
and it has a wire home rather than an out-of-band hand-wave: the
client sends its nonce on the already-exempt health endpoint
(`GET /v1/health?nonce=…`) and the proxy's response carries a
`Station-Proof: HMAC(token, nonce)` header (both sides hold the
token file), so the unauthenticated surface stays exactly one
endpoint long. Probe failures — including
auth/proof failures against an imposter — degrade exactly like
absence, with the cause named in the warning event. Every request on
every transport requires the bearer token (only `/v1/health` is
exempt, and it returns nothing sensitive); the daemon validates
`Host` against expected local values and rejects unexpected `Origin`s
(the MCP endpoint per the MCP spec) — a loopback JSON daemon is the
classic DNS-rebinding target and is hardened as such.

### 8.2 Control and data planes

Control:

- `POST /v1/register` — descriptor + process identity `{ pid, lang,
  app }` + reserved `identity: { org?, app?, principal? }` (ignored
  by a local proxy, load-bearing on a remote one — reserved *now* so
  remote does not force a wire v2) → `{ session, binding }`
- `POST /v1/events` — NDJSON batch; carries session liveness
- `DELETE /v1/session` — clean shutdown (§3.4)
- `DELETE /v1/grants/{plugin}` — revocation
- `GET /v1/policy/{plugin}` — long-poll for policy updates
- `GET /v1/health`

Data:

- `POST /v1/forward` — an explicit request **envelope**: `{ url,
  method, headers, body }` plus `Station-Session` /
  `Station-Plugin` / `Station-Corr` headers, and `Station-Redact`
  naming which envelope headers carry credentials the library itself
  resolved, so the proxy can scrub them from its own capture of the
  exchange without ever storing them (§15). The proxy applies
  policy, injects credentials (R2), sends upstream, and captures.
  The response is deliberately *not* a JSON wrapper — a JSON `body`
  field can neither stream nor carry binary without escaping — so
  the upstream status and headers ride back as response metadata —
  `Station-Status` for the status; the upstream headers themselves
  individually, each prefixed `Station-Up-`, repeats preserved. (One
  aggregated base64-JSON header was rejected: a third of encoding
  overhead, and a large-but-valid set — several sizable `Set-Cookie`
  values, say — would blow a single-header limit in some attached
  language's HTTP stack even though the original response was fine.)
  The raw upstream body is the response body itself, passed through
  chunked and binary-safe. The proxy's upstream client **never
  follows redirects**: a 3xx rides back like any other response, so
  a `Location` pointing off the `policy.hosts` allowlist cannot pull
  an automatic follow-up request — injected credentials attached —
  to a host no policy decision ever approved. A caller that chooses
  to follow issues a new envelope, policed, credentialed, and
  captured like any other. Request bodies are buffered in v1 with a
  size limit (below); streaming uploads are an open question (§18).

A transparent HTTP forward proxy (the existing `proxy` feature's
`fetchdef.proxy` seam) was considered and **rejected** for the data
plane: HTTPS through a forward proxy means `CONNECT`, and a `CONNECT`
tunnel is opaque — no injection, no capture — unless the proxy
terminates TLS with an installed MITM CA, which is a developer-trust
and operational disaster. The envelope keeps the proxy a first-party
recipient, not an interceptor. (The `proxy` feature remains what it
is — egress routing through corporate proxies — and composes: the
station proxy's own upstream calls honor `HTTPS_PROXY`.)

### 8.3 Proxy-side policy authority

The review's most important finding: **everything a client registers
is untrusted input.** The descriptor is built client-side; the secret
name comes from client-side profile loading; process identity is
self-reported. If the proxy derived the egress allowlist and the
plugin→secret binding from registration, a compromised (or merely
local, token-holding) process could register `slug: solardemo, base:
https://evil.example, secret: voxgig_solardemo.apikey` and have the
proxy resolve that name through its Vault-backed chain and inject the
real credential into a request to the attacker's host. Note what is
*not* the flaw: sekreto resolved exactly the name it was asked for,
correctly. Choosing the name and the destination is station's half,
and station must not take either from the client.

So, as policy: under `resolve: proxy`, the plugin→secret-name mapping,
the provider chain, and the `hosts` egress allowlist all come from
**proxy-side configuration** — the proxy loads `station.json` profiles
itself and builds its own sekreto instance from them. Where no
proxy-side profile covers a plugin, there is no first-seen shortcut
(trusting the first registration would just move the race to whoever
registers the slug first): the plugin parks in a **pending** state —
registered, visible in `status`, capture and library-resolved traffic
working — but proxy-side resolution and its hosts default stay
unusable until `voxgig-station approve <plugin>` explicitly blesses
the base/hosts/name triple, and any later change to that triple
re-enters pending. A registered descriptor can only *narrow* what
approved proxy-side policy allows, never widen it, and never selects
which secret is resolved. Plugins resolving in-process (R1) don't
route secrets through the proxy, so registration for them is
lower-stakes — capture and policy still apply.

### 8.4 Remote mode

Remote is the same binary behind TLS with per-app bearer tokens, and
in v1 it is **explicitly single-team and fully mutually trusting**:
every attached app can see every capture, and `agent.read` defaults
off (§7). Grants bind to the authenticated app identity, which is
where plugin-scoping becomes a real boundary (§5.3). Visibility
partitioning, per-principal authz on call/replay/secrets, and tenant
isolation are the open question that gates any shared deployment
(§18) — the `identity` field in `/v1/register` and per-app tokens are
reserved now precisely so answering it doesn't break wire v1.

### 8.5 Bounds and storage

Named defaults, all configurable, all visible in `status`: library
ring 1k events; proxy capture store 10k entries / 256 MB LRU;
`capture: full` bodies truncated at 64 KB with a `truncated` marker;
`/v1/forward` request-body limit 32 MB with a structured error.
Truncation and redaction make some captures lossy, and a lossy
capture is not a replayable one: each capture records `replayable`,
false when the request body was truncated or body-field redaction
replaced bytes the request needs (redacted *auth headers* are the
exception — replay restores those through the credential path, §6),
and `replay` refuses a `replayable: false` capture with
`station_replay_lossy` rather than silently re-issuing a corrupt
request.
In-memory by default; the optional SQLite capture store (for
replay/record across restarts) carries age/size retention config;
secret values live in memory only — every sekreto provider is a
*reader*, and station adds no store of its own, so there is no
station-written copy of a credential anywhere on disk. sekreto's own
cache is per-instance and in-memory, dropped by `refresh()`.
Encryption at rest for the SQLite store: §18.

### 8.6 Compatibility

Five artifacts version independently — wire protocol, descriptor
schema, StationEvent schema, each library's semver, and the generated
adapter frozen into consumer repos at add time. The policy: the proxy
accepts wire and descriptor versions N and N−1 and rejects unknown
versions with a structured error (`station_protocol`) the library
surfaces; descriptor and event schemas evolve additively within a
major (unknown fields ignored); an adapter pins its library to
`^major` via the feature model's `deps.<lang>` entry, and bumping
that range on a library major is the station repo's job (it owns the
sdkgen-station package). Skew is the steady state — `add` is
overwrite and adapters live for years in consumer diffs — so
compatibility is designed, not hoped.


## 9. The sdkgen integration

What lands in sdkgen or the sdkgen-station package — the
generator-side half:

1. **The `station` feature.** A feature model
   (`model/feature/station.aontu`) declaring top-level `active: true`
   like every shipped feature (model-level `active: false` would
   exclude it from the embedded config and strip its source at
   generation — the off-by-default convention lives at
   `config.options.active: false`, which station follows), hooks
   `PostConstruct`, `PrePoint`, `PreDone`, `PreUnexpected` active,
   and `config.options`: `{ active: false, url: '', fromEnv: true,
   profile: '', secret: '', register: true, capture: 'meta' }`.
   Per-target adapter source lives in each target's feature container,
   wherever the discovery walk (`ts/src/helpers/featureSource.ts`)
   finds it — `src/feature/station/` for ts/js, `feature/
   station_feature.go` for go, `pkg/feature/` for py, `lib/feature/
   station/` for dart, and so on; the walk exists precisely because
   the container path differs per target. Six targets declare
   `feature.trim: false`, in two distinct shapes: **zig and scala**
   keep per-feature files but statically reference every feature
   (root.zig/build.zig; SdkTestMain.scala) — a station adapter there
   is a new file plus edits to those reference points; **haskell,
   clojure, ocaml, lean** hold all feature code in one monolithic
   module an external package cannot safely overlay (a whole-file
   overlay would fork the base scaffold's copy and resync-clobber —
   the exact defect class CLAUDE.md warns about). Adapters for those
   four are deferred until either the modules become model-driven or
   station graduates into the bundled scaffold where the module has
   one owner — consistent with their tier-B/C placement and Phase 3
   (§17).
2. **A per-language dependency on the station library.** The
   generated SDK depends on the station library only; sekreto is the
   station library's own dependency, declared there
   (`@voxgig/sekreto`, `@voxgig/sekreto-js`, `voxgig-sekreto`,
   `github.com/voxgig/sekreto/go`, `voxgig_sekreto`, …) and never
   named in a generated manifest — one edge per language, not two,
   and sdkgen learns nothing about secret stores. For the ~14 targets
   whose `Package_<lang>` components consume `collectDeps`,
   the feature model's `deps.<lang>` blocks flow the dependency into
   generated manifests (peer for ts/js — the `log` feature's pino
   precedent — prod elsewhere). Targets whose manifests are hardcoded
   today (haskell, clojure, elixir, ocaml, lean, scala) need their
   Package components taught to consume `collectDeps` first — a
   listed prerequisite, not a footnote. Registry-less targets (c,
   cpp, zig) get the library **vendored** through the sdkgen-station
   `tm` overlay, accepting the consequences: the vendored source
   falls under add-overwrite/doctor semantics and its release cadence
   couples to `package add`. (Their tier-C solo-only scope keeps that
   vendored surface small.)
3. **Three additive `configDefinition()` fields** (§4:
   `main.version`, `main.target`, `main.slug`) and **two
   base-template changes**: the generated `makeOptions` gains a
   station featureorder special case mirroring test's (inserting
   station after test in the *merged* order, so map-form activation
   gets the §3.3 placement without the ordered-array form), and the
   constructor's featureorder loop learns to skip a name with no
   registered feature class when an `extend`-supplied instance
   carries it — the `adopt()` prerequisite (§3.1).
4. **README, agent-guide, and repo docs.** A `ReadmeStation` section
   (composed by `Readme.ts`, gated on the feature) documenting the
   binding forms, secret names, and the proxy quickstart (pointing at
   sekreto's own docs for stores rather than restating them); a
   station paragraph
   in generated `AGENTS.md` via `AgentGuide`/`AgentGuideFeature`; and
   in sdkgen's own docs map: `docs/how-to/use-station.md` (the
   §11 install flow is a textbook how-to), the station feature's
   options in the model reference, and an error-code catalog page
   under `docs/reference/` that ReadmeStation links — one canonical
   catalog, seeded with the existing SDK codes.
5. **Distribution: external package first.** The feature ships as
   `@voxgig/sdkgen-station` — an sdkgen package (manifest +
   `.sdk/model/feature/station.aontu` + per-target `tm/` overlays),
   installed with `voxgig-sdkgen package add @voxgig/sdkgen-station`.
   This exercises the package system's feature-overlay path with a
   real external package (it has none today) and keeps station's
   release cadence off sdkgen's. Because the bundled test suites
   cannot exercise a feature that isn't installed, **pre-graduation
   generator-side testing runs from the package side**: sdkgen-
   station's CI installs sdkgen, runs `package add` + `add-feature
   station` + generate into a fixture consumer across all shipped
   targets (the `generate.test.ts` memfs pattern), plus `package
   check`. The bundled suites take over at graduation.
6. **A sequencing rule, stated once:** *an adapter never ships for a
   target before that target's station library exists* — otherwise
   the generated manifest depends on a package that doesn't resolve
   and the consumer's first five minutes is a broken build. §17's
   phases obey it.

Existing targets are repositioned, not changed: **go-mcp** stays the
right answer for "one SDK, standalone MCP server, no other moving
parts"; the station proxy is the answer for "all my integrations, one
agent surface". go-cli similarly. Neither grows a station dependency
in v1.

Constraints inherited from the feature system, stated so nobody
relearns them: feature names cannot be aliased (`station` is the
name, everywhere); `add` is overwrite, so adapter source must stay
doctor-comparable (project customization goes through options, never
edits); feature source reaches only targets present at add time, and
`package add` orders targets-then-features correctly. A possible
future sdkgen change — a public `client.extend(feature)` late-attach
seam — would upgrade `adopt()` beyond construction-time sugar; it is
deliberately not required for v1.


## 10. The libraries: the modem principle

D5 says hand-written. Twenty-odd hand-written libraries stay
sustainable only if they are small, and they stay small only if the
design *forbids* them from growing. The rule:

> **The library is a modem, the proxy is the machine.** A station
> library implements exactly: config/profile loading, the credential
> placeholder + copy-on-inject middleware, the event buffer/batcher,
> the descriptor normalizer + canonical serializer, the wire-protocol
> client (tier A/B only), and the ambient instance. Nothing else — no
> OTel, no storage, no TLS configuration beyond the platform default,
> and **no secret store clients**, because that is sekreto's job.

sekreto is the one dependency a station library takes, and it is
taken rather than reimplemented for the same reason this rule exists.
In nine of the ten ports it costs nothing against the budget: sekreto
carries zero third-party dependencies of its own, so `station →
sekreto` adds one well-tested library and no transitive tree at all.
Rust is the stated exception — sekreto there takes `rustls` (plus
`webpki-roots` for trust anchors) for TLS, which brings its own crate
graph, and hand-rolling TLS in a secrets library would be far worse
than depending on an audited one. So the Rust station library, alone,
inherits a real dependency tree, and its generated `Cargo.toml` and
tier budget must account for it rather than treat sekreto as free.
Where sekreto has no port, the library falls back to reading the
environment and says so (§2.2); it does not grow a second provider.

### 10.1 Budgets, honestly

Roughly 1–2k lines for GC'd languages with a platform HTTP stack (tier
A) — the ballpark of a larger existing feature implementation. That
number does **not** hold for c/cpp/zig, where there is no substrate to
lean on (the C SDK's value/JSON machinery ships inside each generated
SDK, not as a reusable library) — which is one more reason those
targets are tier C: a solo-only station with no wire client, no
canonical serializer duty beyond the descriptor it hands the app, and
a shared vendored C core for c/cpp (the voxgig-struct precedent) if
demand pulls them further. Budgets are per tier, in the tier table's
repo home, and a library that busts its budget is redesigned, not
merged.

### 10.2 Shared contracts

- **Ambient instance:** `Station.open()` returns the process-ambient
  singleton; it is idempotent, and a second `open()` with conflicting
  options is an error. `new Station(opts)` (or the idiomatic
  equivalent) creates an isolated instance for tests and multi-tenant
  hosts. `adopt` and feature-driven binding target the ambient
  instance; binding one client twice is an error.
- **Concurrency:** all public station operations are safe to call
  from any thread; registry and buffers are internally synchronized;
  `tap` callbacks are serialized. Each library uses its idiom; the
  observable contract is fixed. The JSON corpus cannot express this,
  so per-language stress tests against the testkit proxy cover it
  (§13).
- **Layout:** the `voxgig/station` repo mirrors a generated SDK
  project's shape — per-language directories (`ts/`, `go/`, `py/`,
  …), the proxy under `proxy/`, the conformance corpus under
  `spec/`, and `sdkgen-station/` holding the sdkgen package. Every
  voxgig engineer and agent already knows how to navigate that shape.

Rollout follows the tier table and the parity-tier spirit (§17):
reference implementation is `ts`, as it is for the SDK targets.


## 11. Developer experience

The walkthroughs the design is accountable to:

**Zero to station (existing app, two lines):**

```ts
import { Station } from '@voxgig/station'
import { SolardemoSDK } from '@voxgig/solardemo-sdk'

const station = Station.open()               // profile/env/proxy all defaulted
const solar = station.connect(SolardemoSDK)  // was: new SolardemoSDK({ apikey: … })

const planets = await solar.Planet().list()
```

No proxy running, no config file: `open()` finds no `station.json`,
uses profile defaults, and asks sekreto's default one-provider chain
for `voxgig_solardemo.apikey` — which is `VOXGIG_SOLARDEMO_APIKEY`,
the env var this SDK's README already documents, unchanged. Runs solo.
Strictly better than before: the key is out of app code's way — no
longer in `options()`, `prepare()` output, captures, or logs (§5.3's
honest scope) — and `station.tap(console.log)` shows live traffic.
Point the `prod` profile at a vault later and this code does not
change, which is sekreto's whole thesis and now station's too.

**Quickstart parity** is part of the accountability, not a ts-only
demo. The same two lines in the first-wave languages:

```go
st := station.Open()                                  // go
solar := solardemo.NewSolardemoSDK(st.Options())
```
```py
station = Station.open()                              # py
solar = station.connect(SolardemoSDK)
```
```java
var st = Station.open();                              // java
var solar = new SolardemoSDK(st.options());
```

Inverted binding (§3.1) keeps these on the constructors the SDKs
already generate — no new SDK API is required for the quickstart —
and the isolation guarantees are identical in all forms.

**Add the proxy when you want eyes:**

```
$ voxgig-station run          # local daemon on 127.0.0.1:8299
$ voxgig-station tap          # live view: every SDK, every process, every language
```

Restart the app (auto-attach), and the same two lines now stream to
the consolidated surface. `voxgig-station status` shows plugins,
modes, isolation rungs, secret resolution status, drop counters. The
CLI also carries `call` and `describe` — the human skins of the §7
tools.

**Profiles (`station.json`, committable — names and stores, never
values):**

```json
{ "station": 1,
  "profiles": {
    "dev": {
      "secrets": { "providers": [ { "kind": "env" },
                                  { "kind": "dotenv", "file": ".env.local" } ] },
      "plugin": { "solardemo": { "base": "http://localhost:8000" } } },
    "prod": {
      "secrets": { "providers": [
        { "kind": "hashicorp", "addr": "https://vault.example.com",
          "auth": { "method": "kubernetes", "role": "solar" } } ] },
      "plugin": { "solardemo": {
        "secret": "voxgig_solardemo.apikey",
        "resolve": "proxy",
        "policy": { "hosts": ["api.solar.example.com"] } } } } } }
```

The `secrets.providers` array is sekreto's own declarative
`ProviderSpec` form, passed through untouched — station neither
extends nor validates it, so every provider sekreto gains is available
here the day it lands, and sekreto's documentation is the reference.
Omit the block entirely and the chain is `[{kind:'env'}]`, which is
today's behavior.

**A profile's `secrets.providers` replaces the base array outright;
it never concatenates or merges by position** (§3.5). Chain order
decides which store wins, so a deep merge would be actively
dangerous: a `default` profile's `env` entry surviving in front of
`prod`'s Vault entry means a stale developer environment variable
quietly out-ranks the production secret, on some ports and not
others depending on how each merged. Replacement is the only rule
that reads the same in ten languages, and the `profile` corpus
section pins the resulting order. It is also why the `prod` examples
here and in §5.2 have no `env` entry at all: first-provider-wins
means an `env` entry in front of the vault would let a stale
variable on the host out-rank the production secret — the exact
failure this paragraph exists to prevent.

The `plugin` map is keyed by **descriptor slug** (= the model's
hyphenated `name`), discoverable via `station.plugins()` /
`voxgig-station status` / `station_integrations`; a key matching no
registered plugin produces a warning event at register time, because
a typo'd key silently configuring nothing is the worst outcome for a
secrets-and-policy file. Lookup path, profile selection, and merge
order are §3.5; a JSON Schema for `station.json` ships in the
packages so editors and agents validate as they type.
`VOXGIG_STATION_PROFILE=prod` or `Station.open({ profile: 'prod' })`
selects. This is where the ecosystem finally gets named environments
— the model has none, deliberately; environments are a deployment
concern and station is the deployment-facing component.

**New SDK project:** `npm install --save-dev @voxgig/sdkgen-station
&& voxgig-sdkgen package add @voxgig/sdkgen-station && npm run
generate` — the npm install comes first because `package add`
resolves from `.sdk/node_modules` and deliberately does not fetch
(only `package update` shells out to npm), and the add itself
installs the declared station feature, so no separate `add-feature`
step. The generated README now carries the "Use with Station"
section, and the generated `AGENTS.md` tells agents the station
story. The full recipe is `docs/how-to/use-station.md` (§9.4).

**Debug a failing integration:** `tap` → spot the 401 →
`voxgig-station traffic --plugin solardemo --grep 401` →
`station_secrets` shows the chain as sekreto reports it — `env` miss,
`hashicorp` miss — so the name resolved nowhere and the remediation
line names the env var and the vault path that *would* have answered
→ fix the profile → `replay` the captured request → green. No print
statements, no code changes, same loop in every language. The
distinction §5.2 preserves earns its keep here: "the vault said no"
and "the vault could not be reached" are different lines, and only the
first is a missing secret.

**CI:** `voxgig-station mock --record` against a live run once,
commit the transcript, `--replay` in CI — deterministic integration
tests that exercise the real SDK pipeline, complementing the
in-memory `test` feature and `netsim`.

## 12. Agent experience

Symmetric walkthroughs, because agents are users:

**Agent operating the app's integrations:** `claude mcp add station
-- voxgig-station mcp`. The agent calls `station_status` (is station
itself healthy), `station_integrations` (what exists, with a
per-plugin op summary — one call, not N), `station_call {plugin:
solardemo, entity: planet, op: list}` (reads allowed by default; a
wrong entity name gets the candidate list back in the error), and
`station_traffic` (what actually happened). It never connects to N
servers, never reads a credential, and cannot mutate — by call or by
replay — unless the policy says `agent.write: true`.

**Agent debugging the app:** `station_traffic {since}` and
`station_status` answer "what is this app doing over the network and
why is it failing" from *outside* the process, in any language, with
redaction guaranteed and error codes from one catalog (§14).

**Agent working on the app's code:** the generated `AGENTS.md` in
every SDK plus the station section (§9.4) tells it the seams;
`client.prepare()` output being placeholder-safe (§5) means an agent
can inspect request construction without a secret entering its
context window.

**Agent safety posture, stated plainly:** station's job is to make
the *capable* path the *safe* path — an agent with full station
access can list, describe, call, observe, and replay, but the design
gives it no operation whose output contains a secret value; writes
are a policy grant, not a default; and upstream response content
flowing through the tools is treated as untrusted input by the
server and should be by the agent's harness too (§7, §15).


## 13. Testing

The discipline that keeps N of anything honest is a shared corpus
with a zero-case guard — proven by the 22-section parity corpus and
`ts/test/parity.test.ts`. Station adopts it wholesale — and sekreto
independently arrived at the same answer (`spec/sekreto.json`, one
JSON file every port runs through voxgig/omni, with the byte-identical
error messages pinned), which is a good sign for both.

The boundary matters as much as the corpus: **station's spec does not
re-test secret resolution.** Name validity, `envkey`/`vaultref`/
`flatname`/`awsparam` mappings, `.env` parsing, chain order, miss vs
error, SigV4, redaction of resolved values — all of that is
sekreto's spec, already green in ten languages, and restating any of
it here would be the two-sources-of-truth defect sdkgen has spent
several fixes removing. Station's corpus tests only the station half:
that the right *name* was asked for, and that what came back was
placed correctly.

- **`spec/` conformance corpus** (JSON, language-neutral), sections:
  `secretname` (slug → sekreto name, hyphens to underscores, and the
  `envkey` round-trip that must equal sdkgen's `envName()` — the one
  place station's and sekreto's grammars meet), `descriptor`
  (config-in → descriptor-out, including
  the legacy-config sentinel case), `canonical-serialize`
  (adversarial: non-ASCII names, large ints), `inject`
  (placeholder/copy-on-inject: `ctrl.explain` still holds the
  placeholder after an op), `order` (station sees N retry attempts;
  cache hits produce no http event; `station_wrap_order` guard),
  `redact` (headers and body fields, including a credential echoed
  in a response body, and the R1-attached `Station-Redact` case where
  the redacting instance is not the resolving one — §15),
  `envelope` (forward serialization, `Station-Redact` included),
  `event` (StationEvent shapes), `errors` (the §14 catalog: exact
  code strings and trigger conditions), `profile` (the §3.5 merge
  order, including wholesale `secrets.providers` replacement),
  `degrade` (solo/attached transitions, non-blocking open).
  Section applicability is **tier-scoped**: wire-dependent sections
  (`envelope`, the attached half of `degrade`) apply to tiers A/B
  only. A library declares its tier; an *applicable* section that is
  empty or missing fails loudly, and out-of-tier sections sit in an
  explicit pinned pending list — the go corpus runner's
  `pendingSections` precedent, adopted so tier-C libraries neither
  fake a wire client nor run permanently red. (The zero-case guard,
  copied deliberately, declared-pending escape hatch included.)
  Concurrency is the one contract the JSON corpus cannot express —
  per-language stress tests against the testkit cover it (§10.2).
- **Proxy contract tests** in Go, plus `voxgig-station testkit` —
  the proxy binary in deterministic mode (fixed clock,
  transcript-driven upstreams) used by every library's CI to test
  attachment, forward, grants, and degradation without a real
  network.
- **Generator-side:** pre-graduation, from the package side — the
  sdkgen-station CI fixture-consumer flow of §9.5, plus `package
  check`. Post-graduation the bundled suites add coverage but do
  **not** replace that flow: `generate.test.ts` renders components
  into memfs and asserts on generated *text* — it never invokes a
  target compiler — so the fixture-consumer lane that actually
  compiles the generated SDK + adapter per language stays in CI
  permanently; `feature.test.ts` exercises the ts template against
  the miniature pipeline.
- **End-to-end:** the solardemo validation flow (the repo's
  existing `validate-solardemo` loop) extended with station:
  generate with the feature, run apps in the shipped-library
  languages against a local testkit proxy, assert captures,
  injection, and `station_call` round-trips.

## 14. Failure modes and error codes

Specified, because "optional component" is only true if absence is
well-behaved:

- **Proxy absent at startup (`auto`)** → solo mode, one
  `station`-kind warning event naming the cause (not found, auth
  failed, proof-of-token failed — an imposter reads as absence).
  `require` → never solo, but the failure rides the operation path,
  not the constructor: `open()` stays non-blocking (§2.1), and every
  operation awaits attachment with the bounded timeout, then fails
  `station_no_proxy`.
- **Proxy dies mid-flight** → the next envelope fails; a plugin whose
  chain the library can run itself degrades to solo seamlessly (events
  buffer, capture gap noted); a `resolve: proxy` plugin fails closed
  with `station_no_proxy` — the process never held the secret and must
  not now go looking, and a silent fall back to an `env` provider
  would quietly downgrade the isolation the deployment chose.
  Reattachment is automatic with backoff and is always a full
  re-register (§3.4).
- **Events never fail an operation, and never delay one beyond
  §6's per-model budget** (zero, or the inline bounded-blocking
  budget on synchronous single-threaded targets). Fire-and-forget
  within each execution model's delivery semantics (§6), bounded
  buffers, drop-oldest,
  drop counts in `status`. An observability outage must not become
  an application outage.
- **Latency budget:** solo middleware overhead target < 0.1ms/op
  (including the synchronous-runtime inline flush amortized);
  attached envelope over loopback p50 < 1ms, p99 < 5ms —
  benchmarked in testkit CI, because a control surface that taxes
  the data path gets turned off.

**Error codes** follow the SDKs' house grammar
(`<subject>_<condition>`, absence as `no_<thing>`, gates as
`_allow` — the `point_op_allow` / `request_no_spec` /
`fetch_mode_block` family), surface through the SDK's own error path
(`err.code`), live in one catalog page (§9.4), and are pinned by the
`errors` corpus section. The v1 set:

| code | when |
|---|---|
| `station_no_proxy` | attachment `require`d but not achieved within an operation's bounded wait (§2.1), or proxy lost for a `resolve: proxy` plugin |
| `station_secret_no_value` | the chain ran and no store had the name (sekreto's `unknown secret`) |
| `station_secret_error` | a store could not answer — locked vault, refused login, unreachable host; carries sekreto's message verbatim and is never retried against a weaker store (§5.2) |
| `station_secret_name` | a configured secret name sekreto rejects as malformed, caught at profile load rather than first request |
| `station_host_allow` | egress denied by the hosts policy |
| `station_grant_expired` | grant TTL passed and re-registration failed |
| `station_wrap_order` | the §3.3 position guard tripped |
| `station_protocol` | wire/descriptor version rejected by the proxy |
| `station_no_plugin` / `station_no_entity` / `station_no_op` | unknown lookup in `station_call`/`station_describe`; the payload lists the valid candidates (§7) |
| `station_agent_allow` | `agent.write`/`agent.read` policy denial, on call or replay |
| `station_body_limit` | `/v1/forward` request body over the configured limit |
| `station_replay_lossy` | replay refused: the capture's request cannot be reconstructed byte-for-byte (truncated or redaction-damaged body, §8.5) |

## 15. Security posture

- **Redaction:** capture defaults to `meta`; `headers`/`full` apply
  the header redaction list seeded from the `debug` feature's, plus
  body-field redaction in the spirit of `clean.keys` — noting
  honestly that the `clean()` body-redaction in the reference SDK is
  currently disabled and must be revived and corpus-pinned before
  `capture: full` ships. Redaction is applied at capture time, never
  retroactively. Defense in depth comes from sekreto rather than a
  station reimplementation: `redact(text)` hides every value *that*
  sekreto instance resolved, wherever it appears in a body, with a
  four-character floor so short values do not shred the logs. Station
  runs it over `headers|full` captures and over live `station_call`
  results (§7).
- **The R1-attached capture, spelled out**, because a sekreto instance
  can only redact what *it* resolved and that leaves a real hole
  otherwise. Under R1 the **library** resolved the credential, so the
  **proxy's** sekreto has never seen it — yet the proxy is the one
  capturing the `/v1/forward` exchange, and an upstream that echoes
  the credential in a 401 body would land it, unredactable, in the
  capture store and in `station_traffic`. What closes it is that in
  this mode the credential is already crossing to the proxy by
  necessity: the library injected it into the envelope headers so the
  proxy can forward it upstream. So the envelope names its own
  secret-bearing headers in `Station-Redact`, and the proxy holds
  those values **transiently, for the duration of that one exchange**
  — redacting them from the captured request and response, then
  discarding them unwritten and unlogged. No new exposure (the proxy
  handled the value anyway), and no unredactable capture. If the
  marker is absent — an older library against a newer proxy — the
  proxy degrades that plugin's capture to `headers` rather than
  storing a body it cannot scrub, and says so in `status`. The
  `redact` corpus section carries the case: R1 attached, credential
  echoed in the response body, capture must not contain it.
- **"By construction", scoped truthfully:** §5's placement makes the
  *injected credential* absent from request headers in captures,
  events, `options()`, `prepare()`, MCP tools, and CLI output
  without scrubbing. Bodies are not covered by construction — apps
  put credentials in bodies (token exchanges, GraphQL mutations)
  and upstreams echo them in diagnostics — so body redaction remains
  load-bearing at `capture: headers|full`.
- **Local daemon:** loopback/unix-socket only by default;
  token-on-every-request; proxy authenticated by proof-of-token
  before anything sensitive is sent; `Host`/`Origin` validation
  against DNS rebinding; 0700 directory (§8.1).
- **No MITM, ever:** the envelope design (§8.2) exists so the proxy
  never needs a CA in anyone's trust store.
- **Untrusted registration:** every field of a client-registered
  descriptor is untrusted input; it may only narrow proxy-side
  policy and never selects which secret is injected (§8.3).
- **Threat model, abbreviated:** malicious/compromised agent on the
  MCP surface → no secret-bearing tool output + `agent.write`/
  `agent.read` gates + prompt injection via upstream response
  content named and mitigated (tool results labeled external, never
  instruction-bearing); hostile in-process code → *not* an R1 claim
  (§5.3); R2 bounds what a compromised process holds to a
  session-bound revocable grant, with the token file as the honest
  local boundary; imposter local proxy → proof-of-token before
  disclosure; DNS rebinding → Host/Origin checks; leaked capture
  store → redaction-at-capture; compromised proxy → it holds
  secrets, so it is the hardening focus: minimal dependencies,
  memory-only default, no execution of plugin-supplied code; supply
  chain → the sdkgen posture holds (adapter source lands in the
  consumer's diff at add time and executes only when the consumer
  builds).

## 16. Policy

Per-plugin, declared in profiles, enforced twice where possible (in
the library and again in the proxy — the proxy cannot be bypassed in
R2, the library catches early in solo). For proxy-held secrets the
authoritative copy is proxy-side (§8.3).

- `allow.op` / `allow.method` — the same vocabulary the SDKs already
  enforce (`options.allow`, and the raw-access gate every target
  implements); station sets these SDK options from policy so
  enforcement is in the SDK's own pipeline, with station's checks as
  backstop.
- `hosts:` egress allowlist — defaulted from the *proxy-side* view
  of the descriptor's base + server-variable expansion, per §8.3;
  anything else is a policy edit, not a surprise.
- `budget:` rps/concurrency ceilings (the SDK `ratelimit` feature,
  configured by station, plus proxy-side enforcement in R2).
- `agent.write:` gates mutating `station_call` **and** replay of
  mutating captures (§6, §7); default false. `agent.read:` default
  true locally, false on remote proxies.
- `mode: live | record | replay | mock | block` — per plugin, per
  profile; `block` is the kill switch.

## 17. Delivery phasing

Obeying §9.6's rule — an adapter never precedes its library:

- **Phase 1 — prove the loop (narrow and deep):** ts library
  (browser-safe entry points included, §2.2) over `@voxgig/sekreto` +
  proxy core (register with proof-of-token, envelope forward, R1 and
  R2 with the Go sekreto proxy-side, proxy-side policy authority,
  capture, tap, status) + MCP
  (`station_status`/`integrations`/`describe`/`call`/`traffic`) +
  `@voxgig/sdkgen-station` with adapters for **ts/js only** + the
  three `configDefinition` fields and the featureorder change +
  package-side CI fixture flow + solardemo end-to-end (ts/js). Exit:
  the §11 two-line quickstart and the §12 agent transcript both
  real.
- **Phase 2 — breadth and depth:** go library then go adapter
  (unblocking go-heavy consumers and dogfooding next to the proxy);
  py, then the rest of tier A in demand order (java, csharp, kotlin,
  swift, dart, rb, php — scala and clojure wait for Phase 3 behind
  their §9.1 adapter prerequisites, JVM transport notwithstanding),
  each over its own sekreto port where one exists and env-only where
  it does not (swift, dart, elixir — §2.2); replay/mock/record with
  the §6
  per-class semantics; OTLP export; grants hardening + revocation
  UX; `station.json` schema; ReadmeStation + AgentGuide +
  `docs/how-to/use-station.md`; conformance corpus enforced in CI
  for every shipped library.
- **Phase 3 — long tail and remote:** tier B (rust, lua, haskell,
  ocaml — the latter two gated on §9.1's single-module work), the
  scala and clojure adapters after the zig/scala static-reference
  and single-module prerequisites, tier C scope decisions
  (c/cpp/zig/lean solo-only or vendored-core); remote proxy mode
  against the §8.4 tenancy answer; policy long-poll; `station_call`
  write-scopes in anger.

Each language library is a bounded, independent deliverable (modem
principle + tier budgets + corpus), so the long tail parallelizes
and never blocks the core.

## 18. Open questions

- **Remote multi-tenancy.** Visibility partitioning (who sees whose
  captures), per-principal authz on call/replay/secrets, grant
  scoping per app identity — must be answered before any shared
  deployment; until then remote v1 is single-team by policy (§8.4).
- **Streaming uploads through the envelope** (downloads pass through
  chunked; uploads are buffered with a size cap in v1). Matters for
  the `streaming` feature's upload half.
- **`$action`/multi-point ops via `station_call`** — the descriptor
  keeps the points array (§4); v1 calls the canonical point only.
  Expose action routes generically or require per-op annotation?
- **Multi-credential plugins.** Blocked on the model growing
  multi-scheme auth; the `Binding` reserves a keyed name map, and
  sekreto's `all(names)` already fetches a set at once when it lands.
- **sekreto ports for the gap languages** (swift, dart, elixir, lua,
  haskell, ocaml, and tier C). Contributed to sekreto, not worked
  around in station — but who writes them, and in what order,
  is a sekreto roadmap question this design should not pre-empt.
  Until then the tier A/B ones are env-only in solo mode and fully
  covered attached; tier C, having no wire client either, is env-only
  outright and is the case worth prioritizing (§2.2).
- **An OS-keychain provider**, wanted by the original draft and absent
  from sekreto today. It belongs in sekreto if it is wanted.
- **Whether the publish-time `aql` vault and sekreto's `boru`
  provider are one vault or two** (§1) — if one, a project could
  declare a credential once for CI and runtime alike.
- **Non-sdkgen outbound traffic.** A `station.fetch` for arbitrary
  HTTP would extend the control surface beyond SDKs; deliberately
  out of v1 to keep the descriptor story crisp.
- **A public `client.extend()` late-attach seam** in generated SDKs
  (§9), which would upgrade `adopt()` beyond construction-time
  sugar. Cross-language parity cost vs. value.
- **Graduation timing** of `@voxgig/sdkgen-station` into the bundled
  scaffold catalog — which also unblocks the four single-module
  targets (§9.1).
- **Proxy capture store encryption at rest** once SQLite persistence
  is on.

## 19. Non-goals

- Inbound traffic. Station is outbound-only, permanently.
- Replacing API gateways, service meshes, or egress firewalls.
- A general-purpose secret manager. Station brokers and isolates; it
  does not aspire to be Vault. (`Full secret manager` was explicitly
  considered and declined.)
- **Any secret-store client code in station at all.** sekreto owns
  resolution, its store mappings, and its conformance spec (§5, §13).
  A new store is a sekreto provider; a new mapping is a sekreto
  function; a resolution bug is a sekreto test. Station's secrets
  code is the placement, and nothing else.
- Generating the station libraries with sdkgen (D5 decided
  hand-written; the *adapter* is generated, the *library* is not).
- An OTel SDK dependency in every language library (proxy-only,
  §10).
- Replacing go-mcp / go-cli as standalone single-SDK tools (§9).
- Claiming R1 as an in-process security boundary (§5.3 — it is
  hygiene; R2 is the boundary, and only against value exposure, not
  a live local attacker holding the token file).
