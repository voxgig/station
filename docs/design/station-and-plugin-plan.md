# Plan: completing voxgig/plugin and voxgig/station

Status: **plan** (2026-08-22; state refreshed 2026-08-24). Companion to
[`station-and-plugin.md`](./station-and-plugin.md), which settles *what*
the two designs agree; this settles *when*, and in which repo.

It does not replace either per-repo plan. Plugin's phases **P0–P6**
(P§18) and station's **Stages 1–5** (§12) stay authoritative for their
own contents. What neither can state, because each is written from
inside one repo, is the order the two must run in and what each owes
the other. That is this document's only job.

**P§n** are to plugin's design at the revision pinned in
`station-and-plugin.md`; bare **§n** to
[`station-declarative-config.md`](./station-declarative-config.md);
**S§n** to [`station.md`](./station.md).

No calendar dates appear here. Every ordering below is a dependency, not
a schedule, because the dependencies are knowable now and the dates are
not.


## 0. Where things actually stand

Refreshed 2026-08-24. This section originally recorded an asymmetry —
station a working system, plugin a document with a build around it —
and that asymmetry has since closed faster than either plan budgeted
for.

| | state |
|---|---|
| **voxgig/plugin** | **P0–P4 complete; P5 under way, two of fourteen.** The corpus is 527 entries across all 19 sections P§15.3 names, and five implementations pass every one — `typescript/` (canonical), `go/`, `python/`, `javascript/`, `ruby/` (voxgig/plugin#15; `main` = `153c878`). The one open P3 item is **P3.1**, the extraction proof against station — runnable now that C3 is discharged. |
| plugin's design | On `main`, pinned by `station-and-plugin.md` at `153c878`. |
| **voxgig/station** | **Sixteen written ports, eleven green in CI.** Stages 1, 2, 3 and 3b are merged (voxgig/station#8–#10; `main` = `2036cd6`). Stage 4 is **partial** — the feature model declares `transport` and `instance`, while adapter self-registration is blocked on sdkgen's injection machinery. Stage 5's grammar crossing is done for all eleven CI ports; the declarative front door beyond TypeScript, and the five toolchain-gated ports (lua, dart, elixir, csharp, swift) still on the pre-rename grammar, are the remaining tranches. |
| station's design | On `main`, with `station.md` carrying the §16 amendments (applied 2026-08-24). |

So the starting condition has been replaced by the couplings this
document exists to name: **both tracks are systems now**, and what is
open between them is P3.1's extraction and the C4 conformance wiring
(§3).


## 1. Shape: two tracks, four meeting points

The reconciliation's core decision — station builds natively, plugin
extracts — means the two tracks are *mostly independent*, which is the
point. They are not fully independent, and the couplings are few enough
to name:

```
Step 0   land the designs
           |
     ------+------------------------------------------------
     |                                                      |
  TRACK P (plugin)                              TRACK S (station)
     |                                                      |
   P0 skeleton                                       Stage 1 grammar
     |                                                      |
   P1 tracer bullet ---- M1: ref + config corpus ----> Stage 2 instances
     |                                                      |
   P2 canonical                                       Stage 3 front door
     |                                                      |
     |                                                Stage 3b features
     |                                                      |
     |         <---- M2: station is the proof host ---------|
   P3 proof + bridge                                        |
     |                    M3: bridge enables nested hosts -->|
   P3b capabilities                                  Stage 4 generator
     |                                                      |
     |                                                Stage 5: ts, js
     |                                                      |
   P4 go + python <===== M4: pair these, see §5 =====> Stage 5: py, go
     |                                                      |
   P5 tier 3                                         Stage 5: the rest
     |                                                      |
     +------------- dependency decision (§6) -------> (a later migration,
     |                                                 not a gate here)
     |
   P6 tier 4
```

Track S never blocks on Track P for its *own* correctness. It consumes
Track P's corpus to stay honest, and it hands Track P a real host at M2.


## 2. Step 0 — land the designs

**Complete.** Neither track could start cleanly while the agreement was
unmerged, and plugin's could not start at all while its design sat on a
branch `main` had never seen.

1. ~~**voxgig/plugin#3** merges into
   `claude/voxgig-plugin-architecture-h6cly0`.~~ Done (the working
   branch is itself gone now; its head survives as `0ea4c4f`).
2. ~~**That branch merges into plugin's `main`.**~~ Done, as
   voxgig/plugin#4 — the step that was missing, and a prerequisite for
   P0 rather than a tidy-up.
3. ~~**voxgig/station#6** merges into station's `main`.~~ Done.
4. ~~**Re-pin** `station-and-plugin.md`'s revision reference to
   plugin's merge commit.~~ Done, and **already advanced once**: Step 0
   pinned `0ea4c4f` (an ancestor of plugin's `main`, replacing a
   branch-head placeholder that went stale within one commit of being
   written), and the `live` rename moved it to `56f48e1`
   (voxgig/plugin#6's merge commit). The pin is not a one-time step —
   the instruction in `station-and-plugin.md` is to advance it whenever
   plugin's design does, and the first time that came due it was caught
   in review rather than remembered.

*Exit, met:* both designs on `main` in their own repos, and the
reconciliation pinned to a commit that will not move.


## 3. What each repo owes the other

Four obligations, and they are the whole cross-repo contract. Everything
else in both plans is internal.

| # | owed by | to | what | due |
|---|---|---|---|---|
| **C1** | plugin | station | `ref` and `config` corpus sections, as pure data | **before station Stage 2** — earlier than P1's exit |
| **C2** | plugin | station | `lifecycle` and `order` corpus sections **plus** the draft language-neutral driver contract in `DOCS.md` (P§15.2's probes, command vocabulary, canonical observable) | **before P1's exit** |
| **C3** | station | plugin | a working Stages 2–**3b** implementation to extract from, and its own suites as the bar | **before plugin P3** |
| **C4a** | station | plugin | conformance on the pure sections: station runs C1's `ref` and `config` against its own implementation, and reports divergence as a plugin issue rather than absorbing it | **continuous from Stage 2** |
| **C4b** | station | plugin | conformance on the driver sections: the same for C2's `lifecycle` and `order` | **continuous from Stage 3b** |

State, 2026-08-24: **C1 and C2 are discharged** — both shipped with
voxgig/plugin#7, leading P1's exit as required — and **C3 is
discharged** by station's Stages 2–3b (voxgig/station#9). **C4a and
C4b are the open pair.** Station's Stages 2 and 3b landed without
wiring plugin's corpus into their suites, so the conformance harness
is being added to station's test suite now, in the same change set as
this refresh — late against "continuous from Stage 2", and said out
loud rather than papered over, because §7 names this as exactly the
obligation nothing fails for skipping.

C1 and C2 are the reason plugin's P1 has an obligation that looks
external to it. C4 is split because the two halves become runnable at
different moments: `ref` and `config` are exercised by Stage 2's
identity change and Stage 1's grammar, while `lifecycle` and `order`
describe feature behaviour station does not implement until Stage 3b.
Asking Stage 2 to claim conformance to all four would either block it
on C2 — contradicting its own gate — or have it assert conformance to
sections it cannot execute, which is worse than not claiming it.

Together they are the only thing preventing the drift the
build-natively decision buys — and it is worth being blunt that it is
also the easiest of the four to quietly skip, because nothing fails when
a team stops running someone else's corpus.

**C1 is the tightest and is easy to miss.** Station's Stage 1 lands the
grammar and Stage 2 lands the identity change; if plugin's `ref` corpus
arrives after Stage 2, station has already written ref parsing and the
corpus becomes a retrofit audit rather than a contract. `ref` and
`config` are pure data (P§15.3) — the files *are* the deliverable, so
this is cheap for plugin and only cheap if it is early. (It was: C1
led P1. The miss moved one obligation down — the *wiring*, C4a, is
what lagged, and the retrofit-audit cost this paragraph warns about is
the cost now being paid.)


## 4. The sequence

### 4.1 Track P — plugin

P0 through P4 are complete and P5 has its first two ports in
(javascript, ruby); P3.1 — the extraction proof — is the one open P3
item. The gating below stays as written, because it is dependencies
rather than dates, and it held:

| phase | gated on | notes |
|---|---|---|
| **P0** skeleton | Step 0 | Layout, `Makefile`, `spec/def/plugin-spec.aontu`, `build-spec.js`, empty `check_parity.py`. Exit: `make spec` / `make spec-check` on an empty corpus. |
| **P1** tracer bullet (ts) | P0 | Ships **C1 and C2** as its first deliverables, not its last — see §5.2. Also the four P1 configuration items the reconciliation pinned: the `default` map, the ten-level ladder, defaults-after-merge, and shape-declared merge depth including `{"deep": N}`. |
| **P2** canonical | P1 | Dynamic resolution, `apply()`, exports, position verification, remaining corpus sections; `DOCS.md` completed from P1's draft. |
| **P3** proof + bridge | P2, **C3** | Extraction against a working station, plus the `FeatureHost` bridge. Gated on station's Stage **3b**, not Stage 3: P3's bar includes a fleet-wide feature default reaching an instance that never mentions it, and feature management is Stage 3b's deliverable. Gating on Stage 3 would start P3 with its own acceptance test unavailable. |
| **P3b** capabilities | P3 | Deliberately after the station proof: station uses none of §11, and this is the largest tranche in the library. |
| **P4** go + python | P3b | **May change the canonical — that is why it precedes P5.** See §5. |
| **P5** tier 3 (14 langs) | P4 | Model changes now cost ~15 ports. Dependency decision reopens here. |
| **P6** tier 4 (6 langs) | P5 | Plus the sdkgen `plugin` feature package question. |

### 4.2 Track S — station

Stages 1–3b are merged, Stage 4 is partial (blocked on sdkgen's
injection machinery), and Stage 5's grammar crossing covers all eleven
CI ports:

| stage | gated on | notes |
|---|---|---|
| **Stage 1** grammar | Step 0 | Independent of plugin entirely. Note the §3.3 rewrite: the api is now the ref's prefix, so the "api resolved before its block is read" phasing is *gone*, not reordered. |
| **Stage 2** instances | Stage 1, **C1** | The `name$tag` re-key. The intent here was to run plugin's `ref` corpus against station's own parser from the first commit; the stage landed without that wiring, and the C4a/C4b harness is being added to station's suite now, in this change set (§3). |
| **Stage 3** front door | Stage 2 | Factory table with `{construct, config}`, loader, `sdk()`/`create()`/`instances()`/`check()`. |
| **Stage 3b** features | Stage 3, **C2** | Three-level merge including the `{"deep": 2}` boundary; `transport` **retained** here (§2.10 of the reconciliation) because features are not yet bindings. |
| **Stage 4** generator | Stage 3b | sdkgen-station: `instance` option, ts/js self-registration. |
| **Stage 5** ports | Stage 4; the fourteen beyond ts/js also on **P4** (§5.1) | Sixteen languages, in three tranches: ts/js after Stage 4, py/go paired with P4 (§5.2), the rest after P4 settles. Gated on P4 and **not** on the dependency decision — that is a later migration question (§6), and treating it as a gate here would stall the rollout behind a decision deliberately deferred to P5. |

### 4.3 The meeting points

- **M1 (plugin P1 → station Stage 2)** — C1 and C2. Data flowing one
  way. **Done** (voxgig/plugin#7): both sections shipped as P1's first
  deliverables, before station's Stage 2 wrote its ref parsing.
- **M2 (station Stage 3 → plugin P3)** — station becomes plugin's proof
  host. Plugin's P3 bar is station's own integration test: twenty-plus
  declared instances, none constructed at `open()`, two instances of one
  api with distinct placeholders, and a fleet-wide feature default
  reaching an instance that never mentions it. **The station half is
  done** — Stages 2–3b merged as voxgig/station#9, so every element of
  that bar exists on station's `main` — and **plugin's P3.1 extraction
  is the pending half**, runnable now.
- **M3 (plugin P3 → station's nested-host option)** — the bridge makes
  fleet-wide feature management over a nested host reachable with
  generated code untouched. The bridge exists (plugin's P3.2 runs an
  unmodified sdkgen feature class as a plugin), so the nested-host form
  is available to station when it wants it; sdkgen adoption remains
  not-a-precondition.
- **M4 (plugin P4 ↔ station Stage 5)** — the pairing argued in §5.
  **Its moment has passed**: P4 completed (go and python) in the same
  window station's Stage 5 crossed the eleven CI ports, so the hold
  §5.1 argues for is discharged, and P4's findings landed as canonical
  fixes rather than as changes to sixteen shipped ports — the outcome
  the pairing existed to buy.


## 5. Two conclusions neither per-repo plan reaches

### 5.1 Station's broad port rollout should follow plugin's P4

P§18.1 states that **P4 may change the canonical, and that this is the
point of running it before P5** — go and python are expected to find
every TypeScript-shaped assumption in the model.

Both plans are silent on what that means for station, and it matters,
because under the reconciliation station's ports are written *to
plugin's semantics* natively. If station completes Stage 5 across
sixteen languages before P4 has settled the model, a P4 finding lands as
a change to sixteen working ports rather than to one design.

The asymmetry is worth seeing clearly: **plugin scheduled P4 early to
make model changes cheap, and station porting first makes them
expensive again — in the other repo.**

So: **station's Stage 5 should stop after ts and js until plugin's P4
has settled the canonical.** Those two are the reference implementations
and would carry any model change cheaply. The other fourteen wait on a
phase that exists precisely to shake the model out.

This is a recommendation with a real cost — it serializes station's port
rollout behind a plugin phase that is four phases out, in a repo that
today has three files. If that is unacceptable, the honest alternative
is to accept divergence and budget for a migration pass across sixteen
ports after P4, and to say so rather than discovering it.

**Outcome (2026-08-24): the hold never had to bind.** P4 completed in
the same window as station's Stage-5 grammar crossing, so the eleven
CI ports crossed against a canonical P4 had already shaken out. What
remains of Stage 5 — the declarative front door beyond TypeScript, and
the five toolchain-gated ports — proceeds with no P4 finding hanging
over it.

### 5.2 Pair plugin's P4 with station's py and go ports

Station's Stage 5 order is `js`, `py`, then `go`, `java`. Plugin's P4 is
**go and python**. The same two languages, for the same reason — they
are where a TypeScript-shaped model breaks.

Running them together means one team finds each divergence once, in two
implementations that are supposed to agree, with the corpus between them
as the arbiter. Running them apart means finding the same divergence
twice, months apart, and having to work out whether the second one is
the same bug.

This is the strongest single argument for M4 being a genuine
synchronisation point rather than a coincidence of ordering. In the
event the two ran in one window — plugin's P4 and station's crossing
both merged 2026-08-23 — which is the pairing this section asked for,
delivered by the schedules collapsing together rather than by
coordination.


## 6. Decisions, and what each one gates

| decision | owner | gates | current state |
|---|---|---|---|
| Does **sdkgen** adopt plugin? (P§17.2) | sdkgen | nested hosts *natively*; deletion of `transport`; the seventeen-model change | **open** — explicitly uncommitted; carries a propagation cost across 23 template trees |
| Does **station take the library as a dependency**? | station | **not** the native port rollout — that resumed after P4 (§5.1). This decides only whether ports later *replace* their native implementation with the library, and the +800-lines-per-port trade | **deferred to plugin tier 3 (P5)**, by design, and explicitly **non-blocking** for native ports. P5 has begun, so the reopening point has arrived — nothing forces the answer, and the second-consumer condition (§7) still governs it |
| Is **`active`** renamed? | plugin | P1's public API and its corpus fixtures | **settled** — the status is `live`, the key stays `active`; see below |
| Does **P3b move earlier**? | plugin | only if P3 turns up a station requirement needing capabilities | **overtaken** — P3b has landed (plugin's §11 complete) ahead of P3.1's extraction run, so the question closed itself |

**`active` is settled — and it was two concepts, not the three both
documents recorded.** Station's `active: false` (*barred from running*)
and plugin's document key `active` (*may this run*) are one predicate
in two polarities. Counting them separately made the problem look
harder than it was and obscured which way the fix runs.

The genuine clash was between that key and plugin's lifecycle
**status**, and it was real rather than cosmetic: `active: true` with
`start: "lazy"` sits at `declared` indefinitely, so one word answered
two questions whose answers routinely differ.

**Resolution: plugin's lifecycle status is `live`; the document key
stays `active` in both repos.** Decided on cost — `active`-as-key was
already shipped across station's 17 ports, its `station.json`
documents, and sdkgen's `options.feature.<name>.active` in ~23 language
template trees, while the status was unshipped: no code, and no
`lifecycle` corpus section. The verbs `activate()`/`deactivate()` are
unchanged. Station's `instances()` already reported `{active, live}`
for exactly this split, so its boolean `live` is now precisely plugin's
`status == "live"`.

Landed in plugin's design, `README.md` and `AGENTS.md`, and in
station's `station-declarative-config.md`, **before P1 wrote a
fixture** — which was the whole point of dating it.


## 7. Risks

| risk | why it is real | mitigation |
|---|---|---|
| **Silent drift** between station's native implementation and plugin's canonical | Nothing fails when a team stops running another repo's corpus. C4 has no enforcement — and Stages 2–3b landing without the wiring proved it. | Make plugin's `ref`/`config`/`lifecycle`/`order` corpus part of station's own CI — the C4 harness being wired now (§3). Until it is green, this is the plan's one live drift risk. |
| **C1 arrives late** | *Retired*: C1 led P1 (voxgig/plugin#7), as the guard required | — |
| **P4 changes the model after station has ported** | *Retired*: P4 completed alongside station's grammar crossing (§4.3 M4), and its findings landed in the canonical before Stage 5's later tranches | — |
| **Plugin is a document and station is a system** | *Closed*: five implementations pass the 527-entry corpus, so estimates past P1 are about work that exists | — |
| **The second consumer never appears** | The +800-lines-per-port trade only pays with more than one consumer, and sdkgen's adoption is uncommitted | The dependency decision is already deferred to P5; keep it deferred rather than assuming |

The last one deserves its own sentence, because it is the risk that
invalidates the plan rather than delaying it: **if sdkgen never adopts
plugin, station is a sixteen-language library carrying a generic
abstraction for a single consumer.** The reconciliation's answer is that
station should not pay that cost until a second consumer exists, and
this plan keeps that answer by never putting station's ports behind
plugin's.


## 8. Tracking

P§18.1 already requires that each phase update a plan register in the
same change that lands the work — omni's `doc/plan/` discipline
(`adoption.md`, `progress.md`, `status.md`, `handover.md`).

Extend it by one file rather than inventing a second system: the
register gains **`contracts.md`** — in place now, as plugin's
`doc/plan/contracts.md` — carrying §3's four obligations and
nothing else — what is owed, by whom, its state, and the commit that
discharged it. Four rows. It exists so that C1 through C4 have somewhere
to be visibly outstanding, which is the only property that makes a
cross-repo obligation different from a good intention.
