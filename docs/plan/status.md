# Status: where the next session starts

Snapshot, **2026-11-13**. `main` is at `2f68eaf`. 0.2.0 is released on
every route, and `main` is ahead of it: the six pull requests of W1
merged on 2026-11-11 and changed every port's source, and on 2026-11-12
W5.1 (the proxy builds), W4.3 (the fixture SDKs), W2.1 (the carried
adapter's place), W2.2 (the Station out of the SDK's options), W2.4
(passwords refused in a block's `base`), W2.5 (no userinfo in an
event's whole URL) and W2.3 (the scrub reaches a transport error's
chain) merged, which completes W2a, and from W2b, W2.6 (one `op` event
per operation), W2.7 (the policy's hostname), W2.8 (the event's host),
W2.9 (unpaired surrogate escapes), W2.10 (the kill switch), W2.12
(the list form of `options.feature`) and, on 2026-11-13, W2.13 (the
declared feature order), W2.14 (java's strict JSON) and W2.15 (strict
UTF-8), which completes W2b. The seven
decisions were ruled on 2026-11-11. The register
in [`progress.md`](progress.md) is the per-item authority, and
[`upstream.md`](upstream.md) tracks what other repositories owe. This
file says what is in flight, what to pick up first, and what waits on a
human.

**Update it at the end of a session, or delete it once it goes stale. A
wrong status file is worse than none.**


## How this snapshot was checked

- **CI, on the tree `main` now has.** Run 43023139038, on the last
  pull request's branch after it took `main`: green, all twenty lanes,
  against that day's plugin and struct. The tree is `main`'s at
  `9a650d4`, object for object. The counts in the table below are from
  that run's log, read lane by lane.
- **CI after every merge.** `main` was green after each of the six:
  runs 43019560965, 43020827544, 43021502368, 43021520512, 43023058555
  and 43023803175.
- **Run here.** The gates and eleven port suites, on a local merge of
  all six, in CI's layout, against omni `dcbab7a`, sekreto `32b83ac`,
  plugin `8605cdc` and struct `055ac4a`. All pass. That tree lacks
  three one-line fixes CI later asked for, in csharp and swift.
- **Not run here.** csharp and swift: there was no toolchain. For
  those two, CI is the only evidence, and on 2026-11-11 it was the only
  thing that caught two faults (W1). dart 3.14, elixir 1.14 and lua 5.4
  were installed here on 2026-11-12 for W2.1, and their suites pass;
  CI runs elixir 1.18. swift 6.0.3 was installed here for W2.12, from
  swift.org's tarball, and the swift suite passes with it. lua 5.3
  was installed beside 5.4 for W2.15, since the lua port claims 5.3
  and its `utf8.len` is laxer there; `test/station.lua` passes on both.
  swift 6.4.2, the version CI runs, was installed beside 6.0.3 for
  W2.15, after CI found their Foundations decode a byte order mark
  differently; the swift suite passes on both.
- **The gates.** `make version-check`, `vendor-check`, `comments` and
  `omni-isolation` pass on the merged tree.
- **`make release-plan` now refuses, as it should.** It says
  `typescript changed since typescript/v0.2.0 was released`, and to
  bump `VERSION`. `main` carries changes no release holds, so a
  dispatch would refuse too until the version moves (W2.11).

Before today, `main` had last changed a port's source on 2026-10-17.
What landed on 2026-11-10 was W0.3 as `690b08f`, this register and W0.9
as `e78b38a`, and the tag `go/v0.2.0`, from release run 42913723297.


## The ports

| port | secrets | corpus sections | guard | declarative front door | suite in CI | released as |
|---|---|---|---|---|---|---|
| typescript (canonical) | sekreto | 11 | **no** | yes | 158 tests: 138 pass, 20 skipped | npm `@voxgig/station` 0.2.0 |
| javascript | sekreto | 11 | yes | yes | 29 pass | npm `@voxgig/station-js` 0.2.0 |
| go | sekreto | 11 | yes | yes | both packages pass | tag `go/v0.2.0` |
| python | sekreto | 11 | yes | yes | 101 pass | — |
| ruby | sekreto | 11 | yes | yes | 80 and 12 pass | — |
| php | sekreto | 11 | yes | yes | 73 pass | — |
| perl | sekreto | 11 | yes | yes | 69 pass | vendored into SDKs |
| java (kotlin rides it) | sekreto | 11 | yes | yes | 62 pass | — |
| rust | sekreto | 11 | yes | yes | 51 and 2 pass | — |
| c | sekreto | 11 | yes | yes | unit, 12 and the secret store pass | vendored into SDKs, env only |
| cpp | env only | 11 | yes | yes | 31 and 12 pass | vendored into SDKs |
| csharp | sekreto | **9** | **no** | **no** | 32 pass | — |
| swift | env only | **9** | **no** | **no** | 37 pass | — |
| dart | env only | **8** | **no** | **no** | 54 pass | — |
| elixir | env only | **8** | **no** | **no** | 35 pass | — |
| lua | env only | **8** | **no** | **no** | 32 and 8 pass | vendored into SDKs |

