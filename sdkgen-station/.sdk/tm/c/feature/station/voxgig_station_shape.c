/* voxgig/station - the config grammar, as data (design station.md 4).
 *
 * TWO STEPS, AND THE FIRST IS WHAT MAKES THE SECOND HONEST.
 *
 * struct drops the unexpected-key check for a map whose spec node ends
 * up empty - "an empty spec object means the object can be open". An
 * optional key is `['$ONE','$NIL', spec]`, and when the data does not
 * carry that key the validator REMOVES it from the spec node. So a
 * block whose keys are all optional degenerates into an open map
 * exactly when the data has none of them, and `{"solar": {"bass": 1}}`
 * validates clean - the one property the whole exercise is for,
 * silently absent in the one case that matters.
 *
 * So: vxstn_normalize_config materializes every documented default, and
 * vxstn_validate_config then runs a shape WITH NO OPTIONAL CONTAINERS
 * AT ALL. After normalization every container is present, so the shape
 * can require them, so unexpected-key detection is live at every level
 * and every error names its path.
 *
 * THE SECOND RUNTIME DEPENDENCY. Validation is voxgig/struct's, not a
 * second validator written here: `validate` with an `errs` collection
 * (so it collects rather than throwing at the first problem), closed
 * maps by default, and `$OPEN` where a foreign grammar passes through.
 * C has no registry, so struct is VENDORED - a generated C SDK already
 * carries it at `utility/struct/` beside this library's own
 * `feature/station/` (sdkgen-station .sdk/tm/c/feature/station/
 * VENDORED.md names that precedent), and this checkout borrows the
 * sibling through the Makefile's $STRUCT_HOME lookup.
 *
 * A port of typescript/src/shape.ts, which is canonical.
 */

#if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdlib.h>
#include <string.h>

/* The vendored dependency. In a generated SDK this resolves to
 * `utility/struct/voxgig_struct.h`; in this checkout the Makefile puts
 * the sibling's `c/src` on the include path. */
#include "voxgig_struct.h"

/* spec/config-shape.json, mirrored verbatim (generated - `make
 * sync-shape`; test/unit.c fails on drift). */
#include "config_shape.h"

/* =========================================================================
 * The defaults table - ONE table, two callers
 * =========================================================================*/

/* Profile-level containers. Safe to materialize early either way: they
 * are containers, and a missing one merges as empty regardless. */
vxstn_val* vxstn_profile_defaults(void) {
  vxstn_val* out = vxstn_map();
  vxstn_val* secrets = vxstn_map();
  vxstn_val* providers = vxstn_list();
  vxstn_val* env = vxstn_map();
  vxstn_map_set(env, "kind", vxstn_str("env"));
  vxstn_list_push(providers, env);
  vxstn_map_set(secrets, "providers", providers);
  vxstn_map_set(out, "secrets", secrets);
  vxstn_map_set(out, "api", vxstn_map());
  vxstn_map_set(out, "sdk", vxstn_map());
  vxstn_map_set(out, "feature", vxstn_map());
  return out;
}

/* Block-level. `feature` is a container and safe early.
 *
 * `active` IS NOT, and that is the whole timing rule: a default
 * synthesized into an OVERLAY block overwrites the base's real value
 * and silently reactivates an integration the base deliberately barred
 * (design 3.3). So the two consumers read this same table at different
 * moments - vxstn_validate_config BEFORE, applied to every block,
 * because a block with no present keys is an open map; the profile
 * resolver AFTER, applied to the merged instance, because an absent key
 * must stay absent through the merge. */
vxstn_val* vxstn_block_defaults(void) {
  vxstn_val* out = vxstn_map();
  vxstn_map_set(out, "active", vxstn_bool(true));
  vxstn_map_set(out, "feature", vxstn_map());
  return out;
}

/* The one block key carrying the timing rule. Named rather than
 * inferred, so a reader does not have to work out which of the two it
 * is, and so a test can assert it. */
const char* const VXSTN_MERGE_SENSITIVE[] = {"active", NULL};

/* =========================================================================
 * normalizeConfig
 * =========================================================================*/

/* Per feature entry, at every level: `active` -> true.
 *
 * A FEATURE NAMED IN THE CONFIG IS ONE YOU ARE ASKING FOR. The SDK's
 * own default is `active: false` for all but `log`, and
 * `{"retry": {"retries": 3}}` plainly means "retry, with three
 * attempts". It also keeps the feature map closed, for the same reason
 * every other block needs one present key.
 *
 * Defensive like the rest: a non-map is left untouched for validate to
 * reject by path. Mutates the (already copied) node in place. */
