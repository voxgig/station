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
| `voxgig_station.c` | voxgig/station `c/src/voxgig_station.c` | byte-identical |

Refresh by re-copying from the canonical checkout (edit there first,
never here). In a generated project, never edit these files at all -
`add` is overwrite, and the next resync would silently revert the edit.

The library is standalone C99 + POSIX and TIER C by design (station
design 2.2/10.1): solo mode only, secrets env-only (there is no sekreto
C port, and the library says so at runtime), no station.json file
lookup - configuration arrives in code. Nothing here adds a build or
runtime dependency.
