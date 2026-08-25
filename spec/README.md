# station conformance corpus

`station.json` is the shared, language-neutral test spec (design §13),
run by every station port through [voxgig/omni](https://github.com/voxgig/omni)
- the discipline sekreto already uses (`spec/sekreto.json`).

Sections here are the pure-contract half: `secretname`, `placeholder`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `feature`,
`instance`, `instanceref`, `errors`.

**Coverage is not uniform, and this is the honest count.** Eleven of the
sixteen ports run all ten sections: `typescript` and the ten that took
Stage 5's later tranche (`javascript`, `python`, `go`, `java`, `ruby`,
`php`, `perl`, `rust`, `c`, `cpp`). Ten of those eleven also carry a
COMPLETENESS GUARD - a test asserting that the sections it runs, plus any
it explicitly pins as pending, are exactly the sections this file
carries, so a section added here cannot silently go untested.

Two gaps follow from that, both real:

- `csharp`, `dart`, `elixir`, `lua` and `swift` run SEVEN sections. They
  crossed the `plugin` -> `sdk` rename but have not taken the later
  tranche, so `config`, `instanceref` and `feature` are not opted in
  there yet.
- `typescript` - the canonical port - has NO completeness guard. It
  hand-writes one test per section rather than deriving them from a
  table, so a section added here would silently not run in the very port
  the others are ported from. Verified by mutation: a bogus section added
  to `station.json` passes the typescript suite and fails ten others.

`feature` is §10.1's promised section: the
three-level merge with its depth boundary (a map-valued option replaces
wholesale) and the defaults-after-merge guard one level down, plus the
§8.4 order resolution - constraints, bands, vacuous absence, the cycle
rejection, and the pinned `station` wrap - the set station holds itself
to under C4. One driver, two entry shapes: `merged` selects the
resolver, anything else the merge. Feature *option* checking is
descriptor-dependent and stays in the integration suites.

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
