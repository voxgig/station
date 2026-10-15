/* RUN: make test
 *
 * The secret broker over real stores: a mini vault written to a scratch
 * directory and read back through station, its passphrase handed over in
 * memory in the provider spec, and the file-backed built-in kinds. This
 * binary links the minivault plugin and libcrypto; the unit and
 * conformance binaries link neither.
 */

#define _POSIX_C_SOURCE 200809L

/* mkdtemp, which Apple's headers hide under _POSIX_C_SOURCE alone. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../src/voxgig_station.h"

#include "sekretoplugins.h"

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

#define MASTER "station-test-master"
#define READER "station-test-reader"

/* PBKDF2 rounds per key: the library default is the point of a KDF and
 * the wrong cost to pay per test. */
#define ROUNDS 1000

static char WORK[] = "/tmp/station-secrets-XXXXXX";
static char* VAULT = NULL;

static const char* TASKPAD_CONFIG =
    "{\"main\":{\"name\":\"Taskpad\",\"slug\":\"taskpad\","
    "\"version\":\"0.0.1\",\"target\":\"c\"},"
    "\"feature\":{\"test\":{}},"
    "\"options\":{\"base\":\"http://localhost:8902\","
    "\"auth\":{\"prefix\":\"\"},\"entity\":{\"todo\":{}}},"
    "\"entity\":{\"todo\":{\"fields\":[{\"name\":\"title\",\"kind\":\"String\"}],"
    "\"op\":{\"list\":{\"points\":[{\"method\":\"GET\",\"orig\":\"/api/todo\","
    "\"parts\":[\"api\",\"todo\"]}]}}}}}";

static char* workpath(const char* name) {
  size_t n = strlen(WORK) + strlen(name) + 2;
  char* out = (char*)malloc(n);
  snprintf(out, n, "%s/%s", WORK, name);
  return out;
}

static void writefile(const char* path, const char* text) {
  FILE* f = fopen(path, "w");
  CHECK(NULL != f);
  if (NULL != f) {
    fputs(text, f);
    fclose(f);
  }
}

/* A JSON string literal for `text`, escaped by the library's own
 * canonical writer. Owned. */
static char* quoted(const char* text) {
  vxstn_val* v = vxstn_str(text);
  char* out = vxstn_canonical(v);
  vxstn_val_free(v);
  return out;
}

/* A provider entry: {"kind":kind,"file":file,...}, with the passphrase
 * and key id only when given. Owned. */
static char* entry(const char* kind, const char* field, const char* path, const char* key,
                   const char* passphrase) {
  char* qpath = quoted(path);
  char* qkey = quoted(NULL == key ? "" : key);
  char* qphrase = quoted(NULL == passphrase ? "" : passphrase);
  size_t n = strlen(kind) + strlen(field) + strlen(qpath) + strlen(qkey) + strlen(qphrase) + 96;
  char* out = (char*)malloc(n);
  snprintf(out, n, "{\"kind\":\"%s\",\"%s\":%s%s%s%s%s}", kind, field, qpath,
           NULL == key ? "" : ",\"vaultkey\":", NULL == key ? "" : qkey,
           NULL == passphrase ? "" : ",\"passphrase\":", NULL == passphrase ? "" : qphrase);
  free(qpath);
  free(qkey);
  free(qphrase);
  return out;
}

/* A station over one profile whose chain is `providers`, a JSON list.
 * The config lives only in this process's memory. */
static vxstn_station* open_chain(const char* providers, bool minivault, vxstn_error** err) {
  static void* plugins[1];
  vxstn_open_opts opts;
  vxstn_station* st;
  size_t n = strlen(providers) + 96;
  char* config = (char*)malloc(n);

  snprintf(config, n,
           "{\"station\":1,\"profiles\":{\"default\":{\"secrets\":{\"providers\":%s}}}}",
           providers);
  plugins[0] = sek_plugin_minivault();
  memset(&opts, 0, sizeof(opts));
  opts.proxy = "off";
  opts.config_json = config;
  opts.plugins = minivault ? plugins : NULL;
  opts.plugincount = minivault ? 1 : 0;
  st = vxstn_station_new(&opts, err);
  free(config);
  return st;
}

static vxstn_station* open_one(const char* provider, bool minivault, vxstn_error** err) {
  size_t n = strlen(provider) + 3;
  char* list = (char*)malloc(n);
  vxstn_station* st;
  snprintf(list, n, "[%s]", provider);
  st = open_chain(list, minivault, err);
  free(list);
  return st;
}

