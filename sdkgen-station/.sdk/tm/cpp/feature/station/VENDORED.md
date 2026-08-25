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
| `voxgig_station.hpp` | voxgig/station `cpp/src/voxgig_station.hpp` | byte-identical apart from the two rewritten struct includes below |

Refresh with `make vendor-refresh` from the voxgig/station root (edit
the canonical port first, never here); `make vendor-check` fails on any
difference and runs in CI. In a generated project, never edit this file
at all - `add` is overwrite, and the next resync would silently revert
the edit.

## The one transform

The canonical header names struct as `#include "voxgig_struct.hpp"` and
`#include "value_io.hpp"`, which resolve because the canonical build
passes `-isystem <struct>/cpp/src`. A generated C++ SDK passes **no**
include flags at all - it is header-only and every include in it is
relative - so `tools/vendor.py` rewrites both to
`../../utility/voxgigstruct/`, which is where the SDK's own vendored
struct lives, two levels up from `feature/station/`. Without the
rewrite the payload does not compile in a generated SDK; with it, the
header compiles with no `-I` whatsoever. struct's own `value.hpp`,
included by `voxgig_struct.hpp`, resolves relative to the including
file and needs no help.

The rewrite is not best-effort: if `voxgig_station.hpp` ever stops
naming one of those two headers, `vendor.py` fails loudly rather than
writing a payload that looks refreshed and does not build.

That strictness applies to `voxgig_station.hpp` alone. Should `cpp/src`
gain a helper header later, it is carried as-is (with any struct include
it happens to name rewritten the same way) - holding every globbed
`.hpp` to the two-include rule would make a newly added file abort the
tool outright, defeating the new-file guard the glob exists to provide.
A header here whose canonical source was deleted is an orphan, reported
by `vendor-check` and removed by `vendor-refresh`.

The library is TIER C by design (station design 2.2/10.1): solo mode
only, secrets env-only - there is no sekreto C++ port, and the library
says so at runtime. Apart from stdlib it depends only on the vendored
`voxgig/struct` above, one of the exactly two dependencies a station
library may take (design station.md 10). Both are header-only, so there
is still nothing to link and no runtime dependency.
