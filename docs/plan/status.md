# Status: where the next session starts

Snapshot, **2026-11-28**. `main` is at `b26a62a`, and **CI is green on
every lane.** It was red on every pull request from 2026-11-16,
when voxgig/struct's `main` dropped the `$ONE` checker station's shape
was written with, until voxgig/station#95 moved station onto `$NOF` and
npm took struct 0.4.0. #95 merged on 2026-11-20, so pull requests merge
again (D-2026-11-17-1). **W4.10's checkpoint exists** since 2026-11-25,
so the hold of D-2026-11-19-1 has lifted: struct's releases are out and
the checkpoint is cut. **0.4.0 is
released on every route**, from `8639364` (W4.10): every port's move
onto `$NOF`, with go on struct's `go/v0.2.0`, and in typescript W8.6,
the extension host, and W9.1, its extension points. 0.3.0, from
`ef358d6` (W2.11), carried all of this:
the six pull requests of W1 merged on 2026-11-11 and changed every port's source, and on 2026-11-12
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

- **CI, on `main` at `8639364`.** Run 45922255319, on the push that
  merged voxgig/station#102, is green on every lane. Since `24f859c`
  the code that changed is every port's version declaration and the
  fixture scripts' create-sdkgen default.
- **CI, on `main` at `24f859c`.** Run 44951039784, on the push that
  merged voxgig/station#98, is green on every lane. Since `b83a16d` the
  only code that changed is go's `go.mod` and `go.sum`, so the counts
  in the table below, from the run on `b83a16d`, stand.
- **CI, on `main` at `b83a16d`.** Run 44646671763, on the push that
  merged voxgig/station#95: green, every lane, against omni `dcbab7a`,
  sekreto `32b83ac`, plugin's `main` at `8605cdc` and struct's `main`
  at `d47ba41`, the commit npm's struct 0.4.0 and struct-js 0.2.0 were
  built from. The typescript lane takes struct from npm, at 0.4.0. The
  counts in the table below are from that run's log, read lane by
  lane. The pull request's last run, 44645701546, on `cc167a8`, the
  same tree, was green too.
- **Run here, on `main`.** `make version-check`, `vendor-check`,
  `comments` and `omni-isolation` pass. `make traffic` and then `make
  traffic-test` pass 2 of 2, beside station-view `25d73b7`, station-mcp
  `11bea2d` and sdkgen-validpack `c799ab4`, each its repository's
  `main`.
- **The fixtures, on 2026-11-27.** On create-sdkgen 0.31.12, which
  takes sdkgen 4.48.1, `make fixtures-test` passes 77 tests, none
  skipped, and `make traffic-test` 2 of 2, beside the same three.
- **`make release-plan`** reports every port released at 0.4.0: each
  tag is on `8639364`, and npm built both packages from it.


## The ports

| port | secrets | corpus sections | guard | declarative front door | suite in CI | released as |
|---|---|---|---|---|---|---|
| typescript (canonical) | sekreto | 11 | **no** | yes | 201 tests: 181 pass, 20 skipped | npm `@voxgig/station` 0.4.0 |
| javascript | sekreto | 11 | yes | yes | 58 pass | npm `@voxgig/station-js` 0.4.0 |
| go | sekreto | 11 | yes | yes | three packages pass | tag `go/v0.4.0` |
| python | sekreto | 11 | yes | yes | 126 pass | — |
| ruby | sekreto | 11 | yes | yes | 93 and 12 pass | — |
| php | sekreto | 11 | yes | yes | 94 pass | — |
| perl | sekreto | 11 | yes | yes | 89 pass | vendored into SDKs |
| java (kotlin rides it) | sekreto | 11 | yes | yes | 75 pass | — |
| rust | sekreto | 11 | yes | yes | 61 and 2 pass | — |
| c | sekreto | 11 | yes | yes | unit, 12 and the secret store pass | vendored into SDKs, env only |
| cpp | env only | 11 | yes | yes | 40 and 12 pass | vendored into SDKs |
| csharp | sekreto | **9** | **no** | **no** | 43 pass | — |
| swift | env only | **9** | **no** | **no** | 49 pass | — |
| dart | env only | **8** | **no** | **no** | 72 pass | — |
| elixir | env only | **8** | **no** | **no** | 50 pass | — |
| lua | env only | **8** | **no** | **no** | 50 and 8 pass | vendored into SDKs |

The "released as" column is 0.4.0, from `8639364`. The counts are
from the run on `b83a16d`, and since then the code that changed is
go's `go.mod` and `go.sum` and every port's version declaration.

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
Neither CI nor those suites see W4.10's flag day, since none of them
opens a `station.json` beside an SDK. Measured by hand on 2026-11-27:
beside an SDK generated by sdkgen 4.48.1, `main`'s ruby, php and perl
accept a valid one, and on a struct from before the change each
refuses it.

**The other parts.**

| part | state |
|---|---|
| `sdkgen-station/` | The feature model and an adapter per target. Never published. ts and js SDKs register themselves; no other target does. |
| `proxy/` | About 7,900 lines with tests. Builds against CI's sekreto pin since W5.1, with 57 tests. No CI lane until its patch is applied. |
| attach | In no port. `proxy: 'auto'` records that the proxy is absent without looking for one. |
| plugin conformance (C4) | Runs in the typescript lane: 144 pass, 0 pinned divergences, 128 skipped with reasons. |


## In flight

