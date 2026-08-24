/* voxgig/station - one control surface for outbound integrations (C port).
 *
 * See voxgig_station.h for the scope statement (tier C: solo only,
 * env-only secrets, config in code) and the copy discipline (canonical
 * source: voxgig/station c/src/; vendored copy: sdkgen-station
 * .sdk/tm/c/feature/station/ - byte-identical, edit HERE first).
 *
 * THIS FILE is the core: the value model and JSON, the canonical
 * serializer, identity, the descriptor normalizer, profile resolution,
 * the event ring, the env-only broker, the instance registry, and the
 * declarative front door (design 6), which lives here because it reads
 * the station's own state. The config grammar (4), feature management
 * (8) and the factory table with the ref grammar (6.1/6.2) are the
 * other three sources beside it.
 *
 * Port of the canonical typescript/src sources. Behaviour must match,
 * case for case; the shared conformance corpus (spec/station.json, run
 * through voxgig/omni) pins the pure-contract half.
 */

#if !defined(_POSIX_C_SOURCE) && !defined(_GNU_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "voxgig_station.h"

#include "voxgig_station_int.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* =========================================================================
 * Small helpers
 * =========================================================================*/

char* vxstn_sdup(const char* s) {
  size_t n;
  char* d;
  if (NULL == s) {
    s = "";
  }
  n = strlen(s);
  d = (char*)malloc(n + 1);
  memcpy(d, s, n + 1);
  return d;
}

void vxstn_sb_init(vxstn_sb* sb) {
  sb->cap = 64;
  sb->len = 0;
  sb->buf = (char*)malloc(sb->cap);
  sb->buf[0] = '\0';
}

static void vxstn_sb_need(vxstn_sb* sb, size_t extra) {
  if (sb->len + extra + 1 > sb->cap) {
    while (sb->len + extra + 1 > sb->cap) {
      sb->cap *= 2;
    }
    sb->buf = (char*)realloc(sb->buf, sb->cap);
  }
}

void vxstn_sb_putn(vxstn_sb* sb, const char* s, size_t n) {
  vxstn_sb_need(sb, n);
  memcpy(sb->buf + sb->len, s, n);
  sb->len += n;
  sb->buf[sb->len] = '\0';
}

void vxstn_sb_put(vxstn_sb* sb, const char* s) { vxstn_sb_putn(sb, s, strlen(s)); }

void vxstn_sb_putc(vxstn_sb* sb, char c) { vxstn_sb_putn(sb, &c, 1); }

void vxstn_sb_putf(vxstn_sb* sb, const char* fmt, ...) {
  char tmp[64];
  va_list ap;
  int n;
  va_start(ap, fmt);
  n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (0 < n) {
    vxstn_sb_putn(sb, tmp, (size_t)n);
  }
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

int64_t vxstn_now_ms(void) {
  struct timespec ts;
#if defined(CLOCK_REALTIME)
  if (0 == clock_gettime(CLOCK_REALTIME, &ts)) {
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
  }
#endif
  return (int64_t)time(NULL) * 1000;
}

/* =========================================================================
 * Errors
 * =========================================================================*/

static const char* const VXSTN_CODES[] = {
  "station_no_proxy",
  "station_secret_no_value",
  "station_secret_error",
  "station_secret_name",
  "station_host_allow",
  "station_grant_expired",
  "station_wrap_order",
  "station_protocol",
  "station_no_plugin",
  "station_no_entity",
  "station_no_op",
  "station_agent_allow",
  "station_body_limit",
  "station_replay_lossy",
  "station_open_conflict",
  "station_bound_twice",

  /* Declarative config (design 6.4). Only the reference ports raise
     the config-validation codes so far (Stage 1); the catalog is
     repo-wide, so every port knows them. */
  "station_config_invalid",
  "station_config_secret",
  "station_secret_collision",
  "station_feature_reserved",

  /* Instances (design 6.4). `as` is a tag, not a free name. */
  "station_instance_api",

  /* The declarative front door (design 6.4). Availability errors are
     fatal at first use, not at open(). */
  "station_no_instance",
  "station_instance_inactive",
  "station_sdk_load",
  "station_no_factory",
  "station_factory_conflict",

  /* Features (design 8.4, 8.5). */
  "station_feature_unknown",
  "station_feature_option",
  "station_feature_order",
};

bool vxstn_known_code(const char* code) {
  size_t i;
  if (NULL == code) {
    return false;
  }
  for (i = 0; i < sizeof(VXSTN_CODES) / sizeof(VXSTN_CODES[0]); i++) {
    if (0 == strcmp(VXSTN_CODES[i], code)) {
      return true;
    }
  }
  return false;
}

vxstn_error* vxstn_error_new(const char* code, const char* msg) {
  vxstn_error* err = (vxstn_error*)calloc(1, sizeof(vxstn_error));
  vxstn_sb sb;
  err->code = vxstn_sdup(code);
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, NULL == code ? "" : code);
  vxstn_sb_put(&sb, ": ");
  vxstn_sb_put(&sb, NULL == msg ? "" : msg);
  err->message = sb.buf;
  return err;
}

void vxstn_error_free(vxstn_error* err) {
  if (NULL == err) {
    return;
  }
  free(err->code);
  free(err->message);
  free(err);
}

/* Set *out (when non-NULL) to a fresh error. */
void vxstn_seterr(vxstn_error** out, const char* code, const char* msg) {
  if (NULL != out) {
    *out = vxstn_error_new(code, msg);
  }
}

/* =========================================================================
 * Value model
 * =========================================================================*/

static vxstn_val* val_new(vxstn_kind kind) {
  vxstn_val* v = (vxstn_val*)calloc(1, sizeof(vxstn_val));
  v->kind = kind;
  return v;
}

vxstn_val* vxstn_undef(void) { return val_new(VXSTN_UNDEF); }
vxstn_val* vxstn_null(void) { return val_new(VXSTN_NULL); }

vxstn_val* vxstn_bool(bool b) {
  vxstn_val* v = val_new(VXSTN_BOOL);
  v->b = b;
  return v;
}

vxstn_val* vxstn_int(int64_t i) {
  vxstn_val* v = val_new(VXSTN_NUM);
  v->isint = true;
  v->i = i;
  v->num = (double)i;
  return v;
}

vxstn_val* vxstn_num(double n) {
  vxstn_val* v = val_new(VXSTN_NUM);
  v->num = n;
  /* An integral double within exact range keeps the integer rep, so
   * canonical printing never invents a fraction. */
  if (n == (double)(int64_t)n && -9007199254740992.0 < n && n < 9007199254740992.0) {
    v->isint = true;
    v->i = (int64_t)n;
  }
  return v;
}

vxstn_val* vxstn_str(const char* s) {
  vxstn_val* v = val_new(VXSTN_STR);
  v->str = vxstn_sdup(s);
  return v;
}

vxstn_val* vxstn_list(void) { return val_new(VXSTN_LIST); }
vxstn_val* vxstn_map(void) { return val_new(VXSTN_MAP); }

void vxstn_list_push(vxstn_val* list, vxstn_val* item) {
  if (NULL == list || VXSTN_LIST != list->kind || NULL == item) {
    vxstn_val_free(item);
    return;
  }
  if (list->len + 1 > list->cap) {
    list->cap = 0 == list->cap ? 8 : list->cap * 2;
    list->items = (vxstn_val**)realloc(list->items, list->cap * sizeof(vxstn_val*));
  }
  list->items[list->len++] = item;
}

void vxstn_map_set(vxstn_val* map, const char* key, vxstn_val* val) {
  size_t i;
  if (NULL == map || VXSTN_MAP != map->kind || NULL == key || NULL == val) {
    vxstn_val_free(val);
    return;
  }
  for (i = 0; i < map->mlen; i++) {
    if (0 == strcmp(map->keys[i], key)) {
      vxstn_val_free(map->vals[i]);
      map->vals[i] = val;
      return;
    }
  }
  if (map->mlen + 1 > map->mcap) {
    map->mcap = 0 == map->mcap ? 8 : map->mcap * 2;
    map->keys = (char**)realloc(map->keys, map->mcap * sizeof(char*));
    map->vals = (vxstn_val**)realloc(map->vals, map->mcap * sizeof(vxstn_val*));
  }
  map->keys[map->mlen] = vxstn_sdup(key);
  map->vals[map->mlen] = val;
  map->mlen++;
}

vxstn_val* vxstn_map_get(const vxstn_val* map, const char* key) {
  size_t i;
  if (NULL == map || VXSTN_MAP != map->kind || NULL == key) {
    return NULL;
  }
  for (i = 0; i < map->mlen; i++) {
    if (0 == strcmp(map->keys[i], key)) {
      return map->vals[i];
    }
  }
  return NULL;
}

vxstn_val* vxstn_list_get(const vxstn_val* list, size_t index) {
  if (NULL == list || VXSTN_LIST != list->kind || index >= list->len) {
    return NULL;
  }
  return list->items[index];
}

bool vxstn_is_map(const vxstn_val* v) { return NULL != v && VXSTN_MAP == v->kind; }
bool vxstn_is_list(const vxstn_val* v) { return NULL != v && VXSTN_LIST == v->kind; }
bool vxstn_is_str(const vxstn_val* v) { return NULL != v && VXSTN_STR == v->kind; }

bool vxstn_is_nil(const vxstn_val* v) {
  return NULL == v || VXSTN_UNDEF == v->kind || VXSTN_NULL == v->kind;
}

const char* vxstn_strval(const vxstn_val* v) {
  return vxstn_is_str(v) ? v->str : "";
}

vxstn_val* vxstn_clone(const vxstn_val* v) {
  size_t i;
  vxstn_val* out;
  if (NULL == v) {
    return vxstn_undef();
  }
  switch (v->kind) {
  case VXSTN_UNDEF:
    return vxstn_undef();
  case VXSTN_NULL:
    return vxstn_null();
  case VXSTN_BOOL:
    return vxstn_bool(v->b);
  case VXSTN_NUM:
    out = val_new(VXSTN_NUM);
    out->isint = v->isint;
    out->i = v->i;
    out->num = v->num;
    return out;
  case VXSTN_STR:
    return vxstn_str(v->str);
  case VXSTN_LIST:
    out = vxstn_list();
    for (i = 0; i < v->len; i++) {
      vxstn_list_push(out, vxstn_clone(v->items[i]));
    }
    return out;
  case VXSTN_MAP:
    out = vxstn_map();
    for (i = 0; i < v->mlen; i++) {
      vxstn_map_set(out, v->keys[i], vxstn_clone(v->vals[i]));
    }
    return out;
  }
  return vxstn_undef();
}

void vxstn_val_free(vxstn_val* v) {
  size_t i;
  if (NULL == v) {
    return;
  }
  free(v->str);
  for (i = 0; i < v->len; i++) {
    vxstn_val_free(v->items[i]);
  }
  free(v->items);
  for (i = 0; i < v->mlen; i++) {
    free(v->keys[i]);
    vxstn_val_free(v->vals[i]);
  }
  free(v->keys);
  free(v->vals);
  free(v);
}

/* Map read treating a present null as absent (the ts `null == v`
 * config-surface reads). Borrowed. */
vxstn_val* vxstn_getk(const vxstn_val* map, const char* key) {
  vxstn_val* v = vxstn_map_get(map, key);
  return vxstn_is_nil(v) ? NULL : v;
}

/* Sorted (byte order) copy of a map's key pointers; caller frees the
 * array, not the strings. */
static int cmp_keys(const void* a, const void* b) {
  return strcmp(*(const char* const*)a, *(const char* const*)b);
}

const char** vxstn_sortedkeys(const vxstn_val* map, size_t* n_out) {
  const char** keys;
  size_t i, n;
  n = vxstn_is_map(map) ? map->mlen : 0;
  keys = (const char**)malloc((0 == n ? 1 : n) * sizeof(char*));
  for (i = 0; i < n; i++) {
    keys[i] = map->keys[i];
  }
  qsort(keys, n, sizeof(char*), cmp_keys);
  *n_out = n;
  return keys;
}

/* String() of a scalar config value (descriptor normalization). Owned. */
char* vxstn_val_to_string(const vxstn_val* v) {
  vxstn_sb sb;
  if (NULL == v) {
    return vxstn_sdup("");
  }
  switch (v->kind) {
  case VXSTN_STR:
    return vxstn_sdup(v->str);
  case VXSTN_BOOL:
    return vxstn_sdup(v->b ? "true" : "false");
  case VXSTN_NUM:
    vxstn_sb_init(&sb);
    if (v->isint) {
      vxstn_sb_putf(&sb, "%lld", (long long)v->i);
    } else {
      vxstn_sb_putf(&sb, "%g", v->num);
    }
    return sb.buf;
  default:
    return vxstn_sdup("");
  }
}

/* =========================================================================
 * JSON parse (strict; null -> VXSTN_NULL)
 * =========================================================================*/

typedef struct {
  const char* text;
  size_t pos;
  size_t n;
  char* err;
} jparse;

static void jp_err(jparse* jp, const char* msg) {
  vxstn_sb sb;
  if (NULL != jp->err) {
    return;
  }
  vxstn_sb_init(&sb);
  vxstn_sb_putf(&sb, "station: invalid JSON at %lld: ", (long long)(jp->pos + 1));
  vxstn_sb_put(&sb, msg);
  jp->err = sb.buf;
}

static void jp_ws(jparse* jp) {
  while (jp->pos < jp->n) {
    char c = jp->text[jp->pos];
    if (' ' == c || '\t' == c || '\n' == c || '\r' == c) {
      jp->pos++;
    } else {
      break;
    }
  }
}

static void jp_utf8(vxstn_sb* sb, long cp) {
  char b[4];
  if (cp < 0x80) {
    b[0] = (char)cp;
    vxstn_sb_putn(sb, b, 1);
  } else if (cp < 0x800) {
    b[0] = (char)(0xC0 | (cp >> 6));
    b[1] = (char)(0x80 | (cp & 0x3F));
    vxstn_sb_putn(sb, b, 2);
  } else if (cp < 0x10000) {
    b[0] = (char)(0xE0 | (cp >> 12));
    b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    b[2] = (char)(0x80 | (cp & 0x3F));
    vxstn_sb_putn(sb, b, 3);
  } else {
    b[0] = (char)(0xF0 | (cp >> 18));
    b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    b[3] = (char)(0x80 | (cp & 0x3F));
    vxstn_sb_putn(sb, b, 4);
  }
}

static int jp_hex4(jparse* jp, long* out) {
  long v = 0;
  int i;
  for (i = 0; i < 4; i++) {
    char c;
    if (jp->pos >= jp->n) {
      return 0;
    }
    c = jp->text[jp->pos];
    v <<= 4;
    if ('0' <= c && c <= '9') {
      v |= c - '0';
    } else if ('a' <= c && c <= 'f') {
      v |= c - 'a' + 10;
    } else if ('A' <= c && c <= 'F') {
      v |= c - 'A' + 10;
    } else {
      return 0;
    }
    jp->pos++;
  }
  *out = v;
  return 1;
}

static char* jp_string(jparse* jp) {
  vxstn_sb sb;
  jp->pos++; /* opening quote */
  vxstn_sb_init(&sb);
  for (;;) {
    char c;
    if (jp->pos >= jp->n) {
      jp_err(jp, "unterminated string");
      free(sb.buf);
      return NULL;
    }
    c = jp->text[jp->pos];
    if ('"' == c) {
      jp->pos++;
      return sb.buf;
    }
    if ('\\' == c) {
      char e;
      jp->pos++;
      if (jp->pos >= jp->n) {
        jp_err(jp, "bad escape");
        free(sb.buf);
        return NULL;
      }
      e = jp->text[jp->pos];
      jp->pos++;
      if ('u' == e) {
        long cp;
        if (!jp_hex4(jp, &cp)) {
          jp_err(jp, "bad \\u escape");
          free(sb.buf);
          return NULL;
        }
        if (0xD800 <= cp && cp <= 0xDBFF && jp->pos + 1 < jp->n &&
            '\\' == jp->text[jp->pos] && 'u' == jp->text[jp->pos + 1]) {
          size_t save = jp->pos;
          long lo;
          jp->pos += 2;
          if (jp_hex4(jp, &lo) && 0xDC00 <= lo && lo <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          } else {
            jp->pos = save;
          }
        }
        jp_utf8(&sb, cp);
      } else if ('"' == e || '\\' == e || '/' == e) {
        vxstn_sb_putc(&sb, e);
      } else if ('b' == e) {
        vxstn_sb_putc(&sb, '\b');
      } else if ('f' == e) {
        vxstn_sb_putc(&sb, '\f');
      } else if ('n' == e) {
        vxstn_sb_putc(&sb, '\n');
      } else if ('r' == e) {
        vxstn_sb_putc(&sb, '\r');
      } else if ('t' == e) {
        vxstn_sb_putc(&sb, '\t');
      } else {
        jp_err(jp, "bad escape");
        free(sb.buf);
        return NULL;
      }
    } else {
      vxstn_sb_putc(&sb, c);
      jp->pos++;
    }
  }
}

static vxstn_val* jp_value(jparse* jp);

