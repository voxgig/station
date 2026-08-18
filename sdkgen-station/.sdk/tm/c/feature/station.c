// Station feature: binds this SDK to a voxgig/station control surface -
// registration, wire-truth http events, and placeholder credential
// injection. Thin by design - every DECISION it enforces (wrap order,
// host policy, secret resolution, event shapes, error codes) lives in
// the station library (station design 2); this file is only the bridge
// between the SDK's voxgig_value/Fetcher types and that library.
//
// The station library rides VENDORED beside this file, at
// feature/station/voxgig_station.{h,c} - C has no package registry to
// declare a dependency in (station design 9.2), so the tier-C library
// ships with the feature source and the SDK Makefile's feature/*/*.c
// wildcard compiles it. Its canonical source is the voxgig/station
// repo's c/ port; the copy here is refreshed by the sdkgen-station
// package, so never edit it in a generated project (add is overwrite).
//
// C has no extend seam and no connect/adopt (station design 3.1: for c,
// regeneration with this feature is the only retrofit), so binding is
// the INVERTED form only: the app opens a station (vxstn_open) and
// constructs the SDK with options.feature.station.active = true; this
// feature binds to the ambient instance - or to an isolated one handed
// through the options as a station_handle_value() entry - during
// construction. No station open -> inert no-op that emits nothing and
// fails nothing (station design 3.1).
//
// C also cannot throw from init, so guard trips (station_wrap_order,
// station_bound_twice) fail LOUDLY on the operation path instead: the
// error event is emitted once at init and every request through the
// wrap returns the guard's code until the configuration is fixed. One
// honest limit of that idiom: a list-form feature order that puts
// station BEFORE test lets the mock transport REPLACE the failing wrap
// afterwards (test replaces, it does not wrap), leaving the error
// event as the only signal - the map-form default order (the generated
// make_options station-after-test splice) never produces that layout.

#include "sdk.h"

#include "station/voxgig_station.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  Feature base;
  char* name;
  bool active;
  voxgig_value* add_opts;
  voxgig_value* options;
  vxstn_station* st; // NULL while inert (no station open at construction)
  char* slug;        // registered slug (NULL while inert/failed)
  char* rung;        // "R1" | "none"
  char* fail_code;   // a tripped guard: every request fails with this
  char* fail_msg;
} StationFeature;

typedef struct {
  Fetcher* inner;
  StationFeature* sf;
} StationLink;

// ---- station handle in options -------------------------------------------
//
// The ambient instance needs no handle. An ISOLATED station (tests,
// multi-tenant hosts) rides the feature options as a FUNC value whose
// closure holds the pointer - the generated make_options deep-clones
// and merges the options, and voxgig_clone copies a FUNC's fn+ud
// verbatim, so the handle survives the trip (the lua/perl ports'
// closure device, for the same reason).

static voxgig_value* station_handle_fn(void* ud, voxgig_value* arg) {
  (void)arg;
  return v_int((int64_t)(intptr_t)ud);
}

voxgig_value* station_handle_value(vxstn_station* st) {
  return vfn(station_handle_fn, (void*)st);
}

static vxstn_station* station_resolve(voxgig_value* fopts) {
  voxgig_value* handle = getp(fopts, "station");
  if (voxgig_is_func(handle)) {
    voxgig_value* got = call_vfn(handle, voxgig_new_undef());
    if (voxgig_is_number(got)) {
      return (vxstn_station*)(intptr_t)to_int(got);
    }
  }
  return vxstn_current();
}

// ---- value bridging ------------------------------------------------------

// Shallow map copy (copy-on-inject, station design 5.3): the generated
// request machinery shares references - fetchdef.headers IS
// spec.headers, and ctrl.explain holds the fetchdef - so the fetchdef
// and its headers map are duplicated before any swap; the object graph
// reachable from ctx/spec/ctrl holds only the placeholder, ever.
static voxgig_value* shallow_copy_map(voxgig_value* m) {
  voxgig_value* out = voxgig_new_map();
  if (voxgig_is_map(m)) {
    voxgig_map* mm = voxgig_as_map(m);
    for (size_t i = 0; i < mm->len; i++) {
      setp(out, mm->entries[i].key, voxgig_retain(mm->entries[i].value));
    }
  }
  return out;
}

