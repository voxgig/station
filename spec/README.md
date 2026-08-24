# station conformance corpus

`station.json` is the shared, language-neutral test spec (design §13),
run by every station port through [voxgig/omni](https://github.com/voxgig/omni)
- the discipline sekreto already uses (`spec/sekreto.json`).

Sections here are the pure-contract half: `secretname`, `placeholder`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `feature`,
`instance`, `instanceref`, `profile`, `errors`.

## Two grammars, for as long as the rename is in flight

`plugin` -> `sdk` is a breaking rename across every port
(station-declarative-config.md §3.4, §13). Ports cross it one at a time,
so for the duration the corpus carries both sides and each port runs the
one it implements:

| section | grammar | run by |
|---|---|---|
| `instance` | `sdk` / `api` refs, the §3.3 four-source merge | **all eleven CI ports** |
| `profile` | the pre-Stage-1 `plugin` key | the five toolchain-gated ports |

`instance` is a superset: everything `profile` pins is restated there in
the new grammar, alongside the two regression guards that are the reason
the section exists - **defaults applied after the merge** (a one-key
overlay must not overwrite the base's `active: false`) and **a name and
an untagged ref are the same key string**.

**What is left, precisely.** `lua`, `dart`, `elixir`, `csharp` and
`swift` are not in the Makefile's `RUNNABLE` list and do not run in CI,
so a change to them cannot be verified here or there. They keep the
`plugin` grammar and keep running `profile`. **`profile` is deleted when
those five cross**, together with this table.

That is a deliberate stopping point rather than an oversight: porting a
language whose toolchain is absent means shipping an implementation
nobody has executed, and the corpus is the whole reason this repo does
not do that. Whoever has those toolchains should port them the way the
eleven were ported - the `instance` section is the specification, and it
is executable.

`config`, `instanceref` and `feature` are TypeScript-only for now
because `validateConfig`, `instanceRef` and `feature.ts` are ported in
Stage 5's later tranches; sections are opt-in per port, so that costs
the others nothing. `feature` is §10.1's promised section: the
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