static vxstn_val* jp_number(jparse* jp) {
  size_t start = jp->pos;
  bool isint = true;
  char* buf;
  vxstn_val* out;
  if (jp->pos < jp->n && '-' == jp->text[jp->pos]) {
    jp->pos++;
  }
  while (jp->pos < jp->n && '0' <= jp->text[jp->pos] && jp->text[jp->pos] <= '9') {
    jp->pos++;
  }
  if (jp->pos < jp->n && '.' == jp->text[jp->pos]) {
    isint = false;
    jp->pos++;
    while (jp->pos < jp->n && '0' <= jp->text[jp->pos] && jp->text[jp->pos] <= '9') {
      jp->pos++;
    }
  }
  if (jp->pos < jp->n && ('e' == jp->text[jp->pos] || 'E' == jp->text[jp->pos])) {
    isint = false;
    jp->pos++;
    if (jp->pos < jp->n && ('+' == jp->text[jp->pos] || '-' == jp->text[jp->pos])) {
      jp->pos++;
    }
    while (jp->pos < jp->n && '0' <= jp->text[jp->pos] && jp->text[jp->pos] <= '9') {
      jp->pos++;
    }
  }
  if (jp->pos == start || (jp->pos == start + 1 && '-' == jp->text[start])) {
    jp_err(jp, "bad number");
    return NULL;
  }
  buf = (char*)malloc(jp->pos - start + 1);
  memcpy(buf, jp->text + start, jp->pos - start);
  buf[jp->pos - start] = '\0';
  if (isint) {
    long long i;
    if (1 == sscanf(buf, "%lld", &i)) {
      free(buf);
      return vxstn_int((int64_t)i);
    }
  }
  out = vxstn_num(strtod(buf, NULL));
  free(buf);
  return out;
}

static vxstn_val* jp_value(jparse* jp) {
  char c;
  jp_ws(jp);
  if (jp->pos >= jp->n) {
    jp_err(jp, "unexpected end");
    return NULL;
  }
  c = jp->text[jp->pos];
  if ('{' == c) {
    vxstn_val* out = vxstn_map();
    jp->pos++;
    jp_ws(jp);
    if (jp->pos < jp->n && '}' == jp->text[jp->pos]) {
      jp->pos++;
      return out;
    }
    for (;;) {
      char* key;
      vxstn_val* v;
      jp_ws(jp);
      if (jp->pos >= jp->n || '"' != jp->text[jp->pos]) {
        jp_err(jp, "expected key");
        vxstn_val_free(out);
        return NULL;
      }
      key = jp_string(jp);
      if (NULL == key) {
        vxstn_val_free(out);
        return NULL;
      }
      jp_ws(jp);
      if (jp->pos >= jp->n || ':' != jp->text[jp->pos]) {
        jp_err(jp, "expected :");
        free(key);
        vxstn_val_free(out);
        return NULL;
      }
      jp->pos++;
      v = jp_value(jp);
      if (NULL == v) {
        free(key);
        vxstn_val_free(out);
        return NULL;
      }
      vxstn_map_set(out, key, v);
      free(key);
      jp_ws(jp);
      if (jp->pos < jp->n && ',' == jp->text[jp->pos]) {
        jp->pos++;
      } else if (jp->pos < jp->n && '}' == jp->text[jp->pos]) {
        jp->pos++;
        return out;
      } else {
        jp_err(jp, "expected , or }");
        vxstn_val_free(out);
        return NULL;
      }
    }
  }
  if ('[' == c) {
    vxstn_val* out = vxstn_list();
    jp->pos++;
    jp_ws(jp);
    if (jp->pos < jp->n && ']' == jp->text[jp->pos]) {
      jp->pos++;
      return out;
    }
    for (;;) {
      vxstn_val* v = jp_value(jp);
      if (NULL == v) {
        vxstn_val_free(out);
        return NULL;
      }
      vxstn_list_push(out, v);
      jp_ws(jp);
      if (jp->pos < jp->n && ',' == jp->text[jp->pos]) {
        jp->pos++;
      } else if (jp->pos < jp->n && ']' == jp->text[jp->pos]) {
        jp->pos++;
        return out;
      } else {
        jp_err(jp, "expected , or ]");
        vxstn_val_free(out);
        return NULL;
      }
    }
  }
  if ('"' == c) {
    char* s = jp_string(jp);
    vxstn_val* out;
    if (NULL == s) {
      return NULL;
    }
    out = val_new(VXSTN_STR);
    out->str = s;
    return out;
  }
  if (jp->pos + 4 <= jp->n && 0 == strncmp(jp->text + jp->pos, "true", 4)) {
    jp->pos += 4;
    return vxstn_bool(true);
  }
  if (jp->pos + 5 <= jp->n && 0 == strncmp(jp->text + jp->pos, "false", 5)) {
    jp->pos += 5;
    return vxstn_bool(false);
  }
  if (jp->pos + 4 <= jp->n && 0 == strncmp(jp->text + jp->pos, "null", 4)) {
    jp->pos += 4;
    return vxstn_null();
  }
  return jp_number(jp);
}

vxstn_val* vxstn_parse_json(const char* text, char** errmsg) {
  jparse jp;
  vxstn_val* out;
  if (NULL != errmsg) {
    *errmsg = NULL;
  }
  jp.text = NULL == text ? "" : text;
  jp.pos = 0;
  jp.n = strlen(jp.text);
  jp.err = NULL;
  out = jp_value(&jp);
  if (NULL != out) {
    jp_ws(&jp);
    if (jp.pos < jp.n) {
      jp_err(&jp, "trailing content");
      vxstn_val_free(out);
      out = NULL;
    }
  }
  if (NULL == out) {
    if (NULL != errmsg) {
      *errmsg = NULL != jp.err ? jp.err : vxstn_sdup("station: invalid JSON");
    } else {
      free(jp.err);
    }
    return NULL;
  }
  free(jp.err);
  return out;
}

/* =========================================================================
 * Canonical serialization
 * =========================================================================*/

static void canon_escape(vxstn_sb* sb, const char* s) {
  const unsigned char* p = (const unsigned char*)s;
  for (; *p; p++) {
    unsigned char c = *p;
    switch (c) {
    case '"':
      vxstn_sb_put(sb, "\\\"");
      break;
    case '\\':
      vxstn_sb_put(sb, "\\\\");
      break;
    case '\b':
      vxstn_sb_put(sb, "\\b");
      break;
    case '\f':
      vxstn_sb_put(sb, "\\f");
      break;
    case '\n':
      vxstn_sb_put(sb, "\\n");
      break;
    case '\r':
      vxstn_sb_put(sb, "\\r");
      break;
    case '\t':
      vxstn_sb_put(sb, "\\t");
      break;
    default:
      if (c < 0x20) {
        vxstn_sb_putf(sb, "\\u%04x", (unsigned)c);
      } else {
        /* Minimal escaping: UTF-8 bytes ride through verbatim. */
        vxstn_sb_putn(sb, (const char*)p, 1);
      }
    }
  }
}

/* Shortest round-trip double, matching JSON number printing closely
 * enough for descriptor duty (integer-shaped values never come here). */
static void canon_number(vxstn_sb* sb, const vxstn_val* v) {
  char tmp[40];
  int prec;
  if (v->isint) {
    vxstn_sb_putf(sb, "%lld", (long long)v->i);
    return;
  }
  for (prec = 1; prec <= 17; prec++) {
    snprintf(tmp, sizeof(tmp), "%.*g", prec, v->num);
    if (strtod(tmp, NULL) == v->num) {
      break;
    }
  }
  vxstn_sb_put(sb, tmp);
}

static void canon_val(vxstn_sb* sb, const vxstn_val* v) {
  size_t i;
  if (NULL == v || VXSTN_UNDEF == v->kind || VXSTN_NULL == v->kind) {
    vxstn_sb_put(sb, "null");
    return;
  }
  switch (v->kind) {
  case VXSTN_BOOL:
    vxstn_sb_put(sb, v->b ? "true" : "false");
    return;
  case VXSTN_NUM:
    canon_number(sb, v);
    return;
  case VXSTN_STR:
    vxstn_sb_putc(sb, '"');
    canon_escape(sb, v->str);
    vxstn_sb_putc(sb, '"');
    return;
  case VXSTN_LIST:
    vxstn_sb_putc(sb, '[');
    for (i = 0; i < v->len; i++) {
      if (0 < i) {
        vxstn_sb_putc(sb, ',');
      }
      canon_val(sb, v->items[i]);
    }
    vxstn_sb_putc(sb, ']');
    return;
  case VXSTN_MAP: {
    size_t n = 0;
    const char** keys = vxstn_sortedkeys(v, &n);
    bool first = true;
    vxstn_sb_putc(sb, '{');
    for (i = 0; i < n; i++) {
      /* An UNDEF value means "absent": the key is skipped, matching
       * the ts serializer's undefined filter. */
      vxstn_val* item = vxstn_map_get(v, keys[i]);
      if (NULL != item && VXSTN_UNDEF == item->kind) {
        continue;
      }
      if (!first) {
        vxstn_sb_putc(sb, ',');
      }
      first = false;
      vxstn_sb_putc(sb, '"');
      canon_escape(sb, keys[i]);
      vxstn_sb_put(sb, "\":");
      canon_val(sb, item);
    }
    free(keys);
    vxstn_sb_putc(sb, '}');
    return;
  }
  default:
    vxstn_sb_put(sb, "null");
  }
}

char* vxstn_canonical(const vxstn_val* v) {
  vxstn_sb sb;
  vxstn_sb_init(&sb);
  canon_val(&sb, v);
  return sb.buf;
}

/* =========================================================================
 * Identity: envtoken / secret names
 * =========================================================================*/

char* vxstn_envtoken(const char* name) {
  vxstn_sb sb;
  const unsigned char* p;
  bool pending = false; /* a pending '_' between alnum runs */
  bool any = false;
  vxstn_sb_init(&sb);
  if (NULL == name) {
    name = "";
  }
  for (p = (const unsigned char*)name; *p; p++) {
    unsigned char c = *p;
    if ('a' <= c && c <= 'z') {
      c = (unsigned char)(c - 'a' + 'A');
    }
    if (('A' <= c && c <= 'Z') || ('0' <= c && c <= '9')) {
      if (pending && any) {
        vxstn_sb_putc(&sb, '_');
      }
      pending = false;
      any = true;
      vxstn_sb_putc(&sb, (char)c);
    } else {
      pending = true; /* runs of non-alnum collapse; edges trim */
    }
  }
  return sb.buf;
}

char* vxstn_secretname_default(const char* slug) {
  char* token = vxstn_envtoken(slug);
  vxstn_sb sb;
  char* p;
  for (p = token; *p; p++) {
    if ('A' <= *p && *p <= 'Z') {
      *p = (char)(*p - 'A' + 'a');
    }
  }
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, token);
  vxstn_sb_put(&sb, ".apikey");
  free(token);
  return sb.buf;
}

bool vxstn_validname(const char* name) {
  const char* p;
  bool seg = false; /* the current segment has at least one char */
  if (NULL == name || '\0' == name[0]) {
    return false;
  }
  for (p = name; *p; p++) {
    char c = *p;
    if ('.' == c) {
      if (!seg) {
        return false;
      }
      seg = false;
    } else if (('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || '_' == c) {
      seg = true;
    } else {
      return false;
    }
  }
  return seg;
}

char* vxstn_envkey(const char* name, vxstn_error** err) {
  vxstn_sb sb;
  const char* p;
  if (NULL != err) {
    *err = NULL;
  }
  if (!vxstn_validname(name)) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "invalid secret name: ");
    vxstn_sb_put(&msg, NULL == name ? "" : name);
    vxstn_seterr(err, "station_secret_error", msg.buf);
    free(msg.buf);
    return NULL;
  }
  vxstn_sb_init(&sb);
  for (p = name; *p; p++) {
    char c = *p;
    if ('.' == c) {
      vxstn_sb_putc(&sb, '_');
    } else if ('a' <= c && c <= 'z') {
      vxstn_sb_putc(&sb, (char)(c - 'a' + 'A'));
    } else {
      vxstn_sb_putc(&sb, c);
    }
  }
  return sb.buf;
}

char* vxstn_placeholder(const char* slug) {
  vxstn_sb sb;
  vxstn_sb_init(&sb);
  vxstn_sb_put(&sb, "[station:");
  vxstn_sb_put(&sb, NULL == slug ? "" : slug);
  vxstn_sb_putc(&sb, ']');
  return sb.buf;
}

/* =========================================================================
 * Descriptor
 * =========================================================================*/

/* Best-effort slug from a camel name, for SDKs whose embedded config
 * predates main.slug (design station.md 4 legacy sentinels). The hyphen
 * caveat is real: 'VoxgigSolardemo' -> 'voxgigsolardemo', NOT
 * 'voxgig-solardemo' - callers surface a warning event when this path
 * is taken. */
static char* legacy_slug(const char* name) {
  char* out = vxstn_sdup(name);
  char* p;
  for (p = out; *p; p++) {
    if ('A' <= *p && *p <= 'Z') {
      *p = (char)(*p - 'A' + 'a');
    }
  }
  return out;
}

