# Status: where the next session starts

Snapshot, **2026-11-11**, of `main` at `9a650d4`. 0.2.0 is released on
every route. `main` is now ahead of it: the six pull requests of W1
merged today and changed every port's source. The register
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
- **Not run here.** csharp, swift, dart, elixir and lua: there was no
  toolchain. For those five, CI is the only evidence, and on 2026-11-11
  it was the only thing that caught two faults (W1).
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
ruby's nine quickstart cases and perl's `t/quickstart.t`. Nothing in the
repository generates the SDKs they look for (W4.3).

**The other parts.**

| part | state |
|---|---|
| `sdkgen-station/` | The feature model and an adapter per target. Never published. ts and js SDKs register themselves; no other target does. |
| `proxy/` | About 7,800 lines with tests. Does not compile against CI's sekreto pin; its 49 tests pass against the sekreto revision it was written for. No CI lane. |
| attach | In no port. `proxy: 'auto'` records that the proxy is absent without looking for one. |
| plugin conformance (C4) | Runs in the typescript lane: 144 pass, 0 pinned divergences, 128 skipped with reasons. |


## In flight

Nothing. No pull request is open in voxgig/station or voxgig/likeness.


## Pick this up first

In this order. None of it waits on the maintainer.

1. **W5.1**, the proxy's build. No open change touches `proxy/`, and
   the build fix is one file.
2. **W4.3**, a `make` target that generates the fixture SDKs. It is new
   files only, and it is what lets W2.1 be reproduced before it is
   fixed.
3. **W2a**, canonical first: W2.1, W2.2, W2.4, W2.5, W2.3. That is what
   0.3.0 waits on, now that W1 is in.
4. **W4.1**, a completeness guard in typescript. W1.1, which edited the
   same test file, has landed.
5. **W0.8**, the design's account of sdkgen.

DEC-1 should be answered while 1 to 3 are under way, since all of W3
waits on it.


## Blocked on a human

Everything here needs the maintainer, and most of it fits one sitting.

| what | why a human | rows |
|---|---|---|
| Apply a workflow patch, when one is on `main` in [`patch/`](patch/README.md) | A token with the `workflow` scope. A session cannot push a change under `.github/workflows/`, so it commits a patch to `main` instead. None is pending. | W3.11, W4.3, W4.4 and W5.1, when their patches are written |
| Seven decisions | The owner's call | DEC-1 to DEC-7 |
| Register `@voxgig/sdkgen-station` for trusted publishing | An npm owner | W3.11 |
| Approve the upstream drafts for filing | They go to other repositories, and each one notifies people | [`upstream.md`](upstream.md), "Not yet filed" |


## Recently settled

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
