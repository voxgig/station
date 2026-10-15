/* voxgig/station - the secret broker (C port): sekreto resolves, the
 * broker holds what it resolved, privately. Resolved values never enter
 * options, events or captures; the SDK sees only the placeholder.
 *
 * Built with VXSTN_ENV_ONLY, as the sdkgen-station payload is, the broker
 * reads the process environment under envkey(name) instead, and says so.
 */

#define VXSTN_ENV_ONLY 1

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdlib.h>
#include <string.h>

#ifndef VXSTN_ENV_ONLY
#include "sekreto.h"

/* For sek_specof: sekreto reads its own provider spec, so a field it gains
 * reaches a chain from station.json with no change here (design 5.2). */
#include "internal.h"
#endif

typedef struct {
  char* key;
  char* value;
} vxstn_kv;

struct vxstn_broker {
  vxstn_kv* overrides; /* hoisted, keyed by INSTANCE (design 3.1) */
  size_t noverrides;
  vxstn_kv* cache; /* resolved, keyed by SECRET NAME (design 5.3) */
  size_t ncache;
  char** held; /* every value ever held, for the exact-value scrub */
  size_t nheld;
#ifndef VXSTN_ENV_ONLY
  sek_pool* pool;
  sek_sekreto* sek;
#endif
};

static const char* kv_get(const vxstn_kv* kvs, size_t n, const char* key) {
  size_t i;
  for (i = 0; i < n; i++) {
    if (0 == strcmp(kvs[i].key, key)) {
      return kvs[i].value;
    }
  }
  return NULL;
}

static void kv_set(vxstn_kv** kvs, size_t* n, const char* key, const char* value) {
  size_t i;
  for (i = 0; i < *n; i++) {
    if (0 == strcmp((*kvs)[i].key, key)) {
      free((*kvs)[i].value);
      (*kvs)[i].value = vxstn_sdup(value);
      return;
    }
  }
  *kvs = (vxstn_kv*)realloc(*kvs, (*n + 1) * sizeof(vxstn_kv));
  (*kvs)[*n].key = vxstn_sdup(key);
  (*kvs)[*n].value = vxstn_sdup(value);
  (*n)++;
}

static void kv_free(vxstn_kv* kvs, size_t n) {
  size_t i;
  for (i = 0; i < n; i++) {
    free(kvs[i].key);
    free(kvs[i].value);
  }
  free(kvs);
}

static void hold(vxstn_broker* b, const char* value) {
  b->held = (char**)realloc(b->held, (b->nheld + 1) * sizeof(char*));
  b->held[b->nheld++] = vxstn_sdup(value);
}

/* Literal (non-pattern) replace-all; owned result. */
static char* replaceall(const char* s, const char* find, const char* rep) {
  vxstn_sb sb;
  const char* p = s;
  size_t flen = strlen(find);
  if (0 == flen) {
    return vxstn_sdup(s);
  }
  vxstn_sb_init(&sb);
  for (;;) {
    const char* hit = strstr(p, find);
    if (NULL == hit) {
      vxstn_sb_put(&sb, p);
      break;
    }
    vxstn_sb_putn(&sb, p, (size_t)(hit - p));
    vxstn_sb_put(&sb, rep);
    p = hit + flen;
  }
  return sb.buf;
}

#ifdef VXSTN_ENV_ONLY

bool vxstn_broker_envonly(void) { return true; }

/* A chain naming any store but `env` gets one warning at open rather than
 * a silent read from a weaker store than the profile asked for. */