The "released as" column is 0.2.0, which is not the tree these counts
are from: nothing on `main` since `a570686` is in a release yet.

The eleven sections are `secretname`, `placeholder`, `substitute`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `feature`,
`instance`, `instanceref` and `errors`. dart, elixir and lua lack
`config`, `feature` and `instanceref`. csharp and swift lack `config`
and `feature`: they took `instanceref` with W1.1. All sixteen read the
`sdk` grammar.

**What green does not cover.** The suites that run against real
generated SDKs skip in CI in every port that has them: typescript's
`quickstart`, `gnarly-pets` and `generated-feature`, javascript's two,
and the quickstarts of ruby, php and perl. `make fixtures` generates
those SDKs since W4.3. With W2.1's retrofit suites, `make
fixtures-test` runs thirteen suites, 77 tests, none skipped, all
passing; CI runs them once the fixture lane's patch is applied.

**The other parts.**

| part | state |
|---|---|
| `sdkgen-station/` | The feature model and an adapter per target. Never published. ts and js SDKs register themselves; no other target does. |
| `proxy/` | About 7,900 lines with tests. Builds against CI's sekreto pin since W5.1, with 57 tests. No CI lane until its patch is applied. |
| attach | In no port. `proxy: 'auto'` records that the proxy is absent without looking for one. |
| plugin conformance (C4) | Runs in the typescript lane: 144 pass, 0 pinned divergences, 128 skipped with reasons. |


## In flight

Nothing. Every W2 fix is merged, W2.15's follow-up for the proxy
daemon among them; the one W2 item left is the 0.3.0 release (W2.11),
and it waits on the owner.


## Pick this up first

In this order. Only the release dispatch waits on the maintainer.

1. **0.3.0** (W2.11): W2a is complete, with the cpp guard review found
   after W2.3. The version bump is an ordinary pull request; the
   dispatch publishes to npm, which cannot be undone, so it goes when
   the owner says. W2b is merged too, which the plan put in 0.3.x, so
   a release from `main` now carries it, and its notes must name W2b's
   behaviour changes as well as the three in `plan.md` §6.
2. **W4.1**, a completeness guard in typescript. W1.1, which edited the
   same test file, has landed.
3. **W0.8**, the design's account of sdkgen.

Two more can start at any time, since each begins with a document:
**W8.1**, the design note for taking voxgig/plugin, which every later
step of W8 waits on; and **W3.2**, now that the route is ruled.


## Blocked on a human

Everything here needs the maintainer, and most of it fits one sitting.

| what | why a human | rows |
|---|---|---|
| Apply a workflow patch, when one is on `main` in [`patch/`](patch/README.md) | A token with the `workflow` scope. A session cannot push a change under `.github/workflows/`, so it commits a patch to `main` instead. Two are pending, both on `main`: `proxy-ci-lane.patch` and `fixtures-ci-lane.patch`. They apply in either order, re-checked against `main` on 2026-11-13. | W5.1 and W4.3 now; W3.11 and W4.4 when theirs are written |
| Delete eleven merged branches | The owner ruled on 2026-11-12 that they go. A session cannot do it: its push access refuses a branch deletion (HTTP 403). The list is below. | — |
| Register `@voxgig/sdkgen-station` for trusted publishing | An npm owner | W3.11 |


**The eleven branches to delete.** Each is merged, so nothing is lost:
every commit is on `main`, or is the head of a merged pull request.

```sh
# voxgig/station: the heads of the six pull requests merged 2026-11-11
git push origin --delete claude/declared-block-options \
  claude/event-path-escaped claude/event-host \
  claude/agents-sekreto-ranges claude/refusal-section-sign \
  claude/c-sekreto
# voxgig/likeness: four merged, and chore/comment-policy, whose one
# commit is what voxgig/likeness#4 squashed onto main
git push origin --delete chore/comment-policy \
  claude/adoring-archimedes-5jqzny claude/gracious-ptolemy-gkntnn \
  claude/modest-goodall-j4t6p6 claude/upstream-needs-review
