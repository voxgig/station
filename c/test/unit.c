/* RUN: make test
 *
 * Focused unit tests for the station C library - the SDK-independent
 * behaviors the conformance corpus does not reach: the event ring,
 * the env-only broker (hoist, scrub, refresh, miss), the ambient
 * instance, registration and its guards, the wrap-order check with the
 * generated make_feature's base-feature strays, host policy, and the
 * secret-name precedence chain. Zero test framework, the house style:
 * a failing check prints and the process exits non-zero.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../src/voxgig_station.h"

/* The tests build a few strings and copy a few of their own; the
 * library's internal helpers are already linked here. */
#include "../src/voxgig_station_int.h"

static int FAILS = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    if (!(cond)) {                                                         \
      FAILS++;                                                             \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);               \
    }                                                                      \
  } while (0)

#define CHECK_STR(got, want)                                               \
  do {                                                                     \
    const char* g_ = (got);                                                \
    const char* w_ = (want);                                               \
    if (NULL == g_ || 0 != strcmp(g_, w_)) {                               \
      FAILS++;                                                             \
      printf("FAIL %s:%d: got \"%s\" want \"%s\"\n", __FILE__, __LINE__,   \
             NULL == g_ ? "(null)" : g_, w_);                              \
    }                                                                      \
  } while (0)

static void test_identity(void) {
  char* t;
  vxstn_error* err = NULL;

  t = vxstn_envtoken("gnarly-pets");
  CHECK_STR(t, "GNARLY_PETS");
  free(t);
  t = vxstn_envtoken("Weird--Name..2");
  CHECK_STR(t, "WEIRD_NAME_2");
  free(t);
  t = vxstn_envtoken("-lead-trail-");
  CHECK_STR(t, "LEAD_TRAIL");
  free(t);
  t = vxstn_envtoken("");
  CHECK_STR(t, "");
  free(t);

  t = vxstn_secretname_default("voxgig-solardemo");
  CHECK_STR(t, "voxgig_solardemo.apikey");
  free(t);

  CHECK(vxstn_validname("api.token"));
  CHECK(vxstn_validname("db.pass.main"));
  CHECK(!vxstn_validname("Not A Name"));
  CHECK(!vxstn_validname(""));
  CHECK(!vxstn_validname(".lead"));
  CHECK(!vxstn_validname("trail."));
  CHECK(!vxstn_validname("UPPER.case"));

  t = vxstn_envkey("gnarly_pets.apikey", &err);
  CHECK_STR(t, "GNARLY_PETS_APIKEY");
  CHECK(NULL == err);
  free(t);

  t = vxstn_envkey("Not A Name", &err);
  CHECK(NULL == t);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_error"));
  vxstn_error_free(err);

  t = vxstn_placeholder("solardemo");
  CHECK_STR(t, "[station:solardemo]");
  free(t);
}

static void test_canonical(void) {
  vxstn_val* m = vxstn_map();
  vxstn_val* inner = vxstn_map();
  char* out;

  /* Insertion order b,a - canonical sorts bytewise. */
  vxstn_map_set(m, "b", vxstn_int(1));
  vxstn_map_set(m, "a", vxstn_int(2));
  vxstn_map_set(inner, "y", vxstn_bool(true));
  vxstn_map_set(inner, "x", vxstn_null());
  vxstn_map_set(m, "n", inner);
  out = vxstn_canonical(m);
  CHECK_STR(out, "{\"a\":2,\"b\":1,\"n\":{\"x\":null,\"y\":true}}");
  free(out);
  vxstn_val_free(m);

  /* An undef map value means absent: the key is skipped. */
  m = vxstn_map();
  vxstn_map_set(m, "keep", vxstn_int(1));
  vxstn_map_set(m, "skip", vxstn_undef());
  out = vxstn_canonical(m);
  CHECK_STR(out, "{\"keep\":1}");
  free(out);
  vxstn_val_free(m);

  /* Large exact integer, string escaping, non-ASCII bytes verbatim. */
  m = vxstn_map();
  vxstn_map_set(m, "n", vxstn_int(9007199254740991LL));
  vxstn_map_set(m, "s", vxstn_str("q\"\\\n\x01é"));
  out = vxstn_canonical(m);
  CHECK_STR(out, "{\"n\":9007199254740991,\"s\":\"q\\\"\\\\\\n\\u0001é\"}");
  free(out);
  vxstn_val_free(m);
}

static void test_parse_json(void) {
  char* err = NULL;
  vxstn_val* v = vxstn_parse_json(
      "{\"a\":[1,2.5,null,true,\"x\\u00e9\"],\"b\":{}}", &err);
  char* out;
  CHECK(NULL == err);
  CHECK(vxstn_is_map(v));
  out = vxstn_canonical(v);
  CHECK_STR(out, "{\"a\":[1,2.5,null,true,\"xé\"],\"b\":{}}");
  free(out);
  vxstn_val_free(v);

  v = vxstn_parse_json("{\"a\":1,}", &err);
  CHECK(NULL == v);
  CHECK(NULL != err);
  free(err);
  err = NULL;

  v = vxstn_parse_json("[1] trailing", &err);
  CHECK(NULL == v);
  CHECK(NULL != err);
  free(err);
}

static void test_events_ring(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_val* events;
  vxstn_val* status;
  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off"; /* no open-warning noise in the ring */
  opts.event_max = 3;
  st = vxstn_station_new(&opts, NULL);
  CHECK(NULL != st);

  vxstn_emit_warn(st, NULL, "w1");
  vxstn_emit_warn(st, NULL, "w2");
  vxstn_emit_warn(st, NULL, "w3");
  vxstn_emit_warn(st, NULL, "w4"); /* drops w1 */

  events = vxstn_events(st);
  CHECK(3 == events->len);
  CHECK_STR(vxstn_strval(vxstn_map_get(vxstn_map_get(events->items[0], "meta"), "warn")),
            "w2");
  vxstn_val_free(events);

  status = vxstn_status(st);
  CHECK(vxstn_map_get(vxstn_map_get(status, "events"), "dropped")->i == 1);
  CHECK_STR(vxstn_strval(vxstn_map_get(status, "secrets")), "env-only");
  CHECK_STR(vxstn_strval(vxstn_map_get(status, "mode")), "solo");
  vxstn_val_free(status);

  vxstn_station_free(st);
}