// Literal replace-all of `find` in `s`; malloc'd.
static char* str_replace_all(const char* s, const char* find, const char* rep) {
  size_t flen = strlen(find);
  size_t rlen = strlen(rep);
  size_t cap = strlen(s) + 1;
  char* out;
  size_t len = 0;
  const char* p = s;
  if (0 == flen) {
    out = (char*)malloc(cap);
    memcpy(out, s, cap);
    return out;
  }
  out = (char*)malloc(cap);
  while (1) {
    const char* hit = strstr(p, find);
    size_t take = hit ? (size_t)(hit - p) : strlen(p);
    size_t need = len + take + (hit ? rlen : 0) + 1;
    if (need > cap) {
      while (need > cap) cap *= 2;
      out = (char*)realloc(out, cap);
    }
    memcpy(out + len, p, take);
    len += take;
    if (!hit) break;
    memcpy(out + len, rep, rlen);
    len += rlen;
    p = hit + flen;
  }
  out[len] = '\0';
  return out;
}

// The client's options.feature reduced to {name: {active}} JSON - the
// only part registration reads - so FUNC handles and mock fixtures
// never need serializing.
static char* features_json(Context* ctx) {
  voxgig_value* reduced = voxgig_new_map();
  voxgig_value* fmap = to_map(getp(ctx->options, "feature"));
  char* out;
  if (voxgig_is_map(fmap)) {
    voxgig_map* mm = voxgig_as_map(fmap);
    for (size_t i = 0; i < mm->len; i++) {
      bool active = false;
      get_bool(mm->entries[i].value, "active", &active);
      setp(reduced, mm->entries[i].key, cmap(1, "active", v_bool(active)));
    }
  }
  out = voxgig_jsonify(reduced, NULL);
  return out ? out : strdup("{}");
}

// The per-op correlation state PrePoint stashed on the SDK's own ctx
// (ctx.out_extra "station$"). corr may be NULL (direct/graphql bypass
// the hook pipeline but not the transport).
static const char* op_corr(Context* ctx, int64_t* start_out) {
  voxgig_value* stv = ctx_out_extra_get(ctx, "station$");
  if (start_out) {
    voxgig_value* start = getp(stv, "start");
    *start_out = voxgig_is_number(start) ? to_int(start) : 0;
  }
  return get_str(stv, "corr");
}

// ---- the transport middleware (station design 3.3, 5.3) ------------------

static voxgig_value* station_fetch(Fetcher* self, Context* ctx, const char* url,
                                   voxgig_value* fetchdef, PNError** err) {
  StationLink* link = (StationLink*)self->state;
  StationFeature* sf = link->sf;
  vxstn_station* st = sf->st;
  const char* corr;
  int64_t started;
  voxgig_value* senddef = fetchdef;
  bool live;
  bool has_policy = false;
  PNError* e = NULL;
  voxgig_value* out;

  *err = NULL;

  // A tripped construction guard fails every request loudly rather than
  // silently reporting non-wire events (station design 3.3).
  if (sf->fail_code) {
    *err = context_make_error(ctx, sf->fail_code, sf->fail_msg);
    return NULL;
  }

  corr = op_corr(ctx, NULL);

  // Fail-closed means traffic (station design 2.1): with the proxy
  // deferred, `require` can never attach, so every operation fails here
  // - the operation path, never the constructor.
  if (vxstn_require_proxy(st)) {
    const char* msg = "proxy: \"require\" is set and no proxy is attached";
    vxstn_emit_err(st, sf->slug, corr, "station_no_proxy", msg);
    *err = context_make_error(ctx, "station_no_proxy", msg);
    return NULL;
  }

  live = ctx->client && ctx->client->mode && 0 == strcmp(ctx->client->mode, "live");

  // Egress policy (station design 16), solo half: the hosts allowlist
  // is enforced at the seam every request crosses. When a policy is
  // present the fetchdef asks for manual redirects - a 3xx is a
  // response like any other, so a Location off the allowlist cannot
  // pull an automatic credentialed follow-up to an unapproved host
  // (design 8.2's rule at the library seam). NOTE the C SDK's live
  // transport is the app-supplied options.system.fetch; it should
  // honour the redirect slot.
  if (live && !vxstn_host_allowed(st, sf->slug, url, &has_policy)) {
    char msg[512];
    snprintf(msg, sizeof(msg),
             "egress denied by the hosts policy of plugin \"%s\" (URL was: \"%s\")",
             sf->slug ? sf->slug : "", url);
    vxstn_emit_err(st, sf->slug, corr, "station_host_allow", msg);
    *err = context_make_error(ctx, "station_host_allow", msg);
    return NULL;
  }

  if (live && has_policy) {
    senddef = shallow_copy_map(senddef);
    setp(senddef, "redirect", v_str("manual"));
  }

  // Injection: at the last boundary, below every recording feature, and
  // never into mock transports (station design 3.3) - in test/mock
  // modes the placeholder rides through untouched, so real credentials
  // never enter in-memory mock stores. Copy-on-inject (design 5.3).
  if (live && sf->rung && 0 == strcmp(sf->rung, "R1")) {
    vxstn_error* serr = NULL;
    const char* value = vxstn_secret_value(st, sf->slug, &serr);
    if (NULL == value) {
      const char* code = serr ? serr->code : "station_secret_error";
      const char* msg = serr ? serr->message : "station_secret_error";
      vxstn_emit_err(st, sf->slug, corr, code, msg);
      *err = context_make_error(ctx, code, msg);
      vxstn_error_free(serr);
      return NULL;
    }
    {
      char* placeholder = vxstn_placeholder(sf->slug);
      voxgig_value* headers;
      if (senddef == fetchdef) {
        senddef = shallow_copy_map(senddef);
      }
      headers = shallow_copy_map(getp(senddef, "headers"));
      if (voxgig_is_map(headers)) {
        voxgig_map* hm = voxgig_as_map(headers);
        for (size_t i = 0; i < hm->len; i++) {
          voxgig_value* hv = hm->entries[i].value;
          if (voxgig_is_string(hv) && NULL != strstr(voxgig_as_string(hv), placeholder)) {
            char* swapped = str_replace_all(voxgig_as_string(hv), placeholder, value);
            setp(headers, hm->entries[i].key, v_str(swapped));
            free(swapped);
          }
        }
      }
      setp(senddef, "headers", headers);
      free(placeholder);
    }
  }

  started = vxstn_now_ms();
  out = link->inner->fn(link->inner, ctx, url, senddef, &e);

  if (e) {
    // One http event per attempt, wire truth even for failures.
    vxstn_emit_http(st, sf->slug, corr, get_str(senddef, "method"), url, 0, started, 0);
    vxstn_emit_err(st, sf->slug, corr, e->code, e->msg);
    *err = e;
    return out;
  }

  {
    int64_t status = 0;
    int64_t bytes = 0;
    if (voxgig_is_map(out)) {
      fres_status(out, &status);
      bytes = fparse_int(fres_header(out, "content-length"), 0);
    }
    vxstn_emit_http(st, sf->slug, corr, get_str(senddef, "method"), url,
                    status, started, bytes);
  }

  return out;
}

