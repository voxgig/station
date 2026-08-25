/* voxgig/station - the factory table (design station.md 6.2) and the
 * instance ref grammar (design 6.1).
 *
 * A FACTORY IS A CONSTRUCTOR *PLUS* THE SDK'S STATIC CONFIG, not a bare
 * function pointer. Station composes the ordered feature array FOR the
 * constructor, so it needs the transport roles and the feature option
 * schemas BEFORE construction - but the adapter builds and registers
 * its descriptor DURING construction, so nothing would be known in
 * time. The generated package emits its config as a module-level
 * constant, which exists as soon as the package is linked; station
 * normalizes the descriptor AT PROVIDE TIME and three things follow:
 * the per-api descriptor cache is populated at registration, `check()`
 * can validate every instance's feature config without constructing
 * anything, and the adapter's registration during construction becomes
 * a RECONCILIATION rather than the first sighting.
 *
 * PROCESS-GLOBAL, and station-independent: it holds no configuration,
 * only "here is how to construct this api". Path 1 of design 6.2 is
 * module self-registration, which happens once per process and not once
 * per Station.
 *
 * THE C DIVERGENCE (design 6.2/6.3, and the loader's 5.4): C has no
 * runtime module loading and no module-init hook a linker is required
 * to run, so of the three ways the table gets filled this port offers
 * exactly ONE - `vxstn_provide`, called by the application (or by a
 * generated SDK's own registrar function) before the first
 * `vxstn_sdk`. `api.<slug>.package` stays IN THE GRAMMAR, because the
 * corpus validates configs carrying it and one config file serves a
 * polyglot fleet, but it is not honoured here: open() emits one warning
 * event per declared package and `vxstn_check_package` exists only as
 * the pure validator, never as a loader. README.md states it in full.
 *
 * THREADING: none, like the rest of this library - the generated C SDKs
 * are single-threaded and the table matches that scope. A threaded host
 * must call vxstn_provide before it starts its threads.
 *
 * A port of typescript/src/factory.ts and the ref half of
 * typescript/src/Station.ts, which are canonical.
 */

#if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdlib.h>
#include <string.h>

/* =========================================================================
 * The ref grammar (design 6.1), pinned by the `instanceref` corpus
 * section
 * =========================================================================*/

/* The joint identity model's (station-and-plugin.md 2, plugin design
 * 4): a name is a package-ish specifier, a tag is not - it MAY start
 * with a digit, because auto-tagging assigns integer tags, and admits
 * neither `@` nor `/`. Both cap at 1024. The split is on the FIRST `$`,
 * so "a$b$c" is a good name with a bad tag. */
#define VXSTN_REF_MAX 1024

bool vxstn_check_instance_name(const char* name) {
  size_t i, n;
  if (NULL == name) {
    return false;
  }
  n = strlen(name);
  if (0 == n || VXSTN_REF_MAX < n) {
    return false;
  }
  if (!((name[0] >= 'a' && name[0] <= 'z') || (name[0] >= 'A' && name[0] <= 'Z') ||
        '@' == name[0])) {
    return false;
  }
  for (i = 1; i < n; i++) {
    char c = name[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
        '.' == c || '~' == c || '_' == c || '-' == c || '/' == c) {
      continue;
    }
    return false;
  }
  return true;
}

bool vxstn_check_instance_tag(const char* tag) {
  size_t i, n;
  if (NULL == tag) {
    return false;
  }
  n = strlen(tag);
  /* The empty tag is an ordinary tag: the single-instance case writes
   * no tag and never learns tags exist. */
  if (0 == n) {
    return true;
  }
  if (VXSTN_REF_MAX < n) {
    return false;
  }
  for (i = 0; i < n; i++) {
    char c = tag[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
        '.' == c || '~' == c || '_' == c || '-' == c) {
      continue;
    }
    return false;
  }
  return true;
}

/* Validate a ref against the joint grammar and return its CANONICAL
 * spelling: a trailing `$` (empty tag) is never kept, so "stripe$" and
 * "stripe" are ONE registry key rather than two. Owned, or NULL +
 * *err. */