static void tap_count(void* ud, const vxstn_val* ev) {
  (void)ev;
  (*(int*)ud)++;
}

static void test_taps(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  int count = 0;
  int id;
  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  st = vxstn_station_new(&opts, NULL);

  id = vxstn_tap(st, tap_count, &count);
  vxstn_emit_warn(st, NULL, "one");
  vxstn_emit_warn(st, NULL, "two");
  CHECK(2 == count);
  vxstn_untap(st, id);
  vxstn_emit_warn(st, NULL, "three");
  CHECK(2 == count);

  vxstn_station_free(st);
}

static const char* TASKPAD_CONFIG =
    "{\"main\":{\"name\":\"Taskpad\",\"slug\":\"taskpad\","
    "\"version\":\"0.0.1\",\"target\":\"c\"},"
    "\"feature\":{\"test\":{}},"
    "\"options\":{\"base\":\"http://localhost:8902\","
    "\"auth\":{\"prefix\":\"\"},\"entity\":{\"todo\":{}}},"
    "\"entity\":{\"todo\":{\"fields\":[{\"name\":\"title\",\"kind\":\"String\"}],"
    "\"op\":{\"list\":{\"points\":[{\"method\":\"GET\",\"orig\":\"/api/todo\","
    "\"parts\":[\"api\",\"todo\"]}]}}}}}";

static void test_register(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_binding* binding;
  vxstn_error* err = NULL;
  int client_a = 0;
  int client_b = 0;
  vxstn_val* events;
  bool saw_construct = false;
  size_t i;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  st = vxstn_station_new(&opts, NULL);

  binding = vxstn_register(st, &client_a, TASKPAD_CONFIG, NULL, NULL, &err);
  CHECK(NULL != binding);
  CHECK(NULL == err);
  CHECK_STR(binding->plugin, "taskpad");
  CHECK_STR(binding->placeholder, "[station:taskpad]");
  CHECK_STR(binding->secretname, "taskpad.apikey");
  CHECK_STR(binding->rung, "R1");
  CHECK(vxstn_bound(st, &client_a));
  CHECK(!vxstn_bound(st, &client_b));
  CHECK_STR(vxstn_rung(st, "taskpad"), "R1");
  vxstn_binding_free(binding);

  /* A second CLIENT of the same SDK slug fails the register slug check. */
  binding = vxstn_register(st, &client_b, TASKPAD_CONFIG, NULL, NULL, &err);
  CHECK(NULL == binding);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_bound_twice"));
  vxstn_error_free(err);
  err = NULL;

  events = vxstn_events(st);
  for (i = 0; i < events->len; i++) {
    if (0 == strcmp("construct",
                    vxstn_strval(vxstn_map_get(events->items[i], "kind")))) {
      saw_construct = true;
      CHECK_STR(vxstn_strval(vxstn_map_get(events->items[i], "plugin")), "taskpad");
    }
  }
  CHECK(saw_construct);
  vxstn_val_free(events);

  /* descriptor_of and its unknown-plugin candidates list. */
  {
    vxstn_val* d = vxstn_descriptor_of(st, "taskpad", &err);
    CHECK(NULL != d && NULL == err);
    CHECK_STR(vxstn_strval(vxstn_map_get(d, "envtoken")), "TASKPAD");
    vxstn_val_free(d);
    d = vxstn_descriptor_of(st, "nope", &err);
    CHECK(NULL == d);
    CHECK(NULL != err && 0 == strcmp(err->code, "station_no_plugin"));
    CHECK(NULL != strstr(err->message, "taskpad"));
    vxstn_error_free(err);
    err = NULL;
  }

  vxstn_station_free(st);
}

static void test_secret_broker(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_binding* binding;
  vxstn_error* err = NULL;
  const char* value;
  char* red;
  int client = 0;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";

  /* Miss: unset variable is station_secret_no_value (design 5.2). */
  unsetenv("TASKPAD_APIKEY");
  st = vxstn_station_new(&opts, NULL);
  binding = vxstn_register(st, &client, TASKPAD_CONFIG, NULL, NULL, &err);
  CHECK(NULL != binding);
  vxstn_binding_free(binding);
  value = vxstn_secret_value(st, "taskpad", &err);
  CHECK(NULL == value);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_no_value"));
  vxstn_error_free(err);
  err = NULL;

  /* Hit through the environment, under envkey(secretname). */
  setenv("TASKPAD_APIKEY", "k1", 1);
  value = vxstn_secret_value(st, "taskpad", &err);
  CHECK_STR(value, "k1");
  CHECK(NULL == err);

  /* Cached: a changed variable is not seen until refresh. */
  setenv("TASKPAD_APIKEY", "k2", 1);
  value = vxstn_secret_value(st, "taskpad", &err);
  CHECK_STR(value, "k1");
  vxstn_refresh_secrets(st);
  value = vxstn_secret_value(st, "taskpad", &err);
  CHECK_STR(value, "k2");

  /* Exact-value scrub, no 4-char floor: both held values go. */
  red = vxstn_redact(st, "a k1 and k2 leaked");
  CHECK_STR(red, "a [redacted] and [redacted] leaked");
  free(red);

  /* Hoist wins over the environment and is scrubbed too. */
  vxstn_hoist(st, "taskpad", "resident-key");
  value = vxstn_secret_value(st, "taskpad", &err);
  CHECK_STR(value, "resident-key");
  red = vxstn_redact(st, "saw resident-key here");
  CHECK_STR(red, "saw [redacted] here");
  free(red);

  unsetenv("TASKPAD_APIKEY");
  vxstn_station_free(st);
}

static void test_secret_precedence(void) {
  /* fopt secret > profile secret > descriptor default. */
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_binding* binding;
  int client = 0;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json =
      "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":"
      "{\"taskpad\":{\"secret\":\"custom.name\"}}}}}";

  st = vxstn_station_new(&opts, NULL);
  binding = vxstn_register(st, &client, TASKPAD_CONFIG, NULL, NULL, NULL);
  CHECK(NULL != binding);
  CHECK_STR(binding->secretname, "custom.name");
  vxstn_binding_free(binding);
  vxstn_station_free(st);

  st = vxstn_station_new(&opts, NULL);
  binding = vxstn_register(st, &client, TASKPAD_CONFIG, NULL, "opt.wins", NULL);
  CHECK(NULL != binding);
  CHECK_STR(binding->secretname, "opt.wins");
  vxstn_binding_free(binding);
  vxstn_station_free(st);
}

