/* RUN: make test
 * RUN-SOME: ./build/conform secretname
 *
 * The station conformance suite: the pure-contract half of the design's
 * (station.md 13) corpus, from spec/station.json, through voxgig/omni -
 * the same file every port runs. Sections that need live SDK machinery
 * (inject, event correlation) live in the generated-SDK integration
 * flow; the corpus carries what a port can prove with no SDK present.
 *
 * TEN SECTIONS, ALL RUN. The tests are REGISTERED FROM THE `DRIVERS`
 * TABLE below rather than written out by hand, so a section named there
 * cannot silently fail to run; `sections-covered` closes the other
 * direction by reading spec/station.json AS RAW JSON - not through the
 * runner, which resolves a named section and would hide one it never
 * resolved - and asserting that the sections it carries are exactly
 * DRIVERS. A section added to the corpus and not picked up here fails
 * loudly instead of never running; a section renamed or deleted while
 * this port still lists it fails too.
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

/* The completeness guard reads the spec file itself and sorts its
 * section names; the library's own internal helpers do exactly that and
 * are already linked here. */
#include "../src/voxgig_station_int.h"

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

/* The 3.3 merge, and the whole of this port's profile contract. */
static omni_result subject_instance(omni_subject *self, omni_json **args, size_t nargs) {
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

/* design 4.2's pipeline, and the whole of this port's config contract:
   the entry is a RAW config in, and either the normalized output or the
   expected error out. THE TWO STEPS ARE ONE PIPELINE - a port that
   split them would be free to validate the wrong form, which is the
   exact mistake 4.2 exists to prevent (an all-optional block is an OPEN
   map until normalization makes its keys present). */
static omni_result subject_config(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  vxstn_val *raw = to_station(0 < nargs ? args[0] : NULL);
  vxstn_val *normalized = vxstn_normalize_config(raw);
  vxstn_error *err = NULL;
  vxstn_val *validated = vxstn_validate_config(normalized, &err);
  (void)self;

  vxstn_val_free(raw);
  vxstn_val_free(normalized);
  if (NULL == validated) {
    out.err = omni_pool_strdup(POOL, NULL == err ? "validate failed" : err->message);
    vxstn_error_free(err);
    return out;
  }
  out.val = to_omni(validated);
  vxstn_val_free(validated);
  return out;
}

/* design 6.1's `as` rule: pure over (api, opts), so it is corpus-shaped
   rather than driver-shaped even though it decides a registry key. */
static omni_result subject_instanceref(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  const char *api = omni_strval(omni_map_get(vin, "api"));
  vxstn_val *opts = to_station(omni_map_get(vin, "opts"));
  vxstn_error *err = NULL;
  char *ref = vxstn_instance_ref(NULL == api ? "" : api, opts, &err);
  (void)self;

  vxstn_val_free(opts);
  if (NULL == ref) {
    out.err = omni_pool_strdup(POOL, NULL == err ? "instanceref failed" : err->message);
    vxstn_error_free(err);
    return out;
  }
  out.val = omni_str(POOL, ref);
  free(ref);
  return out;
}

/* design 8's pure half (design 10.1): the three-level merge with its
   depth boundary, and the 8.4 order resolution. ONE DRIVER, TWO ENTRY
   SHAPES - `merged` selects the resolver, anything else the merge -
   because a port that guessed from looser cues would run the wrong
   subject on a mistyped entry. */
static omni_result subject_feature(omni_subject *self, omni_json **args, size_t nargs) {
  omni_result out = {NULL, NULL};
  const omni_json *vin = 0 < nargs ? args[0] : NULL;
  const omni_json *mergedin = omni_map_get(vin, "merged");
  vxstn_error *err = NULL;
  (void)self;

  if (!omni_isnone(mergedin)) {
    vxstn_val *merged = to_station(mergedin);
    vxstn_val *ordered = vxstn_resolve_order(merged, &err);
    omni_json *names;
    size_t i;

    vxstn_val_free(merged);
    if (NULL == ordered) {
      out.err = omni_pool_strdup(POOL, NULL == err ? "order failed" : err->message);
      vxstn_error_free(err);
      return out;
    }
    err = vxstn_check_pin(ordered);
    if (NULL != err) {
      out.err = omni_pool_strdup(POOL, err->message);
      vxstn_error_free(err);
      vxstn_val_free(ordered);
      return out;
    }
    names = omni_list(POOL);
    for (i = 0; i < ordered->len; i++) {
      omni_list_push(names,
                     omni_str(POOL, vxstn_strval(vxstn_map_get(ordered->items[i], "name"))));
    }
    vxstn_val_free(ordered);
    out.val = names;
    return out;
  }

  {
    vxstn_val *base = to_station(omni_map_get(vin, "base"));
    vxstn_val *overlay = to_station(omni_map_get(vin, "overlay"));
    const char *api = omni_strval(omni_map_get(vin, "api"));
    const char *ref = omni_strval(omni_map_get(vin, "ref"));
    vxstn_val *sources = vxstn_feature_sources(base, overlay, api, ref);
    vxstn_val *merged = vxstn_merge_features(sources);

    out.val = to_omni(merged);
    vxstn_val_free(base);
    vxstn_val_free(overlay);
    vxstn_val_free(sources);
    vxstn_val_free(merged);
    return out;
  }
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

/* ---- the driver table: what runs -----------------------------------
 *
 * DRIVERS is the opt-in surface: a section runs if and only if it has a
 * row here, and the runs below are generated from it. `sections-covered`
 * then asserts it is exactly what the corpus carries, so a section
 * quietly dropped from DRIVERS to make a red test go away fails loudly
 * instead of going unnoticed.
 *
 * C has no dynamic test registry, so the table is a static array
 * iterated by main() - the same two properties the dynamic ports get
 * from generating their tests. */

typedef struct {
  const char *name;
  omni_result (*call)(omni_subject *, omni_json **, size_t);
} driver_row;

static const driver_row DRIVERS[] = {
    {"secretname", subject_secretname},
    {"placeholder", subject_placeholder},
    {"descriptor", subject_descriptor},
    {"descriptorwarnings", subject_descriptorwarnings},
    {"canonical", subject_canonical},
    {"config", subject_config},
    {"instance", subject_instance},
    {"instanceref", subject_instanceref},
    {"feature", subject_feature},
    {"errors", subject_errors},
};

#define DRIVER_COUNT (sizeof(DRIVERS) / sizeof(DRIVERS[0]))

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
  omni_json *set;

  if (!wanted(name)) {
    return;
  }

  /* The corpus must actually carry a set of this name - a renamed
   * section quietly matching nothing is the failure mode a table-driven
   * suite would otherwise hide. */
  set = omni_set(pack, name);
  if (NULL == set) {
    report(name, 1, "corpus section missing");
    return;
  }

  /* nonull: spec nulls arrive as real nulls, which is what the station
   * subjects mean (the ts port denulls by hand; same effect). */
  failed = omni_runsetflags(pack, set, omni_flags_nonull(), subject, &err);
  report(name, failed, err);
}

/* Section completeness (design 13). Reads spec/station.json AS RAW
   JSON - not through the runner, which resolves and normalizes a named
   section and would hide one it never resolved - and asserts that the
   section names it carries are EXACTLY the DRIVERS rows. Not a subset
   either way: a section added to the corpus and not picked up here
   fails loudly instead of never running, and a stale driver fails
   rather than rotting. */
static int cmp_names(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static void sections_covered(const char *specpath) {
  FILE *f = fopen(specpath, "rb");
  char *text;
  long size;
  vxstn_val *spec;
  const vxstn_val *sections;
  const char **present;
  const char **covered;
  size_t npresent, ncovered = DRIVER_COUNT;
  size_t i;
  vxstn_sb msg;
  int failed = 0;

  if (!wanted("sections-covered")) {
    return;
  }
  if (NULL == f) {
    report("sections-covered", 1, "cannot read spec/station.json");
    return;
  }
  fseek(f, 0, SEEK_END);
  size = ftell(f);
  fseek(f, 0, SEEK_SET);
  text = (char *)malloc((size_t)size + 1);
  if (1 != fread(text, (size_t)size, 1, f)) {
    fclose(f);
    free(text);
    report("sections-covered", 1, "cannot read spec/station.json");
    return;
  }
  text[size] = '\0';
  fclose(f);

  spec = vxstn_parse_json(text, NULL);
  free(text);
  if (NULL == spec) {
    report("sections-covered", 1, "cannot parse spec/station.json");
    return;
  }

  sections = vxstn_map_get(vxstn_map_get(spec, "primary"), "station");
  present = vxstn_sortedkeys(sections, &npresent);

  covered = (const char **)malloc(ncovered * sizeof(char *));
  for (i = 0; i < DRIVER_COUNT; i++) {
    covered[i] = DRIVERS[i].name;
  }
  qsort(covered, ncovered, sizeof(char *), cmp_names);

  vxstn_sb_init(&msg);
  if (npresent != ncovered) {
    failed = 1;
  } else {
    for (i = 0; i < npresent; i++) {
      if (0 != strcmp(present[i], covered[i])) {
        failed = 1;
        break;
      }
    }
  }
  if (failed) {
    vxstn_sb_put(&msg, "  corpus:  ");
    for (i = 0; i < npresent; i++) {
      vxstn_sb_put(&msg, 0 == i ? "" : ", ");
      vxstn_sb_put(&msg, present[i]);
    }
    vxstn_sb_put(&msg, "\n  covered: ");
    for (i = 0; i < ncovered; i++) {
      vxstn_sb_put(&msg, 0 == i ? "" : ", ");
      vxstn_sb_put(&msg, covered[i]);
    }
  }
  report("sections-covered", failed, msg.buf);

  free(msg.buf);
  free(present);
  free((void *)covered);
  vxstn_val_free(spec);
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

  sections_covered(path);

  /* REGISTERED FROM THE TABLE, never written out by hand: a section
     named in DRIVERS cannot silently fail to execute. */
  {
    size_t i;
    for (i = 0; i < DRIVER_COUNT; i++) {
      rungroup(pack, DRIVERS[i].name, makesubject(DRIVERS[i].call));
    }
  }

  printf("\n%d passed, %d failed\n", PASSCOUNT, FAILCOUNT);

  omni_pool_free(POOL);

  return 0 == FAILCOUNT ? 0 : 1;
}
