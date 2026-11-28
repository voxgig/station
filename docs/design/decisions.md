# Decision records

Settled-by-record answers to open questions the design docs gate work
on. A row here is a **decision with a date and a revisit trigger**, not
prose in a section that can drift. Status `proposed` means the record
was drafted by the completion pass of 2026-08-24 and awaits owner
sign-off; code written against a proposed decision must be cheap to
change if the sign-off reverses it. Status `accepted` means the owner
has ruled, and the status line gives the date. `parked` means the
owner has ruled that the question waits, and on what.

The six records dated 2026-11-11 are the owner's rulings on the
decisions `docs/plan/plan.md` §5 put to them as DEC-1 to DEC-7. Each
names the option that was chosen and the ones that were not. Where a
ruling went against the plan's recommendation, the record says so.

## D-2026-08-24-1 — Grant scoping is per instance

**Status: accepted by the owner on 2026-11-11 (DEC-2); proposed
2026-08-24. Gates: R2 (`resolve: proxy`), the proxy grant table,
`/v1/grants` addressing.**

`station.md` §5.3's grant was plugin-scoped; the Stage 2 identity
change re-keyed the registry, the secret broker's overrides, and the
placeholders by **instance** (`name$tag`). The grant follows the same
key: **a grant is issued per instance, not per api.**

Why: the declarative design's own §15 calls per-instance "the obvious
answer", and the identity argument is the same one Stage 2 settled —
`stripe$test` and `stripe$live` differ in exactly the material a grant
protects (credential, base URL, blast radius). An api-scoped grant
would re-introduce the pre-instance identity at the security boundary,
the one place a coarser key is least defensible. The cost is the
proxy's grant table is keyed by instance ref and sized by instances
rather than apis — bounded by the same §8.5 bounds as everything else.

Consequences: `/v1/grants/{ref}` addresses an instance ref;
`station_grant_expired` names the instance; revocation of one instance
never touches its siblings on the same api.

Revisit if: a fleet with hundreds of instances per api makes grant
issuance a measured bottleneck (then consider api-level issuance with
instance-level revocation, which preserves the revocation grain).

## D-2026-08-24-2 — Remote v1 is single-team by policy

**Status: accepted by the owner on 2026-11-11 (DEC-2); proposed
2026-08-24. Gates: remote proxy mode (`station.md` §8.4, Phase 3).**

A remote proxy deployment in v1 serves **one trust domain**: everyone
who can reach it is assumed entitled to see every capture, call every
integration, and use every grant it holds. Visibility partitioning,
per-principal authz on call/replay/secrets, and grant scoping per app
identity are **v2 work, behind a design pass of their own** — they are
authorization systems, not options on this one.

Why: this is `station.md` §8.4's existing posture ("single-team by
policy") made a decision rather than a placeholder. The wire protocol
already reserves what v2 needs (`{ session, binding }` on register) so
single-team v1 does not force a wire v2.

Consequences for the proxy build: no per-principal state anywhere in
v1; the proof-of-token gate is the entire authn story; anything that
would need to know *who* is asking is out of scope until this record
is superseded.

Revisit if: anyone deploys a shared remote proxy across team
boundaries — that deployment is unsupported until the v2 design
exists, and the proxy README must say so.

## D-2026-11-11-1 — A non-JavaScript consumer gets station by a staged route

**Status: accepted by the owner on 2026-11-11 (DEC-1). Gates: every
non-JavaScript lane of a generated SDK that carries the station
feature, and the order in which ports gain a manifest.**

Station reaches a consumer outside npm in three steps, and a port can
be on any one of them:

1. **Optional.** Where the language allows it, a generated SDK does not
   require station at all. Its adapter loads station only when the
   feature initialises, as the ts, js, py and rb adapters already do,
   and the feature is generated inactive.
2. **A git pin.** Each port gains a manifest that installs it from this
   repository at a revision.
3. **A registry.** Station is published to a language's registry once
   sekreto and plugin are there, since station cannot be published
   where its own dependencies are not.

