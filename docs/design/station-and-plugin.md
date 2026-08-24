# Reconciliation: voxgig/station and voxgig/plugin

Status: **reconciled** (2026-08-22). Supersedes the one-sided assessment
this file previously held.

[voxgig/plugin](https://github.com/voxgig/plugin) is a general plugin
architecture — one model, ported to every language the Voxgig stack
targets. [station](./station.md) is its first host, and this document
is the agreed position between the two designs: what they share, where
they disagreed, and which side moved.

References of the form **P§n** are to plugin's design **as merged by
[voxgig/plugin#15](https://github.com/voxgig/plugin/pull/15), commit
[`153c878`](https://github.com/voxgig/plugin/blob/153c8785a996940e80e5a626ec978fc5e1c07bc5/docs/design/plugin.md)**
— plugin's `main` as of 2026-08-24, with P0–P4 complete and five
implementations green against the 527-entry corpus. A merge commit
rather than a branch head, because an agreement whose references move
is not reproducible: every section number and every "plugin adopted
this" claim below is against that revision.

This pin has now advanced three times, and the second advance is the
instructive one. Step 0 set it to `0ea4c4f` (voxgig/plugin#3). The
`live` status rename (to `56f48e1`) then made this document assert
`live` while the previously pinned revision still said `active` —
precisely the failure the pin exists to prevent, caught in review
rather than by the discipline meant to prevent it. **The obligation
below is standing, not a step that was completed once.**

The third advance spans the five design-touching commits between
`56f48e1` and `153c878` — `fe30bbd`, `3a285cb`, `740e9aa`, `79f4462`,
`950f41c` — and the claims were re-checked rather than assumed, as the
obligation requires. No section was added, removed or renumbered, so
every P§ reference below still resolves. Two of the five are
substantive here. `fe30bbd` corrects P§15.3's section assignments —
auto-tag and `seq` move from the pure `ref` section to the `declare`
driver section, and `pos` assignment to `config` — which leaves the
"`ref` and `config` are pure data" claims intact while sharpening
where each half is pinned. `740e9aa` adds `plugin_inactive` to P§12's
catalog: the error a document-barred `active: false` instance now
fails with, plugin's counterpart to station's
`station_instance_inactive`, which strengthens rather than changes
§2.10's settlement. The other three (`bail`'s null-declines rule,
`hold` reading cardinality rather than the cascade's set, reluctance
as a remembered choice) touch nothing this document asserts. One
erratum runs the other way: P§17.1 repeats the thirteen-in-CI
over-count this document corrects in §2.1 — station's CI matrix runs
eleven ports — and the fix belongs in plugin's next design touch, not
in this pin.

Earlier drafts of this line tracked the working branch
(`claude/voxgig-plugin-architecture-h6cly0`) by URL and went stale
three times in a day, which is the argument for pinning rather than a
theory about it — and the branch itself is gone now, so the URL those
drafts carried dangles; its final head survives as commit `0ea4c4f`,
the pin's own first value. Re-pin when plugin's design advances again,
and re-check the claims rather than assuming they still hold.

Bare **§n** are to [`station-declarative-config.md`](./station-declarative-config.md);
**S§n** to [`station.md`](./station.md).

The ordering matters and is stated once: **plugin is the general
library and station is the first use case, not the specification.**
Where station's need is genuinely general, plugin absorbs it. Where it
is station's own, station keeps it and plugin provides a seam. Several
resolutions below are the second kind, and they are the ones that keep
plugin from quietly becoming station-shaped.


## 0. The settled position

**Adopt the model now. Adopt the library when it has ports.**

Station builds its Stages 2–3 natively against plugin's semantics;
plugin extracts the implementation afterwards. This is P§17.1's plan
rather than its fallback, for the reason in §2.1 below: station had
sixteen written ports when this was settled and plugin had none, and a
library cannot lead its only consumer across sixteen languages. Both
sides have since run the plan — station's Stages 1–3b are merged,
built natively to plugin's semantics, and plugin has five green
implementations with P3's extraction target discharged — which is the
settled position working, not a reason to revisit it.

What that costs is drift between two implementations before they meet,
and the mitigation is the corpus — plugin ships `ref` and `config` as
pure data early, with `lifecycle` and `order` behind P§15.2's driver
contract, and station holds itself to all four.


## 1. Four asks, all landed

Station's original review made four asks. All four are now in plugin's
design (voxgig/plugin#2, #3 and the reconciliation pass):

| ask | outcome |
|---|---|
| add the sixteen-port constraint to P§17.1, and make "station builds natively, plugin extracts" the primary plan | done |
| drop or qualify "closed by construction" — a generic library cannot supply station's credential guarantee | done; stated in both documents as the host's to keep |
| mark the nested-host row contingent on P§17.2 (sdkgen adopting) | done, and sharpened — P§6.5 now separates *native* host-shape (needs sdkgen) from reachability over P3's bridge (does not); see §2.3 |
| add a name-keyed `default` map beside the ref-keyed `instance` map | **settled** — P§9.1, P§9.3; see §3.1 |

Four mechanisms plugin has that station's design lacked, and station
takes regardless of whether it ever depends on the library:

1. **Ordering by constraints and bands (P§7)** replaces §8.4's
   test-first-then-alphabetical default plus an explicit `order` list,
   and gets vacuous satisfaction right (`after: 'test'` in a host with
   no test plugin loads fine — sdkgen's `__after__` behaviour kept).
2. **The `transport` role becomes unnecessary — once features are
   bindings.** Which point a feature binds to carries the role
   structurally: a `chain` binding is in the wrap chain, a `hook`
   binding is not. That holds in plugin's model and *not yet* in
   station's native one, so the seventeen-model sdkgen change is
   deferred rather than deleted — §2.10 has the staging.
3. **Position verification (P§6.6)** generalizes S§3.3's hand-rolled
   wrap-order guard to every plugin in every host.
4. **Runtime deactivation with resource release (P§8)** makes "turn
   debug on for five minutes without a redeploy" possible — §15's
   most-wanted item, which §8.8 currently declares a non-goal.


## 2. The mismatches

§1's asks were all about how P§17.1 *described* station. Reading the
two designs against each other turned up nine more, and these are
about the models themselves. Three were gaps in plugin that adoption
would have turned into defects in station.

### 2.1 The sixteen-port constraint

Station has sixteen written ports, eleven green in CI (the
`.github/workflows/build.yml` matrix; an earlier revision of this
line said thirteen, over-counting the toolchain-gated ports). Plugin
had none when this was settled, and P§16.1 rolls out in four tiers —
five implementations are green as of the current pin (typescript
canonical, go, python, javascript, ruby), which is that rollout under
way rather than a changed premise. A station port cannot depend on a
plugin library absent from its language, so adoption-as-dependency
means waiting for sixteen ports or carrying two instance models in one
repo — the outcome P§17.1 exists to avoid.

The budget compounds it. P§19 is ~1200 lines of core against S§10.1's
1–2k for an *entire* tier-A station port, minus perhaps 300–400 lines
plugin absorbs: net **≈ +800 lines per language, in sixteen
languages**, carried by the only consumer that exists.

**Resolved:** station builds natively to plugin's semantics; plugin's
P3 becomes an extraction from working code rather than a construction
against a design. That is an easier proof obligation, not a harder one,
and it gives plugin's TypeScript port a real consumer on day one.

### 2.2 The credential guarantee inverts

§5.2's guarantee is that station's **grammar** cannot express a
credential: eight known block keys, closed maps, no key that holds a
value. Plugin validates against the **definition's** option shape, and
`apikey` is a declared key in every sdkgen SDK's `optspec`. So

```json
"stripe$test": { "options": { "apikey": "sk-live-abc123" } }
```

is grammatically valid under plugin where station rejects it. The
property does not weaken — it inverts.

**Resolved:** not a defect, and not fixable generically — a plugin
library cannot know which of a definition's options is a credential.
It is the host's to keep. Station keeps §5.2's recursive scan over
every instance's `options` and `feature`, layered over plugin's option
shapes, and both documents now say so, so neither repo assumes the
other is providing it.

### 2.3 Nested hosts — reachable over the bridge, native only after sdkgen

P§6.5 justified nested hosts by station's fleet-wide feature
management, and that mapping holds only once **sdkgen adopts plugin** —
which P§17.2 explicitly declines to commit to. Until then a generated
SDK is not a host: it has `options.feature` and a `FEATURE_CLASS`
table, and station configures features by composing that array (§8).
`inst.host(...)` around one would be a host-shaped object wrapping a
non-host.

**Resolved:** the model stays — it is far cheaper to carry from the
start than to retrofit onto a shipped lifecycle — and P§6.5 now
distinguishes two things it previously ran together. A generated SDK is
not *natively* a host and will not be unless sdkgen adopts. But plugin's
own P3 deliverable is a `FeatureHost` **bridge** that runs an unmodified
sdkgen feature class as a plugin, and the inner host can be the bridge
rather than the SDK — so fleet-wide feature management over a nested
host is reachable at P3 with generated code untouched.

For station that means §8 as written is the present plan and the
nested-host form is a P3 option rather than a post-adoption one. Station
should not build against it until plugin's P3 bridge exists, and should
not assume sdkgen adoption is a precondition for it either.

### 2.4 Per-definition defaults

§3.1 has two block levels: `sdk.<instance>` and **`api.<slug>`**, the
second inherited by every instance of that api. §3.2 uses it for
`api.stripe.policy.hosts` — written once, applying to every stripe
instance, which is what stops a twenty-api file being repetitive.

Plugin's only per-definition slot was the *untagged instance*, because
P§9.3 sourced seneca's shortname inheritance from
`instance.<name>.options`. A project with `stripe$live`, `stripe$test`
and `stripe$eu` and no untagged instance therefore had nowhere to write
what all three share, short of declaring
`"stripe": {"active": false, "options": {…}}` — a defaults carrier
masquerading as an instance, visible as one in `host.list()` and in
every status row built from it.

**Resolved:** P§9.1 gains a **`default` map keyed by name**, beside the
ref-keyed `instance` map. It declares nothing, never appears in
`host.list()`, and is inert for a name with no instances. Station's
`api.<slug>` block maps onto it directly.

This **replaces** seneca's shortname rule rather than sitting beside
it: the untagged instance is now an ordinary instance whose options
apply only to itself. Two sources for one value is the defect class
both repos have spent fixes on.

**The two maps are separate namespaces, not separate spellings** — an
earlier draft of this section got that wrong. An untagged ref *is* a
bare name (P§4 rule 5 canonicalizes `stripe$` and `stripe` to the same
thing), so `api.stripe` and `sdk.stripe` are the same key string in two
maps, and a normalizer that tried to tell them apart lexically would
reject the ordinary single-instance case — which is most of station's
existing config files. The map decides the meaning: the `api` block
configures every instance of that api and declares none; the `sdk`
block declares the untagged instance and configures only it.
Disambiguation is structural, and the corpus pins the case where a name
has both.

The forfeit is familiarity for seneca users.

Settled now rather than deferred because plugin's P1 ships the document
normalizer and requires the `config` corpus green at its exit; a
`default` map introduced after that would invalidate P1's fixtures
rather than extend them.

### 2.5 Merge depth — the two rules could not both be global

**The sharpest disagreement, and neither document had noticed it.**

- §3.3: a block merges **shallow, per key**. §8.3's table makes it
  explicit — `policy` and `options` replace wholesale, scalars replace,
  only `feature` merges two levels down.
- P§9.4: merging is `voxgig/struct`'s `merge` — **deep for maps**,
  index-wise for lists (which plugin corrects to list-replaces).

Both were stated as the settled global rule. Under plugin's, an
overlay's `policy` would deep-merge into the base's rather than replace
it, and an egress allowlist that silently widens because two precedence
levels merged is the exact failure §3.2 designs against. Station cannot
give up that guarantee to adopt a plugin library, and plugin cannot
adopt shallow-everywhere without making composition impossible for the
feature maps that are its whole point.

**Resolved:** neither is global. **The option shape declares the merge
behaviour of each key** — library default deep-for-maps and
replace-for-lists, with `{"$MERGE": "replace"}` and `"append"`
available per key. Station declares `policy` and `options` as `replace`
in its SDK definition shape and §3.3's guarantee is unchanged. The
mechanism already existed in P§9.4 for lists; it generalizes to maps,
and the question is answered in one place that travels with the
definition.

**One boundary is not top-level, and it is station's.** §8.3 merges
`feature` **by feature name, then by option key**, and replaces below
that — so a map-valued feature option like `headers` must replace
wholesale rather than merge key-by-key with the fleet default
underneath it. Marking the top-level `feature` key `replace` would
destroy the composition a fleet default exists for; leaving it deep
would silently retain base keys inside an option an overlay meant to
replace. Neither top-level marker expresses the rule. So `$MERGE` takes
a depth bound — `{"$MERGE": {"deep": 2}}` on `feature` — which states
§8.3 exactly, once, instead of one `replace` marker per feature per
option that would be wrong the first time someone adds a feature.

### 2.6 Defaults were applied at the wrong time

§3.3 states, with a worked case, that block defaults are applied to the
**fully merged** instance and never per layer. An overlay that only
moves a URL must not carry a synthesized `active: true` into the merge,
because it would overwrite a base's `active: false` and silently
re-enable a deliberately disabled integration from a one-key
environment override. §8.3 repeats the rule one level down for
`feature`.

**Plugin's §9 never stated it.** Under `name$tag` the other half of
station's case — a synthesized `api` selecting a *different SDK* —
disappears, because the name is the definition. The re-enable half is
fully live.

**Resolved:** P§9.3 now carries the rule and the case, and the `config`
corpus pins it. Adopted from station unchanged.

### 2.7 The option shape arrived too late

§6.2 records this as a hole in station's own first draft: a factory
table registering a bare constructor is not enough, because station
composes the ordered feature array *for* the constructor and validates
feature config against the api's schema — both **before** construction.
So a factory is `{construct, config}`, and `station.check()` validates
every instance's configuration with no construction at all.

Plugin's catalog had the same hole one layer down: a definition's
option shape was reachable only after `load`. P§9.6 admits the
consequence — lazy instances cannot be resolved in advance. A document
of twenty lazy instances could not be validated without defeating the
laziness that is the reason the `declared` state exists.

**Resolved:** a catalog entry carries the option shape at registration.
`define` takes it alongside the definition, a dynamic resolver may
return it without instantiating, and `host.check()` validates every
*declared* instance from the catalog — forcing an instance up only
where a dynamic resolver cannot supply a shape, and reporting that per
instance rather than silently.

### 2.8 Catalog scope

Station's factory table is **process-global**, station-independent,
shared by every station in the process and populated before any
`Station.open()`. Plugin's catalog is per-host (`host.define`). Two
stations in one process would need two registrations.

**Resolved:** P§10.1 gains a shared catalog — `makeCatalog()` and
`makeHost({catalog})`. The default stays a private per-host catalog;
sharing is the host's decision, and a shared catalog is still only a
map from name to definition, holding no configuration and no instances.

### 2.9 Two mechanisms station needs that plugin did not have

**Reserved refs.** §8.4 reserves `feature.station` outright: station's
adapter is a feature like any other, so a generic document surface
would let a config file set `active: false` on it — switching off the
component reading the file — and §3.3's precedence puts a document
value *above* what station passes at construction. A configuration
surface that can disable the thing reading it is not a surface, it is a
trap. Plugin had no notion of a ref a document may not touch, so
adoption would have reopened it.

*Resolved:* `makeHost({reserved: ['station']})` and
`plugin_ref_reserved` (P§9.1), all-or-nothing per name in v1.

**Pinned positions.** §8.4 rejects an `order` that moves station away
from immediately-after-base — S§3.3 pins that mechanism. P§6.6's
`inst.position()` lets a binding *verify* where it landed, which is an
assertion after the fact, not enforcement: it tells a plugin it was
misplaced rather than making the misplacement inexpressible.

*Resolved:* `host.point('request', {pin: {station: 'innermost'}})` and
`plugin_order_pinned` (P§7). The vocabulary is positional rather than
ordinal because the two read in opposite directions — P§6.2 composes a
chain with the *first* binding outermost, so a "first" pin would put
every wrapper between station's adapter and the base. Constraints and bands are negotiable — they are what plugins and
documents ask for. A pin is the host stating a structural invariant of
its own architecture, and must not lose a tie to a document.

### 2.10 Two smaller ones, recorded rather than resolved

- **`transport: 'base'` had no plugin expression, and deleting the
  role is staged rather than immediate.** A chain's base is host-owned
  (P§6.2), so a plugin cannot replace it. The mapping is that a
  substituting plugin — sdkgen's `test`, which assigns
  `ctx.utility.fetcher` outright — binds as the **innermost link and
  declines to call `next`**, which is behaviourally identical and needs
  no declared role. P§6.2 now says so.

  **But the role is only structural once features are bindings.** In
  station's native Stage 3b — which is what station builds now, and for
  as long as it does not depend on the library — a generated SDK's
  features are still an ordered array composed from `FEATURE_CLASS`,
  with no `chain` or `hook` point to read a role off. §8.4 is explicit
  that the roles cannot be inferred: the obvious signal, an empty
  `hook: {}`, is wrong for `station` itself, which both wraps *and*
  dispatches hooks. Dropping `transport` now would leave Stage 3b
  unable to classify features or validate an explicit `order` at all.

  So: **keep `transport` for the native phase, and delete it when
  features become bindings** — over P3's `FeatureHost` bridge (§2.3) or
  after sdkgen adopts. The seventeen-model sdkgen change is deferred to
  that point, not cancelled, and §8.4 is amended to say so rather than
  to strike the field.
- **`active` was overloaded. Now fixed: plugin's lifecycle status is
  `live`.** The framing here was itself part of the problem — calling
  it "overloaded in both directions" counted station's `active: false`
  (*barred from running*) and plugin's document key `active` (*may this
  run*) as two collisions when they are **one predicate in two
  polarities**. The real clash was the key against plugin's runtime
  **status**, and it was substantive: `active: true` with
  `start: "lazy"` sits at `declared` indefinitely.

  The earlier conclusion — left as-is, because renaming costs more
  churn than the ambiguity — was reversed once the two sides were
  costed separately. `active`-as-key is shipped across station's 17
  ports, its `station.json` documents, and ~23 sdkgen template trees;
  the status was shipped nowhere. So the status is `live`
  (`declared → loaded → pending → live`), the key keeps `active` in
  both repos, and `activate()`/`deactivate()` are unchanged. Station's
  `instances()` already reported `{active, live}` for this split, so
  its boolean `live` is now exactly plugin's `status == "live"` — which
  also removes the failure mode this entry warned about, a port
  conflating them into a config that looks like it works.


## 3. The joint model

The parts that must read identically in both repos, because they are
where two implementations would otherwise drift.

### 3.1 Identity and the two maps

One identity, `name$tag`, where **the name is always the definition**.
Station's instance keys become refs — `voxgig-solardemo`, `stripe$test`,
`github$ent` — and `sdk.<n>.api` is deleted, because the name before
`$` is the api.

Two maps, disjoint key spaces:

| station writes | plugin sees | keyed by | declares an instance? |
|---|---|---|---|
| `sdk.<ref>` | `instance.<ref>` | ref | yes |
| `api.<slug>` | `default.<name>` | name | no |

**Station keeps its own words.** P§9.1's key renaming —
`makeHost({keys: {instance: 'sdk', default: 'api'}})` — is the
mechanism, and it is the point rather than a concession: `sdk` and
`api` read correctly in a `station.json`, and `instance` and `default`
read correctly in a library that knows nothing about SDKs. The shape
underneath is identical, so the corpus tests it once.

### 3.2 One precedence ladder

Station's §3.3 and plugin's P§9.3 are the same ladder, and the rule
that orders the middle of it is **profile specificity outranks
definition specificity**:

| | station | plugin |
|---|---|---|
| 3 | base profile — `api` block | document base — `default.<name>` |
| 4 | base profile — `sdk` block | document base — `instance.<ref>` |
| 5 | overlay — `api` block | profile overlay — `default.<name>` |
| 6 | overlay — `sdk` block | profile overlay — `instance.<ref>` |

A `prod` api-level `base` beats a `default`-profile instance-level
`base`, because that is what an environment overlay is for; within one
profile the instance beats the api default, because that is what an
instance is for. Plugin previously said only that inheritance "applies
at levels 2–4", which does not decide this; it now states the ladder.

Two rules make that order safe, and a port that skips either
reintroduces a real defect:

- **Defaults after the merge, never per layer** (§2.6).
- **Merge depth from the option shape, not from the library** (§2.5).

### 3.3 What station keeps as its own

Not everything general-looking belongs in a general library, and these
stay station's:

- the §5.2 credential scan and the sekreto `validname()` name/value
  rule (§2.2);
- the descriptor, the placeholder, the registry and the event stream —
  none of which have a plugin analogue and none of which should;
- `feature.station` being reserved *by name*: plugin supplies the
  mechanism, station chooses the name;
- the eight-key block grammar. Plugin validates an instance's options
  against a definition's shape; station's grammar is closed
  independently of what any definition permits.


## 4. What each repo does next

**station** — unchanged from the original recommendation except where
§2 settles a question it left open. Items 1–5 have since landed with
Stages 1–3b ([`station-and-plugin-plan.md`](./station-and-plugin-plan.md)
tracks the state); item 6 stays deliberately deferred:

1. **Stage 1 proceeds immediately.** Grammar, shape file, normalizer,
   corpus sections — station's own data, dependent on nothing here.
2. **Re-key Stage 2 to `name$tag` refs.** Cheaper before Stage 2 is
   written than after, and right on its own merits. `sdk` keys become
   refs; `sdk.<n>.api` is deleted; §6.1's `create()` uses `tag: '?'`
   auto-tagging in place of `name#<n>`; the `api` block stays and is
   now defined as plugin's `default` map (§3.1).
3. **Build Stages 2–3 natively, to plugin's semantics** — state names,
   ref grammar, the §3.2 ladder, list-replace, vacuous constraint
   satisfaction — written so plugin can extract them.
4. **Adopt P§7's ordering in §8.4 now** — constraints and bands,
   vacuous satisfaction, and station's pinned wrap position expressed
   as a pin rather than a validation special case. **Keep `transport`
   while the native implementation needs it** (§2.10): the role stops
   being data and starts being structure only when features are
   bindings, so the seventeen-model sdkgen change is deferred to the
   bridge rather than dropped now.
5. **Declare `policy` and `options` as `$MERGE: replace`** in the SDK
   definition shape, which is what keeps §3.3's guarantee under
   plugin's merge (§2.5).
6. **Revisit the dependency when plugin reaches tier 3** — most ports
   have something to depend on, sdkgen's P§17.2 decision is likelier to
   have landed, and the trade is being made for two consumers.

**plugin** — items 1 and 2 are discharged (C1 and C2 shipped with
voxgig/plugin#7, leading P1 rather than trailing it), and item 3
holds: the P3.2 bridge is in, and P3.1's extraction now has a working
station to run against:

1. Ship `ref` and `config` corpus sections early as pure data, and
   `lifecycle` and `order` with P§15.2's driver contract in draft.
2. Hold P1's configuration work to the settled `default` map, the
   ten-level ladder, defaults-after-merge and shape-declared merge
   depth — all four are P1 fixtures, not P2 additions.
3. Keep P3 as extraction against a working station.


## 5. Still open

- **Does sdkgen adopt plugin?** (P§17.2.) Everything nested-host waits
  on it, and it carries a propagation cost across 23 template trees.
  Not station's decision.
- **The second consumer.** §2.1's arithmetic only pays off if plugin is
  used by more than one library. sdkgen features are the candidate and
  the bet is probably right, but station should not carry the cost of
  proving it in sixteen languages before the second consumer exists.
- **`active` overloading** (§2.10) — **fixed**: the status is `live`, the config key stays `active`.
