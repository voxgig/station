# The plan

Status: **plan** (2026-11-10). The live per-item state is
[`progress.md`](progress.md), what station needs from other repositories
is [`upstream.md`](upstream.md), and what is in flight right now is
[`status.md`](status.md).

This document does not replace the design. Phases 1–3
([`station.md`](../design/station.md) §17) and Stages 1–5
([`station-declarative-config.md`](../design/station-declarative-config.md)
§12) stay authoritative for *what* is built. This says in what order the
remaining work runs, what each piece is gated on, and when it counts as
finished.

No calendar dates appear below. Every ordering is a dependency.


## 1. The goal

Station is one control surface for an application's outbound
integrations: the place where they are configured, credentialed,
observed, policed and debugged, for a developer and for an AI agent.

The design's own bar for "it works" is Phase 1's exit: **the §11
quickstarts and the §12 agent transcript are both real.** That takes
three parts working together: the library in the application's
language, the generated adapter in each SDK, and the proxy with its MCP
surface.

Four outcomes get there, and the workstreams below are grouped by them:

1. **A developer can install station and trust it in live mode.**
   Installable from their own package manager, working with the SDK's
   other features switched on, and keeping secrets out of everything it
   prints. (W0–W3)
2. **Every port behaves the same, and a test says so.** (W4)
3. **The proxy and the agent surface work end to end.** (W5)
4. **The rest of Phases 2 and 3.** (W6, W7)


## 2. Where things stand

The per-port matrix and the evidence are in [`status.md`](status.md).
In one table, on `main` at `e78b38a` (0.2.0):

| design phase | in-process library | proxy and agent surface |
|---|---|---|
| **Phase 1**, prove the loop | Done. Stages 1–3b in the canonical. | Written and tested, but stranded: it does not compile against the sekreto CI pins, has no CI lane, and no library speaks its wire protocol. Phase 1's exit is not met. |
| **Phase 2**, breadth and depth | Sixteen ports in CI, all green. Eleven carry the declarative front door and all eleven corpus sections. Five run eight sections. | Not started (replay, record, mock, OTLP, persistence). |
| **Phase 3**, long tail and remote | rust, lua, c and cpp exist. Six targets have no adapter. | Not started. |

Released at 0.2.0: `@voxgig/station` and `@voxgig/station-js` on npm,
and the Go module by its tag, `go/v0.2.0`. No other port has a package,
and `@voxgig/sdkgen-station` has never been published.


## 3. Standing rules

None of these is new. Each is already in the design or `AGENTS.md`, and
the plan depends on all of them.

- **Canonical first.** TypeScript defines behaviour. A behaviour change
  is TypeScript, then the corpus, then every port, in one change set.
