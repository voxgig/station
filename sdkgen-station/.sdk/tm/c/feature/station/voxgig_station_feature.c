/* voxgig/station - feature management (design station.md 8): the
 * three-level merge, the constraint-and-band resolver, and the
 * descriptor-derived checker.
 *
 * The resolver is written to voxgig/plugin's 7 semantics so plugin can
 * extract it - one of the pieces the joint plan means by "station
 * builds natively to plugin's semantics".
 *
 * Pure data in, data out: no station handle, no SDK, nothing to
 * construct. That is what lets the corpus pin it (the `feature`
 * section) rather than leaving it to the integration suites.
 *
 * A port of typescript/src/feature.ts, which is canonical.
 */

#if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdlib.h>
#include <string.h>

/* Reserved on a feature entry: not options, and never passed through to
 * the SDK's own option map. */
const char* const VXSTN_RESERVED_KEYS[] = {"active", "order", NULL};

static bool reservedkey(const char* key) {
  size_t i;
  for (i = 0; NULL != VXSTN_RESERVED_KEYS[i]; i++) {
    if (0 == strcmp(VXSTN_RESERVED_KEYS[i], key)) {
      return true;
    }
  }
  return false;
}

/* =========================================================================
 * design 8.3 - the merge
 * =========================================================================*/

/* `feature` is the ONE key where design 3.3's shallow-per-key rule is
 * wrong: composition is the entire point, a fleet default plus a
 * per-instance tweak. So it is a TWO-LEVEL merge - per feature name,
 * then per option key - AND NO DEEPER. A map-valued option REPLACES
 * wholesale, which is what `{"$MERGE": {"deep": 2}}` states and what a
 * port defaulting to a deep merge would silently get wrong.
 *
 * NO DEFAULTS ARE SYNTHESIZED HERE - the caller passes RAW blocks. An
 * entry mentioned at one level with only a tuning key must NOT
 * synthesize `active` and switch on a feature a broader level turned
 * off. That is the design 3.3 defect one level down. Owned. */
vxstn_val* vxstn_merge_features(const vxstn_val* sources) {
  vxstn_val* out = vxstn_map();
  size_t s;

  if (!vxstn_is_list(sources)) {
    return out;
  }
  for (s = 0; s < sources->len; s++) {
    const vxstn_val* src = sources->items[s];
    size_t i;
    if (!vxstn_is_map(src)) {
      continue;
    }
    for (i = 0; i < src->mlen; i++) {
      const char* name = src->keys[i];
      const vxstn_val* entry = src->vals[i];
      vxstn_val* prior;
      vxstn_val* merged;
      size_t k;

      if (!vxstn_is_map(entry)) {
        vxstn_map_set(out, name, vxstn_clone(entry));
        continue;
      }

      /* Per option key, and NOT deeper. */
      prior = vxstn_map_get(out, name);
      merged = vxstn_is_map(prior) ? vxstn_clone(prior) : vxstn_map();
      for (k = 0; k < entry->mlen; k++) {
        vxstn_map_set(merged, entry->keys[k], vxstn_clone(entry->vals[k]));
      }
      vxstn_map_set(out, name, merged);
    }
  }
  return out;
}

/* The six sources for one instance, in design 3.3's order extended by
 * the profile level:
 *
 *   1 base.feature            4 overlay.feature
 *   2 base.api[<api>].feature 5 overlay.api[<api>].feature
 *   3 base.sdk[<ref>].feature 6 overlay.sdk[<ref>].feature
 *
 * PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and within a profile
 * the narrower block wins - the same principle as design 3.3, one level
 * down. Assembled here rather than at the call site so the order lives
 * in exactly one place. An absent level contributes an undef entry, so
 * the list is always six long and the provenance labels line up with
 * it. Owned. */
