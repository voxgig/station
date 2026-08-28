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
**voxgig/sekreto as a genuine runtime dependency** (design §10): it is the one
library dependency a station port is allowed.

| port | how it takes sekreto |
| --- | --- |
| `typescript` | npm `@voxgig/sekreto` `^0.1.0` |
| `javascript` | npm `@voxgig/sekreto-js` `^0.1.0` |
| `python` | PyPI `voxgig-sekreto>=0.1` |
| `go` | `github.com/voxgig/sekreto/go` — in the LIBRARY `go.mod`, not just `testutil/` |
| `rust` | path dep on `vendor/sekreto`, linked by `make vendor` |
| `csharp` | `SekretoPath` project reference |

So a sekreto change can reach station's *shipped* code, which is never true of
omni. When sekreto releases, check station: `npm update @voxgig/sekreto` in
`typescript/`, and the equivalents elsewhere. The committed lockfiles pin real
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
ports run all ten sections, five run seven, and typescript — the canonical
port — has no completeness guard. Read it before adding a section.

### 3. The one `.aontu` file must stay `.aontu`

`sdkgen-station/.sdk/model/feature/station.aontu` is **not** a station spec
source. It is the model fragment of the published sdkgen package
`@voxgig/sdkgen-station`, found by sdkgen's `provides.feature` convention.

sdkgen's own shipped fragments are still `.aontu` as of **sdkgen 4.5.3**
(`.sdk/model/feature/*.aontu`, `.sdk/model/target/*.aontu`). Renaming station's
to `.aon` would break the package against every sdkgen in the field, and the
extension is sdkgen's call, not station's. Leave it alone until sdkgen moves.

## Release and publish

Two npm packages, released one at a time:

| port | package | tag |
| --- | --- | --- |
| `typescript/` | `@voxgig/station` | `typescript/v<version>` |
| `javascript/` | `@voxgig/station-js` | `javascript/v<version>` |

The other fourteen ports ship no package and have no publish flow; they are
consumed from this repository.

Both are published and tagged, so the path works end to end:

| package | npm | tag |
| --- | --- | --- |
| `@voxgig/station` | 0.1.0 | `typescript/v0.1.0` |
| `@voxgig/station-js` | 0.0.2 | `javascript/v0.0.2` |

> `release.yml`'s header still says "TRUSTED PUBLISHING IS PER PACKAGE, and
> NEITHER station package is registered yet", with `npm trust` commands to run
> "before the first release of each". **That is out of date** — both have since
> released through this workflow. Keep the commands as the reference for
> registering a *new* package; do not read them as a blocker.

Note the `--file release.yml` in those commands. **Every other @voxgig package
registers `publish.yml`; station and sekreto use `release.yml`.** npm binds a trusted
publisher to one owner, one repo and a single workflow **filename**, so
renaming this file breaks publishing until the `npm trust` re-run — and an
unregistered workflow's OIDC token comes back **404, not 403**, a message that
reads as "the package does not exist" and costs an hour if you have not met it.

### Releasing

**Actions → release → Run workflow** on `main`, choosing the `port`. The
version comes from that port's own manifest, so **bump it first in a reviewed
PR**, then dispatch.

`allow_removals` exists because a release that would *remove* files from the
published package fails unless you declare it deliberate: adding files is
ordinary, silently dropping some is how a patch release breaks consumers.
`make pack-diff` is the same check by hand.

### Three jobs, each with the least it needs

| job | holds | runs |
| --- | --- | --- |
| `build` | `contents: read` | sibling checkouts, install, build, tests, packaging checks — all project code and every dependency lifecycle script. Uploads the tarball. |
| `publish` | `id-token: write`, `contents: read` | downloads that tarball and publishes it. **No checkout at all.** |
| `tag` | `contents: write` | git, and nothing else. |

`id-token: write` is a **job-level** grant — it reaches every process in the
job — so a compromised `postinstall` during install could mint a publish
credential. That is why the publish job never checks out the repository and
only ships the tarball `build` produced.

The publish job's `contents: read` is belt-and-braces: with no checkout,
nothing there reads the repository and the grant could be dropped. It is
listed because a permissions table that omits a grant is worse than no table.

They cannot be split across two **files**: a ref pushed with `GITHUB_TOKEN`
starts no further workflow run, so "tag in A, publish on the tag" publishes
nothing, silently.

### Irreversible

**npm never allows republishing a version.** If a run publishes then fails
before tagging, re-dispatch: the registry check skips the completed publish and
retries the tag. Never publish locally over a token — that bypasses OIDC and
its provenance attestation.

`voxgig/apidef`'s `docs/how-to/release-and-tag.md` carries the fullest
write-up of this design; sekreto's `AGENTS.md` documents the same shape.

## Checks worth knowing

```sh
make test              # every port whose toolchain is present
make omni-isolation    # omni is declared by no shipped library, + the guard's own mutation test
make vendor-check      # the vendored sekreto/struct payloads match canonical
make sync-shape        # regenerate spec/config-shape.json
make pack-diff         # what a release would add to or remove from the package
```

`make test` and the per-port suites need a **voxgig/omni checkout**
(`OMNI_HOME`, or a sibling directory). `vendor-refresh` and `vendor-check`
additionally need a **voxgig/sekreto checkout** (`SEKRETO_HOME`).