char* vxstn_check_ref(const char* ref, vxstn_error** err) {
  const char* cut;
  char* name;
  const char* tag;
  vxstn_sb msg;

  if (NULL == ref) {
    ref = "";
  }
  cut = strchr(ref, '$');
  name = vxstn_refapi(ref);
  tag = NULL == cut ? "" : cut + 1;

  if (!vxstn_check_instance_name(name)) {
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "invalid instance name \"");
    vxstn_sb_put(&msg, name);
    vxstn_sb_put(&msg, "\" in ref \"");
    vxstn_sb_put(&msg, ref);
    vxstn_sb_put(&msg, "\": a name starts with a letter or `@` and uses "
                       "`[a-zA-Z0-9.~_-/]`, max 1024 (design 6.1)");
    vxstn_seterr(err, "station_instance_api", msg.buf);
    free(msg.buf);
    free(name);
    return NULL;
  }
  if (!vxstn_check_instance_tag(tag)) {
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "invalid instance tag \"");
    vxstn_sb_put(&msg, tag);
    vxstn_sb_put(&msg, "\" in ref \"");
    vxstn_sb_put(&msg, ref);
    vxstn_sb_put(&msg, "\": a tag uses `[a-zA-Z0-9.~_-]`, max 1024 (design 6.1)");
    vxstn_seterr(err, "station_instance_api", msg.buf);
    free(msg.buf);
    free(name);
    return NULL;
  }

  if ('\0' == tag[0]) {
    return name;
  }
  free(name);
  return vxstn_sdup(ref);
}

/* `as` is a TAG, not a free name: a ref whose name half is another api
 * is refused rather than quietly denoting some other definition. */
static bool checkapi(const char* api, const char* ref, vxstn_error** err) {
  char* named = vxstn_refapi(ref);
  vxstn_sb msg;
  if (0 == strcmp(named, NULL == api ? "" : api)) {
    free(named);
    return true;
  }
  vxstn_sb_init(&msg);
  vxstn_sb_put(&msg, "instance \"");
  vxstn_sb_put(&msg, ref);
  vxstn_sb_put(&msg, "\" names api \"");
  vxstn_sb_put(&msg, named);
  vxstn_sb_put(&msg, "\", but the SDK passed is api \"");
  vxstn_sb_put(&msg, NULL == api ? "" : api);
  vxstn_sb_put(&msg, "\"; `as` is a tag, not a free name (design 6.1)");
  vxstn_seterr(err, "station_instance_api", msg.buf);
  free(msg.buf);
  free(named);
  return false;
}

static const char* nonempty(const vxstn_val* fopts, const char* key) {
  const vxstn_val* v = vxstn_getk(fopts, key);
  if (!vxstn_is_str(v) || '\0' == v->str[0]) {
    return NULL;
  }
  return v->str;
}

/* design 6.1's rule. `instance` wins over `as`; a bare call returns the
 * validated api slug; a `$`-LESS `as` IS ALWAYS A TAG and yields
 * api+"$"+as; a `$`-bearing value is a full ref validated against the
 * api. Owned, or NULL + *err (station_instance_api).
 *
 * The `$`-less branch has no exception for "the tag happens to equal
 * the api": design 6.1 says twice and emphatically that `as` is a tag
 * rather than a free name, and a rule with no exceptions is the one
 * that ports the same way twenty times. Someone who wants the untagged
 * instance passes no `as` at all. */