// ---- op events (the hook bridge, station design 3 item 3) ----------------

static void station_op_event(StationFeature* sf, Context* ctx, const char* forced) {
  SdkResult* result = ctx->out_result ? ctx->out_result : ctx->result;
  const char* outcome = forced
      ? forced
      : vxstn_outcome(NULL != result, NULL != result && NULL != result->err,
                      NULL != result && result->ok);
  int64_t start = 0;
  const char* corr = op_corr(ctx, &start);
  const char* entity = ctx->op && ctx->op->entity ? ctx->op->entity : "";
  const char* opname = ctx->op && ctx->op->name ? ctx->op->name : "";
  if ('\0' == entity[0] && ctx->entity) {
    entity = ctx->entity->vt->get_name(ctx->entity);
  }
  vxstn_emit_op(sf->st, sf->slug, corr, entity, opname, outcome,
                0 != start ? vxstn_now_ms() - start : 0);
}

// ---- feature vtable ------------------------------------------------------

static const char* station_name(Feature* f) { return ((StationFeature*)f)->name; }
static bool station_active(Feature* f) { return ((StationFeature*)f)->active; }
static voxgig_value* station_add_options(Feature* f) {
  return ((StationFeature*)f)->add_opts;
}

static void station_bind_fail(StationFeature* sf, Context* ctx, vxstn_error* err) {
  sf->fail_code = strdup(err->code);
  sf->fail_msg = strdup(err->message);
  vxstn_emit_err(sf->st, sf->slug, NULL, err->code, err->message);
  vxstn_error_free(err);
  (void)ctx;
}

static void station_wrap(StationFeature* sf, Context* ctx) {
  Utility* util = context_util(ctx);
  StationLink* link = (StationLink*)calloc(1, sizeof(StationLink));
  Fetcher* wrapped = (Fetcher*)calloc(1, sizeof(Fetcher));
  link->inner = util->fetcher;
  link->sf = sf;
  wrapped->fn = station_fetch;
  wrapped->state = link;
  util->fetcher = wrapped;
}