vxstn_val* vxstn_normalize_descriptor(const vxstn_val* config,
                                      const vxstn_val* active_features,
                                      vxstn_val** warnings_out) {
  vxstn_val* warnings = vxstn_list();
  const vxstn_val* main_ = vxstn_getk(config, "main");
  const vxstn_val* options = vxstn_getk(config, "options");
  const vxstn_val* slugv;
  const vxstn_val* optauth;
  const vxstn_val* entdefs;
  const vxstn_val* fdefs;
  char* name;
  char* slug;
  char* version;
  char* target;
  char* envtoken;
  bool auth_active;
  vxstn_val* descriptor;
  vxstn_val* server;
  vxstn_val* auth;
  vxstn_val* entities;
  vxstn_val* features;
  const char** keys;
  size_t nkeys, i;

  name = vxstn_is_str(vxstn_getk(main_, "name")) ? vxstn_sdup(vxstn_strval(vxstn_getk(main_, "name")))
                                           : vxstn_val_to_string(vxstn_getk(main_, "name"));

  slugv = vxstn_getk(main_, "slug");
  if (NULL == slugv || (vxstn_is_str(slugv) && '\0' == slugv->str[0])) {
    vxstn_sb warn;
    slug = legacy_slug(name);
    vxstn_sb_init(&warn);
    vxstn_sb_put(&warn, "descriptor: legacy config has no main.slug; derived \"");
    vxstn_sb_put(&warn, slug);
    vxstn_sb_put(&warn, "\" from the camel name - hyphens in the original name are lost");
    {
      vxstn_val* w = val_new(VXSTN_STR);
      w->str = warn.buf;
      vxstn_list_push(warnings, w);
    }
  } else {
    slug = vxstn_val_to_string(slugv);
  }

  version = NULL == vxstn_getk(main_, "version") ? vxstn_sdup("0.0.0")
                                           : vxstn_val_to_string(vxstn_getk(main_, "version"));
  target = NULL == vxstn_getk(main_, "target") ? vxstn_sdup("unknown")
                                         : vxstn_val_to_string(vxstn_getk(main_, "target"));

  server = vxstn_list();
  {
    const vxstn_val* svr = vxstn_getk(options, "server");
    keys = vxstn_sortedkeys(svr, &nkeys);
    for (i = 0; i < nkeys; i++) {
      vxstn_val* entry = vxstn_map();
      char* value = vxstn_val_to_string(vxstn_getk(svr, keys[i]));
      vxstn_map_set(entry, "name", vxstn_str(keys[i]));
      {
        vxstn_val* vv = val_new(VXSTN_STR);
        vv->str = value;
        vxstn_map_set(entry, "value", vv);
      }
      vxstn_list_push(server, entry);
    }
    free(keys);
  }

  optauth = vxstn_getk(options, "auth");
  auth_active = NULL != optauth;
  auth = vxstn_map();
  vxstn_map_set(auth, "active", vxstn_bool(auth_active));
  vxstn_map_set(auth, "prefix",
                auth_active && NULL != vxstn_getk(optauth, "prefix")
                    ? vxstn_str(vxstn_strval(vxstn_getk(optauth, "prefix")))
                    : vxstn_str(""));
  {
    char* sn = vxstn_secretname_default(slug);
    vxstn_val* sv = val_new(VXSTN_STR);
    sv->str = sn;
    vxstn_map_set(auth, "secretname", sv);
  }

  entities = vxstn_map();
  entdefs = vxstn_getk(config, "entity");
  keys = vxstn_sortedkeys(entdefs, &nkeys);
  for (i = 0; i < nkeys; i++) {
    const char* ename = keys[i];
    const vxstn_val* e = vxstn_getk(entdefs, ename);
    vxstn_val* fields = vxstn_map();
    vxstn_val* ops = vxstn_map();
    vxstn_val* ent = vxstn_map();
    const vxstn_val* flist = vxstn_getk(e, "fields");
    const vxstn_val* opdefs = vxstn_getk(e, "op");
    const char** opkeys;
    size_t nops, j;

    if (vxstn_is_list(flist)) {
      size_t fi;
      for (fi = 0; fi < flist->len; fi++) {
        const vxstn_val* f = flist->items[fi];
        const vxstn_val* fname = vxstn_getk(f, "name");
        if (NULL != fname) {
          vxstn_val* fd = vxstn_map();
          const vxstn_val* kind = vxstn_getk(f, "kind");
          if (NULL == kind || (vxstn_is_str(kind) && '\0' == kind->str[0])) {
            kind = vxstn_getk(f, "type"); /* ts: f.kind || f.type - '' falls through */
          }
          {
            char* ks = vxstn_val_to_string(kind);
            vxstn_val* kv = val_new(VXSTN_STR);
            kv->str = ks;
            vxstn_map_set(fd, "kind", kv);
          }
          {
            char* fn = vxstn_val_to_string(fname);
            vxstn_map_set(fields, fn, fd);
            free(fn);
          }
        }
      }
    }

    opkeys = vxstn_sortedkeys(opdefs, &nops);
    for (j = 0; j < nops; j++) {
      const vxstn_val* op = vxstn_getk(opdefs, opkeys[j]);
      const vxstn_val* pdefs = vxstn_getk(op, "points");
      vxstn_val* points = vxstn_list();
      vxstn_val* opout = vxstn_map();
      if (vxstn_is_list(pdefs)) {
        size_t pi;
        for (pi = 0; pi < pdefs->len; pi++) {
          const vxstn_val* p = pdefs->items[pi];
          vxstn_val* point;
          vxstn_val* params;
          const vxstn_val* parts;
          const vxstn_val* pathv;
          const vxstn_val* sel;
          if (vxstn_is_nil(p)) {
            continue;
          }
          point = vxstn_map();
          params = vxstn_list();
          parts = vxstn_getk(p, "parts");
          if (vxstn_is_list(parts)) {
            size_t qi;
            for (qi = 0; qi < parts->len; qi++) {
              const vxstn_val* part = parts->items[qi];
              if (vxstn_is_str(part) && ':' == part->str[0]) {
                vxstn_list_push(params, vxstn_str(part->str + 1));
              }
            }
          }
          {
            char* ms = vxstn_val_to_string(vxstn_getk(p, "method"));
            vxstn_val* mv = val_new(VXSTN_STR);
            mv->str = ms;
            vxstn_map_set(point, "method", mv);
          }
          pathv = vxstn_getk(p, "orig");
          if (NULL == pathv || (vxstn_is_str(pathv) && '\0' == pathv->str[0])) {
            pathv = vxstn_getk(p, "path"); /* ts: p.orig || p.path - '' falls through */
          }
          {
            char* ps = vxstn_val_to_string(pathv);
            vxstn_val* pv = val_new(VXSTN_STR);
            pv->str = ps;
            vxstn_map_set(point, "path", pv);
          }
          vxstn_map_set(point, "params", params);
          sel = vxstn_map_get((vxstn_val*)p, "select");
          if (NULL != sel && VXSTN_UNDEF != sel->kind && VXSTN_NULL != sel->kind) {
            vxstn_map_set(point, "select", vxstn_clone(sel));
          }
          vxstn_list_push(points, point);
        }
      }
      vxstn_map_set(opout, "points", points);
      vxstn_map_set(ops, opkeys[j], opout);
    }
    free(opkeys);

    vxstn_map_set(ent, "fields", fields);
    vxstn_map_set(ent, "ops", ops);
    vxstn_map_set(entities, ename, ent);
  }
  free(keys);

  features = vxstn_list();
  fdefs = vxstn_getk(config, "feature");
  keys = vxstn_sortedkeys(fdefs, &nkeys);
  for (i = 0; i < nkeys; i++) {
    vxstn_val* entry = vxstn_map();
    const vxstn_val* fopts = vxstn_getk(active_features, keys[i]);
    const vxstn_val* activev = vxstn_getk(fopts, "active");
    const vxstn_val* fdef = vxstn_getk(fdefs, keys[i]);
    const vxstn_val* declared = vxstn_getk(fdef, "options");
    const vxstn_val* transport = vxstn_getk(fdef, "transport");
    bool active = NULL != activev && VXSTN_BOOL == activev->kind && activev->b;
    vxstn_map_set(entry, "name", vxstn_str(keys[i]));
    vxstn_map_set(entry, "active", vxstn_bool(active));

    /* Stage 5 (design 7.4): the feature row stops discarding two fields
       the SDK already embeds. `options` is the feature's own declared
       key set WITH TYPED DEFAULTS - the schema design 8.5 validates
       against - and `transport` is the role 8.4 orders by. Both are
       ADDITIVE, so descriptor v1 consumers are unaffected and the
       `descriptor` corpus section passes unchanged (its fixtures carry
       neither).

       `transport` is CARRIED rather than inferred: the obvious signal,
       an empty `hook: {}`, is wrong for station, which both wraps AND
       dispatches hooks. Until sdkgen emits it, the role checks degrade
       to nothing rather than guessing. */
    if (vxstn_is_map(declared)) {
      vxstn_map_set(entry, "options", vxstn_clone(declared));
    }
    if (NULL != transport) {
      char* role = vxstn_val_to_string(transport);
      if ('\0' != role[0]) {
        vxstn_map_set(entry, "transport", vxstn_str(role));
      }
      free(role);
    }
    vxstn_list_push(features, entry);
  }
  free(keys);

  envtoken = vxstn_envtoken(slug);

  descriptor = vxstn_map();
  vxstn_map_set(descriptor, "station", vxstn_int(1));
  {
    vxstn_val* nv = val_new(VXSTN_STR);
    nv->str = name;
    vxstn_map_set(descriptor, "name", nv);
  }
  {
    vxstn_val* sv = val_new(VXSTN_STR);
    sv->str = vxstn_sdup(slug);
    vxstn_map_set(descriptor, "slug", sv);
  }
  {
    vxstn_val* ev = val_new(VXSTN_STR);
    ev->str = envtoken;
    vxstn_map_set(descriptor, "envtoken", ev);
  }
  {
    vxstn_val* vv = val_new(VXSTN_STR);
    vv->str = version;
    vxstn_map_set(descriptor, "version", vv);
  }
  {
    vxstn_val* tv = val_new(VXSTN_STR);
    tv->str = target;
    vxstn_map_set(descriptor, "target", tv);
  }
  {
    char* base = NULL == vxstn_getk(options, "base") ? vxstn_sdup("")
                                               : vxstn_val_to_string(vxstn_getk(options, "base"));
    vxstn_val* bv = val_new(VXSTN_STR);
    bv->str = base;
    vxstn_map_set(descriptor, "base", bv);
  }
  vxstn_map_set(descriptor, "server", server);
  vxstn_map_set(descriptor, "auth", auth);
  vxstn_map_set(descriptor, "entities", entities);
  vxstn_map_set(descriptor, "features", features);

  free(slug);

  if (NULL != warnings_out) {
    *warnings_out = warnings;
  } else {
    vxstn_val_free(warnings);
  }
  return descriptor;
}

/* =========================================================================
 * Profiles
 * =========================================================================*/

char* vxstn_select_profile(const char* opt_profile) {
  const char* env;
  if (NULL != opt_profile && '\0' != opt_profile[0]) {
    return vxstn_sdup(opt_profile);
  }
  env = getenv("VOXGIG_STATION_PROFILE");
  if (NULL != env && '\0' != env[0]) {
    return vxstn_sdup(env);
  }
  return vxstn_sdup("default");
}

/* The api half of a ref is the substring before the first `$`, and an
   untagged ref IS an api slug (design 3.4). LEXICAL, and that is the
   point: under the old free-form identity which api an instance used was
   itself a merged value, so a port that got the phasing wrong silently
   picked another api's defaults. Caller frees. */
char* vxstn_refapi(const char* ref) {
  const char* at;
  size_t n;
  char* out;
  if (NULL == ref) {
    ref = "";
  }
  at = strchr(ref, '$');
  n = (NULL == at) ? strlen(ref) : (size_t)(at - ref);
  out = (char*)malloc(n + 1);
  memcpy(out, ref, n);
  out[n] = '\0';
  return out;
}

/* Shallow merge, per key, left to right - each source over the one
   before it. An overlay's `policy` REPLACES the base's entirely rather
   than merging `hosts` into it; an allowlist that widens because two
   precedence levels merged is the failure this rule prevents. */
static void merge_into(vxstn_val* out, const vxstn_val* src) {
  size_t j;
  if (!vxstn_is_map(src)) {
    return;
  }
  for (j = 0; j < src->mlen; j++) {
    vxstn_map_set(out, src->keys[j], vxstn_clone(src->vals[j]));
  }
}

/* Defaults are applied ONCE, to the fully merged instance (3.3, 4.2).
   Had the overlay block carried a synthesized `active` into the merge, a
   one-key environment override would silently re-enable an integration
   the base declared inactive.

   THE SAME TABLE vxstn_validate_config applies BEFORE the shape run
   (voxgig_station_shape.c): one table, two callers, two moments. The
   timing is the rule, so reading the table from both places is what
   keeps the two from drifting apart. */
static void apply_block_defaults(vxstn_val* merged) {
  vxstn_val* defaults = vxstn_block_defaults();
  size_t i;
  for (i = 0; i < defaults->mlen; i++) {
    if (NULL == vxstn_map_get(merged, defaults->keys[i])) {
      vxstn_map_set(merged, defaults->keys[i], vxstn_clone(defaults->vals[i]));
    }
  }
  vxstn_val_free(defaults);
}

/* Collect the sorted union of two maps' keys. Caller frees the array and
   each entry. */
static char** merged_keys(const vxstn_val* a, const vxstn_val* b,
                          size_t* count_out) {
  char** keys = NULL;
  size_t n = 0, i, j;
  const vxstn_val* srcs[2];
  srcs[0] = a;
  srcs[1] = b;
  for (j = 0; j < 2; j++) {
    const vxstn_val* m = srcs[j];
    if (!vxstn_is_map(m)) {
      continue;
    }
    for (i = 0; i < m->mlen; i++) {
      size_t k;
      int seen = 0;
      for (k = 0; k < n; k++) {
        if (0 == strcmp(keys[k], m->keys[i])) {
          seen = 1;
          break;
        }
      }
      if (!seen) {
        keys = (char**)realloc(keys, (n + 1) * sizeof(char*));
        keys[n] = vxstn_sdup(m->keys[i]);
        n++;
      }
    }
  }
  /* Insertion sort: the counts here are instance counts, not data. */
  for (i = 1; i < n; i++) {
    char* cur = keys[i];
    size_t k = i;
    while (0 < k && 0 < strcmp(keys[k - 1], cur)) {
      keys[k] = keys[k - 1];
      k--;
    }
    keys[k] = cur;
  }
  *count_out = n;
  return keys;
}

static void free_keys(char** keys, size_t n) {
  size_t i;
  for (i = 0; i < n; i++) {
    free(keys[i]);
  }
  free(keys);
}

/* A configured secret name sekreto would reject is caught at profile
   load, not first request (14 station_secret_name) - and then the DERIVED
   names are checked for uniqueness, because envtoken is LOSSY: it
   collapses any run of non-alphanumerics to `_`, so `stripe$test` and an
   untagged instance of a `stripe-test` api both derive
   `stripe_test.apikey` and would silently share one credential.

   Two instances that EXPLICITLY name one secret are not a collision -
   that is the shared-key case the api-level `secret` exists for. */
static int checksecrets(const vxstn_val* sdk, const char* profile_name,
                        vxstn_error** err) {
  size_t i, j;
  char** names = NULL;
  int* derivedf = NULL;

  for (i = 0; i < sdk->mlen; i++) {
    const vxstn_val* namev = vxstn_getk(sdk->vals[i], "secret");
    if (NULL != namev) {
      const char* name = vxstn_is_str(namev) ? namev->str : "";
      if (!vxstn_validname(name)) {
        vxstn_sb msg;
        vxstn_val* asval = vxstn_str(name);
        char* shown = vxstn_canonical(asval);
        vxstn_val_free(asval);
        vxstn_sb_init(&msg);
        vxstn_sb_put(&msg, "profile \"");
        vxstn_sb_put(&msg, profile_name);
        vxstn_sb_put(&msg, "\" sdk \"");
        vxstn_sb_put(&msg, sdk->keys[i]);
        vxstn_sb_put(&msg, "\": secret name rejected by sekreto: ");
        vxstn_sb_put(&msg, shown);
        vxstn_seterr(err, "station_secret_name", msg.buf);
        free(msg.buf);
        free(shown);
        return 0;
      }
    }
  }

  names = (char**)calloc(sdk->mlen ? sdk->mlen : 1, sizeof(char*));
  derivedf = (int*)calloc(sdk->mlen ? sdk->mlen : 1, sizeof(int));
  for (i = 0; i < sdk->mlen; i++) {
    const vxstn_val* namev = vxstn_getk(sdk->vals[i], "secret");
    const char* written = (NULL != namev && vxstn_is_str(namev)) ? namev->str : "";
    derivedf[i] = ('\0' == written[0]) ? 1 : 0;
    names[i] = derivedf[i] ? vxstn_secretname_default(sdk->keys[i])
                           : vxstn_sdup(written);
  }

  for (i = 0; i < sdk->mlen; i++) {
    for (j = 0; j < i; j++) {
      if (0 == strcmp(names[i], names[j]) && (derivedf[i] || derivedf[j])) {
        vxstn_sb msg;
        vxstn_sb_init(&msg);
        vxstn_sb_put(&msg, "profile \"");
        vxstn_sb_put(&msg, profile_name);
        vxstn_sb_put(&msg, "\": instances \"");
        vxstn_sb_put(&msg, sdk->keys[j]);
        vxstn_sb_put(&msg, "\" and \"");
        vxstn_sb_put(&msg, sdk->keys[i]);
        vxstn_sb_put(&msg, "\" both resolve to secret name \"");
        vxstn_sb_put(&msg, names[i]);
        vxstn_sb_put(&msg,
               "\", so they would share one credential; name it explicitly "
               "on each, or at the api level to share it deliberately (5.1)");
        vxstn_seterr(err, "station_secret_collision", msg.buf);
        free(msg.buf);
        free_keys(names, sdk->mlen);
        free(derivedf);
        return 0;
      }
    }
  }

  free_keys(names, sdk->mlen);
  free(derivedf);
  return 1;
}

/* Merge the base profile ('default') with the selected overlay.

   Design 3.3's total order for the two block levels, lowest first:

     base.api[<api>] + base.sdk[<ref>] + overlay.api[<api>] + overlay.sdk[<ref>]

   PROFILE SPECIFICITY OUTRANKS BLOCK SPECIFICITY, and this is ONE FLAT
   LEFT-TO-RIGHT MERGE. It must not be reorganized into "collapse each
   namespace, then put instance over api" - that lets every instance
   value beat every api value, so a production `api.stripe.policy` would
   fail to override a default profile's `sdk.stripe$test.policy`,
   silently keeping the wider allowlist in production. */
vxstn_val* vxstn_resolve_profile(const vxstn_val* config,
                                 const char* profile_name,
                                 vxstn_error** err) {
  const vxstn_val* profiles = vxstn_getk(config, "profiles");
  const vxstn_val* base;
  const vxstn_val* overlay = NULL;
  const vxstn_val* providers;
  const vxstn_val *base_api, *over_api, *base_sdk, *over_sdk;
  vxstn_val* api;
  vxstn_val* sdk;
  vxstn_val* out;
  char** keys;
  size_t nkeys, i;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == profile_name) {
    profile_name = "default";
  }

  base = vxstn_getk(profiles, "default");
  if (0 != strcmp("default", profile_name)) {
    overlay = vxstn_getk(profiles, profile_name);
  }

  /* secrets.providers replaces WHOLESALE, never merges by position
   * (design 3.5, 5.2): chain order decides which store wins, so a
   * positional merge would be actively dangerous. */
  providers = vxstn_getk(vxstn_getk(overlay, "secrets"), "providers");
  if (NULL == providers) {
    providers = vxstn_getk(vxstn_getk(base, "secrets"), "providers");
  }

  base_api = vxstn_getk(base, "api");
  over_api = vxstn_getk(overlay, "api");
  base_sdk = vxstn_getk(base, "sdk");
  over_sdk = vxstn_getk(overlay, "sdk");

  /* The api-level defaults in effect for this profile. A REPORT, not an
     input to the instance merge below. */
  api = vxstn_map();
  keys = merged_keys(base_api, over_api, &nkeys);
  for (i = 0; i < nkeys; i++) {
    vxstn_val* merged = vxstn_map();
    merge_into(merged, vxstn_map_get((vxstn_val*)base_api, keys[i]));
    merge_into(merged, vxstn_map_get((vxstn_val*)over_api, keys[i]));
    vxstn_map_set(api, keys[i], merged);
  }
  free_keys(keys, nkeys);

  /* An api block declares no instance of its own (3.1), so the ref set
     comes from the two `sdk` maps alone. */
  sdk = vxstn_map();
  keys = merged_keys(base_sdk, over_sdk, &nkeys);
  for (i = 0; i < nkeys; i++) {
    char* a = vxstn_refapi(keys[i]);
    vxstn_val* merged = vxstn_map();
    merge_into(merged, vxstn_map_get((vxstn_val*)base_api, a));
    merge_into(merged, vxstn_map_get((vxstn_val*)base_sdk, keys[i]));
    merge_into(merged, vxstn_map_get((vxstn_val*)over_api, a));
    merge_into(merged, vxstn_map_get((vxstn_val*)over_sdk, keys[i]));
    apply_block_defaults(merged);
    vxstn_map_set(sdk, keys[i], merged);
    free(a);
  }
  free_keys(keys, nkeys);

  if (!checksecrets(sdk, profile_name, err)) {
    vxstn_val_free(api);
    vxstn_val_free(sdk);
    return NULL;
  }

  out = vxstn_map();
  vxstn_map_set(out, "name", vxstn_str(profile_name));
  if (NULL != providers) {
    vxstn_map_set(out, "providers", vxstn_clone(providers));
  } else {
    vxstn_val* defaults = vxstn_list();
    vxstn_val* env_provider = vxstn_map();
    vxstn_map_set(env_provider, "kind", vxstn_str("env"));
    vxstn_list_push(defaults, env_provider);
    vxstn_map_set(out, "providers", defaults);
  }
  vxstn_map_set(out, "api", api);
  vxstn_map_set(out, "sdk", sdk);
  return out;
}

/* =========================================================================
 * URL parsing ( host-with-port, hostname, path ) - mirrors ts URL
 * semantics: host keeps a non-default port, hostname strips it, an
 * empty path reads as '/'.
 * =========================================================================*/

