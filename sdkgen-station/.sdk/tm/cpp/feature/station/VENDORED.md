# Vendored libraries

This directory is the C++ station adapter's VENDORED payload, copied
into a generated SDK's `feature/station/` by the sdkgen-station feature
fan-out. The C++ SDK target is header-only and registry-less (no
package manifest exists to declare a dependency in - Package_cpp is a
deliberate no-op), so the library rides here, the precedent being the
SDK's own vendored struct at `utility/voxgigstruct/`. Being
header-only, it needs no Makefile change: every generated test TU
includes the whole SDK, and the generated `core/config.hpp` includes
`feature/station.hpp`, which includes this file.

| file | canonical source | copy discipline |
|---|---|---|
| `voxgig_station.hpp` | voxgig/station `cpp/src/voxgig_station.hpp` | byte-identical |

Refresh by re-copying from the canonical checkout (edit there first,
never here). In a generated project, never edit this file at all -
`add` is overwrite, and the next resync would silently revert the edit.
The header is stdlib-only (secrets are env-only - there is no sekreto
C++ port, and the library says so at runtime); nothing here adds a
runtime dependency.
