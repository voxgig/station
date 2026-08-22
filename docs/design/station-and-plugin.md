# Review: adopting voxgig/plugin in station

Status: **assessment** (2026-08-22). Reviews
[voxgig/plugin's design](https://github.com/voxgig/plugin/blob/claude/voxgig-plugin-architecture-h6cly0/docs/design/plugin.md)
at commit `9fd5548` from station's side, and says what station should
do about it.

That document already reads station's
[declarative-config design](./station-declarative-config.md) and
reconciles against it in its §17.1. This is the reply: what it gets
right, where its account of station overstates the fit, and the
sequencing station should actually take. References of the form
**P§n** are to the plugin design; bare **§n** are to
`station-declarative-config.md`.


## 0. Verdict

**Adopt the model. Do not block on the library.**

The model is right, and in four places it is better than what
`station-declarative-config.md` arrived at independently. But
voxgig/plugin is a design with no implementation, and station has
**sixteen working language ports**. The library's per-port budget is
~1200 lines of core (P§19) — comparable to an entire station port
(`station.md` §10.1 budgets 1–2k for tier A). Adopting the library
before it has ports would take station from sixteen green ports to one.

So: **build station's Stages 1–3 natively against plugin's semantics,
and let plugin extract the implementation afterwards.** P§17.1 already
names that as its fallback ("the same destination, reached in the other
order"). It should be the plan, not the fallback, and §6 below says
why the case is stronger than that section allows.


## 1. What it gets right, including four things it does better

Credit first, because the overlap is not coincidence — P§17.1 was
written against station's document, and several of its mechanisms exist
*because* station needed them.

| plugin mechanism | what it settles for station |
|---|---|
| `name$tag` refs (P§4) | §2's instance/api split, with one identity instead of two |
| the `declared` state (P§5.1) | §6.5's "`open()` does one file read and no other I/O", as a first-class state |
| `tag: '?'` auto-tagging (P§4 rule 3) | §6.1's `create()` identity — a *declared* mechanism, not the `name#<n>` convention I invented under review pressure |
| list-replaces-on-merge (P§9.4) | generalizes §3.3's `secrets.providers` carve-out into the global rule it should have been |

Four where plugin is **better than station's design**, and station
should take them regardless of whether it adopts the library:

1. **Ordering by constraints and bands (P§7) beats §8.4.** My design
   kept sdkgen's test-first-then-alphabetical default and layered an
   explicit `order` list on top. P§7 replaces both with a stable
   topological sort — and, pointedly, removes `makeOptions`' `test` and
   `station` special cases rather than adding a third. It also gets the
   vacuous-satisfaction rule right (`after: 'test'` in a host with no
   test plugin loads fine), which is sdkgen's existing `__after__`
   behaviour preserved rather than reinvented.

2. **The `transport` role (§8.4) becomes unnecessary.** I proposed
   adding `transport: 'base' | 'wrap' | 'none'` to seventeen feature
   models so station could order them. Under plugin, *which point you
   bind to* carries that: a `chain` binding is in the wrap chain, a
   `hook` binding is not. The role is structural rather than declared,
   which is strictly better — and it deletes a seventeen-model sdkgen
   change from §11.

3. **Position verification (P§6.6) generalizes `station.md` §3.3's
   guard.** `inst.position('request')` returning
   `{index, count, innermost, outermost}` is the wrap-order check
   station hand-rolls, available to every plugin in every host.

4. **Runtime deactivation with resource release (P§8).** §8.8 declares
   runtime feature toggling a non-goal, because features install at
   construction and there is no late-attach. Plugin's instance scope
   makes deactivate a first-class operation with automatic unwind — so
   "turn debug on for five minutes without a redeploy", which §15 lists
   as the most-wanted thing station cannot do, becomes possible. That
   is a capability gain, not a refactor.

P§17.1 also catches a collision worth recording: station's `active:
false` (*barred from running*) and plugin's `active` **state** share a
spelling and not a meaning. Both documents should say so; §3.1 now does.


## 2. Finding 1 — the sixteen-port problem (P§17.1 does not mention it)

P§17.1 discusses sequencing entirely in TypeScript: station's Stages 2
and 3 go behind plugin's P1 and P2. That is the *small* version of the
problem.

Station today has **sixteen written ports** — `c`, `cpp`, `csharp`,
`dart`, `elixir`, `go`, `java`, `javascript`, `lua`, `perl`, `php`,
`python`, `ruby`, `rust`, `swift`, `typescript` — thirteen of them
running a full suite in CI. Plugin has **none**, and its rollout
(P§16.1) is four tiers: typescript, then go+python, then fourteen more,
then six constrained ones.

A station port cannot use a plugin library that does not exist in its
language. So adopting the library as a dependency means, for each of
station's sixteen ports, either:

- wait for that language's plugin port (tier 3 for most; tier 4 for
  `c`, `cpp`), or
- keep a native implementation and carry two instance models in one
  repo — the exact outcome P§17.1 exists to avoid.

**This is the decisive constraint and it is absent from P§17.1's
account.** It does not argue against the model. It argues that the
library must follow station's ports rather than lead them.


## 3. Finding 2 — the credential guarantee inverts

P§17.1's table contains this row:

> struct-validated config, closed by construction → §9.4's option
> shapes, same `struct.validate`

**That is not the same property, and the difference is the one security
claim station makes.**

§5.2's guarantee is that the *grammar* cannot express a credential:
station's block has eight known keys, maps are closed, and no key holds
a value. An inline `apikey` is `station_config_invalid` naming the key.

P§9.4 validates an instance's `options` against **the definition's
option shape**. For an SDK definition that shape is the SDK's own
options — and `apikey: ''` is in it
(`MakeOptionsUtility.ts`'s `optspec`, line 46). So under plugin's rule
as written:

```json
"stripe$test": { "options": { "apikey": "sk-live-abc123" } }
```

is **grammatically valid**, because the SDK genuinely accepts that
option. The guarantee does not weaken — it inverts. A closed grammar
that omits the credential key becomes an open one that includes it by
definition.

This is survivable and station knows how: §5.2's recursive scan and the
sekreto-`validname()` name/value rule are station-side policy over
whatever the mechanism permits, and they keep working. But it must be
**stated as station's job**, because P§17.1 currently reads as though
plugin supplies it. Two consequences:

- station's host wrapper keeps the §5.2 scan over every instance's
  `options`, regardless of the definition's shape;
- the plugin document should drop or qualify that table row. A generic
  plugin library cannot be closed-by-construction against credentials,
  because it does not know which of a definition's options is one.


## 4. Finding 3 — nested-host feature management depends on an uncommitted change

P§17.1 maps "SDK features managed fleet-wide, per instance" onto
"an instance that is itself a host (P§6.5)", and P§6.5 says nested
hosts are in the model *because* station needs them.

Station's actual §8 need is satisfiable without them, and the mapping
only holds if **sdkgen adopts plugin** — which P§17.2 explicitly does
not commit to:

> This is stated as a demonstration, not a commitment: the deliverable
> is a bridge in this repo that runs an unmodified sdkgen feature as a
> plugin … leaving whether sdkgen's generated code adopts it as a
> separate, sdkgen-side decision with its own propagation cost across
> 23 template trees.

Until that decision lands, a generated SDK is **not** a plugin host. It
has `options.feature` (map or ordered array) and `FEATURE_CLASS`, and
station configures features by composing that array — which is what §8
describes and what §8.1 shows already works. Wrapping it in
`inst.host(...)` would be a host-shaped object around a non-host, which
buys nothing until the inside is real.

So the honest staging is: **§8 as written now; nested hosts when sdkgen
adopts.** The nested-host model is right and worth having in plugin —
but it is a *future* fit for station's feature management, not a
present one, and P§6.5's justification overstates the immediacy.


## 5. Finding 4 — api-level defaults have nowhere to live

§3.1 has two block levels: `sdk.<instance>` and **`api.<slug>`**, the
second providing defaults inherited by every instance of that api. §3.2
uses it for `api.stripe.policy.hosts` — written once, applying to every
stripe instance, which is what stops a twenty-api file being repetitive.

P§17.1 says station's `api` field "disappears because the name already
carries it". That is true of the **field** (`sdk.<n>.api`) and not of
the **block**. For the block, plugin offers P§9.3's untagged-to-tagged
inheritance: options written for `stripe` are a base for `stripe$test`.

But P§4 rule 2 makes `stripe` **an ordinary instance** — "`stripe` and
`stripe$test` are two different instances of one definition, and both
may exist". So writing shared defaults under `stripe` also declares a
live untagged stripe instance. A project wanting `stripe$live`,
`stripe$test` and `stripe$eu` and *no* untagged instance has nowhere in
the document to put their shared policy: the only other home is
`makeHost({defaults})`, which is code, and station's whole premise is
that this belongs in JSON.

**Ask:** a `default` (or `define`) map keyed by bare **name**, distinct
from the `instance` map keyed by **ref**, feeding precedence level 2.
It is a small addition that P§9.3's precedence list already has a slot
for, and without it station either loses the api block or has to create
instances nobody asked for.


## 6. Budget arithmetic

`station.md` §10 permits station exactly one dependency, sekreto, and
argues it costs nothing because sekreto is zero-dependency in nine of
ten ports. Plugin is a different proposition:

| | per port |
|---|---|
| station library (`station.md` §10.1, tier A) | 1–2k lines |
| plugin core (P§19) | ~1200 lines |
| plugin + capabilities (P§19) | ~1700 lines |

Plugin absorbs some of station's own weight — config/profile loading,
the instance registry, lifecycle, ordering; call it 300–400 lines of a
~1500-line station port. So the net is roughly **+800 lines per
language, in sixteen languages**, against a saving of ~350.

That is not an argument against adoption. It is an argument that the
line count only pays for itself if plugin is used by **more than one**
voxgig library — which is precisely its thesis (P§1), and precisely
what has not happened yet. Station is the first consumer, and a first
consumer that pays 800 lines a port for an abstraction it is the only
user of is subsidising a bet.

The bet is probably right. sdkgen features (P§17.2) are the second
consumer and are a genuine fit. But station should not be the one
carrying the cost of proving it in sixteen languages before the second
consumer exists.


## 7. Recommendation

**Take the model now; take the library when it has ports.**

1. **Station Stage 1 proceeds unchanged and immediately.** Grammar,
   shape file, normalizer, corpus sections — station's own data,
   dependent on nothing here. P§17.1 agrees.

2. **Re-key Stage 2 to `name$tag` refs** rather than to the
   free-form-name-plus-`api`-field of §2. This is the one change to
   make *now*, because it is cheaper to adopt before Stage 2 is written
   than to migrate after, and it is right on its own merits: one
   identity, and every log line naming an instance names its api.
   Concretely, in `station-declarative-config.md`:
   - `sdk` keys become refs — `voxgig-solardemo`, `stripe$test`,
     `github$ent`;
   - `sdk.<n>.api` is deleted; the name before `$` is the api;
   - §6.1's `create()` uses `tag: '?'` auto-tagging in place of
     `name#<n>`;
   - the `api` block stays, pending Finding 4.

3. **Build Stages 2 and 3 natively, to plugin's semantics.** The state
   names (`declared`/`loaded`/`active`), the ref grammar, the
   precedence order, list-replaces merging, and vacuous constraint
   satisfaction all become station's implementation — written so that
   plugin can extract them. Station's sixteen ports keep working
   throughout.

4. **Adopt P§7's ordering model in §8.4 now**, dropping the proposed
   `transport` field and the seventeen-model sdkgen change with it.
   Constraints plus bands, resolved by topological sort, is a better
   design than the one §8.4 has, and it does not require the library.

5. **Plugin's P3 becomes extraction rather than construction.** Its
   proof obligation ("station keeps `connect`/`adopt`/`options`/`sdk`/
   `create` as its public API, and plugin has to fit underneath it
   unchanged") is *easier* to discharge against a working station than
   against a design, and it gives plugin's TypeScript port a real
   consumer on day one.

6. **Revisit the library dependency when plugin reaches tier 3.** At
   that point most of station's sixteen ports have a plugin to depend
   on, sdkgen's decision on P§17.2 is likelier to have landed, and the
   +800-lines-per-port trade is being made with two consumers rather
   than one.

The one thing this sequencing costs is that station's implementation
and plugin's may drift before they meet. The mitigation is the corpus:
plugin's `ref`, `config`, `lifecycle` and `order` sections are pure
data (P§15), and station can run them against its own implementation
long before it depends on the library. **That is the concrete ask of
plugin's P1: ship the corpus sections early, even in draft, and station
will hold itself to them.**


## 8. What we would ask voxgig/plugin to change

Small, and all four are in P§17.1's account of station rather than in
the model:

1. **Add the sixteen-port constraint** (§2) to P§17.1's sequencing
   discussion, and make "station builds natively, plugin extracts" the
   primary plan rather than the fallback.
2. **Drop or qualify the "closed by construction" table row** (§3) — a
   generic plugin library cannot make that guarantee, and station's is
   layered on top rather than supplied.
3. **Mark the nested-host row as contingent on P§17.2** (§4), so
   P§6.5's justification does not rest on a station need that today's
   sdkgen cannot satisfy.
4. **Add a name-keyed `default` map** beside the ref-keyed `instance`
   map (§5), so shared per-definition configuration does not require
   declaring an untagged instance.

None of these is a disagreement with the model. Three are about how
P§17.1 describes station, and the fourth is a gap that station is
simply the first host to hit.