vxstn_val* vxstn_feature_sources(const vxstn_val* base, const vxstn_val* overlay,
                                 const char* api, const char* ref) {
  vxstn_val* out = vxstn_list();
  const vxstn_val* levels[2];
  size_t i;
  levels[0] = base;
  levels[1] = overlay;

  for (i = 0; i < 2; i++) {
    const vxstn_val* lv = levels[i];
    const vxstn_val* f = vxstn_getk(lv, "feature");
    const vxstn_val* ablock = vxstn_getk(vxstn_getk(lv, "api"), NULL == api ? "" : api);
    const vxstn_val* sblock = vxstn_getk(vxstn_getk(lv, "sdk"), NULL == ref ? "" : ref);
    vxstn_list_push(out, NULL == f ? vxstn_undef() : vxstn_clone(f));
    vxstn_list_push(out, NULL == vxstn_getk(ablock, "feature")
                             ? vxstn_undef()
                             : vxstn_clone(vxstn_getk(ablock, "feature")));
    vxstn_list_push(out, NULL == vxstn_getk(sblock, "feature")
                             ? vxstn_undef()
                             : vxstn_clone(vxstn_getk(sblock, "feature")));
  }
  return out;
}

/* =========================================================================
 * design 8.4 - activation and order
 * =========================================================================*/

/* `test` substitutes the base transport, so it takes the innermost
 * band; `station` sits immediately outside it, pinned; everything else
 * is band 0, outside station.
 *
 * THE DEFAULT IS TODAY'S BEHAVIOUR EXPRESSED IN THE NEW MODEL rather
 * than as a special case: a project that writes no `order` anywhere
 * sees exactly today's nesting. HIGHER IS FURTHER IN. */
int vxstn_default_band(const char* name) {
  if (NULL == name) {
    return VXSTN_BAND_DEFAULT;
  }
  if (0 == strcmp("test", name)) {
    return VXSTN_BAND_TEST;
  }
  if (0 == strcmp("station", name)) {
    return VXSTN_BAND_STATION;
  }
  return VXSTN_BAND_DEFAULT;
}

/* A feature named in the config is one you are ASKING for, so an entry
 * with no `active` is active. Only an EXACT boolean false switches it
 * off - at the entry, or as the entry. */
bool vxstn_feature_active(const vxstn_val* entry) {
  const vxstn_val* activev;
  if (!vxstn_is_map(entry)) {
    return !(NULL != entry && VXSTN_BOOL == entry->kind && !entry->b);
  }
  activev = vxstn_map_get(entry, "active");
  return !(NULL != activev && VXSTN_BOOL == activev->kind && !activev->b);
}

/* `before`/`after` take a feature name or a list of them, stringified.
 * Calls `apply` with each. */
static void listof(const vxstn_val* v, void (*apply)(const char*, void*), void* ud) {
  size_t i;
  if (NULL == v || VXSTN_UNDEF == v->kind || VXSTN_NULL == v->kind) {
    return;
  }
  if (vxstn_is_list(v)) {
    for (i = 0; i < v->len; i++) {
      char* s = vxstn_val_to_string(v->items[i]);
      apply(s, ud);
      free(s);
    }
    return;
  }
  {
    char* s = vxstn_val_to_string(v);
    apply(s, ud);
    free(s);
  }
}

typedef struct {
  const char** names;
  size_t n;
  unsigned char* inner; /* n*n: inner[a*n+b] means b is further IN than a */
  size_t self;
  bool reverse; /* `before`: the named one is further in than self */
} orderctx;

static void addedge(const char* other, void* ud) {
  orderctx* ctx = (orderctx*)ud;
  size_t i;
  for (i = 0; i < ctx->n; i++) {
    if (0 != strcmp(ctx->names[i], other)) {
      continue;
    }
    /* A constraint naming an ABSENT feature is SATISFIED VACUOUSLY,
     * never an error - sdkgen's `__after__` behaviour kept rather than
     * reinvented. That is this loop finding no match and doing
     * nothing. */
    if (ctx->reverse) {
      ctx->inner[ctx->self * ctx->n + i] = 1;
    } else {
      ctx->inner[i * ctx->n + ctx->self] = 1;
    }
    return;
  }
}

