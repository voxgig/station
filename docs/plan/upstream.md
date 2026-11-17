# The upstream register

What station needs from repositories it does not own, and what it pins
of them. One row per ask. The items these rows gate are in
[`progress.md`](progress.md).

**A row is `DONE` when the change has merged upstream**, and the row
names where. A fix in sdkgen reaches a generated SDK only when that SDK
is regenerated, so "done upstream" and "in an SDK" are tracked apart
(see "The generated SDKs").

Everything below was observed on **2026-11-10**. Issue states were read
through GitHub's search API, package lists from each registry, and
sdkgen at its `main`, `66de706` (4.41.0).

Checked again on **2026-11-11**: every issue and pull request a row
below gives as open is still open, and the heads of struct and sdkgen
had moved, as the pins table says. sdkgen's source was not read again.

On **2026-11-12** the eleven asks that had no issue were filed, on the
owner's instruction. Before that, the three sdkgen rows were read again
at sdkgen `9aebaf9` (4.44.0), the two sekreto rows at sekreto
`ee83713`, and the plugin row at plugin `8605cdc`. All six still held.

States: `DONE`, `OPEN` (an issue or pull request exists upstream),
`NOT FILED` (station needs it and nothing upstream tracks it),
`WATCH` (nothing is owed, but a change there will reach
station), `DECISION NEEDED`.


## What station pins