static void normfeatures(vxstn_val* f) {
  size_t i;
  if (!vxstn_is_map(f)) {
    return;
  }
  for (i = 0; i < f->mlen; i++) {
    vxstn_val* entry = f->vals[i];
    if (vxstn_is_map(entry) && NULL == vxstn_map_get(entry, "active")) {
      vxstn_map_set(entry, "active", vxstn_bool(true));
    }
  }
}

/* Materialize every documented default, DEFENSIVELY: a node that is not
 * the kind it expects is left alone for validate to reject with a
 * proper message. Pure data-in/data-out, which is what makes it
 * portable to 22 languages and expressible in the corpus.
 *
 * NEVER MUTATES THE INPUT: this port copies the whole tree up front and
 * writes into the copy, where the dynamic ports copy each map as they
 * descend. Same rule, and one free() rather than an ownership graph.
 *
 * THE NORMALIZED FORM IS AN INPUT TO VALIDATION AND TO NOTHING ELSE. */
vxstn_val* vxstn_normalize_config(const vxstn_val* raw) {
  vxstn_val* out;
  vxstn_val* profiles;
  vxstn_val* defaults;
  size_t p, d, b;
  static const char* const BLOCKKEYS[] = {"api", "sdk"};

  if (!vxstn_is_map(raw)) {
    return vxstn_clone(raw);
  }
  out = vxstn_clone(raw);

  if (NULL == vxstn_map_get(out, "station")) {
    vxstn_map_set(out, "station", vxstn_int(1));
  }
  if (NULL == vxstn_map_get(out, "profiles")) {
    vxstn_map_set(out, "profiles", vxstn_map());
  }
  profiles = vxstn_map_get(out, "profiles");
  if (!vxstn_is_map(profiles)) {
    return out;
  }

  defaults = vxstn_profile_defaults();

  for (p = 0; p < profiles->mlen; p++) {
    vxstn_val* prof = profiles->vals[p];
    vxstn_val* secrets;
    if (!vxstn_is_map(prof)) {
      continue;
    }

    for (d = 0; d < defaults->mlen; d++) {
      if (NULL == vxstn_map_get(prof, defaults->keys[d])) {
        vxstn_map_set(prof, defaults->keys[d], vxstn_clone(defaults->vals[d]));
      }
    }

    /* A `secrets` written without `providers` still gets the chain. */
    secrets = vxstn_map_get(prof, "secrets");
    if (vxstn_is_map(secrets) && NULL == vxstn_map_get(secrets, "providers")) {
      vxstn_val* providers = vxstn_list();
      vxstn_val* env = vxstn_map();
      vxstn_map_set(env, "kind", vxstn_str("env"));
      vxstn_list_push(providers, env);
      vxstn_map_set(secrets, "providers", providers);
    }

    normfeatures(vxstn_map_get(prof, "feature"));

    for (b = 0; b < sizeof(BLOCKKEYS) / sizeof(BLOCKKEYS[0]); b++) {
      vxstn_val* blocks = vxstn_map_get(prof, BLOCKKEYS[b]);
      vxstn_val* blockdefaults;
      size_t r;
      if (!vxstn_is_map(blocks)) {
        continue;
      }
      blockdefaults = vxstn_block_defaults();
      for (r = 0; r < blocks->mlen; r++) {
        vxstn_val* block = blocks->vals[r];
        size_t k;
        if (!vxstn_is_map(block)) {
          continue;
        }
        for (k = 0; k < blockdefaults->mlen; k++) {
          if (NULL == vxstn_map_get(block, blockdefaults->keys[k])) {
            vxstn_map_set(block, blockdefaults->keys[k],
                          vxstn_clone(blockdefaults->vals[k]));
          }
        }
        normfeatures(vxstn_map_get(block, "feature"));
      }
      vxstn_val_free(blockdefaults);
    }
  }

  vxstn_val_free(defaults);
  return out;
}

/* =========================================================================
 * The shape, and the struct bridge
 * =========================================================================*/

/* A FRESH DEEP COPY ON EVERY CALL, and that is not an optimization
 * left undone: struct's validate CONSUMES the spec it walks - it
 * deletes satisfied `$ONE` branches as it goes - so handing it one
 * parsed constant twice validates the second config against a spec the
 * first already ate. Re-parsing the mirror is the copy. */
vxstn_val* vxstn_config_shape(void) {
  return vxstn_parse_json(VXSTN_CONFIG_SHAPE_JSON, NULL);
}

/* The mirrored bytes, for the drift check in test/unit.c. Borrowed. */
const char* vxstn_config_shape_json(void) { return VXSTN_CONFIG_SHAPE_JSON; }

