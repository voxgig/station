# Vendored libraries

This directory is the perl station adapter's VENDORED payload, copied
into a generated SDK's `feature/station/` by the sdkgen-station feature
fan-out. Generated Perl SDKs load everything by absolute file path (the
vendored `Voxgig::Struct` precedent) and no Voxgig distribution exists
on CPAN, so the station library and its one dependency ride here rather
than in `Makefile.PL`'s `PREREQ_PM`.

| tree | canonical source | copy discipline |
|---|---|---|
| `lib/Voxgig/Station.pm`, `lib/Voxgig/Station/*` | voxgig/station `perl/lib/Voxgig/` | byte-identical, apart from the swapped NOTE ON COPIES paragraph at the top of `Station.pm` |
| `lib/Voxgig/Sekreto.pm`, `lib/Voxgig/Sekreto/*` | voxgig/sekreto `perl/lib/Voxgig/` | byte-identical |
| `spec/config-shape.json` | voxgig/station `spec/config-shape.json` | byte-identical |

The station tree is `Station.pm` plus `Adapter`, `Descriptor`, `Error`,
`Events`, `Factory`, `Feature`, `Loader`, `Profile`, `Secrets`, `Shape`
and `Struct`; sekreto's is `Sekreto.pm` plus `Providers` and `Sigv4`.
`spec/config-shape.json` is not code but the port reads it like code:
`Shape.pm` walks up from its own directory looking for
`spec/config-shape.json` and dies if eight levels turn up nothing, so a
payload without it is a generated SDK that throws on the first `open()`.
`feature/station/spec/` is four levels up from
`lib/Voxgig/Station/Shape.pm`, inside that walk. No other payload needs
it - c compiles `config_shape.h` in, cpp embeds the bytes in a generated
function, and lua does not validate against the shape at all.

That list is not maintained by hand - `tools/vendor.py` walks both
canonical `lib/Voxgig` trees and copies every `.pm` it finds, so a
module added canonically and not carried here is drift like any other.
A module here whose canonical source was deleted or renamed is an
orphan, reported by `vendor-check` and removed by `vendor-refresh`. And
the tool refuses to run at all without a voxgig/sekreto checkout,
because a check that could not see sekreto's half would pass by looking
at less.

Refresh with `make vendor-refresh` from the voxgig/station root (edit
the canonical ports first, never here); `make vendor-check` fails on
any difference and runs in CI. In a generated project, never edit these
files at all - `add` is overwrite, and the next resync would silently
revert the edit.

## The one transform

`Station.pm`'s header paragraph points the reader the opposite way in
each copy: the canonical says "edit HERE, then refresh the vendored
copy", this copy says "edit THERE first". Same information, opposite
direction. `vendor.py` swaps it; nothing else in any file differs.

Everything is core-Perl only apart from `Voxgig::Struct`, one of the
exactly two dependencies a station library may take (design station.md
10). `Station/Struct.pm` is a shim that tries a plain
`require Voxgig::Struct` before any checkout lookup, so in a generated
SDK it resolves against the SDK's own vendored `lib/Voxgig/Struct.pm`
with no `STRUCT_HOME` and no sibling checkout in sight. Nothing here
adds a CPAN dependency.