static void parse_url(const char* fullurl, char** host_out, char** hostname_out,
                      char** path_out) {
  const char* p = NULL == fullurl ? "" : fullurl;
  const char* scheme_end = strstr(p, "://");
  const char* authority;
  const char* auth_end;
  const char* at;
  const char* colon;
  const char* path;
  size_t alen;
  char scheme[16] = {0};
  char* hostname;
  char* host;
  char* pathstr;

  if (NULL == scheme_end) {
    *host_out = vxstn_sdup("");
    *hostname_out = vxstn_sdup("");
    *path_out = vxstn_sdup(p);
    return;
  }

  {
    size_t sn = (size_t)(scheme_end - p);
    size_t i;
    if (sn >= sizeof(scheme)) {
      sn = sizeof(scheme) - 1;
    }
    for (i = 0; i < sn; i++) {
      char c = p[i];
      scheme[i] = ('A' <= c && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
    }
  }

  authority = scheme_end + 3;
  auth_end = authority;
  while (*auth_end && '/' != *auth_end && '?' != *auth_end && '#' != *auth_end) {
    auth_end++;
  }
  at = memchr(authority, '@', (size_t)(auth_end - authority));
  if (NULL != at) {
    authority = at + 1;
  }
  alen = (size_t)(auth_end - authority);

  /* The last ':' with only digits (at least one) after it is a port
   * separator; a ']' first means an ipv6 literal with no port. */
  colon = NULL;
  {
    size_t i;
    for (i = alen; 0 < i; i--) {
      char c = authority[i - 1];
      if (':' == c) {
        bool digits = i < alen;
        size_t j;
        for (j = i; j < alen; j++) {
          if (authority[j] < '0' || '9' < authority[j]) {
            digits = false;
            break;
          }
        }
        if (digits) {
          colon = authority + i - 1;
        }
        break;
      }
      if (']' == c) {
        break;
      }
    }
  }

  if (NULL != colon && colon + 1 < authority + alen) {
    size_t hn = (size_t)(colon - authority);
    const char* port = colon + 1;
    size_t plen = alen - hn - 1;
    const char* dflt = 0 == strcmp(scheme, "http")
                           ? "80"
                           : (0 == strcmp(scheme, "https") ? "443" : "");
    hostname = (char*)malloc(hn + 1);
    memcpy(hostname, authority, hn);
    hostname[hn] = '\0';
    if (strlen(dflt) == plen && 0 == strncmp(port, dflt, plen)) {
      host = vxstn_sdup(hostname);
    } else {
      host = (char*)malloc(alen + 1);
      memcpy(host, authority, alen);
      host[alen] = '\0';
    }
  } else {
    hostname = (char*)malloc(alen + 1);
    memcpy(hostname, authority, alen);
    hostname[alen] = '\0';
    host = vxstn_sdup(hostname);
  }

  path = auth_end;
  {
    const char* path_end = path;
    while (*path_end && '?' != *path_end && '#' != *path_end) {
      path_end++;
    }
    if (path_end == path) {
      pathstr = vxstn_sdup("/");
    } else {
      size_t pn = (size_t)(path_end - path);
      pathstr = (char*)malloc(pn + 1);
      memcpy(pathstr, path, pn);
      pathstr[pn] = '\0';
    }
  }

  *host_out = host;
  *hostname_out = hostname;
  *path_out = pathstr;
}

/* =========================================================================
 * Events: a bounded ring buffer plus a live tap (design station.md 6).
 * Events never fail an operation; overflow drops oldest and the drop
 * count is visible in status().
 * =========================================================================*/

typedef struct {
  vxstn_tap_fn fn;
  void* ud;
  int id;
} vxstn_tap_entry;

typedef struct {
  vxstn_val** ring;
  size_t len;
  size_t cap;
  size_t max;
  int64_t drops;
  vxstn_tap_entry* taps;
  size_t ntaps;
  size_t captaps;
  int tapseq;
} vxstn_events_buf;

static void events_init(vxstn_events_buf* eb, size_t max) {
  memset(eb, 0, sizeof(*eb));
  eb->max = 0 == max ? 1000 : max;
}

static void events_emit(vxstn_events_buf* eb, vxstn_val* ev) {
  size_t i;
  if (eb->len + 1 > eb->cap) {
    eb->cap = 0 == eb->cap ? 16 : eb->cap * 2;
    eb->ring = (vxstn_val**)realloc(eb->ring, eb->cap * sizeof(vxstn_val*));
  }
  eb->ring[eb->len++] = ev;
  if (eb->len > eb->max) {
    vxstn_val_free(eb->ring[0]);
    memmove(eb->ring, eb->ring + 1, (eb->len - 1) * sizeof(vxstn_val*));
    eb->len--;
    eb->drops++;
  }
  /* Serialized; a tap must not longjmp (C has no catch to keep a
   * misbehaving tap from failing the operation). */
  for (i = 0; i < eb->ntaps; i++) {
    eb->taps[i].fn(eb->taps[i].ud, ev);
  }
}

static void events_destroy(vxstn_events_buf* eb) {
  size_t i;
  for (i = 0; i < eb->len; i++) {
    vxstn_val_free(eb->ring[i]);
  }
  free(eb->ring);
  free(eb->taps);
}

/* =========================================================================
 * Secrets: the broker holds resolved values privately - they never
 * enter options, events, or captures; the SDK sees only the
 * placeholder. ENV-ONLY (design station.md 2.2): no sekreto C port
 * exists, so the one provider is the process environment, read directly
 * under envkey(name). No second provider is grown here; other
 * configured provider kinds are reported at open, not silently
 * half-implemented.
 * =========================================================================*/

typedef struct {
  char* slug;
  char* value;
} vxstn_kv;

typedef struct {
  vxstn_kv* overrides; /* hoisted by the adapter (design 3.1) */
  size_t noverrides;
  vxstn_kv* cache;
  size_t ncache;
  char** held; /* every value ever held, for the exact-value scrub */
  size_t nheld;
} vxstn_broker;

static const char* kv_get(vxstn_kv* kvs, size_t n, const char* slug) {
  size_t i;
  for (i = 0; i < n; i++) {
    if (0 == strcmp(kvs[i].slug, slug)) {
      return kvs[i].value;
    }
  }
  return NULL;
}

static void kv_set(vxstn_kv** kvs, size_t* n, const char* slug, const char* value) {
  size_t i;
  for (i = 0; i < *n; i++) {
    if (0 == strcmp((*kvs)[i].slug, slug)) {
      free((*kvs)[i].value);
      (*kvs)[i].value = vxstn_sdup(value);
      return;
    }
  }
  *kvs = (vxstn_kv*)realloc(*kvs, (*n + 1) * sizeof(vxstn_kv));
  (*kvs)[*n].slug = vxstn_sdup(slug);
  (*kvs)[*n].value = vxstn_sdup(value);
  (*n)++;
}

static void broker_hold(vxstn_broker* b, const char* value) {
  b->held = (char**)realloc(b->held, (b->nheld + 1) * sizeof(char*));
  b->held[b->nheld++] = vxstn_sdup(value);
}

static void broker_hoist(vxstn_broker* b, const char* slug, const char* value) {
  kv_set(&b->overrides, &b->noverrides, slug, value);
  broker_hold(b, value);
}

/* Resolve the value for a plugin's secret name. Env-only, and the miss
 * keeps sekreto's meaning (design 5.2): an unset variable is
 * station_secret_no_value; a set-but-empty variable is a present
 * (empty) value, exactly as sekreto's env provider reads it. There is
 * no store that can "fail to answer" here, so station_secret_error is
 * reserved for malformed names. */
static const char* broker_value(vxstn_broker* b, const char* slug,
                                const char* name, vxstn_error** err) {
  const char* override_;
  const char* cached;
  char* key;
  const char* env;
  vxstn_error* kerr = NULL;

  if (NULL != err) {
    *err = NULL;
  }

  /* design 5.3's two keyings, and they are different on purpose. A
     HOISTED override belongs to the one client it was resident in, so
     it is keyed by INSTANCE. A RESOLVED VALUE belongs to the name it
     was resolved for, so the cache is keyed by SECRET NAME: several
     instances sharing one api-level `secret` then cost one lookup, and
     at 26 instances over 20 apis keying the cache by instance would
     turn one store round-trip into 26. */
  override_ = kv_get(b->overrides, b->noverrides, slug);
  if (NULL != override_) {
    return override_;
  }
  cached = kv_get(b->cache, b->ncache, name);
  if (NULL != cached) {
    return cached;
  }

  key = vxstn_envkey(name, &kerr);
  if (NULL == key) {
    if (NULL != err) {
      *err = kerr;
    } else {
      vxstn_error_free(kerr);
    }
    return NULL;
  }
  env = getenv(key);
  free(key);
  if (NULL == env) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "no store had \"");
    vxstn_sb_put(&msg, name);
    vxstn_sb_put(&msg, "\" for plugin \"");
    vxstn_sb_put(&msg, slug);
    vxstn_sb_putc(&msg, '"');
    vxstn_seterr(err, "station_secret_no_value", msg.buf);
    free(msg.buf);
    return NULL;
  }

  kv_set(&b->cache, &b->ncache, name, env);
  broker_hold(b, env);
  return kv_get(b->cache, b->ncache, name);
}

/* Exact-value scrub, deliberately WITHOUT sekreto's four-character
 * readability floor (design 7 as revised): on boundaries where the
 * promise is absolute, every held value is scrubbed whatever its
 * length. Owned result. */
static char* broker_scrub(vxstn_broker* b, const char* text) {
  char* out = vxstn_sdup(text);
  size_t i;
  for (i = 0; i < b->nheld; i++) {
    if ('\0' != b->held[i][0]) {
      char* next = replaceall(out, b->held[i], "[redacted]");
      free(out);
      out = next;
    }
  }
  return out;
}

static void broker_refresh(vxstn_broker* b) {
  size_t i;
  for (i = 0; i < b->ncache; i++) {
    free(b->cache[i].slug);
    free(b->cache[i].value);
  }
  free(b->cache);
  b->cache = NULL;
  b->ncache = 0;
}

static void broker_destroy(vxstn_broker* b) {
  size_t i;
  broker_refresh(b);
  for (i = 0; i < b->noverrides; i++) {
    free(b->overrides[i].slug);
    free(b->overrides[i].value);
  }
  free(b->overrides);
  for (i = 0; i < b->nheld; i++) {
    free(b->held[i]);
  }
  free(b->held);
}

/* =========================================================================
 * The Station
 * =========================================================================*/

/* THE REGISTRY IS KEYED BY INSTANCE NAME, not api slug (design 6.1,
   7.5). Two clients of one api is the NORMAL case now - `stripe` and
   `stripe$test` - while two bindings of ONE instance is still
   station_bound_twice. Everything downstream keys on the instance: the
   placeholder (two live instances of one api must have distinct
   placeholders or the injection seam cannot tell which credential a
   header wants), the transport wrap, and every event. `api` is what
   groups an instance with its siblings, and both ride every event. */
typedef struct {
  char* name; /* the instance ref: "stripe" or "stripe$test" */
  char* api;  /* the api slug - the descriptor's own, shared by siblings */
  vxstn_val* descriptor;
  char* rung; /* "R1" | "none" */
  void* client;
  vxstn_val* warnings; /* list of strings */
  char* secretname;    /* effective (fopt > profile block > default) */
} vxstn_plugin_entry;

/* The `vxstn_sdk` cache: one client per instance name. `create` is
   deliberately NOT cached and does not appear here. */
typedef struct {
  char* name;
  void* client;
} vxstn_client_entry;

/* An auto-assigned tag to the DECLARED instance it stands for (design
   5.3). Kept beside the registry rather than inside it, because the
   mapping exists BEFORE construction and vxstn_block_for needs it
   during registration. */
typedef struct {
  char* tag;
  char* declared;
} vxstn_alias_entry;

/* design 7.4: the per-API descriptor cache. THE DESCRIPTOR IS SHARED
   because it describes the API rather than any use of it - at 26
   instances over 20 apis that is 20 normalizations, not 26. */
typedef struct {
  char* api;
  vxstn_val* descriptor;
  vxstn_val* warnings;
} vxstn_desc_entry;

struct vxstn_station {
  vxstn_val* profile; /* { name, providers, api, sdk } */
  /* The RAW config, kept for design 8.7's provenance: the resolved
     profile has already collapsed the levels provenance has to name.
     resolveProfile reads this, never the normalized form. */
  vxstn_val* raw;
  vxstn_broker broker;
  vxstn_events_buf events;
  vxstn_plugin_entry* plugins;
  size_t nplugins;
  vxstn_client_entry* clients;
  size_t nclients;
  vxstn_alias_entry* aliases;
  size_t naliases;
  vxstn_desc_entry* descriptors;
  size_t ndescriptors;
  bool repo_scoped;
  bool require_proxy;
  bool closed;
  int64_t corr_seq;
};

static vxstn_station* AMBIENT = NULL;
static char* AMBIENT_OPTS = NULL;

/* One key for open() conflict detection: the canonical bytes of the
 * observable opts. */
static char* opts_key(const vxstn_open_opts* opts) {
  vxstn_val* m = vxstn_map();
  char* out;
  if (NULL != opts) {
    if (NULL != opts->profile) {
      vxstn_map_set(m, "profile", vxstn_str(opts->profile));
    }
    if (NULL != opts->proxy) {
      vxstn_map_set(m, "proxy", vxstn_str(opts->proxy));
    }
    if (NULL != opts->config_json) {
      vxstn_map_set(m, "config", vxstn_str(opts->config_json));
    }
    if (0 != opts->event_max) {
      vxstn_map_set(m, "event_max", vxstn_int(opts->event_max));
    }
    if (0 != opts->repo_scoped) {
      vxstn_map_set(m, "repo_scoped", vxstn_int(opts->repo_scoped));
    }
    if (opts->no_load) {
      vxstn_map_set(m, "no_load", vxstn_bool(true));
    }
  }
  out = vxstn_canonical(m);
  vxstn_val_free(m);
  return out;
}

static void station_emit(vxstn_station* st, vxstn_val* ev) {
  events_emit(&st->events, ev);
}

void vxstn_emit_warn(vxstn_station* st, const char* name, const char* warn) {
  vxstn_val* ev;
  vxstn_val* meta;
  if (NULL == st) {
    return;
  }
  ev = vxstn_map();
  vxstn_map_set(ev, "t", vxstn_int(vxstn_now_ms()));
  vxstn_map_set(ev, "kind", vxstn_str("station"));
  if (NULL != name && '\0' != name[0]) {
    char* api = vxstn_refapi(name);
    vxstn_map_set(ev, "plugin", vxstn_str(name));
    vxstn_map_set(ev, "api", vxstn_str(api));
    free(api);
  }
  meta = vxstn_map();
  vxstn_map_set(meta, "warn", vxstn_str(warn));
  vxstn_map_set(ev, "meta", meta);
  station_emit(st, ev);
}