/* vxstn_val -> voxgig_value. Integer-shaped numbers stay integers:
 * struct's `$INTEGER` checker and its error spellings ("found integer:
 * 7" rather than "found decimal") both read the distinction. */
static voxgig_value* to_struct(const vxstn_val* v) {
  size_t i;
  if (NULL == v) {
    return voxgig_new_undef();
  }
  switch (v->kind) {
  case VXSTN_UNDEF:
    return voxgig_new_undef();
  case VXSTN_NULL:
    return voxgig_new_null();
  case VXSTN_BOOL:
    return voxgig_new_bool(v->b);
  case VXSTN_NUM:
    return v->isint ? voxgig_new_int(v->i) : voxgig_new_double(v->num);
  case VXSTN_STR:
    return voxgig_new_string(NULL == v->str ? "" : v->str);
  case VXSTN_LIST: {
    voxgig_value* out = voxgig_new_list();
    for (i = 0; i < v->len; i++) {
      voxgig_list_push(voxgig_as_list(out), to_struct(v->items[i]));
    }
    return out;
  }
  case VXSTN_MAP: {
    voxgig_value* out = voxgig_new_map();
    for (i = 0; i < v->mlen; i++) {
      if (VXSTN_UNDEF == v->vals[i]->kind) {
        continue; /* absent is absent, as in the canonical serializer */
      }
      voxgig_map_set(voxgig_as_map(out), v->keys[i], to_struct(v->vals[i]));
    }
    return out;
  }
  default:
    return voxgig_new_undef();
  }
}

/* Run the shape. Appends struct's own error strings, IN ENCOUNTER
 * ORDER, to `errs` (a vxstn list of strings). */
static void runshape(const vxstn_val* normalized, vxstn_val* errs) {
  voxgig_value* data = to_struct(normalized);
  voxgig_value* spec = voxgig_parse_json(VXSTN_CONFIG_SHAPE_JSON,
                                         strlen(VXSTN_CONFIG_SHAPE_JSON));
  voxgig_injection* inj = voxgig_inj_new(NULL, NULL);
  voxgig_value* out;
  voxgig_list* collected;
  size_t i;

  inj->mode = 0;
  /* The errs collection is what makes struct COLLECT rather than throw
   * at the first problem, which is what "every error at once" needs. */
  voxgig_release(inj->errs);
  inj->errs = voxgig_new_list();

  out = voxgig_validate(data, spec, inj);

  collected = voxgig_as_list(inj->errs);
  for (i = 0; NULL != collected && i < collected->len; i++) {
    voxgig_value* e = collected->items[i];
    if (voxgig_is_string(e)) {
      vxstn_list_push(errs, vxstn_str(voxgig_as_string(e)));
    }
  }

  voxgig_release(out);
  voxgig_inj_free(inj);
  voxgig_release(data);
  voxgig_release(spec);
}

/* =========================================================================
 * The design 5.2 / 4.4 scans
 * =========================================================================*/

/* Credential-shaped keys (design 5.2). `secret` is here AND is the one
 * exempt key - see secretvalue below; a blanket deny would reject the
 * very mechanism that keeps values out of the file. */
static const char* const CREDENTIAL_KEYS[] = {
  "apikey", "auth", "authorization", "token",
  "secret", "password", "credential", "bearer", NULL,
};

/* The suffix rule catches `access_key`, `X-Api-Token` and friends in
 * one rule rather than a growing list of spellings. */
static const char* const CREDENTIAL_SUFFIX[] = {
  "_KEY", "_TOKEN", "_SECRET", "_PASSWORD", NULL,
};

/* Design 5.2's backstop, stated as a bound rather than a grammar.
 * `validname()` is a NAME grammar, not a credential filter: it rejects
 * uppercase, hyphens, `+`, `/` and `=`, so it excludes most real
 * credential formats - but a lowercase hex token passes it cleanly. A
 * character class cannot tell a name from a secret.
 *
 * Derived names break on every separator (`voxgig_solardemo.apikey`
 * runs 6/9/6) and a hand-written name for a human to read does too; a
 * 24-character unbroken run is not a name anybody writes. Note this is
 * a RUN bound, not a length bound: `acme_internal_billing_service.apikey`
 * is 36 characters and passes, which is the false positive a naive
 * length bound would produce. */
#define VXSTN_RUN_BOUND 24

