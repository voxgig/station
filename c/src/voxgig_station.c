/* voxgig/station - one control surface for outbound integrations (C port).
 *
 * See voxgig_station.h for the scope statement (tier C: solo only,
 * env-only secrets, config in code) and the copy discipline (canonical
 * source: voxgig/station c/src/; vendored copy: sdkgen-station
 * .sdk/tm/c/feature/station/ - byte-identical, edit HERE first).
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

  override_ = kv_get(b->overrides, b->noverrides, slug);
  if (NULL != override_) {
    return override_;
  }
  cached = kv_get(b->cache, b->ncache, slug);
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

  kv_set(&b->cache, &b->ncache, slug, env);
  broker_hold(b, env);
  return kv_get(b->cache, b->ncache, slug);
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

typedef struct {
  char* slug;
  vxstn_val* descriptor;
  char* rung; /* "R1" | "none" */
  void* client;
  vxstn_val* warnings;   /* list of strings */
  char* secretname;      /* effective (fopt > profile > default) */
} vxstn_plugin_entry;

struct vxstn_station {
  vxstn_val* profile; /* { name, providers, plugin } */
  vxstn_broker broker;
  vxstn_events_buf events;
  vxstn_plugin_entry* plugins;
  size_t nplugins;
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
  }
  out = vxstn_canonical(m);
  vxstn_val_free(m);
  return out;
}

static void station_emit(vxstn_station* st, vxstn_val* ev) {
  events_emit(&st->events, ev);
}