static void bind_taskpad(vxstn_station* st, const char* secret) {
  static int client = 0;
  vxstn_error* err = NULL;
  vxstn_binding* binding;
  if (NULL == st) {
    return;
  }
  binding = vxstn_register(st, &client, TASKPAD_CONFIG, NULL, secret, &err);
  CHECK(NULL != binding && NULL == err);
  vxstn_binding_free(binding);
  vxstn_error_free(err);
}

static bool make_vault(void) {
  sek_pool* pool = sek_pool_new();
  sek_vaultoptions options;
  sek_vaultgrant grant;
  sek_minivault* vault = NULL;
  sek_err err;

  memset(&options, 0, sizeof(options));
  options.file = VAULT;
  options.passphrase = MASTER;
  options.iterations = ROUNDS;
  err = sek_vault_create(pool, &options, &vault);
  if (NULL == err) {
    err = sek_vault_set(vault, "taskpad.apikey", "vault-key-1");
  }
  if (NULL == err) {
    err = sek_vault_set(vault, "other.apikey", "vault-other");
  }
  if (NULL == err) {
    memset(&grant, 0, sizeof(grant));
    grant.key = "reader";
    grant.passphrase = READER;
    grant.names = sek_list_new(pool);
    sek_list_add(grant.names, "taskpad.apikey");
    grant.iterations = ROUNDS;
    err = sek_vault_grant(vault, &grant);
  }
  if (NULL != err) {
    printf("cannot make the vault: %s\n", err);
  }
  sek_pool_free(pool);
  return NULL == err;
}

static void set_in_vault(const char* name, const char* value) {
  sek_pool* pool = sek_pool_new();
  sek_vaultoptions options;
  sek_minivault* vault = NULL;
  sek_err err;

  memset(&options, 0, sizeof(options));
  options.file = VAULT;
  options.passphrase = MASTER;
  err = sek_vault_open(pool, &options, &vault);
  if (NULL == err) {
    err = sek_vault_set(vault, name, value);
  }
  CHECK(NULL == err);
  sek_pool_free(pool);
}

static void test_vault_resolves(void) {
  char* provider = entry("minivault", "file", VAULT, NULL, MASTER);
  vxstn_error* err = NULL;
  vxstn_station* st = open_one(provider, true, &err);
  char* red;
  vxstn_val* status;

  CHECK(NULL != st && NULL == err);
  bind_taskpad(st, NULL);
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "vault-key-1");
  CHECK(NULL == err);

  red = vxstn_redact(st, "the upstream echoed vault-key-1 back");
  CHECK_STR(red, "the upstream echoed [redacted] back");
  free(red);

  status = vxstn_status(st);
  CHECK(NULL == vxstn_map_get(status, "secrets"));
  vxstn_val_free(status);

  /* Rotation: a cached value holds until refresh, then the chain answers
     again from the file. */
  set_in_vault("taskpad.apikey", "vault-key-2");
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "vault-key-1");
  vxstn_refresh_secrets(st);
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "vault-key-2");
  set_in_vault("taskpad.apikey", "vault-key-1");

  vxstn_station_free(st);
  free(provider);
}

/* A restricted key reads what it was granted; an ungranted name is a
   miss, exactly as if the vault did not hold it. */
