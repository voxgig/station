# Plan: completing voxgig/plugin and voxgig/station

Status: **plan** (2026-08-22). Companion to
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

Worth stating plainly, because both plans read as though their repo has
a floor under it and only one does.

| | state |
|---|---|
| **voxgig/plugin** | **Three files** — `LICENSE`, `README.md`, `docs/design/plugin.md`. No code, no `Makefile`, no `spec/`, no ports. P0 has not started. |
| plugin's design | **Not on `main`.** It lives on `claude/voxgig-plugin-architecture-h6cly0`, which has never merged; voxgig/plugin#3 targets that branch, not `main`. |
| **voxgig/station** | **Sixteen written ports**, thirteen green in CI, `spec/station.json` in place. Stage 1 has not started; everything before it has. |
| station's design | On `main`. voxgig/station#6 adds the reconciliation and the ref migration. |

So the asymmetry driving the whole reconciliation is also the starting
condition: **station is a working system and plugin is a document.**


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
     |         <---- M2: station is the proof host ---------|
   P3 proof + bridge                                 Stage 3b features
     |                    M3: bridge enables nested hosts -->|
   P3b capabilities                                  Stage 4 generator
     |                                                      |
   P4 go + python <===== M4: pair these, see §5 =====> Stage 5 ports
     |                                                      |
   P5 tier 3 ------------ dependency decision ---------> (revisit)
     |
   P6 tier 4