- **The corpus is the contract.** A fix lands with a case in
  `spec/station.json` wherever the behaviour can be written as data.
  Where it cannot (events, transports), every port's own suite pins it,
  and the pin is shown to fail against the old code.
  [#45] is what skipping this costs: eleven ports wrote a different
  message from the canonical and nothing caught it, because the corpus
  pinned only the codes.
- **One version.** Every port shares `VERSION`. `make version-set`
  moves them together and a release ships every port that has a route.
- **An adapter never ships before its library** (`station.md` §9.6).
  The feature model may not name a package a consumer cannot install.
  [#31] is this rule broken.
- **Two library dependencies, no more**: sekreto and struct. omni is
  test-only.
- **Station does not re-test sekreto.** Resolution is sekreto's spec;
  station tests that the right name was asked for and the value was
  placed correctly.
- **An upstream gap is filed, not absorbed.** It gets a row in
  [`upstream.md`](upstream.md) and an issue in the repository that owns
  the fix. A local workaround names the issue it waits on, and goes
  when that issue closes.
- **CI is the only check for five ports.** csharp, swift, dart, elixir
  and lua have no toolchain in a typical development container. A
  change to them is not verified until its pull request's CI has run.


## 4. The workstreams

| | workstream | design reference | gated on | who can do it |
|---|---|---|---|---|
| **W0** | Close out 0.2.0 | `AGENTS.md`, Releasing | nothing | whoever may dispatch the release workflow |
| **W1** | Land the review queue | — | review | review and merge rights; no new code |
| **W2** | Make the solo library safe for live use | §3.3, §5, §6, §16 | W1 | anyone; canonical first |
| **W3** | Installable in every language | §9.2, §9.6; Stage 4 | DEC-1; W0 for Go | anyone, plus upstream releases |
| **W4** | One contract in every port | §13; Stage 5 | W1 | anyone; a workflow change goes in as a patch |
| **W5** | The proxy and the agent surface | §7, §8; Phase 1 exit | DEC-2; W2 for the library half | anyone; a workflow change goes in as a patch |
| **W6** | Phase 2's remainder | §6, §17 | W5 | anyone |
| **W7** | Phase 3 | §8.4, §9.1, §17 | W5, and upstream | anyone, plus upstream |

```
W0 ──► W1 ──┬──► W2 ──► release 0.3.0 ──► W5.5 onward (attach) ──► W6 ──► W7
            ├──► W3   (once DEC-1 is made)
            └──► W4
W5.1 (the proxy builds, and CI holds it) depends on nothing and can start today.
```

What is left of W0 is one merge in likeness and one stale passage of the
design (W0.8). W1 comes before any new code because the queue is the
same files: every fix in W2 touches what those six pull requests touch,
in all sixteen ports.

**For a change to a GitHub workflow, a patch is created on `main`.** A
session's token cannot push a workflow file, so it writes the change as
a patch and commits the patch file to `main` itself, which is where the
maintainer looks for one. [`patch/`](patch/README.md) says how, and
lists the workflow changes that cannot be written yet.

### W0. Close out 0.2.0

Three steps were left when the 0.2.0 release session ran out of
permissions. They were written up, with their patches, in
voxgig/likeness `HANDOVER.md`. Two are done, and the third is waiting to
be merged.

1. ~~Tag `go/v0.2.0`.~~ Done on 2026-11-10, by a dispatch of the
   release workflow, as every release so far has been made. `main` had
   moved past `a570686`, the later of the two commits the npm packages
   were built from, and the plan used to refuse to tag go anywhere else.
   It now tags go on a later commit of `main` when `go/` is the same
   tree, so the tag is on `e78b38a`. [#27] is closed.
2. ~~Apply the release-workflow patch.~~ Done on 2026-11-10, as
   `690b08f`: one dispatch now releases every port, and CI has a
   `versions` job.
3. Move likeness onto the tag. Written, as voxgig/likeness#13, which
   also retires the handover. It is waiting to be merged.

The housekeeping is done too. [#24], which `b145609` fixed and 0.2.0
shipped, is closed, after its own script passed against a generated
SDK. The merged branches are gone.

**Exit:** `make release-plan` reports every port `done`, and
`go list -m github.com/voxgig/station/go@v0.2.0` resolves through the
Go proxy. Both have held since 2026-11-10. Step 3's merge is what
remains.

### W1. Land the review queue

Six pull requests have been open since 2026-10-15, all green at their
heads. They close eight open issues between them. They were trial-merged
together onto `a570686` on 2026-11-10: the order below needs two
one-line conflict resolutions, and the merged tree passes every gate and
all eleven port suites that can run outside CI.

Order: [#60], [#51], [#56], [#47], [#48], [#58]. The register carries
each one's conflicts and what it closes.

**Exit:** the six are merged, CI is green on `main` for all twenty
lanes, and [#23], [#26], [#38], [#45], [#49], [#50], [#52] and [#59]
are closed.

### W2. Make the solo library safe for live use

The fixes with no pull request yet. Two tranches, because the first is
what stands between station and production use.

**W2a, before 0.3.0.** A live-mode failure, and every known path by
which a credential can reach somewhere it should not:

- [#63]. Binding an SDK that was generated without the station feature
  throws `station_wrap_order` in live mode when another feature, such as
  retry, is active. Tests pass, because in test mode the `test` feature
  is present to anchor station's position. This is the `connect()` and
  `adopt()` path, which exists for exactly those SDKs.
- [#37]. The whole `Station` rides in the SDK's options, so serialising
  them prints resolved secrets and the provider chain's configuration.
- [#29]. A transport error's cause chain can still quote a URL carrying
  a placed credential.
- [#57]. `station.json` accepts a password in a block's `base`, and in
  any URL that does not parse.
- [#53]. An `http` event's path keeps the userinfo of a URL the port
  cannot parse.

**W2b, parity and semantics.** These make one request read the same in
every language, and can ship in 0.3.x:

- [#36]. One failed operation emits three `op` events.
- [#54]. Rust and swift read an IPv6 policy host without its brackets,
  and no port pins the policy's hostname directly.
- [#55]. Four URL forms still read differently from `URL.host` (DEC-4).
- [#61]. An unpaired surrogate escape in `station.json` reads three
  different ways in four ports.
- [#64]. The kill switch shares its error code with an allowlist miss,
  and takes effect only on restart (DEC-5).

**Exit:** each issue is closed by a change that carries a corpus case
or, where the corpus cannot see it, a pin in every port's suite. 0.3.0
is released from the commit that completes W2a.

### W3. Installable in every language

Today only a TypeScript or JavaScript consumer can install station. The
feature model writes a registry dependency into every generated SDK,
and outside npm none of those packages exists ([#31]). The cause runs
upstream: station's ports depend on sekreto, and sekreto is published
on npm only ([`upstream.md`](upstream.md), registries).

- The route is DEC-1. The recommendation is staged: make station an
  optional dependency of a generated SDK wherever the language allows
  it, as it already is in TypeScript and JavaScript; give each port a
  manifest that installs from a git pin; and publish to a registry as
  sekreto and plugin arrive there.
- Make each port installable on its own terms: Python ships the config
  shape as package data and takes struct from PyPI ([#39]); Ruby gains a
  gemspec; PHP declares its requirements; Java gains a build file; Rust
  stops depending on a symlink.
- The Perl payload carries voxgig/plugin, which sekreto's core needs
  ([#42]).
- Generated SDKs register themselves in every language that can express
  it, or their README stops saying they do ([#30]). This is Stage 4's
  unfinished half, and the generator side belongs to sdkgen.
- `@voxgig/sdkgen-station` gets a release route.
- The fleet's SDKs are regenerated on the result.

**Exit:** for each language the fleet generates, a generated SDK with
the station feature installs and passes its own lane with no checkout
of station on disk; Stage 4's exit holds in each of those languages
("a generated SDK is reachable through `station.sdk()` with no import
in application code"); and no README promises what its target does not
do.

### W4. One contract in every port

- TypeScript gains the completeness guard the other ten have, so a
  corpus section cannot go unrun in the canonical.
- csharp, swift, dart, elixir and lua take Stage 5's last tranche: the
  `config`, `feature` and `instanceref` sections, the declarative front
  door, and a guard each.
- A fixture lane generates real SDKs from `test/api/` and runs the
  integration suites against them. Today those suites skip in CI in
  every port, adapter code that compiles only inside a generated SDK is
  never compiled ([#60] names three such pieces), and [#63] could not
  be caught. This is the lane `station.md` §9.5 and §13 already require.
- CI pins `struct` once the last five ports have taken that tranche,
  which is when `build.yml` itself says to. `plugin` stays unpinned, on
  purpose: its corpus is the C4 contract, and a red lane when plugin
  moves is that contract working.
- The corpus gains the sections §13 names and it lacks, starting with
  `event`, so that an event's shape is pinned once and not sixteen
  times.

**Exit:** all sixteen ports run every corpus section or pin it as
pending by name; every port has a completeness guard; the integration
suites run in CI; and the only dependency that floats in `build.yml` is
`plugin`, which floats on purpose.

### W5. The proxy and the agent surface

This is the largest block of remaining work, and half of it already
exists. `proxy/` holds a daemon with the §8 wire surface, the policy
authority, capture, tap, grants and eight MCP tools. Its 49 tests pass
against the sekreto revision it was written for. Against the revision
CI pins it fails to compile: two undefined names, in one file ([#46]).
What does not exist at all is the other end: no library port can
attach.

1. The proxy builds against the pinned sekreto, takes the single-pass
   scrub, and gets a CI lane ([#46]).
2. The two proposed decisions are signed off (DEC-2).
3. `voxgig-station testkit`: the proxy in deterministic mode, which §13
   makes the way every library tests attachment.
4. The wire's corpus sections: `envelope`, `degrade`, and the attached
   half of `redact`.
5. Attach in the canonical: discovery and the proof-of-token handshake
   (§8.1), register, events, the forward envelope, `resolve: proxy`, and
   the `auto`, `require` and `off` semantics (§2.1).
6. The same in JavaScript, so that both released packages attach.
7. End to end: a generated SDK through the proxy, the §11 quickstarts
   and the §12 agent transcript run for real, and each MCP tool checked
   against a live registration.
8. Attach in go and python, then the rest of tier A, then tier B with
   its one declared dependency. Tier C does not attach in v1.
9. The proxy binary gets a release route.

**Exit:** Phase 1's exit, as the design states it.

### W6. Phase 2's remainder

Replay, record and mock with §6's per-class semantics; SQLite capture
persistence; OTLP export; grants hardening and the revocation
experience; config reload; a unix-socket listener. All proxy-side, and
all listed as deferred in `proxy/README.md`.

### W7. Phase 3

Remote mode behind the tenancy design (§8.4, §18); policy long-poll in
the libraries; `station_call` write scopes; adapters for scala, clojure,
haskell, ocaml, zig and lean, each behind an sdkgen prerequisite; and
sekreto ports for the languages that have none.


## 5. Open decisions

Each is the owner's call. Once made, it becomes a dated record in
[`decisions.md`](../design/decisions.md) with a revisit trigger, and its
row in the register moves.

### DEC-1. How does a non-JavaScript consumer get station?

Gates W3, and through it every non-JS lane of every generated SDK that
carries the feature.

The facts, checked on 2026-11-10: struct is published on PyPI, RubyGems,
crates.io, NuGet, Hex and pub.dev. sekreto and plugin are on npm only;
plugin also has Go tags, and sekreto has none. Station's Python manifest
requires `voxgig-sekreto`, which is not on PyPI. The Ruby port has no
gemspec, the Java port no build file, the Rust port depends on a
symlink, and the Swift dependency names a repository,
`voxgig/station-swift`, that does not exist publicly.

| option | what it takes | what it costs |
|---|---|---|
| **A.** Publish station to each registry | sekreto and plugin published there first; a release route per registry | Waits on two other repositories, per language |
| **B.** The feature model writes git pins | A manifest per port that installs from git | A generated SDK that is itself published cannot depend on a git reference (PyPI refuses one); Composer and SwiftPM cannot take a subdirectory of a repository; NuGet cannot take a git reference at all |
| **C.** Staged | Station becomes an optional dependency of the SDK where the language allows it, as in ts and js; ports install from a git pin now; registries follow as sekreto and plugin arrive | Three steps, and the README of each target has to say which step it is on |

**Recommended: C.** The ts, js, py and rb adapters already load station
only when the feature initialises (`d866631`), php checks that the class
exists, and the feature is generated inactive. So in those languages an
SDK that never binds does not need station at all, and making the
dependency optional removes the red lanes without waiting on anyone. Go
links station statically, and has its tag.

The calls inside it: whether "optional" is acceptable for py, rb and
php; which registries come first (the issue names py, rb, php and
java); and who publishes sekreto and plugin, which is those
repositories' decision.

### DEC-2. Sign off the two proposed decision records

`D-2026-08-24-1` (a grant is scoped per instance) and `D-2026-08-24-2`
(remote v1 serves one trust domain) are still `proposed`. The proxy's
grant table and `/v1/grants/{ref}` are already written to the first.
Gates W5 item 2 and W7's remote mode.

**Recommended: accept both.** Each restates a position the design
already takes, and each carries its own revisit trigger.

### DEC-3. Does station take voxgig/plugin as a dependency?

plugin's own register holds this as `DECISION NEEDED` (its item 5.2).
It gates nothing: it decides only whether ports later replace their
native implementation with the library.

**Recommended: keep it deferred** until a second consumer exists, which
is the condition `station-and-plugin-plan.md` §7 sets.

### DEC-4. How far does an event's host follow `URL.host`?

[#55] offers two answers for the four forms that still differ:
normalise them as `URL.host` does, or name them in §6 as outside the
rule.

**Recommended:** normalise the three that are cheap in every language
(lower-case an ASCII host, drop an empty port, read a port as a number),
and name long-form IPv6 as outside the rule, since compressing it needs
an address parser most of the sixteen do not have.

### DEC-5. What is the kill switch's contract?

[#64] asks for a distinct error code and a way to change policy without
a restart.

**Recommended:** add `station_blocked` now. It is one more entry in
§14's catalog and the `errors` corpus section. Treat reload as two
answers: in attached mode it is the policy long-poll the design already
has (W7); in solo mode it needs a decision on whether `reload()` is in
scope at all.

### DEC-6. What does station-view read?

The repository has a description and no code. A viewer needs a source
of events, and there are two: one process's in-memory ring, or the
proxy's consolidated stream.

**Recommended:** the proxy. `/v1/status`, `/v1/tap` and `/v1/traffic`
are what a viewer needs and are already written. That makes
station-view wait on W5 items 1 and 5.

### DEC-7. What is seneca-station?

The repository has a one-line README. Nothing in station's or sdkgen's
design describes a Seneca binding. It needs a one-page design before
any code: what a Seneca application gets from it that
`@voxgig/station` does not already give. It depends only on the
released TypeScript library, so nothing in this plan blocks it.


## 6. The release train

| release | carries | gate |
|---|---|---|
| **0.2.0** | Released: on npm 2026-10-16 and 17, and the Go tag on 2026-11-10. | Done; W0's housekeeping remains |
| **0.3.0** | W1 and W2a. The first release to recommend for live use. | W2a's exit |
| **0.3.x** | W2b, W3's port packaging, W4. | each item's own exit |
| **0.4.0** | Attach in typescript and javascript, with the proxy binary released beside them. Phase 1's exit. | W5 items 1–7 |

Every release moves every port (`make version-set`), and one dispatch
of `release.yml` on that commit ships all three.
0.3.0 changes behaviour that 0.2.0 shipped: [#60] checks feature options
as the SDK does, [#48] changes message text, and [#58] makes the C port
refuse a provider kind it used to warn about. Its release notes say so.


## 7. The clients

| client | state | what it needs from this plan |
|---|---|---|
| **voxgig/likeness** | Stages 0 and 1 done; Stage 2 at 9 of 20 cells; Stage 3 not started. CI green. | W0 (its own step 3); [#51] for eight Go entries; [#58] for the C port; [#36] and [#61] for parity. The rest is the generated SDKs: see [`upstream.md`](upstream.md). |
| **voxgig/station-view** | Tooling only. No code, no design. | DEC-6, then W5. |
| **senecajs/seneca-station** | A README. No code, no design. | DEC-7. |


## 8. Risks

| risk | why it is real | what the plan does |
|---|---|---|
| **The queue rots.** | Six pull requests, a month old, across the same files in sixteen ports. Two already conflict. | W1 before any new code. |
| **Upstream moves under a floating CI.** | `plugin` and `struct` float in `build.yml`, both by decision: plugin so that drift from its corpus goes red, struct until Stage 5 completes. struct has a parity pull request open that changes behaviour across its ports. A red lane on an unrelated pull request is the likely first symptom. | A red lane is read as upstream drift first, and reported upstream. W4 pins struct when the last five ports have landed. |
| **Code without a CI lane dies quietly.** | The proxy stopped compiling when sekreto's API moved, and nothing went red. | W5 item 1 adds the lane before anything else is built on it. |
| **A fix skips the corpus.** | Sixteen ports make every fix expensive, and the cheap version is to fix the port that was reported. | Standing rule 2, and the exit of every W2 item. |
| **Distribution waits on other repositories.** | sekreto and plugin are on npm only. | DEC-1's staged route does not wait for them. |
| **Attach has one side.** | The proxy implements the wire; no library does. A protocol with one implementation has not been tested. | The testkit and the wire's corpus sections come before the first client. |
| **Human-only steps queue up.** | Tags, merges, registry setup and applying a workflow patch all need the maintainer. | `status.md` lists them together, so they can be done in one sitting, and every workflow change arrives as a patch ready for `git am`. |
| **The second consumer of plugin never appears.** | sdkgen's adoption is uncommitted. | DEC-3 stays deferred; no port is put behind plugin. |


## 9. Not in this plan

The design's non-goals stand (`station.md` §19). Its open questions
(§18) are not scheduled here unless a workstream above needs one
answered: remote multi-tenancy (W7), streaming uploads (W6), capture
encryption at rest (W6), and sekreto ports for the gap languages (W7).


[#23]: https://github.com/voxgig/station/issues/23
[#24]: https://github.com/voxgig/station/issues/24
[#26]: https://github.com/voxgig/station/issues/26
[#27]: https://github.com/voxgig/station/issues/27
[#29]: https://github.com/voxgig/station/issues/29
[#30]: https://github.com/voxgig/station/issues/30
[#31]: https://github.com/voxgig/station/issues/31
[#36]: https://github.com/voxgig/station/issues/36
[#37]: https://github.com/voxgig/station/issues/37
[#38]: https://github.com/voxgig/station/issues/38
[#39]: https://github.com/voxgig/station/issues/39
[#42]: https://github.com/voxgig/station/issues/42
[#45]: https://github.com/voxgig/station/issues/45
[#46]: https://github.com/voxgig/station/issues/46
[#47]: https://github.com/voxgig/station/pull/47
[#48]: https://github.com/voxgig/station/pull/48
[#49]: https://github.com/voxgig/station/issues/49
[#50]: https://github.com/voxgig/station/issues/50
[#51]: https://github.com/voxgig/station/pull/51
[#52]: https://github.com/voxgig/station/issues/52
[#53]: https://github.com/voxgig/station/issues/53
[#54]: https://github.com/voxgig/station/issues/54
[#55]: https://github.com/voxgig/station/issues/55
[#56]: https://github.com/voxgig/station/pull/56
[#57]: https://github.com/voxgig/station/issues/57
[#58]: https://github.com/voxgig/station/pull/58
[#59]: https://github.com/voxgig/station/issues/59
[#60]: https://github.com/voxgig/station/pull/60
[#61]: https://github.com/voxgig/station/issues/61
[#63]: https://github.com/voxgig/station/issues/63
[#64]: https://github.com/voxgig/station/issues/64
