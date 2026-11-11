# AGENTS.md

Guidance for AI coding agents (and humans) working on **voxgig/station**.

station is a multi-port library in the same family as
[`voxgig/sekreto`](https://github.com/voxgig/sekreto),
[`voxgig/omni`](https://github.com/voxgig/omni) and
[`voxgig/struct`](https://github.com/voxgig/struct), and it shares their
layout: per-language directories, `spec/` at the root, one shared corpus run
by every port through voxgig/omni. It differs from them in three ways that
matter, and each has burned someone.

## The three differences from its siblings

### 1. sekreto is a LIBRARY dependency, not a test one

Every other repo in this family declares voxgig/omni for **tests only**, and
`tools/omni_isolation.py` enforces that no shipped manifest names it (omni
register 4.13). That rule still holds here — but station additionally takes
**voxgig/sekreto as a genuine runtime dependency** (design §10).

sekreto is one of **exactly two** library dependencies a station port may
take. The other is **voxgig/struct**, which validates `station.json` at
`open()` rather than only under test (design §4, §9) — it is in
`typescript/package.json` `dependencies`, in `javascript/package.json` as
`@voxgig/struct-js`, and in the library `go/go.mod`, and
`docs/design/station.md` names the pair. Do not "clean up" either one.

ELEVEN of the sixteen ports take sekreto in shipped code, by seven different
mechanisms — so a sekreto compatibility sweep has eleven places to look, not
two:

| port | how it takes sekreto |
| --- | --- |
| `typescript` | npm `@voxgig/sekreto` `^0.3.0` |
| `javascript` | npm `@voxgig/sekreto-js` `^0.2.0` |
| `python` | PyPI `voxgig-sekreto>=0.1` |
| `go` | `github.com/voxgig/sekreto/go` — in the LIBRARY `go.mod`, not just `testutil/` |
| `rust` | path dep on `vendor/sekreto`, linked by `make vendor` |
| `csharp` | `SekretoPath` project reference |
| `ruby` | `require 'voxgig_sekreto'` from the load path |
| `java` | `import com.voxgig.sekreto.*`; `java/Makefile` finds a checkout and builds it |
| `php` | `require_once` via `src/Sekreto.php` — `SEKRETO_HOME` or a sibling checkout, no Composer package |
| `perl` | `require Voxgig::Sekreto` via `@INC` — sibling checkout, no CPAN distribution |
| `c` | source vendored at `c/vendor/sekreto`, read out of git at `SEKRETO_C_COMMIT` (`tools/vendor.py`) and stamped with it; sekreto's core is built on voxgig/plugin's C host from a sibling checkout (`PLUGIN_HOME`). The sdkgen-station payload is built env-only |

The remaining five — `cpp`, `swift`, `dart`, `elixir`, `lua` — do not load
sekreto at all; they mention it only in comments. (`perl`'s vendored SDK
payload does carry sekreto's modules — see `vendor-check` below.)

So a sekreto change can reach station's *shipped* code, which is never true of
omni. When sekreto releases, check station: `npm update @voxgig/sekreto` in
`typescript/`, and the equivalents elsewhere — for `c`, a new
`SEKRETO_C_COMMIT` and `make vendor-refresh`. The committed lockfiles pin real
versions, so a new sekreto does **not** arrive on its own.

### 2. The corpus is hand-written JSON, NOT compiled from aontu

`spec/station.json` is edited directly. There is **no `@voxgig/model`
dependency, no `.model-config/`, and no aontu source** anywhere in this
repository's own spec.

That is the opposite of sekreto, omni and struct, which compile their corpora
from `.aon` sources with `@voxgig/model` and gate freshness in CI. **Do not
"align" station by introducing that toolchain** — the corpus here has no build
step, and there is nothing to regenerate.

`spec/README.md` carries the honest coverage count: eleven of the sixteen
ports run all eleven sections, three run eight, two run nine, and typescript —
the canonical port — has no completeness guard. Read it before adding a
section.

### 3. The one `.aontu` file must stay `.aontu`

`sdkgen-station/.sdk/model/feature/station.aontu` is **not** a station spec
source. It is the model fragment of the published sdkgen package
`@voxgig/sdkgen-station`, found by sdkgen's `provides.feature` convention.

sdkgen's own shipped fragments are still `.aontu` as of **sdkgen 4.5.3**
(`.sdk/model/feature/*.aontu`, `.sdk/model/target/*.aontu`). Renaming station's
to `.aon` would break the package against every sdkgen in the field, and the
extension is sdkgen's call, not station's. Leave it alone until sdkgen moves.

## Release and publish

**Every port shares one version: the one in `VERSION`.** Every port but go
declares it, in its manifest or, where it has none, in a version constant; go's
version is its tag. So must the proxy daemon's `Version`, the c, cpp, lua and perl
payloads in sdkgen-station, and the station dependencies the sdkgen-station
feature model writes into generated SDKs. `make version-check` fails naming any
that differ; CI runs it in the `versions` job, and every release runs it
before it plans. `make version-set V=X.Y.Z` rewrites them all in one diff. **Never
bump one port alone.**

Three ports have a release route, and a release ships all three at `VERSION`:

| port | released as | tag |
| --- | --- | --- |
| `typescript/` | npm `@voxgig/station` | `typescript/v<version>` |
| `javascript/` | npm `@voxgig/station-js` | `javascript/v<version>` |
| `go/` | the tag itself: `go get github.com/voxgig/station/go@v<version>` | `go/v<version>` |

The other thirteen ports ship no package and have no publish flow; they are
consumed from this repository, and their declarations still follow `VERSION`.

Outside the shared version, on purpose: the `version` each port's carried
adapter gives the station *feature* (it mirrors the feature model's own
`version` and moves with sdkgen-station), sdkgen-station's own package version,
the wire, descriptor and event schema versions (design §8.6), and `rust/corpus`,
the unpublished conformance crate.

`sdkgen-station/` is a **third** npm package, `@voxgig/sdkgen-station` — the
sdkgen feature package described above. `release.yml` has no `port` value for
it, it carries no release scripts, and it is **not on npm** at all (0.0.1 has
never been published). Releasing it needs a route that does not exist yet;
bumping its version alone publishes nothing.

`make release-plan` shows, for each port, whether `VERSION` is released, the
commit its tag and its npm build came from, and what a release would still do.

`release.yml`'s header carries the `npm trust` command that registers a new
package. Note its `--file release.yml`. **Every other @voxgig package
registers `publish.yml`; station and sekreto use `release.yml`.** npm binds a trusted
publisher to one owner, one repo and a single workflow **filename**, so
renaming this file breaks publishing until the `npm trust` re-run — and an
unregistered workflow's OIDC token comes back **404, not 403**, a message that
reads as "the package does not exist" and costs an hour if you have not met it.

### Releasing

1. **Bump every port in a reviewed PR:** `make version-set V=X.Y.Z`, and
   commit the diff.
2. **Once it merges, Actions → release → Run workflow** on `main`. One run
   releases every port at `VERSION` from that commit: typescript and
   javascript publish to npm, then all three tags go up in one atomic push,
   after every publish has succeeded and the go module has passed as a
   consumer resolves it. A port already released at `VERSION` is skipped,
   but only while its directory is unchanged since its tag; otherwise the run
   refuses, because one version must not name two trees of a port.
3. `make release-plan` then reports every port `done`.

`allow_removals` exists because a release that would *remove* files from the
published package fails unless you declare it deliberate: adding files is
ordinary, silently dropping some is how a patch release breaks consumers.
`make pack-diff` is the same check by hand.

### Five jobs, each with the least it needs

| job | holds | runs |
| --- | --- | --- |
| `plan` | `contents: read` | the version gate and `tools/release_plan.py`: what each port still needs. |
| `npm` | `contents: read` | per npm port: sibling checkouts, install, build, tests, packaging checks — all project code and every dependency lifecycle script. Uploads the tarball. |
| `go` | `contents: read` | builds and tests the go module with no workspace, as a consumer resolves it. |
| `publish` | `id-token: write`, `contents: read` | per npm port: downloads that tarball and publishes it. **No checkout at all.** |
| `tag` | `contents: write` | git, and nothing else. |

`id-token: write` is a **job-level** grant — it reaches every process in the
job — so a compromised `postinstall` during install could mint a publish
credential. That is why the publish job never checks out the repository and
only ships the tarball the `npm` job produced.

The publish job's `contents: read` is belt-and-braces: with no checkout,
nothing there reads the repository and the grant could be dropped. It is
listed because a permissions table that omits a grant is worse than no table.

They cannot be split across two **files**: a ref pushed with `GITHUB_TOKEN`
starts no further workflow run, so "tag in A, publish on the tag" publishes
nothing, silently.

### Irreversible

**npm never allows republishing a version.** If a run publishes then fails
before tagging, re-dispatch: the plan finds the version on npm, built from this
commit, and only tags.

**That retry works only while `main` still points at the published commit.**
npm records no `gitHead` for a tarball publish, so the plan reads the source
commit from the version's provenance attestation, and refuses to tag a
different one. If `main` has moved on, do not re-dispatch, and do not bump the
version to get past it, which publishes a *second* version rather than
tagging the first. Push one port's tag on the published commit instead:

```sh
make release-plan                              # "npm built it from <commit>"
git tag <port>/v<version> <that commit>
git push origin <port>/v<version>
```

`release.yml` triggers on `typescript/v*`, `javascript/v*` and `go/v*` **tag
pushes**, and that run plans at the tagged commit: it publishes whatever is
missing and pushes the remaining tags. The pushed tag must be one of
`VERSION`'s port tags, and its commit must be on `main`.

**go is the exception, because it is a tag and nothing more.** A dispatch can
still tag go after `main` has moved, as long as `go/` is the same tree it was
on the commit the npm release came from. The plan says so when it does, and
names both commits. If `go/` has changed since, the plan refuses, and
`go/v<version>` is pushed by hand on that commit, as above.

Never publish locally over a token — that bypasses OIDC and its provenance
attestation.

`voxgig/apidef`'s `docs/how-to/release-and-tag.md` carries the fullest
write-up of this design; sekreto's `AGENTS.md` documents the same shape.

## Checks worth knowing

```sh
make test              # every port whose toolchain is present
make omni-isolation    # omni is declared by no shipped library, + the guard's own mutation test
make vendor-check      # the c/cpp/lua/perl SDK payloads match canonical (+ perl's sekreto copy, + c/vendor/sekreto at its pinned commit)
make sync-shape        # mirror spec/config-shape.json into the typescript and javascript ports
make pack-diff         # what a release would add to or remove from the package
make version-check     # every port declares VERSION, + the gate's own mutation test
make version-set V=X.Y.Z  # move every port to a new version in one diff
make release-plan      # per port: is VERSION released, and what would a release do
```

`make test` and the per-port suites need a **voxgig/omni checkout**
(`OMNI_HOME`, or a sibling directory); the c port also needs a
**voxgig/plugin checkout** (`PLUGIN_HOME`), as go and csharp do.
`vendor-refresh` and `vendor-check` additionally need a **voxgig/sekreto
checkout** (`SEKRETO_HOME`) that holds the commit `c/vendor/sekreto` is
pinned to.

## Source code comments

Follow [COMMENT-POLICY.md](COMMENT-POLICY.md): comments are sparse and terse,
only for intricate or surprising code. Names carry intent; documents carry
requirements. Run `make comments comments-test` after editing source.

Durable implementation rationale is in [COMMENT-NOTES.md](COMMENT-NOTES.md).

## The plan

[`docs/plan/`](docs/plan/README.md) holds the plan, the per-item
register and the upstream register. Read `docs/plan/status.md` before
starting work: it says what is in flight and what to pick up first.

**A change that lands a plan item updates that item's row in
`docs/plan/progress.md` in the same commit.** A change to a
dependency's pin, or to the state of an upstream issue, updates
`docs/plan/upstream.md`. Status lives there: `README.md` and the design
documents carry a status line each, and are corrected from it.

**For a change under `.github/workflows/`, create a patch on `main`.**
GitHub refuses a workflow change pushed without the `workflow` scope,
which a session's token does not have. Make the change on a scratch
branch cut from `main`, write it out with `git format-patch`, and commit
the patch file to `main` itself, in `docs/plan/patch/`, with its row in
`docs/plan/patch/README.md`. `main` is where the maintainer looks for
it: a patch left on a feature branch is not found. A session that may
not push to `main` says so at once, and asks. Do not leave the change
waiting for a human to write it.

**A commit message can close an issue.** `close`, `fix` or `resolve`, in
any tense, written directly before an issue's number closes that issue
when the commit reaches `main`, whatever the sentence around it meant.
One issue here closed a step early that way. Name an issue without one
of those words in front of it, unless closing it is the point.
