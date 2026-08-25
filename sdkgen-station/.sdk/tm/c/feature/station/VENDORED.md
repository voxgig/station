# Vendored libraries

This directory is the C station adapter's VENDORED payload, copied into
a generated SDK's `feature/station/` by the sdkgen-station feature
fan-out. C has no package registry to declare a station-library
dependency in (`Package_c` is a deliberate no-op; publishing IS the git
tag), so the library rides here and the SDK Makefile's `feature/*/*.c`
wildcard compiles it - the same vendoring precedent as
`utility/struct/` (voxgig_struct.h etc.).

| file | canonical source | copy discipline |
|---|---|---|
| `voxgig_station.h` | voxgig/station `c/src/voxgig_station.h` | byte-identical |
| `voxgig_station_int.h` | voxgig/station `c/src/voxgig_station_int.h` | byte-identical |
| `config_shape.h` | voxgig/station `c/src/config_shape.h` | byte-identical |
| `voxgig_station.c` | voxgig/station `c/src/voxgig_station.c` | byte-identical |
| `voxgig_station_factory.c` | voxgig/station `c/src/voxgig_station_factory.c` | byte-identical |
| `voxgig_station_feature.c` | voxgig/station `c/src/voxgig_station_feature.c` | byte-identical |
| `voxgig_station_shape.c` | voxgig/station `c/src/voxgig_station_shape.c` | byte-identical |

The list is not maintained by hand. `tools/vendor.py` globs `c/src` and
copies every `.c` and `.h` it finds, so a file added to the canonical
port and not carried here is drift like any other. Refresh with
`make vendor-refresh` from the voxgig/station root (edit the canonical
port first, never here); `make vendor-check` fails on any difference and
runs in CI. `config_shape.h` is generated - run `make -C c sync-shape`
before refreshing if `spec/config-shape.json` changed. In a generated
project, never edit these files at all - `add` is overwrite, and the
next resync would silently revert the edit.

The library is standalone C99 + POSIX and TIER C by design (station
design 2.2/10.1): solo mode only, secrets env-only (there is no sekreto
C port, and the library says so at runtime), no station.json file
lookup - configuration arrives in code.

It takes ONE build dependency, and the SDK already carries it:
`voxgig_station_shape.c` includes `voxgig_struct.h` for config
validation, which resolves through the SDK Makefile's existing
`-I utility/struct`, and the same wildcard that compiles this directory
compiles `utility/struct/*.c` into `libsdk.a`. That is voxgig/struct -
one of the exactly two dependencies a station library may take (design
station.md 10) - reached by the established vendoring path rather than a
new one. Nothing here adds a *runtime* dependency: the result is still a
self-contained static archive.
