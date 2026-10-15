/* voxgig/station - the secret store the broker asks (C port): sekreto's
 * chain, built from the profile's providers verbatim. Built with
 * VXSTN_ENV_ONLY, as the sdkgen-station payload is, it reads the process
 * environment under envkey(name) instead.
 */

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdlib.h>
#include <string.h>

#ifdef VXSTN_ENV_ONLY

struct vxstn_store {
  int envonly;
};

static vxstn_store ENVIRONMENT = {1};

vxstn_store* vxstn_store_new(const vxstn_val* providers, void* const* plugins,
                             size_t nplugins, vxstn_error** err) {
  (void)providers;
  (void)plugins;
  (void)nplugins;
  if (NULL != err) {
    *err = NULL;
  }
  return &ENVIRONMENT;
}

/* A set-but-empty variable is a present (empty) value, as sekreto's env
 * provider reads it; a malformed name is the one way this can fail. */
bool vxstn_store_get(vxstn_store* s, const char* name, const char** out,
                     vxstn_error** err) {
  char* key = vxstn_envkey(name, err);
  (void)s;
  *out = NULL;
  if (NULL == key) {
    return false;
  }
  *out = getenv(key);
  free(key);
  return true;
}

void vxstn_store_refresh(vxstn_store* s) { (void)s; }

void vxstn_store_free(vxstn_store* s) { (void)s; }

#else

#include "sekreto.h"

/* For sek_specof: sekreto reads its own provider spec, so a field it gains
 * reaches a chain from station.json with no change here (design 5.2). */
#include "internal.h"

struct vxstn_store {
  sek_pool* pool;
  sek_sekreto* sek;
};

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

vxstn_store* vxstn_store_new(const vxstn_val* providers, void* const* plugins,
                             size_t nplugins, vxstn_error** err) {
  vxstn_store* s = (vxstn_store*)calloc(1, sizeof(vxstn_store));
  size_t count = vxstn_is_list(providers) ? providers->len : 0;
  sek_options options;
  sek_spec* specs;
  Definition** defs;
  size_t ndefs = 0;
  sek_err failed;
  size_t i;

  if (NULL != err) {
    *err = NULL;
  }

  s->pool = sek_pool_new();
  specs = (sek_spec*)sek_alloc(s->pool, (0 == count ? 1 : count) * sizeof(sek_spec));
  for (i = 0; i < count; i++) {
    specs[i] = sek_specof(s->pool, optionsof(providers->items[i]));
  }

  defs = (Definition**)sek_alloc(s->pool, (0 == nplugins ? 1 : nplugins) * sizeof(Definition*));
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

  failed = sek_new(s->pool, &options, &s->sek);
  if (NULL != failed) {
    vxstn_seterr(err, "station_secret_error", failed);
    sek_pool_free(s->pool);
    free(s);
    return NULL;
  }
  return s;
}

/* A store that could not answer - a wrong vault passphrase, an unreadable
 * file - is an error, and sekreto never falls through past it to a
 * weaker store. Only a miss carries on down the chain. */
bool vxstn_store_get(vxstn_store* s, const char* name, const char** out,
                     vxstn_error** err) {
  char* found = NULL;
  sek_err failed = sek_try(s->sek, name, &found);
  *out = found;
  if (NULL != failed) {
    vxstn_seterr(err, "station_secret_error", failed);
    return false;
  }
  return true;
}

void vxstn_store_refresh(vxstn_store* s) { sek_refresh(s->sek); }

void vxstn_store_free(vxstn_store* s) {
  if (NULL == s) {
    return;
  }
  (void)sek_close(s->sek);
  sek_pool_free(s->pool);
  free(s);
}

#endif