static void test_host_policy(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  bool has_policy = false;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json =
      "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":"
      "{\"taskpad\":{\"policy\":{\"hosts\":[\"api.good.example\"]}}}}}}";
  st = vxstn_station_new(&opts, NULL);

  CHECK(vxstn_host_allowed(st, "taskpad", "https://api.good.example/x", &has_policy));
  CHECK(has_policy);
  CHECK(!vxstn_host_allowed(st, "taskpad", "https://api.evil.example/x", &has_policy));
  /* Non-default port: hostname (not host:port) is what the list names. */
  CHECK(vxstn_host_allowed(st, "taskpad", "http://api.good.example:8080/x", &has_policy));
  /* No policy for an unknown slug. */
  CHECK(vxstn_host_allowed(st, "other", "https://api.evil.example/x", &has_policy));
  CHECK(!has_policy);

  vxstn_station_free(st);
}

static void test_wrap_order(void) {
  vxstn_error* err;
  {
    const char* names[] = {"test", "station", "retry"};
    err = vxstn_wrap_order_check(names, 3);
    CHECK(NULL == err);
  }
  {
    const char* names[] = {"station"};
    err = vxstn_wrap_order_check(names, 1);
    CHECK(NULL == err);
  }
  {
    /* base strays (the generated make_feature fallback) are excluded. */
    const char* names[] = {"base", "test", "base", "station"};
    err = vxstn_wrap_order_check(names, 4);
    CHECK(NULL == err);
  }
  {
    const char* names[] = {"test", "retry", "station"};
    err = vxstn_wrap_order_check(names, 3);
    CHECK(NULL != err && 0 == strcmp(err->code, "station_wrap_order"));
    CHECK(NULL != strstr(err->message, "test, retry, station"));
    vxstn_error_free(err);
  }
  {
    /* Missing entirely also trips. */
    const char* names[] = {"test", "retry"};
    err = vxstn_wrap_order_check(names, 2);
    CHECK(NULL != err && 0 == strcmp(err->code, "station_wrap_order"));
    vxstn_error_free(err);
  }
}

static void test_ambient(void) {
  vxstn_error* err = NULL;
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_station* again;

  vxstn_reset();
  CHECK(NULL == vxstn_current());

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  st = vxstn_open(&opts, &err);
  CHECK(NULL != st && NULL == err);
  CHECK(st == vxstn_current());

  again = vxstn_open(&opts, &err);
  CHECK(again == st && NULL == err);

  opts.profile = "prod";
  again = vxstn_open(&opts, &err);
  CHECK(NULL == again);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_open_conflict"));
  vxstn_error_free(err);
  err = NULL;

  vxstn_close(st);
  CHECK(NULL == vxstn_current());
  vxstn_station_free(st);
}

static void test_close_warns(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_val* events;
  bool warned = false;
  size_t i;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json =
      "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":"
      "{\"typod\":{\"base\":\"http://x\"}}}}}";
  st = vxstn_station_new(&opts, NULL);
  vxstn_close(st);
  events = vxstn_events(st);
  for (i = 0; i < events->len; i++) {
    const char* warn = vxstn_strval(
        vxstn_map_get(vxstn_map_get(events->items[i], "meta"), "warn"));
    if (NULL != strstr(warn, "typod")) {
      warned = true;
    }
  }
  CHECK(warned);
  vxstn_val_free(events);
  vxstn_station_free(st);
}

static void test_outcome(void) {
  CHECK_STR(vxstn_outcome(false, false, false), "unknown");
  CHECK_STR(vxstn_outcome(true, true, true), "err");
  CHECK_STR(vxstn_outcome(true, false, false), "err");
  CHECK_STR(vxstn_outcome(true, false, true), "ok");
}

static void test_emit_http(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_val* events;
  const vxstn_val* http;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  st = vxstn_station_new(&opts, NULL);

  vxstn_emit_http(st, "taskpad", "c1", "GET", "http://localhost:8902/api/todo?x=1",
                  200, vxstn_now_ms(), 42);
  events = vxstn_events(st);
  CHECK(1 == events->len);
  http = vxstn_map_get(events->items[0], "http");
  CHECK_STR(vxstn_strval(vxstn_map_get(http, "host")), "localhost:8902");
  CHECK_STR(vxstn_strval(vxstn_map_get(http, "path")), "/api/todo");
  CHECK(200 == vxstn_map_get(http, "status")->i);
  CHECK(42 == vxstn_map_get(http, "bytes")->i);
  CHECK_STR(vxstn_strval(vxstn_map_get(events->items[0], "corr")), "c1");
  vxstn_val_free(events);
  vxstn_station_free(st);
}

/* ---- Stage 5: the config shape, the mirror, and its invariants ---- */

/* The mirror is only honest if something compares it to the spec. Walk
   up from the working directory for spec/, the way the conformance
   suite finds station.json. */
static char* specpath(const char* name) {
  static char path[4200];
  char dir[4096];
  int step;

  if (NULL == getcwd(dir, sizeof(dir))) {
    return NULL;
  }
  for (step = 0; step < 8; step++) {
    FILE* probe;
    snprintf(path, sizeof(path), "%s/spec/%s", dir, name);
    probe = fopen(path, "rb");
    if (NULL != probe) {
      fclose(probe);
      return path;
    }
    {
      char* slash = strrchr(dir, '/');
      if (NULL == slash || dir == slash) {
        break;
      }
      *slash = '\0';
    }
  }
  return NULL;
}

