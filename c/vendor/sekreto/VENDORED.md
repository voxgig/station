# Vendored: voxgig/sekreto, C

sekreto's C port, which the station C library resolves secrets through
(design station.md §5, §10). C has no package registry, so the source is
carried here, read out of git at one sekreto commit by `tools/vendor.py`.

| path | sekreto source | why it is here |
|---|---|---|
| `src/` | `c/src/`, all of it | the core: the chain, the cache, redaction, and the four built-in kinds `env`, `memory`, `dotenv` and `file` |
| `plugins/minivault.c` | `c/plugins/minivault.c` | the mini vault plugin kind |
| `plugins/encode.c` | `c/plugins/encode.c` | `sek_unbase64`, the one plugin-side object the mini vault links |
| `plugins/sekretoplugins.h`, `plugins/support.h` | `c/plugins/` | the headers those two compile against |

Every file opens with a three-line stamp naming the commit,
`SEKRETO_C_COMMIT` in `tools/vendor.py`; below the stamp it is
byte-identical to sekreto at that commit. `make vendor-check` fails on a
changed, missing or orphaned file and runs in CI, and `make
vendor-refresh` rewrites the copy. Both read a sekreto checkout that holds
the commit (`SEKRETO_HOME`). Never edit here: move the pin and refresh.

## Linking

The core is built on voxgig/plugin's C host (`host.h`), sekreto's own
dependency, which `c/Makefile` finds as a sibling checkout
(`PLUGIN_HOME`). It links no crypto. The mini vault links libcrypto and
not libssl, because it opens no socket; `-lpthread` comes with it for a
glibc older than 2.34. A chain may name `minivault` only when the caller
links `minivault.c` and `encode.c` and passes `sek_plugin_minivault()` in
`vxstn_open_opts.plugins`, which is sekreto's own rule for every plugin
kind. `make check-core` reads each of those facts off the built
artifacts.

The mini vault is the only plugin kind here. Another is the same shape:
vendor its object and the objects it links, link the libraries it
needs, and pass its definition.
