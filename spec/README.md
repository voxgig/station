# station conformance corpus

`station.json` is the shared, language-neutral test spec (design §13),
run by every station port through [voxgig/omni](https://github.com/voxgig/omni)
- the discipline sekreto already uses (`spec/sekreto.json`).

Sections here are the pure-contract half: `secretname`, `placeholder`,
`substitute`, `descriptor`, `descriptorwarnings`, `canonical`, `config`,
`feature`, `instance`, `instanceref`, `errors`.

**Coverage is not uniform, and this is the honest count.** Eleven of the
sixteen ports run all eleven sections: `typescript` and the ten that took
Stage 5's later tranche (`javascript`, `python`, `go`, `java`, `ruby`,
`php`, `perl`, `rust`, `c`, `cpp`). Ten of those eleven also carry a
COMPLETENESS GUARD - a test asserting that the sections it runs, plus any
it explicitly pins as pending, are exactly the sections this file
carries, so a section added here cannot silently go untested.

Two gaps follow from that, both real:

- `dart`, `elixir`, `lua` and `swift` run EIGHT sections, and `csharp`
  NINE. They crossed the `plugin` -> `sdk` rename and took `substitute`,
  but not the later tranche, so `config` and `feature` are not opted in
  there yet, nor `instanceref` outside `csharp`, which took it with its
  named instances.
- `typescript` - the canonical port - has NO completeness guard. It
  hand-writes one test per section rather than deriving them from a
  table, so a section added here would silently not run in the very port
  the others are ported from. Verified by mutation: a bogus section added
  to `station.json` passes the typescript suite and fails ten others.

`substitute` is §5.3's placement, the pure half of `inject`: the
placeholder becomes the value in header values and in the URL query,
where an SDK percent-encodes it (either hex case) and the value is written
strictly encoded (every byte outside RFC 3986 unreserved, as upper-case
`%XX`). The path and the fragment are never touched, and a `?` inside
the fragment starts no query. Copy-on-inject, and
the scrub of a transport error that quotes the placed URL, stay in each
port's integration suite.

`feature` is §10.1's promised section: the
three-level merge with its depth boundary (a map-valued option replaces
wholesale) and the defaults-after-merge guard one level down, plus the
§8.4 order resolution - constraints, bands, vacuous absence, the cycle
rejection, and the pinned `station` wrap - the set station holds itself
to under C4, and the §8.5 option checker. One driver, three entry
shapes: `check` selects the checker, run against the descriptor feature
rows in `features` and answered as the faults' `code`, `feature` and
`key`; `merged` selects the resolver; anything else the merge.

`instance` is the §3.3 merge. An entry with a `ref` asks instead for the
options that instance is constructed with: its block's `options` and
`base` under the entry's `opts`, one top-level key at a time, which is
what `sdk(name)`, `create`, and a named `connect`, `adopt` or
`options(name, extra)` all hand the SDK.

The sections that need live SDK machinery - `inject` (copy-on-inject,
placeholder-safe `ctrl.explain`), `order` (wrap position, retry
attempts, cache hits), `event` correlation, `degrade` - are exercised by
each port's integration suite against real generated SDKs
(`typescript/test/quickstart.test.ts`, `typescript/test/pets.test.ts`),
because a JSON corpus cannot construct an SDK. As ports arrive, any
behavior that CAN be expressed as data moves into this file - the
corpus is the contract, the integration suites are the proof it holds
against real generated code.

The boundary from the design holds here: this spec does not re-test
secret RESOLUTION (chain order, providers, envkey grammar) - that is
sekreto's spec. Station's sections test only the station half: the
right name asked for, the value placed correctly.