static void test_shape_mirror(void) {
  char* path = specpath("config-shape.json");
  FILE* f;
  long size;
  char* text;
  vxstn_val* shape;
  const vxstn_val* profile;
  const vxstn_val* apiblock;
  const vxstn_val* sdkblock;
  char* a;
  char* b;

  /* THE DRIFT GUARD: src/config_shape.h is a verbatim mirror of
     spec/config-shape.json, so the check is a byte compare. Regenerate
     with `make sync-shape` when the spec moves. */
  CHECK(NULL != path);
  if (NULL == path) {
    return;
  }
  f = fopen(path, "rb");
  CHECK(NULL != f);
  if (NULL == f) {
    return;
  }
  fseek(f, 0, SEEK_END);
  size = ftell(f);
  fseek(f, 0, SEEK_SET);
  text = (char*)malloc((size_t)size + 1);
  CHECK(1 == fread(text, (size_t)size, 1, f));
  text[size] = '\0';
  fclose(f);
  CHECK_STR(vxstn_config_shape_json(), text);
  free(text);

  /* A FRESH DEEP COPY every call: struct's validate consumes the spec
     it walks, so two calls must not hand back one tree. */
  {
    vxstn_val* one = vxstn_config_shape();
    vxstn_val* two = vxstn_config_shape();
    CHECK(one != two);
    a = vxstn_canonical(one);
    b = vxstn_canonical(two);
    CHECK_STR(a, b);
    free(a);
    free(b);
    vxstn_val_free(one);
    vxstn_val_free(two);
  }

  shape = vxstn_config_shape();
  profile = vxstn_map_get(vxstn_map_get(shape, "profiles"), "`$CHILD`");

  /* The two block specs are IDENTICAL: an api block and an sdk block
     take the same keys, and a difference between them would be a
     grammar that means one thing at one level and another at the
     other. */
  apiblock = vxstn_map_get(vxstn_map_get(profile, "api"), "`$CHILD`");
  sdkblock = vxstn_map_get(vxstn_map_get(profile, "sdk"), "`$CHILD`");
  a = vxstn_canonical(apiblock);
  b = vxstn_canonical(sdkblock);
  CHECK_STR(a, b);
  free(a);
  free(b);
  vxstn_val_free(shape);

  /* MERGE_SENSITIVE is exactly {"active"}, it is a block default, and
     every non-container block default is in it - the timing rule stated
     as an assertion rather than left to a reader to infer. */
  {
    vxstn_val* defaults = vxstn_block_defaults();
    size_t i;
    CHECK_STR(VXSTN_MERGE_SENSITIVE[0], "active");
    CHECK(NULL == VXSTN_MERGE_SENSITIVE[1]);
    CHECK(NULL != vxstn_map_get(defaults, "active"));
    for (i = 0; i < defaults->mlen; i++) {
      bool container = VXSTN_MAP == defaults->vals[i]->kind ||
                       VXSTN_LIST == defaults->vals[i]->kind;
      bool sensitive = 0 == strcmp("active", defaults->keys[i]);
      CHECK(container || sensitive);
    }
    vxstn_val_free(defaults);
  }
}

static void test_normalize_config(void) {
  const char* rawtext =
      "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
      "{\"feature\":{\"retry\":{\"retries\":3}}}}}}}";
  vxstn_val* raw = vxstn_parse_json(rawtext, NULL);
  char* before = vxstn_canonical(raw);
  vxstn_val* out = vxstn_normalize_config(raw);
  char* after = vxstn_canonical(raw);
  const vxstn_val* prof;
  const vxstn_val* block;

  /* NEVER MUTATES THE INPUT. */
  CHECK_STR(before, after);
  free(before);
  free(after);

  prof = vxstn_map_get(vxstn_map_get(out, "profiles"), "default");
  CHECK(NULL != vxstn_map_get(prof, "api"));
  CHECK(NULL != vxstn_map_get(prof, "feature"));
  CHECK_STR(vxstn_strval(vxstn_map_get(
                vxstn_list_get(vxstn_map_get(vxstn_map_get(prof, "secrets"),
                                             "providers"),
                               0),
                "kind")),
            "env");

  block = vxstn_map_get(vxstn_map_get(prof, "sdk"), "solar");
  CHECK(vxstn_map_get(block, "active")->b);
  /* A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. */
  CHECK(vxstn_map_get(vxstn_map_get(vxstn_map_get(block, "feature"), "retry"),
                      "active")
            ->b);
  vxstn_val_free(out);
  vxstn_val_free(raw);

  /* A non-map is returned untouched, for validation to reject by
     path. */
  raw = vxstn_parse_json("[1]", NULL);
  out = vxstn_normalize_config(raw);
  CHECK(vxstn_is_list(out));
  vxstn_val_free(out);
  vxstn_val_free(raw);
}

static vxstn_error* validate_text(const char* text) {
  vxstn_val* raw = vxstn_parse_json(text, NULL);
  vxstn_val* normalized = vxstn_normalize_config(raw);
  vxstn_error* err = NULL;
  vxstn_val* out = vxstn_validate_config(normalized, &err);
  vxstn_val_free(out);
  vxstn_val_free(normalized);
  vxstn_val_free(raw);
  return err;
}

static void test_validate_config(void) {
  vxstn_error* err;

  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"sdk\":"
                      "{\"solar\":{}}}}}");
  CHECK(NULL == err);
  vxstn_error_free(err);

  /* EVERY ERROR AT ONCE, in encounter order. */
  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"sdk\":"
                      "{\"a\":{\"bass\":1},\"b\":{\"tuba\":2}}}}}");
  CHECK(NULL != err);
  if (NULL != err) {
    CHECK_STR(err->code, "station_config_invalid");
    CHECK(NULL != strstr(err->message, "sdk.a: bass"));
    CHECK(NULL != strstr(err->message, "sdk.b: tuba"));
  }
  vxstn_error_free(err);

  /* The `plugin` -> `sdk` rename hint, on the error that rejects it. */
  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"plugin\":{}}}}");
  CHECK(NULL != err && NULL != strstr(err->message, "rename `plugin` to `sdk`"));
  vxstn_error_free(err);

  /* station is reserved at every feature level. */
  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"feature\":"
                      "{\"station\":{}}}}}");
  CHECK(NULL != err && 0 == strcmp(err->code, "station_feature_reserved"));
  vxstn_error_free(err);

  /* A credential-shaped key inside `options`, one level down. */
  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
                      "{\"options\":{\"deep\":{\"apikey\":\"v\"}}}}}}}");
  CHECK(NULL != err && 0 == strcmp(err->code, "station_config_secret"));
  CHECK(NULL != strstr(err->message, "options.deep.apikey"));
  vxstn_error_free(err);

  /* A `secret` holding a NAME is exempt; one holding a token is not. */
  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
                      "{\"secret\":\"acme_internal_billing_service.apikey\"}}}}}");
  CHECK(NULL == err);
  vxstn_error_free(err);

  err = validate_text("{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
                      "{\"secret\":\"550e8400e29b41d4a716446655440000\"}}}}}");
  CHECK(NULL != err && 0 == strcmp(err->code, "station_config_secret"));
  CHECK(NULL != strstr(err->message, "unbroken alphanumeric run of 24"));
  vxstn_error_free(err);
}

