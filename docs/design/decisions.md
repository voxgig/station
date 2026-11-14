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
superseded by D-2026-11-14-1 on 2026-11-14. Gates:
voxgig/station-view.**

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
code" of D-2026-11-11-5. Gates: voxgig/station-view,
voxgig/station-mcp, voxgig/likeness.**

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