| dependency | role | where it is pinned | pinned at | upstream now |
|---|---|---|---|---|
| **voxgig/sekreto** | library | `build.yml` checkout | `32b83ac` (voxgig/sekreto#34, 2026-09-16) | `main` is `ee83713` |
| | | `go/go.mod` | a pseudo-version of `32b83ac` | no `go/v*` tag exists |
| | | `proxy/go.mod`, since W5.1 | a pseudo-version of `32b83ac` | — |
| | | `typescript/package.json` | `^0.3.0`, locked 0.3.0 | npm 0.3.0 |
| | | `javascript/package.json` | `@voxgig/sekreto-js` `^0.2.0`, locked 0.2.0 | npm 0.2.0 |
| | | `python/pyproject.toml` | `voxgig-sekreto>=0.1` | not on PyPI |
| | | `c/vendor/sekreto`, since W1.6 | `SEKRETO_C_COMMIT`, `32b83ac` | — |
| **voxgig/struct** | library | `build.yml` checkout | **unpinned**, until Stage 5 is complete, and not pinned for the drift of 2026-11-16 (D-2026-11-17-1) | `main` is `03b9f2f` on 2026-11-17, the release bump (`struct-7`). On 2026-11-16 it dropped `$ONE` (`struct-3`). |
| | | `typescript/package.json` | `^0.2.2`, locked 0.2.2 | npm 0.3.7, outside the range. W4.10 takes 0.4.0 once it is out (`struct-7`). |
| | | `javascript/package.json` | `@voxgig/struct-js` `^0.1.7`, locked 0.1.7 | npm 0.1.7. W4.10 takes 0.2.0. |
| | | `go/go.mod` | `v0.1.6` | `go/v0.1.6`. W4.10 takes `go/v0.2.0`. |
| | | `rust/Cargo.toml` | a path to `vendor/struct`, a link to the sibling checkout; the lock records 0.1.7 | crates.io 0.1.7 |
| **voxgig/plugin** | sekreto's dependency; the C4 corpus | `build.yml` checkout | **unpinned**, on purpose | `main` is `8605cdc` |
| | | `go/go.mod`, indirect | a pseudo-version of `91f294b` (2026-09-01) | `go/v0.2.0` |
| | | typescript lockfile, transitive | 0.1.7 | npm 0.2.0 |
| **voxgig/omni** | tests only | `build.yml` checkout | `dcbab7a` (voxgig/omni#36, 2026-08-22) | `main` is `ef55ad0`; npm 0.2.0; `go/v0.2.0` |
| **voxgig/sdkgen** | generator, for sdkgen-station | `sdkgen-station/package.json` peer | `>=3.6` | npm 4.44.1 on 2026-11-17, still vendoring struct at `sdk-20261016-0845-0`, which has `$ONE` only (`sdkgen-18`); `main` is `a939e09` |

Three things in that table are worth knowing. The first two are rows
W4.4 and W4.5 of the plan register:

- **struct and plugin float in CI, and both by decision.** `build.yml`
  leaves plugin unpinned so that drift from plugin's corpus goes red,
  which is the C4 contract working, and leaves struct unpinned until
  Stage 5 is complete. So a change in either reaches every station pull
  request. A lane that goes red on an unrelated change is upstream
  drift until shown otherwise.
- **The canonical port tests a different struct from every other
  port.** The typescript lane links no struct checkout, so it runs
  npm's 0.2.2 from the lockfile, while the other fifteen run struct
  `main`.
- **Moving the sekreto pin is five edits**: `build.yml`, `go/go.mod`,
  `proxy/go.mod` (since W5.1), the npm ranges, and `SEKRETO_C_COMMIT`
  with a `make vendor-refresh` (since W1.6).


## Registries

Where each package is published. "—" means the registry was queried
and has no such package. A blank means it was not checked.

| | npm | Go tags | PyPI | RubyGems | crates.io | NuGet | Maven Central | Packagist | Hex | pub.dev |
|---|---|---|---|---|---|---|---|---|---|---|
| **station** | 0.2.0, and `-js` 0.2.0 | v0.2.0 | — | — | — | — | — | — | — | — |
| **sdkgen-station** | — | | | | | | | | | |
| **sekreto** | 0.3.0, and `-js` 0.2.0 | — | — | — | — | — | | | | |
| **struct** | 0.3.7, and `-js` 0.1.7 | v0.1.6 | yes | yes | 0.1.7 | yes | — | — | yes | yes |
| **plugin** | 0.2.0, and `-js` 0.2.0 | v0.2.0 | — | | — | | | | | |
| **omni** | 0.2.0 | v0.2.0 | | | | | | | | |

The consequence is what DEC-1 ruled on, and its answer is the staged
route (D-2026-11-11-1). Station cannot be published anywhere but npm
until sekreto is, and sekreto's own Python package takes plugin from
git because plugin is not on PyPI either. At `32b83ac`, sekreto's Ruby
and PHP ports carry no gemspec and no `composer.json`.


## voxgig/sdkgen

The design's asks are `station.md` §9 and
`station-declarative-config.md` §11. Most have shipped since those
sections were written.

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| sdkgen-1 | Every feature model declares its `transport` role, and `configDefinition` carries it (§11 items 6 and 7) | in the tree | DONE | Nothing. Twenty bundled models carry it: one `base`, eight `wrap`, eleven `none`. |
| sdkgen-2 | A per-feature option schema (§11 item 8, planned for "later") | in the tree, as `optspec` (`ts/src/helpers/optspec.ts`) | DONE | Nothing. W1.1 was station catching up with it. |
| sdkgen-3 | `ReadmeStation`, the agent-guide paragraph, `docs/how-to/use-station.md`, and an error-code catalog (§9.4; §11 items 3 to 5) | in the tree | DONE | Nothing. The how-to leads with the declarative flow. |
| sdkgen-4 | `configDefinition(model, target.name)` in every `Config_*` component (§9.3) | in the tree | DONE | Nothing. All twenty do; the design still says seventeen (W0.8). |
| sdkgen-5 | A misspelled feature option is refused | [sdkgen#422] | OPEN | What W1.1 gave up. Every feature defaults to `strict: false`. See also `struct-2`. |
| sdkgen-6 | An `extend`-carried feature is added at its `featureorder` slot, not appended when its `__after__` anchor is absent | [sdkgen#489] | OPEN | Filed 2026-11-12. W2.1, for newly generated SDKs. `Main.fragment.ts` skips the name in the ordered loop and adds it afterwards "positioned by its own `__after__` entry"; `FeatureAddUtility.ts` appends when the anchor is missing. |
| sdkgen-7 | A generated SDK registers itself with station at module load in every target that can express it (§6.2; §11 item 2) | [sdkgen#490] | OPEN | Filed 2026-11-12. W3.10, and Stage 4's exit outside ts and js. Only `cmp/ts` and `cmp/js` have a `MainStation` fragment, and `ReadmeStation` tells ten targets that loading the package registers it. |
| sdkgen-8 | `PreDone` runs for every operation that ends | [sdkgen#428] | OPEN | W2.6. It decides which stage station's `op` event can ride. |
| sdkgen-9 | The SDK does not keep a hoisted credential in its own options | [sdkgen#491]; related: [sdkgen#274] | OPEN | Filed 2026-11-12. The SDK half of W2.2. [#37] found the key under `options().__derived__.clean.values`, and at 4.44.0 `options()` still returns a clone that includes the clean registry. W2.2 took station's copies out; on 2026-11-12 the adopt path still showed a resident key there, and nowhere else, in a ts and a php SDK generated by 4.44.0 (run). |
| sdkgen-10 | `Package_*` consumes `collectDeps` in clojure, ocaml and scala, and in haskell and lean in the language pack (§9.2) | —; sdkgen `docs/design/feature-tags.md` | NOT FILED | W7.3. Twelve targets call it now, elixir among them, which the design still lists as missing. ts and js carry feature deps inline; c, cpp and zig vendor. |
| sdkgen-11 | Feature tags: which features a target can take | sdkgen `docs/design/feature-tags.md`, a proposal dated 2026-08-17 | OPEN | W7.3, for the targets whose features live in one module. |
| sdkgen-12 | — | [sdkgen#430] | WATCH | It reports that a feature passed in `extend` fires its hooks whatever `active` says. Station's carried adapter rides `extend` and depends on its hooks firing. A fix there has to keep that working. |
| sdkgen-13 | Two generated Ruby SDKs load in one process | [sdkgen#404] | OPEN | Station's premise in Ruby: many SDKs, one process. likeness proved the collisions inert for what it uses. |
| sdkgen-14 | A TLS trust option in every transport | [sdkgen#408] | OPEN | likeness's Obsidian source. Station passes `options.tls` through and owns none of it. |
| sdkgen-15 | Does sdkgen adopt voxgig/plugin? (plugin's design §17.2) | plugin's register, item 6.2 | DECISION NEEDED | Nothing here. It is the "second consumer" this plan wanted DEC-3 to wait for. DEC-3 was ruled without it on 2026-11-11 (D-2026-11-11-4), so until sdkgen decides, station is plugin's only consumer. |
| sdkgen-16 | A public `client.extend()` late-attach seam (`station.md` §18) | — | NOT FILED | Nothing. It would upgrade `adopt()` beyond construction time; v1 does not need it. |
| sdkgen-17 | One id for a call across `telemetry`'s span, `debug`'s entry and `audit`'s record | — | NOT FILED | W9.5. The span carries `traceId` and `spanId`, the audit record carries `correlationId`, the context's id, and the debug entry carries no id of its own (read, at 4.44.0). station-view joins the three by client, operation and time until they share one. |
| sdkgen-18 | Vendor struct at a checkpoint that has `$NOF`, and generate specs with `$NOF` in place of `$ONE` | — | NOT FILED | W4.10. Without it every SDK sdkgen generates holds a struct that station 0.4.0's shape cannot use, in ruby, perl, php, c and cpp. **Ready on sdkgen's `claude/bold-newton-4of9bo` at `dee8b22`, and waiting on the checkpoint.** `7cbda27` re-vendors at a local tag, `sdk-local-nof`, which names struct `03b9f2f`, and must not merge as it is; `dd797f6` writes every spec as `$NOF`. As the owner ruled on 2026-11-17 (D-2026-11-17-2), the ten targets whose struct copies no route produced, rb, php, rust, c, cpp, swift, scala, clojure, elixir and ocaml, are routed and resynced at the same tag, each built and run on its own toolchain (target by target below), and `dee8b22` deletes the `$ONE` shim: a spec that still names `$ONE` is refused at generation. On `dee8b22`, `make all` passed: 3236 tests, none failed, 96 skipped where a toolchain or a header is missing (run). Re-checked apart from that run: `make vendor-check` clean at 80 routes; the vendoring, null, option-spec and swift-type guards, 220 tests; and cpp's secrets and entity lanes (run). Three struct defects are carried as marked patches until struct fixes them (`struct-9` to `struct-11`). create-sdkgen's struct corpus is struct's own at `03b9f2f`, on its `claude/bold-newton-4of9bo` at `b9fb8e9`, and a project re-pulls it, since the runners now run `validate.nof`. The checkpoint will also move omni to `ef55ad0` and plugin to `8605cdc`, past the commits `sdk-20261016-0845-0` names, and that part of the resync is not run yet. After it: a pull request in each of sdkgen and create-sdkgen, then sdkgen's release. |
| sdkgen-19 | The `debug` feature records the URL a call was sent to | — | NOT FILED | Found by W9.6, in the ts template at sdkgen 4.44.1; the other targets are not read. `PreRequest` runs before `makeFetchDef` sets `spec.url`, so the entry takes `spec.path`, the route (`api/planet/{id}`), and `PreResponse` keeps it: `entry.url = entry.url \|\| spec.url`. A call with path parameters is reported by its route, never by its address. station-view shows the route as written. |
| sdkgen-20 | Does a swift SDK refuse invalid options, as every other target's does? | — | DECISION NEEDED | Found by W4.10 (`sdkgen-18`) on 2026-11-17. A swift SDK's `makeOptions` has never refused anything, because the struct copy it carried dropped validate's errors. struct's swift `validate` now throws, and the resync keeps the old behaviour on purpose: `validateKept` and `transformKept` discard the errors. Refusing needs a throwing initialiser or a trap, and that is the owner's call. |
| sdkgen-21 | Every target's struct-corpus runner runs every `validate` group | — | NOT FILED | Found by W4.10 (`sdkgen-18`) on 2026-11-17. struct's corpus now has six more groups: `directive`, `all`, `len`, `range`, `like` and `unknown`. rust's runner, whose completeness guard asks for every group, runs them; the others run the groups they name, `nof` among them, and none of the six (read). |

### sdkgen-18, target by target

The ten targets of D-2026-11-17-2, resynced on sdkgen's
`claude/bold-newton-4of9bo` at `sdk-local-nof` (run, 2026-11-17).
"Generated SDK" is the generated solardemo SDK's own suites, with its
struct corpus where it carries one; "lanes" are sdkgen's
`generatedcompile` lanes for the target.

| target | commit | generated SDK | lanes | notes |
|---|---|---|---|---|
| php | `9ced9e9`, after `c5e82bb` | 265 tests, none failed; 53 skipped, features this SDK lacks | 44, all passed | |
| rb | `2bcb977`, `4439a1d` | 267 runs, none failed; 58 skipped, features this SDK lacks | 56 passed | struct's null class moves, and `structnull.test.ts` pins it |
| rust | `888398f` | 125 passed | 41 passed | the one runner that runs every `validate` group (`sdkgen-21`) |
| c | `a7f63eb` | 14 binaries, 355 checks; struct corpus, 1256 cases | 36 passed; 1 skipped, the secrets lane, for want of libcurl and OpenSSL headers | one patch (`struct-9`) |
| cpp | `1aef54b` | 15 binaries, 452 checks; struct corpus, 1317 cases | 34 passed; 2 skipped, transport probes | one patch (`struct-10`) |
| elixir | `046d3dc` | 153 passed; struct corpus, 1317 cases | 25 passed; 1 skipped, Hex | |
| ocaml | `a03b5d3` | 68 passed; struct corpus, 1322 cases | 26 passed; 2 skipped | run on OCaml 4.14, where CI's is 5 |
| scala | `4ba2e8c` | every suite passed; struct corpus, 1322 cases | 16 passed | routes both its struct copies, the scala port and a java `Struct.java` |
| clojure | `8d7b356` | 149 passed; struct corpus, 1289 cases | 17 passed | |
| swift | `8c8bd93` | 111 tests, 110 passed; struct corpus, 1265 cases | 25 passed | ten patches (`struct-11`), and `sdkgen-20`. The failing test, `testTheSweepCanSeeALeakCleanSwitchedOffShowsTheCredential`, fails the same way before the resync. |


## voxgig/sekreto

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| sekreto-1 | Releases beyond npm, starting where the fleet generates: PyPI and RubyGems, then the rest; and a `go/v*` tag | [sekreto#43] | OPEN | Filed 2026-11-12. W3.3 to W3.8, on the staged route. PyPI waits on `plugin-5`, since sekreto's Python metadata names plugin by URL. |
| sekreto-2 | Its Python metadata pins voxgig/plugin | [sekreto#44] | OPEN | Filed 2026-11-12. W3.3. `python/pyproject.toml` requires `voxgig-plugin @ git+https://github.com/voxgig/plugin.git#subdirectory=python`, with no revision, so a pinned station and a pinned sekreto still resolve whatever plugin's default branch is that day ([#39]). |
| sekreto-3 | `minivault.c` declares what it calls | [sekreto#41] | DONE, closed 2026-10-15 | W1.6 compiles with `-D_DEFAULT_SOURCE` until `SEKRETO_C_COMMIT` moves past the fix. |
| sekreto-4 | A Swift package and mini vault; AES-GCM for Dart's mini vault; a native crypto module for Lua's | — | NOT FILED | W7.4. From [#58]'s assessment of each port; not re-checked here. |
| sekreto-5 | An OS-keychain provider (`station.md` §18) | — | NOT FILED | Nothing. Wanted by the design's first draft. |
| sekreto-6 | Are the publish-time `aql` vault and the `boru` provider one vault or two? (`station.md` §18) | — | NOT FILED | Nothing. An open design question. |
| sekreto-7 | Its TypeScript port takes `@voxgig/plugin` `^0.1.3` | — | NOT FILED | Found by W8.6: station's typescript takes `^0.2.0`, so an install holds 0.2.0 and sekreto's 0.1.7 (run). Harmless while the two hosts never meet; one copy once sekreto moves to 0.2. |


## voxgig/struct

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| struct-1 | `$CHILD` in list mode validates element 0 | [struct#113] | DONE, closed 2026-08-25 | W4.8: station's explicit first-element checks can go once every port's struct carries the fix. |
| struct-2 | A closed map whose keys are all optional still refuses an undeclared key | [struct#175] | OPEN | `sdkgen-5`. A strict feature refuses a misspelled option only when a correctly spelled one is passed beside it. Found by W1.1. |
| struct-3 | — | [struct#178], a parity pull request across its ports | DONE, merged 2026-11-16 | It replaced `$ONE` with `$NOF` and made `validate` refuse a checker it lacks. Station's CI went red the same day: W4.10, D-2026-11-17-1. |
| struct-4 | Packages on Packagist and Maven Central | — | NOT FILED | W3.5, W3.6. It is on every other registry station's ports use. |
| struct-5 | Perl's `parse_json` decodes an escaped surrogate pair as one character | — | NOT FILED | Found by W2.9: it decodes each `\u` escape on its own, so `\ud83d\ude00` arrives as two surrogate characters (run, at `055ac4a`). Station's perl joins the halves after it reads (`jsonform`), and the corpus holds it to that. |
| struct-7 | A release that carries `$NOF`: `@voxgig/struct` 0.4.0, `@voxgig/struct-js` 0.2.0, `go/v0.2.0` | [struct#180], the version bump | OPEN: the bump merged on 2026-11-17, and nothing is published yet | W4.10. Prepared from this session, and merged with one CI job red on the owner's ruling (`struct-8`). The owner dispatches `publish.yml` for typescript and for javascript, and runs `make publish-go` for the go tag. typescript's lane is red until npm has 0.4.0. |
| struct-6 | Perl's `parse_json` reads a value that begins with an unexpected character as an empty number | — | NOT FILED | Found by W2.15: `x`, `{"a": x}` and a text that begins with a byte order mark each print `Argument "" isn't numeric in int`, then are refused at the next delimiter, as trailing data or a missing `,` (run, at `055ac4a`). The text is refused either way, so station's answer is right; the warning reaches its perl suite's output, and the refusal names the wrong fault. |
| struct-8 | `test-php (macos-15)` gets as far as struct's tests | — | NOT FILED | Found by W4.10 on 2026-11-17. The job fails inside `shivammathur/setup-php`, before any of struct's code runs: `Could not setup PHP 8.3`, after `php_config: parameter null or not set`. It failed so twice on [struct#180], and `main`'s build of `1ba9203` was cancelled in it after 28 minutes. Until it passes, no struct build is green on every leg. |
| struct-9 | c's `getpath` reads each step as `getprop` does, so a stored null is no value | — | NOT FILED | Found by W4.10 (`sdkgen-18`) on 2026-11-17, at `03b9f2f`: each step reads the raw value, so `getpath({a: null}, 'a')` gives null where the canonical gives no value. create-sdkgen's `nullsem` corpus sees it; struct's own corpus has no case that does. sdkgen's c copy carries a marked patch until struct is fixed. |
| struct-10 | cpp's `validate` admits a function in a `$NOF` alternative | — | NOT FILED | Found by W4.10 (`sdkgen-18`) on 2026-11-17, at `03b9f2f`: `admits` asks `keeps` whether validate gave the value back as it was, `keeps` asks `deepequal`, and no two cpp functions compare equal. So an option holding a function, a secrets provider, an audit sink or a clock, is refused. Four of sdkgen's cpp lanes failed on it, and its cpp copy carries a marked patch. |
| struct-11 | swift's `Value` can hold an opaque native value | — | NOT FILED | Found by W4.10 (`sdkgen-18`) on 2026-11-17: a swift SDK keeps native objects in its struct values, as a `.native` case that struct's swift port lacks, so sdkgen's resynced copy carries it as ten marked patches. Whether the port should have the case is struct's to decide. |


## voxgig/plugin

The four obligations between the two repositories are in plugin's
[`doc/plan/contracts.md`][plugin-contracts] and in
[`station-and-plugin-plan.md`](../design/station-and-plugin-plan.md) §3.

| # | what | upstream | state | gates, and notes |
|---|---|---|---|---|
| plugin-1 | `contracts.md` records C4a and C4b as `NOT STARTED`. Station has run both in CI since `ce0819b` (2026-08-24): 144 pass, 0 pinned divergences, 128 skipped with reasons, against plugin `8605cdc`. | [plugin#45] | OPEN | Filed 2026-11-12, as an issue: the draft suggested a two-row pull request, and none was asked for. Nothing here waits on it. |
| plugin-2 | P3.1, the extraction proof against station | plugin's `progress.md`, item 3.1: `NOT STARTED` | OPEN | Nothing here. Station's half, C3, was discharged by voxgig/station#9. |
| plugin-3 | `station-and-plugin.md` pins plugin's design at `153c878`. plugin `main` is `8605cdc`. | — | station's to do | Re-pin after reading what changed between the two. plugin's own handover names stale cross-repo pins as the thing its discipline failed to catch. |
| plugin-4 | Does station take the library as a dependency? | plugin's `progress.md`, item 5.2; noted in [plugin#45] | OPEN | Ruled here on 2026-11-11: yes (D-2026-11-11-4), and W8 is the work. plugin's own register still shows the decision as needed until [plugin#45] is acted on. |
| plugin-5 | A PyPI release | — | NOT FILED | `sekreto-2`, and through it W3.3. |
| plugin-6 | A host-declared instance under a reserved name cannot be activated | — | NOT FILED | Found by W8.6: after `hostdeclare('station')`, `activate('station')` fails `plugin_ref_reserved`, because `activate` reloads the instance through `declare`, which checks the reserved list again without the host-owned flag (run, at 0.2.0). Station does not reserve `station` through plugin, and refuses the name in `use()` instead. |
| plugin-7 | The host keeps its instances in a plain object | — | NOT FILED | Found by review of W8.6: an instance named `constructor` makes `declare` read `Object.prototype.constructor` as an existing instance, and fail with `TypeError: Cannot read properties of undefined (reading 'name')` (run, at 0.2.0). `checkname` accepts seven names `Object.prototype` holds, `constructor` and `toString` among them. Station refuses those seven in `use()` as `plugin_bad_name`. |


## voxgig/omni

Tests only. Nothing is owed.

| # | what | upstream | state | gates, and notes |
|---|---|---|---|---|
| omni-1 | CI pins `dcbab7a`, from August. omni has since released npm 0.2.0 and `go/v0.2.0`, and likeness runs on the tag. | — | station's to do | Nothing. Move the pin to the release when a section needs what it adds. |
| omni-2 | An entry declared as waiting on a named cause | [omni#74] | WATCH | W5.4. It is the general form of the "pinned pending" list §13 asks tier C ports to carry. |
| omni-3 | The rust, c and cpp runners decode an escaped surrogate pair in the spec as one character | — | NOT FILED | Found by W2.9, at the pinned `dcbab7a`: each decodes a `\u` escape on its own, rust to U+FFFD and c to three bytes per half, so an expected value spelled with an escaped pair never matches a port that reads the pair correctly (run); cpp's decoder is the same code (read). `main` was not checked. Until it is fixed the corpus spells such a value as raw UTF-8, and `spec/README.md` says why. |


## The generated SDKs (voxgig-sdk)

voxgig-sdk holds 966 repositories. By GitHub code search, none carries
the station feature on its default branch: the fourteen that mention
`sdkgen-station` do so in a scaffold comment.

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| sdk-1 | The four SDKs likeness uses, regenerated with the station feature and merged | [joplin-sdk#4], [obsidian-sdk#3], [notion-sdk#5], [linear-sdk#3] | OPEN | W3.13, C.1. Three name sdkgen 4.34.6 in their titles; the generator is at 4.41.1. They still require station's Go module at `v0.0.1`, which was never tagged: likeness's `go/go.mod` maps it to the tag with one `replace` line, and its `PROCESS.md` says why. They need generating again on a current sdkgen and on `sdkgen-station` from station `main`, which requires `v0.2.0`; that tag now exists (W0.1). |
| sdk-2 | Generator fixes that reach an SDK only when it is regenerated | voxgig/sdkgen#400, #401 (Linear's queries and paging), #403, #405 (C: a live transport; two SDKs in one program), #406, #413, #414, #418, #419 | DONE upstream, all closed 2026-10-17; in no SDK yet | C.1. These were every sdkgen cause behind a red cell in likeness's matrix. |
| sdk-3 | Tags and published packages | [joplin-sdk#2], [linear-sdk#2], [obsidian-sdk#2], [notion-sdk#3] | OPEN | A consumer can pin only a commit. |


## Filed on 2026-11-12

Eleven asks had rows and no issue. The owner approved filing them, and
each was checked against the upstream's current code first.

| | where | issue |
|---|---|---|
| `sdkgen-6` | voxgig/sdkgen | [sdkgen#489] |
| `sdkgen-7` | voxgig/sdkgen | [sdkgen#490] |
| `sdkgen-9` | voxgig/sdkgen | [sdkgen#491] |
| `sekreto-1` | voxgig/sekreto | [sekreto#43] |
| `sekreto-2` | voxgig/sekreto | [sekreto#44] |
| `plugin-1` | voxgig/plugin | [plugin#45] |
| W4.1 | voxgig/station | [#66] |
| W4.2 | voxgig/station | [#67] |
| W4.3 | voxgig/station | [#68] |
| W4.4 and W4.5 | voxgig/station | [#69] |
| W5.5 | voxgig/station | [#70] |

Still not filed, and not among the eleven: `sdkgen-10`, `sdkgen-16` and
`sdkgen-17`,
`sekreto-4` to `sekreto-7`, `struct-4` to `struct-6`, `plugin-5` to
`plugin-7`, and `omni-3`. Each is marked `NOT FILED` in its row above.

Two findings from this review extend issues that are already open,
and are better added there than filed new. They have not been added:

- to voxgig/station#31: the Swift dependency names
  `voxgig/station-swift`, which is not a public repository; the Ruby
  port has no gemspec and the Java port no build file; and sekreto
  itself is on npm only.
- to voxgig/station#39: `structhome.py` looks for a struct checkout
  though `voxgig-struct` is on PyPI, and `pyproject.toml` requires
  `voxgig-sekreto`, which is not.


[#37]: https://github.com/voxgig/station/issues/37
[#39]: https://github.com/voxgig/station/issues/39
[#58]: https://github.com/voxgig/station/pull/58
[sdkgen#274]: https://github.com/voxgig/sdkgen/issues/274
[sdkgen#404]: https://github.com/voxgig/sdkgen/issues/404
[sdkgen#408]: https://github.com/voxgig/sdkgen/issues/408
[sdkgen#422]: https://github.com/voxgig/sdkgen/issues/422
[sdkgen#428]: https://github.com/voxgig/sdkgen/issues/428
[sdkgen#430]: https://github.com/voxgig/sdkgen/issues/430
[sdkgen#489]: https://github.com/voxgig/sdkgen/issues/489
[sdkgen#490]: https://github.com/voxgig/sdkgen/issues/490
[sdkgen#491]: https://github.com/voxgig/sdkgen/issues/491
[sekreto#43]: https://github.com/voxgig/sekreto/issues/43
[sekreto#44]: https://github.com/voxgig/sekreto/issues/44
[plugin#45]: https://github.com/voxgig/plugin/issues/45
[#66]: https://github.com/voxgig/station/issues/66
[#67]: https://github.com/voxgig/station/issues/67
[#68]: https://github.com/voxgig/station/issues/68
[#69]: https://github.com/voxgig/station/issues/69
[#70]: https://github.com/voxgig/station/issues/70
[sekreto#41]: https://github.com/voxgig/sekreto/issues/41
[struct#113]: https://github.com/voxgig/struct/issues/113
[struct#175]: https://github.com/voxgig/struct/issues/175
[struct#178]: https://github.com/voxgig/struct/pull/178
[struct#180]: https://github.com/voxgig/struct/pull/180
[omni#74]: https://github.com/voxgig/omni/issues/74
[plugin-contracts]: https://github.com/voxgig/plugin/blob/main/doc/plan/contracts.md
[joplin-sdk#2]: https://github.com/voxgig-sdk/joplin-sdk/issues/2
[joplin-sdk#4]: https://github.com/voxgig-sdk/joplin-sdk/pull/4
[linear-sdk#2]: https://github.com/voxgig-sdk/linear-sdk/issues/2
[linear-sdk#3]: https://github.com/voxgig-sdk/linear-sdk/pull/3
[obsidian-sdk#2]: https://github.com/voxgig-sdk/obsidian-sdk/issues/2
[obsidian-sdk#3]: https://github.com/voxgig-sdk/obsidian-sdk/pull/3
[notion-sdk#3]: https://github.com/voxgig-sdk/notion-sdk/issues/3
[notion-sdk#5]: https://github.com/voxgig-sdk/notion-sdk/pull/5