vxstn_station* vxstn_station_new(const vxstn_open_opts* opts, vxstn_error** err) {
  vxstn_station* st;
  vxstn_val* config = NULL;
  char* profile_name;
  const char* proxy;
  vxstn_error* perr = NULL;

  if (NULL != err) {
    *err = NULL;
  }

  if (NULL != opts && NULL != opts->config_json) {
    char* jerr = NULL;
    config = vxstn_parse_json(opts->config_json, &jerr);
    if (NULL == config) {
      /* A parse failure is a config error, not a protocol one: the
         caller wrote a station.json, so say so in the vocabulary the
         rest of the config surface uses. */
      vxstn_sb msg;
      vxstn_sb_init(&msg);
      vxstn_sb_put(&msg, "config is not valid JSON: ");
      vxstn_sb_put(&msg, NULL == jerr ? "parse failed" : jerr);
      vxstn_seterr(err, "station_config_invalid", msg.buf);
      free(msg.buf);
      free(jerr);
      return NULL;
    }

    /* Normalize, then validate (design 4.2). A malformed config fails
       open() with EVERY error at once - an eighteen-instance config
       must not die because the eighteenth has a typo'd package name.

       vxstn_resolve_profile then reads the RAW config, NOT the
       normalized one: the normalized form is an input to validation and
       to nothing else, and block defaults synthesized before the
       profile merge would let a one-key overlay overwrite the base's
       `active: false` and silently re-enable a barred integration
       (design 3.3, 4.2). */
    {
      vxstn_val* normalized = vxstn_normalize_config(config);
      vxstn_error* cerr = NULL;
      vxstn_val* validated = vxstn_validate_config(normalized, &cerr);
      vxstn_val_free(normalized);
      if (NULL == validated) {
        vxstn_val_free(config);
        if (NULL != err) {
          *err = cerr;
        } else {
          vxstn_error_free(cerr);
        }
        return NULL;
      }
      vxstn_val_free(validated);
    }
  }

  profile_name = vxstn_select_profile(NULL == opts ? NULL : opts->profile);

  st = (vxstn_station*)calloc(1, sizeof(vxstn_station));
  st->profile = vxstn_resolve_profile(config, profile_name, &perr);
  st->raw = config;
  free(profile_name);
  if (NULL == st->profile) {
    vxstn_val_free(st->raw);
    free(st);
    if (NULL != err) {
      *err = perr;
    } else {
      vxstn_error_free(perr);
    }
    return NULL;
  }

  events_init(&st->events, NULL == opts ? 0 : (size_t)(0 > opts->event_max ? 0 : opts->event_max));

  proxy = (NULL != opts && NULL != opts->proxy) ? opts->proxy : "auto";
  st->require_proxy = 0 == strcmp("require", proxy);

  if (0 == strcmp("auto", proxy)) {
    /* The probe is deferred with the proxy itself; absence degrades to
     * solo with a single warning event naming the cause (design 14). */
    vxstn_emit_warn(st, NULL, "proxy absent (not found); running solo");
  }

  /* Env-only honesty (design 2.2): a chain naming stores this port
   * cannot reach gets said out loud, once, rather than silently
   * resolving from a weaker store than the profile asked for. */
  {
    const vxstn_val* providers = vxstn_map_get(st->profile, "providers");
    vxstn_sb missing;
    const char* seen[32];
    size_t nseen = 0;
    bool any = false;
    size_t i;
    vxstn_sb_init(&missing);
    if (vxstn_is_list(providers)) {
      for (i = 0; i < providers->len; i++) {
        const vxstn_val* kindv = vxstn_getk(providers->items[i], "kind");
        const char* kind = vxstn_is_str(kindv) ? kindv->str : "?";
        bool dup = false;
        size_t j;
        for (j = 0; j < nseen; j++) {
          if (0 == strcmp(seen[j], kind)) {
            dup = true;
            break;
          }
        }
        if (0 != strcmp("env", kind) && !dup) {
          if (nseen < sizeof(seen) / sizeof(seen[0])) {
            seen[nseen++] = kind;
          }
          if (any) {
            vxstn_sb_put(&missing, ", ");
          }
          vxstn_sb_put(&missing, kind);
          any = true;
        }
      }
    }
    if (any) {
      vxstn_sb warn;
      vxstn_sb_init(&warn);
      vxstn_sb_put(&warn, "c station is env-only (no sekreto c port): provider kind(s) [");
      vxstn_sb_put(&warn, missing.buf);
      vxstn_sb_put(&warn, "] are not available; secrets are read from the process "
                    "environment only (design 2.2)");
      vxstn_emit_warn(st, NULL, warn.buf);
      free(warn.buf);
    }
    free(missing.buf);
  }

  /* design 6.3: an in-code config is repo-scoped by construction - the
     application wrote it - and this tier has NO station.json file
     lookup, so there is no user-level file to distrust and no
     configScope to compute. THE EXPLICIT OPTION IS READ FIRST anyway:
     inferring before reading it is a real precedence bug, and it makes
     `repo_scoped = -1` unsettable for exactly the caller that passes a
     config in code, which is every test of the rule. */
  st->repo_scoped = (NULL != opts && 0 != opts->repo_scoped) ? (0 < opts->repo_scoped)
                                                             : true;

  /* design 5.4 item 2: `package` STAYS IN THE GRAMMAR - the corpus
     validates configs carrying it and one config file serves a polyglot
     fleet - but C has no loader, so it is not honoured here. One
     warning event per declared api, at open, once, rather than an error
     that would refuse a config another port loads happily. */
  {
    const vxstn_val* api = vxstn_map_get(st->profile, "api");
    const vxstn_val* sdk = vxstn_map_get(st->profile, "sdk");
    const vxstn_val* levels[2];
    const char* seen[64];
    size_t nseen = 0;
    size_t lv;
    levels[0] = api;
    levels[1] = sdk;
    for (lv = 0; lv < 2; lv++) {
      size_t i;
      for (i = 0; NULL != levels[lv] && i < levels[lv]->mlen; i++) {
        const vxstn_val* pkg = vxstn_getk(levels[lv]->vals[i], "package");
        char* slug;
        size_t j;
        bool dup = false;
        if (!vxstn_is_str(pkg) || '\0' == pkg->str[0]) {
          continue;
        }
        slug = vxstn_refapi(levels[lv]->keys[i]);
        for (j = 0; j < nseen; j++) {
          if (0 == strcmp(seen[j], slug)) {
            dup = true;
            break;
          }
        }
        if (dup || nseen >= sizeof(seen) / sizeof(seen[0])) {
          free(slug);
          continue;
        }
        {
          vxstn_val* ev = vxstn_map();
          vxstn_val* meta = vxstn_map();
          vxstn_sb warn;
          vxstn_sb_init(&warn);
          vxstn_sb_put(&warn, "`package` is not honoured in the c port: it has no "
                              "runtime module loading, so api \"");
          vxstn_sb_put(&warn, slug);
          vxstn_sb_put(&warn, "\" must arrive through vxstn_provide() before the "
                              "first vxstn_sdk(); everything else in this config "
                              "still applies (design 6.3)");
          vxstn_map_set(ev, "t", vxstn_int(vxstn_now_ms()));
          vxstn_map_set(ev, "kind", vxstn_str("station"));
          vxstn_map_set(ev, "plugin", vxstn_str(slug));
          vxstn_map_set(ev, "api", vxstn_str(slug));
          vxstn_map_set(meta, "warn", vxstn_str(warn.buf));
          vxstn_map_set(ev, "meta", meta);
          free(warn.buf);
          station_emit(st, ev);
        }
        /* One event per API, not per declaring block: `seen` holds the
           api halves already warned about and is freed below. */
        seen[nseen++] = slug;
      }
    }
    {
      size_t j;
      for (j = 0; j < nseen; j++) {
        free((void*)seen[j]);
      }
    }
  }

  return st;
}

vxstn_station* vxstn_open(const vxstn_open_opts* opts, vxstn_error** err) {
  char* key;
  vxstn_station* st;
  if (NULL != err) {
    *err = NULL;
  }
  key = opts_key(opts);
  if (NULL != AMBIENT) {
    if (0 != strcmp(key, AMBIENT_OPTS)) {
      vxstn_seterr(err, "station_open_conflict",
             "vxstn_open() was already called with different options");
      free(key);
      return NULL;
    }
    free(key);
    return AMBIENT;
  }
  st = vxstn_station_new(opts, err);
  if (NULL == st) {
    free(key);
    return NULL;
  }
  AMBIENT = st;
  AMBIENT_OPTS = key;
  return st;
}

vxstn_station* vxstn_current(void) { return AMBIENT; }

void vxstn_reset(void) {
  AMBIENT = NULL;
  free(AMBIENT_OPTS);
  AMBIENT_OPTS = NULL;
}

void vxstn_station_free(vxstn_station* st) {
  size_t i;
  if (NULL == st) {
    return;
  }
  if (AMBIENT == st) {
    vxstn_reset();
  }
  vxstn_val_free(st->profile);
  vxstn_val_free(st->raw);
  broker_destroy(&st->broker);
  events_destroy(&st->events);
  for (i = 0; i < st->nplugins; i++) {
    /* `descriptor` and `warnings` are BORROWED from the per-api cache
       below, which owns them: one descriptor, many instances. */
    free(st->plugins[i].name);
    free(st->plugins[i].api);
    free(st->plugins[i].rung);
    free(st->plugins[i].secretname);
  }
  free(st->plugins);
  for (i = 0; i < st->nclients; i++) {
    free(st->clients[i].name);
  }
  free(st->clients);
  for (i = 0; i < st->naliases; i++) {
    free(st->aliases[i].tag);
    free(st->aliases[i].declared);
  }
  free(st->aliases);
  for (i = 0; i < st->ndescriptors; i++) {
    free(st->descriptors[i].api);
    vxstn_val_free(st->descriptors[i].descriptor);
    vxstn_val_free(st->descriptors[i].warnings);
  }
  free(st->descriptors);
  free(st);
}

void vxstn_close(vxstn_station* st) {
  const vxstn_val* plugin;
  size_t n = 0, i;
  const char** keys;
  if (NULL == st || st->closed) {
    return;
  }
  /* Warn on profile plugin keys that matched no registered plugin - a
   * typo'd key silently configuring nothing is the worst outcome for a
   * secrets-and-policy file (design 11). */
  plugin = vxstn_map_get(st->profile, "sdk");
  keys = vxstn_sortedkeys(plugin, &n);
  for (i = 0; i < n; i++) {
    size_t j;
    bool found = false;
    for (j = 0; j < st->nplugins; j++) {
      if (0 == strcmp(st->plugins[j].name, keys[i])) {
        found = true;
        break;
      }
    }
    if (!found) {
      vxstn_sb warn;
      vxstn_sb_init(&warn);
      vxstn_sb_put(&warn, "profile plugin key \"");
      vxstn_sb_put(&warn, keys[i]);
      vxstn_sb_put(&warn, "\" matched no registered plugin");
      vxstn_emit_warn(st, NULL, warn.buf);
      free(warn.buf);
    }
  }
  free(keys);
  st->closed = true;
  if (AMBIENT == st) {
    vxstn_reset();
  }
}

/* --- registration --- */

/* By INSTANCE NAME (design 6.1): "stripe" and "stripe$test" are two
   entries of one api, and every seam below asks by the name the binding
   returned. */
static vxstn_plugin_entry* find_plugin(vxstn_station* st, const char* name) {
  size_t i;
  if (NULL == name) {
    return NULL;
  }
  for (i = 0; i < st->nplugins; i++) {
    if (0 == strcmp(st->plugins[i].name, name)) {
      return &st->plugins[i];
    }
  }
  return NULL;
}

/* The DECLARED instance an assigned tag stands for, or the name itself.
   `vxstn_create("stripe$prod")` registers under `stripe$1`, and every
   question about that client's configuration - its secret, its base,
   its egress policy - is a question about `stripe$prod`. Borrowed. */
const char* vxstn_declared_ref(vxstn_station* st, const char* name) {
  size_t i;
  if (NULL == st || NULL == name) {
    return name;
  }
  for (i = 0; i < st->naliases; i++) {
    if (0 == strcmp(st->aliases[i].tag, name)) {
      return st->aliases[i].declared;
    }
  }
  return name;
}

/* The profile block that governs an instance - its own if the profile
   declares it, otherwise its API's.

   vxstn_resolve_profile builds `profile.sdk` from the DECLARED refs
   alone ("an api block declares no instance, so the ref set comes from
   the two `sdk` maps"). That is right for a declared instance and
   leaves an IMPERATIVE one - registered with `as: "test"`, named but
   never written into config - with no block at all, so the api-level
   `secret`, `base` and most seriously `policy.hosts` did not reach it,
   and a profile that denied egress everywhere denied nothing for a
   tagged client.

   ONE RULE, ONE PLACE: registration and the transport seam both ask
   here, because their disagreeing is how the credential and the
   allowlist came apart in the first place. Borrowed; NULL when neither
   level declares anything. */
const vxstn_val* vxstn_block_for(vxstn_station* st, const char* name) {
  const vxstn_val* block;
  char* api;
  if (NULL == st) {
    return NULL;
  }
  block = vxstn_getk(vxstn_map_get(st->profile, "sdk"), vxstn_declared_ref(st, name));
  if (NULL != block) {
    return block;
  }
  api = vxstn_refapi(name);
  block = vxstn_getk(vxstn_map_get(st->profile, "api"), api);
  free(api);
  return block;
}

bool vxstn_bound(vxstn_station* st, void* client) {
  size_t i;
  if (NULL == st || NULL == client) {
    return false;
  }
  for (i = 0; i < st->nplugins; i++) {
    if (st->plugins[i].client == client) {
      return true;
    }
  }
  return false;
}

void vxstn_binding_free(vxstn_binding* b) {
  if (NULL == b) {
    return;
  }
  free(b->plugin);
  free(b->api);
  free(b->placeholder);
  free(b->secretname);
  free(b->rung);
  free(b->allow_op);
  free(b->allow_method);
  free(b);
}

/* A policy list joined with "," for the SDK's own `options.allow`, or
   NULL when the list is absent or empty. Owned. */
static char* joinstrings(const vxstn_val* list) {
  vxstn_sb sb;
  size_t i;
  if (!vxstn_is_list(list) || 0 == list->len) {
    return NULL;
  }
  vxstn_sb_init(&sb);
  for (i = 0; i < list->len; i++) {
    char* item = vxstn_val_to_string(list->items[i]);
    if (0 < i) {
      vxstn_sb_putc(&sb, ',');
    }
    vxstn_sb_put(&sb, item);
    free(item);
  }
  return sb.buf;
}

/* design 7.4: THE DESCRIPTOR IS SHARED, because it describes the api
   rather than any use of it. It is normalized ONCE PER API and every
   instance of that api holds the same value - at 26 instances over 20
   apis that is 20 normalizations, not 26, and the canonical
   serialization the proxy dedupes registrations by is computed once per
   api too.

   Normalized with NO per-instance features, so the shared value holds
   only api-stable metadata - which is what the factory table already
   does at provide time. Per-instance activation is
   vxstn_features_of()'s answer; a cache keyed by slug but built from
   the first instance's feature map would make vxstn_descriptor_of
   construction-order-dependent. Borrowed - the station owns it. */
static const vxstn_desc_entry* describe(vxstn_station* st, const vxstn_val* config) {
  const char* slug = vxstn_strval(vxstn_getk(vxstn_getk(config, "main"), "slug"));
  vxstn_desc_entry* entry;
  vxstn_val* warnings = NULL;
  size_t i;

  if ('\0' != slug[0]) {
    for (i = 0; i < st->ndescriptors; i++) {
      if (0 == strcmp(st->descriptors[i].api, slug)) {
        return &st->descriptors[i];
      }
    }
  }

  st->descriptors = (vxstn_desc_entry*)realloc(
      st->descriptors, (st->ndescriptors + 1) * sizeof(vxstn_desc_entry));
  entry = &st->descriptors[st->ndescriptors++];
  memset(entry, 0, sizeof(*entry));
  entry->descriptor = vxstn_normalize_descriptor(config, NULL, &warnings);
  entry->warnings = warnings;
  entry->api = vxstn_sdup(vxstn_strval(vxstn_map_get(entry->descriptor, "slug")));
  return entry;
}

/* One event, both identities. design 7.5: events carry BOTH `plugin`
   (the instance) and `api` (what groups its siblings) on EVERY kind -
   construction events carrying both while runtime events carried only
   one is grouping that works exactly until it is used. */
static void station_event(vxstn_station* st, const char* kind, const char* name,
                          vxstn_val* meta) {
  vxstn_val* ev = vxstn_map();
  char* api = vxstn_refapi(name);
  vxstn_map_set(ev, "t", vxstn_int(vxstn_now_ms()));
  vxstn_map_set(ev, "kind", vxstn_str(kind));
  if (NULL != name && '\0' != name[0]) {
    vxstn_map_set(ev, "plugin", vxstn_str(name));
    vxstn_map_set(ev, "api", vxstn_str(api));
  }
  free(api);
  if (NULL != meta) {
    vxstn_map_set(ev, "meta", meta);
  }
  station_emit(st, ev);
}

vxstn_binding* vxstn_register(vxstn_station* st, void* client,
                              const char* config_json,
                              const char* features_json,
                              const char* secret_opt,
                              vxstn_error** err) {
  vxstn_val* config;
  vxstn_val* features = NULL;
  const vxstn_desc_entry* shared;
  const vxstn_val* descriptor;
  const vxstn_val* auth;
  const vxstn_val* activev;
  const vxstn_val* block;
  const char* api;
  char* name;
  bool auth_active;
  const char* profile_secret = NULL;
  char* effective_secret;
  vxstn_plugin_entry* entry;
  vxstn_binding* binding;
  char* jerr = NULL;
  vxstn_error* referr = NULL;
  size_t i;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == st) {
    vxstn_seterr(err, "station_no_plugin", "no station");
    return NULL;
  }
  if (st->closed) {
    vxstn_seterr(err, "station_no_plugin", "station is closed");
    return NULL;
  }

  config = vxstn_parse_json(NULL == config_json ? "{}" : config_json, &jerr);
  if (NULL == config) {
    vxstn_seterr(err, "station_protocol", NULL == jerr ? "invalid config JSON" : jerr);
    free(jerr);
    return NULL;
  }
  if (NULL != features_json) {
    features = vxstn_parse_json(features_json, NULL);
  }

  shared = describe(st, config);
  descriptor = shared->descriptor;
  vxstn_val_free(config);

  api = vxstn_strval(vxstn_map_get(descriptor, "slug"));

  /* design 7.5: station knows the instance name before construction
     begins and passes it through the feature options - `as` is a TAG
     resolved against the api here, because the api comes from the SDK
     and is not knowable at the call site. A bare registration with no
     name falls back to the descriptor slug, which is today's behaviour
     and why the single-instance case is unchanged to the byte. */
  name = vxstn_instance_ref(api, vxstn_getk(features, "station"), &referr);
  vxstn_val_free(features);
  if (NULL == name) {
    if (NULL != err) {
      *err = referr;
    } else {
      vxstn_error_free(referr);
    }
    return NULL;
  }

  /* design 7.1: the check moves to the INSTANCE key. Two clients of one
     api is the NORMAL case now; two bindings of one instance is still
     the error it was. */
  if (NULL != find_plugin(st, name)) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "instance \"");
    vxstn_sb_put(&msg, name);
    vxstn_sb_put(&msg, "\" is already registered; binding one client twice is an "
                       "error (10.2)");
    vxstn_seterr(err, "station_bound_twice", msg.buf);
    free(msg.buf);
    free(name);
    return NULL;
  }

  auth = vxstn_map_get(descriptor, "auth");
  activev = vxstn_map_get(auth, "active");
  auth_active = NULL != activev && VXSTN_BOOL == activev->kind && activev->b;

  /* Secret name precedence: the feature option (in-code, design 9
     config.options.secret) beats the profile block, which beats the
     INSTANCE-derived default.

     design 5.1: the default takes the instance name, not the api slug -
     and the DECLARED name rather than an assigned tag, so every
     per-request client of one instance shares one broker cache entry
     (5.3). For an untagged instance the two are the same string, so the
     single-instance case is unchanged to the byte.

     The descriptor's own `auth.secretname` stays the API-level default
     and is NOT used here (7.4): one descriptor is shared by every
     instance of an api and cannot hold two instance-derived names. */
  block = vxstn_block_for(st, name);
  {
    const vxstn_val* ps = vxstn_getk(block, "secret");
    if (vxstn_is_str(ps) && '\0' != ps->str[0]) {
      profile_secret = ps->str;
    }
  }
  if (NULL != secret_opt && '\0' != secret_opt[0]) {
    effective_secret = vxstn_sdup(secret_opt);
  } else if (NULL != profile_secret) {
    effective_secret = vxstn_sdup(profile_secret);
  } else {
    effective_secret = vxstn_secretname_default(vxstn_declared_ref(st, name));
  }

  st->plugins = (vxstn_plugin_entry*)realloc(
      st->plugins, (st->nplugins + 1) * sizeof(vxstn_plugin_entry));
  entry = &st->plugins[st->nplugins++];
  memset(entry, 0, sizeof(*entry));
  entry->name = vxstn_sdup(name);
  entry->api = vxstn_sdup(api);
  /* Borrowed: the per-api cache owns the descriptor and its warnings. */
  entry->descriptor = (vxstn_val*)descriptor;
  entry->rung = vxstn_sdup(auth_active ? "R1" : "none");
  entry->client = client;
  entry->warnings = shared->warnings;
  /* STORED ON THE ENTRY and read from there at the transport seam, with
     NO FALLBACK: re-deriving it there is how a tagged instance with no
     explicit `secret` reads `stripe.apikey` where registration recorded
     `stripe_test.apikey`. */
  entry->secretname = effective_secret;

  for (i = 0; NULL != entry->warnings && i < entry->warnings->len; i++) {
    vxstn_val* meta = vxstn_map();
    vxstn_map_set(meta, "warn", vxstn_str(vxstn_strval(entry->warnings->items[i])));
    station_event(st, "station", name, meta);
  }
  {
    vxstn_val* meta = vxstn_map();
    vxstn_map_set(meta, "name",
                  vxstn_str(vxstn_strval(vxstn_map_get(descriptor, "name"))));
    vxstn_map_set(meta, "version",
                  vxstn_str(vxstn_strval(vxstn_map_get(descriptor, "version"))));
    vxstn_map_set(meta, "rung", vxstn_str(entry->rung));
    station_event(st, "construct", name, meta);
  }

  binding = (vxstn_binding*)calloc(1, sizeof(vxstn_binding));
  binding->plugin = vxstn_sdup(name);
  binding->api = vxstn_sdup(api);
  /* design 7.2: two live instances of one api MUST have distinct
     placeholders, or the injection seam cannot tell which credential a
     header wants. */
  binding->placeholder = auth_active ? vxstn_placeholder(name) : NULL;
  binding->secretname = auth_active ? vxstn_sdup(effective_secret) : NULL;
  binding->rung = vxstn_sdup(entry->rung);

  /* design 16, the solo half: the POLICY ALLOWLIST is enforcement, not
     a default, so it wins on exactly the keys it sets. The DECISION is
     here (the library owns every decision); the adapter applies the two
     strings to the SDK's own `options.allow` at binding time, on both
     entry paths, because both come through here. */
  {
    const vxstn_val* allow = vxstn_getk(vxstn_getk(block, "policy"), "allow");
    if (vxstn_is_map(allow)) {
      binding->allow_op = joinstrings(vxstn_getk(allow, "op"));
      binding->allow_method = joinstrings(vxstn_getk(allow, "method"));
    }
  }

  free(name);
  return binding;
}

