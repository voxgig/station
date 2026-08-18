# Vendored libraries

This directory is the perl station adapter's VENDORED payload, copied
into a generated SDK's `feature/station/` by the sdkgen-station feature
fan-out. Generated Perl SDKs load everything by absolute file path (the
vendored `Voxgig::Struct` precedent) and no Voxgig distribution exists
on CPAN, so the station library and its one dependency ride here rather
than in `Makefile.PL`'s `PREREQ_PM`.

| tree | canonical source | copy discipline |
|---|---|---|
| `lib/Voxgig/Station*` | voxgig/station `perl/lib/Voxgig/` | byte-identical, apart from the swapped NOTE ON COPIES paragraph at the top of `Station.pm` |
| `lib/Voxgig/Sekreto*` | voxgig/sekreto `perl/lib/Voxgig/` | byte-identical |

Refresh by re-copying from the canonical checkouts (edit there first,
never here). In a generated project, never edit these files at all -
`add` is overwrite, and the next resync would silently revert the edit.
Everything is core-Perl only; nothing here adds a runtime dependency.
