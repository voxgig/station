# Design: declarative station config and dynamic SDK instances

Status: **proposal** (2026-08-22). An extension of
[`station.md`](./station.md), not a replacement. Where the two
disagree, this document wins and names the section of `station.md` it
amends (§15 collects every amendment in one list).

Unqualified `typescript/...`, `go/...`, `spec/...` paths are relative
to this repo. Unqualified `ts/src/...` and `ts/project/.sdk/...` paths
are relative to the [sdkgen repo](https://github.com/voxgig/sdkgen),
as in `station.md`.


## 0. The use case this exists to serve

Two steps, and the whole design is accountable to them:

1. **Init station from a fully declarative config.**
2. **Get an SDK instance from station, dynamically, where it is
   needed.**

With four properties that turn those two lines into a real-world
component rather than a demo:

- **Scale.** A real project drives **at least 20 SDKs**. Twenty is the
  design point, not the stress case.
- **SDKs are not singletons.** One API can have **many instances**, each
  with its own configuration — `stripe-live` and `stripe-test`,
  `github-cloud` and `github-enterprise`, one tenant's endpoint and
  another's.
- **The config is plain JSON**, and it is validated with
  [voxgig/struct](https://github.com/voxgig/struct).
- **Secrets come from [sekreto](https://github.com/voxgig/sekreto) and
  nowhere else** — never inline in the config, never by a second
  mechanism — and that has to be coordinated with the generated SDKs,
  which have their own credential convention.

All of it works in every target language. `ts` is the tracer bullet.

The one-sentence answer:

> **`station.json` declares named SDK *instances*; `station.sdk(name)`
> returns one, constructed lazily and cached; the registry is keyed by
> instance rather than by API; the config is normalized to its
> documented defaults and then validated against a struct shape that
> is closed by construction — so the grammar cannot express a
> credential, and a typo cannot survive `open()`.**


## 1. Why today's design does not do this yet

`station.md` is written for a different starting posture: an
application that already constructs its SDKs, adding station to what it
has. Everything in it is correct for that posture and load-bearing for
this one — the descriptor, the transport seam, copy-on-inject, the
sekreto division of labour. What it does not have is the declarative
front door. With receipts from the shipped code:

- **Nothing is declared; everything is discovered.** `station.json`
  today carries *overlay* config — `profiles.<p>.plugin.<slug>` —
  which modifies plugins that register themselves when app code
  constructs them. Delete every line of app code and station has zero
  integrations. The config describes adjustments to a set it does not
  own.
- **Binding needs the class in hand.** `station.connect(SDK)`
  (`typescript/src/Station.ts`) takes a constructor. At 20 SDKs that is
  20 imports resolved at startup whether or not the process touches
  them, and every call site must know which class it wants.
- **One plugin per API, enforced.** The registry is
  `Map<slug, PluginEntry>` and `_register` throws
  `station_bound_twice` on the second registration of a slug. Two
  instances of one API is not an unimplemented case; it is a
  prohibited one.
- **Identity is the API everywhere downstream.** `placeholderFor(slug)`
  yields one placeholder per API, so two live instances of the same API
  would be indistinguishable at the injection seam.
  `SecretBroker.value()` caches by slug. `StationEvent.plugin` carries
  the slug. `profile.plugin[slug]` is the config lookup. Instance
  identity has nowhere to live.
- **The config is unvalidated.** `loadConfig` is `JSON.parse` and
  nothing more. `resolveProfile` checks configured secret *names* with
  sekreto's `validname()` and nothing else. A typo'd key is caught, if
  at all, by a warning emitted at `close()` — after the process has run
  with a silently unconfigured integration. `station.md` §11 promises
  "a JSON Schema for `station.json` ships in the packages"; struct is
  the better answer and is already a dependency of this ecosystem in
  22 languages.

None of that is wrong. It is the imperative half of a component that
needs both halves.


## 2. Vocabulary

Three words, used precisely from here on. The middle one is new.

| term | is | identified by | example |
|---|---|---|---|
| **api** | a generated SDK — one OpenAPI definition, one package | the descriptor **slug** (the model's hyphenated `name`) | `voxgig-solardemo` |
| **instance** | one configured use of an api: its own base URL, secret, policy, options | the **instance name** — the key in `sdk` | `solar-eu` |
| **plugin** | an instance *bound to a station* — a live client in the registry | the instance name | — |

The change in one line: **a plugin used to be an api; a plugin is now
an instance.** Everything keyed by slug in the registry, the
placeholder, the event stream and the config becomes keyed by instance
name. The descriptor stays keyed by api, because it describes the API
and not the use of it — and one descriptor is shared by every instance
of its api (§7.4).

The degenerate case is the important one: **an instance whose name
equals its api slug, and which is the only instance of that api, has
exactly today's behaviour** — the same resolved secret name, the same
env var, the same base URL, the same binding calls, and the §11
two-line quickstart unchanged. Multi-instance is what you get when you
ask for it.

Two changes cross that line and are called out rather than buried,
because "unchanged" has to mean it:

- **the config key is renamed.** `profiles.<p>.plugin` becomes `sdk`
  and the old key is rejected by name (§3.4). Every block *means* what
  it meant; the key it sits under changes, and that is a one-line
  migration per file.
- **events gain an `api` field** (§7.3). Additive, so a consumer
  reading `plugin` is unaffected, but a byte-exact snapshot of the
  event stream is not.

Nothing else. No behavioural difference reaches a single-instance
project.


## 3. The config

### 3.1 Shape

`station.json`, complete grammar. Everything is plain JSON — no
functions, no references, no expressions, no environment interpolation
(§5.4 says why that last one is deliberate).

```json
{
  "station": 1,
  "profiles": {
    "<profile>": {
      "secrets": { "providers": [ /* sekreto ProviderSpec, verbatim */ ] },
      "api":     { "<api-slug>":      { /* block */ } },
      "sdk":     { "<instance-name>": { "api": "<api-slug>", /* block */ } }
    }
  }
}
```

A **block** — the same eight keys in both positions:

| key | type | meaning |
|---|---|---|
| `package` | string | the module/package providing this api's SDK (§6.3) |
| `export` | string | the constructor's exported name; only needed for SDKs generated without the station feature (§6.3) |
| `base` | string | base URL override |
| `secret` | string | sekreto secret **name** — never a value (§5) |
| `resolve` | `"library"` \| `"proxy"` | R1 in-process, or R2 proxy-side (`station.md` §5.3) |
| `policy` | `{ "hosts": [string] }` | egress allowlist |
| `options` | map | extra options passed to the SDK constructor (§5.3 restricts it) |
| `active` | boolean | default `true`; `false` declares an instance without allowing it to be built |

An `sdk` block adds one key, `api`, naming which api it instantiates;
it defaults to the instance name, so the single-instance case never
writes it. An `api` block is the same block *minus* `api` — settings
inherited by every instance of that api. The two spec objects in the
shape file are identical apart from that one key, and a guard test
asserts it (§9.1), because they are one concept written twice as data.

### 3.2 Twenty SDKs, twenty-six instances

```json
{
  "station": 1,
  "profiles": {
    "default": {
      "secrets": { "providers": [ { "kind": "env" } ] },

      "api": {
        "voxgig-solardemo": { "package": "@voxgig-sdk/voxgig-solardemo-sdk" },
        "stripe":  { "package": "@acme-sdk/stripe-sdk",
                     "policy": { "hosts": ["api.stripe.com"] } },
        "github":  { "package": "@acme-sdk/github-sdk" },
        "slack":   { "package": "@acme-sdk/slack-sdk" }
      },

      "sdk": {
        "solardemo":    { "api": "voxgig-solardemo" },
        "stripe":       { "api": "stripe" },
        "stripe-test":  { "api": "stripe", "base": "https://api.stripe.test",
                          "secret": "stripe_test.apikey",
                          "policy": { "hosts": ["api.stripe.test"] } },
        "github":       { "api": "github" },
        "github-ent":   { "api": "github", "base": "https://ghe.acme.internal",
                          "secret": "github_ent.apikey" },
        "slack-ops":    { "api": "slack", "secret": "slack_ops.apikey" },
        "slack-alerts": { "api": "slack", "secret": "slack_alerts.apikey" }
      }
    },

    "prod": {
      "secrets": { "providers": [
        { "kind": "hashicorp", "addr": "https://vault.example.com",
          "auth": { "method": "kubernetes", "role": "acme" } } ] },
      "sdk": {
        "stripe-test": { "active": false },
        "stripe":      { "resolve": "proxy" }
      }
    }
  }
}
```

Four things to read out of that, because they are the requirements:

- **`stripe`, `stripe-test`, `github`, `github-ent`, `slack-ops`,
  `slack-alerts`** — six instances over three apis, each with its own
  base, secret and policy, all in JSON.
- **`api.stripe.policy.hosts`** is written once and applies to every
  stripe instance that does not say otherwise. At 20 apis this is what
  stops the file being repetitive — and `stripe-test`, which moves its
  `base` off the api's host, has to carry its own `policy` or the
  fail-closed host check in `station.md` §16 denies every request it
  makes. **An instance that overrides `base` away from the api's
  allowlist must override `policy` too.** That is the shallow-merge
  rule of §3.3 doing exactly what an allowlist wants — an inherited
  allowlist is never silently widened by a base URL — and it is the
  first thing `station.check()` should report on (§6.6).
- **The `prod` overlay is short**, because a profile overlays instances
  rather than redeclaring them. `stripe-test` is switched off in prod
  by one key; `station.sdk('stripe-test')` then fails loudly rather
  than quietly talking to a test endpoint from production.
- **There is no credential anywhere**, and §5.2 shows that is a
  property of the grammar rather than of the example.

### 3.3 Resolution order

`station.md` §3.5's total order, extended for the two block levels.
Lowest to highest precedence:

1. generated SDK `Config` defaults (including the feature's model defaults)
2. station feature options passed at SDK construction (in-code defaults)
3. base profile (`profiles.default`) — **`api`** block
4. base profile — **`sdk`** block
5. selected profile overlay — **`api`** block
6. selected profile overlay — **`sdk`** block
7. `VOXGIG_STATION_*` env vars
8. `Station.open(opts)`
9. per-call overrides — `connect`/`adopt` opts, `create(name, overrides)`

Steps 3–6 are one ordered merge, which is the whole point of writing
them in that order: **profile specificity outranks block specificity.**
A `prod` api-level `base` beats a `default` instance-level `base`,
because that is what an environment overlay is for; within one profile,
the instance beats the api default, because that is what an instance is
for. It degenerates to today's `base.plugin ⊕ overlay.plugin` when no
`api` blocks exist.

**Two mechanism rules make that order safe, and a port that skips
either reintroduces a real defect.**

*The api is resolved before its defaults are looked up.* An api block is
keyed by api slug, and which api an instance uses is itself a merged
value, so the merge is not a flat four-way pass over both maps:

1. merge the **instance** blocks — base ⊕ overlay (steps 4, 6);
2. read `api` from the result, defaulting to the instance name;
3. merge the **api** blocks for *that* api — base ⊕ overlay (steps 3, 5);
4. compose: api defaults under the instance block.

*Absent keys stay absent through the merge, and block defaults are
applied once, to the fully merged instance.* This is the rule §4.2's
normalization must not be confused with, and it is worth showing why
rather than asserting it. Take a base that declares an instance
properly and an overlay that only moves its base URL:

```json
"default": { "sdk": { "pad-a": { "api": "taskpad", "active": false } } },
"prod":    { "sdk": { "pad-a": { "base": "https://prod.example" } } }
```

If the overlay block had defaults filled in before merging, it would
carry a synthesized `api: "pad-a"` and `active: true` — and those would
overwrite the base's real values. The merged instance would name a
**different api** and would be **live in production despite being
declared inactive**. A one-key environment override, silently
selecting the wrong SDK and re-enabling a disabled integration. So:
merge the blocks as authored, then apply `api` → instance name and
`active` → `true` to the result. The `instance` corpus section carries
exactly this case.

Two rules survive unchanged from `station.md` and one is corrected:

- **`secrets.providers` replaces wholesale**, never merges (§3.5, §5.2).
  It is profile-level, so this is untouched by the block levels.
- Merging within a block is **shallow, per key**. `station.md` §3.5 says
  "deep-merge per plugin"; the TypeScript and Go ports both implement a
  shallow per-key merge and their comments say so
  (`typescript/src/profile.ts`, `go/station/profile.go:93`). The
  implementations agree with each other and the prose is the outlier.
  **Settled as shallow** — it is the rule that reads the same in 22
  languages — and `station.md` §3.5 is corrected (§15). The visible
  consequence: an overlay's `policy` replaces the base's `policy`
  entirely rather than merging `hosts` into it. That is also the safer
  reading for an allowlist.
- Profile selection is unchanged, and follows the same precedence as
  everything else: `Station.open({profile})`, else
  `VOXGIG_STATION_PROFILE`, else `default` — the explicit option
  outranks the environment, as steps 7 and 8 above require and as every
  shipped `selectProfile` already implements
  (`typescript/src/profile.ts`). `station.md` §3.5 states only the env
  var and the default; it is completed here rather than changed (§15).

### 3.4 Migration from `plugin`

`profiles.<p>.plugin` becomes `profiles.<p>.sdk`. That is the whole
migration: the keys used to be api slugs and are now instance names,
and an instance name defaults to its api slug, so **every existing
block means exactly what it meant before under the new key.**

Station is pre-1.0 and unreleased. `plugin` is **removed**, not
aliased, and validation rejects it by name with a message that says
what to rename — a deprecated alias would be a second grammar for one
concept in 17 ports, which is the defect class this repo's parent
project has spent five fixes on. The `profile` section of
`spec/station.json` is rewritten in the same change.


## 4. Validating with voxgig/struct

### 4.1 Why struct, and what it buys

struct ships `validate(data, spec, {errs})` in
[22 language ports at full canonical parity](https://github.com/voxgig/struct),
pinned by a shared corpus — the same discipline sekreto and station
themselves run on. So the shape can be **data**: one JSON file, read by
every port, producing the same verdict and the same message paths
everywhere. That is a strictly stronger position than a JSON Schema
(which would need a validator dependency per language, and would be
the only such dependency in a design whose §10 forbids them).

Three struct properties do the real work, all verified against
`@voxgig/struct@0.2.2` while writing this:

- **Maps are closed by default.** An unexpected key is an error naming
  the key and its path. This is what turns typo-catching from a
  `close()`-time warning into an `open()`-time failure.
- **`errs` collects instead of throwing.** Every problem in the file is
  reported in one message, not the first one.
- **`` `$OPEN` ``** re-opens a map where a foreign grammar has to pass
  through untouched.

### 4.2 Normalize, then validate

The non-obvious part, and the reason this section exists rather than
just naming a shape file.

struct drops the unexpected-key check for a map whose spec node ends up
empty — "an empty spec object means the object can be open". An
optional key is expressed as `` ['`$ONE`','`$NIL`', spec] ``, and when
the data does not carry that key the validator removes it from the spec
node. So **a block whose keys are all optional degenerates into an open
map exactly when the data has none of them** — and `{"solar": {"bass":
1}}` validates clean. The one property the whole exercise is for,
silently absent in the one case that matters.

Wrapping containers in `` `$ONE` `` has a second cost: the failure
message collapses to `to be one of nil, {…whole spec dumped…}` instead
of naming the offending path, and sibling errors stop accumulating.

So the pipeline is two steps, and the first one is what makes the
second honest:

> **`normalizeConfig(raw)` materializes every documented default;
> `validateConfig(normalized)` then runs a shape with no optional
> containers at all.**

`normalizeConfig` fills in, defensively — a node that is not the kind
it expects is left alone for `validate` to reject with a proper
message:

- `station: 1` when absent;
- `profiles: {}` when absent;
- per profile: `secrets.providers` → `[{"kind":"env"}]` (the documented
  default chain), `api` → `{}`, `sdk` → `{}`;
- per block: `active` → `true`;
- per `sdk` block: `api` → the instance name.

After normalization every container is present, so the shape can
require them, so unexpected-key detection is live at every level and
every error names its path.

**The normalized form is an input to validation and to nothing else.**
The two block-level defaults — `active` and `api` — must *not* be
materialized before the profile merge, because a default synthesized
into an overlay block overwrites the base's real value and produces the
wrong-api / silently-reactivated failure worked through in §3.3. So the
two consumers read the same defaults table at different moments:

| consumer | when defaults are applied | why |
|---|---|---|
| `validateConfig` | before, to every block | a block with no present keys is an open map (above) |
| the resolver | after, to the merged instance | an absent key must stay absent through the merge (§3.3) |

Written as one defaults table and two callers, not as two lists that
drift. The profile-level containers (`secrets.providers`, `api`, `sdk`)
are safe to materialize early either way — they are containers, and a
missing one merges as empty regardless — so only the two block keys
carry the timing rule.

The normalizer is roughly 30 lines and pure data-in/data-out, which is
what makes it portable to 22 languages and expressible in the corpus.

### 4.3 The shape

`spec/config-shape.json`, in full. This is the artifact; it is verified
against the cases in §4.5.

```json
{
  "station": ["`$EXACT`", 1],
  "profiles": {
    "`$CHILD`": {
      "secrets": { "providers": "`$LIST`" },
      "api": {
        "`$CHILD`": {
          "active":  "`$BOOLEAN`",
          "package": ["`$ONE`", "`$NIL`", "`$STRING`"],
          "export":  ["`$ONE`", "`$NIL`", "`$STRING`"],
          "base":    ["`$ONE`", "`$NIL`", "`$STRING`"],
          "secret":  ["`$ONE`", "`$NIL`", "`$STRING`"],
          "resolve": ["`$ONE`", "`$NIL`", ["`$EXACT`", "library"], ["`$EXACT`", "proxy"]],
          "policy":  ["`$ONE`", "`$NIL`", { "hosts": ["`$CHILD`", "`$STRING`"] }],
          "options": ["`$ONE`", "`$NIL`", "`$MAP`"]
        }
      },
      "sdk": {
        "`$CHILD`": {
          "api":     "`$STRING`",
          "active":  "`$BOOLEAN`",
          "package": ["`$ONE`", "`$NIL`", "`$STRING`"],
          "export":  ["`$ONE`", "`$NIL`", "`$STRING`"],
          "base":    ["`$ONE`", "`$NIL`", "`$STRING`"],
          "secret":  ["`$ONE`", "`$NIL`", "`$STRING`"],
          "resolve": ["`$ONE`", "`$NIL`", ["`$EXACT`", "library"], ["`$EXACT`", "proxy"]],
          "policy":  ["`$ONE`", "`$NIL`", { "hosts": ["`$CHILD`", "`$STRING`"] }],
          "options": ["`$ONE`", "`$NIL`", "`$MAP`"]
        }
      }
    }
  }
}
```

`api` and `active` are required rather than optional — normalization
guarantees both are present, and requiring at least one key per block
is precisely what keeps the block closed.

**`secrets.providers` is `` `$LIST` `` and nothing more**, by design
rather than by omission. `station.md` §5.2 and §19 say station neither
extends nor validates sekreto's `ProviderSpec` grammar, so every
provider sekreto gains is available the day it lands and sekreto's own
error message is the one the developer sees. Station checks that the
chain is a list; sekreto checks what is in it.

### 4.4 Two honest limits

- **`policy` stays optional, so its errors are the generic
  `` `$ONE` `` form.** It cannot be normalized away: a default
  `{"hosts": []}` would mean *deny everything*, which is not what
  "absent" means. A typo inside it is still caught (`hosts` is required
  when `policy` is present), just reported as
  `policy to be one of nil, {hosts:[child,string]}` rather than by path.
  Accepted.
- **`` `$CHILD` `` in list mode does not validate element 0.** Verified:
  `["a", 1]` fails at index 1, `[1]` passes.
  `validate_CHILD` installs the template across the data's indices, sets
  `keyI = 0` and returns element 0 as the slot value, and the injection
  loop resumes past it. This is an upstream struct defect; **filing it
  against voxgig/struct is a deliverable of this plan** (§9.5). Its only
  reach here is `policy.hosts[0]`, and the failure is closed rather than
  open — a non-string host matches no request, so traffic is denied, not
  admitted.

### 4.5 What the shape catches

Verified against `@voxgig/struct@0.2.2`; these become the `config`
section of the conformance corpus (§9.1).

| case | verdict |
|---|---|
| `{"station":1}` | passes — an empty config is legal |
| `{"station":1,"profiles":{"default":{"sdk":{"solar":{}}}}}` | passes — `api` defaults to the key |
| the §3.2 twenty-SDK config | passes |
| `sdk.solar.bass` | `Unexpected keys at field profiles.default.sdk.solar: bass` |
| `sdk.solar.apikey` | `Unexpected keys at field profiles.default.sdk.solar: apikey` |
| `sdk.s.token` | `Unexpected keys at field profiles.default.sdk.s: token` |
| top-level `profile` (for `profiles`) | `Unexpected keys at field <root>: profile` |
| `profiles.default.sdks` | `Unexpected keys at field profiles.default: sdks` |
| `secrets.provider` | `Unexpected keys at field profiles.default.secrets: provider` |
| `api.x.packag` | `Unexpected keys at field profiles.default.api.x: packag` |
| `api.x.api` | `Unexpected keys at field profiles.default.api.x: api` |
| `"station": 2` | `Expected field station to be exactly equal to 1` |
| `resolve: "vault"` | `to be one of nil, [exact,library], [exact,proxy]` |
| `base: 8080` | `to be one of nil, string, but found integer: 8080` |
| `policy: {host:[…]}` | fails (generic `$ONE` form, §4.4) |
| `profiles: []` | `Expected field profiles to be object, but found list` |
| three separate errors in three instances | **all three reported in one message** |

### 4.6 Cost

Normalize + validate is linear in instance count at ≈0.7 ms per
instance on Node 22 (1 → 1.5 ms, 20 → 15 ms, 100 → 66 ms, 200 →
132 ms). It is the dominant cost of `Station.open()` and it is paid
once per process.

**Budget: ≤25 ms at the 20-instance design point, measured in CI.**
There is no `validate: false` escape hatch, and there will not be one:
this is the file that decides which credential reaches which host, and
an option to skip checking it would be taken in exactly the deployment
where it matters. If the budget is ever busted the fix is in struct.


## 5. Secrets

`station.md` §5 is unchanged in principle — *application code names a
secret; sekreto resolves it; station places the value where the
application cannot reach it and the wire still gets it.* Three things
change because instances now exist, and one guarantee gets stronger.

### 5.1 Names are per instance

`secretnameDefault` takes the **instance name**, not the slug:

> `envtoken(instanceName).toLowerCase() + '.apikey'`

using the same `envtoken` helper as today (`typescript/src/descriptor.ts`),
which is the one place that grammar lives.

The single-instance case is unchanged to the byte. Instance
`voxgig-solardemo` → `voxgig_solardemo.apikey` → sekreto's `envkey()` →
`VOXGIG_SOLARDEMO_APIKEY` — exactly what sdkgen's `envName()` emits and
exactly what the generated README documents. `station.md` §5.1's
promise, that a project which configures nothing keeps reading the env
var it reads today, survives intact.

Multi-instance follows the same rule with no special case: `stripe-test`
→ `stripe_test.apikey` → `STRIPE_TEST_APIKEY`. Each instance has its own
credential because each instance *is* a separate credentialed use of the
API, and the env var a developer has to set is derivable from the name
they chose. Where that is not wanted — several instances sharing one key
— `secret` at the **api** level names it once for all of them (§3.3),
which is the case the api block exists for.

**`envtoken` is lossy, so derived names can collide, and a collision
here is two integrations quietly sharing one credential.** `stripe-test`
and `stripe_test` are different instance names that both derive
`stripe_test.apikey` — and since §5.3 keys the resolution cache by
secret name, the second instance would silently receive the first's
value while this section claims each has its own. So the derived names
are checked for uniqueness at `open()`: **two instances whose
*resolved* secret names are equal, where at least one of them was
derived rather than written, is `station_secret_collision`**, naming
both instances and the shared name. Two instances that *explicitly*
name the same secret are not a collision — that is the shared-key case
the api-level `secret` exists for, and saying so out loud is how you
ask for it.

The `secretname` corpus section extends to cover instance names in both
directions and the collision case, because this is still the point where
three independently maintained grammars meet.

### 5.2 The grammar cannot express a credential

Scoped precisely, because this is a security claim and the wrong
version of it is worse than none.

**What is structural.** Every block map is closed (§4.1) and not one
block key holds a value: `secret` holds a *name*, further checked by
sekreto's `validname()` at profile-resolution time as today. `apikey`,
`token`, `password`, `key`, `credential` are not in the grammar, so
writing one is `station_config_invalid` naming the key and the path
(§4.5). For the eight-key grammar this is a proof, not a policy.

**Where it stops being structural.** `options` is an arbitrary map — it
has to be, it is passthrough to a generated constructor — so it is the
one place a value can hide. Three defences, in decreasing strength, and
then the residual:

1. **`validateConfig` scans `options` recursively** — every nested map
   and list, not just the top level — and rejects credential-shaped
   keys with `station_config_secret`. The list: `apikey` (the generated
   SDK's actual credential option, so this one is not a guess);
   `auth`, `authorization`, `token`, `secret`, `password`,
   `credential`, `bearer`; and any key whose `envtoken` normalization
   ends `_KEY`, `_TOKEN`, `_SECRET` or `_PASSWORD` — which is what
   catches `access_key`, `X-Api-Token` and friends in one rule rather
   than a growing list of spellings.
2. **At construction, station knows the descriptor**, and the
   descriptor names this API's auth prefix and header. So the
   *instance-specific* check that validation cannot do — "does this
   `options` map set anything this SDK would actually send as a
   credential?" — happens where the answer is knowable: at bind time,
   and eagerly for every instance under `station.check()` (§6.6).
3. **The value never survives anyway.** An `options.apikey` that got
   past both is hoisted into the broker and replaced by the placeholder
   before construction completes — that is `adopt()`'s existing
   behaviour (`station.md` §3.1), and it emits a warning event.

**The residual, stated.** A determined author can still put a working
credential in `options` under a key none of the above recognises and
that the SDK forwards — a custom header the descriptor does not model,
say. Nothing short of validating `options` against a per-SDK schema
closes that, and station has no descriptor at validation time. So the
honest claim is the one this section is now titled with: **the grammar
cannot express a credential, and `options` is scanned rather than
proven.** A project that wants the proof restricts `options` to the
empty map and passes everything in code.

A project that genuinely needs a non-credential option matching one of
those names sets it in code (`create(name, {options})`, precedence step
9) — the config file is the wrong place for it either way.

### 5.3 One sekreto per station, not one per instance

At 20 SDKs this stops being a detail. The station builds **one** sekreto
instance from the profile's provider chain and every plugin resolves
through it, so a Vault login, a token renewal and a provider cache are
paid once per process rather than 26 times.

The broker's internal keying is corrected while it is being touched.
Today `SecretBroker` caches by slug (`typescript/src/secrets.ts`), which
at instance granularity is simply wrong. The decomposition is:

- **hoisted overrides keyed by instance** — `adopt()` lifting a resident
  `options.apikey` is a property of that one client;
- **the resolution cache keyed by secret name** — so several instances
  naming one secret share a single resolution, which is the behaviour
  the api-level `secret` key implies;
- **the scrub list** unchanged: every value the broker ever held, exact
  match, no length floor (`station.md` §7).

### 5.4 No interpolation, and why

The config carries no `${ENV_VAR}` expansion, no `!file` includes and
no expressions. It is JSON that means what it says. Interpolation would
be a second secret-fetching mechanism sitting beside sekreto, with none
of sekreto's provider chain, miss/error distinction, plaintext refusal
or redaction — and it is how credentials end up in config files in the
first place. Naming a secret and letting sekreto resolve it is not a
restriction here; it is the feature.

### 5.5 Coordinating with the generated SDKs

Generated SDKs have their own credential story — one env var,
`<NAME>_APIKEY` — and station must compose with it rather than race it.
Four rules:

1. **Bound instances never resolve their own secret.** The SDK holds
   the placeholder, station's broker holds the value, injection happens
   at the transport seam (`station.md` §5.3, unchanged). If an SDK ever
   grows a direct sekreto integration it must be inert while a station
   binding is present, or the same secret gets resolved twice by two
   caches with two lifetimes.
2. **Unbound SDKs are untouched.** R0 is today's behaviour: the SDK
   reads its env var. Station changes nothing for code that does not use
   it.
3. **The name is the bridge.** `envkey(secretname) == envName(slug)` for
   the default single-instance case, pinned in the corpus in both
   directions. A project migrating from R0 to R1 changes no environment.
4. **Batch on demand.** `station.warm()` resolves secrets in one
   `sekreto.all(names)` call. At 20 instances against a remote vault,
   lazy per-first-request resolution is 20 sequential round-trips
   spread over the first minute of process life; `warm()` makes it one,
   at a moment the application chooses. It is opt-in — `open()` does no
   I/O (§6.5) — and it is the mechanism `station.md` §5.3 already
   reserved for multi-credential plugins.

   **The no-argument form warms *active* instances only.** In the §3.2
   prod profile `stripe-test` is deliberately inactive; warming it would
   ask the production provider chain for `stripe_test.apikey` — a secret
   that deployment has no business holding, and whose absence would turn
   a convenience call into a startup failure. Reaching for a credential
   belonging to a disabled integration is the wrong default in both
   directions. `warm(names)` warms exactly what it is given, inactive
   included, because an explicit name is an explicit request.


## 6. Getting an SDK

### 6.1 The surface

```ts
const station = Station.open()          // declarative init; no SDKs constructed
const stripe  = station.sdk('stripe')   // built on first ask, cached, ready
const test    = station.sdk('stripe-test')
```

| call | does |
|---|---|
| `station.sdk(name)` | the instance, constructed on first call and cached; same name → same object |
| `station.create(name, overrides?)` | an uncached client from the same resolved config plus overrides |
| `station.instances()` | every **declared** instance: name, api, active, live, rung |
| `station.plugins()` | every **live** plugin — as today, now one entry per instance |
| `station.check()` | eagerly resolve and construct every active instance; for CI (§6.6) |
| `station.warm(names?)` | batch-resolve secrets for active instances (§5.5) |
| `await station.load()` | ts/js only: preload ESM packages into the factory table (§6.3) |
| `Station.provide(api, factory)` | register a constructor for an api (§6.2) |

Retained unchanged in kind, because the imperative path is still the
retrofit path and still how a project with no config file starts:

- `station.connect(SDK, opts?)` — constructs an anonymous instance named
  by the api slug. Identical to today.
- `station.connect(SDK, { as: 'solar-eu' })` — names it, so
  multi-instance works imperatively too.
- `station.adopt(SDK, opts?)` — unchanged (`station.md` §3.1).
- `station.options(instanceName?, extra?)` — the inverted binding for
  static languages, now able to say which instance it is building.

`sdk(name)` caching is what makes "get it where you need it" a real
instruction: call it in a request handler, in a worker, in a test — the
first call pays construction, the rest are a map lookup. `create()`
exists for the case that genuinely wants a distinct client (a
per-request credential scope, a test double) and is deliberately the
longer name.

**`create()` needs its own registry identity**, or it cannot do what it
says. §7.5 registers every constructed adapter under its instance name
and §6.4 keeps `station_bound_twice` for a second binding of one name,
so a second `create('stripe')` — or the first one after `sdk('stripe')`
— would throw, which is exactly the per-request case the row above
promises. So a client from `create(name)` registers under a **derived
identity**, `name#<n>` with `n` a per-name counter, carrying `instance:
name` as the declared instance it came from:

- the registry key is unique, so `station_bound_twice` keeps meaning
  what it means: one *binding* per identity, never a cap on clients;
- `plugins()` and the event stream distinguish the clients, which is
  what you want when one of them is misbehaving;
- the placeholder follows the identity (§7.2), so injection is never
  ambiguous;
- the **secret name does not** — it is resolved from the declared
  instance, so every client of one instance shares one broker cache
  entry (§5.3) rather than re-resolving per request.

`instances()` reports declared instances; `plugins()` reports live
identities. At 20 SDKs with a per-request `create()` somewhere, that
distinction is the difference between a readable status page and an
unbounded one — so `plugins()` collapses `name#<n>` entries to a count
by default and lists them on request.

Static languages need one accommodation: `sdk()` returns the language's
dynamic form, and each port ships the idiomatic typed accessor over it —
`station.Get[T](st, "stripe")` in Go, `st.sdk("stripe",
StripeSDK.class)` in Java, and so on. The contract is the untyped one;
the sugar is per-port and specified in the port's README.

### 6.2 How station gets a constructor — the factory table

The universal mechanism, present in all 22 targets: a **process-global
table from api slug to factory**. It is station-independent — populated
before any `Station.open()`, shared by every station in the process, and
holding no configuration, only "here is how to construct this api".

It is filled three ways, in this order of preference:

1. **The generated adapter self-registers**, where the language has a
   module-init hook that actually runs: Go `func init()` on a blank
   import, a TypeScript/JavaScript module side-effect, a Python module
   import, a Ruby `require`. There, *linking the SDK package is the
   whole bootstrap* and the config's `api` map needs no `package` key.

   **Java, C# and Swift are not in that list, and saying they were
   would be a bug.** A Java `import` is a compile-time name alias: it
   loads nothing and runs no static initializer, so an adapter relying
   on one would leave the factory table empty and every
   `station.sdk(name)` failing `station_no_factory`. Those targets need
   an executable bootstrap, and the idiomatic one is a **service
   loader** — `ServiceLoader<StationFactory>` over a
   `META-INF/services` entry in Java, `[assembly:]`-attribute discovery
   or an explicit registrar in C#. sdkgen generates the service file
   alongside the adapter, so it stays one line of build output rather
   than one line of application code. Where a port has no service
   mechanism worth the weight, it uses path 2 and its README says so
   plainly instead of implying an import is enough.
2. **`Station.provide(api, factory)`.** One line per api, for SDKs
   generated before this lands and for anything hand-rolled. In Go
   that is a 20-line `sdks.go`, and every other line of configuration
   stays in JSON.
3. **The loader** (§6.3), which removes even that in languages that can
   import by name.

Registration is idempotent per api; a second registration for the same
api with a different factory is `station_factory_conflict`, because
silently picking one of two SDK builds is not a thing to do quietly.

### 6.3 The loader, where the language allows it

In ts, js, py, rb, php, perl, lua, elixir and clojure a module can be
imported by name at runtime, so `api.<slug>.package` closes the loop:
station imports the package (which triggers self-registration, path 1)
and then looks up the factory. `export` is the fallback for a package
whose SDK predates the station feature and therefore self-registers
nothing — station reads the named export and builds a factory from it.
Its default is sdkgen's own class-naming rule, `camelify(slug) + 'SDK'`
(`voxgig-solardemo` → `VoxgigSolardemoSDK`), which is a fixed rule in
the generator. `package` has **no** default: sdkgen's published name is
derivable *most* of the time but a target may override it outright
(`publish.registry.package`, `ts/src/helpers/packageMeta.ts`), and a
guessed package name that resolves to the wrong thing is worse than a
required key.

Compiled targets (go, java, csharp, rust, swift, dart, kotlin, c, cpp,
zig) ignore `package`/`export` — a warning event at open, not an error,
so one config file serves a polyglot fleet. Those targets use paths 1
and 2 from §6.2.

**`sdk()` is synchronous, and in ts/js that bounds what the loader can
import.** A CommonJS package loads synchronously through `require`; an
ESM-only package, or one with top-level `await`, only loads through
`import()`, which is a promise. Making `sdk()` async to cover that
would put an `await` in front of every call site in every language for
a cost only two of them pay — the wrong trade, and it would break the
chained call in §9.2's test. So the rule is explicit rather than
discovered at runtime:

- **the synchronous loader handles CommonJS.** That covers every SDK
  sdkgen generates — the ts target is `"type": "commonjs"` — which is
  the case the loader exists for;
- **ESM packages load through an explicit preload**, `await
  station.load()`, which imports every declared `package` and fills the
  same factory table §6.2 describes. After it resolves, `sdk()` is
  synchronous again for everything. An application with ESM SDKs adds
  one `await` at startup rather than one per call site;
- **a package that only `import()` can load, reached through `sdk()`
  without a preload, is `station_sdk_load`** with a message naming
  `station.load()`. It fails at first use with the remedy in the error,
  which is the §6.4 split working as intended — never a silent
  half-loaded client.

**The loader is a code-loading surface driven by a config file, so it
has rules:**

- Only **module names** resolved by the host language's ordinary
  resolution from the application root. Never a filesystem path, never a
  URL, never anything relative.
- **`package` and `export` are honoured only from repo-scoped config.**
  `station.json` is found by walking cwd upward to the repo root and
  then falling back to `~/.voxgig/station.json`
  (`typescript/src/profile.ts`). A user-level file is outside the repo's
  review boundary, so a `package` key arriving from it is **ignored with
  a warning event** rather than imported. Everything else in a
  user-level config still applies.
- **`Station.open({ load: false })`** disables the loader outright;
  only self-registered and explicitly provided factories are used.

### 6.4 Failure, split by when it can be known

- **Shape errors are fatal at `open()`**, and so are the two
  whole-file checks that only `open()` can make: a derived secret-name
  collision (§5.1) and a `secret` name sekreto would reject. The file
  is malformed, and it is the file that decides which credential
  reaches which host.
- **Availability errors are fatal at first use.** A package that will not
  import, an api with no factory, an instance marked inactive — these
  fail at `station.sdk(name)`, not at `open()`. At 20 SDKs a process
  that touches three of them must not die because the eighteenth has a
  typo'd package name.

New error codes for `station.md` §14's catalog:

| code | when |
|---|---|
| `station_config_invalid` | struct validation failed; message carries every error with paths |
| `station_config_secret` | a credential-shaped key in an `options` block (§5.2) |
| `station_no_instance` | `sdk(name)` for an undeclared name; message lists the declared ones |
| `station_instance_inactive` | the instance is declared with `active: false` |
| `station_sdk_load` | `package` could not be imported, `export` is absent from it, or it is ESM-only and `station.load()` was not awaited (§6.3) |
| `station_secret_collision` | two instances derive the same secret name (§5.1) |
| `station_no_factory` | no factory for the api; message names both remedies |
| `station_factory_conflict` | two different factories registered for one api |

Amended: `station_bound_twice` is now keyed by **instance name**. Two
clients of one api is the normal case; two bindings of one instance is
still the error it was.

### 6.5 What `open()` costs

Stated as a budget because 20 SDKs is the design point:

> **`Station.open()` performs exactly one file read and no other I/O.**
> No module is imported, no SDK is constructed, no secret is resolved,
> no socket is opened.

Its cost is the config read plus normalize-and-validate (§4.6) — ~15 ms
at 20 instances — and building the instance table, which is a map
comprehension. Everything expensive is deferred to the instance that
asks for it. The proxy probe stays deferred exactly as today
(`station.md` §2.1).

### 6.6 `check()` — the CI counterpart

Deferring availability errors to first use is right for production and
wrong for CI, so it is a verb: `station.check()` (and
`voxgig-station check`) walks every active instance, resolves its
factory, constructs it and reports per-instance status without sending
a request. It is what a project runs in CI to learn that
`@acme-sdk/stripe-sdk` was never added to `package.json` — at build
time, rather than at 3am from the one code path that uses it.


## 7. What this changes in the shipped design

### 7.1 Registry and identity

`Map<slug, PluginEntry>` → `Map<instanceName, PluginEntry>`, with
`PluginEntry` carrying both `name` (instance) and `api` (slug).
`_register` takes the instance name; its `station_bound_twice` check
moves to that key.

### 7.2 Placeholder

`placeholderFor(instanceName)` → `[station:stripe-test]`. Two live
instances of one api **must** have distinct placeholders or the
injection seam cannot tell which credential a header wants. This is a
corpus change (`placeholder` section) and a required change in every
port.

### 7.3 Events

`StationEvent.plugin` keeps its name and carries the **instance name**;
a new `api` field carries the slug. Additive, so `station.md` §8.6's
wire compatibility rule holds, and a consumer that only knows `plugin`
keeps working — it simply sees instance-grained events, which is what
it wants at 20 SDKs anyway. `station.md` §6's per-plugin views become
per-instance, with api available for grouping.

### 7.4 Descriptor

**Shared**: it describes the api, so `normalizeDescriptor` runs once per
api and every instance of that api holds a reference to the same object.
At 26 instances over 20 apis that is 20 normalizations, not 26, and the
canonical serialization the proxy dedupes registrations by is computed
once per api. `descriptorOf()` accepts an instance name and returns its
api's descriptor.

**One field has to move, and it is the one §5.1 touches.** The
descriptor carries `auth.secretname` — `station.md` §4 calls it
`secretname-default` — derived today from the slug. A single descriptor
shared by `pad-a` and `pad-b` cannot hold two different instance-derived
names, so whichever instance built the cached copy would report the
other's secret metadata wrongly. The split:

- **the descriptor keeps the api-level default**, slug-derived, exactly
  as `normalizeDescriptor` computes it today. It is a property of the
  API — the conventional env var its README documents — and it is
  correct for every instance to share it, because it describes the API
  rather than any use of it;
- **the instance's effective secret name lives in `Binding.secretname`**,
  which is already per-registration (`typescript/src/types.ts`) and is
  already what `_transport` resolves through. That is the authority; the
  descriptor field is documentation.

So `descriptorOf(instance)` reports the api's conventional name and
`plugins()` reports each instance's effective one, and neither is a
guess about the other. The `descriptor` corpus section gains a case
asserting the shared descriptor is byte-identical across two instances
of one api.

### 7.5 Registration is now driven by station

Today the SDK constructs itself and the feature registers it. With
`sdk(name)`, station constructs the SDK, so it knows the instance name
before construction begins and passes it through the feature options
(`feature.station.instance`). The adapter reads it and registers under
it. Nothing about the plugin contract — wrap ordering, position guard,
copy-on-inject, hook bridge — changes; only where the name comes from.

For the inverted binding, `st.options('solar-eu')` puts the instance
name in the same place. For a bare `connect(SDK)` with no name, the
adapter falls back to the descriptor slug, which is today's behaviour.

### 7.6 `close()`

The `close()`-time warning for profile keys that matched no registered
plugin narrows: with declarative instances, station creates what the
config declares, so an unmatched `sdk` key is no longer possible. The
warning survives for **`api` blocks that no instance references** — a
real typo case that validation cannot catch, since an api block key is
a free-form slug.


## 8. Every language

`ts` is the tracer bullet and the reference, as it is for the SDK
targets. The porting surface, honestly:

**What is data, and therefore free per port** — the config grammar, the
shape file, the normalizer's defaults, the resolution order, the
placeholder format, secret-name derivation, and every case in the
corpus. A port implements the mechanism; it never restates the rules.

**What each port must write:**

| piece | size | notes |
|---|---|---|
| `normalizeConfig` | ~30 lines | pure data-in/data-out |
| `validateConfig` | ~20 lines | calls the port's struct `validate`, plus the recursive `options` scan |
| the §3.3 block merge | ~30 lines | replaces the two-way plugin merge; api resolved first, defaults applied last |
| derived secret-name collision check | ~10 lines | §5.1 |
| instance table + lazy cache | ~60 lines | plus the port's concurrency idiom |
| factory table + `provide` | ~30 lines | process-global |
| loader | ~30 lines | dynamic-import languages only |
| re-keying to instance | — | registry, placeholder, broker, events |

Call it 175–225 lines added per port against `station.md` §10.1's
1–2k budget for a tier A library. It fits, and it is mostly the same
shape in every language because it is mostly map manipulation.

**The one new dependency question.** Station libraries take exactly one
dependency, sekreto (`station.md` §10). This adds struct — in the nine
of ten ports where sekreto is dependency-free, struct is the same kind
of addition: a voxgig sibling with a shared corpus and no transitive
tree. Two positions need naming rather than assuming:

- **Tier C (c, cpp, zig, lean)** vendors its libraries already
  (`station.md` §9.2). struct has c, cpp and zig ports, so this is the
  established vendoring path, not a new one. Lean is deferred with the
  rest of its tier.
- **Rust** already carries a real tree through sekreto's rustls
  (`station.md` §10); struct-rust adds to it. The tier budget note
  stands.

**Order.** `ts` first and complete. Then `js` and `py` (loader
languages, cheap second and third proofs). Then `go` and `java` — the
factory-table path with no loader, which is the shape that proves the
design is not TypeScript-flavoured. Then the rest in `station.md` §17's
demand order. The rule from §9.6 is unchanged and unchanged in force:
**an adapter never ships for a target before that target's station
library exists.**


## 9. Testing

### 9.1 Corpus

`spec/station.json` gains and amends:

- **`config` (new)** — normalize-then-validate over the §4.5 table: each
  case is a raw config in, and either the normalized output or the
  expected error set out. This is the section that makes the grammar
  identical in 22 languages.
- **`instance` (new)** — the merge of §3.3: api ⊕ sdk across base ⊕
  overlay, the `api`-defaults-to-key rule, `active: false`, and the
  shallow-merge-replaces-`policy` consequence. Two cases are
  regression guards rather than examples, because both are defects
  this design had before review: **defaults applied after the merge**
  (a one-key overlay block must not overwrite the base's `api` or
  `active`) and **the api resolved before its defaults are looked
  up**.
- **`secretname` collisions (new cases)** — two instances deriving one
  name is `station_secret_collision`; two instances *naming* one
  secret explicitly is legal.
- **`profile` (rewritten)** — `plugin` → `sdk`, and the existing cases
  restated in the new grammar.
- **`secretname` (extended)** — instance-name derivation and the
  `envkey` ↔ `envName` round-trip for both the degenerate and
  multi-instance cases.
- **`placeholder` (amended)** — keyed by instance.

A guard test asserts the two block specs in `config-shape.json` differ
only by the `api` key (§3.1) — the sdkgen discipline for data that must
be duplicated.

### 9.2 The integration test that is the requirement

`typescript/test/declarative.test.ts`, against the real generated
taskpad SDK and two live servers. `test/api/taskpad/server.js` already
takes `TASKPAD_PORT` and `TASKPAD_APIKEY`, so:

- run taskpad twice — `:8902` with key A, `:8903` with key B;
- one `station.json` declaring one api and two instances, `pad-a` and
  `pad-b`, with different `base` and different `secret`;
- `Station.open()`; assert **no** SDK constructed and **no** secret
  resolved;
- `station.sdk('pad-a').Todo().list()` and the same for `pad-b`;
- assert: each reached its own port; each authenticated with its own
  key; `sdk('pad-a')` twice is the same object; events carry
  `plugin: 'pad-a'` / `'pad-b'` with `api: 'taskpad'` on both;
  `ctrl.explain` on both still holds only that instance's placeholder;
  neither key appears anywhere in the event stream.

That single test is requirement "SDKs are not singletons" made
executable, and it runs against a real generated SDK rather than a mock.

### 9.3 Scale test

A generated 20-api / 26-instance config: `open()` under the §4.6 budget,
`instances()` complete, exactly the touched SDKs constructed, and
`warm()` issuing one batch resolve rather than 26.

### 9.4 Negative tests

Every §4.5 failing case as a unit test, plus: a credential in
`options`; a `package` key arriving from a simulated `~/.voxgig`
config; `load: false`; a `provide()` conflict.

### 9.5 Upstream

File the `` `$CHILD` ``-skips-element-0 defect against voxgig/struct
with the minimal reproduction from §4.4. When it is fixed, `hosts[0]`
starts being checked and the corpus case flips from documented-gap to
enforced.


## 10. sdkgen and sdkgen-station

Small, because the plugin contract does not move.

1. **`feature.station.config.options` gains `instance: ''`** — how the
   instance name reaches the adapter (§7.5). One key in
   `model/feature/station.aontu`.
2. **The adapter self-registers its factory at module init** (§6.2) in
   every target where that is expressible — the one genuinely new
   per-target code in the sdkgen-station overlay, and it is a handful of
   lines each.
3. **`ReadmeStation` gains the declarative quickstart** — the
   `station.json` block and `station.sdk()` beside the existing
   `connect()` form, plus the instance-derived env var name.
4. **The generated `AGENTS.md` station paragraph** says that
   integrations are declared in `station.json` and that an agent should
   read that file to learn what the application talks to.
5. **`docs/how-to/use-station.md`** (sdkgen, `station.md` §9.4) leads
   with the declarative flow.

Everything already listed in `station.md` §9 — the three
`configDefinition` fields, the `makeOptions` featureorder special case,
the `extend` tolerance — is unchanged and still required.


## 11. Implementation plan

Five stages. Each ends in a state where `make test` is green and the
repo is coherent; nothing here is a long-lived branch.

### Stage 1 — the grammar, as data (no behaviour change)

- `spec/config-shape.json` — §4.3, verbatim.
- `spec/station.json`: add the `config` section from §4.5; rewrite
  `profile` for `sdk`/`api`.
- `typescript/src/shape.ts` — one defaults table with two callers
  (§4.2): `normalizeConfig` producing the **validation form**, and
  `validateConfig` (struct `validate` with `errs`, plus the recursive
  `options` scan of §5.2), raising `station_config_invalid` /
  `station_config_secret`.
- `typescript/src/profile.ts` — the §3.3 merge over **raw** blocks with
  defaults applied to the merged instance and the api resolved before
  its block is read; `ResolvedProfile` becomes
  `{ name, providers, api, sdk }`; `validname` per instance; the
  derived-secret-name collision check.
- `selectProfile` — no change; §3.3 documents what it already does.
- `@voxgig/struct` added to `typescript/package.json`.
- Guard test for the two block specs.

*Exit:* the corpus `config` and `instance` sections pass in ts,
including both defaults-after-merge regression guards; a malformed
`station.json` fails `open()` with every error at once.

### Stage 2 — instances (the identity change)

- `types.ts` — `SdkBlock`, `ResolvedInstance`; `PluginEntry` gains
  `name` + `api`; `Binding` gains `instance`.
- `Station.ts` — registry keyed by instance; `_register` takes the
  instance name; `_transport` and `_opEvent` take it; placeholder and
  profile lookup follow.
- `descriptor.ts` — `secretnameDefault(instanceName)` for the
  instance default; the descriptor keeps the **api** default and the
  effective name moves to `Binding.secretname` (§7.4); descriptor cache
  per api.
- `secrets.ts` — overrides by instance, resolution cache by secret name.
- `adapter.ts` — read `fopts.instance`, fall back to the slug.
- Events gain `api`.

*Exit:* the amended `placeholder` and `secretname` corpus sections pass;
`connect(SDK, {as})` binds two instances of one api; the existing
suites are green with no behaviour change for single-instance projects.

### Stage 3 — the declarative front door

- `typescript/src/factory.ts` — the process-global table, `provide`,
  `station_factory_conflict`.
- `typescript/src/loader.ts` — synchronous `require` for CommonJS, the
  `await station.load()` ESM preload, repo-scoped-only rule, `export`
  fallback and its default, `station_sdk_load` (§6.3).
- `Station.ts` — the instance table built at `open()`; `sdk()`,
  `create()` with its `name#<n>` registry identity (§6.1),
  `instances()`, `check()`, `warm()` over active instances only;
  `options(instanceName, extra)`; the deferred-availability errors.
- `index.ts` exports.

*Exit:* §9.2's two-instance integration test is green, and §6.5's
`open()` budget is asserted.

### Stage 4 — the generator side

- sdkgen-station: `instance` feature option; adapter self-registration
  for ts and js (module side-effect); ReadmeStation and AgentGuide copy.
  The generated service-loader entries for java and csharp (§6.2) land
  with those ports in Stage 5, not here.
- sdkgen: `docs/how-to/use-station.md` leads with the declarative flow.
- The package-side CI fixture flow (`station.md` §9.5) covers the ts/js
  adapters.

*Exit:* a generated SDK is reachable through `station.sdk()` with no
import in application code.

### Stage 5 — ports

`js`, `py`, then `go`, `java`, then `station.md` §17's order. Each port
is one independent deliverable: the seven pieces in §8's table, the
corpus green, its own README updated. The corpus is what makes them
parallelizable and what makes "it works in every language" checkable
rather than claimed.

**Docs.** `station.md` gets its §15 amendments applied in the same
change as Stage 3, so the two documents never disagree in `main`. The
repo README's status table gains a declarative-config column as ports
land.


## 12. Risks

- **The struct optional-container trap (§4.2) is easy to reintroduce.**
  Someone adds an optional key, wraps a container in `` `$ONE` ``, and
  quietly reopens a map. Mitigation: the `config` corpus section carries
  a typo case for **every** map level, so reopening one fails a test
  rather than passing silently.
- **`plugin` → `sdk` is a breaking rename** across 17 ports and the
  corpus. Mitigated by being pre-1.0 and by the rename being mechanical;
  the alternative — an alias — is worse and permanent.
- **The loader is config-driven code loading.** Bounded by §6.3's three
  rules. The residual is that a repo-scoped `station.json` can name a
  package, which is the same trust level as `package.json` naming a
  dependency — and the user-level config, which is *not* that trust
  level, is excluded.
- **Instance-derived secret names surprise someone.** Rename an instance
  and its default env var changes. Mitigated: `secret` pins the name
  explicitly, api-level `secret` covers the shared-key case, and
  `station_secret_no_value` already names the env var that would have
  answered.
- **The defaults-timing rule (§3.3, §4.2) is invisible until it
  bites.** A port that materializes block defaults before merging looks
  correct on every single-profile test and silently picks the wrong api
  under an overlay. Mitigation: it is a named regression guard in the
  `instance` corpus section, not a prose warning.
- **`options` is scanned, not proven** (§5.2). The residual is stated
  in the doc and in the error message; a project that needs the proof
  empties `options`.
- **A 22-port change of this size drifts.** The corpus is the control,
  and CI already runs every port against it.


## 13. Non-goals

Everything in `station.md` §19 still holds. Added:

- **No expressions in the config.** No interpolation, includes,
  conditionals or templating (§5.4).
- **No dependency injection container.** `sdk(name)` resolves *SDK
  instances* from station's own config. It is not a service locator for
  application objects and will not grow into one.
- **No hot reload of `station.json` in v1.** Config is read once at
  `open()`. Live policy updates are the proxy's long-poll
  (`station.md` §17 Phase 3), which is where a change of mind should
  arrive from.
- **No cross-instance orchestration.** Station configures and observes
  20 SDKs; it does not sequence, transact or fan out across them.


## 14. Open questions

- **Should an api block be able to declare its instances?** A
  `"instances": ["eu","us"]` shorthand would shorten a fleet where
  instances differ only by name. Deferred: the explicit `sdk` map is
  more readable at 26 entries and there is exactly one place to look.
- **Per-instance `resolve: proxy` grant scoping.** `station.md` §5.3's
  grant is plugin-scoped; with instances, is the grant per instance or
  per api? Per instance is the obvious answer and costs the proxy a
  wider grant table. Settle before R2 ships (Phase 1 of `station.md`
  §17).
- **A `station.json` fragment per package.** At 20 SDKs a monorepo may
  want each service to contribute its own instances. Composition rules
  (precedence, conflict) are a real design, not an afterthought;
  deferred until someone has the problem.
- **`instances()` for an agent** — should `station_integrations` list
  declared-but-never-built instances, or only live plugins? Declared, on
  the argument that an agent asking what the app integrates with wants
  the config's answer, not the current process's; needs a field to
  distinguish them.


## 15. Amendments to `station.md`

Applied in the same change as Stage 3, so the documents never disagree:

| section | amendment |
|---|---|
| §3.1 | binding forms gain `sdk()`/`create()`; `connect` gains `as`; `options()` gains an instance name |
| §3.2 | the registry is keyed by instance; `plugins()` returns one entry per instance |
| §3.5 | the resolution order becomes §3.3 of this document; "deep-merge per plugin" corrected to **shallow**, matching every port; profile selection completed to `open({profile})` > env > `default`, matching every shipped `selectProfile` |
| §4 | the descriptor is shared per api and looked up by instance name; `secretname-default` stays the **api** default and the instance's effective name moves to `Binding.secretname` (§7.4) |
| §5.1 | secret names derive from the **instance** name; the degenerate case is unchanged |
| §5.2 | `station.json`'s `plugin` map becomes `sdk` + `api`; providers validated as a list only |
| §5.3 | broker keying corrected: overrides by instance, resolution cache by secret name |
| §6 | events carry `plugin` = instance name and a new `api` field |
| §11 | the declarative quickstart leads; the two-line imperative form stays as the retrofit path |
| §13 | the `config` and `instance` corpus sections; `profile`, `secretname`, `placeholder` amended |
| §14 | eight new error codes (§6.4); `station_bound_twice` re-keyed to the instance, and explicitly not a cap on clients per instance (§6.1) |
| §17 | Phase 1 gains Stages 1–4 of §11; Phase 2's `station.json` schema item is satisfied by the struct shape |