/* Resolve the activation order: constraints, then bands, then the
 * feature's position in the merged map.
 *
 * Constraints beat bands; bands break ties no constraint decides;
 * remaining ties break by DECLARATION POSITION, so the result is a
 * stable topological sort with no alphabetical accident in it - and it
 * breaks the same way in every port.
 *
 * Returns OUTERMOST FIRST, which is the array form the constructor
 * takes and the direction plugin's chain composes in: a list of
 * { name, band, entry }. NULL + *err (station_feature_order) on a
 * cycle. Owned. */
vxstn_val* vxstn_resolve_order(const vxstn_val* merged, vxstn_error** err) {
  const char** names = NULL;
  double* band = NULL;
  unsigned char* inner = NULL;
  size_t* indeg = NULL;
  size_t* ready = NULL;
  unsigned char* done = NULL;
  size_t n = 0, i, j, nready = 0, nout = 0;
  vxstn_val* out;

  if (NULL != err) {
    *err = NULL;
  }
  out = vxstn_list();
  if (!vxstn_is_map(merged)) {
    return out;
  }

  names = (const char**)malloc((0 == merged->mlen ? 1 : merged->mlen) * sizeof(char*));
  for (i = 0; i < merged->mlen; i++) {
    if (vxstn_feature_active(merged->vals[i])) {
      names[n++] = merged->keys[i];
    }
  }
  if (0 == n) {
    free((void*)names);
    return out;
  }

  band = (double*)malloc(n * sizeof(double));
  inner = (unsigned char*)calloc(n * n, 1);
  indeg = (size_t*)calloc(n, sizeof(size_t));
  ready = (size_t*)malloc(n * sizeof(size_t));
  done = (unsigned char*)calloc(n, 1);

  for (i = 0; i < n; i++) {
    const vxstn_val* entry = vxstn_map_get(merged, names[i]);
    const vxstn_val* order = vxstn_is_map(entry) ? vxstn_getk(entry, "order") : NULL;
    const vxstn_val* bandv = vxstn_is_map(order) ? vxstn_getk(order, "band") : NULL;
    band[i] = (NULL != bandv && VXSTN_NUM == bandv->kind)
                  ? (bandv->isint ? (double)bandv->i : bandv->num)
                  : (double)vxstn_default_band(names[i]);
  }

  /* edges: from OUTER to INNER. `after: X` means "further in than X". */
  for (i = 0; i < n; i++) {
    const vxstn_val* entry = vxstn_map_get(merged, names[i]);
    const vxstn_val* order = vxstn_is_map(entry) ? vxstn_getk(entry, "order") : NULL;
    orderctx ctx;
    if (!vxstn_is_map(order)) {
      continue;
    }
    ctx.names = names;
    ctx.n = n;
    ctx.inner = inner;
    ctx.self = i;
    ctx.reverse = false;
    listof(vxstn_getk(order, "after"), addedge, &ctx);
    ctx.reverse = true;
    listof(vxstn_getk(order, "before"), addedge, &ctx);
  }

  for (i = 0; i < n; i++) {
    for (j = 0; j < n; j++) {
      if (inner[i * n + j]) {
        indeg[j]++;
      }
    }
  }

  for (i = 0; i < n; i++) {
    if (0 == indeg[i]) {
      ready[nready++] = i;
    }
  }

  /* Kahn, picking the LOWEST BAND first (outermost), then declaration
   * position. */
  while (0 < nready) {
    size_t pick = 0;
    size_t chosen;
    vxstn_val* row;
    for (i = 1; i < nready; i++) {
      if (band[ready[i]] < band[ready[pick]] ||
          (band[ready[i]] == band[ready[pick]] && ready[i] < ready[pick])) {
        pick = i;
      }
    }
    chosen = ready[pick];
    for (i = pick + 1; i < nready; i++) {
      ready[i - 1] = ready[i];
    }
    nready--;

    row = vxstn_map();
    vxstn_map_set(row, "name", vxstn_str(names[chosen]));
    vxstn_map_set(row, "band", vxstn_num(band[chosen]));
    vxstn_map_set(row, "entry", vxstn_clone(vxstn_map_get(merged, names[chosen])));
    vxstn_list_push(out, row);
    done[chosen] = 1;
    nout++;

    for (i = 0; i < n; i++) {
      if (inner[chosen * n + i] && 0 == --indeg[i]) {
        ready[nready++] = i;
      }
    }
  }

  if (nout != n) {
    /* The remainder form a cycle. */
    vxstn_sb sb;
    const char** stuck = (const char**)malloc(n * sizeof(char*));
    size_t nstuck = 0;
    bool any = false;
    for (i = 0; i < n; i++) {
      if (!done[i]) {
        stuck[nstuck++] = names[i];
      }
    }
    for (i = 1; i < nstuck; i++) {
      const char* cur = stuck[i];
      size_t k = i;
      while (0 < k && 0 < strcmp(stuck[k - 1], cur)) {
        stuck[k] = stuck[k - 1];
        k--;
      }
      stuck[k] = cur;
    }
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, "feature ordering constraints form a cycle among [");
    for (i = 0; i < nstuck; i++) {
      if (any) {
        vxstn_sb_put(&sb, ", ");
      }
      vxstn_sb_put(&sb, stuck[i]);
      any = true;
    }
    vxstn_sb_put(&sb, "]");
    vxstn_seterr(err, "station_feature_order", sb.buf);
    free(sb.buf);
    free((void*)stuck);
    vxstn_val_free(out);
    out = NULL;
  }

  free((void*)names);
  free(band);
  free(inner);
  free(indeg);
  free(ready);
  free(done);
  return out;
}

