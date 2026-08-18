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

Refresh by re-copying from the canonical checkout (edit there first,
never here). In a generated project, never edit this file at all -
`add` is overwrite, and the next resync would silently revert the edit.
The module is stdlib-only (secrets are env-only - there is no sekreto
lua port, and the library says so at runtime); nothing here adds a
runtime dependency.
