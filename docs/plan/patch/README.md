# Workflow patches

GitHub refuses a change under `.github/workflows/` pushed by a token
without the `workflow` scope, and a session's token has no such scope.
So a workflow change is not pushed. It is written here as a patch
against `main`, and a maintainer applies it.

A patch is cut from `main`, never from a feature branch, so that it
applies to what a maintainer has checked out.


## Applying one

```sh
git switch -c <branch> origin/main
git am docs/plan/patch/<file>.patch
# run the checks its row lists
git push -u origin <branch>      # with a token that has the workflow scope
```

Open a pull request. In that pull request, delete the patch file, drop
its row below, and move its item's row in [`../progress.md`](../progress.md).


## Pending

| patch | items | what it changes | needs first | checked |
|---|---|---|---|---|
| [`station-release-workflow.patch`](station-release-workflow.patch) | W0.3, W4.9 | `release.yml` releases every port at `VERSION` from one dispatch: typescript and javascript publish to npm, go is a tag, and every tag goes up in one push after every publish has succeeded. `build.yml` gains a `versions` job. `AGENTS.md` and the `Makefile` follow. It also corrects `release.yml`'s header, which says neither package is registered for trusted publishing. | Nothing. It is independent of the six open pull requests. | 2026-11-10. `git am` on `main` at `a570686`, and `git apply --check` on `main` with all six open pull requests merged. On the result: `make version-check release-plan-test` pass, and actionlint 1.7.12 with shellcheck 0.9.0 is clean on both workflow files. |

`station-release-workflow.patch` is the patch the 0.2.0 release session
left in voxgig/likeness, at `upstream/patch/`. The two files are
byte-identical. This is the copy to keep current: if `main` moves and it
stops applying, it is regenerated here. Apply it once, from either
place.


## Not written yet

Each of these is a workflow change the plan needs, and none can be a
patch on `main` today: each waits on something that is not on `main`
yet. A lane added before then would be red.

| item | the workflow change | what has to be on `main` first |
|---|---|---|
| W5.1 | A `proxy` lane running `make -C station/proxy test` | The proxy building against the sekreto revision CI pins (voxgig/station#46) |
| W4.3 | A job that generates the fixture SDKs and runs the integration suites against them | The `make` target that generates them |
| W4.4 | A `ref:` on the `struct` checkout | Stage 5 complete (W4.2). `build.yml` says to pin struct then and not before. |
| W3.11 | A `port` value for `sdkgen-station` in `release.yml` | The package registered for trusted publishing, and its release scripts |


## Writing one

```sh
git fetch origin main
git worktree add -b <scratch> <dir> origin/main
# edit, then commit with a full message, as for any change
git -C <dir> format-patch -1 --stdout > docs/plan/patch/<name>.patch
```

Then check it the way a maintainer will use it: `git am` on a clean
checkout of `main`, the repository's own gates on the result, and
[actionlint](https://github.com/rhysd/actionlint) with shellcheck on
every workflow file it touches. Add its row above, with what was run and
when. The scratch branch is never pushed.

A patch may carry files outside `.github/workflows/` when they have to
land with the workflow change, as the release patch carries `AGENTS.md`
and the `Makefile`. Anything that can land on its own goes in an
ordinary pull request.