char* vxstn_instance_ref(const char* api, const vxstn_val* fopts, vxstn_error** err) {
  const char* explicit_;
  const char* as;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == api) {
    api = "";
  }

  explicit_ = nonempty(fopts, "instance");
  if (NULL != explicit_) {
    if (!checkapi(api, explicit_, err)) {
      return NULL;
    }
    return vxstn_check_ref(explicit_, err);
  }

  as = nonempty(fopts, "as");
  if (NULL == as) {
    /* The bare fallback is the SLUG - a name, never a ref: a `$` in it
     * is an invalid name, not an implicit tag. */
    vxstn_sb msg;
    if (vxstn_check_instance_name(api)) {
      return vxstn_sdup(api);
    }
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "invalid instance name \"");
    vxstn_sb_put(&msg, api);
    vxstn_sb_put(&msg, "\": a name starts with a letter or `@` and uses "
                       "`[a-zA-Z0-9.~_-/]`, max 1024 (design 6.1)");
    vxstn_seterr(err, "station_instance_api", msg.buf);
    free(msg.buf);
    return NULL;
  }

  if (NULL == strchr(as, '$')) {
    vxstn_sb ref;
    char* out;
    vxstn_sb_init(&ref);
    vxstn_sb_put(&ref, api);
    vxstn_sb_putc(&ref, '$');
    vxstn_sb_put(&ref, as);
    out = vxstn_check_ref(ref.buf, err);
    free(ref.buf);
    return out;
  }

  if (!checkapi(api, as, err)) {
    return NULL;
  }
  return vxstn_check_ref(as, err);
}

/* =========================================================================
 * `package`: the validator this port keeps, and the loader it does not
 * (design 6.3, and the non-loader divergence 5.4)
 * =========================================================================*/

/* Only MODULE NAMES, resolved by the host language's ordinary
 * resolution from the application root - never a filesystem path, never
 * a URL, never anything relative.
 *
 * THE SEGMENT CHECK IS NOT OPTIONAL AND IS NOT IMPLIED BY THE PREFIX
 * CHECKS: "pkg/../../escape" starts with neither `.` nor `/`, so a
 * first-character check passes it, and a host that resolved it would
 * reach application-local code from OUTSIDE the named dependency.
 *
 * C HAS NO LOADER, so this is a pure predicate here: it rejects a
 * malformed `package` value with the same station_sdk_load message
 * every loader port raises, and nothing in this port ever imports
 * anything. Kept because it is pure and cheap and because a config
 * shared with a loader port should fail the same way in both. */
bool vxstn_check_package(const char* api, const char* pkg, vxstn_error** err) {
  bool bad = false;
  size_t i, n;

  if (NULL != err) {
    *err = NULL;
  }
  n = NULL == pkg ? 0 : strlen(pkg);

  if (0 == n) {
    bad = true;
  } else if ('.' == pkg[0] || '/' == pkg[0] || '~' == pkg[0]) {
    bad = true;
  } else if (NULL != strstr(pkg, "://") || NULL != strchr(pkg, '\\')) {
    bad = true;
  } else {
    /* A path SEGMENT that is exactly "." or "..". */
    size_t start = 0;
    for (i = 0; i <= n; i++) {
      if (i == n || '/' == pkg[i]) {
        size_t seglen = i - start;
        if ((1 == seglen && '.' == pkg[start]) ||
            (2 == seglen && '.' == pkg[start] && '.' == pkg[start + 1])) {
          bad = true;
          break;
        }
        start = i + 1;
      }
    }
  }

  if (bad) {
    vxstn_val* asval = vxstn_str(NULL == pkg ? "" : pkg);
    char* shown = vxstn_canonical(asval);
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "api \"");
    vxstn_sb_put(&msg, NULL == api ? "" : api);
    vxstn_sb_put(&msg, "\": `package` must be a module name resolved from the "
                       "application root, not a path or URL: ");
    vxstn_sb_put(&msg, shown);
    vxstn_seterr(err, "station_sdk_load", msg.buf);
    free(msg.buf);
    free(shown);
    vxstn_val_free(asval);
    return false;
  }
  return true;
}

/* =========================================================================
 * The table
 * =========================================================================*/

static vxstn_factory* TABLE = NULL;
static size_t NTABLE = 0;

static bool sameconfig(const vxstn_val* a, const vxstn_val* b) {
  char* ja;
  char* jb;
  bool same;
  if (a == b) {
    return true;
  }
  /* The dynamic ports compare object identity (`prior.config ===
   * factory.config`). C has no such handle to compare across
   * translation units - a generated SDK's config constant may be built
   * per call - so "the same values" is read literally: the same
   * canonical bytes. */
  ja = vxstn_canonical(a);
  jb = vxstn_canonical(b);
  same = 0 == strcmp(ja, jb);
  free(ja);
  free(jb);
  return same;
}