/* ---- Stage 5: feature merge, order, composition, the 8.5 check ---- */

static void test_feature_merge(void) {
  const char* basetext =
      "{\"feature\":{\"retry\":{\"max\":1,\"wait\":100}},"
      "\"api\":{\"solar\":{\"feature\":{\"retry\":{\"max\":2}}}},"
      "\"sdk\":{\"solar$eu\":{\"feature\":{\"audit\":{\"sink\":{\"kind\":\"file\","
      "\"path\":\"/tmp/a\"}}}}}}";
  const char* overtext =
      "{\"feature\":{\"audit\":{\"sink\":{\"kind\":\"stdout\"}}}}";
  vxstn_val* base = vxstn_parse_json(basetext, NULL);
  vxstn_val* overlay = vxstn_parse_json(overtext, NULL);
  vxstn_val* sources = vxstn_feature_sources(base, overlay, "solar", "solar$eu");
  vxstn_val* merged = vxstn_merge_features(sources);
  char* json;

  /* Six sources, always, so the provenance labels line up. */
  CHECK(6 == sources->len);

  json = vxstn_canonical(merged);
  /* Per key within a feature (max from the api block, wait from the
     profile level), and a map-valued option REPLACES wholesale - the
     depth boundary. */
  CHECK_STR(json, "{\"audit\":{\"sink\":{\"kind\":\"stdout\"}},"
                  "\"retry\":{\"max\":2,\"wait\":100}}");
  free(json);
  vxstn_val_free(merged);
  vxstn_val_free(sources);
  vxstn_val_free(base);
  vxstn_val_free(overlay);
}

static char* ordernames(const char* mergedtext, vxstn_error** err) {
  vxstn_val* merged = vxstn_parse_json(mergedtext, NULL);
  vxstn_val* ordered = vxstn_resolve_order(merged, err);
  vxstn_sb sb;
  size_t i;

  vxstn_val_free(merged);
  if (NULL == ordered) {
    return NULL;
  }
  if (NULL != err) {
    vxstn_error* pin = vxstn_check_pin(ordered);
    if (NULL != pin) {
      *err = pin;
      vxstn_val_free(ordered);
      return NULL;
    }
  }
  vxstn_sb_init(&sb);
  for (i = 0; i < ordered->len; i++) {
    vxstn_sb_put(&sb, 0 == i ? "" : ",");
    vxstn_sb_put(&sb, vxstn_strval(vxstn_map_get(ordered->items[i], "name")));
  }
  vxstn_val_free(ordered);
  return sb.buf;
}

static void test_feature_order(void) {
  vxstn_error* err = NULL;
  char* names;

  /* Bands: lower is outermost, and the default bands are today's
     nesting expressed in the new model. */
  names = ordernames("{\"debug\":{},\"station\":{},\"test\":{}}", &err);
  CHECK_STR(names, "debug,station,test");
  free(names);

  /* Constraints beat bands. */
  names = ordernames("{\"x\":{\"order\":{\"band\":10}},"
                     "\"y\":{\"order\":{\"after\":\"x\",\"band\":1}}}",
                     &err);
  CHECK_STR(names, "x,y");
  free(names);

  /* A constraint naming an ABSENT feature is satisfied vacuously. */
  names = ordernames("{\"a\":{\"order\":{\"after\":\"ghost\"}},\"b\":{}}", &err);
  CHECK_STR(names, "a,b");
  free(names);

  /* Inactive entries are excluded, not ordered. */
  names = ordernames("{\"a\":{},\"b\":{\"active\":false}}", &err);
  CHECK_STR(names, "a");
  free(names);

  /* A cycle is an error naming the sorted stuck set. */
  err = NULL;
  names = ordernames("{\"a\":{\"order\":{\"after\":\"b\"}},"
                     "\"b\":{\"order\":{\"after\":\"a\"}}}",
                     &err);
  CHECK(NULL == names);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_feature_order"));
  CHECK(NULL != err && NULL != strstr(err->message, "form a cycle among [a, b]"));
  vxstn_error_free(err);

  /* THE PIN IS INNERMOST: immediately outside the base transport. */
  err = NULL;
  names = ordernames("{\"station\":{\"order\":{\"band\":0}},\"test\":{},"
                     "\"wrap\":{\"order\":{\"band\":150}}}",
                     &err);
  CHECK(NULL == names);
  CHECK(NULL != err && NULL != strstr(err->message, "pinned innermost"));
  vxstn_error_free(err);

  /* ...and last when there is no base transport. */
  err = NULL;
  names = ordernames("{\"retry\":{},\"station\":{}}", &err);
  CHECK_STR(names, "retry,station");
  free(names);
}