```

Track S never blocks on Track P for its *own* correctness. It consumes
Track P's corpus to stay honest, and it hands Track P a real host at M2.


## 2. Step 0 — land the designs

Neither track can start cleanly while the agreement is unmerged, and
plugin's cannot start at all while its design is on a branch that `main`
has never seen.

1. **voxgig/plugin#3** merges into
   `claude/voxgig-plugin-architecture-h6cly0`.
2. **That branch merges into plugin's `main`.** This is the missing
   step, and it is a prerequisite for P0 rather than a tidy-up: P0
   creates a repository skeleton around a design document that is not
   yet in the repository's mainline.
3. **voxgig/station#6** merges into station's `main`.
4. **Re-pin** `station-and-plugin.md`'s revision reference to plugin's
   merge commit. The branch-head pin it carries now is a placeholder
   that went stale within one commit of being written.

*Exit:* both designs on `main` in their own repos, and the
reconciliation pinned to a commit that will not move.


## 3. What each repo owes the other

Four obligations, and they are the whole cross-repo contract. Everything
else in both plans is internal.

| # | owed by | to | what | due |
|---|---|---|---|---|
| **C1** | plugin | station | `ref` and `config` corpus sections, as pure data | **before station Stage 2** — earlier than P1's exit |
| **C2** | plugin | station | `lifecycle` and `order` corpus sections **plus** the draft language-neutral driver contract in `DOCS.md` (P§15.2's probes, command vocabulary, canonical observable) | **before P1's exit** |
| **C3** | station | plugin | a working Stages 2–3 implementation to extract from, and its own suites as the bar | **before plugin P3** |
| **C4** | station | plugin | conformance: station's native implementation runs C1's and C2's corpus sections against itself, and reports divergence as a plugin issue rather than absorbing it | **continuous from Stage 2** |

C1 and C2 are the reason plugin's P1 has an obligation that looks
external to it. C4 is the only thing preventing the drift the
build-natively decision buys — and it is worth being blunt that it is
also the easiest of the four to quietly skip, because nothing fails when
a team stops running someone else's corpus.

**C1 is the tightest and is easy to miss.** Station's Stage 1 lands the
grammar and Stage 2 lands the identity change; if plugin's `ref` corpus
arrives after Stage 2, station has already written ref parsing and the
corpus becomes a retrofit audit rather than a contract. `ref` and
`config` are pure data (P§15.3) — the files *are* the deliverable, so
this is cheap for plugin and only cheap if it is early.


## 4. The sequence

### 4.1 Track P — plugin

| phase | gated on | notes |
|---|---|---|
| **P0** skeleton | Step 0 | Layout, `Makefile`, `spec/def/plugin-spec.aontu`, `build-spec.js`, empty `check_parity.py`. Exit: `make spec` / `make spec-check` on an empty corpus. |
| **P1** tracer bullet (ts) | P0 | Ships **C1 and C2** as its first deliverables, not its last — see §5.2. Also the four P1 configuration items the reconciliation pinned: the `default` map, the ten-level ladder, defaults-after-merge, and shape-declared merge depth including `{"deep": N}`. |
| **P2** canonical | P1 | Dynamic resolution, `apply()`, exports, position verification, remaining corpus sections; `DOCS.md` completed from P1's draft. |
| **P3** proof + bridge | P2, **C3** | Extraction against a working station, plus the `FeatureHost` bridge. |
| **P3b** capabilities | P3 | Deliberately after the station proof: station uses none of §11, and this is the largest tranche in the library. |
| **P4** go + python | P3b | **May change the canonical — that is why it precedes P5.** See §5. |
| **P5** tier 3 (14 langs) | P4 | Model changes now cost ~15 ports. Dependency decision reopens here. |
| **P6** tier 4 (6 langs) | P5 | Plus the sdkgen `plugin` feature package question. |

### 4.2 Track S — station

| stage | gated on | notes |
|---|---|---|
| **Stage 1** grammar | Step 0 | Independent of plugin entirely. Note the §3.3 rewrite: the api is now the ref's prefix, so the "api resolved before its block is read" phasing is *gone*, not reordered. |
| **Stage 2** instances | Stage 1, **C1** | The `name$tag` re-key. Runs plugin's `ref` corpus against station's own parser from the first commit. |
| **Stage 3** front door | Stage 2 | Factory table with `{construct, config}`, loader, `sdk()`/`create()`/`instances()`/`check()`. |
| **Stage 3b** features | Stage 3, **C2** | Three-level merge including the `{"deep": 2}` boundary; `transport` **retained** here (§2.10 of the reconciliation) because features are not yet bindings. |
| **Stage 4** generator | Stage 3b | sdkgen-station: `instance` option, ts/js self-registration. |
| **Stage 5** ports | Stage 4, **and see §5** | Sixteen languages. This is where the plan's one real disagreement with the per-repo plans lives. |

### 4.3 The meeting points

- **M1 (plugin P1 → station Stage 2)** — C1 and C2. Data flowing one way.
- **M2 (station Stage 3 → plugin P3)** — station becomes plugin's proof
  host. Plugin's P3 bar is station's own integration test: twenty-plus
  declared instances, none constructed at `open()`, two instances of one
  api with distinct placeholders, and a fleet-wide feature default
  reaching an instance that never mentions it.
- **M3 (plugin P3 → station's nested-host option)** — the bridge makes
  fleet-wide feature management over a nested host reachable with
  generated code untouched. Station should not build against it before
  P3, and should not wait for sdkgen adoption either.
- **M4 (plugin P4 ↔ station Stage 5)** — the pairing argued in §5.


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
synchronisation point rather than a coincidence of ordering.


## 6. Decisions, and what each one gates

| decision | owner | gates | current state |
|---|---|---|---|
| Does **sdkgen** adopt plugin? (P§17.2) | sdkgen | nested hosts *natively*; deletion of `transport`; the seventeen-model change | **open** — explicitly uncommitted; carries a propagation cost across 23 template trees |
| Does **station take the library as a dependency**? | station | Stage 5's remaining ports; the +800-lines-per-port trade | **deferred to plugin tier 3 (P5)**, by design |
| Is **`active`** renamed? | plugin | P1's public API and its corpus fixtures | **open, and undated** — see below |
| Does **P3b move earlier**? | plugin | only if P3 turns up a station requirement needing capabilities | conditional on a finding, not a plan |

**`active` needs a date and does not have one.** It is overloaded three
ways: station's `active: false` (*barred from running*), plugin's
`active` lifecycle **status** (*bindings live, resources held*), and
plugin's own document key `active` (*may this run*). Both documents
record the collision; neither schedules a fix. It is an API name in
P1's surface and in the `config` and `lifecycle` corpus sections, so
renaming after P1 costs fixtures in every port that exists by then.

**Recommendation: settle it inside P1, or close it explicitly as
won't-fix.** An open naming question with no deadline attached to a
name that appears in two corpus sections is the shape of a decision that
gets made by default.


## 7. Risks

| risk | why it is real | mitigation |
|---|---|---|
| **Silent drift** between station's native implementation and plugin's canonical | Nothing fails when a team stops running another repo's corpus. C4 has no enforcement. | Make plugin's `ref`/`config`/`lifecycle`/`order` corpus part of station's own CI from Stage 2, so drift is red rather than unnoticed |
| **C1 arrives late** | It is plugin's first deliverable and plugin has not started P0 | Treat C1 as P0's exit criterion rather than P1's, if P0 slips |
| **P4 changes the model after station has ported** | §5.1 | Hold Stage 5 after ts/js, or budget the migration explicitly |
| **Plugin is a document and station is a system** | Every estimate on Track P is an estimate about work that has not begun | Do not sequence station work behind Track P except where §3's contracts require it |
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
register gains **`contracts.md`**, carrying §3's four obligations and
nothing else — what is owed, by whom, its state, and the commit that
discharged it. Four rows. It exists so that C1 through C4 have somewhere
to be visibly outstanding, which is the only property that makes a
cross-repo obligation different from a good intention.
