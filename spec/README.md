# station conformance corpus

`station.json` is the shared, language-neutral test spec (design §13),
run by every station port through [voxgig/omni](https://github.com/voxgig/omni)
- the discipline sekreto already uses (`spec/sekreto.json`).

Sections here are the pure-contract half: `secretname`, `placeholder`,
`descriptor`, `descriptorwarnings`, `canonical`, `config`, `instance`,
`profile`, `errors`.

## Two grammars, for as long as the rename is in flight

`plugin` -> `sdk` is a breaking rename across every port
(station-declarative-config.md §3.4, §13). Ports cross it one at a time,
so for the duration the corpus carries both sides and each port runs the
one it implements:

| section | grammar | run by |
|---|---|---|
| `instance` | `sdk` / `api` refs, the §3.3 four-source merge | ports on Stage 1 |
| `profile` | the pre-Stage-1 `plugin` key | ports not yet moved |

`instance` is a superset: everything `profile` pins is restated there in
the new grammar, alongside the two regression guards that are the reason
the section exists - **defaults applied after the merge** (a one-key
overlay must not overwrite the base's `active: false`) and **a name and
an untagged ref are the same key string**.

**`profile` is deleted when the last port crosses**, not before. A port
that has not been ported should keep the coverage it has rather than
skip a section and quietly test nothing - which is the failure mode this
table exists to avoid. `config` is TypeScript-only for now because
`validateConfig` is ported in Stage 5; sections are opt-in per port, so
that costs the others nothing.

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
