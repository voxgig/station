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
| **voxgig/struct** | library | `build.yml` checkout | **unpinned**, until Stage 5 is complete | `main` is `055ac4a` on 2026-11-11. It moved on both days this register was checked. |
| | | `typescript/package.json` | `^0.2.2`, locked 0.2.2 | npm 0.3.7, outside the range |
| | | `javascript/package.json` | `@voxgig/struct-js` `^0.1.7`, locked 0.1.7 | npm 0.1.7 |
| | | `go/go.mod` | `v0.1.6` | `go/v0.1.6` |
| | | `rust/Cargo.toml` | a path to `vendor/struct`, a link to the sibling checkout; the lock records 0.1.7 | crates.io 0.1.7 |
| **voxgig/plugin** | sekreto's dependency; the C4 corpus | `build.yml` checkout | **unpinned**, on purpose | `main` is `8605cdc` |
| | | `go/go.mod`, indirect | a pseudo-version of `91f294b` (2026-09-01) | `go/v0.2.0` |
| | | typescript lockfile, transitive | 0.1.7 | npm 0.2.0 |
| **voxgig/omni** | tests only | `build.yml` checkout | `dcbab7a` (voxgig/omni#36, 2026-08-22) | `main` is `ef55ad0`; npm 0.2.0; `go/v0.2.0` |
| **voxgig/sdkgen** | generator, for sdkgen-station | `sdkgen-station/package.json` peer | `>=3.6` | npm 4.44.0 on 2026-11-12; `main` is `9aebaf9` |

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
| sdkgen-9 | The SDK does not keep a hoisted credential in its own options | [sdkgen#491]; related: [sdkgen#274] | OPEN | Filed 2026-11-12. The SDK half of W2.2. [#37] found the key under `options().__derived__.clean.values`, and at 4.44.0 `options()` still returns a clone that includes the clean registry. |
| sdkgen-10 | `Package_*` consumes `collectDeps` in clojure, ocaml and scala, and in haskell and lean in the language pack (§9.2) | —; sdkgen `docs/design/feature-tags.md` | NOT FILED | W7.3. Twelve targets call it now, elixir among them, which the design still lists as missing. ts and js carry feature deps inline; c, cpp and zig vendor. |
| sdkgen-11 | Feature tags: which features a target can take | sdkgen `docs/design/feature-tags.md`, a proposal dated 2026-08-17 | OPEN | W7.3, for the targets whose features live in one module. |
| sdkgen-12 | — | [sdkgen#430] | WATCH | It reports that a feature passed in `extend` fires its hooks whatever `active` says. Station's carried adapter rides `extend` and depends on its hooks firing. A fix there has to keep that working. |
| sdkgen-13 | Two generated Ruby SDKs load in one process | [sdkgen#404] | OPEN | Station's premise in Ruby: many SDKs, one process. likeness proved the collisions inert for what it uses. |
| sdkgen-14 | A TLS trust option in every transport | [sdkgen#408] | OPEN | likeness's Obsidian source. Station passes `options.tls` through and owns none of it. |
| sdkgen-15 | Does sdkgen adopt voxgig/plugin? (plugin's design §17.2) | plugin's register, item 6.2 | DECISION NEEDED | Nothing here. It is the "second consumer" this plan wanted DEC-3 to wait for. DEC-3 was ruled without it on 2026-11-11 (D-2026-11-11-4), so until sdkgen decides, station is plugin's only consumer. |
| sdkgen-16 | A public `client.extend()` late-attach seam (`station.md` §18) | — | NOT FILED | Nothing. It would upgrade `adopt()` beyond construction time; v1 does not need it. |


## voxgig/sekreto

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| sekreto-1 | Releases beyond npm, starting where the fleet generates: PyPI and RubyGems, then the rest; and a `go/v*` tag | [sekreto#43] | OPEN | Filed 2026-11-12. W3.3 to W3.8, on the staged route. PyPI waits on `plugin-5`, since sekreto's Python metadata names plugin by URL. |
| sekreto-2 | Its Python metadata pins voxgig/plugin | [sekreto#44] | OPEN | Filed 2026-11-12. W3.3. `python/pyproject.toml` requires `voxgig-plugin @ git+https://github.com/voxgig/plugin.git#subdirectory=python`, with no revision, so a pinned station and a pinned sekreto still resolve whatever plugin's default branch is that day ([#39]). |
| sekreto-3 | `minivault.c` declares what it calls | [sekreto#41] | DONE, closed 2026-10-15 | W1.6 compiles with `-D_DEFAULT_SOURCE` until `SEKRETO_C_COMMIT` moves past the fix. |
| sekreto-4 | A Swift package and mini vault; AES-GCM for Dart's mini vault; a native crypto module for Lua's | — | NOT FILED | W7.4. From [#58]'s assessment of each port; not re-checked here. |
| sekreto-5 | An OS-keychain provider (`station.md` §18) | — | NOT FILED | Nothing. Wanted by the design's first draft. |
| sekreto-6 | Are the publish-time `aql` vault and the `boru` provider one vault or two? (`station.md` §18) | — | NOT FILED | Nothing. An open design question. |


## voxgig/struct

| # | what station needs | upstream | state | gates, and notes |
|---|---|---|---|---|
| struct-1 | `$CHILD` in list mode validates element 0 | [struct#113] | DONE, closed 2026-08-25 | W4.8: station's explicit first-element checks can go once every port's struct carries the fix. |
| struct-2 | A closed map whose keys are all optional still refuses an undeclared key | [struct#175] | OPEN | `sdkgen-5`. A strict feature refuses a misspelled option only when a correctly spelled one is passed beside it. Found by W1.1. |
| struct-3 | — | [struct#178], a parity pull request across its ports | WATCH | W4.4. It changes behaviour, and station's CI takes struct `main`. |
| struct-4 | Packages on Packagist and Maven Central | — | NOT FILED | W3.5, W3.6. It is on every other registry station's ports use. |


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


## voxgig/omni

Tests only. Nothing is owed.

| # | what | upstream | state | gates, and notes |
|---|---|---|---|---|
| omni-1 | CI pins `dcbab7a`, from August. omni has since released npm 0.2.0 and `go/v0.2.0`, and likeness runs on the tag. | — | station's to do | Nothing. Move the pin to the release when a section needs what it adds. |
| omni-2 | An entry declared as waiting on a named cause | [omni#74] | WATCH | W5.4. It is the general form of the "pinned pending" list §13 asks tier C ports to carry. |


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

Still not filed, and not among the eleven: `sdkgen-10` and `sdkgen-16`,
`sekreto-4` to `sekreto-6`, `struct-4` and `plugin-5`. Each is marked
`NOT FILED` in its row above.

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
