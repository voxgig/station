/* RUN: make test
 * RUN-SOME: ./build/conform secretname
 *
 * The station conformance suite: the pure-contract half of the design's
 * (station.md 13) corpus, from spec/station.json, through voxgig/omni -
 * the same file every port runs. Sections that need live SDK machinery
 * (inject, order, event correlation) live in the generated-SDK
 * integration flow; the corpus carries what a port can prove with no
 * SDK present. Seven sections: canonical, descriptor,
 * descriptorwarnings, errors, placeholder, profile, secretname.
 *
 * Values cross the omni/station boundary through direct converters
 * (omni_json <-> vxstn_val), with omni_flags_nonull so a spec null
 * arrives as a real null, which is what the station subjects mean.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "omni.h"

#include "../src/voxgig_station.h"

static omni_pool *POOL = NULL;
static const char *ONLY = NULL;
static int PASSCOUNT = 0;
static int FAILCOUNT = 0;

/* ---- converters ---------------------------------------------------- */

static vxstn_val *to_station(const omni_json *v) {
  size_t i;
  if (NULL == v || OMNI_ABSENT == v->type) {
    return vxstn_undef();
  }
  switch (v->type) {
  case OMNI_NULL:
    return vxstn_null();
  case OMNI_BOOL:
    return vxstn_bool(0 != v->boolval);
  case OMNI_NUM:
    return vxstn_num(v->numval);
  case OMNI_STR:
    return vxstn_str(NULL == v->strval ? "" : v->strval);
  case OMNI_LIST: {
    vxstn_val *out = vxstn_list();
    for (i = 0; i < v->listlen; i++) {
      vxstn_list_push(out, to_station(v->list[i]));
    }
    return out;
  }
  case OMNI_MAP: {
    vxstn_val *out = vxstn_map();
    for (i = 0; i < v->maplen; i++) {
      vxstn_map_set(out, v->keys[i], to_station(v->vals[i]));
    }
    return out;
  }
  default:
    return vxstn_undef();
  }
}

static omni_json *to_omni(const vxstn_val *v) {
  size_t i;
  if (NULL == v || VXSTN_UNDEF == v->kind) {
    return omni_absent(POOL);
  }
  switch (v->kind) {
  case VXSTN_NULL:
    return omni_null(POOL);
  case VXSTN_BOOL:
    return omni_bool(POOL, v->b ? 1 : 0);
  case VXSTN_NUM:
    return omni_num(POOL, v->isint ? (double)v->i : v->num);
  case VXSTN_STR:
    return omni_str(POOL, v->str);
  case VXSTN_LIST: {
    omni_json *out = omni_list(POOL);
    for (i = 0; i < v->len; i++) {
      omni_list_push(out, to_omni(v->items[i]));
    }
    return out;
  }
  case VXSTN_MAP: {
    omni_json *out = omni_map(POOL);
    for (i = 0; i < v->mlen; i++) {
      omni_map_set(out, v->keys[i], to_omni(v->vals[i]));
    }
    return out;
  }
  default:
    return omni_absent(POOL);
  }
}

/* ---- subjects ------------------------------------------------------ */

static omni_result subject_secretname(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  const char *slug = omni_strval(omni_map_get(vin, "slug"));
  char *envtoken = vxstn_envtoken(slug);
  char *secretname = vxstn_secretname_default(slug);
  vxstn_error *err = NULL;
  char *envkey = vxstn_envkey(secretname, &err);
  omni_json *res;
  (void)self;

  if (NULL == envkey) {
    out.err = omni_pool_strdup(POOL, NULL == err ? "envkey failed" : err->message);
    vxstn_error_free(err);
    free(envtoken);
    free(secretname);
    return out;
  }

  res = omni_map(POOL);
  omni_map_set(res, "envtoken", omni_str(POOL, envtoken));
  omni_map_set(res, "secretname", omni_str(POOL, secretname));
  omni_map_set(res, "envkey", omni_str(POOL, envkey));
  free(envtoken);
  free(secretname);
  free(envkey);
  out.val = res;
  return out;
}

static omni_result subject_placeholder(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const char *slug = 0 < nargs ? omni_strval(args[0]) : "";
  char *ph = vxstn_placeholder(NULL == slug ? "" : slug);
  (void)self;
  out.val = omni_str(POOL, ph);
  free(ph);
  return out;
}

static omni_result subject_descriptor(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  vxstn_val *config = to_station(omni_map_get(vin, "config"));
  vxstn_val *features = to_station(omni_map_get(vin, "feature"));
  vxstn_val *descriptor = vxstn_normalize_descriptor(config, features, NULL);
  (void)self;
  out.val = to_omni(descriptor);
  vxstn_val_free(config);
  vxstn_val_free(features);
  vxstn_val_free(descriptor);
  return out;
}