const vxstn_factory* vxstn_factory_for(const char* api) {
  size_t i;
  if (NULL == api) {
    return NULL;
  }
  for (i = 0; i < NTABLE; i++) {
    if (0 == strcmp(TABLE[i].api, api)) {
      return &TABLE[i];
    }
  }
  return NULL;
}

/* Register an api's { construct, config } pair.
 *
 * IDEMPOTENT per api: registering the SAME pair twice is a no-op,
 * because a generated SDK's own registrar plus an explicit
 * vxstn_provide for one api is an ordinary thing for an application to
 * end up with. A second registration with a DIFFERENT factory is
 * station_factory_conflict - a process has one build of an SDK, and
 * picking between two silently is not a thing to do quietly. */
const vxstn_factory* vxstn_provide(const char* api, vxstn_construct_fn construct,
                                   void* ud, const vxstn_val* config,
                                   vxstn_error** err) {
  const vxstn_factory* prior;
  vxstn_factory* entry;
  vxstn_val* warnings = NULL;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == api) {
    api = "";
  }

  prior = vxstn_factory_for(api);
  if (NULL != prior) {
    if (prior->construct == construct && prior->ud == ud &&
        sameconfig(prior->config, config)) {
      return prior;
    }
    {
      vxstn_sb msg;
      vxstn_sb_init(&msg);
      vxstn_sb_put(&msg, "two different factories registered for api \"");
      vxstn_sb_put(&msg, api);
      vxstn_sb_put(&msg, "\"; a process has one build of an SDK, and picking "
                         "between two silently is not a thing to do quietly");
      vxstn_seterr(err, "station_factory_conflict", msg.buf);
      free(msg.buf);
    }
    return NULL;
  }

  TABLE = (vxstn_factory*)realloc(TABLE, (NTABLE + 1) * sizeof(vxstn_factory));
  entry = &TABLE[NTABLE++];
  memset(entry, 0, sizeof(*entry));
  entry->api = vxstn_sdup(api);
  entry->construct = construct;
  entry->ud = ud;
  entry->config = vxstn_clone(config);
  /* AT PROVIDE TIME, which is the whole point of carrying `config` -
   * and with NO per-instance features, so the shared value holds only
   * api-stable metadata. */
  entry->descriptor = vxstn_normalize_descriptor(entry->config, NULL, &warnings);
  entry->warnings = warnings;
  return entry;
}

/* The api slugs currently registered, sorted. Owned. */
vxstn_val* vxstn_provided(void) {
  vxstn_val* out = vxstn_list();
  const char** slugs = (const char**)malloc((0 == NTABLE ? 1 : NTABLE) * sizeof(char*));
  size_t i;
  for (i = 0; i < NTABLE; i++) {
    slugs[i] = TABLE[i].api;
  }
  for (i = 1; i < NTABLE; i++) {
    const char* cur = slugs[i];
    size_t k = i;
    while (0 < k && 0 < strcmp(slugs[k - 1], cur)) {
      slugs[k] = slugs[k - 1];
      k--;
    }
    slugs[k] = cur;
  }
  for (i = 0; i < NTABLE; i++) {
    vxstn_list_push(out, vxstn_str(slugs[i]));
  }
  free((void*)slugs);
  return out;
}

/* Test seam. The table is process-global by design, so a suite that
 * registers factories has to be able to put the process back. */
void vxstn_reset_factories(void) {
  size_t i;
  for (i = 0; i < NTABLE; i++) {
    free(TABLE[i].api);
    vxstn_val_free(TABLE[i].config);
    vxstn_val_free(TABLE[i].descriptor);
    vxstn_val_free(TABLE[i].warnings);
  }
  free(TABLE);
  TABLE = NULL;
  NTABLE = 0;
}