static bool unbroken_run(const char* s) {
  size_t run = 0;
  const unsigned char* p = (const unsigned char*)s;
  for (; '\0' != *p; p++) {
    if ((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
        (*p >= '0' && *p <= '9')) {
      run++;
      if (VXSTN_RUN_BOUND <= run) {
        return true;
      }
    } else {
      run = 0;
    }
  }
  return false;
}

/* The SHAPE kindof: it must agree with struct's own spellings, because
 * the workarounds below raise the message the shape would have raised.
 * NOT the feature kindof of design 8.5 (voxgig_station_feature.c) -
 * "object"/"integer" here against "map"/"number" there - and unifying
 * the two would make one of the two sets of messages wrong. */
static const char* shape_kindof(const vxstn_val* v) {
  if (NULL == v || VXSTN_UNDEF == v->kind) {
    return "undefined";
  }
  switch (v->kind) {
  case VXSTN_NULL:
    return "null";
  case VXSTN_LIST:
    return "list";
  case VXSTN_NUM:
    return v->isint ? "integer" : "decimal";
  case VXSTN_MAP:
    return "object";
  case VXSTN_BOOL:
    return "boolean";
  case VXSTN_STR:
    return "string";
  default:
    return "undefined";
  }
}

/* JSON.stringify of one value, for a message. Owned. */
static char* jsonof(const vxstn_val* v) { return vxstn_canonical(v); }

static void push_str(vxstn_val* list, char* owned) {
  vxstn_list_push(list, vxstn_str(owned));
  free(owned);
}

static char* joinpath(const char* path, const char* leaf) {
  vxstn_sb sb;
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, path);
  vxstn_sb_putc(&sb, '.');
  vxstn_sb_put(&sb, leaf);
  return sb.buf;
}

static char* joinindex(const char* path, size_t index) {
  vxstn_sb sb;
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, path);
  vxstn_sb_putc(&sb, '.');
  vxstn_sb_putf(&sb, "%lu", (unsigned long)index);
  return sb.buf;
}

/* A `secret`-named key holds a NAME, and that exemption is not a
 * loophole - it is the whole design. THREE checks, not one, in this
 * order, first failure winning, and they live in the same handful of
 * lines precisely so a port cannot implement only the first and inherit
 * the gap the others close. */
static void secretvalue(const vxstn_val* val, const char* path, vxstn_val* secrets) {
  vxstn_sb sb;
  if (!vxstn_is_str(val)) {
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, path);
    vxstn_sb_put(&sb, " must be a secret name (a string), but found ");
    vxstn_sb_put(&sb, shape_kindof(val));
    push_str(secrets, sb.buf);
    return;
  }
  if (!vxstn_validname(val->str)) {
    char* shown = jsonof(val);
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, path);
    vxstn_sb_put(&sb, " is not a valid sekreto name, so it cannot be a name "
                      "and must not be a value: ");
    vxstn_sb_put(&sb, shown);
    free(shown);
    push_str(secrets, sb.buf);
    return;
  }
  if (unbroken_run(val->str)) {
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, path);
    vxstn_sb_put(&sb, " contains an unbroken alphanumeric run of 24 or more "
                      "characters, which is not a name anybody writes");
    push_str(secrets, sb.buf);
  }
}

/* One rule about VALUES rather than keys, because the `proxy` feature
 * makes it concrete: `http://user:pass@proxy.internal:8080`. A parse
 * failure is not an error - it returns silently. */
static void userinfo(const vxstn_val* val, const char* path, vxstn_val* secrets) {
  const char* s;
  const char* p;
  const char* authority;
  const char* end;
  const char* at = NULL;
  const char* q;
  vxstn_sb sb;

  if (!vxstn_is_str(val)) {
    return;
  }
  s = val->str;

  /* ^[a-zA-Z][a-zA-Z0-9+.-]*:// */
  p = s;
  if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z'))) {
    return;
  }
  for (p++; '\0' != *p; p++) {
    if ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
        (*p >= '0' && *p <= '9') || '+' == *p || '.' == *p || '-' == *p) {
      continue;
    }
    break;
  }
  if (0 != strncmp(p, "://", 3)) {
    return;
  }

  authority = p + 3;
  end = authority;
  while ('\0' != *end && '/' != *end && '?' != *end && '#' != *end) {
    end++;
  }
  /* Everything before the LAST `@` in the authority is the userinfo. */
  for (q = authority; q < end; q++) {
    if ('@' == *q) {
      at = q;
    }
  }
  if (NULL == at || at == authority) {
    return;
  }

  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, path);
  vxstn_sb_put(&sb, " is a URL carrying userinfo, which puts a credential in "
                    "the config file; use the proxy feature's `fromEnv` "
                    "option instead (design 8.6)");
  push_str(secrets, sb.buf);
}

