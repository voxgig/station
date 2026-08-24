# Decision records

Settled-by-record answers to open questions the design docs gate work
on. A row here is a **decision with a date and a revisit trigger**, not
prose in a section that can drift. Status `proposed` means the record
was drafted by the completion pass of 2026-08-24 and awaits owner
sign-off; code written against a proposed decision must be cheap to
change if the sign-off reverses it.

## D-2026-08-24-1 — Grant scoping is per instance

**Status: proposed (2026-08-24). Gates: R2 (`resolve: proxy`), the
proxy grant table, `/v1/grants` addressing.**

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

**Status: proposed (2026-08-24). Gates: remote proxy mode (`station.md`
§8.4, Phase 3).**

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