/* Station's own position is PINNED and not orderable (design 8.4): an
 * order that moves `station` away from immediately-outside-the-base is
 * REJECTED, not honoured.
 *
 * THE PIN IS INNERMOST, and the spelling matters. The chain composes
 * with the FIRST binding OUTERMOST, so a pin written in sort terms -
 * "station first" - would place every other wrapper between the adapter
 * and the base: the exact inversion of the invariant, and one that
 * would leave station's wire-truth events observing the wrong boundary
 * while still looking ordered. Returns an owned error, or NULL. */
vxstn_error* vxstn_check_pin(const vxstn_val* ordered) {
  size_t i;
  long at = -1;
  long base = -1;
  long want;
  vxstn_error* err = NULL;

  if (!vxstn_is_list(ordered)) {
    return NULL;
  }
  for (i = 0; i < ordered->len; i++) {
    const char* name = vxstn_strval(vxstn_map_get(ordered->items[i], "name"));
    if (0 == strcmp("station", name) && -1 == at) {
      at = (long)i;
    }
    if (0 == strcmp("test", name) && -1 == base) {
      base = (long)i;
    }
  }
  if (-1 == at) {
    return NULL;
  }

  /* station must be the innermost wrapper: last, or immediately outside
   * the base-transport feature when one is active. */
  want = -1 == base ? (long)ordered->len - 1 : base - 1;
  if (at != want) {
    vxstn_seterr(&err, "station_feature_order",
                 "an ordering would move `station` away from immediately "
                 "outside the base transport; its position is pinned "
                 "innermost and is not orderable (design 8.4)");
  }
  return err;
}

/* Compose the ordered rows into the ARRAY FORM the generated
 * constructor takes: { name, active: true, ...entry minus the reserved
 * keys }. Reserved keys are not options and are never passed through to
 * the SDK's own option map. Owned. */
vxstn_val* vxstn_compose_features(const vxstn_val* ordered) {
  vxstn_val* out = vxstn_list();
  size_t i;
  if (!vxstn_is_list(ordered)) {
    return out;
  }
  for (i = 0; i < ordered->len; i++) {
    const vxstn_val* row = ordered->items[i];
    const vxstn_val* entry = vxstn_map_get(row, "entry");
    vxstn_val* item = vxstn_map();
    size_t k;
    vxstn_map_set(item, "name", vxstn_str(vxstn_strval(vxstn_map_get(row, "name"))));
    vxstn_map_set(item, "active", vxstn_bool(true));
    for (k = 0; vxstn_is_map(entry) && k < entry->mlen; k++) {
      if (reservedkey(entry->keys[k])) {
        continue;
      }
      vxstn_map_set(item, entry->keys[k], vxstn_clone(entry->vals[k]));
    }
    vxstn_list_push(out, item);
  }
  return out;
}