/* --- middleware seams --- */

bool vxstn_require_proxy(vxstn_station* st) {
  return NULL != st && st->require_proxy;
}

const vxstn_val* vxstn_profile_sdk(vxstn_station* st, const char* name) {
  if (NULL == st || NULL == name) {
    return NULL;
  }
  return vxstn_getk(vxstn_map_get(st->profile, "sdk"), name);
}

bool vxstn_host_allowed(vxstn_station* st, const char* name,
                        const char* fullurl, bool* has_policy) {
  /* THROUGH vxstn_block_for, not the sdk map directly: an imperative
     instance - named with `as` but never written into config - has no
     block of its own, and reading only `profile.sdk` left it with no
     `policy.hosts` at all, so a profile that denied egress everywhere
     denied nothing for a tagged client. */
  const vxstn_val* pp = vxstn_block_for(st, name);
  const vxstn_val* hosts = vxstn_getk(vxstn_getk(pp, "policy"), "hosts");
  char* host;
  char* hostname;
  char* path;
  bool allowed = false;
  size_t i;

  if (NULL != has_policy) {
    *has_policy = false;
  }
  if (!vxstn_is_list(hosts)) {
    return true;
  }
  if (NULL != has_policy) {
    *has_policy = true;
  }

  parse_url(fullurl, &host, &hostname, &path);
  for (i = 0; i < hosts->len; i++) {
    if (vxstn_is_str(hosts->items[i]) && 0 == strcmp(hosts->items[i]->str, hostname)) {
      allowed = true;
      break;
    }
  }
  free(host);
  free(hostname);
  free(path);
  return allowed;
}

const char* vxstn_rung(vxstn_station* st, const char* slug) {
  vxstn_plugin_entry* entry = NULL == st ? NULL : find_plugin(st, slug);
  return NULL == entry ? NULL : entry->rung;
}

const char* vxstn_secret_value(vxstn_station* st, const char* name,
                               vxstn_error** err) {
  vxstn_plugin_entry* entry;
  if (NULL != err) {
    *err = NULL;
  }
  entry = NULL == st ? NULL : find_plugin(st, name);
  if (NULL == entry) {
    vxstn_seterr(err, "station_no_plugin", "unknown instance");
    return NULL;
  }
  /* The effective name is READ FROM THE REGISTRY ENTRY, with NO
     FALLBACK: re-deriving it here is how a tagged instance with no
     explicit `secret` reads `stripe.apikey` where registration recorded
     `stripe_test.apikey`. */
  return broker_value(&st->broker, name, entry->secretname, err);
}

void vxstn_hoist(vxstn_station* st, const char* name, const char* value) {
  vxstn_val* meta;
  if (NULL == st || NULL == name || NULL == value) {
    return;
  }
  broker_hoist(&st->broker, name, value);
  meta = vxstn_map();
  vxstn_map_set(meta, "warn",
                vxstn_str("a resident credential was hoisted into the broker and "
                          "replaced by the placeholder; prefer configuring the "
                          "secret name and letting the environment resolve it"));
  station_event(st, "station", name, meta);
}

char* vxstn_next_corr(vxstn_station* st) {
  vxstn_sb sb;
  vxstn_sb_init(&sb);
  vxstn_sb_putf(&sb, "c%lld", (long long)(NULL == st ? 0 : ++st->corr_seq));
  return sb.buf;
}

const char* vxstn_outcome(bool has_result, bool has_err, bool ok) {
  if (!has_result) {
    return "unknown";
  }
  if (has_err || !ok) {
    return "err";
  }
  return "ok";
}

vxstn_error* vxstn_wrap_order_check(const char* const* names, size_t n) {
  /* Strays named "base" are excluded: the generated C make_feature
   * FALLS BACK to an inert base feature for unknown names, and a base
   * feature has a no-op init - it can never wrap or record the
   * transport - so the guard keeps its actual meaning: nothing that
   * could wrap sits between the base transport and station. */
  long self_at = -1;
  long test_at = -1;
  long expected;
  long at = 0;
  size_t i;

  for (i = 0; i < n; i++) {
    const char* name = NULL == names[i] ? "" : names[i];
    if (0 == strcmp("base", name)) {
      continue;
    }
    if (0 > self_at && 0 == strcmp("station", name)) {
      self_at = at;
    }
    if (0 > test_at && 0 == strcmp("test", name)) {
      test_at = at;
    }
    at++;
  }

  expected = 0 > test_at ? 0 : test_at + 1;
  if (self_at != expected) {
    vxstn_sb msg;
    vxstn_error* err;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "station must init immediately after the base transport; "
                 "feature order is [");
    for (i = 0; i < n; i++) {
      if (0 < i) {
        vxstn_sb_put(&msg, ", ");
      }
      vxstn_sb_put(&msg, NULL == names[i] ? "" : names[i]);
    }
    vxstn_sb_putc(&msg, ']');
    err = vxstn_error_new("station_wrap_order", msg.buf);
    free(msg.buf);
    return err;
  }
  return NULL;
}

/* --- event emission --- */

/* design 7.5: BOTH identities on EVERY kind - `plugin` is the instance
   the event came from and `api` is what groups it with its siblings.
   Construction events carrying both while runtime events carried only
   one is grouping that works exactly until it is used. */
static void ev_common(vxstn_val* ev, int64_t t, const char* kind,
                      const char* name, const char* corr) {
  vxstn_map_set(ev, "t", vxstn_int(t));
  vxstn_map_set(ev, "kind", vxstn_str(kind));
  if (NULL != name && '\0' != name[0]) {
    char* api = vxstn_refapi(name);
    vxstn_map_set(ev, "plugin", vxstn_str(name));
    vxstn_map_set(ev, "api", vxstn_str(api));
    free(api);
  }
  if (NULL != corr && '\0' != corr[0]) {
    vxstn_map_set(ev, "corr", vxstn_str(corr));
  }
}

void vxstn_emit_http(vxstn_station* st, const char* slug, const char* corr,
                     const char* method, const char* fullurl,
                     int64_t status, int64_t started_ms, int64_t bytes) {
  vxstn_val* ev;
  vxstn_val* http;
  char* host;
  char* hostname;
  char* path;
  if (NULL == st) {
    return;
  }
  parse_url(fullurl, &host, &hostname, &path);
  ev = vxstn_map();
  ev_common(ev, started_ms, "http", slug, corr);
  http = vxstn_map();
  vxstn_map_set(http, "method",
                vxstn_str(NULL == method || '\0' == method[0] ? "GET" : method));
  {
    vxstn_val* hv = val_new(VXSTN_STR);
    hv->str = host;
    vxstn_map_set(http, "host", hv);
  }
  {
    vxstn_val* pv = val_new(VXSTN_STR);
    pv->str = path;
    vxstn_map_set(http, "path", pv);
  }
  vxstn_map_set(http, "status", vxstn_int(status));
  vxstn_map_set(http, "durationMs", vxstn_int(vxstn_now_ms() - started_ms));
  vxstn_map_set(http, "bytes", vxstn_int(bytes));
  vxstn_map_set(ev, "http", http);
  free(hostname);
  station_emit(st, ev);
}

void vxstn_emit_err(vxstn_station* st, const char* slug, const char* corr,
                    const char* code, const char* message) {
  vxstn_val* ev;
  vxstn_val* errv;
  char* scrubbed;
  if (NULL == st) {
    return;
  }
  ev = vxstn_map();
  ev_common(ev, vxstn_now_ms(), "error", slug, corr);
  errv = vxstn_map();
  if (NULL != code && '\0' != code[0]) {
    vxstn_map_set(errv, "code", vxstn_str(code));
  }
  /* The scrub keeps an upstream echo of a credential out of the event
   * stream (design 7 as revised: exact-value, no length floor). */
  scrubbed = broker_scrub(&st->broker, NULL == message ? "" : message);
  {
    vxstn_val* mv = val_new(VXSTN_STR);
    mv->str = scrubbed;
    vxstn_map_set(errv, "message", mv);
  }
  vxstn_map_set(ev, "err", errv);
  station_emit(st, ev);
}

void vxstn_emit_op(vxstn_station* st, const char* slug, const char* corr,
                   const char* entity, const char* op, const char* outcome,
                   int64_t duration_ms) {
  vxstn_val* ev;
  vxstn_val* opv;
  if (NULL == st) {
    return;
  }
  ev = vxstn_map();
  ev_common(ev, vxstn_now_ms(), "op", slug, corr);
  opv = vxstn_map();
  vxstn_map_set(opv, "entity", vxstn_str(NULL == entity ? "" : entity));
  vxstn_map_set(opv, "op", vxstn_str(NULL == op ? "" : op));
  vxstn_map_set(opv, "outcome", vxstn_str(NULL == outcome ? "" : outcome));
  vxstn_map_set(opv, "durationMs", vxstn_int(duration_ms));
  vxstn_map_set(ev, "op", opv);
  station_emit(st, ev);
}

/* --- the query/observe surface --- */

vxstn_val* vxstn_events(vxstn_station* st) {
  vxstn_val* out = vxstn_list();
  size_t i;
  if (NULL == st) {
    return out;
  }
  for (i = 0; i < st->events.len; i++) {
    vxstn_list_push(out, vxstn_clone(st->events.ring[i]));
  }
  return out;
}

int vxstn_tap(vxstn_station* st, vxstn_tap_fn fn, void* ud) {
  vxstn_events_buf* eb;
  if (NULL == st || NULL == fn) {
    return -1;
  }
  eb = &st->events;
  if (eb->ntaps + 1 > eb->captaps) {
    eb->captaps = 0 == eb->captaps ? 4 : eb->captaps * 2;
    eb->taps = (vxstn_tap_entry*)realloc(eb->taps,
                                         eb->captaps * sizeof(vxstn_tap_entry));
  }
  eb->taps[eb->ntaps].fn = fn;
  eb->taps[eb->ntaps].ud = ud;
  eb->taps[eb->ntaps].id = ++eb->tapseq;
  eb->ntaps++;
  return eb->tapseq;
}

void vxstn_untap(vxstn_station* st, int tap_id) {
  vxstn_events_buf* eb;
  size_t i;
  if (NULL == st) {
    return;
  }
  eb = &st->events;
  for (i = 0; i < eb->ntaps; i++) {
    if (eb->taps[i].id == tap_id) {
      memmove(eb->taps + i, eb->taps + i + 1,
              (eb->ntaps - i - 1) * sizeof(vxstn_tap_entry));
      eb->ntaps--;
      return;
    }
  }
}

vxstn_val* vxstn_status(vxstn_station* st) {
  vxstn_val* out = vxstn_map();
  vxstn_val* plugins = vxstn_list();
  vxstn_val* events = vxstn_map();
  size_t i;
  vxstn_map_set(out, "mode", vxstn_str("solo"));
  vxstn_map_set(out, "profile",
                vxstn_str(NULL == st
                              ? ""
                              : vxstn_strval(vxstn_map_get(st->profile, "name"))));
  if (NULL != st) {
    for (i = 0; i < st->nplugins; i++) {
      vxstn_val* p = vxstn_map();
      /* Truncation is a PRESENTATION decision and it belongs here, in
         status(): name, api, the retained `slug` (equal to the api, and
         what `slug` always meant on this row), and the rung. */
      vxstn_map_set(p, "name", vxstn_str(st->plugins[i].name));
      vxstn_map_set(p, "api", vxstn_str(st->plugins[i].api));
      vxstn_map_set(p, "slug", vxstn_str(st->plugins[i].api));
      vxstn_map_set(p, "rung", vxstn_str(st->plugins[i].rung));
      vxstn_list_push(plugins, p);
    }
  }
  vxstn_map_set(out, "plugins", plugins);
  vxstn_map_set(events, "buffered", vxstn_int(NULL == st ? 0 : (int64_t)st->events.len));
  vxstn_map_set(events, "dropped", vxstn_int(NULL == st ? 0 : st->events.drops));
  vxstn_map_set(out, "events", events);
  /* Env-only, stated where an operator will read it (design 2.2). */
  vxstn_map_set(out, "secrets", vxstn_str("env-only"));
  return out;
}

vxstn_val* vxstn_plugins(vxstn_station* st) {
  vxstn_val* out = vxstn_list();
  size_t i;
  if (NULL == st) {
    return out;
  }
  /* One entry per LIVE INSTANCE, and EXHAUSTIVE: auto-tagged entries
     are NOT collapsed here, because inspection, health reporting and
     cleanup all need to enumerate the clients vxstn_create produced,
     which is exactly when you most want them. */
  for (i = 0; i < st->nplugins; i++) {
    vxstn_val* p = vxstn_map();
    vxstn_map_set(p, "name", vxstn_str(st->plugins[i].name));
    vxstn_map_set(p, "api", vxstn_str(st->plugins[i].api));
    /* Retained: it is the api, which is what `slug` always meant here,
       and dropping it would break every consumer for no gain while the
       two are equal for untagged instances. */
    vxstn_map_set(p, "slug", vxstn_str(st->plugins[i].api));
    vxstn_map_set(p, "descriptor", vxstn_clone(st->plugins[i].descriptor));
    vxstn_map_set(p, "rung", vxstn_str(st->plugins[i].rung));
    vxstn_map_set(p, "secretname", vxstn_str(st->plugins[i].secretname));
    vxstn_map_set(p, "warnings", vxstn_clone(st->plugins[i].warnings));
    vxstn_list_push(out, p);
  }
  return out;
}

vxstn_val* vxstn_descriptor_of(vxstn_station* st, const char* slug,
                               vxstn_error** err) {
  vxstn_plugin_entry* entry;
  if (NULL != err) {
    *err = NULL;
  }
  entry = NULL == st ? NULL : find_plugin(st, slug);
  if (NULL == entry) {
    vxstn_sb msg;
    size_t i;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "unknown plugin \"");
    vxstn_sb_put(&msg, NULL == slug ? "" : slug);
    vxstn_sb_put(&msg, "\"; known: [");
    if (NULL != st) {
      for (i = 0; i < st->nplugins; i++) {
        if (0 < i) {
          vxstn_sb_put(&msg, ", ");
        }
        vxstn_sb_put(&msg, st->plugins[i].name);
      }
    }
    vxstn_sb_putc(&msg, ']');
    vxstn_seterr(err, "station_no_plugin", msg.buf);
    free(msg.buf);
    return NULL;
  }
  return vxstn_clone(entry->descriptor);
}

char* vxstn_canonical_descriptor(vxstn_station* st, const char* slug,
                                 vxstn_error** err) {
  vxstn_val* d = vxstn_descriptor_of(st, slug, err);
  char* out;
  if (NULL == d) {
    return NULL;
  }
  out = vxstn_canonical(d);
  vxstn_val_free(d);
  return out;
}

char* vxstn_redact(vxstn_station* st, const char* text) {
  if (NULL == st) {
    return vxstn_sdup(text);
  }
  return broker_scrub(&st->broker, NULL == text ? "" : text);
}

void vxstn_refresh_secrets(vxstn_station* st) {
  if (NULL != st) {
    broker_refresh(&st->broker);
  }
}