static void test_vault_restricted_key(void) {
  char* provider = entry("minivault", "file", VAULT, "reader", READER);
  vxstn_error* err = NULL;
  vxstn_station* st = open_one(provider, true, &err);

  CHECK(NULL != st);
  bind_taskpad(st, NULL);
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "vault-key-1");
  vxstn_station_free(st);

  st = open_one(provider, true, &err);
  bind_taskpad(st, "other.apikey");
  CHECK(NULL == vxstn_secret_value(st, "taskpad", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_no_value"));
  vxstn_error_free(err);
  vxstn_station_free(st);
  free(provider);
}

/* A wrong passphrase is a store that could not answer: an error, and the
   chain does not fall through to the environment behind it, which holds
   the name. */
static void test_vault_wrong_passphrase(void) {
  char* provider = entry("minivault", "file", VAULT, NULL, "not-the-passphrase");
  size_t n = strlen(provider) + 32;
  char* chain = (char*)malloc(n);
  vxstn_error* err = NULL;
  vxstn_station* st;

  snprintf(chain, n, "[%s,{\"kind\":\"env\"}]", provider);
  setenv("TASKPAD_APIKEY", "from-env", 1);
  st = open_chain(chain, true, &err);
  CHECK(NULL != st && NULL == err);
  bind_taskpad(st, NULL);
  CHECK(NULL == vxstn_secret_value(st, "taskpad", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_error"));
  CHECK(NULL != err && NULL != strstr(err->message, "minivault: wrong passphrase"));
  vxstn_error_free(err);
  unsetenv("TASKPAD_APIKEY");
  vxstn_station_free(st);
  free(chain);
  free(provider);
}

static void test_vault_missing_file(void) {
  char* absent = workpath("absent.skmv");
  char* provider = entry("minivault", "file", absent, NULL, MASTER);
  vxstn_error* err = NULL;
  vxstn_station* st = open_one(provider, true, &err);

  CHECK(NULL != st);
  bind_taskpad(st, NULL);
  CHECK(NULL == vxstn_secret_value(st, "taskpad", &err));
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_error"));
  CHECK(NULL != err && NULL != strstr(err->message, "no vault file"));
  vxstn_error_free(err);
  vxstn_station_free(st);
  free(provider);
  free(absent);
}

/* Linking the plugin is not enough: a kind joins the catalog only when
   its definition is handed in, as sekreto's own options require. */
static void test_vault_not_handed_in(void) {
  char* provider = entry("minivault", "file", VAULT, NULL, MASTER);
  vxstn_error* err = NULL;
  vxstn_station* st = open_one(provider, false, &err);

  CHECK(NULL == st);
  CHECK(NULL != err && 0 == strcmp(err->code, "station_secret_error"));
  CHECK(NULL != err && NULL != strstr(err->message, "minivault is a sekreto plugin"));
  vxstn_error_free(err);
  free(provider);
}

static void test_file_kinds(void) {
  char* dotenv = workpath("app.env");
  char* mounted = workpath("mounted");
  char* secretfile = workpath("mounted/TASKPAD_APIKEY");
  char* provider;
  vxstn_error* err = NULL;
  vxstn_station* st;

  writefile(dotenv, "# local\nTASKPAD_APIKEY=from-dotenv\n");
  CHECK(0 == mkdir(mounted, 0700));
  writefile(secretfile, "from-file\n");

  provider = entry("dotenv", "file", dotenv, NULL, NULL);
  st = open_one(provider, false, &err);
  CHECK(NULL != st);
  bind_taskpad(st, NULL);
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "from-dotenv");
  vxstn_station_free(st);
  free(provider);

  provider = entry("file", "dir", mounted, NULL, NULL);
  st = open_one(provider, false, &err);
  CHECK(NULL != st);
  bind_taskpad(st, NULL);
  CHECK_STR(vxstn_secret_value(st, "taskpad", &err), "from-file");
  vxstn_station_free(st);
  free(provider);

  free(dotenv);
  free(mounted);
  free(secretfile);
}

static void removetree(const char* dir) {
  DIR* d = opendir(dir);
  struct dirent* ent;
  if (NULL == d) {
    return;
  }
  while (NULL != (ent = readdir(d))) {
    size_t n;
    char* path;
    struct stat info;
    if (0 == strcmp(".", ent->d_name) || 0 == strcmp("..", ent->d_name)) {
      continue;
    }
    n = strlen(dir) + strlen(ent->d_name) + 2;
    path = (char*)malloc(n);
    snprintf(path, n, "%s/%s", dir, ent->d_name);
    if (0 == lstat(path, &info) && S_ISDIR(info.st_mode)) {
      removetree(path);
    } else {
      unlink(path);
    }
    free(path);
  }
  closedir(d);
  rmdir(dir);
}

int main(void) {
  if (NULL == mkdtemp(WORK)) {
    printf("station c secrets: cannot make a work directory\n");
    return 1;
  }
  VAULT = workpath("station.skmv");

  if (make_vault()) {
    test_vault_resolves();
    test_vault_restricted_key();
    test_vault_wrong_passphrase();
    test_vault_missing_file();
  } else {
    FAILS++;
  }
  test_vault_not_handed_in();
  test_file_kinds();

  removetree(WORK);
  free(VAULT);

  if (0 == FAILS) {
    printf("station c secrets: all tests passed\n");
    return 0;
  }
  printf("station c secrets: %d FAILED\n", FAILS);
  return 1;
}
