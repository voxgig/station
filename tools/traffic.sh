#!/usr/bin/env bash
# Generates the SDK tools/traffic.js runs: solardemo in typescript, with this
# checkout's sdkgen-station, sdkgen's telemetry, debug, audit and metrics
# features, and voxgig/sdkgen-validpack's seed library and mock. Then links
# station-view's and station-mcp's station to this checkout, so the SDK and
# both extensions load one Station module.
#
#   tools/traffic.sh <dir>     then STATION_TRAFFIC_SDK=<dir>/traffic-sdk
#
# Needs node and npm with access to the registry, the typescript port
# installed and built, and checkouts of sdkgen-validpack, station-view and
# station-mcp: VALIDPACK_HOME, STATION_VIEW_HOME and STATION_MCP_HOME, else
# siblings of this checkout.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: tools/traffic.sh <dir>}
CREATE_SDKGEN=${CREATE_SDKGEN:-0.31.8}
VALIDPACK_HOME=${VALIDPACK_HOME:-$ROOT/../sdkgen-validpack}
STATION_VIEW_HOME=${STATION_VIEW_HOME:-$ROOT/../station-view}
STATION_MCP_HOME=${STATION_MCP_HOME:-$ROOT/../station-mcp}

for f in typescript/dist/src/index.js typescript/node_modules; do
  if [ ! -e "$ROOT/$f" ]; then
    echo "traffic: $f is missing: install and build the typescript port first" >&2
    exit 1
  fi
done
for home in "$VALIDPACK_HOME/sdkgen-package.json" "$STATION_VIEW_HOME/typescript/dist/src/index.js" \
  "$STATION_MCP_HOME/typescript/dist/src/index.js"; do
  if [ ! -e "$home" ]; then
    echo "traffic: $home is missing: check out sdkgen-validpack, station-view and station-mcp" \
      "beside this checkout, or set VALIDPACK_HOME, STATION_VIEW_HOME and STATION_MCP_HOME" >&2
    exit 1
  fi
done

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
VALIDPACK_HOME=$(cd "$VALIDPACK_HOME" && pwd)

. "$ROOT/tools/sdkgen.sh"

generate solardemo traffic-sdk "$ROOT/test/api/solardemo/solardemo-1.0.0-openapi-3.0.0.yaml" \
  "station telemetry debug audit metrics validpack" ts

install traffic-sdk/ts @voxgig/station typescript
build traffic-sdk/ts-seed
build traffic-sdk/ts-mock

for home in "$STATION_VIEW_HOME" "$STATION_MCP_HOME"; do
  STATION_HOME="$ROOT" make -s -C "$home" link
done

echo "traffic: done; run node tools/traffic.js with STATION_TRAFFIC_SDK=$OUT/traffic-sdk"
