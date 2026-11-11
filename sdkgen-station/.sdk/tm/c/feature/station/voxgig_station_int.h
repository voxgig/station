/* voxgig/station - internal helpers shared by the library's translation
 * units (C port). NOT part of the public API: nothing here is
 * documented for consumers, and everything is prefixed `vxstn_` only
 * because a library vendored into a generated SDK must not export bare
 * names like `sdup` into that SDK's link.
 *
 * The library is five translation units - the core (voxgig_station.c),
 * the config shape (voxgig_station_shape.c), feature management
 * (voxgig_station_feature.c), the factory table plus the ref grammar
 * (voxgig_station_factory.c) and the secret store the broker asks
 * (voxgig_station_secrets.c). They share the small string/value helpers
 * below rather than each carrying a copy.
 *
 * The helpers are defined in voxgig_station.c, which is the file every
 * other one already links beside.
 */

#ifndef VOXGIG_STATION_INT_H
#define VOXGIG_STATION_INT_H

#define VXSTN_ENV_ONLY 1

#include "voxgig_station.h"

/* strdup, which C99 does not have. NULL is "". Owned. */
char* vxstn_sdup(const char* s);

/* A growable string builder. `buf` is owned by the caller once built -
 * free(sb.buf) - and there is no destructor for exactly that reason. */
typedef struct {
  char* buf;
  size_t len;
  size_t cap;
} vxstn_sb;

void vxstn_sb_init(vxstn_sb* sb);
void vxstn_sb_putn(vxstn_sb* sb, const char* s, size_t n);
void vxstn_sb_put(vxstn_sb* sb, const char* s);
void vxstn_sb_putc(vxstn_sb* sb, char c);
void vxstn_sb_putf(vxstn_sb* sb, const char* fmt, ...);

/* Map read treating a present null as absent (the ts `null == v`
 * config-surface reads). Borrowed. */
vxstn_val* vxstn_getk(const vxstn_val* map, const char* key);

/* Sorted (byte order) copy of a map's key pointers; caller frees the
 * array, not the strings. */
const char** vxstn_sortedkeys(const vxstn_val* map, size_t* n_out);

/* String() of a scalar config value. Owned. */
char* vxstn_val_to_string(const vxstn_val* v);

/* Set *out (when non-NULL) to a fresh error. */
void vxstn_seterr(vxstn_error** out, const char* code, const char* msg);

/* The store the secret broker asks, defined in voxgig_station_secrets.c:
 * sekreto's chain, or the environment in a VXSTN_ENV_ONLY build. */
typedef struct vxstn_store vxstn_store;

/* NULL + *err (station_secret_error, sekreto's message intact) for a chain
 * sekreto will not build. */
vxstn_store* vxstn_store_new(const vxstn_val* providers, void* const* plugins,
                             size_t nplugins, vxstn_error** err);

/* true with *out the value, or NULL for a miss, borrowed until the next
 * call; false + *err when a store could not answer. */
bool vxstn_store_get(vxstn_store* s, const char* name, const char** out,
                     vxstn_error** err);
void vxstn_store_refresh(vxstn_store* s);
void vxstn_store_free(vxstn_store* s);

#endif /* VOXGIG_STATION_INT_H */
