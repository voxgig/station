# The plan register

Live per-item state of [`plan.md`](plan.md). **A row changes in the same
commit that changes its status.** `DONE` means merged. A row moves to
`IN PROGRESS` when a pull request for it is open, which says work is
under way and not that it has landed.

Statuses: `NOT STARTED`, `IN PROGRESS`, `DONE`, `DECISION NEEDED`,
`BLOCKED` (on what, in the note), `DECIDED-NO`.

Every note below was checked on **2026-11-10** against `main` at
`a570686` unless it gives another date or revision. `main` moved twice
that evening: to `690b08f` when W0.3 landed, and to `e78b38a` when this
register and W0.9 did. Neither changed a port's source. The six pull
requests of W1 merged on 2026-11-11 and changed every port's: a note
dated before that describes the code as it was, unless its row says
otherwise.
"Read" means the code was read and the behaviour not run; "run" means
it was run. What
station needs from other repositories is in [`upstream.md`](upstream.md),
and its rows are named here as `sdkgen-6`, `sekreto-1` and so on.

Every open issue and pull request maps to a row: the index is at the
end.


## W0. Close out 0.2.0

| Item | Status | Notes |
|---|---|---|
| W0.1 Tag `go/v0.2.0` | DONE | 2026-11-10. Release run 42913723297, a dispatch on `main` at `e78b38a`, made the tag: it planned `go tag`, built and tested the go module with no workspace, skipped both npm jobs because both packages were already released, and pushed `go/v0.2.0` on `e78b38a`. `go/` there is the same tree object as on `a570686`, the later of the two commits the npm packages were built from (typescript's is `a509752`, javascript's `a570686`). `make release-plan` on `main` now reports every port `done`. The Go proxy lists `v0.2.0` for `github.com/voxgig/station/go`, and a fresh module outside any workspace gets it by version, builds and runs (run). Before the dispatch, the same consumer check passed against the commit itself, and CI run 42913018209 on `e78b38a` was green. |
| W0.2 Close [#27] | DONE | Closed on 2026-11-10, and not on purpose: the commit recording the release, `4f42226`, had the words "close" and the issue's number side by side in its message, and GitHub closed the issue when that commit reached `main`. It was the right outcome a step early. A note on the issue, added 2026-11-11, names the tag, says how a consumer gets it, and gives the one `replace` line an SDK generated before the tag still needs. |
| W0.3 One dispatch releases every port; CI gains a `versions` job | DONE | `690b08f`, committed to `main` on 2026-11-10 by the maintainer, applying `station-release-workflow.patch`. `main`'s tree is exactly `a570686` plus that patch (run). CI run 42878382277 on it is green: all twenty lanes and the new `versions` job, against that evening's plugin and struct. It also corrected `release.yml`'s stale header and rewrote the release section of `AGENTS.md`. Still open from the same change: the review thread on voxgig/station#65 can be closed. |
| W0.4 likeness onto station 0.2.0 | DONE | voxgig/likeness#13, merged on 2026-11-11 as `4111493`. likeness's `check` run 43018954319 on its `main` is green, the pull request's own runs were green, and its automated review found nothing. `99858ee` makes the Go port require `github.com/voxgig/station/go v0.2.0`, and points the one `replace` the generated SDKs still need at the tag; `go.sum` holds the tag as the module proxy serves it. It moves the Python and Ruby pins to `e78b38a`, the commit the tag names, where the handover's patch said `a570686`. The patch was written before the tag existed, `python/` and `ruby/` are the same trees on both commits (run), and likeness's `ruby/libs.json` says its pin is the revision `go.mod` binds. `2d63db5` deletes `HANDOVER.md` and both patches, as the handover asks once its three steps are done. Before it was opened, `make test-go test-py test-rb` passed with the counts they had before the change (run): Go ok, Python 103 with 2 skipped, Ruby 115 with 3 skipped. `make check` passed (run): four ports agree on 259 entries, and the matrix has 9 of 20 cells green and 11 waiting on upstream, each as its cause predicts. |
| W0.5 Close [#24] | DONE | Closed on 2026-11-11. `b145609` (voxgig/station#28) took `as` and `instance` out of what `connect()` hands the SDK, in the nine ports that have that path, and 0.2.0 shipped it. Before the issue was closed, its own script was run against npm's 0.2.0 and the generated Joplin SDK at `89b86ca`: each of the three calls builds an SDK, neither key reaches the SDK's options, and the SDK by itself still refuses the key, so the pass means something (run). The same three calls pass in the Python port at `e78b38a` (run). Those are the two ports the issue names. Of the other seven, six carry a test named for it (javascript, ruby, php, perl, dart, lua; read). elixir has the fix (`elixir/lib/voxgig/station/adapter.ex:110`) and no test that calls `connect` at all (W4.8). None of the seven was run against a generated SDK (W4.3). The issue had stayed open because the pull request's description names two issues after one closing word, and GitHub acts on the first only. |
| W0.6 Prune merged branches | DONE | Done on 2026-11-10, and not by the session that keeps this register, whose row went on saying `NOT STARTED` until the branches were next listed, on 2026-11-11. The eighteen merged branches and `chore/comment-policy` were on GitHub at 15:52 UTC on 2026-11-10 and gone the next morning. Three merged pull requests whose heads were among them (voxgig/station#22, voxgig/station#28 and voxgig/station#65) were last updated within the same two seconds, at 18:50 UTC on 2026-11-10, which is what deleting a head branch does, so that is probably when. Nothing was lost. The eighteen were ancestors of `main`. `chore/comment-policy`'s one commit, `bd91179`, has the same tree and the same parent as `50667dc`, the squash of voxgig/station#22 on `main`, and GitHub still holds it as that pull request's head (run). Eight branches remain: `main`, the heads of the six open pull requests, and `claude/bold-newton-4of9bo`, which is level with `main`. |
| W0.7 This register, and the README and design status lines brought back to the code | DONE | This change. The README table said the declarative front door was pending in ten ports that have it, that five ports had no toolchain when CI runs all five, and that the proxy was deferred when `proxy/` holds one. `station.md` §17 and `station-and-plugin-plan.md` §0 and §3 said the same. |
| W0.8 The design's account of sdkgen, brought up to date | NOT STARTED | `station.md` §9 item 3 and `station-declarative-config.md` §11 describe sdkgen as it stood in August: seventeen of twenty `Config_*` components passing their target name (all twenty do), the constructor's `extend` tolerance still to come (the ts, js and py templates carry it; the others were not checked), and a per-feature option schema as later work (it shipped as `optspec`). [`upstream.md`](upstream.md) carries the current state. The prose should say what station still needs and point there for the rest. |
| W0.9 A dispatch can tag go after `main` has moved | DONE | This change. `tools/release_plan.py` put go's tag only on the commit the npm release came from, and the workflow can only tag the commit it runs on, so once `main` had moved no dispatch could finish 0.2.0. The plan now also allows a later commit of `main` when `go/` is the same tree as on that commit, and says so in the run, naming both commits. It still refuses when `go/` has changed, or when the commit does not descend from the release. No workflow file changes. 13 tests, two of them new; three mutations of the new rule each fail one (run). `AGENTS.md`, "Irreversible", says the same. On `main` as `e78b38a`, and used the same evening: it is what let W0.1's dispatch run. |


## W1. Land the review queue

**All six merged on 2026-11-11**, on the maintainer's instruction. Each
branch was first brought up to `main`, and its pull request's CI run
again on the result. Nothing was merged red, and `main` was green after
every merge.

That re-run found two faults the trial merge could not see. Both were
in ports with no toolchain outside CI, and both came from changes that
reached `main` after these branches were cut:

- **swift, in [#51] and [#56].** Three pins called the send closure of
  `Binding.transport` with two arguments. voxgig/station#28 had given
  it a third, `place`. One token at each site.
- **csharp and swift, in [#48].** Four instance-ref refusals in each
  port cited the design as `(6.1)`. They arrived with [#60], after
  [#48] had moved every other port to `(§N)` and pinned three of the
  four whole in the corpus. Eight lines.

Each fix went onto its pull request's branch, and CI was green on it
before the merge. The two conflicts the trial had predicted were
resolved on the branches too, as the rows say.

`main` at `9a650d4` is the tree CI passed in run 43023139038, all
twenty lanes. It differs from the tree of the local trial below only in
the three files those fixes touch.

**Trial merge, 2026-11-10 and again 2026-11-11.** All six onto `main`,
in the order below, with the two resolutions the notes give. `make
vendor-check`, `version-check`, `comments` and `omni-isolation` pass,
and no payload needed `vendor-refresh`. Eleven port suites pass:
typescript (158 tests: 138 pass, 20 skipped), javascript (29), go,
python, ruby (80 and 12), php (73), perl, java (62), rust, c (with its
new secrets suite) and cpp. csharp, swift, dart, elixir and lua were
**not** run, for want of a toolchain, which is where both faults were.

| Item | Status | Notes |
|---|---|---|
| W1.1 [#60]: a named instance gets its declared options; feature options are checked as the SDK checks them | DONE | Merged on 2026-11-11 as `687673c`. Its branch took `main` cleanly; CI run 43018971325 on that, and 43019560965 on `main`, are green. It closed [#26] and [#59]. [#49] was closed by hand: the description names three issues after one closing word, GitHub acts on the first only, and [#59] closed because a commit names it. Gives csharp and swift named instances and the `instanceref` section, so they run nine. Gives up typo detection for a non-strict feature, as the SDK does (`sdkgen-5`). |
| W1.2 [#51]: an `http` event's path, exactly as sent | DONE | Merged on 2026-11-11 as `94b67db`. Its branch took `main` cleanly and then failed CI in swift (run 43019593629): the path pin's send closure had two arguments where `main` takes three. `08670a6` fixes the line; run 43020817471 on it, and 43021502368 on `main`, are green. It closed [#50]. [#38] was closed by hand: its station half is this change, and its `..` row was voxgig/sdkgen#414, closed 2026-10-17. likeness's Go port waits on a station release that carries this, for eight transcript entries. |
| W1.3 [#56]: an `http` event's host, as `URL.host` reads it | DONE | Merged on 2026-11-11 as `8972526`. It failed CI in swift the same way (run 43019661168), at three sites: the path pin it carries from [#51], and its own host and policy pins. The branch took [#51]'s corrected commit by merge (`e8f07ba`), so that the two would land one after the other without a conflict, and `f8944a8` fixes the other two. Run 43020816654 on it, and 43021520512 on `main`, are green. It closed [#52]. Also fixes a policy bypass in rust and swift, which read a URL's user name as its host: `https://api.test:x@evil.test/x` passed an allowlist naming `api.test`. Leaves [#53], [#54], [#55] to W2. |
| W1.4 [#47]: the sekreto ranges in `AGENTS.md` | DONE | Merged on 2026-11-11 as `96de131`, ahead of [#51] and [#56] while those two were being fixed: it is two lines of one document. Runs 43019666262 on its branch and 43020827544 on `main` are green. |
| W1.5 [#48]: `(§N)` in every port's refusal messages | DONE | Merged on 2026-11-11 as `7b7970e`. The conflict with [#60] was the one predicted, one hunk each in `csharp/src/Station.cs` and `swift/Sources/VoxgigStation/Station.swift`, both the `station_bound_twice` message; `544cad6` keeps [#60]'s wording (`instance "…"`) with this change's citation (`(§10.2)`). CI on that was red in csharp and swift (run 43021591775), on the corpus case `instanceref#wrong-api-refusal-message-in-full`: [#60] had brought four more refusals into each port citing `(6.1)`. `90c7da4` changes the eight lines to `(§6.1)`, as the other fourteen ports read. Run 43022470574 on it, and 43023058555 on `main`, are green. It closed [#45]. Pins eight refusals whole in the corpus. |
| W1.6 [#58]: the C port resolves through sekreto's C port | DONE | Merged on 2026-11-11 as `9a650d4`. Two conflicts with `main`, both in documents, resolved in `5156f55`. In `AGENTS.md`, under "Checks worth knowing": its `vendor-check` line and `main`'s `sync-shape` line. In `README.md`, the port table: `main`'s rows, with the C row carrying what this change alters in it, which is secrets through sekreto's C port, the secret-store suite beside the unit and corpus runs, and its note that configuration arrives in code. Run 43023139038 on that is green, and its tree is `main`'s. It closed [#23]. Net: 32 files, +7,879 −250, most of it sekreto's C core vendored at `32b83ac`. The C lane needs libcrypto and the plugin checkout, and CI has both. Its `-D_DEFAULT_SOURCE` workaround goes with `sekreto-3`. |


## W2. Make the solo library safe for live use

Each row lands canonical first, with a corpus case or a pin in every
port's suite.

### W2a. Before 0.3.0

| Item | Status | Notes |
|---|---|---|
| W2.1 [#63]: station's place in the feature order when `test` is absent | NOT STARTED | **Blocks live use of `connect()` and `adopt()`.** The carried adapter asks to be placed `__after__: 'test'` (`typescript/src/adapter.ts:108`) and then requires index 0, or the index after `test` (`:25-33`). sdkgen's `featureAdd` appends a feature whose anchor is not in the list, and its constructor adds an `extend`-carried `station` "positioned by its own `__after__` entry" (sdkgen 4.41.0, read). With `test` inactive, station lands last and its own guard throws. An SDK generated *with* the feature is placed by `makeOptions`, which puts station first when `test` is absent, so it is unaffected. Not reproduced: nothing here generates an SDK (W4.3). Two halves: station must place itself in SDKs already in the field, and sdkgen should add an `extend`-carried feature at its `featureorder` slot (`sdkgen-6`). Pin: retry active, bound live, one `http` event per attempt. |
| W2.2 [#37]: the Station out of the SDK's options | NOT STARTED | `feature.station.station` is the `Station` itself (`typescript/src/Station.ts:209`, `:233`, read). The broker's `held` array is a TypeScript `private`, which is ordinary data at run time (`secrets.ts:117-119`), so `JSON.stringify(client.options())` prints resolved values after one live request (the issue's reproduction, 0.1.0). Reach the Station through a closure or a `WeakMap` keyed by the client; keep held values out of enumerable and inspectable state in every port; drop the caller's key from `calleropts` once hoisted. go is unaffected (unexported fields). Pin: bind, one live request, serialise the options, the secret is absent. The SDK's own copy of the key is `sdkgen-9`. |
| W2.3 [#29]: scrub a transport error's cause chain | NOT STARTED | ts and js: `fetch`'s `cause` carries the placed URL in `input`. java: the scrubbed error keeps the original as its cause. py, rb, php: a non-string argument is not scrubbed deeply. Scrub the chain where the port can; drop the cause where it cannot. One seam test per port. |
| W2.4 [#57]: refuse a password in a block's `base`, and in a URL that does not parse | NOT STARTED | `scanConfig` checks a block's `secret`, `options`, `feature` and `policy`, never its `base`, and `userinfo()` returns when `new URL` throws (`typescript/src/shape.ts:135`, `:303`, read). Raise `station_config_secret` naming the path. Add both cases to the `config` corpus section beside the three it has. python accepted the parseable case at `50667dc` (the issue); the other ports were not checked. |
| W2.5 [#53]: an unparseable URL's userinfo stays out of the event | NOT STARTED | It amends the rule W1.2 and W1.3 set. When a string is reported whole and has a scheme and `://`, drop everything up to the last `@` of its authority first. Pin two rows in every port. |

### W2b. Parity and semantics

| Item | Status | Notes |
|---|---|---|
| W2.6 [#36]: one `op` event per operation | NOT STARTED | The binding emits from every hook stage that can end an operation. The generator's double `PreUnexpected` is fixed (voxgig/sdkgen#413, closed 2026-10-17), but only a regenerated SDK carries that, and go emitted two regardless. Key the event on the operation's context so the count is one whatever generated the SDK. `sdkgen-8` changes which stages fire. Pin: one failed operation, exactly one `op` event. |
| W2.7 [#54]: the policy's hostname | NOT STARTED | rust and swift read an IPv6 host without its brackets, so an allowlist entry `[::1]` never matches there. No port pins the policy's hostname directly: pin an allow and a deny for an IPv6 host, an explicit default port, and userinfo with a raw `@`. |
| W2.8 [#55]: the four forms that still differ from `URL.host` | DECISION NEEDED | DEC-4. |
| W2.9 [#61]: an unpaired surrogate escape in `station.json` | NOT STARTED | Refuse with `station_config_invalid` in every port, as I-JSON requires. go needs a scan of the raw text, since `encoding/json` has already replaced the escape. Corpus: a lone high, a lone low, and a valid pair that must still be accepted. |
| W2.10 [#64]: the kill switch | DECISION NEEDED | DEC-5. Today mode `block` raises `station_host_allow`, the allowlist's code (`typescript/src/Station.ts:354-357`, read), and the config is read once, at construction. |
| W2.11 Release 0.3.0 | NOT STARTED | After W2a. Since W1 merged, `main` differs from the 0.2.0 tags in every released port, so `make release-plan` refuses and names the fix, and a dispatch would refuse the same way (run, 2026-11-11): nothing can be released from `main` until `VERSION` moves. `make version-set V=0.3.0` in a reviewed pull request, then one dispatch of `release.yml` on that commit, which publishes typescript and javascript and pushes all three tags (W0.3). The notes name the three behaviour changes in `plan.md` §6. |


## W3. Installable in every language

What is published where is in [`upstream.md`](upstream.md), under
"Registries".

| Item | Status | Notes |
|---|---|---|
| W3.1 The route | DECISION NEEDED | DEC-1. |
| W3.2 [#31]: the feature model writes a dependency that resolves, and an optional one where the language allows | BLOCKED | On W3.1. `sdkgen-station/.sdk/model/feature/station.aontu` names `voxgig-station` (PyPI), `voxgig_station` (RubyGems, pub.dev, Hex, crates.io), `voxgig/station` (Packagist), `com.voxgig:station` (Maven) and `Voxgig.Station` (NuGet). None exists. Its Swift entry names `https://github.com/voxgig/station-swift`, which is not a public repository. Go is done: W0.1. |
| W3.3 [#39]: Python installs outside a checkout | NOT STARTED | Not gated on DEC-1: these are defects on any route. `shape.py:183` reads `spec/config-shape.json` by a checkout-relative path; ship it as package data and have `make sync-shape` keep it in step, as it does for typescript and javascript. `structhome.py` looks for a struct checkout and says struct is unpublished; `voxgig-struct` is on PyPI. `pyproject.toml` requires `voxgig-sekreto>=0.1`, which is not (`sekreto-1`). |
| W3.4 Ruby: a gemspec | NOT STARTED | `ruby/` has none, so Bundler can take the port neither from git nor from a registry. |
| W3.5 PHP: a manifest that states its requirements | NOT STARTED | `php/composer.json` requires only `php`; sekreto is found through `SEKRETO_HOME` or a sibling checkout. Composer reads a VCS package from a repository's root, not a subdirectory. |
| W3.6 Java and Kotlin: a build file | NOT STARTED | `java/` has a Makefile and no `pom.xml` or Gradle build, while the feature model names Maven coordinates. |
| W3.7 Rust: dependencies that resolve without `make vendor` | NOT STARTED | `Cargo.toml` path-depends on `vendor/sekreto` and `vendor/struct`, links the Makefile makes to sibling checkouts. struct has a crate; sekreto has none. |
| W3.8 csharp, swift, dart and elixir manifests | NOT STARTED | After the four above. csharp takes sekreto by `ProjectReference`. SwiftPM needs a package at a repository's root. |
| W3.9 [#42]: the Perl payload carries voxgig/plugin | NOT STARTED | `Voxgig::Sekreto` requires `Voxgig::Plugin` at load, and the payload does not carry it, so a generated Perl SDK works only where a plugin checkout is on `@INC`. Vendor it through `tools/vendor.py`, hold it in `make vendor-check`, correct `VENDORED.md`, and make the bootstrap name the module that was missing. |
| W3.10 [#30]: a generated SDK registers itself, or its README says what it needs | BLOCKED | On `sdkgen-7`. sdkgen generates the registration for ts and js only. In Go an explicit `station.Provide` was verified to work (the issue). The README text is sdkgen's `ReadmeStation`. |
| W3.11 A release route for `@voxgig/sdkgen-station` | BLOCKED | On a maintainer registering a third package with `npm trust`. The `port` value in `release.yml` is a workflow change, and follows as a patch on `main` ([`patch/`](patch/README.md)). The package has never been published (`npm view` finds nothing). Its version is outside `VERSION` by decision. |
| W3.12 Generated C SDKs resolve through sekreto | NOT STARTED | W1.6 left them env-only: the payload is built with `VXSTN_ENV_ONLY`. sdkgen-station would have to carry sekreto and plugin's C host beside sdkgen's own `secrets` feature, which vendors sekreto at a different commit. |
| W3.13 The fleet's SDKs regenerated | BLOCKED | On `sdk-1`. W0.1 is done, so a regenerated SDK's Go module can require `v0.2.0`. The four regeneration pull requests are open and were generated on sdkgen 4.34.6. No SDK in voxgig-sdk carries the station feature on its default branch. |


## W4. One contract in every port

| Item | Status | Notes |
|---|---|---|
| W4.1 A completeness guard in typescript | NOT STARTED | `typescript/test/conform.test.ts` writes one test per section by hand. `spec/README.md` records the mutation: a bogus section passes typescript and fails ten other ports. |
| W4.2 The last five ports take Stage 5's tranche | NOT STARTED (0/5) | csharp, swift, dart, elixir, lua. Each needs the `config`, `feature` and `instanceref` sections, the declarative front door (`sdk`, `create`, `check`, `warm`, `features`, `instances`), struct validation at `open()`, and a guard. All five read the `sdk` grammar. dart, elixir and lua run eight sections. csharp and swift run nine since W1.1, which gave them `instanceref` and named instances (CI run 43023139038), so those two need `config` and `feature` and the rest of the list. One deliverable per port. |
| W4.3 A fixture lane: generated SDKs, and the integration suites run against them | NOT STARTED | The suites look for `$STATION_TEST_SDKS/taskpad-sdk/ts/dist` and for `STATION_TEST_RB_SDK`, `STATION_TEST_PHP_SDK` and `STATION_TEST_PERL_SDK`. Nothing in the repository generates them. In CI, typescript's `quickstart`, `gnarly-pets` and `generated-feature` suites skip, javascript's two skip, ruby's nine quickstart cases skip and perl's `t/quickstart.t` skips. Inputs exist: `test/api/taskpad` and `test/api/gnarly-pets`. This is the lane `station.md` §9.5 and §13 require. The `make` target is ordinary work. The CI job is a workflow change: it follows as a patch on `main`, once the target is there ([`patch/`](patch/README.md)). |
| W4.4 Pin `struct` in `build.yml` | BLOCKED | On W4.2. The file's own comment says struct is unpinned while Stage 5's tranches land, because a pin would hide a divergence, and is to be pinned once Stage 5 is complete. Then it is one `ref:` line, delivered as a patch on `main` ([`patch/`](patch/README.md)). **`plugin` is not to be pinned.** The file's header says it is deliberately unpinned: the C4 suite runs plugin's corpus against station, and drift going red there is the contract working. Heads observed on 2026-11-11: plugin `8605cdc`, and struct `055ac4a`, which had moved on each of the two days it was looked at. The typescript lane links no struct checkout: it tests npm's 0.2.2 from the lockfile, while every other lane tests struct `main` (W4.5). |
| W4.5 typescript onto struct 0.3 | NOT STARTED | `^0.2.2` excludes 0.3.x; npm's latest is 0.3.7. javascript is on the latest `struct-js`, 0.1.7. |
| W4.6 The corpus sections §13 names and `spec/station.json` lacks | NOT STARTED | `inject`, `order`, `redact`, `event`, `degrade`, `envelope`. `event` first: [#50], [#52] and [#36] are each pinned once per port because no section can see an event. `envelope` and `degrade` belong to W5.4. |
| W4.7 Plugin conformance (C4a, C4b) | DONE | Continuous, so "done" means wired and red on drift. `typescript/test/c4-plugin.test.ts` landed in `ce0819b` (2026-08-24), and CI's typescript lane sets `STATION_REQUIRE_C4=1`, so a missing plugin checkout fails the lane. Run against plugin `8605cdc`: 144 pass, 0 pinned divergences, 128 skipped, each with its reason. plugin's own register still says `NOT STARTED` (`plugin-1`). |
| W4.8 Small repairs | NOT STARTED | The root `make test-dart` runs `dart test`, and the port has no `package:test`; CI uses `make -C dart test`, which works. The explicit first-element checks of `station-declarative-config.md` §4.4 can go once every port's struct carries the fix for voxgig/struct#113, closed 2026-08-25. elixir's suite never calls `connect` or `adopt`: eight ports carry a test that `as` and `instance` stay out of the SDK's options, and elixir, which has the same code, does not (found while W0.5 was checked). |
| W4.9 The `versions` CI job | DONE | Landed with W0.3 in `690b08f`. `build.yml` runs `make version-check` and `make release-plan-test` in their own job, and the hooks that carried the gate on `vendor-check` and `pack-diff` are gone from the `Makefile`. |


## W5. The proxy and the agent surface

| Item | Status | Notes |
|---|---|---|
| W5.1 [#46]: the proxy builds, scrubs in one pass, and has a CI lane | NOT STARTED | Against sekreto `32b83ac`, CI's pin: `internal/daemon/secrets.go:36:31: undefined: sekreto.MakeNamedChain` and `:41:18: undefined: sekreto.NewNamed` (run). Against sekreto `5cc462e`, the revision it was written for: it builds and `go test ./...` passes, 49 tests (run). So the port is one file: construct the broker with `sekreto.New(&sekreto.Options{…})`, as `go/station/secrets.go` does. Then the single-pass scrub from voxgig/station#28, with a test of two values that overlap. `proxy/go.mod` requires `sekreto/go v0.0.0`, the placeholder [#27] removed from the library. The CI lane is a workflow change: it follows as a patch on `main`, once the proxy builds there ([`patch/`](patch/README.md)). |
| W5.2 Sign off the two proposed decisions | DECISION NEEDED | DEC-2. |
| W5.3 `voxgig-station testkit` | NOT STARTED | The proxy in deterministic mode: a fixed clock and transcript-driven upstreams (`station.md` §13). Nothing in `proxy/` is named `testkit`. |
| W5.4 The wire's corpus sections | NOT STARTED | `envelope`, `degrade`, and the attached half of `redact`. Tier-scoped: A and B run them, C pins them as pending. |
| W5.5 Attach in typescript | NOT STARTED | No port holds a wire client: nothing outside `proxy/` names `/v1/register`, `/v1/events` or `Station-Proof`. Today `proxy: 'auto'` records "proxy absent (not found); running solo" without probing, and `require` raises `station_no_proxy` (`typescript/src/Station.ts:171-179`, `:337-360`, read). Scope: §8.1 discovery and the proof-of-token handshake, register, events, the forward envelope with `Station-Redact`, `resolve: proxy`, and §2.1's non-blocking `open()`. |
| W5.6 Attach in javascript | NOT STARTED | So that both released packages attach in the same release. |
| W5.7 End to end, and Phase 1's exit | NOT STARTED | A generated SDK through a local proxy: captures, injection and a `station_call` round trip asserted. The §11 quickstarts and the §12 agent transcript run for real. Needs W4.3. |
| W5.8 Attach in go and python, then tier A, then tier B | NOT STARTED | One port, one deliverable, each held by W5.4's sections and W5.3's testkit. |
| W5.9 A release route for the proxy binary | NOT STARTED | The daemon's `Version` already follows `VERSION`. A tag shape for a second Go module in this repository has to be chosen, and `release-plan` taught it. |


## W6 and W7. The rest of Phases 2 and 3

| Item | Status | Notes |
|---|---|---|
| W6.1 Replay, record and mock | NOT STARTED | `station_replay` enforces its gates and refusals today and reports execution as a later phase (`proxy/README.md`). |
| W6.2 SQLite capture persistence | NOT STARTED | With retention config. Encryption at rest is an open question (`station.md` §18). |
| W6.3 OTLP export | NOT STARTED | Proxy-only, by design (§10). |
| W6.4 Grants hardening, the revocation experience, config reload, a unix-socket listener | NOT STARTED | Each is listed as deferred in `proxy/README.md`. |
| W7.1 Remote mode | BLOCKED | On DEC-2 and on the multi-tenancy design `station.md` §18 asks for. |
| W7.2 Policy long-poll in the libraries; `station_call` write scopes | NOT STARTED | The proxy already serves `GET /v1/policy/{ref}` as a long-poll. |
| W7.3 Adapters for scala, clojure, haskell, ocaml, zig and lean | BLOCKED | On `sdkgen-10` and `sdkgen-11`. |
| W7.4 Secrets in the env-only ports | NOT STARTED | cpp, swift, dart, elixir and lua. c left this list with W1.6. [#58] assessed each against what sekreto ships: elixir is the easiest, cpp has C's shape, lua and dart can take sekreto's core now and wait for a mini vault, and swift is blocked on `sekreto-4`. Attached with `resolve: proxy`, a tier A or B port needs no sekreto of its own, which is W5.8's other benefit. |


## Clients

| Item | Status | Notes |
|---|---|---|
| C.1 voxgig/likeness | BLOCKED | On `sdk-1` to `sdk-3` for the red cells of its matrix. Its own step, W0.4, is done. W1.2 (eight Go entries) and W1.6 (the C port) are on station's `main` now, and reach likeness when it pins a station that carries them: for its Go port that is a release, so 0.3.0 (W2.11), and for C it also takes regenerated C SDKs. It still waits on W2.6 and W2.9 (parity). Its Stage 3, search and writes, also needs the Joplin and Notion definitions to carry search. |
| C.2 voxgig/station-view | DECISION NEEDED | DEC-6. The repository holds comment-policy tooling and no code. |
| C.3 senecajs/seneca-station | DECISION NEEDED | DEC-7. The repository holds a README and a licence. |


## Decisions

| Decision | Status | Gates |
|---|---|---|
| DEC-1 How a non-JavaScript consumer gets station | DECISION NEEDED | W3.2, W3.13, and the order of W3.4 to W3.8 |
| DEC-2 Sign off `D-2026-08-24-1` and `D-2026-08-24-2` | DECISION NEEDED | W5.2, W7.1 |
| DEC-3 Does station take voxgig/plugin as a dependency | DECISION NEEDED | Nothing. Deferred by design. |
| DEC-4 How far an event's host follows `URL.host` | DECISION NEEDED | W2.8 |
| DEC-5 The kill switch's contract | DECISION NEEDED | W2.10 |
| DEC-6 What station-view reads | DECISION NEEDED | C.2 |
| DEC-7 What seneca-station is | DECISION NEEDED | C.3 |


## Index: every open issue and pull request

| | row | | row | | row |
|---|---|---|---|---|---|
| [#29] | W2.3 | [#39] | W3.3 | [#55] | W2.8 |
| [#30] | W3.10 | [#42] | W3.9 | [#57] | W2.4 |
| [#31] | W3.1, W3.2 | [#46] | W5.1 | [#61] | W2.9 |
| [#36] | W2.6 | [#53] | W2.5 | [#63] | W2.1 |
| [#37] | W2.2 | [#54] | W2.7 | [#64] | W2.10 |

No pull request is open.

Closed since this register began, and so out of the table: [#24]
(W0.5) and [#27] (W0.1, W0.2); and with W1 on 2026-11-11, [#26], [#49]
and [#59] (W1.1), [#38] and [#50] (W1.2), [#52] (W1.3), [#45] (W1.5) and
[#23] (W1.6). The six pull requests were [#60], [#51], [#56], [#47],
[#48] and [#58].


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
