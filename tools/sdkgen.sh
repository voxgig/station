# The steps tools/fixtures.sh and tools/traffic.sh share, sourced by both.
# The caller sets ROOT (this checkout), OUT (where the SDKs go) and
# CREATE_SDKGEN, and VALIDPACK_HOME before it generates with `validpack`.

step() {
  local log=$1; shift
  if ! "$@" >>"$log" 2>&1; then
    echo "fixtures: failed: $* (log: $log)" >&2
    tail -20 "$log" >&2
    exit 1
  fi
}

# <features> names sdkgen features to add. Two name a package instead:
# `station` is this checkout's sdkgen-station, and `validpack` the checkout
# of voxgig/sdkgen-validpack at VALIDPACK_HOME, with its ts-seed and ts-mock.
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
      elif [ validpack = "$feature" ]; then
        mkdir -p node_modules/@voxgig
        ln -sfn "${VALIDPACK_HOME:?}" node_modules/@voxgig/sdkgen-validpack
        step "$log" npx --no-install voxgig-sdkgen package add @voxgig/sdkgen-validpack
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

# A generated package that takes no station: validpack's seed library and mock.
build() {
  local dir=$1
  local log="$OUT/$dir.log"
  (
    cd "$OUT/$dir"
    step "$log" npm install --no-audit --no-fund
    step "$log" npm run build
  )
  echo "fixtures: $dir: built"
}