static char* envonly_warning(const vxstn_val* providers) {
  vxstn_sb missing;
  vxstn_sb warn;
  const char* seen[32];
  size_t nseen = 0;
  bool any = false;
  size_t i, j;

  vxstn_sb_init(&missing);
  for (i = 0; vxstn_is_list(providers) && i < providers->len; i++) {
    const vxstn_val* kindv = vxstn_getk(providers->items[i], "kind");
    const char* kind = vxstn_is_str(kindv) ? kindv->str : "?";
    bool dup = false;
    for (j = 0; j < nseen; j++) {
      if (0 == strcmp(seen[j], kind)) {
        dup = true;
        break;
      }
    }
    if (0 == strcmp("env", kind) || dup) {
      continue;
    }
    if (nseen < sizeof(seen) / sizeof(seen[0])) {
      seen[nseen++] = kind;
    }
    if (any) {
      vxstn_sb_put(&missing, ", ");
    }
    vxstn_sb_put(&missing, kind);
    any = true;
  }
  if (!any) {
    free(missing.buf);
    return NULL;
  }
  vxstn_sb_init(&warn);
  vxstn_sb_put(&warn, "c station is built env-only: provider kind(s) [");
  vxstn_sb_put(&warn, missing.buf);
  vxstn_sb_put(&warn, "] are not available; secrets are read from the process "
                      "environment only (design 2.2)");
  free(missing.buf);
  return warn.buf;
}

vxstn_broker* vxstn_broker_new(const vxstn_val* providers, void* const* plugins,
                               size_t nplugins, char** warn, vxstn_error** err) {
  char* text = envonly_warning(providers);
  (void)plugins;
  (void)nplugins;
  if (NULL != err) {
    *err = NULL;
  }
  if (NULL != warn) {
    *warn = text;
  } else {
    free(text);
  }
  return (vxstn_broker*)calloc(1, sizeof(vxstn_broker));
}

/* A set-but-empty variable is a present (empty) value, as sekreto's env
 * provider reads it; a malformed name is the one way this can fail. */
static bool lookup(vxstn_broker* b, const char* name, const char** out, vxstn_error** err) {
  char* key = vxstn_envkey(name, err);
  (void)b;
  *out = NULL;
  if (NULL == key) {
    return false;
  }
  *out = getenv(key);
  free(key);
  return true;
}

#else

bool vxstn_broker_envonly(void) { return false; }

/* A provider spec as the voxgig/plugin value sekreto reads it from. */
static Value* optionsof(const vxstn_val* v) {
  Value* out;
  size_t i;
  if (NULL == v) {
    return vnull();
  }
  switch (v->kind) {
    case VXSTN_BOOL:
      return vbool(v->b);
    case VXSTN_NUM:
      return vnum(v->num);
    case VXSTN_STR:
      return vstr(v->str);
    case VXSTN_LIST:
      out = vlist();
      for (i = 0; i < v->len; i++) {
        vpush(out, optionsof(v->items[i]));
      }
      return out;
    case VXSTN_MAP:
      out = vmap();
      for (i = 0; i < v->mlen; i++) {
        vset(out, v->keys[i], optionsof(v->vals[i]));
      }
      return out;
    default:
      return vnull();
  }
}

vxstn_broker* vxstn_broker_new(const vxstn_val* providers, void* const* plugins,
                               size_t nplugins, char** warn, vxstn_error** err) {
  vxstn_broker* b = (vxstn_broker*)calloc(1, sizeof(vxstn_broker));
  size_t count = vxstn_is_list(providers) ? providers->len : 0;
  sek_options options;
  sek_spec* specs;
  Definition** defs;
  size_t ndefs = 0;
  sek_err failed;
  size_t i;

  if (NULL != warn) {
    *warn = NULL;
  }
  if (NULL != err) {
    *err = NULL;
  }

  b->pool = sek_pool_new();
  specs = (sek_spec*)sek_alloc(b->pool, (0 == count ? 1 : count) * sizeof(sek_spec));
  for (i = 0; i < count; i++) {
    specs[i] = sek_specof(b->pool, optionsof(providers->items[i]));
  }

  defs = (Definition**)sek_alloc(b->pool, (0 == nplugins ? 1 : nplugins) * sizeof(Definition*));
  for (i = 0; NULL != plugins && i < nplugins; i++) {
    if (NULL != plugins[i]) {
      defs[ndefs++] = (Definition*)plugins[i];
    }
  }

  memset(&options, 0, sizeof(options));
  options.providers = specs;
  options.count = count;
  options.plugins = defs;
  options.plugincount = ndefs;

  failed = sek_new(b->pool, &options, &b->sek);
  if (NULL != failed) {
    vxstn_seterr(err, "station_secret_error", failed);
    sek_pool_free(b->pool);
    free(b);
    return NULL;
  }
  return b;
}