static bool credentialkey(const char* key) {
  vxstn_sb low;
  char* tok;
  size_t i;
  bool hit = false;

  vxstn_sb_init(&low);
  for (i = 0; '\0' != key[i]; i++) {
    char c = key[i];
    if (c >= 'A' && c <= 'Z') {
      c = (char)(c - 'A' + 'a');
    }
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
      vxstn_sb_putc(&low, c);
    }
  }
  for (i = 0; NULL != CREDENTIAL_KEYS[i]; i++) {
    if (0 == strcmp(CREDENTIAL_KEYS[i], low.buf)) {
      hit = true;
      break;
    }
  }
  free(low.buf);
  if (hit) {
    return true;
  }

  tok = vxstn_envtoken(key);
  for (i = 0; NULL != CREDENTIAL_SUFFIX[i]; i++) {
    size_t tl = strlen(tok);
    size_t sl = strlen(CREDENTIAL_SUFFIX[i]);
    if (tl >= sl && 0 == strcmp(tok + tl - sl, CREDENTIAL_SUFFIX[i])) {
      hit = true;
      break;
    }
  }
  free(tok);
  return hit;
}

/* `key` lower-cased equals `lowerlit` (which must already be lower
   case). */
static bool eqlower(const char* key, const char* lowerlit) {
  size_t i;
  for (i = 0; '\0' != key[i] && '\0' != lowerlit[i]; i++) {
    char c = key[i];
    if (c >= 'A' && c <= 'Z') {
      c = (char)(c - 'A' + 'a');
    }
    if (c != lowerlit[i]) {
      return false;
    }
  }
  return '\0' == key[i] && '\0' == lowerlit[i];
}

/* RECURSIVE OVER EVERY NESTED MAP AND LIST, not just the top level - a
 * credential one level down is the case a top-level scan misses. */
static void scan(const vxstn_val* node, const char* path, vxstn_val* secrets,
                 vxstn_val* reserved) {
  size_t i;

  if (vxstn_is_list(node)) {
    for (i = 0; i < node->len; i++) {
      char* kpath = joinindex(path, i);
      scan(node->items[i], kpath, secrets, reserved);
      free(kpath);
    }
    return;
  }
  if (vxstn_is_str(node)) {
    userinfo(node, path, secrets);
    return;
  }
  if (!vxstn_is_map(node)) {
    return;
  }

  for (i = 0; i < node->mlen; i++) {
    const char* key = node->keys[i];
    const vxstn_val* val = node->vals[i];
    char* kpath = joinpath(path, key);

    /* Design 8.6: station owns feature composition, so an
     * `options.feature` in a declarative config is a second,
     * unreconciled ordering input. */
    if (0 == strcmp("feature", key)) {
      vxstn_sb sb;
      vxstn_sb_init(&sb);
      vxstn_sb_put(&sb, kpath);
      vxstn_sb_put(&sb, " is reserved: configure features under the block's "
                        "own `feature` key, not through `options`");
      push_str(reserved, sb.buf);
      free(kpath);
      continue;
    }

    /* The one EXEMPT key, and it is matched case-insensitively because
       a config writes `Secret` as readily as `secret`. */
    if (eqlower(key, "secret")) {
      secretvalue(val, kpath, secrets);
      free(kpath);
      continue;
    }

    if (credentialkey(key)) {
      vxstn_sb sb;
      vxstn_sb_init(&sb);
      vxstn_sb_put(&sb, kpath);
      vxstn_sb_put(&sb, " is a credential-shaped key: station.json holds "
                        "secret NAMES, never values (design 5.2)");
      push_str(secrets, sb.buf);
      free(kpath);
      continue;
    }

    scan(val, kpath, secrets, reserved);
    free(kpath);
  }
}

/* Design 4.4: `$CHILD` in list mode DOES NOT VALIDATE ELEMENT 0.
 * Verified: `["a", 1]` fails at index 1, `[1]` passes, at any list
 * length. Filed upstream as voxgig/struct#113.
 *
 * It reaches THREE string lists in this shape: `policy.hosts`, and the
 * per-feature `order.before` and `order.after`. Applied where the shape
 * cannot reach, raising the same code the shape would, and PINNED IN
 * THE CORPUS so the workaround is removed deliberately when struct is
 * fixed rather than forgotten. */
static void firstelement(const vxstn_val* list, const char* path, vxstn_val* invalid) {
  vxstn_sb sb;
  char* shown;
  if (!vxstn_is_list(list) || 0 == list->len) {
    return;
  }
  if (vxstn_is_str(list->items[0])) {
    return;
  }
  shown = jsonof(list->items[0]);
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, "Expected field ");
  vxstn_sb_put(&sb, path);
  vxstn_sb_put(&sb, ".0 to be string, but found ");
  vxstn_sb_put(&sb, shape_kindof(list->items[0]));
  vxstn_sb_put(&sb, ": ");
  vxstn_sb_put(&sb, shown);
  free(shown);
  push_str(invalid, sb.buf);
}

