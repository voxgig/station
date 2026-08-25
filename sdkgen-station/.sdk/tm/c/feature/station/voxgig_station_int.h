/* voxgig/station - internal helpers shared by the library's translation
 * units (C port). NOT part of the public API: nothing here is
 * documented for consumers, and everything is prefixed `vxstn_` only
 * because a library vendored into a generated SDK must not export bare
 * names like `sdup` into that SDK's link.
 *
 * The Stage 5 tranche split the library into four translation units -
 * the core (voxgig_station.c), the config shape (voxgig_station_shape.c),
 * feature management (voxgig_station_feature.c) and the factory table
 * plus the ref grammar (voxgig_station_factory.c). They share the small
 * string/value helpers below rather than each carrying a copy.
 *
 * Definitions live in voxgig_station.c, which is the file every other
 * one already links beside.
 */

#ifndef VOXGIG_STATION_INT_H
#define VOXGIG_STATION_INT_H

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

#endif /* VOXGIG_STATION_INT_H */
