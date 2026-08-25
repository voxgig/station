# Vendored libraries

This directory is the lua station adapter's VENDORED payload, copied
into a generated SDK's `feature/station/` by the sdkgen-station feature
fan-out. No `voxgig-station` rock exists on LuaRocks, and a rockspec
dependency on a nonexistent package would break every consumer install,
so the library rides here and the generated rockspec lists it as a
`build.modules` entry instead of a dependency.

| file | canonical source | copy discipline |
|---|---|---|
| `voxgig_station.lua` | voxgig/station `lua/src/voxgig_station.lua` | byte-identical |

Refresh with `make vendor-refresh` from the voxgig/station root (edit
the canonical port first, never here); `make vendor-check` fails on any
difference and runs in CI. In a generated project, never edit this file
at all - `add` is overwrite, and the next resync would silently revert
the edit.

The module is stdlib-only and TIER C by design (station design
2.2/10.1): solo mode only, secrets env-only - there is no sekreto lua
port, and the library says so at runtime. Alone among the four vendored
payloads it needs no struct: it carries its own JSON handling, so the
copy is byte-identical with no transform at all and it loads from a
bare `require` with nothing else on the path. Nothing here adds a
runtime dependency.