/* The policy block's design 4.4 workarounds, in one place because they
 * are one class of gap: struct cannot check what its own defects hide.
 *
 * - `hosts`, `allow.op` and `allow.method` are `$CHILD` string lists,
 *   so element 0 escapes the shape (see firstelement above).
 * - `budget` is a map whose keys are ALL optional scalars, and struct
 *   removes an unsatisfied optional key from the spec node - so
 *   `budget: {rp: 1}` degenerates the spec into an open map and the
 *   typo passes. `allow` does not have this problem (its `$CHILD` keys
 *   stay in the spec whether or not the data carries them, keeping the
 *   map closed), and neither does `policy` itself (`hosts` anchors it);
 *   `budget` alone needs the explicit unexpected-key check, phrased as
 *   struct would phrase it. */
static const char* const BUDGET_KEYS[] = {"concurrency", "rps", NULL};

static void checkpolicy(const vxstn_val* policy, const char* path, vxstn_val* invalid) {
  const vxstn_val* allow;
  const vxstn_val* budget;
  char* p;

  if (!vxstn_is_map(policy)) {
    return;
  }

  p = joinpath(path, "hosts");
  firstelement(vxstn_getk(policy, "hosts"), p, invalid);
  free(p);

  allow = vxstn_getk(policy, "allow");
  if (vxstn_is_map(allow)) {
    p = joinpath(path, "allow.op");
    firstelement(vxstn_getk(allow, "op"), p, invalid);
    free(p);
    p = joinpath(path, "allow.method");
    firstelement(vxstn_getk(allow, "method"), p, invalid);
    free(p);
  }

  budget = vxstn_getk(policy, "budget");
  if (vxstn_is_map(budget)) {
    const char** keys;
    size_t n, i;
    vxstn_sb sb;
    bool any = false;
    keys = vxstn_sortedkeys(budget, &n);
    vxstn_sb_init(&sb);
    for (i = 0; i < n; i++) {
      size_t j;
      bool known = false;
      for (j = 0; NULL != BUDGET_KEYS[j]; j++) {
        if (0 == strcmp(BUDGET_KEYS[j], keys[i])) {
          known = true;
          break;
        }
      }
      if (known) {
        continue;
      }
      if (any) {
        vxstn_sb_put(&sb, ", ");
      }
      vxstn_sb_put(&sb, keys[i]);
      any = true;
    }
    free(keys);
    if (any) {
      vxstn_sb msg;
      vxstn_sb_init(&msg);
      vxstn_sb_put(&msg, "Unexpected keys at field ");
      vxstn_sb_put(&msg, path);
      vxstn_sb_put(&msg, ".budget: ");
      vxstn_sb_put(&msg, sb.buf);
      push_str(invalid, msg.buf);
    }
    free(sb.buf);
  }
}

/* The `$CHILD` MAP-MODE SPELLING, and why this port states it itself.
 *
 * struct's `$CHILD` installs its template across the data's keys, and
 * when the data at that level is not a map it reports the type error -
 * canonically as "Expected field profiles to be object, but found
 * list: [].", naming the FIELD. The C build vendored here names the
 * spec key instead: "Expected field profiles.`$CHILD` to be object...",
 * so the corpus's pinned substring is absent from a message that is
 * otherwise about exactly the right thing.
 *
 * Same reasoning as the design 4.4 workarounds beside it, and the same
 * remedy: produce the PINNED message here, so behaviour is identical
 * whatever struct build is vendored, and pin it in the corpus so the
 * workaround is removed deliberately rather than forgotten
 * (config#profiles-must-be-a-map, config#feature-must-be-a-map).
 *
 * A present null is NOT an error: `$CHILD` treats an absent or null
 * node as an empty map at that level, in every struct port. */
static void childmap(const vxstn_val* node, const char* path, vxstn_val* invalid) {
  vxstn_sb sb;
  char* shown;
  if (NULL == node || vxstn_is_map(node)) {
    return;
  }
  shown = jsonof(node);
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, "Expected field ");
  vxstn_sb_put(&sb, path);
  vxstn_sb_put(&sb, " to be object, but found ");
  vxstn_sb_put(&sb, shape_kindof(node));
  vxstn_sb_put(&sb, ": ");
  vxstn_sb_put(&sb, shown);
  vxstn_sb_put(&sb, ".");
  free(shown);
  push_str(invalid, sb.buf);
}