static omni_result subject_descriptorwarnings(omni_subject *self, omni_json **args,
                                              size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  vxstn_val *config = to_station(omni_map_get(vin, "config"));
  vxstn_val *features = to_station(omni_map_get(vin, "feature"));
  vxstn_val *warnings = NULL;
  vxstn_val *descriptor = vxstn_normalize_descriptor(config, features, &warnings);
  (void)self;
  out.val = omni_num(POOL, (double)warnings->len);
  vxstn_val_free(config);
  vxstn_val_free(features);
  vxstn_val_free(descriptor);
  vxstn_val_free(warnings);
  return out;
}

static omni_result subject_canonical(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  vxstn_val *v = to_station(0 < nargs ? args[0] : NULL);
  char *text = vxstn_canonical(v);
  (void)self;
  out.val = omni_str(POOL, text);
  vxstn_val_free(v);
  free(text);
  return out;
}

static omni_result subject_profile(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  vxstn_val *config = to_station(omni_map_get(vin, "config"));
  const char *profile = omni_strval(omni_map_get(vin, "profile"));
  vxstn_error *err = NULL;
  vxstn_val *resolved =
      vxstn_resolve_profile(config, NULL == profile ? "default" : profile, &err);
  (void)self;
  vxstn_val_free(config);
  if (NULL == resolved) {
    out.err = omni_pool_strdup(POOL, NULL == err ? "profile failed" : err->message);
    vxstn_error_free(err);
    return out;
  }
  out.val = to_omni(resolved);
  vxstn_val_free(resolved);
  return out;
}

static omni_result subject_errors(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const char *code = 0 < nargs ? omni_strval(args[0]) : NULL;
  (void)self;
  out.val = omni_bool(POOL, vxstn_known_code(code) ? 1 : 0);
  return out;
}

static omni_subject *makesubject(omni_result (*call)(omni_subject *, omni_json **, size_t)) {
  omni_subject *subject = (omni_subject *)omni_pool_alloc(POOL, sizeof(omni_subject));
  subject->call = call;
  subject->data = NULL;
  return subject;
}

/* ---- harness (the omni c fib harness pattern) ---------------------- */

static void report(const char *name, int failed, const char *message) {
  if (failed) {
    FAILCOUNT++;
    printf("FAIL - %s\n%s\n", name, NULL == message ? "" : message);
  } else {
    PASSCOUNT++;
    printf("ok   - %s\n", name);
  }
}

static int wanted(const char *name) { return NULL == ONLY || 0 == strcmp(ONLY, name); }

/* Find the shared spec directory by walking up from the working dir. */
static char *specfile(const char *name) {
  static char path[4200];
  char dir[4096];
  int step;

  if (NULL == getcwd(dir, sizeof(dir))) {
    return NULL;
  }

  for (step = 0; step < 8; step++) {
    FILE *probe;
    snprintf(path, sizeof(path), "%s/spec/%s", dir, name);
    probe = fopen(path, "rb");
    if (NULL != probe) {
      fclose(probe);
      return path;
    }

    {
      char *slash = strrchr(dir, '/');
      if (NULL == slash || dir == slash) {
        break;
      }
      *slash = '\0';
    }
  }

  return NULL;
}

static void rungroup(omni_runpack *pack, const char *name, omni_subject *subject) {
  char *err = NULL;
  int failed;

  if (!wanted(name)) {
    return;
  }

  /* nonull: spec nulls arrive as real nulls, which is what the station
   * subjects mean (the ts port denulls by hand; same effect). */
  failed = omni_runsetflags(pack, omni_set(pack, name), omni_flags_nonull(), subject, &err);
  report(name, failed, err);
}

int main(int argc, char **argv) {
  char *path;
  char *err = NULL;
  omni_runner *runner;
  omni_runpack *pack;

  POOL = omni_pool_new();

  if (1 < argc) {
    ONLY = argv[1];
  }

  path = specfile("station.json");
  if (NULL == path) {
    printf("station: spec not found: station.json\n");
    omni_pool_free(POOL);
    return 1;
  }

  runner = omni_make_runner(POOL, path, NULL, NULL, &err);
  if (NULL == runner) {
    printf("%s\n", err);
    omni_pool_free(POOL);
    return 1;
  }

  pack = omni_runner_run(runner, "station", NULL, &err);
  if (NULL == pack) {
    printf("%s\n", err);
    omni_pool_free(POOL);
    return 1;
  }

  rungroup(pack, "secretname", makesubject(subject_secretname));
  rungroup(pack, "placeholder", makesubject(subject_placeholder));
  rungroup(pack, "descriptor", makesubject(subject_descriptor));
  rungroup(pack, "descriptorwarnings", makesubject(subject_descriptorwarnings));
  rungroup(pack, "canonical", makesubject(subject_canonical));
  rungroup(pack, "profile", makesubject(subject_profile));
  rungroup(pack, "errors", makesubject(subject_errors));

  printf("\n%d passed, %d failed\n", PASSCOUNT, FAILCOUNT);

  omni_pool_free(POOL);

  return 0 == FAILCOUNT ? 0 : 1;
}