/* A store that could not answer - a wrong vault passphrase, an unreadable
 * file - is an error, and sekreto never falls through past it to a
 * weaker store. Only a miss carries on down the chain. */
static bool lookup(vxstn_broker* b, const char* name, const char** out, vxstn_error** err) {
  char* found = NULL;
  sek_err failed = sek_try(b->sek, name, &found);
  *out = found;
  if (NULL != failed) {
    vxstn_seterr(err, "station_secret_error", failed);
    return false;
  }
  return true;
}

#endif

void vxstn_broker_hoist(vxstn_broker* b, const char* instance, const char* value) {
  kv_set(&b->overrides, &b->noverrides, instance, value);
  hold(b, value);
}

const char* vxstn_broker_value(vxstn_broker* b, const char* instance, const char* name,
                               vxstn_error** err) {
  const char* known;
  const char* found = NULL;

  if (NULL != err) {
    *err = NULL;
  }

  known = kv_get(b->overrides, b->noverrides, instance);
  if (NULL != known) {
    return known;
  }
  known = kv_get(b->cache, b->ncache, name);
  if (NULL != known) {
    return known;
  }

  if (!lookup(b, name, &found, err)) {
    return NULL;
  }
  if (NULL == found) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "no store had \"");
    vxstn_sb_put(&msg, name);
    vxstn_sb_put(&msg, "\" for plugin \"");
    vxstn_sb_put(&msg, instance);
    vxstn_sb_putc(&msg, '"');
    vxstn_seterr(err, "station_secret_no_value", msg.buf);
    free(msg.buf);
    return NULL;
  }

  kv_set(&b->cache, &b->ncache, name, found);
  hold(b, found);
  return kv_get(b->cache, b->ncache, name);
}

/* Exact-value, WITHOUT sekreto's four-character floor (design 7 as
 * revised), and longest first, so a held value that contains another is
 * masked whole rather than leaving its tail. Owned. */
char* vxstn_broker_scrub(vxstn_broker* b, const char* text) {
  char* out = vxstn_sdup(text);
  const char** order;
  size_t i, j;

  if (0 == b->nheld) {
    return out;
  }
  order = (const char**)malloc(b->nheld * sizeof(char*));
  for (i = 0; i < b->nheld; i++) {
    const char* cur = b->held[i];
    for (j = i; 0 < j && strlen(order[j - 1]) < strlen(cur); j--) {
      order[j] = order[j - 1];
    }
    order[j] = cur;
  }
  for (i = 0; i < b->nheld; i++) {
    if ('\0' != order[i][0]) {
      char* next = replaceall(out, order[i], "[redacted]");
      free(out);
      out = next;
    }
  }
  free((void*)order);
  return out;
}

void vxstn_broker_refresh(vxstn_broker* b) {
  kv_free(b->cache, b->ncache);
  b->cache = NULL;
  b->ncache = 0;
#ifndef VXSTN_ENV_ONLY
  sek_refresh(b->sek);
#endif
}

void vxstn_broker_free(vxstn_broker* b) {
  size_t i;
  if (NULL == b) {
    return;
  }
  kv_free(b->cache, b->ncache);
  kv_free(b->overrides, b->noverrides);
  for (i = 0; i < b->nheld; i++) {
    free(b->held[i]);
  }
  free(b->held);
#ifndef VXSTN_ENV_ONLY
  (void)sek_close(b->sek);
  sek_pool_free(b->pool);
#endif
  free(b);
}
