# Status: where the next session starts

Snapshot, **2026-11-10**, of `main` at `690b08f` (0.2.0). The register
in [`progress.md`](progress.md) is the per-item authority, and
[`upstream.md`](upstream.md) tracks what other repositories owe. This
file says what is in flight, what to pick up first, and what waits on a
human.

**Update it at the end of a session, or delete it once it goes stale. A
wrong status file is worse than none.**


## How this snapshot was checked

- **CI.** Run 42878382277 on `690b08f` (2026-11-10): green, all twenty
  lanes and the `versions` job, against that evening's plugin and
  struct. The counts in the table below are from run 39025102214 on
  `a570686` (2026-10-17), whose log was read lane by lane to confirm
  each suite ran and did not skip its way to green. No port's source
  differs between the two commits.
- **Re-run, 2026-11-10.** Eleven port suites, in CI's layout, against
  omni `dcbab7a`, sekreto `32b83ac`, plugin `8605cdc` and struct
  `18d6237`. CI pins the first two and floats the others, and struct
  had moved that day. All eleven passed with CI's counts.
- **Not run here.** csharp, swift, dart, elixir and lua: there was no
  toolchain. For those five, the CI runs above are the evidence.
- **The gates.** `make version-check`, `vendor-check`, `comments`,
  `omni-isolation` and `release-plan` pass.

W0.3 landed on `main` on 2026-11-10, as `690b08f`. Nothing else has
merged since 2026-10-17.


## The ports

| port | secrets | corpus sections | guard | declarative front door | suite in CI | released as |
|---|---|---|---|---|---|---|
| typescript (canonical) | sekreto | 11 | **no** | yes | 147 tests: 127 pass, 20 skipped | npm `@voxgig/station` 0.2.0 |
| javascript | sekreto | 11 | yes | yes | 21 pass | npm `@voxgig/station-js` 0.2.0 |
| go | sekreto | 11 | yes | yes | both packages pass | **no tag yet** (W0.1) |
| python | sekreto | 11 | yes | yes | 91 pass | — |
| ruby | sekreto | 11 | yes | yes | 70 and 12 pass | — |
| php | sekreto | 11 | yes | yes | 63 pass | — |
| perl | sekreto | 11 | yes | yes | pass | vendored into SDKs |
| java (kotlin rides it) | sekreto | 11 | yes | yes | 55 pass | — |
| rust | sekreto | 11 | yes | yes | 46 and 2 pass | — |
| c | env only | 11 | yes | yes | unit, and 12 pass | vendored into SDKs |
| cpp | env only | 11 | yes | yes | 28 and 12 pass | vendored into SDKs |
| csharp | sekreto | **8** | **no** | **no** | 27 pass | — |
| swift | env only | **8** | **no** | **no** | 32 pass | — |
| dart | env only | **8** | **no** | **no** | 50 pass | — |
| elixir | env only | **8** | **no** | **no** | 33 pass | — |
| lua | env only | **8** | **no** | **no** | unit, and 8 pass | vendored into SDKs |

The eleven sections are `secretname`, `placeholder`, `substitute`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `feature`,
`instance`, `instanceref` and `errors`. The five ports on eight lack
`config`, `feature` and `instanceref`. All sixteen read the `sdk`
grammar.

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

Six pull requests, all opened 2026-10-15 and all green at their heads:
W1.1 to W1.6. An automated review ran on each. Its eight threads, on
three of the six, are all answered and resolved. None has an approval.
Nothing else is in flight.


## Pick this up first

In this order. The first two need the maintainer; the rest do not.

1. **W0.1, then W0.4.** Tag `go/v0.2.0` on `a570686`, by hand:
   `git tag go/v0.2.0 a570686fe886bc2d686c991ffee5c7e6a47b5f8a`, then
   `git push origin go/v0.2.0`. `main` has moved past that commit, so
   `make release-plan` stops with an error naming it until the tag is
   there, and a dispatch of the release workflow cannot make it.
2. **W1, in the register's order.** A trial merge of all six passed on
   2026-11-10, with two one-line resolutions the register spells out.
3. **W5.1**, the proxy's build. It can start now: no open pull request
   touches `proxy/`, and the build fix is one file.
4. **W4.3**, a `make` target that generates the fixture SDKs. It is new
   files only, and it is what lets W2.1 be reproduced before it is
   fixed.
5. **W2a**, canonical first: W2.1, W2.2, W2.4, W2.5, W2.3.
6. **W4.1**, after W1.1, which edits the same test file.

DEC-1 should be answered while 3 to 5 are under way, since all of W3
waits on it.


## Blocked on a human

Everything here needs the maintainer, and most of it fits one sitting.

| what | why a human | rows |
|---|---|---|
| Push the tag `go/v0.2.0` | Tag-push rights. The last session's push was refused. | W0.1 |
| Apply a workflow patch, when one is on `main` in [`patch/`](patch/README.md) | A token with the `workflow` scope. A session cannot push a change under `.github/workflows/`, so it commits a patch to `main` instead. None is pending. | W3.11, W4.3, W4.4 and W5.1, when their patches are written |
| Review and merge six pull requests | Merge rights | W1 |
| Seven decisions | The owner's call | DEC-1 to DEC-7 |
| Register `@voxgig/sdkgen-station` for trusted publishing | An npm owner | W3.11 |
| Approve the upstream drafts for filing | They go to other repositories, and each one notifies people | [`upstream.md`](upstream.md), "Not yet filed" |
| Close [#24]; delete merged branches | Housekeeping | W0.5, W0.6 |


## Recently settled

- **The release workflow releases every port from one dispatch**, and
  CI has a `versions` job (W0.3 and W4.9, `690b08f`, 2026-11-10).
- **0.2.0 is on npm for both packages**, and every port declares it
  (voxgig/station#65). Only the Go tag is outstanding.
- **Nine sdkgen issues closed on 2026-10-17**, among them every sdkgen
  cause behind a red cell in likeness's matrix. The fixes are in the
  generator and in no SDK yet (`sdk-2`).
- **The documents agree with the code again.** `README.md`,
  `station.md` §17 and `station-and-plugin-plan.md` §0 and §3 were
  corrected with this register (W0.7).


## Known to be stale, and left

Each is inside a change that is already open, or is source the plan
schedules:

- `AGENTS.md` gives the typescript and javascript sekreto ranges as
  `^0.1.0`. W1.4 corrects it.
- `station.md` §2.2 says sekreto ships ten ports. W1.6 rewrites part of
  that paragraph.
- `python/pyproject.toml` and `structhome.py` say struct is not
  published. W3.3.
- `station.md` §9 and `station-declarative-config.md` §11 describe
  sdkgen as it stood in August. W0.8; `upstream.md` has the current
  state.
- voxgig/likeness `HANDOVER.md` still lists the release-workflow patch
  as a step to take. It is done.


[#24]: https://github.com/voxgig/station/issues/24