static void test_compose_and_check(void) {
  vxstn_val* merged = vxstn_parse_json(
      "{\"retry\":{\"active\":true,\"max\":2,\"order\":{\"band\":5}}}", NULL);
  vxstn_val* ordered = vxstn_resolve_order(merged, NULL);
  vxstn_val* composed = vxstn_compose_features(ordered);
  vxstn_val* config = vxstn_parse_json(
      "{\"main\":{\"name\":\"Solar\",\"slug\":\"solar\",\"version\":\"1\","
      "\"target\":\"c\"},\"feature\":{\"retry\":{\"options\":{\"max\":3},"
      "\"transport\":\"base\"}}}",
      NULL);
  vxstn_val* descriptor = vxstn_normalize_descriptor(config, NULL, NULL);
  vxstn_val* faults;
  char* json;

  /* The ARRAY FORM the constructor takes, with the reserved keys
     dropped: they are not options. */
  json = vxstn_canonical(composed);
  CHECK_STR(json, "[{\"active\":true,\"max\":2,\"name\":\"retry\"}]");
  free(json);

  /* design 7.4: the descriptor now carries the feature's declared
     options and its transport role. ADDITIVE - the `descriptor` corpus
     fixtures carry neither and are unaffected. */
  {
    const vxstn_val* row = vxstn_list_get(vxstn_map_get(descriptor, "features"), 0);
    CHECK_STR(vxstn_strval(vxstn_map_get(row, "transport")), "base");
    CHECK(3 == vxstn_map_get(vxstn_map_get(row, "options"), "max")->i);
  }

  /* Known option, right kind: no fault. */
  faults = vxstn_check_features(merged, descriptor);
  CHECK(0 == faults->len);
  vxstn_val_free(faults);

  /* THE CASE THAT ACTUALLY BITES: a typo'd option name. */
  {
    vxstn_val* typo = vxstn_parse_json("{\"retry\":{\"retires\":5}}", NULL);
    faults = vxstn_check_features(typo, descriptor);
    CHECK(1 == faults->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(faults->items[0], "code")),
              "station_feature_option");
    CHECK(NULL != strstr(vxstn_strval(vxstn_map_get(faults->items[0], "message")),
                         "declares no option \"retires\""));
    vxstn_val_free(faults);
    vxstn_val_free(typo);
  }

  /* A kind mismatch on a declared option. */
  {
    vxstn_val* wrong = vxstn_parse_json("{\"retry\":{\"max\":\"two\"}}", NULL);
    faults = vxstn_check_features(wrong, descriptor);
    CHECK(1 == faults->len);
    CHECK(NULL != strstr(vxstn_strval(vxstn_map_get(faults->items[0], "message")),
                         "expects number, but found string"));
    vxstn_val_free(faults);
    vxstn_val_free(wrong);
  }

  /* A feature the SDK does not declare at all. */
  {
    vxstn_val* unknown = vxstn_parse_json("{\"nope\":{}}", NULL);
    faults = vxstn_check_features(unknown, descriptor);
    CHECK(1 == faults->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(faults->items[0], "code")),
              "station_feature_unknown");
    vxstn_val_free(faults);
    vxstn_val_free(unknown);
  }

  vxstn_val_free(descriptor);
  vxstn_val_free(config);
  vxstn_val_free(composed);
  vxstn_val_free(ordered);
  vxstn_val_free(merged);
}

/* ---- Stage 5: the factory table and the package validator ---- */

static const char* SOLAR_CONFIG =
    "{\"main\":{\"name\":\"Solar\",\"slug\":\"solar\",\"version\":\"1.0.0\","
    "\"target\":\"c\"},"
    "\"feature\":{\"retry\":{\"options\":{\"max\":3}},\"log\":{\"options\":{}},"
    "\"ratelimit\":{\"options\":{\"rate\":1,\"burst\":1}}},"
    "\"options\":{\"base\":\"https://solar.example.com\","
    "\"auth\":{\"prefix\":\"Bearer \"}}}";

typedef struct {
  char* instance;
  vxstn_val* options;
} fake_client;

static fake_client* LAST_CLIENT = NULL;
static int CONSTRUCTED = 0;

/* A generated C SDK's constructor, in miniature: it takes the options
   station composed and binds through the ambient station, exactly as
   the generated feature/station.c adapter does. */
static void* fake_construct(const vxstn_val* options, void* ud) {
  fake_client* c = (fake_client*)calloc(1, sizeof(fake_client));
  vxstn_station* st = vxstn_current();
  char* fjson = vxstn_canonical(vxstn_map_get(options, "feature"));
  vxstn_binding* binding = vxstn_register(st, c, SOLAR_CONFIG, fjson, NULL, NULL);
  (void)ud;
  c->options = vxstn_clone(options);
  c->instance = vxstn_sdup(NULL == binding ? "" : binding->plugin);
  vxstn_binding_free(binding);
  free(fjson);
  CONSTRUCTED++;
  LAST_CLIENT = c;
  return c;
}

static void fake_free(void* client) {
  fake_client* c = (fake_client*)client;
  if (NULL == c) {
    return;
  }
  free(c->instance);
  vxstn_val_free(c->options);
  free(c);
}

static void test_factory_table(void) {
  vxstn_val* config = vxstn_parse_json(SOLAR_CONFIG, NULL);
  vxstn_val* same = vxstn_parse_json(SOLAR_CONFIG, NULL);
  vxstn_error* err = NULL;
  const vxstn_factory* one;
  const vxstn_factory* two;
  vxstn_val* slugs;

  vxstn_reset_factories();

  one = vxstn_provide("solar", fake_construct, NULL, config, &err);
  CHECK(NULL != one && NULL == err);
  /* NORMALIZED AT PROVIDE TIME: check() can validate a feature config
     without constructing anything. */
  CHECK_STR(vxstn_strval(vxstn_map_get(one->descriptor, "slug")), "solar");

  /* Idempotent for the same pair - a generated registrar plus an
     explicit provide is an ordinary thing to end up with. */
  two = vxstn_provide("solar", fake_construct, NULL, same, &err);
  CHECK(one == two && NULL == err);

  /* A DIFFERENT factory is a conflict, not a silent replacement. */
  two = vxstn_provide("solar", NULL, NULL, same, &err);
  CHECK(NULL == two);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_factory_conflict"));
  vxstn_error_free(err);
  err = NULL;

  slugs = vxstn_provided();
  CHECK(1 == slugs->len);
  CHECK_STR(vxstn_strval(slugs->items[0]), "solar");
  vxstn_val_free(slugs);

  vxstn_reset_factories();
  CHECK(NULL == vxstn_factory_for("solar"));

  vxstn_val_free(config);
  vxstn_val_free(same);
}

