# station conformance corpus

`station.json` is the shared, language-neutral test spec (design §13),
run by every station port through [voxgig/omni](https://github.com/voxgig/omni)
- the discipline sekreto already uses (`spec/sekreto.json`).

Sections here are the pure-contract half: `secretname`, `placeholder`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `feature`,
`instance`, `instanceref`, `errors`.

Every section here is run by every port. `config`, `instanceref` and
`feature` were TypeScript-only while Stage 5's later tranches were in
flight; all sixteen ports now run all ten sections, each behind a
completeness guard that fails when a section in this file is neither run
nor explicitly pinned pending. `feature` is §10.1's promised section: the
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
