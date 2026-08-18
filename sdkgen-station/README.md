# @voxgig/sdkgen-station

An [sdkgen](https://github.com/voxgig/sdkgen) package providing the
`station` feature: it binds a generated SDK to a
[voxgig/station](https://github.com/voxgig/station) control surface —
descriptor registration, wire-truth request events, and placeholder
credential injection, with the secret values kept out of the SDK's
options, captures, and logs.

The package ships the feature model (`.sdk/model/feature/station.aontu`)
plus per-target adapter source under `.sdk/tm/<target>/`. The adapters
are thin: everything they call lives in the per-language station
library, which the generated manifest depends on.

## Install (in an SDK project)

```bash
cd my-sdk/.sdk
npm install --save-dev @voxgig/sdkgen-station
npx voxgig-sdkgen package add @voxgig/sdkgen-station
npm run generate
```

The npm install comes first because `package add` resolves from
`.sdk/node_modules` and deliberately does not fetch. The add installs
the feature and copies its adapter into every target already present;
`generate` then emits the feature, its config entry, and the station
library dependency.

The feature is generated **inactive**. Binding is opt-in at runtime:
`station.connect(SDK)` / `station.adopt(SDK)`, or the inverted form
`new SDK(st.options())` — see the station design's Developer
experience section (`docs/design/station.md` §11).