Why: on 2026-11-10 struct was on PyPI, RubyGems, crates.io, NuGet, Hex
and pub.dev, and sekreto and plugin were on npm only. Publishing
everywhere first would have every language wait on two other
repositories. Git pins alone cannot serve a published SDK: PyPI refuses
a git reference, Composer and SwiftPM cannot take a subdirectory of a
repository, and NuGet cannot take a git reference at all.

Not chosen: publish to every registry first; git pins only.

Consequences: the feature model stops writing a registry dependency
that does not resolve (voxgig/station#31). Each target's README says
which step its language is on. Go is outside this: it links station
statically and has its tag.

Revisit if: sekreto and plugin reach a registry, which moves that
language to step 3; or a language turns out to have no way to make the
dependency optional, which leaves it on step 2 until then.

## D-2026-11-11-2 — An event's host follows `URL.host` in three forms, and not in long-form IPv6

**Status: accepted by the owner on 2026-11-11 (DEC-4). Gates:
voxgig/station#55.**

After voxgig/station#56, four forms of a request URL's host still read
differently between ports. Three of them are brought to what canonical
`URL.host` gives, in all sixteen ports: an ASCII host is lower-cased,
an empty port is dropped, and a port is read as a number, so a leading
zero goes. The fourth is not: a long-form IPv6 address is reported as
it was sent, and §6 says so beside the host rule.

Why: the three are a few lines in any language. Compressing an IPv6
address needs an address parser, and most of the sixteen ports have
none to hand.

Not chosen: full `URL.host` parity in every port; documenting all four
forms as outside the rule and changing no code.

Consequences: each of the three is pinned in every port's suite beside
the six cases voxgig/station#56 pinned, since no corpus section can see
an event. An audit consumer comparing hosts across ports can rely on
them for everything but a long-form IPv6 literal.

Revisit if: the `event` corpus section lands and makes a fourth rule
cheap to hold every port to; or a consumer needs to compare IPv6 hosts
across ports.

## D-2026-11-11-3 — The kill switch has its own error code, and no reload in solo mode yet

**Status: accepted by the owner on 2026-11-11 (DEC-5). Gates:
voxgig/station#64.**

Policy mode `block` raises a code of its own, `station_blocked`. It no
longer shares `station_host_allow` with an allowlist miss. Changing
policy without a restart is not added to the solo library now.

Why: a caller, and an agent reading the error, must be able to tell "an
operator has stopped all traffic" from "this host is not on the list".
The code is one entry in §14's catalog and one case in the `errors`
corpus section. Live policy change is what attached mode's policy
long-poll is for, and that is designed already.

Not chosen: adding a `reload()` to the solo library of every port now;
leaving both as they are.

Consequences: `station_blocked` joins the error catalog in every port.
In solo mode the switch still takes effect at construction only, and
the design says so until attach lands. Whether solo mode ever gains a
`reload()` is left open, and nothing waits on it.

Revisit if: attach slips far enough that a solo deployment needs to
stop traffic without a restart.

## D-2026-11-11-4 — Station takes voxgig/plugin as a library dependency

**Status: accepted by the owner on 2026-11-11 (DEC-3), against the
plan's recommendation. Gates: workstream W8 of `docs/plan/plan.md`.**

Station's ports replace their native implementation of what plugin
defines with voxgig/plugin's port of their language, one port at a
time, the canonical first.

This reverses a position three documents hold.
`station-and-plugin.md` §2.1 settled that station builds natively to
plugin's semantics. `station-and-plugin-plan.md` §6 deferred the
dependency, and its §7 kept it deferred until a second consumer of
plugin exists. The plan put the same recommendation to the owner, who
ruled the other way. No second consumer has appeared: sdkgen's adoption
of plugin is still open (plugin's register, item 6.2).

What has changed since §2.1 was written is its first premise. It said a
station port cannot depend on a plugin library absent from its
language. Plugin now has twenty-three implementations passing its
corpus, and they cover all sixteen of station's languages.

What has not changed is its second. §2.1 put the cost at about 800
lines more per language than the native code it replaces, and that
figure has not been measured again.

Not chosen: keeping it deferred; deciding that station never takes the
library.

Consequences:

- **Three library dependencies, not two.** A station port may take
  sekreto, struct and plugin. `AGENTS.md` and the plan's standing rules
  say so from this record's date. omni stays test-only.
- **Plugin joins the distribution question.** A port that takes plugin
  cannot be published where plugin is not. Plugin is on npm, and has a
  tag for every port, which is all a Go consumer needs. It was on no
  other registry when this was written. sekreto is in the same
  position but for the tags, and D-2026-11-11-1's staged route covers
  both.
- **The C4 suite changes what it proves.** Today it runs plugin's
  corpus against station's own implementation. Once the canonical takes
  the library, it runs that corpus against the library through station,
  and the question it answers becomes whether station drives the
  library correctly.
- **Plugin's register, item 5.2, is answered**, and its item 3.1, the
  extraction against station, becomes the first step and not a proof
  for later.

Nothing is replaced by this record. The work is W8, which starts with a
design note saying what is replaced in a port, in what order the ports
go, and what the measured cost is.

Revisit if: the design note finds a port where the library cannot
replace the native code without changing behaviour the corpus pins; or
the measured cost per port is far from what §2.1 estimated.

## D-2026-11-11-5 — station-view waits for the proxy and attach

**Status: parked by the owner on 2026-11-11 (DEC-6); its "no code"
superseded by D-2026-11-14-1 on 2026-11-14, and its question ruled on
2026-11-16 by D-2026-11-16-1. Gates: voxgig/station-view.**

What station-view reads is not decided. No work is done on it, and the
question is not put again, until the proxy and attach have shipped.
That is 0.4.0: W5's items 1 to 7.

Not chosen: reading the proxy's `/v1/status`, `/v1/tap` and
`/v1/traffic`, which the plan recommended; reading one process's
in-memory event ring.

Consequences: voxgig/station-view stays as it is, tooling and no code.
Nothing in the plan depends on it.

Revisit when: Phase 1's exit is met. The two sources can then be
compared against something that runs.

## D-2026-11-11-6 — seneca-station waits for 0.3.0

**Status: parked by the owner on 2026-11-11 (DEC-7). Gates:
senecajs/seneca-station.**

What seneca-station is stays undecided, and the repository stays as it
is, a README and a licence, until station 0.3.0 is released.

Not chosen: a one-page design first, which the plan recommended;
deciding there will be no Seneca binding.

Consequences: none for the plan. It depends only on the released
TypeScript library, so nothing waits on it.

Revisit when: 0.3.0 is out (W2.11).

## D-2026-11-14-1 — station-view and station-mcp are extensions a Station loads when asked

**Status: requested by the owner on 2026-11-14. Supersedes the "no
code" of D-2026-11-11-5. Its open question is answered for now, and its
likeness consequence deferred, by D-2026-11-16-1. Gates:
voxgig/station-view, voxgig/station-mcp, voxgig/likeness.**

The owner asked for voxgig/station-view, and a new repository,
voxgig/station-mcp, to be plugins voxgig/station loads optionally, with
stub implementations for now, and for likeness to load both.

So a Station hosts extensions: voxgig/plugin definitions a caller hands
to `use()`, in a voxgig/plugin host whose first instance is the Station
itself (`station-extensions.md`). typescript goes first.

Consequences:
- station's typescript port takes `@voxgig/plugin` directly, ahead of
  W8.1's note, for extension hosting only (W8.6).
- station-view gets code: a stub that reads one process's in-memory
  event ring, one of the two sources D-2026-11-11-5 left open. Which
  source the real view reads is still open.
- station-mcp exists, as a stub answering two of the proxy's tools from
  the Station's public API, in the application's process.
- likeness loads both, in its TypeScript port.

Open: where station-mcp's real MCP surface runs. The design puts the
agent surface in the proxy (`station.md` §7), where no SDK code runs
and an agent cannot reach a secret. Served from an application's
process, it would not have that property. The stub decides nothing
about it, since it has no transport.

Revisit when: station-mcp grows a transport, or attach ships.

## D-2026-11-16-1 — Traffic is observed locally first: a view over sdkgen's telemetry features, an MCP that drives it, and generated mocks

**Status: directed by the owner on 2026-11-16, with four points ruled
by question the same day. Gates: voxgig/station-view,
voxgig/station-mcp, voxgig/sdkgen-validpack, voxgig/likeness.**

The owner's direction. Nothing is published yet, and the repositories
link to each other locally. station-view exposes a local web interface
for observing and filtering API traffic made through the SDKs, using
sdkgen's telemetry features and the hooks they provide. station-mcp
exposes an MCP a user drives to generate that traffic. likeness is the
live test eventually, and local mocks come first: voxgig/sdkgen-validpack
gains a target that generates a local mock for an API, in TypeScript,
which depends on a second target there that generates schema-valid,
human-readable test data deterministically from a seed.

Ruled by question:

1. **What station-view reads.** The callbacks of sdkgen's `telemetry`,
   `debug` and `audit` features and the counters of `metrics`, wired
   into every SDK a Station builds that carries them; and station's own
   `http` and `op` events for an SDK generated without them.
2. **station-mcp's tools** take the shape sdkgen's go-mcp target gives
   its own, per bound SDK: `<slug>_list` and `<slug>_load`, and
   `_create`, `_update`, `_patch` and `_remove` when writes are on,
   each taking `entity` and a `query` or `data` map. `station_status`
   and `station_integrations` stay.
3. **No third-party runtime dependency** in station-view's server and
   page, in station-mcp's server, or in the generated mock.
4. **"Schema-valid" means valid against the API definition's schemas**,
   read through apidef's resolved definition, as sdkgen's own
   definition tests read it. The model alone carries no enum, range,
   pattern or nested shape.

Consequences:
- The work is W9 of the plan. Station gains two extension points, so
  that an extension can add feature options to the SDKs a Station
  builds, and learn of each client it binds.
- station-mcp serves MCP from the application's process. That answers
  D-2026-11-14-1's open question for now. The proxy's surface
  (`station.md` §7) is unchanged, and is still where an agent cannot
  reach a secret; a tool's result here passes through the Station's
  redaction.
- station-view's server runs in the application's process first. A
  process that exits after one command, as each of likeness's does,
  needs a viewer that outlives it, which is a later item.
- likeness loads neither extension yet and stays on the published
  station. D-2026-11-14-1's consequence that it loads both waits for
  W9's last item.
- Nothing is released for this. A repository resolves another through
  a link in an ignored dependency directory, and no manifest names a
  path.

Not chosen: station-view carrying a pipeline feature of its own, which
would see raw credentials; the proxy's `station_call` as the tool
shape; the official MCP SDK, Fastify or a UI framework; validity
against the model's field types alone.

Revisit when: attach ships, since the proxy can then be what
station-view reads and where MCP is served; or likeness becomes the
live test.

## D-2026-11-17-1 — struct's `$ONE` goes, by a flag day at 0.4.0

voxgig/struct's `main` replaced the `$ONE` checker with `$NOF` on
2026-11-16 ([voxgig/struct#178]), and its `validate` now refuses a spec
that names a checker it lacks. Station's shape was written with `$ONE`,
and `build.yml` takes struct's `main`, so the ten lanes that read
struct from a checkout went red on every pull request. typescript
stayed green on npm's struct 0.2.2.

The owner ruled, by question, on 2026-11-16 and 2026-11-17:

1. **No pin.** struct is released with `$NOF`, and station migrates now.
2. **No station pull request merges until CI is green.** Station's work
   stacks on one branch meanwhile.
3. **A flag day.** The shape, the corpus and the option-spec reading
   move to `$NOF` alone. Station then works only beside an SDK generated
   by an sdkgen that vendors the new struct.
4. **No old-struct detection.** An SDK generated before the change, and
   holding its own struct in the same process, gets struct's errors as
   they are. The release notes say so.
5. **0.4.0** carries it, every port together, by `make version-set`.
6. **The upstream work is prepared from this session**: struct's
   release bump, then sdkgen's re-vendor at a new checkpoint, with its
   own specs moved to `$NOF`. The owner dispatches struct's and
   sdkgen's publishes and cuts the checkpoint in voxgig/admin.
7. **W9 carries on meanwhile**, and voxgig/sdkgen-validpack, which has no
   CI, merges on the local runs recorded in each pull request.

Consequences:
- A refusal reads `to be at least 1 of …` where it read `to be one of
  …`, and a list that is not a map reads `to be map`. The corpus pins
  the new wording.
- An option spec's `$NOF` bounds a value's kinds only when its count
  requires at least one alternative to admit the value; otherwise it
  admits any kind. The corpus has a case for each.
- In ruby, perl and php a process holds one struct, and once a generated
  SDK is loaded it is the SDK's copy. So station 0.4.0 refuses a valid
  `station.json` beside an SDK generated before the change. The c, cpp
  and perl payloads compile against the SDK's own struct, so the same
  holds inside such an SDK. typescript, javascript and go keep their own
  struct, and only the option-spec reading reaches them.
- Station's CI goes green when npm has the new `@voxgig/struct`, which
  the typescript lane installs. Its fixture SDKs follow once sdkgen
  vendors the new struct.

Not chosen: pinning struct at the last revision with `$ONE` and parking
the move; a `$ONE` alias in struct; a shape that speaks both grammars;
detecting an old struct to refuse more clearly.

Revisit when: never, for the grammar. The detection can still be added
if the errors beside an old SDK turn out to cost people time.

[voxgig/struct#178]: https://github.com/voxgig/struct/pull/178

## D-2026-11-17-2 — sdkgen resyncs struct in all twenty targets at once

Preparing sdkgen's half of the flag day (`sdkgen-18`) found that ten of
its twenty bundled targets carry hand-kept struct copies older than
`$NOF`, which no vendoring route produces: rb, php, rust, c, cpp, swift,
scala, clojure, elixir and ocaml. The prepared branch still handed them
`$ONE`, through a shim. But create-sdkgen's struct corpus cannot serve
both generations. The routed targets fail the old corpus on its `$ONE`
cases, and an old struct (rb, measured) fails the new one in `basic`,
`child` and `special`. Station's ruby and php ports also need their
generated SDKs on a `$NOF` struct (D-2026-11-17-1, its third
consequence).

The owner ruled, by question, on 2026-11-17: **resync all ten now.**

- struct is routed for all twenty targets, at the checkpoint the owner
  cuts.
- php's templates emit a `[]` shape that the new validate refuses; they
  are fixed first, in a commit of their own. rb's resync flips its null
  class, in a commit of its own that moves its characterization too.
- create-sdkgen's struct corpus is regenerated from struct's
  `build/test/validate.aon`, and sdkgen's runner templates move from
  `validate.one` to `nof` in the same change.
- Toolchains this machine lacks are installed where apt or a pinned
  tarball allows. A target that still cannot be built is named, not
  claimed.

Not chosen: rb and php now and the other eight later, behind a pinned
copy of the old corpus; holding sdkgen and releasing station 0.4.0 with
a documented gap in ruby and php.

Revisit when: a target cannot take struct's current port at all.

## D-2026-11-19-1 — the struct defects sdkgen's resync found go upstream, and every runner runs every validate group

Resyncing struct in all twenty of sdkgen's targets (D-2026-11-17-2)
found three struct ports that disagree with the canonical or lack what
a generated SDK needs, each carried in sdkgen as a marked patch
(`struct-9` to `struct-11`), and two questions for sdkgen
(`sdkgen-20`, `sdkgen-21`).

The owner ruled, by question, on 2026-11-19:

1. **File all three, and fix c's and cpp's in struct.** They are
   [voxgig/struct#181] to [voxgig/struct#183], and the two fixes are
   one pull request, [voxgig/struct#184]. The checkpoint does not wait
   for it: sdkgen keeps its patches until a checkpoint carries the
   fixes.
2. **A swift SDK keeps accepting invalid options, for now.** The gap
   between swift and the other targets stays recorded, and the sdkgen
   change makes no swift API change.
3. **Every generated SDK's struct runner runs every `validate` group,
   in the sdkgen change**, with a check in each runner that fails when
   a group is left out. A struct defect it finds is carried as a marked
   patch and taken upstream, never skipped.
4. **Nothing else starts** while W4.10 waits on struct's releases and
   the checkpoint.

Not chosen: filing without fixing, or recording without filing; a
throwing swift constructor, or a trap, now; the runners' gap as a
separate follow-up; starting W9.7 or W4.1 meanwhile.

Revisit when: a swift SDK's user is hurt by an option it should have
refused.

[voxgig/struct#181]: https://github.com/voxgig/struct/issues/181
[voxgig/struct#183]: https://github.com/voxgig/struct/issues/183
[voxgig/struct#184]: https://github.com/voxgig/struct/pull/184

## D-2026-11-19-2 — lua and elixir leave out the validate entries they cannot express, and the other skipped sections come next

Running every `validate` group in every generated SDK (`sdkgen-21`,
D-2026-11-19-1) found that lua cannot run fourteen of the entries and
elixir three. Each needs a JSON null the language cannot hold: a Lua
table cannot store a nil, and Elixir has one nil for null and absent.
struct's own lua and elixir runners leave out the same entries, each
named and guarded so that a change to the corpus fails rather than
skipping a different entry. It also found other corpus sections that
some targets' runners do not run.

The owner ruled, by question, on 2026-11-19:

1. **Accept the exclusions**, guarded and named as struct's runners
   have them.
2. **The other skipped sections are sdkgen's next pull request**, after
   the current one merges, with the same check per runner (`sdkgen-22`).

Not chosen: running the entries and leaving lua's and elixir's suites
red; folding the other sections into the current pull request; only
recording them.

Revisit when: lua or elixir gains a way to represent JSON null in
struct.

## D-2026-11-20-1 — struct's Go release and the checkpoint run from GitHub Actions

A struct Go release is its tag alone, `go/v0.2.0`, and until now only
`make publish-go` on a workstation could write it: struct's `publish.yml`
had no go target, and a session can push neither a tag nor a workflow
change. The checkpoint was the same: `make checkpoint` runs the four
repositories' gates side by side on a workstation, then pushes one tag to
all four.

The owner ruled, by question, on 2026-11-20:

1. **struct's `publish.yml` gains a `go` target.** It runs the build, vet
   and tests that `make publish-go` runs, then writes the tag. The change
   waits on struct's `claude/bold-newton-4of9bo` as a patch for the owner
   to apply. A dispatch then releases `go/v0.2.0`, and every later Go
   release.
2. **A workflow in voxgig/admin cuts checkpoints, with the four suites
   run together.** One job per repository runs that repository's gate,
   with all four cloned beside admin at the commits being checkpointed,
   and a last job tags all four with the Makefile's own `tag`. It needs
   `CHECKPOINT_TOKEN`, a fine-grained token with Contents: read and write
   on the four, and only the tagging step reads it. The workflow waits on
   admin's `claude/bold-newton-4of9bo` as a patch.

Not chosen: running `make publish-go` and `make checkpoint` by hand; a
checkpoint workflow that tags each `main` once that repository's own CI
has passed there, which drops the side-by-side run a checkpoint exists
for.

Revisit when: the first checkpoint run shows that one runner per
repository cannot hold every toolchain its gate needs.

## D-2026-11-27-1 — The extensions are completed in local TypeScript: a record log for the view, and one id per call from sdkgen

**Status: directed by the owner on 2026-11-27, with two points ruled by
question the same day. Gates: voxgig/station-view, voxgig/station-mcp,
voxgig/sdkgen, voxgig/likeness.**

The owner's direction: stay with local TypeScript, and complete it.
station-view and station-mcp do everything the design asks of an
extension in the application's process, in typescript, before the
proxy, attach, another language or a release. That is W10 of the plan.

Ruled by question:

1. **How station-view outlives a process.** A record log. Each process
   appends its records, already redacted, to a local log that only its
   owner can read, and a `station-view` command serves the same page
   from that log: live as records arrive, and with the history from
   before it started. Nothing has to be running while the commands run.
2. **One call's records are joined, in every sdkgen target.** One
   sdkgen change puts the operation context's id on `telemetry`'s span,
   `debug`'s entry and `audit`'s record in all twenty targets, and a
   release carries it (`sdkgen-17`). station-view joins a call's
   records on that id.

Consequences:
- station-mcp gates a write as the proxy does: its `write` option and
  the instance's `agent.write` must both be on (`station.md` §7). It
  labels what it returns as external data, as the proxy does.
- station-mcp answers `station_describe`, `station_traffic`,
  `station_secrets` and `station_policy` in process, from the
  Station's public API. `station_secrets` needs the Station to say which
  store answers each secret, never its value, which the typescript
  Station adds. `station_call` stays replaced by the per-SDK tools
  (D-2026-11-16-1), and `station_replay` stays the proxy's.
- station-mcp serves MCP's streamable HTTP transport beside stdio, on
  loopback only.
- Both repositories build and test on npm's station 0.4.0, which
  carries the extension points, with no checkout link. Each gets a CI
  workflow, as a patch for the owner to apply.
- likeness's TypeScript port takes station 0.4.0 and loads both
  extensions, which is W9.7.

Not chosen: a viewer daemon that each process forwards its records to;
both a log and forwarding; changing only sdkgen's ts and js targets;
leaving a call's records unjoined.

Revisit when: attach ships, for which D-2026-11-14-1 and
D-2026-11-16-1 still hold; or a second language hosts extensions.

## D-2026-11-27-2 — likeness serves its SDKs over MCP with a command of its own

**Status: ruled by the owner by question on 2026-11-27. Gates:
voxgig/likeness (W9.7).**

The question: likeness's commands each exit at once, so station-view
fits through its record log, but station-mcp needs a process that stays
up. How should likeness's TypeScript port serve its three SDKs, Joplin,
Notion and Obsidian, over MCP?

Ruled: **a `likeness mcp` command.** It is new in the TypeScript port.
It serves the bound SDKs through station-mcp on stdio, or on streamable
HTTP with `--http`. Write tools stay off unless both gates are on. The
Go, Python, Ruby and C ports refuse it as `unsupported-capability`, as
C refuses the commands it cannot answer, so the transcript corpus
records it.

Consequences:
- likeness's command table lets a command name the ports that serve
  it. Every other port refuses it with one message, naming those ports.
- A transcript entry of such a command carries what the other ports
  answer as `unserved`, and each port's runner holds the entry to it.
  likeness's byte comparison judges the entry among the ports that
  serve it and, apart, among those that refuse it.
- `--write` is the extension's `write` option, and an instance's
  `agent.write` in station.json is the other gate (`station.md` §7).

Not chosen: an environment switch that turns any likeness command into
an MCP server; loading station-view alone in likeness, and showing the
MCP half of W10's exit with station's traffic demonstration only.

Revisit when: another likeness port can host station's extensions.

## D-2026-11-28-1 — W9.7 waits for an SDK `tls` option, takes station 0.5.0, and regenerates likeness's SDKs

**Status: ruled by the owner by question on 2026-11-28. Gates:
voxgig/sdkgen (`sdkgen-14`), voxgig/station (0.5.0), voxgig-sdk's
joplin, notion and obsidian SDKs, and voxgig/likeness (W9.7).**

Three questions W9.7 raised, each ruled:

1. **Where likeness keeps Obsidian's certificate pin.** Station 0.3.0
   and later hand a named instance's block options to its SDK
   (`station.md` §4), and the Obsidian SDK refuses likeness's
   `options.tls`. Ruled: **wait for an SDK `tls` option**
   (`sdkgen-14`). Every target's transport takes `tls`, which pins a
   server certificate or trusts an authority, with verification never
   switched off. The pin is then an SDK option, and station.json keeps
   the shape likeness writes. Not chosen: moving the pin into
   likeness.json; stripping it before the Station opens; keeping
   likeness on station 0.2.0.
2. **A station release.** Ruled: **release 0.5.0 now.** It carries the
   typescript Station's `secrets()` and `policies()`, and its use of the
   SDK's id as `corr`, which likeness's `mcp` command and its view
   need. Not chosen: waiting for a later release.
3. **likeness's SDKs.** Ruled: **regenerated within W9.7,** on the
   sdkgen release that carries `sdkgen-14` and `sdkgen-17`, so W9.7
   lands with a call's records joined. Not chosen: regenerating them
   after W9.7, as an item of their own; leaving them as they are.

Consequences:
- `sdkgen-14` is sdkgen's next change: a `tls` client option in
  `main.kit.optspec`, honoured by all twenty targets. Each target shows
  that no request byte leaves before the pin matches.
- likeness's TypeScript suite fails its seven Obsidian tests until the
  regenerated Obsidian SDK takes `tls`.

Revisit when: a target cannot honour `tls` without switching
verification off.