/* A feature map at any level. `station` is reserved: station composes
 * its own wrap and a config that reconfigures it is asking for a state
 * the ordering rules cannot express (design 8.4). */
static void checkfeatures_scan(const vxstn_val* f, const char* path, vxstn_val* secrets,
                               vxstn_val* reserved, vxstn_val* invalid) {
  size_t i;
  if (!vxstn_is_map(f)) {
    return;
  }
  for (i = 0; i < f->mlen; i++) {
    const char* name = f->keys[i];
    const vxstn_val* entry = f->vals[i];
    const vxstn_val* order;
    char* fpath;

    if (0 == strcmp("station", name)) {
      vxstn_sb sb;
      vxstn_sb_init(&sb);
      vxstn_sb_put(&sb, path);
      vxstn_sb_put(&sb, ".station is reserved: station composes its own wrap "
                        "and it cannot be configured from station.json");
      push_str(reserved, sb.buf);
    }

    fpath = joinpath(path, name);
    order = vxstn_is_map(entry) ? vxstn_getk(entry, "order") : NULL;
    if (vxstn_is_map(order)) {
      char* p = joinpath(fpath, "order.before");
      firstelement(vxstn_getk(order, "before"), p, invalid);
      free(p);
      p = joinpath(fpath, "order.after");
      firstelement(vxstn_getk(order, "after"), p, invalid);
      free(p);
    }
    scan(entry, fpath, secrets, reserved);
    free(fpath);
  }
}

/* The design 5.2 scans, over the parts of the grammar that hold
 * arbitrary data. Everything else is closed by construction and needs
 * no scan - and `profiles.<p>.secrets.providers` IS NOT SCANNED:
 * provider blocks legitimately carry an `auth` sub-map ({method, role}),
 * and config#twenty-sdk-fleet passes only because the scan does not
 * reach there. Collects rather than throwing - the caller owns the
 * throw order. */
static void scanconfig(const vxstn_val* cfg, vxstn_val* secrets, vxstn_val* reserved,
                       vxstn_val* invalid) {
  const vxstn_val* profiles = vxstn_getk(cfg, "profiles");
  size_t p, b, r;
  static const char* const BLOCKKEYS[] = {"api", "sdk"};

  childmap(profiles, "profiles", invalid);
  if (!vxstn_is_map(profiles)) {
    return;
  }

  for (p = 0; p < profiles->mlen; p++) {
    const vxstn_val* prof = profiles->vals[p];
    vxstn_sb pp;
    char* ppath;
    char* fpath;

    if (!vxstn_is_map(prof)) {
      continue;
    }
    vxstn_sb_init(&pp);
    vxstn_sb_put(&pp, "profiles.");
    vxstn_sb_put(&pp, profiles->keys[p]);
    ppath = pp.buf;

    fpath = joinpath(ppath, "feature");
    childmap(vxstn_getk(prof, "feature"), fpath, invalid);
    checkfeatures_scan(vxstn_getk(prof, "feature"), fpath, secrets, reserved, invalid);
    free(fpath);

    for (b = 0; b < sizeof(BLOCKKEYS) / sizeof(BLOCKKEYS[0]); b++) {
      const vxstn_val* blocks = vxstn_getk(prof, BLOCKKEYS[b]);
      char* blockspath = joinpath(ppath, BLOCKKEYS[b]);
      childmap(blocks, blockspath, invalid);
      free(blockspath);
      if (!vxstn_is_map(blocks)) {
        continue;
      }
      for (r = 0; r < blocks->mlen; r++) {
        const vxstn_val* block = blocks->vals[r];
        vxstn_sb bp;
        char* bpath;
        char* sub;

        if (!vxstn_is_map(block)) {
          continue;
        }
        vxstn_sb_init(&bp);
        vxstn_sb_put(&bp, ppath);
        vxstn_sb_putc(&bp, '.');
        vxstn_sb_put(&bp, BLOCKKEYS[b]);
        vxstn_sb_putc(&bp, '.');
        vxstn_sb_put(&bp, blocks->keys[r]);
        bpath = bp.buf;

        /* The block's own `secret` holds a NAME. vxstn_resolve_profile
         * checks it again per instance (station_secret_name); this
         * catches it at open(), for the whole file at once. */
        if (NULL != vxstn_map_get(block, "secret")) {
          sub = joinpath(bpath, "secret");
          secretvalue(vxstn_map_get(block, "secret"), sub, secrets);
          free(sub);
        }

        /* `options` is passthrough to a generated constructor, so it is
         * the one place a value can hide. */
        sub = joinpath(bpath, "options");
        scan(vxstn_getk(block, "options"), sub, secrets, reserved);
        free(sub);

        sub = joinpath(bpath, "feature");
        childmap(vxstn_getk(block, "feature"), sub, invalid);
        checkfeatures_scan(vxstn_getk(block, "feature"), sub, secrets, reserved, invalid);
        free(sub);

        sub = joinpath(bpath, "policy");
        checkpolicy(vxstn_getk(block, "policy"), sub, invalid);
        free(sub);

        free(bpath);
      }
    }

    free(ppath);
  }
}

