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
CREATE_SDKGEN=${CREATE_SDKGEN:-0.31.12}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

for f in typescript/dist/src/index.js typescript/node_modules javascript/node_modules; do
  if [ ! -e "$ROOT/$f" ]; then
    echo "fixtures: $f is missing: install and build the typescript and javascript ports first" >&2
    exit 1
  fi
done

. "$ROOT/tools/sdkgen.sh"

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