**W10, the extensions completed in local TypeScript**, directed by the
owner on 2026-11-27 with two points ruled (D-2026-11-27-1): a record
log that a `station-view` command serves, and one id per call from
sdkgen, in every target. Its seven items are in `plan.md`, and all
seven are done. Both extensions test on npm's station. station-mcp
keeps §7's gates and labels, and answers six of its tools in process,
over stdio and over streamable HTTP. station-view keeps a record log
that its `station-view` command serves, and joins a call's records on
the id sdkgen 4.50.0 puts on each (`sdkgen-17`). Each extension's CI is
on its `main` as a patch for the owner. W10's exit waits on W9.7,
likeness as the live test.

**W4.10 is done**: 0.4.0 released it on 2026-11-27 (see "Recently
settled"). The sections some struct runners still skip are sdkgen's
next pull request (`sdkgen-22`), on sdkgen's side.

W9, observing traffic locally, directed by the owner on 2026-11-16
(D-2026-11-16-1): a user drives station-mcp, its tools call a generated
SDK, the SDK calls a generated local mock, and station-view shows the
calls on a local page. W9.1 to W9.6 are done and merged, W9.1 and
W9.6 as voxgig/station#95, and W9's exit holds on `main`: `make
traffic` and then `make traffic-test` pass, with nothing published.
W9.7, likeness as the live test, is under way on likeness's branch
(D-2026-11-27-2). Every likeness port passes but TypeScript's seven
Obsidian tests. The owner ruled on 2026-11-28 (D-2026-11-28-1) that they
wait for `sdkgen-14`, a `tls` option in every SDK target, and that
likeness's three SDKs are regenerated on the sdkgen that carries it,
within W9.7, and station 0.5.0 is released for it.


## Pick this up first

In this order. The hold of D-2026-11-19-1 lifted with the checkpoint.

1. **`sdkgen-14`**, a `tls` option in every sdkgen target, then an
   sdkgen release.
2. **W9.7**: likeness's three SDKs regenerated on that release, then
   likeness's pull request, on likeness's branch.
3. **W4.1**, a completeness guard in typescript. W1.1, which edited the
   same test file, has landed.
4. **W0.8**, the design's account of sdkgen.

Two more begin with a document and wait on nothing else: **W8.1**, the design note for taking voxgig/plugin,
which every later step of W8 waits on; and **W3.2**, now that the
route is ruled.


## Blocked on a human

Everything here needs the maintainer, and most of it fits one sitting.

| what | why a human | rows |
|---|---|---|
| Apply a workflow patch, when one is on `main` in [`patch/`](patch/README.md) | A token with the `workflow` scope. A session cannot push a change under `.github/workflows/`, so it commits a patch to `main` instead. Two are pending, both on `main`: `proxy-ci-lane.patch` and `fixtures-ci-lane.patch`. They apply in either order, re-checked against `main` on 2026-11-13. | W5.1 and W4.3 now; W3.11 and W4.4 when theirs are written |
| Delete eleven merged branches | The owner ruled on 2026-11-12 that they go. A session cannot do it: its push access refuses a branch deletion (HTTP 403). The list is below. | — |
| Register `@voxgig/sdkgen-station` for trusted publishing | An npm owner | W3.11 |
| Apply the CI patches in voxgig/station-view and voxgig/station-mcp | Each has a workflow patch on its `main`, in `patch/`, whose README names the apply command. Until applied, station-mcp has no CI, and station-view runs the comment gate alone. | W10.2 |
| CI for voxgig/sdkgen-validpack | It has no workflow, and a session cannot push one. Until one is applied from a patch, each change there rests on runs recorded in its pull request. | W9.2 to W9.6 |
| Rule on seneca-station again (DEC-7) | It was parked until 0.3.0, which is released | C.3 |


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

- **0.5.0 is released on all three routes** (D-2026-11-28-1,
  2026-11-28, from `b26a62a`, run 46170171928): both npm packages as
  `latest`, with provenance, and the three tags. It carries the
  typescript Station's `secrets()` and `policies()`, and the SDK's id as
  an op's `corr`. Release notes: `docs/release/0.5.0.md`.
- **sdkgen 4.50.0 is released** (W10.7, 2026-11-27, from `0dee8bd`,
  run 46075262935): telemetry's spans and debug's entries carry
  `correlationId` in all twenty targets (`sdkgen-17`), and station-view
  joins a call's records on it.
- **0.4.0 is released on all three routes** (W4.10, 2026-11-27, from
  `8639364`, run 45922269816): both npm packages as `latest`, with
  provenance, and the three tags. Release notes: `docs/release/0.4.0.md`.
  sdkgen 4.48.0 and 4.48.1 and create-sdkgen 0.31.12 came first, on
  2026-11-26, and the fixture SDKs regenerated on them
  (voxgig/station#101).
- **struct's Go module is released, and station takes it**
  (2026-11-21): `go/v0.2.0`, from a `publish.yml` dispatch once the
  owner applied its go target (D-2026-11-20-1), and `go/go.mod` moved to
  it.
- **Station is on struct's `$NOF`, and W9's traffic view is merged**
  (2026-11-20, voxgig/station#95, `b83a16d`): W9.1, W9.6 and W4.10's
  change in every port, once CI passed on every lane. typescript and
  javascript take npm's struct 0.4.0 and struct-js 0.2.0, released that
  day by `publish.yml` dispatch, with provenance.
- **A Station hosts extensions, in typescript** (W8.6, 2026-11-14,
  `e893528` and its follow-up `84efd1b`), and voxgig/station-view and
  voxgig/station-mcp each hold a stub one. It found three things
  upstream: `plugin-6`, `plugin-7` and `sekreto-7`.
- **0.3.0 is released on all three routes** (W2.11, 2026-11-14, from
  `ef358d6`, run 43608982834): both npm packages as `latest`, with
  provenance, and the three tags. Release notes: `docs/release/0.3.0.md`.
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