/* =========================================================================
 * The declarative front door (design station.md 6)
 *
 * "Write it once in station.json, get it where you need it." The
 * instance table comes from the resolved profile, the CONSTRUCTOR comes
 * from the factory table (voxgig_station_factory.c), and everything
 * between them - the feature merge, the order, the design 8.5 check,
 * the options - is composed here.
 *
 * THE C DIVERGENCE, stated once: there is no loader (design 5.4). An
 * api reaches the table through vxstn_provide and nothing else, and
 * `package` is warned about at open rather than imported. Everything
 * else in design 6 is here.
 * =========================================================================*/

static void alias_set(vxstn_station* st, const char* tag, const char* declared) {
  size_t i;
  for (i = 0; i < st->naliases; i++) {
    if (0 == strcmp(st->aliases[i].tag, tag)) {
      free(st->aliases[i].declared);
      st->aliases[i].declared = vxstn_sdup(declared);
      return;
    }
  }
  st->aliases = (vxstn_alias_entry*)realloc(
      st->aliases, (st->naliases + 1) * sizeof(vxstn_alias_entry));
  st->aliases[st->naliases].tag = vxstn_sdup(tag);
  st->aliases[st->naliases].declared = vxstn_sdup(declared);
  st->naliases++;
}

static void* client_get(vxstn_station* st, const char* name) {
  size_t i;
  for (i = 0; i < st->nclients; i++) {
    if (0 == strcmp(st->clients[i].name, name)) {
      return st->clients[i].client;
    }
  }
  return NULL;
}

static void client_set(vxstn_station* st, const char* name, void* client) {
  st->clients = (vxstn_client_entry*)realloc(
      st->clients, (st->nclients + 1) * sizeof(vxstn_client_entry));
  st->clients[st->nclients].name = vxstn_sdup(name);
  st->clients[st->nclients].client = client;
  st->nclients++;
}

/* Inverted binding (design 3.1): the plain options map a generated
   constructor already accepts, carrying the activation entry and the
   instance name station resolved before construction began.
   `instance` is OPTIONAL AND LEADING, so an existing
   vxstn_options(st, NULL, extra) call is unchanged.

   The station HANDLE does not ride the map, because a C value tree
   holds JSON and not pointers: the generated station feature binds to
   the ambient instance (vxstn_current) or to a handle the host gave it,
   which is what design 3.1 already says about C. Owned. */
vxstn_val* vxstn_options(vxstn_station* st, const char* instance,
                         const vxstn_val* extra) {
  vxstn_val* out = vxstn_is_map(extra) ? vxstn_clone(extra) : vxstn_map();
  const vxstn_val* infeature = vxstn_getk(extra, "feature");
  vxstn_val* fmap = vxstn_is_map(infeature) ? vxstn_clone(infeature) : vxstn_map();
  const vxstn_val* prior = vxstn_getk(fmap, "station");
  vxstn_val* entry = vxstn_is_map(prior) ? vxstn_clone(prior) : vxstn_map();
  (void)st;

  vxstn_map_set(entry, "active", vxstn_bool(true));
  if (NULL != instance && '\0' != instance[0]) {
    vxstn_map_set(entry, "instance", vxstn_str(instance));
  }
  vxstn_map_set(fmap, "station", entry);
  vxstn_map_set(out, "feature", fmap);
  return out;
}

/* Every DECLARED instance (design 6.1), sorted by name - a different
   question from vxstn_plugins(), and the answers differ routinely: a
   lazily-started instance is active and not yet live. Owned. */
vxstn_val* vxstn_instances(vxstn_station* st) {
  vxstn_val* out = vxstn_list();
  const vxstn_val* sdk;
  const char** names;
  size_t n, i;

  if (NULL == st) {
    return out;
  }
  sdk = vxstn_map_get(st->profile, "sdk");
  names = vxstn_sortedkeys(sdk, &n);
  for (i = 0; i < n; i++) {
    const vxstn_val* block = vxstn_map_get(sdk, names[i]);
    const vxstn_val* activev = vxstn_map_get(block, "active");
    const vxstn_plugin_entry* live = find_plugin(st, names[i]);
    char* api = vxstn_refapi(names[i]);
    vxstn_val* row = vxstn_map();
    vxstn_map_set(row, "name", vxstn_str(names[i]));
    vxstn_map_set(row, "api", vxstn_str(api));
    /* `active: false` means BARRED FROM RUNNING - a declaration that
       stays in the file and here while being refused a client. */
    vxstn_map_set(row, "active",
                  vxstn_bool(!(NULL != activev && VXSTN_BOOL == activev->kind &&
                               !activev->b)));
    vxstn_map_set(row, "live", vxstn_bool(NULL != live));
    vxstn_map_set(row, "rung", vxstn_str(NULL == live ? "none" : live->rung));
    vxstn_map_set(row, "block", vxstn_clone(block));
    vxstn_list_push(out, row);
    free(api);
  }
  free(names);
  return out;
}

/* The merged, ordered feature set for one instance, WITH PROVENANCE
   (design 8.7): which config level set each value. Provenance is the
   half that makes a fleet view usable rather than merely correct - at
   26 instances "why is retry off here" is the question, and a merged
   map alone cannot answer it.

   Returns { ordered: [name...], merged, from }, owned, or NULL + *err
   (station_feature_order) when the order cannot be resolved. */
vxstn_val* vxstn_features_of(vxstn_station* st, const char* name, vxstn_error** err) {
  char* api;
  const vxstn_val* profiles;
  const vxstn_val* base;
  const vxstn_val* overlay = NULL;
  const char* pname;
  vxstn_val* sources;
  vxstn_val* from = vxstn_map();
  vxstn_val* merged;
  const vxstn_val* budget;
  vxstn_val* fororder;
  vxstn_val* ordered;
  vxstn_val* names;
  vxstn_val* out;
  vxstn_error* perr;
  char* levels[6];
  size_t i, j, k;

  if (NULL != err) {
    *err = NULL;
  }
  api = vxstn_refapi(name);
  pname = NULL == st ? "default" : vxstn_strval(vxstn_map_get(st->profile, "name"));
  profiles = NULL == st ? NULL : vxstn_getk(st->raw, "profiles");
  base = vxstn_getk(profiles, "default");
  if (0 != strcmp("default", pname)) {
    overlay = vxstn_getk(profiles, pname);
  }

  /* One label per source, in design 3.3's order. */
  levels[0] = vxstn_sdup("default.feature");
  levels[1] = vxstn_sdup("default.api");
  levels[2] = vxstn_sdup("default.sdk");
  for (i = 0; i < 3; i++) {
    static const char* const TAIL[3] = {".feature", ".api", ".sdk"};
    vxstn_sb sb;
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, pname);
    vxstn_sb_put(&sb, TAIL[i]);
    levels[3 + i] = sb.buf;
  }

  sources = vxstn_feature_sources(base, overlay, api, name);

  /* LAST WRITER PER (feature, key) WINS, and the level that wrote it is
     what `from` records. */
  for (i = 0; i < sources->len && i < 6; i++) {
    const vxstn_val* src = sources->items[i];
    if (!vxstn_is_map(src)) {
      continue;
    }
    for (j = 0; j < src->mlen; j++) {
      const vxstn_val* entry = src->vals[j];
      vxstn_val* keys;
      if (!vxstn_is_map(entry)) {
        continue;
      }
      keys = vxstn_map_get(from, src->keys[j]);
      if (!vxstn_is_map(keys)) {
        keys = vxstn_map();
        vxstn_map_set(from, src->keys[j], keys);
      }
      for (k = 0; k < entry->mlen; k++) {
        vxstn_map_set(keys, entry->keys[k], vxstn_str(levels[i]));
      }
    }
  }

  merged = vxstn_merge_features(sources);
  vxstn_val_free(sources);
  for (i = 0; i < 6; i++) {
    free(levels[i]);
  }

  /* design 16's policy budget: rps/concurrency ceilings ride "the SDK
     `ratelimit` feature, configured by station". Composed HERE, into
     the merged map every consumer reads, rather than patched in at
     construction alone - so vxstn_build orders it with the ordinary
     constraint-and-band rules, vxstn_check's 8.5 pass catches a budget
     on an SDK with no ratelimit feature as station_feature_unknown
     rather than a setting that quietly did nothing, and the fleet view
     answers "is ratelimit on?" truthfully.

     `rps` maps to the token bucket's refill `rate` (per second - the
     same unit); `concurrency` to its capacity `burst`, the number of
     requests that can be in flight from a full bucket. POLICY WINS over
     a `feature.ratelimit` config entry on the keys it sets - it is
     enforcement, not a default - and other tuning keys survive beside
     it. */
  budget = vxstn_getk(vxstn_getk(vxstn_block_for(st, name), "policy"), "budget");
  if (vxstn_is_map(budget)) {
    const vxstn_val* prior = vxstn_map_get(merged, "ratelimit");
    vxstn_val* entry = vxstn_is_map(prior) ? vxstn_clone(prior) : vxstn_map();
    vxstn_val* keys = vxstn_map_get(from, "ratelimit");
    const vxstn_val* rps = vxstn_getk(budget, "rps");
    const vxstn_val* concurrency = vxstn_getk(budget, "concurrency");
    if (!vxstn_is_map(keys)) {
      keys = vxstn_map();
      vxstn_map_set(from, "ratelimit", keys);
    }
    vxstn_map_set(entry, "active", vxstn_bool(true));
    vxstn_map_set(keys, "active", vxstn_str("policy.budget"));
    if (NULL != rps) {
      vxstn_map_set(entry, "rate", vxstn_clone(rps));
      vxstn_map_set(keys, "rate", vxstn_str("policy.budget"));
    }
    if (NULL != concurrency) {
      vxstn_map_set(entry, "burst", vxstn_clone(concurrency));
      vxstn_map_set(keys, "burst", vxstn_str("policy.budget"));
    }
    vxstn_map_set(merged, "ratelimit", entry);
  }

  /* THE IMPLICIT STATION ENTRY, added for ORDERING ONLY. `station` is
     never in `merged` - feature.station is reserved and rejected at
     validation (8.4) - so without it vxstn_check_pin finds no station
     row and is a PERMANENT NO-OP: a constraint like
     `retry.order.after: "station"` would be treated as vacuous rather
     than rejected, and the reported order would omit the one feature
     whose position is supposedly pinned. `merged` itself stays the
     user's own merge result. */
  fororder = vxstn_clone(merged);
  {
    vxstn_val* stationentry = vxstn_map();
    vxstn_map_set(stationentry, "active", vxstn_bool(true));
    vxstn_map_set(fororder, "station", stationentry);
  }
  ordered = vxstn_resolve_order(fororder, err);
  vxstn_val_free(fororder);
  free(api);
  if (NULL == ordered) {
    vxstn_val_free(merged);
    vxstn_val_free(from);
    return NULL;
  }
  perr = vxstn_check_pin(ordered);
  if (NULL != perr) {
    if (NULL != err) {
      *err = perr;
    } else {
      vxstn_error_free(perr);
    }
    vxstn_val_free(ordered);
    vxstn_val_free(merged);
    vxstn_val_free(from);
    return NULL;
  }

  names = vxstn_list();
  for (i = 0; i < ordered->len; i++) {
    vxstn_list_push(names,
                    vxstn_str(vxstn_strval(vxstn_map_get(ordered->items[i], "name"))));
  }
  vxstn_val_free(ordered);

  out = vxstn_map();
  vxstn_map_set(out, "ordered", names);
  vxstn_map_set(out, "merged", merged);
  vxstn_map_set(out, "from", from);
  return out;
}

/* The fleet feature view: instance x feature, effective options, and
   which config level set each (design 8.7).

   The filter is either a STRING - shorthand for "this instance or this
   api", loose - or a map { instance?, api?, feature? }. Only the map
   form can express the question the view exists for: {feature:
   "debug"}, "is debug on anywhere?", the one that is twenty greps
   today. Owned. */
vxstn_val* vxstn_features(vxstn_station* st, const vxstn_val* filter) {
  vxstn_val* out = vxstn_list();
  vxstn_val* rows;
  const char* want_instance = NULL;
  const char* want_api = NULL;
  const char* want_feature = NULL;
  bool loose = false;
  size_t i;

  if (NULL == st) {
    return out;
  }
  if (vxstn_is_str(filter)) {
    want_instance = filter->str;
    want_api = filter->str;
    loose = true;
  } else if (vxstn_is_map(filter)) {
    const vxstn_val* v = vxstn_getk(filter, "instance");
    want_instance = vxstn_is_str(v) ? v->str : NULL;
    v = vxstn_getk(filter, "api");
    want_api = vxstn_is_str(v) ? v->str : NULL;
    v = vxstn_getk(filter, "feature");
    want_feature = vxstn_is_str(v) ? v->str : NULL;
  }

  rows = vxstn_instances(st);
  for (i = 0; i < rows->len; i++) {
    const char* name = vxstn_strval(vxstn_map_get(rows->items[i], "name"));
    const char* api = vxstn_strval(vxstn_map_get(rows->items[i], "api"));
    vxstn_val* resolved;
    vxstn_val* row;

    if (loose) {
      if (NULL != want_instance && 0 != strcmp(name, want_instance) &&
          0 != strcmp(api, want_api)) {
        continue;
      }
    } else {
      if (NULL != want_instance && 0 != strcmp(name, want_instance) &&
          0 != strcmp(api, want_instance)) {
        continue;
      }
      if (NULL != want_api && 0 != strcmp(api, want_api)) {
        continue;
      }
    }

    resolved = vxstn_features_of(st, name, NULL);
    if (NULL == resolved) {
      continue;
    }

    /* `feature` filters the ROWS, not the instances: an instance that
       does not carry the named feature is not part of the answer, and
       the rows that remain are narrowed to it, so the view answers
       "where is debug on, and with what" rather than "here is
       everything, go and look". */
    if (NULL != want_feature) {
      const vxstn_val* merged = vxstn_map_get(resolved, "merged");
      const vxstn_val* hit = vxstn_map_get(merged, want_feature);
      vxstn_val* narrowed;
      vxstn_val* onemerged;
      vxstn_val* onefrom;
      const vxstn_val* ordered;
      const vxstn_val* fromall;
      size_t j;
      if (NULL == hit) {
        vxstn_val_free(resolved);
        continue;
      }
      narrowed = vxstn_list();
      ordered = vxstn_map_get(resolved, "ordered");
      for (j = 0; NULL != ordered && j < ordered->len; j++) {
        if (0 == strcmp(want_feature, vxstn_strval(ordered->items[j]))) {
          vxstn_list_push(narrowed, vxstn_str(want_feature));
        }
      }
      onemerged = vxstn_map();
      vxstn_map_set(onemerged, want_feature, vxstn_clone(hit));
      onefrom = vxstn_map();
      fromall = vxstn_map_get(vxstn_map_get(resolved, "from"), want_feature);
      vxstn_map_set(onefrom, want_feature,
                    vxstn_is_map(fromall) ? vxstn_clone(fromall) : vxstn_map());
      vxstn_val_free(resolved);
      resolved = vxstn_map();
      vxstn_map_set(resolved, "ordered", narrowed);
      vxstn_map_set(resolved, "merged", onemerged);
      vxstn_map_set(resolved, "from", onefrom);
    }

    row = vxstn_map();
    vxstn_map_set(row, "instance", vxstn_str(name));
    vxstn_map_set(row, "api", vxstn_str(api));
    vxstn_map_set(row, "ordered", vxstn_clone(vxstn_map_get(resolved, "ordered")));
    vxstn_map_set(row, "merged", vxstn_clone(vxstn_map_get(resolved, "merged")));
    vxstn_map_set(row, "from", vxstn_clone(vxstn_map_get(resolved, "from")));
    vxstn_val_free(resolved);
    vxstn_list_push(out, row);
  }
  vxstn_val_free(rows);
  return out;
}

/* The lowest positive integer tag not already taken, by a LIVE instance
   or a DECLARED one.

   THE REGISTRY ALONE IS NOT ENOUGH: a profile may declare `stripe$1`,
   and until something constructs it the registry says false - so
   vxstn_create("stripe$prod") would take that identity, vxstn_instances
   would report the declared `stripe$1` as live with the wrong client,
   and a later vxstn_sdk("stripe$1") would fail station_bound_twice
   against a binding that was never its own. Declaration reserves the
   name whether or not it has been built. Owned. */
char* vxstn_autotag(vxstn_station* st, const char* name) {
  char* api = vxstn_refapi(name);
  const vxstn_val* sdk = NULL == st ? NULL : vxstn_map_get(st->profile, "sdk");
  long n;
  for (n = 1;; n++) {
    vxstn_sb sb;
    vxstn_sb_init(&sb);
    vxstn_sb_put(&sb, api);
    vxstn_sb_putc(&sb, '$');
    vxstn_sb_putf(&sb, "%ld", n);
    if (NULL == find_plugin(st, sb.buf) && NULL == vxstn_map_get(sdk, sb.buf)) {
      free(api);
      return sb.buf;
    }
    free(sb.buf);
  }
}

/* design 6.2's paths, in order of preference - and in C there are TWO,
   not three: the registered factory, then the error. THE MESSAGE NAMES
   ONLY THE REMEDIES THIS PORT OFFERS, and says that `package` is not
   honoured here: a message telling a C user to set `api.<slug>.package`
   is a message that sends them down a road with no end. Borrowed, or
   NULL + *err. */
