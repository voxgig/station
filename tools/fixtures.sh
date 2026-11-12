#!/usr/bin/env bash
# Generates the SDKs the integration suites run against, from the OpenAPI
# definitions in test/api/, with this checkout's sdkgen-station feature,
# and links each one's station dependency to the port under test.
#
#   tools/fixtures.sh <dir>     then STATION_TEST_SDKS=<dir> for the suites
#
# Needs node and npm with access to the registry, and the typescript and
# javascript ports installed and built, since the generated SDKs are built
# against them.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: tools/fixtures.sh <dir>}
CREATE_SDKGEN=${CREATE_SDKGEN:-0.31.8}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

for f in typescript/dist/src/index.js typescript/node_modules javascript/node_modules; do
  if [ ! -e "$ROOT/$f" ]; then
    echo "fixtures: $f is missing: install and build the typescript and javascript ports first" >&2
    exit 1
  fi
done

step() {
  local log=$1; shift
  if ! "$@" >>"$log" 2>&1; then
    echo "fixtures: failed: $* (log: $log)" >&2
    tail -20 "$log" >&2
    exit 1
  fi
}

# <features> names sdkgen features to add; `station` is this checkout's
# sdkgen-station package.
generate() {
  local name=$1 dir=$2 def=$3 features=$4; shift 4
  local log="$OUT/$dir.log"
  echo "fixtures: $dir: generating ($*, with $features)"
  rm -rf "${OUT:?}/$dir" "$log"
  (cd "$OUT" && step "$log" npm create "@voxgig/sdkgen@$CREATE_SDKGEN" -- "$name" -o "$dir" -d "$def")
  (
    cd "$OUT/$dir/.sdk"
    for target in "$@"; do
      step "$log" npx --no-install voxgig-sdkgen target add "$target"
    done
    for feature in $features; do
      if [ station = "$feature" ]; then
        mkdir -p node_modules/@voxgig
        ln -sfn "$ROOT/sdkgen-station" node_modules/@voxgig/sdkgen-station
        step "$log" npx --no-install voxgig-sdkgen package add @voxgig/sdkgen-station
      else
        step "$log" npx --no-install voxgig-sdkgen feature add "$feature"
      fi
    done
    step "$log" npm run generate
  )
}

# npm installs a peer dependency it can resolve, which would give the SDK the
# published station; --legacy-peer-deps stops that, and the link puts the port
# under test where the SDK looks for it.
install() {
  local sdk=$1 package=$2 port=$3
  local log="$OUT/$sdk.log"
  (
    cd "$OUT/$sdk"
    step "$log" npm install --no-audit --no-fund --legacy-peer-deps
    mkdir -p node_modules/@voxgig
    rm -rf "node_modules/$package"
    ln -s "$ROOT/$port" "node_modules/$package"
    if node -e 'process.exit(require("./package.json").scripts.build ? 0 : 1)'; then
      step "$log" npm run build
    fi
  )
  echo "fixtures: $sdk: installed, with $package from $port"
}

TASKPAD="$ROOT/test/api/taskpad/taskpad-1.0.0-openapi-3.0.0.yaml"

generate taskpad taskpad-sdk "$TASKPAD" station ts rb php perl
generate gnarly-pets gnarly-pets-sdk "$ROOT/test/api/gnarly-pets/gnarly-pets-1.0.0-openapi-3.0.0.yaml" station ts js
generate solardemo voxgig-solardemo-sdk "$ROOT/test/api/solardemo/solardemo-1.0.0-openapi-3.0.0.yaml" station ts
# Without the station feature: what connect() and adopt() retrofit.
generate taskpad taskpad-plain-sdk "$TASKPAD" retry ts js rb php perl

install taskpad-sdk/ts @voxgig/station typescript
install gnarly-pets-sdk/ts @voxgig/station typescript
install voxgig-solardemo-sdk/ts @voxgig/station typescript
install gnarly-pets-sdk/js @voxgig/station-js javascript
install taskpad-plain-sdk/ts @voxgig/station typescript
install taskpad-plain-sdk/js @voxgig/station-js javascript

echo "fixtures: done; run the suites with STATION_TEST_SDKS=$OUT"