```


## Recently settled

- **The W2 fixes are all merged** (2026-11-12 and 13): the kill switch
  (W2.10, `c9f6f76`), the list form of `options.feature` (W2.12,
  `5fc9e31`), the declared feature order (W2.13, `79ce914`), java's
  strict JSON (W2.14, `1e4a123`) and strict UTF-8 in every port
  (W2.15, `cb29b1b`), and in the proxy daemon (`2f68eaf`). W2.15 found that CI's swift 6.4.2 drops a byte
  order mark that 6.0.3 keeps, and `struct-6`.
- **Every port refuses an unpaired surrogate escape in `station.json`**
  (W2.9, 2026-11-12, `a525c81`), and reads an escaped pair as one
  character; [#61] closed. It found W2.14 and W2.15, and two upstream
  decoders (`omni-3`, `struct-5`).
- **An `http` event's host follows `URL.host` in the three ruled
  forms** (W2.8, 2026-11-12, `156dea9`), in every port; [#55] closed.
  It carried the policy key's lower case that review asked for on W2.7.
- **The hosts policy reads the hostname as `URL.hostname` does**
  (W2.7, 2026-11-12, `cc3bac7`), in every port; [#54] closed. It
  carried the go sweep fix review asked for on W2.6.
- **One `op` event per operation** (W2.6, 2026-11-12, `50b072c`), in
  every port; [#36] closed.
- **The scrub reaches the chain behind a transport error** (W2.3,
  2026-11-12, `362b351`), in every port that has one; [#29] closed.
  This completes W2a. Review found one more case in cpp, a
  `std::nested_exception` holding nothing, guarded in `1170547`.
- **An http event keeps no userinfo from a URL it reports whole**
  (W2.5, 2026-11-12, `94dd0dc`), in every port; [#53] closed.
- **A password in a block's `base`, or in a URL that does not parse,
  is refused** (W2.4, 2026-11-12, `e195639`), in the eleven ports that
  run the `config` section; [#57] closed.
- **The SDK's options hold no Station and no caller key** (W2.2,
  2026-11-12, `dc36a3e`), in every port that carried either; [#37]
  closed. The SDK's own copy of a resident key is `sdkgen-9`.
- **connect() and adopt() bind live with retry on** (W2.1, 2026-11-12,
  `f9f221a`), in the nine ports that carry the adapter; [#63] closed.
- **The proxy builds again, and the fixture SDKs generate**
  (2026-11-12): W5.1 merged as `60dd59e` and W4.3 as `8c563f2`. Each
  still waits on its CI lane's patch.
- **Eleven issues are filed** (2026-11-12), for asks that had a row
  and nothing to link to: three in voxgig/sdkgen, two in
  voxgig/sekreto, one in voxgig/plugin and five here.
  [`upstream.md`](upstream.md) lists them.
- **All seven decisions are ruled** (2026-11-11), and each is a record
  in `docs/design/decisions.md`. Four went as the plan recommended:
  the staged route for non-JavaScript consumers, both proposed records
  accepted, three host forms normalised, and `station_blocked`. One
  went against it: **station takes voxgig/plugin as a dependency now**,
  which adds W8 and makes the dependency rule three, not two. Two were
  parked: station-view until 0.4.0, seneca-station until 0.3.0.
- **The review queue is merged** (W1, 2026-11-11): six pull requests,
  each after CI passed on its branch brought up to `main`. Two needed
  a fix first, in ports only CI can build. Eight issues closed with
  them.
- **likeness is on station 0.2.0** (W0.4): voxgig/likeness#13 merged,
  and its handover is retired.
- **The release workflow releases every port from one dispatch**, and
  CI has a `versions` job (W0.3 and W4.9, `690b08f`, 2026-11-10).
- **0.2.0 is released on all three routes.** Both npm packages, and
  now the Go module: release run 42913723297 tagged `go/v0.2.0` on
  2026-11-10 (W0.1). Every port declares 0.2.0 (voxgig/station#65).
- **[#27] is closed** (W0.2), with a note naming the tag.
- **[#24] is closed** (W0.5), after its own script passed against
  npm's 0.2.0 and a generated SDK, in typescript and in python.
- **The merged branches are gone** (W0.6). They were deleted on
  2026-11-10, and this register listed the job as open for a day
  after. Eight branches remain: `main`, six pull request heads and the
  session's own.
- **Nine sdkgen issues closed on 2026-10-17**, among them every sdkgen
  cause behind a red cell in likeness's matrix. The fixes are in the
  generator and in no SDK yet (`sdk-2`).
- **The documents agree with the code again.** `README.md`,
  `station.md` §17 and `station-and-plugin-plan.md` §0 and §3 were
  corrected with this register (W0.7).


## Known to be stale, and left

Each is source or prose the plan schedules:

- `python/pyproject.toml` and `structhome.py` say struct is not
  published. W3.3.
- `station.md` §9 and `station-declarative-config.md` §11 describe
  sdkgen as it stood in August. W0.8; `upstream.md` has the current
  state.

[#24]: https://github.com/voxgig/station/issues/24
[#27]: https://github.com/voxgig/station/issues/27
[#63]: https://github.com/voxgig/station/issues/63
[#37]: https://github.com/voxgig/station/issues/37
[#57]: https://github.com/voxgig/station/issues/57
[#53]: https://github.com/voxgig/station/issues/53
[#29]: https://github.com/voxgig/station/issues/29
[#36]: https://github.com/voxgig/station/issues/36
[#54]: https://github.com/voxgig/station/issues/54
[#55]: https://github.com/voxgig/station/issues/55
[#61]: https://github.com/voxgig/station/issues/61