const vxstn_factory* vxstn_resolve_factory(vxstn_station* st, const char* api,
                                           const vxstn_val* block,
                                           vxstn_error** err) {
  const vxstn_factory* direct = vxstn_factory_for(api);
  vxstn_sb msg;
  (void)st;
  (void)block;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL != direct) {
    return direct;
  }

  vxstn_sb_init(&msg);
  vxstn_sb_put(&msg, "no factory for api \"");
  vxstn_sb_put(&msg, NULL == api ? "" : api);
  vxstn_sb_put(&msg, "\"; link the generated package and call vxstn_provide(\"");
  vxstn_sb_put(&msg, NULL == api ? "" : api);
  vxstn_sb_put(&msg, "\", ...) before the first vxstn_sdk() - the c port has no "
                     "runtime module loading, so `api.");
  vxstn_sb_put(&msg, NULL == api ? "" : api);
  vxstn_sb_put(&msg, ".package` is not honoured here (design 6.3)");
  vxstn_seterr(err, "station_no_factory", msg.buf);
  free(msg.buf);
  return NULL;
}

/* The shared construction path behind vxstn_sdk and vxstn_create.
   `as` is the ASSIGNED tag (vxstn_create's) or NULL. */
static void* build(vxstn_station* st, const char* name, const char* as,
                   const vxstn_val* overrides, vxstn_error** err) {
  const vxstn_val* sdk;
  const vxstn_val* block;
  const vxstn_val* activev;
  const vxstn_factory* entry;
  vxstn_val* resolved;
  vxstn_val* faults;
  vxstn_val* ordered;
  vxstn_val* composed;
  vxstn_val* fmap;
  vxstn_val* opts;
  vxstn_val* options;
  char* api;
  void* client;
  size_t i;

  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == st || st->closed) {
    vxstn_seterr(err, "station_no_plugin", "station is closed");
    return NULL;
  }

  sdk = vxstn_map_get(st->profile, "sdk");
  block = vxstn_map_get(sdk, name);
  if (NULL == block) {
    const char** declared;
    size_t n;
    vxstn_sb msg;
    declared = vxstn_sortedkeys(sdk, &n);
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "no declared instance \"");
    vxstn_sb_put(&msg, NULL == name ? "" : name);
    vxstn_sb_put(&msg, "\"; declared: [");
    for (i = 0; i < n; i++) {
      vxstn_sb_put(&msg, 0 == i ? "" : ", ");
      vxstn_sb_put(&msg, declared[i]);
    }
    vxstn_sb_put(&msg, "]");
    vxstn_seterr(err, "station_no_instance", msg.buf);
    free(msg.buf);
    free(declared);
    return NULL;
  }

  activev = vxstn_map_get(block, "active");
  if (NULL != activev && VXSTN_BOOL == activev->kind && !activev->b) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "instance \"");
    vxstn_sb_put(&msg, name);
    vxstn_sb_put(&msg, "\" is declared with `active: false`, which bars it from "
                       "running while keeping it visible in instances()");
    vxstn_seterr(err, "station_instance_inactive", msg.buf);
    free(msg.buf);
    return NULL;
  }

  api = vxstn_refapi(name);
  entry = vxstn_resolve_factory(st, api, block, err);
  free(api);
  if (NULL == entry) {
    return NULL;
  }

  resolved = vxstn_features_of(st, name, err);
  if (NULL == resolved) {
    return NULL;
  }

  /* design 8.5 VALIDATES HERE, not only in vxstn_check. The schema
     arrives with the factory, so the moment a factory is resolved is
     the first moment validation is possible - and running it in
     check() alone left production vxstn_sdk silently ignoring an
     unknown option like `retry.retires`. One call here closes it,
     because EVERY path to a constructor comes through this line. */
  faults = vxstn_check_features(vxstn_map_get(resolved, "merged"), entry->descriptor);
  if (0 < faults->len) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    for (i = 0; i < faults->len; i++) {
      vxstn_sb_put(&msg, 0 == i ? "" : "; ");
      vxstn_sb_put(&msg, vxstn_strval(vxstn_map_get(faults->items[i], "message")));
    }
    vxstn_seterr(err, vxstn_strval(vxstn_map_get(faults->items[0], "code")), msg.buf);
    free(msg.buf);
    vxstn_val_free(faults);
    vxstn_val_free(resolved);
    return NULL;
  }
  vxstn_val_free(faults);

  /* design 8.4: compose the merged map into the ORDERED form and hand
     it to the constructor. Station's own entry is composed AFTER the
     user merge and always wins, which is why `station` is dropped here
     and re-added by vxstn_options: a config file that can switch off
     the component reading it is not a surface, it is a trap.
     feature.station is already station_feature_reserved at validation,
     so this is the second half of one rule rather than a second rule. */
  ordered = vxstn_resolve_order(vxstn_map_get(resolved, "merged"), err);
  if (NULL == ordered) {
    vxstn_val_free(resolved);
    return NULL;
  }
  composed = vxstn_compose_features(ordered);
  vxstn_val_free(ordered);

  fmap = vxstn_map();
  for (i = 0; i < composed->len; i++) {
    const vxstn_val* row = composed->items[i];
    const char* fname = vxstn_strval(vxstn_map_get(row, "name"));
    vxstn_val* body = vxstn_map();
    size_t k;
    if (0 == strcmp("station", fname)) {
      continue;
    }
    for (k = 0; k < row->mlen; k++) {
      if (0 == strcmp("name", row->keys[k])) {
        continue;
      }
      vxstn_map_set(body, row->keys[k], vxstn_clone(row->vals[k]));
    }
    vxstn_map_set(fmap, fname, body);
  }
  vxstn_val_free(composed);

  opts = vxstn_map();
  {
    const vxstn_val* blockopts = vxstn_getk(block, "options");
    const vxstn_val* base = vxstn_getk(block, "base");
    size_t k;
    for (k = 0; vxstn_is_map(blockopts) && k < blockopts->mlen; k++) {
      vxstn_map_set(opts, blockopts->keys[k], vxstn_clone(blockopts->vals[k]));
    }
    if (NULL != base) {
      vxstn_map_set(opts, "base", vxstn_clone(base));
    }
    for (k = 0; vxstn_is_map(overrides) && k < overrides->mlen; k++) {
      if (0 == strcmp("feature", overrides->keys[k])) {
        continue;
      }
      vxstn_map_set(opts, overrides->keys[k], vxstn_clone(overrides->vals[k]));
    }
    {
      const vxstn_val* overfeature = vxstn_getk(overrides, "feature");
      for (k = 0; vxstn_is_map(overfeature) && k < overfeature->mlen; k++) {
        vxstn_map_set(fmap, overfeature->keys[k], vxstn_clone(overfeature->vals[k]));
      }
    }
    vxstn_map_set(opts, "feature", fmap);
  }

  /* THE ALIAS IS RECORDED, NOT THE FIELDS (design 5.3). Carrying the
     declared `secret` through the feature options and stopping there
     leaves `policy`, `base` and everything else behind, so an
     auto-tagged client silently loses its declared instance's HOSTS
     ALLOWLIST and falls back to the wider api-level one. Recording what
     the tag STANDS FOR is one rule that every lookup already goes
     through. Only when the tag was ASSIGNED: a caller naming its own is
     naming an instance, not aliasing one. */
  if (NULL != as && 0 != strcmp(as, name)) {
    alias_set(st, as, name);
  }

  /* NO `extend` SEAM IN C. The dynamic ports carry the adapter on
     `extend` so that an SDK generated BEFORE the station feature still
     gets bound; a C SDK has no runtime composition to carry it with, so
     the declarative path requires a regenerated SDK that carries
     feature/station.c - which is the same requirement the imperative
     path already has here. The activation entry below is what that
     feature reads. */
  options = vxstn_options(st, NULL == as ? name : as, opts);
  vxstn_val_free(opts);
  vxstn_val_free(resolved);

  /* The instance name reaches the adapter the same way it does on the
     imperative path, so registration has one spelling (design 7.5). */
  client = entry->construct(options, entry->ud);
  vxstn_val_free(options);
  return client;
}

/* The instance, constructed on first call and CACHED: same name, same
   object. That caching is what makes "get it where you need it" a real
   instruction - call it in a request handler, in a worker, in a test,
   and the first call pays construction while the rest are a lookup.
   SYNCHRONOUS, like every other seam in this port. */
void* vxstn_sdk(vxstn_station* st, const char* name, vxstn_error** err) {
  void* cached;
  void* client;
  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == st || NULL == name) {
    vxstn_seterr(err, "station_no_plugin", "no station");
    return NULL;
  }
  cached = client_get(st, name);
  if (NULL != cached) {
    return cached;
  }
  client = build(st, name, NULL, NULL, err);
  if (NULL == client) {
    return NULL;
  }
  client_set(st, name, client);
  return client;
}

/* An UNCACHED client from the same resolved config plus overrides, for
   the case that genuinely wants a distinct one - a per-request
   credential scope, a test double. Deliberately the longer name.

   It registers under an AUTO-ASSIGNED TAG, because registration is per
   instance and station_bound_twice fires on a second binding of one
   name: a second vxstn_create("stripe") would otherwise fail, which is
   exactly the per-request case this exists for. The SECRET NAME does
   not follow the assigned tag - it resolves from the DECLARED instance
   the tag was assigned under, so every client of one instance shares
   one broker cache entry (design 5.3). */
void* vxstn_create(vxstn_station* st, const char* name, const vxstn_val* overrides,
                   vxstn_error** err) {
  char* as;
  void* client;
  if (NULL != err) {
    *err = NULL;
  }
  if (NULL == st || NULL == name) {
    vxstn_seterr(err, "station_no_plugin", "no station");
    return NULL;
  }
  as = vxstn_autotag(st, name);
  client = build(st, name, as, overrides, err);
  free(as);
  return client;
}

/* Eagerly validate and construct every ACTIVE declared instance - for
   CI (design 6.6). The point is to turn availability errors, which are
   deliberately deferred to first use, into ONE failure at a moment
   somebody is watching. Returns { ok: [name...], failed: [{name, code,
   message}] }, owned. */
vxstn_val* vxstn_check(vxstn_station* st) {
  vxstn_val* out = vxstn_map();
  vxstn_val* ok = vxstn_list();
  vxstn_val* failed = vxstn_list();
  vxstn_val* rows;
  size_t i;

  if (NULL == st) {
    vxstn_map_set(out, "ok", ok);
    vxstn_map_set(out, "failed", failed);
    return out;
  }

  rows = vxstn_instances(st);
  for (i = 0; i < rows->len; i++) {
    const char* name = vxstn_strval(vxstn_map_get(rows->items[i], "name"));
    const char* api = vxstn_strval(vxstn_map_get(rows->items[i], "api"));
    const vxstn_val* activev = vxstn_map_get(rows->items[i], "active");
    const vxstn_factory* entry;
    vxstn_error* err = NULL;
    vxstn_val* resolved;

    if (NULL != activev && VXSTN_BOOL == activev->kind && !activev->b) {
      continue;
    }

    /* design 8.5 runs FIRST and needs no construction: the schema
       arrives with the factory, not with a live client, so a feature
       typo is a CI failure rather than a setting that quietly did
       nothing in production. */
    entry = vxstn_factory_for(api);
    resolved = vxstn_features_of(st, name, &err);
    if (NULL == resolved) {
      vxstn_val* row = vxstn_map();
      vxstn_map_set(row, "name", vxstn_str(name));
      vxstn_map_set(row, "code", vxstn_str(NULL == err ? "" : err->code));
      vxstn_map_set(row, "message", vxstn_str(NULL == err ? "" : err->message));
      vxstn_list_push(failed, row);
      vxstn_error_free(err);
      continue;
    }
    if (NULL != entry) {
      vxstn_val* faults =
          vxstn_check_features(vxstn_map_get(resolved, "merged"), entry->descriptor);
      if (0 < faults->len) {
        vxstn_sb msg;
        vxstn_val* row = vxstn_map();
        size_t j;
        vxstn_sb_init(&msg);
        for (j = 0; j < faults->len; j++) {
          vxstn_sb_put(&msg, 0 == j ? "" : "; ");
          vxstn_sb_put(&msg, vxstn_strval(vxstn_map_get(faults->items[j], "message")));
        }
        vxstn_map_set(row, "name", vxstn_str(name));
        vxstn_map_set(row, "code",
                      vxstn_str(vxstn_strval(vxstn_map_get(faults->items[0], "code"))));
        vxstn_map_set(row, "message", vxstn_str(msg.buf));
        free(msg.buf);
        vxstn_list_push(failed, row);
        vxstn_val_free(faults);
        vxstn_val_free(resolved);
        continue;
      }
      vxstn_val_free(faults);
    }
    vxstn_val_free(resolved);

    if (NULL == vxstn_sdk(st, name, &err)) {
      vxstn_val* row = vxstn_map();
      vxstn_map_set(row, "name", vxstn_str(name));
      vxstn_map_set(row, "code", vxstn_str(NULL == err ? "" : err->code));
      vxstn_map_set(row, "message", vxstn_str(NULL == err ? "" : err->message));
      vxstn_list_push(failed, row);
      vxstn_error_free(err);
      continue;
    }
    vxstn_list_push(ok, vxstn_str(name));
  }
  vxstn_val_free(rows);

  vxstn_map_set(out, "ok", ok);
  vxstn_map_set(out, "failed", failed);
  return out;
}

/* Batch-resolve secrets (design 5.5). With no argument it warms the
   ACTIVE declared instances only, because reaching for a credential
   belonging to a disabled integration is the wrong default;
   vxstn_warm(st, names) warms exactly what it is given, inactive
   included, because an explicit name is an explicit request.

   NO ASYNC IDIOM IN C, so this resolves SERIALLY over the DEDUPLICATED
   secret names rather than concurrently - the deduplication is the half
   that matters here, since the broker's cache is keyed by secret name
   and several instances sharing one api-level `secret` must cost one
   read, not several. README.md says so.

   THE REGISTRY IS THE AUTHORITY: a name nobody declared or registered
   is a MISS, not a lookup - a wider fallback would let a typo like
   `stripe$prodd` derive a secret name, call the provider, and report a
   nonexistent instance `warmed` off a shared api-level credential.
   Returns { warmed, missed }, both sorted. Owned. */
vxstn_val* vxstn_warm(vxstn_station* st, const vxstn_val* names) {
  vxstn_val* out = vxstn_map();
  vxstn_val* warmed = vxstn_list();
  vxstn_val* missed = vxstn_list();
  vxstn_val* wanted = vxstn_list();
  vxstn_val* plan = vxstn_map(); /* secret name -> [instance name...] */
  size_t i, j;

  if (NULL == st) {
    vxstn_map_set(out, "warmed", warmed);
    vxstn_map_set(out, "missed", missed);
    vxstn_val_free(wanted);
    vxstn_val_free(plan);
    return out;
  }

  if (vxstn_is_list(names)) {
    for (i = 0; i < names->len; i++) {
      vxstn_list_push(wanted, vxstn_clone(names->items[i]));
    }
  } else {
    vxstn_val* rows = vxstn_instances(st);
    for (i = 0; i < rows->len; i++) {
      const vxstn_val* activev = vxstn_map_get(rows->items[i], "active");
      if (NULL != activev && VXSTN_BOOL == activev->kind && !activev->b) {
        continue;
      }
      vxstn_list_push(wanted,
                      vxstn_str(vxstn_strval(vxstn_map_get(rows->items[i], "name"))));
    }
    vxstn_val_free(rows);
  }

  for (i = 0; i < wanted->len; i++) {
    const char* name = vxstn_strval(wanted->items[i]);
    const vxstn_plugin_entry* live = find_plugin(st, name);
    const vxstn_val* block = vxstn_getk(vxstn_map_get(st->profile, "sdk"), name);
    char* secretname;
    vxstn_val* group;

    if (NULL == live && NULL == block) {
      vxstn_list_push(missed, vxstn_str(name));
      continue;
    }
    if (NULL != live) {
      secretname = vxstn_sdup(live->secretname);
    } else {
      const vxstn_val* written = vxstn_getk(vxstn_block_for(st, name), "secret");
      secretname = (vxstn_is_str(written) && '\0' != written->str[0])
                       ? vxstn_sdup(written->str)
                       : vxstn_secretname_default(vxstn_declared_ref(st, name));
    }
    group = vxstn_map_get(plan, secretname);
    if (!vxstn_is_list(group)) {
      group = vxstn_list();
      vxstn_map_set(plan, secretname, group);
    }
    vxstn_list_push(group, vxstn_str(name));
    free(secretname);
  }

  /* One resolution per DISTINCT secret name; the per-instance results
     are mapped back afterwards so the reported shape is unchanged. */
  for (i = 0; i < plan->mlen; i++) {
    const vxstn_val* group = plan->vals[i];
    const char* first = vxstn_strval(group->items[0]);
    vxstn_error* err = NULL;
    bool got = NULL != broker_value(&st->broker, first, plan->keys[i], &err);
    vxstn_error_free(err);
    for (j = 0; j < group->len; j++) {
      vxstn_list_push(got ? warmed : missed, vxstn_clone(group->items[j]));
    }
  }
  vxstn_val_free(wanted);
  vxstn_val_free(plan);

  /* Both sorted: a stable answer is what a fleet report needs. */
  {
    vxstn_val* lists[2];
    lists[0] = warmed;
    lists[1] = missed;
    for (i = 0; i < 2; i++) {
      size_t a;
      for (a = 1; a < lists[i]->len; a++) {
        vxstn_val* cur = lists[i]->items[a];
        size_t k = a;
        while (0 < k && 0 < strcmp(vxstn_strval(lists[i]->items[k - 1]),
                                   vxstn_strval(cur))) {
          lists[i]->items[k] = lists[i]->items[k - 1];
          k--;
        }
        lists[i]->items[k] = cur;
      }
    }
  }

  vxstn_map_set(out, "warmed", warmed);
  vxstn_map_set(out, "missed", missed);
  return out;
}

bool vxstn_repo_scoped(vxstn_station* st) { return NULL != st && st->repo_scoped; }