static void test_check_package(void) {
  vxstn_error* err = NULL;

  CHECK(vxstn_check_package("solar", "@acme-sdk/solar-sdk", &err));
  CHECK(NULL == err);

  /* THE SEGMENT CHECK IS NOT IMPLIED BY THE PREFIX CHECKS: this one
     starts with neither `.` nor `/` and still escapes the dependency. */
  CHECK(!vxstn_check_package("solar", "pkg/../../escape", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_sdk_load"));
  vxstn_error_free(err);
  err = NULL;

  CHECK(!vxstn_check_package("solar", "./local", &err));
  vxstn_error_free(err);
  err = NULL;
  CHECK(!vxstn_check_package("solar", "https://example.com/x.js", &err));
  vxstn_error_free(err);
  err = NULL;
  CHECK(!vxstn_check_package("solar", "", &err));
  vxstn_error_free(err);
}

/* ---- Stage 5: the declarative front door ---- */

static const char* FLEET_CONFIG =
    "{\"station\":1,\"profiles\":{\"default\":{"
    "\"api\":{\"solar\":{\"package\":\"@acme-sdk/solar-sdk\","
    "\"feature\":{\"retry\":{\"max\":2}}}},"
    "\"sdk\":{\"solar\":{},"
    "\"solar$eu\":{\"base\":\"https://eu.solar.example.com\","
    "\"secret\":\"solar_eu.apikey\","
    "\"policy\":{\"hosts\":[\"eu.solar.example.com\"],"
    "\"budget\":{\"rps\":10,\"concurrency\":4}}},"
    "\"solar$off\":{\"active\":false}}}}}";

static void test_declarative(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_error* err = NULL;
  vxstn_val* config;
  vxstn_val* rows;
  vxstn_val* resolved;
  fake_client* a;
  fake_client* b;

  vxstn_reset_factories();
  vxstn_reset();

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json = FLEET_CONFIG;
  st = vxstn_open(&opts, &err);
  CHECK(NULL != st && NULL == err);
  if (NULL == st) {
    return;
  }

  /* design 6.3's review boundary: an in-code config is repo-scoped by
     construction. */
  CHECK(vxstn_repo_scoped(st));

  /* design 5.4 item 2: `package` stays in the grammar and is WARNED
     ABOUT at open, once per api, rather than imported or refused. */
  {
    vxstn_val* events = vxstn_events(st);
    bool saw = false;
    size_t i;
    for (i = 0; i < events->len; i++) {
      const char* warn =
          vxstn_strval(vxstn_map_get(vxstn_map_get(events->items[i], "meta"), "warn"));
      if (NULL != strstr(warn, "`package` is not honoured in the c port")) {
        saw = true;
        CHECK_STR(vxstn_strval(vxstn_map_get(events->items[i], "api")), "solar");
      }
    }
    CHECK(saw);
    vxstn_val_free(events);
  }

  /* Every DECLARED instance, sorted, whether or not it is live. */
  rows = vxstn_instances(st);
  CHECK(3 == rows->len);
  CHECK_STR(vxstn_strval(vxstn_map_get(rows->items[0], "name")), "solar");
  CHECK_STR(vxstn_strval(vxstn_map_get(rows->items[1], "api")), "solar");
  CHECK(!vxstn_map_get(rows->items[2], "active")->b);
  CHECK(!vxstn_map_get(rows->items[0], "live")->b);
  vxstn_val_free(rows);

  /* No factory yet: the message names the remedies THIS port offers,
     and says `package` is not one of them. */
  CHECK(NULL == vxstn_sdk(st, "solar", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_no_factory"));
  CHECK(NULL != err && NULL != strstr(err->message, "vxstn_provide"));
  CHECK(NULL != err && NULL != strstr(err->message, "not honoured here"));
  vxstn_error_free(err);
  err = NULL;

  config = vxstn_parse_json(SOLAR_CONFIG, NULL);
  CHECK(NULL != vxstn_provide("solar", fake_construct, NULL, config, &err));
  CHECK(NULL == err);

  /* An undeclared name, and an instance barred from running. */
  CHECK(NULL == vxstn_sdk(st, "solar$nope", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_no_instance"));
  CHECK(NULL != strstr(err->message, "declared: [solar, solar$eu, solar$off]"));
  vxstn_error_free(err);
  err = NULL;

  CHECK(NULL == vxstn_sdk(st, "solar$off", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_instance_inactive"));
  vxstn_error_free(err);
  err = NULL;

  /* CONSTRUCTED ON FIRST ASK AND CACHED: same name, same object. */
  CONSTRUCTED = 0;
  a = (fake_client*)vxstn_sdk(st, "solar$eu", &err);
  CHECK(NULL != a && NULL == err);
  CHECK(1 == CONSTRUCTED);
  CHECK(a == (fake_client*)vxstn_sdk(st, "solar$eu", &err));
  CHECK(1 == CONSTRUCTED);
  CHECK_STR(a->instance, "solar$eu");

  /* The block's `base` reaches the constructor, and the composed
     feature map does too - with the api-level `retry` in it. */
  CHECK_STR(vxstn_strval(vxstn_map_get(a->options, "base")),
            "https://eu.solar.example.com");
  CHECK(2 == vxstn_map_get(vxstn_map_get(vxstn_map_get(a->options, "feature"),
                                         "retry"),
                           "max")
                 ->i);
  /* Station's own entry is composed AFTER the user merge and always
     wins, so it is added by vxstn_options rather than by the config. */
  CHECK(vxstn_map_get(vxstn_map_get(vxstn_map_get(a->options, "feature"), "station"),
                      "active")
            ->b);

  /* The declared `secret` wins over the derived default, and the
     registry stores the effective name. */
  {
    vxstn_val* plugins = vxstn_plugins(st);
    CHECK(1 == plugins->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(plugins->items[0], "name")), "solar$eu");
    CHECK_STR(vxstn_strval(vxstn_map_get(plugins->items[0], "api")), "solar");
    CHECK_STR(vxstn_strval(vxstn_map_get(plugins->items[0], "secretname")),
              "solar_eu.apikey");
    vxstn_val_free(plugins);
  }

  /* design 8.7: provenance per (feature, key), and the policy budget
     composed into `ratelimit` with `policy.budget` as its level. */
  resolved = vxstn_features_of(st, "solar$eu", &err);
  CHECK(NULL != resolved && NULL == err);
  CHECK_STR(vxstn_strval(vxstn_map_get(
                vxstn_map_get(vxstn_map_get(resolved, "from"), "retry"), "max")),
            "default.api");
  CHECK(vxstn_map_get(vxstn_map_get(vxstn_map_get(resolved, "merged"), "ratelimit"),
                      "active")
            ->b);
  CHECK(10 == vxstn_map_get(vxstn_map_get(vxstn_map_get(resolved, "merged"),
                                          "ratelimit"),
                            "rate")
                  ->i);
  CHECK(4 == vxstn_map_get(vxstn_map_get(vxstn_map_get(resolved, "merged"),
                                         "ratelimit"),
                           "burst")
                 ->i);
  CHECK_STR(vxstn_strval(vxstn_map_get(
                vxstn_map_get(vxstn_map_get(resolved, "from"), "ratelimit"), "rate")),
            "policy.budget");
  /* The implicit station row is in the ORDER and not in `merged`. */
  CHECK(NULL == vxstn_map_get(vxstn_map_get(resolved, "merged"), "station"));
  {
    const vxstn_val* ordered = vxstn_map_get(resolved, "ordered");
    CHECK_STR(vxstn_strval(ordered->items[ordered->len - 1]), "station");
  }
  vxstn_val_free(resolved);

  /* An UNCACHED client under an auto-assigned tag; the secret name
     follows the DECLARED instance, not the tag. */
  b = (fake_client*)vxstn_create(st, "solar$eu", NULL, &err);
  CHECK(NULL != b && NULL == err);
  CHECK(b != a);
  CHECK_STR(b->instance, "solar$1");
  CHECK_STR(vxstn_declared_ref(st, "solar$1"), "solar$eu");
  /* ...and so does everything else the declared block carries: the
     alias is recorded, not the fields. */
  CHECK_STR(vxstn_strval(vxstn_map_get(vxstn_block_for(st, "solar$1"), "base")),
            "https://eu.solar.example.com");

  /* The fleet view, narrowed to one feature. */
  {
    vxstn_val* filter = vxstn_map();
    vxstn_val* view;
    vxstn_map_set(filter, "feature", vxstn_str("ratelimit"));
    view = vxstn_features(st, filter);
    CHECK(1 == view->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(view->items[0], "instance")), "solar$eu");
    CHECK(1 == vxstn_map_get(view->items[0], "merged")->mlen);
    vxstn_val_free(view);
    vxstn_val_free(filter);
  }

  /* check(): every ACTIVE declared instance, constructed or refused,
     and the inactive one skipped rather than failed. */
  {
    vxstn_val* result = vxstn_check(st);
    const vxstn_val* ok = vxstn_map_get(result, "ok");
    const vxstn_val* failed = vxstn_map_get(result, "failed");
    CHECK(2 == ok->len);
    CHECK(0 == failed->len);
    vxstn_val_free(result);
  }

  /* warm(): a name nobody declared or registered is a MISS, never a
     lookup, and the active declared set is what a bare call warms. */
  {
    vxstn_val* names = vxstn_list();
    vxstn_val* result;
    vxstn_list_push(names, vxstn_str("solar$prodd"));
    result = vxstn_warm(st, names);
    CHECK(0 == vxstn_map_get(result, "warmed")->len);
    CHECK(1 == vxstn_map_get(result, "missed")->len);
    vxstn_val_free(result);
    vxstn_val_free(names);

    result = vxstn_warm(st, NULL);
    /* No environment variable is set for either, so both miss - the
       point here is the PLAN: two active declared instances, and the
       barred one left alone. */
    CHECK(2 == vxstn_map_get(result, "missed")->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(result, "missed")->items[0]), "solar");
    vxstn_val_free(result);
  }

  fake_free(a);
  fake_free(b);
  vxstn_reset_factories();
  vxstn_station_free(st);
  vxstn_reset();
}

static void test_declarative_feature_faults(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_error* err = NULL;
  vxstn_val* config;
  void* client;

  vxstn_reset_factories();
  vxstn_reset();

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  /* A typo'd option name: accepted by the grammar (a feature entry is
     `$OPEN`) and caught by the descriptor-derived checker. */
  opts.config_json = "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
                     "{\"feature\":{\"retry\":{\"retires\":5}}}}}}}";
  st = vxstn_open(&opts, &err);
  CHECK(NULL != st && NULL == err);

  config = vxstn_parse_json(SOLAR_CONFIG, NULL);
  vxstn_provide("solar", fake_construct, NULL, config, NULL);

  client = vxstn_sdk(st, "solar", &err);
  CHECK(NULL == client);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_feature_option"));
  CHECK(NULL != err && NULL != strstr(err->message, "declares no option \"retires\""));
  vxstn_error_free(err);

  /* ...and check() reports it WITHOUT constructing anything. */
  {
    vxstn_val* result = vxstn_check(st);
    CHECK(0 == vxstn_map_get(result, "ok")->len);
    CHECK(1 == vxstn_map_get(result, "failed")->len);
    CHECK_STR(vxstn_strval(vxstn_map_get(vxstn_map_get(result, "failed")->items[0],
                                         "code")),
              "station_feature_option");
    vxstn_val_free(result);
  }

  vxstn_val_free(config);
  vxstn_reset_factories();
  vxstn_station_free(st);
  vxstn_reset();
}

/* A malformed config fails open() with EVERY error at once, rather than
   at the first request that touches the bad key. */
static void test_open_validates(void) {
  vxstn_open_opts opts;
  vxstn_station* st;
  vxstn_error* err = NULL;

  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json = "{\"station\":1,\"profiles\":{\"default\":{\"sdk\":{\"solar\":"
                     "{\"bass\":1}}}}}";
  st = vxstn_station_new(&opts, &err);
  CHECK(NULL == st);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_config_invalid"));
  CHECK(NULL != err && NULL != strstr(err->message, "sdk.solar: bass"));
  vxstn_error_free(err);
  err = NULL;

  opts.config_json = "{not json";
  st = vxstn_station_new(&opts, &err);
  CHECK(NULL == st);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_config_invalid"));
  vxstn_error_free(err);
}

int main(void) {
  test_identity();
  test_canonical();
  test_parse_json();
  test_events_ring();
  test_taps();
  test_register();
  test_secret_broker();
  test_secret_precedence();
  test_host_policy();
  test_wrap_order();
  test_ambient();
  test_close_warns();
  test_outcome();
  test_emit_http();
  test_shape_mirror();
  test_normalize_config();
  test_validate_config();
  test_feature_merge();
  test_feature_order();
  test_compose_and_check();
  test_factory_table();
  test_check_package();
  test_declarative();
  test_declarative_feature_faults();
  test_open_validates();

  if (0 == FAILS) {
    printf("station c unit: all tests passed\n");
    return 0;
  }
  printf("station c unit: %d FAILED\n", FAILS);
  return 1;
}