/* `plugin` is REMOVED, not aliased (design 3.4) - a deprecated alias
 * would be a second grammar for one concept in sixteen ports. The shape
 * already rejects it as an unexpected key; this says WHAT TO RENAME,
 * because "unexpected key: plugin" alone does not, and the migration
 * for a single-instance project is exactly this one rename. Owned. */
static char* renamehint(const vxstn_val* cfg) {
  const vxstn_val* profiles = vxstn_getk(cfg, "profiles");
  vxstn_sb sb;
  bool any = false;
  size_t i;

  if (!vxstn_is_map(profiles)) {
    return vxstn_sdup("");
  }
  vxstn_sb_init(&sb);
  for (i = 0; i < profiles->mlen; i++) {
    const vxstn_val* prof = profiles->vals[i];
    if (!vxstn_is_map(prof) || NULL == vxstn_map_get(prof, "plugin")) {
      continue;
    }
    vxstn_sb_put(&sb, any ? ", profiles." : "; rename `plugin` to `sdk` in profiles.");
    vxstn_sb_put(&sb, profiles->keys[i]);
    any = true;
  }
  if (!any) {
    free(sb.buf);
    return vxstn_sdup("");
  }
  vxstn_sb_put(&sb, " - the keys are unchanged, an untagged ref IS an api slug "
                    "(design 3.4)");
  return sb.buf;
}

static char* joinlist(const vxstn_val* a, const vxstn_val* b) {
  vxstn_sb sb;
  size_t i;
  bool any = false;
  const vxstn_val* srcs[2];
  srcs[0] = a;
  srcs[1] = b;
  vxstn_sb_init(&sb);
  for (i = 0; i < 2; i++) {
    size_t j;
    for (j = 0; NULL != srcs[i] && j < srcs[i]->len; j++) {
      if (any) {
        vxstn_sb_put(&sb, "; ");
      }
      vxstn_sb_put(&sb, vxstn_strval(srcs[i]->items[j]));
      any = true;
    }
  }
  return sb.buf;
}

/* Normalize, then validate (design 4.2). Raises station_config_invalid
 * with EVERY struct error at once - an eighteen-instance config that
 * touches three of them must not die because the eighteenth has a
 * typo'd package name - then the design 5.2 scans.
 *
 * The design 4.4 workarounds are merged into the SAME error as struct's
 * own: a struct new enough to reject a first-element gap itself reports
 * a DIFFERENT spelling ("to be one of ..."), and the corpus pins the
 * explicit one - so the pinned message is produced here either way, and
 * behaviour is identical whatever struct version is vendored.
 *
 * Takes the NORMALIZED form. Handing it a raw config is the mistake
 * design 4.2 exists to prevent, so every caller goes through
 * vxstn_normalize_config first. Returns an owned copy of the input, or
 * NULL + *err. */
vxstn_val* vxstn_validate_config(const vxstn_val* normalized, vxstn_error** err) {
  vxstn_val* errs = vxstn_list();
  vxstn_val* secrets = vxstn_list();
  vxstn_val* reserved = vxstn_list();
  vxstn_val* invalid = vxstn_list();
  vxstn_val* out = NULL;

  if (NULL != err) {
    *err = NULL;
  }

  runshape(normalized, errs);
  scanconfig(normalized, secrets, reserved, invalid);

  if (0 < errs->len || 0 < invalid->len) {
    char* joined = joinlist(errs, invalid);
    char* hint = renamehint(normalized);
    vxstn_sb sb;
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, joined);
    vxstn_sb_put(&sb, hint);
    vxstn_seterr(err, "station_config_invalid", sb.buf);
    free(sb.buf);
    free(joined);
    free(hint);
  } else if (0 < reserved->len) {
    char* joined = joinlist(reserved, NULL);
    vxstn_seterr(err, "station_feature_reserved", joined);
    free(joined);
  } else if (0 < secrets->len) {
    char* joined = joinlist(secrets, NULL);
    vxstn_seterr(err, "station_config_secret", joined);
    free(joined);
  } else {
    out = vxstn_clone(normalized);
  }

  vxstn_val_free(errs);
  vxstn_val_free(secrets);
  vxstn_val_free(reserved);
  vxstn_val_free(invalid);
  return out;
}