void vxstn_emit_warn(vxstn_station* st, const char* slug, const char* warn) {
  vxstn_val* ev;
  vxstn_val* meta;
  if (NULL == st) {
    return;
  }
  ev = vxstn_map();
  vxstn_map_set(ev, "t", vxstn_int(vxstn_now_ms()));
  vxstn_map_set(ev, "kind", vxstn_str("station"));
  if (NULL != slug && '\0' != slug[0]) {
    vxstn_map_set(ev, "plugin", vxstn_str(slug));
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
      vxstn_seterr(err, "station_protocol", NULL == jerr ? "invalid config JSON" : jerr);
      free(jerr);
      return NULL;
    }
  }

  profile_name = vxstn_select_profile(NULL == opts ? NULL : opts->profile);

  st = (vxstn_station*)calloc(1, sizeof(vxstn_station));
  st->profile = vxstn_resolve_profile(config, profile_name, &perr);
  vxstn_val_free(config);
  free(profile_name);
  if (NULL == st->profile) {
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
  broker_destroy(&st->broker);
  events_destroy(&st->events);
  for (i = 0; i < st->nplugins; i++) {
    free(st->plugins[i].slug);
    vxstn_val_free(st->plugins[i].descriptor);
    free(st->plugins[i].rung);
    vxstn_val_free(st->plugins[i].warnings);
    free(st->plugins[i].secretname);
  }
  free(st->plugins);
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
      if (0 == strcmp(st->plugins[j].slug, keys[i])) {
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

static vxstn_plugin_entry* find_plugin(vxstn_station* st, const char* slug) {
  size_t i;
  if (NULL == slug) {
    return NULL;
  }
  for (i = 0; i < st->nplugins; i++) {
    if (0 == strcmp(st->plugins[i].slug, slug)) {
      return &st->plugins[i];
    }
  }
  return NULL;
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
  free(b->placeholder);
  free(b->secretname);
  free(b->rung);
  free(b);
}

vxstn_binding* vxstn_register(vxstn_station* st, void* client,
                              const char* config_json,
                              const char* features_json,
                              const char* secret_opt,
                              vxstn_error** err) {
  vxstn_val* config;
  vxstn_val* features = NULL;
  vxstn_val* warnings = NULL;
  vxstn_val* descriptor;
  const vxstn_val* auth;
  const vxstn_val* activev;
  const char* slug;
  bool auth_active;
  const char* profile_secret = NULL;
  const char* effective_secret;
  vxstn_plugin_entry* entry;
  vxstn_binding* binding;
  char* jerr = NULL;
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

  descriptor = vxstn_normalize_descriptor(config, features, &warnings);
  vxstn_val_free(config);
  vxstn_val_free(features);

  slug = vxstn_strval(vxstn_map_get(descriptor, "slug"));

  if (NULL != find_plugin(st, slug)) {
    vxstn_sb msg;
    vxstn_sb_init(&msg);
    vxstn_sb_put(&msg, "plugin \"");
    vxstn_sb_put(&msg, slug);
    vxstn_sb_put(&msg, "\" is already registered; binding one client twice is an "
                 "error (10.2)");
    vxstn_seterr(err, "station_bound_twice", msg.buf);
    free(msg.buf);
    vxstn_val_free(descriptor);
    vxstn_val_free(warnings);
    return NULL;
  }

  auth = vxstn_map_get(descriptor, "auth");
  activev = vxstn_map_get(auth, "active");
  auth_active = NULL != activev && VXSTN_BOOL == activev->kind && activev->b;

  /* Secret name precedence: the feature option (in-code, design 9
   * config.options.secret) beats the profile, which beats the
   * descriptor default. */
  {
    const vxstn_val* pp = vxstn_getk(vxstn_map_get(st->profile, "sdk"), slug);
    const vxstn_val* ps = vxstn_getk(pp, "secret");
    if (vxstn_is_str(ps) && '\0' != ps->str[0]) {
      profile_secret = ps->str;
    }
  }
  if (NULL != secret_opt && '\0' != secret_opt[0]) {
    effective_secret = secret_opt;
  } else if (NULL != profile_secret) {
    effective_secret = profile_secret;
  } else {
    effective_secret = vxstn_strval(vxstn_map_get(auth, "secretname"));
  }

  st->plugins = (vxstn_plugin_entry*)realloc(
      st->plugins, (st->nplugins + 1) * sizeof(vxstn_plugin_entry));
  entry = &st->plugins[st->nplugins++];
  memset(entry, 0, sizeof(*entry));
  entry->slug = vxstn_sdup(slug);
  entry->descriptor = descriptor;
  entry->rung = vxstn_sdup(auth_active ? "R1" : "none");
  entry->client = client;
  entry->warnings = warnings;
  entry->secretname = vxstn_sdup(effective_secret);

  for (i = 0; i < entry->warnings->len; i++) {
    vxstn_emit_warn(st, slug, vxstn_strval(entry->warnings->items[i]));
  }
  {
    vxstn_val* ev = vxstn_map();
    vxstn_val* meta = vxstn_map();
    vxstn_map_set(ev, "t", vxstn_int(vxstn_now_ms()));
    vxstn_map_set(ev, "kind", vxstn_str("construct"));
    vxstn_map_set(ev, "plugin", vxstn_str(slug));
    vxstn_map_set(meta, "name",
                  vxstn_str(vxstn_strval(vxstn_map_get(descriptor, "name"))));
    vxstn_map_set(meta, "version",
                  vxstn_str(vxstn_strval(vxstn_map_get(descriptor, "version"))));
    vxstn_map_set(meta, "rung", vxstn_str(entry->rung));
    vxstn_map_set(ev, "meta", meta);
    station_emit(st, ev);
  }

  binding = (vxstn_binding*)calloc(1, sizeof(vxstn_binding));
  binding->plugin = vxstn_sdup(slug);
  binding->placeholder = auth_active ? vxstn_placeholder(slug) : NULL;
  binding->secretname = auth_active ? vxstn_sdup(effective_secret) : NULL;
  binding->rung = vxstn_sdup(entry->rung);
  return binding;
}

/* --- middleware seams --- */

bool vxstn_require_proxy(vxstn_station* st) {
  return NULL != st && st->require_proxy;
}

const vxstn_val* vxstn_profile_sdk(vxstn_station* st, const char* slug) {
  if (NULL == st || NULL == slug) {
    return NULL;
  }
  return vxstn_getk(vxstn_map_get(st->profile, "sdk"), slug);
}

bool vxstn_host_allowed(vxstn_station* st, const char* slug,
                        const char* fullurl, bool* has_policy) {
  const vxstn_val* pp = vxstn_profile_sdk(st, slug);
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

const char* vxstn_secret_value(vxstn_station* st, const char* slug,
                               vxstn_error** err) {
  vxstn_plugin_entry* entry;
  if (NULL != err) {
    *err = NULL;
  }
  entry = NULL == st ? NULL : find_plugin(st, slug);
  if (NULL == entry) {
    vxstn_seterr(err, "station_no_plugin", "unknown plugin");
    return NULL;
  }
  return broker_value(&st->broker, slug, entry->secretname, err);
}

void vxstn_hoist(vxstn_station* st, const char* slug, const char* value) {
  if (NULL == st || NULL == slug || NULL == value) {
    return;
  }
  broker_hoist(&st->broker, slug, value);
  vxstn_emit_warn(st, slug,
                  "a resident credential was hoisted into the broker and "
                  "replaced by the placeholder; prefer configuring the secret "
                  "name and letting the environment resolve it");
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

static void ev_common(vxstn_val* ev, int64_t t, const char* kind,
                      const char* slug, const char* corr) {
  vxstn_map_set(ev, "t", vxstn_int(t));
  vxstn_map_set(ev, "kind", vxstn_str(kind));
  if (NULL != slug && '\0' != slug[0]) {
    vxstn_map_set(ev, "plugin", vxstn_str(slug));
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
      vxstn_map_set(p, "slug", vxstn_str(st->plugins[i].slug));
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
  for (i = 0; i < st->nplugins; i++) {
    vxstn_val* p = vxstn_map();
    vxstn_map_set(p, "slug", vxstn_str(st->plugins[i].slug));
    vxstn_map_set(p, "descriptor", vxstn_clone(st->plugins[i].descriptor));
    vxstn_map_set(p, "rung", vxstn_str(st->plugins[i].rung));
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
        vxstn_sb_put(&msg, st->plugins[i].slug);
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