/* =========================================================================
 * design 8.5 - the checker, derived from the descriptor
 * =========================================================================*/

/* The FEATURE kindof: `null`/absent -> "null", list -> "list", any
 * number -> "number", map -> "map", else the type name. NOT the shape
 * kindof of voxgig_station_shape.c ("object"/"integer" there), and
 * unifying the two would make one of the two sets of messages wrong. */
static const char* feature_kindof(const vxstn_val* v) {
  if (NULL == v || VXSTN_UNDEF == v->kind || VXSTN_NULL == v->kind) {
    return "null";
  }
  switch (v->kind) {
  case VXSTN_LIST:
    return "list";
  case VXSTN_NUM:
    return "number";
  case VXSTN_MAP:
    return "map";
  case VXSTN_BOOL:
    return "boolean";
  case VXSTN_STR:
    return "string";
  default:
    return "null";
  }
}

static void sb_joinkeys(vxstn_sb* sb, const char** keys, size_t n) {
  size_t i;
  for (i = 0; i < n; i++) {
    if (0 < i) {
      vxstn_sb_put(sb, ", ");
    }
    vxstn_sb_put(sb, keys[i]);
  }
}

/* Check a merged feature map against the SDK'S OWN DECLARATION.
 *
 * The schema arrives with the FACTORY rather than with a live client
 * (design 6.2), so this needs no construction and no network - which is
 * what lets `check()` run it for every instance in CI.
 *
 * Derived from the descriptor, NEVER hand-written, so it cannot drift:
 * when a feature gains an option, the next regeneration teaches station
 * about it with no station change.
 *
 * SCALARS AGREE BY CONSTRUCTION; COMPOUND OPTIONS ARE KIND-CHECKED
 * ONLY, and that limit is real and deliberate: an empty list default
 * says nothing reliable about its element type and a nested map default
 * says nothing about its value shapes.
 *
 * COLLECTS, never raises - the callers own the error. Returns an owned
 * list of { code, feature, key?, message }, iterating feature names and
 * option keys in SORTED order so two ports report the same first
 * fault. */
