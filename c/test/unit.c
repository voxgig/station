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

#include "../src/voxgig_station.h"

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
      "{\"station\":1,\"profiles\":{\"default\":{\"plugin\":"
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
      "{\"station\":1,\"profiles\":{\"default\":{\"plugin\":"
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
      "{\"station\":1,\"profiles\":{\"default\":{\"plugin\":"
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

  if (0 == FAILS) {
    printf("station c unit: all tests passed\n");
    return 0;
  }
  printf("station c unit: %d FAILED\n", FAILS);
  return 1;
}
