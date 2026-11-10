# The plan register

Live per-item state of [`plan.md`](plan.md). **A row changes in the same
commit that changes its status.** `DONE` means merged. A row moves to
`IN PROGRESS` when a pull request for it is open, which says work is
under way and not that it has landed.

Statuses: `NOT STARTED`, `IN PROGRESS`, `DONE`, `DECISION NEEDED`,
`BLOCKED` (on what, in the note), `DECIDED-NO`.

Every note below was checked on **2026-11-10** against `main` at
`a570686` unless it gives another date or revision. "Read" means the
code was read and the behaviour not run; "run" means it was run. What
station needs from other repositories is in [`upstream.md`](upstream.md),
and its rows are named here as `sdkgen-6`, `sekreto-1` and so on.

Every open issue and pull request maps to a row: the index is at the
end.


## W0. Close out 0.2.0

| Item | Status | Notes |
|---|---|---|
| W0.1 Tag `go/v0.2.0` on `a570686` | BLOCKED | On a maintainer with tag-push rights. `make release-plan` (run) prints `typescript done`, `javascript done`, `go tag`. `git ls-remote --tags` shows no `go/*` tag, and the Go proxy lists no version of `github.com/voxgig/station/go`. The commands and the check afterwards are in voxgig/likeness `HANDOVER.md` §1. A Go tag cannot be withdrawn, so tag only the commit `release-plan` names. |
| W0.2 Close [#27] | BLOCKED | On W0.1. Its first step, real versions in `go/go.mod`, landed in voxgig/station#32. The feature model already requires `v0.2.0`. |
| W0.3 One dispatch releases every port; CI gains a `versions` job | BLOCKED | On a maintainer whose token has the `workflow` scope. `station-release-workflow.patch`, in likeness `upstream/patch/`, still applies: `git apply --check` is clean (run). It edits `build.yml`, `release.yml`, `AGENTS.md` and the `Makefile`, and answers the review thread left open on voxgig/station#65. |
| W0.4 likeness onto station 0.2.0 | BLOCKED | On W0.1, because `go mod tidy` needs the tag. `likeness-station-go-v0.2.0.patch`; likeness `HANDOVER.md` §3. |
| W0.5 Close [#24] | NOT STARTED | Fixed on `main` by `b145609` (voxgig/station#28) and shipped in 0.2.0: `construct()` takes `as` and `instance` out before the SDK sees its options (`typescript/src/Station.ts:205`, read). The ports with `connect` pin it in their suites. Not re-run against a generated SDK (W4.3). |
| W0.6 Prune merged branches | NOT STARTED | Eighteen remote branches are fully merged into `main`. `chore/comment-policy` is one commit ahead and conflicts in four files; its change looks like what landed, squashed, as voxgig/station#22. Confirm, then delete. |
| W0.7 This register, and the README and design status lines brought back to the code | DONE | This change. The README table said the declarative front door was pending in ten ports that have it, that five ports had no toolchain when CI runs all five, and that the proxy was deferred when `proxy/` holds one. `station.md` §17 and `station-and-plugin-plan.md` §0 and §3 said the same. |
| W0.8 The design's account of sdkgen, brought up to date | NOT STARTED | `station.md` §9 item 3 and `station-declarative-config.md` §11 describe sdkgen as it stood in August: seventeen of twenty `Config_*` components passing their target name (all twenty do), the constructor's `extend` tolerance still to come (the ts, js and py templates carry it; the others were not checked), and a per-feature option schema as later work (it shipped as `optspec`). [`upstream.md`](upstream.md) carries the current state. The prose should say what station still needs and point there for the rest. |


## W1. Land the review queue

All six were green at their heads on 2026-10-15 and are 18 to 20 commits
behind `main`, so each needs its branch updated and CI re-run. Every
review thread on them is resolved: four on [#60], three on [#51], one on
[#58], none on the others. None has an approval.

**Trial merge, 2026-11-10.** All six onto `a570686`, in the order below,
with the two resolutions the notes give. `make vendor-check`,
`version-check`, `comments` and `omni-isolation` pass, and no payload
needed `vendor-refresh`. Eleven port suites pass: typescript (158 tests:
138 pass, 20 skipped), javascript (29), go, python, ruby (80 and 12),
php (73), perl, java (62), rust, c (with its new secrets suite) and
cpp. csharp, swift, dart, elixir and lua were **not** run, for want of a
toolchain; CI runs them. The merged tree was not pushed anywhere.

| Item | Status | Notes |
|---|---|---|
| W1.1 [#60]: a named instance gets its declared options; feature options are checked as the SDK checks them | IN PROGRESS | Closes [#26], [#49], [#59]. Net against `main`: 109 files, +6,966 −695. Merges clean. Gives csharp and swift named instances and the `instanceref` section, so they run nine. Gives up typo detection for a non-strict feature, as the SDK does (`sdkgen-5`). |
| W1.2 [#51]: an `http` event's path, exactly as sent | IN PROGRESS | Closes [#50], and the station half of [#38]: that issue's `..` row was voxgig/sdkgen#414, closed 2026-10-17. Merges clean. likeness's Go port waits on it for eight transcript entries. |
| W1.3 [#56]: an `http` event's host, as `URL.host` reads it | IN PROGRESS | Closes [#52]. Stacked on [#51]; after that merges it is left with its own two commits. Also fixes a policy bypass in rust and swift, which read a URL's user name as its host: `https://api.test:x@evil.test/x` passed an allowlist naming `api.test`. Leaves [#53], [#54], [#55] to W2. |
| W1.4 [#47]: the sekreto ranges in `AGENTS.md` | IN PROGRESS | Two lines. Merges clean. |
| W1.5 [#48]: `(§N)` in every port's refusal messages | IN PROGRESS | Closes [#45]. After [#60] it conflicts in `csharp/src/Station.cs` and `swift/Sources/VoxgigStation/Station.swift`, one hunk each, both the `station_bound_twice` message: keep [#60]'s wording (`instance "…"`) with this one's citation (`(§10.2)`). Pins eight refusals whole in the corpus. |
| W1.6 [#58]: the C port resolves through sekreto's C port | IN PROGRESS | Closes [#23]. Conflicts with `main` in `AGENTS.md`, one hunk under "Checks worth knowing": keep its `vendor-check` line and `main`'s `sync-shape` line. After W0.7 it also conflicts in `README.md`'s C row: take its secrets and validation cells, and this change's declarative cell. Net: 32 files, +7,879 −250, most of it sekreto's C core vendored at `32b83ac`. The C lane then needs libcrypto and the plugin checkout. Its `-D_DEFAULT_SOURCE` workaround goes with `sekreto-3`. |


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
| W2.5 [#53]: an unparseable URL's userinfo stays out of the event | NOT STARTED | After W1.2 and W1.3, which set the rule it amends. When a string is reported whole and has a scheme and `://`, drop everything up to the last `@` of its authority first. Pin two rows in every port. |

### W2b. Parity and semantics

| Item | Status | Notes |
|---|---|---|
| W2.6 [#36]: one `op` event per operation | NOT STARTED | The binding emits from every hook stage that can end an operation. The generator's double `PreUnexpected` is fixed (voxgig/sdkgen#413, closed 2026-10-17), but only a regenerated SDK carries that, and go emitted two regardless. Key the event on the operation's context so the count is one whatever generated the SDK. `sdkgen-8` changes which stages fire. Pin: one failed operation, exactly one `op` event. |
| W2.7 [#54]: the policy's hostname | NOT STARTED | rust and swift read an IPv6 host without its brackets, so an allowlist entry `[::1]` never matches there. No port pins the policy's hostname directly: pin an allow and a deny for an IPv6 host, an explicit default port, and userinfo with a raw `@`. |
| W2.8 [#55]: the four forms that still differ from `URL.host` | DECISION NEEDED | DEC-4. |
| W2.9 [#61]: an unpaired surrogate escape in `station.json` | NOT STARTED | Refuse with `station_config_invalid` in every port, as I-JSON requires. go needs a scan of the raw text, since `encoding/json` has already replaced the escape. Corpus: a lone high, a lone low, and a valid pair that must still be accepted. |
| W2.10 [#64]: the kill switch | DECISION NEEDED | DEC-5. Today mode `block` raises `station_host_allow`, the allowlist's code (`typescript/src/Station.ts:354-357`, read), and the config is read once, at construction. |
| W2.11 Release 0.3.0 | NOT STARTED | After W2a. `make version-set V=0.3.0`, typescript and javascript through `release.yml`, `go/v0.3.0` on the same commit. The notes name the three behaviour changes in `plan.md` §6. |


## W3. Installable in every language

What is published where is in [`upstream.md`](upstream.md), under
"Registries".

| Item | Status | Notes |
|---|---|---|
| W3.1 The route | DECISION NEEDED | DEC-1. |
| W3.2 [#31]: the feature model writes a dependency that resolves, and an optional one where the language allows | BLOCKED | On W3.1. `sdkgen-station/.sdk/model/feature/station.aontu` names `voxgig-station` (PyPI), `voxgig_station` (RubyGems, pub.dev, Hex, crates.io), `voxgig/station` (Packagist), `com.voxgig:station` (Maven) and `Voxgig.Station` (NuGet). None exists. Its Swift entry names `https://github.com/voxgig/station-swift`, which is not a public repository. Go needs only W0.1. |
| W3.3 [#39]: Python installs outside a checkout | NOT STARTED | Not gated on DEC-1: these are defects on any route. `shape.py:183` reads `spec/config-shape.json` by a checkout-relative path; ship it as package data and have `make sync-shape` keep it in step, as it does for typescript and javascript. `structhome.py` looks for a struct checkout and says struct is unpublished; `voxgig-struct` is on PyPI. `pyproject.toml` requires `voxgig-sekreto>=0.1`, which is not (`sekreto-1`). |
| W3.4 Ruby: a gemspec | NOT STARTED | `ruby/` has none, so Bundler can take the port neither from git nor from a registry. |
| W3.5 PHP: a manifest that states its requirements | NOT STARTED | `php/composer.json` requires only `php`; sekreto is found through `SEKRETO_HOME` or a sibling checkout. Composer reads a VCS package from a repository's root, not a subdirectory. |
| W3.6 Java and Kotlin: a build file | NOT STARTED | `java/` has a Makefile and no `pom.xml` or Gradle build, while the feature model names Maven coordinates. |
| W3.7 Rust: dependencies that resolve without `make vendor` | NOT STARTED | `Cargo.toml` path-depends on `vendor/sekreto` and `vendor/struct`, links the Makefile makes to sibling checkouts. struct has a crate; sekreto has none. |
| W3.8 csharp, swift, dart and elixir manifests | NOT STARTED | After the four above. csharp takes sekreto by `ProjectReference`. SwiftPM needs a package at a repository's root. |
| W3.9 [#42]: the Perl payload carries voxgig/plugin | NOT STARTED | `Voxgig::Sekreto` requires `Voxgig::Plugin` at load, and the payload does not carry it, so a generated Perl SDK works only where a plugin checkout is on `@INC`. Vendor it through `tools/vendor.py`, hold it in `make vendor-check`, correct `VENDORED.md`, and make the bootstrap name the module that was missing. |
| W3.10 [#30]: a generated SDK registers itself, or its README says what it needs | BLOCKED | On `sdkgen-7`. sdkgen generates the registration for ts and js only. In Go an explicit `station.Provide` was verified to work (the issue). The README text is sdkgen's `ReadmeStation`. |
| W3.11 A release route for `@voxgig/sdkgen-station` | BLOCKED | On a maintainer: `npm trust` for a third package, and a `port` value in `release.yml`, which needs the `workflow` scope. The package has never been published (`npm view` finds nothing). Its version is outside `VERSION` by decision. |
| W3.12 Generated C SDKs resolve through sekreto | NOT STARTED | After W1.6, which leaves them env-only: the payload is built with `VXSTN_ENV_ONLY`. sdkgen-station would have to carry sekreto and plugin's C host beside sdkgen's own `secrets` feature, which vendors sekreto at a different commit. |
| W3.13 The fleet's SDKs regenerated | BLOCKED | On W0.1 and `sdk-1`. The four regeneration pull requests are open and were generated on sdkgen 4.34.6. No SDK in voxgig-sdk carries the station feature on its default branch. |


## W4. One contract in every port

| Item | Status | Notes |
|---|---|---|
| W4.1 A completeness guard in typescript | NOT STARTED | `typescript/test/conform.test.ts` writes one test per section by hand. `spec/README.md` records the mutation: a bogus section passes typescript and fails ten other ports. |
| W4.2 The last five ports take Stage 5's tranche | NOT STARTED (0/5) | csharp, swift, dart, elixir, lua. Each needs the `config`, `feature` and `instanceref` sections, the declarative front door (`sdk`, `create`, `check`, `warm`, `features`, `instances`), struct validation at `open()`, and a guard. All five already read the `sdk` grammar and run eight sections (CI run 39025102214). W1.1 gives csharp and swift `instanceref`. One deliverable per port. |
| W4.3 A fixture lane: generated SDKs, and the integration suites run against them | NOT STARTED | The suites look for `$STATION_TEST_SDKS/taskpad-sdk/ts/dist` and for `STATION_TEST_RB_SDK`, `STATION_TEST_PHP_SDK` and `STATION_TEST_PERL_SDK`. Nothing in the repository generates them. In CI, typescript's `quickstart`, `gnarly-pets` and `generated-feature` suites skip, javascript's two skip, ruby's nine quickstart cases skip and perl's `t/quickstart.t` skips. Inputs exist: `test/api/taskpad` and `test/api/gnarly-pets`. This is the lane `station.md` §9.5 and §13 require. The CI job needs the `workflow` scope; a `make` target does not. |
| W4.4 Pin `plugin` and `struct` in `build.yml` | BLOCKED | On the `workflow` scope. The file's own comment says to pin once Stage 5 completes. Heads observed: plugin `8605cdc`, struct `18d6237`, which moved on 2026-11-10. The typescript lane links no struct checkout: it tests npm's 0.2.2 from the lockfile, while every other lane tests struct `main`. |
| W4.5 typescript onto struct 0.3 | NOT STARTED | `^0.2.2` excludes 0.3.x; npm's latest is 0.3.7. javascript is on the latest `struct-js`, 0.1.7. |
| W4.6 The corpus sections §13 names and `spec/station.json` lacks | NOT STARTED | `inject`, `order`, `redact`, `event`, `degrade`, `envelope`. `event` first: [#50], [#52] and [#36] are each pinned once per port because no section can see an event. `envelope` and `degrade` belong to W5.4. |
| W4.7 Plugin conformance (C4a, C4b) | DONE | Continuous, so "done" means wired and red on drift. `typescript/test/c4-plugin.test.ts` landed in `ce0819b` (2026-08-24), and CI's typescript lane sets `STATION_REQUIRE_C4=1`, so a missing plugin checkout fails the lane. Run against plugin `8605cdc`: 144 pass, 0 pinned divergences, 128 skipped, each with its reason. plugin's own register still says `NOT STARTED` (`plugin-1`). |
| W4.8 Small repairs | NOT STARTED | The root `make test-dart` runs `dart test`, and the port has no `package:test`; CI uses `make -C dart test`, which works. The explicit first-element checks of `station-declarative-config.md` §4.4 can go once every port's struct carries the fix for voxgig/struct#113, closed 2026-08-25. |
| W4.9 The `versions` CI job | BLOCKED | Part of W0.3's patch. Until then `make vendor-check` and `make pack-diff` run `version-check` first. |


## W5. The proxy and the agent surface

| Item | Status | Notes |
|---|---|---|
| W5.1 [#46]: the proxy builds, scrubs in one pass, and has a CI lane | NOT STARTED | Against sekreto `32b83ac`, CI's pin: `internal/daemon/secrets.go:36:31: undefined: sekreto.MakeNamedChain` and `:41:18: undefined: sekreto.NewNamed` (run). Against sekreto `5cc462e`, the revision it was written for: it builds and `go test ./...` passes, 49 tests (run). So the port is one file: construct the broker with `sekreto.New(&sekreto.Options{…})`, as `go/station/secrets.go` does. Then the single-pass scrub from voxgig/station#28, with a test of two values that overlap. `proxy/go.mod` requires `sekreto/go v0.0.0`, the placeholder [#27] removed from the library. The CI job needs the `workflow` scope. |
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
| W7.4 Secrets in the env-only ports | NOT STARTED | cpp, swift, dart, elixir and lua, and c until W1.6. [#58] assessed each against what sekreto ships: elixir is the easiest, cpp has C's shape, lua and dart can take sekreto's core now and wait for a mini vault, and swift is blocked on `sekreto-4`. Attached with `resolve: proxy`, a tier A or B port needs no sekreto of its own, which is W5.8's other benefit. |


## Clients

| Item | Status | Notes |
|---|---|---|
| C.1 voxgig/likeness | BLOCKED | On W0.1 for its own step, and on `sdk-1` to `sdk-3` for the red cells of its matrix. From this plan it waits on W1.2 (eight Go entries), W1.6 (the C port, with the regenerated C SDKs) and W2.6 and W2.9 (parity). Its Stage 3, search and writes, also needs the Joplin and Notion definitions to carry search. |
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
| [#23] | W1.6 | [#38] | W1.2 | [#53] | W2.5 |
| [#24] | W0.5 | [#39] | W3.3 | [#54] | W2.7 |
| [#26] | W1.1 | [#42] | W3.9 | [#55] | W2.8 |
| [#27] | W0.1, W0.2 | [#45] | W1.5 | [#57] | W2.4 |
| [#29] | W2.3 | [#46] | W5.1 | [#59] | W1.1 |
| [#30] | W3.10 | [#49] | W1.1 | [#61] | W2.9 |
| [#31] | W3.1, W3.2 | [#50] | W1.2 | [#63] | W2.1 |
| [#36] | W2.6 | [#52] | W1.3 | [#64] | W2.10 |
| [#37] | W2.2 | | | | |

Pull requests: [#47] W1.4, [#48] W1.5, [#51] W1.2, [#56] W1.3,
[#58] W1.6, [#60] W1.1.


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