vxstn_val* vxstn_check_features(const vxstn_val* merged, const vxstn_val* descriptor) {
  vxstn_val* faults = vxstn_list();
  const vxstn_val* declared = vxstn_getk(descriptor, "features");
  const char** dnames;
  const vxstn_val** drows;
  size_t ndeclared = 0;
  const char** mnames;
  size_t nmerged = 0;
  size_t i, j;

  ndeclared = vxstn_is_list(declared) ? declared->len : 0;
  dnames = (const char**)malloc((0 == ndeclared ? 1 : ndeclared) * sizeof(char*));
  drows = (const vxstn_val**)malloc((0 == ndeclared ? 1 : ndeclared) * sizeof(vxstn_val*));
  for (i = 0; i < ndeclared; i++) {
    dnames[i] = vxstn_strval(vxstn_map_get(declared->items[i], "name"));
    drows[i] = declared->items[i];
  }
  /* Sorted for the "it declares [...]" list; the index below is a
   * linear scan because a feature list is a handful of rows. */
  for (i = 1; i < ndeclared; i++) {
    const char* cur = dnames[i];
    size_t k = i;
    while (0 < k && 0 < strcmp(dnames[k - 1], cur)) {
      dnames[k] = dnames[k - 1];
      k--;
    }
    dnames[k] = cur;
  }

  mnames = vxstn_sortedkeys(merged, &nmerged);

  for (i = 0; i < nmerged; i++) {
    const char* name = mnames[i];
    const vxstn_val* spec = NULL;
    const vxstn_val* entry;
    const vxstn_val* defaults;
    const char** okeys;
    size_t nokeys, k;

    for (j = 0; j < ndeclared; j++) {
      if (0 == strcmp(vxstn_strval(vxstn_map_get(drows[j], "name")), name)) {
        spec = drows[j];
        break;
      }
    }
    if (NULL == spec) {
      vxstn_sb sb;
      vxstn_val* fault = vxstn_map();
      vxstn_sb_init(&sb);
      vxstn_sb_put(&sb, "the SDK has no feature \"");
      vxstn_sb_put(&sb, name);
      vxstn_sb_put(&sb, "\"; it declares [");
      sb_joinkeys(&sb, dnames, ndeclared);
      vxstn_sb_put(&sb, "]");
      vxstn_map_set(fault, "code", vxstn_str("station_feature_unknown"));
      vxstn_map_set(fault, "feature", vxstn_str(name));
      vxstn_map_set(fault, "message", vxstn_str(sb.buf));
      free(sb.buf);
      vxstn_list_push(faults, fault);
      continue;
    }

    entry = vxstn_map_get(merged, name);
    if (!vxstn_is_map(entry)) {
      continue;
    }
    defaults = vxstn_getk(spec, "options");
    if (!vxstn_is_map(defaults)) {
      defaults = NULL;
    }

    okeys = vxstn_sortedkeys(entry, &nokeys);
    for (k = 0; k < nokeys; k++) {
      const char* key = okeys[k];
      const vxstn_val* want;
      const vxstn_val* got;
      vxstn_val* fault;
      vxstn_sb sb;

      if (reservedkey(key)) {
        continue;
      }
      want = NULL == defaults ? NULL : vxstn_map_get(defaults, key);
      got = vxstn_map_get(entry, key);

      if (NULL == want) {
        const char** dkeys;
        size_t ndkeys;
        /* THE CASE THAT ACTUALLY BITES: `retry.retires: 5` is accepted
         * and silently ignored today, because the SDK's own feature
         * spec is `$OPEN` per feature so the SDK cannot catch it and
         * nothing else looks. */
        dkeys = vxstn_sortedkeys(defaults, &ndkeys);
        vxstn_sb_init(&sb);
        vxstn_sb_put(&sb, "feature \"");
        vxstn_sb_put(&sb, name);
        vxstn_sb_put(&sb, "\" declares no option \"");
        vxstn_sb_put(&sb, key);
        vxstn_sb_put(&sb, "\"; it declares [");
        sb_joinkeys(&sb, dkeys, ndkeys);
        vxstn_sb_put(&sb, "]");
        free(dkeys);
        fault = vxstn_map();
        vxstn_map_set(fault, "code", vxstn_str("station_feature_option"));
        vxstn_map_set(fault, "feature", vxstn_str(name));
        vxstn_map_set(fault, "key", vxstn_str(key));
        vxstn_map_set(fault, "message", vxstn_str(sb.buf));
        free(sb.buf);
        vxstn_list_push(faults, fault);
        continue;
      }

      if (0 != strcmp(feature_kindof(want), feature_kindof(got))) {
        char* shown = vxstn_canonical(got);
        vxstn_sb_init(&sb);
        vxstn_sb_put(&sb, "feature \"");
        vxstn_sb_put(&sb, name);
        vxstn_sb_put(&sb, "\" option \"");
        vxstn_sb_put(&sb, key);
        vxstn_sb_put(&sb, "\" expects ");
        vxstn_sb_put(&sb, feature_kindof(want));
        vxstn_sb_put(&sb, ", but found ");
        vxstn_sb_put(&sb, feature_kindof(got));
        vxstn_sb_put(&sb, ": ");
        vxstn_sb_put(&sb, shown);
        free(shown);
        fault = vxstn_map();
        vxstn_map_set(fault, "code", vxstn_str("station_feature_option"));
        vxstn_map_set(fault, "feature", vxstn_str(name));
        vxstn_map_set(fault, "key", vxstn_str(key));
        vxstn_map_set(fault, "message", vxstn_str(sb.buf));
        free(sb.buf);
        vxstn_list_push(faults, fault);
      }
    }
    free(okeys);
  }

  free(mnames);
  free((void*)dnames);
  free((void*)drows);
  return faults;
}
