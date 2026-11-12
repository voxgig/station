# Workflow patches

GitHub refuses a change under `.github/workflows/` pushed by a token
without the `workflow` scope, and a session's token has no such scope.
So a workflow change is not pushed. It is written as a patch against
`main`, and the patch file is committed to `main` itself, in this
directory, for a maintainer to apply.

**The patch file goes on `main`.** That is where the maintainer looks
for it. The first one was written into voxgig/likeness, and then onto a
session's branch here, and was on station's `main` in neither case.

A patch is cut from `main`, never from a feature branch, so that it
applies to what the maintainer has checked out.


## Applying one

```sh
git switch main && git pull --ff-only
git am docs/plan/patch/<file>.patch
# run the checks its row lists
git push                         # with a token that has the workflow scope
```

Then delete the patch file, drop its row below, and move its item's row
in [`../progress.md`](../progress.md).


## Pending

| patch | items | what it does | checked |
|---|---|---|---|
| `proxy-ci-lane.patch` | W5.1 | Adds a `proxy` job to `build.yml`, beside `versions`: it checks out sekreto at the pinned revision and plugin unpinned, runs `make -C station/proxy build vet test`, then `make -C station/proxy build-clean` with no workspace. | 2026-11-12, on the commit that made the proxy build: `git am` on a clean checkout, actionlint 1.7.12 with shellcheck 0.9.0 over every workflow file, and both of the job's steps run in CI's directory layout against sekreto `32b83ac` and plugin `8605cdc`, all clean. Apply it once that commit is on `main`. |
| `fixtures-ci-lane.patch` | W4.3 | Adds a `fixtures` job at the end of `build.yml`: it checks out the siblings at the revisions `ports` uses, installs and builds the typescript and javascript ports as their lanes do, then runs `make -C station fixtures` and `make -C station fixtures-test`, with `PLUGIN_HOME` set. | 2026-11-12, on the commit that added the targets: `git am` on a clean checkout, alone and with `proxy-ci-lane.patch` in either order; actionlint 1.7.12 with shellcheck 0.9.0 over every workflow file; and all three of the job's steps run in a fresh copy of CI's directory layout, with the siblings at CI's revisions: 56 tests pass, none skipped. Apply it once that commit is on `main`. |


## Applied

| patch | items | applied as | checked |
|---|---|---|---|
| `station-release-workflow.patch` | W0.3, W4.9 | `690b08f`, on `main`, 2026-11-10 | `main`'s tree is exactly `a570686` plus the patch. CI run 42878382277 on it is green. Before it was applied: `git am` on a clean `main`, `make version-check release-plan-test`, and actionlint 1.7.12 with shellcheck 0.9.0, all clean. |


## Not written yet

Each of these is a workflow change the plan needs, and none can be a
patch on `main` today: each waits on something that is not on `main`
yet. A lane added before then would be red.

| item | the workflow change | what has to be on `main` first |
|---|---|---|
| W4.4 | A `ref:` on the `struct` checkout | Stage 5 complete (W4.2). `build.yml` says to pin struct then and not before. |
| W3.11 | A `port` value for `sdkgen-station` in `release.yml` | The package registered for trusted publishing, and its release scripts |


## Writing one

```sh
git fetch origin main
git worktree add -b <scratch> <dir> origin/main
# edit, then commit with a full message, as for any change
git -C <dir> format-patch -1 --stdout > <name>.patch
```

Check it the way the maintainer will use it: `git am` on a clean
checkout of `main`, the repository's own gates on the result, and
[actionlint](https://github.com/rhysd/actionlint) with shellcheck on
every workflow file it touches.

Then commit the patch file, and its row under "Pending" with what was
run and when, to `main`, as a commit that holds nothing else. The
scratch branch is never pushed.

A patch may carry files outside `.github/workflows/` when they have to
land with the workflow change, as the release patch carried `AGENTS.md`
and the `Makefile`. Anything that can land on its own goes in an
ordinary pull request.
