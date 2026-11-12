# The station plan

This directory is where station's plan and its live state are kept. The
design documents in [`../design/`](../design/) say what station is and
why. These files say what is done, what is next, who is waiting on whom,
and what each dependency owes.

It follows the plan-register discipline voxgig/plugin and voxgig/omni
already use (`doc/plan/` there), so that the family reads one way.

| file | what it holds | changes when |
|---|---|---|
| [`plan.md`](plan.md) | The plan: the goal, the rules, nine workstreams in order with their exit criteria, the decisions and how each was ruled, the release train and the risks. | The plan itself changes. Rare. |
| [`progress.md`](progress.md) | The plan register: one row per item, with its status and the evidence for it. Every open issue and pull request is mapped to a row. | **In the same commit as the work it records.** |
| [`upstream.md`](upstream.md) | The upstream register: what station pins of each dependency, one row per thing station needs from another repository, and the asks not yet filed. | An upstream issue is filed, moves or closes; a pin moves. |
| [`status.md`](status.md) | The snapshot: the per-port matrix, what is in flight, what to pick up first, and what waits on a human. | At the end of a working session. |
| [`patch/`](patch/README.md) | Workflow changes, each written as a patch and committed to `main` for a maintainer to apply. | A workflow change is ready, or one has been applied. |

## The rules

1. **A row changes in the same commit that changes its state.** A pull
   request that lands an item updates that item's row in `progress.md`.
2. **`DONE` means merged.** Never "written", never "on a branch". A row
   about another repository is `DONE` when the change merges there, and
   the row names the pull request.
3. **Every claim carries its evidence.** A commit, a CI run, a command
   and its output, or a file and line. A state nobody checked is
   written as "not verified", with what would verify it.
4. **Status lives here, not in the design.** `README.md` and the design
   documents carry a status line each, for orientation. When one of
   them disagrees with this directory, this directory is right and the
   other is corrected.
5. **A wrong status file is worse than none.** `status.md` is dated. If
   it has gone stale and nobody is going to refresh it, delete it:
   `progress.md` is the authority and does not depend on it.
6. **For a workflow change, a patch is created on `main`.** A session's
   token cannot push a change under `.github/workflows/`. Such a change
   is made on a scratch branch cut from `main` and written out with
   `git format-patch`, and the patch file is committed to `main` itself,
   in [`patch/`](patch/README.md). `main` is where the maintainer looks
   for it; one left on a feature branch is not found. Its item stays
   `BLOCKED`, on that patch being applied, until the change it carries
   is on `main`.

## Statuses

`NOT STARTED`, `IN PROGRESS` (a pull request is open), `DONE` (merged),
`DECISION NEEDED` (waiting on a call that is not the implementer's to
make), `BLOCKED` (waiting on something outside the item, named in the
note), `DECIDED-NO` (with the reason). The same six voxgig/plugin uses.

## Item names

Workstreams are `W0` to `W8`, and items are `W2.3`. Decisions are
`DEC-1` onward; once ruled, each becomes a dated record in
[`../design/decisions.md`](../design/decisions.md). Upstream rows are
named for their repository: `sdkgen-3`, `sekreto-1`.

These names were chosen not to collide with the ones the design already
uses: Phases 1–3 (`station.md` §17), Stages 1–5
(`station-declarative-config.md` §12), obligations C1–C4 and meeting
points M1–M4 (`station-and-plugin-plan.md`), decisions D1–D5 and rungs
R1–R2 (`station.md`), and plugin's phases P0–P6.