static void station_init(Feature* f, Context* ctx, voxgig_value* options) {
  StationFeature* sf = (StationFeature*)f;
  vxstn_station* st;
  vxstn_binding* binding;
  vxstn_error* err = NULL;
  char* config_json;
  char* feats_json;

  sf->options = options;
  sf->active = fopt_bool(options, "active", false);
  if (!sf->active) return;

  // Resolve the station this activation binds to: an explicit handle in
  // the feature options, else the ambient instance. No station open ->
  // inert no-op that emits nothing and fails nothing (design 3.1;
  // binding is never implicit - the activation entry is).
  st = station_resolve(options);
  if (NULL == st) return;
  sf->st = st;

  // Same client, second arrival: the first bind won, this one is inert.
  if (ctx->client && vxstn_bound(st, (void*)ctx->client)) {
    sf->st = NULL;
    return;
  }

  // Position guard (station design 3.3): the wrap must sit immediately
  // outside the base transport - inside retry/cache/ratelimit - or its
  // http events stop being wire truth. Position in client->features IS
  // init order; the library's check excludes the inert "base" strays
  // the generated make_feature falls back to for unknown names.
  if (ctx->client) {
    size_t n = ctx->client->features_len;
    const char** names = (const char**)malloc((0 == n ? 1 : n) * sizeof(char*));
    vxstn_error* oerr;
    for (size_t i = 0; i < n; i++) {
      names[i] = ctx->client->features[i]->vt->name(ctx->client->features[i]);
    }
    oerr = vxstn_wrap_order_check(names, n);
    free(names);
    if (oerr) {
      station_bind_fail(sf, ctx, oerr);
      station_wrap(sf, ctx); // requests fail station_wrap_order loudly
      return;
    }
  }

  // A double wrap is a second binding of the same client (design 10.2).
  {
    Utility* util = context_util(ctx);
    if (util->fetcher && station_fetch == util->fetcher->fn) {
      station_bind_fail(sf, ctx,
                        vxstn_error_new("station_bound_twice",
                                        "client already carries a station wrap"));
      station_wrap(sf, ctx);
      return;
    }
  }

  // Registration (station design 3 item 1): the descriptor is a view
  // over the embedded config, serialized across the value-model
  // boundary as JSON.
  config_json = voxgig_jsonify(ctx->config, NULL);
  feats_json = features_json(ctx);
  binding = vxstn_register(st, ctx->client ? (void*)ctx->client : (void*)sf,
                           config_json ? config_json : "{}", feats_json,
                           fopt_str(options, "secret", ""), &err);
  free(config_json);
  free(feats_json);
  if (NULL == binding) {
    station_bind_fail(sf, ctx, err ? err : vxstn_error_new("station_protocol", "register failed"));
    station_wrap(sf, ctx);
    return;
  }
  sf->slug = strdup(binding->plugin);
  sf->rung = strdup(binding->rung);

  // Credential placement (station design 3 item 4, 5.3): a real
  // credential already resident in the options is hoisted into the
  // broker and replaced by the placeholder before construction
  // completes - options and prepare() output become placeholder-safe
  // from here on. The feature never handles the secret value itself;
  // injection happens in the middleware at send time.
  if (0 == strcmp(sf->rung, "R1")) {
    char* placeholder = vxstn_placeholder(sf->slug);
    voxgig_value* resident = getp(ctx->options, "apikey");
    if (voxgig_is_string(resident)) {
      const char* rv = voxgig_as_string(resident);
      if ('\0' != rv[0] && 0 != strcmp(rv, placeholder)) {
        vxstn_hoist(st, sf->slug, rv);
      }
    }
    setp(ctx->options, "apikey", v_str(placeholder));
    free(placeholder);
  }

  vxstn_binding_free(binding);

  // Wrap the transport (station design 3 item 2). The wrap covers
  // direct() and graphql() traffic, which skip the hook pipeline but
  // not the transport.
  station_wrap(sf, ctx);
}

static void station_hook(Feature* f, const char* name, Context* ctx) {
  StationFeature* sf = (StationFeature*)f;
  if (NULL == sf->st || NULL == sf->slug || sf->fail_code) return;

  if (0 == strcmp(name, "PrePoint")) {
    // The per-operation correlation id, carried on the SDK's own ctx
    // (ctx.out_extra) so the op and http events correlate (design 3).
    char* corr = vxstn_next_corr(sf->st);
    ctx_out_extra_set(ctx, "station$",
                      cmap(2, "corr", v_str(corr), "start",
                           v_num((double)vxstn_now_ms())));
    free(corr);
  } else if (0 == strcmp(name, "PreDone")) {
    station_op_event(sf, ctx, NULL);
  } else if (0 == strcmp(name, "PreUnexpected")) {
    station_op_event(sf, ctx, "unexpected");
  }
}

static const FeatureVT STATION_VT = {
  station_name, station_active, station_add_options, station_init, station_hook,
  NULL, // no activity tracking; the event stream is the record
};

Feature* feature_station_new(void) {
  StationFeature* sf = (StationFeature*)calloc(1, sizeof(StationFeature));
  sf->base.vt = &STATION_VT;
  sf->name = strdup("station");
  sf->active = true; // overridden by init from options, like every feature
  sf->add_opts = NULL;
  sf->options = voxgig_new_undef();
  return (Feature*)sf;
}
